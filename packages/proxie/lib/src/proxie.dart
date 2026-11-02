import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'adapters/capture_adapter.dart';
import 'adapters/http_client_adapter.dart';
import 'config.dart';
import 'core/engine.dart';
import 'core/rule.dart';
import 'enablement.dart';
import 'navigation/custom_navigation.dart';
import 'navigation/navigation_adapter.dart';
import 'navigation/navigator_key_navigation.dart';
import 'navigation/navigator_observer.dart';
import 'navigation/overlay_navigation.dart';
import 'runtime.dart';
import 'ui/inspector_shell.dart';
import 'ui/proxie_layer.dart';
import 'worker/commands.dart';
import 'worker/worker.dart';
import 'worker/worker_factory.dart';

/// Entry point: set Proxie up once, then wrap the app.
///
/// ```dart
/// void main() {
///   Proxie.init(adapters: [ProxieHttpOverridesAdapter()]);
///   runApp(MaterialApp(builder: Proxie.wrap, home: const Home()));
/// }
/// ```
///
/// Everything is a no-op unless [kProxieEnabled] (debug builds, or
/// `--dart-define=PROXIE=true`), so release builds tree-shake Proxie out;
/// `init(enabled: false)` turns it off at runtime as well.
abstract final class Proxie {
  static Future<void>? _init;
  static Future<void>? _shuttingDown;
  static bool _disabled = false;
  static bool _wrapped = false;
  static final List<WeakReference<ProxieHttpClient>> _clients = [];
  static final NavigatorObserver _inertObserver = NavigatorObserver();

  /// Starts Proxie: spawns the storage worker, builds the engine, loads the
  /// saved rules and attaches [adapters].
  ///
  /// Call it before `runApp` (no need to await): the overlay's back-button
  /// handling must be registered before the app's navigator. A no-op when
  /// [enabled] is false or [kProxieEnabled] is off: no isolate, no files,
  /// adapters stay pass-through.
  ///
  /// Only the first call counts; later calls ignore their arguments (until
  /// [shutdown]) and return the first call's future (an already completed
  /// one when the first call disabled Proxie). An init called while a
  /// [shutdown] runs starts after it finished, so it never overlaps the
  /// old worker. A failed start is
  /// reported through [FlutterError.reportError] (it never throws into the
  /// app), leaves Proxie inactive, and may be retried with another `init`.
  ///
  /// [supportDir] overrides the directory that holds Proxie's database
  /// (default: `getApplicationSupportDirectory()`); meant for tests.
  static Future<void> init({
    List<ProxieCaptureAdapter> adapters = const [],
    ProxieNavigation navigation = const ProxieNavigation.overlay(),
    bool enabled = true,
    ProxieConfig config = const ProxieConfig(),
    @visibleForTesting String? supportDir,
  }) {
    // Disabled: no future is kept, so nothing waits on one created in the
    // caller's zone later.
    if (!kProxieEnabled || _disabled) return Future<void>.value();
    final existing = _init;
    if (existing != null) return existing;
    if (!enabled) {
      _disabled = true;
      _clients.clear();
      return Future<void>.value();
    }
    final shuttingDown = _shuttingDown;
    Future<void> start() => _start(adapters, navigation, config, supportDir);
    late final Future<void> started;
    started =
        (shuttingDown == null ? start() : shuttingDown.then((_) => start()))
            .catchError((Object error, StackTrace stack) {
              if (identical(_init, started)) _init = null;
              FlutterError.reportError(
                FlutterErrorDetails(
                  exception: error,
                  stack: stack,
                  library: 'proxie',
                  context: ErrorDescription('while starting Proxie'),
                ),
              );
            });
    return _init = started;
  }

  static Future<void> _start(
    List<ProxieCaptureAdapter> adapters,
    ProxieNavigation navigation,
    ProxieConfig config,
    String? supportDir,
  ) async {
    final binding = WidgetsFlutterBinding.ensureInitialized();
    final controller = ProxieInspectorController();
    final nav = switch (navigation) {
      OverlayNavigation() => OverlayNavigationAdapter(),
      NavigatorKeyNavigation(:final key) => NavigatorKeyNavigationAdapter(key),
      CustomNavigation(:final push, :final pop) => CustomNavigationAdapter(
        push: push,
        pop: pop,
      ),
      AdapterNavigation(:final adapter) => adapter,
    };
    if (nav is OverlayNavigationAdapter) {
      // Before the first await, so a call before runApp registers ahead of
      // the app's navigator.
      if (binding.rootElement != null) {
        developer.log(
          'Proxie.init was called after runApp: add Proxie.navigatorObserver '
          "to the app's navigator so the back button cannot reach it while "
          'the inspector is open',
          name: 'proxie',
        );
      }
      nav.attachBackButton();
    }

    ProxieWorker? worker;
    ProxieEngine? engine;
    final attached = <ProxieCaptureAdapter>[];
    try {
      worker = await spawnProxieWorker(config, supportDir: supportDir);
      engine = ProxieEngine(
        config: config,
        sink: worker,
        sessionId: worker.sessionId,
      );
      engine.rules = RuleSet(await worker.run(const LoadRules()));
      for (final adapter in adapters) {
        adapter.attach(engine);
        attached.add(adapter);
      }
      proxieActive.value = ProxieRuntime(
        worker: worker,
        engine: engine,
        adapters: attached,
        controller: controller,
        navigation: nav,
        config: config,
      );
    } catch (_) {
      if (nav is OverlayNavigationAdapter) nav.dispose();
      controller.dispose();
      attached.forEach(detachAdapter);
      engine?.dispose();
      try {
        await worker?.dispose();
      } catch (e, st) {
        developer.log(
          'Proxie worker dispose failed',
          name: 'proxie',
          error: e,
          stackTrace: st,
        );
      }
      rethrow;
    }
    for (final client in _liveClients()) {
      client.attach(engine);
    }
  }

  /// Use as `MaterialApp(builder: Proxie.wrap)`: draws the bubble and, in
  /// overlay mode, the inspector above [child].
  ///
  /// Returns [child] itself when Proxie is disabled. Before [init] finishes
  /// it returns a wrapper that shows Proxie once it is ready, so the app's
  /// tree stays the same.
  static Widget wrap(BuildContext context, Widget? child) {
    final host = child ?? const SizedBox.shrink();
    if (!kProxieEnabled) return host;
    // Once wrapped, keep wrapping so a later init(enabled: false) does not
    // remount the app.
    if (_disabled && !_wrapped) return host;
    _wrapped = true;
    return ProxieHost(child: host);
  }

  /// A `package:http` client whose calls Proxie records.
  ///
  /// While Proxie is active this is a [ProxieHttpClient] around [inner]
  /// (default `http.Client()`). Before [init] finishes it is the same, and
  /// starts recording once init completes. When Proxie is disabled it
  /// returns [inner] (or a new `http.Client()`) unchanged.
  static http.Client httpClient({http.Client? inner}) {
    if (!kProxieEnabled || _disabled) return inner ?? http.Client();
    final client = ProxieHttpClient(inner: inner);
    final runtime = proxieActive.value;
    if (runtime != null) client.attach(runtime.engine);
    _clients
      ..removeWhere((ref) => ref.target == null)
      ..add(WeakReference(client));
    return client;
  }

  /// Opens the inspector; a no-op while Proxie is not active.
  static void open() {
    if (!kProxieEnabled) return;
    proxieActive.value?.controller.open();
  }

  /// The engine while Proxie is active.
  static ProxieEngine? get engine =>
      kProxieEnabled ? proxieActive.value?.engine : null;

  /// Whether [init] completed and Proxie is recording.
  static bool get isActive => kProxieEnabled && proxieActive.value != null;

  /// Add to the app's root navigator, e.g.
  /// `MaterialApp(navigatorObservers: [Proxie.navigatorObserver])` or
  /// `GoRouter(observers: [Proxie.navigatorObserver])`.
  ///
  /// Overlay mode then holds the app's top route in place while the
  /// inspector is open. Required for apps with predictive back page
  /// transitions (otherwise a back gesture can pop the app's route along
  /// with closing the inspector) and for apps calling [init] after
  /// `runApp`. An observer can only be added to one navigator.
  ///
  /// The hold is a pop entry on the app's top route: if a back press reaches
  /// the app's navigator while the inspector is open, a `PopScope` on that
  /// route sees `onPopInvokedWithResult(false, null)` even though Proxie
  /// handled the press by closing the inspector.
  static NavigatorObserver get navigatorObserver =>
      kProxieEnabled ? proxieNavigatorObserver : _inertObserver;

  /// Stops Proxie and resets it to before [init]: hides the inspector,
  /// detaches adapters and the clients from [httpClient] (a later [init]
  /// attaches them again), disposes the engine, then the worker.
  ///
  /// Waits for a running [init] and earlier shutdowns first; completes once
  /// everything is disposed.
  static Future<void> shutdown() {
    if (!kProxieEnabled) return Future<void>.value();
    final previous = _shuttingDown;
    final pendingInit = _init;
    _init = null;
    _disabled = false;
    _wrapped = false;
    late final Future<void> done;
    done = _teardown(previous, pendingInit).whenComplete(() {
      if (identical(_shuttingDown, done)) _shuttingDown = null;
    });
    return _shuttingDown = done;
  }

  static Future<void> _teardown(
    Future<void>? previous,
    Future<void>? pendingInit,
  ) async {
    // Neither throws: init reports its own failures, teardown logs.
    if (previous != null) await previous;
    if (pendingInit != null) await pendingInit;
    final runtime = proxieActive.value;
    if (runtime == null) return;
    proxieActive.value = null;
    for (final client in _liveClients()) {
      client.detach();
    }
    try {
      await runtime.dispose();
    } catch (e, st) {
      developer.log(
        'Proxie shutdown failed',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
    }
  }

  static Iterable<ProxieHttpClient> _liveClients() sync* {
    for (final ref in _clients) {
      final client = ref.target;
      if (client != null) yield client;
    }
  }
}
