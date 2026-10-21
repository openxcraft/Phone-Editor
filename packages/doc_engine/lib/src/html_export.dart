import 'model.dart';

/// Deterministic HTML export from the neutral node tree.
///
/// Rules (in the style of EXPORT.md): semantic tags only, all text and
/// attribute values escaped, no scripts, no styles, no external
/// resources. Consecutive bullet blocks are grouped into one `<ul>`.
/// Images export as `<img>` with their alt text always present (empty
/// alt marks a decorative image) and asset metadata in `data-*`
/// attributes — the engine holds no binary data, so no `src` is emitted.
class HtmlExporter {
  const HtmlExporter();

  String export(Document doc) {
    final lines = <String>[
      '<!DOCTYPE html>',
      '<html>',
      '<head>',
      '<meta charset="utf-8">',
      '<title>${_escapeText(doc.title)}</title>',
      '</head>',
      '<body>',
    ];
    final blocks = doc.allBlocks.toList();
    var i = 0;
    while (i < blocks.length) {
      final block = blocks[i];
      if (block.type == BlockType.bullet) {
        lines.add('<ul>');
        while (i < blocks.length && blocks[i].type == BlockType.bullet) {
          lines.add('<li>${_inlines(blocks[i])}</li>');
          i++;
        }
        lines.add('</ul>');
        continue;
      }
      lines.add(_exportBlock(block));
      i++;
    }
    lines.add('</body>');
    lines.add('</html>');
    return '${lines.join('\n')}\n';
  }

  String _exportBlock(Block block) {
    switch (block.type) {
      case BlockType.heading1:
        return '<h1>${_inlines(block)}</h1>';
      case BlockType.heading2:
        return '<h2>${_inlines(block)}</h2>';
      case BlockType.paragraph:
        return '<p>${_inlines(block)}</p>';
      case BlockType.quote:
        return '<blockquote><p>${_inlines(block)}</p></blockquote>';
      case BlockType.bullet:
        return '<ul><li>${_inlines(block)}</li></ul>'; // handled in export()
      case BlockType.table:
        return _exportTable(block);
      case BlockType.image:
        return _exportImage(block);
    }
  }

  String _exportTable(Block block) {
    final rows = block.tableRows ?? const <List<TableCell>>[];
    final buf = StringBuffer('<table><tbody>');
    for (final row in rows) {
      buf.write('<tr>');
      for (final cell in row) {
        buf.write('<td>${cell.inlines.map(_exportInline).join()}</td>');
      }
      buf.write('</tr>');
    }
    buf.write('</tbody></table>');
    return buf.toString();
  }

  String _exportImage(Block block) {
    final attrs = StringBuffer(' alt="${_escapeAttr(block.imageAlt ?? '')}"');
    if (block.imageAssetId != null) {
      attrs.write(' data-image-id="${_escapeAttr(block.imageAssetId!)}"');
    }
    if (block.imageByteLength != null) {
      attrs.write(' data-byte-length="${block.imageByteLength}"');
    }
    if (block.imageHash != null) {
      attrs.write(' data-hash="${_escapeAttr(block.imageHash!)}"');
    }
    return '<img$attrs>';
  }

  String _inlines(Block block) => block.inlines.map(_exportInline).join();

  String _exportInline(InlineNode node) {
    if (node.text.isEmpty) return '';
    var out = _escapeText(node.text);
    // Fixed wrap order (innermost first) keeps output deterministic:
    // code, then underline, then italic, then bold outermost.
    if (node.marks.contains(Mark.code)) out = '<code>$out</code>';
    if (node.marks.contains(Mark.underline)) out = '<u>$out</u>';
    if (node.marks.contains(Mark.italic)) out = '<em>$out</em>';
    if (node.marks.contains(Mark.bold)) out = '<strong>$out</strong>';
    return out;
  }

  static String _escapeText(String text) => text
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  static String _escapeAttr(String text) =>
      _escapeText(text).replaceAll('"', '&quot;');
}
