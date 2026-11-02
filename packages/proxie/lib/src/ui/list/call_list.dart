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

class _CallListState extends State<CallList> {
  late ListController _controller = _create();

  ListController _create([CallQuery query = const CallQuery()]) =>
      ListController(worker: widget.worker, calls: widget.calls, query: query);

  @override
  void didUpdateWidget(CallList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.worker != widget.worker || oldWidget.calls != widget.calls) {
      final query = _controller.query;
      _controller.dispose();
      _controller = _create(query);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
          builder: (context, _) => _controller.count == 0
              ? _Empty(filtered: _hasFilters(_controller.query))
              : ListView.builder(
                  itemCount: _controller.count,
                  itemBuilder: _item,
                ),
        ),
      ),
    ],
  );

  Widget _item(BuildContext context, int i) {
    final call = _controller.rowAt(i);
    if (call == null) return const SizedBox(height: CallRow.height);
    final row = CallRow(
      key: ValueKey(call.id),
      call: call,
      selected: call.id == widget.selectedCallId,
      onTap: widget.onSelected == null
          ? null
          : () => widget.onSelected!(call.id),
    );
    final previous = i == 0 ? null : _controller.rowAt(i - 1);
    final firstOfSession =
        i == 0 || (previous != null && previous.sessionId != call.sessionId);
    if (!firstOfSession) return row;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SessionHeader(call.sessionId, _controller.session(call.sessionId)),
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
  const _SessionHeader(this.id, this.info);

  final int id;
  final SessionInfo? info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text(
        info == null ? 'Session $id' : sessionLabel(info!, DateTime.now()),
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A session header's text, such as `Today 14:02 — 312 calls`: `Today`,
/// `Yesterday` or the date (`2026-10-30`) relative to [now], the start time,
/// and the number of stored calls.
String sessionLabel(SessionInfo session, DateTime now) {
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
  return '$day ${two(start.hour)}:${two(start.minute)} — '
      '$n ${n == 1 ? 'call' : 'calls'}';
}

class _Empty extends StatelessWidget {
  const _Empty({required this.filtered});

  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          filtered ? 'No matching requests' : 'No requests yet',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
