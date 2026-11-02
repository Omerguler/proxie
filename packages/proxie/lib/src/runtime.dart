import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';

import 'package:proxie/src/adapters/capture_adapter.dart';
import 'package:proxie/src/config.dart';
import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/navigation/navigation_adapter.dart';
import 'package:proxie/src/navigation/overlay_navigation.dart';
import 'package:proxie/src/ui/bubble.dart';
import 'package:proxie/src/ui/inspector_shell.dart';
import 'package:proxie/src/worker/worker.dart';

/// The runtime of the active Proxie, or null while inactive. Set by the
/// facade, read by the layer `Proxie.wrap` draws.
final ValueNotifier<ProxieRuntime?> proxieActive = ValueNotifier(null);

/// Detaches [adapter], logging (never throwing) a failure.
void detachAdapter(ProxieCaptureAdapter adapter) {
  try {
    adapter.detach();
  } catch (e, st) {
    developer.log(
      'Proxie adapter ${adapter.name} failed to detach',
      name: 'proxie',
      error: e,
      stackTrace: st,
    );
  }
}

/// Everything an active Proxie owns.
class ProxieRuntime {
  ProxieRuntime({
    required this.worker,
    required this.engine,
    required this.adapters,
    required this.controller,
    required this.navigation,
    required this.config,
  }) : callCount = SessionCallCounter(engine.calls) {
    controller.addListener(_sync);
  }

  final ProxieWorker worker;
  final ProxieEngine engine;
  final List<ProxieCaptureAdapter> adapters;
  final ProxieInspectorController controller;
  final ProxieNavigationAdapter navigation;
  final SessionCallCounter callCount;
  final ProxieConfig config;
  bool _disposed = false;

  bool get isOverlay => navigation is OverlayNavigationAdapter;

  // The controller is the source of truth; the adapter follows it. A page
  // the host dismissed closes the controller through onDismissed.
  void _sync() {
    if (_disposed) return;
    if (controller.isOpen) {
      if (navigation.isShowing) return;
      try {
        navigation.show(
          ProxieInspector(
            controller: controller,
            splitWidth: config.splitWidth,
            themeMode: config.themeMode,
          ),
          onDismissed: _onDismissed,
        );
      } catch (e, st) {
        _report(e, st, 'while showing the Proxie inspector');
        controller.close();
      }
    } else if (navigation.isShowing) {
      try {
        navigation.hide();
      } catch (e, st) {
        _report(e, st, 'while hiding the Proxie inspector');
      }
    }
  }

  void _onDismissed() {
    if (!_disposed) controller.close();
  }

  void _report(Object error, StackTrace stack, String context) =>
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'proxie',
          context: ErrorDescription(context),
        ),
      );

  /// Hides the inspector, detaches the adapters, disposes everything owned,
  /// the worker last.
  Future<void> dispose() async {
    _disposed = true;
    controller.removeListener(_sync);
    try {
      navigation.hide();
    } catch (e, st) {
      developer.log(
        'Proxie failed to hide the inspector',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
    }
    final nav = navigation;
    if (nav is OverlayNavigationAdapter) nav.dispose();
    // Pages the app still shows see a closed, inert controller.
    controller
      ..close()
      ..dispose();
    adapters.forEach(detachAdapter);
    callCount.dispose();
    engine.dispose();
    await worker.dispose();
  }
}
