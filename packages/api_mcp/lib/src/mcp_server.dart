import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doc_engine/doc_engine.dart';
import 'package:pdf_engine/pdf_engine.dart';
import 'package:presentation_engine/presentation_engine.dart';
import 'package:sheets_engine/sheets_engine.dart';

import 'audit_log.dart';
import 'permissions.dart';

/// Header carrying the per-session token required by [McpServer].
const String sessionTokenHeader = 'x-session-token';

/// Header carrying an opaque session identifier used for ask-once
/// permission caching. Never a secret.
const String sessionIdHeader = 'x-session-id';

/// JSON-RPC error codes used by [McpServer] (custom codes sit in the
/// reserved server range -32099..-32000).
abstract class McpErrorCodes {
  static const int unauthorized = -32001;
  static const int documentNotFound = -32002;
  static const int permissionDenied = -32003;
  static const int unsupportedFormat = -32004;
  static const int sheetNotFound = -32005;
  static const int presentationNotFound = -32006;
  static const int slideNotFound = -32007;
}

/// A tool failure whose message is safe to return to the caller verbatim
/// (fixed text and ids only — never document content or secrets).
class _ToolFailure implements Exception {
  _ToolFailure(this.code, this.message);
  final int code;
  final String message;
}

/// Static tool definitions: name, description, input schema, and the
/// consent frequency from the API_MCP.md tool table. The document tools
/// ([mcpToolDefinitions]) are always exposed; the sheet, presentation,
/// and PDF tools are exposed only when the matching registry is injected
/// into [McpServer] — a tool that cannot be backed is never listed.
class McpToolDefinition {
  const McpToolDefinition({
    required this.name,
    required this.description,
    required this.frequency,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final PermissionFrequency frequency;
  final Map<String, Object?> inputSchema;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
      };
}

/// The always-exposed tool set, in stable order.
const List<McpToolDefinition> mcpToolDefinitions = <McpToolDefinition>[
  McpToolDefinition(
    name: 'doc.read',
    description: 'Read a document node tree as JSON.',
    frequency: PermissionFrequency.askOncePerSession,
    inputSchema: _SchemaShim.docRead,
  ),
  McpToolDefinition(
    name: 'doc.apply_edit',
    description:
        'Apply editing operations (insertText, deleteRange) to a document.',
    frequency: PermissionFrequency.askEveryCall,
    inputSchema: _SchemaShim.docApplyEdit,
  ),
  McpToolDefinition(
    name: 'export.create',
    description: 'Export a document. Returns the exported content. '
        'Only format "markdown" is supported.',
    frequency: PermissionFrequency.askEveryCall,
    inputSchema: _SchemaShim.exportCreate,
  ),
];

/// Sheet tools, listed only when a sheet registry is injected.
const List<McpToolDefinition> mcpSheetToolDefinitions = <McpToolDefinition>[
  McpToolDefinition(
    name: 'sheet.read_range',
    description: 'Read computed cell values for an A1 range of a sheet.',
    frequency: PermissionFrequency.askOncePerSession,
    inputSchema: _SchemaShim.sheetReadRange,
  ),
  McpToolDefinition(
    name: 'sheet.write_range',
    description: 'Write values into an A1 range of a sheet. Strings '
        'starting with "=" are stored as formulas and recalculated.',
    frequency: PermissionFrequency.askEveryCall,
    inputSchema: _SchemaShim.sheetWriteRange,
  ),
];

/// Presentation tools, listed only when a presentation registry is
/// injected.
const List<McpToolDefinition> mcpPresentationToolDefinitions =
    <McpToolDefinition>[
  McpToolDefinition(
    name: 'presentation.render_state',
    description: 'Compute the deterministic render state of one slide '
        'at a point in time, via the playback core.',
    frequency: PermissionFrequency.askOncePerSession,
    inputSchema: _SchemaShim.presentationRenderState,
  ),
];

/// PDF tools, listed only when a PDF annotation registry is injected.
const List<McpToolDefinition> mcpPdfToolDefinitions = <McpToolDefinition>[
  McpToolDefinition(
    name: 'pdf.annotate',
    description: 'Validate and store an annotation for a document. '
        'Returns the full stored annotation list for that document.',
    frequency: PermissionFrequency.askEveryCall,
    inputSchema: _SchemaShim.pdfAnnotate,
  ),
];

/// Input schemas, kept as literal maps so tool definitions stay const.
abstract class _SchemaShim {
  static const Map<String, Object?> docRead = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'documentId': <String, Object?>{'type': 'string'},
    },
    'required': <String>['documentId'],
  };

  static const Map<String, Object?> docApplyEdit = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'documentId': <String, Object?>{'type': 'string'},
      'operations': <String, Object?>{
        'type': 'array',
        'items': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'type': <String, Object?>{
              'type': 'string',
              'enum': <String>['insertText', 'deleteRange'],
            },
            'blockId': <String, Object?>{'type': 'string'},
            'offset': <String, Object?>{'type': 'integer'},
            'start': <String, Object?>{'type': 'integer'},
            'end': <String, Object?>{'type': 'integer'},
            'text': <String, Object?>{'type': 'string'},
          },
          'required': <String>['type', 'blockId'],
        },
      },
    },
    'required': <String>['documentId', 'operations'],
  };

  static const Map<String, Object?> exportCreate = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'documentId': <String, Object?>{'type': 'string'},
      'format': <String, Object?>{
        'type': 'string',
        'enum': <String>['markdown'],
        'default': 'markdown',
      },
    },
    'required': <String>['documentId'],
  };

  static const Map<String, Object?> sheetReadRange = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'sheetId': <String, Object?>{'type': 'string'},
      'range': <String, Object?>{
        'type': 'string',
        'description': 'A1 range, e.g. "A1:B2" (a single ref is a 1x1 range)',
      },
    },
    'required': <String>['sheetId', 'range'],
  };

  static const Map<String, Object?> sheetWriteRange = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'sheetId': <String, Object?>{'type': 'string'},
      'range': <String, Object?>{
        'type': 'string',
        'description': 'A1 range, e.g. "A1:B2"',
      },
      'values': <String, Object?>{
        'type': 'array',
        'description': 'Rows matching the range exactly: one array per '
            'range row, one scalar per range column. A string starting '
            'with "=" is stored as a formula; null clears a cell.',
        'items': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{},
        },
      },
    },
    'required': <String>['sheetId', 'range', 'values'],
  };

  static const Map<String, Object?> presentationRenderState =
      <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'presentationId': <String, Object?>{'type': 'string'},
      'slideId': <String, Object?>{'type': 'string'},
      'timeMs': <String, Object?>{'type': 'integer', 'minimum': 0},
    },
    'required': <String>['presentationId', 'slideId', 'timeMs'],
  };

  static const Map<String, Object?> pdfAnnotate = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'documentId': <String, Object?>{'type': 'string'},
      'annotation': <String, Object?>{
        'type': 'object',
        'description': 'Annotation in the pdf_engine JSON form: '
            '{type: "note"|"highlight", page: int, rect: '
            '[left, bottom, width, height], text: string, author: string}',
        'properties': <String, Object?>{
          'type': <String, Object?>{
            'type': 'string',
            'enum': <String>['note', 'highlight'],
          },
          'page': <String, Object?>{'type': 'integer', 'minimum': 0},
          'rect': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'number'},
            'minItems': 4,
            'maxItems': 4,
          },
          'text': <String, Object?>{'type': 'string'},
          'author': <String, Object?>{'type': 'string'},
        },
        'required': <String>['type', 'page', 'rect', 'text', 'author'],
      },
    },
    'required': <String>['documentId', 'annotation'],
  };
}

/// Local MCP server: JSON-RPC 2.0 over HTTP (Streamable-HTTP style
/// single-endpoint POST), implemented on `dart:io`.
///
/// Safety contract (API_MCP.md):
/// - **Opt-in:** constructing the server binds nothing. [start] must be
///   called explicitly, and binds loopback unless another address is
///   passed deliberately.
/// - Every request requires the per-session token in the
///   [sessionTokenHeader] header; a missing/wrong token gets a 401
///   JSON-RPC error and nothing is executed or audited as a tool call.
/// - Every `tools/call` passes the [PermissionPolicy] gate *before* any
///   data is read or changed. Denied calls return an error, change
///   nothing, and are audited as [AuditOutcome.denied].
/// - Every gated call appends exactly one [AuditLog] entry.
class McpServer {
  McpServer({
    required DocumentStore store,
    required PermissionPolicy permissions,
    required AuditLog auditLog,
    required String sessionToken,
    required int Function() clockMs,
    IdGenerator? idGenerator,
    Map<String, SheetEngine>? sheets,
    Map<String, Presentation>? presentations,
    Map<String, List<PdfAnnotation>>? pdfAnnotations,
  })  : _store = store,
        _permissions = permissions,
        _auditLog = auditLog,
        _sessionToken = sessionToken,
        _clockMs = clockMs,
        _idGenerator = idGenerator ?? SequentialIdGenerator(),
        _sheets = sheets,
        _presentations = presentations,
        _pdfAnnotations = pdfAnnotations,
        _playbackCores = presentations == null
            ? null
            : <String, PlaybackCore>{
                for (final entry in presentations.entries)
                  entry.key: PlaybackCore(entry.value),
              };

  final DocumentStore _store;
  final PermissionPolicy _permissions;
  final AuditLog _auditLog;
  final String _sessionToken;
  final int Function() _clockMs;
  final IdGenerator _idGenerator;

  /// Optional in-memory registries backing the non-document tools.
  /// A null registry means its tools are neither listed nor callable.
  final Map<String, SheetEngine>? _sheets;
  final Map<String, Presentation>? _presentations;
  final Map<String, PlaybackCore>? _playbackCores;

  /// Annotation storage keyed by document ID. The server appends to the
  /// injected lists (creating one per document on first use), so the
  /// caller observes stored annotations through its own map.
  final Map<String, List<PdfAnnotation>>? _pdfAnnotations;

  /// The tools this server actually exposes: the document tools, plus
  /// each registry-backed group whose registry was injected.
  List<McpToolDefinition> get toolDefinitions => <McpToolDefinition>[
        ...mcpToolDefinitions,
        if (_sheets != null) ...mcpSheetToolDefinitions,
        if (_presentations != null) ...mcpPresentationToolDefinitions,
        if (_pdfAnnotations != null) ...mcpPdfToolDefinitions,
      ];

  HttpServer? _httpServer;

  /// The bound port, valid after [start].
  int get port {
    final server = _httpServer;
    if (server == null) throw StateError('McpServer is not started');
    return server.port;
  }

  /// Base URI clients should target, valid after [start].
  Uri get baseUri => Uri(
        scheme: 'http',
        host: _httpServer!.address.address,
        port: port,
      );

  bool get isStarted => _httpServer != null;

  /// Binds the HTTP server (loopback by default, ephemeral [port] 0).
  Future<void> start({
    InternetAddress? address,
    int port = 0,
  }) async {
    if (_httpServer != null) throw StateError('McpServer already started');
    final server = await HttpServer.bind(
      address ?? InternetAddress.loopbackIPv4,
      port,
    );
    _httpServer = server;
    server.listen(_handleGuarded);
  }

  Future<void> close() async {
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  Future<void> _handleGuarded(HttpRequest request) async {
    try {
      await _handle(request);
    } catch (_) {
      // Last-resort guard: never leak an exception (it could contain
      // document content) and never leave a request hanging.
      try {
        _sendError(request, null, -32603, 'Internal error',
            statusCode: 500);
      } catch (_) {
        // Response already (partially) sent; nothing safe left to do.
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.method != 'POST') {
      _sendError(request, null, -32600, 'Only POST is supported',
          statusCode: 405);
      return;
    }
    final token = request.headers.value(sessionTokenHeader);
    if (token == null || token != _sessionToken) {
      _sendError(request, null, McpErrorCodes.unauthorized,
          'Unauthorized: missing or invalid session token',
          statusCode: 401);
      return;
    }

    final rawBody = await utf8.decoder.bind(request).join();
    final Object? decoded;
    try {
      decoded = jsonDecode(rawBody);
    } on FormatException {
      _sendError(request, null, -32700, 'Parse error');
      return;
    }
    if (decoded is! Map) {
      _sendError(request, null, -32600, 'Invalid request');
      return;
    }
    final envelope = decoded.cast<String, Object?>();
    final id = envelope['id'];
    final method = envelope['method'];
    if (method is! String) {
      _sendError(request, id, -32600, 'Invalid request: method missing');
      return;
    }

    // Notifications carry no id and expect no response body.
    if (id == null && method.startsWith('notifications/')) {
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
      return;
    }

    final params = envelope['params'];
    final paramsMap =
        params is Map ? params.cast<String, Object?>() : <String, Object?>{};

    switch (method) {
      case 'initialize':
        _sendResult(request, id, <String, Object?>{
          'protocolVersion':
              paramsMap['protocolVersion'] ?? '2025-03-26',
          'capabilities': <String, Object?>{
            'tools': <String, Object?>{},
          },
          'serverInfo': <String, Object?>{
            'name': 'workspace-mcp-server',
            'version': '0.1.0',
          },
        });
      case 'tools/list':
        _sendResult(request, id, <String, Object?>{
          'tools': toolDefinitions.map((t) => t.toJson()).toList(),
        });
      case 'tools/call':
        await _toolsCall(request, id, paramsMap);
      default:
        _sendError(request, id, -32601, 'Method not found: $method');
    }
  }

  Future<void> _toolsCall(
      HttpRequest request, Object? id, Map<String, Object?> params) async {
    final name = params['name'];
    final rawArgs = params['arguments'];
    final args =
        rawArgs is Map ? rawArgs.cast<String, Object?>() : <String, Object?>{};
    final targetId = args['documentId'] as String? ??
        args['sheetId'] as String? ??
        args['presentationId'] as String?;

    if (name is! String) {
      _sendError(request, id, -32602, 'Invalid params: tool name missing');
      return;
    }
    final definition = _definitionFor(name);
    if (definition == null) {
      _audit(name, targetId, AuditOutcome.error);
      _sendError(request, id, -32602, 'Unknown tool: $name');
      return;
    }

    final sessionId =
        request.headers.value(sessionIdHeader) ?? 'default-session';
    final allowed = await _permissions.isAllowed(PermissionRequest(
      sessionId: sessionId,
      tool: name,
      targetId: targetId,
      frequency: definition.frequency,
    ));
    if (!allowed) {
      _audit(name, targetId, AuditOutcome.denied);
      _sendError(request, id, McpErrorCodes.permissionDenied,
          'Permission denied for tool $name');
      return;
    }

    try {
      final result = await _execute(definition.name, args);
      _audit(name, targetId, AuditOutcome.allowed);
      _sendResult(request, id, result);
    } on _ToolFailure catch (e) {
      _audit(name, targetId, AuditOutcome.error);
      _sendError(request, id, e.code, e.message);
    } catch (_) {
      _audit(name, targetId, AuditOutcome.error);
      _sendError(request, id, -32603, 'Tool execution failed');
    }
  }

  McpToolDefinition? _definitionFor(String name) {
    for (final def in toolDefinitions) {
      if (def.name == name) return def;
    }
    return null;
  }

  void _audit(String tool, String? targetId, AuditOutcome outcome) {
    _auditLog.record(
      timestampMs: _clockMs(),
      tool: tool,
      targetId: targetId,
      outcome: outcome,
    );
  }

  /// Executes an allowed tool call and returns its JSON-RPC result.
  Future<Map<String, Object?>> _execute(
      String tool, Map<String, Object?> args) async {
    switch (tool) {
      case 'doc.read':
        final doc = await _requireDocument(args);
        return _textResult(jsonEncode(doc.toJson()),
            structured: doc.toJson());
      case 'doc.apply_edit':
        return _applyEdit(args);
      case 'export.create':
        final format = args['format'] as String? ?? 'markdown';
        if (format != 'markdown') {
          throw _ToolFailure(McpErrorCodes.unsupportedFormat,
              'Unsupported export format: only "markdown" is available');
        }
        final doc = await _requireDocument(args);
        return _textResult(const MarkdownExporter().export(doc));
      case 'sheet.read_range':
        return _sheetReadRange(args);
      case 'sheet.write_range':
        return _sheetWriteRange(args);
      case 'presentation.render_state':
        return _presentationRenderState(args);
      case 'pdf.annotate':
        return _pdfAnnotate(args);
      default:
        throw _ToolFailure(-32602, 'Unknown tool: $tool');
    }
  }

  // --- Registry-backed tools ------------------------------------------------

  Map<String, Object?> _sheetReadRange(Map<String, Object?> args) {
    final engine = _requireSheet(args);
    final range = _requireRange(args);
    final payload = _rangePayload(args['sheetId'] as String, engine, range);
    return _textResult(jsonEncode(payload), structured: payload);
  }

  Map<String, Object?> _sheetWriteRange(Map<String, Object?> args) {
    final engine = _requireSheet(args);
    final range = _requireRange(args);
    final rawValues = args['values'];
    if (rawValues is! List || rawValues.length != range.rowCount) {
      throw _ToolFailure(-32602,
          'Invalid params: values must have exactly ${range.rowCount} row(s) for range ${range.toA1()}');
    }
    // Convert everything before mutating anything, so a malformed row
    // cannot leave a half-written range behind.
    final converted = <Cell>[];
    for (final rawRow in rawValues) {
      if (rawRow is! List || rawRow.length != range.colCount) {
        throw _ToolFailure(-32602,
            'Invalid params: each values row must have exactly ${range.colCount} cell(s) for range ${range.toA1()}');
      }
      for (final rawCell in rawRow) {
        converted.add(_cellFromJson(rawCell));
      }
    }
    var i = 0;
    for (final ref in range.cells) {
      engine.setCell(ref, converted[i++]); // setCell recalcs dependents
    }
    final payload = _rangePayload(args['sheetId'] as String, engine, range)
      ..['written'] = converted.length;
    return _textResult(jsonEncode(payload), structured: payload);
  }

  /// One cell in a range payload: its computed value as a JSON scalar
  /// (null for empty), its stored formula when it has one, and an
  /// `error` field when the computed value is an evaluation error
  /// (disambiguating an error code from a text cell with the same text).
  Map<String, Object?> _cellPayload(CellRef ref, SheetEngine engine) {
    final stored = engine.sheet.cellAt(ref);
    final value = engine.valueAt(ref);
    return <String, Object?>{
      'ref': ref.toA1(),
      'value': switch (value) {
        EmptyValue() => null,
        NumberValue(:final value) => value,
        TextValue(:final value) => value,
        BoolValue(:final value) => value,
        ErrorValue(:final code) => code,
      },
      if (value is ErrorValue) 'error': value.code,
      if (stored != null && stored.kind == CellKind.formula)
        'formula': stored.formulaSource,
    };
  }

  Map<String, Object?> _rangePayload(
          String sheetId, SheetEngine engine, CellRange range) =>
      <String, Object?>{
        'sheetId': sheetId,
        'range': range.toA1(),
        'cells': <List<Map<String, Object?>>>[
          for (var r = 0; r < range.rowCount; r++)
            <Map<String, Object?>>[
              for (var c = 0; c < range.colCount; c++)
                _cellPayload(
                    CellRef(range.start.row + r, range.start.col + c), engine),
            ],
        ],
      };

  Cell _cellFromJson(Object? raw) => switch (raw) {
        null => Cell.empty(),
        num n => Cell.number(n.toDouble()),
        bool b => Cell.boolean(b),
        String s when s.startsWith('=') => Cell.formula(s),
        String s => Cell.text(s),
        _ => throw _ToolFailure(-32602,
            'Invalid params: cell values must be null, number, bool, or string'),
      };

  SheetEngine _requireSheet(Map<String, Object?> args) {
    final sheets = _sheets;
    if (sheets == null) {
      throw _ToolFailure(-32602, 'Sheet tools are not available');
    }
    final sheetId = args['sheetId'];
    if (sheetId is! String || sheetId.isEmpty) {
      throw _ToolFailure(-32602, 'Invalid params: sheetId is required');
    }
    final engine = sheets[sheetId];
    if (engine == null) {
      throw _ToolFailure(McpErrorCodes.sheetNotFound, 'Sheet not found');
    }
    return engine;
  }

  CellRange _requireRange(Map<String, Object?> args) {
    final raw = args['range'];
    final range = raw is String ? CellRange.tryParse(raw) : null;
    if (range == null) {
      throw _ToolFailure(
          -32602, 'Invalid params: range must be an A1 range, e.g. "A1:B2"');
    }
    return range;
  }

  Map<String, Object?> _presentationRenderState(Map<String, Object?> args) {
    final presentations = _presentations;
    final cores = _playbackCores;
    if (presentations == null || cores == null) {
      throw _ToolFailure(
          -32602, 'Presentation tools are not available');
    }
    final presentationId = args['presentationId'];
    if (presentationId is! String || presentationId.isEmpty) {
      throw _ToolFailure(
          -32602, 'Invalid params: presentationId is required');
    }
    final presentation = presentations[presentationId];
    if (presentation == null) {
      throw _ToolFailure(McpErrorCodes.presentationNotFound,
          'Presentation not found');
    }
    final slideId = args['slideId'];
    if (slideId is! String || slideId.isEmpty) {
      throw _ToolFailure(-32602, 'Invalid params: slideId is required');
    }
    if (presentation.slideById(slideId) == null) {
      throw _ToolFailure(McpErrorCodes.slideNotFound, 'Slide not found');
    }
    final timeMs = args['timeMs'];
    if (timeMs is! int || timeMs < 0) {
      throw _ToolFailure(
          -32602, 'Invalid params: timeMs must be an integer >= 0');
    }
    // PlaybackCore.stateAt is pure, so this result is deterministic:
    // same presentation, slide, and time -> same JSON, every call.
    final state = cores[presentationId]!.stateAt(slideId, timeMs);
    final payload = state.toJson();
    return _textResult(jsonEncode(payload), structured: payload);
  }

  Map<String, Object?> _pdfAnnotate(Map<String, Object?> args) {
    final registry = _pdfAnnotations;
    if (registry == null) {
      throw _ToolFailure(-32602, 'PDF tools are not available');
    }
    final documentId = args['documentId'];
    if (documentId is! String || documentId.isEmpty) {
      throw _ToolFailure(
          -32602, 'Invalid params: documentId is required');
    }
    final raw = args['annotation'];
    if (raw is! Map) {
      throw _ToolFailure(
          -32602, 'Invalid params: annotation must be an object');
    }
    final PdfAnnotation annotation;
    try {
      annotation =
          PdfAnnotation.fromJson(raw.cast<String, Object?>());
    } on Object {
      throw _ToolFailure(
          -32602, 'Invalid params: annotation is malformed');
    }
    if (annotation.page < 0 ||
        annotation.rect.width < 0 ||
        annotation.rect.height < 0) {
      throw _ToolFailure(-32602,
          'Invalid params: annotation page and rect size must be >= 0');
    }
    final stored =
        registry.putIfAbsent(documentId, () => <PdfAnnotation>[]);
    stored.add(annotation);
    final payload = <String, Object?>{
      'documentId': documentId,
      'annotations': annotationsToJson(stored),
    };
    return _textResult(jsonEncode(payload), structured: payload);
  }

  Future<Map<String, Object?>> _applyEdit(Map<String, Object?> args) async {
    final doc = await _requireDocument(args);
    final rawOps = args['operations'];
    if (rawOps is! List || rawOps.isEmpty) {
      throw _ToolFailure(
          -32602, 'Invalid params: operations must be a non-empty list');
    }
    final editor = DocumentEditor(
      doc,
      ids: _idGenerator,
      clockMs: _clockMs,
    );
    var applied = 0;
    for (final rawOp in rawOps) {
      if (rawOp is! Map) {
        throw _ToolFailure(-32602, 'Invalid params: operation must be an object');
      }
      final op = rawOp.cast<String, Object?>();
      final type = op['type'];
      final blockId = op['blockId'];
      if (blockId is! String) {
        throw _ToolFailure(
            -32602, 'Invalid params: operation requires a blockId');
      }
      switch (type) {
        case 'insertText':
          final offset = op['offset'];
          final text = op['text'];
          if (offset is! int || text is! String) {
            throw _ToolFailure(-32602,
                'Invalid params: insertText requires offset:int and text:String');
          }
          editor.insertText(blockId, offset, text);
        case 'deleteRange':
          final start = op['start'];
          final end = op['end'];
          if (start is! int || end is! int) {
            throw _ToolFailure(-32602,
                'Invalid params: deleteRange requires start:int and end:int');
          }
          editor.deleteRange(blockId, start, end);
        default:
          throw _ToolFailure(
              -32602, 'Unsupported operation type: $type');
      }
      applied++;
    }
    await _store.save(doc);
    return _textResult(jsonEncode(<String, Object?>{
      'documentId': doc.id,
      'appliedOperations': applied,
      'document': doc.toJson(),
    }));
  }

  Future<Document> _requireDocument(Map<String, Object?> args) async {
    final documentId = args['documentId'];
    if (documentId is! String || documentId.isEmpty) {
      throw _ToolFailure(
          -32602, 'Invalid params: documentId is required');
    }
    final doc = await _store.load(documentId);
    if (doc == null) {
      throw _ToolFailure(
          McpErrorCodes.documentNotFound, 'Document not found');
    }
    return doc;
  }

  Map<String, Object?> _textResult(String text,
          {Map<String, Object?>? structured}) =>
      <String, Object?>{
        'content': <Map<String, Object?>>[
          <String, Object?>{'type': 'text', 'text': text},
        ],
        'isError': false,
        if (structured != null) 'structuredContent': structured,
      };

  void _sendResult(HttpRequest request, Object? id, Map<String, Object?> result) {
    _sendJson(request, <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    });
  }

  void _sendError(HttpRequest request, Object? id, int code, String message,
      {int statusCode = 200}) {
    request.response.statusCode = statusCode;
    _sendJson(request, <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'error': <String, Object?>{'code': code, 'message': message},
    });
  }

  void _sendJson(HttpRequest request, Map<String, Object?> payload) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(payload));
    request.response.close();
  }
}
