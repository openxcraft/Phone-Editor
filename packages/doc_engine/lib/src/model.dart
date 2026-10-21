/// Format-neutral document model.
///
/// Node tree: document -> sections -> blocks -> inline nodes.
/// Serialization is deterministic: fixed key order, marks sorted by name,
/// no wall-clock values are generated inside this file (timestamps are
/// supplied by callers), so the same tree always encodes to the same JSON.
library;

/// Inline formatting marks. Serialized by [Enum.name], sorted for output.
enum Mark { bold, italic, underline, code }

/// Block kinds. Phase 1 adds [BlockType.table] and [BlockType.image].
enum BlockType { paragraph, heading1, heading2, bullet, quote, table, image }

/// A run of text sharing one set of marks.
class InlineNode {
  InlineNode(this.text, [Set<Mark> marks = const {}])
      : marks = Set.unmodifiable(marks);

  String text;
  final Set<Mark> marks;

  InlineNode copy() => InlineNode(text, marks);

  Map<String, Object?> toJson() => <String, Object?>{
        'text': text,
        'marks': (marks.map((m) => m.name).toList()..sort()),
      };

  factory InlineNode.fromJson(Map<String, Object?> json) {
    final rawText = json['text'];
    final rawMarks = json['marks'];
    if (rawText is! String || rawMarks is! List) {
      throw const FormatException('InlineNode requires text:String, marks:List');
    }
    final marks = <Mark>{};
    for (final m in rawMarks) {
      marks.add(Mark.values.byName(m as String));
    }
    return InlineNode(rawText, marks);
  }
}

/// One cell of a table block: a list of inline runs (a single
/// paragraph's worth of content per cell in Phase 1).
class TableCell {
  TableCell({List<InlineNode>? inlines})
      : inlines = inlines ?? <InlineNode>[InlineNode('')];

  List<InlineNode> inlines;

  String get plainText => inlines.map((n) => n.text).join();

  TableCell copy() =>
      TableCell(inlines: inlines.map((n) => n.copy()).toList());

  Map<String, Object?> toJson() => <String, Object?>{
        'inlines': inlines.map((n) => n.toJson()).toList(),
      };

  factory TableCell.fromJson(Map<String, Object?> json) {
    final inlines = json['inlines'];
    if (inlines is! List) {
      throw const FormatException('TableCell requires inlines:List');
    }
    return TableCell(
      inlines: inlines
          .map((e) => InlineNode.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
    );
  }
}

/// A block: one unit of a section.
///
/// Text-bearing blocks use [inlines]. Table blocks use [tableRows]
/// (rows of cells; [inlines] stays a single empty run and text operations
/// do not apply). Image blocks carry metadata only — [imageAssetId],
/// [imageAlt], [imageByteLength], [imageHash] — the engine never handles
/// image binary data; asset storage lives outside the document model.
class Block {
  Block({
    required this.id,
    required this.type,
    List<InlineNode>? inlines,
    this.tableRows,
    this.imageAssetId,
    this.imageAlt,
    this.imageByteLength,
    this.imageHash,
  }) : inlines = inlines ?? <InlineNode>[InlineNode('')];

  final String id;
  BlockType type;
  List<InlineNode> inlines;

  /// Table content when [type] is [BlockType.table]; null otherwise.
  List<List<TableCell>>? tableRows;

  /// Image metadata when [type] is [BlockType.image]; null otherwise.
  /// [imageHash] is a caller-supplied content hash placeholder (e.g. a
  /// digest computed by the asset layer); the engine does not verify it.
  String? imageAssetId;
  String? imageAlt;
  int? imageByteLength;
  String? imageHash;

  /// Concatenated plain text of all inline runs. Operation offsets are
  /// defined over this string. For table blocks this is empty — cell text
  /// is reached through [tableRows].
  String get plainText => inlines.map((n) => n.text).join();

  Block copy() => Block(
        id: id,
        type: type,
        inlines: inlines.map((n) => n.copy()).toList(),
        tableRows: tableRows
            ?.map((row) => row.map((c) => c.copy()).toList())
            .toList(),
        imageAssetId: imageAssetId,
        imageAlt: imageAlt,
        imageByteLength: imageByteLength,
        imageHash: imageHash,
      );

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'id': id,
      'type': type.name,
      'inlines': inlines.map((n) => n.toJson()).toList(),
    };
    if (tableRows != null) {
      json['table_rows'] = tableRows!
          .map((row) => row.map((c) => c.toJson()).toList())
          .toList();
    }
    if (type == BlockType.image) {
      json['image'] = <String, Object?>{
        'asset_id': imageAssetId,
        'alt': imageAlt,
        'byte_length': imageByteLength,
        'hash': imageHash,
      };
    }
    return json;
  }

  factory Block.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final type = json['type'];
    final inlines = json['inlines'];
    if (id is! String || type is! String || inlines is! List) {
      throw const FormatException(
          'Block requires id:String, type:String, inlines:List');
    }
    List<List<TableCell>>? tableRows;
    final rawRows = json['table_rows'];
    if (rawRows != null) {
      if (rawRows is! List) {
        throw const FormatException('Block.table_rows must be a List');
      }
      tableRows = rawRows
          .map((row) => (row as List)
              .map((c) =>
                  TableCell.fromJson((c as Map).cast<String, Object?>()))
              .toList())
          .toList();
    }
    String? imageAssetId;
    String? imageAlt;
    int? imageByteLength;
    String? imageHash;
    final rawImage = json['image'];
    if (rawImage != null) {
      final image = (rawImage as Map).cast<String, Object?>();
      imageAssetId = image['asset_id'] as String?;
      imageAlt = image['alt'] as String?;
      imageByteLength = image['byte_length'] as int?;
      imageHash = image['hash'] as String?;
    }
    return Block(
      id: id,
      type: BlockType.values.byName(type),
      inlines: inlines
          .map((e) => InlineNode.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      tableRows: tableRows,
      imageAssetId: imageAssetId,
      imageAlt: imageAlt,
      imageByteLength: imageByteLength,
      imageHash: imageHash,
    );
  }
}

/// A comment anchored to a rune range `[start, end)` of one block's
/// plain text. Anchors are stored, not tracked: if the anchored text is
/// later edited, the range is not adjusted in Phase 1 (documented
/// simplification; anchor tracking arrives with the CRDT phase).
class DocComment {
  DocComment({
    required this.id,
    required this.blockId,
    required this.start,
    required this.end,
    required this.author,
    required this.text,
    required this.createdAtMs,
    this.resolved = false,
  });

  final String id;
  final String blockId;
  final int start;
  final int end;
  final String author;
  String text;
  final int createdAtMs;
  bool resolved;

  DocComment copy() => DocComment(
        id: id,
        blockId: blockId,
        start: start,
        end: end,
        author: author,
        text: text,
        createdAtMs: createdAtMs,
        resolved: resolved,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'block_id': blockId,
        'start': start,
        'end': end,
        'author': author,
        'text': text,
        'created_at': createdAtMs,
        'resolved': resolved,
      };

  factory DocComment.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final blockId = json['block_id'];
    final start = json['start'];
    final end = json['end'];
    final author = json['author'];
    final text = json['text'];
    final created = json['created_at'];
    if (id is! String ||
        blockId is! String ||
        start is! int ||
        end is! int ||
        author is! String ||
        text is! String ||
        created is! int) {
      throw const FormatException('DocComment field type mismatch');
    }
    return DocComment(
      id: id,
      blockId: blockId,
      start: start,
      end: end,
      author: author,
      text: text,
      createdAtMs: created,
      resolved: json['resolved'] as bool? ?? false,
    );
  }
}

/// Kind of a tracked-change suggestion.
enum SuggestionKind { insertion, deletion }

/// A pending tracked change, recorded while suggestion mode is on
/// (see DocumentEditor). The document's suggestion list holds pending
/// items only: accepting or rejecting removes the entry.
///
/// For an insertion, [start] is the rune offset and [text]/[marks] are
/// what would be inserted. For a deletion, `[start, end)` is the range
/// and [text] is a plain-text snapshot of that range at record time
/// (per-run marks of the deleted text are not preserved — documented
/// simplification). Ranges are as-recorded and are clamped, not
/// remapped, when accepted after other edits.
class Suggestion {
  Suggestion({
    required this.id,
    required this.kind,
    required this.blockId,
    required this.start,
    required this.end,
    required this.text,
    required this.author,
    required this.createdAtMs,
    Set<Mark> marks = const {},
  }) : marks = Set.unmodifiable(marks);

  final String id;
  final SuggestionKind kind;
  final String blockId;
  final int start;
  final int end;
  final String text;
  final Set<Mark> marks;
  final String author;
  final int createdAtMs;

  Suggestion copy() => Suggestion(
        id: id,
        kind: kind,
        blockId: blockId,
        start: start,
        end: end,
        text: text,
        author: author,
        createdAtMs: createdAtMs,
        marks: marks,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind.name,
        'block_id': blockId,
        'start': start,
        'end': end,
        'text': text,
        'marks': (marks.map((m) => m.name).toList()..sort()),
        'author': author,
        'created_at': createdAtMs,
      };

  factory Suggestion.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final kind = json['kind'];
    final blockId = json['block_id'];
    final start = json['start'];
    final end = json['end'];
    final text = json['text'];
    final author = json['author'];
    final created = json['created_at'];
    final rawMarks = json['marks'];
    if (id is! String ||
        kind is! String ||
        blockId is! String ||
        start is! int ||
        end is! int ||
        text is! String ||
        author is! String ||
        created is! int ||
        rawMarks is! List) {
      throw const FormatException('Suggestion field type mismatch');
    }
    return Suggestion(
      id: id,
      kind: SuggestionKind.values.byName(kind),
      blockId: blockId,
      start: start,
      end: end,
      text: text,
      author: author,
      createdAtMs: created,
      marks: rawMarks.map((m) => Mark.values.byName(m as String)).toSet(),
    );
  }
}

/// A section: an ordered group of blocks.
class Section {
  Section({required this.id, List<Block>? blocks}) : blocks = blocks ?? <Block>[];

  final String id;
  List<Block> blocks;

  Section copy() =>
      Section(id: id, blocks: blocks.map((b) => b.copy()).toList());

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'blocks': blocks.map((b) => b.toJson()).toList(),
      };

  factory Section.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final blocks = json['blocks'];
    if (id is! String || blocks is! List) {
      throw const FormatException('Section requires id:String, blocks:List');
    }
    return Section(
      id: id,
      blocks: blocks
          .map((e) => Block.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
    );
  }
}

/// Sync lifecycle of a document row (mirrors the SQLite CHECK constraint).
enum SyncStatus { localOnly, pending, synced }

extension SyncStatusWire on SyncStatus {
  String get wire => switch (this) {
        SyncStatus.localOnly => 'local_only',
        SyncStatus.pending => 'pending',
        SyncStatus.synced => 'synced',
      };

  static SyncStatus fromWire(String value) => switch (value) {
        'local_only' => SyncStatus.localOnly,
        'pending' => SyncStatus.pending,
        'synced' => SyncStatus.synced,
        _ => throw FormatException('Unknown sync_status: $value'),
      };
}

/// The document root.
class Document {
  Document({
    required this.id,
    required this.title,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.deletedAtMs,
    this.syncStatus = SyncStatus.localOnly,
    List<Section>? sections,
    List<DocComment>? comments,
    List<Suggestion>? suggestions,
  })  : sections = sections ?? <Section>[],
        comments = comments ?? <DocComment>[],
        suggestions = suggestions ?? <Suggestion>[];

  final String id;
  String title;
  List<Section> sections;

  /// All comments (open and resolved), in creation order.
  List<DocComment> comments;

  /// Pending tracked-change suggestions, in creation order.
  List<Suggestion> suggestions;

  /// Epoch milliseconds, supplied by the caller (never read from a clock
  /// inside the model, keeping serialization and tests deterministic).
  final int createdAtMs;
  int updatedAtMs;
  int? deletedAtMs;
  SyncStatus syncStatus;

  /// All blocks in document order.
  Iterable<Block> get allBlocks sync* {
    for (final s in sections) {
      yield* s.blocks;
    }
  }

  Block? blockById(String blockId) {
    for (final b in allBlocks) {
      if (b.id == blockId) return b;
    }
    return null;
  }

  Document copy() => Document(
        id: id,
        title: title,
        createdAtMs: createdAtMs,
        updatedAtMs: updatedAtMs,
        deletedAtMs: deletedAtMs,
        syncStatus: syncStatus,
        sections: sections.map((s) => s.copy()).toList(),
        comments: comments.map((c) => c.copy()).toList(),
        suggestions: suggestions.map((s) => s.copy()).toList(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'created_at': createdAtMs,
        'updated_at': updatedAtMs,
        'deleted_at': deletedAtMs,
        'sync_status': syncStatus.wire,
        'sections': sections.map((s) => s.toJson()).toList(),
        'comments': comments.map((c) => c.toJson()).toList(),
        'suggestions': suggestions.map((s) => s.toJson()).toList(),
      };

  factory Document.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final title = json['title'];
    final created = json['created_at'];
    final updated = json['updated_at'];
    final sections = json['sections'];
    if (id is! String ||
        title is! String ||
        created is! int ||
        updated is! int ||
        sections is! List) {
      throw const FormatException(
          'Document requires id/title Strings, created_at/updated_at ints, sections List');
    }
    return Document(
      id: id,
      title: title,
      createdAtMs: created,
      updatedAtMs: updated,
      deletedAtMs: json['deleted_at'] as int?,
      syncStatus:
          SyncStatusWire.fromWire(json['sync_status'] as String? ?? 'local_only'),
      sections: sections
          .map((e) => Section.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      // Missing keys (Slice-1 documents) decode as empty lists.
      comments: ((json['comments'] as List?) ?? const <Object?>[])
          .map((e) => DocComment.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      suggestions: ((json['suggestions'] as List?) ?? const <Object?>[])
          .map((e) => Suggestion.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
    );
  }
}

/// Deterministic ID source. Tests use a sequential generator; the app may
/// supply any generator, but IDs must be unique per document store.
abstract class IdGenerator {
  String next(String prefix);
}

/// Yields `<prefix>-1`, `<prefix>-2`, … — fully deterministic.
class SequentialIdGenerator implements IdGenerator {
  int _counter = 0;

  @override
  String next(String prefix) => '$prefix-${++_counter}';
}
