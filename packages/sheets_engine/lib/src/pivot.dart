import 'a1.dart';
import 'engine.dart';
import 'model.dart';

/// Aggregation for [pivotSummary].
enum Aggregation { sum, count, average }

class PivotGroup {
  const PivotGroup({
    required this.key,
    required this.value,
    required this.rowCount,
  });

  /// Display form of the grouping key.
  final String key;

  /// Aggregated value. For [Aggregation.count] this is the number of
  /// rows in the group (as a double, like every other result).
  final double value;

  /// Rows contributing to the group.
  final int rowCount;

  @override
  bool operator ==(Object other) =>
      other is PivotGroup &&
      other.key == key &&
      other.value == value &&
      other.rowCount == rowCount;

  @override
  int get hashCode => Object.hash(key, value, rowCount);

  @override
  String toString() => 'PivotGroup($key, $value, rows=$rowCount)';
}

/// Pivot-like summary: groups the rows of [range] by the computed value
/// of the column at offset [keyColumn] (0-based within [range]) and
/// aggregates the column at offset [valueColumn].
///
/// Rows with an empty key are skipped. Non-numeric values are ignored by
/// sum/average (they still count for count). Average of a group with no
/// numeric values is 0. Ordering is deterministic: numeric keys
/// ascending first, then text keys in code-unit order.
List<PivotGroup> pivotSummary(
  SheetEngine engine, {
  required CellRange range,
  required int keyColumn,
  required int valueColumn,
  required Aggregation aggregation,
}) {
  if (keyColumn < 0 ||
      keyColumn >= range.colCount ||
      valueColumn < 0 ||
      valueColumn >= range.colCount) {
    throw ArgumentError('key/value column outside the range');
  }

  final groups = <String, _Accum>{};
  final keyOrder = <String, CellValue>{};
  for (var r = range.start.row; r <= range.end.row; r++) {
    final key = engine.valueAt(CellRef(r, range.start.col + keyColumn));
    if (key is EmptyValue || key is ErrorValue) continue;
    final display = switch (key) {
      NumberValue n => formatNumber(n.value),
      TextValue t => t.value,
      BoolValue b => b.value ? 'TRUE' : 'FALSE',
      _ => '',
    };
    final acc = groups.putIfAbsent(display, () => _Accum());
    keyOrder[display] = key;
    acc.rows++;
    final v = engine.valueAt(CellRef(r, range.start.col + valueColumn));
    if (v is NumberValue) {
      acc.sum += v.value;
      acc.numericCount++;
    }
  }

  final keys = groups.keys.toList();
  keys.sort((a, b) {
    final ka = keyOrder[a]!;
    final kb = keyOrder[b]!;
    if (ka is NumberValue && kb is NumberValue) {
      return ka.value.compareTo(kb.value);
    }
    if (ka is NumberValue) return -1;
    if (kb is NumberValue) return 1;
    return a.compareTo(b);
  });

  return keys.map((key) {
    final acc = groups[key]!;
    final value = switch (aggregation) {
      Aggregation.sum => acc.sum,
      Aggregation.count => acc.rows.toDouble(),
      Aggregation.average =>
        acc.numericCount == 0 ? 0.0 : acc.sum / acc.numericCount,
    };
    return PivotGroup(key: key, value: value, rowCount: acc.rows);
  }).toList();
}

class _Accum {
  var rows = 0;
  var sum = 0.0;
  var numericCount = 0;
}
