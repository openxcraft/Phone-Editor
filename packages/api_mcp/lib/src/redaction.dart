/// Redaction helper for log lines and error text.
///
/// Register every sensitive string (API keys, session tokens, prompt or
/// document text that must not be logged) and pass all output through
/// [redact] before it reaches a log sink. Replacement is a fixed
/// placeholder, so redacted output reveals neither the value nor its
/// content.
class Redactor {
  Redactor({Iterable<String> sensitiveValues = const <String>[]}) {
    for (final value in sensitiveValues) {
      registerSensitive(value);
    }
  }

  /// Placeholder substituted for every sensitive value.
  static const String placeholder = '[redacted]';

  final Set<String> _sensitive = <String>{};

  /// Registers a value that must never appear in output. Empty strings
  /// are ignored (replacing them would corrupt all text).
  void registerSensitive(String value) {
    if (value.isNotEmpty) _sensitive.add(value);
  }

  /// Returns [input] with every registered value replaced by
  /// [placeholder]. Longer values are replaced first so overlapping
  /// values redact fully.
  String redact(String input) {
    var out = input;
    final values = _sensitive.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final value in values) {
      out = out.replaceAll(value, placeholder);
    }
    return out;
  }

  /// A safe one-line summary of a prompt for logs: length only, never
  /// content.
  static String promptSummary(String prompt) =>
      'prompt(${prompt.length} chars, content redacted)';
}
