import 'dart:io';

import 'package:doc_engine/doc_engine.dart';
import 'package:test/test.dart';

Document sampleDoc(String id, int updatedMs, {String title = 'Doc'}) {
  final ids = SequentialIdGenerator();
  final ed = DocumentEditor.newDocument(ids: ids, title: title, nowMs: updatedMs);
  // Reassign the generated ID so tests control identity.
  final doc = ed.document.copy();
  return Document(
    id: id,
    title: doc.title,
    createdAtMs: doc.createdAtMs,
    updatedAtMs: updatedMs,
    sections: doc.sections,
  );
}

void main() {
  group('InMemoryDocumentStore contract', () {
    test('save/load/list ordering and soft delete', () async {
      final store = InMemoryDocumentStore();
      await store.save(sampleDoc('a', 100));
      await store.save(sampleDoc('b', 200));
      expect((await store.list()).map((d) => d.id), ['b', 'a']);
      expect((await store.load('a'))!.id, 'a');

      await store.softDelete('b', 300);
      expect(await store.load('b'), isNull);
      expect((await store.list()).map((d) => d.id), ['a']);
      await store.close();
    });
  });

  group('SqliteDocumentStore', () {
    test('persists across close/reopen on a real file (offline)', () async {
      final dir = await Directory.systemTemp.createTemp('doc_engine_test');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/test.db';

      final doc = sampleDoc('doc-1', 500, title: 'Persisted');
      final ids = SequentialIdGenerator();
      final ed = DocumentEditor(doc, ids: ids);
      final blockId = doc.allBlocks.first.id;
      ed.insertText(blockId, 0, 'Saved offline');

      var store = SqliteDocumentStore(path);
      await store.save(ed.document);
      await store.close();

      store = SqliteDocumentStore(path);
      final loaded = await store.load('doc-1');
      expect(loaded, isNotNull);
      expect(loaded!.title, 'Persisted');
      expect(loaded.allBlocks.first.plainText, 'Saved offline');
      expect(loaded.syncStatus, SyncStatus.localOnly);

      await store.softDelete('doc-1', 900);
      expect(await store.load('doc-1'), isNull);
      expect(await store.list(), isEmpty);
      await store.close();
    });

    test('in-memory store honours sync_status round-trip', () async {
      final store = SqliteDocumentStore.inMemory();
      final doc = sampleDoc('doc-2', 100);
      doc.syncStatus = SyncStatus.pending;
      await store.save(doc);
      expect((await store.load('doc-2'))!.syncStatus, SyncStatus.pending);
      await store.close();
    });
  });
}
