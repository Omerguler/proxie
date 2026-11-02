import 'package:flutter/material.dart';

import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/ui/detail/body_view.dart';

/// Readable duration: `850 ms` below ten seconds, else `12.3 s`.
String formatDuration(Duration d) {
  final ms = d.inMilliseconds;
  return ms < 10000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';
}

/// The Timing tab: when the call started, how long it took, its state,
/// adapter, sizes and tags.
class TimingTab extends StatelessWidget {
  /// Creates the tab for [call].
  const TimingTab({required this.call, super.key});

  /// The call whose timing is shown.
  final ProxieCall call;

  @override
  Widget build(BuildContext context) {
    final response = call.response;
    final error = call.error;
    final duration = call.duration;
    final state = error != null
        ? 'Failed (${error.type})'
        : response != null
        ? 'Complete'
        : 'Pending';
    final rows = <(String, String)>[
      ('Started', call.startedAt.toLocal().toString()),
      ('Duration', duration == null ? '—' : formatDuration(duration)),
      ('State', state),
      ('Adapter', call.adapter),
      ('Request size', formatBytes(call.request.body.originalLength)),
      if (response != null)
        ('Response size', formatBytes(response.body.originalLength)),
      if (call.tags.isNotEmpty)
        ('Tags', [for (final t in call.tags) t.name].join(', ')),
    ];
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 120, child: Text(label, style: muted)),
                  Expanded(
                    child: Text(value, style: theme.textTheme.bodyMedium),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
