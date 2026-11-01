import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

import 'test_server.dart';

/// Records every snapshot the engine emits.
class RecordingSink implements CallSink {
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

/// Shared setup for the `HttpOverrides` adapter tests: a [TestServer], an
/// engine recording into [sink], and [adapter] attached to it, with the
/// global overrides cleared before and restored after each test.
class IoHarness {
  late TestServer server;
  late RecordingSink sink;
  late ProxieEngine engine;
  late ProxieHttpOverridesAdapter adapter;
  HttpOverrides? _saved;

  /// Registers setUp and tearDown for the enclosing suite.
  void install() {
    setUp(() async {
      _saved = globalOverrides();
      HttpOverrides.global = null;
      server = await startTestServer();
      sink = RecordingSink();
      engine = makeEngine();
      adapter = ProxieHttpOverridesAdapter()..attach(engine);
    });
    tearDown(() async {
      adapter.detach();
      HttpOverrides.global = _saved;
      engine.dispose();
      await server.close();
    });
  }

  ProxieEngine makeEngine({ProxieConfig config = const ProxieConfig()}) =>
      ProxieEngine(
        config: config,
        sink: sink,
        breakpoints: BreakpointController(timeout: const Duration(seconds: 5)),
      );

  /// Sends [method] [path] with a fresh `HttpClient()`.
  Future<HttpClientResponse> send(
    String method,
    String path, {
    void Function(HttpClientRequest)? prepare,
  }) async {
    final client = HttpClient();
    final req = await client.openUrl(method, server.url(path));
    prepare?.call(req);
    return req.close();
  }

  /// The decoded body of an `/echo` response.
  Future<Map<String, dynamic>> echo(HttpClientResponse res) async =>
      jsonDecode(await readText(res)) as Map<String, dynamic>;
}

ProxieRule mapLocalRule(String pattern, MapLocalAction action) => ProxieRule(
  id: 'ml',
  name: 'ml',
  kind: RuleKind.mapLocal,
  matcher: UrlMatcher(pattern),
  mapLocal: action,
);

ProxieRule breakpointRule(String pattern, BreakpointPhase phase) => ProxieRule(
  id: 'bp',
  name: 'bp',
  kind: RuleKind.breakpoint,
  matcher: UrlMatcher(pattern),
  phase: phase,
);

/// A JSON response with [body] (or the given headers [h]).
ProxieResponse jsonResponse(
  int status,
  String body, {
  Map<String, List<String>>? h,
}) => ProxieResponse(
  statusCode: status,
  headers:
      h ??
      {
        'content-type': ['application/json'],
      },
  body: ProxieBody.from(
    Uint8List.fromList(utf8.encode(body)),
    'application/json',
  ),
);

/// Resolves the next paused call in [phase] with [resolve].
void onPause(
  ProxieEngine engine,
  BreakpointPhase phase,
  BreakpointResolution Function(PausedCall) resolve,
) {
  late StreamSubscription<List<PausedCall>> sub;
  sub = engine.breakpoints.changes.listen((pending) {
    for (final p in pending) {
      if (p.phase == phase) {
        sub.cancel();
        engine.breakpoints.resolve(p.callId, resolve(p));
        return;
      }
    }
  });
}

/// The overrides set globally, ignoring zone overrides.
HttpOverrides? globalOverrides() => Zone.root.run(() => HttpOverrides.current);

/// [res]'s body as UTF-8 text.
Future<String> readText(HttpClientResponse res) => utf8.decodeStream(res);
