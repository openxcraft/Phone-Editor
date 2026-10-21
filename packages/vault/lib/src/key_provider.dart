import 'package:cryptography/cryptography.dart';

/// Supplies the vault data-encryption key.
///
/// Implementations in the app are expected to back this with platform
/// secure storage / hardware-bound key storage (see SECURITY.md at the
/// repo root). Keys obtained from a provider must never be logged,
/// serialized, or stored alongside ciphertext records.
abstract interface class KeyProvider {
  Future<SecretKey> getKey();
}

/// Holds a single AES-256 key in process memory. For tests, previews,
/// and as the reference implementation of the [KeyProvider] contract.
class InMemoryKeyProvider implements KeyProvider {
  InMemoryKeyProvider._(this._key);

  final SecretKey _key;

  /// Generates a fresh random 256-bit key.
  static Future<InMemoryKeyProvider> generate() async {
    final key = await AesGcm.with256bits().newSecretKey();
    return InMemoryKeyProvider._(key);
  }

  /// Wraps existing raw key bytes, which must be exactly 32 bytes
  /// (AES-256). The bytes are copied into a [SecretKey]; callers should
  /// not retain their own copy longer than necessary.
  factory InMemoryKeyProvider.fromBytes(List<int> bytes) {
    if (bytes.length != 32) {
      throw ArgumentError.value(
          bytes.length, 'bytes', 'An AES-256 key must be exactly 32 bytes');
    }
    return InMemoryKeyProvider._(SecretKey(List<int>.of(bytes)));
  }

  @override
  Future<SecretKey> getKey() async => _key;
}
