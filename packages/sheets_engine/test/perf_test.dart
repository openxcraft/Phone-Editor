import 'package:sheets_engine/sheets_engine.dart';
import 'package:test/test.dart';

void main() {
  test('5,000-cell dependency chain recalculates correctly', () {
    const n = 5000;
    final sheet = Sheet();
    sheet.setCell(const CellRef(0, 0), Cell.number(1));
    for (var r = 1; r < n; r++) {
      sheet.setCell(
        CellRef(r, 0),
        Cell.formula('=${CellRef(r - 1, 0).toA1()}+1'),
      );
    }
    final stopwatch = Stopwatch()..start();
    final engine = SheetEngine(sheet);
    stopwatch.stop();

    expect(engine.valueAt(CellRef(n - 1, 0)),
        NumberValue(n.toDouble()));
    // Incremental update at the head must ripple through the whole chain.
    engine.setCell(const CellRef(0, 0), Cell.number(101));
    expect(engine.valueAt(CellRef(n - 1, 0)),
        NumberValue((100 + n).toDouble()));
    // Generous bound: this runs in well under a second locally; the
    // assertion guards against accidental exponential/quadratic blowups
    // in the scheduler without being a flaky benchmark.
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 30)));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('1,000-cell column SUM range recalculates', () {
    const n = 1000;
    final sheet = Sheet();
    for (var r = 0; r < n; r++) {
      sheet.setCell(CellRef(r, 0), Cell.number(1));
    }
    sheet.setCell(CellRef(0, 1),
        Cell.formula('=SUM(A1:A$n)'));
    final engine = SheetEngine(sheet);
    expect(engine.valueAt(const CellRef(0, 1)),
        NumberValue(n.toDouble()));
    engine.setCell(CellRef(n - 1, 0), Cell.number(2));
    expect(engine.valueAt(const CellRef(0, 1)),
        NumberValue(n + 1.0));
  });
}
