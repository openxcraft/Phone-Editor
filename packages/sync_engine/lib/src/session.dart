import 'dart:convert';

import 'package:doc_engine/doc_engine.dart';

import 'delta.dart';
import 'merge.dart';

/// One entry in the server's change log: a full document snapshot at a
/// monotonic [revision]. (Simplification, documented: the reference
/// server stores snapshots; [DocumentDelta] is the wire optimisation a
/// transport would send instead, and is tested separately.)
class ChangeEntry {
  ChangeEntry({
    required this.revision,
    required this.originSiteId,
    required this.document,
  });

  final int revision;
  final String originSiteId;
  final Document document;

  String get documentId => document.id;
  bool get isDelete => document.deletedAtMs != null;
}

/// In-memory reference sync server: a document table plus an append-only
/// change log with revisions starting at 1 and increasing by 1 per push.
/// Documents cross the boundary by JSON round-trip, as they would over
/// a wire, so aliasing bugs cannot hide.
class InMemorySyncServer {
  final Map<String, Document> _docs = <String, Document>{};
  final List<ChangeEntry> _log = <ChangeEntry>[];
  int _revision = 0;

  int get latestRevision => _revision;
  List<ChangeEntry> get log => List<ChangeEntry>.unmodifiable(_log);

  /// Stores [doc] (marked `synced`) and appends a change entry.
  /// Returns the assigned revision.
  int push(Document doc, {required String originSiteId}) {
    final stored = _roundTrip(doc)..syncStatus = SyncStatus.synced;
    _docs[doc.id] = stored;
    _revision++;
    _log.add(ChangeEntry(
      revision: _revision,
      originSiteId: originSiteId,
      document: stored.copy(),
    ));
    return _revision;
  }

  /// The server's current version of a document (including tombstones),
  /// or null when unknown.
  Document? document(String id) => _docs[id]?.copy();

  /// All entries with revision greater than [revision], in order.
  List<ChangeEntry> changesSince(int revision) => <ChangeEntry>[
        for (final entry in _log)
          if (entry.revision > revision)
            ChangeEntry(
              revision: entry.revision,
              originSiteId: entry.originSiteId,
              document: entry.document.copy(),
            ),
      ];

  static Document _roundTrip(Document doc) => Document.fromJson(
      (jsonDecode(jsonEncode(doc.toJson())) as Map).cast<String, Object?>());
}

/// Result of one [SyncClient.sync] run.
class SyncResult {
  SyncResult({
    required this.pushed,
    required this.pulled,
    required this.completed,
    required this.lastRevision,
    required this.conflictCopies,
  });

  /// Documents pushed (including merged results pushed back).
  final int pushed;

  /// Change entries applied from the pull phase.
  final int pulled;

  /// False when the run stopped early (cancellation or pull batch
  /// limit). The cursor is consistent either way: [lastRevision] only
  /// ever advances past fully-applied entries.
  final bool completed;
  final int lastRevision;

  /// Losing versions preserved during this run.
  final List<Document> conflictCopies;
}

/// A sync client bound to one local [InMemoryDocumentStore] and one
/// [InMemorySyncServer].
///
/// The client tracks, per document, a *shadow*: the last server version
/// it has seen. Shadows are the three-way merge base and the change
/// detector for both directions. Local state includes tombstones (the
/// store hides them from `list()`, the client mirror keeps them).
///
/// Cancellation: call [cancel] (also invoked automatically by tests via
/// [onPullEntry]); the running sync stops between documents/entries,
/// returns `completed: false`, and a later [sync] resumes from
/// [lastRevision] with no loss or duplication.
class SyncClient {
  SyncClient({
    required this.siteId,
    required this.store,
    required this.server,
    required IdGenerator conflictIds,
  }) : _conflictIds = conflictIds;

  final String siteId;
  final InMemoryDocumentStore store;
  final InMemorySyncServer server;
  final IdGenerator _conflictIds;

  /// Local mirror including tombstones, by document ID.
  final Map<String, Document> _local = <String, Document>{};

  /// Last known server version per document ID (merge base / shadow).
  final Map<String, Document> _shadow = <String, Document>{};

  /// Resumable pull cursor: the last server revision fully applied.
  int lastRevision = 0;

  bool _cancelRequested = false;
  bool get cancelRequested => _cancelRequested;
  void cancel() => _cancelRequested = true;
  void clearCancel() => _cancelRequested = false;

  /// Optional hook invoked after each pull entry is applied (used by
  /// tests to cancel mid-pull deterministically; also a progress hook).
  void Function(ChangeEntry entry)? onPullEntry;

  // --- Local editing surface ------------------------------------------------

  /// Records a local create/edit. New or changed documents are marked
  /// `pending` when they were previously `synced`.
  Future<void> upsertLocal(Document doc) async {
    final copy = doc.copy();
    if (_shadow.containsKey(copy.id) && copy.syncStatus == SyncStatus.synced) {
      copy.syncStatus = SyncStatus.pending;
    }
    _local[copy.id] = copy.copy();
    await store.save(copy);
  }

  /// Records a local soft delete at [deletedAtMs].
  Future<void> deleteLocal(String id, int deletedAtMs) async {
    final existing = _local[id];
    if (existing == null) return;
    final tombstone = existing.copy()
      ..deletedAtMs = deletedAtMs
      ..updatedAtMs = deletedAtMs
      ..syncStatus = SyncStatus.pending;
    _local[id] = tombstone.copy();
    await store.save(tombstone);
  }

  /// Local version including tombstones, or null.
  Document? localDocument(String id) => _local[id]?.copy();

  /// Alive local documents (as the app would list them).
  Future<List<Document>> localDocuments() => store.list();

  // --- Sync -------------------------------------------------------------------

  /// Push-then-pull. [maxPullEntries] bounds the pull batch (an
  /// interrupted run); omitting it pulls everything available.
  Future<SyncResult> sync({int? maxPullEntries}) async {
    var pushed = 0;
    var pulled = 0;
    final conflictCopies = <Document>[];

    // ---- Push phase ------------------------------------------------------
    final localIds = _local.keys.toList()..sort();
    for (final id in localIds) {
      if (_cancelRequested) {
        return _result(pushed, pulled, false, conflictCopies);
      }
      final local = _local[id]!;
      if (local.syncStatus == SyncStatus.synced) continue;
      final shadow = _shadow[id];
      final serverDoc = server.document(id);

      final localChanged = shadow == null ||
          documentContentJson(local) != documentContentJson(shadow);
      if (!localChanged) {
        // Flagged pending but content-identical to the server version.
        await _markSynced(local);
        continue;
      }
      final serverChanged = serverDoc != null &&
          (shadow == null ||
              documentContentJson(serverDoc) != documentContentJson(shadow));

      if (serverDoc == null || !serverChanged) {
        server.push(local, originSiteId: siteId);
        pushed++;
        await _markSynced(local);
        _shadow[id] = (await _syncedCopy(local));
      } else {
        // Both sides moved: three-way merge with the shadow as base.
        final outcome = mergeDocuments(
          local: local,
          remote: serverDoc,
          localSiteId: siteId,
          remoteSiteId: _originSiteOf(id),
          conflictIds: _conflictIds,
          base: shadow,
        );
        await _adoptMerged(outcome, conflictCopies);
        server.push(outcome.merged, originSiteId: siteId);
        pushed++;
        _shadow[id] = (await _syncedCopy(outcome.merged));
      }
    }

    // ---- Pull phase --------------------------------------------------------
    final entries = server.changesSince(lastRevision);
    for (final entry in entries) {
      if (_cancelRequested) {
        return _result(pushed, pulled, false, conflictCopies);
      }
      if (maxPullEntries != null && pulled >= maxPullEntries) {
        return _result(pushed, pulled, false, conflictCopies);
      }
      await _applyRemote(entry, conflictCopies);
      lastRevision = entry.revision;
      pulled++;
      onPullEntry?.call(entry);
    }

    return _result(pushed, pulled, true, conflictCopies);
  }

  SyncResult _result(
          int pushed, int pulled, bool completed, List<Document> copies) =>
      SyncResult(
        pushed: pushed,
        pulled: pulled,
        completed: completed,
        lastRevision: lastRevision,
        conflictCopies: copies,
      );

  String _originSiteOf(String documentId) {
    // The site that produced the server's current version: the origin of
    // the latest log entry for this document, defaulting to 'server'.
    for (var i = server.log.length - 1; i >= 0; i--) {
      if (server.log[i].documentId == documentId) {
        return server.log[i].originSiteId;
      }
    }
    return 'server';
  }

  Future<Document> _syncedCopy(Document doc) async =>
      doc.copy()..syncStatus = SyncStatus.synced;

  Future<void> _markSynced(Document local) async {
    final synced = await _syncedCopy(local);
    _local[local.id] = synced.copy();
    await store.save(synced);
  }

  /// Saves a merge outcome locally and records any conflict copy as a
  /// new pending local document (it pushes on a later sync, or — when
  /// adopted during the push phase — the caller may push it next run).
  Future<void> _adoptMerged(
      MergeOutcome outcome, List<Document> conflictCopies) async {
    final mergedSynced = await _syncedCopy(outcome.merged);
    _local[outcome.merged.id] = mergedSynced.copy();
    await store.save(mergedSynced);
    final copy = outcome.conflictCopy;
    if (copy != null) {
      conflictCopies.add(copy.copy());
      _local[copy.id] = copy.copy();
      await store.save(copy);
    }
  }

  Future<void> _applyRemote(
      ChangeEntry entry, List<Document> conflictCopies) async {
    final remote = entry.document;
    final local = _local[remote.id];
    final shadow = _shadow[remote.id];

    if (local == null) {
      final synced = await _syncedCopy(remote);
      _local[remote.id] = synced.copy();
      await store.save(synced);
      _shadow[remote.id] = remote.copy();
      return;
    }

    if (documentContentJson(local) == documentContentJson(remote)) {
      // Echo of our own push, or convergence: just mark synced.
      if (local.deletedAtMs == null || remote.deletedAtMs != null) {
        await _markSynced(local);
      }
      _shadow[remote.id] = remote.copy();
      return;
    }

    final localChangedVsShadow = shadow == null ||
        documentContentJson(local) != documentContentJson(shadow);
    if (!localChangedVsShadow) {
      // Fast-forward: we have no divergent local work.
      final synced = await _syncedCopy(remote);
      _local[remote.id] = synced.copy();
      await store.save(synced);
      _shadow[remote.id] = remote.copy();
      return;
    }

    // Divergent local work the push phase did not see (defensive path:
    // reachable when local state changed between phases in embedding
    // apps). Merge, adopt, and push the result back so the server
    // converges; the push is logged and will echo next run.
    final outcome = mergeDocuments(
      local: local,
      remote: remote,
      localSiteId: siteId,
      remoteSiteId: entry.originSiteId,
      conflictIds: _conflictIds,
      base: shadow,
    );
    await _adoptMerged(outcome, conflictCopies);
    server.push(outcome.merged, originSiteId: siteId);
    _shadow[remote.id] = await _syncedCopy(outcome.merged);
  }
}
