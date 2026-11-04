import 'dart:async';

import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// The usual classification of a failed replay: a [TimeoutException] is a
/// `timeout`, anything else `network`. For adapters whose library has no
/// exceptions of its own to tell apart.
ProxieError defaultReplayError(Object error) => ProxieError(
  type: error is TimeoutException ? 'timeout' : 'network',
  message: '$error',
);

/// Connects one HTTP stack to a [ProxieEngine].
///
/// While no engine is attached the adapter is a pure pass-through.
abstract interface class ProxieCaptureAdapter {
  /// Short adapter id recorded on each call (for example `http`).
  String get name;

  /// Whether [replay] is supported.
  bool get supportsReplay;

  /// Starts capturing calls into [engine].
  void attach(ProxieEngine engine);

  /// Stops capturing; later calls pass straight through.
  void detach();

  /// Sends [request] again and returns the full response, without recording.
  ///
  /// Throws a [StateError] when `request.body.truncated` is set: the full
  /// body was not kept, so it cannot be sent again faithfully.
  Future<ProxieResponse> replay(ProxieRequest request);

  /// What [error], thrown by [replay], is recorded as. Only this adapter
  /// knows its library's exceptions; see [defaultReplayError].
  ProxieError classifyReplayError(Object error);
}
