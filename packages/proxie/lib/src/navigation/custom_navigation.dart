import 'package:flutter/widgets.dart';

import 'package:proxie/src/navigation/navigation_adapter.dart';

/// Hands the inspector page to app-provided [push] and [pop] callbacks.
class CustomNavigationAdapter implements ProxieNavigationAdapter {
  /// Creates an adapter that shows the page with [push] and removes it
  /// with [pop].
  CustomNavigationAdapter({required this.push, required this.pop});

  /// Shows the inspector page in the app's own way.
  final void Function(Widget page) push;

  /// Removes the page [push] showed.
  final void Function() pop;

  // Identifies the page currently shown; a late dispose of an earlier page
  // must not close a newer one.
  Object? _shown;

  @override
  bool get isShowing => _shown != null;

  /// [onDismissed] runs after the page left the widget tree without [hide].
  /// If [push] throws, nothing is showing and the error propagates.
  @override
  void show(Widget inspector, {required VoidCallback onDismissed}) {
    if (_shown != null) return;
    final token = Object();
    _shown = token;
    try {
      push(
        DismissWatcher(
          onDispose: () {
            if (!identical(_shown, token)) return;
            _shown = null;
            onDismissed();
          },
          child: inspector,
        ),
      );
    } catch (_) {
      _shown = null;
      rethrow;
    }
  }

  @override
  void hide() {
    if (_shown == null) return;
    _shown = null;
    pop();
  }
}
