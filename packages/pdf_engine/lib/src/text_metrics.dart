/// Text encoding and width measurement for the standard-14 Helvetica
/// family used by this package.
///
/// Encoding rule (documented limitation): text is written as PDF literal
/// strings in WinAnsiEncoding. A rune is representable when it is
/// printable ASCII (0x20–0x7E), Latin-1 (0xA0–0xFF), or in the explicit
/// WinAnsi punctuation table below (€, •, –, —, quotes, …). Every other
/// rune — including all CJK, Cyrillic outside Latin-1, emoji, and combining
/// marks — is replaced with '?' (0x3F). There is no font embedding and no
/// Unicode (UTF-16BE) string path in this package version.
library;

/// WinAnsi code points for punctuation that lives in the 0x80–0x9F range.
const Map<int, int> _winAnsiSpecial = <int, int>{
  0x20AC: 0x80, // €
  0x201A: 0x82, // ‚
  0x0192: 0x83, // ƒ
  0x201E: 0x84, // „
  0x2026: 0x85, // …
  0x2020: 0x86, // †
  0x2021: 0x87, // ‡
  0x02C6: 0x88, // ˆ
  0x2030: 0x89, // ‰
  0x0160: 0x8A, // Š
  0x2039: 0x8B, // ‹
  0x0152: 0x8C, // Œ
  0x017D: 0x8E, // Ž
  0x2018: 0x91, // '
  0x2019: 0x92, // '
  0x201C: 0x93, // "
  0x201D: 0x94, // "
  0x2022: 0x95, // •
  0x2013: 0x96, // –
  0x2014: 0x97, // —
  0x02DC: 0x98, // ˜
  0x2122: 0x99, // ™
  0x0161: 0x9A, // š
  0x203A: 0x9B, // ›
  0x0153: 0x9C, // œ
  0x017E: 0x9E, // ž
  0x0178: 0x9F, // Ÿ
};

/// Encodes [text] to WinAnsi bytes applying the replacement rule above.
List<int> winAnsiEncode(String text) {
  final out = <int>[];
  for (final rune in text.runes) {
    if (rune >= 0x20 && rune <= 0x7E) {
      out.add(rune);
    } else if (rune >= 0xA0 && rune <= 0xFF) {
      out.add(rune);
    } else if (_winAnsiSpecial.containsKey(rune)) {
      out.add(_winAnsiSpecial[rune]!);
    } else {
      out.add(0x3F); // '?'
    }
  }
  return out;
}

/// Escapes already-WinAnsi-encoded [bytes] for a PDF literal string:
/// `\`, `(`, `)` get a backslash; bytes outside 0x20–0x7E become
/// three-digit octal escapes. Returns an ASCII string.
String escapePdfStringBytes(List<int> bytes) {
  final buf = StringBuffer();
  for (final b in bytes) {
    if (b == 0x5C || b == 0x28 || b == 0x29) {
      buf.write(r'\');
      buf.writeCharCode(b);
    } else if (b < 0x20 || b > 0x7E) {
      buf.write(r'\');
      buf.write(b.toRadixString(8).padLeft(3, '0'));
    } else {
      buf.writeCharCode(b);
    }
  }
  return buf.toString();
}

/// Convenience: encode + escape a Dart string for a PDF literal string
/// (without the surrounding parentheses).
String escapePdfString(String text) =>
    escapePdfStringBytes(winAnsiEncode(text));

// --- Width measurement ------------------------------------------------------
//
// Approximate Helvetica advance widths, in 1/1000 em, by character class.
// This is a layout approximation (real AFM tables are a later refinement);
// it is fully deterministic, which is what word-wrap and the tests rely on.

int _charWidth1000(int rune) {
  if (rune == 0x20) return 278; // space
  const narrow = "ilj.,:;!'|";
  if (narrow.contains(String.fromCharCode(rune))) return 278;
  if (rune == 0x28 || rune == 0x29 || rune == 0x5B || rune == 0x5D) return 333;
  if (rune == 0x66 || rune == 0x74 || rune == 0x72) return 333; // f t r
  if (rune == 0x6D) return 833; // m
  if (rune == 0x77) return 722; // w
  if (rune == 0x4D) return 833; // M
  if (rune == 0x57) return 944; // W
  if (rune >= 0x30 && rune <= 0x39) return 556; // digits
  if (rune >= 0x41 && rune <= 0x5A) return 667; // uppercase default
  if (rune == 0x2D) return 333; // hyphen
  return 556; // lowercase and everything else
}

/// Courier is monospace: every glyph is 600/1000 em.
const int _courierWidth1000 = 600;

/// Width of [text] in points when set at [fontSize] in [fontKey].
/// [fontKey] is one of 'F1'..'F5' (see layout.dart font table).
double measureText(String text, String fontKey, double fontSize) {
  var units = 0;
  for (final rune in text.runes) {
    units += fontKey == 'F5' ? _courierWidth1000 : _charWidth1000(rune);
  }
  return units * fontSize / 1000.0;
}

/// Formats a number for PDF output deterministically: integers without a
/// decimal point, otherwise rounded to 2 decimal places with trailing
/// zeros trimmed. Never uses scientific notation or a locale.
String pdfNum(double value) {
  final rounded = (value * 100).round() / 100;
  if (rounded == rounded.roundToDouble()) return rounded.toInt().toString();
  var s = rounded.toStringAsFixed(2);
  while (s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}
