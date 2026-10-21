import 'package:sheets_engine/sheets_engine.dart';
import 'package:test/test.dart';

SheetEngine engineFrom(Map<String, Cell> cells) {
  final sheet = Sheet();
  cells.forEach((ref, cell) {
    sheet.setCell(CellRef.tryParse(ref)!, cell);
  });
  return SheetEngine(sheet);
}

double numAt(SheetEngine e, String ref) =>
    (e.valueAt(CellRef.tryParse(ref)!) as NumberValue).value;

void main() {
  group('recalculation', () {
    test('chain: values flow through in dependency order', () {
      final e = engineFrom({
        'A1': Cell.number(1),
        'A2': Cell.formula('=A1+1'),
        'A3': Cell.formula('=A2+1'),
        'A4': Cell.formula('=A3+1'),
      });
      expect(numAt(e, 'A4'), 4);
      e.setCell(CellRef.tryParse('A1')!, Cell.number(10));
      expect(numAt(e, 'A4'), 13);
    });

    test('diamond: a shared dependency recomputes once, consistently', () {
      final e = engineFrom({
        'A1': Cell.number(2),
        'B1': Cell.formula('=A1*3'),
        'C1': Cell.formula('=A1+10'),
        'D1': Cell.formula('=B1+C1'),
      });
      expect(numAt(e, 'D1'), 18);
      e.setCell(CellRef.tryParse('A1')!, Cell.number(5));
      expect(numAt(e, 'B1'), 15);
      expect(numAt(e, 'C1'), 15);
      expect(numAt(e, 'D1'), 30);
    });

    test('ranges: SUM over a range follows edits inside it', () {
      final e = engineFrom({
        'A1': Cell.number(1),
        'A2': Cell.number(2),
        'A3': Cell.number(3),
        'B1': Cell.formula('=SUM(A1:A3)'),
      });
      expect(numAt(e, 'B1'), 6);
      // Editing a cell that was inside the range from the start.
      e.setCell(CellRef.tryParse('A2')!, Cell.number(20));
      expect(numAt(e, 'B1'), 24);
    });

    test('editing a previously empty cell inside a range is picked up',
        () {
      final e = engineFrom({
        'A1': Cell.number(1),
        'B1': Cell.formula('=SUM(A1:A3)'),
      });
      expect(numAt(e, 'B1'), 1);
      e.setCell(CellRef.tryParse('A3')!, Cell.number(100));
      expect(numAt(e, 'B1'), 101);
    });

    test('changing a formula rewires its dependencies', () {
      final e = engineFrom({
        'A1': Cell.number(1),
        'A2': Cell.number(100),
        'B1': Cell.formula('=A1'),
      });
      expect(numAt(e, 'B1'), 1);
      e.setCell(
          CellRef.tryParse('B1')!, Cell.formula('=A2'));
      expect(numAt(e, 'B1'), 100);
      // A1 no longer drives B1.
      e.setCell(CellRef.tryParse('A1')!, Cell.number(999));
      expect(numAt(e, 'B1'), 100);
      e.setCell(CellRef.tryParse('A2')!, Cell.number(7));
      expect(numAt(e, 'B1'), 7);
    });

    test('clearing a cell makes dependents see empty (0)', () {
      final e = engineFrom({
        'A1': Cell.number(5),
        'B1': Cell.formula('=A1*2'),
      });
      expect(numAt(e, 'B1'), 10);
      e.setCell(CellRef.tryParse('A1')!, Cell.empty());
      expect(numAt(e, 'B1'), 0);
      expect(e.valueAt(CellRef.tryParse('A1')!), const EmptyValue());
    });

    test('unrelated cells are not disturbed by an edit', () {
      final e = engineFrom({
        'A1': Cell.number(1),
        'B1': Cell.formula('=A1+1'),
        'Z9': Cell.formula('=40+2'),
      });
      e.setCell(CellRef.tryParse('A1')!, Cell.number(50));
      expect(numAt(e, 'B1'), 51);
      expect(numAt(e, 'Z9'), 42);
    });
  });

  group('cycles', () {
    test('two-cell cycle: members are #CYCLE!, dependents propagate it',
        () {
      final e = engineFrom({
        'A1': Cell.formula('=B1+1'),
        'B1': Cell.formula('=A1+1'),
        'C1': Cell.formula('=A1*2'),
        'D1': Cell.number(9),
      });
      expect(e.valueAt(CellRef.tryParse('A1')!),
          const ErrorValue('#CYCLE!'));
      expect(e.valueAt(CellRef.tryParse('B1')!),
          const ErrorValue('#CYCLE!'));
      expect(e.valueAt(CellRef.tryParse('C1')!),
          const ErrorValue('#CYCLE!'));
      expect(numAt(e, 'D1'), 9); // outside the cycle: unaffected
    });

    test('self reference is a cycle', () {
      final e = engineFrom({'A1': Cell.formula('=A1+1')});
      expect(e.valueAt(CellRef.tryParse('A1')!),
          const ErrorValue('#CYCLE!'));
    });

    test('breaking a cycle restores normal values', () {
      final e = engineFrom({
        'A1': Cell.formula('=B1+1'),
        'B1': Cell.formula('=A1+1'),
      });
      expect(e.valueAt(CellRef.tryParse('A1')!),
          const ErrorValue('#CYCLE!'));
      e.setCell(CellRef.tryParse('B1')!, Cell.number(41));
      expect(numAt(e, 'A1'), 42);
      expect(numAt(e, 'B1'), 41);
    });
  });
}
