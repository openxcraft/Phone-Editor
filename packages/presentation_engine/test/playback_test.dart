import 'dart:convert';

import 'package:presentation_engine/presentation_engine.dart';
import 'package:test/test.dart';

/// Slide 's1': a delayed fade-in title over a static box.
/// Entry: start 200, end 1000, opacity 0 -> 1 (linear).
/// Slide 's2': an element that exits upward. Exit: start 0, end 500,
/// translateY 0 -> -100.
Presentation buildPresentation() => Presentation(
      id: 'pres',
      title: 'Deck',
      createdAtMs: 1000,
      updatedAtMs: 1000,
      slides: <Slide>[
        Slide(id: 's1', elements: <SlideElement>[
          SlideElement(
            id: 'title',
            kind: ElementKind.text,
            x: 100,
            y: 100,
            w: 400,
            h: 50,
            text: 'Hello',
            tracks: <AnimationTrack>[
              AnimationTrack(
                id: 'fade-in',
                kind: TrackKind.entry,
                property: AnimProperty.opacity,
                delayMs: 200,
                durationMs: 800,
                keyframes: const <Keyframe>[
                  Keyframe(timeMs: 0, value: 0),
                  Keyframe(timeMs: 800, value: 1),
                ],
              ),
            ],
          ),
          SlideElement(
              id: 'box', kind: ElementKind.shape, x: 10, y: 20, w: 30, h: 40),
        ]),
        Slide(id: 's2', elements: <SlideElement>[
          SlideElement(
            id: 'leaving',
            kind: ElementKind.shape,
            x: 0,
            y: 200,
            w: 50,
            h: 50,
            tracks: <AnimationTrack>[
              AnimationTrack(
                id: 'rise-out',
                kind: TrackKind.exit,
                property: AnimProperty.translateY,
                durationMs: 500,
                keyframes: const <Keyframe>[
                  Keyframe(timeMs: 0, value: 0),
                  Keyframe(timeMs: 500, value: -100),
                ],
              ),
            ],
          ),
          SlideElement(
            id: 'pulse',
            kind: ElementKind.shape,
            x: 300,
            y: 300,
            w: 20,
            h: 20,
            tracks: <AnimationTrack>[
              AnimationTrack(
                id: 'emphasis',
                kind: TrackKind.emphasis,
                property: AnimProperty.scale,
                delayMs: 100,
                durationMs: 600,
                keyframes: const <Keyframe>[
                  Keyframe(timeMs: 0, value: 1),
                  Keyframe(timeMs: 300, value: 2),
                  Keyframe(timeMs: 600, value: 1),
                ],
              ),
            ],
          ),
        ]),
      ],
    );

void main() {
  group('stateAt', () {
    test('entry: invisible before start, pinned at initial value', () {
      final core = PlaybackCore(buildPresentation());
      final at0 = core.stateAt('s1', 0).elementById('title')!;
      expect(at0.visible, isFalse);
      expect(at0.opacity, 0.0);
    });

    test('entry: mid-animation and completed states', () {
      final core = PlaybackCore(buildPresentation());
      final mid = core.stateAt('s1', 600).elementById('title')!;
      expect(mid.visible, isTrue);
      expect(mid.opacity, 0.5); // (600-200)/800 linear
      final end = core.stateAt('s1', 1000).elementById('title')!;
      expect(end.opacity, 1.0);
      expect(end.visible, isTrue);
      // After the timeline ends the settled state is stable.
      expect(core.stateAt('s1', 9999).elementById('title')!.opacity, 1.0);
      expect(core.stateAt('s1', 0).durationMs, 1000);
    });

    test('static elements pass through unchanged at any time', () {
      final core = PlaybackCore(buildPresentation());
      final box = core.stateAt('s1', 12345).elementById('box')!;
      expect(box.visible, isTrue);
      expect(box.opacity, 1.0);
      expect(box.x, 10.0);
      expect(box.y, 20.0);
      expect(box.w, 30.0);
      expect(box.h, 40.0);
      expect(box.scale, 1.0);
      expect(box.rotation, 0.0);
    });

    test('exit: animates, then the element becomes invisible at its end',
        () {
      final core = PlaybackCore(buildPresentation());
      final mid = core.stateAt('s2', 250).elementById('leaving')!;
      expect(mid.visible, isTrue);
      expect(mid.y, 150.0); // 200 + (-100 * 0.5)
      expect(core.stateAt('s2', 499).elementById('leaving')!.visible, isTrue);
      final done = core.stateAt('s2', 500).elementById('leaving')!;
      expect(done.visible, isFalse);
      expect(done.y, 100.0);
    });

    test('emphasis: applies only while running, never hides the element',
        () {
      final core = PlaybackCore(buildPresentation());
      final before = core.stateAt('s2', 0).elementById('pulse')!;
      expect(before.visible, isTrue);
      expect(before.scale, 1.0); // emphasis not started: not applied
      final peak = core.stateAt('s2', 400).elementById('pulse')!;
      expect(peak.scale, 2.0); // local 300 of the track
      expect(peak.w, 40.0);
      expect(peak.h, 40.0);
      expect(peak.visible, isTrue);
    });

    test('determinism: same input yields equal states and identical JSON',
        () {
      final pres = buildPresentation();
      final core = PlaybackCore(pres);
      final a = core.stateAt('s1', 600);
      final b = core.stateAt('s1', 600);
      expect(a, b);
      expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()));
      // And across two independently built copies of the same deck.
      final c = PlaybackCore(buildPresentation()).stateAt('s1', 600);
      expect(jsonEncode(c.toJson()), jsonEncode(a.toJson()));
    });

    test('golden RenderState snapshot at t=600', () {
      final core = PlaybackCore(buildPresentation());
      const expected = '{"slide_id":"s1","time_ms":600,"duration_ms":1000,'
          '"elements":['
          '{"element_id":"title","kind":"text","visible":true,"opacity":0.5,'
          '"x":100.0,"y":100.0,"w":400.0,"h":50.0,"scale":1.0,"rotation":0.0},'
          '{"element_id":"box","kind":"shape","visible":true,"opacity":1.0,'
          '"x":10.0,"y":20.0,"w":30.0,"h":40.0,"scale":1.0,"rotation":0.0}]}';
      expect(jsonEncode(core.stateAt('s1', 600).toJson()), expected);
    });

    test('negative time clamps to 0; unknown slide throws', () {
      final core = PlaybackCore(buildPresentation());
      expect(core.stateAt('s1', -50).timeMs, 0);
      expect(() => core.stateAt('missing', 0), throwsArgumentError);
    });

    test('rotate and translate compose with the base transform', () {
      final pres = Presentation(
        id: 'p',
        title: 'T',
        createdAtMs: 0,
        updatedAtMs: 0,
        slides: <Slide>[
          Slide(id: 's', elements: <SlideElement>[
            SlideElement(
              id: 'e',
              kind: ElementKind.shape,
              x: 10,
              y: 10,
              w: 10,
              h: 10,
              rotation: 15,
              tracks: <AnimationTrack>[
                AnimationTrack(
                  id: 'spin',
                  kind: TrackKind.emphasis,
                  property: AnimProperty.rotate,
                  durationMs: 100,
                  keyframes: const <Keyframe>[
                    Keyframe(timeMs: 0, value: 0),
                    Keyframe(timeMs: 100, value: 90),
                  ],
                ),
                AnimationTrack(
                  id: 'slide',
                  kind: TrackKind.emphasis,
                  property: AnimProperty.translateX,
                  durationMs: 100,
                  keyframes: const <Keyframe>[
                    Keyframe(timeMs: 0, value: 0),
                    Keyframe(timeMs: 100, value: 40),
                  ],
                ),
              ],
            ),
          ]),
        ],
      );
      final state =
          PlaybackCore(pres).stateAt('s', 100).elementById('e')!;
      expect(state.rotation, 105.0); // 15 base + 90
      expect(state.x, 50.0); // 10 base + 40
    });
  });
}
