import 'package:flutter/material.dart';

import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/ui/common.dart';
import 'package:proxie/src/ui/theme.dart';

/// Readable duration: `850 ms` below ten seconds, else `12.3 s`.
String formatDuration(Duration d) {
  final ms = d.inMilliseconds;
  return ms < 10000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';
}

/// Round marks from zero up to [totalMs]: at most [maxTicks] steps of 1, 2 or
/// 5 times a power of ten.
List<int> traceTicks(int totalMs, {int maxTicks = 5}) {
  if (totalMs <= 0) return const [0];
  var power = 1;
  while (true) {
    for (final m in const [1, 2, 5]) {
      final step = m * power;
      if (step * maxTicks >= totalMs) {
        return [for (var t = 0; t <= totalMs; t += step) t];
      }
    }
    power *= 10;
  }
}

/// The label of the mark at [ms] on the trace's scale.
String traceTickLabel(int ms) {
  if (ms == 0) return '0';
  if (ms < 1000) return '$ms ms';
  final seconds = ms / 1000;
  return seconds == seconds.roundToDouble()
      ? '${seconds.round()} s'
      : '$seconds s';
}

/// The Timing tab: the call drawn as a pulse on a time scale, then when it
/// started, how long it took, its state, adapter, sizes and tags.
///
/// A call records only its start and its duration, so the trace shows exactly
/// that one pulse; it has no phases.
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
    final colors = ProxieColors.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: colors.muted);
    final figure = proxieMono(theme.textTheme.bodySmall);
    return SelectionArea(
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _Trace(
            durationMs: duration?.inMilliseconds,
            signal: error != null ? colors.serverError : colors.accent,
          ),
          const SizedBox(height: 12),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 120, child: Text(label, style: muted)),
                  Expanded(child: Text(value, style: figure)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// The figures below it say the same, so screen readers skip the drawing.
class _Trace extends StatelessWidget {
  const _Trace({required this.durationMs, required this.signal});

  final int? durationMs;
  final Color signal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = ProxieColors.of(context);
    final label = proxieMono(theme.textTheme.labelSmall);
    return ExcludeSemantics(
      child: Container(
        key: const ValueKey('proxie-timing-trace'),
        height: 112,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(12),
          border: Border.fromBorderSide(
            BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: CustomPaint(
          painter: _TracePainter(
            durationMs: durationMs,
            signal: signal,
            grid: scheme.outlineVariant,
            direction: Directionality.of(context),
            scaleLabel: label?.copyWith(
              color: colors.muted,
              fontWeight: FontWeight.w400,
            ),
            durationLabel: label?.copyWith(color: signal),
            textScaler: MediaQuery.textScalerOf(context),
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

/// One pulse: low until the call starts, high while it runs, low again once
/// it ended; a call still running stays high to the edge. Marks along the
/// bottom give the scale, with zero at the rising edge.
class _TracePainter extends CustomPainter {
  const _TracePainter({
    required this.durationMs,
    required this.signal,
    required this.grid,
    required this.direction,
    required this.scaleLabel,
    required this.durationLabel,
    required this.textScaler,
  });

  final int? durationMs;
  final Color signal;
  final Color grid;
  final TextDirection direction;
  final TextStyle? scaleLabel;
  final TextStyle? durationLabel;
  final TextScaler textScaler;

  static const double _inset = 12;
  static const double _gridTop = 12;
  static const double _high = 32;
  static const double _low = 64;
  static const double _axis = 80;

  TextPainter _text(String text, TextStyle? style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: textScaler,
  )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    const left = _inset;
    final right = size.width - _inset;
    final width = right - left;
    if (width <= 0) return;
    final rise = left + width * 0.08;
    final ms = durationMs;
    final fall = ms == null ? null : right - width * 0.08;
    final end = fall ?? right;

    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    canvas.drawLine(const Offset(left, _axis), Offset(right, _axis), gridPaint);

    final ticks = ms == null
        ? const [0]
        : traceTicks(ms, maxTicks: (width / 88).floor().clamp(1, 6));
    var clearFrom = double.negativeInfinity;
    for (final t in ticks) {
      final x = ms == null || ms == 0 ? rise : rise + (end - rise) * t / ms;
      canvas.drawLine(Offset(x, _gridTop), Offset(x, _axis + 4), gridPaint);
      final label = _text(traceTickLabel(t), scaleLabel);
      final labelX = (x - label.width / 2).clamp(left, right - label.width);
      if (labelX >= clearFrom) {
        label.paint(canvas, Offset(labelX, _axis + 8));
        clearFrom = labelX + label.width + 8;
      }
      label.dispose();
    }

    final trace = Path()
      ..moveTo(left, _low)
      ..lineTo(rise, _low)
      ..lineTo(rise, _high)
      ..lineTo(end, _high);
    if (fall != null) {
      trace
        ..lineTo(fall, _low)
        ..lineTo(right, _low);
    }
    canvas.drawPath(
      trace,
      Paint()
        ..color = signal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    if (ms != null) {
      final label = _text(
        formatDuration(Duration(milliseconds: ms)),
        durationLabel,
      );
      label
        ..paint(canvas, Offset(end - label.width, _high - label.height - 4))
        ..dispose();
    }
  }

  @override
  bool shouldRepaint(_TracePainter oldDelegate) =>
      oldDelegate.durationMs != durationMs ||
      oldDelegate.signal != signal ||
      oldDelegate.grid != grid ||
      oldDelegate.direction != direction ||
      oldDelegate.scaleLabel != scaleLabel ||
      oldDelegate.durationLabel != durationLabel ||
      oldDelegate.textScaler != textScaler;
}
