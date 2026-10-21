/// Raised for every vault failure: wrong key, tampered ciphertext,
/// malformed or unsupported envelope, or a stored record that is not a
/// vault envelope at all.
///
/// Messages are deliberately generic and never contain key material,
/// plaintext, or ciphertext.
class VaultException implements Exception {
  VaultException(this.message);

  final String message;

  @override
  String toString() => 'VaultException: $message';
}
