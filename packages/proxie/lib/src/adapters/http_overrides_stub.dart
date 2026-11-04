import 'package:proxie/src/adapters/capture_adapter.dart';
import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/model/response.dart';

/// Web stand-in for the `dart:io` `HttpOverrides` adapter.
///
/// `dart:io` does not exist on the web, so there is nothing to capture:
/// [attach] and [detach] do nothing and [replay] is unsupported. Use the
/// `package:http` or Dio adapters there.
class ProxieHttpOverridesAdapter implements ProxieCaptureAdapter {
  @override
  String get name => 'io';

  @override
  bool get supportsReplay => false;

  @override
  void attach(ProxieEngine engine) {}

  @override
  void detach() {}

  @override
  Future<ProxieResponse> replay(ProxieRequest request) =>
      throw UnsupportedError('dart:io is not available on this platform');

  @override
  ProxieError classifyReplayError(Object error) => defaultReplayError(error);
}
