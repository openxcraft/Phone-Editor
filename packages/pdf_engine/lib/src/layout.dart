/// Deterministic A4 layout for the doc_engine node tree.
///
/// Pure geometry: same document in → same pages, lines, and coordinates
/// out. No rendering, no clock, no randomness.
library;

import 'package:doc_engine/doc_engine.dart';

import 'text_metrics.dart';

/// Standard-14 fonts. Resource names are fixed so output never depends
/// on use order: F1 Helvetica, F2 Helvetica-Bold, F3 Helvetica-Oblique,
/// F4 Helvetica-BoldOblique, F5 Courier.
const Map<String, String> pdfFontBaseNames = <String, String>{
  'F1': 'Helvetica',
  'F2': 'Helvetica-Bold',
  'F3': 'Helvetica-Oblique',
  'F4': 'Helvetica-BoldOblique',
  'F5': 'Courier',
};

/// Page geometry (points). A4: 595 × 842.
class PdfPageSpec {
  const PdfPageSpec();
  final double width = 595;
  final double height = 842;
  final double margin = 56;

  double get contentWidth => width - 2 * margin;
  double get top => height - margin; // cursor start (top of line area)
  double get bottom => margin; // lowest allowed baseline
}

class _Style {
  const _Style(this.fontKey, this.size, this.leading, this.spaceBefore,
      this.spaceAfter, this.indent);
  final String fontKey; // base font for unmarked runs
  final double size;
  final double leading;
  final double spaceBefore;
  final double spaceAfter;
  final double indent;
}

_Style _styleFor(BlockType type) => switch (type) {
      BlockType.heading1 => const _Style('F2', 20, 26, 12, 6, 0),
      BlockType.heading2 => const _Style('F2', 15, 20, 10, 5, 0),
      BlockType.paragraph => const _Style('F1', 11, 15, 0, 6, 0),
      BlockType.bullet => const _Style('F1', 11, 15, 0, 3, 18),
      BlockType.quote => const _Style('F3', 11, 15, 0, 6, 18),
      BlockType.table => const _Style('F1', 11, 15, 0, 6, 0),
      BlockType.image => const _Style('F3', 11, 15, 0, 6, 0),
    };

/// The logical lines a block contributes, before wrapping.
///
/// Text blocks contribute one logical line (their inline runs). Table
/// blocks contribute one logical line per row, cells joined by a
/// separator run — tables are rendered as text rows in this package
/// version (no grid geometry yet; documented limitation). Image blocks
/// contribute one placeholder line carrying the alt text, because the
/// document model stores image metadata only, never image bytes.
List<List<InlineNode>> _logicalLines(Block block) {
  switch (block.type) {
    case BlockType.table:
      final rows = block.tableRows;
      if (rows == null || rows.isEmpty) return <List<InlineNode>>[];
      return <List<InlineNode>>[
        for (final row in rows)
          <InlineNode>[
            for (var c = 0; c < row.length; c++) ...<InlineNode>[
              if (c > 0) InlineNode(' | '),
              ...row[c].inlines,
            ],
          ],
      ];
    case BlockType.image:
      final alt = block.imageAlt;
      return <List<InlineNode>>[
        <InlineNode>[
          InlineNode(
              alt != null && alt.isNotEmpty ? '[Image: $alt]' : '[Image]'),
        ],
      ];
    default:
      return <List<InlineNode>>[block.inlines];
  }
}

String _fontForRun(_Style style, InlineNode run) {
  if (run.marks.contains(Mark.code)) return 'F5';
  final bold = run.marks.contains(Mark.bold) || style.fontKey == 'F2';
  final italic = run.marks.contains(Mark.italic) || style.fontKey == 'F3';
  if (bold && italic) return 'F4';
  if (bold) return 'F2';
  if (italic) return 'F3';
  return 'F1';
}

/// One typeset fragment on a line (a run of one font).
class PlacedSpan {
  const PlacedSpan(this.text, this.fontKey, this.width);
  final String text;
  final String fontKey;
  final double width;
}

/// One typeset line, ready to draw.
class PlacedLine {
  const PlacedLine({
    required this.blockIndex,
    required this.blockType,
    required this.x,
    required this.baseline,
    required this.fontSize,
    required this.spans,
  });

  /// Index into `Document.allBlocks` order (the synthetic title block,
  /// when present, is index -1).
  final int blockIndex;
  final BlockType blockType;
  final double x;
  final double baseline;
  final double fontSize;
  final List<PlacedSpan> spans;

  String get text => spans.map((s) => s.text).join();
}

class LayoutPage {
  LayoutPage(this.index);
  final int index;
  final List<PlacedLine> lines = <PlacedLine>[];
}

class LayoutResult {
  const LayoutResult(this.pages, this.spec);
  final List<LayoutPage> pages;
  final PdfPageSpec spec;
}

class _Word {
  _Word(this.text, this.fontKey, this.size, this.isSpace);
  final String text;
  final String fontKey;
  final double size;
  final bool isSpace;
  double get width => measureText(text, fontKey, size);
}

/// Lays out a document into pages of positioned lines.
class PdfLayoutEngine {
  const PdfLayoutEngine([this.spec = const PdfPageSpec()]);

  final PdfPageSpec spec;

  LayoutResult layout(Document doc) {
    final pages = <LayoutPage>[LayoutPage(0)];
    var cursorY = spec.top; // top of the next line box

    void newPage() {
      pages.add(LayoutPage(pages.length));
      cursorY = spec.top;
    }

    void placeBlock(int blockIndex, Block block, _Style style,
        {bool forceNoSpaceBefore = false}) {
      final logicalLines = _logicalLines(block);
      if (logicalLines.isEmpty) return; // e.g. a table with no rows
      final atPageTop = cursorY == spec.top;
      if (!atPageTop && !forceNoSpaceBefore) cursorY -= style.spaceBefore;

      final maxWidth = spec.contentWidth - style.indent;
      for (var li = 0; li < logicalLines.length; li++) {
        final words = <_Word>[];
        if (li == 0 && block.type == BlockType.bullet) {
          words.add(_Word('• ', style.fontKey, style.size, false));
        }
        for (final run in logicalLines[li]) {
          final font = _fontForRun(style, run);
          // Tokenize into words and single spaces, preserving run fonts.
          final parts = run.text.split(' ');
          for (var i = 0; i < parts.length; i++) {
            if (i > 0) words.add(_Word(' ', font, style.size, true));
            if (parts[i].isNotEmpty) {
              words.add(_Word(parts[i], font, style.size, false));
            }
          }
        }

        final lines = _wrap(words, style, maxWidth);
        if (lines.isEmpty) lines.add(<_Word>[]); // empty line: blank

        for (final lineWords in lines) {
          if (cursorY - style.size < spec.bottom) {
            newPage();
          }
          final baseline = cursorY - style.size;
          // Group consecutive same-font words into spans (re-adding the
          // single space between words of the same font run).
          final spans = <PlacedSpan>[];
          final buf = StringBuffer();
          String? bufFont;
          var bufWidth = 0.0;
          void flush() {
            if (bufFont != null && buf.isNotEmpty) {
              spans.add(PlacedSpan(buf.toString(), bufFont!, bufWidth));
            }
            buf.clear();
            bufWidth = 0;
            bufFont = null;
          }

          for (final w in lineWords) {
            if (bufFont == w.fontKey) {
              buf.write(w.text);
              bufWidth += w.width;
            } else {
              flush();
              bufFont = w.fontKey;
              buf.write(w.text);
              bufWidth = w.width;
            }
          }
          flush();
          pages.last.lines.add(PlacedLine(
            blockIndex: blockIndex,
            blockType: block.type,
            x: spec.margin + style.indent,
            baseline: baseline,
            fontSize: style.size,
            spans: spans,
          ));
          cursorY -= style.leading;
        }
      }
      cursorY -= style.spaceAfter;
    }

    // Document title as a synthetic heading block on page 1.
    if (doc.title.trim().isNotEmpty) {
      final titleBlock = Block(
        id: '__title__',
        type: BlockType.heading1,
        inlines: <InlineNode>[InlineNode(doc.title.trim())],
      );
      placeBlock(-1, titleBlock, const _Style('F2', 24, 30, 0, 10, 0),
          forceNoSpaceBefore: true);
    }

    final blocks = doc.allBlocks.toList();
    for (var i = 0; i < blocks.length; i++) {
      placeBlock(i, blocks[i], _styleFor(blocks[i].type));
    }
    return LayoutResult(pages, spec);
  }

  /// Greedy word wrap. A single word wider than the line is hard-broken
  /// by characters. Trailing spaces never end a line.
  List<List<_Word>> _wrap(List<_Word> words, _Style style, double maxWidth) {
    final lines = <List<_Word>>[];
    var current = <_Word>[];
    var currentWidth = 0.0;

    void endLine() {
      while (current.isNotEmpty && current.last.isSpace) {
        currentWidth -= current.last.width;
        current.removeLast();
      }
      lines.add(current);
      current = <_Word>[];
      currentWidth = 0;
    }

    for (final word in words) {
      if (word.isSpace) {
        if (current.isEmpty) continue; // never start a line with a space
        if (currentWidth + word.width > maxWidth) continue;
        current.add(word);
        currentWidth += word.width;
        continue;
      }
      if (word.width > maxWidth) {
        // Hard-break an over-long word by characters (rune-based, so
        // surrogate pairs are never split).
        var restRunes = word.text.runes.toList();
        while (restRunes.isNotEmpty) {
          final avail = maxWidth - currentWidth;
          var take = 0;
          var w = 0.0;
          for (final rune in restRunes) {
            final cw =
                measureText(String.fromCharCode(rune), word.fontKey, word.size);
            if (w + cw > avail && take > 0) break;
            w += cw;
            take++;
          }
          if (take == 0) {
            endLine();
            continue;
          }
          final piece = _Word(String.fromCharCodes(restRunes.sublist(0, take)),
              word.fontKey, word.size, false);
          current.add(piece);
          currentWidth += piece.width;
          restRunes = restRunes.sublist(take);
          if (restRunes.isNotEmpty) endLine();
        }
        continue;
      }
      if (current.isNotEmpty && currentWidth + word.width > maxWidth) {
        endLine();
      }
      current.add(word);
      currentWidth += word.width;
    }
    if (current.isNotEmpty) endLine();
    return lines;
  }
}
