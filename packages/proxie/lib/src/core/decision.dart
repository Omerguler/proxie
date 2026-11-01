import '../model/call.dart';
import '../model/request.dart';
import 'rule.dart';

/// What an adapter should do with a request.
sealed class RequestDecision {
  const RequestDecision();
}

/// Send [request] (possibly edited) to the network.
class Proceed extends RequestDecision {
  const Proceed(this.request);

  final ProxieRequest request;
}

/// Answer locally per [action] instead of hitting the network.
class Mock extends RequestDecision {
  const Mock(this.action);

  final MapLocalAction action;
}

/// Fail the request with [error].
class AbortRequest extends RequestDecision {
  const AbortRequest(this.error);

  final ProxieError error;
}
