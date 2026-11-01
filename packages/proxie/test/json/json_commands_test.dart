import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/worker/isolate_worker.dart';

ProxieBody _body(String s, {String type = 'application/json', int? cap}) =>
    ProxieBody.from(
      Uint8List.fromList(utf8.encode(s)),
      type,
      cap: cap ?? defaultBodyCap,
    );

ProxieCall _call(String id, {ProxieBody? request, ProxieBody? response}) =>
    ProxieCall(
      id: id,
      sessionId: 1,
      adapter: 'test',
      request: ProxieRequest(
        method: 'POST',
        url: Uri.parse('https://api.test/$id'),
        headers: const {},
        body: request ?? _body('{"q":[1,2,3]}'),
      ),
      response: response == null
          ? null
          : ProxieResponse(statusCode: 200, headers: const {}, body: response),
      startedAt: DateTime.utc(2026),
    );

final _closed = throwsA(isA<JsonDocumentClosed>());

/// A JSON array of [n] zeros: n + 1 nodes.
ProxieBody _zeros(int n) => ProxieBody(
  bytes: Uint8List.fromList(utf8.encode('[${List.filled(n, '0').join(',')}]')),
  contentType: 'application/json',
  kind: BodyKind.json,
);

void main() {
  late MemoryStore store;
  late WorkerContext ctx;

  setUp(() {
    store = MemoryStore();
    ctx = WorkerContext(store: store, config: const ProxieConfig());
  });

  Future<JsonHandle> open(String id, JsonBodySide side) =>
      OpenJson(id, side).execute(ctx);

  Iterable<JsonDocument> openDocs() => ctx.resources.values.whereType();

  test('open, page, toggle and close a request body', () async {
    await store.upsert(_call('c1', response: _body('{"ok":true}')));
    final h = await open('c1', JsonBodySide.request);
    expect(h.parseError, isNull);
    expect(h.truncated, isFalse);
    expect(h.visibleCount, 1);
    expect(ctx.resources['json:${h.docId}'], isA<JsonDocument>());

    final rows = await JsonRows(h.docId, 0, 10).execute(ctx);
    expect(rows.single.key, 'q');
    expect(await JsonToggle(h.docId, rows.single.nodeId).execute(ctx), 4);
    final after = await JsonRows(h.docId, 1, 10).execute(ctx);
    expect([for (final r in after) r.preview], ['1', '2', '3']);

    await CloseJson(h.docId).execute(ctx);
    expect(ctx.resources['json:${h.docId}'], isNull);
    expect(() => JsonRows(h.docId, 0, 1).execute(ctx), _closed);
    // Closing twice is harmless.
    await CloseJson(h.docId).execute(ctx);
  });

  test('response bodies open independently of the request', () async {
    await store.upsert(_call('c1', response: _body('[1,2]')));
    final req = await open('c1', JsonBodySide.request);
    final res = await open('c1', JsonBodySide.response);
    expect(req.docId, isNot(res.docId));
    expect(res.visibleCount, 2);
  });

  test('missing calls and responses throw StateError', () async {
    await store.upsert(_call('c1'));
    expect(() => open('nope', JsonBodySide.request), throwsStateError);
    expect(() => open('c1', JsonBodySide.response), throwsStateError);
  });

  test('unknown docs throw JsonDocumentClosed', () async {
    expect(() => JsonRows('x', 0, 1).execute(ctx), _closed);
    expect(() => JsonToggle('x', 0).execute(ctx), _closed);
    expect(() => JsonSchema('x', 0).execute(ctx), _closed);
    expect(
      const JsonDocumentClosed('x').toString(),
      'JsonDocumentClosed: no open JSON document x',
    );
  });

  test('invalid JSON and non-JSON kinds', () async {
    await store.upsert(
      _call(
        'c1',
        request: ProxieBody(
          bytes: Uint8List.fromList([0xff, 0xfe]),
          contentType: 'application/json',
          kind: BodyKind.binary,
        ),
        // Mislabeled JSON is still parsed.
        response: _body('{"a":1}', type: 'text/plain'),
      ),
    );
    final bad = await open('c1', JsonBodySide.request);
    expect(bad.parseError, isNotNull);
    expect(bad.visibleCount, 0);
    expect(await JsonRows(bad.docId, 0, 10).execute(ctx), isEmpty);
    final good = await open('c1', JsonBodySide.response);
    expect(good.parseError, isNull);
    expect(good.visibleCount, 1);
  });

  test('truncated bodies report why the JSON is unavailable', () async {
    await store.upsert(
      _call(
        'c1',
        request: _body('[1,2,3,4,5,6]', cap: 5),
        response: _body('[1]   ', cap: 4), // cut in trailing whitespace
      ),
    );
    final cut = await open('c1', JsonBodySide.request);
    expect(cut.truncated, isTrue);
    expect(
      cut.parseError,
      'Body was truncated at capture; full JSON unavailable',
    );
    final ok = await open('c1', JsonBodySide.response);
    expect(ok.truncated, isTrue);
    expect(ok.parseError, isNull);
    expect(ok.visibleCount, 1);
  });

  test('reopening the same body returns the open document', () async {
    await store.upsert(_call('c1', response: _body('[[1,2]]')));
    final a = await open('c1', JsonBodySide.response);
    final rows = await JsonRows(a.docId, 0, 1).execute(ctx);
    await JsonToggle(a.docId, rows.single.nodeId).execute(ctx);
    final b = await open('c1', JsonBodySide.response);
    expect(b.docId, a.docId);
    expect(b.visibleCount, 3); // shares the expansion state
    expect(openDocs(), hasLength(1));

    // A changed body gets a fresh document; the stale one is closed.
    await store.upsert(_call('c1', response: _body('[0]')));
    final c = await open('c1', JsonBodySide.response);
    expect(c.docId, isNot(a.docId));
    expect(c.visibleCount, 1);
    expect(() => JsonRows(a.docId, 0, 1).execute(ctx), _closed);
    expect(openDocs(), hasLength(1));
  });

  test('reopening counts as a use for eviction', () async {
    for (var i = 0; i < 8; i++) {
      await store.upsert(_call('c$i'));
    }
    final first = await open('c0', JsonBodySide.request);
    for (var i = 1; i < 8; i++) {
      await open('c$i', JsonBodySide.request);
    }
    expect((await open('c0', JsonBodySide.request)).docId, first.docId);
    await store.upsert(_call('c8'));
    await open('c8', JsonBodySide.request);
    // c1 was least recently used, not c0.
    expect(await JsonRows(first.docId, 0, 1).execute(ctx), hasLength(1));
    expect(openDocs(), hasLength(8));
  });

  test(
    'at most 8 documents stay open; least recently used goes first',
    () async {
      for (var i = 0; i < 9; i++) {
        await store.upsert(_call('c$i'));
      }
      final handles = [
        for (var i = 0; i < 8; i++) await open('c$i', JsonBodySide.request),
      ];
      // Touch the oldest so the second-oldest becomes the eviction victim.
      await JsonRows(handles[0].docId, 0, 1).execute(ctx);
      await open('c8', JsonBodySide.request);
      expect(await JsonRows(handles[0].docId, 0, 1).execute(ctx), hasLength(1));
      expect(() => JsonRows(handles[1].docId, 0, 1).execute(ctx), _closed);
      expect(openDocs(), hasLength(8));
    },
  );

  test('open documents are bounded by total nodes', () async {
    expect(maxOpenJsonNodes, 4000000);
    await store.upsert(_call('big1', response: _zeros(2500000)));
    await store.upsert(_call('small', response: _body('[1]')));
    await store.upsert(_call('big2', response: _zeros(2500000)));
    await store.upsert(_call('huge', response: _zeros(4100000)));

    final big1 = await open('big1', JsonBodySide.response);
    final small = await open('small', JsonBodySide.response);
    final big2 = await open('big2', JsonBodySide.response);
    // big1 had to go to fit big2; small fits alongside.
    expect(() => JsonRows(big1.docId, 0, 1).execute(ctx), _closed);
    expect(await JsonRows(small.docId, 0, 1).execute(ctx), hasLength(1));
    expect(await JsonRows(big2.docId, 0, 1).execute(ctx), hasLength(1));

    // A single document above the budget is still allowed, alone.
    final huge = await open('huge', JsonBodySide.response);
    expect(huge.visibleCount, 4100000);
    expect([for (final d in openDocs()) d.nodeCount], [4100001]);
  });

  test('JsonSchema infers the schema of an array node', () async {
    await store.upsert(
      _call('c1', response: _body('{"l":[{"a":1},{"a":2,"b":"x"}],"n":1}')),
    );
    final h = await open('c1', JsonBodySide.response);
    final rows = await JsonRows(h.docId, 0, 2).execute(ctx);
    final schema = await JsonSchema(h.docId, rows[0].nodeId).execute(ctx);
    expect(schema!.describe(), '{a: number, b?: string}');
    expect(await JsonSchema(h.docId, rows[1].nodeId).execute(ctx), isNull);
  });

  test('handles, rows and schemas cross the isolate boundary', () async {
    final worker = await IsolateWorker.spawn(
      const ProxieConfig(persistHistory: false),
      MemoryStore.new,
    );
    addTearDown(worker.dispose);
    worker.upsert(_call('c1', response: _body('{"a":{"b":1}}')));
    final h = await worker.run(OpenJson('c1', JsonBodySide.response));
    final rows = await worker.run(JsonRows(h.docId, 0, 5));
    expect(rows.single.key, 'a');
    expect(await worker.run(JsonToggle(h.docId, rows.single.nodeId)), 2);
    final list = await worker.run(OpenJson('c1', JsonBodySide.request));
    final schema = await worker.run(JsonSchema(list.docId, 0));
    expect(schema, isNull); // {"q":[1,2,3]} root is an object
    await worker.run(CloseJson(h.docId));
    await expectLater(
      worker.run(JsonRows(h.docId, 0, 5)),
      throwsA(
        isA<ProxieWorkerException>().having(
          (e) => e.type,
          'type',
          'JsonDocumentClosed',
        ),
      ),
    );
  });
}
