import 'a1.dart';

/// Formula tokenizer, AST, and recursive-descent parser.
///
/// Grammar (loosest to tightest binding):
///
/// ```
/// expression  := comparison
/// comparison  := concat (('=' | '<>' | '<' | '<=' | '>' | '>=') concat)*
/// concat      := additive ('&' additive)*
/// additive    := term (('+' | '-') term)*
/// term        := power (('*' | '/') power)*
/// power       := unary ('^' unary)*          // left-associative
/// unary       := ('-' | '+') unary | postfix
/// postfix     := primary '%'*
/// primary     := number | string | boolean | reference [':' reference]
///              | functionName '(' [expression (',' expression)*] ')'
///              | '(' expression ')'
/// ```
///
/// Ranges are valid only where a function argument is expected; the
/// evaluator rejects a range used as a scalar with `#VALUE!`.

enum TokenKind {
  number,
  string,
  identifier, // function name, boolean literal, or bare name
  cellRef,
  operator,
  leftParen,
  rightParen,
  comma,
  colon,
  end,
}

class Token {
  const Token(this.kind, this.text, [this.numberValue]);

  final TokenKind kind;
  final String text;
  final double? numberValue;

  @override
  String toString() => 'Token($kind, $text)';
}

/// Thrown by the tokenizer/parser. [errorCode] is the cell error the
/// formula should evaluate to (`#REF!` for malformed references,
/// `#VALUE!` for other syntax errors).
class FormulaSyntaxException implements Exception {
  const FormulaSyntaxException(this.message, {this.errorCode = '#VALUE!'});

  final String message;
  final String errorCode;

  @override
  String toString() => 'FormulaSyntaxException: $message';
}

List<Token> tokenize(String source) {
  final tokens = <Token>[];
  var i = 0;
  final s = source;

  bool isDigit(int u) => u >= 0x30 && u <= 0x39;
  bool isLetter(int u) =>
      (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A);

  while (i < s.length) {
    final u = s.codeUnitAt(i);
    final ch = s[i];

    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      i++;
      continue;
    }

    // Number: digits with optional fraction and exponent, or `.5`.
    if (isDigit(u) ||
        (ch == '.' && i + 1 < s.length && isDigit(s.codeUnitAt(i + 1)))) {
      final start = i;
      var seenDot = false;
      while (i < s.length &&
          (isDigit(s.codeUnitAt(i)) || (s[i] == '.' && !seenDot))) {
        if (s[i] == '.') seenDot = true;
        i++;
      }
      if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
        var j = i + 1;
        if (j < s.length && (s[j] == '+' || s[j] == '-')) j++;
        if (j < s.length && isDigit(s.codeUnitAt(j))) {
          i = j;
          while (i < s.length && isDigit(s.codeUnitAt(i))) {
            i++;
          }
        }
      }
      final text = s.substring(start, i);
      final value = double.tryParse(text);
      if (value == null) {
        throw FormulaSyntaxException('Invalid number: $text');
      }
      tokens.add(Token(TokenKind.number, text, value));
      continue;
    }

    // String literal with "" as an escaped quote (RFC-style, as in Excel).
    if (ch == '"') {
      final buf = StringBuffer();
      i++;
      var closed = false;
      while (i < s.length) {
        if (s[i] == '"') {
          if (i + 1 < s.length && s[i + 1] == '"') {
            buf.write('"');
            i += 2;
          } else {
            closed = true;
            i++;
            break;
          }
        } else {
          buf.write(s[i]);
          i++;
        }
      }
      if (!closed) {
        throw const FormulaSyntaxException('Unterminated string literal');
      }
      tokens.add(Token(TokenKind.string, buf.toString()));
      continue;
    }

    // Identifier or cell reference: [$] letters [$] digits, or a word.
    if (isLetter(u) || ch == r'$' || ch == '_') {
      final start = i;
      if (i < s.length && s[i] == r'$') i++;
      while (i < s.length &&
          (isLetter(s.codeUnitAt(i)) ||
              isDigit(s.codeUnitAt(i)) ||
              s[i] == '_' ||
              s[i] == '.')) {
        i++;
      }
      if (i < s.length && s[i] == r'$') {
        i++;
        while (i < s.length && isDigit(s.codeUnitAt(i))) {
          i++;
        }
      }
      final text = s.substring(start, i);
      // A word directly followed by '(' is a function call, even when its
      // shape resembles a reference (e.g. LOG10). Otherwise the ref
      // shape decides.
      final followedByParen = i < s.length && s[i] == '(';
      if (!followedByParen && _refShape.hasMatch(text)) {
        tokens.add(Token(TokenKind.cellRef, text.toUpperCase()));
        continue;
      }
      tokens.add(Token(TokenKind.identifier, text.toUpperCase()));
      continue;
    }

    // Two-character operators first.
    if (i + 1 < s.length) {
      final two = s.substring(i, i + 2);
      if (two == '<=' || two == '>=' || two == '<>') {
        tokens.add(Token(TokenKind.operator, two));
        i += 2;
        continue;
      }
    }

    switch (ch) {
      case '(':
        tokens.add(const Token(TokenKind.leftParen, '('));
      case ')':
        tokens.add(const Token(TokenKind.rightParen, ')'));
      case ',':
        tokens.add(const Token(TokenKind.comma, ','));
      case ':':
        tokens.add(const Token(TokenKind.colon, ':'));
      case '+':
      case '-':
      case '*':
      case '/':
      case '^':
      case '%':
      case '&':
      case '=':
      case '<':
      case '>':
        tokens.add(Token(TokenKind.operator, ch));
      default:
        throw FormulaSyntaxException('Unexpected character: $ch');
    }
    i++;
  }

  tokens.add(const Token(TokenKind.end, ''));
  return tokens;
}

final RegExp _refShape = RegExp(r'^\$?[A-Za-z]{1,3}\$?[0-9]+$');

// --- AST --------------------------------------------------------------------

sealed class AstNode {
  const AstNode();
}

final class NumberNode extends AstNode {
  const NumberNode(this.value);
  final double value;
}

final class StringNode extends AstNode {
  const StringNode(this.value);
  final String value;
}

final class BoolNode extends AstNode {
  const BoolNode(this.value);
  final bool value;
}

final class RefNode extends AstNode {
  const RefNode(this.ref);
  final CellRef ref;
}

final class RangeNode extends AstNode {
  const RangeNode(this.range);
  final CellRange range;
}

final class UnaryNode extends AstNode {
  const UnaryNode(this.op, this.operand);
  final String op; // '-' or '+'
  final AstNode operand;
}

final class PercentNode extends AstNode {
  const PercentNode(this.operand);
  final AstNode operand;
}

final class BinaryNode extends AstNode {
  const BinaryNode(this.op, this.left, this.right);
  final String op;
  final AstNode left;
  final AstNode right;
}

final class FunctionNode extends AstNode {
  const FunctionNode(this.name, this.args);
  final String name; // upper-case
  final List<AstNode> args;
}

/// Collects every cell a formula depends on: individual refs plus every
/// cell inside every range (row-major order, de-duplicated by the caller
/// if needed).
List<CellRef> astDependencies(AstNode node) {
  final out = <CellRef>[];
  void visit(AstNode n) {
    switch (n) {
      case RefNode r:
        out.add(r.ref);
      case RangeNode r:
        out.addAll(r.range.cells);
      case UnaryNode u:
        visit(u.operand);
      case PercentNode p:
        visit(p.operand);
      case BinaryNode b:
        visit(b.left);
        visit(b.right);
      case FunctionNode f:
        for (final arg in f.args) {
          visit(arg);
        }
      case NumberNode() || StringNode() || BoolNode():
        break;
    }
  }

  visit(node);
  return out;
}

// --- Parser -------------------------------------------------------------------

/// Parses a formula body (with or without the leading `=`).
AstNode parseFormula(String source) {
  var body = source.trim();
  if (body.startsWith('=')) body = body.substring(1);
  final parser = _Parser(tokenize(body));
  final node = parser.parseExpression();
  parser.expectEnd();
  return node;
}

class _Parser {
  _Parser(this.tokens);

  final List<Token> tokens;
  var _pos = 0;

  Token get _peek => tokens[_pos];
  Token _advance() => tokens[_pos++];

  bool _isOp(String op) => _peek.kind == TokenKind.operator && _peek.text == op;

  AstNode parseExpression() => _parseComparison();

  void expectEnd() {
    if (_peek.kind != TokenKind.end) {
      throw FormulaSyntaxException('Unexpected trailing input: ${_peek.text}');
    }
  }

  AstNode _parseComparison() {
    var left = _parseConcat();
    while (_peek.kind == TokenKind.operator &&
        const {'=', '<>', '<', '<=', '>', '>='}.contains(_peek.text)) {
      final op = _advance().text;
      left = BinaryNode(op, left, _parseConcat());
    }
    return left;
  }

  AstNode _parseConcat() {
    var left = _parseAdditive();
    while (_isOp('&')) {
      _advance();
      left = BinaryNode('&', left, _parseAdditive());
    }
    return left;
  }

  AstNode _parseAdditive() {
    var left = _parseTerm();
    while (_isOp('+') || _isOp('-')) {
      final op = _advance().text;
      left = BinaryNode(op, left, _parseTerm());
    }
    return left;
  }

  AstNode _parseTerm() {
    var left = _parsePower();
    while (_isOp('*') || _isOp('/')) {
      final op = _advance().text;
      left = BinaryNode(op, left, _parsePower());
    }
    return left;
  }

  AstNode _parsePower() {
    var left = _parseUnary();
    while (_isOp('^')) {
      _advance();
      left = BinaryNode('^', left, _parseUnary());
    }
    return left;
  }

  AstNode _parseUnary() {
    if (_isOp('-') || _isOp('+')) {
      final op = _advance().text;
      return UnaryNode(op, _parseUnary());
    }
    return _parsePostfix();
  }

  AstNode _parsePostfix() {
    var node = _parsePrimary();
    while (_isOp('%')) {
      _advance();
      node = PercentNode(node);
    }
    return node;
  }

  AstNode _parsePrimary() {
    final token = _peek;
    switch (token.kind) {
      case TokenKind.number:
        _advance();
        return NumberNode(token.numberValue!);
      case TokenKind.string:
        _advance();
        return StringNode(token.text);
      case TokenKind.cellRef:
        _advance();
        final ref = CellRef.tryParse(token.text);
        if (ref == null) {
          throw FormulaSyntaxException('Invalid reference: ${token.text}',
              errorCode: '#REF!');
        }
        if (_peek.kind == TokenKind.colon) {
          _advance();
          final endToken = _peek;
          if (endToken.kind != TokenKind.cellRef) {
            throw const FormulaSyntaxException('Range end must be a cell '
                'reference', errorCode: '#REF!');
          }
          _advance();
          final end = CellRef.tryParse(endToken.text);
          if (end == null) {
            throw FormulaSyntaxException(
                'Invalid reference: ${endToken.text}',
                errorCode: '#REF!');
          }
          return RangeNode(CellRange(ref, end));
        }
        return RefNode(ref);
      case TokenKind.identifier:
        _advance();
        if (token.text == 'TRUE') return const BoolNode(true);
        if (token.text == 'FALSE') return const BoolNode(false);
        if (_peek.kind == TokenKind.leftParen) {
          _advance();
          final args = <AstNode>[];
          if (_peek.kind != TokenKind.rightParen) {
            args.add(parseExpression());
            while (_peek.kind == TokenKind.comma) {
              _advance();
              args.add(parseExpression());
            }
          }
          if (_peek.kind != TokenKind.rightParen) {
            throw const FormulaSyntaxException('Missing closing parenthesis');
          }
          _advance();
          return FunctionNode(token.text, args);
        }
        // A bare name that is not a boolean literal: keep it as a
        // zero-argument "unknown name" function so evaluation yields
        // #NAME? rather than a syntax error.
        return FunctionNode(token.text, const <AstNode>[]);
      case TokenKind.leftParen:
        _advance();
        final inner = parseExpression();
        if (_peek.kind != TokenKind.rightParen) {
          throw const FormulaSyntaxException('Missing closing parenthesis');
        }
        _advance();
        return inner;
      default:
        throw FormulaSyntaxException(
            'Unexpected token: ${token.text.isEmpty ? '(end)' : token.text}');
    }
  }
}
