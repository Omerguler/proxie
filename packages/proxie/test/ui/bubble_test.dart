import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';

void main() {
  testWidgets('the amber ring and the pulse show only while a call is paused', (
    tester,
  ) async {
    final breakpoints = BreakpointController();
    addTearDown(breakpoints.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ProxieTheme.dark(),
        home: Scaffold(
          body: ProxieBubble(
            callCount: ValueNotifier(3),
            breakpoints: breakpoints,
            onTap: () {},
          ),
        ),
      ),
    );
    final ring = find.byKey(const ValueKey('proxie-bubble-ring'));
    double scale() => tester
        .widget<ScaleTransition>(
          find.descendant(
            of: find.byType(ProxieBubble),
            matching: find.byType(ScaleTransition),
          ),
        )
        .scale
        .value;
    // Would time out if anything looped.
    await tester.pumpAndSettle();
    expect(ring, findsNothing);
    expect(scale(), 1);

    final resolved = breakpoints.pause(
      PausedCall(
        callId: 'a',
        phase: BreakpointPhase.request,
        request: ProxieRequest(
          method: 'GET',
          url: Uri.parse('https://api.test/a'),
          headers: const {},
          body: ProxieBody.empty(),
        ),
        pausedAt: DateTime.now(),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(ring, findsOneWidget);
    expect(scale(), greaterThan(1));

    breakpoints.resolve('a', const ContinueUnchanged());
    await resolved;
    await tester.pumpAndSettle();
    expect(ring, findsNothing);
    expect(scale(), 1);
  });
}
