-- Schema v1 — single source of truth for local persistence.
-- The Dart SqliteDocumentStore embeds exactly these statements.
-- Every syncable row carries updated_at / deleted_at / sync_status
-- per ARCHITECTURE.md (offline-first delta sync).

CREATE TABLE IF NOT EXISTS documents (
  id          TEXT PRIMARY KEY,
  title       TEXT NOT NULL,
  body_json   TEXT NOT NULL,
  created_at  INTEGER NOT NULL,  -- epoch milliseconds, from document metadata
  updated_at  INTEGER NOT NULL,  -- epoch milliseconds, bumped on every save
  deleted_at  INTEGER,           -- epoch milliseconds, NULL = not deleted
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
