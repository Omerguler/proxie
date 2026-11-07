import 'dart:async';

import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// How a paused call was resolved.
sealed class BreakpointResolution {
  const BreakpointResolution();
}

/// Continue with an edited request.
class ExecuteRequest extends BreakpointResolution {
  /// Creates a resolution that sends [request] instead of the captured one.
  const ExecuteRequest(this.request);

  /// The request to send.
  final ProxieRequest request;
}

/// Continue with an edited response.
class ExecuteResponse extends BreakpointResolution {
  /// Creates a resolution that hands [response] to the app.
  const ExecuteResponse(this.response);

  /// The response the app receives.
  final ProxieResponse response;
}

/// Abort the call.
class Abort extends BreakpointResolution {
  /// Creates a resolution that fails the call.
  const Abort();
}

/// Continue exactly as captured.
class ContinueUnchanged extends BreakpointResolution {
  /// Creates a resolution that lets the call go on as captured.
  const ContinueUnchanged();
}

/// A call waiting at a breakpoint.
class PausedCall {
  /// Describes a call paused at [phase]; [response] is set for response
  /// breakpoints only.
  const PausedCall({
    required this.callId,
    required this.phase,
    required this.request,
    required this.pausedAt,
    this.response,
  });

  /// The id of the paused call.
  final String callId;

  /// Whether the call paused before sending or after the response.
  final BreakpointPhase phase;

  /// The request as captured, or as edited at an earlier breakpoint.
  final ProxieRequest request;

  /// The response received, for a response breakpoint; otherwise null.
  final ProxieResponse? response;

  /// When the call was paused; its timeout runs from here.
  final DateTime pausedAt;
}

/// Holds paused calls in arrival order until resolved or timed out.
class BreakpointController {
  /// Creates a controller whose paused calls continue unchanged after
  /// [timeout].
  BreakpointController({this.timeout = const Duration(seconds: 60)});

  /// How long a call stays paused before it continues unchanged.
  final Duration timeout;
  final _entries = <String, _Entry>{};
  final _changes = StreamController<List<PausedCall>>.broadcast();

  /// Paused calls, oldest first.
  List<PausedCall> get pending => [for (final e in _entries.values) e.call];

  /// Emits the pending list whenever a call is added or removed.
  Stream<List<PausedCall>> get changes => _changes.stream;

  /// Pauses [p]; completes when resolved, or with [ContinueUnchanged] on
  /// timeout.
  Future<BreakpointResolution> pause(PausedCall p) {
    resolve(p.callId, const ContinueUnchanged());
    final entry = _Entry(p, DateTime.now().add(timeout))
      ..timer = Timer(
        timeout,
        () => resolve(p.callId, const ContinueUnchanged()),
      );
    _entries[p.callId] = entry;
    _notify();
    return entry.completer.future;
  }

  /// When the paused call [callId] continues unchanged unless resolved
  /// first; null when it is not paused.
  DateTime? deadlineOf(String callId) => _entries[callId]?.deadline;

  /// Resolves a paused call; unknown ids are ignored.
  void resolve(String callId, BreakpointResolution r) {
    final entry = _entries.remove(callId);
    if (entry == null) return;
    entry.timer?.cancel();
    entry.completer.complete(r);
    _notify();
  }

  /// Resolves everything pending as [ContinueUnchanged] and closes [changes].
  void dispose() {
    for (final id in _entries.keys.toList()) {
      resolve(id, const ContinueUnchanged());
    }
    unawaited(_changes.close());
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(pending);
  }
}

class _Entry {
  _Entry(this.call, this.deadline);

  final PausedCall call;
  final DateTime deadline;
  final completer = Completer<BreakpointResolution>();
  Timer? timer;
}
