import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:proxie/proxie.dart';

import '../support/test_server.dart';

class _Sink implements CallSink {
  final calls = <ProxieCall>[];
  @override
  void upsert(ProxieCall call) => calls.add(call);

  /// The latest snapshot of each call, in first-seen order.
  List<ProxieCall> get latest {
    final byId = <String, ProxieCall>{};
    for (final c in calls) {
      byId[c.id] = c;
    }
    return byId.values.toList();
  }

  ProxieCall get last => calls.last;
}

/// An inner client whose responses come from [handler].
class _FakeClient extends http.BaseClient {
  _FakeClient(this.handler);

  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final sent = <http.BaseRequest>[];
  final capturedZone = <bool>[];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent.add(request);
    capturedZone.add(isProxieCaptured());
    return handler(request);
  }

  @override
  void close() => closed = true;
}

ProxieRule _mapLocal(String pattern, MapLocalAction action) => ProxieRule(
  id: 'ml',
  name: 'ml',
  kind: RuleKind.mapLocal,
  matcher: UrlMatcher(pattern),
  mapLocal: action,
);

ProxieRule _bp(String pattern, BreakpointPhase phase) => ProxieRule(
  id: 'bp',
  name: 'bp',
  kind: RuleKind.breakpoint,
  matcher: UrlMatcher(pattern),
  phase: phase,
);

ProxieResponse _jsonRes(int status, String body) => ProxieResponse(
  statusCode: status,
  headers: {
    'content-type': ['application/json'],
  },
  body: ProxieBody.from(
    Uint8List.fromList(utf8.encode(body)),
    'application/json',
  ),
);

/// Resolves the next paused call in [phase] with [resolve].
void _onPause(
  ProxieEngine engine,
  BreakpointPhase phase,
  BreakpointResolution Function(PausedCall) resolve,
) {
  late StreamSubscription<List<PausedCall>> sub;
  sub = engine.breakpoints.changes.listen((pending) {
    for (final p in pending) {
      if (p.phase == phase) {
        unawaited(sub.cancel());
        engine.breakpoints.resolve(p.callId, resolve(p));
        return;
      }
    }
  });
}

void main() {
  late TestServer server;
  late _Sink sink;
  late ProxieEngine engine;
  late ProxieHttpClient client;

  ProxieEngine makeEngine({ProxieConfig config = const ProxieConfig()}) =>
      ProxieEngine(
        config: config,
        sink: sink,
        breakpoints: BreakpointController(timeout: const Duration(seconds: 5)),
      );

  setUp(() async {
    server = await startTestServer();
    sink = _Sink();
    engine = makeEngine();
    client = ProxieHttpClient()..attach(engine);
  });

  tearDown(() async {
    client.close();
    engine.dispose();
    await server.close();
  });

  test('name and replay support', () {
    expect(client.name, 'http');
    expect(client.supportsReplay, isTrue);
    expect(client, isA<ProxieCaptureAdapter>());
  });

  test('GET /json: app gets body, sink records 200', () async {
    final res = await client.get(server.url('/json'));
    expect(res.statusCode, 200);
    expect(jsonDecode(res.body), {'hello': 'world'});
    await pumpEventQueue();
    final call = sink.last;
    expect(sink.latest, hasLength(1));
    expect(call.adapter, 'http');
    expect(call.request.method, 'GET');
    expect(call.request.url, server.url('/json'));
    expect(call.response!.statusCode, 200);
    expect(call.response!.body.text, '{"hello":"world"}');
    expect(call.response!.body.kind, BodyKind.json);
    expect(call.response!.body.truncated, isFalse);
    expect(call.duration, isNotNull);
    expect(call.error, isNull);
  });

  test('POST /echo: request body captured and delivered', () async {
    final res = await client.post(
      server.url('/echo'),
      headers: {'Content-Type': 'text/plain', 'X-Custom': 'v'},
      body: 'hello proxie',
    );
    final echo = jsonDecode(res.body) as Map;
    expect(echo['method'], 'POST');
    expect(echo['body'], 'hello proxie');
    expect((echo['headers'] as Map)['x-custom'], 'v');
    await pumpEventQueue();
    final call = sink.last;
    expect(call.request.method, 'POST');
    expect(call.request.body.text, 'hello proxie');
    expect(call.request.headers['x-custom'], ['v']);
    expect(
      call.request.headers['content-type']!.single,
      startsWith('text/plain'),
    );
    expect(call.response!.statusCode, 200);
  });

  test(
    'request body larger than teeCap is sent in full, stored capped',
    () async {
      engine.dispose();
      engine = makeEngine(config: const ProxieConfig(teeCap: 10));
      client.attach(engine);
      final payload = 'x' * 100;
      final res = await client.post(server.url('/echo'), body: payload);
      expect((jsonDecode(res.body) as Map)['body'], payload);
      await pumpEventQueue();
      final body = sink.last.request.body;
      expect(body.truncated, isTrue);
      expect(body.bytes, hasLength(10));
      expect(body.originalLength, 100);
    },
  );

  test('map-local mock: app gets 404, server not hit', () async {
    engine.rules = RuleSet([
      _mapLocal('*/json', MapLocalAction(response: _jsonRes(404, '{"m":1}'))),
    ]);
    final res = await client.get(server.url('/json'));
    expect(res.statusCode, 404);
    expect(res.body, '{"m":1}');
    expect(res.headers['content-type'], 'application/json');
    expect(server.hitsFor('/json'), 0);
    await pumpEventQueue();
    final call = sink.last;
    expect(call.response!.statusCode, 404);
    expect(call.tags, contains(CallTag.mapLocal));
  });

  test('map-local delay is honoured', () async {
    engine.rules = RuleSet([
      _mapLocal(
        '*/json',
        MapLocalAction(
          response: _jsonRes(200, '{}'),
          delay: const Duration(milliseconds: 150),
        ),
      ),
    ]);
    final sw = Stopwatch()..start();
    final res = await client.get(server.url('/json'));
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(140));
    expect(res.statusCode, 200);
  });

  test('map-local timeout failure throws TimeoutException', () async {
    engine.rules = RuleSet([
      _mapLocal(
        '*/json',
        const MapLocalAction(failure: SimulatedFailure.timeout),
      ),
    ]);
    await expectLater(
      client.get(server.url('/json')),
      throwsA(isA<TimeoutException>()),
    );
    expect(server.hitsFor('/json'), 0);
    expect(sink.last.error!.type, 'timeout');
  });

  test('map-local noConnection failure throws ClientException', () async {
    engine.rules = RuleSet([
      _mapLocal(
        '*/json',
        const MapLocalAction(failure: SimulatedFailure.noConnection),
      ),
    ]);
    await expectLater(
      client.get(server.url('/json')),
      throwsA(
        isA<http.ClientException>()
            .having(
              (e) => e.message,
              'message',
              'Connection failed (simulated by Proxie)',
            )
            .having((e) => e.uri, 'uri', server.url('/json')),
      ),
    );
    expect(server.hitsFor('/json'), 0);
    expect(sink.last.error!.type, 'no_connection');
  });

  test('request breakpoint adding x-test header reaches the server', () async {
    engine.rules = RuleSet([_bp('*/echo', BreakpointPhase.request)]);
    _onPause(
      engine,
      BreakpointPhase.request,
      (p) => ExecuteRequest(
        p.request.copyWith(
          headers: {
            ...p.request.headers,
            'x-test': ['1'],
          },
        ),
      ),
    );
    final res = await client.post(server.url('/echo'), body: 'b');
    final echo = jsonDecode(res.body) as Map;
    expect((echo['headers'] as Map)['x-test'], '1');
    expect(echo['body'], 'b');
    await pumpEventQueue();
    expect(sink.last.tags, contains(CallTag.edited));
    expect(sink.last.request.headers['x-test'], ['1']);
  });

  test(
    'request breakpoint abort throws ClientException, server not hit',
    () async {
      engine.rules = RuleSet([_bp('*/json', BreakpointPhase.request)]);
      _onPause(engine, BreakpointPhase.request, (_) => const Abort());
      await expectLater(
        client.get(server.url('/json')),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            'Aborted at breakpoint',
          ),
        ),
      );
      expect(server.hitsFor('/json'), 0);
      expect(sink.last.error!.type, 'aborted');
    },
  );

  test('response breakpoint editing status is seen by the app', () async {
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.response)]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(p.response!.copyWith(statusCode: 500)),
    );
    final res = await client.get(server.url('/json'));
    expect(res.statusCode, 500);
    expect(res.body, '{"hello":"world"}');
    expect(res.contentLength, 17);
    expect(server.hitsFor('/json'), 1);
    await pumpEventQueue();
    expect(sink.last.response!.statusCode, 500);
    expect(sink.last.tags, contains(CallTag.edited));
  });

  test('response breakpoint editing the body updates content-length', () async {
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.response)]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(
        p.response!.copyWith(
          body: ProxieBody.from(
            Uint8List.fromList(utf8.encode('{"a":12345}')),
            'application/json',
          ),
        ),
      ),
    );
    final res = await client.get(server.url('/json'));
    expect(res.body, '{"a":12345}');
    expect(res.contentLength, 11);
    expect(res.headers['content-length'], '11');
  });

  test(
    'response breakpoint left unchanged delivers the full large body',
    () async {
      engine.dispose();
      engine = makeEngine(config: const ProxieConfig(teeCap: 1024));
      client.attach(engine);
      engine.rules = RuleSet([_bp('*/big*', BreakpointPhase.response)]);
      _onPause(
        engine,
        BreakpointPhase.response,
        (_) => const ContinueUnchanged(),
      );
      final res = await client.get(server.url('/big?mb=1'));
      expect(res.bodyBytes, hasLength(1024 * 1024));
      await pumpEventQueue();
      expect(sink.last.response!.body.truncated, isTrue);
      expect(sink.last.response!.body.originalLength, 1024 * 1024);
    },
  );

  test('response breakpoint abort throws ClientException', () async {
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.response)]);
    _onPause(engine, BreakpointPhase.response, (_) => const Abort());
    await expectLater(
      client.get(server.url('/json')),
      throwsA(
        isA<http.ClientException>().having(
          (e) => e.message,
          'message',
          'Aborted at response breakpoint',
        ),
      ),
    );
    expect(sink.last.error!.type, 'aborted');
  });

  test('response breakpoints apply to mocked responses', () async {
    engine.rules = RuleSet([
      _mapLocal('*/json', MapLocalAction(response: _jsonRes(404, '{}'))),
      _bp('*/json', BreakpointPhase.response),
    ]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(p.response!.copyWith(statusCode: 418)),
    );
    final res = await client.get(server.url('/json'));
    expect(res.statusCode, 418);
    expect(server.hitsFor('/json'), 0);
  });

  test(
    '6 MB response: app gets every byte, stored body capped at 5 MB',
    () async {
      final res = await client.get(server.url('/big?mb=6'));
      const total = 6 * 1024 * 1024;
      expect(res.bodyBytes, hasLength(total));
      expect(res.bodyBytes.every((b) => b == 0x61), isTrue);
      await pumpEventQueue();
      final body = sink.last.response!.body;
      expect(body.truncated, isTrue);
      expect(body.bytes, hasLength(5 * 1024 * 1024));
      expect(body.originalLength, total);
      expect(body.kind, BodyKind.text);
      expect(sink.last.tags, contains(CallTag.truncated));
    },
  );

  test(
    'replay re-sends through the inner client and is not recorded',
    () async {
      final res = await client.get(server.url('/echo'));
      expect(res.statusCode, 200);
      await pumpEventQueue();
      final recorded = sink.calls.length;
      final call = sink.last;
      final replayed = await client.replay(call.request);
      expect(server.hitsFor('/echo'), 2);
      expect(replayed.statusCode, 200);
      expect((jsonDecode(replayed.body.text!) as Map)['method'], 'GET');
      expect(sink.calls, hasLength(recorded));
    },
  );

  test('replay sends method, headers and body as captured', () async {
    final replayed = await client.replay(
      ProxieRequest(
        method: 'PUT',
        url: server.url('/echo'),
        headers: {
          'x-r': ['1'],
          'content-length': ['999'],
        },
        body: ProxieBody.from(Uint8List.fromList(utf8.encode('rb')), null),
      ),
    );
    final echo = jsonDecode(replayed.body.text!) as Map;
    expect(echo['method'], 'PUT');
    expect(echo['body'], 'rb');
    expect((echo['headers'] as Map)['x-r'], '1');
  });

  test('unattached and detached: pure pass-through to inner', () async {
    final inner = _FakeClient(
      (_) async => http.StreamedResponse(Stream.value([1, 2, 3]), 200),
    );
    final c = ProxieHttpClient(inner: inner);
    final req = http.Request('GET', server.url('/json'));
    final res = await c.send(req);
    expect(inner.sent.single, same(req));
    expect(inner.capturedZone.single, isFalse);
    expect(await res.stream.toBytes(), [1, 2, 3]);

    c
      ..attach(engine)
      ..detach();
    final req2 = http.Request('GET', server.url('/json'));
    final res2 = await c.send(req2);
    expect(inner.sent.last, same(req2));
    await res2.stream.toBytes();
    expect(sink.calls, isEmpty);
    c.close();
    expect(inner.closed, isTrue);
  });

  test('inner send runs marked captured, request options copied', () async {
    final inner = _FakeClient(
      (_) async => http.StreamedResponse(const Stream.empty(), 204),
    );
    final c = ProxieHttpClient(inner: inner)..attach(engine);
    expect(isProxieCaptured(), isFalse);
    final req = http.Request('PATCH', server.url('/x'))
      ..followRedirects = false
      ..maxRedirects = 2
      ..persistentConnection = false
      ..headers['X-Name'] = 'Value'
      ..body = 'abc';
    final res = await c.send(req);
    await res.stream.toBytes();
    expect(inner.capturedZone.single, isTrue);
    final sent = inner.sent.single as http.Request;
    expect(sent, isNot(same(req)));
    expect(sent.method, 'PATCH');
    expect(sent.followRedirects, isFalse);
    expect(sent.maxRedirects, 2);
    expect(sent.persistentConnection, isFalse);
    expect(sent.headers['X-Name'], 'Value');
    expect(sent.body, 'abc');
    expect(res.request, same(req));
  });

  test('runMarkedCaptured marks the zone', () {
    expect(isProxieCaptured(), isFalse);
    expect(runMarkedCaptured(isProxieCaptured), isTrue);
    expect(runMarkedCaptured(() => 7), 7);
    expect(kProxieCapturedZoneKey, #proxie.captured);
  });

  test('inner send failure records a network error and rethrows', () async {
    final inner = _FakeClient(
      (r) async => throw http.ClientException('refused', r.url),
    );
    final c = ProxieHttpClient(inner: inner)..attach(engine);
    await expectLater(
      c.get(server.url('/json')),
      throwsA(isA<http.ClientException>()),
    );
    expect(sink.last.error!.type, 'network');
    expect(sink.last.error!.message, contains('refused'));
  });

  test('stream error is recorded and forwarded to the app', () async {
    final inner = _FakeClient((_) async {
      final ctrl = StreamController<List<int>>()
        ..add(utf8.encode('par'))
        ..addError(const FormatException('broken'));
      unawaited(ctrl.close());
      return http.StreamedResponse(ctrl.stream, 200);
    });
    final c = ProxieHttpClient(inner: inner)..attach(engine);
    final res = await c.send(http.Request('GET', server.url('/x')));
    await expectLater(res.stream.toBytes(), throwsA(isA<FormatException>()));
    await pumpEventQueue();
    final call = sink.last;
    expect(call.error!.type, 'stream_error');
    expect(call.response!.statusCode, 200);
    expect(call.response!.body.bytes, utf8.encode('par'));
    expect(call.response!.body.truncated, isTrue);
    expect(call.response!.body.originalLength, 3);
    expect(sink.latest, hasLength(1));
  });

  test('early cancel records cancelled and cancels upstream', () async {
    var upstreamCancelled = false;
    final inner = _FakeClient((_) async {
      late StreamController<List<int>> ctrl;
      ctrl = StreamController<List<int>>(
        onListen: () => ctrl.add(utf8.encode('first')),
        onCancel: () => upstreamCancelled = true,
      );
      return http.StreamedResponse(ctrl.stream, 200);
    });
    final c = ProxieHttpClient(inner: inner)..attach(engine);
    final res = await c.send(http.Request('GET', server.url('/x')));
    final got = Completer<List<int>>();
    late StreamSubscription<List<int>> sub;
    sub = res.stream.listen((d) {
      got.complete(d);
      unawaited(sub.cancel());
    });
    expect(await got.future, utf8.encode('first'));
    await pumpEventQueue();
    expect(upstreamCancelled, isTrue);
    final call = sink.last;
    expect(call.error!.type, 'cancelled');
    expect(call.response!.body.bytes, utf8.encode('first'));
    expect(call.response!.body.truncated, isTrue);
    expect(call.response!.body.originalLength, 5);
  });

  test('early cancel against the real server completes cleanly', () async {
    final res = await client.send(http.Request('GET', server.url('/big?mb=6')));
    final first = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = res.stream.listen((_) {
      if (!first.isCompleted) {
        first.complete();
        unawaited(sub.cancel());
      }
    });
    await first.future;
    await pumpEventQueue();
    expect(sink.last.error!.type, 'cancelled');
  });

  test('rule added mid-stream does not pause the streamed call', () async {
    final res = await client.send(http.Request('GET', server.url('/json')));
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.response)]);
    var paused = false;
    final sub = engine.breakpoints.changes.listen((p) {
      if (p.isNotEmpty) paused = true;
    });
    expect(await res.stream.bytesToString(), '{"hello":"world"}');
    await pumpEventQueue();
    await sub.cancel();
    expect(paused, isFalse);
    expect(engine.breakpoints.pending, isEmpty);
    final call = sink.last;
    expect(call.response!.statusCode, 200);
    expect(call.tags, isNot(contains(CallTag.breakpoint)));
    expect(call.tags, isNot(contains(CallTag.edited)));
  });

  test('Set-Cookie headers stay separate values (streamed)', () async {
    final res = await client.get(server.url('/cookies'));
    expect(res.body, 'ok');
    await pumpEventQueue();
    expect(sink.last.response!.headers['set-cookie'], [
      'a=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT',
      'b=2',
    ]);
  });

  test('Set-Cookie headers stay separate values (breakpoint)', () async {
    engine.rules = RuleSet([_bp('*/cookies', BreakpointPhase.response)]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (_) => const ContinueUnchanged(),
    );
    final res = await client.get(server.url('/cookies'));
    expect(res.headers['set-cookie'], contains('b=2'));
    await pumpEventQueue();
    expect(sink.last.response!.headers['set-cookie'], hasLength(2));
  });

  test('Set-Cookie headers stay separate values (replay)', () async {
    final r = await client.replay(
      ProxieRequest(
        method: 'GET',
        url: server.url('/cookies'),
        headers: {},
        body: ProxieBody.empty(),
      ),
    );
    expect(r.headers['set-cookie'], hasLength(2));
  });

  test('final url after redirects is kept (streamed)', () async {
    final res = await client.send(http.Request('GET', server.url('/redirect')));
    await res.stream.drain<void>();
    expect(res, isA<http.BaseResponseWithUrl>());
    expect((res as http.BaseResponseWithUrl).url, server.url('/json'));
  });

  test('final url after redirects is kept (breakpoint)', () async {
    engine.rules = RuleSet([_bp('*/redirect', BreakpointPhase.response)]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (_) => const ContinueUnchanged(),
    );
    final res = await client.send(http.Request('GET', server.url('/redirect')));
    await res.stream.drain<void>();
    expect((res as http.BaseResponseWithUrl).url, server.url('/json'));
  });

  test('mocked responses carry the request url', () async {
    engine.rules = RuleSet([
      _mapLocal('*/json', MapLocalAction(response: _jsonRes(200, '{}'))),
    ]);
    final res = await client.send(http.Request('GET', server.url('/json')));
    await res.stream.drain<void>();
    expect((res as http.BaseResponseWithUrl).url, server.url('/json'));
  });

  test('replay of a truncated request body throws StateError', () async {
    final body = ProxieBody.from(Uint8List(20), null, cap: 10);
    expect(body.truncated, isTrue);
    await expectLater(
      client.replay(
        ProxieRequest(
          method: 'POST',
          url: server.url('/echo'),
          headers: {},
          body: body,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Cannot replay: request body was truncated',
        ),
      ),
    );
    expect(server.hitsFor('/echo'), 0);
  });

  test('a streamed response that is never listened to stays pending', () async {
    final res = await client.send(http.Request('GET', server.url('/json')));
    await pumpEventQueue();
    expect(sink.last.response, isNull);
    expect(sink.last.error, isNull);
    expect(sink.last.duration, isNull);
    await res.stream.drain<void>();
    await pumpEventQueue();
    expect(sink.last.response!.statusCode, 200);
  });

  test('/status/<code>: app and record see the status', () async {
    final res = await client.get(server.url('/status/418'));
    expect(res.statusCode, 418);
    expect(jsonDecode(res.body), {'status': 418});
    await pumpEventQueue();
    expect(sink.last.response!.statusCode, 418);
  });

  test('MultipartRequest: boundary in content-type matches the body', () async {
    final req = http.MultipartRequest('POST', server.url('/echo'))
      ..fields['name'] = 'proxie'
      ..files.add(
        http.MultipartFile.fromString('file', 'data', filename: 'f.txt'),
      );
    final res = await http.Response.fromStream(await client.send(req));
    final echo = jsonDecode(res.body) as Map;
    final ct = (echo['headers'] as Map)['content-type'] as String;
    final boundary = RegExp(r'boundary=(.+)$').firstMatch(ct)!.group(1)!;
    final body = echo['body'] as String;
    expect(body, startsWith('--$boundary\r\n'));
    expect(body, contains('proxie'));
    expect(body, contains('data'));
    expect(body.trimRight(), endsWith('--$boundary--'));
    await pumpEventQueue();
    final call = sink.last;
    expect(call.request.headers['content-type']!.single, ct);
    expect(call.request.body.text, body);
  });

  test('StreamedRequest: chunks are sent and captured in full', () async {
    final req = http.StreamedRequest('PUT', server.url('/echo'))
      ..headers['content-type'] = 'text/plain';
    final sent = client.send(req);
    req.sink
      ..add(utf8.encode('one,'))
      ..add(utf8.encode('two,'))
      ..add(utf8.encode('three'));
    unawaited(req.sink.close());
    final res = await http.Response.fromStream(await sent);
    expect((jsonDecode(res.body) as Map)['body'], 'one,two,three');
    await pumpEventQueue();
    expect(sink.last.request.body.text, 'one,two,three');
  });
}
