import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';

/// What an adapter should do with a request.
sealed class RequestDecision {
  const RequestDecision();
}

/// Send [request] (possibly edited) to the network.
class Proceed extends RequestDecision {
  /// Creates a decision that sends [request].
  const Proceed(this.request);

  /// The request to send to the network.
  final ProxieRequest request;
}

/// Answer locally per [action] instead of hitting the network.
class Mock extends RequestDecision {
  /// Creates a decision that answers with [action].
  const Mock(this.action);

  /// The local response or simulated failure to answer with.
  final MapLocalAction action;
}

/// Fail the request with [error].
class AbortRequest extends RequestDecision {
  /// Creates a decision that fails the request with [error].
  const AbortRequest(this.error);

  /// Why the request is failed; adapters report its message to the app.
  final ProxieError error;
}

/// Thrown by `onResponse` when a response breakpoint is aborted.
class ProxieAbortedException implements Exception {
  /// Creates the exception for a response aborted with [error].
  const ProxieAbortedException(this.error);

  /// The error recorded for the aborted call.
  final ProxieError error;

  @override
  String toString() => 'ProxieAbortedException: ${error.message}';
}
