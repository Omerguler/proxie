import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Tracks the top route of the navigator it is added to (the app's root
/// navigator, via `Proxie.navigatorObserver`).
class ProxieNavigatorObserver extends NavigatorObserver with ChangeNotifier {
  Route<dynamic>? _top;

  /// The navigator's current top route, or null when not attached.
  Route<dynamic>? get topRoute {
    final top = _top;
    if (navigator == null || top == null || !top.isActive) return null;
    return top;
  }

  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    _top = topRoute;
    notifyListeners();
  }
}

/// The observer behind `Proxie.navigatorObserver`.
final proxieNavigatorObserver = ProxieNavigatorObserver();

/// While engaged, keeps the app's top route from popping (back button and
/// predictive back gestures) and reports each attempt to the `onBack`
/// callback instead. Follows the top route as the app navigates.
///
/// The block is an ordinary [PopEntry] on the app's route, so when an
/// attempt reaches the app's navigator (`maybePop`, e.g. a back press the
/// app's navigator sees first), the route's other pop entries are invoked
/// too: an app `PopScope` on that route gets
/// `onPopInvokedWithResult(false, null)` although Proxie handled the press.
class HostPopGuard {
  /// Creates a guard that follows the top route reported by [observer].
  HostPopGuard(this.observer);

  /// Reports the app's top route, which the guard blocks while engaged.
  final ProxieNavigatorObserver observer;

  _BlockingPopEntry? _entry;
  ModalRoute<dynamic>? _route;

  /// Whether [engage] was called without a matching [release].
  bool get isEngaged => _entry != null;

  /// Whether a blocking entry sits on an app route right now. While true,
  /// the app navigator's NavigationNotifications report the block, not the
  /// app's own state.
  bool get isBlocking => _route != null;

  /// Starts blocking pops of the app's top route, calling [onBack] for
  /// each attempt; does nothing when already engaged.
  void engage(VoidCallback onBack) {
    if (_entry != null) return;
    _entry = _BlockingPopEntry(onBack);
    observer.addListener(_follow);
    _follow();
  }

  /// Stops blocking and removes the block from the app's route.
  void release() {
    final entry = _entry;
    if (entry == null) return;
    observer.removeListener(_follow);
    _unregister(entry);
    _entry = null;
  }

  void _follow() {
    final entry = _entry;
    if (entry == null) return;
    final top = observer.topRoute;
    final target = top is ModalRoute<dynamic> ? top : null;
    if (identical(target, _route)) return;
    _unregister(entry);
    if (target != null) {
      // Set first: the notification registering dispatches is the block's.
      _route = target;
      target.registerPopEntry(entry);
    }
  }

  void _unregister(_BlockingPopEntry entry) {
    final route = _route;
    // Cleared first: the notification unregistering dispatches is the app's
    // real state again.
    _route = null;
    route?.unregisterPopEntry(entry);
  }
}

class _BlockingPopEntry extends PopEntry<Object?> {
  _BlockingPopEntry(this.onBack);

  final VoidCallback onBack;

  @override
  final ValueListenable<bool> canPopNotifier = ValueNotifier(false);

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {
    if (!didPop) onBack();
  }
}
