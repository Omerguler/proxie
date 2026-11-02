import 'package:flutter/widgets.dart';

/// Shows and hides the inspector page for one navigation style.
///
/// Implement it to plug in another router; pass the instance to
/// [ProxieNavigation.adapter]. Keep one adapter per file.
abstract interface class ProxieNavigationAdapter {
  /// Shows [inspector], an already themed full-screen page.
  ///
  /// When the page goes away without [hide] (the app's router popped it, the
  /// system back button), set [isShowing] to false and call [onDismissed] so
  /// Proxie knows the inspector is closed.
  void show(Widget inspector, {required VoidCallback onDismissed});

  /// Hides the inspector; does nothing when it is not showing.
  void hide();

  bool get isShowing;
}

/// How the inspector is presented. Choose one in `Proxie.init(navigation:)`.
///
/// * [ProxieNavigation.overlay] (default): drawn by `Proxie.wrap` above the
///   whole app, never touching the app's navigation stack.
/// * [ProxieNavigation.navigatorKey]: pushed as a full-screen route onto
///   the app's navigator. Works with routers that expose their navigator
///   key, for example GoRouter:
///
///   ```dart
///   final rootKey = GlobalKey<NavigatorState>();
///   final router = GoRouter(navigatorKey: rootKey, routes: [...]);
///   Proxie.init(navigation: ProxieNavigation.navigatorKey(rootKey));
///   MaterialApp.router(routerConfig: router, builder: Proxie.wrap);
///   ```
///
///   or AutoRoute:
///
///   ```dart
///   final appRouter = AppRouter(); // extends RootStackRouter
///   Proxie.init(
///     navigation: ProxieNavigation.navigatorKey(appRouter.navigatorKey),
///   );
///   MaterialApp.router(
///     routerConfig: appRouter.config(),
///     builder: Proxie.wrap,
///   );
///   ```
/// * [ProxieNavigation.custom]: the app shows and removes the page itself.
/// * [ProxieNavigation.adapter]: an app-provided [ProxieNavigationAdapter].
sealed class ProxieNavigation {
  const ProxieNavigation();

  /// Draws the inspector in Proxie's own layer from `Proxie.wrap`.
  ///
  /// The Android back button closes it and never reaches the app. Call
  /// `Proxie.init` before `runApp` so Proxie sees the back button before the
  /// app's navigator does. Apps using predictive back page transitions (or
  /// calling `init` after `runApp`) must also add `Proxie.navigatorObserver`
  /// to their root navigator's observers, so the app's top route is held in
  /// place while the inspector is open.
  const factory ProxieNavigation.overlay() = OverlayNavigation;

  /// Pushes the inspector as a full-screen dialog route onto [key]'s
  /// navigator; closing it pops the route.
  const factory ProxieNavigation.navigatorKey(GlobalKey<NavigatorState> key) =
      NavigatorKeyNavigation;

  /// Calls [push] with the inspector page to show it and [pop] to remove
  /// it. A page that leaves the widget tree counts as closed.
  const factory ProxieNavigation.custom({
    required void Function(Widget page) push,
    required void Function() pop,
  }) = CustomNavigation;

  /// Uses an app-provided [adapter], e.g. for a router Proxie has no
  /// built-in support for.
  const factory ProxieNavigation.adapter(ProxieNavigationAdapter adapter) =
      AdapterNavigation;
}

/// See [ProxieNavigation.overlay].
final class OverlayNavigation extends ProxieNavigation {
  const OverlayNavigation();
}

/// See [ProxieNavigation.navigatorKey].
final class NavigatorKeyNavigation extends ProxieNavigation {
  const NavigatorKeyNavigation(this.key);

  final GlobalKey<NavigatorState> key;
}

/// See [ProxieNavigation.custom].
final class CustomNavigation extends ProxieNavigation {
  const CustomNavigation({required this.push, required this.pop});

  final void Function(Widget page) push;
  final void Function() pop;
}

/// See [ProxieNavigation.adapter].
final class AdapterNavigation extends ProxieNavigation {
  const AdapterNavigation(this.adapter);

  final ProxieNavigationAdapter adapter;
}

/// Calls [onDispose] when it leaves the tree, so an adapter learns that the
/// host removed the page.
class DismissWatcher extends StatefulWidget {
  const DismissWatcher({
    super.key,
    required this.onDispose,
    required this.child,
  });

  final VoidCallback onDispose;
  final Widget child;

  @override
  State<DismissWatcher> createState() => _DismissWatcherState();
}

class _DismissWatcherState extends State<DismissWatcher> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
