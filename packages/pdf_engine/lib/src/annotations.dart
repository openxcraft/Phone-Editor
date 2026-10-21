/// Annotation model for generated PDFs.
///
/// Annotations are plain data: they serialize to/from JSON (so a sync or
/// storage layer can carry them next to a document), and the PDF
/// generator emits **note** annotations as real PDF text annotations
/// (`/Subtype /Text`). **Highlight** annotations are modelled and
/// serialized here but are not yet drawn into generated files — a
/// documented limitation of this package version, not a silent loss:
/// `PdfGenerator` ignores highlight entries when writing `/Annots`.
library;

/// A rectangle in PDF page coordinates (origin bottom-left, points).
class PdfRect {
  const PdfRect({
    required this.left,
    required this.bottom,
    required this.width,
    required this.height,
  });

  final double left;
  final double bottom;
  final double width;
  final double height;

  double get right => left + width;
  double get top => bottom + height;

  List<double> toJson() => <double>[left, bottom, width, height];

  factory PdfRect.fromJson(List<Object?> json) {
    if (json.length != 4) {
      throw const FormatException(
          'PdfRect requires [left, bottom, width, height]');
    }
    double n(Object? v) => (v as num).toDouble();
    return PdfRect(
        left: n(json[0]),
        bottom: n(json[1]),
        width: n(json[2]),
        height: n(json[3]));
  }
}

/// Annotation kinds understood by this package.
enum PdfAnnotationType { highlight, note }

/// One annotation anchored to a page of the generated document.
class PdfAnnotation {
  const PdfAnnotation({
    required this.type,
    required this.page,
    required this.rect,
    required this.text,
    required this.author,
  });

  final PdfAnnotationType type;

  /// Zero-based page index in the generated document.
  final int page;

  final PdfRect rect;
  final String text;
  final String author;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type.name,
        'page': page,
        'rect': rect.toJson(),
        'text': text,
        'author': author,
      };

  factory PdfAnnotation.fromJson(Map<String, Object?> json) {
    final type = json['type'];
    final page = json['page'];
    final rect = json['rect'];
    final text = json['text'];
    final author = json['author'];
    if (type is! String ||
        page is! int ||
        rect is! List ||
        text is! String ||
        author is! String) {
      throw const FormatException(
          'PdfAnnotation requires type:String, page:int, rect:List, text:String, author:String');
    }
    return PdfAnnotation(
      type: PdfAnnotationType.values.byName(type),
      page: page,
      rect: PdfRect.fromJson(rect.cast<Object?>()),
      text: text,
      author: author,
    );
  }
}

/// Serializes a list of annotations deterministically (input order kept).
List<Map<String, Object?>> annotationsToJson(List<PdfAnnotation> annotations) =>
    annotations.map((a) => a.toJson()).toList();

/// Inverse of [annotationsToJson].
List<PdfAnnotation> annotationsFromJson(List<Object?> json) => json
    .map((e) => PdfAnnotation.fromJson((e as Map).cast<String, Object?>()))
    .toList();
