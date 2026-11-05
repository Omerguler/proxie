import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/ui/list/call_list.dart';
import 'package:proxie/src/ui/list/call_row.dart';
import 'package:proxie/src/ui/list/list_controller.dart';

import '../support/ui_harness.dart';

/// Runs commands straight against a [MemoryStore] and records them.
class FakeWorker implements ProxieWorker {
  FakeWorker(this.store, this.sessionId);

  final MemoryStore store;
  final List<WorkerCommand<Object?>> log = [];
  late final WorkerContext _ctx = WorkerContext(
    store: store,
    config: const ProxieConfig(),
  );

  @override
  final int sessionId;

  Iterable<CallQuery> get queried =>
      log.whereType<QueryCalls>().map((c) => c.query);

  @override
  void upsert(ProxieCall call) => unawaited(store.upsert(call));

  /// While true, commands wait for [release] before running.
  bool hold = false;
  final List<(WorkerCommand<Object?>, Completer<void>)> _held = [];

  /// While true, [CountCalls] fails.
  bool failCounts = false;

  /// This many next [CountCalls] fail.
  int failNextCounts = 0;

  int get reloads => log.whereType<CountCalls>().length;

  /// Lets held commands run; only those passing [test] when given.
  void release([bool Function(WorkerCommand<Object?> cmd)? test]) {
    final picked = [
      for (final h in _held)
        if (test == null || test(h.$1)) h,
    ];
    _held.removeWhere(picked.contains);
    for (final h in picked) {
      h.$2.complete();
    }
  }

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) async {
    log.add(cmd);
    if (hold) {
      final gate = Completer<void>();
      _held.add((cmd, gate));
      await gate.future;
    }
    if (cmd is CountCalls) {
      if (failCounts) throw StateError('worker gone');
      if (failNextCounts > 0) {
        failNextCounts--;
        throw StateError('worker busy');
      }
    }
    return await cmd.execute(_ctx);
  }

  @override
  Future<void> dispose() async {}
}

ProxieCall call(
  String id, {
  required DateTime at,
  int session = 1,
  String method = 'GET',
  String path = '/items',
  int? status = 200,
  ProxieError? error,
  Set<CallTag> tags = const {},
}) => ProxieCall(
  id: id,
  sessionId: session,
  adapter: 'http',
  request: ProxieRequest(
    method: method,
    url: Uri.parse('https://api.test$path'),
    headers: const {},
    body: ProxieBody.empty(),
  ),
  response: status == null
      ? null
      : ProxieResponse(
          statusCode: status,
          headers: const {},
          body: ProxieBody.empty(),
        ),
  error: error,
  startedAt: at,
  duration: status == null && error == null
      ? null
      : const Duration(milliseconds: 42),
  tags: tags,
);

const _minute = Duration(minutes: 1);

void main() {
  final epoch = DateTime(2020, 1, 2, 10, 5);
  late DateTime clock;
  late MemoryStore store;
  late FakeWorker worker;
  late StreamController<ProxieCall> calls;

  setUp(() async {
    clock = epoch;
    store = MemoryStore(now: () => clock);
    await store.startSession(); // session 1, 2020-01-02 10:05
    clock = DateTime.now();
    final current = await store.startSession(); // session 2, now
    worker = FakeWorker(store, current);
    calls = StreamController<ProxieCall>.broadcast();
  });

  tearDown(() => calls.close());

  Future<void> pumpList(
    WidgetTester tester, {
    Stream<ProxieCall>? stream,
    ValueChanged<String>? onSelected,
  }) async {
    addTearDown(tester.view.reset);
    setViewSize(tester, phoneSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: ProxieTheme.dark(),
        home: Scaffold(
          body: CallList(
            worker: worker,
            calls: stream ?? calls.stream,
            renderCap: 5 * 1024 * 1024,
            onSelected: onSelected,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('1,000 calls build only the visible rows', (tester) async {
    for (var i = 0; i < 1000; i++) {
      await store.upsert(
        call(
          'c$i',
          session: 2,
          path: '/items/$i',
          at: clock.subtract(Duration(seconds: 1000 - i)),
        ),
      );
    }
    await pumpList(tester);

    expect(find.text('/items/999'), findsOneWidget);
    final built = find.byType(CallRow).evaluate().length;
    expect(built, greaterThan(5));
    expect(built, lessThan(40));
    // Pages of 100, fetched lazily: only the first one so far.
    expect(worker.log.whereType<QueryCalls>().map((c) => c.offset), [0]);

    await tester.drag(find.byType(Scrollable).last, const Offset(0, -8000));
    await tester.pump();
    await tester.pump();
    expect(worker.log.whereType<QueryCalls>().map((c) => c.offset), [0, 100]);
    expect(find.byType(CallRow).evaluate().length, lessThan(40));
  });

  testWidgets('search re-queries with the text after 250 ms', (tester) async {
    await pumpList(tester);
    await tester.enterText(find.byType(TextField), 'users');
    await tester.pump(const Duration(milliseconds: 200));
    expect(worker.queried.where((q) => q.text == 'users'), isEmpty);

    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    expect(worker.queried.last.text, 'users');
    expect(worker.log.whereType<CountCalls>().last.query.text, 'users');
  });

  testWidgets('Errors chip filters by StatusFilter.errors', (tester) async {
    await store.upsert(call('ok', session: 2, at: clock));
    await pumpList(tester);
    expect(worker.queried.last.status, StatusFilter.all);

    await tester.tap(find.widgetWithText(FilterChip, 'Errors'));
    await tester.pump();
    await tester.pump();
    expect(worker.queried.last.status, StatusFilter.errors);
    expect(find.text('No matching requests'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'All'));
    await tester.pump();
    await tester.pump();
    expect(worker.queried.last.status, StatusFilter.all);
    expect(find.byType(CallRow), findsOneWidget);
  });

  group('optional adapter chips', () {
    final builtIn = find.widgetWithText(FilterChip, 'built-in');

    Future<void> pumpChips(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ProxieTheme.dark(),
          home: Scaffold(
            body: CallList(
              worker: worker,
              calls: calls.stream,
              renderCap: 5 * 1024 * 1024,
              adapterNames: const ['http'],
              optionalAdapterNames: const ['built-in'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('hidden while no call is recorded under the name', (
      tester,
    ) async {
      await store.upsert(call('a', at: clock));
      await pumpChips(tester);
      expect(builtIn, findsNothing);
      expect(find.widgetWithText(FilterChip, 'http'), findsNothing);
    });

    testWidgets('shown for a call already stored, and filters', (tester) async {
      await store.upsert(call('a', at: clock).copyWith(adapter: 'built-in'));
      await pumpChips(tester);
      expect(builtIn, findsOneWidget);
      expect(find.widgetWithText(FilterChip, 'http'), findsOneWidget);
      await tester.ensureVisible(builtIn);
      await tester.tap(builtIn);
      await tester.pumpAndSettle();
      expect(worker.queried.last.adapters, {'built-in'});
    });

    testWidgets('appears when such a call arrives', (tester) async {
      await pumpChips(tester);
      expect(builtIn, findsNothing);
      calls.add(call('a', at: clock).copyWith(adapter: 'built-in'));
      await tester.pumpAndSettle();
      expect(builtIn, findsOneWidget);
    });
  });

  testWidgets('other chips set their filters', (tester) async {
    await pumpList(tester);
    Future<CallQuery> tapChip(String label) async {
      final chip = find.widgetWithText(FilterChip, label);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
      await tester.pump();
      return worker.queried.last;
    }

    expect((await tapChip('JSON')).onlyJson, isTrue);
    expect((await tapChip('Hide > 5 MB')).maxSize, 5 * 1024 * 1024);
    expect((await tapChip('Hide binary')).hideBinary, isTrue);
    expect((await tapChip('POST')).methods, {'POST'});
    expect((await tapChip('POST')).methods, isEmpty);
  });

  testWidgets('a new call from the engine appears at the top', (tester) async {
    await store.upsert(
      call(
        'old',
        session: 2,
        path: '/old',
        at: clock.subtract(const Duration(minutes: 1)),
      ),
    );
    final engine = ProxieEngine(
      config: const ProxieConfig(),
      sink: worker,
      sessionId: 2,
    );
    addTearDown(engine.dispose);
    await pumpList(tester, stream: engine.calls);
    expect(find.text('/old'), findsOneWidget);

    await engine.onRequest('new', 'http', getRequest('/new'));
    await tester.pump();
    await tester.pump();
    final rows = tester.widgetList<CallRow>(find.byType(CallRow)).toList();
    expect(rows.map((r) => r.call.id), ['new', 'old']);
    expect(rows.first.call.statusCode, isNull);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Completing the call updates its row in place.
    engine.recordResponse('new', okResponse());
    await tester.pump();
    await tester.pump();
    expect(
      tester.widget<CallRow>(find.byType(CallRow).first).call.statusCode,
      200,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('session header rows, including the previous session', (
    tester,
  ) async {
    for (var i = 0; i < 3; i++) {
      await store.upsert(
        call(
          'p$i',
          path: '/prev/$i',
          at: epoch.add(Duration(minutes: i)),
        ),
      );
    }
    for (var i = 0; i < 2; i++) {
      await store.upsert(
        call(
          'n$i',
          session: 2,
          path: '/now/$i',
          at: clock.add(Duration(seconds: i)),
        ),
      );
    }
    await pumpList(tester);

    expect(find.text('2020-01-02 10:05 — 3 calls'), findsOneWidget);
    expect(
      find.textContaining(RegExp(r'^Today \d\d:\d\d — 2 calls$')),
      findsOneWidget,
    );
    // Headers sit above the first row of each session.
    expect(
      tester.getTopLeft(find.textContaining('Today')).dy,
      lessThan(tester.getTopLeft(find.text('/now/1')).dy),
    );
    expect(
      tester.getTopLeft(find.text('2020-01-02 10:05 — 3 calls')).dy,
      lessThan(tester.getTopLeft(find.text('/prev/2')).dy),
    );
  });

  testWidgets('rows show status colors, tags and badges; tap selects', (
    tester,
  ) async {
    ProxieSections.addListBadge(
      ProxieListBadge(
        id: 'mine',
        label: (c) => c.method == 'DELETE' ? 'DEL' : null,
      ),
    );
    addTearDown(ProxieSections.clear);
    await store.upsert(
      call(
        'a',
        session: 2,
        path: '/missing',
        status: 404,
        at: clock,
        tags: {CallTag.breakpoint, CallTag.mapLocal, CallTag.edited},
      ),
    );
    await store.upsert(
      call(
        'b',
        session: 2,
        method: 'DELETE',
        path: '/broken',
        status: null,
        error: const ProxieError(type: 'timeout', message: 'timed out'),
        at: clock.subtract(const Duration(seconds: 1)),
      ),
    );
    String? selected;
    await pumpList(tester, onSelected: (id) => selected = id);

    const colors = ProxieColors();
    expect(
      tester.widget<Text>(find.text('404')).style?.color,
      colors.clientError,
    );
    expect(
      tester.widget<Text>(find.text('ERR')).style?.color,
      colors.serverError,
    );
    expect(find.text('BREAK'), findsOneWidget);
    expect(find.text('MAP'), findsOneWidget);
    expect(find.text('EDITED'), findsOneWidget);
    expect(find.text('DEL'), findsOneWidget);
    expect(find.text('api.test'), findsNWidgets(2));
    expect(find.textContaining('42 ms'), findsNWidgets(2));

    await tester.tap(find.text('/missing'));
    expect(selected, 'a');
  });

  Future<void> addItems(int n) async {
    for (var i = 0; i < n; i++) {
      await store.upsert(
        call(
          'c$i',
          session: 2,
          path: '/items/$i',
          at: clock.subtract(Duration(seconds: n - i)),
        ),
      );
    }
  }

  Future<ProxieEngine> pumpWithEngine(WidgetTester tester) async {
    final engine = ProxieEngine(
      config: const ProxieConfig(),
      sink: worker,
      sessionId: 2,
    );
    addTearDown(engine.dispose);
    await pumpList(tester, stream: engine.calls);
    return engine;
  }

  testWidgets('stream-driven reloads are throttled to one per 250 ms', (
    tester,
  ) async {
    final engine = await pumpWithEngine(tester);
    expect(worker.reloads, 1);
    for (var i = 0; i < 10; i++) {
      await engine.onRequest('n$i', 'http', getRequest('/n/$i'));
    }
    await tester.pump();
    await tester.pump();
    // The first change reloads at once; the rest wait for the interval.
    expect(worker.reloads, 2);
    await tester.pump(const Duration(milliseconds: 200));
    expect(worker.reloads, 2);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pump();
    expect(worker.reloads, 3);
    expect(find.text('/n/9'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(worker.reloads, 3);
  });

  testWidgets('a reload covers only the pages around the viewport', (
    tester,
  ) async {
    await addItems(1000);
    final engine = await pumpWithEngine(tester);
    for (var i = 0; i < 5; i++) {
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -9000));
      await tester.pump();
      await tester.pump();
    }
    worker.log.clear();
    await engine.onRequest('new', 'http', getRequest('/new'));
    await tester.pump();
    await tester.pump();
    final offsets = worker.log.whereType<QueryCalls>().map((c) => c.offset);
    expect(offsets.length, lessThanOrEqualTo(2));
    expect(offsets, isNot(contains(0)));
  });

  testWidgets('a query change reloads page 0 only and hides old rows', (
    tester,
  ) async {
    await addItems(300);
    await pumpList(tester);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -8000));
    await tester.pump();
    await tester.pump();
    expect(worker.log.whereType<QueryCalls>().map((c) => c.offset), [0, 100]);

    worker
      ..log.clear()
      ..hold = true;
    final get = find.widgetWithText(FilterChip, 'GET');
    await tester.ensureVisible(get);
    await tester.tap(get);
    await tester.pump();
    // The old query's rows are gone while the new ones load.
    expect(find.byType(CallRow), findsNothing);
    worker
      ..hold = false
      ..release();
    await tester.pump();
    await tester.pump();
    expect(worker.log.whereType<QueryCalls>().map((c) => c.offset), [0]);
    expect(find.text('/items/299'), findsOneWidget);
  });

  testWidgets('results for an old query are dropped', (tester) async {
    await store.upsert(call('ok', session: 2, path: '/ok', at: clock));
    worker.hold = true;
    await pumpList(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'Errors'));
    await tester.pump();
    // The first load (unfiltered) answers after the query changed.
    worker.release();
    await tester.pump();
    expect(find.text('/ok'), findsNothing);
    worker
      ..hold = false
      ..release();
    await tester.pump();
    await tester.pump();
    expect(find.text('/ok'), findsNothing);
    expect(find.text('No matching requests'), findsOneWidget);
  });

  testWidgets('a chip tapped while typing keeps the pending search', (
    tester,
  ) async {
    await pumpList(tester);
    await tester.enterText(find.byType(TextField), 'users');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(FilterChip, 'Errors'));
    await tester.pump();
    await tester.pump();
    expect(worker.queried.last.text, 'users');
    expect(worker.queried.last.status, StatusFilter.errors);
    await tester.pump(const Duration(seconds: 1));
    expect(worker.queried.last.text, 'users');
  });

  testWidgets('a failed load shows an error with retry', (tester) async {
    await store.upsert(call('ok', session: 2, path: '/ok', at: clock));
    worker.failCounts = true;
    await pumpList(tester);
    expect(find.text('No requests yet'), findsNothing);
    expect(find.text("Couldn't load requests"), findsOneWidget);

    worker.failCounts = false;
    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.text("Couldn't load requests"), findsNothing);
    expect(find.text('/ok'), findsOneWidget);
  });

  testWidgets('session headers show filtered counts out of the total', (
    tester,
  ) async {
    await store.upsert(call('p0', path: '/p0', at: epoch, status: 500));
    await store.upsert(call('p1', path: '/p1', at: epoch.add(_minute)));
    await store.upsert(
      call('p2', path: '/p2', at: epoch.add(_minute * 2), status: 404),
    );
    await pumpList(tester);
    expect(find.text('2020-01-02 10:05 — 3 calls'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'Errors'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('2020-01-02 10:05 — 2 of 3 calls'), findsOneWidget);
  });

  testWidgets('dispose cancels the search timer and the subscription', (
    tester,
  ) async {
    final controller = ListController(worker: worker, calls: calls.stream);
    await tester.pump();
    expect(calls.hasListener, isTrue);
    // Two calls: the first reloads and starts the cooldown timer, the second
    // waits for it.
    calls
      ..add(call('x', session: 2, at: clock))
      ..add(call('y', session: 2, at: clock));
    await tester.pump();
    final reloads = worker.reloads;
    controller
      ..search('users')
      ..dispose();
    expect(calls.hasListener, isFalse);
    // No pump past the cooldown: a timer still pending here fails the test.
    await tester.pump(const Duration(milliseconds: 10));
    expect(worker.reloads, reloads);
    expect(worker.queried.where((q) => q.text == 'users'), isEmpty);
  });

  testWidgets('2xx, 3xx and 5xx status colors', (tester) async {
    await store.upsert(
      call('a', session: 2, path: '/a', status: 201, at: clock),
    );
    await store.upsert(
      call(
        'b',
        session: 2,
        path: '/b',
        status: 304,
        at: clock.subtract(_minute),
      ),
    );
    await store.upsert(
      call(
        'c',
        session: 2,
        path: '/c',
        status: 503,
        at: clock.subtract(_minute * 2),
      ),
    );
    await pumpList(tester);
    const colors = ProxieColors();
    Color? colorOf(String text) =>
        tester.widget<Text>(find.text(text)).style?.color;
    expect(colorOf('201'), colors.success);
    expect(colorOf('304'), colors.redirect);
    expect(colorOf('503'), colors.serverError);
  });

  testWidgets('new calls keep scrolled rows still; the pill goes to the top', (
    tester,
  ) async {
    await addItems(200);
    final engine = await pumpWithEngine(tester);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -3000));
    await tester.pump();
    await tester.pump();
    final anchor = find.text('/items/150');
    expect(anchor, findsOneWidget);
    final before = tester.getTopLeft(anchor).dy;

    await engine.onRequest('new', 'http', getRequest('/new'));
    engine.recordResponse('new', okResponse());
    // Every frame, not only the settled one, keeps the row in place.
    for (var i = 0; i < 6; i++) {
      await tester.pump();
      expect(tester.getTopLeft(anchor).dy, before, reason: 'frame $i');
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(tester.getTopLeft(anchor).dy, before);
    expect(find.text('1 new'), findsOneWidget);

    await tester.tap(find.text('1 new'));
    await tester.pumpAndSettle();
    expect(find.text('/new'), findsOneWidget);
    expect(find.text('1 new'), findsNothing);
  });

  testWidgets('at the top, new calls show without a pill', (tester) async {
    await addItems(20);
    final engine = await pumpWithEngine(tester);
    await engine.onRequest('new', 'http', getRequest('/new'));
    engine.recordResponse('new', okResponse());
    await tester.pump();
    await tester.pump();
    expect(find.text('/new'), findsOneWidget);
    expect(find.text('1 new'), findsNothing);
  });

  testWidgets('a reload that shrinks the list keeps scrolled rows still', (
    tester,
  ) async {
    for (var i = 0; i < 200; i++) {
      await store.upsert(
        call(
          'c$i',
          session: 2,
          path: '/items/$i',
          status: 500,
          at: clock.subtract(Duration(seconds: 200 - i)),
        ),
      );
    }
    await pumpList(tester);
    await tester.tap(find.widgetWithText(FilterChip, 'Errors'));
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -3000));
    await tester.pump();
    await tester.pump();
    final anchor = find.text('/items/150');
    expect(anchor, findsOneWidget);
    final before = tester.getTopLeft(anchor).dy;

    // The newest call, far above the screen, stops matching the filter.
    final fixed = call(
      'c199',
      session: 2,
      path: '/items/199',
      at: clock.subtract(const Duration(seconds: 1)),
    );
    await store.upsert(fixed);
    calls.add(fixed);
    for (var i = 0; i < 6; i++) {
      await tester.pump();
      expect(tester.getTopLeft(anchor).dy, before, reason: 'frame $i');
    }
    expect(find.textContaining(' new'), findsNothing);
  });

  testWidgets('a reload keeps pages that loaded during its flight', (
    tester,
  ) async {
    await addItems(1000);
    await pumpList(tester);
    worker.hold = true;
    final added = call('x', session: 2, path: '/x', at: DateTime.now());
    await store.upsert(added);
    calls.add(added);
    await tester.pump();
    expect(worker.reloads, 2);

    // Scrolling while the reload is held asks for pages it does not cover.
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
    await tester.pump();
    await tester.pump();
    bool deep(WorkerCommand<Object?> c) => c is QueryCalls && c.offset >= 200;
    final early = worker.log
        .where(deep)
        .cast<QueryCalls>()
        .map((c) => c.offset)
        .toSet();
    expect(early, isNotEmpty);
    worker.release(deep);
    await tester.pump();
    worker
      ..hold = false
      ..release();
    await tester.pump();
    await tester.pump();
    for (final offset in early) {
      expect(
        worker.log.whereType<QueryCalls>().where((c) => c.offset == offset),
        hasLength(1),
        reason: 'offset $offset fetched again',
      );
    }
    expect(find.byType(CallRow), findsWidgets);
  });

  testWidgets('a failed reload still runs the reload asked for meanwhile', (
    tester,
  ) async {
    await store.upsert(call('ok', session: 2, path: '/ok', at: clock));
    worker.hold = true;
    await pumpList(tester);
    // Asked for while the first load is in flight.
    calls.add(call('ok', session: 2, path: '/ok', at: clock));
    await tester.pump();
    worker
      ..failNextCounts = 1
      ..hold = false
      ..release();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(worker.reloads, 2);
    expect(find.text("Couldn't load requests"), findsNothing);
    expect(find.text('/ok'), findsOneWidget);
  });

  double pixelsOf(WidgetTester tester) => tester
      .state<ScrollableState>(find.byType(Scrollable).last)
      .position
      .pixels;

  testWidgets('a fling keeps going through a page load and a new call', (
    tester,
  ) async {
    await addItems(1000);
    Future<(double, List<double>)> run({required bool push}) async {
      worker.log.clear();
      await tester.pumpWidget(const SizedBox());
      final engine = ProxieEngine(
        config: const ProxieConfig(),
        sink: worker,
        sessionId: 2,
      );
      addTearDown(engine.dispose);
      await pumpList(tester, stream: engine.calls);
      final list = find.byType(Scrollable).last;
      await tester.drag(list, const Offset(0, -4800));
      await tester.pumpAndSettle();

      worker.hold = true;
      await tester.fling(list, const Offset(0, -300), 3000);
      final trace = <double>[];
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        trace.add(pixelsOf(tester));
      }
      // Mid-fling: the page it scrolled into arrives, and a call is pushed.
      expect(worker.log.whereType<QueryCalls>(), isNotEmpty);
      worker
        ..hold = false
        ..release();
      if (push) {
        await engine.onRequest('new', 'http', getRequest('/new'));
        engine.recordResponse('new', okResponse());
      }
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        trace.add(pixelsOf(tester));
      }
      await tester.pumpAndSettle();
      return (pixelsOf(tester), trace);
    }

    final (still, _) = await run(push: false);
    final (moved, trace) = await run(push: true);
    for (var i = 1; i < trace.length; i++) {
      expect(trace[i], greaterThan(trace[i - 1]), reason: 'frame $i');
    }
    // Same resting place, shifted by the one row inserted above it.
    expect(moved, closeTo(still + CallRow.height, 0.5));
  });

  testWidgets('scrolled to the end, a new call keeps the last row still', (
    tester,
  ) async {
    await addItems(200);
    final engine = await pumpWithEngine(tester);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -20000));
    await tester.pumpAndSettle();
    final last = find.text('/items/0');
    expect(last, findsOneWidget);
    final before = tester.getTopLeft(last).dy;

    await engine.onRequest('new', 'http', getRequest('/new'));
    engine.recordResponse('new', okResponse());
    for (var i = 0; i < 6; i++) {
      await tester.pump();
      expect(tester.getTopLeft(last).dy, before, reason: 'frame $i');
    }
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(last).dy, before);
    expect(find.text('1 new'), findsOneWidget);
  });

  testWidgets('clearing a filter while scrolled starts the new list at the '
      'top without a pill', (tester) async {
    for (var i = 0; i < 1000; i++) {
      await store.upsert(
        call(
          'c$i',
          session: 2,
          method: i.isEven ? 'GET' : 'POST',
          path: '/items/$i',
          at: clock.subtract(Duration(seconds: 1000 - i)),
        ),
      );
    }
    await pumpList(tester);
    final post = find.widgetWithText(FilterChip, 'POST');
    await tester.ensureVisible(post);
    await tester.tap(post);
    await tester.pump();
    await tester.pump();
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(pixelsOf(tester), greaterThan(0));

    final all = find.widgetWithText(FilterChip, 'All');
    await tester.ensureVisible(all);
    await tester.tap(all);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(pixelsOf(tester), 0);
    expect(find.textContaining(' new'), findsNothing);
    expect(find.text('/items/999'), findsOneWidget);
  });

  testWidgets('a tagged row stays one tappable node naming its tags', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await store.upsert(
        call(
          'tagged',
          session: 2,
          path: '/tagged',
          at: clock,
          tags: const {
            CallTag.breakpoint,
            CallTag.mapLocal,
            CallTag.edited,
            CallTag.replayed,
          },
        ),
      );
      await pumpList(tester, onSelected: (_) {});

      final row = find.bySemanticsLabel(RegExp('/tagged'));
      expect(row, findsOneWidget);
      final label = tester.getSemantics(row).label;
      for (final tag in ['BREAK', 'MAP', 'EDITED', 'REPLAY']) {
        expect(label, contains(tag));
      }
      expect(tester.getSemantics(row), isSemantics(hasTapAction: true));
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('a replayed row shows REPLAY; an edited one EDITED too', (
    tester,
  ) async {
    await store.upsert(
      call(
        'replayed',
        session: 2,
        path: '/replayed',
        at: clock,
        tags: const {CallTag.replayed},
      ),
    );
    await pumpList(tester);
    expect(find.text('REPLAY'), findsOneWidget);
    expect(find.text('EDITED'), findsNothing);
  });

  testWidgets('a session header is not part of the row under it', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await store.upsert(call('n', session: 2, path: '/now', at: clock));
      await pumpList(tester, onSelected: (_) {});

      final row = tester.getSemantics(find.bySemanticsLabel(RegExp('/now')));
      expect(row.label, isNot(contains('Today')));
      expect(row, isSemantics(isButton: true, hasTapAction: true));
      expect(row.childrenCount, 0);
      expect(
        find.bySemanticsLabel(RegExp(r'^Today \d\d:\d\d — 1 call$')),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('the inspector shows the call list', (tester) async {
    addTearDown(Proxie.shutdown);
    addTearDown(tester.view.reset);
    setViewSize(tester, phoneSize);
    await initProxie(tester);
    await tester.pumpWidget(hostApp());
    Proxie.open();
    await tester.pumpAndSettle();
    expect(find.byType(CallList), findsOneWidget);
    expect(find.text('No requests yet'), findsOneWidget);
  });
}
