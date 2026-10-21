import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'model.dart';
import 'store.dart';

/// SQLite-backed [DocumentStore].
///
/// The DDL below is byte-identical in effect to `db/schema_v1.sql` at the
/// repo root (which is verified separately with the sqlite3 CLI). The full
/// document tree is stored as deterministic JSON in `body_json`; columns
/// carry the fields sync and listing need without parsing the body.
class SqliteDocumentStore implements DocumentStore {
  SqliteDocumentStore(String path) : _db = sqlite3.open(path) {
    _db.execute(_schema);
  }

  /// Opens an in-memory database (tests, previews).
  SqliteDocumentStore.inMemory() : _db = sqlite3.openInMemory() {
    _db.execute(_schema);
  }

  final Database _db;

  static const String _schema = '''
CREATE TABLE IF NOT EXISTS documents (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  body_json   TEXT NOT NULL,
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  deleted_at  INTEGER,
  sync_status TEXT NOT NULL DEFAULT 'local_only'
              CHECK (sync_status IN ('local_only', 'pending', 'synced'))
);
CREATE INDEX IF NOT EXISTS idx_documents_updated_at
  ON documents (updated_at);
CREATE TABLE IF NOT EXISTS schema_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('schema_version', '1');
''';

  @override
  Future<void> save(Document doc) async {
    final stmt = _db.prepare('''
INSERT INTO documents (id, title, body_json, created_at, updated_at, deleted_at, sync_status)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  title = excluded.title,
  body_json = excluded.body_json,
  updated_at = excluded.updated_at,
  deleted_at = excluded.deleted_at,
  sync_status = excluded.sync_status
''');
    try {
      stmt.execute(<Object?>[
        doc.id,
        doc.title,
        jsonEncode(doc.toJson()),
        doc.createdAtMs,
        doc.updatedAtMs,
        doc.deletedAtMs,
        doc.syncStatus.wire,
      ]);
    } finally {
      stmt.close();
    }
  }

  @override
  Future<Document?> load(String id) async {
    final stmt = _db.prepare(
        'SELECT body_json FROM documents WHERE id = ? AND deleted_at IS NULL');
    try {
      final rows = stmt.select(<Object?>[id]);
      if (rows.isEmpty) return null;
      final body = rows.first['body_json'] as String;
      return Document.fromJson(
          (jsonDecode(body) as Map).cast<String, Object?>());
    } finally {
      stmt.close();
    }
  }

  @override
  Future<List<Document>> list() async {
    final rows = _db.select(
        'SELECT body_json FROM documents WHERE deleted_at IS NULL '
        'ORDER BY updated_at DESC');
    return rows
        .map((r) => Document.fromJson(
            (jsonDecode(r['body_json'] as String) as Map)
                .cast<String, Object?>()))
        .toList();
  }

  @override
  Future<void> softDelete(String id, int deletedAtMs) async {
    final stmt = _db.prepare(
        'UPDATE documents SET deleted_at = ? WHERE id = ?');
    try {
      stmt.execute(<Object?>[deletedAtMs, id]);
    } finally {
      stmt.close();
    }
    // Keep body_json consistent with the column so a later row restore
    // cannot resurrect a stale deleted_at.
    final doc = await _loadIncludingDeleted(id);
    if (doc != null) {
      doc.deletedAtMs = deletedAtMs;
      await save(doc);
    }
  }

  Future<Document?> _loadIncludingDeleted(String id) async {
    final stmt =
        _db.prepare('SELECT body_json FROM documents WHERE id = ?');
    try {
      final rows = stmt.select(<Object?>[id]);
      if (rows.isEmpty) return null;
      return Document.fromJson(
          (jsonDecode(rows.first['body_json'] as String) as Map)
              .cast<String, Object?>());
    } finally {
      stmt.close();
    }
  }

  @override
  Future<void> close() async {
    _db.close();
  }
}
