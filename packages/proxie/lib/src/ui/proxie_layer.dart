import 'package:flutter/material.dart';

import 'package:proxie/src/navigation/overlay_navigation.dart';
import 'package:proxie/src/runtime.dart';
import 'package:proxie/src/ui/bubble.dart';
import 'package:proxie/src/ui/theme.dart';

/// What `Proxie.wrap` returns: the app plus [ProxieLayer] once Proxie is
/// active.
///
/// While the overlay inspector is open it speaks for the back button: it
/// tells the platform that Flutter handles back (Android predictive back
/// sends presses to the framework only when told so), hides the app from
/// semantics, and afterwards restores the app's own back state.
class ProxieHost extends StatefulWidget {
  /// Creates the host around the app's [child].
  const ProxieHost({required this.child, super.key});

  /// The app, drawn below Proxie's layer.
  final Widget child;

  @override
  State<ProxieHost> createState() => _ProxieHostState();
}

class _ProxieHostState extends State<ProxieHost> {
  ProxieRuntime? _runtime;
  OverlayNavigationAdapter? _overlay;
  // The app's own back state from its last NavigationNotification, and
  // whether Proxie is speaking for the back button instead (overlay
  // inspector showing).
  bool _appCanHandlePop = false;
  bool _overlayOpen = false;

  @override
  void initState() {
    super.initState();
    proxieActive.addListener(_onRuntime);
    _attach(proxieActive.value);
  }

  @override
  void dispose() {
    proxieActive.removeListener(_onRuntime);
    _overlay?.removeListener(_onOpenChanged);
    super.dispose();
  }

  void _onRuntime() {
    _attach(proxieActive.value);
    setState(() {});
  }

  void _attach(ProxieRuntime? runtime) {
    if (identical(runtime, _runtime)) return;
    _overlay?.removeListener(_onOpenChanged);
    _runtime = runtime;
    final nav = runtime?.navigation;
    _overlay = nav is OverlayNavigationAdapter ? nav : null;
    _overlay?.addListener(_onOpenChanged);
    _onOpenChanged();
  }

  // Follows the adapter rather than the controller. Route notifications are
  // dispatched post-frame, so on close this sends the last state recorded
  // before the guard engaged; the guard's release notification then follows
  // with the app's current back state.
  void _onOpenChanged() {
    final open = _overlay?.isShowing ?? false;
    if (open == _overlayOpen) return;
    setState(() => _overlayOpen = open);
    NavigationNotification(
      canHandlePop: open || _appCanHandlePop,
    ).dispatch(context);
  }

  void _onAppNotification(NavigationNotification n) {
    // While the guard blocks an app route, the app's navigator reports the
    // block (can handle pop), not its own state.
    if (_overlay?.blocksAppNavigation ?? false) return;
    _appCanHandlePop = n.canHandlePop;
  }

  @override
  Widget build(BuildContext context) {
    final runtime = _runtime;
    // Non-directional alignment: works without a Directionality above.
    return Stack(
      alignment: Alignment.topLeft,
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: _overlayOpen,
          child: NotificationListener<NavigationNotification>(
            onNotification: (n) {
              _onAppNotification(n);
              // Swallowed while Proxie speaks for the back button.
              return _overlayOpen;
            },
            child: widget.child,
          ),
        ),
        if (runtime != null) ProxieLayer(runtime: runtime),
      ],
    );
  }
}

/// The bubble, and the inspector in overlay mode, in Proxie's own theme.
class ProxieLayer extends StatelessWidget {
  /// Creates the layer for [runtime].
  const ProxieLayer({required this.runtime, super.key});

  /// The active Proxie whose bubble and inspector are drawn.
  final ProxieRuntime runtime;

  @override
  Widget build(BuildContext context) {
    final nav = runtime.navigation;
    final overlay = nav is OverlayNavigationAdapter ? nav : null;
    return NotificationListener<NavigationNotification>(
      // Proxie's navigators never speak for the app's back button.
      onNotification: (_) => true,
      child: ProxieThemed(
        mode: runtime.config.themeMode,
        child: Material(
          type: MaterialType.transparency,
          child: ListenableBuilder(
            listenable: Listenable.merge([runtime.controller, ?overlay]),
            builder: (context, _) {
              final page = overlay?.page;
              return Stack(
                alignment: Alignment.topLeft,
                fit: StackFit.expand,
                children: [
                  // Kept mounted so position and animations survive.
                  Visibility(
                    visible: !runtime.controller.isOpen,
                    maintainState: true,
                    child: ProxieBubble(
                      callCount: runtime.callCount,
                      breakpoints: runtime.engine.breakpoints,
                      onTap: runtime.controller.open,
                    ),
                  ),
                  if (overlay != null)
                    _OverlayNavigator(
                      navigatorKey: overlay.navigatorKey,
                      page: page,
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

/// The navigator around the overlay inspector's [page].
///
/// When [page] goes away the navigator first stops taking focus, hidden, and
/// is removed one frame later. Removing it at once fails on the web: when the
/// focused element leaves the semantics tree, the browser reports a view focus
/// change in the middle of that frame, and focus traversal then measures
/// focus nodes whose render objects were already detached.
class _OverlayNavigator extends StatefulWidget {
  const _OverlayNavigator({required this.navigatorKey, required this.page});

  final GlobalKey<NavigatorState> navigatorKey;
  final Widget? page;

  @override
  State<_OverlayNavigator> createState() => _OverlayNavigatorState();
}

class _OverlayNavigatorState extends State<_OverlayNavigator> {
  // The page the navigator was built with, kept while it is being removed.
  Widget? _shown;

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final removing = page == null;
    if (page != null) {
      _shown = page;
    } else if (_shown != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.page == null) setState(() => _shown = null);
      });
    }
    final shown = _shown;
    if (shown == null) return const SizedBox.shrink();
    return ExcludeFocus(
      excluding: removing,
      child: Offstage(
        offstage: removing,
        child: HeroControllerScope.none(
          child: Navigator(
            key: widget.navigatorKey,
            onGenerateRoute: (_) =>
                MaterialPageRoute<void>(builder: (_) => shown),
          ),
        ),
      ),
    );
  }
}
