import 'dart:convert';

import 'package:presentation_engine/presentation_engine.dart';
import 'package:test/test.dart';

Presentation buildDeck() => Presentation(
      id: 'pres-1',
      title: 'Quarterly Review',
      createdAtMs: 1700000000000,
      updatedAtMs: 1700000001000,
      width: 1280,
      height: 720,
      slides: <Slide>[
        Slide(
          id: 's1',
          notes: 'Open with the headline number.',
          transition: TransitionKind.fade,
          transitionDurationMs: 250,
          elements: <SlideElement>[
            SlideElement(
              id: 'title',
              kind: ElementKind.text,
              x: 80,
              y: 60,
              w: 800,
              h: 90,
              rotation: 0,
              opacity: 1,
              text: 'Results',
              tracks: <AnimationTrack>[
                AnimationTrack(
                  id: 'in',
                  kind: TrackKind.entry,
                  property: AnimProperty.opacity,
                  delayMs: 100,
                  durationMs: 600,
                  trigger: Trigger.afterPrevious,
                  // Supplied out of order on purpose: construction sorts.
                  keyframes: const <Keyframe>[
                    Keyframe(timeMs: 600, value: 1, easing: Easing.easeOut),
                    Keyframe(timeMs: 0, value: 0),
                  ],
                ),
              ],
            ),
            SlideElement(
              id: 'chart',
              kind: ElementKind.image,
              x: 80,
              y: 200,
              w: 640,
              h: 360,
              opacity: 0.9,
            ),
          ],
        ),
        Slide(id: 's2', elements: <SlideElement>[
          SlideElement(
              id: 'title',
              kind: ElementKind.text,
              x: 80,
              y: 60,
              w: 800,
              h: 90,
              text: 'Details'),
        ]),
      ],
    );

void main() {
  group('serialization', () {
    test('deterministic JSON round-trip is byte-identical', () {
      final deck = buildDeck();
      final json1 = jsonEncode(deck.toJson());
      final restored = Presentation.fromJson(
          (jsonDecode(json1) as Map).cast<String, Object?>());
      final json2 = jsonEncode(restored.toJson());
      expect(json2, json1);
      // Encoding the same graph twice is also identical.
      expect(jsonEncode(buildDeck().toJson()), json1);
    });

    test('round-trip preserves structure, payloads, and sorted keyframes',
        () {
      final restored = Presentation.fromJson(
          (jsonDecode(jsonEncode(buildDeck().toJson())) as Map)
              .cast<String, Object?>());
      expect(restored.title, 'Quarterly Review');
      expect(restored.width, 1280.0);
      expect(restored.slides, hasLength(2));
      final s1 = restored.slides.first;
      expect(s1.notes, 'Open with the headline number.');
      expect(s1.transition, TransitionKind.fade);
      expect(s1.transitionDurationMs, 250);
      final title = s1.elementById('title')!;
      expect(title.kind, ElementKind.text);
      expect(title.text, 'Results');
      expect(title.tracks.single.trigger, Trigger.afterPrevious);
      expect(title.tracks.single.keyframes.map((k) => k.timeMs), [0, 600]);
      expect(title.tracks.single.keyframes.last.easing, Easing.easeOut);
      final chart = s1.elementById('chart')!;
      expect(chart.kind, ElementKind.image);
      expect(chart.text, isNull);
      expect(chart.opacity, 0.9);
    });

    test('fixed key order: document keys come first, in declared order', () {
      final json = jsonEncode(buildDeck().toJson());
      expect(
          json.startsWith(
              '{"id":"pres-1","title":"Quarterly Review","width":1280.0,'),
          isTrue);
    });

    test('malformed JSON is rejected', () {
      expect(() => Presentation.fromJson(<String, Object?>{'id': 'x'}),
          throwsFormatException);
      expect(
          () => SlideElement.fromJson(<String, Object?>{
                'id': 'e',
                'kind': 'text',
              }),
          throwsFormatException);
    });

    test('invalid element values are rejected at construction', () {
      expect(
          () => SlideElement(
              id: 'e', kind: ElementKind.shape, x: 0, y: 0, w: 1, h: 1,
              opacity: 1.5),
          throwsArgumentError);
      expect(
          () => SlideElement(
              id: 'e', kind: ElementKind.shape, x: 0, y: 0, w: -1, h: 1),
          throwsArgumentError);
    });
  });
}
