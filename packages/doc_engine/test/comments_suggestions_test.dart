import 'dart:convert';

import 'package:doc_engine/doc_engine.dart';
import 'package:test/test.dart';

DocumentEditor makeEditor() {
  final ed = DocumentEditor.newDocument(
    ids: SequentialIdGenerator(),
    title: 'Review',
    nowMs: 1000,
  );
  final blockId = ed.document.allBlocks.first.id;
  ed.insertText(blockId, 0, 'The quick brown fox');
  return ed;
}

String firstBlock(DocumentEditor ed) => ed.document.allBlocks.first.id;

void main() {
  group('comments', () {
    test('add/list captures anchor, author, text, timestamp', () {
      final ed = makeEditor();
      final id = ed.addComment(
        blockId: firstBlock(ed),
        start: 4,
        end: 9,
        author: 'Ana',
        text: 'Check this word',
        createdAtMs: 5000,
      );
      final comments = ed.listComments();
      expect(comments, hasLength(1));
      final c = comments.single;
      expect(c.id, id);
      expect(c.blockId, firstBlock(ed));
      expect(c.start, 4);
      expect(c.end, 9);
      expect(c.author, 'Ana');
      expect(c.text, 'Check this word');
      expect(c.createdAtMs, 5000);
      expect(c.resolved, isFalse);
    });

    test('resolve hides from default list but keeps history', () {
      final ed = makeEditor();
      final id = ed.addComment(
        blockId: firstBlock(ed),
        start: 0,
        end: 3,
        author: 'Ben',
        text: 'note',
        createdAtMs: 1,
      );
      ed.resolveComment(id);
      expect(ed.listComments(), isEmpty);
      final all = ed.listComments(includeResolved: true);
      expect(all.single.resolved, isTrue);
      expect(() => ed.resolveComment('missing'), throwsArgumentError);
    });

    test('listComments filters by block; out-of-range anchors rejected', () {
      final ed = makeEditor();
      final second =
          ed.insertBlock(afterBlockId: firstBlock(ed));
      ed.insertText(second, 0, 'second');
      ed.addComment(
          blockId: firstBlock(ed),
          start: 0,
          end: 1,
          author: 'A',
          text: 'one',
          createdAtMs: 1);
      ed.addComment(
          blockId: second,
          start: 0,
          end: 1,
          author: 'A',
          text: 'two',
          createdAtMs: 2);
      expect(ed.listComments(blockId: second).single.text, 'two');
      expect(
          () => ed.addComment(
              blockId: firstBlock(ed),
              start: 0,
              end: 999,
              author: 'A',
              text: 'bad',
              createdAtMs: 3),
          throwsArgumentError);
    });

    test('comments survive a JSON round-trip', () {
      final ed = makeEditor();
      ed.addComment(
          blockId: firstBlock(ed),
          start: 10,
          end: 15,
          author: 'Ana',
          text: 'brown?',
          createdAtMs: 42);
      final decoded = Document.fromJson(
          (jsonDecode(ed.toJsonString()) as Map).cast<String, Object?>());
      expect(decoded.comments.single.text, 'brown?');
      expect(decoded.comments.single.start, 10);
    });
  });

  group('track changes (suggestion mode)', () {
    DocumentEditor suggesting() {
      final ed = makeEditor();
      var tick = 7000;
      ed.enableSuggestionMode(author: 'Ana', clockMs: () => tick++);
      return ed;
    }

    test('insertText records a suggestion and does not mutate text', () {
      final ed = suggesting();
      final blockId = firstBlock(ed);
      ed.insertText(blockId, 19, ' jumps');
      expect(ed.document.blockById(blockId)!.plainText, 'The quick brown fox');
      final s = ed.suggestions.single;
      expect(s.kind, SuggestionKind.insertion);
      expect(s.text, ' jumps');
      expect(s.start, 19);
      expect(s.author, 'Ana');
      expect(s.createdAtMs, 7000);
    });

    test('deleteRange records a deletion with a text snapshot', () {
      final ed = suggesting();
      ed.deleteRange(firstBlock(ed), 4, 10);
      expect(ed.document.allBlocks.first.plainText, 'The quick brown fox');
      final s = ed.suggestions.single;
      expect(s.kind, SuggestionKind.deletion);
      expect(s.text, 'quick ');
      expect(s.start, 4);
      expect(s.end, 10);
    });

    test('suggestion mode without provenance throws', () {
      final ed = makeEditor();
      ed.suggestionMode = true; // author/clock not configured
      expect(() => ed.insertText(firstBlock(ed), 0, 'x'), throwsStateError);
    });

    test('accept applies an insertion; reject discards a deletion', () {
      final ed = suggesting();
      final blockId = firstBlock(ed);
      ed.insertText(blockId, 19, ' jumps');
      ed.deleteRange(blockId, 0, 4);
      final insertion = ed.suggestions[0];
      final deletion = ed.suggestions[1];

      ed.acceptSuggestion(insertion.id);
      expect(ed.document.blockById(blockId)!.plainText,
          'The quick brown fox jumps');
      expect(ed.suggestions, hasLength(1));

      ed.rejectSuggestion(deletion.id);
      expect(ed.document.blockById(blockId)!.plainText,
          'The quick brown fox jumps');
      expect(ed.suggestions, isEmpty);
      expect(() => ed.acceptSuggestion('missing'), throwsArgumentError);
    });

    test('accepting a deletion removes the recorded range', () {
      final ed = suggesting();
      ed.deleteRange(firstBlock(ed), 4, 10);
      ed.acceptSuggestion(ed.suggestions.single.id);
      expect(ed.document.allBlocks.first.plainText, 'The brown fox');
    });

    test('accept-all applies in order; reject-all clears', () {
      final ed = suggesting();
      final blockId = firstBlock(ed);
      ed.insertText(blockId, 19, ' A');
      ed.insertText(blockId, 19, ' B');
      ed.acceptAllSuggestions();
      // Both were recorded at offset 19; applied in creation order.
      expect(ed.document.blockById(blockId)!.plainText,
          'The quick brown fox B A');
      expect(ed.suggestions, isEmpty);

      ed.deleteRange(blockId, 0, 3);
      ed.deleteRange(blockId, 0, 3);
      ed.rejectAllSuggestions();
      expect(ed.document.blockById(blockId)!.plainText,
          'The quick brown fox B A');
      expect(ed.suggestions, isEmpty);
    });

    test('turning suggestion mode off restores direct editing', () {
      final ed = suggesting();
      ed.disableSuggestionMode();
      ed.insertText(firstBlock(ed), 0, '>> ');
      expect(ed.document.allBlocks.first.plainText, '>> The quick brown fox');
      expect(ed.suggestions, isEmpty);
    });

    test('pending suggestions survive a JSON round-trip', () {
      final ed = suggesting();
      ed.insertText(firstBlock(ed), 0, 'New ');
      final decoded = Document.fromJson(
          (jsonDecode(ed.toJsonString()) as Map).cast<String, Object?>());
      expect(decoded.suggestions.single.kind, SuggestionKind.insertion);
      expect(decoded.suggestions.single.text, 'New ');
      expect(decoded.suggestions.single.author, 'Ana');
    });
  });
}
