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
  /// Throws a [StateError] when the file was written by a newer schema.
  factory SqliteStore.open(
    String dbPath, {
    required String spillDir,
    required int spillThreshold,
    DateTime Function()? now,
  }) {
    final db = sqlite3.open(dbPath);
    try {
      db.createFunction(
        functionName: _lowerFn,
        argumentCount: const AllowedArgumentCount(1),
        deterministic: true,
        function: (args) => (args[0] as String?)?.toLowerCase(),
      );
      migrateSqliteSchema(db);
      Directory(spillDir).createSync(recursive: true);
    } catch (_) {
      db.close();
      rethrow;
    }
    return SqliteStore._(db, spillDir, spillThreshold, now ?? DateTime.now);
  }

  final Database _db;
  final String _spillDir;
  final int _spillThreshold;
  final DateTime Function() _now;
  bool _closed = false;

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
          error_type, meta)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          session_id = excluded.session_id, method = excluded.method,
          url = excluded.url, host = excluded.host, status = excluded.status,
          duration_ms = excluded.duration_ms, req_size = excluded.req_size,
          res_size = excluded.res_size, kind = excluded.kind,
          tags = excluded.tags, adapter = excluded.adapter,
          started_at = excluded.started_at, error_type = excluded.error_type,
          meta = excluded.meta''',
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
          c.error?.type,
          utf8.encode(jsonEncode(meta)),
        ],
      );
      final rowId =
          _db
                  .select('SELECT rowid FROM calls WHERE id = ?', [c.id])
                  .single
                  .columnAt(0)
              as int;
      _db.execute('DELETE FROM bodies WHERE call_id = ?', [c.id]);
      _insertBody(c.id, rowId, 'req', c.request.body, written);
      if (resBody != null) _insertBody(c.id, rowId, 'res', resBody, written);
      _db.execute('DELETE FROM calls_fts WHERE rowid = ?', [rowId]);
      _db.execute(
        'INSERT INTO calls_fts(rowid, url, body_text) VALUES (?, ?, ?)',
        [rowId, c.request.url.toString(), _searchableText(resBody)],
      );
      _db.execute('COMMIT');
    } catch (_) {
      _rollback();
      // Files the rolled-back rows would have pointed to; ones the old rows
      // still use were overwritten in place and are kept.
      _deleteSpillFiles(written.difference(old));
      rethrow;
    }
    _deleteSpillFiles(old.difference(written));
  }

  void _insertBody(
    String callId,
    int rowId,
    String which,
    ProxieBody body,
    Set<String> written,
  ) {
    String? fileName;
    Uint8List? bytes = body.bytes;
    if (body.bytes.length > _spillThreshold) {
      fileName = _spillFileName(callId, rowId, which);
      File(_spillPath(fileName)).writeAsBytesSync(body.bytes);
      written.add(fileName);
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
          'rowid IN (SELECT rowid FROM calls_fts WHERE calls_fts MATCH ?)',
        );
        params.add('"${text.replaceAll('"', '""')}"');
      } else {
        // Too short for trigrams. LIKE folds ASCII case only, so non-ASCII
        // text is compared after Dart's Unicode-aware lowercasing.
        final ascii = text.codeUnits.every((u) => u < 0x80);
        String col(String name) => ascii ? name : '$_lowerFn($name)';
        clauses.add(
          'rowid IN (SELECT rowid FROM calls_fts WHERE '
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
      SELECT id, session_id, method, url, status, duration_ms, res_size, kind,
        tags, started_at, adapter, error_type
      FROM calls $where
      ORDER BY started_at DESC, id DESC
      LIMIT ? OFFSET ?''',
      [...params, limit, offset < 0 ? 0 : offset],
    );
    return List.unmodifiable([
      for (final r in rows)
        CallSummary(
          id: r['id'] as String,
          sessionId: r['session_id'] as int,
          method: r['method'] as String,
          url: r['url'] as String,
          statusCode: r['status'] as int?,
          durationMs: r['duration_ms'] as int?,
          responseSize: r['res_size'] as int,
          kind: BodyKind.values.byName(r['kind'] as String),
          tags: Set.unmodifiable(_decodeTags(r['tags'] as String)),
          startedAt: DateTime.fromMicrosecondsSinceEpoch(
            r['started_at'] as int,
            isUtc: true,
          ),
          adapter: r['adapter'] as String,
          hasError: r['error_type'] != null,
        ),
    ]);
  }

  static Set<CallTag> _decodeTags(String raw) => {
    for (final name in raw.split(','))
      for (final t in CallTag.values)
        if (t.name == name) t,
  };

  @override
  Future<int> count(CallQuery q) async {
    final (where, params) = _where(q);
    return _db
            .select('SELECT count(*) FROM calls $where', params)
            .single
            .columnAt(0)
        as int;
  }

  @override
  Future<ProxieCall?> get(String id) async {
    final rows = _db.select('SELECT meta, started_at FROM calls WHERE id = ?', [
      id,
    ]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    final map =
        jsonDecode(utf8.decode(row['meta'] as Uint8List))
            as Map<String, Object?>;
    final bodies = {
      for (final b in _db.select('SELECT * FROM bodies WHERE call_id = ?', [
        id,
      ]))
        b['which'] as String: b,
    };
    (map['request']! as Map)['body'] = _bodyMap(bodies['req']);
    (map['response'] as Map?)?['body'] = _bodyMap(bodies['res']);
    final call = ProxieCall.fromMap(map);
    // The column holds the exact instant; the ISO string in meta only tells
    // whether it was a UTC or a local DateTime.
    final at = DateTime.fromMicrosecondsSinceEpoch(
      row['started_at'] as int,
      isUtc: true,
    );
    return call.copyWith(startedAt: call.startedAt.isUtc ? at : at.toLocal());
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
        out.add(ProxieRule.fromMap(_decodeJson(r['json'] as String) as Map));
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
    final encoded = [for (final rule in r) _encodeJson(rule.toMap())];
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
          _decodeJson(r['json'] as String) as Map,
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
  ) async => _putPreset(id, label, _encodeJson(a.toMap()));

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

final _reservedName = RegExp(
  r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])$',
  caseSensitive: false,
);

/// A file name for a spilled body that is safe on every platform and
/// distinct per (call, which).
///
/// Bytes other than ASCII letters, digits and `-` become `_XX` (hex), which
/// keeps the mapping one-to-one. Overlong names fall back to `_r<rowid>`,
/// which no escaped id can produce.
String _spillFileName(String callId, int rowId, String which) {
  String esc(int byte) =>
      '_${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}';
  final bytes = utf8.encode(callId);
  final b = StringBuffer();
  for (final byte in bytes) {
    final safe =
        (byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        byte == 0x2D;
    b.write(safe ? String.fromCharCode(byte) : esc(byte));
  }
  var name = b.toString();
  if (name.isEmpty) {
    name = '_';
  } else if (_reservedName.hasMatch(name)) {
    // Windows device names (CON, NUL, ...) are reserved even with an
    // extension; escaping the first letter keeps the name decodable.
    name = '${esc(bytes.first)}${name.substring(1)}';
  }
  if (name.length > 120) name = '_r$rowId';
  return '$name.$which';
}

const _bytesKey = r'$bytes';

/// JSON with byte buffers stored as base64 instead of number arrays.
String _encodeJson(Object? value) => jsonEncode(_packBytes(value));

Object? _decodeJson(String json) => _unpackBytes(jsonDecode(json));

Object? _packBytes(Object? v) => switch (v) {
  Uint8List() => {_bytesKey: base64Encode(v)},
  Map() => {for (final e in v.entries) e.key: _packBytes(e.value)},
  List() => [for (final x in v) _packBytes(x)],
  _ => v,
};

Object? _unpackBytes(Object? v) => switch (v) {
  Map() when v.length == 1 && v[_bytesKey] is String => base64Decode(
    v[_bytesKey] as String,
  ),
  Map() => {for (final e in v.entries) e.key: _unpackBytes(e.value)},
  List() => [for (final x in v) _unpackBytes(x)],
  _ => v,
};
