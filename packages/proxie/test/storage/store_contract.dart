import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

final _t0 = DateTime.utc(2026, 1, 1, 12);

/// The fixed clock every store under test is created with.
final _now = DateTime.utc(2026, 6, 1, 12);

ProxieBody _body(String text, String contentType) =>
    ProxieBody.from(Uint8List.fromList(utf8.encode(text)), contentType);

ProxieCall _call(
  String id, {
  int session = 1,
  String adapter = 'http_overrides',
  String method = 'GET',
  String? url,
  int? status,
  ProxieBody? responseBody,
  ProxieError? error,
  DateTime? startedAt,
  Duration? duration,
  Set<CallTag> tags = const {},
}) => ProxieCall(
  id: id,
  sessionId: session,
  adapter: adapter,
  request: ProxieRequest(
    method: method,
    url: Uri.parse(url ?? 'https://api.test/$id'),
    headers: {
      'X-Req': ['1'],
    },
    body: _body('{"q":1}', 'application/json'),
  ),
  response: status == null
      ? null
      : ProxieResponse(
          statusCode: status,
          reasonPhrase: 'R',
          headers: {
            'content-type': ['application/json'],
          },
          body: responseBody ?? _body('{"ok":true}', 'application/json'),
        ),
  error: error,
  startedAt: startedAt ?? _t0,
  duration: duration,
  tags: tags,
);

const _err = ProxieError(type: 'T', message: 'm');

Future<List<String>> _ids(
  ProxieStore s,
  CallQuery q, {
  int offset = 0,
  int limit = 100,
}) async => [
  for (final c in await s.query(q, offset: offset, limit: limit)) c.id,
];

/// Behaviour every [ProxieStore] implementation must satisfy.
void runStoreContract(
  Future<ProxieStore> Function({DateTime Function()? now}) create,
) {
  group('ProxieStore contract', () {
    late ProxieStore store;

    setUp(() async => store = await create(now: () => _now));
    tearDown(() async => store.close());

    group('calls', () {
      test('upsert then get returns the same call', () async {
        final c = _call(
          'a',
          status: 201,
          duration: const Duration(milliseconds: 42),
          tags: {CallTag.mapLocal, CallTag.edited},
        );
        await store.upsert(c);
        final got = await store.get('a');
        expect(got, isNotNull);
        expect(got!.toMap(), c.toMap());
        expect(got.tags, {CallTag.mapLocal, CallTag.edited});
        expect(got.startedAt.isAtSameMomentAs(c.startedAt), isTrue);
      });

      test('get of an unknown id is null', () async {
        expect(await store.get('nope'), isNull);
      });

      test('second upsert with the same id updates the call', () async {
        await store.upsert(_call('a'));
        expect((await store.get('a'))!.response, isNull);
        await store.upsert(
          _call('a', status: 200, duration: const Duration(seconds: 1)),
        );
        final got = await store.get('a');
        expect(got!.response!.statusCode, 200);
        expect(got.duration, const Duration(seconds: 1));
        expect(await store.count(const CallQuery()), 1);
      });

      test('upsert can remove a response and error again', () async {
        await store.upsert(_call('a', status: 500, error: _err));
        await store.upsert(_call('a'));
        final got = await store.get('a');
        expect(got!.response, isNull);
        expect(got.error, isNull);
      });

      test('stores error details', () async {
        await store.upsert(
          _call(
            'a',
            error: const ProxieError(type: 'Timeout', message: 'mm'),
          ),
        );
        final got = await store.get('a');
        expect(got!.error!.type, 'Timeout');
        expect(got.error!.message, 'mm');
      });

      test('keeps binary body bytes exactly', () async {
        final bytes = Uint8List.fromList([0, 255, 1, 254, 128, 10, 0]);
        final c = _call(
          'a',
          status: 200,
          responseBody: ProxieBody.from(bytes, 'application/octet-stream'),
        );
        await store.upsert(c);
        final got = await store.get('a');
        expect(got!.response!.body.bytes, bytes);
        expect(got.response!.body.kind, BodyKind.binary);
      });

      test('keeps truncated flag and original length', () async {
        final body = ProxieBody.from(
          Uint8List.fromList(List.filled(100, 65)),
          'text/plain',
          cap: 10,
        );
        await store.upsert(_call('a', status: 200, responseBody: body));
        final got = (await store.get('a'))!.response!.body;
        expect(got.truncated, isTrue);
        expect(got.bytes, hasLength(10));
        expect(got.originalLength, 100);
      });
    });

    group('query', () {
      test('newest first, ties broken by id descending', () async {
        await store.upsert(_call('b', startedAt: _t0));
        await store.upsert(_call('a', startedAt: _t0));
        await store.upsert(
          _call('c', startedAt: _t0.add(const Duration(seconds: 1))),
        );
        await store.upsert(
          _call('d', startedAt: _t0.subtract(const Duration(seconds: 1))),
        );
        expect(await _ids(store, const CallQuery()), ['c', 'b', 'a', 'd']);
      });

      test('offset/limit pagination is stable and complete', () async {
        for (var i = 0; i < 10; i++) {
          // Pairs share a timestamp to exercise the tie-break.
          await store.upsert(
            _call(
              'c${i.toString().padLeft(2, '0')}',
              startedAt: _t0.add(Duration(seconds: i ~/ 2)),
            ),
          );
        }
        const q = CallQuery();
        final all = await _ids(store, q);
        expect(all, hasLength(10));
        final paged = <String>[];
        for (var off = 0; off < 10; off += 3) {
          paged.addAll(await _ids(store, q, offset: off, limit: 3));
        }
        expect(paged, all);
        expect(await _ids(store, q, offset: 10, limit: 3), isEmpty);
        expect(await _ids(store, q, offset: 50, limit: 3), isEmpty);
        expect(await _ids(store, q, limit: 0), isEmpty);
        expect(await store.count(q), 10);
      });

      test('summary carries list-row fields', () async {
        await store.upsert(
          _call(
            'a',
            method: 'POST',
            url: 'https://api.test/x?y=1',
            status: 201,
            responseBody: _body('{"id":1}', 'application/json'),
            duration: const Duration(milliseconds: 120),
            tags: {CallTag.breakpoint},
            session: 3,
            adapter: 'dio',
          ),
        );
        final s = (await store.query(
          const CallQuery(),
          offset: 0,
          limit: 1,
        )).single;
        expect(s.id, 'a');
        expect(s.method, 'POST');
        expect(s.url, 'https://api.test/x?y=1');
        expect(s.statusCode, 201);
        expect(s.durationMs, 120);
        expect(s.responseSize, 8);
        expect(s.kind, BodyKind.json);
        expect(s.tags, {CallTag.breakpoint});
        expect(s.sessionId, 3);
        expect(s.adapter, 'dio');
        expect(s.hasError, isFalse);
        expect(s.startedAt.isAtSameMomentAs(_t0), isTrue);
      });

      test('pending and failed calls have no status, size or kind', () async {
        await store.upsert(_call('p'));
        await store.upsert(_call('e', error: _err));
        final all = await store.query(const CallQuery(), offset: 0, limit: 10);
        for (final s in all) {
          expect(s.statusCode, isNull);
          expect(s.durationMs, isNull);
          expect(s.responseSize, 0);
          expect(s.kind, BodyKind.empty);
        }
        expect(all.firstWhere((s) => s.id == 'e').hasError, isTrue);
        expect(all.firstWhere((s) => s.id == 'p').hasError, isFalse);
      });

      test('text matches the URL substring, case-insensitively', () async {
        await store.upsert(_call('a', url: 'https://api.test/Users/1'));
        await store.upsert(_call('b', url: 'https://api.test/posts/1'));
        expect(await _ids(store, const CallQuery(text: 'users')), ['a']);
        expect(await _ids(store, const CallQuery(text: 'USERS/1')), ['a']);
        expect(await _ids(store, const CallQuery(text: 'nomatch')), isEmpty);
        expect(await _ids(store, const CallQuery(text: '')), hasLength(2));
        expect(await store.count(const CallQuery(text: 'api.test')), 2);
      });

      test('text treats LIKE and regex characters literally', () async {
        await store.upsert(_call('a', url: 'https://api.test/a_b'));
        await store.upsert(_call('b', url: 'https://api.test/axb'));
        await store.upsert(_call('c', url: 'https://api.test/100%25'));
        expect(await _ids(store, const CallQuery(text: 'a_b')), ['a']);
        expect(await _ids(store, const CallQuery(text: '%')), ['c']);
        expect(await _ids(store, const CallQuery(text: '.*')), isEmpty);
      });

      test('methods filter compares case-insensitively', () async {
        await store.upsert(_call('g'));
        await store.upsert(_call('p', method: 'post'));
        await store.upsert(_call('d', method: 'DELETE'));
        expect(
          (await _ids(
            store,
            const CallQuery(methods: {'post', 'Get'}),
          )).toSet(),
          {'g', 'p'},
        );
        expect(await _ids(store, const CallQuery(methods: {'PUT'})), isEmpty);
      });

      test(
        'StatusFilter.errors returns >=400 and calls with an error',
        () async {
          await store.upsert(_call('ok', status: 200));
          await store.upsert(_call('redir', status: 302));
          await store.upsert(_call('nf', status: 404));
          await store.upsert(_call('boom', status: 500));
          await store.upsert(_call('pending'));
          await store.upsert(_call('fail', error: _err));
          await store.upsert(_call('both', status: 200, error: _err));
          const q = CallQuery(status: StatusFilter.errors);
          expect((await _ids(store, q)).toSet(), {
            'nf',
            'boom',
            'fail',
            'both',
          });
          expect(await store.count(q), 4);
        },
      );

      test('StatusFilter.success returns 200-399 without error', () async {
        await store.upsert(_call('s199', status: 199));
        await store.upsert(_call('s200', status: 200));
        await store.upsert(_call('s399', status: 399));
        await store.upsert(_call('s400', status: 400));
        await store.upsert(_call('pending'));
        await store.upsert(_call('both', status: 200, error: _err));
        const q = CallQuery(status: StatusFilter.success);
        expect((await _ids(store, q)).toSet(), {'s200', 's399'});
      });

      test('onlyJson keeps only json responses', () async {
        await store.upsert(_call('j', status: 200));
        await store.upsert(
          _call('t', status: 200, responseBody: _body('hi', 'text/plain')),
        );
        await store.upsert(_call('none'));
        expect(await _ids(store, const CallQuery(onlyJson: true)), ['j']);
      });

      test('hideBinary excludes binary and image, keeps the rest', () async {
        final png = Uint8List.fromList([
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, //
        ]);
        await store.upsert(
          _call(
            'bin',
            status: 200,
            responseBody: ProxieBody.from(
              Uint8List.fromList([0, 1, 2, 255, 254]),
              'application/octet-stream',
            ),
          ),
        );
        await store.upsert(
          _call(
            'img',
            status: 200,
            responseBody: ProxieBody.from(png, 'image/png'),
          ),
        );
        await store.upsert(_call('json', status: 200));
        await store.upsert(
          _call('txt', status: 200, responseBody: _body('hi', 'text/plain')),
        );
        await store.upsert(_call('pending'));
        const q = CallQuery(hideBinary: true);
        expect((await _ids(store, q)).toSet(), {'json', 'txt', 'pending'});
        expect(await store.count(q), 3);
      });

      test('maxSize excludes larger responses, boundary inclusive', () async {
        await store.upsert(
          _call(
            'small',
            status: 200,
            responseBody: _body('12345', 'text/plain'),
          ),
        );
        await store.upsert(
          _call(
            'big',
            status: 200,
            responseBody: _body('1234567890', 'text/plain'),
          ),
        );
        await store.upsert(_call('pending'));
        expect((await _ids(store, const CallQuery(maxSize: 5))).toSet(), {
          'small',
          'pending',
        });
        expect((await _ids(store, const CallQuery(maxSize: 10))).toSet(), {
          'small',
          'big',
          'pending',
        });
        expect(await _ids(store, const CallQuery(maxSize: 0)), ['pending']);
      });

      test('maxSize uses the original length of truncated bodies', () async {
        final body = ProxieBody.from(
          Uint8List.fromList(List.filled(100, 65)),
          'text/plain',
          cap: 10,
        );
        await store.upsert(_call('a', status: 200, responseBody: body));
        expect(await _ids(store, const CallQuery(maxSize: 50)), isEmpty);
        expect(await _ids(store, const CallQuery(maxSize: 100)), ['a']);
      });

      test('sessionId and adapters filter', () async {
        await store.upsert(_call('a', adapter: 'dio'));
        await store.upsert(_call('b', session: 2, adapter: 'dio'));
        await store.upsert(_call('c', session: 2, adapter: 'http'));
        expect((await _ids(store, const CallQuery(sessionId: 2))).toSet(), {
          'b',
          'c',
        });
        expect(
          (await _ids(store, const CallQuery(adapters: {'dio'}))).toSet(),
          {'a', 'b'},
        );
        expect(
          await _ids(
            store,
            const CallQuery(sessionId: 2, adapters: {'dio', 'other'}),
          ),
          ['b'],
        );
      });

      test('filters combine with AND, and count agrees with query', () async {
        await store.upsert(_call('a', status: 500));
        await store.upsert(_call('b', method: 'POST', status: 500));
        await store.upsert(_call('c', status: 200));
        const q = CallQuery(
          methods: {'GET'},
          status: StatusFilter.errors,
          onlyJson: true,
        );
        expect(await _ids(store, q), ['a']);
        expect(await store.count(q), 1);
        expect(await store.count(const CallQuery()), 3);
      });

      test('text also searches text and json response bodies', () async {
        const token = 'ZxqUniqueToken';
        final tokenBytes = utf8.encode(token);
        await store.upsert(
          _call(
            'json',
            status: 200,
            responseBody: _body('{"k":"$token"}', 'application/json'),
          ),
        );
        await store.upsert(
          _call(
            'txt',
            status: 200,
            responseBody: _body('hello $token!', 'text/plain'),
          ),
        );
        await store.upsert(
          _call(
            'other',
            status: 200,
            responseBody: _body('{"k":"nothing"}', 'application/json'),
          ),
        );
        await store.upsert(
          _call(
            'bin',
            status: 200,
            responseBody: ProxieBody.from(
              Uint8List.fromList([0, 255, 254, ...tokenBytes]),
              'application/octet-stream',
            ),
          ),
        );
        await store.upsert(
          _call(
            'img',
            status: 200,
            responseBody: ProxieBody.from(
              Uint8List.fromList([
                0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
                ...tokenBytes,
              ]),
              'image/png',
            ),
          ),
        );
        await store.upsert(_call('pending'));
        await store.upsert(_call('pending2', url: 'https://api.test/$token'));

        const q = CallQuery(text: 'zxqUNIQUEtoken');
        expect((await _ids(store, q)).toSet(), {'json', 'txt', 'pending2'});
        expect(await store.count(q), 3);
        expect(
          await _ids(store, const CallQuery(text: 'absent-token')),
          isEmpty,
        );
      });

      test('filtered pagination is stable and count ignores paging', () async {
        for (var i = 0; i < 12; i++) {
          await store.upsert(
            _call(
              'c${i.toString().padLeft(2, '0')}',
              method: i.isEven ? 'GET' : 'POST',
              startedAt: _t0.add(Duration(seconds: i)),
            ),
          );
        }
        const q = CallQuery(methods: {'GET'});
        final all = await _ids(store, q);
        expect(all, ['c10', 'c08', 'c06', 'c04', 'c02', 'c00']);
        final paged = <String>[];
        for (var off = 0; off < 6; off += 2) {
          paged.addAll(await _ids(store, q, offset: off, limit: 2));
        }
        expect(paged, all);
        expect(await _ids(store, q, offset: 5, limit: 10), ['c00']);
        expect(await _ids(store, q, offset: 6, limit: 10), isEmpty);
        expect(await store.count(q), 6);
      });

      test('every filter excludes on its own and filters combine', () async {
        ProxieBody json(String s) => _body(s, 'application/json');
        await store.upsert(
          _call(
            'hit',
            url: 'https://api.test/needle/1',
            session: 2,
            adapter: 'dio',
            status: 200,
            responseBody: json('{"a":1}'),
          ),
        );
        await store.upsert(
          _call(
            'plain',
            url: 'https://api.test/needle/2',
            session: 2,
            adapter: 'dio',
            status: 200,
            responseBody: _body('ok', 'text/plain'),
          ),
        );
        // Each row below differs from a hit in exactly one respect.
        await store.upsert(
          _call(
            'noText',
            url: 'https://api.test/other',
            session: 2,
            adapter: 'dio',
            status: 200,
            responseBody: json('{"a":1}'),
          ),
        );
        await store.upsert(
          _call(
            'method',
            url: 'https://api.test/needle/3',
            method: 'POST',
            session: 2,
            adapter: 'dio',
            status: 200,
            responseBody: json('{"a":1}'),
          ),
        );
        await store.upsert(
          _call(
            'status',
            url: 'https://api.test/needle/4',
            session: 2,
            adapter: 'dio',
            status: 500,
            responseBody: json('{"a":1}'),
          ),
        );
        await store.upsert(
          _call(
            'adapter',
            url: 'https://api.test/needle/5',
            session: 2,
            adapter: 'http',
            status: 200,
            responseBody: json('{"a":1}'),
          ),
        );
        await store.upsert(
          _call(
            'session',
            url: 'https://api.test/needle/6',
            adapter: 'dio',
            status: 200,
            responseBody: json('{"a":1}'),
          ),
        );
        await store.upsert(
          _call(
            'big',
            url: 'https://api.test/needle/7',
            session: 2,
            adapter: 'dio',
            status: 200,
            responseBody: json('{"a":"${'x' * 100}"}'),
          ),
        );
        await store.upsert(
          _call(
            'binary',
            url: 'https://api.test/needle/8',
            session: 2,
            adapter: 'dio',
            status: 200,
            responseBody: ProxieBody.from(
              Uint8List.fromList([0, 255, 254]),
              'application/octet-stream',
            ),
          ),
        );
        const q = CallQuery(
          text: 'NEEDLE',
          methods: {'get'},
          status: StatusFilter.success,
          hideBinary: true,
          maxSize: 50,
          sessionId: 2,
          adapters: {'dio'},
        );
        expect((await _ids(store, q)).toSet(), {'hit', 'plain'});
        expect(await store.count(q), 2);
        final onlyJson = q.copyWith(onlyJson: true);
        expect(await _ids(store, onlyJson), ['hit']);
        expect(await store.count(onlyJson), 1);
      });

      test('upsert refreshes the queryable summary', () async {
        await store.upsert(_call('a', url: 'https://old.test/a'));
        await store.upsert(
          _call(
            'a',
            url: 'https://new.test/b',
            method: 'PUT',
            session: 2,
            adapter: 'dio',
            status: 500,
            responseBody: _body('boom', 'text/plain'),
            duration: const Duration(milliseconds: 77),
            tags: {CallTag.edited},
          ),
        );
        expect(await store.count(const CallQuery()), 1);
        final s = (await store.query(
          const CallQuery(),
          offset: 0,
          limit: 10,
        )).single;
        expect(s.url, 'https://new.test/b');
        expect(s.method, 'PUT');
        expect(s.sessionId, 2);
        expect(s.adapter, 'dio');
        expect(s.statusCode, 500);
        expect(s.durationMs, 77);
        expect(s.kind, BodyKind.text);
        expect(s.responseSize, 4);
        expect(s.tags, {CallTag.edited});
        expect(s.hasError, isFalse);
        expect(
          await _ids(store, const CallQuery(status: StatusFilter.errors)),
          ['a'],
        );
        expect(await _ids(store, const CallQuery(sessionId: 2)), ['a']);
        expect(await _ids(store, const CallQuery(text: 'new.test')), ['a']);
        expect(await _ids(store, const CallQuery(text: 'boom')), ['a']);
        expect(await _ids(store, const CallQuery(methods: {'PUT'})), ['a']);
        expect(await _ids(store, const CallQuery(sessionId: 1)), isEmpty);
        expect(await _ids(store, const CallQuery(text: 'old.test')), isEmpty);
        expect(await _ids(store, const CallQuery(methods: {'GET'})), isEmpty);
        expect(
          await _ids(store, const CallQuery(status: StatusFilter.success)),
          isEmpty,
        );
      });

      test('upsert that adds an error flips hasError and the filter', () async {
        await store.upsert(_call('a', status: 200));
        await store.upsert(_call('a', status: 200, error: _err));
        final s = (await store.query(
          const CallQuery(),
          offset: 0,
          limit: 1,
        )).single;
        expect(s.hasError, isTrue);
        expect(
          await store.count(const CallQuery(status: StatusFilter.errors)),
          1,
        );
        expect(
          await store.count(const CallQuery(status: StatusFilter.success)),
          0,
        );
      });

      test('orders by instant across UTC and local, down to the ms', () async {
        final base = DateTime.utc(2026, 1, 1, 12);
        await store.upsert(_call('a', startedAt: base));
        await store.upsert(
          _call('b', startedAt: base.add(const Duration(milliseconds: 1))),
        );
        // Same instant as base + 1 s, but expressed in local time.
        await store.upsert(
          _call(
            'c',
            startedAt: DateTime.fromMillisecondsSinceEpoch(
              base.millisecondsSinceEpoch + 1000,
            ),
          ),
        );
        await store.upsert(
          _call('d', startedAt: base.subtract(const Duration(milliseconds: 1))),
        );
        expect(await _ids(store, const CallQuery()), ['c', 'b', 'a', 'd']);
        final got = await store.get('c');
        expect(
          got!.startedAt.millisecondsSinceEpoch,
          base.millisecondsSinceEpoch + 1000,
        );
      });

      test('CallQuery.copyWith sets and clears fields', () {
        const q = CallQuery(text: 't', maxSize: 3, sessionId: 2);
        expect(q.copyWith(onlyJson: true).text, 't');
        expect(q.copyWith(clearText: true).text, isNull);
        expect(q.copyWith(clearMaxSize: true).maxSize, isNull);
        expect(q.copyWith(clearSessionId: true).sessionId, isNull);
        expect(q.copyWith(maxSize: 9).maxSize, 9);
        expect(
          q.copyWith(status: StatusFilter.errors).status,
          StatusFilter.errors,
        );
      });
    });

    group('sessions', () {
      test(
        'ids increase from 1 and list newest first with call counts',
        () async {
          expect(await store.sessions(), isEmpty);
          final s1 = await store.startSession();
          final s2 = await store.startSession();
          final s3 = await store.startSession();
          expect([s1, s2, s3], [1, 2, 3]);
          await store.upsert(_call('a', session: s1));
          await store.upsert(_call('b', session: s2));
          await store.upsert(_call('c', session: s2));
          await store.upsert(_call('c', session: s2)); // update, not new
          final sessions = await store.sessions();
          expect(sessions.map((s) => s.id), [3, 2, 1]);
          expect(sessions.map((s) => s.callCount), [0, 2, 1]);
        },
      );

      test('lists only started sessions; orphan calls are tolerated', () async {
        final s1 = await store.startSession();
        await store.upsert(_call('orphan', session: 99));
        await store.upsert(_call('a', session: s1));
        final sessions = await store.sessions();
        expect(sessions.map((s) => s.id), [s1]);
        expect(sessions.single.callCount, 1);
        expect(await store.get('orphan'), isNotNull);
        expect(await store.count(const CallQuery(sessionId: 99)), 1);
      });

      test('a call moved to another session is counted there', () async {
        final s1 = await store.startSession();
        final s2 = await store.startSession();
        await store.upsert(_call('a', session: s1));
        await store.upsert(_call('a', session: s2));
        final counts = {
          for (final s in await store.sessions()) s.id: s.callCount,
        };
        expect(counts, {s1: 0, s2: 1});
      });
    });

    group('rules', () {
      ProxieRule rule(String id, {bool enabled = true}) => ProxieRule(
        id: id,
        name: 'Rule $id',
        enabled: enabled,
        kind: RuleKind.mapLocal,
        matcher: UrlMatcher('*/$id*'),
        method: 'GET',
        mapLocal: MapLocalAction(
          response: ProxieResponse(
            statusCode: 418,
            headers: const {},
            body: _body('{"t":1}', 'application/json'),
          ),
          delay: const Duration(milliseconds: 250),
        ),
      );

      test('start empty', () async {
        expect(await store.rules(), isEmpty);
      });

      test('roundtrip in order', () async {
        final rules = [rule('c'), rule('a', enabled: false), rule('b')];
        await store.saveRules(rules);
        final got = await store.rules();
        expect(got.map((r) => r.id), ['c', 'a', 'b']);
        expect(
          got.map((r) => r.toMap()).toList(),
          rules.map((r) => r.toMap()).toList(),
        );
      });

      test('saveRules replaces the previous list', () async {
        await store.saveRules([rule('a'), rule('b')]);
        await store.saveRules([rule('z')]);
        expect((await store.rules()).map((r) => r.id), ['z']);
        await store.saveRules([]);
        expect(await store.rules(), isEmpty);
      });
    });

    group('custom presets', () {
      MapLocalAction action(int status) => MapLocalAction(
        response: ProxieResponse(
          statusCode: status,
          headers: const {},
          body: _body('{"s":$status}', 'application/json'),
        ),
        delay: const Duration(seconds: 1),
      );

      test('start empty', () async {
        expect(await store.customPresets(), isEmpty);
      });

      test('roundtrip: build ignores the captured response', () async {
        await store.saveCustomPreset('p1', 'My preset', action(418));
        final presets = await store.customPresets();
        expect(presets, hasLength(1));
        expect(presets.single.id, 'p1');
        expect(presets.single.label, 'My preset');
        final captured = ProxieResponse(
          statusCode: 200,
          headers: const {},
          body: _body('other', 'text/plain'),
        );
        for (final c in [null, captured]) {
          final built = presets.single.build(c);
          expect(built.response!.statusCode, 418);
          expect(built.response!.body.text, '{"s":418}');
          expect(built.delay, const Duration(seconds: 1));
        }
      });

      test('failure-only actions roundtrip', () async {
        await store.saveCustomPreset(
          'f',
          'Fail',
          const MapLocalAction(failure: SimulatedFailure.timeout),
        );
        final built = (await store.customPresets()).single.build(null);
        expect(built.failure, SimulatedFailure.timeout);
        expect(built.response, isNull);
      });

      test('listed in insertion order; replacing keeps the position', () async {
        await store.saveCustomPreset('b', 'B', action(400));
        await store.saveCustomPreset('a', 'A', action(401));
        await store.saveCustomPreset('c', 'C', action(402));
        await store.saveCustomPreset('b', 'B2', action(403));
        final presets = await store.customPresets();
        expect(presets.map((p) => p.id), ['b', 'a', 'c']);
        expect(presets.first.label, 'B2');
        expect(presets.first.build(null).response!.statusCode, 403);
      });

      test('saving an existing id replaces it', () async {
        await store.saveCustomPreset('p1', 'One', action(400));
        await store.saveCustomPreset('p2', 'Two', action(500));
        await store.saveCustomPreset('p1', 'One v2', action(404));
        final presets = await store.customPresets();
        expect(presets, hasLength(2));
        final p1 = presets.firstWhere((p) => p.id == 'p1');
        expect(p1.label, 'One v2');
        expect(p1.build(null).response!.statusCode, 404);
      });
    });

    group('isolation', () {
      test(
        'changing objects after upsert does not change stored data',
        () async {
          final c = _call('a', status: 200);
          await store.upsert(c);
          c.response!.body.bytes[0] = 0x58;
          c.request.body.bytes[0] = 0x58;
          final changed = c.copyWith(
            response: c.response!.copyWith(statusCode: 500),
          );
          expect(changed.response!.statusCode, 500);
          final got = (await store.get('a'))!;
          expect(got.response!.statusCode, 200);
          expect(got.response!.body.text, '{"ok":true}');
          expect(got.request.body.text, '{"q":1}');
        },
      );

      test('changing a returned call does not change stored data', () async {
        await store.upsert(_call('a', status: 200));
        final got = (await store.get('a'))!;
        got.response!.body.bytes[0] = 0x58;
        got.request.body.bytes[0] = 0x58;
        got.copyWith(response: got.response!.copyWith(statusCode: 500));
        final again = (await store.get('a'))!;
        expect(again.response!.statusCode, 200);
        expect(again.response!.body.text, '{"ok":true}');
        expect(again.request.body.text, '{"q":1}');
        expect(await store.count(const CallQuery(text: '"ok"')), 1);
      });
    });

    group('trim', () {
      test('maxCalls: 2 keeps the newest 2', () async {
        for (var i = 0; i < 5; i++) {
          await store.upsert(
            _call('c$i', startedAt: _now.add(Duration(seconds: i))),
          );
        }
        await store.trim(maxCalls: 2, maxAge: const Duration(days: 365));
        expect(await _ids(store, const CallQuery()), ['c4', 'c3']);
        expect(await store.get('c0'), isNull);
        expect(await store.count(const CallQuery()), 2);
      });

      test('ties at the cutoff are broken by id like the listing', () async {
        final t = _now;
        await store.upsert(_call('a', startedAt: t));
        await store.upsert(_call('b', startedAt: t));
        await store.upsert(_call('c', startedAt: t));
        await store.trim(maxCalls: 2, maxAge: const Duration(days: 365));
        expect(await _ids(store, const CallQuery()), ['c', 'b']);
      });

      test('maxCalls larger than the count removes nothing', () async {
        await store.upsert(_call('a', startedAt: _now));
        await store.trim(maxCalls: 10, maxAge: const Duration(days: 365));
        expect(await store.count(const CallQuery()), 1);
      });

      test('maxCalls: 0 removes everything', () async {
        await store.upsert(_call('a', startedAt: _now));
        await store.trim(maxCalls: 0, maxAge: const Duration(days: 365));
        expect(await store.count(const CallQuery()), 0);
      });

      test('removes calls older than maxAge', () async {
        final now = _now;
        await store.upsert(
          _call('old', startedAt: now.subtract(const Duration(days: 10))),
        );
        await store.upsert(
          _call('fresh', startedAt: now.subtract(const Duration(hours: 1))),
        );
        await store.trim(maxCalls: 100, maxAge: const Duration(days: 7));
        expect(await _ids(store, const CallQuery()), ['fresh']);
      });

      test('applies the age cut and then the count cut in one call', () async {
        for (final (id, age) in [
          ('ancient', 30),
          ('old', 20),
          ('d3', 3),
          ('d2', 2),
          ('d1', 1),
        ]) {
          await store.upsert(
            _call(id, startedAt: _now.subtract(Duration(days: age))),
          );
        }
        await store.trim(maxCalls: 2, maxAge: const Duration(days: 10));
        expect(await _ids(store, const CallQuery()), ['d1', 'd2']);
        // Age alone would keep all three recent calls; count alone is 2.
        await store.upsert(
          _call('d0', startedAt: _now.subtract(const Duration(hours: 1))),
        );
        await store.trim(
          maxCalls: 10,
          maxAge: const Duration(days: 1, hours: 12),
        );
        expect(await _ids(store, const CallQuery()), ['d0', 'd1']);
      });

      test('a call exactly maxAge old is kept, one older is removed', () async {
        const age = Duration(days: 7);
        await store.upsert(_call('exact', startedAt: _now.subtract(age)));
        await store.upsert(
          _call(
            'older',
            startedAt: _now.subtract(age + const Duration(milliseconds: 1)),
          ),
        );
        await store.trim(maxCalls: 100, maxAge: age);
        expect(await _ids(store, const CallQuery()), ['exact']);
      });

      test('keeps rules, presets and sessions', () async {
        final s = await store.startSession();
        await store.saveRules([
          ProxieRule(
            id: 'r',
            name: 'r',
            kind: RuleKind.breakpoint,
            matcher: UrlMatcher('*'),
          ),
        ]);
        await store.saveCustomPreset(
          'p',
          'P',
          const MapLocalAction(failure: SimulatedFailure.noConnection),
        );
        await store.upsert(_call('a', session: s, startedAt: _now));
        await store.trim(maxCalls: 0, maxAge: const Duration(days: 1));
        expect(await store.rules(), hasLength(1));
        expect(await store.customPresets(), hasLength(1));
        expect((await store.sessions()).single.callCount, 0);
      });
    });

    group('clear', () {
      test('removes calls and sessions but keeps rules and presets', () async {
        final s = await store.startSession();
        await store.upsert(_call('a', session: s));
        await store.saveRules([
          ProxieRule(
            id: 'r',
            name: 'r',
            kind: RuleKind.breakpoint,
            matcher: UrlMatcher('*'),
          ),
        ]);
        await store.saveCustomPreset(
          'p',
          'P',
          const MapLocalAction(failure: SimulatedFailure.timeout),
        );
        await store.clear();
        expect(await store.count(const CallQuery()), 0);
        expect(await store.get('a'), isNull);
        expect(await store.sessions(), isEmpty);
        expect((await store.rules()).single.id, 'r');
        expect((await store.customPresets()).single.id, 'p');
      });

      test('session ids are not reused after clear', () async {
        final s1 = await store.startSession();
        await store.clear();
        final s2 = await store.startSession();
        expect(s2, greaterThan(s1));
      });
    });

    group('CallSummary.fromCall', () {
      test('maps a call without response', () {
        final s = CallSummary.fromCall(_call('a'));
        expect(s.statusCode, isNull);
        expect(s.responseSize, 0);
        expect(s.kind, BodyKind.empty);
        expect(s.hasError, isFalse);
      });

      test('tags are unmodifiable', () {
        final s = CallSummary.fromCall(_call('a', tags: {CallTag.edited}));
        expect(() => s.tags.add(CallTag.mapLocal), throwsUnsupportedError);
      });
    });
  });
}
