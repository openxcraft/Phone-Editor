# Mobile Workspace

Offline-first mobile workspace for documents, presentations, PDFs, and
sheets. Start with the context files:

- [CONTEXT.md](CONTEXT.md) — product brief
- [ARCHITECTURE.md](ARCHITECTURE.md) — stack and sync model
- [ENGINES.md](ENGINES.md) — engine contracts
- [UX.md](UX.md) — design principles
- [API_MCP.md](API_MCP.md) — external model API and MCP
- [EXPORT.md](EXPORT.md) — export formats and rules
- [SECURITY.md](SECURITY.md) — security and performance budgets
- [ACCEPTANCE.md](ACCEPTANCE.md) — acceptance checklist
- [PLAN.md](PLAN.md) — phased build plan

## Layout

```
app/                          Flutter shell (list + editor; needs Flutter SDK)
packages/doc_engine/          Documents: model, ops, comments, suggestions, SQLite, MD/HTML/DOCX
packages/presentation_engine/ Slides: scene graph, animation, pure playback core
packages/sheets_engine/       Sheets: formulas, dependency graph, charts, pivot, CSV/JSON
packages/sync_engine/         CRDT text, deltas, merge, sync sessions
packages/api_mcp/             External-model adapter + MCP client/server
packages/pdf_engine/          Deterministic PDF generation + annotations
packages/vault/               AES-256-GCM encrypted document store
packages/export_engine/       PPTX + XLSX export/import round-trips
rust/doc_core/                Rust mirror of the document model (golden-tested vs Dart)
rust/golden/                  Shared Dart<->Rust golden vectors
db/schema_v1.sql              SQLite schema v1 (verified with the sqlite3 CLI)
tools/verify.sh               Full verification (all packages + Rust + schema + scans)
tools/security_scan.sh        Brand/secret scan
```

## Verification

```sh
tools/verify.sh
```

Runs `dart analyze` + `dart test` for every package, `cargo test` for
the Rust core, applies `db/schema_v1.sql` with the `sqlite3` CLI, and
runs the security scan. Current status: **266 tests passing** — see
FINAL_VERIFICATION.md. The Flutter shell is compiled separately:

```sh
cd app && flutter analyze && flutter run
```
