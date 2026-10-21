/// Append-only audit trail for MCP tool calls (see API_MCP.md).
///
/// Every `tools/call` that reaches the permission gate appends exactly
/// one entry: whether it was allowed and ran, denied by policy, or
/// failed with an error. Entries carry no document content and no
/// secrets — tool name, target id, outcome, and a caller-supplied
/// timestamp only.
library;

/// Outcome of one audited tool call.
enum AuditOutcome { allowed, denied, error }

/// One immutable audit entry.
class AuditEntry {
  const AuditEntry({
    required this.timestampMs,
    required this.tool,
    required this.outcome,
    this.targetId,
  });

  /// Epoch milliseconds, supplied by the server's injected clock.
  final int timestampMs;

  /// Tool name, e.g. `doc.read`.
  final String tool;

  /// Document (or other object) the call targeted, when known.
  final String? targetId;

  final AuditOutcome outcome;

  Map<String, Object?> toJson() => <String, Object?>{
        'timestamp_ms': timestampMs,
        'tool': tool,
        'target_id': targetId,
        'outcome': outcome.name,
      };

  @override
  String toString() => 'AuditEntry($timestampMs, $tool, '
      'target: $targetId, ${outcome.name})';
}

/// In-memory, append-only [AuditEntry] collection.
class AuditLog {
  final List<AuditEntry> _entries = <AuditEntry>[];

  /// All entries in append order. The returned list is unmodifiable:
  /// audit history cannot be rewritten through this API.
  List<AuditEntry> get entries => List<AuditEntry>.unmodifiable(_entries);

  void append(AuditEntry entry) => _entries.add(entry);

  /// Convenience for the common case.
  void record({
    required int timestampMs,
    required String tool,
    required AuditOutcome outcome,
    String? targetId,
  }) {
    append(AuditEntry(
      timestampMs: timestampMs,
      tool: tool,
      outcome: outcome,
      targetId: targetId,
    ));
  }
}
