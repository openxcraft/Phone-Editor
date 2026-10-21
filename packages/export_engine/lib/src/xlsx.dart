import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:sheets_engine/sheets_engine.dart';

import 'xml_util.dart';

/// XLSX (OOXML) export and minimal import for a single [Sheet].
///
/// Export writes a real `.xlsx`: `[Content_Types].xml`, `_rels/.rels`,
/// `xl/workbook.xml`, `xl/worksheets/sheet1.xml`,
/// `xl/sharedStrings.xml`, and a minimal `xl/styles.xml`. ZIP entries
/// carry the fixed 1980 timestamp and all iteration follows the sheet's
/// sorted (row, column) order, so repeated exports are byte-identical.
///
/// Cell mapping:
/// - number -> `<c><v>…</v></c>` (deterministic [formatNumber] form)
/// - text -> shared string (`t="s"`)
/// - bool -> `t="b"` with `1`/`0`
/// - error -> `t="e"` with the error code as the value
/// - formula -> `<f>` holding the source without the leading `=`, plus
///   the **computed** value cached in `<v>` (evaluated with
///   [SheetEngine]); a computed text value uses `t="str"`, a computed
///   bool `t="b"`, a computed error `t="e"`.
///
/// Formula text in this engine is A1-style without sheet qualifiers,
/// which is exactly what a single-sheet workbook needs.
///
/// Import reads `sheet1.xml` (and the sheet name from `workbook.xml`)
/// back into a [Sheet]: shared strings resolve to text cells, `t="b"`
/// to bools, `t="e"` to error cells, `<f>` to formula cells (the cached
/// value is ignored — the engine recomputes it), and plain `<v>` to
/// numbers. Export → import → export is byte-stable for sheets within
/// this subset. See the package README for what is NOT preserved
/// (charts, pivots, styles, additional sheets).
class XlsxExporter {
  const XlsxExporter();

  List<int> export(Sheet sheet) {
    final engine = SheetEngine(sheet);
    final strings = _SharedStrings();
    final sheetXml = _sheetXml(sheet, engine, strings);

    final archive = Archive();
    addXmlPart(archive, '[Content_Types].xml', _contentTypes);
    addXmlPart(archive, '_rels/.rels', _packageRels);
    addXmlPart(archive, 'xl/workbook.xml', _workbookXml(sheet));
    addXmlPart(archive, 'xl/_rels/workbook.xml.rels', _workbookRels);
    addXmlPart(archive, 'xl/worksheets/sheet1.xml', sheetXml);
    addXmlPart(archive, 'xl/sharedStrings.xml', strings.toXml());
    addXmlPart(archive, 'xl/styles.xml', _stylesXml);
    return ZipEncoder().encode(archive);
  }

  static const String _contentTypes =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
      '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>'
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      '</Types>';

  static const String _packageRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      '</Relationships>';

  static const String _workbookRels =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
      '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>'
      '<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>'
      '</Relationships>';

  static const String _stylesXml =
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>'
      '<fills count="2">'
      '<fill><patternFill patternType="none"/></fill>'
      '<fill><patternFill patternType="gray125"/></fill>'
      '</fills>'
      '<borders count="1"><border/></borders>'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>'
      '</styleSheet>';

  String _workbookXml(Sheet sheet) =>
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<sheets><sheet name="${xmlEscape(sheet.name)}" sheetId="1" r:id="rId1"/></sheets>'
      '</workbook>';

  String _sheetXml(Sheet sheet, SheetEngine engine, _SharedStrings strings) {
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>');
    int? currentRow;
    for (final entry in sheet.sortedEntries) {
      final ref = entry.key;
      if (ref.row != currentRow) {
        if (currentRow != null) buf.write('</row>');
        buf.write('<row r="${ref.row + 1}">');
        currentRow = ref.row;
      }
      buf.write(_cellXml(ref, entry.value, engine, strings));
    }
    if (currentRow != null) buf.write('</row>');
    buf.write('</sheetData></worksheet>');
    return buf.toString();
  }

  String _cellXml(
      CellRef ref, Cell cell, SheetEngine engine, _SharedStrings strings) {
    final r = ref.toA1();
    switch (cell.kind) {
      case CellKind.empty:
        return ''; // Sparse model: empty cells are never stored.
      case CellKind.number:
        return '<c r="$r"><v>${formatNumber(cell.numberValue!)}</v></c>';
      case CellKind.text:
        return '<c r="$r" t="s"><v>${strings.indexOf(cell.textValue!)}</v></c>';
      case CellKind.bool:
        return '<c r="$r" t="b"><v>${cell.boolValue! ? 1 : 0}</v></c>';
      case CellKind.error:
        return '<c r="$r" t="e"><v>${xmlEscape(cell.textValue!)}</v></c>';
      case CellKind.formula:
        final source = cell.formulaSource!;
        final body = xmlEscape(source.substring(1)); // strip leading '='
        final computed = engine.valueAt(ref);
        return switch (computed) {
          NumberValue n =>
            '<c r="$r"><f>$body</f><v>${formatNumber(n.value)}</v></c>',
          TextValue t =>
            '<c r="$r" t="str"><f>$body</f><v>${xmlEscape(t.value)}</v></c>',
          BoolValue b =>
            '<c r="$r" t="b"><f>$body</f><v>${b.value ? 1 : 0}</v></c>',
          ErrorValue e =>
            '<c r="$r" t="e"><f>$body</f><v>${xmlEscape(e.code)}</v></c>',
          EmptyValue _ => '<c r="$r"><f>$body</f></c>',
        };
    }
  }
}

/// Collects shared strings in first-seen order (which, given the
/// exporter's sorted cell iteration, is deterministic).
class _SharedStrings {
  final List<String> _values = <String>[];
  final Map<String, int> _index = <String, int>{};
  var _totalRefs = 0;

  int indexOf(String value) {
    _totalRefs++;
    return _index.putIfAbsent(value, () {
      _values.add(value);
      return _values.length - 1;
    });
  }

  String toXml() {
    final buf = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write(
          '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'count="$_totalRefs" uniqueCount="${_values.length}">');
    for (final value in _values) {
      final preserve =
          value != value.trim() ? ' xml:space="preserve"' : '';
      buf.write('<si><t$preserve>${xmlEscape(value)}</t></si>');
    }
    buf.write('</sst>');
    return buf.toString();
  }
}

/// Minimal XLSX import: the inverse of [XlsxExporter] for the
/// documented subset (single sheet; values and formulas).
class XlsxImporter {
  const XlsxImporter();

  Sheet importBytes(List<int> bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);

    var sheetName = 'Sheet1';
    final workbookFile = archive.findFile('xl/workbook.xml');
    if (workbookFile != null) {
      final workbook = parseXml(utf8.decode(workbookFile.content));
      final sheetNode = workbook.descendantsNamed('sheet').firstOrNull;
      final name = sheetNode?.attrs['name'];
      if (name != null && name.isNotEmpty) sheetName = name;
    }

    final sharedStrings = <String>[];
    final sstFile = archive.findFile('xl/sharedStrings.xml');
    if (sstFile != null) {
      final sst = parseXml(utf8.decode(sstFile.content));
      for (final si in sst.childrenNamed('si')) {
        // An si may split text across several t runs (rich text); this
        // importer concatenates them (formatting is a documented loss).
        sharedStrings
            .add(si.descendantsNamed('t').map((t) => t.text).join());
      }
    }

    final sheetFile = archive.findFile('xl/worksheets/sheet1.xml');
    if (sheetFile == null) {
      throw const FormatException(
          'Not an XLSX file: xl/worksheets/sheet1.xml missing');
    }
    final sheetRoot = parseXml(utf8.decode(sheetFile.content));
    final sheet = Sheet(name: sheetName);
    for (final c in sheetRoot.descendantsNamed('c')) {
      final ref = CellRef.tryParse(c.attrs['r'] ?? '');
      if (ref == null) continue;
      final cell = _readCell(c, sharedStrings);
      if (cell != null) sheet.setCell(ref, cell);
    }
    return sheet;
  }

  Cell? _readCell(XmlNode c, List<String> sharedStrings) {
    final type = c.attrs['t'];
    final formula = c.firstChild('f');
    final value = c.firstChild('v')?.text ?? '';
    if (formula != null) {
      // The cached value is deliberately ignored: the engine
      // recomputes from source, which keeps re-export stable.
      return Cell.formula('=${formula.text}');
    }
    switch (type) {
      case 's':
        final idx = int.tryParse(value);
        if (idx == null || idx < 0 || idx >= sharedStrings.length) {
          return null;
        }
        return Cell.text(sharedStrings[idx]);
      case 'str':
        return Cell.text(value);
      case 'b':
        return Cell.boolean(value == '1' || value.toUpperCase() == 'TRUE');
      case 'e':
        return ErrorCodes.isErrorCode(value) ? Cell.error(value) : null;
      case 'inlineStr':
        final t = c.firstChild('is')?.descendantsNamed('t');
        return Cell.text(t?.map((e) => e.text).join() ?? '');
      default:
        if (value.isEmpty) return null;
        final number = double.tryParse(value);
        return number == null ? Cell.text(value) : Cell.number(number);
    }
  }
}
