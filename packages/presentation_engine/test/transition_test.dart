import 'package:presentation_engine/presentation_engine.dart';
import 'package:test/test.dart';

SlideElement box(String id, double x, double y, double w, double h,
        {double rotation = 0, double opacity = 1}) =>
    SlideElement(
      id: id,
      kind: ElementKind.shape,
      x: x,
      y: y,
      w: w,
      h: h,
      rotation: rotation,
      opacity: opacity,
    );

PlaybackCore coreFor(Slide from, Slide to) => PlaybackCore(Presentation(
      id: 'p',
      title: 'T',
      createdAtMs: 0,
      updatedAtMs: 0,
      slides: <Slide>[from, to],
    ));

void main() {
  group('magicMove', () {
    final from = Slide(id: 'a', elements: <SlideElement>[
      box('hero', 0, 0, 100, 100),
      box('gone', 500, 0, 50, 50),
    ]);
    final to = Slide(
      id: 'b',
      transition: TransitionKind.magicMove,
      elements: <SlideElement>[
        box('hero', 100, 50, 200, 100, rotation: 90, opacity: 0.5),
        box('new', 600, 300, 80, 80),
      ],
    );

    test('midpoint geometry interpolates matched elements by stable ID',
        () {
      final state = coreFor(from, to).transitionStateAt(from, to, 500, 1000);
      expect(state.kind, TransitionKind.magicMove);
      expect(state.progress, 0.5);
      final hero =
          state.elements.firstWhere((e) => e.elementId == 'hero');
      // easeInOut(0.5) == 0.5, so every value sits at its midpoint.
      expect(hero.x, 50.0);
      expect(hero.y, 25.0);
      expect(hero.w, 150.0);
      expect(hero.h, 100.0);
      expect(hero.rotation, 45.0);
      expect(hero.opacity, 0.75);
    });

    test('unmatched elements cross-fade; order is out-only, matched, in-only',
        () {
      final state = coreFor(from, to).transitionStateAt(from, to, 500, 1000);
      expect(state.elements.map((e) => e.elementId), ['gone', 'hero', 'new']);
      expect(state.elements[0].opacity, 0.5); // fading out
      expect(state.elements[0].x, 500.0); // geometry held
      expect(state.elements[2].opacity, 0.5); // fading in
      expect(state.elements[2].x, 600.0);
    });

    test('endpoints equal the source and target geometry', () {
      final core = coreFor(from, to);
      final start = core.transitionStateAt(from, to, 0, 1000);
      final heroStart =
          start.elements.firstWhere((e) => e.elementId == 'hero');
      expect(heroStart.x, 0.0);
      expect(heroStart.w, 100.0);
      final end = core.transitionStateAt(from, to, 1000, 1000);
      final heroEnd = end.elements.firstWhere((e) => e.elementId == 'hero');
      expect(heroEnd.x, 100.0);
      expect(heroEnd.y, 50.0);
      expect(heroEnd.w, 200.0);
      expect(heroEnd.opacity, 0.5);
    });
  });

  group('fade / push / none', () {
    final from = Slide(id: 'a', elements: <SlideElement>[box('x', 0, 0, 10, 10)]);
    Slide toWith(TransitionKind kind) => Slide(
          id: 'b',
          transition: kind,
          elements: <SlideElement>[box('y', 20, 20, 10, 10)],
        );

    test('fade scales both slides opacities by progress', () {
      final to = toWith(TransitionKind.fade);
      final state = coreFor(from, to).transitionStateAt(from, to, 250, 1000);
      expect(state.elements.map((e) => e.elementId), ['x', 'y']);
      expect(state.elements[0].opacity, 0.75); // outgoing: 1 - 0.25
      expect(state.elements[1].opacity, 0.25); // incoming: 0.25
      expect(state.fromSlideOffsetX, 0.0);
      expect(state.toSlideOffsetX, 0.0);
    });

    test('push offsets whole slides horizontally', () {
      final to = toWith(TransitionKind.push);
      final state = coreFor(from, to).transitionStateAt(from, to, 500, 1000);
      expect(state.fromSlideOffsetX, -640.0); // -0.5 * 1280 (default width)
      expect(state.toSlideOffsetX, 640.0);
      expect(state.elements.map((e) => e.elementId), ['x', 'y']);
    });

    test('none cuts instantly to the incoming slide', () {
      final to = toWith(TransitionKind.none);
      final state = coreFor(from, to).transitionStateAt(from, to, 0, 1000);
      expect(state.elements.map((e) => e.elementId), ['y']);
    });

    test('zero duration completes the transition', () {
      final to = toWith(TransitionKind.fade);
      final state = coreFor(from, to).transitionStateAt(from, to, 0, 0);
      expect(state.progress, 1.0);
      expect(state.elements[0].opacity, 0.0);
      expect(state.elements[1].opacity, 1.0);
    });
  });
}
