import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:export_engine/export_engine.dart';
import 'package:presentation_engine/presentation_engine.dart';
import 'package:test/test.dart';

/// Round-trip fixture: 2 slides, text + shape, one element carrying
/// opacity and rotation. Geometry uses values that survive the
/// points -> EMU -> points conversion exactly.
Presentation fixture() => Presentation(
      id: 'deck-1',
      title: 'Quarterly Review',
      width: 960,
      height: 540,
      createdAtMs: 1000,
      updatedAtMs: 2000,
      slides: <Slide>[
        Slide(
          id: 'slide-1',
          elements: <SlideElement>[
            SlideElement(
              id: 'title',
              kind: ElementKind.text,
              x: 40,
              y: 30,
              w: 600,
              h: 60,
              text: 'Quarterly Review',
            ),
            SlideElement(
              id: 'box',
              kind: ElementKind.shape,
              x: 100,
              y: 150,
              w: 200,
              h: 120,
              rotation: 15,
              opacity: 0.5,
            ),
          ],
        ),
        Slide(
          id: 'slide-2',
          elements: <SlideElement>[
            SlideElement(
              id: 'body',
              kind: ElementKind.text,
              x: 40,
              y: 40,
              w: 800,
              h: 200,
              opacity: 0.75,
              text: 'First line\nSecond line',
            ),
            SlideElement(
              id: 'chip',
              kind: ElementKind.shape,
              x: 700,
              y: 400,
              w: 120,
              h: 48,
            ),
          ],
        ),
      ],
    );

Set<String> partNames(List<int> bytes) =>
    ZipDecoder().decodeBytes(bytes).files.map((f) => f.name).toSet();

String part(List<int> bytes, String name) {
  final file = ZipDecoder().decodeBytes(bytes).findFile(name);
  if (file == null) fail('Missing PPTX part: $name');
  return utf8.decode(file.content);
}

void main() {
  group('pptx export', () {
    test('produces a real ZIP with the required OOXML parts', () {
      final bytes = const PptxExporter().export(fixture());
      expect(bytes.sublist(0, 2), [0x50, 0x4B]); // 'PK'
      expect(
        partNames(bytes),
        containsAll(<String>[
          '[Content_Types].xml',
          '_rels/.rels',
          'docProps/core.xml',
          'ppt/presentation.xml',
          'ppt/_rels/presentation.xml.rels',
          'ppt/slides/slide1.xml',
          'ppt/slides/slide2.xml',
          'ppt/slides/_rels/slide1.xml.rels',
          'ppt/slideMasters/slideMaster1.xml',
          'ppt/slideLayouts/slideLayout1.xml',
          'ppt/theme/theme1.xml',
        ]),
      );
    });

    test('geometry is converted from points to EMU (12700 per point)',
        () {
      final bytes = const PptxExporter().export(fixture());
      final slide1 = part(bytes, 'ppt/slides/slide1.xml');
      // Shape at (100, 150) sized 200x120 points.
      expect(slide1, contains('<a:off x="1270000" y="1905000"/>'));
      expect(slide1, contains('<a:ext cx="2540000" cy="1524000"/>'));
      // Rotation 15 degrees = 900000 (60000ths).
      expect(slide1, contains('rot="900000"'));
      // Opacity 0.5 -> alpha 50000.
      expect(slide1, contains('<a:alpha val="50000"/>'));
      // Slide size 960x540 pt.
      final pres = part(bytes, 'ppt/presentation.xml');
      expect(pres, contains('<p:sldSz cx="12192000" cy="6858000"'));
    });

    test('deterministic: two exports are byte-identical', () {
      final a = const PptxExporter().export(fixture());
      final b = const PptxExporter().export(fixture());
      expect(a, b);
    });
  });

  group('pptx round trip', () {
    test('import restores slides, kinds, text, geometry, opacity, '
        'rotation; re-export is byte-stable', () {
      final bytes1 = const PptxExporter().export(fixture());
      final imported = const PptxImporter()
          .importBytes(bytes1, presentationId: 'deck-1');

      expect(imported.title, 'Quarterly Review');
      expect(imported.createdAtMs, 1000);
      expect(imported.updatedAtMs, 2000);
      expect(imported.width, 960);
      expect(imported.height, 540);
      expect(imported.slides.map((s) => s.id), ['slide-1', 'slide-2']);

      final s1 = imported.slides[0];
      expect(s1.elements.map((e) => e.id), ['title', 'box']);
      expect(s1.elements[0].kind, ElementKind.text);
      expect(s1.elements[0].text, 'Quarterly Review');
      final box = s1.elements[1];
      expect(box.kind, ElementKind.shape);
      expect([box.x, box.y, box.w, box.h], [100.0, 150.0, 200.0, 120.0]);
      expect(box.rotation, 15);
      expect(box.opacity, 0.5);

      final body = imported.slides[1].elements[0];
      expect(body.text, 'First line\nSecond line');
      expect(body.opacity, 0.75);

      final bytes2 = const PptxExporter().export(imported);
      expect(bytes2, bytes1);
    });

    test('import rejects bytes without slides', () {
      final notPptx = ZipEncoder().encode(Archive()
        ..addFile(ArchiveFile('readme.txt', 3, utf8.encode('hey'))));
      expect(() => const PptxImporter().importBytes(notPptx),
          throwsFormatException);
    });
  });
}
