/// Consent model for MCP tool calls (see API_MCP.md at the repo root).
///
/// Read tools ask once per session; write tools ask every call. A denied
/// call must return an error and change nothing — enforcement lives in
/// the MCP server; this file defines the policy contract and reusable
/// implementations.
library;

/// How often consent must be asked for a tool.
enum PermissionFrequency {
  /// Ask once; a grant is remembered for the rest of the session.
  askOncePerSession,

  /// Ask again on every single call. Grants are never remembered.
  askEveryCall,
}

/// One consent check, as presented to a [PermissionPolicy].
class PermissionRequest {
  const PermissionRequest({
    required this.sessionId,
    required this.tool,
    required this.frequency,
    this.targetId,
  });

  /// Opaque session identifier (never a token value).
  final String sessionId;

  /// Tool name, e.g. `doc.read`.
  final String tool;

  /// Document (or other object) the call targets, when known.
  final String? targetId;

  final PermissionFrequency frequency;

  @override
  String toString() => 'PermissionRequest(tool: $tool, '
      'targetId: $targetId, frequency: ${frequency.name})';
}

/// Decides whether a tool call may proceed.
abstract class PermissionPolicy {
  Future<bool> isAllowed(PermissionRequest request);
}

/// Always allows or always denies — for tests and locked-down setups.
class StaticPermissionPolicy implements PermissionPolicy {
  const StaticPermissionPolicy(this.allow);

  final bool allow;

  @override
  Future<bool> isAllowed(PermissionRequest request) async => allow;
}

/// Delegates each question to a callback (a UI prompt in the app) and
/// implements the ask-once rule: a *grant* for an
/// [PermissionFrequency.askOncePerSession] tool is cached per
/// (session, tool); denials are not cached, so a later call asks again;
/// [PermissionFrequency.askEveryCall] tools always reach the callback.
class CallbackPermissionPolicy implements PermissionPolicy {
  CallbackPermissionPolicy(this._ask);

  final Future<bool> Function(PermissionRequest request) _ask;
  final Set<String> _sessionGrants = <String>{};

  @override
  Future<bool> isAllowed(PermissionRequest request) async {
    final cacheKey = '${request.sessionId}::${request.tool}';
    if (request.frequency == PermissionFrequency.askOncePerSession &&
        _sessionGrants.contains(cacheKey)) {
      return true;
    }
    final granted = await _ask(request);
    if (granted &&
        request.frequency == PermissionFrequency.askOncePerSession) {
      _sessionGrants.add(cacheKey);
    }
    return granted;
  }
}
