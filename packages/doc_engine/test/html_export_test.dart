import 'package:doc_engine/doc_engine.dart';
import 'package:test/test.dart';

void main() {
  test('golden: semantic structure, marks, bullet grouping', () {
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
    ed.insertText(b3, 0, 'one');
    final b4 = ed.insertBlock(afterBlockId: b3, type: BlockType.bullet);
    ed.insertText(b4, 0, 'two');

    final b5 = ed.insertBlock(afterBlockId: b4, type: BlockType.quote);
    ed.insertText(b5, 0, 'note');

    const expected = '<!DOCTYPE html>\n'
        '<html>\n'
        '<head>\n'
        '<meta charset="utf-8">\n'
        '<title>Spec</title>\n'
        '</head>\n'
        '<body>\n'
        '<h1>Intro</h1>\n'
        '<p><strong>Hello</strong> <em>world</em></p>\n'
        '<ul>\n'
        '<li>one</li>\n'
        '<li>two</li>\n'
        '</ul>\n'
        '<blockquote><p>note</p></blockquote>\n'
        '</body>\n'
        '</html>\n';
    expect(const HtmlExporter().export(ed.document), expected);
  });

  test('text and attribute values are escaped', () {
    final ed = DocumentEditor.newDocument(
        ids: SequentialIdGenerator(), title: 'A & B', nowMs: 1);
    final b1 = ed.document.allBlocks.first.id;
    ed.insertText(b1, 0, '1 < 2 & "quoted"');
    ed.insertImageBlock(assetId: 'x"y', alt: 'a "b" <c>');
    final html = const HtmlExporter().export(ed.document);
    expect(html, contains('<title>A &amp; B</title>'));
    expect(html, contains('1 &lt; 2 &amp; "quoted"'));
    expect(html, contains('alt="a &quot;b&quot; &lt;c&gt;"'));
    expect(html, contains('data-image-id="x&quot;y"'));
  });

  test('table exports as table/tr/td with inline marks', () {
    final ed = DocumentEditor.newDocument(
        ids: SequentialIdGenerator(), title: '', nowMs: 1);
    final tableId = ed.insertTableBlock(rows: 2, cols: 2);
    ed.setTableCellText(tableId, 0, 0, 'Name');
    ed.setTableCellText(tableId, 0, 1, 'Value', marks: {Mark.bold});
    ed.setTableCellText(tableId, 1, 0, 'alpha');
    ed.setTableCellText(tableId, 1, 1, '3');
    final html = const HtmlExporter().export(ed.document);
    expect(
        html,
        contains('<table><tbody>'
            '<tr><td>Name</td><td><strong>Value</strong></td></tr>'
            '<tr><td>alpha</td><td>3</td></tr>'
            '</tbody></table>'));
  });

  test('image exports alt text and asset metadata, no src', () {
    final ed = DocumentEditor.newDocument(
        ids: SequentialIdGenerator(), title: '', nowMs: 1);
    ed.insertImageBlock(
        assetId: 'asset-9', alt: 'Pipeline diagram', byteLength: 100, hash: 'h1');
    final html = const HtmlExporter().export(ed.document);
    expect(
        html,
        contains('<img alt="Pipeline diagram" data-image-id="asset-9" '
            'data-byte-length="100" data-hash="h1">'));
    expect(html, isNot(contains('src=')));
  });

  test('export is deterministic; combined marks nest in fixed order', () {
    final ed = DocumentEditor.newDocument(
        ids: SequentialIdGenerator(), title: '', nowMs: 1);
    final b1 = ed.document.allBlocks.first.id;
    ed.insertText(b1, 0, 'x');
    ed.applyMark(b1, 0, 1, Mark.code, true);
    ed.applyMark(b1, 0, 1, Mark.bold, true);
    final a = const HtmlExporter().export(ed.document);
    expect(a, const HtmlExporter().export(ed.document));
    expect(a, contains('<p><strong><code>x</code></strong></p>'));
  });
}
