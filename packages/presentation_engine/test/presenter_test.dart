import 'dart:convert';

import 'package:presentation_engine/presentation_engine.dart';
import 'package:test/test.dart';

Presentation deck() => Presentation(
      id: 'p',
      title: 'Talk',
      createdAtMs: 0,
      updatedAtMs: 0,
      slides: <Slide>[
        Slide(id: 's1', notes: 'Intro notes', elements: <SlideElement>[
          SlideElement(
              id: 'a', kind: ElementKind.text, x: 0, y: 0, w: 10, h: 10,
              text: 'One'),
        ]),
        Slide(id: 's2', notes: 'Second notes', elements: <SlideElement>[
          SlideElement(
              id: 'b', kind: ElementKind.text, x: 5, y: 5, w: 10, h: 10,
              text: 'Two'),
        ]),
      ],
    );

void main() {
  group('PresenterModel', () {
    test('notes come from the current slide; navigation is bounded', () {
      final presenter = PresenterModel(deck());
      expect(presenter.currentNotes, 'Intro notes');
      expect(presenter.notesFor('s2'), 'Second notes');
      expect(presenter.back(), isFalse);
      expect(presenter.advance(), isTrue);
      expect(presenter.currentSlide!.id, 's2');
      expect(presenter.currentNotes, 'Second notes');
      expect(presenter.advance(), isFalse); // stays on the last slide
      expect(presenter.currentSlide!.id, 's2');
      expect(presenter.back(), isTrue);
      expect(presenter.currentSlide!.id, 's1');
      expect(() => presenter.notesFor('missing'), throwsArgumentError);
    });

    test('next-slide preview is exactly stateAt(next, 0)', () {
      final pres = deck();
      final presenter = PresenterModel(pres);
      final preview = presenter.nextSlidePreview()!;
      final direct = PlaybackCore(pres).stateAt('s2', 0);
      expect(jsonEncode(preview.toJson()), jsonEncode(direct.toJson()));
      expect(preview.slideId, 's2');
      expect(preview.timeMs, 0);

      presenter.advance();
      expect(presenter.nextSlidePreview(), isNull);
    });

    test('currentState delegates to the playback core', () {
      final pres = deck();
      final presenter = PresenterModel(pres);
      final state = presenter.currentState(42)!;
      expect(state.slideId, 's1');
      expect(state.timeMs, 42);
    });

    test('elapsed formatting is caller-driven and deterministic', () {
      expect(PresenterModel.formatElapsed(0), '00:00');
      expect(PresenterModel.formatElapsed(59999), '00:59');
      expect(PresenterModel.formatElapsed(61000), '01:01');
      expect(PresenterModel.formatElapsed(3661000), '1:01:01');
      expect(PresenterModel.formatElapsed(-5), '00:00');
    });
  });
}
