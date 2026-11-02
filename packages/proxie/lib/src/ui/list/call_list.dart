import 'package:flutter/material.dart';

import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/call_query.dart';
import 'package:proxie/src/storage/store.dart';
import 'package:proxie/src/ui/list/call_row.dart';
import 'package:proxie/src/ui/list/filter_bar.dart';
import 'package:proxie/src/ui/list/list_controller.dart';
import 'package:proxie/src/worker/worker.dart';

/// The inspector's call list: [FilterBar] over a lazily built list of
/// [CallRow]s, newest first, with a header row (`Today 14:02 — 312 calls`)
/// above the first call of each session.
///
/// While scrolled away from the top, new calls do not move the rows on
/// screen; a "N new" pill counts them and scrolls to the top when tapped.
///
/// Owns a [ListController] for as long as it is on screen, so nothing is
/// queried while the inspector is closed.
class CallList extends StatefulWidget {
  /// Creates the list of the calls stored by [worker], kept current by
  /// [calls] (the engine's call stream).
  const CallList({
    required this.worker,
    required this.calls,
    required this.renderCap,
    super.key,
    this.adapterNames = const [],
    this.selectedCallId,
    this.onSelected,
  });

  /// Where the calls are stored and queried.
  final ProxieWorker worker;

  /// Snapshots of calls as they change.
  final Stream<ProxieCall> calls;

  /// The render cap in bytes, for the size filter chip.
  final int renderCap;

  /// Names of the attached adapters, for the adapter filter chips.
  final List<String> adapterNames;

  /// The call to highlight, or null for none.
  final String? selectedCallId;

  /// Called with a call's id when its row is tapped.
  final ValueChanged<String>? onSelected;

  @override
  State<CallList> createState() => _CallListState();
}

typedef _Anchor = ({String id, double dy});

class _CallListState extends State<CallList> {
  late ListController _controller = _create();
  final _scroll = ScrollController();
  final GlobalKey _listKey = GlobalKey();
  // Rows currently built, by call id, for measuring the scroll anchor.
  final _rows = <String, BuildContext>{};
  int _seenGeneration = 0;
  int _seenCount = 0;
  int _newCalls = 0;

  ListController _create([CallQuery query = const CallQuery()]) =>
      ListController(worker: widget.worker, calls: widget.calls, query: query)
        ..addListener(_onListChanged);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(CallList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.worker != widget.worker || oldWidget.calls != widget.calls) {
      final query = _controller.query;
      _controller.dispose();
      _controller = _create(query);
      _seenGeneration = _controller.generation;
      _seenCount = 0;
      _newCalls = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_newCalls > 0 && _scroll.position.pixels <= 0) {
      setState(() => _newCalls = 0);
    }
  }

  // Runs before the next frame, so the rows on screen still have their old
  // positions and the anchor can be measured.
  void _onListChanged() {
    final count = _controller.count;
    if (_controller.generation != _seenGeneration) {
      _seenGeneration = _controller.generation;
      _seenCount = count;
      // The list is rebuilt under a new key and starts at the top.
      _newCalls = 0;
      return;
    }
    final added = count - _seenCount;
    _seenCount = count;
    if (added <= 0 || !_scroll.hasClients || _scroll.position.pixels <= 0) {
      return;
    }
    final anchor = _findAnchor();
    setState(() => _newCalls += added);
    if (anchor == null) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _restore(anchor, added, retry: true),
    );
  }

  double? _dyOf(String id) {
    final list = _listKey.currentContext?.findRenderObject();
    final row = _rows[id]?.findRenderObject();
    if (list is! RenderBox || row is! RenderBox) return null;
    if (!row.attached || !row.hasSize) return null;
    return row.localToGlobal(Offset.zero, ancestor: list).dy;
  }

  // The first row whose top is on screen.
  _Anchor? _findAnchor() {
    _Anchor? best;
    for (final id in _rows.keys) {
      final dy = _dyOf(id);
      if (dy == null || dy < 0) continue;
      if (best == null || dy < best.dy) best = (id: id, dy: dy);
    }
    return best;
  }

  void _restore(_Anchor anchor, int added, {required bool retry}) {
    if (!mounted || !_scroll.hasClients) return;
    final dy = _dyOf(anchor.id);
    if (dy != null) {
      final shift = dy - anchor.dy;
      if (shift != 0) _scroll.jumpTo(_scroll.position.pixels + shift);
    } else if (retry) {
      // The anchor moved out of the built rows: estimate, then measure.
      _scroll.jumpTo(_scroll.position.pixels + added * CallRow.height);
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restore(anchor, added, retry: false),
      );
    }
  }

  void _toTop() {
    setState(() => _newCalls = 0);
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FilterBar(
        controller: _controller,
        renderCap: widget.renderCap,
        adapterNames: widget.adapterNames,
      ),
      const Divider(height: 1),
      Expanded(
        child: ListenableBuilder(
          listenable: _controller,
          builder: (context, _) {
            final error = _controller.error;
            if (_controller.count == 0) {
              return error != null
                  ? _Message(
                      "Couldn't load requests",
                      onRetry: _controller.refresh,
                    )
                  : _Message(
                      _hasFilters(_controller.query)
                          ? 'No matching requests'
                          : 'No requests yet',
                    );
            }
            return Column(
              children: [
                if (error != null) _ErrorBar(onRetry: _controller.refresh),
                Expanded(child: _list()),
              ],
            );
          },
        ),
      ),
    ],
  );

  Widget _list() => Stack(
    key: _listKey,
    children: [
      // A new query gets a new list, scrolled to the top, so no row of the
      // old one is rebuilt (and its page fetched) on the way.
      ListView.builder(
        key: ValueKey(_controller.generation),
        controller: _scroll,
        itemCount: _controller.count,
        itemBuilder: _item,
      ),
      if (_newCalls > 0)
        Positioned(
          top: 8,
          left: 0,
          right: 0,
          child: Center(
            child: ActionChip(
              avatar: const Icon(Icons.arrow_upward, size: 16),
              label: Text('$_newCalls new'),
              onPressed: _toTop,
            ),
          ),
        ),
    ],
  );

  Widget _item(BuildContext context, int i) {
    final call = _controller.rowAt(i);
    if (call == null) return const SizedBox(height: CallRow.height);
    final row = _Tracked(
      key: ValueKey(call.id),
      id: call.id,
      registry: _rows,
      child: CallRow(
        call: call,
        selected: call.id == widget.selectedCallId,
        onTap: widget.onSelected == null
            ? null
            : () => widget.onSelected!(call.id),
      ),
    );
    final previous = i == 0 ? null : _controller.rowAt(i - 1);
    final firstOfSession =
        i == 0 || (previous != null && previous.sessionId != call.sessionId);
    if (!firstOfSession) return row;
    final info = _controller.session(call.sessionId);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SessionHeader(
          info == null
              ? 'Session ${call.sessionId}'
              : sessionLabel(
                  info,
                  DateTime.now(),
                  matching: _controller.sessionMatches(call.sessionId),
                ),
        ),
        row,
      ],
    );
  }

  static bool _hasFilters(CallQuery q) =>
      (q.text?.isNotEmpty ?? false) ||
      q.methods.isNotEmpty ||
      q.status != StatusFilter.all ||
      q.onlyJson ||
      q.hideBinary ||
      q.maxSize != null ||
      q.adapters.isNotEmpty;
}

/// Keeps [registry] pointing at the context of the built row [id].
class _Tracked extends StatefulWidget {
  const _Tracked({
    required this.id,
    required this.registry,
    required this.child,
    super.key,
  });

  final String id;
  final Map<String, BuildContext> registry;
  final Widget child;

  @override
  State<_Tracked> createState() => _TrackedState();
}

class _TrackedState extends State<_Tracked> {
  @override
  void initState() {
    super.initState();
    widget.registry[widget.id] = context;
  }

  @override
  void dispose() {
    if (widget.registry[widget.id] == context) {
      widget.registry.remove(widget.id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _SessionHeader extends StatelessWidget {
  const _SessionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A session header's text, such as `Today 14:02 — 312 calls`: `Today`,
/// `Yesterday` or the date (`2026-10-30`) relative to [now], the start time,
/// and the number of stored calls. With [matching] (the calls passing the
/// active filters) it reads `Today 14:02 — 3 of 312 calls`.
String sessionLabel(SessionInfo session, DateTime now, {int? matching}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final start = session.startedAt.toLocal();
  final local = now.toLocal();
  final startDay = DateTime(start.year, start.month, start.day);
  final days = DateTime(
    local.year,
    local.month,
    local.day,
  ).difference(startDay).inDays;
  final day = switch (days) {
    0 => 'Today',
    1 => 'Yesterday',
    _ => '${start.year}-${two(start.month)}-${two(start.day)}',
  };
  final n = session.callCount;
  final calls = '$n ${n == 1 ? 'call' : 'calls'}';
  return '$day ${two(start.hour)}:${two(start.minute)} — '
      '${matching == null ? '' : '$matching of '}$calls';
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.onRetry});

  final String text;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 8),
              TextButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                "Couldn't refresh the list",
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
