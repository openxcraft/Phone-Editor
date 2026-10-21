import 'dart:convert';

import 'model.dart';

/// Applies operations to a [Document] and owns undo/redo.
///
/// Slice-1 undo uses deep snapshots taken before each operation. This is
/// deliberately simple and correct for single-device editing; ENGINES.md
/// schedules op-inverse / CRDT history for the collaboration phase, behind
/// this same public interface.
///
/// Offsets are rune-based positions in a block's plain text, clamped to
/// the block length. Every mutating method records one undo step and, if
/// a clock is supplied, bumps `updatedAtMs` and marks the document
/// `pending` when it was previously `synced`.
class DocumentEditor {
  DocumentEditor(this.document, {required IdGenerator ids, int Function()? clockMs})
      : _ids = ids,
        _clockMs = clockMs;

  final Document document;
  final IdGenerator _ids;
  final int Function()? _clockMs;

  final List<Document> _undoStack = <Document>[];
  final List<Document> _redoStack = <Document>[];

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  // --- Suggestion (track-changes) mode -------------------------------------
  //
  // When [suggestionMode] is on, insertText/deleteRange record a pending
  // [Suggestion] on the document instead of mutating block text. Both an
  // author and a caller-supplied clock are required, so recorded
  // suggestions carry provenance without this class reading a wall clock.

  bool suggestionMode = false;
  String? suggestionAuthor;
  int Function()? suggestionClockMs;

  /// Turns suggestion mode on with the given provenance.
  void enableSuggestionMode({
    required String author,
    required int Function() clockMs,
  }) {
    suggestionMode = true;
    suggestionAuthor = author;
    suggestionClockMs = clockMs;
  }

  void disableSuggestionMode() {
    suggestionMode = false;
    suggestionAuthor = null;
    suggestionClockMs = null;
  }

  (String, int) _suggestionProvenance() {
    final author = suggestionAuthor;
    final clock = suggestionClockMs;
    if (author == null || clock == null) {
      throw StateError(
          'Suggestion mode requires enableSuggestionMode(author:, clockMs:)');
    }
    return (author, clock());
  }

  /// Pending suggestions, in creation order (unmodifiable view).
  List<Suggestion> get suggestions =>
      List<Suggestion>.unmodifiable(document.suggestions);

  /// Creates a document with one section and one empty paragraph.
  factory DocumentEditor.newDocument({
    required IdGenerator ids,
    required String title,
    required int nowMs,
    int Function()? clockMs,
  }) {
    final doc = Document(
      id: ids.next('doc'),
      title: title,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      sections: <Section>[
        Section(
          id: ids.next('sec'),
          blocks: <Block>[
            Block(id: ids.next('blk'), type: BlockType.paragraph),
          ],
        ),
      ],
    );
    return DocumentEditor(doc, ids: ids, clockMs: clockMs);
  }

  void _beginOp() {
    _undoStack.add(document.copy());
    _redoStack.clear();
  }

  void _endOp() {
    final now = _clockMs?.call();
    if (now != null) {
      document.updatedAtMs = now;
      if (document.syncStatus == SyncStatus.synced) {
        document.syncStatus = SyncStatus.pending;
      }
    }
  }

  Block _requireBlock(String blockId) {
    final block = document.blockById(blockId);
    if (block == null) {
      throw ArgumentError.value(blockId, 'blockId', 'Block not found');
    }
    return block;
  }

  /// Text operations apply to text-bearing blocks only; table and image
  /// blocks reject them so cell/asset content can never be corrupted by
  /// an offset computed against [Block.plainText].
  Block _requireTextBlock(String blockId) {
    final block = _requireBlock(blockId);
    if (block.type == BlockType.table || block.type == BlockType.image) {
      throw StateError(
          'Text operations do not apply to ${block.type.name} blocks');
    }
    return block;
  }

  // --- Inline run helpers -------------------------------------------------

  /// Splits [block]'s runs so that a run boundary exists at [offset].
  /// Returns the run index that starts at [offset].
  static int _splitAt(Block block, int offset) {
    var pos = 0;
    for (var i = 0; i < block.inlines.length; i++) {
      final run = block.inlines[i];
      final len = run.text.runes.length;
      if (offset == pos) return i;
      if (offset < pos + len) {
        final cut = offset - pos;
        final runes = run.text.runes.toList();
        final left = InlineNode(String.fromCharCodes(runes.sublist(0, cut)), run.marks);
        final right = InlineNode(String.fromCharCodes(runes.sublist(cut)), run.marks);
        block.inlines.replaceRange(i, i + 1, <InlineNode>[left, right]);
        return i + 1;
      }
      pos += len;
    }
    return block.inlines.length; // offset == end of block
  }

  /// Merges adjacent runs with equal marks and removes empty runs,
  /// keeping exactly one empty run for an empty block.
  static void _normalize(Block block) {
    final out = <InlineNode>[];
    for (final run in block.inlines) {
      if (run.text.isEmpty) continue;
      if (out.isNotEmpty && _sameMarks(out.last.marks, run.marks)) {
        out.last.text += run.text;
      } else {
        out.add(run.copy());
      }
    }
    block.inlines = out.isEmpty ? <InlineNode>[InlineNode('')] : out;
  }

  static bool _sameMarks(Set<Mark> a, Set<Mark> b) =>
      a.length == b.length && a.containsAll(b);

  static int _clamp(int value, int max) =>
      value < 0 ? 0 : (value > max ? max : value);

  // --- Operations -----------------------------------------------------------

  /// Marks that an insertion at rune [offset] would inherit.
  static Set<Mark> _marksAt(Block block, int offset) {
    var pos = 0;
    Set<Mark> previous = const <Mark>{};
    for (final run in block.inlines) {
      final len = run.text.runes.length;
      if (offset <= pos + len) {
        // Inside a run, or at its end boundary: inherit that run. At a
        // boundary between runs the previous run wins once we pass it.
        return offset == pos && pos > 0 ? previous : run.marks;
      }
      previous = run.marks;
      pos += len;
    }
    return block.inlines.isNotEmpty ? block.inlines.last.marks : const <Mark>{};
  }

  /// Inserts [text] with explicit [marks] at rune [offset]; no undo step,
  /// no timestamp bump (callers own both).
  static void _insertRun(Block block, int offset, String text, Set<Mark> marks) {
    final idx = _splitAt(block, offset);
    if (idx >= block.inlines.length) {
      block.inlines.add(InlineNode(text, marks));
    } else {
      block.inlines.insert(idx, InlineNode(text, marks));
    }
    _normalize(block);
  }

  /// Deletes runes in `[s, e)`; no undo step, no timestamp bump.
  static void _deleteRun(Block block, int s, int e) {
    // Split at the start first: splitting at the end afterwards cannot
    // shift the start index, whereas the reverse order invalidates the
    // already-computed end index.
    final startIdx = _splitAt(block, s);
    final endIdx = _splitAt(block, e);
    block.inlines.removeRange(startIdx, endIdx);
    _normalize(block);
  }

  /// Inserts [text] at rune [offset] in the block, inheriting the marks of
  /// the run at the insertion point (or the previous run at a boundary).
  ///
  /// In suggestion mode this records an insertion [Suggestion] instead of
  /// mutating the block.
  void insertText(String blockId, int offset, String text) {
    if (text.isEmpty) return;
    final block = _requireTextBlock(blockId);
    final len = block.plainText.runes.length;
    final at = _clamp(offset, len);
    if (suggestionMode) {
      final (author, nowMs) = _suggestionProvenance();
      _beginOp();
      document.suggestions.add(Suggestion(
        id: _ids.next('sug'),
        kind: SuggestionKind.insertion,
        blockId: blockId,
        start: at,
        end: at + text.runes.length,
        text: text,
        marks: _marksAt(block, at),
        author: author,
        createdAtMs: nowMs,
      ));
      _endOp();
      return;
    }
    _beginOp();
    _insertRun(block, at, text, _marksAt(block, at));
    _endOp();
  }

  /// Deletes runes in `[start, end)` in the block.
  ///
  /// In suggestion mode this records a deletion [Suggestion] (with a
  /// plain-text snapshot of the range) instead of mutating the block.
  void deleteRange(String blockId, int start, int end) {
    final block = _requireTextBlock(blockId);
    final len = block.plainText.runes.length;
    final s = _clamp(start, len);
    final e = _clamp(end, len);
    if (e <= s) return;
    if (suggestionMode) {
      final (author, nowMs) = _suggestionProvenance();
      final runes = block.plainText.runes.toList();
      _beginOp();
      document.suggestions.add(Suggestion(
        id: _ids.next('sug'),
        kind: SuggestionKind.deletion,
        blockId: blockId,
        start: s,
        end: e,
        text: String.fromCharCodes(runes.sublist(s, e)),
        author: author,
        createdAtMs: nowMs,
      ));
      _endOp();
      return;
    }
    _beginOp();
    _deleteRun(block, s, e);
    _endOp();
  }

  /// Sets or clears [mark] on runes in `[start, end)`.
  void applyMark(String blockId, int start, int end, Mark mark, bool enabled) {
    final block = _requireTextBlock(blockId);
    final len = block.plainText.runes.length;
    final s = _clamp(start, len);
    final e = _clamp(end, len);
    if (e <= s) return;
    _beginOp();
    // Start split first, for the same index-stability reason as deleteRange.
    final startIdx = _splitAt(block, s);
    final endIdx = _splitAt(block, e);
    for (var i = startIdx; i < endIdx; i++) {
      final run = block.inlines[i];
      final marks = Set<Mark>.of(run.marks);
      if (enabled) {
        marks.add(mark);
      } else {
        marks.remove(mark);
      }
      block.inlines[i] = InlineNode(run.text, marks);
    }
    _normalize(block);
    _endOp();
  }

  /// Inserts a new block of [type] after [afterBlockId] (or at the end of
  /// the document when null) and returns its ID.
  String insertBlock({String? afterBlockId, BlockType type = BlockType.paragraph}) {
    if (type == BlockType.table || type == BlockType.image) {
      throw ArgumentError.value(
          type, 'type', 'Use insertTableBlock/insertImageBlock');
    }
    return _insertBlockObject(
      Block(id: _ids.next('blk'), type: type),
      afterBlockId: afterBlockId,
    );
  }

  /// Shared insertion path for all block kinds: validates the anchor,
  /// records one undo step, inserts after the anchor (or at the end).
  String _insertBlockObject(Block newBlock, {String? afterBlockId}) {
    if (afterBlockId != null && document.blockById(afterBlockId) == null) {
      throw ArgumentError.value(afterBlockId, 'afterBlockId', 'Block not found');
    }
    _beginOp();
    if (afterBlockId == null) {
      document.sections.last.blocks.add(newBlock);
    } else {
      for (final section in document.sections) {
        final idx = section.blocks.indexWhere((b) => b.id == afterBlockId);
        if (idx >= 0) {
          section.blocks.insert(idx + 1, newBlock);
          break;
        }
      }
    }
    _endOp();
    return newBlock.id;
  }

  /// Inserts a table block with [rows] x [cols] empty cells and returns
  /// its ID. Cell content is set with [setTableCellText].
  String insertTableBlock({String? afterBlockId, int rows = 2, int cols = 2}) {
    if (rows < 1 || cols < 1) {
      throw ArgumentError('Table needs at least 1 row and 1 column');
    }
    return _insertBlockObject(
      Block(
        id: _ids.next('blk'),
        type: BlockType.table,
        tableRows: List.generate(
          rows,
          (_) => List.generate(cols, (_) => TableCell()),
        ),
      ),
      afterBlockId: afterBlockId,
    );
  }

  /// Inserts an image block carrying metadata only (no binary handling)
  /// and returns its ID.
  String insertImageBlock({
    String? afterBlockId,
    required String assetId,
    String alt = '',
    int? byteLength,
    String? hash,
  }) {
    return _insertBlockObject(
      Block(
        id: _ids.next('blk'),
        type: BlockType.image,
        imageAssetId: assetId,
        imageAlt: alt,
        imageByteLength: byteLength,
        imageHash: hash,
      ),
      afterBlockId: afterBlockId,
    );
  }

  Block _requireTable(String blockId) {
    final block = _requireBlock(blockId);
    if (block.type != BlockType.table || block.tableRows == null) {
      throw StateError('Block $blockId is not a table');
    }
    return block;
  }

  /// Replaces one table cell's content with a single run.
  void setTableCellText(String blockId, int row, int col, String text,
      {Set<Mark> marks = const {}}) {
    final block = _requireTable(blockId);
    final rows = block.tableRows!;
    if (row < 0 || row >= rows.length || col < 0 || col >= rows[row].length) {
      throw RangeError('Cell ($row, $col) outside table bounds');
    }
    _beginOp();
    rows[row][col].inlines = <InlineNode>[InlineNode(text, marks)];
    _endOp();
  }

  /// Plain text of one table cell.
  String tableCellText(String blockId, int row, int col) {
    final block = _requireTable(blockId);
    return block.tableRows![row][col].plainText;
  }

  /// Changes a block's type (e.g. paragraph → heading1).
  void setBlockType(String blockId, BlockType type) {
    final block = _requireBlock(blockId);
    _beginOp();
    block.type = type;
    _endOp();
  }

  /// Removes a block. A section is never left block-less: deleting its last
  /// block replaces it with an empty paragraph (with a fresh ID).
  void deleteBlock(String blockId) {
    _beginOp();
    for (final section in document.sections) {
      final idx = section.blocks.indexWhere((b) => b.id == blockId);
      if (idx >= 0) {
        section.blocks.removeAt(idx);
        if (section.blocks.isEmpty) {
          section.blocks.add(
              Block(id: _ids.next('blk'), type: BlockType.paragraph));
        }
        _endOp();
        return;
      }
    }
    throw ArgumentError.value(blockId, 'blockId', 'Block not found');
  }

  /// Case-sensitive (by default) find/replace across all blocks.
  /// Returns the number of replacements. One undo step total.
  int findReplace(String query, String replacement, {bool caseSensitive = true}) {
    if (query.isEmpty) return 0;
    var total = 0;
    _beginOp();
    for (final block in document.allBlocks) {
      final text = block.plainText;
      final haystack = caseSensitive ? text : text.toLowerCase();
      final needle = caseSensitive ? query : query.toLowerCase();
      var count = 0;
      var from = 0;
      while (true) {
        final at = haystack.indexOf(needle, from);
        if (at < 0) break;
        count++;
        from = at + needle.length;
      }
      if (count == 0) continue;
      total += count;
      // Rebuild as a single run preserving the marks of the first run.
      // Slice-1 simplification, documented: find/replace flattens marks
      // within an affected block. Phase 1 replaces this with a
      // mark-preserving splice.
      final marks =
          block.inlines.isNotEmpty ? block.inlines.first.marks : const <Mark>{};
      final newText = caseSensitive
          ? text.replaceAll(query, replacement)
          : _replaceAllCaseInsensitive(text, query, replacement);
      block.inlines = <InlineNode>[InlineNode(newText, marks)];
    }
    if (total == 0) {
      _undoStack.removeLast(); // no-op: no undo step, no timestamp bump
      return 0;
    }
    _endOp();
    return total;
  }

  static String _replaceAllCaseInsensitive(
      String text, String query, String replacement) {
    final lower = text.toLowerCase();
    final needle = query.toLowerCase();
    final buf = StringBuffer();
    var from = 0;
    while (true) {
      final at = lower.indexOf(needle, from);
      if (at < 0) {
        buf.write(text.substring(from));
        return buf.toString();
      }
      buf.write(text.substring(from, at));
      buf.write(replacement);
      from = at + needle.length;
    }
  }

  // --- Comments ---------------------------------------------------------------

  /// Adds a comment anchored to rune range `[start, end)` of a block and
  /// returns its ID. The range must lie within the block's plain text.
  String addComment({
    required String blockId,
    required int start,
    required int end,
    required String author,
    required String text,
    required int createdAtMs,
  }) {
    final block = _requireTextBlock(blockId);
    final len = block.plainText.runes.length;
    if (start < 0 || end < start || end > len) {
      throw ArgumentError(
          'Comment range [$start, $end) outside block length $len');
    }
    _beginOp();
    final comment = DocComment(
      id: _ids.next('cmt'),
      blockId: blockId,
      start: start,
      end: end,
      author: author,
      text: text,
      createdAtMs: createdAtMs,
    );
    document.comments.add(comment);
    _endOp();
    return comment.id;
  }

  /// Comments in creation order; optionally only one block's, and
  /// optionally including resolved ones (default: open only).
  List<DocComment> listComments(
      {String? blockId, bool includeResolved = false}) {
    return List<DocComment>.unmodifiable(document.comments.where((c) =>
        (blockId == null || c.blockId == blockId) &&
        (includeResolved || !c.resolved)));
  }

  /// Marks a comment resolved. Unknown IDs throw [ArgumentError].
  void resolveComment(String commentId) {
    final idx = document.comments.indexWhere((c) => c.id == commentId);
    if (idx < 0) {
      throw ArgumentError.value(commentId, 'commentId', 'Comment not found');
    }
    _beginOp();
    document.comments[idx].resolved = true;
    _endOp();
  }

  // --- Track changes: resolving suggestions -----------------------------------

  Suggestion _requireSuggestion(String suggestionId) {
    for (final s in document.suggestions) {
      if (s.id == suggestionId) return s;
    }
    throw ArgumentError.value(
        suggestionId, 'suggestionId', 'Suggestion not found');
  }

  /// Applies one pending suggestion to the text and removes it from the
  /// pending list. Ranges are as-recorded, clamped to current text (see
  /// the [Suggestion] doc for the Phase-1 anchor simplification).
  void acceptSuggestion(String suggestionId) {
    final suggestion = _requireSuggestion(suggestionId);
    final block = _requireTextBlock(suggestion.blockId);
    _beginOp();
    _applySuggestion(block, suggestion);
    document.suggestions.remove(suggestion);
    _endOp();
  }

  /// Discards one pending suggestion without changing the text.
  void rejectSuggestion(String suggestionId) {
    final suggestion = _requireSuggestion(suggestionId);
    _beginOp();
    document.suggestions.remove(suggestion);
    _endOp();
  }

  /// Applies all pending suggestions in creation order, as one undo step.
  void acceptAllSuggestions() {
    if (document.suggestions.isEmpty) return;
    _beginOp();
    for (final suggestion in List<Suggestion>.of(document.suggestions)) {
      _applySuggestion(_requireTextBlock(suggestion.blockId), suggestion);
    }
    document.suggestions.clear();
    _endOp();
  }

  /// Discards all pending suggestions, as one undo step.
  void rejectAllSuggestions() {
    if (document.suggestions.isEmpty) return;
    _beginOp();
    document.suggestions.clear();
    _endOp();
  }

  void _applySuggestion(Block block, Suggestion suggestion) {
    final len = block.plainText.runes.length;
    switch (suggestion.kind) {
      case SuggestionKind.insertion:
        if (suggestion.text.isNotEmpty) {
          _insertRun(block, _clamp(suggestion.start, len), suggestion.text,
              suggestion.marks);
        }
      case SuggestionKind.deletion:
        final s = _clamp(suggestion.start, len);
        final e = _clamp(suggestion.end, len);
        if (e > s) _deleteRun(block, s, e);
    }
  }

  // --- Undo / redo ----------------------------------------------------------

  bool undo() {
    if (_undoStack.isEmpty) return false;
    _redoStack.add(document.copy());
    _restore(_undoStack.removeLast());
    return true;
  }

  bool redo() {
    if (_redoStack.isEmpty) return false;
    _undoStack.add(document.copy());
    _restore(_redoStack.removeLast());
    return true;
  }

  void _restore(Document snapshot) {
    document.title = snapshot.title;
    document.sections = snapshot.sections.map((s) => s.copy()).toList();
    document.updatedAtMs = snapshot.updatedAtMs;
    document.deletedAtMs = snapshot.deletedAtMs;
    document.syncStatus = snapshot.syncStatus;
    document.comments = snapshot.comments.map((c) => c.copy()).toList();
    document.suggestions =
        snapshot.suggestions.map((s) => s.copy()).toList();
  }

  // --- Serialization --------------------------------------------------------

  /// Deterministic JSON string for this document (see model.dart).
  String toJsonString() => jsonEncode(document.toJson());
}
