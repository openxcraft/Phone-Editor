import 'a1.dart';
import 'engine.dart';
import 'model.dart';

/// CSV (RFC 4180) and JSON import/export.
///
/// CSV export writes *computed* values (taken from a [SheetEngine]) over
/// the sheet's used rectangle. CSV import infers cell kinds from field
/// text: a leading `=` makes a formula, `TRUE`/`FALSE` (any case) a
/// boolean, a known error code an error cell, a numeric literal a number,
/// anything else text. The formula-preserving serialization is the JSON
/// form on [Sheet] itself (`toJsonString` / `Sheet.fromJsonString`).
abstract final class CsvCodec {
  /// Parses RFC 4180 CSV: quoted fields may contain commas, quotes
  /// (escaped as `""`), and line breaks; rows end with CRLF or LF.
  static List<List<String>> parse(String source) {
    final rows = <List<String>>[];
    var row = <String>[];
    final field = StringBuffer();
    var inQuotes = false;
    var fieldStarted = false;
    var i = 0;

    void endField() {
      row.add(field.toString());
      field.clear();
      fieldStarted = false;
    }

    void endRow() {
      endField();
      rows.add(row);
      row = <String>[];
    }

    while (i < source.length) {
      final ch = source[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < source.length && source[i + 1] == '"') {
            field.write('"');
            i += 2;
          } else {
            inQuotes = false;
            i++;
          }
        } else {
          field.write(ch);
          i++;
        }
        continue;
      }
      switch (ch) {
        case '"':
          if (!fieldStarted && field.isEmpty) {
            inQuotes = true;
            fieldStarted = true;
          } else {
            field.write(ch);
          }
          i++;
        case ',':
          endField();
          i++;
        case '\r':
          // CRLF or lone CR both end a row.
          endRow();
          i += (i + 1 < source.length && source[i + 1] == '\n') ? 2 : 1;
        case '\n':
          endRow();
          i++;
        default:
          field.write(ch);
          fieldStarted = true;
          i++;
      }
    }
    // Trailing content without a final line break forms the last row; a
    // completely empty tail (input ended with a line break) does not.
    if (fieldStarted || field.isNotEmpty || row.isNotEmpty) {
      endRow();
    }
    return rows;
  }

  /// Encodes rows as RFC 4180 with CRLF line endings, quoting any field
  /// that contains a comma, quote, or line break.
  static String encode(List<List<String>> rows) {
    final buf = StringBuffer();
    for (final row in rows) {
      for (var c = 0; c < row.length; c++) {
        if (c > 0) buf.write(',');
        buf.write(_encodeField(row[c]));
      }
      buf.write('\r\n');
    }
    return buf.toString();
  }

  static String _encodeField(String field) {
    if (field.contains(',') ||
        field.contains('"') ||
        field.contains('\n') ||
        field.contains('\r')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  /// Infers the stored cell for one CSV field (see class docs).
  static Cell cellFromField(String field) {
    if (field.isEmpty) return Cell.empty();
    if (field.startsWith('=')) return Cell.formula(field);
    final upper = field.toUpperCase();
    if (upper == 'TRUE') return Cell.boolean(true);
    if (upper == 'FALSE') return Cell.boolean(false);
    if (ErrorCodes.isErrorCode(field)) return Cell.error(field);
    final number = double.tryParse(field);
    if (number != null) return Cell.number(number);
    return Cell.text(field);
  }

  /// Inverse of [cellFromField] for a *stored* cell (formulas keep their
  /// source; used for lossless-ish CSV round trips of input, though the
  /// normal export path is [sheetToCsv]).
  static String fieldFromCell(Cell cell) => switch (cell.kind) {
        CellKind.empty => '',
        CellKind.number => formatNumber(cell.numberValue!),
        CellKind.text => cell.textValue!,
        CellKind.bool => cell.boolValue! ? 'TRUE' : 'FALSE',
        CellKind.formula => cell.textValue!,
        CellKind.error => cell.textValue!,
      };

  /// Imports CSV text into a new [Sheet] named [sheetName].
  static Sheet sheetFromCsv(String source, {String sheetName = 'Sheet1'}) {
    final rows = parse(source);
    final sheet = Sheet(name: sheetName);
    for (var r = 0; r < rows.length; r++) {
      for (var c = 0; c < rows[r].length; c++) {
        final cell = cellFromField(rows[r][c]);
        if (cell.kind != CellKind.empty) {
          sheet.setCell(CellRef(r, c), cell);
        }
      }
    }
    return sheet;
  }

  /// Exports the *computed* values of [engine]'s sheet as CSV over the
  /// used rectangle (unset cells inside it become empty fields).
  static String sheetToCsv(SheetEngine engine) {
    final corner = engine.sheet.usedCorner;
    if (corner == null) return '';
    final rows = <List<String>>[];
    for (var r = 0; r <= corner.row; r++) {
      final row = <String>[];
      for (var c = 0; c <= corner.col; c++) {
        row.add(_computedField(engine.valueAt(CellRef(r, c))));
      }
      rows.add(row);
    }
    return encode(rows);
  }

  static String _computedField(CellValue v) => switch (v) {
        EmptyValue _ => '',
        NumberValue n => formatNumber(n.value),
        TextValue t => t.value,
        BoolValue b => b.value ? 'TRUE' : 'FALSE',
        ErrorValue e => e.code,
      };
}
