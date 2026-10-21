import 'dart:convert';
import 'dart:typed_data';

import 'package:doc_engine/doc_engine.dart';

import 'annotations.dart';
import 'layout.dart';
import 'pdf_writer.dart';
import 'text_metrics.dart';

/// Options for [PdfGenerator].
class PdfOptions {
  const PdfOptions({
    this.structured = false,
    this.pdfaMode = false,
    this.annotations = const <PdfAnnotation>[],
    this.language = 'en',
  });

  /// When true, emit a tagged structure skeleton: catalog `/MarkInfo`
  /// and `/Lang`, a `/StructTreeRoot` with one structure element per
  /// block segment, marked-content (`BDC`/`EMC`) operators in the page
  /// streams, and a parent tree. This demonstrates the PDF/UA direction;
  /// it is **not** a claim of PDF/UA conformance (see README).
  final bool structured;

  /// When true, add an sRGB `/OutputIntent` (with a placeholder ICC
  /// profile stream) and an XMP metadata stream carrying `pdfaid:part`
  /// and `pdfaid:conformance`. External validation (e.g. a veraPDF-style
  /// checker) is still required; this package does not certify PDF/A
  /// conformance (see README).
  final bool pdfaMode;

  /// Annotations to include. Note annotations are emitted as PDF text
  /// annotations; highlight annotations are model-only in this version.
  final List<PdfAnnotation> annotations;

  /// Language tag written to the catalog `/Lang` entry when
  /// [structured] is true.
  final String language;
}

class _Segment {
  _Segment(this.pageIndex, this.blockIndex, this.blockType, this.mcid);
  final int pageIndex;
  final int blockIndex;
  final BlockType blockType;
  final int mcid;
}

String _structTypeFor(int blockIndex, BlockType type) {
  if (blockIndex < 0) return 'H1'; // synthetic document-title block
  return switch (type) {
    BlockType.heading1 => 'H1',
    BlockType.heading2 => 'H2',
    BlockType.paragraph => 'P',
    BlockType.bullet => 'LI',
    BlockType.quote => 'BlockQuote',
    BlockType.table => 'Table',
    BlockType.image => 'Figure',
  };
}

/// Generates a complete, deterministic PDF 1.7 file from a [Document].
class PdfGenerator {
  const PdfGenerator();

  Uint8List generate(Document doc, {PdfOptions options = const PdfOptions()}) {
    final layout = const PdfLayoutEngine().layout(doc);
    final spec = layout.spec;

    for (final a in options.annotations) {
      if (a.page < 0 || a.page >= layout.pages.length) {
        throw ArgumentError.value(a.page, 'annotations.page',
            'Annotation page out of range (document has ${layout.pages.length} page(s))');
      }
    }
    final noteAnnotations = options.annotations
        .where((a) => a.type == PdfAnnotationType.note)
        .toList();

    // --- Content streams (+ structure segments) --------------------------
    final segments = <_Segment>[];
    final contentBytes = <List<int>>[];
    for (final page in layout.pages) {
      final buf = StringBuffer();
      int? openBlock;
      var nextMcid = 0;
      final pageSegments = <_Segment>[];
      for (final line in page.lines) {
        if (options.structured && line.blockIndex != openBlock) {
          if (openBlock != null) buf.write('EMC\n');
          final seg =
              _Segment(page.index, line.blockIndex, line.blockType, nextMcid++);
          pageSegments.add(seg);
          buf.write(
              '/${_structTypeFor(line.blockIndex, line.blockType)} << /MCID ${seg.mcid} >> BDC\n');
          openBlock = line.blockIndex;
        }
        var x = line.x;
        for (final span in line.spans) {
          if (span.text.isEmpty) continue;
          buf.write('BT /${span.fontKey} ${pdfNum(line.fontSize)} Tf '
              '1 0 0 1 ${pdfNum(x)} ${pdfNum(line.baseline)} Tm '
              '(${escapePdfString(span.text)}) Tj ET\n');
          x += span.width;
        }
      }
      if (options.structured && openBlock != null) buf.write('EMC\n');
      segments.addAll(pageSegments);
      contentBytes.add(latin1.encode(buf.toString()));
    }

    // --- Object allocation (fixed order = deterministic numbering) -------
    final b = PdfBuilder();
    final catalogNum = b.allocate(); // must be 1: trailer /Root
    final pagesNum = b.allocate();
    final fontNums = <String, int>{
      for (final key in pdfFontBaseNames.keys) key: b.allocate(),
    };
    final structRootNum = options.structured ? b.allocate() : null;
    final pageNums = <int>[];
    final contentNums = <int>[];
    for (var i = 0; i < layout.pages.length; i++) {
      pageNums.add(b.allocate());
      contentNums.add(b.allocate());
    }
    final annotNums = <int>[
      for (var i = 0; i < noteAnnotations.length; i++) b.allocate()
    ];
    final structElemNums = options.structured
        ? <int>[for (var i = 0; i < segments.length; i++) b.allocate()]
        : const <int>[];
    final parentTreeNum = options.structured ? b.allocate() : null;
    final iccNum = options.pdfaMode ? b.allocate() : null;
    final outputIntentNum = options.pdfaMode ? b.allocate() : null;
    final xmpNum = options.pdfaMode ? b.allocate() : null;

    // --- Bodies ------------------------------------------------------------
    pdfFontBaseNames.forEach((key, base) {
      b.setBody(fontNums[key]!,
          '<< /Type /Font /Subtype /Type1 /BaseFont /$base /Encoding /WinAnsiEncoding >>');
    });

    final kids = pageNums.map((n) => '$n 0 R').join(' ');
    b.setBody(
        pagesNum, '<< /Type /Pages /Kids [$kids] /Count ${pageNums.length} >>');

    final catalog = StringBuffer('<< /Type /Catalog /Pages $pagesNum 0 R');
    if (options.structured) {
      catalog
        ..write(' /MarkInfo << /Marked true >>')
        ..write(' /StructTreeRoot $structRootNum 0 R')
        ..write(' /Lang (${escapePdfString(options.language)})');
    }
    if (options.pdfaMode) {
      catalog
        ..write(' /OutputIntents [$outputIntentNum 0 R]')
        ..write(' /Metadata $xmpNum 0 R');
    }
    catalog.write(' >>');
    b.setBody(catalogNum, catalog.toString());

    final fontDict =
        fontNums.entries.map((e) => '/${e.key} ${e.value} 0 R').join(' ');
    for (var i = 0; i < layout.pages.length; i++) {
      final annotsForPage = <int>[
        for (var j = 0; j < noteAnnotations.length; j++)
          if (noteAnnotations[j].page == i) annotNums[j],
      ];
      final page = StringBuffer('<< /Type /Page /Parent $pagesNum 0 R '
          '/MediaBox [0 0 ${pdfNum(spec.width)} ${pdfNum(spec.height)}] '
          '/Resources << /Font << $fontDict >> >> '
          '/Contents ${contentNums[i]} 0 R');
      if (annotsForPage.isNotEmpty) {
        page.write(
            ' /Annots [${annotsForPage.map((n) => '$n 0 R').join(' ')}]');
      }
      if (options.structured) page.write(' /StructParents $i');
      page.write(' >>');
      b.setBody(pageNums[i], page.toString());
      b.setStream(contentNums[i], contentBytes[i]);
    }

    for (var j = 0; j < noteAnnotations.length; j++) {
      final a = noteAnnotations[j];
      b.setBody(
          annotNums[j],
          '<< /Type /Annot /Subtype /Text /NM (annot-$j) '
          '/Rect [${pdfNum(a.rect.left)} ${pdfNum(a.rect.bottom)} '
          '${pdfNum(a.rect.right)} ${pdfNum(a.rect.top)}] '
          '/Contents (${escapePdfString(a.text)}) '
          '/Title (${escapePdfString(a.author)}) /Open false >>');
    }

    if (options.structured) {
      for (var s = 0; s < segments.length; s++) {
        final seg = segments[s];
        b.setBody(
            structElemNums[s],
            '<< /Type /StructElem /S /${_structTypeFor(seg.blockIndex, seg.blockType)} '
            '/P $structRootNum 0 R /Pg ${pageNums[seg.pageIndex]} 0 R '
            '/K ${seg.mcid} >>');
      }
      // ParentTree: key = the page's /StructParents value (its index);
      // value = array indexed by MCID holding that segment's StructElem.
      final nums = StringBuffer();
      for (var p = 0; p < layout.pages.length; p++) {
        final pageSegs = <(int, int)>[
          for (var s = 0; s < segments.length; s++)
            if (segments[s].pageIndex == p)
              (segments[s].mcid, structElemNums[s]),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        final arr = pageSegs.map((e) => '${e.$2} 0 R').join(' ');
        nums.write(' $p [$arr]');
      }
      b.setBody(parentTreeNum!, '<< /Nums [$nums] >>');
      final elemRefs = structElemNums.map((n) => '$n 0 R').join(' ');
      b.setBody(structRootNum!,
          '<< /Type /StructTreeRoot /K [$elemRefs] /ParentTree $parentTreeNum 0 R >>');
    }

    if (options.pdfaMode) {
      // Minimal placeholder sRGB ICC profile: fixed 132-byte header-shaped
      // blob ('mntrRGB XYZ' class signature, 'sRGB' marker). It is a
      // placeholder reference only — see README's PDF/A limitations.
      final icc = Uint8List(132);
      icc[3] = 132;
      icc.setRange(36, 40, latin1.encode('mntr'));
      icc.setRange(40, 43, latin1.encode('RGB'));
      icc.setRange(44, 47, latin1.encode('XYZ'));
      icc.setRange(64, 68, latin1.encode('sRGB'));
      b.setStream(iccNum!, icc, '/N 3');
      b.setBody(
          outputIntentNum!,
          '<< /Type /OutputIntent /S /GTS_PDFA1 '
          '/OutputConditionIdentifier (sRGB IEC61966-2.1) '
          '/Info (sRGB IEC61966-2.1) '
          '/DestOutputProfile $iccNum 0 R >>');
      final xmp = _xmpMetadata(doc);
      b.setStream(xmpNum!, utf8.encode(xmp), '/Type /Metadata /Subtype /XML');
    }

    final info = '/Title (${escapePdfString(doc.title)}) '
        '/Producer (pdf_engine) '
        '/CreationDate (${pdfDateUtc(doc.createdAtMs)}) '
        '/ModDate (${pdfDateUtc(doc.updatedAtMs)})';
    return b.build(
      infoDict: info,
      fileIdHex:
          deterministicFileId('${doc.id}|${doc.createdAtMs}|${doc.title}'),
    );
  }

  String _xmpMetadata(Document doc) {
    String xmlEscape(String s) => s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final title = xmlEscape(doc.title);
    return '<?xpacket begin="\uFEFF" id="W5M0MpCehiHzreSzNTczkc9d"?>\n'
        '<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\n'
        ' <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">\n'
        '  <dc:title><rdf:Alt><rdf:li xml:lang="x-default">$title</rdf:li></rdf:Alt></dc:title>\n'
        ' </rdf:Description>\n'
        ' <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">\n'
        '  <pdfaid:part>3</pdfaid:part>\n'
        '  <pdfaid:conformance>B</pdfaid:conformance>\n'
        ' </rdf:Description>\n'
        '</rdf:RDF>\n'
        '<?xpacket end="w"?>';
  }
}
