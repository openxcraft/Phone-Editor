import 'package:sheets_engine/sheets_engine.dart';
import 'package:test/test.dart';

void main() {
  group('A1 references', () {
    test('parse and format round-trip, including multi-letter columns', () {
      expect(CellRef.tryParse('A1'), const CellRef(0, 0));
      expect(CellRef.tryParse('B12'), const CellRef(11, 1));
      expect(CellRef.tryParse('AA100'), const CellRef(99, 26));
      expect(CellRef.tryParse(r'$C$3'), const CellRef(2, 2));
      expect(const CellRef(99, 26).toA1(), 'AA100');
      expect(CellRef.columnIndexToLetters(27), 'AB');
      expect(CellRef.columnLettersToIndex('AB'), 27);
    });

    test('invalid references are rejected', () {
      expect(CellRef.tryParse('A0'), isNull); // rows are one-based
      expect(CellRef.tryParse('1A'), isNull);
      expect(CellRef.tryParse(''), isNull);
      expect(CellRef.tryParse('A'), isNull);
    });

    test('ranges normalize and enumerate row-major', () {
      final range = CellRange.tryParse('B2:A1')!;
      expect(range.toA1(), 'A1:B2');
      expect(range.cells.map((c) => c.toA1()).toList(),
          ['A1', 'B1', 'A2', 'B2']);
      expect(CellRange.tryParse('C3')!.cellCount, 1);
    });
  });

  group('Sheet JSON (formula-preserving)', () {
    Sheet buildSheet() {
      final sheet = Sheet(name: 'Data');
      sheet.setCell(CellRef.tryParse('B2')!, Cell.number(42));
      sheet.setCell(CellRef.tryParse('A1')!, Cell.text('head'));
      sheet.setCell(CellRef.tryParse('A2')!, Cell.formula('=B2*2'));
      sheet.setCell(CellRef.tryParse('C1')!, Cell.boolean(true));
      sheet.setCell(CellRef.tryParse('C2')!, Cell.error('#DIV/0!'));
      return sheet;
    }

    test('round-trip preserves kinds and values', () {
      final sheet = buildSheet();
      final restored = Sheet.fromJsonString(sheet.toJsonString());
      expect(restored.name, 'Data');
      expect(restored.cellCount, sheet.cellCount);
      for (final entry in sheet.sortedEntries) {
        expect(restored.cellAt(entry.key), entry.value,
            reason: 'cell ${entry.key}');
      }
    });

    test('serialization is deterministic: key order is (row, col)', () {
      final sheet = buildSheet();
      final json = sheet.toJsonString();
      expect(json, sheet.toJsonString());
      // A1 (row 0) appears before B2 (row 1) etc., regardless of the
      // insertion order used in buildSheet.
      expect(json.indexOf('"A1"') < json.indexOf('"C1"'), isTrue);
      expect(json.indexOf('"C1"') < json.indexOf('"A2"'), isTrue);
      // Formula survives in its normalized = form.
      expect(json.contains('"value":"=B2*2"'), isTrue);
    });

    test('storing an empty cell keeps the sheet sparse', () {
      final sheet = buildSheet();
      sheet.setCell(CellRef.tryParse('A1')!, Cell.empty());
      expect(sheet.cellAt(CellRef.tryParse('A1')!), isNull);
      expect(sheet.cellCount, 4);
    });
  });
}
