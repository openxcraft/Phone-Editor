import 'dart:convert';

import 'model.dart';

/// Persistence contract for documents. Implementations must be fully
/// usable offline; sync layers sit above this interface, never inside it.
abstract class DocumentStore {
  /// Inserts or replaces the document; sets the row's `updated_at` from
  /// the document metadata and clears `deleted_at` unless the document
  /// itself carries one.
  Future<void> save(Document doc);

  /// Returns the document, or null when missing or soft-deleted.
  Future<Document?> load(String id);

  /// All non-deleted documents, ordered by `updated_at` descending.
  Future<List<Document>> list();

  /// Soft delete: sets `deleted_at`. The row (and its history) survives
  /// until a later purge phase; `load`/`list` stop returning it.
  Future<void> softDelete(String id, int deletedAtMs);

  Future<void> close();
}

/// Volatile store for tests, previews, and as the reference for the
/// contract's semantics.
class InMemoryDocumentStore implements DocumentStore {
  final Map<String, String> _rows = <String, String>{};

  @override
  Future<void> save(Document doc) async {
    _rows[doc.id] = jsonEncode(doc.toJson());
  }

  @override
  Future<Document?> load(String id) async {
    final raw = _rows[id];
    if (raw == null) return null;
    final doc = Document.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    return doc.deletedAtMs == null ? doc : null;
  }

  @override
  Future<List<Document>> list() async {
    final docs = <Document>[];
    for (final raw in _rows.values) {
      final doc =
          Document.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
      if (doc.deletedAtMs == null) docs.add(doc);
    }
    docs.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return docs;
  }

  @override
  Future<void> softDelete(String id, int deletedAtMs) async {
    final raw = _rows[id];
    if (raw == null) return;
    final doc = Document.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
    doc.deletedAtMs = deletedAtMs;
    _rows[id] = jsonEncode(doc.toJson());
  }

  @override
  Future<void> close() async {}
}
