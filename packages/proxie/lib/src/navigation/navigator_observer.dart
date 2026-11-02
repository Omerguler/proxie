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
class HostPopGuard {
  HostPopGuard(this.observer);

  final ProxieNavigatorObserver observer;

  _BlockingPopEntry? _entry;
  ModalRoute<dynamic>? _route;

  bool get isEngaged => _entry != null;

  void engage(VoidCallback onBack) {
    if (_entry != null) return;
    _entry = _BlockingPopEntry(onBack);
    observer.addListener(_follow);
    _follow();
  }

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
      target.registerPopEntry(entry);
      _route = target;
    }
  }

  void _unregister(_BlockingPopEntry entry) {
    _route?.unregisterPopEntry(entry);
    _route = null;
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
