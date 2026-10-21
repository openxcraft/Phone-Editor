import 'dart:convert';

import 'package:archive/archive.dart';

/// Shared helpers for the OOXML exporters: deterministic ZIP writing,
/// XML escaping, and a tiny XML tree parser for the importers.
///
/// The parser is sufficient for well-formed OOXML parts. It is not a
/// general XML parser: it assumes no `<` inside attribute values or text
/// (guaranteed once values are entity-escaped, as OOXML requires) and
/// decodes the five predefined entities plus numeric character
/// references.

/// Fixed ZIP entry timestamp (1980-01-01, the DOS epoch) so repeated
/// exports of the same model are byte-identical.
const int zipTimestampSeconds = 315532800;

/// Adds [xml] to [archive] as a UTF-8 part with the fixed timestamp.
void addXmlPart(Archive archive, String name, String xml) {
  final bytes = utf8.encode(xml);
  final file = ArchiveFile(name, bytes.length, bytes);
  file.lastModTime = zipTimestampSeconds;
  archive.addFile(file);
}

/// Escapes a string for use as XML text content or inside a
/// double-quoted attribute value.
String xmlEscape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// ISO-8601 (UTC) rendering of epoch milliseconds, for core properties.
String isoFromMs(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

/// A parsed XML element: tag name (prefix retained), attributes,
/// element children, and concatenated direct text.
class XmlNode {
  XmlNode(this.name, this.attrs);

  final String name;
  final Map<String, String> attrs;
  final List<XmlNode> children = <XmlNode>[];
  final StringBuffer _text = StringBuffer();

  String get text => _text.toString();

  XmlNode? firstChild(String name) {
    for (final child in children) {
      if (child.name == name) return child;
    }
    return null;
  }

  Iterable<XmlNode> childrenNamed(String name) =>
      children.where((c) => c.name == name);

  /// All descendant elements with [name], in document order.
  Iterable<XmlNode> descendantsNamed(String name) sync* {
    for (final child in children) {
      if (child.name == name) yield child;
      yield* child.descendantsNamed(name);
    }
  }
}

/// Parses [xml] and returns its root element.
XmlNode parseXml(String xml) {
  final tokenPattern = RegExp(r'<[^>]+>|[^<]+');
  final attrPattern = RegExp(r'([\w:.-]+)\s*=\s*"([^"]*)"');
  final root = XmlNode('#root', const <String, String>{});
  final stack = <XmlNode>[root];
  for (final match in tokenPattern.allMatches(xml)) {
    final token = match.group(0)!;
    if (!token.startsWith('<')) {
      stack.last._text.write(decodeXmlEntities(token));
      continue;
    }
    if (token.startsWith('<?') || token.startsWith('<!--')) continue;
    if (token.startsWith('</')) {
      if (stack.length > 1) stack.removeLast();
      continue;
    }
    final selfClosing = token.endsWith('/>');
    final inner =
        token.substring(1, token.length - (selfClosing ? 2 : 1)).trim();
    final space = inner.indexOf(RegExp(r'\s'));
    final name = space < 0 ? inner : inner.substring(0, space);
    final attrs = <String, String>{};
    if (space >= 0) {
      for (final attr in attrPattern.allMatches(inner.substring(space))) {
        attrs[attr.group(1)!] = decodeXmlEntities(attr.group(2)!);
      }
    }
    final node = XmlNode(name, attrs);
    stack.last.children.add(node);
    if (!selfClosing) stack.add(node);
  }
  if (root.children.isEmpty) {
    throw const FormatException('Empty XML document');
  }
  return root.children.first;
}

/// Decodes the five predefined XML entities and numeric references.
String decodeXmlEntities(String input) {
  if (!input.contains('&')) return input;
  return input.replaceAllMapped(
    RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);'),
    (match) {
      final entity = match.group(1)!;
      switch (entity) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
        default:
          final code = entity.startsWith('#x')
              ? int.parse(entity.substring(2), radix: 16)
              : int.parse(entity.substring(1));
          return String.fromCharCode(code);
      }
    },
  );
}
