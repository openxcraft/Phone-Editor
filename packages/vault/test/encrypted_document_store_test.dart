import 'dart:convert';
import 'dart:io';

import 'package:doc_engine/doc_engine.dart';
import 'package:test/test.dart';
import 'package:vault/vault.dart';

/// A string that must never appear in plaintext anywhere at rest.
const marker = 'PLAINTEXT-MARKER-7f3a9c';

Document sampleDoc({String id = 'doc-1', int updatedMs = 1000}) {
  final ed = DocumentEditor.newDocument(
    ids: SequentialIdGenerator(),
    title: 'Report $marker',
    nowMs: updatedMs,
  );
  final blockId = ed.document.allBlocks.first.id;
  ed.insertText(blockId, 0, 'Body containing $marker inside.');
  final doc = ed.document;
  return Document(
    id: id,
    title: doc.title,
    createdAtMs: doc.createdAtMs,
    updatedAtMs: updatedMs,
    sections: doc.sections,
  );
}

/// Fixed test keys (not secrets): all-ones vs all-twos 32-byte keys.
InMemoryKeyProvider keyA() =>
    InMemoryKeyProvider.fromBytes(List<int>.filled(32, 1));
InMemoryKeyProvider keyB() =>
    InMemoryKeyProvider.fromBytes(List<int>.filled(32, 2));

void main() {
  group('EncryptedDocumentStore over SqliteDocumentStore', () {
    late Directory dir;
    late String dbPath;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('vault_test');
      dbPath = '${dir.path}/vault.db';
    });

    tearDown(() => dir.delete(recursive: true));

    test('save/load round-trip restores the original document', () async {
      final inner = SqliteDocumentStore(dbPath);
      final store =
          EncryptedDocumentStore(inner: inner, keyProvider: keyA());
      final doc = sampleDoc();
      await store.save(doc);

      final loaded = await store.load(doc.id);
      expect(loaded, isNotNull);
      expect(loaded!.id, doc.id);
      expect(loaded.title, doc.title);
      expect(loaded.allBlocks.first.plainText,
          'Body containing $marker inside.');
      expect(jsonEncode(loaded.toJson()), jsonEncode(doc.toJson()));
      await store.close();
    });

    test('ciphertext at rest contains no plaintext marker', () async {
      final inner = SqliteDocumentStore(dbPath);
      final store =
          EncryptedDocumentStore(inner: inner, keyProvider: keyA());
      await store.save(sampleDoc());
      await store.close();

      final raw = await File(dbPath).readAsBytes();
      // latin1 keeps a 1:1 byte-to-code-unit mapping for the search.
      final rawText = latin1.decode(raw);
      expect(rawText.contains(marker), isFalse,
          reason: 'plaintext marker leaked into the database file');
      expect(rawText.contains('AES-256-GCM'), isTrue,
          reason: 'expected a versioned envelope record at rest');
    });

    test('wrong key throws VaultException, never partial data', () async {
      final inner = SqliteDocumentStore(dbPath);
      final writer =
          EncryptedDocumentStore(inner: inner, keyProvider: keyA());
      final doc = sampleDoc();
      await writer.save(doc);

      final wrongKeyReader =
          EncryptedDocumentStore(inner: inner, keyProvider: keyB());
      await expectLater(
          wrongKeyReader.load(doc.id), throwsA(isA<VaultException>()));
      await expectLater(
          wrongKeyReader.list(), throwsA(isA<VaultException>()));
      await writer.close();
    });

    test('bit-flipped ciphertext throws VaultException', () async {
      final inner = SqliteDocumentStore(dbPath);
      final store =
          EncryptedDocumentStore(inner: inner, keyProvider: keyA());
      final doc = sampleDoc();
      await store.save(doc);

      // Tamper directly through the inner store: flip one bit in the
      // first ciphertext byte of the stored envelope.
      final wrapper = await inner.load(doc.id);
      expect(wrapper, isNotNull);
      final envelope = (jsonDecode(wrapper!.allBlocks.first.plainText)
              as Map)
          .cast<String, Object?>();
      final data = base64Decode(envelope['data'] as String);
      data[0] = data[0] ^ 0x01;
      envelope['data'] = base64Encode(data);
      final tampered = Document(
        id: wrapper.id,
        title: wrapper.title,
        createdAtMs: wrapper.createdAtMs,
        updatedAtMs: wrapper.updatedAtMs,
        sections: <Section>[
          Section(
            id: 'vault-envelope',
            blocks: <Block>[
              Block(
                id: 'vault-envelope-block',
                type: BlockType.paragraph,
                inlines: <InlineNode>[InlineNode(jsonEncode(envelope))],
              ),
            ],
          ),
        ],
      );
      await inner.save(tampered);

      await expectLater(store.load(doc.id), throwsA(isA<VaultException>()));
      await store.close();
    });

    test('list returns decrypted documents, newest first', () async {
      final inner = SqliteDocumentStore(dbPath);
      final store =
          EncryptedDocumentStore(inner: inner, keyProvider: keyA());
      await store.save(sampleDoc(id: 'doc-old', updatedMs: 100));
      await store.save(sampleDoc(id: 'doc-new', updatedMs: 200));

      final docs = await store.list();
      expect(docs.map((d) => d.id), ['doc-new', 'doc-old']);
      expect(docs.first.allBlocks.first.plainText, contains(marker));
      await store.close();
    });

    test('soft-deleted documents stay hidden', () async {
      final inner = SqliteDocumentStore(dbPath);
      final store =
          EncryptedDocumentStore(inner: inner, keyProvider: keyA());
      final doc = sampleDoc();
      await store.save(doc);
      await store.softDelete(doc.id, 5000);

      expect(await store.load(doc.id), isNull);
      expect(await store.list(), isEmpty);
      await store.close();
    });
  });

  group('envelope behaviour', () {
    test('each save uses a fresh nonce; both saves decrypt identically',
        () async {
      final inner = InMemoryDocumentStore();
      final store =
          EncryptedDocumentStore(inner: inner, keyProvider: keyA());
      final doc = sampleDoc();

      await store.save(doc);
      final first = (await inner.load(doc.id))!.allBlocks.first.plainText;
      await store.save(doc);
      final second = (await inner.load(doc.id))!.allBlocks.first.plainText;

      expect(first, isNot(second),
          reason: 'AES-GCM requires a fresh nonce per encryption');
      final firstEnvelope = jsonDecode(first) as Map;
      expect(firstEnvelope['v'], 1);
      expect(firstEnvelope['alg'], 'AES-256-GCM');

      final loaded = await store.load(doc.id);
      expect(jsonEncode(loaded!.toJson()), jsonEncode(doc.toJson()));
      await store.close();
    });

    test('missing document loads as null', () async {
      final store = EncryptedDocumentStore(
          inner: InMemoryDocumentStore(), keyProvider: keyA());
      expect(await store.load('no-such-id'), isNull);
      await store.close();
    });

    test('a non-envelope record in the inner store throws VaultException',
        () async {
      final inner = InMemoryDocumentStore();
      await inner.save(sampleDoc(id: 'plain-1')); // stored unencrypted
      final store =
          EncryptedDocumentStore(inner: inner, keyProvider: keyA());
      await expectLater(store.load('plain-1'), throwsA(isA<VaultException>()));
      await store.close();
    });
  });

  group('InMemoryKeyProvider', () {
    test('generate produces a usable provider', () async {
      final provider = await InMemoryKeyProvider.generate();
      final store = EncryptedDocumentStore(
          inner: InMemoryDocumentStore(), keyProvider: provider);
      final doc = sampleDoc();
      await store.save(doc);
      expect((await store.load(doc.id))!.id, doc.id);
      await store.close();
    });

    test('fromBytes rejects keys that are not 32 bytes', () {
      expect(() => InMemoryKeyProvider.fromBytes(List<int>.filled(16, 0)),
          throwsArgumentError);
      expect(() => InMemoryKeyProvider.fromBytes(List<int>.filled(64, 0)),
          throwsArgumentError);
    });
  });
}
