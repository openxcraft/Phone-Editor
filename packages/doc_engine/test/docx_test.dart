import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:doc_engine/doc_engine.dart';
import 'package:test/test.dart';

/// Builds the shared round-trip fixture: title, heading, styled
/// paragraph, bullets, quote, and a table.
DocumentEditor fixture() {
  final ids = SequentialIdGenerator();
  final ed = DocumentEditor.newDocument(ids: ids, title: 'Report', nowMs: 1000);
  final b1 = ed.document.allBlocks.first.id;
  ed.setBlockType(b1, BlockType.heading1);
  ed.insertText(b1, 0, 'Overview');

  final b2 = ed.insertBlock(afterBlockId: b1);
  ed.insertText(b2, 0, 'Hello bold and italic and code');
  ed.applyMark(b2, 6, 10, Mark.bold, true);
  ed.applyMark(b2, 15, 21, Mark.italic, true);
  ed.applyMark(b2, 26, 30, Mark.code, true);

  final b3 = ed.insertBlock(afterBlockId: b2, type: BlockType.bullet);
  ed.insertText(b3, 0, 'first');
  final b4 = ed.insertBlock(afterBlockId: b3, type: BlockType.bullet);
  ed.insertText(b4, 0, 'second');

  final b5 = ed.insertBlock(afterBlockId: b4, type: BlockType.quote);
  ed.insertText(b5, 0, 'quoted');

  final tableId = ed.insertTableBlock(afterBlockId: b5, rows: 2, cols: 2);
  ed.setTableCellText(tableId, 0, 0, 'Name');
  ed.setTableCellText(tableId, 0, 1, 'Value');
  ed.setTableCellText(tableId, 1, 0, 'alpha');
  ed.setTableCellText(tableId, 1, 1, 'beta');
  return ed;
}

String part(List<int> bytes, String name) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final file = archive.findFile(name);
  if (file == null) fail('Missing DOCX part: $name');
  return utf8.decode(file.content);
}

void main() {
  group('docx export', () {
    test('produces a real ZIP with the required OOXML parts', () {
      final bytes = const DocxExporter().export(fixture().document);
      // ZIP local file header magic.
      expect(bytes.sublist(0, 2), [0x50, 0x4B]);
      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.map((f) => f.name).toSet();
      expect(
          names,
          containsAll(<String>[
            '[Content_Types].xml',
            '_rels/.rels',
            'word/document.xml',
            'word/styles.xml',
            'word/numbering.xml',
            'word/_rels/document.xml.rels',
            'docProps/core.xml',
          ]));
      final documentXml = part(bytes, 'word/document.xml');
      expect(documentXml, contains('<w:pStyle w:val="Heading1"/>'));
      expect(documentXml, contains('<w:tbl>'));
      expect(documentXml, contains('<w:b/>'));
      expect(documentXml, contains('Courier New'));
      expect(part(bytes, 'docProps/core.xml'), contains('<dc:title>Report</dc:title>'));
    });

    test('export is deterministic: same document, identical bytes', () {
      final doc = fixture().document;
      final a = const DocxExporter().export(doc);
      final b = const DocxExporter().export(doc);
      expect(b, a);
    });

    test('special characters are XML-escaped', () {
      final ed = DocumentEditor.newDocument(
          ids: SequentialIdGenerator(), title: '', nowMs: 1);
      final b1 = ed.document.allBlocks.first.id;
      ed.insertText(b1, 0, 'a < b & c > d');
      final documentXml =
          part(const DocxExporter().export(ed.document), 'word/document.xml');
      expect(documentXml, contains('a &lt; b &amp; c &gt; d'));
    });

    test('image blocks export as an italic alt-text placeholder', () {
      final ed = DocumentEditor.newDocument(
          ids: SequentialIdGenerator(), title: '', nowMs: 1);
      ed.insertImageBlock(assetId: 'a1', alt: 'Diagram');
      final documentXml =
          part(const DocxExporter().export(ed.document), 'word/document.xml');
      expect(documentXml, contains('[Image: Diagram]'));
      expect(documentXml, contains('<w:i/>'));
    });
  });

  group('docx round-trip', () {
    test('export -> import -> export is stable for the fixture', () {
      final original = fixture().document;
      final bytes1 = const DocxExporter().export(original);

      final imported = const DocxImporter().importBytes(
        bytes1,
        ids: SequentialIdGenerator(),
        nowMs: 1000,
      );
      expect(imported.title, 'Report');

      final bytes2 = const DocxExporter().export(imported);
      expect(part(bytes2, 'word/document.xml'),
          part(bytes1, 'word/document.xml'));
      expect(bytes2, bytes1);
    });

    test('import recovers structure: headings, marks, bullets, quote, table',
        () {
      final bytes = const DocxExporter().export(fixture().document);
      final imported = const DocxImporter()
          .importBytes(bytes, ids: SequentialIdGenerator(), nowMs: 5);
      final blocks = imported.allBlocks.toList();
      expect(
          blocks.map((b) => b.type),
          [
            BlockType.heading1,
            BlockType.paragraph,
            BlockType.bullet,
            BlockType.bullet,
            BlockType.quote,
            BlockType.table,
          ]);
      final paragraph = blocks[1];
      expect(paragraph.plainText, 'Hello bold and italic and code');
      final marksByText = <String, Set<Mark>>{
        for (final run in paragraph.inlines) run.text: run.marks,
      };
      expect(marksByText['bold'], {Mark.bold});
      expect(marksByText['italic'], {Mark.italic});
      expect(marksByText['code'], {Mark.code});

      final table = blocks[5];
      expect(table.tableRows![0].map((c) => c.plainText), ['Name', 'Value']);
      expect(table.tableRows![1].map((c) => c.plainText), ['alpha', 'beta']);
    });

    test('import rejects non-DOCX bytes', () {
      expect(
          () => const DocxImporter().importBytes(
              utf8.encode('not a zip at all'),
              ids: SequentialIdGenerator(),
              nowMs: 1),
          throwsA(anything));
    });
  });
}
