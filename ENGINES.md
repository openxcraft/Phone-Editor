# Engines and Algorithms

Every engine has a stable interface, no UI dependency, and unit tests.

## Document engine

- Node tree: `document → sections → blocks → inline nodes`.
- Operations: insert, delete, transform, style, comment, track-change,
  undo/redo.
- CRDT-backed collaborative text; deterministic serialization.
- Find/replace, spellcheck hooks, accessibility metadata.

Slice-1 status: node tree, insert/delete/mark operations, find/replace,
snapshot-based undo/redo, and deterministic JSON are implemented in
`packages/doc_engine`. CRDT operations, comments, and track changes are
Phase 3 (see PLAN.md).

## Presentation engine

- `slide → elements → animation tracks`.
- Entry / exit / emphasis animations; keyframes; easing; delays; triggers.
- Page transitions including magic-move by stable element IDs.
- Playback core: `stateAt(slideId, timeMs) -> RenderState` — pure function,
  shared by editor preview, presenter mode, and export.
- Presenter mode: notes, timer, next-slide preview.

## PDF engine

- Fast render path; text extraction; search; annotations; form fields;
  signatures where supported.
- Generation pipeline from the neutral node tree; PDF/A and PDF/UA
  options; font embedding; metadata.

## Sheets engine

- Grid model; cell types; formula AST; dependency graph; recalc scheduler.
- Functions: math, text, date, lookup, logical, statistical; array
  formulas if feasible.
- Charts from ranges; analysis summaries; CSV/JSON import/export.

## Export engine

- Neutral node tree → target format.
- Round-trip tests for DOCX/PPTX/XLSX where possible.
- Deterministic output (stable ordering, no timestamps inside file bodies
  unless the format requires them, and then sourced from document
  metadata); no UI dependency.
