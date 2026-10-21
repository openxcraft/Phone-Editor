import 'dart:convert';

import 'package:archive/archive.dart';

import 'model.dart';

/// DOCX (OOXML) export and minimal import, from/to the neutral node tree.
///
/// Export writes a real `.docx`: a ZIP of `[Content_Types].xml`,
/// `_rels/.rels`, `word/document.xml`, `word/styles.xml`,
/// `word/numbering.xml`, `word/_rels/document.xml.rels`, and
/// `docProps/core.xml`. Output is deterministic: ZIP entries carry a
/// fixed timestamp and core properties take their timestamps from the
/// document metadata, never from a wall clock.
///
/// Documented Phase-1 simplifications / losses:
/// - Image blocks export as an italic placeholder paragraph
///   (`[Image: <alt text>]`) because the engine holds no binary data;
///   import reads that back as an ordinary paragraph.
/// - Quote blocks use the `Quote` paragraph style; underline and code
///   runs map to run properties (code = monospace font run property).
/// - Comments and pending suggestions are not written to DOCX.
/// - Import builds one section; headings come from `Heading1`/`Heading2`
///   paragraph styles (or outline levels), bullets from list numbering
///   properties, tables from `w:tbl`; other constructs are ignored.
class DocxExporter {
  const DocxExporter();

  /// Fixed ZIP entry timestamp (1980-01-01, the DOS epoch) so repeated
  /// exports of the same document are byte-identical.
  static const int _zipTimestampSeconds = 315532800;

  List<int> export(Document doc) {
    final archive = Archive();
    _add(archive, '[Content_Types].xml', _contentTypes);
    _add(archive, '_rels/.rels', _packageRels);
    _add(archive, 'word/document.xml', _documentXml(doc));
    _add(archive, 'word/styles.xml', _stylesXml);
    _add(archive, 'word/numbering.xml', _numberingXml);
    _add(archive, 'word/_rels/document.xml.rels', _documentRels);
    _add(archive, 'docProps/core.xml', _coreXml(doc));
    return ZipEncoder().encode(archive);
  }

  void _add(Archive archive, String name, String xml) {
    final bytes = utf8.encode(xml);
    final file = ArchiveFile(name, bytes.length, bytes);
    file.lastModTime = _zipTimestampSeconds;
    archive.addFile(file);
  }

  // --- Parts ---------------------------------------------------------------

  static const String _contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      '<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
      '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      '</Types>';

  static const String _packageRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
      '</Relationships>';

  static const String _documentRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>'
      '</Relationships>';

  static const String _stylesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
      '<w:name w:val="Normal"/><w:qFormat/></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading1">'
      '<w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:outlineLvl w:val="0"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Heading2">'
      '<w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:outlineLvl w:val="1"/></w:pPr>'
      '<w:rPr><w:b/><w:sz w:val="28"/></w:rPr></w:style>'
      '<w:style w:type="paragraph" w:styleId="Quote">'
      '<w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/>'
      '<w:pPr><w:ind w:left="480"/></w:pPr>'
      '<w:rPr><w:i/></w:rPr></w:style>'
      '</w:styles>';

  static const String _numberingXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:abstractNum w:abstractNumId="0">'
      '<w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val="•"/>'
      '<w:lvlJc w:val="left"/><w:pPr><w:ind w:left="480" w:hanging="360"/></w:pPr>'
      '</w:lvl></w:abstractNum>'
      '<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>'
      '</w:numbering>';

  String _coreXml(Document doc) {
    final created = _iso(doc.createdAtMs);
    final modified = _iso(doc.updatedAtMs);
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${_escape(doc.title)}</dc:title>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">$created</dcterms:created>'
        '<dcterms:modified xsi:type="dcterms:W3CDTF">$modified</dcterms:modified>'
        '</cp:coreProperties>';
  }

  static String _iso(int ms) =>
      DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

  // --- document.xml ---------------------------------------------------------

  String _documentXml(Document doc) {
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
          '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">')
      ..write('<w:body>');
    for (final block in doc.allBlocks) {
      buf.write(_blockXml(block));
    }
    buf.write(
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/>'
        '<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/>'
        '</w:sectPr></w:body></w:document>');
    return buf.toString();
  }

  String _blockXml(Block block) {
    switch (block.type) {
      case BlockType.table:
        return _tableXml(block);
      case BlockType.image:
        final alt = block.imageAlt ?? '';
        final label = alt.isEmpty ? '[Image]' : '[Image: $alt]';
        final placeholder = Block(
          id: block.id,
          type: BlockType.paragraph,
          inlines: <InlineNode>[
            InlineNode(label, const <Mark>{Mark.italic})
          ],
        );
        return _paragraphXml(placeholder);
      default:
        return _paragraphXml(block);
    }
  }

  String _paragraphXml(Block block) {
    final buf = StringBuffer('<w:p>');
    final style = switch (block.type) {
      BlockType.heading1 => 'Heading1',
      BlockType.heading2 => 'Heading2',
      BlockType.quote => 'Quote',
      _ => null,
    };
    if (style != null || block.type == BlockType.bullet) {
      buf.write('<w:pPr>');
      if (style != null) buf.write('<w:pStyle w:val="$style"/>');
      if (block.type == BlockType.bullet) {
        buf.write(
            '<w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr>');
      }
      buf.write('</w:pPr>');
    }
    for (final run in block.inlines) {
      buf.write(_runXml(run));
    }
    buf.write('</w:p>');
    return buf.toString();
  }

  String _runXml(InlineNode run) {
    if (run.text.isEmpty) return '';
    final buf = StringBuffer('<w:r>');
    final props = StringBuffer();
    if (run.marks.contains(Mark.code)) {
      props.write(
          '<w:rFonts w:ascii="Courier New" w:hAnsi="Courier New"/>');
    }
    if (run.marks.contains(Mark.bold)) props.write('<w:b/>');
    if (run.marks.contains(Mark.italic)) props.write('<w:i/>');
    if (run.marks.contains(Mark.underline)) {
      props.write('<w:u w:val="single"/>');
    }
    if (props.isNotEmpty) buf.write('<w:rPr>$props</w:rPr>');
    buf.write('<w:t xml:space="preserve">${_escape(run.text)}</w:t>');
    buf.write('</w:r>');
    return buf.toString();
  }

  String _tableXml(Block block) {
    final rows = block.tableRows ?? const <List<TableCell>>[];
    final buf = StringBuffer('<w:tbl>');
    buf.write(
        '<w:tblPr><w:tblBorders>'
        '<w:top w:val="single" w:sz="4" w:space="0" w:color="999999"/>'
        '<w:left w:val="single" w:sz="4" w:space="0" w:color="999999"/>'
        '<w:bottom w:val="single" w:sz="4" w:space="0" w:color="999999"/>'
        '<w:right w:val="single" w:sz="4" w:space="0" w:color="999999"/>'
        '<w:insideH w:val="single" w:sz="4" w:space="0" w:color="999999"/>'
        '<w:insideV w:val="single" w:sz="4" w:space="0" w:color="999999"/>'
        '</w:tblBorders></w:tblPr>');
    if (rows.isNotEmpty) {
      buf.write('<w:tblGrid>');
      for (var i = 0; i < rows.first.length; i++) {
        buf.write('<w:gridCol w:w="2400"/>');
      }
      buf.write('</w:tblGrid>');
    }
    for (final row in rows) {
      buf.write('<w:tr>');
      for (final cell in row) {
        buf.write('<w:tc>');
        final cellBlock = Block(
          id: '',
          type: BlockType.paragraph,
          inlines: cell.inlines,
        );
        buf.write(cell.inlines.every((n) => n.text.isEmpty)
            ? '<w:p/>'
            : _paragraphXml(cellBlock));
        buf.write('</w:tc>');
      }
      buf.write('</w:tr>');
    }
    buf.write('</w:tbl>');
    return buf.toString();
  }

  static String _escape(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}

/// Minimal DOCX import: reads `word/document.xml` (and the core title)
/// back into the neutral node tree. See [DocxExporter] for the documented
/// scope. IDs and timestamps come from the caller's generator/clock
/// values, so imports are deterministic in tests.
class DocxImporter {
  const DocxImporter();

  Document importBytes(
    List<int> bytes, {
    required IdGenerator ids,
    required int nowMs,
    String fallbackTitle = '',
  }) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final documentFile = archive.findFile('word/document.xml');
    if (documentFile == null) {
      throw const FormatException('Not a DOCX file: word/document.xml missing');
    }
    final xml = utf8.decode(documentFile.content);
    final root = _XmlParser.parse(xml);
    final body = root.firstChild('w:body');
    if (body == null) {
      throw const FormatException('DOCX document has no w:body');
    }

    var title = fallbackTitle;
    final coreFile = archive.findFile('docProps/core.xml');
    if (coreFile != null) {
      final core = _XmlParser.parse(utf8.decode(coreFile.content));
      final coreTitle = core.firstChild('dc:title')?.text.trim() ?? '';
      if (coreTitle.isNotEmpty) title = coreTitle;
    }

    final blocks = <Block>[];
    for (final child in body.children) {
      switch (child.name) {
        case 'w:p':
          blocks.add(_paragraph(child, ids));
        case 'w:tbl':
          blocks.add(_table(child, ids));
        default:
          break; // sectPr and anything else: ignored by design.
      }
    }
    if (blocks.isEmpty) {
      blocks.add(Block(id: ids.next('blk'), type: BlockType.paragraph));
    }
    return Document(
      id: ids.next('doc'),
      title: title,
      createdAtMs: nowMs,
      updatedAtMs: nowMs,
      sections: <Section>[
        Section(id: ids.next('sec'), blocks: blocks),
      ],
    );
  }

  Block _paragraph(_XmlNode node, IdGenerator ids) {
    var type = BlockType.paragraph;
    final pPr = node.firstChild('w:pPr');
    if (pPr != null) {
      final style = pPr.firstChild('w:pStyle')?.attrs['w:val'];
      if (style == 'Heading1') type = BlockType.heading1;
      if (style == 'Heading2') type = BlockType.heading2;
      if (style == 'Quote') type = BlockType.quote;
      final outline = pPr.firstChild('w:outlineLvl')?.attrs['w:val'];
      if (type == BlockType.paragraph && outline == '0') {
        type = BlockType.heading1;
      }
      if (type == BlockType.paragraph && outline == '1') {
        type = BlockType.heading2;
      }
      if (pPr.firstChild('w:numPr') != null) type = BlockType.bullet;
    }
    final inlines = <InlineNode>[];
    for (final run in _runsOf(node)) {
      inlines.add(run);
    }
    if (inlines.isEmpty) inlines.add(InlineNode(''));
    return Block(id: ids.next('blk'), type: type, inlines: inlines);
  }

  /// Runs of a paragraph, including runs wrapped in `w:hyperlink`.
  Iterable<InlineNode> _runsOf(_XmlNode paragraph) sync* {
    for (final child in paragraph.children) {
      if (child.name == 'w:r') {
        final run = _run(child);
        if (run != null) yield run;
      } else if (child.name == 'w:hyperlink') {
        for (final inner in child.children) {
          if (inner.name == 'w:r') {
            final run = _run(inner);
            if (run != null) yield run;
          }
        }
      }
    }
  }

  InlineNode? _run(_XmlNode node) {
    final marks = <Mark>{};
    final rPr = node.firstChild('w:rPr');
    if (rPr != null) {
      if (_on(rPr.firstChild('w:b'))) marks.add(Mark.bold);
      if (_on(rPr.firstChild('w:i'))) marks.add(Mark.italic);
      if (rPr.firstChild('w:u') != null) marks.add(Mark.underline);
      final fonts = rPr.firstChild('w:rFonts');
      final fontName =
          (fonts?.attrs['w:ascii'] ?? fonts?.attrs['w:hAnsi'] ?? '')
              .toLowerCase();
      if (fontName.contains('courier') || fontName.contains('consolas')) {
        marks.add(Mark.code);
      }
      final rStyle = rPr.firstChild('w:rStyle')?.attrs['w:val'];
      if (rStyle == 'Code') marks.add(Mark.code);
    }
    final text = StringBuffer();
    for (final child in node.children) {
      switch (child.name) {
        case 'w:t':
          text.write(child.text);
        case 'w:tab':
          text.write('\t');
        case 'w:br':
          text.write('\n');
      }
    }
    if (text.isEmpty) return null;
    return InlineNode(text.toString(), marks);
  }

  /// A boolean run property is on when present, unless explicitly off.
  static bool _on(_XmlNode? node) {
    if (node == null) return false;
    final val = node.attrs['w:val'];
    return val != 'false' && val != '0' && val != 'off';
  }

  Block _table(_XmlNode node, IdGenerator ids) {
    final rows = <List<TableCell>>[];
    for (final tr in node.children.where((c) => c.name == 'w:tr')) {
      final row = <TableCell>[];
      for (final tc in tr.children.where((c) => c.name == 'w:tc')) {
        final inlines = <InlineNode>[];
        final paragraphs =
            tc.children.where((c) => c.name == 'w:p').toList();
        for (var p = 0; p < paragraphs.length; p++) {
          if (p > 0) inlines.add(InlineNode('\n'));
          inlines.addAll(_runsOf(paragraphs[p]));
        }
        if (inlines.isEmpty) inlines.add(InlineNode(''));
        row.add(TableCell(inlines: inlines));
      }
      rows.add(row);
    }
    return Block(
      id: ids.next('blk'),
      type: BlockType.table,
      tableRows: rows,
    );
  }
}

/// A tiny XML tree parser, sufficient for well-formed OOXML parts.
/// Not a general XML parser: it assumes no `<` inside attribute values
/// or text (guaranteed once values are entity-escaped, as OOXML
/// requires) and decodes the five predefined entities plus numeric
/// character references.
class _XmlNode {
  _XmlNode(this.name, this.attrs);

  final String name;
  final Map<String, String> attrs;
  final List<_XmlNode> children = <_XmlNode>[];
  final StringBuffer _text = StringBuffer();

  String get text => _text.toString();

  _XmlNode? firstChild(String name) {
    for (final child in children) {
      if (child.name == name) return child;
    }
    return null;
  }
}

class _XmlParser {
  static _XmlNode parse(String xml) {
    final tokenPattern = RegExp(r'<[^>]+>|[^<]+');
    final attrPattern = RegExp(r'([\w:.-]+)\s*=\s*"([^"]*)"');
    final root = _XmlNode('#root', const <String, String>{});
    final stack = <_XmlNode>[root];
    for (final match in tokenPattern.allMatches(xml)) {
      final token = match.group(0)!;
      if (!token.startsWith('<')) {
        stack.last._text.write(_decodeEntities(token));
        continue;
      }
      if (token.startsWith('<?') || token.startsWith('<!--')) continue;
      if (token.startsWith('</')) {
        if (stack.length > 1) stack.removeLast();
        continue;
      }
      final selfClosing = token.endsWith('/>');
      final inner =
          token.substring(1, token.length - (selfClosing ? 2 : 1)).trim();
      final space = inner.indexOf(RegExp(r'\s'));
      final name = space < 0 ? inner : inner.substring(0, space);
      final attrs = <String, String>{};
      if (space >= 0) {
        for (final attr in attrPattern.allMatches(inner.substring(space))) {
          attrs[attr.group(1)!] = _decodeEntities(attr.group(2)!);
        }
      }
      final node = _XmlNode(name, attrs);
      stack.last.children.add(node);
      if (!selfClosing) stack.add(node);
    }
    if (root.children.isEmpty) {
      throw const FormatException('Empty XML document');
    }
    return root.children.first;
  }

  static String _decodeEntities(String input) {
    if (!input.contains('&')) return input;
    return input.replaceAllMapped(
      RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);'),
      (match) {
        final entity = match.group(1)!;
        switch (entity) {
          case 'amp':
            return '&';
          case 'lt':
            return '<';
          case 'gt':
            return '>';
          case 'quot':
            return '"';
          case 'apos':
            return "'";
          default:
            final code = entity.startsWith('#x')
                ? int.parse(entity.substring(2), radix: 16)
                : int.parse(entity.substring(1));
            return String.fromCharCode(code);
        }
      },
    );
  }
}
