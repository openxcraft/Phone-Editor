import 'dart:convert';

import 'package:doc_engine/doc_engine.dart';
import 'package:sync_engine/sync_engine.dart';
import 'package:test/test.dart';

import 'support.dart';

String jsonOf(Document d) => jsonEncode(d.toJson());

void main() {
  group('DocumentDelta.compute + apply reproduces the target', () {
    test('title and block-text changes only', () {
      final base = buildDoc(title: 'Old', blockTexts: <String>['Hello', 'World']);
      final target = base.copy()
        ..title = 'New'
        ..updatedAtMs = 200;
      setBlockText(target, 'blk-1', 'Hello!');

      final delta = DocumentDelta.compute(base, target);
      expect(delta.titleChanged, isTrue);
      expect(delta.blockUpserts['sec-1'], hasLength(1)); // only blk-1
      expect(jsonOf(delta.apply(base)), jsonOf(target));
      // Base is not mutated by apply.
      expect(base.title, 'Old');
      expect(blockText(base, 'blk-1'), 'Hello');
    });

    test('blocks and sections added and removed', () {
      final base = buildDoc(blockTexts: <String>['A', 'B']);
      final target = base.copy()..updatedAtMs = 300;
      target.sections.first.blocks
        ..removeWhere((b) => b.id == 'blk-2')
        ..add(mkBlock('blk-9', 'C'));
      target.sections.add(Section(
        id: 'sec-2',
        blocks: <Block>[mkBlock('blk-10', 'Second section')],
      ));

      final delta = DocumentDelta.compute(base, target);
      expect(delta.removedBlockIds['sec-1'], <String>['blk-2']);
      expect(delta.addedSections.single.id, 'sec-2');
      expect(jsonOf(delta.apply(base)), jsonOf(target));
    });

    test('section removal and reordering', () {
      final base = buildDoc(blockTexts: <String>['A']);
      base.sections.add(Section(
          id: 'sec-2', blocks: <Block>[mkBlock('blk-7', 'Two')]));
      base.sections.add(Section(
          id: 'sec-3', blocks: <Block>[mkBlock('blk-8', 'Three')]));

      final target = base.copy()..updatedAtMs = 400;
      target.sections = <Section>[
        target.sections[2], // sec-3 first
        target.sections[0], // sec-1 second; sec-2 removed
      ];

      final delta = DocumentDelta.compute(base, target);
      expect(delta.removedSectionIds, <String>['sec-2']);
      expect(delta.sectionOrder, <String>['sec-3', 'sec-1']);
      expect(jsonOf(delta.apply(base)), jsonOf(target));
    });

    test('block reordering within a section', () {
      final base = buildDoc(blockTexts: <String>['A', 'B', 'C']);
      final target = base.copy()..updatedAtMs = 500;
      final blocks = target.sections.first.blocks;
      target.sections.first.blocks = <Block>[blocks[2], blocks[0], blocks[1]];

      final delta = DocumentDelta.compute(base, target);
      expect(delta.isContentEmpty, isFalse);
      expect(delta.blockUpserts, isEmpty); // pure reorder: no upserts
      expect(jsonOf(delta.apply(base)), jsonOf(target));
    });

    test('soft delete and sync_status ride along as metadata', () {
      final base = buildDoc();
      final target = base.copy()
        ..deletedAtMs = 999
        ..updatedAtMs = 999
        ..syncStatus = SyncStatus.pending;

      final delta = DocumentDelta.compute(base, target);
      expect(delta.isContentEmpty, isTrue); // no content change
      final applied = delta.apply(base);
      expect(applied.deletedAtMs, 999);
      expect(applied.syncStatus, SyncStatus.pending);
      expect(jsonOf(applied), jsonOf(target));
    });

    test('no-change delta is empty and applies cleanly', () {
      final base = buildDoc(blockTexts: <String>['Same']);
      final delta = DocumentDelta.compute(base, base.copy());
      expect(delta.isContentEmpty, isTrue);
      expect(delta.titleChanged, isFalse);
      expect(jsonOf(delta.apply(base)), jsonOf(base));
    });

    test('mismatched document IDs are rejected', () {
      final a = buildDoc(id: 'doc-a');
      final b = buildDoc(id: 'doc-b');
      expect(() => DocumentDelta.compute(a, b), throwsArgumentError);
      final delta = DocumentDelta.compute(a, a.copy());
      expect(() => delta.apply(b), throwsArgumentError);
    });
  });
}
