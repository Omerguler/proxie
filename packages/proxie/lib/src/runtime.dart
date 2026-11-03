import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';

import 'package:proxie/src/adapters/capture_adapter.dart';
import 'package:proxie/src/config.dart';
import 'package:proxie/src/core/breakpoint_controller.dart';
import 'package:proxie/src/core/engine.dart';
import 'package:proxie/src/navigation/navigation_adapter.dart';
import 'package:proxie/src/navigation/overlay_navigation.dart';
import 'package:proxie/src/ui/breakpoint/breakpoint_editor.dart';
import 'package:proxie/src/ui/bubble.dart';
import 'package:proxie/src/ui/detail/call_detail.dart';
import 'package:proxie/src/ui/inspector_shell.dart';
import 'package:proxie/src/ui/list/call_list.dart';
import 'package:proxie/src/ui/rules/rule_editor.dart';
import 'package:proxie/src/ui/rules/rules_controller.dart';
import 'package:proxie/src/ui/rules/rules_screen.dart';
import 'package:proxie/src/worker/worker.dart';

/// The runtime of the active Proxie, or null while inactive. Set by the
/// facade, read by the layer `Proxie.wrap` draws.
final ValueNotifier<ProxieRuntime?> proxieActive = ValueNotifier(null);

/// Detaches [adapter], logging (never throwing) a failure.
void detachAdapter(ProxieCaptureAdapter adapter) {
  try {
    adapter.detach();
  } on Object catch (e, st) {
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
  /// Bundles the parts of an active Proxie and starts keeping [navigation]
  /// in step with [controller].
  ProxieRuntime({
    required this.worker,
    required this.engine,
    required this.adapters,
    required this.controller,
    required this.navigation,
    required this.config,
  }) : callCount = SessionCallCounter(engine.calls),
       rules = RulesController(
         worker: worker,
         engine: engine,
         rawEditableLimit: config.rawEditableLimit,
       ) {
    controller.addListener(_sync);
    _paused = engine.breakpoints.changes.listen(_onPaused);
  }

  /// Runs storage and heavy JSON work off the UI isolate.
  final ProxieWorker worker;

  /// Decides what happens to each captured call.
  final ProxieEngine engine;

  /// The adapters attached to [engine], detached on dispose.
  final List<ProxieCaptureAdapter> adapters;

  /// Whether the inspector is open; [navigation] follows it.
  final ProxieInspectorController controller;

  /// Shows and hides the inspector page.
  final ProxieNavigationAdapter navigation;

  /// Counts this session's calls for the bubble's badge.
  final SessionCallCounter callCount;

  /// The settings Proxie was started with.
  final ProxieConfig config;

  /// Changes and stores [engine]'s rules for the rules screen and editors.
  final RulesController rules;
  bool _disposed = false;
  late final StreamSubscription<List<PausedCall>> _paused;
  bool _hadPaused = false;
  // Whether the inspector was opened for a pause and the user is still on
  // its editor, so it closes again when the last paused call is resolved.
  bool _openedForPause = false;
  bool _drainCheck = false;

  /// Whether the inspector is drawn in Proxie's own overlay layer.
  bool get isOverlay => navigation is OverlayNavigationAdapter;

  // The controller is the source of truth; the adapter follows it. A page
  // the host dismissed closes the controller through onDismissed.
  void _sync() {
    if (_disposed) return;
    if (!controller.isOpen) _openedForPause = false;
    if (controller.isOpen) {
      if (navigation.isShowing) return;
      try {
        navigation.show(
          RulesScope(
            controller: rules,
            child: ProxieInspector(
              controller: controller,
              splitWidth: config.splitWidth,
              themeMode: config.themeMode,
              listBuilder: _buildList,
              detailBuilder: _buildDetail,
              rulesBuilder: (_) => const RulesScreen(),
              shellBuilder: (_, shell) => BreakpointHost(
                breakpoints: engine.breakpoints,
                worker: worker,
                rawEditableLimit: config.rawEditableLimit,
                // Going back from the editor to stay in the inspector makes
                // it the user's: it no longer closes when the queue drains.
                onEditorLeft: () => _openedForPause = false,
                child: shell,
              ),
            ),
          ),
          onDismissed: _onDismissed,
        );
      } on Object catch (e, st) {
        _report(e, st, 'while showing the Proxie inspector');
        controller.close();
      }
    } else if (navigation.isShowing) {
      try {
        navigation.hide();
      } on Object catch (e, st) {
        _report(e, st, 'while hiding the Proxie inspector');
      }
    }
  }

  // The inspector opens when calls start pausing (its BreakpointHost shows
  // the editor), and closes when they are all resolved, unless the user
  // had it open or left the editor for it (P49b).
  void _onPaused(List<PausedCall> pending) {
    if (_disposed) return;
    final had = _hadPaused;
    _hadPaused = pending.isNotEmpty;
    if (!had && pending.isNotEmpty && !controller.isOpen) {
      controller.open();
      _openedForPause = controller.isOpen;
    } else if (had && pending.isEmpty && _openedForPause && !_drainCheck) {
      // After the events delivered with this one: a call resolved and
      // another paused at once must not close and reopen the inspector.
      _drainCheck = true;
      scheduleMicrotask(() {
        _drainCheck = false;
        if (_disposed || !_openedForPause) return;
        if (engine.breakpoints.pending.isEmpty) controller.close();
      });
    }
  }

  Widget _buildList(BuildContext context) {
    final inspector = ProxieInspectorController.of(context);
    return CallList(
      worker: worker,
      calls: engine.calls,
      renderCap: config.renderCap,
      adapterNames: [for (final a in adapters) a.name],
      selectedCallId: inspector.selectedCallId,
      onSelected: inspector.select,
    );
  }

  Widget _buildDetail(BuildContext context, String callId) => CallDetail(
    worker: worker,
    calls: engine.calls,
    callId: callId,
    renderCap: config.renderCap,
    actions: ruleDetailActions(context),
  );

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
    unawaited(_paused.cancel());
    try {
      navigation.hide();
    } on Object catch (e, st) {
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
    // The last rule change reaches the worker before it goes; bounded and
    // logged by flush, so a stuck worker cannot hang shutdown.
    await rules.flush();
    rules.dispose();
    engine.dispose();
    await worker.dispose();
  }
}
