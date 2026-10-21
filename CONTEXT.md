# Context — Product Brief

A cross-platform mobile workspace for documents, presentations, PDFs, and
sheets. Professional quality, high performance on mid-range phones,
accessible, secure, maintainable. Offline-first: every capability below
works without a network connection; sync is background and conflict-safe.

## First-class capabilities

1. **Rich-text editor** — professional formatting, tables, images, comments,
   track changes, find/replace, undo/redo, robust document model.
2. **Presentation maker** — slides, layouts, animations, motion, transitions,
   presenter mode, deterministic playback.
3. **PDF workspace** — view, annotate, edit forms/signatures where feasible,
   generate PDFs, export PDF/A and PDF/UA.
4. **Sheets maker and data analysis** — formulas, dependency graph, charts,
   pivot-like summaries, analysis workflows.
5. **Word/document maker** — templates, styles, sections, headers/footers,
   references, export to DOCX/PDF.
6. **Export pipeline** — PDF, PDF/A, PDF/UA, DOCX, PPTX, XLSX, SVG, HTML,
   Markdown, CSV, JSON.
7. **External model API integration** — user supplies endpoint, key, and
   model; the app calls it through a provider-agnostic adapter. No vendor
   branding anywhere in UI, strings, metadata, docs, or code comments.
8. **MCP support** — the app acts as an MCP client and as a local MCP server
   so external agents can control documents through permissioned tools.

## Non-negotiable constraints

- UI is clean, minimal, calm, professional. Progressive disclosure: the
  default surface is simple; advanced tools appear only contextually.
- No assistant persona, no chat-first UI, no sparkle iconography, no
  branded gradients. The external-model capability is an optional feature
  behind user-configured API settings, labelled neutrally.
- Deterministic engines; a single source of truth for
  rendering / playback / export.
- Small verified increments: each ships code, tests, and a verification note.
