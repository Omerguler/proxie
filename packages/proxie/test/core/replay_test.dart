import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proxie/src/core/replay.dart';
import 'package:proxie/src/internal_api.dart';

import '../support/io_harness.dart';

/// A replaying adapter that records what it was asked to send.
class _FakeAdapter implements ProxieCaptureAdapter {
  _FakeAdapter(
    this.name, {
    this.supportsReplay = true,
    this.fail,
    this.classified,
  });

  @override
  final String name;

  @override
  final bool supportsReplay;

  final Exception? fail;
  final ProxieError? classified;
  final sent = <ProxieRequest>[];

  @override
  ProxieError classifyReplayError(Object error) =>
      classified ?? defaultReplayError(error);

  @override
  void attach(ProxieEngine engine) {}

  @override
  void detach() {}

  @override
  Future<ProxieResponse> replay(ProxieRequest request) async {
    if (request.body.truncated) {
      throw StateError('Cannot replay: request body was truncated');
    }
    sent.add(request);
    final f = fail;
    if (f != null) throw f;
    return ProxieResponse(
      statusCode: 201,
      headers: const {
        'content-type': ['application/json'],
      },
      body: ProxieBody.from(
        Uint8List.fromList(utf8.encode('{"ok":true}')),
        'application/json',
      ),
    );
  }
}

ProxieRequest _request({
  String url = 'https://api.test/users?page=2',
  Map<String, List<String>> headers = const {
    'X-Trace': ['1'],
  },
  ProxieBody? body,
}) => ProxieRequest(
  method: 'POST',
  url: Uri.parse(url),
  headers: headers,
  body:
      body ??
      ProxieBody.from(
        Uint8List.fromList(utf8.encode('{"a":1}')),
        'application/json',
      ),
);

ProxieCall _original(String adapter, {ProxieRequest? request}) => ProxieCall(
  id: 'orig',
  sessionId: 1,
  adapter: adapter,
  request: request ?? _request(),
  startedAt: DateTime(2026, 11, 3),
  response: ProxieResponse(
    statusCode: 200,
    headers: const {},
    body: ProxieBody.empty(),
  ),
  duration: const Duration(milliseconds: 3),
);

void main() {
  late RecordingSink sink;
  late ProxieEngine engine;

  setUp(() {
    sink = RecordingSink();
    engine = ProxieEngine(config: const ProxieConfig(), sink: sink);
  });

  tearDown(() => engine.dispose());

  test('replays an http-adapter call through that adapter', () async {
    final http = _FakeAdapter('http');
    final other = _FakeAdapter('dio');
    final original = _original('http');

    final result = await replayCall(original, original.request, [
      other,
      http,
    ], engine: engine);

    expect(http.sent, hasLength(1));
    expect(http.sent.single.url, original.request.url);
    expect(other.sent, isEmpty);
    expect(result.viaFallback, isFalse);
    expect(result.adapterName, 'http');
    expect(result.sentVia, 'Sent via http');
    expect(result.response.statusCode, 201);

    final recorded = sink.latest.single;
    expect(recorded.id, result.callId);
    expect(recorded.id, isNot(original.id));
    expect(recorded.adapter, 'http');
    expect(recorded.tags, {CallTag.replayed});
    expect(recorded.response!.statusCode, 201);
    expect(recorded.duration, isNotNull);
  });

  test('the new call is pending while it is sent', () async {
    final gate = Completer<void>();
    final adapter = _GatedAdapter(gate.future);
    final pending = replayCall(_original('gated'), _request(), [
      adapter,
    ], engine: engine);
    await Future<void>.delayed(Duration.zero);
    expect(sink.latest.single.response, isNull);
    expect(sink.latest.single.tags, {CallTag.replayed});
    gate.complete();
    await pending;
    expect(sink.latest.single.response, isNotNull);
  });

  test('an unknown adapter falls back to a client marked captured', () async {
    final captured = <bool>[];
    final seen = <http.BaseRequest>[];
    final result = await replayCall(
      _original('gone'),
      _request(),
      [_FakeAdapter('http')],
      engine: engine,
      fallbackClient: () => MockClient((req) async {
        captured.add(isProxieCaptured());
        seen.add(req);
        return http.Response('{"via":"fallback"}', 200);
      }),
    );

    expect(result.viaFallback, isTrue);
    expect(result.adapterName, kReplayFallbackAdapter);
    expect(
      result.sentVia,
      'Sent via built-in client (app interceptors skipped)',
    );
    expect(captured, [true]);
    final req = seen.single as http.Request;
    expect(req.method, 'POST');
    expect(req.url, Uri.parse('https://api.test/users?page=2'));
    expect(req.body, '{"a":1}');
    expect(req.headers['X-Trace'], '1');
    final recorded = sink.latest.single;
    expect(recorded.adapter, kReplayFallbackAdapter);
    expect(recorded.tags, {CallTag.replayed});
    expect(recorded.response!.body.text, '{"via":"fallback"}');
  });

  test('an adapter that cannot replay falls back', () async {
    final adapter = _FakeAdapter('dio', supportsReplay: false);
    final result = await replayCall(
      _original('dio'),
      _request(),
      [adapter],
      engine: engine,
      fallbackClient: () => MockClient((_) async => http.Response('', 204)),
    );
    expect(result.viaFallback, isTrue);
    expect(adapter.sent, isEmpty);
    expect(result.response.statusCode, 204);
  });

  test('a changed request is tagged edited', () async {
    final original = _original('http');
    final edited = original.request.copyWith(
      url: Uri.parse('https://api.test/users?page=3'),
    );
    await replayCall(original, edited, [_FakeAdapter('http')], engine: engine);
    expect(sink.latest.single.tags, {CallTag.replayed, CallTag.edited});
    expect(sink.latest.single.request.url, edited.url);
  });

  test(
    'changed headers, body or method are edits; method case is not',
    () async {
      final original = _original('http');
      final adapter = _FakeAdapter('http');
      Future<Set<CallTag>> tagsFor(ProxieRequest r) async {
        final result = await replayCall(original, r, [adapter], engine: engine);
        return sink.latest.firstWhere((c) => c.id == result.callId).tags;
      }

      expect(await tagsFor(original.request.copyWith(method: 'post')), {
        CallTag.replayed,
      });
      expect(
        await tagsFor(
          original.request.copyWith(
            headers: {
              'x-trace': ['2'],
            },
          ),
        ),
        {CallTag.replayed, CallTag.edited},
      );
      expect(
        await tagsFor(
          original.request.copyWith(
            body: ProxieBody.from(
              Uint8List.fromList(utf8.encode('{"a":2}')),
              'application/json',
            ),
          ),
        ),
        {CallTag.replayed, CallTag.edited},
      );
      expect(await tagsFor(original.request.copyWith(method: 'PUT')), {
        CallTag.replayed,
        CallTag.edited,
      });
    },
  );

  test('a truncated body throws a StateError and records nothing', () async {
    final adapter = _FakeAdapter('http');
    final truncated = _request(
      body: ProxieBody(
        bytes: Uint8List.fromList([1, 2]),
        contentType: 'application/octet-stream',
        kind: BodyKind.binary,
        truncated: true,
        originalLength: 10,
      ),
    );
    final fallbackUsed = <bool>[];
    await expectLater(
      replayCall(_original('http', request: truncated), truncated, [
        adapter,
      ], engine: engine),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      replayCall(
        _original('gone', request: truncated),
        truncated,
        const [],
        engine: engine,
        fallbackClient: () => MockClient((_) async {
          fallbackUsed.add(true);
          return http.Response('', 200);
        }),
      ),
      throwsA(isA<StateError>()),
    );
    expect(adapter.sent, isEmpty);
    expect(fallbackUsed, isEmpty);
    expect(sink.calls, isEmpty);
  });

  test('a failed send is recorded with its error and rethrown', () async {
    final adapter = _FakeAdapter(
      'http',
      fail: const SocketException('Connection refused'),
    );
    await expectLater(
      replayCall(_original('http'), _request(), [adapter], engine: engine),
      throwsA(isA<SocketException>()),
    );
    final recorded = sink.latest.single;
    expect(recorded.error!.type, 'network');
    expect(recorded.error!.message, contains('Connection refused'));
    expect(recorded.tags, {CallTag.replayed});

    final timeout = _FakeAdapter('http', fail: TimeoutException('slow'));
    await expectLater(
      replayCall(_original('http'), _request(), [timeout], engine: engine),
      throwsA(isA<TimeoutException>()),
    );
    expect(sink.latest.last.error!.type, 'timeout');
  });

  test('the adapter classifies its own failure', () async {
    final adapter = _FakeAdapter(
      'http',
      fail: Exception('library specific'),
      classified: const ProxieError(type: 'bad_certificate', message: 'bad'),
    );
    await expectLater(
      replayCall(_original('http'), _request(), [adapter], engine: engine),
      throwsA(isA<Exception>()),
    );
    expect(sink.latest.single.error!.type, 'bad_certificate');
    expect(sink.latest.single.error!.message, 'bad');
  });

  test('the fallback classifies timeouts and client errors', () async {
    Future<String> typeFor(Exception e) async {
      await expectLater(
        replayCall(
          _original('gone'),
          _request(),
          const [],
          engine: engine,
          fallbackClient: () => MockClient((_) async => throw e),
        ),
        throwsA(isA<Exception>()),
      );
      return sink.latest.last.error!.type;
    }

    expect(await typeFor(TimeoutException('slow')), 'timeout');
    expect(await typeFor(http.ClientException('refused')), 'network');
  });

  test('a throwing client factory records the failure', () async {
    await expectLater(
      replayCall(
        _original('gone'),
        _request(),
        const [],
        engine: engine,
        fallbackClient: () => throw StateError('no client'),
      ),
      throwsA(isA<StateError>()),
    );
    final recorded = sink.latest.single;
    expect(recorded.error!.type, 'network');
    expect(recorded.error!.message, contains('no client'));
    expect(recorded.duration, isNotNull);
  });

  test('a throwing classifier falls back to the default', () async {
    final adapter = _BadClassifier(fail: TimeoutException('slow'));
    await expectLater(
      replayCall(_original('bad'), _request(), [adapter], engine: engine),
      throwsA(isA<TimeoutException>()),
    );
    expect(sink.latest.single.error!.type, 'timeout');
  });

  group('cancel', () {
    test('after the response changes nothing', () async {
      final cancel = Completer<void>();
      final result = await replayCall(
        _original('http'),
        _request(),
        [_FakeAdapter('http')],
        engine: engine,
        cancel: cancel.future,
      );
      expect(result.response.statusCode, 201);
      final snapshots = sink.calls.length;
      cancel.complete();
      await Future<void>.delayed(Duration.zero);
      expect(sink.calls, hasLength(snapshots));
      expect(sink.latest.single.response!.statusCode, 201);
      expect(sink.latest.single.error, isNull);
    });

    test('records the call as cancelled and throws', () async {
      final cancel = Completer<void>();
      final gate = Completer<void>();
      final sending = replayCall(
        _original('gated'),
        _request(),
        [_GatedAdapter(gate.future)],
        engine: engine,
        cancel: cancel.future,
      );
      await Future<void>.delayed(Duration.zero);
      expect(sink.latest.single.error, isNull);

      cancel.complete();
      await expectLater(sending, throwsA(isA<ReplayCancelled>()));
      final recorded = sink.latest.single;
      expect(recorded.error!.type, 'cancelled');
      expect(recorded.error!.message, kReplayCancelledMessage);
      expect(recorded.response, isNull);
      expect(recorded.duration, isNotNull);
      expect(recorded.tags, {CallTag.replayed});

      // The late response changes nothing.
      final snapshots = sink.calls.length;
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(sink.calls, hasLength(snapshots));
      expect(sink.latest.single.error!.type, 'cancelled');
    });

    test('a late failure changes nothing and is not unhandled', () async {
      final cancel = Completer<void>();
      final gate = Completer<void>();
      final adapter = _GatedAdapter(
        gate.future,
        fail: const SocketException('late'),
      );
      final sending = replayCall(
        _original('gated'),
        _request(),
        [adapter],
        engine: engine,
        cancel: cancel.future,
      );
      await Future<void>.delayed(Duration.zero);
      cancel.complete();
      await expectLater(sending, throwsA(isA<ReplayCancelled>()));
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(sink.latest.single.error!.type, 'cancelled');
    });

    test('closes the fallback client, ending its request', () async {
      final cancel = Completer<void>();
      final client = _HangingClient();
      final sending = replayCall(
        _original('gone'),
        _request(),
        const [],
        engine: engine,
        cancel: cancel.future,
        fallbackClient: () => client,
      );
      await Future<void>.delayed(Duration.zero);
      expect(client.closed, isFalse);
      cancel.complete();
      await expectLater(sending, throwsA(isA<ReplayCancelled>()));
      expect(client.closed, isTrue);
      expect(sink.latest.single.error!.type, 'cancelled');
    });

    test('never completing it does not affect the send', () async {
      final result = await replayCall(
        _original('http'),
        _request(),
        [_FakeAdapter('http')],
        engine: engine,
        cancel: Completer<void>().future,
      );
      expect(result.response.statusCode, 201);
      expect(sink.latest.single.error, isNull);
    });
  });

  test('rules are not consulted for a replay', () async {
    engine.rules = RuleSet([
      mapLocalRule('https://api.test/*', const MapLocalAction()),
      breakpointRule('https://api.test/*', BreakpointPhase.both),
    ]);
    final adapter = _FakeAdapter('http');
    final result = await replayCall(_original('http'), _request(), [
      adapter,
    ], engine: engine);
    expect(adapter.sent, hasLength(1));
    expect(result.response.statusCode, 201);
    expect(engine.breakpoints.pending, isEmpty);
    expect(sink.latest.single.tags, {CallTag.replayed});
  });

  group('with the HttpOverrides adapter attached', () {
    final io = IoHarness()..install();

    test('the built-in fallback records exactly one call', () async {
      final original = _original(
        'gone',
        request: _request(url: io.server.url('/echo').toString()),
      );
      final result = await replayCall(original, original.request, [
        io.adapter,
      ], engine: io.engine);
      expect(result.viaFallback, isTrue);
      expect(result.response.statusCode, 200);
      final echoed =
          jsonDecode(result.response.body.text!) as Map<String, dynamic>;
      expect(echoed['method'], 'POST');
      expect(echoed['body'], '{"a":1}');
      expect(io.server.hitsFor('/echo'), 1);
      final recorded = io.sink.latest;
      expect(recorded, hasLength(1));
      expect(recorded.single.adapter, kReplayFallbackAdapter);
      expect(recorded.single.response!.statusCode, 200);
    });

    test('an io call replays through the io adapter, recorded once', () async {
      final original = _original(
        'io',
        request: _request(url: io.server.url('/json').toString()),
      );
      final result = await replayCall(
        original,
        original.request.copyWith(method: 'GET', body: ProxieBody.empty()),
        [io.adapter],
        engine: io.engine,
      );
      expect(result.viaFallback, isFalse);
      expect(result.sentVia, 'Sent via io');
      expect(result.response.body.text, '{"hello":"world"}');
      expect(io.sink.latest, hasLength(1));
      expect(io.sink.latest.single.tags, {CallTag.replayed, CallTag.edited});
    });
  });
}

class _BadClassifier extends _FakeAdapter {
  _BadClassifier({super.fail}) : super('bad');

  @override
  ProxieError classifyReplayError(Object error) =>
      throw StateError('classifier failed');
}

class _GatedAdapter extends _FakeAdapter {
  _GatedAdapter(this.gate, {super.fail}) : super('gated');

  final Future<void> gate;

  @override
  Future<ProxieResponse> replay(ProxieRequest request) async {
    await gate;
    return await super.replay(request);
  }
}

/// A client whose requests never answer until it is closed.
class _HangingClient extends http.BaseClient {
  final _closed = Completer<http.StreamedResponse>();

  bool get closed => _closed.isCompleted;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _closed.future;

  @override
  void close() =>
      _closed.completeError(http.ClientException('closed'), StackTrace.empty);
}
