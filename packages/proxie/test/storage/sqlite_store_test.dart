import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/storage/sqlite_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'store_contract.dart';

const _threshold = 256 * 1024;
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

List<String> _spillFiles(Directory d) {
  final spill = Directory(_spillDir(d));
  if (!spill.existsSync()) return const [];
  return [for (final f in spill.listSync()) f.uri.pathSegments.last]..sort();
}

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
}) => ProxieCall(
  id: id,
  sessionId: session,
  adapter: 'dio',
  request: ProxieRequest(
    method: 'POST',
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
      // Windows may briefly hold just-closed files (pending deletes, virus
      // scanners), so retry; a leftover temp directory is harmless.
      for (var attempt = 0; attempt < 10 && d.existsSync(); attempt++) {
        try {
          d.deleteSync(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
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
      expect(
        File('${_spillDir(dir)}/big.res').readAsBytesSync(),
        orderedEquals(res),
      );
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
      for (final id in ['a/b', 'a_b', 'con', r'..\x', 'ü']) {
        await store.upsert(_call(id, responseBody: body));
      }
      final files = _spillFiles(dir);
      expect(files, hasLength(5));
      expect(files.toSet(), hasLength(5));
      for (final f in files) {
        expect(f, matches(RegExp(r'^[A-Za-z0-9_-]+\.res$')));
      }
      for (final id in ['a/b', 'a_b', 'con', r'..\x', 'ü']) {
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

      // Still spilled: same file, new content.
      final big2 = ProxieBody.from(
        Uint8List.fromList(_pattern(_threshold + 20).reversed.toList()),
        null,
      );
      await store.upsert(_call('a', requestBody: big, responseBody: big2));
      expect(_spillFiles(dir), ['a.req', 'a.res']);
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
      final now = DateTime.utc(2026, 6, 1);
      store.close();
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
        File('${_spillDir(dir)}/a.res').deleteSync();
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
      final db = sqlite3.open(_dbPath(dir));
      db.userVersion = 2;
      db.close();
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
