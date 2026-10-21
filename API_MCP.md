# API and MCP

## External model API adapter

- Provider-agnostic: base URL, API key, model, extra headers, timeout,
  retry with backoff — all user-configured.
- Capabilities: `complete`, `stream`, `embeddings`, image input if the
  configured endpoint supports it.
- Secrets live in platform secure storage only. Logs redact prompts by
  default and never contain keys.
- UI label is neutral: "External model" / "API provider". No vendor names
  in UI, strings, metadata, docs, or code comments.

## MCP client

- Connects to external MCP servers; discovers tools; calls tools only
  with per-server user consent.
- Transport: JSON-RPC 2.0 over Streamable HTTP; auth via OAuth/PKCE or
  bearer token (token in secure storage).

## MCP server (local)

- Exposed only after explicit user opt-in, on an interface the user
  chooses, with a per-session token.
- Initial safe tool set:

  | Tool | Effect | Default permission |
  |---|---|---|
  | `doc.read` | Read a document's node tree | Ask once per session |
  | `doc.apply_edit` | Apply document-engine operations | Ask every call |
  | `sheet.read_range` | Read a cell range | Ask once per session |
  | `sheet.write_range` | Write a cell range | Ask every call |
  | `presentation.render_state` | `stateAt(slideId, timeMs)` | Ask once per session |
  | `export.create` | Run an export to a user-visible file | Ask every call |
  | `pdf.annotate` | Add an annotation | Ask every call |

- Every tool call is permissioned, auditable (append-only audit log),
  and cancellable. External agents can never bypass user consent or
  data boundaries; a denied call returns a JSON-RPC error, not data.
