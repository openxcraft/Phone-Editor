import 'dart:convert';

import 'package:doc_engine/doc_engine.dart';
import 'package:test/test.dart';

DocumentEditor makeEditor() => DocumentEditor.newDocument(
      ids: SequentialIdGenerator(),
      title: 'Notes',
      nowMs: 1000,
    );

void main() {
  group('operations', () {
    test('insertText builds plain text and merges runs', () {
      final ed = makeEditor();
      final blockId = ed.document.allBlocks.first.id;
      ed.insertText(blockId, 0, 'Hello');
      ed.insertText(blockId, 5, ' world');
      final block = ed.document.blockById(blockId)!;
      expect(block.plainText, 'Hello world');
      expect(block.inlines, hasLength(1)); // same marks -> merged
    });

    test('applyMark splits runs; deleteRange removes across runs', () {
      final ed = makeEditor();
      final blockId = ed.document.allBlocks.first.id;
      ed.insertText(blockId, 0, 'Hello world');
      ed.applyMark(blockId, 0, 5, Mark.bold, true);
      var block = ed.document.blockById(blockId)!;
      expect(block.inlines.map((n) => n.text), ['Hello', ' world']);
      expect(block.inlines.first.marks, {Mark.bold});

      ed.deleteRange(blockId, 3, 8);
      block = ed.document.blockById(blockId)!;
      expect(block.plainText, 'Helrld');
    });

    test('applyMark can clear a mark and re-merges runs', () {
      final ed = makeEditor();
      final blockId = ed.document.allBlocks.first.id;
      ed.insertText(blockId, 0, 'abcdef');
      ed.applyMark(blockId, 0, 6, Mark.italic, true);
      ed.applyMark(blockId, 0, 6, Mark.italic, false);
      final block = ed.document.blockById(blockId)!;
      expect(block.inlines, hasLength(1));
      expect(block.inlines.single.marks, isEmpty);
    });

    test('offsets are rune-based, not UTF-16 code units', () {
      final ed = makeEditor();
      final blockId = ed.document.allBlocks.first.id;
      ed.insertText(blockId, 0, 'a😀b');
      ed.deleteRange(blockId, 1, 2); // the emoji is one rune
      expect(ed.document.blockById(blockId)!.plainText, 'ab');
    });

    test('insertBlock / setBlockType / deleteBlock', () {
      final ed = makeEditor();
      final first = ed.document.allBlocks.first.id;
      final second = ed.insertBlock(afterBlockId: first);
      ed.insertText(second, 0, 'Title text');
      ed.setBlockType(second, BlockType.heading1);
      expect(ed.document.allBlocks.map((b) => b.type),
          [BlockType.paragraph, BlockType.heading1]);

      ed.deleteBlock(second);
      expect(ed.document.allBlocks, hasLength(1));
      // Deleting the last block of a section leaves an empty paragraph.
      ed.deleteBlock(first);
      expect(ed.document.allBlocks, hasLength(1));
      expect(ed.document.allBlocks.single.plainText, '');
    });

    test('operations on a missing block throw ArgumentError', () {
      final ed = makeEditor();
      expect(() => ed.insertText('nope', 0, 'x'), throwsArgumentError);
    });
  });

  group('undo/redo', () {
    test('undo restores prior text; redo replays it', () {
      final ed = makeEditor();
      final blockId = ed.document.allBlocks.first.id;
      ed.insertText(blockId, 0, 'one');
      ed.insertText(blockId, 3, ' two');
      expect(ed.undo(), isTrue);
      expect(ed.document.blockById(blockId)!.plainText, 'one');
      expect(ed.undo(), isTrue);
      expect(ed.document.blockById(blockId)!.plainText, '');
      expect(ed.undo(), isFalse);
      expect(ed.redo(), isTrue);
      expect(ed.document.blockById(blockId)!.plainText, 'one');
    });

    test('a new edit clears the redo stack', () {
      final ed = makeEditor();
      final blockId = ed.document.allBlocks.first.id;
      ed.insertText(blockId, 0, 'one');
      ed.undo();
      ed.insertText(blockId, 0, 'other');
      expect(ed.canRedo, isFalse);
    });
  });

  group('find/replace', () {
    test('replaces across blocks and counts; no-op creates no undo step', () {
      final ed = makeEditor();
      final first = ed.document.allBlocks.first.id;
      ed.insertText(first, 0, 'cat and cat');
      final second = ed.insertBlock(afterBlockId: first);
      ed.insertText(second, 0, 'Cat? cat.');

      expect(ed.findReplace('cat', 'dog'), 3); // case-sensitive
      expect(ed.document.allBlocks.map((b) => b.plainText),
          ['dog and dog', 'Cat? dog.']);

      final undoDepthBefore = ed.canUndo;
      expect(ed.findReplace('zebra', 'x'), 0);
      expect(ed.canUndo, undoDepthBefore);
    });

    test('case-insensitive replace', () {
      final ed = makeEditor();
      final first = ed.document.allBlocks.first.id;
      ed.insertText(first, 0, 'Cat cat CAT');
      expect(
          ed.findReplace('cat', 'dog', caseSensitive: false), 3);
      expect(ed.document.blockById(first)!.plainText, 'dog dog dog');
    });
  });

  group('serialization', () {
    test('deterministic: same tree encodes identically, and round-trips', () {
      final ed = makeEditor();
      final first = ed.document.allBlocks.first.id;
      ed.insertText(first, 0, 'Hello world');
      ed.applyMark(first, 0, 5, Mark.bold, true);
      ed.applyMark(first, 0, 5, Mark.italic, true);

      final json1 = ed.toJsonString();
      final decoded = Document.fromJson(
          (jsonDecode(json1) as Map).cast<String, Object?>());
      expect(decoded.toJson().toString(), ed.document.toJson().toString());
      // Marks are sorted in output regardless of insertion order.
      expect(json1.contains('"marks":["bold","italic"]'), isTrue);
      // Encoding the decoded copy yields the identical string.
      final ed2 = DocumentEditor(decoded, ids: SequentialIdGenerator());
      expect(ed2.toJsonString(), json1);
    });

    test('malformed JSON is rejected', () {
      expect(
          () => Document.fromJson(<String, Object?>{'id': 'x'}),
          throwsFormatException);
    });
  });
}
