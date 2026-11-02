import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/ui/json/text_lines.dart';
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

final Matcher _closed = throwsA(isA<JsonDocumentClosed>());

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
    expect(() => const JsonRows('x', 0, 1).execute(ctx), _closed);
    expect(() => const JsonToggle('x', 0).execute(ctx), _closed);
    expect(() => const JsonSchema('x', 0).execute(ctx), _closed);
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

  test('JsonApply edits; JsonEncode returns untouched bodies as is', () async {
    const src = '{ "a" : 1.0,\n  "b": [1, 2] }';
    await store.upsert(_call('c1', response: _body(src)));
    final h = await open('c1', JsonBodySide.response);
    final untouched = await JsonEncode(h.docId).execute(ctx);
    expect(utf8.decode(untouched), src);
    expect(
      utf8.decode(await JsonEncode(h.docId, pretty: true).execute(ctx)),
      '{\n  "a": 1.0,\n  "b": [\n    1,\n    2\n  ]\n}',
    );
    final b = (await JsonRows(h.docId, 1, 1).execute(ctx)).single;
    expect(await JsonApply(h.docId, AddItem(b.nodeId, 3)).execute(ctx), 2);
    expect(
      utf8.decode(await JsonEncode(h.docId).execute(ctx)),
      '{"a":1.0,"b":[1,2,3]}',
    );
    // The stored body is not touched by edits.
    expect(utf8.decode((await store.get('c1'))!.response!.body.bytes), src);
    expect(() => const JsonApply('x', DeleteNode(1)).execute(ctx), _closed);
    expect(() => const JsonEncode('x').execute(ctx), _closed);
  });

  test('JsonApply and JsonEncode on an unparsed body throw', () async {
    await store.upsert(_call('c1', response: _body('{"a":')));
    final h = await open('c1', JsonBodySide.response);
    expect(
      () => JsonApply(h.docId, const SetValue(0, 1)).execute(ctx),
      throwsStateError,
    );
    expect(() => JsonEncode(h.docId).execute(ctx), throwsStateError);
  });

  test('unparsed bodies are not kept; reopening parses again', () async {
    await store.upsert(_call('c1', response: _body('{"a":')));
    final a = await open('c1', JsonBodySide.response);
    final b = await open('c1', JsonBodySide.response);
    expect(b.docId, isNot(a.docId));
    expect(b.parseError, a.parseError);
    expect(() => JsonRows(a.docId, 0, 1).execute(ctx), _closed);
    expect(openDocs(), hasLength(1));
  });

  test('an edit growing one document past the budget is rejected', () async {
    await store.upsert(_call('c1', response: _body('[1,2,3]')));
    final h = await open('c1', JsonBodySide.response);
    final doc = ctx.resources['json:${h.docId}']! as JsonDocument;
    expect(doc.maxCapacity, maxOpenJsonNodes);
    doc.maxCapacity = 10; // a small injected budget
    await expectLater(
      JsonApply(h.docId, AddItem(0, List.filled(20, 0))).execute(ctx),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Document too large to edit further',
        ),
      ),
    );
    expect(utf8.decode(await JsonEncode(h.docId).execute(ctx)), '[1,2,3]');
    expect(await JsonApply(h.docId, const DeleteNode(1)).execute(ctx), 2);
  });

  test('nodes added by edits count towards the budget', () async {
    await store.upsert(_call('big', response: _zeros(2500000)));
    await store.upsert(_call('small', response: _body('[1]')));
    final big = await open('big', JsonBodySide.response);
    final small = await open('small', JsonBodySide.response);
    final count = await JsonApply(
      small.docId,
      AddItem(0, List.filled(1600000, 0)),
    ).execute(ctx);
    expect(count, 2);
    // big was least recently used and had to go; small stays.
    expect(() => JsonRows(big.docId, 0, 1).execute(ctx), _closed);
    expect(await JsonRows(small.docId, 0, 1).execute(ctx), hasLength(1));
    // Closing releases what was charged: two 2M-node docs fit again.
    await CloseJson(small.docId).execute(ctx);
    await store.upsert(_call('a', response: _zeros(2000000)));
    await store.upsert(_call('b', response: _zeros(1999998)));
    final a = await open('a', JsonBodySide.response);
    await open('b', JsonBodySide.response);
    expect(await JsonRows(a.docId, 0, 1).execute(ctx), hasLength(1));
  });

  test('edits cross the isolate boundary', () async {
    final worker = await IsolateWorker.spawn(
      const ProxieConfig(persistHistory: false),
      MemoryStore.new,
    );
    addTearDown(worker.dispose);
    worker.upsert(
      _call('c1', response: _body('{"l":[{"id":1,"x":"a"},{"id":2}],"k":0}')),
    );
    final h = await worker.run(const OpenJson('c1', JsonBodySide.response));
    Future<int> apply(JsonEdit e) => worker.run(JsonApply(h.docId, e));
    final top = await worker.run(JsonRows(h.docId, 0, 2));
    final l = top[0].nodeId;
    final k = top[1].nodeId;
    await worker.run(JsonToggle(h.docId, l));
    final items = await worker.run(JsonRows(h.docId, 1, 2));
    await apply(AddMissingKey(items[1].nodeId, 'x'));
    await apply(DuplicateItem(items[0].nodeId));
    await apply(AddKeyToAll(l, 'tags', ['t', 1, null, true]));
    await apply(RemoveKeyFromAll(l, 'id'));
    await apply(NewItemFromSchema(l));
    await apply(AddItem(l, {'n': const JsonNumber('1e400')}, at: 0));
    await apply(
      SetValue(k, {
        'deep': <Object?>[{}, 2.5],
      }),
    );
    await apply(const AddKey(0, 'z', 'zz'));
    await apply(RenameKey(k, 'kk'));
    const item = '{"x":"a","tags":["t",1,null,true]}';
    expect(
      utf8.decode(await worker.run(JsonEncode(h.docId))),
      '{"l":[{"n":1e400},$item,$item,$item,{"x":"","tags":[]}],'
      '"kk":{"deep":[{},2.5]},"z":"zz"}',
    );
    final count = await apply(DeleteNode(l));
    expect(count, 2);
    expect(
      utf8.decode(await worker.run(JsonEncode(h.docId))),
      '{"kk":{"deep":[{},2.5]},"z":"zz"}',
    );
    await apply(const SetValue(0, [1]));
    expect(utf8.decode(await worker.run(JsonEncode(h.docId))), '[1]');
    await expectLater(
      apply(const RenameKey(0, 'x')),
      throwsA(
        isA<ProxieWorkerException>().having(
          (e) => e.type,
          'type',
          'ArgumentError',
        ),
      ),
    );
  });

  test('handles, rows and schemas cross the isolate boundary', () async {
    final worker = await IsolateWorker.spawn(
      const ProxieConfig(persistHistory: false),
      MemoryStore.new,
    );
    addTearDown(worker.dispose);
    worker.upsert(_call('c1', response: _body('{"a":{"b":1}}')));
    final h = await worker.run(const OpenJson('c1', JsonBodySide.response));
    final rows = await worker.run(JsonRows(h.docId, 0, 5));
    expect(rows.single.key, 'a');
    expect(await worker.run(JsonToggle(h.docId, rows.single.nodeId)), 2);
    final list = await worker.run(const OpenJson('c1', JsonBodySide.request));
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

  test('visible count and whole scalar text', () async {
    // A JSON escape, so the string is decoded from its source text.
    final long = 'é\\n${'x' * 300}';
    await store.upsert(
      _call(
        'c1',
        response: _body(
          '{"list":[{"s":"$long","n":12345678901234567890,"b":false,'
          '"z":null}]}',
        ),
      ),
    );
    final h = await open('c1', JsonBodySide.response);
    expect(await JsonVisibleCount(h.docId).execute(ctx), 1);
    // Nodes: root 0, list 1, item 2, then s 3, n 4, b 5, z 6.
    expect(await JsonReveal(h.docId, 3).execute(ctx), 2);
    expect(await JsonVisibleCount(h.docId).execute(ctx), 6);
    Future<String> text(int id) => JsonScalarText(h.docId, id).execute(ctx);
    expect(await text(3), 'é\n${'x' * 300}');
    expect(await text(4), '12345678901234567890');
    expect(await text(5), 'false');
    expect(await text(6), 'null');
    await expectLater(text(2), throwsArgumentError);
    await JsonApply(h.docId, const SetValue(3, 'new')).execute(ctx);
    await JsonApply(
      h.docId,
      const SetValue(4, JsonNumber('1e400')),
    ).execute(ctx);
    expect(await text(3), 'new');
    expect(await text(4), '1e400');
  });

  test('documents are kept per scope; a reopen reports dirty', () async {
    await store.upsert(_call('c1', response: _body('[1]')));
    final view = await open('c1', JsonBodySide.response);
    final edit = await const OpenJson(
      'c1',
      JsonBodySide.response,
      scope: 'edit:rule',
    ).execute(ctx);
    expect(edit.docId, isNot(view.docId));
    await JsonApply(edit.docId, const DuplicateItem(1)).execute(ctx);
    final viewAgain = await open('c1', JsonBodySide.response);
    expect(viewAgain.docId, view.docId);
    expect(viewAgain.dirty, isFalse);
    expect(viewAgain.visibleCount, 1);
    final editAgain = await const OpenJson(
      'c1',
      JsonBodySide.response,
      scope: 'edit:rule',
    ).execute(ctx);
    expect(editAgain.docId, edit.docId);
    expect(editAgain.dirty, isTrue);
    expect(editAgain.visibleCount, 2);
  });

  test('root row and value of a document', () async {
    await store.upsert(
      _call('c1', response: _body('{"n":12345678901234567890,"l":[true]}')),
    );
    final h = await open('c1', JsonBodySide.response);
    final root = await JsonRootRow(h.docId).execute(ctx);
    expect(root!.nodeId, 0);
    expect(root.kind, JsonKind.object);
    expect(root.preview, '{2 keys}');
    final doc = openDocs().single;
    expect(doc.valueOf(0), {
      'n': const JsonNumber('12345678901234567890'),
      'l': [true],
    });
  });

  test('raw text lines cross the isolate boundary', () async {
    final worker = await IsolateWorker.spawn(
      const ProxieConfig(persistHistory: false),
      MemoryStore.new,
    );
    addTearDown(worker.dispose);
    final lines = await worker.run(
      RawTextLines(Uint8List.fromList(utf8.encode('[1]')), prettyJson: true),
    );
    expect(lines, ['[\n', '  1\n', ']']);
  });
}
