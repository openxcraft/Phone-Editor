import 'a1.dart';
import 'engine.dart';
import 'model.dart';

/// Chart descriptions extracted from sheet data. Data only — rendering
/// belongs to the UI layer. A null value is a gap (non-numeric or empty
/// source cell), preserved so line/bar charts can break or skip a point;
/// pie extraction drops gaps and non-positive values together with their
/// categories.
enum ChartKind { bar, line, pie }

class ChartSeries {
  const ChartSeries({required this.name, required this.values});

  final String name;
  final List<double?> values;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'values': values,
      };
}

class ChartData {
  const ChartData({
    required this.kind,
    required this.categories,
    required this.series,
    this.title,
  });

  final ChartKind kind;
  final String? title;
  final List<String> categories;
  final List<ChartSeries> series;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.name,
        if (title != null) 'title': title,
        'categories': categories,
        'series': series.map((s) => s.toJson()).toList(),
      };
}

/// Builds a [ChartData] from computed values.
///
/// [categories] is a single row or column range. [data] is a block whose
/// columns (or rows, when [seriesInRows] is true) are the series. When
/// [hasHeader] is true the first cell of each series supplies its name;
/// otherwise series are named `Series 1`, `Series 2`, …
ChartData buildChart(
  SheetEngine engine, {
  required ChartKind kind,
  required CellRange categories,
  required CellRange data,
  bool hasHeader = true,
  bool seriesInRows = false,
  String? title,
}) {
  String labelOf(CellValue v) => switch (v) {
        EmptyValue _ => '',
        NumberValue n => formatNumber(n.value),
        TextValue t => t.value,
        BoolValue b => b.value ? 'TRUE' : 'FALSE',
        ErrorValue e => e.code,
      };

  final categoryValues = <String>[];
  for (final ref in categories.cells) {
    categoryValues.add(labelOf(engine.valueAt(ref)));
  }

  final series = <ChartSeries>[];
  final seriesCount = seriesInRows ? data.rowCount : data.colCount;
  final pointCount = seriesInRows ? data.colCount : data.rowCount;
  for (var s = 0; s < seriesCount; s++) {
    var name = 'Series ${s + 1}';
    final values = <double?>[];
    for (var p = 0; p < pointCount; p++) {
      final ref = seriesInRows
          ? CellRef(data.start.row + s, data.start.col + p)
          : CellRef(data.start.row + p, data.start.col + s);
      final v = engine.valueAt(ref);
      if (p == 0 && hasHeader) {
        if (v is! EmptyValue) name = labelOf(v);
        continue;
      }
      values.add(v is NumberValue ? v.value : null);
    }
    series.add(ChartSeries(name: name, values: values));
  }

  final effectiveCategories = categoryValues;
  if (kind == ChartKind.pie) {
    // Pie: first series only, gaps and non-positive slices dropped
    // together with their categories.
    final first = series.isEmpty
        ? const ChartSeries(name: 'Series 1', values: <double?>[])
        : series.first;
    final keptCategories = <String>[];
    final keptValues = <double?>[];
    for (var i = 0; i < first.values.length; i++) {
      final v = first.values[i];
      if (v != null && v > 0) {
        keptCategories
            .add(i < effectiveCategories.length ? effectiveCategories[i] : '');
        keptValues.add(v);
      }
    }
    return ChartData(
      kind: kind,
      title: title,
      categories: keptCategories,
      series: <ChartSeries>[
        ChartSeries(name: first.name, values: keptValues)
      ],
    );
  }

  // When a header row was consumed, categories align with the remaining
  // points; category ranges are expected to exclude the header cell.
  final trimmed = series.isEmpty
      ? effectiveCategories
      : (effectiveCategories.length > series.first.values.length
          ? effectiveCategories.sublist(
              0, series.first.values.length)
          : effectiveCategories);
  return ChartData(
      kind: kind, title: title, categories: trimmed, series: series);
}
