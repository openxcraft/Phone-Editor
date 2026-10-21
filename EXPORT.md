# Export

## Supported targets

- PDF, PDF/A-1/2/3, PDF/UA-1
- DOCX, PPTX, XLSX
- SVG, HTML, Markdown
- CSV, JSON

## Rules

- A single neutral node tree feeds all exports. No export reads UI state.
- Styles, structure, accessibility tags, and metadata are preserved where
  the format allows; losses are documented per format, never silent.
- Deterministic output: same input tree → byte-identical output for
  text formats (Markdown, HTML, SVG, CSV, JSON). Binary formats use
  document metadata timestamps, never wall-clock time.
- Deterministic filenames: `<document-title-slug>.<ext>`, collisions
  resolved with `-2`, `-3`, … in creation order.
- No vendor or capability-provider strings in output, metadata, or
  filenames.
- Round-trip tests for Office formats; visual regression tests for
  PDF/SVG.

## Slice-1 export: Markdown

Implemented in `packages/doc_engine/lib/src/markdown_export.dart`.

Mapping (deterministic):

| Node | Output |
|---|---|
| Document title (non-empty) | `# <title>` followed by a blank line |
| `heading1` block | `# …` |
| `heading2` block | `## …` |
| `paragraph` block | plain paragraph |
| `bullet` block | `- …` |
| `quote` block | `> …` |
| inline `code` | `` `…` `` (other marks ignored inside code) |
| inline `bold` | `**…**` |
| inline `italic` | `*…*` |
| inline `bold`+`italic` | `***…***` |
| inline `underline` | plain text (Markdown has no underline; documented loss) |

Plain text escapes `\`, `` ` ``, `*`, `_` with a backslash. Blocks are
separated by one blank line; the file ends with exactly one newline.
