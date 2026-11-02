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
import 'navigation/overlay_navigation.dart';
import 'ui/bubble.dart';
import 'ui/inspector_shell.dart';
import 'ui/theme.dart';
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
  static bool _disabled = false;
  static bool _wrapped = false;
  static final ValueNotifier<_Runtime?> _active = ValueNotifier(null);
  static final List<WeakReference<ProxieHttpClient>> _clients = [];
  static _ProxieHostState? _host;

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
  /// one when the first call disabled Proxie). A failed start is
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
    late final Future<void> started;
    started = _start(adapters, navigation, config, supportDir).catchError((
      Object error,
      StackTrace stack,
    ) {
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
      OverlayNavigation() => OverlayNavigationAdapter(
        onDismissed: controller.close,
      ),
      NavigatorKeyNavigation(:final key) => NavigatorKeyNavigationAdapter(
        key,
        onDismissed: controller.close,
      ),
      CustomNavigation(:final push, :final pop) => CustomNavigationAdapter(
        push: push,
        pop: pop,
        onDismissed: controller.close,
      ),
    };
    if (nav is OverlayNavigationAdapter) {
      // Before the first await, so a call before runApp registers ahead of
      // the app's navigator.
      if (binding.rootElement != null) {
        developer.log(
          'Proxie.init was called after runApp: the back button may reach '
          "the app's navigator before the inspector",
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
    } catch (_) {
      if (nav is OverlayNavigationAdapter) nav.detachBackButton();
      attached.forEach(_detach);
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

    _active.value = _Runtime(
      worker: worker,
      engine: engine,
      adapters: attached,
      controller: controller,
      navigation: nav,
      callCount: SessionCallCounter(engine.calls),
      config: config,
    );
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
    return _ProxieHost(child: host);
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
    final runtime = _active.value;
    if (runtime != null) client.attach(runtime.engine);
    _clients
      ..removeWhere((ref) => ref.target == null)
      ..add(WeakReference(client));
    return client;
  }

  /// Opens the inspector; a no-op while Proxie is not active.
  static void open() {
    if (!kProxieEnabled) return;
    _active.value?.controller.open();
  }

  /// The engine while Proxie is active.
  static ProxieEngine? get engine =>
      kProxieEnabled ? _active.value?.engine : null;

  /// Whether [init] completed and Proxie is recording.
  static bool get isActive => kProxieEnabled && _active.value != null;

  /// Stops Proxie and resets it to before [init]: hides the inspector,
  /// detaches adapters and clients from [httpClient], disposes the engine,
  /// then the worker. Waits for a running [init] first.
  static Future<void> shutdown() async {
    if (!kProxieEnabled) return;
    final pending = _init;
    if (pending != null) await pending;
    final runtime = _active.value;
    _active.value = null;
    _init = null;
    _disabled = false;
    _wrapped = false;
    for (final client in _liveClients()) {
      client.detach();
    }
    _clients.clear();
    await runtime?.dispose();
  }

  static Iterable<ProxieHttpClient> _liveClients() sync* {
    for (final ref in _clients) {
      final client = ref.target;
      if (client != null) yield client;
    }
  }
}

void _detach(ProxieCaptureAdapter adapter) {
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
class _Runtime {
  _Runtime({
    required this.worker,
    required this.engine,
    required this.adapters,
    required this.controller,
    required this.navigation,
    required this.callCount,
    required this.config,
  }) {
    controller.addListener(_sync);
  }

  final ProxieWorker worker;
  final ProxieEngine engine;
  final List<ProxieCaptureAdapter> adapters;
  final ProxieInspectorController controller;
  final ProxieNavigationAdapter navigation;
  final SessionCallCounter callCount;
  final ProxieConfig config;

  bool get isOverlay => navigation is OverlayNavigationAdapter;

  // The controller is the source of truth; the adapter follows it. A page
  // the host dismissed closes the controller through onDismissed.
  void _sync() {
    if (controller.isOpen) {
      if (!navigation.isShowing) {
        final host = Proxie._host;
        navigation.show(
          host != null && host.mounted ? host.context : null,
          ProxieInspector(
            controller: controller,
            splitWidth: config.splitWidth,
          ),
        );
      }
    } else if (navigation.isShowing) {
      navigation.hide();
    }
  }

  Future<void> dispose() async {
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
    if (nav is OverlayNavigationAdapter) nav.detachBackButton();
    adapters.forEach(_detach);
    callCount.dispose();
    engine.dispose();
    await worker.dispose();
  }
}

/// What [Proxie.wrap] returns: the app plus Proxie's layer once active.
class _ProxieHost extends StatefulWidget {
  const _ProxieHost({required this.child});

  final Widget child;

  @override
  State<_ProxieHost> createState() => _ProxieHostState();
}

class _ProxieHostState extends State<_ProxieHost> {
  _Runtime? _runtime;
  // The app's last NavigationNotification, and whether Proxie is speaking
  // for the back button instead (overlay inspector open).
  bool _appCanHandlePop = false;
  bool _claimsBack = false;

  @override
  void initState() {
    super.initState();
    Proxie._host = this;
    Proxie._active.addListener(_onRuntime);
    _attach(Proxie._active.value);
  }

  @override
  void dispose() {
    Proxie._active.removeListener(_onRuntime);
    _runtime?.controller.removeListener(_onOpenChanged);
    if (identical(Proxie._host, this)) Proxie._host = null;
    super.dispose();
  }

  void _onRuntime() => setState(() => _attach(Proxie._active.value));

  void _attach(_Runtime? runtime) {
    if (identical(runtime, _runtime)) return;
    _runtime?.controller.removeListener(_onOpenChanged);
    _runtime = runtime;
    runtime?.controller.addListener(_onOpenChanged);
    _onOpenChanged();
  }

  // While the overlay inspector is open the back button must reach Flutter
  // (Android predictive back sends it to the framework only when told so),
  // even if the app's navigator could not pop; afterwards the app's own
  // state is restored.
  void _onOpenChanged() {
    final runtime = _runtime;
    final claim =
        runtime != null && runtime.isOverlay && runtime.controller.isOpen;
    if (claim == _claimsBack) return;
    _claimsBack = claim;
    NavigationNotification(
      canHandlePop: claim || _appCanHandlePop,
    ).dispatch(context);
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    return Stack(
      fit: StackFit.expand,
      children: [
        NotificationListener<NavigationNotification>(
          onNotification: (n) {
            _appCanHandlePop = n.canHandlePop;
            // Swallowed while Proxie claims the back button.
            return _claimsBack;
          },
          child: widget.child,
        ),
        if (runtime != null) _ProxieLayer(runtime: runtime),
      ],
    );
  }
}

/// The bubble, and the inspector in overlay mode, in Proxie's own theme.
class _ProxieLayer extends StatelessWidget {
  const _ProxieLayer({required this.runtime});

  final _Runtime runtime;

  @override
  Widget build(BuildContext context) {
    final nav = runtime.navigation;
    final overlay = nav is OverlayNavigationAdapter ? nav : null;
    return NotificationListener<NavigationNotification>(
      // Proxie's navigators never speak for the app's back button.
      onNotification: (_) => true,
      child: Theme(
        data: ProxieTheme.dark(),
        child: Material(
          type: MaterialType.transparency,
          child: ListenableBuilder(
            listenable: Listenable.merge([runtime.controller, ?overlay]),
            builder: (context, _) {
              final page = overlay?.page;
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Kept mounted so position and animations survive.
                  Visibility(
                    visible: !runtime.controller.isOpen,
                    maintainState: true,
                    child: ProxieBubble(
                      callCount: runtime.callCount,
                      breakpoints: runtime.engine.breakpoints,
                      onTap: Proxie.open,
                    ),
                  ),
                  if (overlay != null && page != null)
                    HeroControllerScope.none(
                      child: Navigator(
                        key: overlay.navigatorKey,
                        onGenerateRoute: (_) =>
                            MaterialPageRoute<void>(builder: (_) => page),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
