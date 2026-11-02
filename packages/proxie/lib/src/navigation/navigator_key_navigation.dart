import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'navigation_adapter.dart';

/// Pushes the inspector as a full-screen dialog route onto the navigator of
/// [navigatorKey].
class NavigatorKeyNavigationAdapter implements ProxieNavigationAdapter {
  NavigatorKeyNavigationAdapter(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;

  Route<void>? _route;

  @override
  bool get isShowing => _route != null;

  /// [onDismissed] runs after the route left on its own (system back,
  /// removed by the app), or right away when the navigator is not mounted.
  @override
  void show(Widget inspector, {required VoidCallback onDismissed}) {
    if (_route != null) return;
    final navigator = navigatorKey.currentState;
    if (navigator == null) {
      developer.log(
        'Cannot open the inspector: the navigator key is not mounted',
        name: 'proxie',
      );
      onDismissed();
      return;
    }
    late final MaterialPageRoute<void> route;
    void dismissed() {
      if (!identical(_route, route)) return;
      _route = null;
      onDismissed();
    }

    route = MaterialPageRoute<void>(
      fullscreenDialog: true,
      // The watcher also covers removal without a pop (removeRoute,
      // pushAndRemoveUntil).
      builder: (_) => DismissWatcher(onDispose: dismissed, child: inspector),
    );
    _route = route;
    route.popped.whenComplete(dismissed);
    navigator.push(route);
  }

  @override
  void hide() {
    final route = _route;
    if (route == null) return;
    _route = null;
    final navigator = route.navigator;
    if (navigator == null || !route.isActive) return;
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }
}
