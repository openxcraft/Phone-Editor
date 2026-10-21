import 'dart:convert';

import 'a1.dart';

/// Error codes produced by evaluation. These are values, not exceptions.
abstract final class ErrorCodes {
  static const String divByZero = '#DIV/0!';
  static const String value = '#VALUE!';
  static const String ref = '#REF!';
  static const String name = '#NAME?';
  static const String cycle = '#CYCLE!';
  static const String notAvailable = '#N/A';

  static const Set<String> all = <String>{
    divByZero,
    value,
    ref,
    name,
    cycle,
    notAvailable,
  };

  static bool isErrorCode(String s) => all.contains(s);
}

/// A computed (or literal) cell value.
sealed class CellValue {
  const CellValue();
}

final class EmptyValue extends CellValue {
  const EmptyValue();

  @override
  bool operator ==(Object other) => other is EmptyValue;

  @override
  int get hashCode => 0;

  @override
  String toString() => '';
}

final class NumberValue extends CellValue {
  const NumberValue(this.value);

  final double value;

  @override
  bool operator ==(Object other) =>
      other is NumberValue && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => formatNumber(value);
}

final class TextValue extends CellValue {
  const TextValue(this.value);

  final String value;

  @override
  bool operator ==(Object other) => other is TextValue && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

final class BoolValue extends CellValue {
  const BoolValue(this.value);

  final bool value;

  @override
  bool operator ==(Object other) => other is BoolValue && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value ? 'TRUE' : 'FALSE';
}

final class ErrorValue extends CellValue {
  const ErrorValue(this.code);

  /// One of [ErrorCodes].
  final String code;

  @override
  bool operator ==(Object other) => other is ErrorValue && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => code;
}

/// Deterministic display formatting for numbers: integral values print
/// without a decimal point; others use Dart's shortest round-trip form.
String formatNumber(double v) {
  if (v.isNaN || v.isInfinite) return ErrorCodes.value;
  if (v == v.truncateToDouble() && v.abs() < 1e15) {
    return v.toInt().toString();
  }
  return v.toString();
}

/// The stored kind of a cell (its input, before evaluation).
enum CellKind { empty, number, text, bool, formula, error }

/// A stored cell: exactly one kind plus its payload.
///
/// Formula source is normalized on construction to include the leading
/// `=` and to have no surrounding whitespace.
class Cell {
  const Cell._(this.kind, {this.numberValue, this.textValue, this.boolValue});

  factory Cell.empty() => const Cell._(CellKind.empty);

  factory Cell.number(double value) =>
      Cell._(CellKind.number, numberValue: value);

  factory Cell.text(String value) => Cell._(CellKind.text, textValue: value);

  factory Cell.boolean(bool value) =>
      Cell._(CellKind.bool, boolValue: value);

  factory Cell.formula(String source) {
    var s = source.trim();
    if (!s.startsWith('=')) s = '=$s';
    return Cell._(CellKind.formula, textValue: s);
  }

  factory Cell.error(String code) {
    if (!ErrorCodes.isErrorCode(code)) {
      throw ArgumentError.value(code, 'code', 'Unknown error code');
    }
    return Cell._(CellKind.error, textValue: code);
  }

  final CellKind kind;
  final double? numberValue;
  final String? textValue;
  final bool? boolValue;

  /// Formula source including `=`; non-null only for [CellKind.formula].
  String? get formulaSource => kind == CellKind.formula ? textValue : null;

  /// The literal value of a non-formula cell.
  CellValue get literalValue => switch (kind) {
        CellKind.empty => const EmptyValue(),
        CellKind.number => NumberValue(numberValue!),
        CellKind.text => TextValue(textValue!),
        CellKind.bool => BoolValue(boolValue!),
        CellKind.error => ErrorValue(textValue!),
        CellKind.formula => const ErrorValue(ErrorCodes.value),
      };

  Map<String, Object?> toJson() => switch (kind) {
        CellKind.empty => <String, Object?>{'kind': 'empty'},
        CellKind.number => <String, Object?>{
            'kind': 'number',
            'value': numberValue,
          },
        CellKind.text => <String, Object?>{'kind': 'text', 'value': textValue},
        CellKind.bool => <String, Object?>{'kind': 'bool', 'value': boolValue},
        CellKind.formula => <String, Object?>{
            'kind': 'formula',
            'value': textValue,
          },
        CellKind.error => <String, Object?>{
            'kind': 'error',
            'value': textValue,
          },
      };

  factory Cell.fromJson(Map<String, Object?> json) {
    switch (json['kind']) {
      case 'empty':
        return Cell.empty();
      case 'number':
        return Cell.number((json['value'] as num).toDouble());
      case 'text':
        return Cell.text(json['value'] as String);
      case 'bool':
        return Cell.boolean(json['value'] as bool);
      case 'formula':
        return Cell.formula(json['value'] as String);
      case 'error':
        return Cell.error(json['value'] as String);
      default:
        throw FormatException('Unknown cell kind: ${json['kind']}');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is Cell &&
      other.kind == kind &&
      other.numberValue == numberValue &&
      other.textValue == textValue &&
      other.boolValue == boolValue;

  @override
  int get hashCode => Object.hash(kind, numberValue, textValue, boolValue);
}

/// A sparse grid: only non-empty cells are stored.
///
/// Serialization is deterministic — cells are emitted sorted by
/// (row, column) with A1 keys, so the same sheet always encodes to the
/// same JSON string. This JSON form preserves formulas.
class Sheet {
  Sheet({this.name = 'Sheet1'});

  final String name;
  final Map<CellRef, Cell> _cells = <CellRef, Cell>{};

  Iterable<MapEntry<CellRef, Cell>> get entries => _cells.entries;

  int get cellCount => _cells.length;

  Cell? cellAt(CellRef ref) => _cells[ref];

  /// Sets a cell; storing [CellKind.empty] removes it (sparsity).
  void setCell(CellRef ref, Cell cell) {
    if (cell.kind == CellKind.empty) {
      _cells.remove(ref);
    } else {
      _cells[ref] = cell;
    }
  }

  void clearCell(CellRef ref) => _cells.remove(ref);

  /// Bottom-right used corner, or null for an empty sheet.
  CellRef? get usedCorner {
    if (_cells.isEmpty) return null;
    var row = 0;
    var col = 0;
    for (final ref in _cells.keys) {
      if (ref.row > row) row = ref.row;
      if (ref.col > col) col = ref.col;
    }
    return CellRef(row, col);
  }

  /// Cells sorted by (row, col) — the canonical iteration order.
  List<MapEntry<CellRef, Cell>> get sortedEntries {
    final list = _cells.entries.toList();
    list.sort((a, b) {
      final byRow = a.key.row.compareTo(b.key.row);
      return byRow != 0 ? byRow : a.key.col.compareTo(b.key.col);
    });
    return list;
  }

  Map<String, Object?> toJson() {
    final cells = <String, Object?>{};
    for (final entry in sortedEntries) {
      cells[entry.key.toA1()] = entry.value.toJson();
    }
    return <String, Object?>{'name': name, 'cells': cells};
  }

  String toJsonString() => jsonEncode(toJson());

  factory Sheet.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final cells = json['cells'];
    if (name is! String || cells is! Map) {
      throw const FormatException('Sheet requires name:String, cells:Map');
    }
    final sheet = Sheet(name: name);
    cells.forEach((key, value) {
      final ref = CellRef.tryParse(key as String);
      if (ref == null) {
        throw FormatException('Invalid cell reference in JSON: $key');
      }
      sheet.setCell(
        ref,
        Cell.fromJson((value as Map).cast<String, Object?>()),
      );
    });
    return sheet;
  }

  factory Sheet.fromJsonString(String source) => Sheet.fromJson(
      (jsonDecode(source) as Map).cast<String, Object?>());
}
