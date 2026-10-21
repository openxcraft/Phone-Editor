# Phased Build Plan

Each phase ends with: code, tests, and a verification note. No phase is
"done" on the strength of source alone.

**Status (2026-10-21, autonomous completion run — see
FINAL_VERIFICATION.md):** Phases 0, 1, 3, 4, 5, 7 complete and tested.
Phase 2 started: Rust `doc_core` matches Dart byte-for-byte on golden
vectors; the `flutter_rust_bridge` wiring remains. Phase 6 generation
complete; PDF/A / PDF/UA external validation open. Phase 8 encryption
and scans complete; accessibility audit pending a Flutter environment.

## Phase 0 — Foundations (Slice 1, this increment)

**Goal:** local document model + editor shell + SQLite persistence +
offline save + one export path.

- `packages/doc_engine` (pure Dart): node tree, operations, undo/redo,
  find/replace, deterministic JSON, Markdown export.
- SQLite schema v1 (`db/schema_v1.sql`) with `updated_at`, `deleted_at`,
  `sync_status`; `SqliteDocumentStore` in the engine package.
- Flutter shell in `app/`: document list + calm editor with contextual
  formatting bar and save-state indicator.

**Verification:** `dart test` in `packages/doc_engine` (model,
serialization, export, SQLite store); `sqlite3` CLI applies
`db/schema_v1.sql` cleanly. Flutter shell compile is a manual step on a
Flutter-equipped machine (blocked in the Slice-1 environment).

## Phase 1 — Document depth

- Tables, images, comments, track changes on the same node tree.
- DOCX + HTML + PDF export from the neutral tree; DOCX round-trip tests.
- Drift layer over the v1 schema; migrations tested from v1.

**Verification:** round-trip fixtures; export golden files; migration test.

## Phase 2 — Rust engine extraction

- Port `doc_engine` contracts to a Rust crate behind
  `flutter_rust_bridge`; Dart package becomes the reference implementation.
- Byte-identical JSON and Markdown output enforced by shared golden files.

**Verification:** same test vectors run against both implementations.

## Phase 3 — Sync and collaboration

- Delta sync client against a reference server; CRDT text merge;
  field-level merge for metadata; conflict copies preserved.

**Verification:** scripted conflict scenarios (offline edits on two
devices, delete-vs-edit, rename-vs-edit) with zero data loss assertions.

## Phase 4 — Presentations

- Scene-graph model, animation tracks, pure playback core
  `stateAt(slideId, timeMs)`; editor preview, presenter mode, and PPTX /
  video-frame export all consume the same core.

**Verification:** golden RenderState snapshots at fixed times; preview vs
export frame equality tests.

## Phase 5 — Sheets

- Grid model, formula AST, dependency graph, recalc scheduler, charts,
  CSV/JSON import/export, XLSX export.

**Verification:** formula corpus tests (math/text/date/lookup/logical/
statistical), dependency-order recalc tests, 100k-cell scroll benchmark.

## Phase 6 — PDF workspace

- PDFium viewing, text extraction/search, annotations, forms; PDF
  generation from the neutral tree with PDF/A and PDF/UA options.

**Verification:** PDF/A and PDF/UA validators in CI; annotation
round-trip tests; airplane-mode annotation test.

## Phase 7 — External model API + MCP

- Provider-agnostic adapter (complete/stream/embeddings) with secure
  storage and redacted logs.
- MCP client (discovery + consented calls) and local MCP server with the
  tool set in API_MCP.md, audit log, per-tool permissions.

**Verification:** adapter tests against a local mock HTTP server; MCP
discovery/call test against a reference server; denial-path tests proving
no data leaves without consent; secret-scan of logs and repo.

## Phase 8 — Hardening

- Encryption at rest for sensitive vaults, accessibility audit,
  reduced-motion audit, performance budgets from SECURITY.md, branding
  scan (no vendor strings anywhere in UI, metadata, or output files).

**Verification:** full ACCEPTANCE.md checklist executed and recorded.
