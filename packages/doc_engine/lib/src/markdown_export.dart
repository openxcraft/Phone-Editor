import 'model.dart';

/// Deterministic Markdown export from the neutral node tree.
/// Mapping and loss rules are specified in EXPORT.md at the repo root.
class MarkdownExporter {
  const MarkdownExporter();

  String export(Document doc) {
    final blocks = <String>[];
    if (doc.title.trim().isNotEmpty) {
      blocks.add('# ${_escape(doc.title.trim())}');
    }
    for (final block in doc.allBlocks) {
      blocks.add(_exportBlock(block));
    }
    return '${blocks.join('\n\n')}\n';
  }

  String _exportBlock(Block block) {
    if (block.type == BlockType.table) {
      // Pipe table; cell text reuses the inline mapping. Pipes inside
      // cell text are escaped so the row structure survives.
      final rows = block.tableRows ?? const <List<TableCell>>[];
      return rows
          .map((row) => '| ${row.map(_exportCell).join(' | ')} |')
          .join('\n');
    }
    if (block.type == BlockType.image) {
      // No binary handling: reference the asset by its stored ID.
      final alt = _escape(block.imageAlt ?? '');
      return '![$alt](asset:${block.imageAssetId ?? ''})';
    }
    final inner = block.inlines.map(_exportInline).join();
    return switch (block.type) {
      BlockType.heading1 => '# $inner',
      BlockType.heading2 => '## $inner',
      BlockType.paragraph => inner,
      BlockType.bullet => '- $inner',
      BlockType.quote => '> $inner',
      BlockType.table => '',
      BlockType.image => '',
    };
  }

  String _exportCell(TableCell cell) =>
      cell.inlines.map(_exportInline).join().replaceAll('|', r'\|');

  String _exportInline(InlineNode node) {
    if (node.text.isEmpty) return '';
    if (node.marks.contains(Mark.code)) {
      // Code spans ignore other marks (see EXPORT.md).
      return '`${node.text.replaceAll('`', r'\`')}`';
    }
    var out = _escape(node.text);
    final bold = node.marks.contains(Mark.bold);
    final italic = node.marks.contains(Mark.italic);
    if (bold && italic) {
      out = '***$out***';
    } else if (bold) {
      out = '**$out**';
    } else if (italic) {
      out = '*$out*';
    }
    // Mark.underline has no Markdown equivalent: exported as plain text.
    return out;
  }

  static String _escape(String text) {
    final buf = StringBuffer();
    for (final ch in text.split('')) {
      if (ch == r'\' || ch == '`' || ch == '*' || ch == '_') {
        buf.write(r'\');
      }
      buf.write(ch);
    }
    return buf.toString();
  }
}
