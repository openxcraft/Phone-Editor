import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:doc_engine/doc_engine.dart';

import 'key_provider.dart';
import 'vault_exception.dart';

/// A [DocumentStore] decorator that encrypts every document at rest with
/// AES-256-GCM before delegating to an inner store.
///
/// On save, the document's deterministic JSON is encrypted under the key
/// from the [KeyProvider], with a fresh random nonce per save and the
/// document id bound as additional authenticated data (so a ciphertext
/// record cannot be transplanted onto another document's row). The inner
/// store receives a wrapper [Document] whose single block carries this
/// versioned envelope JSON as its text:
///
/// ```json
/// {"v": 1, "alg": "AES-256-GCM", "nonce": "<base64>",
///  "mac": "<base64>", "data": "<base64>"}
/// ```
///
/// The wrapper's title is intentionally blank so titles do not leak into
/// the inner store's plaintext columns. Only sync metadata (`created_at`,
/// `updated_at`, `deleted_at`, `sync_status`) is carried over in the
/// clear, because the inner store needs it for listing and delta sync.
///
/// On load, any failure — wrong key, tampered ciphertext, malformed or
/// unsupported envelope — throws [VaultException]. Partial or
/// unauthenticated data is never returned.
class EncryptedDocumentStore implements DocumentStore {
  EncryptedDocumentStore({
    required DocumentStore inner,
    required KeyProvider keyProvider,
  })  : _inner = inner,
        _keyProvider = keyProvider;

  final DocumentStore _inner;
  final KeyProvider _keyProvider;
  final AesGcm _algorithm = AesGcm.with256bits();

  static const int envelopeVersion = 1;
  static const String envelopeAlgorithm = 'AES-256-GCM';
  static const String _envelopeSectionId = 'vault-envelope';
  static const String _envelopeBlockId = 'vault-envelope-block';

  @override
  Future<void> save(Document doc) async {
    final key = await _keyProvider.getKey();
    final plainBytes = utf8.encode(jsonEncode(doc.toJson()));
    // No explicit nonce: the cryptography package generates a fresh
    // random one per encryption, which AES-GCM requires for safety
    // under a reused key.
    final box = await _algorithm.encrypt(
      plainBytes,
      secretKey: key,
      aad: utf8.encode(doc.id),
    );
    final envelope = <String, Object?>{
      'v': envelopeVersion,
      'alg': envelopeAlgorithm,
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'data': base64Encode(box.cipherText),
    };
    await _inner.save(_wrap(doc, jsonEncode(envelope)));
  }

  @override
  Future<Document?> load(String id) async {
    final wrapper = await _inner.load(id);
    if (wrapper == null) return null;
    return _decrypt(wrapper);
  }

  @override
  Future<List<Document>> list() async {
    final wrappers = await _inner.list();
    final docs = <Document>[];
    for (final wrapper in wrappers) {
      docs.add(await _decrypt(wrapper));
    }
    return docs;
  }

  @override
  Future<void> softDelete(String id, int deletedAtMs) =>
      _inner.softDelete(id, deletedAtMs);

  @override
  Future<void> close() => _inner.close();

  Document _wrap(Document source, String envelopeJson) {
    return Document(
      id: source.id,
      title: '',
      createdAtMs: source.createdAtMs,
      updatedAtMs: source.updatedAtMs,
      deletedAtMs: source.deletedAtMs,
      syncStatus: source.syncStatus,
      sections: <Section>[
        Section(
          id: _envelopeSectionId,
          blocks: <Block>[
            Block(
              id: _envelopeBlockId,
              type: BlockType.paragraph,
              inlines: <InlineNode>[InlineNode(envelopeJson)],
            ),
          ],
        ),
      ],
    );
  }

  Future<Document> _decrypt(Document wrapper) async {
    final envelopeJson = _envelopeJsonOf(wrapper);
    final Map<String, Object?> envelope;
    try {
      final decoded = jsonDecode(envelopeJson);
      if (decoded is! Map) {
        throw VaultException('Stored record is not a vault envelope');
      }
      envelope = decoded.cast<String, Object?>();
    } on VaultException {
      rethrow;
    } catch (_) {
      throw VaultException('Stored record is not a vault envelope');
    }

    if (envelope['v'] != envelopeVersion ||
        envelope['alg'] != envelopeAlgorithm) {
      throw VaultException('Unsupported vault envelope');
    }
    final nonceField = envelope['nonce'];
    final macField = envelope['mac'];
    final dataField = envelope['data'];
    if (nonceField is! String || macField is! String || dataField is! String) {
      throw VaultException('Malformed vault envelope');
    }

    final SecretBox box;
    try {
      box = SecretBox(
        base64Decode(dataField),
        nonce: base64Decode(nonceField),
        mac: Mac(base64Decode(macField)),
      );
    } catch (_) {
      throw VaultException('Malformed vault envelope');
    }

    final key = await _keyProvider.getKey();
    final List<int> plainBytes;
    try {
      plainBytes = await _algorithm.decrypt(
        box,
        secretKey: key,
        aad: utf8.encode(wrapper.id),
      );
    } on SecretBoxAuthenticationError {
      throw VaultException('Vault record failed authentication');
    } catch (_) {
      throw VaultException('Vault record could not be decrypted');
    }

    final Document doc;
    try {
      doc = Document.fromJson(
          (jsonDecode(utf8.decode(plainBytes)) as Map).cast<String, Object?>());
    } catch (_) {
      throw VaultException('Decrypted record is not a valid document');
    }
    if (doc.id != wrapper.id) {
      throw VaultException('Decrypted record does not match its row');
    }
    return doc;
  }

  String _envelopeJsonOf(Document wrapper) {
    for (final block in wrapper.allBlocks) {
      return block.plainText;
    }
    throw VaultException('Stored record is not a vault envelope');
  }
}
