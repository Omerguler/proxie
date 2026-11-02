/// The types a third-party capture adapter needs, kept apart from the main
/// `package:proxie/proxie.dart` API.
///
/// An adapter implements [ProxieCaptureAdapter] and receives its engine only
/// through [ProxieCaptureAdapter.attach]. Per call it asks
/// [ProxieEngine.onRequest] for a [RequestDecision], then reports the outcome
/// with [ProxieEngine.onResponse], [ProxieEngine.recordResponse] or
/// [ProxieEngine.onError]. Code that sends requests some other Proxie adapter
/// would also see runs inside [runMarkedCaptured], so the call is recorded
/// once.
library;

export 'src/adapters/capture_adapter.dart' show ProxieCaptureAdapter;
export 'src/adapters/capture_marker.dart'
    show kProxieCapturedZoneKey, runMarkedCaptured, isProxieCaptured;
export 'src/config.dart' show ProxieConfig;
export 'src/core/decision.dart'
    show RequestDecision, Proceed, Mock, AbortRequest, ProxieAbortedException;
export 'src/core/engine.dart' show ProxieEngine, CallSink;
export 'src/core/rule.dart' show MapLocalAction, SimulatedFailure;
export 'src/model/body.dart' show ProxieBody, BodyKind, defaultBodyCap;
export 'src/model/call.dart' show ProxieError;
export 'src/model/request.dart' show ProxieRequest;
export 'src/model/response.dart' show ProxieResponse;
