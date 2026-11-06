import 'package:flutter/material.dart';

import 'package:proxie/src/config.dart';
import 'package:proxie/src/ui/theme.dart';

/// Whether the inspector is open and which call it shows.
///
/// After [dispose] every method is a no-op, so a page still on screen after
/// `Proxie.shutdown` cannot fail.
class ProxieInspectorController extends ChangeNotifier {
  bool _isOpen = false;
  String? _selectedCallId;
  bool _disposed = false;

  /// Whether the inspector is open.
  bool get isOpen => _isOpen;

  /// The call shown in the detail pane, or null for none.
  String? get selectedCallId => _selectedCallId;

  /// Opens the inspector; does nothing when it is already open.
  void open() {
    if (_disposed || _isOpen) return;
    _isOpen = true;
    notifyListeners();
  }

  /// Closes the inspector; does nothing when it is already closed.
  void close() {
    if (_disposed || !_isOpen) return;
    _isOpen = false;
    notifyListeners();
  }

  /// Shows [callId] in the detail pane; null shows none.
  void select(String? callId) {
    if (_disposed || _selectedCallId == callId) return;
    _selectedCallId = callId;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// The controller of the nearest enclosing [InspectorShell], for list and
  /// detail builders.
  static ProxieInspectorController of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_InspectorScope>();
    assert(scope != null, 'No InspectorShell above this context');
    return scope!.notifier!;
  }
}

class _InspectorScope extends InheritedNotifier<ProxieInspectorController> {
  const _InspectorScope({
    required ProxieInspectorController controller,
    required super.child,
  }) : super(notifier: controller);
}

/// The full-screen inspector page: [InspectorShell] in Proxie's own theme
/// (see [ProxieThemed]), with its own [ScaffoldMessenger] so its messages
/// never reach the host, and its own [Navigator] for the pages opened from
/// it (rules, editors; see [navigatorOf]), so they never land on the
/// host's navigator. Back pops those pages first.
class ProxieInspector extends StatelessWidget {
  /// Creates the inspector page driven by [controller].
  const ProxieInspector({
    required this.controller,
    super.key,
    this.splitWidth = 700,
    this.themeMode = ProxieThemeMode.dark,
    this.listBuilder,
    this.detailBuilder,
    this.rulesBuilder,
    this.shellBuilder,
  });

  /// Holds whether the inspector is open and which call it shows.
  final ProxieInspectorController controller;

  /// Minimum width for the side-by-side layout.
  final double splitWidth;

  /// Which of Proxie's themes the page uses.
  final ProxieThemeMode themeMode;

  /// Builds the call list; defaults to a placeholder.
  final WidgetBuilder? listBuilder;

  /// Builds the detail of a call; defaults to a placeholder.
  final Widget Function(BuildContext context, String callId)? detailBuilder;

  /// Builds the rules screen the app bar's Rules button opens; the button
  /// is hidden when null.
  final WidgetBuilder? rulesBuilder;

  /// Wraps the list/detail layout inside the inspector's navigator, e.g.
  /// with a widget that opens pages there itself (see [navigatorOf]).
  final Widget Function(BuildContext context, Widget shell)? shellBuilder;

  /// The navigator of the [ProxieInspector] around [context], or the
  /// nearest one when there is none: pages opened from the inspector go
  /// there, above the list/detail layout, so a layout change keeps them.
  static NavigatorState navigatorOf(BuildContext context) =>
      context
          .getInheritedWidgetOfExactType<_InspectorNavigatorScope>()
          ?.navigatorKey
          .currentState ??
      Navigator.of(context);

  @override
  Widget build(BuildContext context) {
    final shell = InspectorShell(
      controller: controller,
      splitWidth: splitWidth,
      listBuilder: listBuilder,
      detailBuilder: detailBuilder,
      rulesBuilder: rulesBuilder,
    );
    return ProxieThemed(
      mode: themeMode,
      child: ScaffoldMessenger(
        child: _InspectorNavigator(
          child: Builder(
            builder: (context) => shellBuilder?.call(context, shell) ?? shell,
          ),
        ),
      ),
    );
  }
}

class _InspectorNavigatorScope extends InheritedWidget {
  const _InspectorNavigatorScope({
    required this.navigatorKey,
    required super.child,
  });

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  bool updateShouldNotify(_InspectorNavigatorScope oldWidget) =>
      navigatorKey != oldWidget.navigatorKey;
}

class _InspectorNavigator extends StatefulWidget {
  const _InspectorNavigator({required this.child});

  final Widget child;

  @override
  State<_InspectorNavigator> createState() => _InspectorNavigatorState();
}

class _InspectorNavigatorState extends State<_InspectorNavigator> {
  final _navigatorKey = GlobalKey<NavigatorState>(
    debugLabel: 'proxie-inspector',
  );

  @override
  Widget build(BuildContext context) => _InspectorNavigatorScope(
    navigatorKey: _navigatorKey,
    // Blocks the enclosing route's pop while a page is open here, and pops
    // that page instead.
    child: NavigatorPopHandler(
      onPopWithResult: (_) => _navigatorKey.currentState?.maybePop(),
      child: HeroControllerScope.none(
        child: Navigator(
          key: _navigatorKey,
          onDidRemovePage: (_) {},
          pages: [
            MaterialPage<void>(
              key: const ValueKey('proxie-inspector'),
              child: widget.child,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Adaptive list/detail layout of the inspector.
///
/// At least [splitWidth] wide: list (40% of the width, at least 320) and
/// detail side by side. Narrower: the list, with the selected call's detail
/// pushed on top inside the shell's own [Navigator]; back pops it. The
/// layout follows rotation and window resizes live. The selection lives in
/// [controller]; everything else the list and the detail hold (search, filters,
/// scroll, tab, revealed bodies) survives too, because this widget's global
/// keys carry their elements across the layout change.
class InspectorShell extends StatefulWidget {
  /// Creates the layout driven by [controller].
  const InspectorShell({
    required this.controller,
    super.key,
    this.splitWidth = 700,
    this.listBuilder,
    this.detailBuilder,
    this.rulesBuilder,
  });

  /// Holds the selection, so it survives layout changes.
  final ProxieInspectorController controller;

  /// Minimum width for the side-by-side layout.
  final double splitWidth;

  /// Builds the call list; defaults to a placeholder.
  final WidgetBuilder? listBuilder;

  /// Builds the detail of a call; defaults to a placeholder.
  final Widget Function(BuildContext context, String callId)? detailBuilder;

  /// Builds the rules screen the app bar's Rules button opens (see
  /// [ProxieInspector.navigatorOf]); the button is hidden when null.
  final WidgetBuilder? rulesBuilder;

  @override
  State<InspectorShell> createState() => _InspectorShellState();
}

class _InspectorShellState extends State<InspectorShell> {
  static const double _minListWidth = 320;

  // Details a layout may still be showing: the selected one, and any that is
  // on its way out of the stacked layout.
  static const int _maxDetailKeys = 4;

  final GlobalKey _listKey = GlobalKey(debugLabel: 'proxie-list');
  final Map<String, GlobalKey> _detailKeys = {};

  GlobalKey _detailKey(String id) {
    final key =
        _detailKeys.remove(id) ?? GlobalKey(debugLabel: 'proxie-detail');
    // Reinserted last, so the first entry is the one used longest ago.
    _detailKeys[id] = key;
    if (_detailKeys.length > _maxDetailKeys) {
      _detailKeys.remove(_detailKeys.keys.first);
    }
    return key;
  }

  Widget _list(BuildContext context) => KeyedSubtree(
    key: _listKey,
    child:
        widget.listBuilder?.call(context) ??
        const _Placeholder('No requests yet'),
  );

  Widget _detail(BuildContext context, String id) => KeyedSubtree(
    key: _detailKey(id),
    child: widget.detailBuilder?.call(context, id) ?? _Placeholder(id),
  );

  @override
  Widget build(BuildContext context) => _InspectorScope(
    controller: widget.controller,
    child: LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= widget.splitWidth
          ? _split(constraints.maxWidth)
          : _StackedLayout(
              controller: widget.controller,
              list: _list,
              detail: _detail,
              rulesBuilder: widget.rulesBuilder,
            ),
    ),
  );

  Widget _split(double width) {
    final controller = widget.controller;
    final listWidth = (width * 0.4).clamp(_minListWidth, width);
    return Scaffold(
      appBar: _inspectorBar(controller, widget.rulesBuilder),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: listWidth,
            child: Builder(builder: _list),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: controller,
              builder: (context, _) {
                final id = controller.selectedCallId;
                return id == null
                    ? const _Placeholder('Select a request')
                    : _detail(context, id);
              },
            ),
          ),
        ],
      ),
    );
  }
}

PreferredSizeWidget _inspectorBar(
  ProxieInspectorController controller,
  WidgetBuilder? rulesBuilder,
) => AppBar(
  title: const Text('Proxie'),
  automaticallyImplyLeading: false,
  actions: [
    if (rulesBuilder != null)
      Builder(
        builder: (context) => IconButton(
          tooltip: 'Rules',
          icon: const Icon(Icons.rule),
          onPressed: () => ProxieInspector.navigatorOf(
            context,
          ).push(MaterialPageRoute<void>(builder: rulesBuilder)),
        ),
      ),
    IconButton(
      tooltip: 'Close',
      icon: const Icon(Icons.close),
      onPressed: controller.close,
    ),
  ],
);

class _StackedLayout extends StatefulWidget {
  const _StackedLayout({
    required this.controller,
    required this.list,
    required this.detail,
    required this.rulesBuilder,
  });

  final ProxieInspectorController controller;
  final WidgetBuilder list;
  final Widget Function(BuildContext context, String callId) detail;
  final WidgetBuilder? rulesBuilder;

  @override
  State<_StackedLayout> createState() => _StackedLayoutState();
}

class _StackedLayoutState extends State<_StackedLayout> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  static const _listKey = ValueKey<String>('proxie-list');

  void _onDidRemovePage(Page<Object?> page) {
    // Popped by the user (back button or gesture). A detail page removed
    // because another call was selected must not clear that selection.
    final key = page.key;
    if (key is ValueKey<_DetailKey> &&
        widget.controller.selectedCallId == key.value.callId) {
      widget.controller.select(null);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final id = widget.controller.selectedCallId;
      // Blocks the enclosing route's pop while the detail is shown, and pops
      // the detail instead.
      return NavigatorPopHandler(
        onPopWithResult: (_) => _navigatorKey.currentState?.maybePop(),
        child: HeroControllerScope.none(
          child: Navigator(
            key: _navigatorKey,
            onDidRemovePage: _onDidRemovePage,
            pages: [
              MaterialPage<void>(
                key: _listKey,
                child: Scaffold(
                  appBar: _inspectorBar(widget.controller, widget.rulesBuilder),
                  body: Builder(builder: widget.list),
                ),
              ),
              if (id != null)
                _DetailPage(
                  key: ValueKey(_DetailKey(id)),
                  child: Scaffold(
                    appBar: AppBar(title: const Text('Request')),
                    body: Builder(
                      builder: (context) => widget.detail(context, id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

class _DetailPage extends Page<void> {
  const _DetailPage({required this.child, super.key});

  final Widget child;

  @override
  Route<void> createRoute(BuildContext context) => _DetailRoute(this);
}

/// A material route that lets the page below it stay laid out for its first
/// frame when it appears without a push, as it does when the layout changes.
///
/// That page holds the list, just carried over from the side-by-side layout.
/// A blinking caret in it may still repaint in that frame, and it looks up its
/// position through its ancestors, which must have been laid out.
class _DetailRoute extends MaterialPageRoute<void> {
  _DetailRoute(_DetailPage page)
    : super(settings: page, builder: (_) => page.child);

  bool _opaque = true;

  @override
  bool get opaque => _opaque;

  @override
  WidgetBuilder get builder =>
      (_) => (settings as _DetailPage).child;

  @override
  void didAdd() {
    _opaque = false;
    super.didAdd();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _opaque = true;
      if (overlayEntries.isNotEmpty) overlayEntries.first.opaque = true;
    });
  }
}

@immutable
class _DetailKey {
  const _DetailKey(this.callId);

  final String callId;

  @override
  bool operator ==(Object other) =>
      other is _DetailKey && other.callId == callId;

  @override
  int get hashCode => callId.hashCode;
}

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
