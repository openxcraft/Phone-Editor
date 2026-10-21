import 'package:doc_engine/doc_engine.dart';

/// Fixed-metadata document builder: no clocks, no randomness, so every
/// expectation in the tests is stable.
Document makeDoc(List<Block> blocks, {String title = ''}) {
  return Document(
    id: 'doc-test',
    title: title,
    createdAtMs: 1700000000000, // fixed instant from document metadata
    updatedAtMs: 1700000060000,
    sections: <Section>[Section(id: 'sec-1', blocks: blocks)],
  );
}

Block para(String id, String text, {Set<Mark> marks = const {}}) =>
    Block(id: id, type: BlockType.paragraph, inlines: <InlineNode>[
      InlineNode(text, marks),
    ]);

Block typed(String id, BlockType type, String text) =>
    Block(id: id, type: type, inlines: <InlineNode>[InlineNode(text)]);

/// A document of [count] identical one-line paragraphs. Layout maths
/// (A4, margin 56, body 11/15, paragraph space-after 6): each block
/// advances the cursor 21 pt from a 786 pt start; a baseline must stay
/// >= 56, so exactly 35 blocks fit per page.
Document manyParagraphs(int count) => makeDoc(<Block>[
      for (var i = 0; i < count; i++)
        para('p$i', 'Lorem ipsum dolor sit amet.'),
    ]);
