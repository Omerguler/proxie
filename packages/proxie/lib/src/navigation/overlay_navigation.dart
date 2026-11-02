import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:proxie/src/navigation/navigation_adapter.dart';
import 'package:proxie/src/navigation/navigator_observer.dart';

/// Shows the inspector in the layer `Proxie.wrap` draws above the app.
///
/// The layer listens to this adapter and builds [page] inside a nested
/// [Navigator] keyed with [navigatorKey]. While showing, the Android back
/// button pops the inspector's own routes first, then closes it, and never
/// reaches the app:
/// * as a [WidgetsBindingObserver] registered before the app's (see
///   [attachBackButton]) it sees back presses and predictive back gestures
///   first;
/// * through [HostPopGuard] (needs `Proxie.navigatorObserver` on the app's
///   navigator) the app's top route refuses to pop, so its predictive back
///   transition never starts and a press that reaches it first still lands
///   here.
class OverlayNavigationAdapter extends ChangeNotifier
    with WidgetsBindingObserver
    implements ProxieNavigationAdapter {
  OverlayNavigationAdapter({ProxieNavigatorObserver? observer})
    : _guard = HostPopGuard(observer ?? proxieNavigatorObserver);

  /// Key of the navigator the layer builds around [page].
  final navigatorKey = GlobalKey<NavigatorState>(debugLabel: 'proxie');

  final HostPopGuard _guard;
  Widget? _page;
  VoidCallback? _onDismissed;
  bool _observing = false;

  /// Whether the guard currently blocks an app route, so the app
  /// navigator's NavigationNotifications describe the block rather than the
  /// app.
  bool get blocksAppNavigation => _guard.isBlocking;

  /// The inspector page while showing.
  Widget? get page => _page;

  @override
  bool get isShowing => _page != null;

  @override
  void show(Widget inspector, {required VoidCallback onDismissed}) {
    if (_page != null) return;
    _page = inspector;
    _onDismissed = onDismissed;
    _guard.engage(() => unawaited(_back()));
    notifyListeners();
  }

  @override
  void hide() {
    if (_page == null) return;
    _page = null;
    _onDismissed = null;
    _guard.release();
    notifyListeners();
  }

  /// Starts handling the back button. Observers run in registration order,
  /// so this must happen before `runApp` to come before the app's
  /// navigator.
  void attachBackButton() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
  }

  void detachBackButton() {
    if (!_observing) return;
    _observing = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void dispose() {
    hide();
    detachBackButton();
    super.dispose();
  }

  @override
  Future<bool> didPopRoute() async {
    if (!isShowing) return false;
    await _back();
    return true;
  }

  // Claim predictive back gestures while showing so the commit reaches us.
  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) => isShowing;

  @override
  void handleCommitBackGesture() {
    if (isShowing) unawaited(_back());
  }

  Future<void> _back() async {
    final navigator = navigatorKey.currentState;
    // Pops a dialog or the phone layout's detail page; false when only the
    // inspector itself is left.
    if (navigator != null && await navigator.maybePop()) return;
    final onDismissed = _onDismissed;
    if (!isShowing || onDismissed == null) return;
    hide();
    onDismissed();
  }
}
