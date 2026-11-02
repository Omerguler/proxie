import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// The row kept still across one data change: its id, its index and its
/// offset in the list's content (not on screen, so the user's own scrolling
/// in the meantime cancels out) as of the last layout.
class _Pending {
  _Pending(this.id, this.index, this.offset);

  final String id;
  final int index;
  double offset;
  int moved = 0;
  bool estimated = false;
}

/// Keeps the rows on screen still while the rows above them change, and
/// counts the calls added above meanwhile.
///
/// Rows report themselves through [ScrollAnchorRow]; the list's sliver is
/// wrapped in an [AnchoredSliver]. When the data changes ([update], called
/// before the next frame) the first row on screen is noted with its offset in
/// the content. After the list lays out the new data, [AnchoredSliver]
/// measures that row again and returns the difference as a
/// [SliverGeometry.scrollOffsetCorrection]: the viewport applies it with
/// `ScrollPosition.correctBy`, which leaves a running drag or fling going.
/// Nothing ever calls `jumpTo`.
class ScrollAnchor extends ChangeNotifier {
  /// Creates an anchor for a list whose rows are [rowHeight] tall.
  ScrollAnchor({required this.rowHeight}) {
    scroll.addListener(_onScroll);
  }

  /// The height of one row, for estimating a move whose row is not laid out.
  final double rowHeight;

  /// Drives the list; give it to the scroll view.
  final ScrollController scroll = ScrollController();

  final Map<String, ({BuildContext context, int index})> _rows = {};
  _RenderAnchoredSliver? _sliver;
  _Pending? _pending;
  int _newCalls = 0;
  bool _disposed = false;

  /// Calls added above the screen while the list was scrolled away from the
  /// top.
  int get newCalls => _newCalls;

  void _setNew(int value) {
    if (_newCalls == value || _disposed) return;
    _newCalls = value;
    notifyListeners();
  }

  /// Forgets any pending correction and clears [newCalls], for a list that
  /// was replaced (a new query) and starts at the top.
  void reset() {
    _pending = null;
    _setNew(0);
  }

  /// Notes a data change: [added] is the change in row count and [indexOf]
  /// gives a call's new index (null when it is not loaded).
  ///
  /// A change that moves no row above the one on screen (a page load, a
  /// call updated in place, rows added below) does nothing.
  void update({required int added, required int? Function(String id) indexOf}) {
    if (_disposed || !scroll.hasClients) return;
    final position = scroll.position;
    // At the top, new calls simply show.
    if (position.pixels <= position.minScrollExtent) return;
    final anchor = _pending ?? _findAnchor(position.pixels);
    if (anchor == null) {
      if (added > 0) _setNew(_newCalls + added);
      return;
    }
    final moved = (indexOf(anchor.id) ?? anchor.index + added) - anchor.index;
    if (moved > anchor.moved) _setNew(_newCalls + moved - anchor.moved);
    anchor.moved = moved;
    if (_pending == null && moved == 0) return;
    _pending = anchor;
    _sliver?.markNeedsLayout();
  }

  /// Scrolls to the top and clears [newCalls].
  void toTop() {
    _setNew(0);
    if (scroll.hasClients) {
      scroll.animateTo(
        scroll.position.minScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  void _onScroll() {
    final position = scroll.position;
    if (_newCalls > 0 && position.pixels <= position.minScrollExtent) {
      _setNew(0);
    }
  }

  /// The offset of row [id] in the list's content, from the last layout;
  /// null when it is not laid out.
  double? _contentOffset(String id) {
    final row = _rows[id]?.context.findRenderObject();
    if (row is! RenderBox || !row.attached || !row.hasSize) return null;
    // Climb to the list item: the child of the sliver list.
    RenderObject item = row;
    while (item.parent is! RenderSliverMultiBoxAdaptor) {
      final parent = item.parent;
      if (parent == null) return null;
      item = parent;
    }
    final data = item.parentData;
    if (item is! RenderBox || data is! SliverMultiBoxAdaptorParentData) {
      return null;
    }
    final itemOffset = data.layoutOffset;
    if (itemOffset == null) return null;
    return itemOffset + row.localToGlobal(Offset.zero, ancestor: item).dy;
  }

  // The first row whose top is on screen.
  _Pending? _findAnchor(double pixels) {
    _Pending? best;
    for (final MapEntry(key: id, value: row) in _rows.entries) {
      final offset = _contentOffset(id);
      if (offset == null || offset < pixels) continue;
      if (best == null || offset < best.offset) {
        best = _Pending(id, row.index, offset);
      }
    }
    return best;
  }

  // Called by the sliver after its child laid out the new data.
  double? _layoutCorrection() {
    final pending = _pending;
    if (pending == null) return null;
    final now = _contentOffset(pending.id);
    if (now != null) {
      _pending = null;
      return now - pending.offset;
    }
    // Moved out of the laid-out rows: estimate from the index; the layout
    // that follows the correction measures it again.
    if (!pending.estimated && pending.moved != 0) {
      pending.estimated = true;
      final estimate = pending.moved * rowHeight;
      pending.offset += estimate;
      return estimate;
    }
    _pending = null;
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _pending = null;
    scroll.dispose();
    super.dispose();
  }
}

/// Wraps the list's sliver so [anchor] can correct the scroll offset after
/// a data change, during layout.
class AnchoredSliver extends SingleChildRenderObjectWidget {
  /// Creates the wrapper around [sliver].
  const AnchoredSliver({
    required this.anchor,
    required Widget sliver,
    super.key,
  }) : super(child: sliver);

  /// Decides the correction.
  final ScrollAnchor anchor;

  @override
  RenderSliver createRenderObject(BuildContext context) =>
      _RenderAnchoredSliver(anchor);

  @override
  void updateRenderObject(BuildContext context, RenderSliver renderObject) =>
      (renderObject as _RenderAnchoredSliver).anchor = anchor;
}

// Corrections smaller than this are rounding, not moves.
const double _tolerance = 1e-6;

class _RenderAnchoredSliver extends RenderProxySliver {
  _RenderAnchoredSliver(this._anchor);

  ScrollAnchor _anchor;

  ScrollAnchor get anchor => _anchor;

  set anchor(ScrollAnchor value) {
    if (value == _anchor) return;
    if (attached && _anchor._sliver == this) _anchor._sliver = null;
    _anchor = value;
    if (attached) _anchor._sliver = this;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _anchor._sliver = this;
  }

  @override
  void detach() {
    if (_anchor._sliver == this) _anchor._sliver = null;
    super.detach();
  }

  @override
  void performLayout() {
    super.performLayout();
    if (geometry!.scrollOffsetCorrection != null) return;
    final correction = _anchor._layoutCorrection();
    if (correction != null && correction.abs() > _tolerance) {
      geometry = SliverGeometry(scrollOffsetCorrection: correction);
    }
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

  void _unregister(ScrollAnchorRow w) {
    if (w.anchor._rows[w.id]?.context == context) w.anchor._rows.remove(w.id);
  }

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
