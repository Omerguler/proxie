import 'package:flutter/material.dart';

import '../navigation/overlay_navigation.dart';
import '../runtime.dart';
import 'bubble.dart';
import 'theme.dart';

/// What `Proxie.wrap` returns: the app plus [ProxieLayer] once Proxie is
/// active.
///
/// While the overlay inspector is open it speaks for the back button: it
/// tells the platform that Flutter handles back (Android predictive back
/// sends presses to the framework only when told so), hides the app from
/// semantics, and afterwards restores the app's own back state.
class ProxieHost extends StatefulWidget {
  const ProxieHost({super.key, required this.child});

  final Widget child;

  @override
  State<ProxieHost> createState() => _ProxieHostState();
}

class _ProxieHostState extends State<ProxieHost> {
  ProxieRuntime? _runtime;
  // The app's last NavigationNotification, and whether Proxie is speaking
  // for the back button instead (overlay inspector open).
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
    _runtime?.controller.removeListener(_onOpenChanged);
    super.dispose();
  }

  void _onRuntime() {
    _attach(proxieActive.value);
    setState(() {});
  }

  void _attach(ProxieRuntime? runtime) {
    if (identical(runtime, _runtime)) return;
    _runtime?.controller.removeListener(_onOpenChanged);
    _runtime = runtime;
    runtime?.controller.addListener(_onOpenChanged);
    _onOpenChanged();
  }

  void _onOpenChanged() {
    final runtime = _runtime;
    final open =
        runtime != null && runtime.isOverlay && runtime.controller.isOpen;
    if (open == _overlayOpen) return;
    setState(() => _overlayOpen = open);
    NavigationNotification(
      canHandlePop: open || _appCanHandlePop,
    ).dispatch(context);
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
              _appCanHandlePop = n.canHandlePop;
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
  const ProxieLayer({super.key, required this.runtime});

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
