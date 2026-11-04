import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';

import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/call_query.dart';
import 'package:proxie/src/storage/store.dart';
import 'package:proxie/src/ui/list/call_row.dart';
import 'package:proxie/src/ui/list/filter_bar.dart';
import 'package:proxie/src/ui/list/list_controller.dart';
import 'package:proxie/src/ui/list/scroll_anchor.dart';
import 'package:proxie/src/worker/commands.dart';
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
    this.optionalAdapterNames = const [],
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

  /// Names calls can be recorded under without an adapter attached (Proxie's
  /// own replay client); each gets a chip once such a call exists.
  final List<String> optionalAdapterNames;

  /// The call to highlight, or null for none.
  final String? selectedCallId;

  /// Called with a call's id when its row is tapped.
  final ValueChanged<String>? onSelected;

  @override
  State<CallList> createState() => _CallListState();
}

class _CallListState extends State<CallList> {
  late ListController _controller = _create();
  final _anchor = ScrollAnchor(rowHeight: CallRow.height);
  int _seenGeneration = 0;
  int _seenCount = 0;
  // False until the current query's first snapshot is seen: that snapshot
  // only sets [_seenCount]; it is not a change to anchor or count as new.
  bool _seeded = false;
  // True from a query change until the new list's first frame: before it,
  // the scroll position still belongs to the old list.
  bool _freshList = false;
  // The optional adapter names that have calls.
  final Set<String> _present = {};
  StreamSubscription<ProxieCall>? _optionalCalls;

  ListController _create([CallQuery query = const CallQuery()]) =>
      ListController(worker: widget.worker, calls: widget.calls, query: query)
        ..addListener(_onListChanged);

  @override
  void initState() {
    super.initState();
    _watchOptional();
  }

  // Calls stored earlier are looked up once; new ones are seen arriving.
  void _watchOptional() {
    final names = widget.optionalAdapterNames;
    if (names.isEmpty) return;
    _optionalCalls = widget.calls.listen(
      (c) {
        if (names.contains(c.adapter) && _present.add(c.adapter)) {
          setState(() {});
        }
      },
      // The stream belongs to the engine; its errors are not ours to show.
      onError: _logOptional,
    );
    for (final name in names) {
      unawaited(_lookUpOptional(name));
    }
  }

  Future<void> _lookUpOptional(String name) async {
    final worker = widget.worker;
    try {
      final n = await worker.run(CountCalls(CallQuery(adapters: {name})));
      if (!mounted || worker != widget.worker || n == 0) return;
      if (_present.add(name)) setState(() {});
    } on Object catch (e, st) {
      // Only a filter chip is missing.
      _logOptional(e, st);
    }
  }

  void _logOptional(Object error, StackTrace stack) => developer.log(
    'Proxie could not look for calls of optional adapters',
    name: 'proxie',
    error: error,
    stackTrace: stack,
  );

  @override
  void didUpdateWidget(CallList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.worker != widget.worker || oldWidget.calls != widget.calls) {
      unawaited(_optionalCalls?.cancel());
      _optionalCalls = null;
      _present.clear();
      _watchOptional();
      final query = _controller.query;
      _controller.dispose();
      _controller = _create(query);
      _seenGeneration = _controller.generation;
      _seeded = false;
      _anchor.reset();
    }
  }

  @override
  void dispose() {
    unawaited(_optionalCalls?.cancel());
    _controller.dispose();
    _anchor.dispose();
    super.dispose();
  }

  // Runs before the next frame, while the rows on screen still have their
  // old positions.
  void _onListChanged() {
    if (_controller.generation != _seenGeneration) {
      // A new query is shown in a new list (new key) that starts at the top.
      _seenGeneration = _controller.generation;
      _seeded = false;
      _freshList = true;
      _anchor.reset();
      WidgetsBinding.instance
        ..addPostFrameCallback((_) => _freshList = false)
        ..ensureVisualUpdate();
    }
    if (!_controller.loaded) return;
    final count = _controller.count;
    if (!_seeded || _freshList) {
      _seeded = true;
      _seenCount = count;
      return;
    }
    final added = count - _seenCount;
    _seenCount = count;
    _anchor.update(added: added, indexOf: _controller.indexOf);
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      FilterBar(
        controller: _controller,
        renderCap: widget.renderCap,
        adapterNames: [
          ...widget.adapterNames,
          for (final name in widget.optionalAdapterNames)
            if (_present.contains(name) && !widget.adapterNames.contains(name))
              name,
        ],
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
                Expanded(child: _list(context)),
              ],
            );
          },
        ),
      ),
    ],
  );

  Widget _list(BuildContext context) => Stack(
    children: [
      // A new query gets a new list, scrolled to the top, so no row of the
      // old one is rebuilt (and its page fetched) on the way.
      CustomScrollView(
        key: ValueKey(_controller.generation),
        controller: _anchor.scroll,
        slivers: [
          AnchoredSliver(
            anchor: _anchor,
            sliver: SliverPadding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(context).bottom,
              ),
              sliver: SliverList.builder(
                itemCount: _controller.count,
                itemBuilder: _item,
              ),
            ),
          ),
        ],
      ),
      Positioned(
        top: 8,
        left: 0,
        right: 0,
        child: NewCallsPill(anchor: _anchor),
      ),
    ],
  );

  Widget _item(BuildContext context, int i) {
    final call = _controller.rowAt(i);
    if (call == null) return const SizedBox(height: CallRow.height);
    final row = ScrollAnchorRow(
      key: ValueKey(call.id),
      anchor: _anchor,
      id: call.id,
      index: i,
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
