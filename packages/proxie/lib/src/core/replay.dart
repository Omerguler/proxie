import 'dart:async';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import 'package:proxie/src/adapters/capture_adapter.dart';
import 'package:proxie/src/adapters/http_client_adapter.dart';
import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/core/message_compare.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// The adapter name a replay sent by Proxie's own client is recorded with.
const String kReplayFallbackAdapter = 'built-in';

/// What is said and recorded when a replay is cancelled. The request may
/// already be out, and an adapter's goes on, so only the wait is certain to
/// have stopped.
const String kReplayCancelledMessage =
    'Stopped waiting. The request may still reach the server.';

/// Thrown by [replayCall] when its `cancel` completes first.
class ReplayCancelled implements Exception {
  /// Creates the exception.
  const ReplayCancelled();

  @override
  String toString() => kReplayCancelledMessage;
}

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
/// partial payload is never sent. A failed send is recorded as the adapter
/// classifies it and rethrown.
///
/// When [cancel] completes first the call is recorded as `cancelled`, a
/// late response or failure is ignored and [ReplayCancelled] is thrown. Only
/// the fallback client's connection is closed: an adapter's request goes on,
/// unseen, and either may already have reached the server.
Future<ReplayResult> replayCall(
  ProxieCall original,
  ProxieRequest edited,
  List<ProxieCaptureAdapter> adapters, {
  required ProxieEngine engine,
  http.Client Function()? fallbackClient,
  Future<void>? cancel,
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
      if (!sameRequest(original.request, edited)) CallTag.edited,
    },
  );
  ProxieHttpClient? fallback;
  try {
    // Inside the try: a factory that throws must still finish the call. Its
    // request is marked captured by its replay.
    final sender =
        adapter ??
        (fallback = ProxieHttpClient(
          inner: (fallbackClient ?? http.Client.new)(),
        )..attach(engine));
    final sending = sender.replay(edited);
    final response = cancel == null
        ? await sending
        // Future.any also takes care of what the loser does later.
        : await Future.any<ProxieResponse?>([
            sending,
            cancel.then((_) => null),
          ]);
    if (response == null) {
      engine.onError(
        callId,
        const ProxieError(type: 'cancelled', message: kReplayCancelledMessage),
      );
      throw const ReplayCancelled();
    }
    engine.recordResponse(callId, response);
    return ReplayResult(
      callId: callId,
      response: response,
      adapterName: name,
      viaFallback: viaFallback,
    );
  } on ReplayCancelled {
    rethrow;
  } on Object catch (e) {
    engine.onError(callId, _classified(adapter, e));
    rethrow;
  } finally {
    fallback?.close();
  }
}

// An adapter's classification must not hide the failure it describes. The
// fallback client (null [adapter]) classifies with the default too.
ProxieError _classified(ProxieCaptureAdapter? adapter, Object error) {
  if (adapter == null) return defaultReplayError(error);
  try {
    return adapter.classifyReplayError(error);
  } on Object catch (e, st) {
    developer.log(
      'Proxie adapter ${adapter.name} failed to classify an error',
      name: 'proxie',
      error: e,
      stackTrace: st,
    );
    return defaultReplayError(error);
  }
}
