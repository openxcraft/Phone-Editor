/// Scene-graph model: presentation -> slides -> elements.
///
/// Serialization is deterministic: fixed key order, no wall-clock values
/// are generated inside this file (timestamps are supplied by callers), so
/// the same graph always encodes to the same JSON.
library;

import 'animation.dart';

/// Element kind. [text] elements carry a text payload; [shape] and [image]
/// carry only geometry in this slice (an image's asset reference lands with
/// the asset pipeline, keyed by element ID).
enum ElementKind { text, shape, image }

/// How a slide is entered. The transition is stored on the slide it
/// transitions *to* (the convention used by common deck formats).
enum TransitionKind { none, fade, push, magicMove }

/// One element on a slide. [id] is stable across edits and across slides:
/// magic-move transitions match elements by this ID.
class SlideElement {
  SlideElement({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.rotation = 0,
    this.opacity = 1,
    this.text,
    List<AnimationTrack>? tracks,
  }) : tracks = tracks ?? <AnimationTrack>[] {
    if (opacity < 0 || opacity > 1) {
      throw ArgumentError.value(opacity, 'opacity', 'Must be within [0, 1]');
    }
    if (w < 0 || h < 0) {
      throw ArgumentError('Element size must be >= 0 (w=$w, h=$h)');
    }
  }

  final String id;
  final ElementKind kind;

  /// Base rectangle in slide units, and base rotation in degrees.
  double x;
  double y;
  double w;
  double h;
  double rotation;

  /// Base opacity, 0..1.
  double opacity;

  /// Text payload for [ElementKind.text]; null for other kinds.
  String? text;

  /// Animation tracks attached to this element, in document order.
  List<AnimationTrack> tracks;

  SlideElement copy() => SlideElement(
        id: id,
        kind: kind,
        x: x,
        y: y,
        w: w,
        h: h,
        rotation: rotation,
        opacity: opacity,
        text: text,
        tracks: List.of(tracks),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'kind': kind.name,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'rotation': rotation,
        'opacity': opacity,
        'text': text,
        'tracks': tracks.map((t) => t.toJson()).toList(),
      };

  factory SlideElement.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final kind = json['kind'];
    final x = json['x'];
    final y = json['y'];
    final w = json['w'];
    final h = json['h'];
    final rotation = json['rotation'];
    final opacity = json['opacity'];
    final tracks = json['tracks'];
    if (id is! String ||
        kind is! String ||
        x is! num ||
        y is! num ||
        w is! num ||
        h is! num ||
        rotation is! num ||
        opacity is! num ||
        tracks is! List) {
      throw const FormatException(
          'SlideElement requires id/kind Strings, numeric geometry/rotation/opacity, tracks List');
    }
    final text = json['text'];
    if (text != null && text is! String) {
      throw const FormatException('SlideElement text must be String or null');
    }
    return SlideElement(
      id: id,
      kind: ElementKind.values.byName(kind),
      x: x.toDouble(),
      y: y.toDouble(),
      w: w.toDouble(),
      h: h.toDouble(),
      rotation: rotation.toDouble(),
      opacity: opacity.toDouble(),
      text: text as String?,
      tracks: tracks
          .map((e) =>
              AnimationTrack.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
    );
  }
}

/// One slide: elements, presenter notes, and the transition into it.
class Slide {
  Slide({
    required this.id,
    List<SlideElement>? elements,
    this.notes = '',
    this.transition = TransitionKind.none,
    this.transitionDurationMs = 300,
  }) : elements = elements ?? <SlideElement>[];

  final String id;
  List<SlideElement> elements;

  /// Presenter notes; never rendered on the slide itself.
  String notes;

  /// Transition used when this slide is entered.
  TransitionKind transition;
  int transitionDurationMs;

  SlideElement? elementById(String elementId) {
    for (final e in elements) {
      if (e.id == elementId) return e;
    }
    return null;
  }

  /// All tracks on this slide, in document order (element order, then
  /// track order within the element) — the order trigger resolution uses.
  Iterable<(String, AnimationTrack)> get tracksInOrder sync* {
    for (final e in elements) {
      for (final t in e.tracks) {
        yield (e.id, t);
      }
    }
  }

  Slide copy() => Slide(
        id: id,
        elements: elements.map((e) => e.copy()).toList(),
        notes: notes,
        transition: transition,
        transitionDurationMs: transitionDurationMs,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'notes': notes,
        'transition': transition.name,
        'transition_duration_ms': transitionDurationMs,
        'elements': elements.map((e) => e.toJson()).toList(),
      };

  factory Slide.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final notes = json['notes'];
    final transition = json['transition'];
    final duration = json['transition_duration_ms'];
    final elements = json['elements'];
    if (id is! String ||
        notes is! String ||
        transition is! String ||
        duration is! int ||
        elements is! List) {
      throw const FormatException(
          'Slide requires id/notes/transition Strings, transition_duration_ms int, elements List');
    }
    return Slide(
      id: id,
      notes: notes,
      transition: TransitionKind.values.byName(transition),
      transitionDurationMs: duration,
      elements: elements
          .map((e) => SlideElement.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
    );
  }
}

/// The presentation root. Slide size is in the same units as element
/// geometry; the conventional default is 1280 x 720.
class Presentation {
  Presentation({
    required this.id,
    required this.title,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.width = 1280,
    this.height = 720,
    List<Slide>? slides,
  }) : slides = slides ?? <Slide>[];

  final String id;
  String title;
  final double width;
  final double height;

  /// Epoch milliseconds, supplied by the caller (never read from a clock
  /// inside the model, keeping serialization and tests deterministic).
  final int createdAtMs;
  int updatedAtMs;
  List<Slide> slides;

  Slide? slideById(String slideId) {
    for (final s in slides) {
      if (s.id == slideId) return s;
    }
    return null;
  }

  Presentation copy() => Presentation(
        id: id,
        title: title,
        createdAtMs: createdAtMs,
        updatedAtMs: updatedAtMs,
        width: width,
        height: height,
        slides: slides.map((s) => s.copy()).toList(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'title': title,
        'width': width,
        'height': height,
        'created_at': createdAtMs,
        'updated_at': updatedAtMs,
        'slides': slides.map((s) => s.toJson()).toList(),
      };

  factory Presentation.fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final title = json['title'];
    final width = json['width'];
    final height = json['height'];
    final created = json['created_at'];
    final updated = json['updated_at'];
    final slides = json['slides'];
    if (id is! String ||
        title is! String ||
        width is! num ||
        height is! num ||
        created is! int ||
        updated is! int ||
        slides is! List) {
      throw const FormatException(
          'Presentation requires id/title Strings, numeric width/height, created_at/updated_at ints, slides List');
    }
    return Presentation(
      id: id,
      title: title,
      width: width.toDouble(),
      height: height.toDouble(),
      createdAtMs: created,
      updatedAtMs: updated,
      slides: slides
          .map((e) => Slide.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
    );
  }
}
