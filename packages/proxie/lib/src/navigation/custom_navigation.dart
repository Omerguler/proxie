import 'package:flutter/widgets.dart';

import 'navigation_adapter.dart';

/// Hands the inspector page to app-provided [push] and [pop] callbacks.
class CustomNavigationAdapter implements ProxieNavigationAdapter {
  CustomNavigationAdapter({
    required this.push,
    required this.pop,
    required this.onDismissed,
  });

  final void Function(Widget page) push;
  final void Function() pop;

  /// Called after the page left the widget tree without [hide].
  final VoidCallback onDismissed;

  // Identifies the page currently shown; a late dispose of an earlier page
  // must not close a newer one.
  Object? _shown;

  @override
  bool get isShowing => _shown != null;

  @override
  void show(BuildContext? context, Widget inspector) {
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
