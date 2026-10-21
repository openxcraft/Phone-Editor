# Security and Performance

## Data protection

- Sensitive documents encrypted at rest; end-to-end encryption available
  for selected vaults.
- Ciphers: AES-256-GCM or ChaCha20-Poly1305; keys hardware-bound where
  the platform supports it.
- API keys and MCP tokens only in platform secure storage; never in the
  database, files, logs, or crash reports.
- Logs redact prompts and document content by default.

## MCP safety

- Local MCP server is off by default and requires explicit opt-in.
- Every tool is permissioned (see API_MCP.md); every call is written to
  an append-only audit log with timestamp, tool, target id, and outcome.
- Tool calls are cancellable; a cancelled call must leave data unchanged
  or roll back.

## Performance budgets

- Sync and export run in background isolates/threads; both are
  cancellable and resumable.
- Memory ceilings for large sheets/PDFs; virtualized rendering for grids,
  page lists, and long documents — never materialize a whole large file
  in the UI layer.
- Editor input latency target: < 16 ms per keystroke on a mid-range
  device; document-engine operations on Slice-1-sized documents
  (< 10k blocks) must complete in < 5 ms (asserted in tests with a
  generous CI bound).
