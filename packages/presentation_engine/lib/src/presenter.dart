/// Presenter model: notes, a caller-driven elapsed timer, and next-slide
/// preview.
///
/// No clocks are read here. The UI owns a timer and passes elapsed
/// milliseconds in; every getter on this class is a pure function of the
/// presentation, the current index, and that caller-supplied elapsed time.
/// Next-slide preview is defined as `stateAt(nextSlide, 0)` on the shared
/// [PlaybackCore], so what the presenter sees is exactly what playback
/// will show.
library;

import 'model.dart';
import 'playback.dart';

class PresenterModel {
  PresenterModel(this.presentation, {int currentIndex = 0})
      : currentIndex = presentation.slides.isEmpty
            ? 0
            : currentIndex.clamp(0, presentation.slides.length - 1).toInt(),
        _core = PlaybackCore(presentation);

  final Presentation presentation;
  final PlaybackCore _core;

  /// Index of the current slide (clamped into range at construction).
  int currentIndex;

  Slide? get currentSlide =>
      presentation.slides.isEmpty ? null : presentation.slides[currentIndex];

  Slide? get nextSlide => currentIndex + 1 < presentation.slides.length
      ? presentation.slides[currentIndex + 1]
      : null;

  bool get hasNext => nextSlide != null;
  bool get hasPrevious => currentIndex > 0;

  /// Speaker notes for the current slide ('' when none).
  String get currentNotes => currentSlide?.notes ?? '';

  /// Notes for an arbitrary slide; throws for an unknown slide ID.
  String notesFor(String slideId) {
    final slide = presentation.slideById(slideId);
    if (slide == null) {
      throw ArgumentError.value(slideId, 'slideId', 'Slide not found');
    }
    return slide.notes;
  }

  /// Current slide's render state at caller-supplied [elapsedMs] of slide
  /// time — delegates to the shared playback core.
  RenderState? currentState(int elapsedMs) {
    final slide = currentSlide;
    return slide == null ? null : _core.stateAt(slide.id, elapsedMs);
  }

  /// Next-slide preview: exactly `stateAt(nextSlide, 0)`, or null on the
  /// last slide.
  RenderState? nextSlidePreview() {
    final slide = nextSlide;
    return slide == null ? null : _core.stateAt(slide.id, 0);
  }

  /// Moves to the next slide; returns false (and does not move) at the end.
  bool advance() {
    if (!hasNext) return false;
    currentIndex++;
    return true;
  }

  /// Moves to the previous slide; returns false at the start.
  bool back() {
    if (!hasPrevious) return false;
    currentIndex--;
    return true;
  }

  /// Formats a caller-supplied elapsed duration as `MM:SS`, or `H:MM:SS`
  /// at an hour or more. Negative values clamp to 0.
  static String formatElapsed(int elapsedMs) {
    final totalSeconds = (elapsedMs < 0 ? 0 : elapsedMs) ~/ 1000;
    final seconds = totalSeconds % 60;
    final minutes = (totalSeconds ~/ 60) % 60;
    final hours = totalSeconds ~/ 3600;
    String two(int v) => v.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '${two(minutes)}:${two(seconds)}';
  }
}
