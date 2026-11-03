import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/ui/breakpoint/breakpoint_editor.dart';
import 'package:proxie/src/ui/detail/call_detail.dart';
import 'package:proxie/src/ui/json/json_tree_view.dart';
import 'package:proxie/src/ui/rules/rule_editor.dart';
import 'package:proxie/src/ui/rules/rules_controller.dart';

import '../support/ui_harness.dart';

/// Runs commands straight against a [MemoryStore].
class _Worker implements ProxieWorker {
  _Worker(this.store);

  final MemoryStore store;
  late final WorkerContext ctx = WorkerContext(
    store: store,
    config: const ProxieConfig(),
  );
  final List<WorkerCommand<Object?>> sent = [];

  @override
  int get sessionId => 1;

  @override
  void upsert(ProxieCall call) => unawaited(store.upsert(call));

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) async {
    sent.add(cmd);
    try {
      return await cmd.execute(ctx);
    } on Object catch (e, st) {
      throw ProxieWorkerException.wrap(e, st);
    }
  }

  @override
  Future<void> dispose() async {}
}

ProxieBody _json(String text) => ProxieBody(
  bytes: Uint8List.fromList(utf8.encode(text)),
  contentType: 'application/json',
  kind: BodyKind.json,
);

ProxieRequest _request(
  String url, {
  String method = 'GET',
  Map<String, List<String>> headers = const {
    'x-a': ['1'],
  },
  ProxieBody? body,
}) => ProxieRequest(
  method: method,
  url: Uri.parse(url),
  headers: headers,
  body: body ?? ProxieBody.empty(),
);

PausedCall _paused(
  String id,
  ProxieRequest request, {
  BreakpointPhase phase = BreakpointPhase.request,
  ProxieResponse? response,
}) => PausedCall(
  callId: id,
  phase: phase,
  request: request,
  response: response,
  pausedAt: DateTime.now(),
);

final Finder _execute = find.widgetWithText(FilledButton, 'Execute');
final Finder _abort = find.widgetWithText(OutlinedButton, 'Abort');
final Finder _continue = find.widgetWithText(
  OutlinedButton,
  'Continue unchanged',
);
final Finder _rawEditor = find.byKey(const ValueKey('proxie-raw-editor'));

ProxieRule _breakpointRule({BreakpointPhase phase = BreakpointPhase.request}) =>
    ProxieRule(
      id: 'bp',
      name: 'bp',
      kind: RuleKind.breakpoint,
      matcher: UrlMatcher('https://api.test/*'),
      phase: phase,
    );

void main() {
  group('BreakpointEditor', () {
    late MemoryStore store;
    late _Worker worker;
    late BreakpointController breakpoints;

    setUp(() async {
      store = MemoryStore();
      await store.startSession();
      worker = _Worker(store);
      breakpoints = BreakpointController(timeout: const Duration(seconds: 5));
    });

    tearDown(() => breakpoints.dispose());

    /// Resolves what is still paused, so no timeout outlives the test.
    Future<void> release(WidgetTester tester) async {
      for (final p in breakpoints.pending) {
        breakpoints.resolve(p.callId, const ContinueUnchanged());
      }
      await tester.pumpAndSettle();
    }

    /// A home page that pushes the editor, so its closing can be seen.
    Future<void> pumpEditor(WidgetTester tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await tester.pumpWidget(
        MaterialApp(
          theme: ProxieTheme.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => BreakpointEditor(
                        breakpoints: breakpoints,
                        worker: worker,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    testWidgets('editing a header then Execute resolves with ExecuteRequest '
        'containing the header', (tester) async {
      final done = breakpoints.pause(
        _paused('a', _request('https://api.test/users')),
      );
      await pumpEditor(tester);
      expect(find.text('GET https://api.test/users'), findsOneWidget);

      await tester.tap(find.text('Headers (1)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('header-value-0')), '2');
      await tester.tap(find.text('Add header'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('header-name-1')),
        'X-New',
      );
      await tester.enterText(
        find.byKey(const ValueKey('header-value-1')),
        'yes',
      );
      await tester.tap(_execute);
      await tester.pumpAndSettle();

      final r = await done;
      expect(r, isA<ExecuteRequest>());
      final request = (r as ExecuteRequest).request;
      expect(request.headers, {
        'x-a': ['2'],
        'x-new': ['yes'],
      });
      expect(request.url, Uri.parse('https://api.test/users'));
      expect(find.byType(BreakpointEditor), findsNothing, reason: 'drained');
    });

    testWidgets('untouched, Execute hands back the same request', (
      tester,
    ) async {
      final original = _request(
        'https://api.test/s?q=a%20b&flag&x=1+2#frag',
        method: 'POST',
        body: _json('{"id":7}'),
      );
      final done = breakpoints.pause(_paused('a', original));
      await pumpEditor(tester);
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      final request = ((await done) as ExecuteRequest).request;
      expect(request.method, 'POST');
      expect(request.url.toString(), original.url.toString());
      expect(request.headers, original.headers);
      expect(request.body.bytes, original.body.bytes);
    });

    testWidgets('method, URL and query parameters are edited', (tester) async {
      final done = breakpoints.pause(
        _paused('a', _request('https://api.test/s?q=a%20b&page=1')),
      );
      await pumpEditor(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('request-url')))
            .controller!
            .text,
        'https://api.test/s',
      );
      await tester.enterText(
        find.byKey(const ValueKey('request-method')),
        'put',
      );
      await tester.tap(find.text('Query parameters (2)'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('query-value-0')))
            .controller!
            .text,
        'a b',
      );
      await tester.enterText(
        find.byKey(const ValueKey('query-value-1')),
        '2&3',
      );
      await tester.tap(find.text('Add parameter'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('query-name-2')), 'n');
      await tester.enterText(find.byKey(const ValueKey('query-value-2')), 'v');
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      final request = ((await done) as ExecuteRequest).request;
      expect(request.method, 'PUT');
      expect(
        request.url.toString(),
        'https://api.test/s?q=a%20b&page=2%263&n=v',
      );
      expect(request.url.queryParameters['page'], '2&3');
    });

    testWidgets('a raw body edit is sent', (tester) async {
      final done = breakpoints.pause(
        _paused(
          'a',
          _request(
            'https://api.test/s',
            method: 'POST',
            body: ProxieBody(
              bytes: Uint8List.fromList(utf8.encode('hello')),
              contentType: 'text/plain',
              kind: BodyKind.text,
            ),
          ),
        ),
      );
      await pumpEditor(tester);
      await tester.enterText(_rawEditor, 'bye');
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      final request = ((await done) as ExecuteRequest).request;
      expect(utf8.decode(request.body.bytes), 'bye');
    });

    testWidgets('a JSON body opens from the live bytes in its own scope and '
        'a tree edit is sent', (tester) async {
      final done = breakpoints.pause(
        _paused(
          'a',
          _request(
            'https://api.test/s',
            method: 'POST',
            body: _json('{"id":7,"token":"secret"}'),
          ),
        ),
      );
      await pumpEditor(tester);
      // Nothing is stored for the call: the tree comes from the paused one.
      expect(find.textContaining('secret', findRichText: true), findsOneWidget);
      final open = worker.sent.whereType<OpenJson>().single;
      expect(open.scope, 'breakpoint:a:request');
      final tree = tester
          .widget<JsonTreeView>(find.byType(JsonTreeView))
          .controller;
      // Root 0, "id" 1, "token" 2.
      await tree.apply(const DeleteNode(1));
      await tester.pumpAndSettle();
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      final request = ((await done) as ExecuteRequest).request;
      expect(utf8.decode(request.body.bytes), '{"token":"secret"}');
    });

    testWidgets('Abort resolves Abort', (tester) async {
      final done = breakpoints.pause(
        _paused('a', _request('https://api.test/a')),
      );
      await pumpEditor(tester);
      await tester.tap(_abort);
      await tester.pumpAndSettle();
      expect(await done, isA<Abort>());
    });

    testWidgets('Continue unchanged resolves ContinueUnchanged', (
      tester,
    ) async {
      final done = breakpoints.pause(
        _paused('a', _request('https://api.test/a')),
      );
      await pumpEditor(tester);
      await tester.tap(_continue);
      await tester.pumpAndSettle();
      expect(await done, isA<ContinueUnchanged>());
    });

    testWidgets('queue indicator reads "1 of 3 paused" and follows the '
        'queue', (tester) async {
      final a = breakpoints.pause(_paused('a', _request('https://api.test/a')));
      unawaited(
        breakpoints.pause(_paused('b', _request('https://api.test/b'))),
      );
      unawaited(
        breakpoints.pause(_paused('c', _request('https://api.test/c'))),
      );
      await pumpEditor(tester);
      expect(find.text('1 of 3 paused'), findsOneWidget);
      expect(find.text('GET https://api.test/a'), findsOneWidget);

      await tester.tap(_continue);
      await tester.pumpAndSettle();
      expect(await a, isA<ContinueUnchanged>());
      expect(find.text('1 of 2 paused'), findsOneWidget);
      expect(find.text('GET https://api.test/b'), findsOneWidget);
      await release(tester);
    });

    testWidgets('timeout closes the editor of that call and shows the next '
        'paused call; the last timeout closes the editor', (tester) async {
      final a = breakpoints.pause(_paused('a', _request('https://api.test/a')));
      await pumpEditor(tester);
      expect(find.textContaining('Continues unchanged in'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      final b = breakpoints.pause(_paused('b', _request('https://api.test/b')));
      await tester.pump();
      await tester.pump();
      expect(find.text('1 of 2 paused'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(await a, isA<ContinueUnchanged>());
      expect(find.text('GET https://api.test/b'), findsOneWidget);
      expect(find.text('1 of 1 paused'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(await b, isA<ContinueUnchanged>());
      expect(find.byType(BreakpointEditor), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('the countdown shows the controller deadline', (tester) async {
      unawaited(
        breakpoints.pause(_paused('a', _request('https://api.test/a'))),
      );
      await pumpEditor(tester);
      expect(breakpoints.deadlineOf('a'), isNotNull);
      expect(find.text('Continues unchanged in 5 s'), findsOneWidget);
      expect(breakpoints.deadlineOf('nope'), isNull);
      await release(tester);
    });

    testWidgets('response phase: status, headers and body are edited and '
        'Execute resolves ExecuteResponse', (tester) async {
      final done = breakpoints.pause(
        _paused(
          'a',
          _request('https://api.test/a'),
          phase: BreakpointPhase.response,
          response: ProxieResponse(
            statusCode: 200,
            reasonPhrase: 'OK',
            headers: const {
              'content-type': ['application/json'],
            },
            body: _json('{"ok":true}'),
          ),
        ),
      );
      await pumpEditor(tester);
      expect(find.text('Response breakpoint'), findsOneWidget);
      expect(
        worker.sent.whereType<OpenJson>().single.scope,
        'breakpoint:a:response',
      );
      await tester.enterText(
        find.byKey(const ValueKey('response-status')),
        '503',
      );
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      final response = ((await done) as ExecuteResponse).response;
      expect(response.statusCode, 503);
      expect(response.headers['content-type'], ['application/json']);
      expect(utf8.decode(response.body.bytes), '{"ok":true}');
    });

    testWidgets('the same call pausing again at its response replaces the '
        'request form and is not resolved by it', (tester) async {
      final request = breakpoints.pause(
        _paused('a', _request('https://api.test/a')),
      );
      await pumpEditor(tester);
      expect(find.text('Request breakpoint'), findsOneWidget);
      // Resolved elsewhere, then paused again at the response.
      breakpoints.resolve('a', const ContinueUnchanged());
      final response = breakpoints.pause(
        _paused(
          'a',
          _request('https://api.test/a'),
          phase: BreakpointPhase.response,
          response: ProxieResponse(
            statusCode: 200,
            headers: const {},
            body: ProxieBody.empty(),
          ),
        ),
      );
      expect(await request, isA<ContinueUnchanged>());
      await tester.pumpAndSettle();
      expect(find.text('Response breakpoint'), findsOneWidget);
      await tester.tap(_abort);
      await tester.pumpAndSettle();
      expect(await response, isA<Abort>());
    });

    testWidgets('an invalid status is refused without resolving', (
      tester,
    ) async {
      unawaited(
        breakpoints.pause(
          _paused(
            'a',
            _request('https://api.test/a'),
            phase: BreakpointPhase.response,
            response: ProxieResponse(
              statusCode: 200,
              headers: const {},
              body: ProxieBody.empty(),
            ),
          ),
        ),
      );
      await pumpEditor(tester);
      await tester.enterText(
        find.byKey(const ValueKey('response-status')),
        '42',
      );
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      expect(breakpoints.pending, hasLength(1));
      expect(find.textContaining('Status must be'), findsOneWidget);
      await release(tester);
    });
  });

  group('auto-open', () {
    tearDown(() async {
      await Proxie.shutdown();
    });

    /// Runs page transitions without settling: the resolved calls, which
    /// never get a response here, spin in the list.
    Future<void> settleTransitions(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
    }

    Future<(Future<RequestDecision>,)> pauseRequest(
      WidgetTester tester,
      String path,
    ) async {
      final engine = Proxie.engine!;
      late Future<RequestDecision> decision;
      await tester.runAsync(() async {
        decision = engine.onRequest(
          engine.newCallId(),
          'test',
          getRequest(path),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      return (decision,);
    }

    for (final (name, keyed) in [('overlay', false), ('navigatorKey', true)]) {
      testWidgets('$name: a pause opens the inspector on the editor; '
          'resolving the last closes both', (tester) async {
        addTearDown(tester.view.reset);
        setViewSize(tester, phoneSize);
        final key = GlobalKey<NavigatorState>();
        await initProxie(
          tester,
          navigation: keyed
              ? ProxieNavigation.navigatorKey(key)
              : const ProxieNavigation.overlay(),
        );
        Proxie.engine!.rules = RuleSet([_breakpointRule()]);
        await tester.pumpWidget(hostApp(navigatorKey: key));
        expect(shellFinder, findsNothing);

        final (decision,) = await pauseRequest(tester, '/users');
        expect(find.byType(BreakpointEditor), findsOneWidget);
        expect(find.text('1 of 1 paused'), findsOneWidget);
        expect(find.text('GET https://api.test/users'), findsOneWidget);

        await tester.tap(_continue);
        await tester.pumpAndSettle();
        final d = await tester.runAsync(() => decision);
        expect(d, isA<Proceed>());
        expect(find.byType(BreakpointEditor), findsNothing);
        expect(
          shellFinder,
          findsNothing,
          reason: 'it was opened for the pause',
        );
        expect(find.text('host home'), findsOneWidget);
        await tester.runAsync(Proxie.shutdown);
      });
    }

    testWidgets('an adapter of the app opens the inspector on the editor', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final page = ValueNotifier<Widget?>(null);
      addTearDown(page.dispose);
      await initProxie(
        tester,
        navigation: ProxieNavigation.adapter(_NotifierAdapter(page)),
      );
      Proxie.engine!.rules = RuleSet([_breakpointRule()]);
      await tester.pumpWidget(
        MaterialApp(
          builder: Proxie.wrap,
          home: ValueListenableBuilder<Widget?>(
            valueListenable: page,
            builder: (_, p, _) => p ?? const Text('host home'),
          ),
        ),
      );
      final (decision,) = await pauseRequest(tester, '/a');
      expect(find.byType(BreakpointEditor), findsOneWidget);
      await tester.tap(_abort);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => decision), isA<AbortRequest>());
      expect(page.value, isNull);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('with the inspector already open, more pauses push one '
        'editor; draining it keeps the inspector open', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      Proxie.engine!.rules = RuleSet([_breakpointRule()]);
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);

      final (a,) = await pauseRequest(tester, '/a');
      final (b,) = await pauseRequest(tester, '/b');
      expect(find.byType(BreakpointEditor), findsOneWidget);
      expect(find.text('1 of 2 paused'), findsOneWidget);

      await tester.tap(_continue);
      await settleTransitions(tester);
      await tester.tap(_continue);
      await settleTransitions(tester);
      expect(await tester.runAsync(() => a), isA<Proceed>());
      expect(await tester.runAsync(() => b), isA<Proceed>());
      expect(find.byType(BreakpointEditor), findsNothing);
      expect(shellFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('an editor closed by back comes back for the next pause', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      Proxie.engine!.rules = RuleSet([_breakpointRule()]);
      await tester.pumpWidget(hostApp());
      final (a,) = await pauseRequest(tester, '/a');
      expect(find.byType(BreakpointEditor), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(BreakpointEditor), findsNothing);
      expect(shellFinder, findsOneWidget);

      final (b,) = await pauseRequest(tester, '/b');
      expect(find.byType(BreakpointEditor), findsOneWidget);
      expect(find.text('1 of 2 paused'), findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
      expect(await tester.runAsync(() => a), isA<Proceed>());
      expect(await tester.runAsync(() => b), isA<Proceed>());
    });

    testWidgets('shutdown while paused releases every pause', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      Proxie.engine!.rules = RuleSet([_breakpointRule()]);
      await tester.pumpWidget(hostApp());
      final (a,) = await pauseRequest(tester, '/a');
      final (b,) = await pauseRequest(tester, '/b');
      expect(find.byType(BreakpointEditor), findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => a), isA<Proceed>());
      expect(await tester.runAsync(() => b), isA<Proceed>());
      expect(find.byType(BreakpointEditor), findsNothing);
    });
  });

  group('"Breakpoint on this URL"', () {
    testWidgets('opens the rule editor pre-filled as a breakpoint rule', (
      tester,
    ) async {
      final store = MemoryStore();
      await store.startSession();
      final worker = _Worker(store);
      final engine = ProxieEngine(config: const ProxieConfig(), sink: worker);
      final rules = RulesController(worker: worker, engine: engine);
      addTearDown(() {
        rules.dispose();
        engine.dispose();
      });
      final call = ProxieCall(
        id: 'c1',
        sessionId: 1,
        adapter: 'test',
        request: _request('https://api.test/users?page=2', method: 'POST'),
        response: ProxieResponse(
          statusCode: 200,
          headers: const {},
          body: _json('{"id":1}'),
        ),
        startedAt: DateTime(2026, 11, 3),
        duration: const Duration(milliseconds: 5),
      );
      await store.upsert(call);
      final calls = StreamController<ProxieCall>.broadcast();
      addTearDown(calls.close);
      await tester.pumpWidget(
        RulesScope(
          controller: rules,
          child: MaterialApp(
            theme: ProxieTheme.dark(),
            home: Scaffold(
              body: Builder(
                builder: (context) => CallDetail(
                  worker: worker,
                  calls: calls.stream,
                  callId: call.id,
                  renderCap: 5 * 1024 * 1024,
                  actions: ruleDetailActions(context),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Breakpoint on this URL'));
      await tester.pumpAndSettle();
      expect(find.byType(RuleEditor), findsOneWidget);
      expect(find.text('Pause at'), findsOneWidget);
      // No response draft is opened for a breakpoint rule.
      expect(
        worker.sent.whereType<OpenJson>().where((o) => o.scope != 'view'),
        isEmpty,
      );
      await tester.tap(find.byTooltip('Save rule'));
      await tester.pumpAndSettle();
      final rule = engine.rules.rules.single;
      expect(rule.kind, RuleKind.breakpoint);
      expect(rule.matcher.pattern, 'https://api.test/users*');
      expect(rule.method, 'POST');
      expect(rule.phase, BreakpointPhase.both);
    });
  });
}

/// Shows the inspector through a [ValueNotifier] the host app renders.
class _NotifierAdapter implements ProxieNavigationAdapter {
  _NotifierAdapter(this.page);

  final ValueNotifier<Widget?> page;

  @override
  bool get isShowing => page.value != null;

  @override
  void show(Widget inspector, {required VoidCallback onDismissed}) =>
      page.value = inspector;

  @override
  void hide() => page.value = null;
}
