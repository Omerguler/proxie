import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';

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

  ProxieEngine makeEngine({
    ProxieConfig config = const ProxieConfig(
      breakpointTimeout: Duration(seconds: 5),
    ),
  }) => ProxieEngine(config: config, sink: sink);

  /// Sends [method] [path] with a fresh `HttpClient()`, closed (not forced)
  /// right after the request is closed, as apps commonly do, unless
  /// [closeClient] is false (dart:io cannot follow redirects on a closed
  /// client).
  Future<HttpClientResponse> send(
    String method,
    String path, {
    void Function(HttpClientRequest)? prepare,
    bool closeClient = true,
  }) async {
    final client = HttpClient();
    final req = await client.openUrl(method, server.url(path));
    prepare?.call(req);
    final res = req.close();
    if (closeClient) client.close();
    return await res;
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
        unawaited(sub.cancel());
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
