import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/ui/breakpoint/breakpoint_editor.dart';
import 'package:proxie/src/ui/common.dart';
import 'package:proxie/src/ui/detail/call_detail.dart';
import 'package:proxie/src/ui/json/json_tree_controller.dart';
import 'package:proxie/src/ui/json/json_tree_view.dart';
import 'package:proxie/src/ui/list/call_list.dart';
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

  /// While non-null and incomplete, [JsonEncode] waits for it.
  Completer<void>? encodeGate;

  /// JSON documents the worker holds open.
  Iterable<String> get openDocs =>
      ctx.resources.keys.where(RegExp(r'^json:\d+$').hasMatch);

  @override
  int get sessionId => 1;

  @override
  void upsert(ProxieCall call) => unawaited(store.upsert(call));

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) async {
    sent.add(cmd);
    if (cmd is JsonEncode) await encodeGate?.future;
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

    for (final url in [
      'https://api.test/s?a=1&&b',
      'https://api.test/p?',
      'https://api.test/s?q=%E9',
      'https://api.test/s?t=%FF&u=%zz',
    ]) {
      testWidgets('untouched, Execute keeps $url as it is', (tester) async {
        final done = breakpoints.pause(_paused('a', _request(url)));
        await pumpEditor(tester);
        expect(find.byType(BreakpointEditor), findsOneWidget);
        await tester.tap(_execute);
        await tester.pumpAndSettle();
        final request = ((await done) as ExecuteRequest).request;
        expect(request.url.toString(), Uri.parse(url).toString());
      });
    }

    testWidgets('focusing a query row without typing leaves the URL as it '
        'is', (tester) async {
      const url = 'https://api.test/s?a=1&&b';
      final done = breakpoints.pause(_paused('a', _request(url)));
      await pumpEditor(tester);
      await tester.tap(find.text('Query parameters (2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-name-0')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('query-value-1')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('request-url')))
            .controller!
            .text,
        url,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      final request = ((await done) as ExecuteRequest).request;
      expect(request.url.toString(), url);
    });

    testWidgets('a ? in the fragment is not a query', (tester) async {
      final done = breakpoints.pause(
        _paused('a', _request('https://api.test/p#a?b')),
      );
      await pumpEditor(tester);
      expect(find.text('Query parameters (0)'), findsOneWidget);
      await tester.tap(find.text('Query parameters (0)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add parameter'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('query-name-0')), 'n');
      await tester.enterText(find.byKey(const ValueKey('query-value-0')), '1');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('request-url')))
            .controller!
            .text,
        'https://api.test/p?n=1#a?b',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      final request = ((await done) as ExecuteRequest).request;
      expect(request.url.queryParameters, {'n': '1'});
      expect(request.url.fragment, 'a?b');
    });

    testWidgets('a query escape that is not UTF-8 shows raw in the table', (
      tester,
    ) async {
      unawaited(
        breakpoints.pause(
          _paused('a', _request('https://api.test/s?q=%E9&r=caf%C3%A9')),
        ),
      );
      await pumpEditor(tester);
      await tester.tap(find.text('Query parameters (2)'));
      await tester.pumpAndSettle();
      String value(int i) => tester
          .widget<TextField>(find.byKey(ValueKey('query-value-$i')))
          .controller!
          .text;
      expect(value(0), '%E9');
      expect(value(1), 'café');
      await release(tester);
    });

    testWidgets('a query typed into the URL field replaces the table rows', (
      tester,
    ) async {
      final done = breakpoints.pause(
        _paused('a', _request('https://api.test/s?a=1')),
      );
      await pumpEditor(tester);
      await tester.enterText(
        find.byKey(const ValueKey('request-url')),
        'https://api.test/s?a=1&b=2',
      );
      await tester.pumpAndSettle();
      expect(find.text('Query parameters (2)'), findsOneWidget);
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      final request = ((await done) as ExecuteRequest).request;
      expect(request.url.toString(), 'https://api.test/s?a=1&b=2');
    });

    final invalid = <(String, Future<void> Function(WidgetTester), String)>[
      (
        'a method that is not a token',
        (t) =>
            t.enterText(find.byKey(const ValueKey('request-method')), 'GE T'),
        'not a valid method',
      ),
      (
        'a URL that is not http or https',
        (t) =>
            t.enterText(find.byKey(const ValueKey('request-url')), 'ftp://x/y'),
        'http or https',
      ),
      (
        'a header name with a space',
        (t) => t.enterText(find.byKey(const ValueKey('header-name-0')), 'x a'),
        'not a valid header name',
      ),
      (
        'a header value that cannot be sent',
        (t) =>
            t.enterText(find.byKey(const ValueKey('header-value-0')), 'café'),
        'cannot be sent',
      ),
    ];
    for (final (what, edit, error) in invalid) {
      testWidgets('Execute refuses $what, inline, and keeps the pause', (
        tester,
      ) async {
        unawaited(
          breakpoints.pause(_paused('a', _request('https://api.test/a'))),
        );
        await pumpEditor(tester);
        await tester.tap(find.text('Headers (1)'));
        await tester.pumpAndSettle();
        await edit(tester);
        await tester.tap(_execute);
        await tester.pumpAndSettle();
        expect(breakpoints.pending, hasLength(1));
        // In the snackbar and next to the field.
        expect(find.textContaining(error), findsNWidgets(2));
        await release(tester);
      });
    }

    testWidgets('response headers follow the received-value rule', (
      tester,
    ) async {
      final done = breakpoints.pause(
        _paused(
          'a',
          _request('https://api.test/a'),
          phase: BreakpointPhase.response,
          response: ProxieResponse(
            statusCode: 200,
            headers: const {
              'x-a': ['é is fine as received'],
            },
            body: ProxieBody.empty(),
          ),
        ),
      );
      await pumpEditor(tester);
      await tester.tap(find.text('Headers (1)'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('header-name-0')),
        'x a',
      );
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      expect(breakpoints.pending, hasLength(1));
      expect(find.textContaining('not a valid header name'), findsNWidgets(2));
      tester
          .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
          .removeCurrentSnackBar();
      await tester.enterText(
        find.byKey(const ValueKey('header-name-0')),
        'x-a',
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('not a valid header name'), findsNothing);
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      final response = ((await done) as ExecuteResponse).response;
      expect(response.headers['x-a'], ['é is fine as received']);
    });

    testWidgets('a response breakpoint without a response offers no '
        'Execute', (tester) async {
      final done = breakpoints.pause(
        _paused(
          'a',
          _request('https://api.test/a'),
          phase: BreakpointPhase.response,
        ),
      );
      await pumpEditor(tester);
      expect(find.textContaining('No response'), findsOneWidget);
      expect(tester.widget<FilledButton>(_execute).onPressed, isNull);
      await tester.tap(_abort);
      await tester.pumpAndSettle();
      expect(await done, isA<Abort>());
    });

    testWidgets('JSON documents of paused calls are closed once the calls '
        'are resolved: Execute, Abort, Continue, timeout', (tester) async {
      Future<BreakpointResolution> pause(String id) => breakpoints.pause(
        _paused(
          id,
          _request(
            'https://api.test/$id',
            method: 'POST',
            body: _json('{"a":1}'),
          ),
        ),
      );
      final a = pause('a');
      final b = pause('b');
      final c = pause('c');
      final d = pause('d');
      await pumpEditor(tester);
      expect(worker.openDocs, hasLength(1));
      await tester.tap(_execute);
      await tester.pumpAndSettle();
      expect(await a, isA<ExecuteRequest>());
      await tester.tap(_abort);
      await tester.pumpAndSettle();
      expect(await b, isA<Abort>());
      await tester.tap(_continue);
      await tester.pumpAndSettle();
      expect(await c, isA<ContinueUnchanged>());
      expect(worker.openDocs, hasLength(1), reason: 'only d is open');
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(await d, isA<ContinueUnchanged>());
      expect(find.byType(BreakpointEditor), findsNothing);
      expect(worker.openDocs, isEmpty);
    });

    testWidgets('a call that continues while Execute builds tells the user '
        'and sends nothing', (tester) async {
      final done = breakpoints.pause(
        _paused(
          'a',
          _request(
            'https://api.test/a',
            method: 'POST',
            body: _json('{"a":1}'),
          ),
        ),
      );
      unawaited(
        breakpoints.pause(_paused('b', _request('https://api.test/b'))),
      );
      await pumpEditor(tester);
      final tree = tester
          .widget<JsonTreeView>(find.byType(JsonTreeView))
          .controller;
      await tree.apply(const DeleteNode(1));
      await tester.pumpAndSettle();
      worker.encodeGate = Completer<void>();
      await tester.tap(_execute);
      await tester.pump();
      expect(find.byType(BusyLine), findsOneWidget);
      breakpoints.resolve('a', const ContinueUnchanged());
      await tester.pump();
      worker.encodeGate!.complete();
      await tester.pumpAndSettle();
      expect(await done, isA<ContinueUnchanged>());
      expect(find.textContaining('already continued'), findsOneWidget);
      expect(find.textContaining("Couldn't"), findsNothing);
      expect(find.text('GET https://api.test/b'), findsOneWidget);
      expect(breakpoints.pending, hasLength(1));
      await release(tester);
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
        'https://api.test/s?q=a%20b&page=1',
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
      // The URL field follows the table.
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('request-url')))
            .controller!
            .text,
        'https://api.test/s?q=a%20b&page=2%263&n=v',
      );
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

  test('a disposed controller does not close the document a newer one '
      'reopened in the same scope', () async {
    final store = MemoryStore();
    await store.startSession();
    final worker = _Worker(store);
    final bytes = Uint8List.fromList(utf8.encode('{"a":1}'));
    JsonTreeController controller() => JsonTreeController(
      worker,
      'c',
      'request',
      editable: true,
      scope: 'editor',
      bytes: bytes,
      closeOnDispose: true,
    );
    final old = controller();
    await pumpEventQueue();
    final fresh = controller();
    await pumpEventQueue();
    expect(fresh.status, JsonTreeStatus.ready);
    old.dispose();
    await pumpEventQueue();
    expect(worker.openDocs, hasLength(1));
    fresh.dispose();
    await pumpEventQueue();
    expect(worker.openDocs, isEmpty);
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
        // The drain check runs once the real event loop delivered the drain.
        await tester.pumpAndSettle();
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

    testWidgets('backing out of an auto-opened editor hands the inspector to '
        'the user: it stays open when the queue drains', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      final breakpoints = Proxie.engine!.breakpoints;
      Proxie.engine!.rules = RuleSet([_breakpointRule()]);
      await tester.pumpWidget(hostApp());
      final (a,) = await pauseRequest(tester, '/a');
      expect(find.byType(BreakpointEditor), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);

      await tester.runAsync(() async {
        breakpoints.resolve(
          breakpoints.pending.single.callId,
          const ContinueUnchanged(),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settleTransitions(tester);
      expect(await tester.runAsync(() => a), isA<Proceed>());
      expect(shellFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('a call resolved and another paused in the same turn keeps '
        'the inspector up and shows the next call', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final page = ValueNotifier<Widget?>(null);
      addTearDown(page.dispose);
      final adapter = _NotifierAdapter(page);
      await initProxie(tester, navigation: ProxieNavigation.adapter(adapter));
      final engine = Proxie.engine!..rules = RuleSet([_breakpointRule()]);
      await tester.pumpWidget(
        MaterialApp(
          builder: Proxie.wrap,
          home: ValueListenableBuilder<Widget?>(
            valueListenable: page,
            builder: (_, p, _) => p ?? const Text('host home'),
          ),
        ),
      );
      final (a,) = await pauseRequest(tester, '/a');
      expect(adapter.shows, 1);
      late Future<RequestDecision> b;
      await tester.runAsync(() async {
        engine.breakpoints.resolve(
          engine.breakpoints.pending.single.callId,
          const ContinueUnchanged(),
        );
        b = engine.onRequest(engine.newCallId(), 'test', getRequest('/b'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await settleTransitions(tester);
      expect(await tester.runAsync(() => a), isA<Proceed>());
      expect(find.text('GET https://api.test/b'), findsOneWidget);
      expect(adapter.shows, 1);
      expect(adapter.hides, 0);

      await tester.tap(_continue);
      await settleTransitions(tester);
      expect(await tester.runAsync(() => b), isA<Proceed>());
      expect(adapter.hides, 1, reason: 'opened for the pause, drained');
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('while calls stay paused behind the inspector, a bar offers '
        'to open the editor again', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      Proxie.engine!.rules = RuleSet([_breakpointRule()]);
      await tester.pumpWidget(hostApp());
      final (a,) = await pauseRequest(tester, '/a');
      expect(find.text('1 paused'), findsNothing, reason: 'editor on top');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('1 paused'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Open'));
      await tester.pumpAndSettle();
      expect(find.byType(BreakpointEditor), findsOneWidget);
      await tester.tap(_continue);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => a), isA<Proceed>());
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('tablet: the editor covers the split layout', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      await initProxie(tester);
      Proxie.engine!.rules = RuleSet([_breakpointRule()]);
      await tester.pumpWidget(hostApp());
      final (a,) = await pauseRequest(tester, '/a');
      expect(find.byType(BreakpointEditor), findsOneWidget);
      expect(tester.getSize(find.byType(BreakpointEditor)), tabletSize);
      expect(find.byType(CallList), findsNothing);
      await tester.tap(_continue);
      await tester.pumpAndSettle();
      expect(await tester.runAsync(() => a), isA<Proceed>());
      await tester.runAsync(Proxie.shutdown);
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
  int shows = 0;
  int hides = 0;

  @override
  bool get isShowing => page.value != null;

  @override
  void show(Widget inspector, {required VoidCallback onDismissed}) {
    shows++;
    page.value = inspector;
  }

  @override
  void hide() {
    if (page.value == null) return;
    hides++;
    page.value = null;
  }
}
