import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:proxie/src/core/breakpoint_controller.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/ui/theme.dart';

/// Counts the distinct calls seen on a call stream.
///
/// Only calls still in flight are remembered (to recognize their later
/// snapshots), so memory stays bounded by the number of pending calls.
class SessionCallCounter extends ValueNotifier<int> {
  SessionCallCounter(Stream<ProxieCall> calls) : super(0) {
    _sub = calls.listen(_onCall);
  }

  late final StreamSubscription<ProxieCall> _sub;
  final _inFlight = <String>{};

  void _onCall(ProxieCall call) {
    final done = call.response != null || call.error != null;
    if (done) {
      // A call first seen finished still counts once.
      if (!_inFlight.remove(call.id)) value++;
    } else if (_inFlight.add(call.id)) {
      value++;
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    super.dispose();
  }
}

/// The floating Proxie button.
///
/// Draggable; on release it snaps to the nearest horizontal edge, always
/// inside the safe area. Shows [callCount] as a badge and pulses while
/// [breakpoints] has paused calls. Fills its parent (pass tight constraints,
/// e.g. inside a `Stack` with `fit: StackFit.expand`); only the button itself
/// takes pointer events.
class ProxieBubble extends StatefulWidget {
  const ProxieBubble({
    required this.callCount,
    required this.breakpoints,
    required this.onTap,
    super.key,
  });

  final ValueListenable<int> callCount;
  final BreakpointController breakpoints;
  final VoidCallback onTap;

  /// Diameter in logical pixels.
  static const double size = 52;

  /// Gap to the safe area's edges.
  static const double margin = 8;

  @override
  State<ProxieBubble> createState() => _ProxieBubbleState();
}

class _ProxieBubbleState extends State<ProxieBubble>
    with TickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  late final Animation<double> _scale = Tween<double>(
    begin: 1,
    end: 1.15,
  ).animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut));
  late final AnimationController _snap = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );
  StreamSubscription<List<PausedCall>>? _breakpointSub;

  // Position: on the right or left edge, at a vertical fraction of the free
  // height, so rotation and resizes keep it in a sensible place.
  bool _right = true;
  double _yFraction = 0.7;
  // While dragging or snapping, the free top-left offset.
  Offset? _free;
  Animation<Offset>? _snapAnimation;
  Rect _bounds = Rect.zero;

  @override
  void initState() {
    super.initState();
    _snap.addListener(() => setState(() => _free = _snapAnimation!.value));
    _snap.addStatusListener((status) {
      if (status == AnimationStatus.completed) setState(() => _free = null);
    });
    _listenBreakpoints();
  }

  @override
  void didUpdateWidget(ProxieBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.breakpoints, widget.breakpoints)) {
      _breakpointSub?.cancel();
      _listenBreakpoints();
    }
  }

  void _listenBreakpoints() {
    _breakpointSub = widget.breakpoints.changes.listen(_updatePulse);
    _updatePulse(widget.breakpoints.pending);
  }

  void _updatePulse(List<PausedCall> pending) {
    if (pending.isNotEmpty) {
      if (!_pulse.isAnimating) _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _breakpointSub?.cancel();
    _pulse.dispose();
    _snap.dispose();
    super.dispose();
  }

  Offset _resting() {
    final x = _right ? _bounds.right : _bounds.left;
    return Offset(x, _bounds.top + _yFraction * _bounds.height);
  }

  Offset _clamp(Offset o) => Offset(
    o.dx.clamp(_bounds.left, _bounds.right),
    o.dy.clamp(_bounds.top, _bounds.bottom),
  );

  void _onPanStart(DragStartDetails _) {
    _snap.stop();
    _free ??= _resting();
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() => _free = _clamp((_free ?? _resting()) + d.delta));
  }

  void _onPanEnd(DragEndDetails _) {
    final from = _free ?? _resting();
    _right = from.dx + ProxieBubble.size / 2 > _bounds.center.dx;
    _yFraction = _bounds.height <= 0
        ? 0
        : ((from.dy - _bounds.top) / _bounds.height).clamp(0.0, 1.0);
    _snapAnimation = Tween<Offset>(
      begin: from,
      end: _resting(),
    ).animate(CurvedAnimation(parent: _snap, curve: Curves.easeOutCubic));
    _snap.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const size = ProxieBubble.size;
        const margin = ProxieBubble.margin;
        final left = padding.left + margin;
        final top = padding.top + margin;
        final right = constraints.maxWidth - padding.right - margin - size;
        final bottom = constraints.maxHeight - padding.bottom - margin - size;
        // On screens too small for the margins, pin to the top-left.
        _bounds = Rect.fromLTRB(
          left,
          top,
          right < left ? left : right,
          bottom < top ? top : bottom,
        );
        final pos = _free == null ? _resting() : _clamp(_free!);
        return Stack(
          children: [
            Positioned(left: pos.dx, top: pos.dy, child: _button(context)),
          ],
        );
      },
    );
  }

  Widget _button(BuildContext context) {
    final colors = ProxieColors.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: widget.callCount,
      builder: (context, count, _) => Semantics(
        button: true,
        label: 'Open Proxie inspector',
        value: count == 1 ? '1 call' : '$count calls',
        excludeSemantics: true,
        onTap: widget.onTap,
        child: GestureDetector(
          onTap: widget.onTap,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          child: ScaleTransition(
            scale: _scale,
            child: SizedBox.square(
              dimension: ProxieBubble.size,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: colors.accentGradient,
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Text(
                        'P',
                        style: TextStyle(
                          color: Color(0xFFFFFFFF),
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                  if (count > 0)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: _Badge(count > 99 ? '99+' : '$count'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
    padding: const EdgeInsets.symmetric(horizontal: 5),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: const Color(0xFF0D1117),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: const Color(0xFFFFFFFF), width: 1.5),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 11,
        fontWeight: FontWeight.w700,
        height: 1.2,
      ),
    ),
  );
}
