# Architecture

## Baseline stack

| Layer | Choice |
|---|---|
| UI | Flutter (Dart), cross-platform UI and gestures |
| Core engines | Rust crates via `flutter_rust_bridge` for document model, CRDT, formula evaluation, export orchestration, MCP transport (phased — see PLAN.md) |
| Local DB | SQLite (drift on top of `sqlite3`) as the single source of truth |
| Rich text | Format-neutral node tree in the engine; native rendering, gestures, IME and selection in the UI layer |
| PDF | PDFium via FFI for fast viewing; a second engine only for advanced edit / signature / form operations |
| Sheets | Canvas-based grid renderer; formula AST tokenizer; dependency graph |
| Presentation | Scene-graph model; pure playback core computing element state at time *t* |
| MCP | JSON-RPC 2.0 over Streamable HTTP; tool schemas; OAuth/PKCE where applicable |
| External model API | Provider-agnostic adapter; user-configured base URL, key, model, headers |

## Sync model

- Offline-first delta sync with `updated_at`, `deleted_at`, `sync_status`
  columns on every syncable row.
- CRDTs for collaborative text; last-writer-wins for simple fields;
  field-level merge for non-conflicting fields.
- Server-authoritative RPC only for strict-consistency operations.
- Sync is resumable and cancellable; conflicts must never lose data
  (losing branches are preserved as copies).

## Rules

- All heavy work runs off the UI thread.
- Sync and export are resumable and cancellable.
- Every engine exposes a stable interface and unit tests.
- A format-neutral node tree is the source for documents, slides, and
  sheets, so export never depends on UI widgets.
- Presentation editor preview, presenter mode, and export all call the
  same pure playback core: `stateAt(slideId, timeMs) -> RenderState`.

## Slice-1 deviation (documented decision)

The first vertical slice implements the document model in pure Dart
(`packages/doc_engine`, no Flutter imports) behind a stable interface.
Rationale: it validates the model, persistence, and export contracts with
`dart test` before the Rust bridge exists. The Rust extraction in Phase 2
must keep the same JSON serialization byte-for-byte (golden tests enforce
this). No behaviour may be defined only in the Flutter layer.
