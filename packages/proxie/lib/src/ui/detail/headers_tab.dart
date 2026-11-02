import 'package:flutter/material.dart';

import 'package:proxie/src/model/call.dart';

/// The Headers tab: request and response headers, one row per value.
class HeadersTab extends StatelessWidget {
  /// Creates the tab for [call].
  const HeadersTab({required this.call, super.key});

  /// The call whose headers are shown.
  final ProxieCall call;

  @override
  Widget build(BuildContext context) {
    final response = call.response;
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.only(bottom: 12),
        children: [
          ..._section(context, 'Request', call.request.headers),
          if (response != null)
            ..._section(context, 'Response', response.headers),
        ],
      ),
    );
  }

  List<Widget> _section(
    BuildContext context,
    String title,
    Map<String, List<String>> headers,
  ) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final count = headers.values.fold(0, (n, v) => n + v.length);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Text('$title ($count)', style: theme.textTheme.titleSmall),
      ),
      if (count == 0)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Text('No headers', style: muted),
        ),
      for (final e in headers.entries)
        for (final v in e.value)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 160, child: Text(e.key, style: muted)),
                const SizedBox(width: 8),
                Expanded(child: Text(v, style: theme.textTheme.bodySmall)),
              ],
            ),
          ),
    ];
  }
}
