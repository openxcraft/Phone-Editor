import 'dart:convert';
import 'dart:typed_data';

import 'package:doc_engine/doc_engine.dart';
import 'package:pdf_engine/pdf_engine.dart';
import 'package:test/test.dart';

import 'test_fixtures.dart';

String asText(Uint8List bytes) => latin1.decode(bytes);

/// Maps object number -> byte offset of its `N 0 obj` line start.
Map<int, int> objectOffsets(String text) {
  final map = <int, int>{};
  for (final m in RegExp(r'^(\d+) 0 obj$', multiLine: true).allMatches(text)) {
    map[int.parse(m.group(1)!)] = m.start;
  }
  return map;
}

/// Parses the xref table: returns (declared size, offsets by object no.).
(int, Map<int, int>) parseXref(String text) {
  final start = text.indexOf('\nxref\n') + 1;
  final lines = text.substring(start).split('\n');
  // lines: ['xref', '0 N', entry0, entry1, ...]
  final size = int.parse(lines[1].split(' ')[1]);
  final offsets = <int, int>{};
  for (var n = 1; n < size; n++) {
    offsets[n] = int.parse(lines[2 + n].substring(0, 10));
  }
  return (size, offsets);
}

void main() {
  final doc = makeDoc(<Block>[
    typed('b1', BlockType.heading1, 'Quarterly Report'),
    para('b2', 'Hello world, this is a plain paragraph.'),
    typed('b3', BlockType.bullet, 'First item'),
    typed('b4', BlockType.quote, 'A short quotation.'),
  ], title: 'Quarterly Report');

  group('file structure', () {
    test('header, EOF, and version', () {
      final text = asText(const PdfGenerator().generate(doc));
      expect(text.startsWith('%PDF-1.7\n'), isTrue);
      expect(text.trimRight().endsWith('%%EOF'), isTrue);
    });

    test('every xref offset points exactly at its object start', () {
      final text = asText(const PdfGenerator().generate(doc));
      final (size, xref) = parseXref(text);
      final objects = objectOffsets(text);
      expect(xref.length, size - 1);
      for (var n = 1; n < size; n++) {
        expect(xref[n], objects[n],
            reason: 'xref offset for object $n must equal its real offset');
        expect(
            text.substring(xref[n]!, xref[n]! + '$n 0 obj'.length), '$n 0 obj');
      }
    });

    test('trailer root resolves and startxref points at the xref table', () {
      final text = asText(const PdfGenerator().generate(doc));
      expect(text.contains('/Root 1 0 R'), isTrue);
      expect(objectOffsets(text)[1], isNotNull);
      expect(
          asText(const PdfGenerator().generate(doc))
              .substring(objectOffsets(text)[1]!)
              .startsWith('1 0 obj\n<< /Type /Catalog'),
          isTrue);
      final m = RegExp(r'startxref\n(\d+)\n').firstMatch(text)!;
      final startxref = int.parse(m.group(1)!);
      expect(text.substring(startxref, startxref + 4), 'xref');
    });

    test('page count matches the layout engine for a multi-page fixture', () {
      final fixture = manyParagraphs(100);
      final expected = const PdfLayoutEngine().layout(fixture).pages.length;
      expect(expected, 3); // 35 one-line paragraphs per page, see fixture
      final text = asText(const PdfGenerator().generate(fixture));
      final count = int.parse(
          RegExp(r'/Type /Pages /Kids \[[^\]]*\] /Count (\d+)')
              .firstMatch(text)!
              .group(1)!);
      expect(count, expected);
      expect(RegExp(r'/Type /Page ').allMatches(text).length, expected);
    });
  });

  group('content', () {
    test('text strings are present in content streams, with fonts', () {
      final text = asText(const PdfGenerator().generate(doc));
      expect(text.contains('(Quarterly Report) Tj'), isTrue);
      expect(text.contains('(Hello world, this is a plain paragraph.) Tj'),
          isTrue);
      expect(text.contains('/F2'), isTrue); // bold (headings)
      expect(text.contains('/BaseFont /Helvetica'), isTrue);
    });

    test('PDF string escaping and the WinAnsi replacement rule', () {
      final tricky = makeDoc(<Block>[
        para('x', r'cost (est) \ path'),
        para('y', 'emoji 😀 here'),
        para('z', 'café — déjà'),
      ]);
      final text = asText(const PdfGenerator().generate(tricky));
      expect(text.contains(r'(cost \(est\) \\ path) Tj'), isTrue);
      // Non-WinAnsi rune (emoji) is replaced with '?', per the documented rule.
      expect(text.contains('(emoji ? here) Tj'), isTrue);
      // Latin-1 and WinAnsi punctuation survive as octal escapes:
      // é = 0xE9 -> \351, — = 0x97 -> \227.
      expect(text.contains(r'(caf\351 \227 d\351j\340) Tj'), isTrue);
    });

    test('metadata comes from document fields, not the clock', () {
      final text = asText(const PdfGenerator().generate(doc));
      expect(text.contains('/Title (Quarterly Report)'), isTrue);
      expect(text.contains('/CreationDate (D:20231114221320Z)'), isTrue);
      expect(text.contains('/ModDate (D:20231114221420Z)'), isTrue);
    });
  });

  group('options', () {
    test('determinism: two runs are byte-identical', () {
      final a = const PdfGenerator().generate(doc,
          options: const PdfOptions(structured: true, pdfaMode: true));
      final b = const PdfGenerator().generate(doc,
          options: const PdfOptions(structured: true, pdfaMode: true));
      expect(a, b);
    });

    test('plain output has no structure tree or output intent', () {
      final text = asText(const PdfGenerator().generate(doc));
      expect(text.contains('/StructTreeRoot'), isFalse);
      expect(text.contains('/OutputIntents'), isFalse);
      expect(text.contains('BDC'), isFalse);
    });

    test('structured output adds MarkInfo, Lang, StructTree, BDC/MCID', () {
      final text = asText(const PdfGenerator()
          .generate(doc, options: const PdfOptions(structured: true)));
      expect(text.contains('/MarkInfo << /Marked true >>'), isTrue);
      expect(text.contains('/Lang (en)'), isTrue);
      expect(text.contains('/Type /StructTreeRoot'), isTrue);
      expect(text.contains('/Type /StructElem'), isTrue);
      expect(text.contains('/StructParents 0'), isTrue);
      expect(text.contains('/H1 << /MCID 0 >> BDC'), isTrue);
      expect(text.contains('EMC'), isTrue);
    });

    test('pdfaMode adds XMP with pdfaid entries and an OutputIntent', () {
      final text = asText(const PdfGenerator()
          .generate(doc, options: const PdfOptions(pdfaMode: true)));
      expect(text.contains('/OutputIntents'), isTrue);
      expect(text.contains('/S /GTS_PDFA1'), isTrue);
      expect(text.contains('/DestOutputProfile'), isTrue);
      expect(text.contains('/Type /Metadata /Subtype /XML'), isTrue);
      expect(text.contains('<pdfaid:part>3</pdfaid:part>'), isTrue);
      expect(
          text.contains('<pdfaid:conformance>B</pdfaid:conformance>'), isTrue);
    });
  });

  group('annotations in file', () {
    test('note annotation is emitted and referenced from its page', () {
      final bytes = const PdfGenerator().generate(doc,
          options: const PdfOptions(annotations: <PdfAnnotation>[
            PdfAnnotation(
              type: PdfAnnotationType.note,
              page: 0,
              rect: PdfRect(left: 400, bottom: 700, width: 20, height: 20),
              text: 'Check this figure',
              author: 'Reviewer',
            ),
          ]));
      final text = asText(bytes);
      expect(text.contains('/Subtype /Text'), isTrue);
      expect(text.contains('/Contents (Check this figure)'), isTrue);
      expect(text.contains('/Title (Reviewer)'), isTrue);
      expect(text.contains('/Rect [400 700 420 720]'), isTrue);
      expect(text.contains('/Annots ['), isTrue);
    });

    test('highlight annotations are model-only (not emitted)', () {
      final text = asText(const PdfGenerator().generate(doc,
          options: const PdfOptions(annotations: <PdfAnnotation>[
            PdfAnnotation(
              type: PdfAnnotationType.highlight,
              page: 0,
              rect: PdfRect(left: 56, bottom: 700, width: 100, height: 12),
              text: 'highlighted',
              author: 'Reviewer',
            ),
          ])));
      expect(text.contains('/Annots'), isFalse);
      expect(text.contains('/Subtype /Highlight'), isFalse);
    });

    test('annotation page out of range throws', () {
      expect(
          () => const PdfGenerator().generate(doc,
              options: const PdfOptions(annotations: <PdfAnnotation>[
                PdfAnnotation(
                  type: PdfAnnotationType.note,
                  page: 99,
                  rect: PdfRect(left: 0, bottom: 0, width: 10, height: 10),
                  text: 'x',
                  author: 'y',
                ),
              ])),
          throwsArgumentError);
    });
  });
}
