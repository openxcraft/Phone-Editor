import 'dart:convert';

import 'package:api_mcp/api_mcp.dart';
import 'package:doc_engine/doc_engine.dart';
import 'package:test/test.dart';

const String sessionToken = 'session-token-for-tests';

/// Consent gate used by the tests: counts how often each tool asked and
/// lets a test flip write permission on/off.
class Gate {
  bool allowWrites = true;
  final Map<String, int> askCounts = <String, int>{};

  Future<bool> ask(PermissionRequest request) async {
    askCounts[request.tool] = (askCounts[request.tool] ?? 0) + 1;
    if (request.tool == 'doc.read' || request.tool == 'export.create') {
      return true;
    }
    return allowWrites;
  }
}

void main() {
  late InMemoryDocumentStore store;
  late Document doc;
  late String blockId;
  late Gate gate;
  late AuditLog audit;
  late McpServer server;
  late McpClient client;
  var tick = 0;

  int clock() => ++tick * 1000;

  setUp(() async {
    tick = 0;
    store = InMemoryDocumentStore();
    final editor = DocumentEditor.newDocument(
      ids: SequentialIdGenerator(),
      title: 'Spec',
      nowMs: 100,
    );
    blockId = editor.document.allBlocks.first.id;
    editor.insertText(blockId, 0, 'Hello world');
    doc = editor.document;
    await store.save(doc);

    gate = Gate();
    audit = AuditLog();
    server = McpServer(
      store: store,
      permissions: CallbackPermissionPolicy(gate.ask),
      auditLog: audit,
      sessionToken: sessionToken,
      clockMs: clock,
    );
    await server.start(); // loopback, ephemeral port
    client = McpClient(baseUrl: server.baseUri, sessionToken: sessionToken);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  test('server binds only on explicit start (opt-in)', () async {
    final unstarted = McpServer(
      store: store,
      permissions: const StaticPermissionPolicy(true),
      auditLog: AuditLog(),
      sessionToken: sessionToken,
      clockMs: clock,
    );
    expect(unstarted.isStarted, isFalse);
    expect(server.isStarted, isTrue);
  });

  test('discovery: initialize handshake and tools/list', () async {
    final info = await client.initialize();
    expect(info['protocolVersion'], '2025-03-26');
    expect((info['serverInfo'] as Map)['name'], 'workspace-mcp-server');

    final tools = await client.listTools();
    expect(
      tools.map((t) => t.name).toList(),
      <String>['doc.read', 'doc.apply_edit', 'export.create'],
    );
    expect(tools.first.inputSchema['type'], 'object');
  });

  test('allowed doc.read returns the document; read asks once per session',
      () async {
    final first = await client.callTool('doc.read', {'documentId': doc.id});
    expect(first.isError, isFalse);
    final parsed = jsonDecode(first.text) as Map;
    expect(parsed['id'], doc.id);
    expect(parsed['title'], 'Spec');

    final second = await client.callTool('doc.read', {'documentId': doc.id});
    expect(second.isError, isFalse);
    expect(gate.askCounts['doc.read'], 1); // asked once, grant cached

    final readEntries =
        audit.entries.where((e) => e.tool == 'doc.read').toList();
    expect(readEntries, hasLength(2));
    expect(readEntries.every((e) => e.outcome == AuditOutcome.allowed),
        isTrue);
    expect(readEntries.every((e) => e.targetId == doc.id), isTrue);
  });

  test('denied doc.apply_edit errors, changes nothing, and is audited',
      () async {
    gate.allowWrites = false;
    await expectLater(
      client.callTool('doc.apply_edit', {
        'documentId': doc.id,
        'operations': [
          {'type': 'insertText', 'blockId': blockId, 'offset': 0, 'text': 'X'},
        ],
      }),
      throwsA(isA<McpException>()
          .having((e) => e.code, 'code', McpErrorCodes.permissionDenied)),
    );

    final unchanged = await store.load(doc.id);
    expect(unchanged!.allBlocks.first.plainText, 'Hello world');

    final denied = audit.entries
        .where((e) => e.tool == 'doc.apply_edit')
        .toList();
    expect(denied, hasLength(1));
    expect(denied.single.outcome, AuditOutcome.denied);
    expect(denied.single.targetId, doc.id);
  });

  test('allowed doc.apply_edit applies ops and asks on every call',
      () async {
    final result = await client.callTool('doc.apply_edit', {
      'documentId': doc.id,
      'operations': [
        {'type': 'insertText', 'blockId': blockId, 'offset': 5, 'text': ','},
        {'type': 'deleteRange', 'blockId': blockId, 'start': 0, 'end': 1},
      ],
    });
    expect(result.isError, isFalse);
    final summary = jsonDecode(result.text) as Map;
    expect(summary['appliedOperations'], 2);

    final updated = await store.load(doc.id);
    expect(updated!.allBlocks.first.plainText, 'ello, world');

    await client.callTool('doc.apply_edit', {
      'documentId': doc.id,
      'operations': [
        {'type': 'insertText', 'blockId': blockId, 'offset': 0, 'text': 'H'},
      ],
    });
    expect(gate.askCounts['doc.apply_edit'], 2); // asked again
    final restored = await store.load(doc.id);
    expect(restored!.allBlocks.first.plainText, 'Hello, world');
  });

  test('export.create returns Markdown content and asks every call',
      () async {
    final result = await client.callTool('export.create', {
      'documentId': doc.id,
      'format': 'markdown',
    });
    expect(result.isError, isFalse);
    expect(result.text, '# Spec\n\nHello world\n');

    await client.callTool('export.create', {'documentId': doc.id});
    expect(gate.askCounts['export.create'], 2);
  });

  test('export.create rejects unsupported formats', () async {
    await expectLater(
      client.callTool('export.create', {
        'documentId': doc.id,
        'format': 'pdf',
      }),
      throwsA(isA<McpException>()
          .having((e) => e.code, 'code', McpErrorCodes.unsupportedFormat)),
    );
  });

  test('doc.read of a missing document is a clean error, audited as error',
      () async {
    await expectLater(
      client.callTool('doc.read', {'documentId': 'no-such-doc'}),
      throwsA(isA<McpException>()
          .having((e) => e.code, 'code', McpErrorCodes.documentNotFound)),
    );
    final entry = audit.entries.last;
    expect(entry.tool, 'doc.read');
    expect(entry.outcome, AuditOutcome.error);
    expect(entry.targetId, 'no-such-doc');
  });

  test('wrong session token is rejected and never reaches the audit log',
      () async {
    final badClient =
        McpClient(baseUrl: server.baseUri, sessionToken: 'not-the-token');
    addTearDown(badClient.close);
    await expectLater(
      badClient.initialize(),
      throwsA(isA<McpException>()
          .having((e) => e.code, 'code', McpErrorCodes.unauthorized)),
    );
    expect(audit.entries, isEmpty);
    expect(badClient.toString(), isNot(contains('not-the-token')));
  });

  test('audit log records allowed and denied calls in order, with the '
      'injected clock', () async {
    await client.callTool('doc.read', {'documentId': doc.id});
    gate.allowWrites = false;
    await expectLater(
      client.callTool('doc.apply_edit', {
        'documentId': doc.id,
        'operations': [
          {'type': 'insertText', 'blockId': blockId, 'offset': 0, 'text': 'X'},
        ],
      }),
      throwsA(isA<McpException>()),
    );

    expect(audit.entries, hasLength(2));
    expect(audit.entries[0].tool, 'doc.read');
    expect(audit.entries[0].outcome, AuditOutcome.allowed);
    expect(audit.entries[0].timestampMs, 1000);
    expect(audit.entries[1].tool, 'doc.apply_edit');
    expect(audit.entries[1].outcome, AuditOutcome.denied);
    expect(audit.entries[1].timestampMs, 2000);
  });
}
