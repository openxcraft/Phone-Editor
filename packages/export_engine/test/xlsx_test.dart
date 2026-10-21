import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:export_engine/export_engine.dart';
import 'package:sheets_engine/sheets_engine.dart';
import 'package:test/test.dart';

/// Round-trip fixture: numbers, text, a bool, a SUM formula over the
/// numbers, and an error cell.
Sheet fixture() {
  final sheet = Sheet(name: 'Data');
  sheet.setCell(const CellRef(0, 0), Cell.number(2));
  sheet.setCell(const CellRef(1, 0), Cell.number(3.5));
  sheet.setCell(const CellRef(2, 0), Cell.formula('=SUM(A1:A2)'));
  sheet.setCell(const CellRef(0, 1), Cell.text('Label & <one>'));
  sheet.setCell(const CellRef(1, 1), Cell.boolean(true));
  sheet.setCell(const CellRef(2, 1), Cell.error(ErrorCodes.divByZero));
  sheet.setCell(const CellRef(0, 2), Cell.text('Plain'));
  return sheet;
}

Set<String> partNames(List<int> bytes) =>
    ZipDecoder().decodeBytes(bytes).files.map((f) => f.name).toSet();

String part(List<int> bytes, String name) {
  final file = ZipDecoder().decodeBytes(bytes).findFile(name);
  if (file == null) fail('Missing XLSX part: $name');
  return utf8.decode(file.content);
}

void main() {
  group('xlsx export', () {
    test('produces a real ZIP with the required OOXML parts', () {
      final bytes = const XlsxExporter().export(fixture());
      expect(bytes.sublist(0, 2), [0x50, 0x4B]); // 'PK'
      expect(
        partNames(bytes),
        containsAll(<String>[
          '[Content_Types].xml',
          '_rels/.rels',
          'xl/workbook.xml',
          'xl/_rels/workbook.xml.rels',
          'xl/worksheets/sheet1.xml',
          'xl/sharedStrings.xml',
          'xl/styles.xml',
        ]),
      );
      expect(part(bytes, 'xl/workbook.xml'), contains('name="Data"'));
    });

    test('formulas are written with their computed value cached', () {
      final bytes = const XlsxExporter().export(fixture());
      final sheetXml = part(bytes, 'xl/worksheets/sheet1.xml');
      // SUM(A1:A2) = 2 + 3.5 = 5.5, cached next to the formula.
      expect(sheetXml, contains('<f>SUM(A1:A2)</f><v>5.5</v>'));
      // Error cell keeps its code and type.
      expect(sheetXml, contains('t="e"><v>#DIV/0!</v>'));
      // Bool cell.
      expect(sheetXml, contains('t="b"><v>1</v>'));
      // Text went to shared strings, XML-escaped.
      final sst = part(bytes, 'xl/sharedStrings.xml');
      expect(sst, contains('Label &amp; &lt;one&gt;'));
      expect(sst, contains('uniqueCount="2"'));
    });

    test('deterministic: two exports are byte-identical', () {
      final a = const XlsxExporter().export(fixture());
      final b = const XlsxExporter().export(fixture());
      expect(a, b);
    });
  });

  group('xlsx round trip', () {
    test('import restores values and formulas; re-export is stable',
        () {
      final bytes1 = const XlsxExporter().export(fixture());
      final imported = const XlsxImporter().importBytes(bytes1);

      expect(imported.name, 'Data');
      expect(imported.cellAt(const CellRef(0, 0)), Cell.number(2));
      expect(imported.cellAt(const CellRef(1, 0)), Cell.number(3.5));
      expect(imported.cellAt(const CellRef(0, 1)),
          Cell.text('Label & <one>'));
      expect(imported.cellAt(const CellRef(1, 1)), Cell.boolean(true));
      expect(imported.cellAt(const CellRef(2, 1)),
          Cell.error(ErrorCodes.divByZero));

      final formula = imported.cellAt(const CellRef(2, 0))!;
      expect(formula.kind, CellKind.formula);
      expect(formula.formulaSource, '=SUM(A1:A2)');
      // And the engine recomputes the same value the cache carried.
      expect(SheetEngine(imported).valueAt(const CellRef(2, 0)),
          const NumberValue(5.5));

      final bytes2 = const XlsxExporter().export(imported);
      expect(bytes2, bytes1);
    });

    test('import rejects bytes without a worksheet', () {
      final notXlsx = ZipEncoder().encode(Archive()
        ..addFile(ArchiveFile('readme.txt', 3, utf8.encode('hey'))));
      expect(() => const XlsxImporter().importBytes(notXlsx),
          throwsFormatException);
    });
  });
}
