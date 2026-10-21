import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'mcp_server.dart' show sessionIdHeader, sessionTokenHeader;

/// A tool discovered from an MCP server via `tools/list`.
class McpTool {
  const McpTool({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;

  factory McpTool.fromJson(Map<String, Object?> json) {
    final schema = json['inputSchema'];
    return McpTool(
      name: json['name'] as String? ?? '',
      description: json['description'] as String? ?? '',
      inputSchema: schema is Map
          ? schema.cast<String, Object?>()
          : <String, Object?>{},
    );
  }

  @override
  String toString() => 'McpTool($name)';
}

/// One content item in a tool-call result.
class McpContent {
  const McpContent({required this.type, required this.text});

  final String type;
  final String text;

  factory McpContent.fromJson(Map<String, Object?> json) => McpContent(
        type: json['type'] as String? ?? '',
        text: json['text'] as String? ?? '',
      );
}

/// Result of a successful `tools/call`.
class McpCallResult {
  const McpCallResult({required this.content, required this.isError});

  final List<McpContent> content;
  final bool isError;

  /// All text content items concatenated, in order.
  String get text => content.map((c) => c.text).join();

  factory McpCallResult.fromJson(Map<String, Object?> json) {
    final raw = json['content'];
    return McpCallResult(
      content: raw is List
          ? raw
              .whereType<Map>()
              .map((e) => McpContent.fromJson(e.cast<String, Object?>()))
              .toList()
          : const <McpContent>[],
      isError: json['isError'] as bool? ?? false,
    );
  }
}

/// A JSON-RPC error returned by the server (including permission
/// denials and authentication failures). Carries only the server's
/// code and message — never a token.
class McpException implements Exception {
  const McpException(this.code, this.message);

  final int code;
  final String message;

  @override
  String toString() => 'McpException($code): $message';
}

/// The client request exceeded its timeout.
class McpTimeoutException implements Exception {
  const McpTimeoutException();

  @override
  String toString() => 'McpTimeoutException: request timed out';
}

/// MCP client: connects to an MCP server over HTTP, discovers its tools
/// (`initialize` + `tools/list`), and calls them (`tools/call`) with the
/// session token. Calls are only ever made when the caller explicitly
/// invokes [callTool] — discovery alone never touches document data, and
/// the server's consent gate still decides every call.
class McpClient {
  McpClient({
    required this.baseUrl,
    required String sessionToken,
    this.sessionId = 'session-1',
    this.timeout = const Duration(seconds: 30),
  }) : _sessionToken = sessionToken;

  /// Base URL of the MCP server (single POST endpoint).
  final Uri baseUrl;

  /// Opaque session identifier sent for ask-once permission caching.
  final String sessionId;

  final Duration timeout;
  final String _sessionToken;

  HttpClient? _httpClient;
  int _nextId = 0;

  HttpClient _client() => _httpClient ??= HttpClient();

  /// Performs the MCP `initialize` handshake and returns the server's
  /// result payload (protocol version, capabilities, server info).
  Future<Map<String, Object?>> initialize() async {
    final result = await _rpc('initialize', <String, Object?>{
      'protocolVersion': '2025-03-26',
      'capabilities': <String, Object?>{},
      'clientInfo': <String, Object?>{
        'name': 'workspace-mcp-client',
        'version': '0.1.0',
      },
    });
    return result;
  }

  /// Discovers the server's tools via `tools/list`.
  Future<List<McpTool>> listTools() async {
    final result = await _rpc('tools/list', <String, Object?>{});
    final raw = result['tools'];
    if (raw is! List) return const <McpTool>[];
    return raw
        .whereType<Map>()
        .map((e) => McpTool.fromJson(e.cast<String, Object?>()))
        .toList();
  }

  /// Calls one tool. A server-side error (including a permission
  /// denial) throws [McpException]; inspect [McpException.code].
  Future<McpCallResult> callTool(
      String name, Map<String, Object?> arguments) async {
    final result = await _rpc('tools/call', <String, Object?>{
      'name': name,
      'arguments': arguments,
    });
    return McpCallResult.fromJson(result);
  }

  Future<Map<String, Object?>> _rpc(
      String method, Map<String, Object?> params) async {
    final id = ++_nextId;
    final payload = <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };
    try {
      final request = await _client().postUrl(baseUrl).timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(sessionTokenHeader, _sessionToken);
      request.headers.set(sessionIdHeader, sessionId);
      request.write(jsonEncode(payload));
      final response = await request.close().timeout(timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(timeout);
      final Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        throw const McpException(-32700, 'Unparseable response from server');
      }
      if (decoded is! Map) {
        throw const McpException(-32600, 'Malformed response from server');
      }
      final envelope = decoded.cast<String, Object?>();
      final error = envelope['error'];
      if (error is Map) {
        final errMap = error.cast<String, Object?>();
        throw McpException(
          errMap['code'] as int? ?? -32603,
          errMap['message'] as String? ?? 'Unknown server error',
        );
      }
      final result = envelope['result'];
      if (result is Map) return result.cast<String, Object?>();
      return <String, Object?>{};
    } on McpException {
      rethrow;
    } on TimeoutException {
      throw const McpTimeoutException();
    } on SocketException {
      throw const McpException(-32000, 'Could not reach the MCP server');
    }
  }

  /// Releases the underlying HTTP client.
  void close() {
    _httpClient?.close(force: true);
    _httpClient = null;
  }

  /// Deliberately excludes the session token.
  @override
  String toString() => 'McpClient(baseUrl: $baseUrl, sessionId: $sessionId)';
}
