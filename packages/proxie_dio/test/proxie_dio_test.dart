import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
// The inspector's replay entry point is internal to proxie; this pins that
// it works with the Dio adapter (P34).
import 'package:proxie/src/core/replay.dart';
import 'package:proxie/src/internal_api.dart';
import 'package:proxie_dio/proxie_dio.dart';
import 'package:proxie_dio/src/dio_bodies.dart';
import 'package:proxie_dio/src/proxie_dio_interceptor.dart'
    show installProxieDio;

import 'support/test_server.dart';

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

/// An adapter failing every fetch.
class _FailingAdapter implements HttpClientAdapter {
  _FailingAdapter(this.error);

  final DioException Function(RequestOptions options) error;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw error(options);

  @override
  void close({bool force = false}) {}
}

/// An adapter recording whether each fetch ran marked captured.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.inner);

  final HttpClientAdapter inner;
  final marked = <bool>[];
  bool? closedForce;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    marked.add(isProxieCaptured());
    return inner.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    closedForce = force;
    inner.close(force: force);
  }
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

ProxieBody _jsonBody(String body) =>
    ProxieBody.from(Uint8List.fromList(utf8.encode(body)), 'application/json');

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

/// An engine whose request handling always throws.
class _ThrowingEngine extends ProxieEngine {
  _ThrowingEngine(CallSink sink)
    : super(config: const ProxieConfig(), sink: sink);

  @override
  Future<RequestDecision> onRequest(
    String callId,
    String adapter,
    ProxieRequest req,
  ) => throw StateError('broken');
}

/// An engine whose request handling and error recording both throw.
class _BrokenEngine extends _ThrowingEngine {
  _BrokenEngine(super.sink);

  @override
  void onError(String callId, ProxieError err, {ProxieResponse? response}) =>
      throw StateError('broken too');
}

/// Throws [StateError] for every body it decodes.
String? _throwingDecoder(
  List<int> bytes,
  RequestOptions options,
  ResponseBody body,
) => throw StateError('decoder failed');

/// The overrides set globally, ignoring zone overrides.
HttpOverrides? _globalOverrides() => Zone.root.run(() => HttpOverrides.current);

class _ListSink implements CallSink {
  final calls = <ProxieCall>[];

  @override
  void upsert(ProxieCall call) => calls.add(call);
}

/// Answers every request with JSON.
class _Answering implements HttpClientAdapter {
  _Answering({this.pad = 0});

  final int pad;
  int fetched = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetched++;
    final text = jsonEncode({'pad': 'x' * pad});
    return ResponseBody.fromString(
      text,
      200,
      headers: {
        'content-type': ['application/json'],
        'content-length': ['${text.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _NullSink implements CallSink {
  @override
  void upsert(ProxieCall call) {}
}

/// Asks like a healthy engine, but recording an outcome throws.
class _BrokenRecording extends ProxieEngine {
  _BrokenRecording(CallSink sink)
    : super(config: const ProxieConfig(), sink: sink);

  @override
  void onError(String callId, ProxieError err, {ProxieResponse? response}) =>
      throw StateError('broken onError');
}

class _ThrowingToString {
  @override
  String toString() => throw StateError('no');
}

void main() {
  late TestServer server;
  late _Sink sink;
  late ProxieEngine engine;
  late Dio dio;
  late ProxieDioInterceptor interceptor;

  setUp(() async {
    server = await startTestServer();
    sink = _Sink();
    engine = ProxieEngine(
      config: const ProxieConfig(),
      sink: sink,
      breakpoints: BreakpointController(timeout: const Duration(seconds: 5)),
    );
    dio = Dio();
    interceptor = ProxieDio.install(dio)..attach(engine);
  });

  tearDown(() async {
    dio.close(force: true);
    engine.dispose();
    await server.close();
  });

  String url(String path) => server.url(path).toString();

  test('name and replay support', () {
    expect(interceptor.name, 'dio');
    expect(interceptor.supportsReplay, isTrue);
    expect(interceptor, isA<ProxieCaptureAdapter>());
    expect(ProxieDioInterceptor().supportsReplay, isFalse);
    expect(ProxieDioInterceptor(replayClient: Dio()).supportsReplay, isTrue);
  });

  test('GET /json: app gets the decoded map, sink records 200', () async {
    final res = await dio.get<dynamic>(url('/json'));
    expect(res.statusCode, 200);
    expect(res.data, {'hello': 'world'});
    await pumpEventQueue();
    expect(sink.latest, hasLength(1));
    final call = sink.last;
    expect(call.adapter, 'dio');
    expect(call.request.method, 'GET');
    expect(call.request.url, server.url('/json'));
    expect(call.response!.statusCode, 200);
    expect(call.response!.body.text, '{"hello":"world"}');
    expect(call.response!.body.kind, BodyKind.json);
    expect(call.error, isNull);
    expect(call.duration, isNotNull);
    expect(res.requestOptions.extra.containsKey('proxie.callId'), isFalse);
  });

  test('POST map body: JSON captured and delivered', () async {
    final res = await dio.post<dynamic>(
      url('/echo'),
      data: {'a': 1, 'b': 'two'},
    );
    expect(jsonDecode((res.data as Map)['body'] as String), {
      'a': 1,
      'b': 'two',
    });
    await pumpEventQueue();
    final req = sink.last.request;
    expect(req.method, 'POST');
    expect(req.headers['content-type'], ['application/json']);
    expect(jsonDecode(req.body.text!), {'a': 1, 'b': 'two'});
    expect(req.body.kind, BodyKind.json);
  });

  test('form-urlencoded map body is captured the way Dio sends it', () async {
    final res = await dio.post<dynamic>(
      url('/echo'),
      data: {'a': '1', 'b': 'x y'},
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final sent = (res.data as Map)['body'] as String;
    expect(sent, 'a=1&b=x+y');
    await pumpEventQueue();
    expect(sink.last.request.body.text, sent);
  });

  test('String and Uint8List bodies are captured as sent', () async {
    await dio.post<dynamic>(
      url('/echo'),
      data: 'plain text',
      options: Options(contentType: 'text/plain'),
    );
    await dio.post<dynamic>(
      url('/echo'),
      data: Uint8List.fromList([1, 2, 3]),
      options: Options(contentType: 'application/octet-stream'),
    );
    await pumpEventQueue();
    final calls = sink.latest;
    expect(calls[0].request.body.text, 'plain text');
    expect(calls[1].request.body.bytes, [1, 2, 3]);
  });

  test('FormData: placeholder recorded, server gets the multipart', () async {
    final form = FormData.fromMap({
      'name': 'proxie',
      'kind': 'test',
      'file': MultipartFile.fromBytes([1, 2, 3], filename: 'a.bin'),
    });
    final length = form.length;
    final res = await dio.post<dynamic>(url('/echo'), data: form);
    final echoed = res.data as Map;
    expect(
      (echoed['headers'] as Map)['content-type'],
      startsWith('multipart/form-data; boundary='),
    );
    expect(echoed['body'], contains('name="name"'));
    await pumpEventQueue();
    final body = sink.last.request.body;
    expect(body.text, 'multipart/form-data: 2 fields, 1 files');
    expect(body.truncated, isTrue);
    expect(body.originalLength, length);
  });

  test('Stream body: placeholder recorded, server gets the bytes', () async {
    final res = await dio.post<dynamic>(
      url('/echo'),
      data: Stream.fromIterable([utf8.encode('ab'), utf8.encode('cd')]),
      options: Options(
        contentType: 'text/plain',
        headers: {Headers.contentLengthHeader: 4},
      ),
    );
    expect((res.data as Map)['body'], 'abcd');
    await pumpEventQueue();
    final body = sink.last.request.body;
    expect(body.text, 'streamed body');
    expect(body.truncated, isTrue);
    expect(body.originalLength, 4);
  });

  test('mocked 401 is a badResponse DioException; server not hit', () async {
    engine.rules = RuleSet([
      _mapLocal('*/json', MapLocalAction(response: _jsonRes(401, '{"e":1}'))),
    ]);
    final err = await dio
        .get<dynamic>(url('/json'))
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.type, DioExceptionType.badResponse);
    expect(err.response!.statusCode, 401);
    expect(err.response!.data, {'e': 1});
    expect(server.hitsFor('/json'), 0);
    await pumpEventQueue();
    expect(sink.latest, hasLength(1));
    expect(sink.last.response!.statusCode, 401);
    expect(sink.last.tags, contains(CallTag.mapLocal));
    expect(sink.last.error, isNull);
  });

  test('mocked 500 with an accept-all validateStatus resolves', () async {
    engine.rules = RuleSet([
      _mapLocal('*/json', MapLocalAction(response: _jsonRes(500, '{"e":2}'))),
    ]);
    final res = await dio.get<dynamic>(
      url('/json'),
      options: Options(validateStatus: (_) => true),
    );
    expect(res.statusCode, 500);
    expect(res.data, {'e': 2});
    expect(res.headers.value('content-type'), 'application/json');
  });

  test('mocked body is decoded per responseType', () async {
    engine.rules = RuleSet([
      _mapLocal('*/json', MapLocalAction(response: _jsonRes(200, '{"m":1}'))),
    ]);
    final plain = await dio.get<dynamic>(
      url('/json'),
      options: Options(responseType: ResponseType.plain),
    );
    expect(plain.data, '{"m":1}');
    final bytes = await dio.get<dynamic>(
      url('/json'),
      options: Options(responseType: ResponseType.bytes),
    );
    expect(bytes.data, utf8.encode('{"m":1}'));
    final stream = await dio.get<ResponseBody>(
      url('/json'),
      options: Options(responseType: ResponseType.stream),
    );
    final streamed = await stream.data!.stream.expand((c) => c).toList();
    expect(utf8.decode(streamed), '{"m":1}');
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
    await dio.get<dynamic>(url('/json'));
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(140));
  });

  test('map-local timeout failure is a connectionTimeout', () async {
    engine.rules = RuleSet([
      _mapLocal(
        '*/json',
        const MapLocalAction(failure: SimulatedFailure.timeout),
      ),
    ]);
    final err = await dio
        .get<dynamic>(url('/json'))
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.type, DioExceptionType.connectionTimeout);
    expect(err.message, contains('simulated by Proxie'));
    expect(server.hitsFor('/json'), 0);
    await pumpEventQueue();
    expect(sink.last.error!.type, 'timeout');
    expect(sink.last.response, isNull);
  });

  test('map-local noConnection failure is a connectionError', () async {
    engine.rules = RuleSet([
      _mapLocal(
        '*/json',
        const MapLocalAction(failure: SimulatedFailure.noConnection),
      ),
    ]);
    final err = await dio
        .get<dynamic>(url('/json'))
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.type, DioExceptionType.connectionError);
    await pumpEventQueue();
    expect(sink.last.error!.type, 'no_connection');
  });

  test('request breakpoint edits query, header and JSON body', () async {
    engine.rules = RuleSet([_bp('*/echo*', BreakpointPhase.request)]);
    _onPause(engine, BreakpointPhase.request, (p) {
      final r = p.request;
      return ExecuteRequest(
        r.copyWith(
          method: 'PUT',
          url: r.url.replace(queryParameters: {'q': 'edited'}),
          headers: {
            ...r.headers,
            'x-test': ['1'],
          },
          body: _jsonBody('{"edited":true}'),
        ),
      );
    });
    final res = await dio.post<dynamic>(
      url('/echo'),
      queryParameters: {'q': 'orig'},
      data: {'orig': true},
    );
    final echoed = res.data as Map;
    expect(echoed['method'], 'PUT');
    expect(echoed['uri'], '/echo?q=edited');
    expect((echoed['headers'] as Map)['x-test'], '1');
    expect((echoed['headers'] as Map)['content-type'], 'application/json');
    expect(jsonDecode(echoed['body'] as String), {'edited': true});
    expect(res.requestOptions.uri, server.url('/echo?q=edited'));
    await pumpEventQueue();
    expect(sink.last.request.url.queryParameters['q'], 'edited');
    expect(sink.last.tags, contains(CallTag.edited));
  });

  test('request breakpoint continue keeps the original request', () async {
    engine.rules = RuleSet([_bp('*/echo*', BreakpointPhase.request)]);
    _onPause(engine, BreakpointPhase.request, (_) => const ContinueUnchanged());
    final form = FormData.fromMap({'f': 'v'});
    final res = await dio.post<dynamic>(url('/echo'), data: form);
    expect((res.data as Map)['body'], contains('name="f"'));
  });

  test(
    'request breakpoint resent with placeholder bytes keeps FormData',
    () async {
      engine.rules = RuleSet([_bp('*/echo*', BreakpointPhase.request)]);
      _onPause(engine, BreakpointPhase.request, (p) {
        final b = p.request.body;
        // A UI round-trip may drop the truncated flag; the bytes are the same.
        return ExecuteRequest(
          p.request.copyWith(
            body: ProxieBody(bytes: b.bytes, kind: b.kind),
          ),
        );
      });
      final res = await dio.post<dynamic>(
        url('/echo'),
        data: FormData.fromMap({'f': 'v'}),
      );
      expect((res.data as Map)['body'], contains('name="f"'));
    },
  );

  test('request breakpoint abort is a connectionError', () async {
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.request)]);
    _onPause(engine, BreakpointPhase.request, (_) => const Abort());
    final err = await dio
        .get<dynamic>(url('/json'))
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.type, DioExceptionType.connectionError);
    expect(err.message, 'Aborted by Proxie');
    expect(err.error, 'Aborted at breakpoint');
    expect(server.hitsFor('/json'), 0);
    await pumpEventQueue();
    expect(sink.last.error!.type, 'aborted');
  });

  test('response breakpoint edits status and JSON body', () async {
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.response)]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(
        p.response!.copyWith(
          statusCode: 201,
          reasonPhrase: 'Made',
          body: _jsonBody('{"edited":[1,2]}'),
        ),
      ),
    );
    final res = await dio.get<dynamic>(url('/json'));
    expect(res.statusCode, 201);
    expect(res.statusMessage, 'Made');
    expect(res.data, {
      'edited': [1, 2],
    });
    await pumpEventQueue();
    expect(sink.last.response!.statusCode, 201);
    expect(sink.last.tags, containsAll([CallTag.breakpoint, CallTag.edited]));
  });

  test('response breakpoint edit to 500 is a badResponse', () async {
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.response)]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(p.response!.copyWith(statusCode: 500)),
    );
    final err = await dio
        .get<dynamic>(url('/json'))
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.type, DioExceptionType.badResponse);
    expect(err.response!.statusCode, 500);
    expect(err.response!.data, {'hello': 'world'});
  });

  test('response breakpoint can turn a server 404 into a success', () async {
    engine.rules = RuleSet([_bp('*/status/*', BreakpointPhase.response)]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(p.response!.copyWith(statusCode: 200)),
    );
    final res = await dio.get<dynamic>(url('/status/404'));
    expect(res.statusCode, 200);
    expect(res.data, {'status': 404});
  });

  test('response breakpoint abort is a connectionError', () async {
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.response)]);
    _onPause(engine, BreakpointPhase.response, (_) => const Abort());
    final err = await dio
        .get<dynamic>(url('/json'))
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.type, DioExceptionType.connectionError);
    expect(err.message, 'Aborted by Proxie');
    expect(err.error, 'Aborted at response breakpoint');
    await pumpEventQueue();
    expect(sink.last.error!.type, 'aborted');
  });

  test('response breakpoints apply to mocked responses', () async {
    engine.rules = RuleSet([
      _bp('*/json', BreakpointPhase.response),
      _mapLocal('*/json', MapLocalAction(response: _jsonRes(200, '{"m":1}'))),
    ]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(p.response!.copyWith(body: _jsonBody('{"m":2}'))),
    );
    final res = await dio.get<dynamic>(url('/json'));
    expect(res.data, {'m': 2});
  });

  test('server 404 is recorded as a response, app gets badResponse', () async {
    final err = await dio
        .get<dynamic>(url('/status/404'))
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.type, DioExceptionType.badResponse);
    expect(err.response!.statusCode, 404);
    await pumpEventQueue();
    expect(sink.latest, hasLength(1));
    expect(sink.last.response!.statusCode, 404);
    expect(sink.last.response!.body.text, '{"status":404}');
    expect(sink.last.error, isNull);
  });

  test('connection failure records a network error', () async {
    final port = server.url('/').port;
    await server.close();
    final err = await dio
        .get<dynamic>('http://127.0.0.1:$port/json')
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.type, DioExceptionType.connectionError);
    await pumpEventQueue();
    expect(sink.last.error!.type, 'network');
    server = await startTestServer();
  });

  test('cancelled request records cancelled', () async {
    final token = CancelToken();
    final future = dio.get<dynamic>(url('/big?mb=50'), cancelToken: token);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    token.cancel('bye');
    final err = await future
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.type, DioExceptionType.cancel);
    await pumpEventQueue();
    expect(sink.last.error!.type, 'cancelled');
  });

  test('/big?mb=6 reaches the app intact; record capped', () async {
    final res = await dio.get<String>(url('/big?mb=6'));
    expect(res.data!.length, 6 * 1024 * 1024);
    expect(res.data!.codeUnits.every((c) => c == 0x61), isTrue);
    await pumpEventQueue();
    final body = sink.last.response!.body;
    expect(body.truncated, isTrue);
    expect(body.bytes.length, 5 * 1024 * 1024);
    expect(body.originalLength, 6 * 1024 * 1024);
  });

  test('ResponseType.stream is not consumed; app gets every byte', () async {
    final res = await dio.get<ResponseBody>(
      url('/big?mb=1'),
      options: Options(responseType: ResponseType.stream),
    );
    await pumpEventQueue();
    final body = sink.last.response!.body;
    expect(body.bytes, isEmpty);
    expect(body.truncated, isTrue);
    expect(body.kind, BodyKind.empty);
    expect(body.originalLength, 1024 * 1024);
    var total = 0;
    await for (final chunk in res.data!.stream) {
      total += chunk.length;
    }
    expect(total, 1024 * 1024);
  });

  test('unattached: pure pass-through, nothing recorded', () async {
    interceptor.detach();
    final options = RequestOptions(path: url('/json'));
    final res = await dio.fetch<dynamic>(options);
    expect(res.data, {'hello': 'world'});
    expect(options.extra, isEmpty);
    expect(identical(res.requestOptions, options), isTrue);
    await pumpEventQueue();
    expect(sink.calls, isEmpty);
  });

  /// Retries the first failed request once, against /json.
  Interceptor retryOnce(Dio d) {
    var retried = false;
    return InterceptorsWrapper(
      onError: (err, handler) async {
        if (retried) return handler.next(err);
        retried = true;
        final again = err.requestOptions..path = url('/json');
        handler.resolve(await d.fetch<dynamic>(again));
      },
    );
  }

  test(
    'install: a retry interceptor added first sees a recorded 500',
    () async {
      final d = Dio();
      d.interceptors.add(retryOnce(d));
      ProxieDio.install(d).attach(engine);
      final res = await d.get<dynamic>(url('/status/500'));
      expect(res.data, {'hello': 'world'});
      await pumpEventQueue();
      final calls = sink.latest;
      expect(calls, hasLength(2));
      expect(calls[0].request.url, server.url('/status/500'));
      expect(calls[0].response!.statusCode, 500);
      expect(calls[0].response!.body.text, '{"status":500}');
      expect(calls[0].error, isNull);
      expect(calls[1].request.url, server.url('/json'));
      expect(calls[1].response!.statusCode, 200);
      d.close(force: true);
    },
  );

  test('hand-added after a retry interceptor: first try superseded', () async {
    final d = Dio();
    d.interceptors
      ..add(retryOnce(d))
      ..add(ProxieDioInterceptor()..attach(engine));
    await d.get<dynamic>(url('/status/500'));
    await pumpEventQueue();
    final calls = sink.latest;
    expect(calls, hasLength(2));
    expect(calls[0].error!.type, 'superseded');
    expect(calls[1].response!.statusCode, 200);
    d.close(force: true);
  });

  test('content-type-only edit sends the recorded bytes', () async {
    engine.rules = RuleSet([_bp('*/echo', BreakpointPhase.request)]);
    _onPause(engine, BreakpointPhase.request, (p) {
      return ExecuteRequest(
        p.request.copyWith(
          headers: {
            ...p.request.headers,
            'content-type': ['text/plain'],
          },
        ),
      );
    });
    final res = await dio.post<dynamic>(url('/echo'), data: {'a': 1});
    final echoed = res.data as Map;
    expect((echoed['headers'] as Map)['content-type'], 'text/plain');
    expect(echoed['body'], '{"a":1}');
  });

  test("header edits keep the app's header name casing", () async {
    engine.rules = RuleSet([_bp('*/echo', BreakpointPhase.request)]);
    _onPause(engine, BreakpointPhase.request, (p) {
      return ExecuteRequest(
        p.request.copyWith(
          headers: {
            ...p.request.headers,
            'x-new': ['n'],
          },
        ),
      );
    });
    final res = await dio.get<dynamic>(
      url('/echo'),
      options: Options(headers: {'X-Custom': 'a'}),
    );
    final keys = res.requestOptions.headers.keys.toList();
    expect(keys, containsAll(['X-Custom', 'x-new']));
    expect(keys, isNot(contains('x-custom')));
    expect(((res.data as Map)['headers'] as Map)['x-custom'], 'a');
  });

  test('URL edit with baseUrl, relative path and query parameters', () async {
    final d = Dio(BaseOptions(baseUrl: url('/')));
    ProxieDio.install(d).attach(engine);
    engine.rules = RuleSet([_bp('*/echo*', BreakpointPhase.request)]);
    Uri? seen;
    _onPause(engine, BreakpointPhase.request, (p) {
      seen = p.request.url;
      return ExecuteRequest(
        p.request.copyWith(
          url: p.request.url.replace(queryParameters: {'q': 'edited'}),
        ),
      );
    });
    final res = await d.get<dynamic>(
      'echo',
      queryParameters: {'q': 'orig', 'k': 'v'},
    );
    expect(seen, server.url('/echo?q=orig&k=v'));
    expect((res.data as Map)['uri'], '/echo?q=edited');
    await pumpEventQueue();
    expect(sink.last.request.url, server.url('/echo?q=edited'));
    d.close(force: true);
  });

  test('cancel while paused at a request breakpoint', () async {
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.request)]);
    final token = CancelToken();
    late StreamSubscription<List<PausedCall>> sub;
    sub = engine.breakpoints.changes.listen((pending) {
      if (pending.isNotEmpty) {
        unawaited(sub.cancel());
        token.cancel('bye');
      }
    });
    final err = await dio
        .get<dynamic>(url('/json'), cancelToken: token)
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException)
        .timeout(const Duration(seconds: 2));
    expect(err.type, DioExceptionType.cancel);
    await pumpEventQueue();
    expect(engine.breakpoints.pending, isEmpty);
    expect(sink.last.error!.type, 'cancelled');
    expect(server.hitsFor('/json'), 0);
  });

  test('edits to a truncated request body are refused', () async {
    final small = ProxieEngine(
      config: const ProxieConfig(teeCap: 4),
      sink: sink,
      breakpoints: BreakpointController(timeout: const Duration(seconds: 5)),
    );
    addTearDown(small.dispose);
    interceptor.attach(small);
    small.rules = RuleSet([_bp('*/echo', BreakpointPhase.request)]);
    bool? truncated;
    _onPause(small, BreakpointPhase.request, (p) {
      truncated = p.request.body.truncated;
      return ExecuteRequest(
        p.request.copyWith(
          body: ProxieBody.from(
            Uint8List.fromList(utf8.encode('zz')),
            'text/plain',
          ),
        ),
      );
    });
    final res = await dio.post<dynamic>(
      url('/echo'),
      data: 'abcdefgh',
      options: Options(contentType: 'text/plain'),
    );
    expect(truncated, isTrue);
    expect((res.data as Map)['body'], 'abcdefgh');
  });

  test(
    'invalid JSON edited into a JSON response reaches the app as text',
    () async {
      engine.rules = RuleSet([_bp('*/json', BreakpointPhase.response)]);
      _onPause(
        engine,
        BreakpointPhase.response,
        (p) => ExecuteResponse(p.response!.copyWith(body: _jsonBody('{oops'))),
      );
      final res = await dio.get<dynamic>(url('/json'));
      expect(res.data, '{oops');
      await pumpEventQueue();
      expect(sink.last.response!.body.text, '{oops');
      expect(sink.last.error, isNull);
    },
  );

  test('a mock with invalid JSON reaches the app as text', () async {
    engine.rules = RuleSet([
      _mapLocal('*/json', MapLocalAction(response: _jsonRes(200, '{oops'))),
    ]);
    final res = await dio.get<dynamic>(url('/json'));
    expect(res.data, '{oops');
  });

  test('an engine failure never breaks the request', () async {
    final broken = _ThrowingEngine(sink);
    addTearDown(broken.dispose);
    interceptor.attach(broken);
    final res = await dio.get<dynamic>(url('/json'));
    expect(res.data, {'hello': 'world'});
    expect(server.hitsFor('/json'), 1);
  });

  test('an engine whose onError throws never breaks the request', () async {
    final broken = _BrokenEngine(sink);
    addTearDown(broken.dispose);
    interceptor.attach(broken);
    final res = await dio
        .get<dynamic>(url('/json'))
        .timeout(const Duration(seconds: 2));
    expect(res.data, {'hello': 'world'});
  });

  test('a throwing responseDecoder fails a mocked call as in Dio', () async {
    engine.rules = RuleSet([
      _mapLocal('*/json', MapLocalAction(response: _jsonRes(200, '{}'))),
    ]);
    final err = await dio
        .get<dynamic>(
          url('/json'),
          options: Options(responseDecoder: _throwingDecoder),
        )
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.error, isA<StateError>());
  });

  test('a throwing responseDecoder fails an edited response', () async {
    engine.rules = RuleSet([_bp('*/json', BreakpointPhase.response)]);
    _onPause(
      engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(p.response!.copyWith(body: _jsonBody('{"x":1}'))),
    );
    var decoded = 0;
    final err = await dio
        .get<dynamic>(
          url('/json'),
          options: Options(
            responseDecoder: (bytes, options, body) {
              // The real response decodes; the edited body does not.
              if (decoded++ == 0) return '{"hello":"world"}';
              throw StateError('decoder failed');
            },
          ),
        )
        .then<DioException>((_) => fail('expected an error'))
        .catchError((Object e) => e as DioException);
    expect(err.error, isA<StateError>());
  });

  test('content-type edit on a truncated body is refused', () async {
    final small = ProxieEngine(
      config: const ProxieConfig(teeCap: 4),
      sink: sink,
      breakpoints: BreakpointController(timeout: const Duration(seconds: 5)),
    );
    addTearDown(small.dispose);
    interceptor.attach(small);
    small.rules = RuleSet([_bp('*/echo', BreakpointPhase.request)]);
    _onPause(small, BreakpointPhase.request, (p) {
      return ExecuteRequest(
        p.request.copyWith(
          headers: {
            ...p.request.headers,
            'content-type': [Headers.formUrlEncodedContentType],
            'x-kept': ['1'],
          },
        ),
      );
    });
    final res = await dio.post<dynamic>(url('/echo'), data: {'a': '1'});
    final echoed = res.data as Map;
    expect((echoed['headers'] as Map)['content-type'], 'application/json');
    expect((echoed['headers'] as Map)['x-kept'], '1');
    expect(echoed['body'], '{"a":"1"}');
  });

  test('a non-String-keyed map body is captured as Dio sends it', () async {
    final res = await dio.post<dynamic>(
      url('/echo'),
      data: <dynamic, dynamic>{'a': 1},
      options: Options(contentType: 'text/plain'),
    );
    final sent = (res.data as Map)['body'];
    expect(sent, '{a: 1}');
    await pumpEventQueue();
    expect(sink.last.request.body.text, sent);
  });

  group('install', () {
    test('wraps the adapter: captured fetches run marked', () async {
      final d = Dio();
      final rec = _RecordingAdapter(d.httpClientAdapter);
      d.httpClientAdapter = rec;
      final i = ProxieDio.install(d);
      await d.get<dynamic>(url('/json'));
      i.attach(engine);
      await d.get<dynamic>(url('/json'));
      expect(rec.marked, [false, true]);
      d.close(force: true);
      expect(rec.closedForce, isTrue);
    });

    test('a different interceptor on an installed Dio throws', () {
      final d = Dio();
      ProxieDio.install(d);
      expect(
        () => ProxieDio.install(d, interceptor: ProxieDioInterceptor()),
        throwsArgumentError,
      );
      d.close();
    });

    test('moves a hand-added interceptor to the end', () {
      final d = Dio();
      final mine = ProxieDioInterceptor();
      final other = InterceptorsWrapper();
      d.interceptors
        ..add(mine)
        ..add(other);
      expect(ProxieDio.install(d), same(mine));
      expect(d.interceptors.last, same(mine));
      expect(d.interceptors.whereType<ProxieDioInterceptor>(), [mine]);
      d.close();
    });

    test('is idempotent and accepts a given interceptor', () {
      final d = Dio();
      final given = ProxieDioInterceptor();
      final i = ProxieDio.install(d, interceptor: given);
      final adapter = d.httpClientAdapter;
      expect(ProxieDio.install(d, interceptor: given), same(i));
      expect(identical(d.httpClientAdapter, adapter), isTrue);
      expect(d.interceptors.whereType<ProxieDioInterceptor>(), [given]);
      expect(given.supportsReplay, isTrue);
      d.close();
    });

    test('with the HttpOverrides adapter attached: captured once', () async {
      final saved = _globalOverrides();
      HttpOverrides.global = null;
      final io = ProxieHttpOverridesAdapter()..attach(engine);
      try {
        final d = Dio();
        ProxieDio.install(d).attach(engine);
        final res = await d.get<dynamic>(url('/json'));
        expect(res.data, {'hello': 'world'});
        await pumpEventQueue();
        expect(sink.latest, hasLength(1));
        expect(sink.last.adapter, 'dio');
        d.close(force: true);
      } finally {
        io.detach();
        HttpOverrides.global = saved;
      }
    });

    test(
      'added by hand with the HttpOverrides adapter: recorded twice',
      () async {
        final saved = _globalOverrides();
        HttpOverrides.global = null;
        final io = ProxieHttpOverridesAdapter()..attach(engine);
        try {
          final d = Dio();
          d.interceptors.add(ProxieDioInterceptor()..attach(engine));
          await d.get<dynamic>(url('/json'));
          await pumpEventQueue();
          expect(
            sink.latest.map((c) => c.adapter),
            unorderedEquals(['dio', 'io']),
          );
          d.close(force: true);
        } finally {
          io.detach();
          HttpOverrides.global = saved;
        }
      },
    );
  });

  group('replayCall (P34)', () {
    ProxieCall original() => ProxieCall(
      id: 'orig',
      sessionId: 0,
      adapter: 'dio',
      request: ProxieRequest(
        method: 'POST',
        url: server.url('/echo'),
        headers: const {
          'content-type': ['text/plain'],
        },
        body: ProxieBody.from(
          Uint8List.fromList(utf8.encode('again')),
          'text/plain',
        ),
      ),
      startedAt: DateTime(2026, 11, 3),
    );

    test('sends through the Dio adapter and records exactly once', () async {
      final saved = _globalOverrides();
      HttpOverrides.global = null;
      final io = ProxieHttpOverridesAdapter()..attach(engine);
      try {
        final call = original();
        final result = await replayCall(call, call.request, [
          io,
          interceptor,
        ], engine: engine);
        expect(result.viaFallback, isFalse);
        expect(result.sentVia, 'Sent via dio');
        expect(result.response.statusCode, 200);
        expect(server.hitsFor('/echo'), 1);
        final ids = {for (final c in sink.calls) c.id};
        expect(ids, {result.callId});
        expect(sink.calls.last.adapter, 'dio');
        expect(sink.calls.last.tags, {CallTag.replayed});
        expect(sink.calls.last.response!.statusCode, 200);
      } finally {
        io.detach();
        HttpOverrides.global = saved;
      }
    });

    test('a Dio timeout is recorded as a timeout', () async {
      dio.httpClientAdapter = _FailingAdapter(
        (options) => DioException.receiveTimeout(
          timeout: const Duration(seconds: 1),
          requestOptions: options,
        ),
      );
      final call = original();
      await expectLater(
        replayCall(call, call.request, [interceptor], engine: engine),
        throwsA(isA<DioException>()),
      );
      expect(sink.calls.last.error!.type, 'timeout');
    });

    test('a Dio connection error is recorded as network', () async {
      dio.httpClientAdapter = _FailingAdapter(
        (options) => DioException.connectionError(
          requestOptions: options,
          reason: 'refused',
        ),
      );
      final call = original();
      await expectLater(
        replayCall(call, call.request, [interceptor], engine: engine),
        throwsA(isA<DioException>()),
      );
      expect(sink.calls.last.error!.type, 'network');
    });

    test('a failure is recorded with the message a live call gets', () async {
      DioException failure(RequestOptions options) => DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: 'short reason',
      );
      dio.httpClientAdapter = _FailingAdapter(failure);
      final call = original();
      await expectLater(
        replayCall(call, call.request, [interceptor], engine: engine),
        throwsA(isA<DioException>()),
      );
      final replayed = sink.calls.last.error!;
      await expectLater(dio.getUri<void>(server.url('/x')), throwsA(anything));
      final live = sink.calls.last.error!;
      expect(replayed.message, 'short reason');
      expect(live.message, replayed.message);
    });
  });

  group('replay', () {
    ProxieRequest req(String path, {ProxieBody? body}) => ProxieRequest(
      method: 'POST',
      url: server.url(path),
      headers: {
        'content-type': ['text/plain'],
        'x-replay': ['1'],
      },
      body:
          body ??
          ProxieBody.from(
            Uint8List.fromList(utf8.encode('again')),
            'text/plain',
          ),
    );

    test('sends the request with the installed Dio, unrecorded', () async {
      final saved = _globalOverrides();
      HttpOverrides.global = null;
      final io = ProxieHttpOverridesAdapter()..attach(engine);
      try {
        final res = await interceptor.replay(req('/echo'));
        expect(res.statusCode, 200);
        final echoed = jsonDecode(res.body.text!) as Map;
        expect(echoed['method'], 'POST');
        expect(echoed['body'], 'again');
        expect((echoed['headers'] as Map)['x-replay'], '1');
        expect(
          res.headers['content-type']!.single,
          startsWith('application/json'),
        );
        await pumpEventQueue();
        expect(sink.calls, isEmpty);
      } finally {
        io.detach();
        HttpOverrides.global = saved;
      }
    });

    test('keeps error statuses as responses', () async {
      final res = await interceptor.replay(req('/status/503'));
      expect(res.statusCode, 503);
    });

    test('uses replayClient when given', () async {
      final client = Dio();
      final i = ProxieDioInterceptor(replayClient: client);
      final res = await i.replay(req('/echo'));
      expect(res.statusCode, 200);
      client.close();
    });

    test('truncated body throws StateError', () async {
      final big = Uint8List(10);
      final body = ProxieBody.from(big, 'text/plain', cap: 4);
      expect(
        () => interceptor.replay(req('/echo', body: body)),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Cannot replay: request body was truncated',
          ),
        ),
      );
    });

    test('without a Dio throws StateError', () {
      expect(
        () => ProxieDioInterceptor().replay(req('/echo')),
        throwsStateError,
      );
    });
  });

  group('recording never breaks live traffic', () {
    test('a failing onError still hands the error to the app', () async {
      final broken = _BrokenRecording(_NullSink());
      final dio = Dio();
      ProxieDio.install(dio).attach(broken);
      await expectLater(
        dio
            .get<void>('http://127.0.0.1:1/x')
            .timeout(const Duration(seconds: 10)),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('when Proxie is compiled out', () {
    test('install leaves the Dio as it found it', () {
      final inner = _Answering();
      final dio = Dio()..httpClientAdapter = inner;
      final before = dio.interceptors.length;
      final interceptor = installProxieDio(dio, enabled: false);
      expect(dio.httpClientAdapter, same(inner));
      expect(dio.interceptors.length, before);
      expect(dio.interceptors, isNot(contains(interceptor)));
      // Still safe to hand to Proxie.init, which does nothing then.
      expect(interceptor.supportsReplay, isFalse);
    });

    test('a passed interceptor comes back', () {
      final given = ProxieDioInterceptor();
      expect(
        installProxieDio(Dio(), interceptor: given, enabled: false),
        given,
      );
    });
  });

  group('names', () {
    test('default to dio; a custom one is recorded and replays through its '
        'own Dio', () async {
      final sink = _ListSink();
      final engine = ProxieEngine(config: const ProxieConfig(), sink: sink);
      addTearDown(engine.dispose);
      final public = _Answering();
      final auth = _Answering();
      final a = ProxieDio.install(Dio()..httpClientAdapter = public);
      final authDio = Dio()..httpClientAdapter = auth;
      final b = ProxieDio.install(authDio, name: 'auth');
      expect(a.name, 'dio');
      expect(b.name, 'auth');
      a.attach(engine);
      b.attach(engine);

      await authDio.get<void>('http://a.test/x');
      final recorded = sink.calls.last;
      expect(recorded.adapter, 'auth');

      await replayCall(recorded, recorded.request, [a, b], engine: engine);
      expect(auth.fetched, 2);
      expect(public.fetched, 0);
    });

    test('an interceptor passed with a name is refused', () {
      expect(
        () => ProxieDio.install(
          Dio(),
          interceptor: ProxieDioInterceptor(),
          name: 'auth',
        ),
        throwsArgumentError,
      );
    });
  });

  group('a response a custom decoder made is still JSON', () {
    String encode(Object data) =>
        utf8.decode(encodeResponseData(data, ResponseType.json));

    test('an unknown value becomes its toString', () {
      final at = DateTime.utc(2026);
      expect(
        encode({'password': 'hunter2', 'at': at}),
        jsonEncode({'password': 'hunter2', 'at': '$at'}),
      );
    });

    test('keys that are not strings keep their keys quoted', () {
      expect(
        encode({
          1: {'password': 'hunter2'},
          'password': 'x',
        }),
        '{"1":{"password":"hunter2"},"password":"x"}',
      );
    });

    test('sets and other iterables are lists', () {
      expect(
        encode({
          'a': {1, 2},
        }),
        '{"a":[1,2]}',
      );
      expect(encode({1, 2}), '[1,2]');
    });

    test('what still cannot be encoded is a placeholder', () {
      final cycle = <String, Object?>{'password': 'hunter2'};
      cycle['self'] = cycle;
      final throwing = {'password': 'hunter2', 'x': _ThrowingToString()};
      for (final data in [cycle, throwing]) {
        final text = encode(data);
        expect(text, isNot(contains('hunter2')));
        expect(text, contains('not captured'));
      }
    });
  });

  group('encoding a response body stops near the cap', () {
    test('a large list is cut, not encoded whole', () {
      final data = List.generate(100000, (i) => {'i': i});
      final bytes = encodeResponseData(data, ResponseType.json, limit: 1000);
      expect(bytes.length, greaterThan(1000));
      expect(bytes.length, lessThan(100000));
      expect(
        utf8.decode(bytes.sublist(0, 12)),
        jsonEncode(data).substring(0, 12),
      );
    });

    test('under the limit it is all there, as jsonEncode writes it', () {
      final data = {
        'a': [1, 2.5, 'é'],
      };
      expect(
        encodeResponseData(data, ResponseType.json, limit: 1000),
        utf8.encode(jsonEncode(data)),
      );
    });

    test('a long string is cut too', () {
      final bytes = encodeResponseData(
        'x' * 5000,
        ResponseType.plain,
        limit: 100,
      );
      expect(bytes.length, 101);
    });

    test('the record is truncated, with the declared length', () async {
      final sink = _ListSink();
      final engine = ProxieEngine(
        config: const ProxieConfig(teeCap: 100),
        sink: sink,
      );
      addTearDown(engine.dispose);
      final dio = Dio()..httpClientAdapter = _Answering(pad: 5000);
      ProxieDio.install(dio).attach(engine);
      final res = await dio.get<Map<String, dynamic>>('http://a.test/x');
      expect((res.data!['pad']! as String).length, 5000);
      final body = sink.calls.last.response!.body;
      expect(body.truncated, isTrue);
      expect(body.bytes.length, lessThanOrEqualTo(100));
      expect(body.originalLength, 5000 + '{"pad":""}'.length);
    });
  });
}
