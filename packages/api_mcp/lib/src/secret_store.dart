/// Storage for secrets (API keys, session tokens).
///
/// Implementations in production are backed by platform secure storage.
/// Secret *values* must never appear in logs, error messages, or
/// `toString` output; only secret *names* (keys of this store) may be
/// printed.
abstract class SecretStore {
  /// Returns the secret stored under [key], or null when absent.
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing any previous value.
  Future<void> write(String key, String value);

  /// Removes the secret stored under [key], if any.
  Future<void> delete(String key);
}

/// Volatile [SecretStore] for tests and previews.
class InMemorySecretStore implements SecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }

  /// Names only — values are deliberately never included.
  @override
  String toString() =>
      'InMemorySecretStore(keys: ${_values.keys.toList()..sort()})';
}
