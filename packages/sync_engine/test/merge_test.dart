import 'package:doc_engine/doc_engine.dart';
import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

import 'support.dart';

MergeOutcome merge({
  required Document local,
  required Document remote,
  Document? base,
  String localSiteId = 'site-a',
  String remoteSiteId = 'site-b',
}) =>
    mergeDocuments(
      local: local,
      remote: remote,
      localSiteId: localSiteId,
      remoteSiteId: remoteSiteId,
      conflictIds: FixedIds('conflict'),
      base: base,
    );

void main() {
  group('non-conflicting merges', () {
    test('rename on one side + block edit on the other combine (3-way)',
        () {
      final base = buildDoc(title: 'Plan', updatedAtMs: 100);
      final renamed = base.copy()
        ..title = 'Plan v2'
        ..updatedAtMs = 200;
      final edited = base.copy()..updatedAtMs = 210;
      setBlockText(edited, 'blk-1', 'Edited body');

      final outcome = merge(local: renamed, remote: edited, base: base);
      expect(outcome.merged.title, 'Plan v2');
      expect(blockText(outcome.merged, 'blk-1'), 'Edited body');
      expect(outcome.hasConflict, isFalse);
      expect(outcome.conflictCopy, isNull);
      expect(outcome.merged.updatedAtMs, 210); // max of both
      expect(outcome.merged.syncStatus, SyncStatus.pending);
    });

    test('blocks added on different sides union, without a base', () {
      final local = buildDoc(title: 'T', updatedAtMs: 200);
      local.sections.first.blocks.add(mkBlock('blk-L', 'from local'));
      final remote = buildDoc(title: 'T', updatedAtMs: 210);
      remote.sections.first.blocks.add(mkBlock('blk-R', 'from remote'));

      final outcome = merge(local: local, remote: remote);
      final ids = outcome.merged.allBlocks.map((b) => b.id).toSet();
      expect(ids, containsAll(<String>['blk-1', 'blk-L', 'blk-R']));
      expect(outcome.hasConflict, isFalse);
    });

    test('identical versions merge to themselves with no conflict', () {
      final a = buildDoc(updatedAtMs: 100, syncStatus: SyncStatus.synced);
      final outcome = merge(local: a, remote: a.copy());
      expect(outcome.hasConflict, isFalse);
      expect(outcome.merged.syncStatus, SyncStatus.synced);
    });
  });

  group('conflicts: deterministic winner + losing copy preserved', () {
    test('same block edited both sides: higher updated_at wins', () {
      final base = buildDoc(updatedAtMs: 100);
      final local = base.copy()..updatedAtMs = 200;
      setBlockText(local, 'blk-1', 'local words');
      final remote = base.copy()..updatedAtMs = 300;
      setBlockText(remote, 'blk-1', 'remote words');

      final outcome = merge(local: local, remote: remote, base: base);
      expect(blockText(outcome.merged, 'blk-1'), 'remote words');
      expect(outcome.winnerSiteId, 'site-b');
      expect(outcome.conflictedBlockIds, <String>['blk-1']);
      final copy = outcome.conflictCopy!;
      expect(copy.id, isNot(base.id));
      expect(copy.title, 'Doc (conflict)');
      expect(blockText(copy, 'blk-1'), 'local words'); // loser preserved
      expect(copy.deletedAtMs, isNull);
      expect(copy.syncStatus, SyncStatus.pending);
    });

    test('tie on updated_at breaks by higher site id', () {
      final base = buildDoc(updatedAtMs: 100);
      final local = base.copy()..updatedAtMs = 200;
      setBlockText(local, 'blk-1', 'from site-a');
      final remote = base.copy()..updatedAtMs = 200;
      setBlockText(remote, 'blk-1', 'from site-b');

      final outcome = merge(local: local, remote: remote, base: base);
      expect(blockText(outcome.merged, 'blk-1'), 'from site-b');
      expect(outcome.winnerSiteId, 'site-b');
      // And symmetrically: give local the higher site id and it wins.
      final flipped = merge(
        local: remote,
        remote: local,
        base: base,
        localSiteId: 'site-b',
        remoteSiteId: 'site-a',
      );
      expect(blockText(flipped.merged, 'blk-1'), 'from site-b');
    });

    test('title conflict: winner title in merged, loser copy kept', () {
      final base = buildDoc(title: 'Base', updatedAtMs: 100);
      final local = base.copy()
        ..title = 'Local name'
        ..updatedAtMs = 500;
      final remote = base.copy()
        ..title = 'Remote name'
        ..updatedAtMs = 400;

      final outcome = merge(local: local, remote: remote, base: base);
      expect(outcome.titleConflicted, isTrue);
      expect(outcome.merged.title, 'Local name');
      expect(outcome.conflictCopy!.title, 'Remote name (conflict)');
    });

    test('block deleted on one side, edited on the other', () {
      final base = buildDoc(blockTexts: <String>['Keep', 'Victim'], updatedAtMs: 100);
      final deletedSide = base.copy()..updatedAtMs = 400;
      deletedSide.sections.first.blocks.removeWhere((b) => b.id == 'blk-2');
      final editedSide = base.copy()..updatedAtMs = 200;
      setBlockText(editedSide, 'blk-2', 'Victim edited');

      // Deleting side has the higher updated_at and wins.
      final outcome =
          merge(local: deletedSide, remote: editedSide, base: base);
      expect(outcome.merged.blockById('blk-2'), isNull);
      expect(outcome.conflictedBlockIds, contains('blk-2'));
      expect(blockText(outcome.conflictCopy!, 'blk-2'), 'Victim edited');
    });
  });

  group('delete-vs-edit at document level', () {
    test('delete wins on recency: merged deleted, edited copy preserved',
        () {
      final base = buildDoc(updatedAtMs: 100);
      final deleted = base.copy()
        ..deletedAtMs = 300
        ..updatedAtMs = 300;
      final edited = base.copy()..updatedAtMs = 200;
      setBlockText(edited, 'blk-1', 'Edited before delete landed');

      final outcome = merge(local: deleted, remote: edited, base: base);
      expect(outcome.deleteEditConflict, isTrue);
      expect(outcome.merged.deletedAtMs, 300);
      final copy = outcome.conflictCopy!;
      expect(copy.deletedAtMs, isNull);
      expect(blockText(copy, 'blk-1'), 'Edited before delete landed');
    });

    test('edit wins on recency: merged alive, deleting version preserved',
        () {
      final base = buildDoc(updatedAtMs: 100);
      final deleted = base.copy()
        ..deletedAtMs = 200
        ..updatedAtMs = 200;
      final edited = base.copy()..updatedAtMs = 300;
      setBlockText(edited, 'blk-1', 'Newer edit');

      final outcome = merge(local: deleted, remote: edited, base: base);
      expect(outcome.deleteEditConflict, isTrue);
      expect(outcome.merged.deletedAtMs, isNull);
      expect(blockText(outcome.merged, 'blk-1'), 'Newer edit');
      expect(outcome.conflictCopy, isNotNull);
      expect(outcome.conflictCopy!.title, 'Doc (conflict)');
    });

    test('deleting an unchanged document is not a conflict', () {
      final base = buildDoc(updatedAtMs: 100);
      final deleted = base.copy()
        ..deletedAtMs = 200
        ..updatedAtMs = 200;

      final outcome = merge(local: deleted, remote: base.copy(), base: base);
      expect(outcome.deleteEditConflict, isFalse);
      expect(outcome.merged.deletedAtMs, 200);
      expect(outcome.conflictCopy, isNull);
    });
  });
}
