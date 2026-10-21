# Slice 1 — Verification Note

**Goal:** local document model + editor shell + SQLite persistence +
offline save + one export path (Markdown), per PLAN.md Phase 0.

## Files changed

- Context/design: `CONTEXT.md`, `ARCHITECTURE.md`, `ENGINES.md`, `UX.md`,
  `API_MCP.md`, `EXPORT.md`, `SECURITY.md`, `ACCEPTANCE.md`, `PLAN.md`,
  `README.md`
- Engine: `packages/doc_engine/lib/src/{model,editor,store,sqlite_store,markdown_export}.dart`
- Tests: `packages/doc_engine/test/{editor,markdown_export,store}_test.dart`
- Persistence: `db/schema_v1.sql`
- Shell: `app/lib/{main,editor_screen}.dart`, `app/pubspec.yaml`
- Tooling: `tools/verify.sh`

## Commands and results (environment: Dart SDK 3.13.6, sqlite3 CLI)

```
$ tools/verify.sh
== doc_engine: pub get ==        Changed 57 dependencies (sqlite3 3.7.1, test 1.33.0)
== doc_engine: analyze ==        No issues found!
== doc_engine: test ==           +18: All tests passed!
== schema_v1.sql via sqlite3 ==  1   (schema_version)
All Slice-1 checks passed.
```

Test coverage: insert/delete/mark operations incl. rune-based offsets
(emoji), run splitting/merging, block insert/type/delete, undo/redo,
find/replace (case-sensitive and insensitive, no-op creates no undo
step), deterministic JSON round-trip, Markdown golden output, store
contract, and SQLite persistence across close/reopen on a real file.

## Bug found and fixed during verification

First run: 15 passed, 3 failed. Root cause: `deleteRange`/`applyMark`
split the end boundary before the start boundary; the start split then
shifted the end index, emptying the range. Fixed by splitting start
first; regression covered by the rune-offset and mark-splitting tests.

## Blockers and risks

- **Flutter SDK not present** in this build environment: `app/` shell is
  source-complete but compile-unverified. Verify with
  `cd app && flutter analyze && flutter run` on a Flutter machine before
  Phase 1 builds on it.
- **Rust toolchain not present**: the ARCHITECTURE.md Rust engines are
  Phase 2; Slice 1 is pure Dart behind the same interface (documented
  deviation in ARCHITECTURE.md).
- `sqlite3` 3.x renamed `dispose()` → `close()`; code uses `close()`
  (caught by `dart analyze` deprecation infos, fixed).
- `sqlite3_flutter_libs` 0.6.0 is marked end-of-life upstream; Phase 1
  evaluates drift's bundling (noted in `app/pubspec.yaml`).
- Slice-1 simplifications, documented in code: snapshot undo (CRDT in
  Phase 3); find/replace flattens marks inside an affected block;
  shell applies marks block-wide until native selection work in Phase 1.

## Next step

Phase 1: tables/images/comments/track changes on the same node tree,
DOCX + HTML export with round-trip tests, drift layer over schema v1 —
starting with compiling the Flutter shell on a Flutter-equipped machine.
