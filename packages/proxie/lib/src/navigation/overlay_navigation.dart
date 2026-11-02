import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'navigation_adapter.dart';

/// Shows the inspector in the layer `Proxie.wrap` draws above the app.
///
/// The layer listens to this adapter and builds [page] inside a nested
/// [Navigator] keyed with [navigatorKey]. As a [WidgetsBindingObserver]
/// registered before the app's (see [attachBackButton]) it handles the
/// Android back button while showing: it pops the inspector's own routes
/// first, then closes the inspector, and never lets the press reach the
/// app's navigator.
class OverlayNavigationAdapter extends ChangeNotifier
    with WidgetsBindingObserver
    implements ProxieNavigationAdapter {
  OverlayNavigationAdapter({required this.onDismissed});

  /// Called after the inspector closed itself (back button).
  final VoidCallback onDismissed;

  /// Key of the navigator the layer builds around [page].
  final navigatorKey = GlobalKey<NavigatorState>(debugLabel: 'proxie');

  Widget? _page;
  bool _observing = false;

  /// The inspector page while showing.
  Widget? get page => _page;

  @override
  bool get isShowing => _page != null;

  @override
  void show(BuildContext? context, Widget inspector) {
    if (_page != null) return;
    _page = inspector;
    notifyListeners();
  }

  @override
  void hide() {
    if (_page == null) return;
    _page = null;
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
    if (!isShowing) return;
    hide();
    onDismissed();
  }
}
