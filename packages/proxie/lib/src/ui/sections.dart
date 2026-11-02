import 'package:flutter/widgets.dart';

import '../enablement.dart';
import '../model/call.dart';
import '../storage/call_query.dart';

/// An extra tab on the call detail screen.
class ProxieDetailTab {
  const ProxieDetailTab({
    required this.id,
    required this.label,
    required this.appliesTo,
    required this.build,
  });

  /// Unique; registering another tab with the same id replaces this one.
  final String id;

  /// The tab title.
  final String label;

  /// Whether the tab is shown for a call.
  final bool Function(ProxieCall call) appliesTo;

  /// Builds the tab body.
  final Widget Function(BuildContext context, ProxieCall call) build;
}

/// An extra tag chip on call list rows.
class ProxieListBadge {
  const ProxieListBadge({required this.id, required this.label, this.color});

  /// Unique; registering another badge with the same id replaces this one.
  final String id;

  /// The chip text for a row, or null for no chip.
  final String? Function(CallSummary call) label;

  /// The chip color; null uses the theme's default.
  final Color? color;
}

/// Registry of UI extensions shown by the inspector.
///
/// Register before the inspector opens, typically next to `Proxie.init`.
/// Registering again with an existing id replaces the entry in place (so
/// hot reload does not duplicate it).
abstract final class ProxieSections {
  static final List<ProxieDetailTab> _tabs = [];
  static final List<ProxieListBadge> _badges = [];

  /// A no-op unless [kProxieEnabled], so release builds drop the entries.
  static void addDetailTab(ProxieDetailTab tab) {
    if (!kProxieEnabled) return;
    _put(_tabs, tab, (t) => t.id == tab.id);
  }

  /// A no-op unless [kProxieEnabled], so release builds drop the entries.
  static void addListBadge(ProxieListBadge badge) {
    if (!kProxieEnabled) return;
    _put(_badges, badge, (b) => b.id == badge.id);
  }

  /// Registered detail tabs, in registration order. Unmodifiable.
  static List<ProxieDetailTab> get detailTabs => List.unmodifiable(_tabs);

  /// Registered list badges, in registration order. Unmodifiable.
  static List<ProxieListBadge> get listBadges => List.unmodifiable(_badges);

  /// Removes every registration.
  @visibleForTesting
  static void clear() {
    _tabs.clear();
    _badges.clear();
  }

  static void _put<T>(List<T> list, T item, bool Function(T) sameId) {
    final i = list.indexWhere(sameId);
    if (i < 0) {
      list.add(item);
    } else {
      list[i] = item;
    }
  }
}
