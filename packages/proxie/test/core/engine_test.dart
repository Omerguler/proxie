import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

class _Sink implements CallSink {
  final calls = <ProxieCall>[];
  @override
  void upsert(ProxieCall call) => calls.add(call);
  ProxieCall get last => calls.last;
}

ProxieBody _json(String s) =>
    ProxieBody.from(Uint8List.fromList(utf8.encode(s)), 'application/json');

ProxieRequest _req({String method = 'GET', String path = '/x'}) =>
    ProxieRequest(
      method: method,
      url: Uri.parse('https://api.test$path'),
      headers: {
        'Authorization': ['Bearer real-token'],
      },
      body: ProxieBody.empty(),
    );

ProxieResponse _res(int code) => ProxieResponse(
  statusCode: code,
  headers: {
    'content-type': ['application/json'],
  },
  body: _json('{"ok":true}'),
);

ProxieRule _bp(BreakpointPhase phase) => ProxieRule(
  id: 'bp',
  name: 'bp',
  kind: RuleKind.breakpoint,
  matcher: UrlMatcher('api.test/*'),
  phase: phase,
);

void main() {
  late _Sink sink;
  late BreakpointController bps;
  late ProxieEngine engine;

  setUp(() {
    sink = _Sink();
    bps = BreakpointController();
    engine = ProxieEngine(
      config: const ProxieConfig(),
      sink: sink,
      breakpoints: bps,
    );
  });

  test('config defaults', () {
    const c = ProxieConfig();
    expect(c.spillThreshold, 256 * 1024);
    expect(c.renderCap, 5 * 1024 * 1024);
    expect(c.teeCap, 5 * 1024 * 1024);
    expect(c.rawEditableLimit, 1024 * 1024);
    expect(c.retentionCalls, 5000);
    expect(c.retentionAge, const Duration(days: 7));
    expect(c.breakpointTimeout, const Duration(seconds: 60));
    expect(c.splitWidth, 700);
    expect(c.persistHistory, isTrue);
  });

  test('newCallId is unique', () {
    expect({for (var i = 0; i < 100; i++) engine.newCallId()}, hasLength(100));
  });

  test('no rules: Proceed with same request, sink gets one call', () async {
    final req = _req();
    final d = await engine.onRequest('c1', 'http', req);
    expect(d, isA<Proceed>());
    expect((d as Proceed).request, same(req));
    expect(sink.calls, hasLength(1));
    expect(sink.last.adapter, 'http');
    expect(sink.last.tags, isEmpty);
  });

  test('map-local rule: Mock and tagged mapLocal', () async {
    final action = MapLocalAction(response: _res(404));
    engine.rules = RuleSet([
      ProxieRule(
        id: 'm',
        name: 'm',
        kind: RuleKind.mapLocal,
        matcher: UrlMatcher('api.test/*'),
        mapLocal: action,
      ),
    ]);
    final d = await engine.onRequest('c1', 'http', _req());
    expect((d as Mock).action, same(action));
    expect(sink.last.tags, contains(CallTag.mapLocal));
  });

  test(
    'request breakpoint + ExecuteRequest(edited): Proceed(edited)',
    () async {
      engine.rules = RuleSet([_bp(BreakpointPhase.request)]);
      final f = engine.onRequest('c1', 'http', _req());
      await Future<void>.delayed(Duration.zero);
      expect(bps.pending.single.callId, 'c1');
      final edited = _req(method: 'POST');
      bps.resolve('c1', ExecuteRequest(edited));
      final d = await f;
      expect((d as Proceed).request, same(edited));
      expect(sink.last.tags, containsAll([CallTag.breakpoint, CallTag.edited]));
    },
  );

  test('ExecuteRequest identical to original is not tagged edited', () async {
    engine.rules = RuleSet([_bp(BreakpointPhase.request)]);
    final f = engine.onRequest('c1', 'http', _req());
    await Future<void>.delayed(Duration.zero);
    bps.resolve('c1', ExecuteRequest(_req()));
    await f;
    expect(sink.last.tags, contains(CallTag.breakpoint));
    expect(sink.last.tags, isNot(contains(CallTag.edited)));
  });

  test('Abort resolution yields AbortRequest', () async {
    engine.rules = RuleSet([_bp(BreakpointPhase.request)]);
    final f = engine.onRequest('c1', 'http', _req());
    await Future<void>.delayed(Duration.zero);
    bps.resolve('c1', const Abort());
    expect(await f, isA<AbortRequest>());
    expect(sink.last.error, isNotNull);
  });

  test('response breakpoint edit 200 -> 500', () async {
    engine.rules = RuleSet([_bp(BreakpointPhase.response)]);
    await engine.onRequest('c1', 'http', _req());
    final f = engine.onResponse('c1', _res(200));
    await Future<void>.delayed(Duration.zero);
    bps.resolve('c1', ExecuteResponse(_res(500)));
    final out = await f;
    expect(out.statusCode, 500);
    expect(sink.last.response!.statusCode, 500);
    expect(sink.last.tags, containsAll([CallTag.breakpoint, CallTag.edited]));
    expect(sink.last.duration, isNotNull);
  });

  test('masked copy to sink, real token to adapter', () async {
    final d = await engine.onRequest('c1', 'http', _req());
    expect(sink.last.request.headers['authorization'], [kMask]);
    expect((d as Proceed).request.headers['authorization'], [
      'Bearer real-token',
    ]);
  });

  test('onResponse works for mocked calls and calls stream emits', () async {
    final seen = <ProxieCall>[];
    engine.calls.listen(seen.add);
    await engine.onRequest('c1', 'http', _req());
    await engine.onResponse('c1', _res(200));
    await Future<void>.delayed(Duration.zero);
    expect(seen.map((c) => c.response?.statusCode), [null, 200]);
  });

  test('onError records error and clears state', () async {
    await engine.onRequest('c1', 'http', _req());
    engine.onError('c1', const ProxieError(type: 'x', message: 'boom'));
    expect(sink.last.error!.message, 'boom');
    // state removed: a late response is passed through untouched
    final r = _res(200);
    expect(await engine.onResponse('c1', r), same(r));
  });

  test('sessionId is stamped on calls', () async {
    engine.sessionId = 7;
    await engine.onRequest('c1', 'http', _req());
    expect(sink.last.sessionId, 7);
  });
}
