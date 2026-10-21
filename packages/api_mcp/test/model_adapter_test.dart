import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:api_mcp/api_mcp.dart';
import 'package:test/test.dart';

const String testKey = 'test-key-abc-123';
const String testPrompt = 'PROMPT-CONTENT-MUST-NOT-LEAK';

void main() {
  late HttpServer server;
  late Uri baseUrl;
  late InMemorySecretStore secrets;
  late List<String> capturedBodies;
  late List<String?> capturedAuth;

  /// Per-test responder: given the request and its decoded body, write a
  /// response. Defaults to a well-formed completion.
  late Future<void> Function(HttpRequest request, String body) responder;

  Future<void> defaultResponder(HttpRequest request, String body) async {
    request.response.statusCode = 200;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'message': <String, Object?>{'role': 'assistant', 'content': 'mock reply'},
        },
      ],
    }));
    await request.response.close();
  }

  setUp(() async {
    capturedBodies = <String>[];
    capturedAuth = <String?>[];
    responder = defaultResponder;
    secrets = InMemorySecretStore();
    await secrets.write('external_model_api_key', testKey);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    baseUrl = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      try {
        final body = await utf8.decoder.bind(request).join();
        capturedBodies.add(body);
        capturedAuth.add(request.headers.value(HttpHeaders.authorizationHeader));
        await responder(request, body);
      } catch (_) {
        // The client may have timed out and gone away; a mock write
        // failure must not fail the test run.
        try {
          request.response.statusCode = 500;
          await request.response.close();
        } catch (_) {}
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  ExternalModelAdapter makeAdapter({
    Duration timeout = const Duration(seconds: 5),
    int maxRetries = 0,
    void Function(String line)? logSink,
  }) {
    return ExternalModelAdapter(
      config: ExternalModelConfig(
        baseUrl: baseUrl,
        model: 'test-model',
        timeout: timeout,
        maxRetries: maxRetries,
        retryBaseDelay: const Duration(milliseconds: 1),
      ),
      secretStore: secrets,
      logSink: logSink,
      sleeper: (_) async {},
    );
  }

  const messages = <ChatMessage>[
    ChatMessage(role: 'user', content: testPrompt),
  ];

  test('complete returns reply text and sends key from the secret store',
      () async {
    final adapter = makeAdapter();
    addTearDown(adapter.close);
    expect(await adapter.complete(messages), 'mock reply');
    expect(capturedAuth.single, 'Bearer $testKey');
    final sent = jsonDecode(capturedBodies.single) as Map;
    expect(sent['model'], 'test-model');
    expect(sent['stream'], isFalse);
    expect((sent['messages'] as List).single['content'], testPrompt);
  });

  test('stream yields delta chunks until [DONE]', () async {
    responder = (request, body) async {
      request.response.statusCode = 200;
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      request.response.writeln(
          'data: ${jsonEncode({'choices': [{'delta': {'content': 'Hel'}}]})}');
      request.response.writeln(
          'data: ${jsonEncode({'choices': [{'delta': {'content': 'lo'}}]})}');
      request.response.writeln('data: [DONE]');
      await request.response.close();
    };
    final adapter = makeAdapter();
    addTearDown(adapter.close);
    final chunks = await adapter.stream(messages).toList();
    expect(chunks, <String>['Hel', 'lo']);
    expect(chunks.join(), 'Hello');
    expect((jsonDecode(capturedBodies.single) as Map)['stream'], isTrue);
  });

  test('401 maps to ModelAuthException', () async {
    responder = (request, body) async {
      request.response.statusCode = 401;
      await request.response.close();
    };
    final adapter = makeAdapter();
    addTearDown(adapter.close);
    await expectLater(
        adapter.complete(messages), throwsA(isA<ModelAuthException>()));
  });

  test('429 maps to ModelRateLimitException with retry-after', () async {
    responder = (request, body) async {
      request.response.statusCode = 429;
      request.response.headers
          .set(HttpHeaders.retryAfterHeader, '3');
      await request.response.close();
    };
    final adapter = makeAdapter();
    addTearDown(adapter.close);
    await expectLater(
      adapter.complete(messages),
      throwsA(isA<ModelRateLimitException>()
          .having((e) => e.retryAfter, 'retryAfter',
              const Duration(seconds: 3))
          .having((e) => e.statusCode, 'statusCode', 429)),
    );
  });

  test('500 maps to ModelServerException', () async {
    responder = (request, body) async {
      request.response.statusCode = 500;
      await request.response.close();
    };
    final adapter = makeAdapter();
    addTearDown(adapter.close);
    await expectLater(
        adapter.complete(messages), throwsA(isA<ModelServerException>()));
  });

  test('a well-formed status with a wrong-shaped body is malformed',
      () async {
    responder = (request, body) async {
      request.response.statusCode = 200;
      request.response.write('{"unexpected": true}');
      await request.response.close();
    };
    final adapter = makeAdapter();
    addTearDown(adapter.close);
    await expectLater(adapter.complete(messages),
        throwsA(isA<ModelMalformedException>()));
  });

  test('a non-JSON body is malformed', () async {
    responder = (request, body) async {
      request.response.statusCode = 200;
      request.response.write('not json at all');
      await request.response.close();
    };
    final adapter = makeAdapter();
    addTearDown(adapter.close);
    await expectLater(adapter.complete(messages),
        throwsA(isA<ModelMalformedException>()));
  });

  test('slow server maps to ModelTimeoutException', () async {
    responder = (request, body) async {
      await Future<void>.delayed(const Duration(milliseconds: 700));
      request.response.statusCode = 200;
      await request.response.close();
    };
    final adapter = makeAdapter(timeout: const Duration(milliseconds: 120));
    addTearDown(adapter.close);
    await expectLater(adapter.complete(messages),
        throwsA(isA<ModelTimeoutException>()));
  });

  test('retryable failure is retried and can succeed', () async {
    var attempts = 0;
    responder = (request, body) async {
      attempts++;
      if (attempts == 1) {
        request.response.statusCode = 500;
        await request.response.close();
        return;
      }
      await defaultResponder(request, body);
    };
    final adapter = makeAdapter(maxRetries: 2);
    addTearDown(adapter.close);
    expect(await adapter.complete(messages), 'mock reply');
    expect(attempts, 2);
  });

  test('secrets and prompts never reach logs, errors, or toString',
      () async {
    final logLines = <String>[];
    // Error path: the provider echoes key and prompt in its error body —
    // neither the exception nor the log may contain them.
    responder = (request, body) async {
      request.response.statusCode = 401;
      request.response.write('echo: $testKey / $testPrompt');
      await request.response.close();
    };
    final adapter = makeAdapter(logSink: logLines.add);
    addTearDown(adapter.close);

    Object? caught;
    try {
      await adapter.complete(messages);
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<ModelAuthException>());
    expect(caught.toString(), isNot(contains(testKey)));
    expect(caught.toString(), isNot(contains(testPrompt)));

    // Success path also logs — and also stays clean.
    responder = defaultResponder;
    expect(await adapter.complete(messages), 'mock reply');
    expect(logLines, isNotEmpty);
    for (final line in logLines) {
      expect(line, isNot(contains(testKey)), reason: line);
      expect(line, isNot(contains(testPrompt)), reason: line);
    }

    expect(adapter.config.toString(), isNot(contains(testKey)));
    expect(secrets.toString(), isNot(contains(testKey)));
  });
}
