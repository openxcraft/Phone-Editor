import 'dart:math' as math;

import 'a1.dart';
import 'formula.dart';
import 'model.dart';

/// Supplies computed values to the evaluator. Implemented by the sheet
/// engine; the evaluator itself holds no grid state.
abstract interface class ValueProvider {
  /// The already-computed value of [ref] (EmptyValue for unset cells).
  CellValue valueAt(CellRef ref);
}

/// An evaluation result: either a scalar or a range of values.
sealed class EvalResult {
  const EvalResult();
}

final class ScalarResult extends EvalResult {
  const ScalarResult(this.value);
  final CellValue value;
}

final class RangeResult extends EvalResult {
  const RangeResult(this.range, this.values);

  final CellRange range;

  /// Row-major values, `values[row][col]`, dimensions match [range].
  final List<List<CellValue>> values;

  Iterable<CellValue> get flat sync* {
    for (final row in values) {
      yield* row;
    }
  }
}

/// Evaluates formula ASTs.
///
/// No wall clock is read here: `TODAY()` uses the injected [today]
/// provider and returns `#VALUE!` when none was supplied.
class Evaluator {
  Evaluator({required ValueProvider values, DateTime Function()? today})
      : _values = values,
        _today = today;

  final ValueProvider _values;
  final DateTime Function()? _today;

  /// Evaluates [node] and coerces the outcome to a scalar cell value.
  /// A range where a scalar is required yields `#VALUE!`.
  CellValue evaluateScalar(AstNode node) {
    final result = evaluate(node);
    return switch (result) {
      ScalarResult s => s.value,
      RangeResult _ => const ErrorValue(ErrorCodes.value),
    };
  }

  EvalResult evaluate(AstNode node) {
    switch (node) {
      case NumberNode n:
        return ScalarResult(NumberValue(n.value));
      case StringNode n:
        return ScalarResult(TextValue(n.value));
      case BoolNode n:
        return ScalarResult(BoolValue(n.value));
      case RefNode n:
        return ScalarResult(_values.valueAt(n.ref));
      case RangeNode n:
        final values = <List<CellValue>>[];
        for (var r = n.range.start.row; r <= n.range.end.row; r++) {
          final row = <CellValue>[];
          for (var c = n.range.start.col; c <= n.range.end.col; c++) {
            row.add(_values.valueAt(CellRef(r, c)));
          }
          values.add(row);
        }
        return RangeResult(n.range, values);
      case PercentNode n:
        final v = _asNumber(evaluateScalar(n.operand));
        return v is ErrorValue
            ? ScalarResult(v)
            : ScalarResult(NumberValue((v as NumberValue).value / 100));
      case UnaryNode n:
        final v = _asNumber(evaluateScalar(n.operand));
        if (v is ErrorValue) return ScalarResult(v);
        final numValue = (v as NumberValue).value;
        return ScalarResult(
            NumberValue(n.op == '-' ? -numValue : numValue));
      case BinaryNode n:
        return ScalarResult(_evaluateBinary(n));
      case FunctionNode n:
        return ScalarResult(_callFunction(n));
    }
  }

  // --- Scalar coercion --------------------------------------------------------

  /// Excel-style numeric coercion: empty → 0, bool → 1/0, numeric text
  /// parses, other text → #VALUE!. Errors pass through.
  CellValue _asNumber(CellValue v) {
    switch (v) {
      case NumberValue n:
        return n;
      case EmptyValue _:
        return const NumberValue(0);
      case BoolValue b:
        return NumberValue(b.value ? 1 : 0);
      case TextValue t:
        final parsed = double.tryParse(t.value.trim());
        return parsed == null
            ? const ErrorValue(ErrorCodes.value)
            : NumberValue(parsed);
      case ErrorValue e:
        return e;
    }
  }

  /// Boolean coercion: empty → FALSE, numbers ≠ 0, "TRUE"/"FALSE" text.
  CellValue _asBool(CellValue v) {
    switch (v) {
      case BoolValue b:
        return b;
      case EmptyValue _:
        return const BoolValue(false);
      case NumberValue n:
        return BoolValue(n.value != 0);
      case TextValue t:
        final up = t.value.trim().toUpperCase();
        if (up == 'TRUE') return const BoolValue(true);
        if (up == 'FALSE') return const BoolValue(false);
        return const ErrorValue(ErrorCodes.value);
      case ErrorValue e:
        return e;
    }
  }

  /// Display string for concatenation / text functions.
  String stringify(CellValue v) => switch (v) {
        EmptyValue _ => '',
        NumberValue n => formatNumber(n.value),
        TextValue t => t.value,
        BoolValue b => b.value ? 'TRUE' : 'FALSE',
        ErrorValue e => e.code,
      };

  // --- Operators ---------------------------------------------------------------

  CellValue _evaluateBinary(BinaryNode node) {
    if (node.op == '&') {
      final l = evaluateScalar(node.left);
      if (l is ErrorValue) return l;
      final r = evaluateScalar(node.right);
      if (r is ErrorValue) return r;
      return TextValue(stringify(l) + stringify(r));
    }

    if (const {'=', '<>', '<', '<=', '>', '>='}.contains(node.op)) {
      final l = evaluateScalar(node.left);
      if (l is ErrorValue) return l;
      final r = evaluateScalar(node.right);
      if (r is ErrorValue) return r;
      return _compare(node.op, l, r);
    }

    final l = _asNumber(evaluateScalar(node.left));
    if (l is ErrorValue) return l;
    final r = _asNumber(evaluateScalar(node.right));
    if (r is ErrorValue) return r;
    final a = (l as NumberValue).value;
    final b = (r as NumberValue).value;
    final result = switch (node.op) {
      '+' => a + b,
      '-' => a - b,
      '*' => a * b,
      '/' => b == 0 ? null : a / b,
      '^' => math.pow(a, b).toDouble(),
      _ => null,
    };
    if (node.op == '/' && b == 0) {
      return const ErrorValue(ErrorCodes.divByZero);
    }
    if (result == null || result.isNaN || result.isInfinite) {
      return const ErrorValue(ErrorCodes.value);
    }
    return NumberValue(result);
  }

  CellValue _compare(String op, CellValue l, CellValue r) {
    final a = l is EmptyValue ? const NumberValue(0) : l;
    final b = r is EmptyValue ? const NumberValue(0) : r;
    int cmp;
    if (a is NumberValue && b is NumberValue) {
      cmp = a.value.compareTo(b.value);
    } else if (a is TextValue && b is TextValue) {
      cmp = a.value.toLowerCase().compareTo(b.value.toLowerCase());
    } else if (a is BoolValue && b is BoolValue) {
      cmp = (a.value ? 1 : 0).compareTo(b.value ? 1 : 0);
    } else if (op == '=') {
      return const BoolValue(false);
    } else if (op == '<>') {
      return const BoolValue(true);
    } else {
      return const ErrorValue(ErrorCodes.value);
    }
    return BoolValue(switch (op) {
      '=' => cmp == 0,
      '<>' => cmp != 0,
      '<' => cmp < 0,
      '<=' => cmp <= 0,
      '>' => cmp > 0,
      '>=' => cmp >= 0,
      _ => false,
    });
  }

  // --- Function dispatch ---------------------------------------------------------

  static const Set<String> functionNames = <String>{
    'SUM', 'AVERAGE', 'MIN', 'MAX', 'COUNT', 'COUNTA',
    'IF', 'AND', 'OR', 'NOT',
    'ABS', 'ROUND', 'SQRT', 'POWER',
    'CONCAT', 'LEFT', 'RIGHT', 'LEN', 'UPPER', 'LOWER',
    'DATE', 'YEAR', 'MONTH', 'DAY', 'TODAY',
    'VLOOKUP', 'INDEX', 'MATCH', 'SUMIF',
    'STDEV', 'MEDIAN',
  };

  CellValue _callFunction(FunctionNode node) {
    if (!functionNames.contains(node.name)) {
      return const ErrorValue(ErrorCodes.name);
    }
    // IF is lazy: the untaken branch is never evaluated, so an error in
    // it does not propagate.
    if (node.name == 'IF') return _fnIf(node.args);

    switch (node.name) {
      case 'SUM':
        return _aggregate(node.args, _Aggregate.sum);
      case 'AVERAGE':
        return _aggregate(node.args, _Aggregate.average);
      case 'MIN':
        return _aggregate(node.args, _Aggregate.min);
      case 'MAX':
        return _aggregate(node.args, _Aggregate.max);
      case 'STDEV':
        return _aggregate(node.args, _Aggregate.stdev);
      case 'MEDIAN':
        return _aggregate(node.args, _Aggregate.median);
      case 'COUNT':
        return _count(node.args, countAll: false);
      case 'COUNTA':
        return _count(node.args, countAll: true);
      case 'AND':
        return _logic(node.args, isAnd: true);
      case 'OR':
        return _logic(node.args, isAnd: false);
      case 'NOT':
        if (node.args.length != 1) {
          return const ErrorValue(ErrorCodes.value);
        }
        final v = _asBool(evaluateScalar(node.args[0]));
        return v is ErrorValue ? v : BoolValue(!(v as BoolValue).value);
      case 'ABS':
        return _unaryNumeric(node.args, (x) => x.abs());
      case 'SQRT':
        return _unaryNumeric(node.args, (x) {
          if (x < 0) return null;
          return math.sqrt(x);
        });
      case 'ROUND':
        if (node.args.isEmpty || node.args.length > 2) {
          return const ErrorValue(ErrorCodes.value);
        }
        final x = _numArg(node.args, 0);
        if (x is ErrorValue) return x;
        var digits = 0;
        if (node.args.length == 2) {
          final d = _numArg(node.args, 1);
          if (d is ErrorValue) return d;
          digits = (d as NumberValue).value.toInt();
        }
        final factor = math.pow(10, digits).toDouble();
        final rounded = ((x as NumberValue).value * factor).round() / factor;
        return NumberValue(rounded);
      case 'POWER':
        if (node.args.length != 2) {
          return const ErrorValue(ErrorCodes.value);
        }
        final base = _numArg(node.args, 0);
        if (base is ErrorValue) return base;
        final exp = _numArg(node.args, 1);
        if (exp is ErrorValue) return exp;
        final result = math
            .pow((base as NumberValue).value, (exp as NumberValue).value)
            .toDouble();
        return result.isNaN || result.isInfinite
            ? const ErrorValue(ErrorCodes.value)
            : NumberValue(result);
      case 'CONCAT':
        final buf = StringBuffer();
        for (final arg in node.args) {
          final result = evaluate(arg);
          if (result is ScalarResult) {
            if (result.value is ErrorValue) return result.value;
            buf.write(stringify(result.value));
          } else if (result is RangeResult) {
            for (final v in result.flat) {
              if (v is ErrorValue) return v;
              buf.write(stringify(v));
            }
          }
        }
        return TextValue(buf.toString());
      case 'LEFT':
        return _leftRight(node.args, isLeft: true);
      case 'RIGHT':
        return _leftRight(node.args, isLeft: false);
      case 'LEN':
        if (node.args.length != 1) {
          return const ErrorValue(ErrorCodes.value);
        }
        final v = evaluateScalar(node.args[0]);
        if (v is ErrorValue) return v;
        return NumberValue(stringify(v).runes.length.toDouble());
      case 'UPPER':
        return _textCase(node.args, upper: true);
      case 'LOWER':
        return _textCase(node.args, upper: false);
      case 'DATE':
        if (node.args.length != 3) {
          return const ErrorValue(ErrorCodes.value);
        }
        final parts = <int>[];
        for (var i = 0; i < 3; i++) {
          final v = _numArg(node.args, i);
          if (v is ErrorValue) return v;
          parts.add((v as NumberValue).value.toInt());
        }
        return NumberValue(
            dateToSerial(DateTime.utc(parts[0], parts[1], parts[2])));
      case 'YEAR':
        return _datePart(node.args, (d) => d.year);
      case 'MONTH':
        return _datePart(node.args, (d) => d.month);
      case 'DAY':
        return _datePart(node.args, (d) => d.day);
      case 'TODAY':
        if (node.args.isNotEmpty) {
          return const ErrorValue(ErrorCodes.value);
        }
        final provider = _today;
        if (provider == null) {
          // No injected clock: deterministic engines must not guess.
          return const ErrorValue(ErrorCodes.value);
        }
        final now = provider();
        return NumberValue(dateToSerial(
            DateTime.utc(now.year, now.month, now.day)));
      case 'VLOOKUP':
        return _vlookup(node.args);
      case 'INDEX':
        return _index(node.args);
      case 'MATCH':
        return _match(node.args);
      case 'SUMIF':
        return _sumIf(node.args);
      default:
        return const ErrorValue(ErrorCodes.name);
    }
  }

  /// Numeric scalar argument, coerced; error values propagate.
  CellValue _numArg(List<AstNode> args, int index) =>
      _asNumber(evaluateScalar(args[index]));

  CellValue _fnIf(List<AstNode> args) {
    if (args.length < 2 || args.length > 3) {
      return const ErrorValue(ErrorCodes.value);
    }
    final cond = _asBool(evaluateScalar(args[0]));
    if (cond is ErrorValue) return cond;
    if ((cond as BoolValue).value) {
      return evaluateScalar(args[1]);
    }
    return args.length == 3
        ? evaluateScalar(args[2])
        : const BoolValue(false);
  }

  CellValue _unaryNumeric(List<AstNode> args, double? Function(double) fn) {
    if (args.length != 1) return const ErrorValue(ErrorCodes.value);
    final v = _numArg(args, 0);
    if (v is ErrorValue) return v;
    final result = fn((v as NumberValue).value);
    return result == null || result.isNaN || result.isInfinite
        ? const ErrorValue(ErrorCodes.value)
        : NumberValue(result);
  }

  CellValue _textCase(List<AstNode> args, {required bool upper}) {
    if (args.length != 1) return const ErrorValue(ErrorCodes.value);
    final v = evaluateScalar(args[0]);
    if (v is ErrorValue) return v;
    final s = stringify(v);
    return TextValue(upper ? s.toUpperCase() : s.toLowerCase());
  }

  CellValue _leftRight(List<AstNode> args, {required bool isLeft}) {
    if (args.isEmpty || args.length > 2) {
      return const ErrorValue(ErrorCodes.value);
    }
    final v = evaluateScalar(args[0]);
    if (v is ErrorValue) return v;
    var count = 1;
    if (args.length == 2) {
      final n = _numArg(args, 1);
      if (n is ErrorValue) return n;
      count = (n as NumberValue).value.toInt();
    }
    if (count < 0) return const ErrorValue(ErrorCodes.value);
    final runes = stringify(v).runes.toList();
    if (count >= runes.length) return TextValue(stringify(v));
    final slice = isLeft
        ? runes.sublist(0, count)
        : runes.sublist(runes.length - count);
    return TextValue(String.fromCharCodes(slice));
  }

  // --- Aggregates ------------------------------------------------------------

  /// Numbers from an argument list. Scalar arguments are coerced (text
  /// numbers count, bad text errors); inside ranges only genuine numbers
  /// count and errors propagate — except COUNT/COUNTA, handled separately.
  ({List<double> numbers, CellValue? error}) _collectNumbers(
      List<AstNode> args) {
    final numbers = <double>[];
    for (final arg in args) {
      final result = evaluate(arg);
      if (result is ScalarResult) {
        final n = _asNumber(result.value);
        if (n is ErrorValue) return (numbers: numbers, error: n);
        numbers.add((n as NumberValue).value);
      } else if (result is RangeResult) {
        for (final v in result.flat) {
          if (v is ErrorValue) return (numbers: numbers, error: v);
          if (v is NumberValue) numbers.add(v.value);
        }
      }
    }
    return (numbers: numbers, error: null);
  }

  CellValue _aggregate(List<AstNode> args, _Aggregate kind) {
    final collected = _collectNumbers(args);
    if (collected.error != null) return collected.error!;
    final nums = collected.numbers;
    switch (kind) {
      case _Aggregate.sum:
        return NumberValue(nums.fold(0.0, (a, b) => a + b));
      case _Aggregate.average:
        if (nums.isEmpty) return const ErrorValue(ErrorCodes.divByZero);
        return NumberValue(nums.fold(0.0, (a, b) => a + b) / nums.length);
      case _Aggregate.min:
        if (nums.isEmpty) return const NumberValue(0);
        return NumberValue(nums.reduce(math.min));
      case _Aggregate.max:
        if (nums.isEmpty) return const NumberValue(0);
        return NumberValue(nums.reduce(math.max));
      case _Aggregate.stdev:
        if (nums.length < 2) {
          return const ErrorValue(ErrorCodes.divByZero);
        }
        final mean = nums.fold(0.0, (a, b) => a + b) / nums.length;
        var acc = 0.0;
        for (final n in nums) {
          acc += (n - mean) * (n - mean);
        }
        return NumberValue(math.sqrt(acc / (nums.length - 1)));
      case _Aggregate.median:
        if (nums.isEmpty) return const ErrorValue(ErrorCodes.value);
        final sorted = List<double>.of(nums)..sort();
        final mid = sorted.length ~/ 2;
        return NumberValue(sorted.length.isOdd
            ? sorted[mid]
            : (sorted[mid - 1] + sorted[mid]) / 2);
    }
  }

  CellValue _count(List<AstNode> args, {required bool countAll}) {
    var count = 0;
    for (final arg in args) {
      final result = evaluate(arg);
      if (result is ScalarResult) {
        final v = result.value;
        if (countAll) {
          if (v is! EmptyValue) count++;
        } else {
          // Scalars: numbers and numeric text count; booleans do not.
          if (v is NumberValue) count++;
          if (v is TextValue && double.tryParse(v.value.trim()) != null) {
            count++;
          }
        }
      } else if (result is RangeResult) {
        for (final v in result.flat) {
          if (countAll) {
            if (v is! EmptyValue) count++;
          } else if (v is NumberValue) {
            count++;
          }
        }
      }
    }
    return NumberValue(count.toDouble());
  }

  CellValue _logic(List<AstNode> args, {required bool isAnd}) {
    var seen = false;
    var acc = isAnd;
    for (final arg in args) {
      final result = evaluate(arg);
      final Iterable<CellValue> values = result is RangeResult
          ? result.flat
          : <CellValue>[(result as ScalarResult).value];
      for (final v in values) {
        if (v is ErrorValue) return v;
        if (v is EmptyValue) continue;
        if (v is TextValue &&
            v.value.trim().toUpperCase() != 'TRUE' &&
            v.value.trim().toUpperCase() != 'FALSE') {
          continue; // text in ranges is ignored
        }
        final b = _asBool(v);
        if (b is ErrorValue) return b;
        seen = true;
        acc = isAnd
            ? acc && (b as BoolValue).value
            : acc || (b as BoolValue).value;
      }
    }
    if (!seen) return const ErrorValue(ErrorCodes.value);
    return BoolValue(acc);
  }

  // --- Dates -------------------------------------------------------------------

  /// Days since 1899-12-30. This is uniformly one more than the legacy
  /// 1900-system serial for the same real date (that system additionally
  /// contains a fictitious 1900-02-29, which is not reproduced here).
  /// Serials are internally consistent: DATE/YEAR/MONTH/DAY round-trip.
  static double dateToSerial(DateTime date) {
    final epoch = DateTime.utc(1899, 12, 30);
    final day = DateTime.utc(date.year, date.month, date.day);
    return day.difference(epoch).inDays.toDouble();
  }

  static DateTime serialToDate(double serial) {
    final epoch = DateTime.utc(1899, 12, 30);
    return epoch.add(Duration(days: serial.truncate()));
  }

  CellValue _datePart(List<AstNode> args, int Function(DateTime) part) {
    if (args.length != 1) return const ErrorValue(ErrorCodes.value);
    final v = _numArg(args, 0);
    if (v is ErrorValue) return v;
    return NumberValue(
        part(serialToDate((v as NumberValue).value)).toDouble());
  }

  // --- Lookup --------------------------------------------------------------------

  RangeResult? _rangeArg(List<AstNode> args, int index) {
    final result = evaluate(args[index]);
    return result is RangeResult ? result : null;
  }

  CellValue _vlookup(List<AstNode> args) {
    if (args.length < 3 || args.length > 4) {
      return const ErrorValue(ErrorCodes.value);
    }
    final key = evaluateScalar(args[0]);
    if (key is ErrorValue) return key;
    final table = _rangeArg(args, 1);
    if (table == null) return const ErrorValue(ErrorCodes.value);
    final colNum = _numArg(args, 2);
    if (colNum is ErrorValue) return colNum;
    final colIndex = (colNum as NumberValue).value.toInt();
    if (colIndex < 1 || colIndex > table.range.colCount) {
      return const ErrorValue(ErrorCodes.ref);
    }
    var exact = true;
    if (args.length == 4) {
      final flag = _asBool(evaluateScalar(args[3]));
      if (flag is ErrorValue) return flag;
      exact = !(flag as BoolValue).value;
    }
    if (exact) {
      for (final row in table.values) {
        if (_compare('=', row[0], key) == const BoolValue(true)) {
          return row[colIndex - 1];
        }
      }
      return const ErrorValue(ErrorCodes.notAvailable);
    }
    // Approximate: last row whose key is <= the lookup value (numeric).
    final keyNum = _asNumber(key);
    if (keyNum is ErrorValue) return keyNum;
    var matchRow = -1;
    for (var i = 0; i < table.values.length; i++) {
      final cellNum = _asNumber(table.values[i][0]);
      if (cellNum is NumberValue &&
          cellNum.value <= (keyNum as NumberValue).value) {
        matchRow = i;
      }
    }
    if (matchRow < 0) return const ErrorValue(ErrorCodes.notAvailable);
    return table.values[matchRow][colIndex - 1];
  }

  CellValue _index(List<AstNode> args) {
    if (args.length < 2 || args.length > 3) {
      return const ErrorValue(ErrorCodes.value);
    }
    // INDEX also accepts a scalar as a 1x1 range.
    final result = evaluate(args[0]);
    final List<List<CellValue>> grid;
    if (result is RangeResult) {
      grid = result.values;
    } else {
      grid = <List<CellValue>>[
        <CellValue>[(result as ScalarResult).value]
      ];
    }
    final rowNum = _numArg(args, 1);
    if (rowNum is ErrorValue) return rowNum;
    final rowIndex = (rowNum as NumberValue).value.toInt();
    var colIndex = 1;
    if (args.length == 3) {
      final colNum = _numArg(args, 2);
      if (colNum is ErrorValue) return colNum;
      colIndex = (colNum as NumberValue).value.toInt();
    } else if (grid.length == 1 && grid[0].length > 1) {
      // Single-row range with two args: the number indexes the row.
      colIndex = rowIndex;
      if (colIndex < 1 || colIndex > grid[0].length) {
        return const ErrorValue(ErrorCodes.ref);
      }
      return grid[0][colIndex - 1];
    }
    if (rowIndex < 1 ||
        rowIndex > grid.length ||
        colIndex < 1 ||
        colIndex > grid[0].length) {
      return const ErrorValue(ErrorCodes.ref);
    }
    return grid[rowIndex - 1][colIndex - 1];
  }

  CellValue _match(List<AstNode> args) {
    if (args.length < 2 || args.length > 3) {
      return const ErrorValue(ErrorCodes.value);
    }
    final key = evaluateScalar(args[0]);
    if (key is ErrorValue) return key;
    final result = evaluate(args[1]);
    final List<CellValue> items;
    if (result is RangeResult) {
      if (result.range.rowCount != 1 && result.range.colCount != 1) {
        return const ErrorValue(ErrorCodes.value);
      }
      items = result.flat.toList();
    } else {
      items = <CellValue>[(result as ScalarResult).value];
    }
    var matchType = 0;
    if (args.length == 3) {
      final t = _numArg(args, 2);
      if (t is ErrorValue) return t;
      matchType = (t as NumberValue).value.toInt();
    }
    if (matchType == 0) {
      for (var i = 0; i < items.length; i++) {
        if (_compare('=', items[i], key) == const BoolValue(true)) {
          return NumberValue((i + 1).toDouble());
        }
      }
      return const ErrorValue(ErrorCodes.notAvailable);
    }
    final keyNum = _asNumber(key);
    if (keyNum is ErrorValue) return keyNum;
    final target = (keyNum as NumberValue).value;
    if (matchType == 1) {
      var found = -1;
      for (var i = 0; i < items.length; i++) {
        final n = _asNumber(items[i]);
        if (n is NumberValue && n.value <= target) found = i;
      }
      return found < 0
          ? const ErrorValue(ErrorCodes.notAvailable)
          : NumberValue((found + 1).toDouble());
    }
    // matchType == -1: smallest value >= key.
    var found = -1;
    for (var i = 0; i < items.length; i++) {
      final n = _asNumber(items[i]);
      if (n is NumberValue && n.value >= target) {
        found = i;
        break;
      }
    }
    return found < 0
        ? const ErrorValue(ErrorCodes.notAvailable)
        : NumberValue((found + 1).toDouble());
  }

  CellValue _sumIf(List<AstNode> args) {
    if (args.length < 2 || args.length > 3) {
      return const ErrorValue(ErrorCodes.value);
    }
    final criteriaRange = _rangeArg(args, 0);
    if (criteriaRange == null) return const ErrorValue(ErrorCodes.value);
    final criteria = evaluateScalar(args[1]);
    if (criteria is ErrorValue) return criteria;
    final sumRange = args.length == 3 ? _rangeArg(args, 2) : criteriaRange;
    if (sumRange == null) return const ErrorValue(ErrorCodes.value);
    final criteriaCells = criteriaRange.flat.toList();
    final sumCells = sumRange.flat.toList();
    final matcher = _criteriaMatcher(criteria);
    if (matcher == null) return const ErrorValue(ErrorCodes.value);
    var total = 0.0;
    final n = criteriaCells.length < sumCells.length
        ? criteriaCells.length
        : sumCells.length;
    for (var i = 0; i < n; i++) {
      if (criteriaCells[i] is ErrorValue) return criteriaCells[i];
      if (matcher(criteriaCells[i])) {
        final v = sumCells[i];
        if (v is ErrorValue) return v;
        if (v is NumberValue) total += v.value;
      }
    }
    return NumberValue(total);
  }

  /// Builds a predicate from a SUMIF-style criteria value: a string may
  /// carry a leading operator (`>=`, `<=`, `<>`, `>`, `<`, `=`), a number
  /// means numeric equality, other text is case-insensitive equality.
  bool Function(CellValue)? _criteriaMatcher(CellValue criteria) {
    if (criteria is NumberValue) {
      return (v) {
        final n = _asNumber(v);
        return n is NumberValue && n.value == criteria.value;
      };
    }
    if (criteria is BoolValue) {
      return (v) => v is BoolValue && v.value == criteria.value;
    }
    if (criteria is! TextValue) return null;
    var text = criteria.value.trim();
    var op = '=';
    for (final candidate in const ['>=', '<=', '<>', '>', '<', '=']) {
      if (text.startsWith(candidate)) {
        op = candidate;
        text = text.substring(candidate.length).trim();
        break;
      }
    }
    final numeric = double.tryParse(text);
    if (numeric != null) {
      return (v) {
        final n = _asNumber(v);
        if (n is! NumberValue) return op == '<>';
        return _compare(op, n, NumberValue(numeric)) ==
            const BoolValue(true);
      };
    }
    final needle = text.toLowerCase();
    return (v) {
      if (op == '=') {
        return v is TextValue && v.value.toLowerCase() == needle;
      }
      if (op == '<>') {
        return !(v is TextValue && v.value.toLowerCase() == needle);
      }
      if (v is! TextValue) return false;
      return _compare(op, v, TextValue(text)) == const BoolValue(true);
    };
  }
}

enum _Aggregate { sum, average, min, max, stdev, median }
