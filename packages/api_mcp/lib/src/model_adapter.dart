import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'redaction.dart';
import 'secret_store.dart';

/// One chat message for the external model API.
class ChatMessage {
  const ChatMessage({required this.role, required this.content});

  /// Conventional roles: 'system', 'user', 'assistant'.
  final String role;
  final String content;

  Map<String, Object?> toJson() => <String, Object?>{
        'role': role,
        'content': content,
      };
}

/// User-configured connection settings for an external model API.
///
/// The API key itself is NOT held here: [apiKeySecretId] names an entry
/// in a [SecretStore], resolved at call time, so configuration objects
/// (and their `toString`) can never leak the key.
class ExternalModelConfig {
  const ExternalModelConfig({
    required this.baseUrl,
    required this.model,
    this.apiKeySecretId = 'external_model_api_key',
    this.extraHeaders = const <String, String>{},
    this.timeout = const Duration(seconds: 30),
    this.maxRetries = 2,
    this.retryBaseDelay = const Duration(milliseconds: 200),
  });

  /// Base URL of the API provider, e.g. `https://api.example.invalid/v1`
  /// or a local endpoint. Requests go to `<baseUrl>/chat/completions`.
  final Uri baseUrl;

  /// Model identifier, as named by the user's provider account.
  final String model;

  /// Name of the API key entry in the [SecretStore].
  final String apiKeySecretId;

  /// Extra headers sent with every request (never logged).
  final Map<String, String> extraHeaders;

  /// Per-attempt timeout for connect, response, and body read.
  final Duration timeout;

  /// Retries after the first attempt for retryable failures
  /// (rate limit, server error, network error, timeout) in [complete].
  final int maxRetries;

  /// Base for exponential backoff between retries.
  final Duration retryBaseDelay;

  @override
  String toString() => 'ExternalModelConfig(baseUrl: $baseUrl, '
      'model: $model, apiKeySecretId: $apiKeySecretId, '
      'timeout: $timeout, maxRetries: $maxRetries)';
}

/// Base class for all external-model failures.
///
/// Messages are built only from status codes and fixed text — never from
/// request/response bodies — so an exception can never carry a prompt or
/// a key. Servers sometimes echo input in error bodies; those bodies are
/// deliberately discarded.
abstract class ModelApiException implements Exception {
  ModelApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => '$runtimeType(statusCode: $statusCode): $message';
}

/// 401/403 — missing, invalid, or unauthorized API key.
class ModelAuthException extends ModelApiException {
  ModelAuthException({super.statusCode})
      : super('Authentication with the API provider failed. '
            'Check the configured API key.');
}

/// 429 — rate limited by the provider.
class ModelRateLimitException extends ModelApiException {
  ModelRateLimitException({super.statusCode, this.retryAfter})
      : super('The API provider rate limit was reached.');

  final Duration? retryAfter;
}

/// The request exceeded the configured timeout.
class ModelTimeoutException extends ModelApiException {
  ModelTimeoutException()
      : super('The request to the API provider timed out.');
}

/// 5xx — the provider failed to answer correctly.
class ModelServerException extends ModelApiException {
  ModelServerException({super.statusCode})
      : super('The API provider returned a server error.');
}

/// Other 4xx — the request itself was rejected.
class ModelClientException extends ModelApiException {
  ModelClientException({super.statusCode})
      : super('The API provider rejected the request.');
}

/// Socket-level failure (DNS, connection refused, reset).
class ModelNetworkException extends ModelApiException {
  ModelNetworkException()
      : super('Could not reach the API provider (network error).');
}

/// A 2xx response whose body did not match the expected shape.
class ModelMalformedException extends ModelApiException {
  ModelMalformedException()
      : super('The API provider returned a response in an '
            'unexpected format.');
}

/// Provider-agnostic adapter for a chat-completions-shaped HTTP API.
///
/// - `POST <baseUrl>/chat/completions` with
///   `{model, messages: [{role, content}], stream}`.
/// - Non-streaming replies are read from `choices[0].message.content`;
///   streaming replies are `data:` lines whose JSON carries
///   `choices[0].delta.content` (a trailing `data: [DONE]` ends them).
/// - No provider or vendor is named anywhere; the endpoint, key, and
///   model are entirely user-configured.
class ExternalModelAdapter {
  ExternalModelAdapter({
    required this.config,
    required SecretStore secretStore,
    void Function(String line)? logSink,
    Future<void> Function(Duration delay)? sleeper,
  })  : _secretStore = secretStore,
        _logSink = logSink,
        _sleeper = sleeper ?? Future.delayed;

  final ExternalModelConfig config;
  final SecretStore _secretStore;
  final void Function(String line)? _logSink;
  final Future<void> Function(Duration delay) _sleeper;

  HttpClient? _httpClient;

  /// Redactor seeded with header values; the API key and message
  /// contents are registered per call before any logging happens.
  final Redactor _redactor = Redactor();

  HttpClient _client() => _httpClient ??= HttpClient();

  Uri get _endpoint {
    var root = config.baseUrl;
    if (!root.path.endsWith('/')) {
      root = root.replace(path: '${root.path}/');
    }
    return root.resolve('chat/completions');
  }

  Future<String?> _resolveApiKey() async {
    final key = await _secretStore.read(config.apiKeySecretId);
    if (key != null && key.isNotEmpty) _redactor.registerSensitive(key);
    return key;
  }

  void _log(String line) {
    final sink = _logSink;
    if (sink != null) sink(_redactor.redact(line));
  }

  Map<String, Object?> _body(List<ChatMessage> messages, {required bool stream}) =>
      <String, Object?>{
        'model': config.model,
        'messages': messages.map((m) => m.toJson()).toList(),
        'stream': stream,
      };

  Future<HttpClientRequest> _openRequest(String? apiKey) async {
    final request = await _client().postUrl(_endpoint);
    request.headers.contentType = ContentType.json;
    config.extraHeaders.forEach((name, value) {
      _redactor.registerSensitive(value);
      request.headers.set(name, value);
    });
    if (apiKey != null && apiKey.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
    return request;
  }

  ModelApiException _exceptionForStatus(int statusCode, {Duration? retryAfter}) {
    if (statusCode == 401 || statusCode == 403) {
      return ModelAuthException(statusCode: statusCode);
    }
    if (statusCode == 429) {
      return ModelRateLimitException(
          statusCode: statusCode, retryAfter: retryAfter);
    }
    if (statusCode >= 500) return ModelServerException(statusCode: statusCode);
    return ModelClientException(statusCode: statusCode);
  }

  static bool _isRetryable(ModelApiException e) =>
      e is ModelRateLimitException ||
      e is ModelServerException ||
      e is ModelNetworkException ||
      e is ModelTimeoutException;

  static Duration? _parseRetryAfter(HttpHeaders headers) {
    final raw = headers.value(HttpHeaders.retryAfterHeader);
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    return seconds == null ? null : Duration(seconds: seconds);
  }

  /// Sends [messages] and returns the reply text.
  ///
  /// Retries retryable failures up to [ExternalModelConfig.maxRetries]
  /// with exponential backoff, then throws the final typed error.
  Future<String> complete(List<ChatMessage> messages) async {
    final apiKey = await _resolveApiKey();
    for (final m in messages) {
      _redactor.registerSensitive(m.content);
    }
    var attempt = 0;
    while (true) {
      try {
        final text = await _completeOnce(messages, apiKey);
        _log('External model request completed '
            '(model: ${config.model}, messages: ${messages.length}, '
            'attempt: ${attempt + 1})');
        return text;
      } on ModelApiException catch (e) {
        _log('External model request failed '
            '(type: ${e.runtimeType}, status: ${e.statusCode}, '
            'attempt: ${attempt + 1})');
        if (!_isRetryable(e) || attempt >= config.maxRetries) rethrow;
        final backoff = e is ModelRateLimitException && e.retryAfter != null
            ? e.retryAfter!
            : config.retryBaseDelay * (1 << attempt);
        attempt++;
        await _sleeper(backoff);
      }
    }
  }

  Future<String> _completeOnce(
      List<ChatMessage> messages, String? apiKey) async {
    try {
      final request = await _openRequest(apiKey).timeout(config.timeout);
      request.write(jsonEncode(_body(messages, stream: false)));
      final response = await request.close().timeout(config.timeout);
      final body =
          await response.transform(utf8.decoder).join().timeout(config.timeout);
      if (response.statusCode != 200) {
        throw _exceptionForStatus(response.statusCode,
            retryAfter: _parseRetryAfter(response.headers));
      }
      return _parseCompletion(body);
    } on ModelApiException {
      rethrow;
    } on TimeoutException {
      throw ModelTimeoutException();
    } on SocketException {
      throw ModelNetworkException();
    } on HttpException {
      throw ModelNetworkException();
    }
  }

  static String _parseCompletion(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw ModelMalformedException();
    }
    if (decoded is! Map) throw ModelMalformedException();
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) {
      throw ModelMalformedException();
    }
    final first = choices.first;
    if (first is! Map) throw ModelMalformedException();
    final message = first['message'];
    if (message is! Map) throw ModelMalformedException();
    final content = message['content'];
    if (content is! String) throw ModelMalformedException();
    return content;
  }

  /// Streams reply text chunks for [messages].
  ///
  /// Streaming requests are not retried: once a chunk may have been
  /// emitted, replaying the request could duplicate output. A failure
  /// before the first chunk surfaces as the same typed errors as
  /// [complete].
  Stream<String> stream(List<ChatMessage> messages) async* {
    final apiKey = await _resolveApiKey();
    for (final m in messages) {
      _redactor.registerSensitive(m.content);
    }
    try {
      final request = await _openRequest(apiKey).timeout(config.timeout);
      request.write(jsonEncode(_body(messages, stream: true)));
      final response = await request.close().timeout(config.timeout);
      if (response.statusCode != 200) {
        try {
          await response.drain<void>();
        } catch (_) {
          // Discarding an error body must never mask the typed error.
        }
        throw _exceptionForStatus(response.statusCode,
            retryAfter: _parseRetryAfter(response.headers));
      }
      final lines = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(config.timeout);
      await for (final line in lines) {
        final chunk = _parseStreamLine(line);
        if (chunk == _doneSentinel) return;
        if (chunk != null && chunk.isNotEmpty) yield chunk;
      }
    } on ModelApiException {
      rethrow;
    } on TimeoutException {
      throw ModelTimeoutException();
    } on SocketException {
      throw ModelNetworkException();
    } on HttpException {
      throw ModelNetworkException();
    }
  }

  static const String _doneSentinel = '\u0000DONE';

  /// Returns the content chunk in one SSE `data:` line, [_doneSentinel]
  /// for `data: [DONE]`, or null for lines carrying no content.
  static String? _parseStreamLine(String line) {
    final trimmed = line.trim();
    if (!trimmed.startsWith('data:')) return null;
    final data = trimmed.substring('data:'.length).trim();
    if (data == '[DONE]') return _doneSentinel;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      throw ModelMalformedException();
    }
    if (decoded is! Map) throw ModelMalformedException();
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map) return null;
    final delta = first['delta'];
    if (delta is Map && delta['content'] is String) {
      return delta['content'] as String;
    }
    final message = first['message'];
    if (message is Map && message['content'] is String) {
      return message['content'] as String;
    }
    return null;
  }

  /// Releases the underlying HTTP client.
  void close() {
    _httpClient?.close(force: true);
    _httpClient = null;
  }
}
