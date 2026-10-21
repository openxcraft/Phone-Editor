# export_engine

Deterministic OOXML export/import for the workspace engines:

- **PPTX** (`PptxExporter` / `PptxImporter`) for
  `presentation_engine`'s `Presentation`.
- **XLSX** (`XlsxExporter` / `XlsxImporter`) for `sheets_engine`'s
  `Sheet`.

Both exporters write real ZIP-based OOXML files and are deterministic:
ZIP entries carry a fixed 1980 timestamp, timestamps inside parts come
from model metadata (never a wall clock), and iteration order is fixed,
so the same model always exports to byte-identical output. Both
importers are deliberately minimal — they read back the subset the
exporters write, so export → import → export is byte-stable for
fixtures inside that subset (asserted in tests).

## Unit decision (PPTX)

The presentation model stores slide size and element geometry in
**points** (1/72 inch). OOXML uses EMUs: 914400 per inch, so
**1 point = 12700 EMU**. Export rounds `points * 12700` to the nearest
EMU; import divides by 12700. Geometry that is a whole number of points
round-trips exactly. Decks authored at the presentation engine's
default 1280×720 slide units are interpreted as 1280×720 pt
(17.8×10 in); callers thinking in pixels should scale first. Rotation
maps directly: model degrees → DrawingML `rot` (60000ths of a degree).
Opacity maps to fill alpha (100000 = opaque).

## PPTX — what is preserved

Slide count and order; slide size; document title and created/modified
timestamps (core properties); per element: ID, kind (text box vs
shape), text (multi-line via one paragraph per line), position, size,
rotation, and opacity.

## PPTX — documented losses

- **Animations are NOT exported** (no timing XML) and transitions are
  NOT exported; a re-imported deck has no tracks and no transitions.
- **Presenter notes are NOT exported** (no notes slides parts).
- **Image elements export as grey placeholder rectangles** and
  re-import as shapes — the model holds no image binary data in this
  increment, and the element kind is lost.
- **Colours and text styling are not in the model**: shapes export
  with a fixed neutral grey fill (D9D9D9); text exports unstyled
  (no font, size, colour, bold/italic). Import ignores fills except
  for alpha (opacity).
- The presentation ID is not stored in the PPTX format; import takes
  it as a parameter (default `presentation`). Slide and element IDs
  *are* preserved, in `cSld/@name` and shape names — third-party decks
  without those names import with generated IDs.
- Decks produced by other tools import only approximately: only
  `p:sp` shapes are read (no pictures, tables, groups, charts, or
  connectors), and text is flattened to plain lines.

## XLSX — what is preserved

A single sheet with its name; per cell: numbers, text (shared strings),
booleans, error cells, and formulas — formulas keep their source and
carry the engine-computed value as the cached `<v>` (text results use
`t="str"`, booleans `t="b"`, errors `t="e"`). Import restores stored
cells exactly and recomputes formula values through the sheets engine.

## XLSX — documented losses

- **Charts and pivot summaries are NOT exported** — they are derived
  views in the sheets engine and have no stored form in this package.
- **Only one sheet**: the model is a single `Sheet`; there is no
  multi-sheet workbook support.
- **No styling**: one default font/style is written; number formats,
  column widths, merged cells, frozen panes, and conditional formats
  are not represented in the model and are not exported.
- Formulas whose computed value is empty export without a cached
  value; formulas are written without sheet qualifiers (single-sheet
  engine), so cross-sheet references cannot be represented.
- Sheet names are written as-is; names that spreadsheet applications
  consider invalid (over 31 characters, or containing `: \ / ? * [ ]`)
  are the caller's responsibility.
- Third-party workbooks import only approximately: only
  `xl/worksheets/sheet1.xml` is read, rich-text runs inside a shared
  string are concatenated without formatting, and inline strings are
  read as plain text.

## Verification

```
dart pub get
dart analyze   # clean
dart test      # PPTX/XLSX parts, determinism, round-trip stability
```
