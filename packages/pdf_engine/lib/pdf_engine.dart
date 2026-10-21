/// Deterministic PDF 1.7 **generation** from the doc_engine node tree.
///
/// This package writes PDFs from scratch — objects, content streams, a
/// cross-reference table with measured byte offsets, trailer — using only
/// the standard-14 Helvetica family (no font embedding, no PDF packages).
///
/// Scope note: PDF **viewing/rendering** (the PDFium fast path in
/// ENGINES.md), text extraction, form filling, and signatures are
/// platform work and live outside this package. This package covers the
/// generation pipeline only. See README.md for documented limitations,
/// including the WinAnsi text rule and the non-certified status of the
/// PDF/A and tagged-structure options.
library pdf_engine;

export 'src/annotations.dart';
export 'src/layout.dart';
export 'src/pdf_generator.dart';
export 'src/pdf_writer.dart';
export 'src/text_metrics.dart';
