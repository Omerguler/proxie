import 'package:flutter/material.dart';

import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/call_query.dart';
import 'package:proxie/src/ui/sections.dart';
import 'package:proxie/src/ui/theme.dart';

/// One call in the list: a status tick on the left edge, the method, path
/// over host, status over duration and size, and tag chips (`BREAK`, `MAP`,
/// `REPLAY`, `EDITED`, then registered [ProxieListBadge]s).
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
  static const double height = 56;

  // The widths of the row's aligned columns.
  static const double _methodWidth = 48;
  static const double _durationWidth = 56;
  static const double _sizeWidth = 64;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ProxieColors.of(context);
    final scheme = theme.colorScheme;
    final uri = Uri.tryParse(call.url);
    final path = uri == null
        ? call.url
        : (uri.path.isEmpty ? '/' : uri.path) +
              (uri.hasQuery ? '?${uri.query}' : '');
    // Muted text does not reach 4.5:1 on the selected row's raised surface.
    final metaColor = selected ? scheme.onSurfaceVariant : colors.muted;
    final muted = theme.textTheme.bodySmall?.copyWith(color: metaColor);
    final figures = proxieMono(muted);
    final chips = _chips();
    final ms = call.durationMs;
    // Its own node: a session header above it must not merge into it.
    return Semantics(
      container: true,
      button: onTap != null,
      selected: selected,
      child: Material(
        color: selected ? scheme.surfaceContainerHigh : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          hoverDuration: ProxieMotion.duration,
          child: SizedBox(
            height: height,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Tick(
                  selected
                      ? colors.accent
                      : colors.statusColor(
                          call.statusCode,
                          error: call.hasError,
                        ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: _methodWidth,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        call.method.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: proxieMono(theme.textTheme.labelMedium)
                            ?.copyWith(
                              color: scheme.onSurfaceVariant,
                              height: 20 / 12,
                            ),
                      ),
                      // The host's line, so the method sits on the path's.
                      const SizedBox(height: 18),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
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
                                  physics: const NeverScrollableScrollPhysics(),
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
                    _status(theme, colors, figures),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _figure(
                          ms == null ? '' : formatDuration(ms),
                          figures,
                          _durationWidth,
                        ),
                        _figure(
                          call.statusCode == null
                              ? ''
                              : formatSize(call.responseSize),
                          figures,
                          _sizeWidth,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(width: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  bool get _pending => call.statusCode == null && !call.hasError;

  Widget _figure(String text, TextStyle? style, double width) => SizedBox(
    width: width,
    child: text.isEmpty
        ? null
        : Text(
            text,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.fade,
            textAlign: TextAlign.right,
            style: style,
          ),
  );

  Widget _status(ThemeData theme, ProxieColors colors, TextStyle? figures) {
    final style = proxieMono(
      theme.textTheme.labelMedium,
    )?.copyWith(height: 20 / 12);
    if (_pending) {
      return ExcludeSemantics(
        child: Text(
          '—',
          key: const ValueKey('proxie-call-pending'),
          style: style?.copyWith(color: figures?.color),
        ),
      );
    }
    final code = call.statusCode;
    return Text(
      code?.toString() ?? 'ERR',
      style: style?.copyWith(
        color: colors.statusColor(code, error: call.hasError),
      ),
    );
  }

  List<_TagChip> _chips() => [
    if (call.tags.contains(CallTag.breakpoint)) const _TagChip('BREAK'),
    if (call.tags.contains(CallTag.mapLocal)) const _TagChip('MAP'),
    if (call.tags.contains(CallTag.replayed)) const _TagChip('REPLAY'),
    if (call.tags.contains(CallTag.edited)) const _TagChip('EDITED'),
    for (final badge in ProxieSections.listBadges)
      if (badge.label(call) case final label?)
        _TagChip(label, color: badge.color),
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

/// The signal line on the row's left edge.
class _Tick extends StatelessWidget {
  const _Tick(this.color);

  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: SizedBox(width: 2, child: ColoredBox(color: color)),
  );
}

class _TagChip extends StatelessWidget {
  const _TagChip(this.label, {this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        border: Border.fromBorderSide(
          BorderSide(color: theme.colorScheme.outline),
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: proxieMono(theme.textTheme.labelSmall)?.copyWith(
          color: color ?? theme.colorScheme.onSurfaceVariant,
          fontSize: 10,
          fontWeight: FontWeight.w400,
          height: 14 / 10,
        ),
      ),
    );
  }
}
