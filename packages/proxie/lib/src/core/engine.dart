import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import '../config.dart';
import '../model/body.dart';
import '../model/call.dart';
import '../model/request.dart';
import '../model/response.dart';
import 'breakpoint_controller.dart';
import 'decision.dart';
import 'rule.dart';

/// Receives call snapshots (unmasked; the worker masks before storing).
abstract interface class CallSink {
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
  ProxieEngine({
    required this.config,
    required this.sink,
    BreakpointController? breakpoints,
    this.sessionId = 0,
  }) : _ownsBreakpoints = breakpoints == null,
       breakpoints =
           breakpoints ??
           BreakpointController(timeout: config.breakpointTimeout);

  final ProxieConfig config;
  final CallSink sink;
  final BreakpointController breakpoints;
  final bool _ownsBreakpoints;

  RuleSet rules = const RuleSet([]);
  int sessionId;

  final _states = <String, _CallState>{};
  final _calls = StreamController<ProxieCall>.broadcast();
  int _counter = 0;
  bool _disposed = false;

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
    _calls.close();
  }

  Future<RequestDecision> onRequest(
    String callId,
    String adapter,
    ProxieRequest req,
  ) async {
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
          if (!_sameRequest(req, request)) state.tags.add(CallTag.edited);
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

  Future<ProxieResponse> onResponse(String callId, ProxieResponse res) async {
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
        if (!_sameResponse(res, r.response)) state.tags.add(CallTag.edited);
      }
    }
    _states.remove(callId);
    _emit(callId, state, response: current);
    return current;
  }

  void onError(String callId, ProxieError err) => _fail(callId, err);

  void _fail(String callId, ProxieError err, {ProxieResponse? response}) {
    final state = _states.remove(callId);
    if (state == null) return;
    breakpoints.resolve(callId, const ContinueUnchanged());
    _emit(callId, state, response: response, error: err);
  }

  T? _guard<T>(T Function() f) {
    try {
      return f();
    } catch (e, st) {
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

  /// Recording must never break live traffic, so failures are only logged.
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
    } catch (e, st) {
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
    } catch (e, st) {
      developer.log('Proxie stream failed', error: e, stackTrace: st);
    }
  }
}

bool _sameHeaders(Map<String, List<String>> a, Map<String, List<String>> b) {
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    final o = b[e.key];
    if (o == null || o.length != e.value.length) return false;
    for (var i = 0; i < o.length; i++) {
      if (o[i] != e.value[i]) return false;
    }
  }
  return true;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _sameRequest(ProxieRequest a, ProxieRequest b) =>
    a.method == b.method &&
    a.url == b.url &&
    _sameHeaders(a.headers, b.headers) &&
    _sameBytes(a.body.bytes, b.body.bytes);

bool _sameResponse(ProxieResponse a, ProxieResponse b) =>
    a.statusCode == b.statusCode &&
    a.reasonPhrase == b.reasonPhrase &&
    _sameHeaders(a.headers, b.headers) &&
    _sameBytes(a.body.bytes, b.body.bytes);
