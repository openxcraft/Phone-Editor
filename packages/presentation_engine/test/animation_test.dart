import 'package:presentation_engine/presentation_engine.dart';
import 'package:test/test.dart';

AnimationTrack track({
  String id = 't',
  TrackKind kind = TrackKind.entry,
  AnimProperty property = AnimProperty.opacity,
  List<Keyframe> keyframes = const <Keyframe>[
    Keyframe(timeMs: 0, value: 0),
    Keyframe(timeMs: 1000, value: 100),
  ],
  int durationMs = 1000,
  int delayMs = 0,
  Trigger trigger = Trigger.onStart,
}) =>
    AnimationTrack(
      id: id,
      kind: kind,
      property: property,
      keyframes: keyframes,
      durationMs: durationMs,
      delayMs: delayMs,
      trigger: trigger,
    );

/// A track whose single keyframe fits any duration (for trigger tests,
/// where keyframe values are irrelevant).
AnimationTrack timed({
  required String id,
  required int durationMs,
  int delayMs = 0,
  Trigger trigger = Trigger.onStart,
}) =>
    AnimationTrack(
      id: id,
      kind: TrackKind.entry,
      property: AnimProperty.opacity,
      keyframes: const <Keyframe>[Keyframe(timeMs: 0, value: 1)],
      durationMs: durationMs,
      delayMs: delayMs,
      trigger: trigger,
    );

SlideElement el(String id, List<AnimationTrack> tracks) => SlideElement(
      id: id,
      kind: ElementKind.shape,
      x: 0,
      y: 0,
      w: 10,
      h: 10,
      tracks: tracks,
    );

void main() {
  group('keyframe interpolation', () {
    test('linear segment interpolates and clamps outside the range', () {
      final t = track();
      expect(t.valueAt(0), 0.0);
      expect(t.valueAt(250), 25.0);
      expect(t.valueAt(500), 50.0);
      expect(t.valueAt(1000), 100.0);
      expect(t.valueAt(5000), 100.0); // after last keyframe: clamp
      expect(t.valueAt(-10), 0.0); // before first keyframe: clamp
    });

    test('the starting keyframe easing shapes its segment', () {
      final t = track(keyframes: const <Keyframe>[
        Keyframe(timeMs: 0, value: 0, easing: Easing.easeIn),
        Keyframe(timeMs: 1000, value: 100),
      ]);
      expect(t.valueAt(500), 12.5); // 100 * 0.5^3
    });

    test('step easing holds the start value until the segment ends', () {
      final t = track(
        durationMs: 100,
        keyframes: const <Keyframe>[
          Keyframe(timeMs: 0, value: 5, easing: Easing.step),
          Keyframe(timeMs: 100, value: 10),
        ],
      );
      expect(t.valueAt(99), 5.0);
      expect(t.valueAt(100), 10.0);
    });

    test('multi-segment track interpolates each segment', () {
      final t = track(
        durationMs: 600,
        keyframes: const <Keyframe>[
          Keyframe(timeMs: 0, value: 1),
          Keyframe(timeMs: 300, value: 2),
          Keyframe(timeMs: 600, value: 1),
        ],
      );
      expect(t.valueAt(150), 1.5);
      expect(t.valueAt(300), 2.0);
      expect(t.valueAt(450), 1.5);
    });

    test('keyframes are sorted at construction regardless of input order',
        () {
      final t = track(keyframes: const <Keyframe>[
        Keyframe(timeMs: 1000, value: 100),
        Keyframe(timeMs: 0, value: 0),
        Keyframe(timeMs: 500, value: 40),
      ]);
      expect(t.keyframes.map((k) => k.timeMs), [0, 500, 1000]);
      expect(t.valueAt(500), 40.0);
    });

    test('invalid tracks are rejected', () {
      expect(
          () => track(keyframes: const <Keyframe>[]), throwsArgumentError);
      expect(
          () => track(keyframes: const <Keyframe>[
                Keyframe(timeMs: 2000, value: 1),
              ]),
          throwsArgumentError); // beyond durationMs
    });
  });

  group('trigger resolution', () {
    test('onStart anchors at delay; withPrevious at previous start; '
        'afterPrevious at previous end', () {
      final slide = Slide(id: 's', elements: <SlideElement>[
        el('a', <AnimationTrack>[
          timed(id: 't1', durationMs: 1000, delayMs: 200),
        ]),
        el('b', <AnimationTrack>[
          timed(
              id: 't2',
              durationMs: 400,
              delayMs: 100,
              trigger: Trigger.withPrevious),
          timed(
              id: 't3',
              durationMs: 100,
              delayMs: 50,
              trigger: Trigger.afterPrevious),
        ]),
      ]);
      final resolved = resolveTimeline(slide);
      expect(resolved.map((r) => r.track.id), ['t1', 't2', 't3']);
      expect(resolved[0].startMs, 200); // onStart: 0 + delay
      expect(resolved[0].endMs, 1200);
      expect(resolved[1].startMs, 300); // withPrevious: 200 + 100
      expect(resolved[1].endMs, 700);
      expect(resolved[2].startMs, 750); // afterPrevious: 700 + 50
      expect(slideDurationMs(slide), 1200);
    });

    test('first track: withPrevious / afterPrevious behave as onStart', () {
      final slide = Slide(id: 's', elements: <SlideElement>[
        el('a', <AnimationTrack>[
          timed(
              id: 't',
              durationMs: 10,
              delayMs: 30,
              trigger: Trigger.withPrevious),
        ]),
      ]);
      expect(resolveTimeline(slide).single.startMs, 30);

      final slide2 = Slide(id: 's', elements: <SlideElement>[
        el('a', <AnimationTrack>[
          timed(
              id: 't',
              durationMs: 10,
              delayMs: 45,
              trigger: Trigger.afterPrevious),
        ]),
      ]);
      expect(resolveTimeline(slide2).single.startMs, 45);
    });

    test('a slide without tracks has duration 0 and an empty timeline', () {
      final slide = Slide(id: 's', elements: <SlideElement>[el('a', const [])]);
      expect(resolveTimeline(slide), isEmpty);
      expect(slideDurationMs(slide), 0);
    });
  });
}
