import 'dart:convert';

import 'package:doc_engine/doc_engine.dart';
import 'package:test/test.dart';

DocumentEditor makeEditor() => DocumentEditor.newDocument(
      ids: SequentialIdGenerator(),
      title: 'Blocks',
      nowMs: 1000,
    );

void main() {
  group('table blocks', () {
    test('insertTableBlock creates addressed empty cells', () {
      final ed = makeEditor();
      final first = ed.document.allBlocks.first.id;
      final tableId = ed.insertTableBlock(afterBlockId: first, rows: 2, cols: 3);
      final table = ed.document.blockById(tableId)!;
      expect(table.type, BlockType.table);
      expect(table.tableRows, hasLength(2));
      expect(table.tableRows!.every((r) => r.length == 3), isTrue);
      expect(ed.tableCellText(tableId, 1, 2), '');
    });

    test('setTableCellText stores text and marks per cell', () {
      final ed = makeEditor();
      final tableId = ed.insertTableBlock(rows: 2, cols: 2);
      ed.setTableCellText(tableId, 0, 0, 'Name');
      ed.setTableCellText(tableId, 0, 1, 'Value', marks: {Mark.bold});
      ed.setTableCellText(tableId, 1, 0, 'alpha');
      expect(ed.tableCellText(tableId, 0, 0), 'Name');
      expect(ed.tableCellText(tableId, 0, 1), 'Value');
      expect(ed.tableCellText(tableId, 1, 1), '');
      final cell = ed.document.blockById(tableId)!.tableRows![0][1];
      expect(cell.inlines.single.marks, {Mark.bold});
      expect(() => ed.setTableCellText(tableId, 5, 0, 'x'), throwsRangeError);
    });

    test('text operations reject table blocks instead of corrupting them', () {
      final ed = makeEditor();
      final tableId = ed.insertTableBlock();
      expect(() => ed.insertText(tableId, 0, 'x'), throwsStateError);
      expect(() => ed.applyMark(tableId, 0, 1, Mark.bold, true),
          throwsStateError);
    });

    test('insertTableBlock validates dimensions and generic insert', () {
      final ed = makeEditor();
      expect(() => ed.insertTableBlock(rows: 0), throwsArgumentError);
      expect(() => ed.insertBlock(type: BlockType.table), throwsArgumentError);
    });

    test('table JSON round-trips deterministically', () {
      final ed = makeEditor();
      final tableId = ed.insertTableBlock(rows: 1, cols: 2);
      ed.setTableCellText(tableId, 0, 0, 'a');
      ed.setTableCellText(tableId, 0, 1, 'b', marks: {Mark.italic});
      final json1 = ed.toJsonString();
      final decoded = Document.fromJson(
          (jsonDecode(json1) as Map).cast<String, Object?>());
      final ed2 = DocumentEditor(decoded, ids: SequentialIdGenerator());
      expect(ed2.toJsonString(), json1);
      expect(ed2.tableCellText(tableId, 0, 1), 'b');
    });
  });

  group('image blocks', () {
    test('insertImageBlock stores metadata only', () {
      final ed = makeEditor();
      final first = ed.document.allBlocks.first.id;
      final imageId = ed.insertImageBlock(
        afterBlockId: first,
        assetId: 'asset-42',
        alt: 'Diagram of the pipeline',
        byteLength: 20481,
        hash: 'sha256:deadbeef',
      );
      final image = ed.document.blockById(imageId)!;
      expect(image.type, BlockType.image);
      expect(image.imageAssetId, 'asset-42');
      expect(image.imageAlt, 'Diagram of the pipeline');
      expect(image.imageByteLength, 20481);
      expect(image.imageHash, 'sha256:deadbeef');
      expect(() => ed.insertText(imageId, 0, 'x'), throwsStateError);
    });

    test('image JSON round-trips deterministically', () {
      final ed = makeEditor();
      ed.insertImageBlock(assetId: 'a1', alt: 'Alt', byteLength: 7, hash: 'h');
      final json1 = ed.toJsonString();
      final decoded = Document.fromJson(
          (jsonDecode(json1) as Map).cast<String, Object?>());
      expect(
          DocumentEditor(decoded, ids: SequentialIdGenerator())
              .toJsonString(),
          json1);
    });

    test('markdown export references the asset and uses alt text', () {
      final ed = makeEditor();
      ed.insertImageBlock(assetId: 'a1', alt: 'Alt text');
      expect(const MarkdownExporter().export(ed.document),
          contains('![Alt text](asset:a1)'));
    });
  });
}
