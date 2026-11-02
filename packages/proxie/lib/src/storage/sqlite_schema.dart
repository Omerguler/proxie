import 'dart:developer' as developer;

import 'package:sqlite3/sqlite3.dart';

/// The schema version this build writes (`PRAGMA user_version`).
const int sqliteSchemaVersion = 1;

const _v1 = [
  '''
  CREATE TABLE sessions(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    started_at INTEGER NOT NULL
  )''',
  '''
  CREATE TABLE calls(
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL UNIQUE,
    session_id INTEGER NOT NULL,
    method TEXT NOT NULL,
    url TEXT NOT NULL,
    host TEXT NOT NULL,
    status INTEGER,
    duration_ms INTEGER,
    req_size INTEGER NOT NULL,
    res_size INTEGER NOT NULL,
    kind TEXT NOT NULL,
    tags TEXT NOT NULL,
    adapter TEXT NOT NULL,
    started_at INTEGER NOT NULL,
    started_utc INTEGER NOT NULL,
    error_type TEXT,
    meta BLOB NOT NULL
  )''',
  'CREATE INDEX calls_session_started ON calls(session_id, started_at)',
  'CREATE INDEX calls_status ON calls(status)',
  'CREATE INDEX calls_host ON calls(host)',
  'CREATE INDEX calls_kind ON calls(kind)',
  'CREATE INDEX calls_started_id ON calls(started_at, id)',
  '''
  CREATE TABLE bodies(
    call_id TEXT NOT NULL,
    which TEXT NOT NULL,
    bytes BLOB,
    file_path TEXT,
    content_type TEXT,
    kind TEXT NOT NULL,
    truncated INTEGER NOT NULL,
    original_length INTEGER NOT NULL,
    PRIMARY KEY(call_id, which)
  )''',
  'CREATE TABLE rules(pos INTEGER NOT NULL, json TEXT)',
  'CREATE TABLE presets(id TEXT PRIMARY KEY, label TEXT, json TEXT)',
  // Rowids mirror calls.seq (an INTEGER PRIMARY KEY, stable under VACUUM).
  // The trigram tokenizer makes a phrase query a case-insensitive substring
  // match.
  '''
  CREATE VIRTUAL TABLE calls_fts USING fts5(
    url, body_text, tokenize = 'trigram case_sensitive 0'
  )''',
  '''
  CREATE TRIGGER calls_after_delete AFTER DELETE ON calls BEGIN
    DELETE FROM calls_fts WHERE rowid = old.seq;
    DELETE FROM bodies WHERE call_id = old.id;
  END''',
];

/// Brings [db] to [sqliteSchemaVersion] and enables WAL mode when the
/// database supports it.
///
/// Throws a [StateError] when the file was written by a newer schema.
void migrateSqliteSchema(Database db) {
  // Checked before anything else so a newer file is left untouched.
  _checkVersion(db.userVersion);
  final mode = db.select('PRAGMA journal_mode = WAL').single.columnAt(0);
  if (mode != 'wal') {
    // E.g. an in-memory database; everything works, just without WAL.
    developer.log('journal_mode is $mode, not wal', name: 'proxie');
  }
  db.execute('PRAGMA synchronous = NORMAL');
  if (db.userVersion == sqliteSchemaVersion) return;
  db.execute('BEGIN IMMEDIATE');
  try {
    // Re-read under the write lock: another connection may have migrated
    // the file since the first check.
    final version = db.userVersion;
    _checkVersion(version);
    if (version < 1) _v1.forEach(db.execute);
    db
      ..userVersion = sqliteSchemaVersion
      ..execute('COMMIT');
  } catch (_) {
    if (!db.autocommit) db.execute('ROLLBACK');
    rethrow;
  }
}

void _checkVersion(int version) {
  if (version > sqliteSchemaVersion) {
    throw StateError(
      'Proxie database has schema version $version; this build supports up '
      'to version $sqliteSchemaVersion.',
    );
  }
}
