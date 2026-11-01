import 'dart:async';

import '../config.dart';
import '../model/call.dart';
import '../model/request.dart';
import '../model/response.dart';
import 'breakpoint_controller.dart';
import 'decision.dart';
import 'rule.dart';

/// Receives masked call snapshots.
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

/// Decides what happens to each captured call and records masked copies.
class ProxieEngine {
  ProxieEngine({
    required this.config,
    required this.sink,
    required this.breakpoints,
    this.sessionId = 0,
  });

  final ProxieConfig config;
  final CallSink sink;
  final BreakpointController breakpoints;

  RuleSet rules = const RuleSet([]);
  int sessionId;

  final _states = <String, _CallState>{};
  final _calls = StreamController<ProxieCall>.broadcast();
  int _counter = 0;

  Stream<ProxieCall> get calls => _calls.stream;

  String newCallId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_counter++}';

  Future<RequestDecision> onRequest(
    String callId,
    String adapter,
    ProxieRequest req,
  ) async {
    final state = _CallState(req, adapter, DateTime.now());
    _states[callId] = state;

    var current = req;
    final paused = rules.requestBreakpointFor(req) != null;
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
        case ContinueUnchanged():
          break;
      }
      state.request = current;
      if (state.tags.contains(CallTag.edited)) _emit(callId, state);
    }

    final rule = rules.mapLocalFor(current);
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
    if (rules.responseBreakpointFor(state.request) != null) {
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
      // Abort has no meaning once a response exists; it continues unchanged.
      if (r is ExecuteResponse) {
        current = r.response;
        if (!_sameResponse(res, r.response)) state.tags.add(CallTag.edited);
      }
    }
    _states.remove(callId);
    _emit(callId, state, response: current);
    return current;
  }

  void onError(String callId, ProxieError err) {
    final state = _states.remove(callId);
    if (state == null) return;
    _emit(callId, state, error: err);
  }

  void _emit(
    String callId,
    _CallState s, {
    ProxieResponse? response,
    ProxieError? error,
  }) {
    final done = response != null || error != null;
    final masking = config.masking;
    final tags = {...s.tags};
    if (s.request.body.truncated || (response?.body.truncated ?? false)) {
      tags.add(CallTag.truncated);
    }
    final call = ProxieCall(
      id: callId,
      sessionId: sessionId,
      adapter: s.adapter,
      request: masking.maskRequest(s.request),
      response: response == null ? null : masking.maskResponse(response),
      error: error,
      startedAt: s.startedAt,
      duration: done ? DateTime.now().difference(s.startedAt) : null,
      tags: tags,
    );
    sink.upsert(call);
    _calls.add(call);
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
