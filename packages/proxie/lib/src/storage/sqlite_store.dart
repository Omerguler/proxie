import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sqlite3/sqlite3.dart';

import '../core/presets.dart';
import '../core/rule.dart';
import '../model/body.dart';
import '../model/call.dart';
import 'call_query.dart';
import 'json_bytes.dart';
import 'spill_names.dart';
import 'sqlite_schema.dart';
import 'store.dart';

/// Response bodies up to this size are full-text indexed (the raw-text
/// editable limit, 1 MB); larger bodies are found by URL only.
const int sqliteFtsBodyLimit = 1024 * 1024;

/// A [ProxieStore] backed by an SQLite file, so history survives restarts.
///
/// Calls are synchronous `sqlite3` calls wrapped in futures; the store is
/// meant to live in the worker isolate. Bodies larger than `spillThreshold`
/// bytes are written to files in `spillDir` instead of the database.
class SqliteStore implements ProxieStore {
  SqliteStore._(this._db, this._spillDir, this._spillThreshold, this._now);

  /// Opens (creating or migrating) the database at [dbPath].
  ///
  /// [spillDir] must belong to this database alone: opening deletes spill
  /// files in it that no row of this database refers to.
  ///
  /// Throws a [StateError] when the file was written by a newer schema.
  factory SqliteStore.open(
    String dbPath, {
    required String spillDir,
    required int spillThreshold,
    DateTime Function()? now,
  }) {
    final db = sqlite3.open(dbPath);
    final SqliteStore store;
    try {
      // Wait for a lock held by another connection (e.g. a debugging tool)
      // instead of failing at once.
      db.execute('PRAGMA busy_timeout = 5000');
      db.createFunction(
        functionName: _lowerFn,
        argumentCount: const AllowedArgumentCount(1),
        deterministic: true,
        function: (args) => (args[0] as String?)?.toLowerCase(),
      );
      migrateSqliteSchema(db);
      Directory(spillDir).createSync(recursive: true);
      store = SqliteStore._(db, spillDir, spillThreshold, now ?? DateTime.now)
        .._sweepOrphans();
    } catch (_) {
      db.close();
      rethrow;
    }
    return store;
  }

  /// Deletes spill files no bodies row refers to, left behind by a crash
  /// between writing a file and committing its row.
  void _sweepOrphans() {
    final referenced = _spillFilesWhere('1', const []);
    try {
      for (final f in Directory(_spillDir).listSync()) {
        final name = f.uri.pathSegments.last;
        if (f is File &&
            spillFileNamePattern.hasMatch(name) &&
            !referenced.contains(name)) {
          _deleteSpillFiles([name]);
        }
      }
    } on FileSystemException {
      // An unreadable spill directory only means orphans stay for now.
    }
  }

  final Database _db;
  final String _spillDir;
  final int _spillThreshold;
  final DateTime Function() _now;
  bool _closed = false;

  /// Source of the per-write part of spill file names; starting from the
  /// clock keeps names from earlier runs out of the way.
  int _spillSeq = DateTime.now().microsecondsSinceEpoch;

  /// Test hook: runs inside [upsert] just before COMMIT, after spill files
  /// were written; throwing from it forces a rollback.
  @visibleForTesting
  void Function()? debugBeforeCommit;

  @override
  Future<int> startSession() async {
    _db.execute('INSERT INTO sessions(started_at) VALUES (?)', [
      _now().microsecondsSinceEpoch,
    ]);
    return _db.lastInsertRowId;
  }

  @override
  Future<void> upsert(ProxieCall c) async {
    final response = c.response;
    final resBody = response?.body;
    final meta = c.toMap();
    (meta['request']! as Map).remove('body');
    (meta['response'] as Map?)?.remove('body');

    final written = <String>{};
    var old = const <String>{};
    _db.execute('BEGIN IMMEDIATE');
    try {
      old = _spillFilesWhere('call_id = ?', [c.id]);
      _db.execute(
        '''
        INSERT INTO calls(id, session_id, method, url, host, status,
          duration_ms, req_size, res_size, kind, tags, adapter, started_at,
          started_utc, error_type, meta)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          session_id = excluded.session_id, method = excluded.method,
          url = excluded.url, host = excluded.host, status = excluded.status,
          duration_ms = excluded.duration_ms, req_size = excluded.req_size,
          res_size = excluded.res_size, kind = excluded.kind,
          tags = excluded.tags, adapter = excluded.adapter,
          started_at = excluded.started_at,
          started_utc = excluded.started_utc,
          error_type = excluded.error_type, meta = excluded.meta''',
        [
          c.id,
          c.sessionId,
          c.request.method,
          c.request.url.toString(),
          c.request.url.host,
          response?.statusCode,
          c.duration?.inMilliseconds,
          c.request.body.originalLength,
          resBody?.originalLength ?? 0,
          (resBody?.kind ?? BodyKind.empty).name,
          [for (final t in c.tags) t.name].join(','),
          c.adapter,
          c.startedAt.microsecondsSinceEpoch,
          c.startedAt.isUtc ? 1 : 0,
          c.error?.type,
          utf8.encode(jsonEncode(meta)),
        ],
      );
      final seq =
          _db
                  .select('SELECT seq FROM calls WHERE id = ?', [c.id])
                  .single
                  .columnAt(0)
              as int;
      _db.execute('DELETE FROM bodies WHERE call_id = ?', [c.id]);
      _insertBody(c.id, seq, 'req', c.request.body, written);
      if (resBody != null) _insertBody(c.id, seq, 'res', resBody, written);
      _db.execute('DELETE FROM calls_fts WHERE rowid = ?', [seq]);
      _db.execute(
        'INSERT INTO calls_fts(rowid, url, body_text) VALUES (?, ?, ?)',
        [seq, c.request.url.toString(), _searchableText(resBody)],
      );
      debugBeforeCommit?.call();
      _db.execute('COMMIT');
    } catch (_) {
      _rollback();
      // Every write goes to a fresh file name, so the old rows' files are
      // untouched and only this attempt's files need to go.
      _deleteSpillFiles(written);
      rethrow;
    }
    // Names are fresh per write, but never delete a file just written.
    _deleteSpillFiles(old.difference(written));
  }

  void _insertBody(
    String callId,
    int seq,
    String which,
    ProxieBody body,
    Set<String> written,
  ) {
    String? fileName;
    Uint8List? bytes = body.bytes;
    if (body.bytes.length > _spillThreshold) {
      String name;
      do {
        name = spillFileName(
          callId,
          seq,
          which,
          (_spillSeq++).toRadixString(36),
        );
      } while (File(_spillPath(name)).existsSync());
      // Recorded before writing, so a rollback also removes a partial file.
      written.add(name);
      _writeSpill(name, body.bytes);
      fileName = name;
      bytes = null;
    }
    _db.execute(
      '''
      INSERT INTO bodies(call_id, which, bytes, file_path, content_type, kind,
        truncated, original_length)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        callId,
        which,
        bytes,
        fileName,
        body.contentType,
        body.kind.name,
        body.truncated ? 1 : 0,
        body.originalLength,
      ],
    );
  }

  void _writeSpill(String name, Uint8List bytes) {
    final file = File(_spillPath(name));
    try {
      file.writeAsBytesSync(bytes);
    } on FileSystemException {
      // The spill directory may have been purged while running (cache
      // cleanup); recreate it and retry once.
      Directory(_spillDir).createSync(recursive: true);
      file.writeAsBytesSync(bytes);
    }
  }

  /// The response text that text search sees, or null when the body is not
  /// searched (binary/image, undecodable, or over [sqliteFtsBodyLimit]).
  static String? _searchableText(ProxieBody? body) {
    if (body == null ||
        (body.kind != BodyKind.text && body.kind != BodyKind.json) ||
        body.bytes.length > sqliteFtsBodyLimit) {
      return null;
    }
    return body.text;
  }

  (String, List<Object?>) _where(CallQuery q) {
    final clauses = <String>[];
    final params = <Object?>[];
    if (q.sessionId != null) {
      clauses.add('session_id = ?');
      params.add(q.sessionId);
    }
    if (q.adapters.isNotEmpty) {
      clauses.add('adapter IN (${_marks(q.adapters.length)})');
      params.addAll(q.adapters);
    }
    if (q.methods.isNotEmpty) {
      final methods = {for (final m in q.methods) m.toUpperCase()};
      clauses.add('upper(method) IN (${_marks(methods.length)})');
      params.addAll(methods);
    }
    switch (q.status) {
      case StatusFilter.all:
        break;
      case StatusFilter.success:
        clauses.add('status BETWEEN 200 AND 399 AND error_type IS NULL');
      case StatusFilter.errors:
        clauses.add('(error_type IS NOT NULL OR status >= 400)');
    }
    if (q.onlyJson) clauses.add("kind = 'json'");
    if (q.hideBinary) clauses.add("kind NOT IN ('binary', 'image')");
    if (q.maxSize != null) {
      clauses.add('res_size <= ?');
      params.add(q.maxSize);
    }
    final text = q.text;
    if (text != null && text.isNotEmpty) {
      if (text.runes.length >= 3) {
        // A trigram phrase query is a case-insensitive substring match.
        clauses.add(
          'seq IN (SELECT rowid FROM calls_fts WHERE calls_fts MATCH ?)',
        );
        params.add('"${text.replaceAll('"', '""')}"');
      } else {
        // Too short for trigrams: a full scan. LIKE folds ASCII case only, so
        // non-ASCII text is compared after Dart's Unicode-aware lowercasing.
        // That calls back into Dart and lowercases every indexed URL and body
        // (up to 1 MB each) per query, so it is kept to this rare case.
        final ascii = text.codeUnits.every((u) => u < 0x80);
        String col(String name) => ascii ? name : '$_lowerFn($name)';
        clauses.add(
          'seq IN (SELECT rowid FROM calls_fts WHERE '
          "${col('url')} LIKE ? ESCAPE '\\' OR "
          "${col('body_text')} LIKE ? ESCAPE '\\')",
        );
        final needle = (ascii ? text : text.toLowerCase()).replaceAllMapped(
          _likeSpecial,
          (m) => '\\${m[0]}',
        );
        final pattern = '%$needle%';
        params
          ..add(pattern)
          ..add(pattern);
      }
    }
    return (clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}', params);
  }

  @override
  Future<List<CallSummary>> query(
    CallQuery q, {
    required int offset,
    required int limit,
  }) async {
    if (limit <= 0) return const [];
    final (where, params) = _where(q);
    final rows = _db.select(
      '''
      SELECT $_summaryColumns FROM calls $where
      ORDER BY started_at DESC, id DESC
      LIMIT ? OFFSET ?''',
      [...params, limit, offset < 0 ? 0 : offset],
    );
    return List.unmodifiable([for (final r in rows) ?_decodeSummary(r)]);
  }

  static const _summaryColumns =
      'id, session_id, method, url, status, duration_ms, res_size, kind, '
      'tags, started_at, started_utc, adapter, error_type';

  /// The summary of a calls row, or null when the row no longer decodes, so
  /// one bad row is skipped instead of failing the whole page.
  static CallSummary? _decodeSummary(Row r) {
    try {
      return CallSummary(
        id: r['id'] as String,
        sessionId: r['session_id'] as int,
        method: r['method'] as String,
        url: r['url'] as String,
        statusCode: r['status'] as int?,
        durationMs: r['duration_ms'] as int?,
        responseSize: r['res_size'] as int,
        kind: BodyKind.values.byName(r['kind'] as String),
        tags: Set.unmodifiable(_decodeTags(r['tags'] as String)),
        startedAt: _startedAt(r),
        adapter: r['adapter'] as String,
        hasError: r['error_type'] != null,
      );
    } on Exception {
      return null;
    } on TypeError {
      return null; // A wrongly typed column.
    } on ArgumentError {
      return null; // An unknown enum name (e.g. from a newer version).
    }
  }

  /// The stored instant, as a UTC or local DateTime like the original.
  static DateTime _startedAt(Row r) {
    final at = DateTime.fromMicrosecondsSinceEpoch(
      r['started_at'] as int,
      isUtc: true,
    );
    return r['started_utc'] == 1 ? at : at.toLocal();
  }

  static Set<CallTag> _decodeTags(String raw) => {
    for (final name in raw.split(','))
      for (final t in CallTag.values)
        if (t.name == name) t,
  };

  /// O(N) over the matching rows (bounded by retention), since each row is
  /// decoded to skip corrupt ones exactly like [query].
  @override
  Future<int> count(CallQuery q) async {
    final (where, params) = _where(q);
    // Decodes like query() so both agree when a row is corrupt.
    var n = 0;
    for (final r in _db.select(
      'SELECT $_summaryColumns FROM calls $where',
      params,
    )) {
      if (_decodeSummary(r) != null) n++;
    }
    return n;
  }

  @override
  Future<ProxieCall?> get(String id) async {
    final rows = _db.select(
      'SELECT meta, started_at, started_utc FROM calls WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    final bodyRows = _db.select('SELECT * FROM bodies WHERE call_id = ?', [id]);
    try {
      final map =
          jsonDecode(utf8.decode(row['meta'] as Uint8List))
              as Map<String, Object?>;
      final bodies = {for (final b in bodyRows) b['which'] as String: b};
      (map['request']! as Map)['body'] = _bodyMap(bodies['req']);
      (map['response'] as Map?)?['body'] = _bodyMap(bodies['res']);
      final call = ProxieCall.fromMap(map);
      // The columns hold the exact instant and whether it was UTC.
      return call.copyWith(startedAt: _startedAt(row));
    } on Exception {
      return null; // A stored row that no longer decodes.
    } on TypeError {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  Map<String, Object?> _bodyMap(Row? row) {
    if (row == null) return ProxieBody.empty().toMap();
    var bytes = row['bytes'] as Uint8List?;
    var truncated = row['truncated'] != 0;
    final fileName = row['file_path'] as String?;
    if (fileName != null) {
      try {
        bytes = File(_spillPath(fileName)).readAsBytesSync();
      } on FileSystemException {
        // The spill file is gone (e.g. removed by the OS): keep the metadata
        // and present the body as cut off.
        bytes = null;
        truncated = true;
      }
    }
    return {
      'bytes': bytes ?? Uint8List(0),
      'contentType': row['content_type'] as String?,
      'kind': row['kind'] as String,
      'truncated': truncated,
      'originalLength': row['original_length'] as int,
    };
  }

  @override
  Future<List<SessionInfo>> sessions() async => [
    for (final r in _db.select('''
      SELECT s.id, s.started_at,
        (SELECT count(*) FROM calls c WHERE c.session_id = s.id) AS n
      FROM sessions s ORDER BY s.id DESC'''))
      SessionInfo(
        id: r['id'] as int,
        startedAt: DateTime.fromMicrosecondsSinceEpoch(
          r['started_at'] as int,
          isUtc: true,
        ),
        callCount: r['n'] as int,
      ),
  ];

  @override
  Future<List<ProxieRule>> rules() async {
    final out = <ProxieRule>[];
    for (final r in _db.select('SELECT json FROM rules ORDER BY pos, rowid')) {
      try {
        out.add(
          ProxieRule.fromMap(decodeJsonBytes(r['json'] as String) as Map),
        );
      } on Exception {
        // Skip rules that no longer decode (e.g. written by a newer version).
      } on TypeError {
        // A wrongly typed field in a stored row.
      }
    }
    return out;
  }

  @override
  Future<void> saveRules(List<ProxieRule> r) async {
    final encoded = [for (final rule in r) encodeJsonBytes(rule.toMap())];
    _transaction(() {
      _db.execute('DELETE FROM rules');
      for (var i = 0; i < encoded.length; i++) {
        _db.execute('INSERT INTO rules(pos, json) VALUES (?, ?)', [
          i,
          encoded[i],
        ]);
      }
    });
  }

  @override
  Future<List<ResponsePreset>> customPresets() async {
    final out = <ResponsePreset>[];
    for (final r in _db.select(
      'SELECT id, label, json FROM presets ORDER BY rowid',
    )) {
      try {
        final action = MapLocalAction.fromMap(
          decodeJsonBytes(r['json'] as String) as Map,
        );
        out.add(
          ResponsePreset(
            id: r['id'] as String,
            label: r['label'] as String,
            build: (_) => MapLocalAction.fromMap(action.toMap()),
          ),
        );
      } on Exception {
        // Skip presets that no longer decode.
      } on TypeError {
        // A wrongly typed field in a stored row.
      }
    }
    return out;
  }

  @override
  Future<void> saveCustomPreset(
    String id,
    String label,
    MapLocalAction a,
  ) async => _putPreset(id, label, encodeJsonBytes(a.toMap()));

  // Updating in place keeps the rowid, and with it the listing position.
  void _putPreset(String id, String? label, String? json) => _db.execute(
    '''
    INSERT INTO presets(id, label, json) VALUES (?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET label = excluded.label, json = excluded.json''',
    [id, label, json],
  );

  /// Test hook: appends [json] as a stored rule without validating it.
  @visibleForTesting
  void debugInsertRawRule(String? json) => _db.execute(
    'INSERT INTO rules(pos, json) '
    'VALUES ((SELECT coalesce(max(pos), -1) + 1 FROM rules), ?)',
    [json],
  );

  /// Test hook: stores a custom preset row without validating it.
  @visibleForTesting
  void debugInsertRawPreset(String id, String? label, String? json) =>
      _putPreset(id, label, json);

  @override
  Future<void> trim({required int maxCalls, required Duration maxAge}) async {
    final cutoff = _now().subtract(maxAge).microsecondsSinceEpoch;
    final keep = maxCalls < 0 ? 0 : maxCalls;
    const beyondKeep =
        'SELECT id FROM calls ORDER BY started_at DESC, id DESC '
        'LIMIT -1 OFFSET ?';
    final files = _transaction(() {
      final files = _spillFilesWhere(
        'call_id IN (SELECT id FROM calls WHERE started_at < ?)',
        [cutoff],
      );
      _db.execute('DELETE FROM calls WHERE started_at < ?', [cutoff]);
      files.addAll(_spillFilesWhere('call_id IN ($beyondKeep)', [keep]));
      _db.execute('DELETE FROM calls WHERE id IN ($beyondKeep)', [keep]);
      return files;
    });
    _deleteSpillFiles(files);
  }

  @override
  Future<void> clear() async {
    final files = _transaction(() {
      final files = _spillFilesWhere('1', const []);
      _db.execute('DELETE FROM calls');
      // AUTOINCREMENT keeps the highest id, so session ids are not reused.
      _db.execute('DELETE FROM sessions');
      return files;
    });
    _deleteSpillFiles(files);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

  T _transaction<T>(T Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = body();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _rollback();
      rethrow;
    }
  }

  // SQLite rolls back by itself after some errors (e.g. a full disk); a
  // second ROLLBACK would then throw and hide the original error.
  void _rollback() {
    if (!_db.autocommit) _db.execute('ROLLBACK');
  }

  Set<String> _spillFilesWhere(String where, List<Object?> params) => {
    for (final r in _db.select(
      'SELECT file_path FROM bodies WHERE file_path IS NOT NULL AND ($where)',
      params,
    ))
      r['file_path'] as String,
  };

  String _spillPath(String fileName) =>
      '$_spillDir${Platform.pathSeparator}$fileName';

  void _deleteSpillFiles(Iterable<String> names) {
    for (final name in names) {
      try {
        File(_spillPath(name)).deleteSync();
      } on FileSystemException {
        // Already gone.
      }
    }
  }
}

const _lowerFn = 'proxie_lower';

final _likeSpecial = RegExp(r'[%_\\]');

String _marks(int n) => List.filled(n, '?').join(', ');
