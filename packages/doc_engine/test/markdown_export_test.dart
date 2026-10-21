import 'package:doc_engine/doc_engine.dart';
import 'package:test/test.dart';

void main() {
  test('golden: title, heading, styled paragraph, bullet, quote', () {
    final ids = SequentialIdGenerator();
    final ed = DocumentEditor.newDocument(ids: ids, title: 'Spec', nowMs: 1);
    final b1 = ed.document.allBlocks.first.id;
    ed.setBlockType(b1, BlockType.heading1);
    ed.insertText(b1, 0, 'Intro');

    final b2 = ed.insertBlock(afterBlockId: b1);
    ed.insertText(b2, 0, 'Hello world');
    ed.applyMark(b2, 0, 5, Mark.bold, true);
    ed.applyMark(b2, 6, 11, Mark.italic, true);

    final b3 = ed.insertBlock(afterBlockId: b2, type: BlockType.bullet);
    ed.insertText(b3, 0, 'item *one*');

    final b4 = ed.insertBlock(afterBlockId: b3, type: BlockType.quote);
    ed.insertText(b4, 0, 'run it');
    ed.applyMark(b4, 0, 6, Mark.code, true);

    const expected = '# Spec\n'
        '\n'
        '# Intro\n'
        '\n'
        '**Hello** *world*\n'
        '\n'
        '- item \\*one\\*\n'
        '\n'
        '> `run it`\n';
    expect(const MarkdownExporter().export(ed.document), expected);
  });

  test('export is deterministic and ends with exactly one newline', () {
    final ed = DocumentEditor.newDocument(
        ids: SequentialIdGenerator(), title: '', nowMs: 1);
    final b1 = ed.document.allBlocks.first.id;
    ed.insertText(b1, 0, 'plain');
    final a = const MarkdownExporter().export(ed.document);
    final b = const MarkdownExporter().export(ed.document);
    expect(a, b);
    expect(a, 'plain\n');
  });

  test('bold+italic combine; underline is a documented loss', () {
    final ed = DocumentEditor.newDocument(
        ids: SequentialIdGenerator(), title: '', nowMs: 1);
    final b1 = ed.document.allBlocks.first.id;
    ed.insertText(b1, 0, 'both under');
    ed.applyMark(b1, 0, 4, Mark.bold, true);
    ed.applyMark(b1, 0, 4, Mark.italic, true);
    ed.applyMark(b1, 5, 10, Mark.underline, true);
    expect(const MarkdownExporter().export(ed.document), '***both*** under\n');
  });
}
