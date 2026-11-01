import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

ProxieRequest _req() => ProxieRequest(
  method: 'GET',
  url: Uri.parse('https://a.test/x'),
  headers: {},
  body: ProxieBody.empty(),
);

PausedCall _paused(String id) => PausedCall(
  callId: id,
  phase: BreakpointPhase.request,
  request: _req(),
  pausedAt: DateTime(2026),
);

void main() {
  test('resolve with ExecuteRequest completes the pause with it', () {
    fakeAsync((async) {
      final c = BreakpointController();
      BreakpointResolution? got;
      c.pause(_paused('a')).then((r) => got = r);
      final edited = ExecuteRequest(_req().copyWith(method: 'POST'));
      c.resolve('a', edited);
      async.flushMicrotasks();
      expect(got, same(edited));
      expect(c.pending, isEmpty);
    });
  });

  test('pending keeps arrival order', () {
    fakeAsync((async) {
      final c = BreakpointController();
      for (final id in ['a', 'b', 'c']) {
        c.pause(_paused(id));
      }
      expect(c.pending.map((p) => p.callId), ['a', 'b', 'c']);
      c.resolve('b', const Abort());
      expect(c.pending.map((p) => p.callId), ['a', 'c']);
    });
  });

  test('no action for 60 s continues unchanged and removes the entry', () {
    fakeAsync((async) {
      final c = BreakpointController();
      BreakpointResolution? got;
      c.pause(_paused('a')).then((r) => got = r);
      async.elapse(const Duration(seconds: 59));
      expect(got, isNull);
      expect(c.pending, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(got, isA<ContinueUnchanged>());
      expect(c.pending, isEmpty);
    });
  });

  test('resolve for an unknown id is a no-op', () {
    final c = BreakpointController();
    c.resolve('nope', const Abort());
    expect(c.pending, isEmpty);
  });

  test('changes emits on add and remove', () {
    fakeAsync((async) {
      final c = BreakpointController();
      final seen = <int>[];
      c.changes.listen((l) => seen.add(l.length));
      c.pause(_paused('a'));
      c.resolve('a', const ContinueUnchanged());
      async.flushMicrotasks();
      expect(seen, [1, 0]);
    });
  });
}
