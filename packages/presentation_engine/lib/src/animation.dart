/// Animation model: easing functions, keyframes, tracks, and resolution of
/// relative triggers into an absolute slide timeline.
///
/// Everything in this file is a pure function of its inputs. No clocks, no
/// randomness: the same tracks always resolve and sample identically.
library;

/// Easing curves. Applied to the progress of a keyframe segment (the easing
/// stored on the segment's *starting* keyframe).
enum Easing { linear, easeIn, easeOut, easeInOut, step }

/// Evaluates [easing] at progress [t] (clamped to 0..1).
///
/// - linear: `t`
/// - easeIn (cubic): `t³`
/// - easeOut (cubic): `1 − (1−t)³`
/// - easeInOut (cubic): `4t³` below 0.5, else `1 − (−2t+2)³ / 2`
/// - step: holds 0 for the whole segment, jumps to 1 at the segment end.
double applyEasing(Easing easing, double t) {
  final x = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
  return switch (easing) {
    Easing.linear => x,
    Easing.easeIn => x * x * x,
    Easing.easeOut => 1 - _cube(1 - x),
    Easing.easeInOut => x < 0.5 ? 4 * x * x * x : 1 - _cube(-2 * x + 2) / 2,
    Easing.step => x >= 1 ? 1.0 : 0.0,
  };
}

double _cube(double v) => v * v * v;

/// The animatable property a track drives.
///
/// Value semantics (applied by the playback core):
/// - [opacity]: absolute value, replaces the element's base opacity.
/// - [translateX] / [translateY]: offset added to the element's position,
///   in slide units.
/// - [scale]: factor multiplied with the element's size (about its
///   top-left corner — a documented Slice simplification).
/// - [rotate]: degrees added to the element's base rotation.
enum AnimProperty { opacity, translateX, translateY, scale, rotate }

/// Track role. Entry tracks control first visibility, exit tracks final
/// visibility; emphasis tracks never affect visibility.
enum TrackKind { entry, exit, emphasis }

/// How a track's start is anchored to the slide timeline.
///
/// - [onStart]: starts at `delayMs` after slide time 0.
/// - [withPrevious]: starts at the previous track's start + `delayMs`.
/// - [afterPrevious]: starts at the previous track's end + `delayMs`.
///
/// "Previous" is the preceding track in document order (elements in slide
/// order, tracks in element order). The first track treats [withPrevious]
/// and [afterPrevious] as [onStart].
enum Trigger { onStart, withPrevious, afterPrevious }

/// One keyframe: at [timeMs] (relative to the track's start) the property
/// holds [value]. [easing] shapes interpolation from this keyframe to the
/// next one.
class Keyframe {
  const Keyframe({
    required this.timeMs,
    required this.value,
    this.easing = Easing.linear,
  });

  final int timeMs;
  final double value;
  final Easing easing;

  Map<String, Object?> toJson() => <String, Object?>{
        'time_ms': timeMs,
        'value': value,
        'easing': easing.name,
      };

  factory Keyframe.fromJson(Map<String, Object?> json) {
    final timeMs = json['time_ms'];
    final value = json['value'];
    final easing = json['easing'];
    if (timeMs is! int || value is! num || easing is! String) {
      throw const FormatException(
          'Keyframe requires time_ms:int, value:num, easing:String');
    }
    return Keyframe(
      timeMs: timeMs,
      value: value.toDouble(),
      easing: Easing.values.byName(easing),
    );
  }
}

/// An animation track attached to one element.
///
/// Keyframes are sorted by [Keyframe.timeMs] at construction (stable for
/// equal times) so sampling and serialization are deterministic regardless
/// of the order they were supplied in.
class AnimationTrack {
  AnimationTrack({
    required this.id,
    required this.kind,
    required this.property,
    required List<Keyframe> keyframes,
    required this.durationMs,
    this.delayMs = 0,
    this.trigger = Trigger.onStart,
  }) : keyframes = _sorted(keyframes) {
    if (this.keyframes.isEmpty) {
      throw ArgumentError.value(
          id, 'id', 'AnimationTrack requires at least one keyframe');
    }
    if (durationMs < 0) {
      throw ArgumentError.value(durationMs, 'durationMs', 'Must be >= 0');
    }
    if (delayMs < 0) {
      throw ArgumentError.value(delayMs, 'delayMs', 'Must be >= 0');
    }
    for (final k in this.keyframes) {
      if (k.timeMs < 0 || k.timeMs > durationMs) {
        throw ArgumentError.value(k.timeMs, 'keyframes',
            'Keyframe time must be within [0, durationMs]');
      }
    }
  }

  final String id;
  final TrackKind kind;
  final AnimProperty property;
  final List<Keyframe> keyframes;
  final int durationMs;
  final int delayMs;
  final Trigger trigger;

  static List<Keyframe> _sorted(List<Keyframe> input) {
    final indexed = <(int, Keyframe)>[
      for (var i = 0; i < input.length; i++) (i, input[i]),
    ];
    indexed.sort((a, b) {
      final byTime = a.$2.timeMs.compareTo(b.$2.timeMs);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
    return List.unmodifiable(indexed.map((e) => e.$2));
  }

  /// Samples the track's value at local time [localMs] (relative to the
  /// track's absolute start). Clamps to the first/last keyframe value
  /// outside the keyframe range.
  double valueAt(int localMs) {
    final ks = keyframes;
    if (localMs <= ks.first.timeMs) return ks.first.value;
    if (localMs >= ks.last.timeMs) return ks.last.value;
    for (var i = 0; i < ks.length - 1; i++) {
      final a = ks[i];
      final b = ks[i + 1];
      if (localMs >= a.timeMs && localMs <= b.timeMs) {
        final span = b.timeMs - a.timeMs;
        if (span == 0) return b.value;
        final p = (localMs - a.timeMs) / span;
        return a.value + (b.value - a.value) * applyEasing(a.easing, p);
      }
    }
    return ks.last.value; // unreachable given the clamps above
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind.name,
        'property': property.name,
        'delay_ms': delayMs,
        'duration_ms': durationMs,
        'trigger': trigger.name,
        'keyframes': keyframes.map((k) => k.toJson()).toList(),
      };

  factory AnimationTrack.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final kind = json['kind'];
    final property = json['property'];
    final delay = json['delay_ms'];
    final duration = json['duration_ms'];
    final trigger = json['trigger'];
    final keyframes = json['keyframes'];
    if (id is! String ||
        kind is! String ||
        property is! String ||
        delay is! int ||
        duration is! int ||
        trigger is! String ||
        keyframes is! List) {
      throw const FormatException(
          'AnimationTrack requires id/kind/property/trigger Strings, delay_ms/duration_ms ints, keyframes List');
    }
    return AnimationTrack(
      id: id,
      kind: TrackKind.values.byName(kind),
      property: AnimProperty.values.byName(property),
      delayMs: delay,
      durationMs: duration,
      trigger: Trigger.values.byName(trigger),
      keyframes: keyframes
          .map((e) => Keyframe.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
    );
  }
}

/// A track placed on the absolute slide timeline by trigger resolution.
class ResolvedTrack {
  const ResolvedTrack({
    required this.elementId,
    required this.track,
    required this.startMs,
  });

  final String elementId;
  final AnimationTrack track;
  final int startMs;

  int get endMs => startMs + track.durationMs;

  /// Samples the track at absolute time [timeMs].
  double valueAt(int timeMs) => track.valueAt(timeMs - startMs);
}
