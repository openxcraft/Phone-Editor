import 'package:doc_engine/doc_engine.dart';
import 'package:pdf_engine/pdf_engine.dart';
import 'package:test/test.dart';

import 'test_fixtures.dart';

void main() {
  group('PdfLayoutEngine', () {
    test('short document: one page, title first, block order preserved', () {
      final doc = makeDoc(<Block>[
        typed('h', BlockType.heading1, 'Heading'),
        para('p', 'Body text.'),
      ], title: 'My Title');
      final result = const PdfLayoutEngine().layout(doc);
      expect(result.pages, hasLength(1));
      final lines = result.pages.single.lines;
      expect(lines.map((l) => l.text), ['My Title', 'Heading', 'Body text.']);
      expect(lines[0].blockIndex, -1); // synthetic title block
      expect(lines[0].fontSize, 24);
      expect(lines[1].spans.single.fontKey, 'F2'); // headings are bold
    });

    test('word wrap: long paragraph wraps within the content width', () {
      const sentence =
          'The quick brown fox jumps over the lazy dog and keeps running '
          'across the field towards the distant river bank today';
      final doc = makeDoc(<Block>[para('p', sentence)]);
      final page = const PdfLayoutEngine().layout(doc).pages.single;
      expect(page.lines.length, greaterThan(1));
      // No words lost or reordered by wrapping.
      expect(page.lines.map((l) => l.text).join(' '), sentence);
      const spec = PdfPageSpec();
      for (final line in page.lines) {
        final width = line.spans.fold<double>(0, (sum, s) => sum + s.width);
        expect(
            line.x + width, lessThanOrEqualTo(spec.width - spec.margin + 0.01),
            reason: 'line must fit inside the right margin: "${line.text}"');
      }
    });

    test('mixed marks produce per-run fonts on one line', () {
      final doc = makeDoc(<Block>[
        Block(id: 'p', type: BlockType.paragraph, inlines: <InlineNode>[
          InlineNode('plain '),
          InlineNode('bold', <Mark>{Mark.bold}),
          InlineNode(' and '),
          InlineNode('code', <Mark>{Mark.code}),
        ]),
      ]);
      final line =
          const PdfLayoutEngine().layout(doc).pages.single.lines.single;
      expect(line.text, 'plain bold and code');
      expect(line.spans.map((s) => s.fontKey),
          containsAll(<String>['F1', 'F2', 'F5']));
    });

    test('bullet lines carry the bullet glyph; quotes are indented', () {
      final doc = makeDoc(<Block>[
        typed('b', BlockType.bullet, 'item one'),
        typed('q', BlockType.quote, 'quoted'),
      ]);
      final lines = const PdfLayoutEngine().layout(doc).pages.single.lines;
      expect(lines[0].text, '• item one');
      expect(lines[1].x, 56 + 18);
    });

    test('over-long single word is hard-broken, never overflowing', () {
      final doc = makeDoc(<Block>[para('p', 'a' * 300)]);
      final page = const PdfLayoutEngine().layout(doc).pages.single;
      expect(page.lines.length, greaterThan(1));
      expect(page.lines.map((l) => l.text).join(), 'a' * 300);
    });

    test('pagination: 100 one-line paragraphs take exactly 3 pages', () {
      // 35 blocks/page per the fixture's layout maths.
      final result = const PdfLayoutEngine().layout(manyParagraphs(100));
      expect(result.pages, hasLength(3));
      expect(result.pages[0].lines, hasLength(35));
      expect(result.pages[1].lines, hasLength(35));
      expect(result.pages[2].lines, hasLength(30));
      // Baselines never cross the bottom margin.
      for (final page in result.pages) {
        for (final line in page.lines) {
          expect(line.baseline, greaterThanOrEqualTo(56));
        }
      }
    });

    test('empty document still yields one page', () {
      final result = const PdfLayoutEngine().layout(makeDoc(<Block>[]));
      expect(result.pages, hasLength(1));
      expect(result.pages.single.lines, isEmpty);
    });
  });
}
