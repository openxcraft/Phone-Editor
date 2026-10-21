/// Provider-agnostic external model adapter and MCP client/server.
///
/// Labels are neutral by design: "External model" / "API provider".
/// No vendor names appear in this package. Secrets live behind
/// [SecretStore] and are never written to logs, errors, or `toString`.
library;

export 'src/audit_log.dart';
export 'src/mcp_client.dart';
export 'src/mcp_server.dart';
export 'src/model_adapter.dart';
export 'src/permissions.dart';
export 'src/redaction.dart';
export 'src/secret_store.dart';
