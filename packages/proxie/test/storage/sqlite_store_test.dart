import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';
import 'package:proxie/src/storage/sqlite_store.dart';
import 'package:sqlite3/sqlite3.dart';

import '../support/temp_dir.dart';
import 'store_contract.dart';

const int _threshold = 256 * 1024;
final _t0 = DateTime.utc(2026, 1, 1, 12);

final _dirs = <Directory>[];

Directory _tempDir() {
  final d = Directory.systemTemp.createTempSync('proxie_sqlite_');
  _dirs.add(d);
  return d;
}

String _dbPath(Directory d) => '${d.path}${Platform.pathSeparator}proxie.db';

String _spillDir(Directory d) => '${d.path}${Platform.pathSeparator}spill';

SqliteStore _open(Directory d, {DateTime Function()? now}) => SqliteStore.open(
  _dbPath(d),
  spillDir: _spillDir(d),
  spillThreshold: _threshold,
  now: now,
);

/// Full names of the files in the spill directory, sorted.
List<String> _spillNames(Directory d) {
  final spill = Directory(_spillDir(d));
  if (!spill.existsSync()) return const [];
  return [for (final f in spill.listSync()) f.uri.pathSegments.last]..sort();
}

/// Spill file names without their per-write unique suffix
/// (`<escaped id>.<which>`), sorted.
List<String> _spillFiles(Directory d) =>
    [for (final n in _spillNames(d)) n.substring(0, n.lastIndexOf('.'))]
      ..sort();

/// The spill file whose name without the unique suffix is [base].
File _spillFile(Directory d, String base) => File(
  '${_spillDir(d)}${Platform.pathSeparator}'
  '${_spillNames(d).singleWhere((n) => n.startsWith('$base.'))}',
);

Uint8List _pattern(int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) (i * 31 + 7) & 0xFF]);

ProxieBody _text(String s, String type) =>
    ProxieBody.from(Uint8List.fromList(utf8.encode(s)), type);

ProxieCall _call(
  String id, {
  ProxieBody? requestBody,
  ProxieBody? responseBody,
  bool respond = true,
  String? url,
  DateTime? startedAt,
  int session = 1,
  String method = 'POST',
}) => ProxieCall(
  id: id,
  sessionId: session,
  adapter: 'dio',
  request: ProxieRequest(
    method: method,
    url: Uri.parse(url ?? 'https://api.test/$id'),
    headers: {
      'X-A': ['1', '2'],
    },
    body: requestBody ?? ProxieBody.empty(),
  ),
  response: respond
      ? ProxieResponse(
          statusCode: 200,
          reasonPhrase: 'OK',
          headers: {
            'content-type': ['application/json'],
          },
          body: responseBody ?? _text('{"ok":true}', 'application/json'),
        )
      : null,
  startedAt: startedAt ?? _t0,
  duration: const Duration(milliseconds: 12),
  tags: {CallTag.edited},
);

Future<List<String>> _ids(ProxieStore s, CallQuery q) async => [
  for (final c in await s.query(q, offset: 0, limit: 100)) c.id,
];

void main() {
  tearDown(() async {
    for (final d in _dirs) {
      await deleteTempDir(d);
    }
    _dirs.clear();
  });

  runStoreContract(({now}) async => _open(_tempDir(), now: now));

  group('SqliteStore bodies', () {
    late Directory dir;
    late SqliteStore store;

    setUp(() {
      dir = _tempDir();
      store = _open(dir);
    });
    tearDown(() => store.close());

    test('a 300 KB body is spilled to a file and read back intact', () async {
      final res = _pattern(300 * 1024);
      final req = _pattern(300 * 1024 + 1).reversed.toList();
      final c = _call(
        'big',
        requestBody: ProxieBody.from(
          Uint8List.fromList(req),
          'application/octet-stream',
        ),
        responseBody: ProxieBody.from(res, 'application/octet-stream'),
      );
      await store.upsert(c);
      expect(_spillFiles(dir), ['big.req', 'big.res']);
      expect(_spillFile(dir, 'big.res').readAsBytesSync(), orderedEquals(res));
      final got = (await store.get('big'))!;
      expect(got.response!.body.bytes, orderedEquals(res));
      expect(got.request.body.bytes, orderedEquals(req));
      expect(got.toMap(), c.toMap());
    });

    test('bodies up to the threshold stay in the database', () async {
      await store.upsert(
        _call(
          'edge',
          responseBody: ProxieBody.from(
            _pattern(_threshold),
            'application/octet-stream',
          ),
        ),
      );
      expect(_spillFiles(dir), isEmpty);
      expect(
        (await store.get('edge'))!.response!.body.bytes,
        orderedEquals(_pattern(_threshold)),
      );
      await store.upsert(
        _call(
          'over',
          responseBody: ProxieBody.from(
            _pattern(_threshold + 1),
            'application/octet-stream',
          ),
        ),
      );
      expect(_spillFiles(dir), ['over.res']);
    });

    test('call ids are made safe and distinct as file names', () async {
      final body = ProxieBody.from(_pattern(_threshold + 1), null);
      const ids = ['a/b', 'a_b', 'con', 'CON', r'..\x', 'ü', 'Ab', 'ab', ''];
      for (final id in ids) {
        await store.upsert(_call(id, responseBody: body));
      }
      final files = _spillNames(dir);
      expect(files, hasLength(ids.length));
      // Distinct even on case-insensitive file systems.
      expect({for (final f in files) f.toLowerCase()}, hasLength(ids.length));
      for (final f in files) {
        expect(f, matches(RegExp(r'^[a-z0-9_-]+\.res\.[a-z0-9]+$')));
        expect(
          f.split('.').first,
          isNot(matches(RegExp(r'^(con|nul|prn|aux)$', caseSensitive: false))),
        );
      }
      for (final id in ids) {
        expect(
          (await store.get(id))!.response!.body.bytes,
          orderedEquals(body.bytes),
        );
      }
    });

    test('replacing a spilled body removes the stale file', () async {
      final big = ProxieBody.from(_pattern(_threshold + 10), null);
      await store.upsert(_call('a', requestBody: big, responseBody: big));
      expect(_spillFiles(dir), ['a.req', 'a.res']);

      // Still spilled: the new content goes to a new file and the old one is
      // removed after commit.
      final before = _spillNames(dir);
      final big2 = ProxieBody.from(
        Uint8List.fromList(_pattern(_threshold + 20).reversed.toList()),
        null,
      );
      await store.upsert(_call('a', requestBody: big, responseBody: big2));
      expect(_spillFiles(dir), ['a.req', 'a.res']);
      expect(
        _spillNames(dir).where((n) => n.startsWith('a.res.')),
        isNot(anyElement(isIn(before))),
      );
      expect(
        (await store.get('a'))!.response!.body.bytes,
        orderedEquals(big2.bytes),
      );

      // Small response body: the file goes away.
      await store.upsert(_call('a', requestBody: big));
      expect(_spillFiles(dir), ['a.req']);
      expect((await store.get('a'))!.response!.body.text, '{"ok":true}');

      // No response at all, small request.
      await store.upsert(_call('a', respond: false));
      expect(_spillFiles(dir), isEmpty);
      expect((await store.get('a'))!.response, isNull);
    });

    test('trim and clear delete spill files', () async {
      final big = ProxieBody.from(_pattern(_threshold + 1), null);
      final now = DateTime.utc(2026, 6);
      unawaited(store.close());
      store = _open(dir, now: () => now);
      for (var i = 0; i < 3; i++) {
        await store.upsert(
          _call(
            'c$i',
            responseBody: big,
            startedAt: now.add(Duration(seconds: i)),
          ),
        );
      }
      await store.upsert(
        _call(
          'old',
          responseBody: big,
          startedAt: now.subtract(const Duration(days: 30)),
        ),
      );
      expect(_spillFiles(dir), ['c0.res', 'c1.res', 'c2.res', 'old.res']);
      await store.trim(maxCalls: 2, maxAge: const Duration(days: 7));
      expect(_spillFiles(dir), ['c1.res', 'c2.res']);
      expect(await _ids(store, const CallQuery()), ['c2', 'c1']);
      await store.clear();
      expect(_spillFiles(dir), isEmpty);
    });

    test(
      'a missing spill file reads back as an empty truncated body',
      () async {
        final big = ProxieBody.from(_pattern(_threshold + 1), null);
        await store.upsert(_call('a', responseBody: big));
        _spillFile(dir, 'a.res').deleteSync();
        final body = (await store.get('a'))!.response!.body;
        expect(body.bytes, isEmpty);
        expect(body.truncated, isTrue);
        expect(body.originalLength, _threshold + 1);
      },
    );
  });

  group('SqliteStore text search', () {
    late SqliteStore store;

    setUp(() => store = _open(_tempDir()));
    tearDown(() => store.close());

    test('finds a token inside a JSON body', () async {
      await store.upsert(
        _call(
          'hit',
          responseBody: _text(
            '{"items":[{"name":"haystack-needle-haystack"}]}',
            'application/json',
          ),
        ),
      );
      await store.upsert(
        _call('miss', responseBody: _text('{"a":1}', 'application/json')),
      );
      expect(await _ids(store, const CallQuery(text: 'needle')), ['hit']);
      expect(await _ids(store, const CallQuery(text: 'NEEDLE')), ['hit']);
      expect(await store.count(const CallQuery(text: 'needle')), 1);
    });

    test('short queries match URL and body substrings', () async {
      await store.upsert(
        _call(
          'body',
          url: 'https://x.test/1',
          responseBody: _text('{"k":"Qz"}', 'application/json'),
        ),
      );
      await store.upsert(_call('url', url: 'https://x.test/qZ'));
      await store.upsert(_call('none', url: 'https://x.test/2'));
      expect((await _ids(store, const CallQuery(text: 'qz'))).toSet(), {
        'body',
        'url',
      });
      expect(await _ids(store, const CallQuery(text: 'q')), hasLength(2));
    });

    test('query syntax characters are matched literally', () async {
      await store.upsert(
        _call(
          'q',
          responseBody: _text('say "hi" -x OR y* NEAR(z)', 'text/plain'),
        ),
      );
      await store.upsert(_call('other'));
      for (final text in [
        '"hi"',
        'y "',
        'i" ',
        '-x OR',
        'y*',
        'NEAR(z)',
        'r(z',
      ]) {
        expect(await _ids(store, CallQuery(text: text)), ['q'], reason: text);
      }
      expect(
        await _ids(store, const CallQuery(text: '"hi" OR other')),
        isEmpty,
      );
    });

    test('non-ASCII queries fold case; length counts characters', () async {
      await store.upsert(
        _call('u', responseBody: _text('{"e":"aÜßb"}', 'application/json')),
      );
      expect(await _ids(store, const CallQuery(text: 'üß')), ['u']);
      expect(await _ids(store, const CallQuery(text: 'aüß')), ['u']);
    });

    test('request bodies are not searched', () async {
      await store.upsert(
        _call('r', requestBody: _text('{"secretword":1}', 'application/json')),
      );
      expect(await _ids(store, const CallQuery(text: 'secretword')), isEmpty);
    });

    test('bodies over 1 MB are not indexed', () async {
      final big = '{"k":"${'x' * (1024 * 1024)}needle"}';
      await store.upsert(
        _call('big', responseBody: _text(big, 'application/json')),
      );
      final ok = '{"k":"${'x' * (1024 * 1024 - 20)}needle"}';
      await store.upsert(
        _call('ok', responseBody: _text(ok, 'application/json')),
      );
      expect(await _ids(store, const CallQuery(text: 'needle')), ['ok']);
    });

    test('a replaced call is searched by its new content only', () async {
      await store.upsert(
        _call('a', responseBody: _text('alpha-token', 'text/plain')),
      );
      await store.upsert(
        _call('a', responseBody: _text('beta-token', 'text/plain')),
      );
      expect(await _ids(store, const CallQuery(text: 'alpha')), isEmpty);
      expect(await _ids(store, const CallQuery(text: 'beta')), ['a']);
      await store.trim(maxCalls: 0, maxAge: const Duration(days: 9999));
      expect(await _ids(store, const CallQuery(text: 'beta')), isEmpty);
    });
  });

  group('SqliteStore persistence', () {
    test('reopening keeps calls, rules, presets and sessions', () async {
      final dir = _tempDir();
      final now = DateTime.utc(2026, 3, 4, 5);
      var store = _open(dir, now: () => now);
      final s1 = await store.startSession();
      final big = ProxieBody.from(_pattern(300 * 1024), null);
      final calls = [
        _call('small', session: s1),
        _call(
          'spilled',
          session: s1,
          responseBody: big,
          startedAt: _t0.add(const Duration(seconds: 1)),
        ),
        _call(
          'local',
          session: s1,
          respond: false,
          startedAt: DateTime.fromMicrosecondsSinceEpoch(
            _t0.microsecondsSinceEpoch + 2000123,
          ),
        ),
      ];
      for (final c in calls) {
        await store.upsert(c);
      }
      final rule = ProxieRule(
        id: 'r1',
        name: 'Rule',
        kind: RuleKind.mapLocal,
        matcher: UrlMatcher('*/users*'),
        mapLocal: MapLocalAction(
          response: ProxieResponse(
            statusCode: 418,
            headers: const {},
            body: ProxieBody.from(_pattern(64), null),
          ),
        ),
      );
      await store.saveRules([rule]);
      await store.saveCustomPreset(
        'p',
        'Preset',
        const MapLocalAction(failure: SimulatedFailure.timeout),
      );
      await store.close();

      store = _open(dir);
      addTearDown(store.close);
      expect(await _ids(store, const CallQuery()), [
        'local',
        'spilled',
        'small',
      ]);
      for (final c in calls) {
        final got = (await store.get(c.id))!;
        expect(got.toMap(), c.toMap(), reason: c.id);
        expect(got.startedAt.isUtc, c.startedAt.isUtc);
        expect(got.startedAt, c.startedAt);
      }
      expect((await store.rules()).single.toMap(), rule.toMap());
      expect((await store.customPresets()).single.id, 'p');
      final sessions = await store.sessions();
      expect(sessions.single.id, s1);
      expect(sessions.single.startedAt, now);
      expect(sessions.single.callCount, 3);
      expect(await store.startSession(), s1 + 1);
      // The search index survives too (the spilled body is binary).
      expect(await _ids(store, const CallQuery(text: '"ok"')), ['small']);
    });

    test('session ids are not reused after clear and reopen', () async {
      final dir = _tempDir();
      var store = _open(dir);
      await store.startSession();
      await store.startSession();
      await store.clear();
      await store.close();
      store = _open(dir);
      addTearDown(store.close);
      expect(await store.startSession(), 3);
    });

    test('uses WAL mode and schema version 1', () async {
      final dir = _tempDir();
      final store = _open(dir);
      await store.close();
      final db = sqlite3.open(_dbPath(dir));
      addTearDown(db.close);
      expect(db.userVersion, 1);
      expect(db.select('PRAGMA journal_mode').single.values.single, 'wal');
    });

    test('a database from a newer version is refused', () async {
      final dir = _tempDir();
      sqlite3.open(_dbPath(dir))
        ..userVersion = 2
        ..close();
      expect(
        () => _open(dir),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('version 2'),
          ),
        ),
      );
      // The refused file is left untouched and not held open.
      final again = sqlite3.open(_dbPath(dir));
      expect(again.userVersion, 2);
      again.close();
    });
  });

  group('SqliteStore spill robustness', () {
    late Directory dir;
    late SqliteStore store;

    setUp(() {
      dir = _tempDir();
      store = _open(dir);
    });
    tearDown(() => store.close());

    ProxieBody big(int seed) => ProxieBody.from(
      Uint8List.fromList([
        for (var i = 0; i < _threshold + 1; i++) (i * seed + 3) & 0xFF,
      ]),
      null,
    );

    test('a failed upsert keeps the old body and leaves no file', () async {
      final old = big(5);
      await store.upsert(_call('a', responseBody: old));
      final before = _spillNames(dir);
      store.debugBeforeCommit = () => throw StateError('boom');
      await expectLater(
        store.upsert(_call('a', requestBody: big(7), responseBody: big(9))),
        throwsStateError,
      );
      await expectLater(
        store.upsert(_call('new', responseBody: big(11))),
        throwsStateError,
      );
      store.debugBeforeCommit = null;
      expect(_spillNames(dir), before);
      expect(
        (await store.get('a'))!.response!.body.bytes,
        orderedEquals(old.bytes),
      );
      expect(await store.get('new'), isNull);
      expect(await store.count(const CallQuery()), 1);
      // The store still works after the rollback.
      await store.upsert(_call('new', responseBody: big(11)));
      expect(_spillFiles(dir), ['a.res', 'new.res']);
    });

    test('opening removes spill files no row refers to', () async {
      await store.upsert(_call('a', responseBody: big(5)));
      await store.close();
      final spill = _spillDir(dir);
      final sep = Platform.pathSeparator;
      File('$spill${sep}orphan.res.zz').writeAsBytesSync([1]);
      File('$spill${sep}a.req.0').writeAsBytesSync([2]);
      File('$spill${sep}notes.txt').writeAsBytesSync([3]);
      store = _open(dir);
      expect(_spillFiles(dir), ['a.res', 'notes']);
      expect(
        (await store.get('a'))!.response!.body.bytes,
        orderedEquals(big(5).bytes),
      );
    });

    test('ids differing only in case keep separate bodies', () async {
      await store.upsert(_call('Ab', responseBody: big(3), startedAt: _t0));
      await store.upsert(
        _call(
          'ab',
          responseBody: big(13),
          startedAt: _t0.add(const Duration(seconds: 1)),
        ),
      );
      expect(_spillNames(dir), hasLength(2));
      expect(
        (await store.get('Ab'))!.response!.body.bytes,
        orderedEquals(big(3).bytes),
      );
      expect(
        (await store.get('ab'))!.response!.body.bytes,
        orderedEquals(big(13).bytes),
      );
      await store.trim(maxCalls: 1, maxAge: const Duration(days: 99999));
      expect(await store.get('Ab'), isNull);
      expect(_spillNames(dir), hasLength(1));
      expect(
        (await store.get('ab'))!.response!.body.bytes,
        orderedEquals(big(13).bytes),
      );
    });

    test('overlong ids use a short distinct fallback name', () async {
      final long1 = 'x' * 121;
      final long2 = '${'x' * 120}y';
      await store.upsert(_call(long1, responseBody: big(3)));
      await store.upsert(_call(long2, responseBody: big(13)));
      final names = _spillNames(dir);
      expect(names, hasLength(2));
      for (final n in names) {
        expect(n, matches(RegExp(r'^_r[0-9]+\.res\.[a-z0-9]+$')));
      }
      expect(
        (await store.get(long1))!.response!.body.bytes,
        orderedEquals(big(3).bytes),
      );
      expect(
        (await store.get(long2))!.response!.body.bytes,
        orderedEquals(big(13).bytes),
      );
    });

    test('a spill directory removed at runtime is recreated', () async {
      await store.upsert(_call('a', responseBody: _text('{}', 'text/plain')));
      Directory(_spillDir(dir)).deleteSync(recursive: true);
      await store.upsert(_call('b', responseBody: big(3)));
      expect(
        (await store.get('b'))!.response!.body.bytes,
        orderedEquals(big(3).bytes),
      );
    });
  });

  group('SqliteStore schema robustness', () {
    late Directory dir;
    late SqliteStore store;

    setUp(() {
      dir = _tempDir();
      store = _open(dir);
    });
    tearDown(() => store.close());

    Database raw() {
      final db = sqlite3.open(_dbPath(dir));
      addTearDown(db.close);
      return db;
    }

    test('summaries keep whether startedAt was UTC or local', () async {
      final local = DateTime.fromMicrosecondsSinceEpoch(
        _t0.microsecondsSinceEpoch + 1000,
      );
      await store.upsert(_call('utc', startedAt: _t0));
      await store.upsert(_call('local', startedAt: local));
      Future<void> check() async {
        final rows = {
          for (final s in await store.query(
            const CallQuery(),
            offset: 0,
            limit: 10,
          ))
            s.id: s.startedAt,
        };
        expect(rows['utc'], _t0);
        expect(rows['utc']!.isUtc, isTrue);
        expect(rows['local'], local);
        expect(rows['local']!.isUtc, isFalse);
      }

      await check();
      await store.close();
      store = _open(dir);
      await check();
    });

    test('search stays correct after VACUUM renumbers rows', () async {
      for (final (id, word) in [
        ('a', 'alphaword'),
        ('b', 'bravoword'),
        ('c', 'charlieword'),
      ]) {
        await store.upsert(
          _call(
            id,
            responseBody: _text(word, 'text/plain'),
            startedAt: _t0.add(Duration(seconds: id.codeUnitAt(0))),
          ),
        );
      }
      await store.trim(maxCalls: 2, maxAge: const Duration(days: 99999));
      raw().execute('VACUUM');
      expect(await _ids(store, const CallQuery(text: 'bravoword')), ['b']);
      expect(await _ids(store, const CallQuery(text: 'charlieword')), ['c']);
      await store.upsert(
        _call('d', responseBody: _text('deltaword', 'text/plain')),
      );
      expect(await _ids(store, const CallQuery(text: 'deltaword')), ['d']);
      expect(await _ids(store, const CallQuery(text: 'bravoword')), ['b']);
    });

    test('has an index for the newest-first listing', () async {
      final indexes = <String>[];
      final db = raw();
      for (final l in db.select(
        "SELECT name FROM pragma_index_list('calls')",
      )) {
        final cols = db
            .select('SELECT name FROM pragma_index_info(?) ORDER BY seqno', [
              l['name'],
            ])
            .map((r) => r['name'])
            .join(',');
        indexes.add(cols);
      }
      expect(indexes, contains('started_at,id'));
    });

    test('a corrupt calls row is skipped by query and null from get', () async {
      for (final id in ['a', 'b', 'c', 'd']) {
        await store.upsert(_call(id));
      }
      await store.upsert(_call('g', method: 'GET'));
      await store.upsert(_call('h', method: 'GET'));
      raw()
        ..execute("UPDATE calls SET kind = 'future' WHERE id = 'b'")
        ..execute("UPDATE calls SET meta = x'7b' WHERE id = 'c'")
        ..execute("UPDATE bodies SET kind = 'future' WHERE call_id = 'd'")
        ..execute("UPDATE calls SET kind = 'future' WHERE id = 'h'");
      expect(await _ids(store, const CallQuery()), ['g', 'd', 'c', 'a']);
      expect(await _ids(store, const CallQuery(methods: {'POST'})), [
        'd',
        'c',
        'a',
      ]);
      for (final q in [
        const CallQuery(),
        const CallQuery(methods: {'POST'}),
        const CallQuery(methods: {'GET'}),
      ]) {
        final listed = await store.query(q, offset: 0, limit: 1000);
        expect(await store.count(q), listed.length);
      }
      expect(await store.count(const CallQuery()), 4);
      expect(await store.count(const CallQuery(methods: {'POST'})), 3);
      expect(await store.count(const CallQuery(methods: {'GET'})), 1);
      expect(await store.get('a'), isNotNull);
      expect(await store.get('c'), isNull);
      expect(await store.get('d'), isNull);
    });

    test('an in-memory database (no WAL) still works', () async {
      final mem = SqliteStore.open(
        ':memory:',
        spillDir: _spillDir(_tempDir()),
        spillThreshold: _threshold,
      );
      addTearDown(mem.close);
      await mem.upsert(_call('a'));
      expect(await mem.count(const CallQuery()), 1);
    });
  });

  group('SqliteStore corrupt rows', () {
    late SqliteStore store;

    setUp(() => store = _open(_tempDir()));
    tearDown(() => store.close());

    final validRule = ProxieRule(
      id: 'ok',
      name: 'ok',
      kind: RuleKind.breakpoint,
      matcher: UrlMatcher('*'),
    );

    test('rules() skips undecodable rows and keeps the valid ones', () async {
      await store.saveRules([validRule]);
      store
        ..debugInsertRawRule(
          jsonEncode({...validRule.toMap(), 'id': 'bad', 'kind': 'future'}),
        )
        ..debugInsertRawRule(jsonEncode({...validRule.toMap(), 'name': 42}))
        ..debugInsertRawRule('{not json')
        ..debugInsertRawRule('[1, 2]')
        ..debugInsertRawRule(null)
        ..debugInsertRawRule(jsonEncode({...validRule.toMap(), 'id': 'ok2'}));
      expect((await store.rules()).map((r) => r.id), ['ok', 'ok2']);
    });

    test('customPresets() skips undecodable rows', () async {
      await store.saveCustomPreset(
        'good',
        'Good',
        const MapLocalAction(failure: SimulatedFailure.timeout),
      );
      store
        ..debugInsertRawPreset('bad1', 'x', '{"failure":"nope"}')
        ..debugInsertRawPreset('bad2', 'x', 'not json')
        ..debugInsertRawPreset('bad3', null, '{}')
        ..debugInsertRawPreset('bad4', 'x', '"str"')
        ..debugInsertRawPreset('good2', 'G2', '{}');
      expect((await store.customPresets()).map((p) => p.id), ['good', 'good2']);
    });
  });
}
