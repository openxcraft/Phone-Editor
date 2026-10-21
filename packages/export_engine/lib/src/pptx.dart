import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:presentation_engine/presentation_engine.dart';

import 'xml_util.dart';

/// PPTX (OOXML) export and minimal import for [Presentation].
///
/// **Unit decision:** the presentation model stores slide size and
/// element geometry in *points* (1/72 inch). OOXML uses EMUs, with
/// 914400 EMU per inch and therefore **12700 EMU per point**. Export
/// converts with `round(points * 12700)`; import divides by 12700.
/// Decks authored at the presentation engine's default 1280x720 "slide
/// units" will therefore be interpreted as 1280x720 pt (17.8x10 in) —
/// callers that think in pixels should scale before export.
///
/// Export writes a real `.pptx`: `[Content_Types].xml`, `_rels/.rels`,
/// `ppt/presentation.xml`, one `ppt/slides/slideN.xml` per slide (each
/// with its layout relationship), a minimal slide master, one blank
/// slide layout, a theme, and `docProps/core.xml` whose timestamps come
/// from the presentation metadata (never a wall clock). ZIP entries
/// carry the fixed 1980 timestamp, so repeated exports of the same
/// presentation are byte-identical.
///
/// Element mapping:
/// - text elements -> text boxes (`txBox="1"`); the element ID is kept
///   in the shape name so import restores it; multi-line text becomes
///   one `a:p` per line.
/// - shape elements -> rectangles (`prstGeom prst="rect"`) filled with a
///   neutral grey (the model carries no colour); opacity < 1 becomes
///   an `a:alpha` on the fill, rotation becomes `a:xfrm/@rot`
///   (60000ths of a degree).
/// - image elements -> placeholder rectangles (see README losses);
///   they re-import as shapes.
///
/// Import is minimal: slide count/order, element kind (text vs shape),
/// text, geometry, rotation, and opacity, plus slide size, title, and
/// core timestamps. See the package README for everything that is NOT
/// preserved (animations, transitions, notes, image data, colours).
class PptxExporter {
  const PptxExporter();

  /// EMU per model unit (point).
  static const int emuPerPoint = 12700;

  List<int> export(Presentation deck) {
    final archive = Archive();
    addXmlPart(archive, '[Content_Types].xml', _contentTypes(deck));
    addXmlPart(archive, '_rels/.rels', _packageRels);
    addXmlPart(archive, 'docProps/core.xml', _coreXml(deck));
    addXmlPart(archive, 'ppt/presentation.xml', _presentationXml(deck));
    addXmlPart(archive, 'ppt/_rels/presentation.xml.rels',
        _presentationRels(deck));
    addXmlPart(
        archive, 'ppt/slideMasters/slideMaster1.xml', _slideMasterXml);
    addXmlPart(archive, 'ppt/slideMasters/_rels/slideMaster1.xml.rels',
        _slideMasterRels);
    addXmlPart(archive, 'ppt/slideLayouts/slideLayout1.xml', _slideLayoutXml);
    addXmlPart(archive, 'ppt/slideLayouts/_rels/slideLayout1.xml.rels',
        _slideLayoutRels);
    addXmlPart(archive, 'ppt/theme/theme1.xml', _themeXml);
    for (var i = 0; i < deck.slides.length; i++) {
      addXmlPart(archive, 'ppt/slides/slide${i + 1}.xml',
          _slideXml(deck.slides[i]));
      addXmlPart(archive, 'ppt/slides/_rels/slide${i + 1}.xml.rels',
          _slideRels);
    }
    return ZipEncoder().encode(archive);
  }

  static int _emu(double points) => (points * emuPerPoint).round();

  // --- Static parts ---------------------------------------------------------

  static const String _packageRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
      '</Relationships>';

  static const String _slideRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
      '</Relationships>';

  static const String _slideMasterRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>'
      '</Relationships>';

  static const String _slideLayoutRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>'
      '</Relationships>';

  static const String _slideMasterXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
      '<p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill>'
      '<a:effectLst/></p:bgPr></p:bg>'
      '<p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/>'
      '</p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
      '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
      '</p:spTree></p:cSld>'
      '<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" '
      'accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" '
      'accent6="accent6" hlink="hlink" folHlink="folHlink"/>'
      '<p:sldLayoutIdLst><p:sldLayoutId id="1" r:id="rId1"/></p:sldLayoutIdLst>'
      '<p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles>'
      '</p:sldMaster>';

  static const String _slideLayoutXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" '
      'type="blank" preserve="1">'
      '<p:cSld name="Blank"><p:spTree>'
      '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>'
      '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
      '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>'
      '</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>'
      '</p:sldLayout>';

  static const String _themeXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Workspace">'
      '<a:themeElements>'
      '<a:clrScheme name="Workspace">'
      '<a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>'
      '<a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>'
      '<a:dk2><a:srgbClr val="44546A"/></a:dk2>'
      '<a:lt2><a:srgbClr val="E7E6E6"/></a:lt2>'
      '<a:accent1><a:srgbClr val="4472C4"/></a:accent1>'
      '<a:accent2><a:srgbClr val="ED7D31"/></a:accent2>'
      '<a:accent3><a:srgbClr val="A5A5A5"/></a:accent3>'
      '<a:accent4><a:srgbClr val="FFC000"/></a:accent4>'
      '<a:accent5><a:srgbClr val="5B9BD5"/></a:accent5>'
      '<a:accent6><a:srgbClr val="70AD47"/></a:accent6>'
      '<a:hlink><a:srgbClr val="0563C1"/></a:hlink>'
      '<a:folHlink><a:srgbClr val="954F72"/></a:folHlink>'
      '</a:clrScheme>'
      '<a:fontScheme name="Workspace">'
      '<a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont>'
      '<a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont>'
      '</a:fontScheme>'
      '<a:fmtScheme name="Workspace">'
      '<a:fillStyleLst>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"><a:tint val="50000"/></a:schemeClr></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"><a:tint val="25000"/></a:schemeClr></a:solidFill>'
      '</a:fillStyleLst>'
      '<a:lnStyleLst>'
      '<a:ln w="6350"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
      '<a:ln w="12700"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
      '<a:ln w="19050"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>'
      '</a:lnStyleLst>'
      '<a:effectStyleLst>'
      '<a:effectStyle><a:effectLst/></a:effectStyle>'
      '<a:effectStyle><a:effectLst/></a:effectStyle>'
      '<a:effectStyle><a:effectLst/></a:effectStyle>'
      '</a:effectStyleLst>'
      '<a:bgFillStyleLst>'
      '<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"><a:tint val="95000"/></a:schemeClr></a:solidFill>'
      '<a:solidFill><a:schemeClr val="phClr"><a:tint val="85000"/></a:schemeClr></a:solidFill>'
      '</a:bgFillStyleLst>'
      '</a:fmtScheme>'
      '</a:themeElements></a:theme>';

  // --- Generated parts ------------------------------------------------------

  String _contentTypes(Presentation deck) {
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
          '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
      ..write(
          '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
      ..write(
          '<Default Extension="xml" ContentType="application/xml"/>')
      ..write(
          '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>')
      ..write(
          '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>')
      ..write(
          '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>')
      ..write(
          '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>')
      ..write(
          '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>');
    for (var i = 0; i < deck.slides.length; i++) {
      buf.write(
          '<Override PartName="/ppt/slides/slide${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>');
    }
    buf.write('</Types>');
    return buf.toString();
  }

  String _coreXml(Presentation deck) {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${xmlEscape(deck.title)}</dc:title>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">${isoFromMs(deck.createdAtMs)}</dcterms:created>'
        '<dcterms:modified xsi:type="dcterms:W3CDTF">${isoFromMs(deck.updatedAtMs)}</dcterms:modified>'
        '</cp:coreProperties>';
  }

  String _presentationXml(Presentation deck) {
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
          '<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
          'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">')
      ..write('<p:sldMasterIdLst><p:sldMasterId id="1" r:id="rId1"/></p:sldMasterIdLst>')
      ..write('<p:sldIdLst>');
    for (var i = 0; i < deck.slides.length; i++) {
      buf.write('<p:sldId id="${256 + i}" r:id="rId${i + 2}"/>');
    }
    buf.write('</p:sldIdLst>');
    buf.write(
        '<p:sldSz cx="${_emu(deck.width)}" cy="${_emu(deck.height)}" type="custom"/>');
    buf.write('<p:notesSz cx="6858000" cy="9144000"/>');
    buf.write('</p:presentation>');
    return buf.toString();
  }

  String _presentationRels(Presentation deck) {
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')
      ..write(
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>');
    for (var i = 0; i < deck.slides.length; i++) {
      buf.write(
          '<Relationship Id="rId${i + 2}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide${i + 1}.xml"/>');
    }
    buf.write('</Relationships>');
    return buf.toString();
  }

  String _slideXml(Slide slide) {
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
          '<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
          'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">')
      // The slide ID rides in cSld/@name so import can restore it.
      ..write('<p:cSld name="${xmlEscape(slide.id)}"><p:spTree>')
      ..write(
          '<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>')
      ..write(
          '<p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>'
          '<a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>');
    for (var i = 0; i < slide.elements.length; i++) {
      buf.write(_elementXml(slide.elements[i], i + 2));
    }
    buf.write('</p:spTree></p:cSld></p:sld>');
    return buf.toString();
  }

  String _elementXml(SlideElement el, int shapeId) {
    final isText = el.kind == ElementKind.text;
    final buf = StringBuffer('<p:sp>');
    buf.write('<p:nvSpPr>');
    buf.write(
        '<p:cNvPr id="$shapeId" name="${xmlEscape(el.id)}"/>');
    buf.write(isText ? '<p:cNvSpPr txBox="1"/>' : '<p:cNvSpPr/>');
    buf.write('<p:nvPr/></p:nvSpPr>');
    buf.write('<p:spPr>');
    buf.write(_xfrmXml(el));
    buf.write('<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>');
    buf.write(_fillXml(el));
    buf.write('</p:spPr>');
    if (isText) {
      buf.write('<p:txBody><a:bodyPr/><a:lstStyle/>');
      final lines = (el.text ?? '').split('\n');
      for (final line in lines) {
        if (line.isEmpty) {
          buf.write('<a:p><a:endParaRPr lang="en-GB"/></a:p>');
        } else {
          buf.write(
              '<a:p><a:r><a:rPr lang="en-GB" dirty="0"/><a:t>${xmlEscape(line)}</a:t></a:r></a:p>');
        }
      }
      buf.write('</p:txBody>');
    }
    buf.write('</p:sp>');
    return buf.toString();
  }

  String _xfrmXml(SlideElement el) {
    final rot = (el.rotation * 60000).round();
    final rotAttr = rot != 0 ? ' rot="$rot"' : '';
    return '<a:xfrm$rotAttr>'
        '<a:off x="${_emu(el.x)}" y="${_emu(el.y)}"/>'
        '<a:ext cx="${_emu(el.w)}" cy="${_emu(el.h)}"/>'
        '</a:xfrm>';
  }

  String _fillXml(SlideElement el) {
    final alpha = (el.opacity * 100000).round();
    final alphaXml = alpha < 100000 ? '<a:alpha val="$alpha"/>' : '';
    if (el.kind == ElementKind.text) {
      // Text boxes are unfilled unless opacity must be carried; then a
      // white fill with alpha preserves the value through import.
      if (alpha >= 100000) return '';
      return '<a:solidFill><a:srgbClr val="FFFFFF">$alphaXml</a:srgbClr></a:solidFill>';
    }
    // Shapes (and image placeholders) use a fixed neutral grey: the
    // model carries no colour in this increment.
    return '<a:solidFill><a:srgbClr val="D9D9D9">$alphaXml</a:srgbClr></a:solidFill>';
  }
}

/// Minimal PPTX import: reads a file produced by [PptxExporter] (or a
/// structurally similar deck) back into a [Presentation].
///
/// Restores slide count and order, slide IDs (from `cSld/@name`,
/// falling back to `slide-N`), element IDs (from shape names), element
/// kind (text box vs shape), text, geometry, rotation, and opacity,
/// plus slide size, title, and core timestamps, so
/// export → import → export is byte-stable for decks within the
/// documented subset. The presentation ID is not stored in PPTX; pass
/// [presentationId] to control it.
class PptxImporter {
  const PptxImporter();

  Presentation importBytes(
    List<int> bytes, {
    String presentationId = 'presentation',
    String fallbackTitle = '',
    int fallbackNowMs = 0,
  }) {
    final archive = ZipDecoder().decodeBytes(bytes);

    var title = fallbackTitle;
    var createdAtMs = fallbackNowMs;
    var updatedAtMs = fallbackNowMs;
    final coreFile = archive.findFile('docProps/core.xml');
    if (coreFile != null) {
      final core = parseXml(utf8.decode(coreFile.content));
      final coreTitle = core.firstChild('dc:title')?.text.trim() ?? '';
      if (coreTitle.isNotEmpty) title = coreTitle;
      createdAtMs =
          _parseIsoMs(core.firstChild('dcterms:created')?.text) ?? createdAtMs;
      updatedAtMs = _parseIsoMs(core.firstChild('dcterms:modified')?.text) ??
          updatedAtMs;
    }

    var width = 960.0;
    var height = 540.0;
    final presFile = archive.findFile('ppt/presentation.xml');
    if (presFile != null) {
      final pres = parseXml(utf8.decode(presFile.content));
      final sldSz = pres.firstChild('p:sldSz');
      final cx = int.tryParse(sldSz?.attrs['cx'] ?? '');
      final cy = int.tryParse(sldSz?.attrs['cy'] ?? '');
      if (cx != null) width = cx / PptxExporter.emuPerPoint;
      if (cy != null) height = cy / PptxExporter.emuPerPoint;
    }

    final slideFiles = archive.files
        .where((f) => RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name))
        .toList()
      ..sort((a, b) => _slideNumber(a.name).compareTo(_slideNumber(b.name)));
    if (slideFiles.isEmpty) {
      throw const FormatException('Not a PPTX file: no slides found');
    }

    final slides = <Slide>[];
    for (var i = 0; i < slideFiles.length; i++) {
      slides.add(_readSlide(
          parseXml(utf8.decode(slideFiles[i].content)), i + 1));
    }

    return Presentation(
      id: presentationId,
      title: title,
      width: width,
      height: height,
      createdAtMs: createdAtMs,
      updatedAtMs: updatedAtMs,
      slides: slides,
    );
  }

  static int _slideNumber(String partName) =>
      int.parse(RegExp(r'slide(\d+)\.xml$').firstMatch(partName)!.group(1)!);

  static int? _parseIsoMs(String? iso) {
    if (iso == null || iso.trim().isEmpty) return null;
    return DateTime.tryParse(iso.trim())?.millisecondsSinceEpoch;
  }

  Slide _readSlide(XmlNode root, int index) {
    final cSld = root.firstChild('p:cSld');
    final spTree = cSld?.firstChild('p:spTree');
    final slideId = (cSld?.attrs['name']?.isNotEmpty ?? false)
        ? cSld!.attrs['name']!
        : 'slide-$index';
    final elements = <SlideElement>[];
    if (spTree != null) {
      var n = 0;
      for (final sp in spTree.childrenNamed('p:sp')) {
        n++;
        elements.add(_readElement(sp, n));
      }
    }
    return Slide(id: slideId, elements: elements);
  }

  SlideElement _readElement(XmlNode sp, int ordinal) {
    final nvSpPr = sp.firstChild('p:nvSpPr');
    final cNvPr = nvSpPr?.firstChild('p:cNvPr');
    final cNvSpPr = nvSpPr?.firstChild('p:cNvSpPr');
    final id = (cNvPr?.attrs['name']?.isNotEmpty ?? false)
        ? cNvPr!.attrs['name']!
        : 'element-$ordinal';
    final isText = cNvSpPr?.attrs['txBox'] == '1';

    var x = 0.0, y = 0.0, w = 0.0, h = 0.0, rotation = 0.0;
    var opacity = 1.0;
    final spPr = sp.firstChild('p:spPr');
    final xfrm = spPr?.firstChild('a:xfrm');
    if (xfrm != null) {
      final off = xfrm.firstChild('a:off');
      final ext = xfrm.firstChild('a:ext');
      x = _emuToPoints(off?.attrs['x']);
      y = _emuToPoints(off?.attrs['y']);
      w = _emuToPoints(ext?.attrs['cx']);
      h = _emuToPoints(ext?.attrs['cy']);
      final rot = int.tryParse(xfrm.attrs['rot'] ?? '');
      if (rot != null) rotation = rot / 60000;
    }
    final alpha = spPr
        ?.firstChild('a:solidFill')
        ?.firstChild('a:srgbClr')
        ?.firstChild('a:alpha')
        ?.attrs['val'];
    final alphaVal = int.tryParse(alpha ?? '');
    if (alphaVal != null) opacity = alphaVal / 100000;

    String? text;
    if (isText) {
      final txBody = sp.firstChild('p:txBody');
      final lines = <String>[];
      if (txBody != null) {
        for (final p in txBody.childrenNamed('a:p')) {
          lines.add(
              p.descendantsNamed('a:t').map((t) => t.text).join());
        }
      }
      text = lines.join('\n');
    }

    return SlideElement(
      id: id,
      kind: isText ? ElementKind.text : ElementKind.shape,
      x: x,
      y: y,
      w: w,
      h: h,
      rotation: rotation,
      opacity: opacity,
      text: text,
    );
  }

  static double _emuToPoints(String? emu) {
    final parsed = int.tryParse(emu ?? '');
    return parsed == null ? 0 : parsed / PptxExporter.emuPerPoint;
  }
}
