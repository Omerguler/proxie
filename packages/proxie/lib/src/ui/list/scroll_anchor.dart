import 'package:flutter/material.dart';

typedef _Anchor = ({String id, int index, double dy});

/// Keeps the rows on screen still while the rows above them change, and
/// counts the calls added meanwhile.
///
/// Rows report themselves through [ScrollAnchorRow]. Call [update] whenever
/// the list data changes, before the next frame: the rows still have their
/// old positions, so the first one on screen is measured, the scroll offset
/// is moved to where that row will be (from its new index), and after the
/// frame a measurement corrects what the estimate missed (session headers).
class ScrollAnchor extends ChangeNotifier {
  /// Creates an anchor for a list whose rows are [rowHeight] tall.
  ScrollAnchor({required this.rowHeight}) {
    scroll.addListener(_onScroll);
  }

  /// The height of one row, for estimating moves before the frame.
  final double rowHeight;

  /// Drives the list; give it to the scroll view.
  final ScrollController scroll = ScrollController();

  /// Put on a widget that covers the list, as the frame rows are measured
  /// in.
  final GlobalKey viewportKey = GlobalKey();

  final Map<String, ({BuildContext context, int index})> _rows = {};
  int _newCalls = 0;
  bool _disposed = false;
  // The anchor measured for the coming frame, and its predicted new index.
  _Anchor? _pending;
  int _predictedIndex = 0;
  // Bumped by a new query, so corrections scheduled before it do nothing.
  int _epoch = 0;

  /// Calls added at the top while the list was scrolled away from it.
  int get newCalls => _newCalls;

  void _setNew(int value) {
    if (_newCalls == value || _disposed) return;
    _newCalls = value;
    notifyListeners();
  }

  /// Adjusts the scroll offset for a data change.
  ///
  /// [newQuery] says the list was replaced (it starts at the top again);
  /// [added] is the change in row count; [indexOf] gives a call's new index,
  /// or null when it is not loaded.
  void update({
    required bool newQuery,
    required int added,
    required int? Function(String id) indexOf,
  }) {
    if (_disposed) return;
    if (newQuery) {
      // The new list starts at the top; corrections for the old one lapse.
      _epoch++;
      _pending = null;
      _setNew(0);
      return;
    }
    if (!scroll.hasClients || scroll.position.pixels <= 0) return;
    if (added > 0) _setNew(_newCalls + added);
    // Several updates may come before one frame: the rows have not moved
    // yet, so each one continues from the index the last one predicted.
    final pending = _pending;
    final anchor = pending ?? _findAnchor();
    if (anchor == null) return;
    final from = pending == null ? anchor.index : _predictedIndex;
    final index = indexOf(anchor.id) ?? from + added;
    if (index != from) {
      scroll.jumpTo(scroll.position.pixels + (index - from) * rowHeight);
    }
    _predictedIndex = index;
    if (pending != null) return;
    _pending = anchor;
    final epoch = _epoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (epoch != _epoch) return;
      _pending = null;
      _correct(anchor, epoch, retry: true);
    });
  }

  /// Scrolls to the top and clears [newCalls].
  void toTop() {
    _setNew(0);
    if (scroll.hasClients) {
      scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _onScroll() {
    if (_newCalls > 0 && scroll.position.pixels <= 0) _setNew(0);
  }

  double? _dyOf(String id) {
    final list = viewportKey.currentContext?.findRenderObject();
    final row = _rows[id]?.context.findRenderObject();
    if (list is! RenderBox || row is! RenderBox) return null;
    if (!row.attached || !row.hasSize) return null;
    return row.localToGlobal(Offset.zero, ancestor: list).dy;
  }

  // The first row whose top is on screen.
  _Anchor? _findAnchor() {
    _Anchor? best;
    for (final MapEntry(key: id, value: row) in _rows.entries) {
      final dy = _dyOf(id);
      if (dy == null || dy < 0) continue;
      if (best == null || dy < best.dy) {
        best = (id: id, index: row.index, dy: dy);
      }
    }
    return best;
  }

  void _correct(_Anchor anchor, int epoch, {required bool retry}) {
    if (_disposed || epoch != _epoch || !scroll.hasClients) return;
    final dy = _dyOf(anchor.id);
    if (dy != null) {
      final shift = dy - anchor.dy;
      if (shift != 0) scroll.jumpTo(scroll.position.pixels + shift);
    } else if (retry) {
      // Not built yet (its page may still be loading): try once more.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _correct(anchor, epoch, retry: false),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    scroll.dispose();
    super.dispose();
  }
}

/// Reports the row of call [id], at [index], to [anchor] while it is built.
class ScrollAnchorRow extends StatefulWidget {
  /// Creates the reporting wrapper around [child].
  const ScrollAnchorRow({
    required this.anchor,
    required this.id,
    required this.index,
    required this.child,
    super.key,
  });

  /// Where the row reports itself.
  final ScrollAnchor anchor;

  /// The call shown by the row.
  final String id;

  /// The row's index in the list.
  final int index;

  /// The row.
  final Widget child;

  @override
  State<ScrollAnchorRow> createState() => _ScrollAnchorRowState();
}

class _ScrollAnchorRowState extends State<ScrollAnchorRow> {
  void _register() =>
      widget.anchor._rows[widget.id] = (context: context, index: widget.index);

  @override
  void initState() {
    super.initState();
    _register();
  }

  @override
  void didUpdateWidget(ScrollAnchorRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.anchor != widget.anchor || oldWidget.id != widget.id) {
      _unregister(oldWidget);
    }
    _register();
  }

  void _unregister(ScrollAnchorRow w) {
    if (w.anchor._rows[w.id]?.context == context) w.anchor._rows.remove(w.id);
  }

  @override
  void dispose() {
    _unregister(widget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The "N new" pill: shown while [anchor] counts new calls; tapping it
/// scrolls to the top.
class NewCallsPill extends StatelessWidget {
  /// Creates the pill for [anchor].
  const NewCallsPill({required this.anchor, super.key});

  /// Counts the new calls and scrolls the list.
  final ScrollAnchor anchor;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: anchor,
    builder: (context, _) => anchor.newCalls == 0
        ? const SizedBox.shrink()
        : Center(
            child: ActionChip(
              avatar: const Icon(Icons.arrow_upward, size: 16),
              label: Text('${anchor.newCalls} new'),
              onPressed: anchor.toTop,
            ),
          ),
  );
}
