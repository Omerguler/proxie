import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:proxie/src/adapters/capture_adapter.dart';
import 'package:proxie/src/adapters/capture_marker.dart';
import 'package:proxie/src/adapters/http_client_adapter.dart';
import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// The adapter name a replay sent by Proxie's own client is recorded with.
const String kReplayFallbackAdapter = 'built-in';

/// The outcome of [replayCall].
class ReplayResult {
  /// Describes a replay recorded as call [callId].
  const ReplayResult({
    required this.callId,
    required this.response,
    required this.adapterName,
    required this.viaFallback,
  });

  /// The id of the new call recorded for the replay.
  final String callId;

  /// The full response received.
  final ProxieResponse response;

  /// The adapter that sent it, or [kReplayFallbackAdapter].
  final String adapterName;

  /// Whether Proxie's own client sent it, skipping the app's interceptors
  /// (the call's adapter is gone or cannot replay).
  final bool viaFallback;

  /// How it was sent, for people.
  String get sentVia => viaFallback
      ? 'Sent via built-in client (app interceptors skipped)'
      : 'Sent via $adapterName';
}

/// Sends [edited] (the request of [original], possibly changed) again and
/// records it in [engine] as a new call tagged [CallTag.replayed], plus
/// [CallTag.edited] when it differs from the original request. No rules
/// apply to it.
///
/// Sends through the adapter of [adapters] named `original.adapter` when it
/// supports replay; otherwise through a new `http.Client` (or one from
/// [fallbackClient]) whose requests are marked captured, so a lower-level
/// adapter does not record it a second time.
///
/// Throws a [StateError], recording nothing, when the body is truncated: a
/// partial payload is never sent. A failed send is recorded with its error
/// and rethrown.
Future<ReplayResult> replayCall(
  ProxieCall original,
  ProxieRequest edited,
  List<ProxieCaptureAdapter> adapters, {
  required ProxieEngine engine,
  http.Client Function()? fallbackClient,
}) async {
  if (edited.body.truncated) {
    throw StateError('Cannot replay: request body was truncated');
  }
  ProxieCaptureAdapter? adapter;
  for (final a in adapters) {
    if (a.name == original.adapter && a.supportsReplay) {
      adapter = a;
      break;
    }
  }
  final viaFallback = adapter == null;
  final name = adapter?.name ?? kReplayFallbackAdapter;
  final callId = engine.newCallId();
  engine.recordRequest(
    callId,
    name,
    edited,
    tags: {
      CallTag.replayed,
      if (!sameReplayedRequest(original.request, edited)) CallTag.edited,
    },
  );
  final ProxieResponse response;
  try {
    response = adapter != null
        ? await adapter.replay(edited)
        : await _sendFallback(engine, edited, fallbackClient);
  } on Object catch (e) {
    engine.onError(
      callId,
      ProxieError(
        type: e is TimeoutException ? 'timeout' : 'network',
        message: '$e',
      ),
    );
    rethrow;
  }
  engine.recordResponse(callId, response);
  return ReplayResult(
    callId: callId,
    response: response,
    adapterName: name,
    viaFallback: viaFallback,
  );
}

Future<ProxieResponse> _sendFallback(
  ProxieEngine engine,
  ProxieRequest request,
  http.Client Function()? create,
) => runMarkedCaptured(() async {
  // Unrecorded: ProxieHttpClient.replay sends inside the captured zone too.
  final client = ProxieHttpClient(inner: (create ?? http.Client.new)())
    ..attach(engine);
  try {
    return await client.replay(request);
  } finally {
    client.close();
  }
});

/// Whether [b] sends the same as [a]: method, URL, header values (names
/// compared case-insensitively, as HTTP does) and body bytes.
bool sameReplayedRequest(ProxieRequest a, ProxieRequest b) {
  if (a.method.toUpperCase() != b.method.toUpperCase() || a.url != b.url) {
    return false;
  }
  final ha = _lowered(a.headers);
  final hb = _lowered(b.headers);
  if (ha.length != hb.length) return false;
  for (final e in ha.entries) {
    final o = hb[e.key];
    if (o == null || !_sameList(o, e.value)) return false;
  }
  return _sameList(a.body.bytes, b.body.bytes);
}

Map<String, List<String>> _lowered(Map<String, List<String>> headers) {
  final out = <String, List<String>>{};
  for (final e in headers.entries) {
    (out[e.key.toLowerCase()] ??= []).addAll(e.value);
  }
  return out;
}

bool _sameList<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
