import '../core/engine.dart';
import '../model/request.dart';
import '../model/response.dart';

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
}
