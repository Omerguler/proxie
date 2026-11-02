import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/ui/list/call_list.dart';
import 'package:proxie/src/ui/list/call_row.dart';

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

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) {
    log.add(cmd);
    return cmd.execute(_ctx);
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
    expect(worker.log.whereType<QueryCalls>().map((c) => c.offset), {0, 100});
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
