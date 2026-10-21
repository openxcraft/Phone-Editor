import 'dart:convert';

import 'package:pdf_engine/pdf_engine.dart';
import 'package:test/test.dart';

void main() {
  const note = PdfAnnotation(
    type: PdfAnnotationType.note,
    page: 2,
    rect: PdfRect(left: 100, bottom: 200, width: 24, height: 24),
    text: 'Review the totals',
    author: 'Sam',
  );
  const highlight = PdfAnnotation(
    type: PdfAnnotationType.highlight,
    page: 0,
    rect: PdfRect(left: 56, bottom: 640, width: 180, height: 12),
    text: 'Important sentence',
    author: 'Sam',
  );

  test('JSON round-trip preserves every field and order', () {
    final json = annotationsToJson(<PdfAnnotation>[note, highlight]);
    final encoded = jsonEncode(json);
    final decoded =
        annotationsFromJson((jsonDecode(encoded) as List).cast<Object?>());
    expect(decoded, hasLength(2));
    expect(decoded[0].type, PdfAnnotationType.note);
    expect(decoded[0].page, 2);
    expect(decoded[0].rect.left, 100);
    expect(decoded[0].rect.bottom, 200);
    expect(decoded[0].rect.width, 24);
    expect(decoded[0].rect.height, 24);
    expect(decoded[0].text, 'Review the totals');
    expect(decoded[0].author, 'Sam');
    expect(decoded[1].type, PdfAnnotationType.highlight);
    // Encoding the decoded list reproduces the identical JSON string.
    expect(jsonEncode(annotationsToJson(decoded)), encoded);
  });

  test('rect right/top are derived from width/height', () {
    expect(note.rect.right, 124);
    expect(note.rect.top, 224);
  });

  test('malformed JSON is rejected', () {
    expect(() => PdfAnnotation.fromJson(<String, Object?>{'type': 'note'}),
        throwsFormatException);
    expect(() => PdfRect.fromJson(<Object?>[1, 2]), throwsFormatException);
  });
}
