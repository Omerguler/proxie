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

void main() {
  late MemoryStore store;
  late WorkerContext ctx;

  setUp(() {
    store = MemoryStore();
    ctx = WorkerContext(store: store, config: const ProxieConfig());
  });

  Future<JsonHandle> open(String id, String which) =>
      OpenJson(id, which).execute(ctx);

  test('open, page, toggle and close a request body', () async {
    await store.upsert(_call('c1', response: _body('{"ok":true}')));
    final h = await open('c1', 'request');
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
    expect(() => JsonRows(h.docId, 0, 1).execute(ctx), throwsStateError);
    // Closing twice is harmless.
    await CloseJson(h.docId).execute(ctx);
  });

  test('response bodies open independently of the request', () async {
    await store.upsert(_call('c1', response: _body('[1,2]')));
    final req = await open('c1', 'request');
    final res = await open('c1', 'response');
    expect(req.docId, isNot(res.docId));
    expect(res.visibleCount, 2);
  });

  test('missing calls, responses and docs throw StateError', () async {
    await store.upsert(_call('c1'));
    expect(() => open('nope', 'request'), throwsStateError);
    expect(() => open('c1', 'response'), throwsStateError);
    expect(() => open('c1', 'body'), throwsArgumentError);
    expect(() => JsonRows('x', 0, 1).execute(ctx), throwsStateError);
    expect(() => JsonToggle('x', 0).execute(ctx), throwsStateError);
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
    final bad = await open('c1', 'request');
    expect(bad.parseError, isNotNull);
    expect(bad.visibleCount, 0);
    expect(await JsonRows(bad.docId, 0, 10).execute(ctx), isEmpty);
    final good = await open('c1', 'response');
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
    final cut = await open('c1', 'request');
    expect(cut.truncated, isTrue);
    expect(
      cut.parseError,
      'Body was truncated at capture; full JSON unavailable',
    );
    final ok = await open('c1', 'response');
    expect(ok.truncated, isTrue);
    expect(ok.parseError, isNull);
    expect(ok.visibleCount, 1);
  });

  test(
    'at most 8 documents stay open; least recently used goes first',
    () async {
      await store.upsert(_call('c1'));
      final handles = [for (var i = 0; i < 8; i++) await open('c1', 'request')];
      // Touch the oldest so the second-oldest becomes the eviction victim.
      await JsonRows(handles[0].docId, 0, 1).execute(ctx);
      await open('c1', 'request');
      expect(await JsonRows(handles[0].docId, 0, 1).execute(ctx), hasLength(1));
      expect(
        () => JsonRows(handles[1].docId, 0, 1).execute(ctx),
        throwsStateError,
      );
      expect(
        ctx.resources.keys.where((k) => ctx.resources[k] is JsonDocument),
        hasLength(8),
      );
    },
  );

  test('JsonSchema infers the schema of an array node', () async {
    await store.upsert(
      _call('c1', response: _body('{"l":[{"a":1},{"a":2,"b":"x"}],"n":1}')),
    );
    final h = await open('c1', 'response');
    final rows = await JsonRows(h.docId, 0, 2).execute(ctx);
    final schema = await JsonSchema(h.docId, rows[0].nodeId).execute(ctx);
    expect(schema!.describe(), '{a: number, b?: string}');
    expect(await JsonSchema(h.docId, rows[1].nodeId).execute(ctx), isNull);
    expect(() => JsonSchema('x', 0).execute(ctx), throwsStateError);
  });

  test('handles, rows and schemas cross the isolate boundary', () async {
    final worker = await IsolateWorker.spawn(
      const ProxieConfig(persistHistory: false),
      MemoryStore.new,
    );
    addTearDown(worker.dispose);
    worker.upsert(_call('c1', response: _body('{"a":{"b":1}}')));
    final h = await worker.run(OpenJson('c1', 'response'));
    final rows = await worker.run(JsonRows(h.docId, 0, 5));
    expect(rows.single.key, 'a');
    expect(await worker.run(JsonToggle(h.docId, rows.single.nodeId)), 2);
    final list = await worker.run(OpenJson('c1', 'request'));
    final schema = await worker.run(JsonSchema(list.docId, 0));
    expect(schema, isNull); // {"q":[1,2,3]} root is an object
    await worker.run(CloseJson(h.docId));
    await expectLater(
      worker.run(JsonRows(h.docId, 0, 5)),
      throwsA(isA<ProxieWorkerException>()),
    );
  });
}
