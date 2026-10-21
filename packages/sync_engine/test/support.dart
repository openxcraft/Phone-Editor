import 'package:doc_engine/doc_engine.dart';

/// Deterministic ID generator with a caller-chosen prefix, so conflict
/// copies from different clients can never collide in tests.
class FixedIds implements IdGenerator {
  FixedIds(this.prefix);

  final String prefix;
  int _n = 0;

  @override
  String next(String _) => '$prefix-${++_n}';
}

Block mkBlock(String id, String text, [BlockType type = BlockType.paragraph]) =>
    Block(id: id, type: type, inlines: <InlineNode>[InlineNode(text)]);

/// A simple one-section document. Block IDs are `blk-1`, `blk-2`, …
Document buildDoc({
  String id = 'doc-main',
  String title = 'Doc',
  int createdAtMs = 100,
  int updatedAtMs = 100,
  int? deletedAtMs,
  SyncStatus syncStatus = SyncStatus.localOnly,
  List<String> blockTexts = const <String>['Hello'],
  String sectionId = 'sec-1',
}) {
  return Document(
    id: id,
    title: title,
    createdAtMs: createdAtMs,
    updatedAtMs: updatedAtMs,
    deletedAtMs: deletedAtMs,
    syncStatus: syncStatus,
    sections: <Section>[
      Section(
        id: sectionId,
        blocks: <Block>[
          for (var i = 0; i < blockTexts.length; i++)
            mkBlock('blk-${i + 1}', blockTexts[i]),
        ],
      ),
    ],
  );
}

void setBlockText(Document doc, String blockId, String text) {
  final block = doc.blockById(blockId);
  if (block == null) throw ArgumentError('No block $blockId');
  block.inlines = <InlineNode>[InlineNode(text)];
}

String blockText(Document doc, String blockId) =>
    doc.blockById(blockId)!.plainText;
