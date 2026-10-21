import 'dart:convert';
import 'dart:typed_data';

/// Minimal PDF 1.7 object writer, built from scratch (no PDF packages).
///
/// Objects are allocated in caller order (`allocate`), filled with
/// `setBody` / `setStream`, then `build` assembles the file: header,
/// objects in numeric order, a cross-reference table whose offsets are
/// measured from the actual bytes written, and a trailer. Everything is
/// deterministic — the caller supplies the Info dictionary and the file
/// ID; this class reads no clock and no random source.
class PdfBuilder {
  final Map<int, List<int>> _bodies = <int, List<int>>{};
  int _nextNumber = 1;

  /// Reserves the next object number (1-based) and returns it.
  int allocate() => _nextNumber++;

  /// Sets a dictionary/plain body for object [number] from an ASCII /
  /// Latin-1 string (encoded as Latin-1 bytes).
  void setBody(int number, String body) {
    _bodies[number] = latin1.encode(body);
  }

  /// Sets a stream object: `<< dict >> stream … endstream`. [extraDict]
  /// is merged into the stream dictionary (which always carries the true
  /// byte /Length).
  void setStream(int number, List<int> data, [String extraDict = '']) {
    final head = latin1.encode(
        '<< /Length ${data.length}${extraDict.isEmpty ? '' : ' $extraDict'} >>\nstream\n');
    final tail = latin1.encode('\nendstream');
    _bodies[number] = <int>[...head, ...data, ...tail];
  }

  /// Assembles the complete file. [infoDict] is the trailer Info
  /// dictionary body (without `<<` `>>`), [fileIdHex] a 32-char hex
  /// string used for both halves of the trailer /ID.
  Uint8List build({required String infoDict, required String fileIdHex}) {
    for (var n = 1; n < _nextNumber; n++) {
      if (!_bodies.containsKey(n)) {
        throw StateError('PDF object $n was allocated but never filled');
      }
    }
    final out = BytesBuilder(copy: false);
    out.add(latin1.encode('%PDF-1.7\n'));
    // Binary marker comment (bytes > 0x7F) per PDF convention.
    out.add(<int>[0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]);

    final offsets = <int, int>{};
    var written = 9 + 6; // "%PDF-1.7\n" (9) + binary comment line (6)
    for (var n = 1; n < _nextNumber; n++) {
      offsets[n] = written;
      final header = latin1.encode('$n 0 obj\n');
      final footer = latin1.encode('\nendobj\n');
      out.add(header);
      out.add(_bodies[n]!);
      out.add(footer);
      written += header.length + _bodies[n]!.length + footer.length;
    }

    final xrefOffset = written;
    final count = _nextNumber; // includes the free object 0
    final xref = StringBuffer()
      ..write('xref\n0 $count\n')
      ..write('0000000000 65535 f \n');
    for (var n = 1; n < _nextNumber; n++) {
      xref.write('${offsets[n]!.toString().padLeft(10, '0')} 00000 n \n');
    }
    xref
      ..write('trailer\n')
      ..write('<< /Size $count /Root 1 0 R /Info << $infoDict >> '
          '/ID [<${fileIdHex.toUpperCase()}> <${fileIdHex.toUpperCase()}>] >>\n')
      ..write('startxref\n$xrefOffset\n%%EOF\n');
    out.add(latin1.encode(xref.toString()));
    return out.toBytes();
  }
}

/// Deterministic 32-hex-char file ID from document fields, using two
/// FNV-1a 64-bit hashes with different offset bases. Not cryptographic —
/// it only needs to be stable per document, per EXPORT.md determinism.
String deterministicFileId(String seedMaterial) {
  String hashWith(int seed) {
    var hash = 0xcbf29ce484222325 ^ seed;
    for (final byte in utf8.encode(seedMaterial)) {
      hash ^= byte;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  return (hashWith(0) + hashWith(0x9e3779b9)).toUpperCase();
}

/// PDF date string (`D:YYYYMMDDHHmmssZ`) in UTC for epoch milliseconds —
/// sourced from document metadata, never the wall clock.
String pdfDateUtc(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
  String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
  return 'D:${p(d.year, 4)}${p(d.month)}${p(d.day)}${p(d.hour)}${p(d.minute)}${p(d.second)}Z';
}
