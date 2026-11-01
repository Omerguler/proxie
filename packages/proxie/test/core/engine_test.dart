import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
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

  test(
    'sink gets real data; stream copy has masked headers, empty body',
    () async {
      final seen = <ProxieCall>[];
      engine.calls.listen(seen.add);
      final d = await engine.onRequest('c1', 'http', _req());
      await Future<void>.delayed(Duration.zero);
      expect(sink.last.request.headers['authorization'], ['Bearer real-token']);
      expect((d as Proceed).request.headers['authorization'], [
        'Bearer real-token',
      ]);
      expect(seen.single.request.headers['authorization'], [kMask]);
      final r = _req().copyWith(body: _json('{"password":"p"}'));
      await engine.onRequest('c2', 'http', r);
      await Future<void>.delayed(Duration.zero);
      expect(seen.last.request.body.bytes, isEmpty);
      expect(seen.last.request.body.kind, BodyKind.json);
      expect(seen.last.request.body.originalLength, r.body.bytes.length);
    },
  );

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

  test('onError while paused clears pause and keeps the error row', () async {
    engine.rules = RuleSet([_bp(BreakpointPhase.request)]);
    final f = engine.onRequest('c1', 'http', _req());
    await Future<void>.delayed(Duration.zero);
    engine.onError('c1', const ProxieError(type: 'x', message: 'cancel'));
    await f;
    expect(bps.pending, isEmpty);
    expect(sink.last.error!.message, 'cancel');
    final n = sink.calls.length;
    await Future<void>.delayed(Duration.zero);
    expect(sink.calls.length, n);
  });

  test('onError while paused in response phase', () async {
    engine.rules = RuleSet([_bp(BreakpointPhase.response)]);
    await engine.onRequest('c1', 'http', _req());
    final f = engine.onResponse('c1', _res(200));
    await Future<void>.delayed(Duration.zero);
    engine.onError('c1', const ProxieError(type: 'x', message: 'cancel'));
    await f;
    expect(bps.pending, isEmpty);
    expect(sink.last.error!.message, 'cancel');
    expect(sink.last.response, isNull);
  });

  test('throwing sink does not break live traffic', () async {
    final e = ProxieEngine(config: const ProxieConfig(), sink: _ThrowingSink());
    final d = await e.onRequest('c1', 'http', _req());
    expect(d, isA<Proceed>());
    final r = _res(200);
    expect(await e.onResponse('c1', r), same(r));
    e.dispose();
  });

  test('throwing rule lookup is treated as no match', () async {
    engine.rules = _ThrowingRules();
    expect(await engine.onRequest('c1', 'http', _req()), isA<Proceed>());
  });

  test('repeated callId resolves the earlier pause', () async {
    engine.rules = RuleSet([_bp(BreakpointPhase.request)]);
    final f1 = engine.onRequest('c1', 'http', _req());
    await Future<void>.delayed(Duration.zero);
    final f2 = engine.onRequest('c1', 'http', _req());
    await Future<void>.delayed(Duration.zero);
    expect(await f1, isA<Proceed>());
    expect(bps.pending, hasLength(1));
    bps.resolve('c1', const ContinueUnchanged());
    await f2;
  });

  test('response-phase Abort throws and records the error', () async {
    engine.rules = RuleSet([_bp(BreakpointPhase.response)]);
    await engine.onRequest('c1', 'http', _req());
    final f = engine.onResponse('c1', _res(200));
    final expectation = expectLater(f, throwsA(isA<ProxieAbortedException>()));
    await Future<void>.delayed(Duration.zero);
    bps.resolve('c1', const Abort());
    await expectation;
    expect(sink.last.error!.message, 'Aborted at response breakpoint');
  });

  test('phase-mismatched resolution asserts', () async {
    engine.rules = RuleSet([_bp(BreakpointPhase.request)]);
    final f = engine.onRequest('c1', 'http', _req());
    final expectation = expectLater(f, throwsA(isA<AssertionError>()));
    await Future<void>.delayed(Duration.zero);
    bps.resolve('c1', ExecuteResponse(_res(200)));
    await expectation;
  });

  test('default controller honors config timeout', () {
    fakeAsync((async) {
      final e = ProxieEngine(
        config: const ProxieConfig(breakpointTimeout: Duration(seconds: 5)),
        sink: sink,
      );
      e.rules = RuleSet([_bp(BreakpointPhase.request)]);
      RequestDecision? d;
      e.onRequest('c1', 'http', _req()).then((v) => d = v);
      async.elapse(const Duration(seconds: 4));
      expect(d, isNull);
      async.elapse(const Duration(seconds: 1));
      expect(d, isA<Proceed>());
      e.dispose();
    });
  });

  test('dispose resolves pending and closes streams', () async {
    final e = ProxieEngine(config: const ProxieConfig(), sink: sink);
    e.rules = RuleSet([_bp(BreakpointPhase.request)]);
    final f = e.onRequest('c1', 'http', _req());
    await Future<void>.delayed(Duration.zero);
    final done = e.calls.isEmpty;
    e.dispose();
    expect(await f, isA<Proceed>());
    expect(e.breakpoints.pending, isEmpty);
    expect(await done, isTrue);
  });

  test(
    'onRequest/onResponse after dispose pass through with no state',
    () async {
      final e = ProxieEngine(config: const ProxieConfig(), sink: sink);
      e.rules = RuleSet([
        _bp(BreakpointPhase.both),
        ProxieRule(
          id: 'm',
          name: 'm',
          kind: RuleKind.mapLocal,
          matcher: UrlMatcher('api.test/*'),
          mapLocal: const MapLocalAction(failure: SimulatedFailure.timeout),
        ),
      ]);
      e.dispose();
      final req = _req();
      final d = await e.onRequest('c1', 'http', req);
      expect(d, isA<Proceed>());
      expect((d as Proceed).request, same(req));
      final res = _res(200);
      expect(await e.onResponse('c1', res), same(res));
      expect(e.breakpoints.pending, isEmpty);
      expect(sink.calls, isEmpty);
    },
  );

  test('three concurrent pauses all time out after 60 s', () {
    fakeAsync((async) {
      final e = ProxieEngine(config: const ProxieConfig(), sink: sink);
      e.rules = RuleSet([_bp(BreakpointPhase.request)]);
      final ds = <RequestDecision>[];
      for (final id in ['a', 'b', 'c']) {
        e.onRequest(id, 'http', _req()).then(ds.add);
      }
      async.flushMicrotasks();
      expect(e.breakpoints.pending.map((p) => p.callId), ['a', 'b', 'c']);
      async.elapse(const Duration(seconds: 60));
      expect(ds, hasLength(3));
      expect(e.breakpoints.pending, isEmpty);
      e.dispose();
    });
  });

  test('map-local is evaluated on the edited request', () async {
    engine.rules = RuleSet([
      _bp(BreakpointPhase.request),
      ProxieRule(
        id: 'm',
        name: 'm',
        kind: RuleKind.mapLocal,
        matcher: UrlMatcher('api.test/other'),
        mapLocal: MapLocalAction(response: _res(404)),
      ),
    ]);
    final f = engine.onRequest('c1', 'http', _req());
    await Future<void>.delayed(Duration.zero);
    bps.resolve('c1', ExecuteRequest(_req(path: '/other')));
    expect(await f, isA<Mock>());
  });

  test('mock goes through a response breakpoint', () async {
    engine.rules = RuleSet([
      _bp(BreakpointPhase.response),
      ProxieRule(
        id: 'm',
        name: 'm',
        kind: RuleKind.mapLocal,
        matcher: UrlMatcher('api.test/*'),
        mapLocal: MapLocalAction(response: _res(404)),
      ),
    ]);
    expect(await engine.onRequest('c1', 'http', _req()), isA<Mock>());
    final f = engine.onResponse('c1', _res(404));
    await Future<void>.delayed(Duration.zero);
    expect(bps.pending.single.phase, BreakpointPhase.response);
    bps.resolve('c1', ExecuteResponse(_res(418)));
    expect((await f).statusCode, 418);
    expect(sink.last.tags, containsAll([CallTag.mapLocal, CallTag.breakpoint]));
  });

  test('truncated tag set for truncated response body', () async {
    await engine.onRequest('c1', 'http', _req());
    final big = ProxieBody.from(
      Uint8List(20),
      'application/octet-stream',
      cap: 10,
    );
    await engine.onResponse(
      'c1',
      ProxieResponse(statusCode: 200, headers: {}, body: big),
    );
    expect(sink.last.tags, contains(CallTag.truncated));
  });

  test('throwing sink still emits on the calls stream', () async {
    final e = ProxieEngine(config: const ProxieConfig(), sink: _ThrowingSink());
    final seen = <ProxieCall>[];
    e.calls.listen(seen.add);
    await e.onRequest('c1', 'http', _req());
    await Future<void>.delayed(Duration.zero);
    expect(seen, hasLength(1));
    e.dispose();
  });

  test(
    'dispose with injected controller resolves this engine pauses',
    () async {
      engine.rules = RuleSet([_bp(BreakpointPhase.request)]);
      final f = engine.onRequest('c1', 'http', _req());
      await Future<void>.delayed(Duration.zero);
      expect(bps.pending, hasLength(1));
      final n = sink.calls.length;
      engine.dispose();
      expect(await f, isA<Proceed>());
      expect(bps.pending, isEmpty);
      expect(sink.calls.length, n);
    },
  );

  test(
    'response-phase Abort keeps the response in the recorded call',
    () async {
      engine.rules = RuleSet([_bp(BreakpointPhase.response)]);
      await engine.onRequest('c1', 'http', _req());
      final f = engine.onResponse('c1', _res(200));
      final expectation = expectLater(
        f,
        throwsA(isA<ProxieAbortedException>()),
      );
      await Future<void>.delayed(Duration.zero);
      bps.resolve('c1', const Abort());
      await expectation;
      expect(sink.last.error, isNotNull);
      expect(sink.last.response!.statusCode, 200);
    },
  );
}

class _ThrowingSink implements CallSink {
  @override
  void upsert(ProxieCall call) => throw StateError('disk full');
}

class _ThrowingRules extends RuleSet {
  _ThrowingRules() : super(const []);
  @override
  ProxieRule? requestBreakpointFor(ProxieRequest request) =>
      throw StateError('bad');
  @override
  ProxieRule? mapLocalFor(ProxieRequest request) => throw StateError('bad');
}
