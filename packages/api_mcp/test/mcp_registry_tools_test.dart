import 'dart:convert';

import 'package:api_mcp/api_mcp.dart';
import 'package:doc_engine/doc_engine.dart';
import 'package:pdf_engine/pdf_engine.dart';
import 'package:presentation_engine/presentation_engine.dart';
import 'package:sheets_engine/sheets_engine.dart';
import 'package:test/test.dart';

const String sessionToken = 'session-token-for-tests';

/// Consent gate: read tools (ask-once) follow [allowReads]; write tools
/// (ask-every-call) follow [allowWrites]. Counts asks per tool.
class Gate {
  bool allowReads = true;
  bool allowWrites = true;
  final Map<String, int> askCounts = <String, int>{};

  static const Set<String> _reads = <String>{
    'doc.read',
    'sheet.read_range',
    'presentation.render_state',
  };

  Future<bool> ask(PermissionRequest request) async {
    askCounts[request.tool] = (askCounts[request.tool] ?? 0) + 1;
    return _reads.contains(request.tool) ? allowReads : allowWrites;
  }
}

Map cellAt(Map payload, String ref) {
  for (final row in payload['cells'] as List) {
    for (final cell in row as List) {
      final map = (cell as Map).cast<String, Object?>();
      if (map['ref'] == ref) return map;
    }
  }
  throw StateError('cell $ref not in payload');
}

void main() {
  late Gate gate;
  late AuditLog audit;
  late McpServer server;
  late McpClient client;
  var tick = 0;

  int clock() => ++tick * 1000;

  // Backing state for the registries, visible to tests for assertions.
  late SheetEngine sheetEngine;
  late Presentation presentation;
  late Map<String, List<PdfAnnotation>> pdfAnnotations;

  setUp(() async {
    tick = 0;
    gate = Gate();
    audit = AuditLog();

    final sheet = Sheet(name: 'Budget');
    sheet.setCell(CellRef.tryParse('A1')!, Cell.number(2));
    sheet.setCell(CellRef.tryParse('B1')!, Cell.formula('=A1*3'));
    sheet.setCell(CellRef.tryParse('A2')!, Cell.text('label'));
    sheetEngine = SheetEngine(sheet);

    presentation = Presentation(
      id: 'pres-1',
      title: 'Deck',
      createdAtMs: 1000,
      updatedAtMs: 1000,
      slides: <Slide>[
        Slide(id: 's1', elements: <SlideElement>[
          SlideElement(
            id: 'title',
            kind: ElementKind.text,
            x: 100,
            y: 100,
            w: 400,
            h: 50,
            text: 'Hello',
            tracks: <AnimationTrack>[
              AnimationTrack(
                id: 'fade-in',
                kind: TrackKind.entry,
                property: AnimProperty.opacity,
                delayMs: 200,
                durationMs: 800,
                keyframes: const <Keyframe>[
                  Keyframe(timeMs: 0, value: 0),
                  Keyframe(timeMs: 800, value: 1),
                ],
              ),
            ],
          ),
          SlideElement(
              id: 'box', kind: ElementKind.shape, x: 10, y: 20, w: 30, h: 40),
        ]),
      ],
    );
    pdfAnnotations = <String, List<PdfAnnotation>>{};

    server = McpServer(
      store: InMemoryDocumentStore(),
      permissions: CallbackPermissionPolicy(gate.ask),
      auditLog: audit,
      sessionToken: sessionToken,
      clockMs: clock,
      sheets: <String, SheetEngine>{'sheet-1': sheetEngine},
      presentations: <String, Presentation>{'pres-1': presentation},
      pdfAnnotations: pdfAnnotations,
    );
    await server.start();
    client = McpClient(baseUrl: server.baseUri, sessionToken: sessionToken);
  });

  tearDown(() async {
    client.close();
    await server.close();
  });

  group('discovery', () {
    test('registry tools are listed when registries are configured',
        () async {
      final tools = await client.listTools();
      expect(
        tools.map((t) => t.name).toList(),
        <String>[
          'doc.read',
          'doc.apply_edit',
          'export.create',
          'sheet.read_range',
          'sheet.write_range',
          'presentation.render_state',
          'pdf.annotate',
        ],
      );
    });

    test('registry tools are absent (and uncallable) without registries',
        () async {
      final bareAudit = AuditLog();
      final bare = McpServer(
        store: InMemoryDocumentStore(),
        permissions: const StaticPermissionPolicy(true),
        auditLog: bareAudit,
        sessionToken: sessionToken,
        clockMs: clock,
      );
      await bare.start();
      final bareClient =
          McpClient(baseUrl: bare.baseUri, sessionToken: sessionToken);
      addTearDown(() async {
        bareClient.close();
        await bare.close();
      });

      final tools = await bareClient.listTools();
      expect(tools.map((t) => t.name).toList(),
          <String>['doc.read', 'doc.apply_edit', 'export.create']);

      await expectLater(
        bareClient.callTool(
            'sheet.read_range', {'sheetId': 'sheet-1', 'range': 'A1'}),
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32602)),
      );
      expect(bareAudit.entries.single.tool, 'sheet.read_range');
      expect(bareAudit.entries.single.outcome, AuditOutcome.error);
    });
  });

  group('sheet.read_range', () {
    test('allowed: returns computed values incl. formulas; asks once',
        () async {
      final result = await client.callTool('sheet.read_range',
          {'sheetId': 'sheet-1', 'range': 'A1:B2'});
      expect(result.isError, isFalse);
      final payload = jsonDecode(result.text) as Map;
      expect(payload['sheetId'], 'sheet-1');
      expect(payload['range'], 'A1:B2');
      expect(cellAt(payload, 'A1')['value'], 2);
      expect(cellAt(payload, 'B1')['value'], 6); // =A1*3, recalced
      expect(cellAt(payload, 'B1')['formula'], '=A1*3');
      expect(cellAt(payload, 'A2')['value'], 'label');
      expect(cellAt(payload, 'B2')['value'], isNull); // empty cell

      await client.callTool('sheet.read_range',
          {'sheetId': 'sheet-1', 'range': 'A1'});
      expect(gate.askCounts['sheet.read_range'], 1); // ask-once
      final entries =
          audit.entries.where((e) => e.tool == 'sheet.read_range').toList();
      expect(entries, hasLength(2));
      expect(entries.every((e) => e.outcome == AuditOutcome.allowed), isTrue);
      expect(entries.every((e) => e.targetId == 'sheet-1'), isTrue);
    });

    test('denied: errors, changes nothing, and is audited', () async {
      gate.allowReads = false;
      await expectLater(
        client.callTool('sheet.read_range',
            {'sheetId': 'sheet-1', 'range': 'A1:B1'}),
        throwsA(isA<McpException>()
            .having((e) => e.code, 'code', McpErrorCodes.permissionDenied)),
      );
      expect(sheetEngine.valueAt(CellRef.tryParse('A1')!),
          const NumberValue(2));
      final denied = audit.entries.single;
      expect(denied.tool, 'sheet.read_range');
      expect(denied.outcome, AuditOutcome.denied);
      expect(denied.targetId, 'sheet-1');
    });

    test('unknown sheet and malformed range are clean audited errors',
        () async {
      await expectLater(
        client.callTool(
            'sheet.read_range', {'sheetId': 'nope', 'range': 'A1'}),
        throwsA(isA<McpException>()
            .having((e) => e.code, 'code', McpErrorCodes.sheetNotFound)),
      );
      await expectLater(
        client.callTool(
            'sheet.read_range', {'sheetId': 'sheet-1', 'range': '::'}),
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32602)),
      );
      expect(
          audit.entries.every((e) => e.outcome == AuditOutcome.error), isTrue);
    });
  });

  group('sheet.write_range', () {
    test('allowed: round-trips through read; formula writes recalc; '
        'asks every call', () async {
      final written = await client.callTool('sheet.write_range', {
        'sheetId': 'sheet-1',
        'range': 'A1',
        'values': [
          [10]
        ],
      });
      expect(written.isError, isFalse);
      final writePayload = jsonDecode(written.text) as Map;
      expect(writePayload['written'], 1);
      expect(cellAt(writePayload, 'A1')['value'], 10);

      // The dependent formula cell recalced from the write.
      final read = await client.callTool(
          'sheet.read_range', {'sheetId': 'sheet-1', 'range': 'B1'});
      expect(cellAt(jsonDecode(read.text) as Map, 'B1')['value'], 30);

      // Writing a new formula cell stores and evaluates it.
      await client.callTool('sheet.write_range', {
        'sheetId': 'sheet-1',
        'range': 'C1',
        'values': [
          ['=A1+B1']
        ],
      });
      final readFormula = await client.callTool(
          'sheet.read_range', {'sheetId': 'sheet-1', 'range': 'C1'});
      final c1 = cellAt(jsonDecode(readFormula.text) as Map, 'C1');
      expect(c1['value'], 40);
      expect(c1['formula'], '=A1+B1');

      expect(gate.askCounts['sheet.write_range'], 2); // ask-every-call
      final entries =
          audit.entries.where((e) => e.tool == 'sheet.write_range').toList();
      expect(entries, hasLength(2));
      expect(entries.every((e) => e.outcome == AuditOutcome.allowed), isTrue);
      expect(entries.every((e) => e.targetId == 'sheet-1'), isTrue);
    });

    test('denied: sheet is unchanged and the denial is audited', () async {
      gate.allowWrites = false;
      await expectLater(
        client.callTool('sheet.write_range', {
          'sheetId': 'sheet-1',
          'range': 'A1',
          'values': [
            [99]
          ],
        }),
        throwsA(isA<McpException>()
            .having((e) => e.code, 'code', McpErrorCodes.permissionDenied)),
      );
      expect(sheetEngine.valueAt(CellRef.tryParse('A1')!),
          const NumberValue(2));
      expect(sheetEngine.valueAt(CellRef.tryParse('B1')!),
          const NumberValue(6));
      final denied = audit.entries.single;
      expect(denied.tool, 'sheet.write_range');
      expect(denied.outcome, AuditOutcome.denied);
    });

    test('dimension mismatch writes nothing at all', () async {
      await expectLater(
        client.callTool('sheet.write_range', {
          'sheetId': 'sheet-1',
          'range': 'A1:B1',
          'values': [
            [7]
          ],
        }),
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32602)),
      );
      expect(sheetEngine.valueAt(CellRef.tryParse('A1')!),
          const NumberValue(2));
      expect(audit.entries.single.outcome, AuditOutcome.error);
    });
  });

  group('presentation.render_state', () {
    test('allowed: returns the deterministic playback-core state; '
        'asks once', () async {
      final args = <String, Object?>{
        'presentationId': 'pres-1',
        'slideId': 's1',
        'timeMs': 600,
      };
      final first = await client.callTool('presentation.render_state', args);
      expect(first.isError, isFalse);

      // Byte-identical to calling the playback core directly, and stable
      // across repeated calls.
      final expected =
          jsonEncode(PlaybackCore(presentation).stateAt('s1', 600).toJson());
      expect(first.text, expected);
      final second =
          await client.callTool('presentation.render_state', args);
      expect(second.text, first.text);

      final payload = jsonDecode(first.text) as Map;
      expect(payload['slide_id'], 's1');
      expect(payload['time_ms'], 600);
      expect(payload['duration_ms'], 1000);
      final elements = (payload['elements'] as List)
          .map((e) => (e as Map).cast<String, Object?>())
          .toList();
      final title = elements.singleWhere((e) => e['element_id'] == 'title');
      expect(title['opacity'], 0.5); // fade-in halfway at t=600
      expect(title['visible'], isTrue);

      expect(gate.askCounts['presentation.render_state'], 1); // ask-once
      final entries = audit.entries
          .where((e) => e.tool == 'presentation.render_state')
          .toList();
      expect(entries, hasLength(2));
      expect(entries.every((e) => e.outcome == AuditOutcome.allowed), isTrue);
      expect(entries.every((e) => e.targetId == 'pres-1'), isTrue);
    });

    test('denied: errors and is audited', () async {
      gate.allowReads = false;
      await expectLater(
        client.callTool('presentation.render_state', {
          'presentationId': 'pres-1',
          'slideId': 's1',
          'timeMs': 0,
        }),
        throwsA(isA<McpException>()
            .having((e) => e.code, 'code', McpErrorCodes.permissionDenied)),
      );
      final denied = audit.entries.single;
      expect(denied.tool, 'presentation.render_state');
      expect(denied.outcome, AuditOutcome.denied);
      expect(denied.targetId, 'pres-1');
    });

    test('unknown presentation and slide are distinct audited errors',
        () async {
      await expectLater(
        client.callTool('presentation.render_state', {
          'presentationId': 'nope',
          'slideId': 's1',
          'timeMs': 0,
        }),
        throwsA(isA<McpException>().having(
            (e) => e.code, 'code', McpErrorCodes.presentationNotFound)),
      );
      await expectLater(
        client.callTool('presentation.render_state', {
          'presentationId': 'pres-1',
          'slideId': 'nope',
          'timeMs': 0,
        }),
        throwsA(isA<McpException>()
            .having((e) => e.code, 'code', McpErrorCodes.slideNotFound)),
      );
      expect(audit.entries, hasLength(2));
      expect(
          audit.entries.every((e) => e.outcome == AuditOutcome.error), isTrue);
    });
  });

  group('pdf.annotate', () {
    Map<String, Object?> noteJson(String text) => <String, Object?>{
          'type': 'note',
          'page': 0,
          'rect': <double>[10, 20, 100, 30],
          'text': text,
          'author': 'Reviewer',
        };

    test('allowed: stores, returns the list, asks every call', () async {
      final first = await client.callTool('pdf.annotate',
          {'documentId': 'doc-9', 'annotation': noteJson('Check this')});
      expect(first.isError, isFalse);
      var payload = jsonDecode(first.text) as Map;
      expect(payload['documentId'], 'doc-9');
      var annotations = payload['annotations'] as List;
      expect(annotations, hasLength(1));
      expect((annotations.single as Map)['text'], 'Check this');
      expect((annotations.single as Map)['type'], 'note');

      final second = await client.callTool('pdf.annotate', {
        'documentId': 'doc-9',
        'annotation': <String, Object?>{
          'type': 'highlight',
          'page': 1,
          'rect': <double>[0, 0, 50, 12],
          'text': 'Key line',
          'author': 'Reviewer',
        },
      });
      payload = jsonDecode(second.text) as Map;
      annotations = payload['annotations'] as List;
      expect(annotations, hasLength(2));
      expect((annotations[1] as Map)['type'], 'highlight');

      // The injected registry itself holds the stored model objects.
      expect(pdfAnnotations['doc-9'], hasLength(2));
      expect(pdfAnnotations['doc-9']!.first.text, 'Check this');
      expect(pdfAnnotations['doc-9']!.first.type, PdfAnnotationType.note);
      expect(pdfAnnotations['doc-9']!.last.page, 1);

      expect(gate.askCounts['pdf.annotate'], 2); // ask-every-call
      final entries =
          audit.entries.where((e) => e.tool == 'pdf.annotate').toList();
      expect(entries, hasLength(2));
      expect(entries.every((e) => e.outcome == AuditOutcome.allowed), isTrue);
      expect(entries.every((e) => e.targetId == 'doc-9'), isTrue);
    });

    test('denied: nothing is stored and the denial is audited', () async {
      gate.allowWrites = false;
      await expectLater(
        client.callTool('pdf.annotate',
            {'documentId': 'doc-9', 'annotation': noteJson('Nope')}),
        throwsA(isA<McpException>()
            .having((e) => e.code, 'code', McpErrorCodes.permissionDenied)),
      );
      expect(pdfAnnotations.containsKey('doc-9'), isFalse);
      final denied = audit.entries.single;
      expect(denied.tool, 'pdf.annotate');
      expect(denied.outcome, AuditOutcome.denied);
      expect(denied.targetId, 'doc-9');
    });

    test('malformed annotations are rejected and store nothing', () async {
      await expectLater(
        client.callTool('pdf.annotate', {
          'documentId': 'doc-9',
          'annotation': <String, Object?>{
            'type': 'scribble', // not a PdfAnnotationType
            'page': 0,
            'rect': <double>[0, 0, 10, 10],
            'text': 'x',
            'author': 'y',
          },
        }),
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32602)),
      );
      await expectLater(
        client.callTool('pdf.annotate', {
          'documentId': 'doc-9',
          'annotation': <String, Object?>{
            'type': 'note',
            'page': -1, // invalid page
            'rect': <double>[0, 0, 10, 10],
            'text': 'x',
            'author': 'y',
          },
        }),
        throwsA(isA<McpException>().having((e) => e.code, 'code', -32602)),
      );
      expect(pdfAnnotations.containsKey('doc-9'), isFalse);
      expect(audit.entries, hasLength(2));
      expect(
          audit.entries.every((e) => e.outcome == AuditOutcome.error), isTrue);
    });
  });
}
