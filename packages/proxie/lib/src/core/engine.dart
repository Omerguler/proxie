import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:proxie/src/config.dart';
import 'package:proxie/src/core/breakpoint_controller.dart';
import 'package:proxie/src/core/decision.dart';
import 'package:proxie/src/core/message_compare.dart';
import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// Receives call snapshots (unmasked; the worker masks before storing).
abstract interface class CallSink {
  /// Stores or replaces the snapshot of [call], keyed by its id.
  void upsert(ProxieCall call);
}

class _CallState {
  _CallState(this.request, this.adapter, this.startedAt);

  ProxieRequest request;
  final String adapter;
  final DateTime startedAt;
  final tags = <CallTag>{};
}

/// Decides what happens to each captured call and records snapshots.
///
/// The [sink] receives unmasked calls; the [calls] stream carries copies with
/// masked headers and bodies stripped (no JSON work on the UI isolate).
class ProxieEngine {
  /// Creates an engine; without [breakpoints] it owns a controller that uses
  /// the configured breakpoint timeout.
  ProxieEngine({
    required this.config,
    required this.sink,
    BreakpointController? breakpoints,
    this.sessionId = 0,
  }) : _ownsBreakpoints = breakpoints == null,
       breakpoints =
           breakpoints ??
           BreakpointController(timeout: config.breakpointTimeout);

  /// The settings, such as the body capture cap and breakpoint timeout.
  final ProxieConfig config;

  /// Where every call snapshot goes, unmasked.
  final CallSink sink;

  /// Holds the calls paused at breakpoints.
  final BreakpointController breakpoints;
  final bool _ownsBreakpoints;

  /// The rules consulted for each call; replace it to change them.
  RuleSet rules = RuleSet(const []);

  /// The session that recorded calls are stamped with.
  int sessionId;

  final _states = <String, _CallState>{};
  final _calls = StreamController<ProxieCall>.broadcast();
  int _counter = 0;
  bool _disposed = false;

  /// Masked, body-free snapshots of each call as it changes, for the UI.
  Stream<ProxieCall> get calls => _calls.stream;

  /// A call id unique within this engine (not across engines or sessions).
  String newCallId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  /// Releases pending breakpoints and closes streams.
  void dispose() {
    _disposed = true;
    for (final id in _states.keys.toList()) {
      breakpoints.resolve(id, const ContinueUnchanged());
    }
    _states.clear();
    if (_ownsBreakpoints) breakpoints.dispose();
    unawaited(_calls.close());
  }

  /// Records the start of call [callId] and decides what happens to [req].
  ///
  /// Pauses at a matching request breakpoint first, then answers from a
  /// matching Map Local rule if there is one; otherwise the (possibly edited)
  /// request proceeds.
  Future<RequestDecision> onRequest(
    String callId,
    String adapter,
    ProxieRequest req,
  ) async {
    if (_disposed) return Proceed(req);
    final state = _CallState(req, adapter, DateTime.now());
    if (_states.containsKey(callId)) {
      breakpoints.resolve(callId, const ContinueUnchanged());
    }
    _states[callId] = state;

    var current = req;
    final paused = _guard(() => rules.requestBreakpointFor(req)) != null;
    if (paused) state.tags.add(CallTag.breakpoint);
    _emit(callId, state);
    if (paused) {
      final r = await breakpoints.pause(
        PausedCall(
          callId: callId,
          phase: BreakpointPhase.request,
          request: req,
          pausedAt: DateTime.now(),
        ),
      );
      // The call failed or was replaced while paused: stop recording.
      if (!identical(_states[callId], state)) return Proceed(current);
      switch (r) {
        case ExecuteRequest(:final request):
          current = request;
          if (!sameRequest(req, request)) state.tags.add(CallTag.edited);
        case Abort():
          const error = ProxieError(
            type: 'aborted',
            message: 'Aborted at breakpoint',
          );
          onError(callId, error);
          return const AbortRequest(error);
        case ExecuteResponse():
          assert(false, 'ExecuteResponse resolved a request breakpoint');
        case ContinueUnchanged():
          break;
      }
      state.request = current;
      if (state.tags.contains(CallTag.edited)) _emit(callId, state);
    }

    final rule = _guard(() => rules.mapLocalFor(current));
    final action = rule?.mapLocal;
    if (action != null) {
      state.tags.add(CallTag.mapLocal);
      _emit(callId, state);
      return Mock(action);
    }
    return Proceed(current);
  }

  /// Records the start of call [callId] that Proxie sends itself (a replay
  /// from the inspector), stamped with [tags]. No rules are consulted:
  /// nothing pauses or answers it. Finish it with [recordResponse] or
  /// [onError].
  void recordRequest(
    String callId,
    String adapter,
    ProxieRequest req, {
    Set<CallTag> tags = const {},
  }) {
    if (_disposed) return;
    if (_states.containsKey(callId)) {
      breakpoints.resolve(callId, const ContinueUnchanged());
    }
    final state = _CallState(req, adapter, DateTime.now());
    state.tags.addAll(tags);
    _states[callId] = state;
    _emit(callId, state);
  }

  /// Records [res] for call [callId] and returns the response for the app.
  ///
  /// Pauses at a matching response breakpoint first, which may edit the
  /// response. Throws a [ProxieAbortedException] when the call is aborted
  /// there.
  Future<ProxieResponse> onResponse(String callId, ProxieResponse res) async {
    if (_disposed) return res;
    final state = _states[callId];
    if (state == null) return res;
    var current = res;
    if (_guard(() => rules.responseBreakpointFor(state.request)) != null) {
      state.tags.add(CallTag.breakpoint);
      final r = await breakpoints.pause(
        PausedCall(
          callId: callId,
          phase: BreakpointPhase.response,
          request: state.request,
          response: res,
          pausedAt: DateTime.now(),
        ),
      );
      if (!identical(_states[callId], state)) return current;
      if (r is Abort) {
        const error = ProxieError(
          type: 'aborted',
          message: 'Aborted at response breakpoint',
        );
        _fail(callId, error, response: res);
        throw const ProxieAbortedException(error);
      }
      assert(
        r is! ExecuteRequest,
        'ExecuteRequest resolved a response breakpoint',
      );
      if (r is ExecuteResponse) {
        current = r.response;
        if (!sameResponse(res, r.response)) state.tags.add(CallTag.edited);
      }
    }
    _states.remove(callId);
    _emit(callId, state, response: current);
    return current;
  }

  /// Records [res] as the final response without consulting breakpoints.
  ///
  /// For responses the app already received (streamed through), where a
  /// pause or edit could no longer take effect. Unknown calls are ignored.
  void recordResponse(String callId, ProxieResponse res) {
    if (_disposed) return;
    final state = _states.remove(callId);
    if (state == null) return;
    _emit(callId, state, response: res);
  }

  /// Records [err] as the outcome of the call, with the [response] received
  /// so far, if any (for example a partial body before a stream failed).
  void onError(String callId, ProxieError err, {ProxieResponse? response}) =>
      _fail(callId, err, response: response);

  void _fail(String callId, ProxieError err, {ProxieResponse? response}) {
    final state = _states.remove(callId);
    if (state == null) return;
    breakpoints.resolve(callId, const ContinueUnchanged());
    _emit(callId, state, response: response, error: err);
  }

  T? _guard<T>(T Function() f) {
    try {
      return f();
    } on Object catch (e, st) {
      developer.log('Proxie rule lookup failed', error: e, stackTrace: st);
      return null;
    }
  }

  ProxieBody _stripBody(ProxieBody b) => ProxieBody(
    bytes: Uint8List(0),
    contentType: b.contentType,
    kind: b.kind,
    truncated: b.truncated,
    originalLength: b.originalLength,
  );

  /// Records a snapshot of the call: unmasked to the [sink], then masked and
  /// body-stripped to the [calls] stream.
  ///
  /// Recording must never break live traffic, so each of the two blocks is
  /// guarded separately and a failure is only logged; a failing sink does not
  /// stop the stream emit. Does nothing once the engine is disposed.
  void _emit(
    String callId,
    _CallState s, {
    ProxieResponse? response,
    ProxieError? error,
  }) {
    if (_disposed) return;
    final done = response != null || error != null;
    final tags = {...s.tags};
    if (s.request.body.truncated || (response?.body.truncated ?? false)) {
      tags.add(CallTag.truncated);
    }
    final duration = done ? DateTime.now().difference(s.startedAt) : null;
    ProxieCall build(ProxieRequest rq, ProxieResponse? rs) => ProxieCall(
      id: callId,
      sessionId: sessionId,
      adapter: s.adapter,
      request: rq,
      response: rs,
      error: error,
      startedAt: s.startedAt,
      duration: duration,
      tags: tags,
    );
    try {
      sink.upsert(build(s.request, response));
    } on Object catch (e, st) {
      developer.log('Proxie sink failed', error: e, stackTrace: st);
    }
    try {
      if (_calls.isClosed) return;
      final masking = config.masking;
      _calls.add(
        build(
          masking.maskRequest(
            s.request.copyWith(body: _stripBody(s.request.body)),
          ),
          response == null
              ? null
              : masking.maskResponse(
                  response.copyWith(body: _stripBody(response.body)),
                ),
        ),
      );
    } on Object catch (e, st) {
      developer.log('Proxie stream failed', error: e, stackTrace: st);
    }
  }
}
