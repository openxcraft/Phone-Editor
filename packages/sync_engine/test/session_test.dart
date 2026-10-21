import 'package:doc_engine/doc_engine.dart';
import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

import 'support.dart';

SyncClient client(String site, InMemorySyncServer server) => SyncClient(
      siteId: site,
      store: InMemoryDocumentStore(),
      server: server,
      conflictIds: FixedIds('$site-conflict'),
    );

/// Creates a doc on A, syncs A and B so both hold it as `synced` at
/// revision 1, and returns the shared document.
Future<(SyncClient, SyncClient, Document)> seededPair(
    InMemorySyncServer server) async {
  final a = client('site-a', server);
  final b = client('site-b', server);
  final doc = buildDoc(blockTexts: <String>['Original']);
  await a.upsertLocal(doc);
  await a.sync();
  await b.sync();
  return (a, b, doc);
}

void main() {
  group('basic push/pull', () {
    test('create on A reaches B; edit on B reaches A; no duplicates',
        () async {
      final server = InMemorySyncServer();
      final (a, b, doc) = await seededPair(server);
      expect(blockText(b.localDocument(doc.id)!, 'blk-1'), 'Original');
      expect(b.localDocument(doc.id)!.syncStatus, SyncStatus.synced);

      final edited = b.localDocument(doc.id)!.copy()..updatedAtMs = 200;
      setBlockText(edited, 'blk-1', 'Edited by B');
      await b.upsertLocal(edited);
      final pushResult = await b.sync();
      expect(pushResult.pushed, 1);

      await a.sync();
      expect(blockText(a.localDocument(doc.id)!, 'blk-1'), 'Edited by B');
      expect((await a.localDocuments()), hasLength(1));
      expect((await b.localDocuments()), hasLength(1));
      expect(server.latestRevision, 2);
    });

    test('repeated syncs are stable: no re-push, no duplication', () async {
      final server = InMemorySyncServer();
      final (a, b, doc) = await seededPair(server);
      final again1 = await a.sync();
      final again2 = await b.sync();
      expect(again1.pushed, 0);
      expect(again2.pushed, 0);
      expect(server.latestRevision, 1);
      expect((await a.localDocuments()), hasLength(1));
      expect(a.localDocument(doc.id), isNotNull);
    });
  });

  group('offline conflict scenarios', () {
    test('rename-vs-edit: both changes combine, no conflict copy', () async {
      final server = InMemorySyncServer();
      final (a, b, doc) = await seededPair(server);

      final renamed = a.localDocument(doc.id)!.copy()
        ..title = 'Renamed'
        ..updatedAtMs = 200;
      await a.upsertLocal(renamed);

      final edited = b.localDocument(doc.id)!.copy()..updatedAtMs = 210;
      setBlockText(edited, 'blk-1', 'Body from B');
      await b.upsertLocal(edited);

      await a.sync(); // pushes the rename
      final bResult = await b.sync(); // merges rename + edit, pushes result
      expect(bResult.conflictCopies, isEmpty);
      await a.sync(); // pulls the merged version

      for (final c in <SyncClient>[a, b]) {
        final d = c.localDocument(doc.id)!;
        expect(d.title, 'Renamed');
        expect(blockText(d, 'blk-1'), 'Body from B');
      }
      final serverDoc = server.document(doc.id)!;
      expect(serverDoc.title, 'Renamed');
      expect(blockText(serverDoc, 'blk-1'), 'Body from B');
    });

    test('same-block conflict: winner lands, loser kept as conflict copy',
        () async {
      final server = InMemorySyncServer();
      final (a, b, doc) = await seededPair(server);

      final editA = a.localDocument(doc.id)!.copy()..updatedAtMs = 200;
      setBlockText(editA, 'blk-1', 'A words');
      await a.upsertLocal(editA);

      final editB = b.localDocument(doc.id)!.copy()..updatedAtMs = 300;
      setBlockText(editB, 'blk-1', 'B words');
      await b.upsertLocal(editB);

      await a.sync();
      final bResult = await b.sync();
      expect(blockText(b.localDocument(doc.id)!, 'blk-1'), 'B words');
      expect(bResult.conflictCopies, hasLength(1));
      final copy = bResult.conflictCopies.single;
      expect(copy.title, 'Doc (conflict)');
      expect(blockText(copy, 'blk-1'), 'A words'); // nothing lost

      await a.sync();
      expect(blockText(a.localDocument(doc.id)!, 'blk-1'), 'B words');
    });

    test('delete-vs-edit, delete newer: doc deleted, edit preserved as copy',
        () async {
      final server = InMemorySyncServer();
      final (a, b, doc) = await seededPair(server);

      final edited = b.localDocument(doc.id)!.copy()..updatedAtMs = 250;
      setBlockText(edited, 'blk-1', 'Edited offline');
      await b.upsertLocal(edited);
      await a.deleteLocal(doc.id, 300);

      await a.sync(); // pushes the tombstone
      final bResult = await b.sync(); // merges: delete wins (300 > 250)
      expect(bResult.conflictCopies, hasLength(1));
      expect(blockText(bResult.conflictCopies.single, 'blk-1'),
          'Edited offline');
      expect(b.localDocument(doc.id)!.deletedAtMs, 300);
      expect((await b.localDocuments()).map((d) => d.title),
          <String>['Doc (conflict)']); // only the copy remains listed
      expect(server.document(doc.id)!.deletedAtMs, 300);
    });

    test('delete-vs-edit, edit newer: doc survives on both clients',
        () async {
      final server = InMemorySyncServer();
      final (a, b, doc) = await seededPair(server);

      final edited = b.localDocument(doc.id)!.copy()..updatedAtMs = 300;
      setBlockText(edited, 'blk-1', 'Newer edit');
      await b.upsertLocal(edited);
      await a.deleteLocal(doc.id, 250);

      await a.sync();
      final bResult = await b.sync();
      expect(bResult.conflictCopies, hasLength(1)); // deleting version kept
      expect(b.localDocument(doc.id)!.deletedAtMs, isNull);
      expect(blockText(b.localDocument(doc.id)!, 'blk-1'), 'Newer edit');

      await a.sync(); // A fast-forwards to the resurrected document
      expect(a.localDocument(doc.id)!.deletedAtMs, isNull);
      expect(blockText(a.localDocument(doc.id)!, 'blk-1'), 'Newer edit');
    });
  });

  group('resumable and cancellable pull', () {
    Future<InMemorySyncServer> seededServer() async {
      final server = InMemorySyncServer();
      for (var i = 1; i <= 3; i++) {
        server.push(
          buildDoc(id: 'doc-$i', title: 'Doc $i', updatedAtMs: 100 + i),
          originSiteId: 'seed',
        );
      }
      return server;
    }

    test('batch-limited pull resumes without loss or duplication', () async {
      final server = await seededServer();
      final b = client('site-b', server);

      final first = await b.sync(maxPullEntries: 2);
      expect(first.completed, isFalse);
      expect(first.pulled, 2);
      expect(first.lastRevision, 2);
      expect((await b.localDocuments()), hasLength(2));

      final second = await b.sync();
      expect(second.completed, isTrue);
      expect(second.lastRevision, 3);
      final docs = await b.localDocuments();
      expect(docs, hasLength(3)); // no duplicates from the resume
      expect(docs.map((d) => d.id).toSet(),
          <String>{'doc-1', 'doc-2', 'doc-3'});
    });

    test('cancel mid-pull stops cleanly; resume completes', () async {
      final server = await seededServer();
      final b = client('site-b', server);
      b.onPullEntry = (_) => b.cancel();

      final interrupted = await b.sync();
      expect(interrupted.completed, isFalse);
      expect(interrupted.pulled, 1);
      expect(interrupted.lastRevision, 1);
      expect((await b.localDocuments()), hasLength(1));

      b.onPullEntry = null;
      b.clearCancel();
      final resumed = await b.sync();
      expect(resumed.completed, isTrue);
      expect(resumed.lastRevision, 3);
      expect((await b.localDocuments()), hasLength(3));
    });
  });
}
