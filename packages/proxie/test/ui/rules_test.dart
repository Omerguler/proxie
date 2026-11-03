import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/ui/detail/call_detail.dart';
import 'package:proxie/src/ui/json/json_tree_controller.dart';
import 'package:proxie/src/ui/json/json_tree_view.dart';
import 'package:proxie/src/ui/rules/message_draft.dart';
import 'package:proxie/src/ui/rules/rule_editor.dart';
import 'package:proxie/src/ui/rules/rules_controller.dart';
import 'package:proxie/src/ui/rules/rules_screen.dart';

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

  /// Commands for which this returns true fail instead of running.
  bool Function(WorkerCommand<Object?> cmd)? failWhen;

  /// While non-null and incomplete, [SaveRules] waits for it.
  Completer<void>? gate;

  Iterable<T> sentOf<T>() => sent.whereType<T>();

  @override
  int get sessionId => 1;

  @override
  void upsert(ProxieCall call) => unawaited(store.upsert(call));

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) async {
    sent.add(cmd);
    if (failWhen?.call(cmd) ?? false) throw StateError('worker down');
    if (cmd is SaveRules) await gate?.future;
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

ProxieCall _call({
  ProxieBody? body,
  int status = 201,
  Map<String, List<String>> headers = const {
    'content-type': ['application/json'],
    'x-trace': ['abc'],
  },
}) => ProxieCall(
  id: 'c1',
  sessionId: 1,
  adapter: 'test',
  request: ProxieRequest(
    method: 'POST',
    url: Uri.parse('https://api.test/users?page=2#top'),
    headers: const {},
    body: ProxieBody.empty(),
  ),
  response: ProxieResponse(
    statusCode: status,
    reasonPhrase: 'Created',
    headers: headers,
    body: body ?? _json('{"id":7,"name":"ada"}'),
  ),
  startedAt: DateTime(2026, 11, 2),
  duration: const Duration(milliseconds: 5),
);

ProxieRule _rule(String id, {bool enabled = true}) => ProxieRule(
  id: id,
  name: 'rule $id',
  kind: RuleKind.mapLocal,
  matcher: UrlMatcher('https://api.test/$id*'),
  enabled: enabled,
  mapLocal: MapLocalAction(
    response: ProxieResponse(
      statusCode: 200,
      headers: const {},
      body: ProxieBody.empty(),
    ),
  ),
);

final Finder _rawEditor = find.byKey(const ValueKey('proxie-raw-editor'));

String _fieldText(WidgetTester tester, Finder f) =>
    tester.widget<TextField>(f).controller!.text;

void main() {
  late MemoryStore store;
  late _Worker worker;
  late ProxieEngine engine;
  late RulesController rules;

  setUp(() async {
    store = MemoryStore();
    await store.startSession();
    worker = _Worker(store);
    engine = ProxieEngine(config: const ProxieConfig(), sink: worker);
    rules = RulesController(worker: worker, engine: engine);
  });

  tearDown(() {
    rules.dispose();
    engine.dispose();
  });

  Widget app(Widget home) => RulesScope(
    controller: rules,
    child: MaterialApp(theme: ProxieTheme.dark(), home: home),
  );

  Future<void> pumpDetail(WidgetTester tester, ProxieCall call) async {
    await store.upsert(call);
    final calls = StreamController<ProxieCall>.broadcast();
    addTearDown(calls.close);
    await tester.pumpWidget(
      app(
        Scaffold(
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
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMapLocal(WidgetTester tester, ProxieCall call) async {
    await pumpDetail(tester, call);
    await tester.tap(find.byTooltip('Map Local from this response'));
    await tester.pumpAndSettle();
    expect(find.byType(RuleEditor), findsOneWidget);
  }

  Future<void> showResponseTab(WidgetTester tester) async {
    await tester.tap(find.text('Response'));
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Save rule'));
    await tester.pumpAndSettle();
  }

  Future<void> pickPreset(WidgetTester tester, String label) async {
    await tester.tap(find.text('Presets'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text(label),
      100,
      scrollable: find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  testWidgets('"Map Local from this response" opens the editor pre-filled '
      'with the call URL, method, status and body', (tester) async {
    await openMapLocal(tester, _call());

    expect(
      _fieldText(tester, find.byKey(const ValueKey('rule-pattern'))),
      'https://api.test/users*',
    );
    expect(find.text('POST'), findsOneWidget);

    await showResponseTab(tester);
    expect(
      _fieldText(tester, find.byKey(const ValueKey('response-status'))),
      '201',
    );
    // The captured JSON body opens in the tree, in the editor's own scope.
    expect(find.textContaining('name: ', findRichText: true), findsOneWidget);
    final open = worker.sentOf<OpenJson>().where((o) => o.scope != 'view');
    expect(open.single.scope, 'rule-editor');

    await save(tester);
    expect(find.byType(RuleEditor), findsNothing);
    final rule = engine.rules.rules.single;
    expect(rule.kind, RuleKind.mapLocal);
    expect(rule.method, 'POST');
    expect(rule.matcher.pattern, 'https://api.test/users*');
    final response = rule.mapLocal!.response!;
    expect(response.statusCode, 201);
    expect(response.headers['x-trace'], ['abc']);
    // Untouched, the body is the captured one byte for byte.
    expect(utf8.decode(response.body.bytes), '{"id":7,"name":"ada"}');
    expect((await store.rules()).single.id, rule.id);
  });

  testWidgets('picking preset not_found sets status 404 and the preset body', (
    tester,
  ) async {
    await openMapLocal(tester, _call());
    await showResponseTab(tester);
    await pickPreset(tester, '404 Not Found');

    expect(
      _fieldText(tester, find.byKey(const ValueKey('response-status'))),
      '404',
    );
    expect(_fieldText(tester, _rawEditor), contains('"code": 404'));

    await save(tester);
    final response = engine.rules.rules.single.mapLocal!.response!;
    expect(response.statusCode, 404);
    final preset = builtInPresets
        .firstWhere((p) => p.id == 'not_found')
        .build(null)
        .response!;
    expect(response.body.bytes, preset.body.bytes);
  });

  testWidgets('a raw body edit is what gets saved', (tester) async {
    await openMapLocal(tester, _call());
    await showResponseTab(tester);
    await tester.tap(find.byTooltip('Raw text'));
    await tester.pumpAndSettle();
    await tester.enterText(_rawEditor, '{"id":8}');
    await save(tester);
    final body = engine.rules.rules.single.mapLocal!.response!.body;
    expect(utf8.decode(body.bytes), '{"id":8}');
    expect(body.kind, BodyKind.json);
  });

  testWidgets('a closed editor releases its document; the detail keeps '
      'its view', (tester) async {
    Iterable<String> docs() =>
        worker.ctx.resources.keys.where(RegExp(r'^json:\d+$').hasMatch);
    await openMapLocal(tester, _call());
    await showResponseTab(tester);
    expect(docs(), hasLength(2));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(docs(), hasLength(1));
  });

  testWidgets('a tree edit is saved from the document; an editor closed '
      'without saving leaves no edits behind', (tester) async {
    JsonTreeController tree() =>
        tester.widget<JsonTreeView>(find.byType(JsonTreeView)).controller;

    await openMapLocal(tester, _call());
    await showResponseTab(tester);
    // Root 0, "id" 1, "name" 2.
    await tree().apply(const DeleteNode(1));
    await tester.pumpAndSettle();
    expect(tree().edited, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(engine.rules.rules, isEmpty);

    await tester.tap(find.byTooltip('Map Local from this response'));
    await tester.pumpAndSettle();
    await showResponseTab(tester);
    expect(tree().edited, isFalse);
    expect(find.textContaining('id: ', findRichText: true), findsOneWidget);

    await tree().apply(const DeleteNode(2));
    await tester.pumpAndSettle();
    await save(tester);
    expect(worker.sentOf<JsonEncode>(), isNotEmpty);
    final body = engine.rules.rules.single.mapLocal!.response!.body;
    expect(utf8.decode(body.bytes), '{"id":7}');
  });

  testWidgets('headers can be added, edited and removed', (tester) async {
    await openMapLocal(tester, _call());
    await showResponseTab(tester);
    await tester.tap(find.text('Headers (2)'));
    await tester.pumpAndSettle();
    // Rows follow the captured order: content-type, x-trace.
    await tester.enterText(
      find.byKey(const ValueKey('header-value-1')),
      'edited',
    );
    await tester.tap(find.byTooltip('Remove header').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add header'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('header-name-1')),
      'x-new',
    );
    await tester.enterText(find.byKey(const ValueKey('header-value-1')), '1');
    await save(tester);
    final headers = engine.rules.rules.single.mapLocal!.response!.headers;
    expect(headers, {
      'x-trace': ['edited'],
      'x-new': ['1'],
    });
  });

  testWidgets('a truncated captured body is not saved as the mock', (
    tester,
  ) async {
    final cut = ProxieBody(
      bytes: Uint8List.fromList(utf8.encode('{"items":[1,2')),
      contentType: 'application/json',
      kind: BodyKind.json,
      truncated: true,
      originalLength: 9000000,
    );
    await openMapLocal(tester, _call(body: cut));
    await showResponseTab(tester);
    expect(find.textContaining('truncated'), findsWidgets);

    await save(tester);
    expect(find.byType(RuleEditor), findsOneWidget);
    expect(engine.rules.rules, isEmpty);
    expect(worker.sentOf<SaveRules>(), isEmpty);

    // Replacing the body makes the rule savable.
    await pickPreset(tester, '200 OK (empty list)');
    await save(tester);
    final body = engine.rules.rules.single.mapLocal!.response!.body;
    expect(utf8.decode(body.bytes), '[]');
  });

  testWidgets('a failing save keeps the rule in the engine, shows an error '
      'and never throws', (tester) async {
    await openMapLocal(tester, _call());
    worker.failWhen = (cmd) => cmd is SaveRules;
    await save(tester);
    expect(tester.takeException(), isNull);
    expect(engine.rules.rules, hasLength(1));
    expect(find.byType(RuleEditor), findsOneWidget);
    expect(find.textContaining("couldn't be saved"), findsOneWidget);

    worker.failWhen = null;
    await save(tester);
    expect(find.byType(RuleEditor), findsNothing);
    expect(engine.rules.rules, hasLength(1));
    expect(await store.rules(), hasLength(1));
  });

  testWidgets('custom preset appears in the picker after save', (tester) async {
    await openMapLocal(tester, _call());
    await showResponseTab(tester);
    await tester.enterText(
      find.byKey(const ValueKey('response-status')),
      '418',
    );
    await tester.tap(find.text('Save as preset'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('preset-label')),
      'Teapot',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(worker.sentOf<SavePreset>().single.label, 'Teapot');

    await tester.enterText(
      find.byKey(const ValueKey('response-status')),
      '200',
    );
    await pickPreset(tester, 'Teapot');
    expect(
      _fieldText(tester, find.byKey(const ValueKey('response-status'))),
      '418',
    );
  });

  testWidgets('toggling a rule off updates engine.rules and persists', (
    tester,
  ) async {
    engine.rules = RuleSet([_rule('a'), _rule('b')]);
    await tester.pumpWidget(app(const RulesScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect([for (final r in engine.rules.rules) r.enabled], [false, true]);
    expect([for (final r in await store.rules()) r.enabled], [false, true]);
  });

  testWidgets('reorder persists order', (tester) async {
    engine.rules = RuleSet([_rule('a'), _rule('b'), _rule('c')]);
    await tester.pumpWidget(app(const RulesScreen()));
    await tester.pumpAndSettle();
    final handle = find.byKey(const ValueKey('rule-drag-c'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect([for (final r in engine.rules.rules) r.id], ['c', 'a', 'b']);
    expect([for (final r in await store.rules()) r.id], ['c', 'a', 'b']);
  });

  testWidgets('reorder downwards persists order', (tester) async {
    engine.rules = RuleSet([_rule('a'), _rule('b'), _rule('c')]);
    await tester.pumpWidget(app(const RulesScreen()));
    await tester.pumpAndSettle();
    final handle = find.byKey(const ValueKey('rule-drag-a'));
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(0, 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect([for (final r in engine.rules.rules) r.id], ['b', 'c', 'a']);
    expect([for (final r in await store.rules()) r.id], ['b', 'c', 'a']);
  });

  testWidgets('a new rule goes first, so no older rule shadows it', (
    tester,
  ) async {
    engine.rules = RuleSet([_rule('a')]);
    await openMapLocal(tester, _call());
    await save(tester);
    expect(engine.rules.rules, hasLength(2));
    expect(engine.rules.rules.last.id, 'a');
    expect(engine.rules.rules.first.matcher.pattern, 'https://api.test/users*');
    expect((await store.rules()).last.id, 'a');
  });

  testWidgets('values masked at capture are flagged but can be saved', (
    tester,
  ) async {
    await openMapLocal(
      tester,
      _call(
        headers: const {
          'content-type': ['application/json'],
          'set-cookie': [kMask],
        },
        body: _json('{"access_token":"$kMask","id":1}'),
      ),
    );
    await showResponseTab(tester);
    expect(
      find.textContaining('2 values were masked at capture'),
      findsOneWidget,
    );
    // The headers open by themselves, with the masked row marked.
    expect(find.byKey(const ValueKey('header-value-1')), findsOneWidget);
    expect(find.byTooltip('Masked at capture'), findsOneWidget);

    await save(tester);
    expect(find.byType(RuleEditor), findsNothing);
    expect(engine.rules.rules, hasLength(1));
  });

  testWidgets('the masked-value warning follows edits and clears once every '
      'masked value is replaced', (tester) async {
    await openMapLocal(
      tester,
      _call(
        headers: const {
          'content-type': ['application/json'],
          'set-cookie': [kMask],
        },
        body: _json('{"access_token":"$kMask","id":1}'),
      ),
    );
    await showResponseTab(tester);
    // The body is scanned in the worker.
    expect(worker.sentOf<CountMasked>(), isNotEmpty);
    expect(find.textContaining('2 values were masked'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('header-value-1')),
      'sid=1',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('1 value was masked'), findsOneWidget);
    expect(find.byTooltip('Masked at capture'), findsNothing);

    await tester.tap(find.byTooltip('Raw text'));
    await tester.pumpAndSettle();
    await tester.enterText(_rawEditor, '{"access_token":"real","id":1}');
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.textContaining('masked at capture'), findsNothing);
  });

  testWidgets('Latin-1 bodies are scanned for their "******" form', (
    tester,
  ) async {
    await openMapLocal(
      tester,
      _call(
        headers: const {
          'content-type': ['text/plain; charset=iso-8859-1'],
        },
        body: ProxieBody(
          bytes: Uint8List.fromList(latin1.encode('{"token":"******"}')),
          contentType: 'text/plain; charset=iso-8859-1',
          kind: BodyKind.text,
        ),
      ),
    );
    await showResponseTab(tester);
    expect(find.textContaining('1 value was masked'), findsOneWidget);
  });

  testWidgets('the captured-body preset brings the masked warning back', (
    tester,
  ) async {
    await openMapLocal(tester, _call(body: _json('{"access_token":"$kMask"}')));
    await showResponseTab(tester);
    expect(find.textContaining('1 value was masked'), findsOneWidget);
    await pickPreset(tester, '404 Not Found');
    expect(find.textContaining('masked at capture'), findsNothing);
    await pickPreset(tester, '200 OK (captured body)');
    expect(find.textContaining('1 value was masked'), findsOneWidget);
  });

  testWidgets('transport headers of a captured response are dropped', (
    tester,
  ) async {
    await openMapLocal(
      tester,
      _call(
        headers: const {
          'content-type': ['application/json'],
          'content-length': ['21'],
          'transfer-encoding': ['chunked'],
          'content-encoding': ['gzip'],
        },
      ),
    );
    await save(tester);
    expect(engine.rules.rules.single.mapLocal!.response!.headers, {
      'content-type': ['application/json'],
    });
  });

  test('flush gives up after its timeout and says so', () async {
    final slow = _Worker(store)..gate = Completer<void>();
    final controller = RulesController(worker: slow, engine: engine);
    addTearDown(controller.dispose);
    unawaited(controller.save(_rule('a')));
    expect(
      await controller.flush(timeout: const Duration(milliseconds: 20)),
      isFalse,
    );
    slow.gate!.complete();
    expect(await controller.flush(), isTrue);
  });

  test('flush waits for a pending save', () async {
    final gate = Completer<void>();
    final slow = _Worker(store)..gate = gate;
    final controller = RulesController(worker: slow, engine: engine);
    addTearDown(controller.dispose);
    unawaited(controller.save(_rule('a')));
    var flushed = false;
    unawaited(controller.flush().then((_) => flushed = true));
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isFalse);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(flushed, isTrue);
    expect(await store.rules(), hasLength(1));
  });

  testWidgets('delete removes the rule; Undo restores it', (tester) async {
    engine.rules = RuleSet([_rule('a'), _rule('b')]);
    await tester.pumpWidget(app(const RulesScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete rule').first);
    await tester.pumpAndSettle();
    expect([for (final r in engine.rules.rules) r.id], ['b']);
    expect([for (final r in await store.rules()) r.id], ['b']);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect([for (final r in engine.rules.rules) r.id], ['a', 'b']);
    expect([for (final r in await store.rules()) r.id], ['a', 'b']);
  });

  testWidgets('the list shows kind and phase; tapping a rule edits it', (
    tester,
  ) async {
    engine.rules = RuleSet([
      _rule('a'),
      ProxieRule(
        id: 'bp',
        name: 'pause users',
        kind: RuleKind.breakpoint,
        matcher: UrlMatcher('*/users*'),
        phase: BreakpointPhase.response,
      ),
    ]);
    await tester.pumpWidget(app(const RulesScreen()));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Map Local'), findsOneWidget);
    expect(find.byTooltip('Breakpoint (response)'), findsOneWidget);

    await tester.tap(find.text('rule a'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('rule-name')), 'renamed');
    await save(tester);
    expect(engine.rules.rules.first.name, 'renamed');
    expect(engine.rules.rules.first.id, 'a');
    expect(find.text('renamed'), findsOneWidget);
  });

  testWidgets('the add button creates a Map Local rule', (tester) async {
    await tester.pumpWidget(app(const RulesScreen()));
    await tester.pumpAndSettle();
    expect(find.text('No rules yet'), findsOneWidget);
    await tester.tap(find.byTooltip('Add rule'));
    await tester.pumpAndSettle();
    await save(tester);
    // A pattern is required.
    expect(find.byType(RuleEditor), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('rule-pattern')),
      '*/health',
    );
    await save(tester);
    final rule = engine.rules.rules.single;
    expect(rule.kind, RuleKind.mapLocal);
    expect(rule.method, isNull);
    expect(rule.mapLocal!.response!.statusCode, 200);
  });

  group('in the inspector', () {
    tearDown(Proxie.shutdown);

    testWidgets('the app bar opens the rules screen', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Rules'));
      await tester.pumpAndSettle();
      expect(find.byType(RulesScreen), findsOneWidget);
      expect(find.text('No rules yet'), findsOneWidget);
      // Back closes the rules screen, not the inspector.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(RulesScreen), findsNothing);
      expect(shellFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('the detail offers Map Local from this response and a '
        'breakpoint on its URL', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      await initProxie(tester);
      final engine = Proxie.engine!;
      final id = engine.newCallId();
      await tester.runAsync(() async {
        await engine.onRequest(id, 'test', _call().request);
        await engine.onResponse(id, _call().response!);
      });
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      controllerIn(tester).select(id);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      expect(find.byTooltip('Map Local from this response'), findsOneWidget);
      expect(find.byTooltip('Breakpoint on this URL'), findsOneWidget);
      await tester.tap(find.byTooltip('Map Local from this response'));
      await tester.pumpAndSettle();
      expect(find.byType(RuleEditor), findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('phone: back closes the editor, then the detail', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      final engine = Proxie.engine!;
      final id = engine.newCallId();
      await tester.runAsync(() async {
        await engine.onRequest(id, 'test', _call().request);
        await engine.onResponse(id, _call().response!);
      });
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      controllerIn(tester).select(id);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('Map Local from this response'));
      await tester.pumpAndSettle();
      expect(find.byType(RuleEditor), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(RuleEditor), findsNothing);
      expect(find.byTooltip('Map Local from this response'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Map Local from this response'), findsNothing);
      expect(find.text('No requests yet'), findsNothing);
      expect(shellFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });
  });
}
