/// A1-style cell and range references.
///
/// Rows and columns are stored zero-based internally; the A1 form is
/// one-based for rows and letter-based for columns (`A1` is the top-left
/// cell). Absolute markers (`$A$1`) parse successfully and are recorded,
/// but do not change evaluation semantics in this single-sheet engine.
library;

/// A single cell coordinate, zero-based.
class CellRef {
  const CellRef(this.row, this.col);

  final int row;
  final int col;

  /// Parses `A1`, `$B$12`, `AA100`, … Returns null on malformed input.
  static CellRef? tryParse(String input) {
    final match = _pattern.firstMatch(input.trim());
    if (match == null) return null;
    final col = columnLettersToIndex(match.group(2)!);
    final row = int.parse(match.group(4)!);
    if (row < 1 || col < 0) return null;
    return CellRef(row - 1, col);
  }

  static final RegExp _pattern =
      RegExp(r'^(\$?)([A-Za-z]{1,3})(\$?)([0-9]+)$');

  /// True when [input] has the exact shape of a cell reference.
  static bool isRef(String input) => tryParse(input) != null;

  /// `A`→0, `Z`→25, `AA`→26, `AB`→27, …
  static int columnLettersToIndex(String letters) {
    var result = 0;
    for (final unit in letters.toUpperCase().codeUnits) {
      if (unit < 0x41 || unit > 0x5A) return -1;
      result = result * 26 + (unit - 0x41 + 1);
    }
    return result - 1;
  }

  /// 0→`A`, 25→`Z`, 26→`AA`, …
  static String columnIndexToLetters(int col) {
    if (col < 0) throw ArgumentError.value(col, 'col', 'must be >= 0');
    var n = col + 1;
    final buf = StringBuffer();
    while (n > 0) {
      final rem = (n - 1) % 26;
      buf.write(String.fromCharCode(0x41 + rem));
      n = (n - 1) ~/ 26;
    }
    return String.fromCharCodes(buf.toString().codeUnits.reversed);
  }

  /// Canonical A1 form, e.g. `B12`.
  String toA1() => '${columnIndexToLetters(col)}${row + 1}';

  @override
  bool operator ==(Object other) =>
      other is CellRef && other.row == row && other.col == col;

  @override
  int get hashCode => Object.hash(row, col);

  @override
  String toString() => toA1();
}

/// An inclusive rectangle of cells, stored normalized (start ≤ end).
class CellRange {
  CellRange(CellRef a, CellRef b)
      : start = CellRef(
          a.row < b.row ? a.row : b.row,
          a.col < b.col ? a.col : b.col,
        ),
        end = CellRef(
          a.row > b.row ? a.row : b.row,
          a.col > b.col ? a.col : b.col,
        );

  final CellRef start;
  final CellRef end;

  int get rowCount => end.row - start.row + 1;
  int get colCount => end.col - start.col + 1;
  int get cellCount => rowCount * colCount;

  /// Parses `A1:B2` (or a single ref, treated as a 1×1 range).
  static CellRange? tryParse(String input) {
    final parts = input.trim().split(':');
    if (parts.length == 1) {
      final ref = CellRef.tryParse(parts[0]);
      return ref == null ? null : CellRange(ref, ref);
    }
    if (parts.length != 2) return null;
    final a = CellRef.tryParse(parts[0]);
    final b = CellRef.tryParse(parts[1]);
    if (a == null || b == null) return null;
    return CellRange(a, b);
  }

  /// All cells in row-major order.
  Iterable<CellRef> get cells sync* {
    for (var r = start.row; r <= end.row; r++) {
      for (var c = start.col; c <= end.col; c++) {
        yield CellRef(r, c);
      }
    }
  }

  bool contains(CellRef ref) =>
      ref.row >= start.row &&
      ref.row <= end.row &&
      ref.col >= start.col &&
      ref.col <= end.col;

  String toA1() =>
      start == end ? start.toA1() : '${start.toA1()}:${end.toA1()}';

  @override
  bool operator ==(Object other) =>
      other is CellRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => toA1();
}
