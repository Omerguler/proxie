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
/// (see [ProxieThemed]),
/// with its own [ScaffoldMessenger] so its messages never reach the host.
class ProxieInspector extends StatelessWidget {
  /// Creates the inspector page driven by [controller].
  const ProxieInspector({
    required this.controller,
    super.key,
    this.splitWidth = 700,
    this.themeMode = ProxieThemeMode.dark,
    this.listBuilder,
    this.detailBuilder,
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

  @override
  Widget build(BuildContext context) => ProxieThemed(
    mode: themeMode,
    child: ScaffoldMessenger(
      child: InspectorShell(
        controller: controller,
        splitWidth: splitWidth,
        listBuilder: listBuilder,
        detailBuilder: detailBuilder,
      ),
    ),
  );
}

/// Adaptive list/detail layout of the inspector.
///
/// At least [splitWidth] wide: list (40% of the width, at least 320) and
/// detail side by side. Narrower: the list, with the selected call's detail
/// pushed on top inside the shell's own [Navigator]; back pops it. The
/// layout follows rotation and window resizes live; the selection lives in
/// [controller] and survives layout changes.
class InspectorShell extends StatelessWidget {
  /// Creates the layout driven by [controller].
  const InspectorShell({
    required this.controller,
    super.key,
    this.splitWidth = 700,
    this.listBuilder,
    this.detailBuilder,
  });

  /// Holds the selection, so it survives layout changes.
  final ProxieInspectorController controller;

  /// Minimum width for the side-by-side layout.
  final double splitWidth;

  /// Builds the call list; defaults to a placeholder.
  final WidgetBuilder? listBuilder;

  /// Builds the detail of a call; defaults to a placeholder.
  final Widget Function(BuildContext context, String callId)? detailBuilder;

  static const double _minListWidth = 320;

  Widget _list(BuildContext context) =>
      listBuilder?.call(context) ?? const _Placeholder('No requests yet');

  Widget _detail(BuildContext context, String id) =>
      detailBuilder?.call(context, id) ?? _Placeholder(id);

  @override
  Widget build(BuildContext context) => _InspectorScope(
    controller: controller,
    child: LayoutBuilder(
      builder: (context, constraints) => constraints.maxWidth >= splitWidth
          ? _split(constraints.maxWidth)
          : _StackedLayout(
              controller: controller,
              list: _list,
              detail: _detail,
            ),
    ),
  );

  Widget _split(double width) {
    final listWidth = (width * 0.4).clamp(_minListWidth, width);
    return Scaffold(
      appBar: _inspectorBar(controller),
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
                    : KeyedSubtree(
                        key: ValueKey(id),
                        child: _detail(context, id),
                      );
              },
            ),
          ),
        ],
      ),
    );
  }
}

PreferredSizeWidget _inspectorBar(ProxieInspectorController controller) =>
    AppBar(
      title: const Text('Proxie'),
      automaticallyImplyLeading: false,
      actions: [
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
  });

  final ProxieInspectorController controller;
  final WidgetBuilder list;
  final Widget Function(BuildContext context, String callId) detail;

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
                  appBar: _inspectorBar(widget.controller),
                  body: Builder(builder: widget.list),
                ),
              ),
              if (id != null)
                MaterialPage<void>(
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
