import 'package:sheets_engine/sheets_engine.dart';
import 'package:test/test.dart';

/// Evaluates a single formula in Z100 (far from every test's data) against
/// a sheet built from [inputs] (A1-style ref → stored cell).
CellValue evalFormula(
  String formula, {
  Map<String, Cell> inputs = const {},
  DateTime Function()? today,
}) {
  final sheet = Sheet();
  inputs.forEach((ref, cell) {
    sheet.setCell(CellRef.tryParse(ref)!, cell);
  });
  sheet.setCell(CellRef.tryParse('Z100')!, Cell.formula(formula));
  return SheetEngine(sheet, today: today)
      .valueAt(CellRef.tryParse('Z100')!);
}

double asNum(CellValue v) => (v as NumberValue).value;
String errOf(CellValue v) => (v as ErrorValue).code;

void main() {
  group('parser & precedence', () {
    test('arithmetic precedence and parentheses', () {
      expect(asNum(evalFormula('=1+2*3')), 7);
      expect(asNum(evalFormula('=(1+2)*3')), 9);
      expect(asNum(evalFormula('=2^3^2')), 64); // ^ is left-associative
      expect(asNum(evalFormula('=10-4-3')), 3);
      expect(asNum(evalFormula('=20/5/2')), 2);
    });

    test('unary minus and percent', () {
      expect(asNum(evalFormula('=-5+3')), -2);
      expect(asNum(evalFormula('=50%')), 0.5);
      expect(asNum(evalFormula('=200*10%')), 20);
    });

    test('concatenation binds looser than addition, tighter than compare',
        () {
      expect(evalFormula('="a"&1+2'), const TextValue('a3'));
      expect(evalFormula('=1+1=2'), const BoolValue(true));
      expect(evalFormula('="b">"A"'), const BoolValue(true));
    });

    test('AST dependency extraction includes range cells', () {
      final ast = parseFormula('=SUM(A1:B2)+C3');
      final deps = astDependencies(ast).map((r) => r.toA1()).toSet();
      expect(deps, {'A1', 'B1', 'A2', 'B2', 'C3'});
    });

    test('syntax errors map to typed cell errors', () {
      expect(errOf(evalFormula('=A0+1')), '#REF!');
      expect(errOf(evalFormula('=1+')), '#VALUE!');
      expect(errOf(evalFormula('=NOSUCHFN(1)')), '#NAME?');
    });
  });

  group('operators & coercion', () {
    test('division by zero', () {
      expect(errOf(evalFormula('=1/0')), '#DIV/0!');
      expect(errOf(evalFormula('=1/(2-2)')), '#DIV/0!');
    });

    test('empty ref is 0; numeric text coerces; bad text errors', () {
      expect(asNum(evalFormula('=Z9+5')), 5);
      expect(asNum(evalFormula('="2"*3')), 6);
      expect(errOf(evalFormula('="x"+1')), '#VALUE!');
    });

    test('errors propagate through arithmetic', () {
      final v = evalFormula('=A1+1',
          inputs: {'A1': Cell.error('#DIV/0!')});
      expect(errOf(v), '#DIV/0!');
    });

    test('range used as scalar is #VALUE!', () {
      expect(errOf(evalFormula('=A1:A2+1')), '#VALUE!');
    });
  });

  group('functions: math & statistical', () {
    final inputs = <String, Cell>{
      'A1': Cell.number(1),
      'A2': Cell.number(2),
      'A3': Cell.number(3),
      'A4': Cell.number(4),
    };

    test('aggregates over ranges and scalars', () {
      expect(asNum(evalFormula('=SUM(A1:A4)', inputs: inputs)), 10);
      expect(asNum(evalFormula('=AVERAGE(A1:A4)', inputs: inputs)), 2.5);
      expect(asNum(evalFormula('=MIN(A1:A4, -5)', inputs: inputs)), -5);
      expect(asNum(evalFormula('=MAX(A1:A4)', inputs: inputs)), 4);
      expect(asNum(evalFormula('=MEDIAN(A1:A4)', inputs: inputs)), 2.5);
      expect(asNum(evalFormula('=COUNT(A1:A4)', inputs: inputs)), 4);
    });

    test('STDEV is the sample standard deviation', () {
      // Values 2,4,4,4,5,5,7,9 -> sample sd = 2.138089935...
      final data = <String, Cell>{
        for (var i = 0; i < 8; i++)
          'A${i + 1}': Cell.number([2, 4, 4, 4, 5, 5, 7, 9][i].toDouble()),
      };
      expect(asNum(evalFormula('=STDEV(A1:A8)', inputs: data)),
          closeTo(2.138089935299395, 1e-9));
      expect(errOf(evalFormula('=STDEV(A1)', inputs: data)), '#DIV/0!');
    });

    test('ABS, ROUND, SQRT, POWER', () {
      expect(asNum(evalFormula('=ABS(-3)')), 3);
      expect(asNum(evalFormula('=ROUND(2.567, 2)')), 2.57);
      expect(asNum(evalFormula('=ROUND(1234, -2)')), 1200);
      expect(asNum(evalFormula('=SQRT(16)')), 4);
      expect(errOf(evalFormula('=SQRT(-1)')), '#VALUE!');
      expect(asNum(evalFormula('=POWER(2, 10)')), 1024);
    });

    test('AVERAGE of no numbers is #DIV/0!; MIN of empty is 0', () {
      expect(errOf(evalFormula('=AVERAGE(C1:C3)')), '#DIV/0!');
      expect(asNum(evalFormula('=MIN(C1:C3)')), 0);
    });
  });

  group('functions: logic & text', () {
    test('IF is lazy — the untaken branch error is ignored', () {
      expect(asNum(evalFormula('=IF(TRUE, 7, 1/0)')), 7);
      expect(asNum(evalFormula('=IF(1>2, 1/0, 8)')), 8);
      expect(evalFormula('=IF(FALSE, 1)'), const BoolValue(false));
    });

    test('AND / OR / NOT with coercion', () {
      expect(evalFormula('=AND(TRUE, 1, 2>1)'), const BoolValue(true));
      expect(evalFormula('=AND(TRUE, FALSE)'), const BoolValue(false));
      expect(evalFormula('=OR(FALSE, 0, "TRUE")'), const BoolValue(true));
      expect(evalFormula('=NOT(FALSE)'), const BoolValue(true));
    });

    test('text functions are rune-based', () {
      expect(evalFormula('=UPPER("aBc")'), const TextValue('ABC'));
      expect(evalFormula('=LOWER("AbC")'), const TextValue('abc'));
      expect(asNum(evalFormula('=LEN("héllo")')), 5);
      expect(evalFormula('=LEFT("hello", 2)'), const TextValue('he'));
      expect(evalFormula('=RIGHT("hello", 2)'), const TextValue('lo'));
      expect(evalFormula('=CONCAT("a", "b", 1)'), const TextValue('ab1'));
      expect(evalFormula('=CONCAT(A1:A2)',
          inputs: {'A1': Cell.text('x'), 'A2': Cell.text('y')}),
          const TextValue('xy'));
    });

    test('COUNT vs COUNTA', () {
      final inputs = <String, Cell>{
        'A1': Cell.number(1),
        'A2': Cell.text('text'),
        'A3': Cell.boolean(true),
        // A4 empty
        'A5': Cell.error('#N/A'),
      };
      expect(asNum(evalFormula('=COUNT(A1:A5)', inputs: inputs)), 1);
      expect(asNum(evalFormula('=COUNTA(A1:A5)', inputs: inputs)), 4);
    });
  });

  group('functions: dates (no wall clock)', () {
    test('DATE/YEAR/MONTH/DAY round-trip', () {
      expect(asNum(evalFormula('=YEAR(DATE(2024, 2, 29))')), 2024);
      expect(asNum(evalFormula('=MONTH(DATE(2024, 2, 29))')), 2);
      expect(asNum(evalFormula('=DAY(DATE(2024, 2, 29))')), 29);
      expect(
          asNum(evalFormula('=DATE(2024, 1, 2) - DATE(2024, 1, 1)')), 1);
    });

    test('TODAY uses the injected date; without one it is #VALUE!', () {
      final fixed = DateTime.utc(2025, 6, 15);
      expect(asNum(evalFormula('=YEAR(TODAY())', today: () => fixed)),
          2025);
      expect(asNum(evalFormula('=MONTH(TODAY())', today: () => fixed)), 6);
      expect(errOf(evalFormula('=TODAY()')), '#VALUE!');
    });
  });

  group('functions: lookup', () {
    final table = <String, Cell>{
      'A1': Cell.text('apple'), 'B1': Cell.number(10),
      'A2': Cell.text('pear'), 'B2': Cell.number(20),
      'A3': Cell.text('fig'), 'B3': Cell.number(30),
      'D1': Cell.number(5), 'D2': Cell.number(15), 'D3': Cell.number(25),
    };

    test('VLOOKUP exact match and miss', () {
      expect(
          asNum(evalFormula('=VLOOKUP("pear", A1:B3, 2, FALSE)',
              inputs: table)),
          20);
      expect(
          errOf(evalFormula('=VLOOKUP("plum", A1:B3, 2, FALSE)',
              inputs: table)),
          '#N/A');
    });

    test('VLOOKUP bad column is #REF!', () {
      expect(
          errOf(evalFormula('=VLOOKUP("fig", A1:B3, 3, FALSE)',
              inputs: table)),
          '#REF!');
    });

    test('INDEX and MATCH', () {
      expect(asNum(evalFormula('=INDEX(B1:B3, 3)', inputs: table)), 30);
      expect(asNum(evalFormula('=INDEX(A1:B3, 2, 2)', inputs: table)), 20);
      expect(errOf(evalFormula('=INDEX(B1:B3, 4)', inputs: table)),
          '#REF!');
      expect(
          asNum(evalFormula('=MATCH("fig", A1:A3, 0)', inputs: table)), 3);
      expect(
          asNum(evalFormula('=MATCH(17, D1:D3, 1)', inputs: table)), 2);
      expect(errOf(evalFormula('=MATCH("plum", A1:A3, 0)', inputs: table)),
          '#N/A');
    });

    test('SUMIF with numeric and text criteria', () {
      final inputs = <String, Cell>{
        'A1': Cell.text('a'), 'B1': Cell.number(5),
        'A2': Cell.text('b'), 'B2': Cell.number(15),
        'A3': Cell.text('a'), 'B3': Cell.number(25),
      };
      expect(
          asNum(evalFormula('=SUMIF(A1:A3, "a", B1:B3)', inputs: inputs)),
          30);
      expect(
          asNum(evalFormula('=SUMIF(B1:B3, ">=10")', inputs: inputs)), 40);
    });
  });
}
