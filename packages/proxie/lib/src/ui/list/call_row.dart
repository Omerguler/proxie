import 'package:flutter/material.dart';

import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/call_query.dart';
import 'package:proxie/src/ui/sections.dart';
import 'package:proxie/src/ui/theme.dart';

/// One call in the list: method badge, path over host, status, duration,
/// size and tag chips (`BREAK`, `MAP`, `REPLAY`, `EDITED`, then registered
/// [ProxieListBadge]s).
class CallRow extends StatelessWidget {
  /// Creates the row for [call]; tapping it calls [onTap].
  const CallRow({
    required this.call,
    super.key,
    this.selected = false,
    this.onTap,
  });

  /// The call shown.
  final CallSummary call;

  /// Whether the row is highlighted as the call in the detail pane.
  final bool selected;

  /// Called when the row is tapped.
  final VoidCallback? onTap;

  /// The row height.
  static const double height = 60;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ProxieColors.of(context);
    final uri = Uri.tryParse(call.url);
    final path = uri == null
        ? call.url
        : (uri.path.isEmpty ? '/' : uri.path) +
              (uri.hasQuery ? '?${uri.query}' : '');
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final chips = _chips(colors);
    // Its own node: a session header above it must not merge into it.
    return Semantics(
      container: true,
      button: onTap != null,
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.14)
            : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: height,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _MethodBadge(call.method, colors.methodColor(call.method)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          path,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                uri?.host ?? '',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: muted,
                              ),
                            ),
                            if (chips.isNotEmpty)
                              // Chips that do not fit are clipped. Read as part
                              // of the row: a scrollable in the semantics tree
                              // would split the row and take its tap action.
                              Flexible(
                                child: Semantics(
                                  label: [
                                    for (final c in chips) c.label,
                                  ].join(' '),
                                  excludeSemantics: true,
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    physics:
                                        const NeverScrollableScrollPhysics(),
                                    child: Row(
                                      children: [
                                        for (final chip in chips) ...[
                                          const SizedBox(width: 4),
                                          chip,
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _status(theme, colors),
                      const SizedBox(height: 2),
                      Text(_meta(), style: muted),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool get _pending => call.statusCode == null && !call.hasError;

  Widget _status(ThemeData theme, ProxieColors colors) {
    if (_pending) {
      return SizedBox.square(
        dimension: 14,
        child: CircularProgressIndicator(strokeWidth: 2, color: colors.pending),
      );
    }
    final code = call.statusCode;
    return Text(
      code?.toString() ?? 'ERR',
      style: theme.textTheme.labelLarge?.copyWith(
        color: colors.statusColor(code, error: call.hasError),
        fontWeight: FontWeight.w600,
      ),
    );
  }

  String _meta() {
    final ms = call.durationMs;
    final parts = [
      if (ms != null) formatDuration(ms),
      if (call.statusCode != null) formatSize(call.responseSize),
    ];
    return parts.join(' · ');
  }

  List<_TagChip> _chips(ProxieColors colors) => [
    if (call.tags.contains(CallTag.breakpoint))
      _TagChip('BREAK', colors.clientError),
    if (call.tags.contains(CallTag.mapLocal)) _TagChip('MAP', colors.redirect),
    if (call.tags.contains(CallTag.replayed))
      _TagChip('REPLAY', colors.pending),
    if (call.tags.contains(CallTag.edited))
      _TagChip('EDITED', colors.accentStart),
    for (final badge in ProxieSections.listBadges)
      if (badge.label(call) case final label?)
        _TagChip(label, badge.color ?? colors.pending),
  ];
}

/// [ms] milliseconds as `42 ms` or, from a second on, `1.2 s`.
String formatDuration(int ms) =>
    ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';

/// [bytes] as `512 B`, `1.5 KB` or `2.0 MB`.
String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _MethodBadge extends StatelessWidget {
  const _MethodBadge(this.method, this.color);

  final String method;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 56,
    padding: const EdgeInsets.symmetric(vertical: 3),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      method.toUpperCase(),
      maxLines: 1,
      overflow: TextOverflow.fade,
      softWrap: false,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _TagChip extends StatelessWidget {
  const _TagChip(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: color),
      borderRadius: BorderRadius.circular(3),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color,
        fontSize: 9,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
