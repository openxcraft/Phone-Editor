import 'dart:convert';

import 'package:doc_engine/doc_engine.dart';

import 'delta.dart';

/// Outcome of [mergeDocuments].
class MergeOutcome {
  MergeOutcome({
    required this.merged,
    required this.conflictCopy,
    required this.conflictedBlockIds,
    required this.titleConflicted,
    required this.deleteEditConflict,
    required this.winnerSiteId,
  });

  /// The merged document (same ID as the inputs).
  final Document merged;

  /// The losing side's whole version, preserved under a new ID with the
  /// title suffix ` (conflict)`. Non-null exactly when a real conflict
  /// occurred. This is the zero-data-loss guarantee: a conflict never
  /// destroys the losing version.
  final Document? conflictCopy;

  /// Block IDs whose content conflicted (both sides changed them
  /// differently), in merged document order.
  final List<String> conflictedBlockIds;

  final bool titleConflicted;
  final bool deleteEditConflict;

  /// Site that won conflict resolution (see [mergeDocuments]).
  final String winnerSiteId;

  bool get hasConflict =>
      conflictCopy != null || titleConflicted || deleteEditConflict;
}

/// Field-level merge of two divergent versions of one document.
///
/// [local] and [remote] are two versions of the same document ID.
/// [base], when supplied, is their common ancestor and enables true
/// three-way semantics: a field/block changed on only one side takes
/// that side's value with no conflict. Without [base], any difference
/// in the same field/block is a conflict (union semantics for
/// additions: content present on only one side is kept).
///
/// Conflict resolution is deterministic: the winner is the side with
/// the higher `updatedAtMs`; ties break to the higher site ID
/// ([localSiteId] vs [remoteSiteId], lexicographic). The winner's value
/// lands in [MergeOutcome.merged]; the loser's whole version is
/// preserved as [MergeOutcome.conflictCopy] (new ID from
/// [conflictIds], title + ` (conflict)`, never deleted, status
/// `pending` so it syncs too).
///
/// Delete-vs-edit: if exactly one side is soft-deleted, and the other
/// side carries edits the deleting side does not have, that is a
/// conflict. If the deleting side wins, the merged document is deleted
/// and the edited version becomes the conflict copy. If the editing
/// side wins, the merged document stays alive and the deleting side's
/// version becomes the conflict copy. A delete of an unchanged document
/// (per [base]) is not a conflict and simply applies.
///
/// Merged metadata: `createdAtMs` = min of both, `updatedAtMs` = max of
/// both, `syncStatus` = `pending` when the inputs diverged, otherwise
/// the shared status.
MergeOutcome mergeDocuments({
  required Document local,
  required Document remote,
  required String localSiteId,
  required String remoteSiteId,
  required IdGenerator conflictIds,
  Document? base,
}) {
  if (local.id != remote.id) {
    throw ArgumentError('Can only merge versions of one document: '
        '${local.id} vs ${remote.id}');
  }
  if (base != null && base.id != local.id) {
    throw ArgumentError('Base must be a version of ${local.id}');
  }

  // Deterministic winner: higher updatedAtMs, then higher site ID.
  final localWins = local.updatedAtMs > remote.updatedAtMs ||
      (local.updatedAtMs == remote.updatedAtMs &&
          localSiteId.compareTo(remoteSiteId) > 0);
  final winner = localWins ? local : remote;
  final loser = localWins ? remote : local;
  final winnerSiteId = localWins ? localSiteId : remoteSiteId;
  final winnerIsLocal = localWins;

  bool changedVsBase(Document side, String? Function(Document) pick) {
    if (base == null) return true; // no ancestor: any difference conflicts
    return pick(side) != pick(base);
  }

  // --- Title ---------------------------------------------------------------
  var titleConflicted = false;
  String mergedTitle;
  if (local.title == remote.title) {
    mergedTitle = local.title;
  } else if (base != null &&
      (!changedVsBase(local, (d) => d.title) ||
          !changedVsBase(remote, (d) => d.title))) {
    mergedTitle =
        changedVsBase(local, (d) => d.title) ? local.title : remote.title;
  } else {
    titleConflicted = true;
    mergedTitle = winner.title;
  }

  // --- Delete vs edit ---------------------------------------------------------
  final localDeleted = local.deletedAtMs != null;
  final remoteDeleted = remote.deletedAtMs != null;
  var deleteEditConflict = false;
  bool mergedDeleted;
  int? mergedDeletedAtMs;

  bool sideHasUniqueContent(Document side, Document other) {
    // Content this side has that the other lacks (ignoring sync status
    // and the deletion fields themselves).
    if (base != null) {
      return documentContentJson(side) != documentContentJson(base);
    }
    return documentContentJson(side) != documentContentJson(other);
  }

  if (localDeleted && remoteDeleted) {
    mergedDeleted = true;
    mergedDeletedAtMs =
        local.deletedAtMs! > remote.deletedAtMs! ? local.deletedAtMs : remote.deletedAtMs;
  } else if (localDeleted != remoteDeleted) {
    final deletedSide = localDeleted ? local : remote;
    final aliveSide = localDeleted ? remote : local;
    final aliveEdited = sideHasUniqueContent(aliveSide, deletedSide);
    if (!aliveEdited) {
      // Plain delete of an unchanged document: applies cleanly.
      mergedDeleted = true;
      mergedDeletedAtMs = deletedSide.deletedAtMs;
    } else {
      deleteEditConflict = true;
      final winnerDeleted = winner.deletedAtMs != null;
      mergedDeleted = winnerDeleted;
      mergedDeletedAtMs = winnerDeleted ? winner.deletedAtMs : null;
    }
  } else {
    mergedDeleted = false;
    mergedDeletedAtMs = null;
  }

  // --- Sections and blocks ----------------------------------------------------
  final conflictedBlockIds = <String>[];

  List<Section> mergeSections() {
    if (mergedDeleted && deleteEditConflict) {
      // The merged document is deleted; its body mirrors the winner so
      // the tombstone carries the winning version. The losing content
      // survives in the conflict copy.
      return winner.sections.map((s) => s.copy()).toList();
    }

    final baseSections = <String, Section>{
      if (base != null) for (final s in base.sections) s.id: s,
    };
    final localSections = <String, Section>{
      for (final s in local.sections) s.id: s,
    };
    final remoteSections = <String, Section>{
      for (final s in remote.sections) s.id: s,
    };

    Section? mergeOneSection(String sectionId) {
      final inLocal = localSections[sectionId];
      final inRemote = remoteSections[sectionId];
      final inBase = baseSections[sectionId];
      if (inLocal != null && inRemote != null) {
        return Section(
          id: sectionId,
          blocks: _mergeBlocks(
            sectionId,
            inLocal.blocks,
            inRemote.blocks,
            baseBlocks: inBase?.blocks,
            winnerIsLocal: winnerIsLocal,
            conflictedBlockIds: conflictedBlockIds,
          ),
        );
      }
      final only = inLocal ?? inRemote;
      if (only == null) return null;
      if (inBase == null) {
        return only.copy(); // added on one side: kept (union semantics)
      }
      // In base but missing on one side: deleted there.
      if (jsonEncode(only.toJson()) == jsonEncode(inBase.toJson())) {
        return null; // other side unchanged: deletion applies
      }
      // Deleted on one side, changed on the other: conflict.
      conflictedBlockIds.addAll(only.blocks.map((b) => b.id));
      final onlyIsWinnerSide =
          (inLocal != null) == winnerIsLocal;
      return onlyIsWinnerSide ? only.copy() : null;
    }

    final allIds = <String>{
      ...localSections.keys,
      ...remoteSections.keys,
    };
    final mergedById = <String, Section>{};
    for (final id in allIds) {
      final merged = mergeOneSection(id);
      if (merged != null) mergedById[id] = merged;
    }

    // Order: pick the side whose section order changed vs base (or the
    // winner when both/neither did), then append any survivors it does
    // not name, in local-then-remote order.
    List<String> orderOf(Document d) => d.sections.map((s) => s.id).toList();
    List<String> chosenOrder;
    if (base != null) {
      final baseOrder = orderOf(base);
      final localChanged = !_sameList(orderOf(local), baseOrder);
      final remoteChanged = !_sameList(orderOf(remote), baseOrder);
      if (localChanged && !remoteChanged) {
        chosenOrder = orderOf(local);
      } else if (remoteChanged && !localChanged) {
        chosenOrder = orderOf(remote);
      } else {
        chosenOrder = orderOf(winner);
      }
    } else {
      chosenOrder = orderOf(winner);
    }
    final ordered = <Section>[
      for (final id in chosenOrder)
        if (mergedById.containsKey(id)) mergedById[id]!,
    ];
    final named = chosenOrder.toSet();
    for (final source in <Document>[local, remote]) {
      for (final s in source.sections) {
        if (!named.contains(s.id) && mergedById.containsKey(s.id)) {
          ordered.add(mergedById[s.id]!);
          named.add(s.id);
        }
      }
    }
    return ordered;
  }

  final merged = Document(
    id: local.id,
    title: mergedTitle,
    createdAtMs:
        local.createdAtMs < remote.createdAtMs ? local.createdAtMs : remote.createdAtMs,
    updatedAtMs:
        local.updatedAtMs > remote.updatedAtMs ? local.updatedAtMs : remote.updatedAtMs,
    deletedAtMs: mergedDeleted ? mergedDeletedAtMs : null,
    syncStatus: documentContentJson(local) == documentContentJson(remote)
        ? local.syncStatus
        : SyncStatus.pending,
    sections: mergeSections(),
  );

  // --- Conflict copy ----------------------------------------------------------
  final anyConflict =
      titleConflicted || deleteEditConflict || conflictedBlockIds.isNotEmpty;
  Document? conflictCopy;
  if (anyConflict) {
    conflictCopy = Document(
      id: conflictIds.next('doc'),
      title: '${loser.title} (conflict)',
      createdAtMs: loser.createdAtMs,
      updatedAtMs: loser.updatedAtMs,
      deletedAtMs: null, // preserved copies are always recoverable/alive
      syncStatus: SyncStatus.pending,
      sections: loser.sections.map((s) => s.copy()).toList(),
    );
  }

  // Report conflicted blocks in merged document order.
  final orderedConflicts = <String>[
    for (final block in merged.allBlocks)
      if (conflictedBlockIds.contains(block.id)) block.id,
    // Blocks lost to a winning deletion still get reported.
    for (final id in conflictedBlockIds)
      if (!merged.allBlocks.any((b) => b.id == id)) id,
  ];

  return MergeOutcome(
    merged: merged,
    conflictCopy: conflictCopy,
    conflictedBlockIds: orderedConflicts,
    titleConflicted: titleConflicted,
    deleteEditConflict: deleteEditConflict,
    winnerSiteId: winnerSiteId,
  );
}

List<Block> _mergeBlocks(
  String sectionId,
  List<Block> localBlocks,
  List<Block> remoteBlocks, {
  List<Block>? baseBlocks,
  required bool winnerIsLocal,
  required List<String> conflictedBlockIds,
}) {
  String json(Block b) => documentJsonBlock(b);

  final baseById = <String, Block>{
    if (baseBlocks != null) for (final b in baseBlocks) b.id: b,
  };
  final localById = <String, Block>{for (final b in localBlocks) b.id: b};
  final remoteById = <String, Block>{for (final b in remoteBlocks) b.id: b};

  final survivors = <String, Block>{};
  final allIds = <String>{...localById.keys, ...remoteById.keys};
  for (final id in allIds) {
    final inLocal = localById[id];
    final inRemote = remoteById[id];
    final inBase = baseById[id];
    if (inLocal != null && inRemote != null) {
      if (json(inLocal) == json(inRemote)) {
        survivors[id] = inLocal.copy();
      } else if (inBase != null && json(inLocal) == json(inBase)) {
        survivors[id] = inRemote.copy(); // only remote changed it
      } else if (inBase != null && json(inRemote) == json(inBase)) {
        survivors[id] = inLocal.copy(); // only local changed it
      } else {
        conflictedBlockIds.add(id);
        survivors[id] = (winnerIsLocal ? inLocal : inRemote).copy();
      }
    } else {
      final only = inLocal ?? inRemote!;
      if (inBase == null) {
        survivors[id] = only.copy(); // added on one side
      } else if (json(only) == json(inBase)) {
        // Deleted on the other side, unchanged here: deletion applies.
      } else {
        // Deleted on one side, edited on the other.
        conflictedBlockIds.add(id);
        final onlyIsWinnerSide = (inLocal != null) == winnerIsLocal;
        if (onlyIsWinnerSide) survivors[id] = only.copy();
      }
    }
  }

  // Order: same rule as sections (side that reordered vs base, else
  // winner), survivors appended in local-then-remote order.
  List<String> orderOf(List<Block> blocks) => blocks.map((b) => b.id).toList();
  List<String> chosen;
  if (baseBlocks != null) {
    final baseOrder = orderOf(baseBlocks);
    final localChanged = !_sameList(orderOf(localBlocks), baseOrder);
    final remoteChanged = !_sameList(orderOf(remoteBlocks), baseOrder);
    if (localChanged && !remoteChanged) {
      chosen = orderOf(localBlocks);
    } else if (remoteChanged && !localChanged) {
      chosen = orderOf(remoteBlocks);
    } else {
      chosen = orderOf(winnerIsLocal ? localBlocks : remoteBlocks);
    }
  } else {
    chosen = orderOf(winnerIsLocal ? localBlocks : remoteBlocks);
  }
  final ordered = <Block>[
    for (final id in chosen)
      if (survivors.containsKey(id)) survivors[id]!,
  ];
  final named = chosen.toSet();
  for (final source in <List<Block>>[localBlocks, remoteBlocks]) {
    for (final b in source) {
      if (!named.contains(b.id) && survivors.containsKey(b.id)) {
        ordered.add(survivors[b.id]!);
        named.add(b.id);
      }
    }
  }
  return ordered;
}

/// Canonical JSON for one block, via the model's own `toJson`.
String documentJsonBlock(Block block) => jsonEncode(block.toJson());

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
