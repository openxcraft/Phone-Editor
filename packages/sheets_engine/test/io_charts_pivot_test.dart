import 'package:sheets_engine/sheets_engine.dart';
import 'package:test/test.dart';

SheetEngine engineFrom(Map<String, Cell> cells) {
  final sheet = Sheet();
  cells.forEach((ref, cell) {
    sheet.setCell(CellRef.tryParse(ref)!, cell);
  });
  return SheetEngine(sheet);
}

void main() {
  group('CSV codec', () {
    test('RFC 4180 quoting round-trip', () {
      final rows = <List<String>>[
        ['plain', 'with,comma', 'with "quote"', 'two\nlines'],
        ['1', '2', '3', ''],
      ];
      final encoded = CsvCodec.encode(rows);
      expect(encoded.contains('"with,comma"'), isTrue);
      expect(encoded.contains('"with ""quote"""'), isTrue);
      expect(CsvCodec.parse(encoded), rows);
    });

    test('parse accepts LF and CRLF and quoted newlines', () {
      expect(CsvCodec.parse('a,b\n1,2\n'), [
        ['a', 'b'],
        ['1', '2'],
      ]);
      expect(CsvCodec.parse('a,b\r\n"x\ny",2\r\n'), [
        ['a', 'b'],
        ['x\ny', '2'],
      ]);
    });

    test('import infers kinds; export writes computed values', () {
      final sheet = CsvCodec.sheetFromCsv(
          'name,amount,ok\napples,10,TRUE\npears,=5*4,FALSE\n');
      expect(sheet.cellAt(CellRef.tryParse('A2')!), Cell.text('apples'));
      expect(sheet.cellAt(CellRef.tryParse('B2')!), Cell.number(10));
      expect(sheet.cellAt(CellRef.tryParse('C3')!), Cell.boolean(false));
      expect(sheet.cellAt(CellRef.tryParse('B3')!),
          Cell.formula('=5*4'));

      final engine = SheetEngine(sheet);
      final csv = CsvCodec.sheetToCsv(engine);
      // The formula exported as its computed value 20, deterministic CRLF.
      expect(csv,
          'name,amount,ok\r\napples,10,TRUE\r\npears,20,FALSE\r\n');
    });
  });

  group('charts', () {
    final engine = engineFrom({
      'A1': Cell.text('Q'), 'B1': Cell.text('Sales'), 'C1': Cell.text('Costs'),
      'A2': Cell.text('Q1'), 'B2': Cell.number(10), 'C2': Cell.number(4),
      'A3': Cell.text('Q2'), 'B3': Cell.number(15), 'C3': Cell.number(6),
      'A4': Cell.text('Q3'), 'B4': Cell.text('n/a'), 'C4': Cell.number(8),
    });

    test('bar chart: columns are series, header row names them', () {
      final chart = buildChart(
        engine,
        kind: ChartKind.bar,
        categories: CellRange.tryParse('A2:A4')!,
        data: CellRange.tryParse('B1:C4')!,
      );
      expect(chart.categories, ['Q1', 'Q2', 'Q3']);
      expect(chart.series.map((s) => s.name), ['Sales', 'Costs']);
      expect(chart.series[0].values, [10, 15, null]); // text -> gap
      expect(chart.series[1].values, [4, 6, 8]);
    });

    test('pie chart: first series, gaps and non-positives dropped', () {
      final pie = buildChart(
        engine,
        kind: ChartKind.pie,
        categories: CellRange.tryParse('A2:A4')!,
        data: CellRange.tryParse('B1:B4')!,
      );
      expect(pie.series, hasLength(1));
      expect(pie.categories, ['Q1', 'Q2']);
      expect(pie.series.single.values, [10, 15]);
    });

    test('series in rows', () {
      final chart = buildChart(
        engine,
        kind: ChartKind.line,
        categories: CellRange.tryParse('A2:A3')!,
        data: CellRange.tryParse('B2:C3')!,
        hasHeader: false,
        seriesInRows: true,
      );
      expect(chart.series[0].values, [10, 4]);
      expect(chart.series[1].values, [15, 6]);
    });
  });

  group('pivot summary', () {
    final engine = engineFrom({
      'A1': Cell.text('fruit'), 'B1': Cell.number(10),
      'A2': Cell.text('veg'), 'B2': Cell.number(5),
      'A3': Cell.text('fruit'), 'B3': Cell.number(7),
      'A4': Cell.text('veg'), 'B4': Cell.number(3),
      'A5': Cell.text('fruit'), 'B5': Cell.text('bad'),
    });

    test('group by text key with sum and count', () {
      final range = CellRange.tryParse('A1:B5')!;
      final sums = pivotSummary(engine,
          range: range, keyColumn: 0, valueColumn: 1,
          aggregation: Aggregation.sum);
      expect(sums, [
        const PivotGroup(key: 'fruit', value: 17, rowCount: 3),
        const PivotGroup(key: 'veg', value: 8, rowCount: 2),
      ]);
      final counts = pivotSummary(engine,
          range: range, keyColumn: 0, valueColumn: 1,
          aggregation: Aggregation.count);
      expect(counts.map((g) => g.value), [3, 2]);
    });

    test('average ignores non-numeric values but counts their rows', () {
      final range = CellRange.tryParse('A1:B5')!;
      final avgs = pivotSummary(engine,
          range: range, keyColumn: 0, valueColumn: 1,
          aggregation: Aggregation.average);
      // fruit numeric values 10, 7 (row 5 'bad' ignored) -> 8.5
      expect(avgs.firstWhere((g) => g.key == 'fruit').value, 8.5);
      expect(avgs.firstWhere((g) => g.key == 'veg').value, 4);
    });

    test('numeric keys sort numerically before text keys', () {
      final e2 = engineFrom({
        'A1': Cell.number(10), 'B1': Cell.number(1),
        'A2': Cell.number(2), 'B2': Cell.number(1),
        'A3': Cell.text('x'), 'B3': Cell.number(1),
      });
      final groups = pivotSummary(e2,
          range: CellRange.tryParse('A1:B3')!,
          keyColumn: 0,
          valueColumn: 1,
          aggregation: Aggregation.count);
      expect(groups.map((g) => g.key), ['2', '10', 'x']);
    });
  });
}
