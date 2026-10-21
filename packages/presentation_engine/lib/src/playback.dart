/// The deterministic playback core.
///
/// [PlaybackCore.stateAt] is a **pure function**: same presentation, same
/// slide, same time -> same [RenderState], always. It reads no clocks and
/// mutates nothing. Editor preview, presenter mode, and export (PPTX /
/// video frames) all consume this one core, which is what guarantees they
/// agree frame-for-frame (ACCEPTANCE.md item 3).
library;

import 'animation.dart';
import 'model.dart';

/// Resolves every track on [slide] into the absolute timeline, in document
/// order. See [Trigger] for the anchoring rules.
List<ResolvedTrack> resolveTimeline(Slide slide) {
  final resolved = <ResolvedTrack>[];
  int? previousStart;
  int? previousEnd;
  for (final (elementId, track) in slide.tracksInOrder) {
    final start = switch (track.trigger) {
      Trigger.onStart => track.delayMs,
      Trigger.withPrevious =>
        (previousStart ?? 0) + track.delayMs,
      Trigger.afterPrevious =>
        (previousEnd ?? 0) + track.delayMs,
    };
    final rt = ResolvedTrack(elementId: elementId, track: track, startMs: start);
    resolved.add(rt);
    previousStart = start;
    previousEnd = rt.endMs;
  }
  return resolved;
}

/// Total animated duration of [slide]: the latest track end, or 0 when the
/// slide has no tracks.
int slideDurationMs(Slide slide) {
  var end = 0;
  for (final rt in resolveTimeline(slide)) {
    if (rt.endMs > end) end = rt.endMs;
  }
  return end;
}

/// Computed state of one element at one instant.
class ElementState {
  const ElementState({
    required this.elementId,
    required this.kind,
    required this.visible,
    required this.opacity,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.scale,
    required this.rotation,
  });

  final String elementId;
  final ElementKind kind;

  /// Structural visibility from entry/exit tracks (see [PlaybackCore]).
  /// An invisible element may still carry a computed state (its entry
  /// track's initial values), so renderers can pre-stage it.
  final bool visible;

  /// Effective opacity (base or opacity-track value), 0..1.
  final double opacity;

  /// Final rectangle: base position + translate offsets, size scaled by
  /// the scale factor about the top-left corner.
  final double x;
  final double y;
  final double w;
  final double h;

  /// Applied scale factor (1 when no scale track applies).
  final double scale;

  /// Base rotation + rotate-track degrees.
  final double rotation;

  ElementState withOpacity(double newOpacity) => ElementState(
        elementId: elementId,
        kind: kind,
        visible: visible,
        opacity: newOpacity,
        x: x,
        y: y,
        w: w,
        h: h,
        scale: scale,
        rotation: rotation,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'element_id': elementId,
        'kind': kind.name,
        'visible': visible,
        'opacity': opacity,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'scale': scale,
        'rotation': rotation,
      };

  @override
  bool operator ==(Object other) =>
      other is ElementState &&
      other.elementId == elementId &&
      other.kind == kind &&
      other.visible == visible &&
      other.opacity == opacity &&
      other.x == x &&
      other.y == y &&
      other.w == w &&
      other.h == h &&
      other.scale == scale &&
      other.rotation == rotation;

  @override
  int get hashCode => Object.hash(
      elementId, kind, visible, opacity, x, y, w, h, scale, rotation);
}

/// Computed state of one slide at one instant: the full render frame.
class RenderState {
  const RenderState({
    required this.slideId,
    required this.timeMs,
    required this.durationMs,
    required this.elements,
  });

  final String slideId;

  /// The (clamped, >= 0) time this state was computed for.
  final int timeMs;

  /// The slide's total animated duration.
  final int durationMs;

  /// Per-element states, in slide (z) order.
  final List<ElementState> elements;

  ElementState? elementById(String elementId) {
    for (final e in elements) {
      if (e.elementId == elementId) return e;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'slide_id': slideId,
        'time_ms': timeMs,
        'duration_ms': durationMs,
        'elements': elements.map((e) => e.toJson()).toList(),
      };

  @override
  bool operator ==(Object other) {
    if (other is! RenderState) return false;
    if (other.slideId != slideId ||
        other.timeMs != timeMs ||
        other.durationMs != durationMs ||
        other.elements.length != elements.length) {
      return false;
    }
    for (var i = 0; i < elements.length; i++) {
      if (other.elements[i] != elements[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(slideId, timeMs, durationMs, Object.hashAll(elements));
}

/// Result of sampling a slide transition at one instant.
///
/// [elements] is the merged render list for the instant, in render order.
/// For fade/push it is: outgoing slide's elements, then incoming slide's
/// elements, with opacities / slide offsets already applied. For
/// magicMove it is: outgoing-only elements (fading out), matched elements
/// (interpolated), incoming-only elements (fading in). For none it is
/// just the incoming slide's elements (an instant cut).
class TransitionRenderState {
  const TransitionRenderState({
    required this.kind,
    required this.progress,
    required this.elements,
    required this.fromSlideOffsetX,
    required this.toSlideOffsetX,
  });

  final TransitionKind kind;

  /// Linear progress 0..1 (geometry interpolation for magicMove eases
  /// this with easeInOut before use).
  final double progress;
  final List<ElementState> elements;

  /// Whole-slide horizontal offsets for push transitions; 0 otherwise.
  final double fromSlideOffsetX;
  final double toSlideOffsetX;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        'progress': progress,
        'from_slide_offset_x': fromSlideOffsetX,
        'to_slide_offset_x': toSlideOffsetX,
        'elements': elements.map((e) => e.toJson()).toList(),
      };
}

/// The playback core over one [Presentation].
class PlaybackCore {
  const PlaybackCore(this.presentation);

  final Presentation presentation;

  /// Pure playback: the render state of slide [slideId] at [timeMs]
  /// (negative times clamp to 0).
  ///
  /// Property application rules, per element, in resolved-timeline order:
  /// a track applies once the time reaches its start; before its start,
  /// only **entry** tracks apply, pinning the property to their first
  /// keyframe value (the element's pre-entry state). Later tracks override
  /// earlier ones for the same property.
  ///
  /// Visibility: an element with entry tracks is invisible before its
  /// earliest entry start; an element with exit tracks is invisible from
  /// its latest exit end onwards. Emphasis tracks never affect it.
  RenderState stateAt(String slideId, int timeMs) {
    final slide = presentation.slideById(slideId);
    if (slide == null) {
      throw ArgumentError.value(slideId, 'slideId', 'Slide not found');
    }
    return _stateAtSlide(slide, timeMs);
  }

  RenderState _stateAtSlide(Slide slide, int timeMs) {
    final t = timeMs < 0 ? 0 : timeMs;
    final timeline = resolveTimeline(slide);
    final byElement = <String, List<ResolvedTrack>>{};
    for (final rt in timeline) {
      byElement.putIfAbsent(rt.elementId, () => <ResolvedTrack>[]).add(rt);
    }

    final states = <ElementState>[];
    for (final el in slide.elements) {
      var opacity = el.opacity;
      var dx = 0.0;
      var dy = 0.0;
      var scale = 1.0;
      var rotate = 0.0;
      int? entryStart;
      int? exitEnd;

      for (final rt in byElement[el.id] ?? const <ResolvedTrack>[]) {
        final track = rt.track;
        if (track.kind == TrackKind.entry) {
          entryStart =
              entryStart == null ? rt.startMs : (rt.startMs < entryStart ? rt.startMs : entryStart);
        }
        if (track.kind == TrackKind.exit) {
          exitEnd =
              exitEnd == null ? rt.endMs : (rt.endMs > exitEnd ? rt.endMs : exitEnd);
        }

        final applies = t >= rt.startMs || track.kind == TrackKind.entry;
        if (!applies) continue;
        final value = rt.valueAt(t);
        switch (track.property) {
          case AnimProperty.opacity:
            opacity = value;
          case AnimProperty.translateX:
            dx = value;
          case AnimProperty.translateY:
            dy = value;
          case AnimProperty.scale:
            scale = value;
          case AnimProperty.rotate:
            rotate = value;
        }
      }

      var visible = true;
      if (entryStart != null && t < entryStart) visible = false;
      if (exitEnd != null && t >= exitEnd) visible = false;

      states.add(ElementState(
        elementId: el.id,
        kind: el.kind,
        visible: visible,
        opacity: opacity,
        x: el.x + dx,
        y: el.y + dy,
        w: el.w * scale,
        h: el.h * scale,
        scale: scale,
        rotation: el.rotation + rotate,
      ));
    }

    return RenderState(
      slideId: slide.id,
      timeMs: t,
      durationMs: timeline.isEmpty
          ? 0
          : timeline.map((rt) => rt.endMs).reduce((a, b) => a > b ? a : b),
      elements: states,
    );
  }

  /// Pure transition sampling between two slides at [tMs] into a
  /// transition of [durationMs]. The kind is [toSlide]'s transition.
  ///
  /// The outgoing slide is sampled at its settled end state and the
  /// incoming slide at time 0 — the same machinery ([stateAt]) that
  /// renders slides, so transition frames cannot drift from playback.
  /// Magic-move matches elements by stable ID and interpolates their
  /// rectangles, rotation, and opacity with easeInOut progress.
  TransitionRenderState transitionStateAt(
      Slide fromSlide, Slide toSlide, int tMs, int durationMs) {
    final kind = toSlide.transition;
    final p = durationMs <= 0
        ? 1.0
        : (tMs / durationMs).clamp(0.0, 1.0).toDouble();

    if (kind == TransitionKind.none) {
      return TransitionRenderState(
        kind: kind,
        progress: p,
        elements: _stateAtSlide(toSlide, 0).elements,
        fromSlideOffsetX: 0,
        toSlideOffsetX: 0,
      );
    }

    final fromState = _stateAtSlide(fromSlide, slideDurationMs(fromSlide));
    final toState = _stateAtSlide(toSlide, 0);

    switch (kind) {
      case TransitionKind.fade:
        return TransitionRenderState(
          kind: kind,
          progress: p,
          elements: <ElementState>[
            for (final e in fromState.elements)
              e.withOpacity(e.opacity * (1 - p)),
            for (final e in toState.elements) e.withOpacity(e.opacity * p),
          ],
          fromSlideOffsetX: 0,
          toSlideOffsetX: 0,
        );
      case TransitionKind.push:
        return TransitionRenderState(
          kind: kind,
          progress: p,
          elements: <ElementState>[
            ...fromState.elements,
            ...toState.elements,
          ],
          fromSlideOffsetX: -p * presentation.width,
          toSlideOffsetX: (1 - p) * presentation.width,
        );
      case TransitionKind.magicMove:
        final e = applyEasing(Easing.easeInOut, p);
        final toById = <String, ElementState>{
          for (final s in toState.elements) s.elementId: s,
        };
        final fromIds = fromState.elements.map((s) => s.elementId).toSet();
        final merged = <ElementState>[];
        // Outgoing-only: hold geometry, fade out.
        for (final f in fromState.elements) {
          if (!toById.containsKey(f.elementId)) {
            merged.add(f.withOpacity(f.opacity * (1 - e)));
          }
        }
        // Matched: interpolate geometry, rotation, opacity.
        for (final f in fromState.elements) {
          final to = toById[f.elementId];
          if (to == null) continue;
          double lerp(double a, double b) => a + (b - a) * e;
          merged.add(ElementState(
            elementId: f.elementId,
            kind: to.kind,
            visible: f.visible || to.visible,
            opacity: lerp(f.opacity, to.opacity),
            x: lerp(f.x, to.x),
            y: lerp(f.y, to.y),
            w: lerp(f.w, to.w),
            h: lerp(f.h, to.h),
            scale: lerp(f.scale, to.scale),
            rotation: lerp(f.rotation, to.rotation),
          ));
        }
        // Incoming-only: hold geometry, fade in.
        for (final to in toState.elements) {
          if (!fromIds.contains(to.elementId)) {
            merged.add(to.withOpacity(to.opacity * e));
          }
        }
        return TransitionRenderState(
          kind: kind,
          progress: p,
          elements: merged,
          fromSlideOffsetX: 0,
          toSlideOffsetX: 0,
        );
      case TransitionKind.none:
        throw StateError('unreachable: none handled above');
    }
  }
}
