import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/ui/detail/body_view.dart';
import 'package:proxie/src/ui/detail/call_detail.dart';
import 'package:proxie/src/ui/detail/copy_actions.dart';

/// Runs commands straight against a [MemoryStore].
class _Worker implements ProxieWorker {
  _Worker(this.store);

  final MemoryStore store;
  late final WorkerContext _ctx = WorkerContext(
    store: store,
    config: const ProxieConfig(),
  );

  /// While non-null, [GetCall] throws this.
  Error? failWith;
  int gets = 0;

  @override
  int get sessionId => 1;

  @override
  void upsert(ProxieCall call) => unawaited(store.upsert(call));

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) async {
    if (cmd is GetCall) {
      gets++;
      final error = failWith;
      if (error != null) throw error;
    }
    return await cmd.execute(_ctx);
  }

  @override
  Future<void> dispose() async {}
}

ProxieBody _body(List<int> bytes, String? contentType) =>
    ProxieBody.from(Uint8List.fromList(bytes), contentType);

ProxieCall _call({
  String id = 'c1',
  ProxieBody? requestBody,
  ProxieResponse? response,
  ProxieError? error,
  Map<String, List<String>> requestHeaders = const {
    'accept': ['application/json'],
  },
}) => ProxieCall(
  id: id,
  sessionId: 1,
  adapter: 'http',
  request: ProxieRequest(
    method: 'POST',
    url: Uri.parse('https://api.test/users?page=2'),
    headers: requestHeaders,
    body:
        requestBody ?? _body(utf8.encode('{"name":"ada"}'), 'application/json'),
  ),
  response: response,
  error: error,
  startedAt: DateTime(2026, 11, 2, 10, 30),
  duration: response == null && error == null
      ? null
      : const Duration(milliseconds: 123),
);

ProxieResponse _response(ProxieBody body, {int status = 200}) => ProxieResponse(
  statusCode: status,
  headers: {
    'content-type': [?body.contentType],
    'x-trace': ['abc'],
  },
  body: body,
);

void main() {
  late MemoryStore store;
  late _Worker worker;
  late StreamController<ProxieCall> calls;
  late List<String> clipboard;

  setUp(() async {
    store = MemoryStore();
    await store.startSession();
    worker = _Worker(store);
    calls = StreamController<ProxieCall>.broadcast();
    clipboard = [];
  });

  tearDown(() {
    ProxieSections.clear();
    return calls.close();
  });

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
  }

  Future<void> pumpDetail(
    WidgetTester tester, {
    String id = 'c1',
    ProxieDetailActions actions = const ProxieDetailActions(),
    BodyJsonBuilder? jsonBuilder,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ProxieTheme.dark(),
        home: Scaffold(
          body: CallDetail(
            worker: worker,
            calls: calls.stream,
            callId: id,
            renderCap: 5 * 1024 * 1024,
            actions: actions,
            jsonBuilder: jsonBuilder,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(Tab, label));
    await tester.pumpAndSettle();
  }

  Future<void> chooseCopy(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('Copy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pump();
  }

  testWidgets('Copy cURL writes toCurl(request) to the clipboard', (
    tester,
  ) async {
    mockClipboard(tester);
    final c = _call(response: _response(_body([], null)));
    await store.upsert(c);
    await pumpDetail(tester);

    await chooseCopy(tester, 'Copy cURL');
    expect(clipboard, [toCurl(c.request)]);
    expect(find.text('cURL copied'), findsOneWidget);
  });

  testWidgets('Copy URL, bodies and headers write the right text', (
    tester,
  ) async {
    mockClipboard(tester);
    final c = _call(
      response: _response(_body(utf8.encode('hello'), 'text/plain')),
    );
    await store.upsert(c);
    await pumpDetail(tester);

    await chooseCopy(tester, 'Copy URL');
    await chooseCopy(tester, 'Copy request body');
    await chooseCopy(tester, 'Copy response body');
    await chooseCopy(tester, 'Copy headers');
    expect(clipboard, [
      'https://api.test/users?page=2',
      '{"name":"ada"}',
      'hello',
      headersText(c),
    ]);
    expect(clipboard.last, contains('accept: application/json'));
    expect(clipboard.last, contains('x-trace: abc'));
  });

  testWidgets('binary response shows a hex view, not text', (tester) async {
    final bytes = [0x00, 0x01, 0xFF, 0x48, 0x69, 0x80, 0x90];
    await store.upsert(
      _call(response: _response(_body(bytes, 'application/octet-stream'))),
    );
    await pumpDetail(tester);

    expect(find.byKey(const ValueKey('proxie-hex-view')), findsOneWidget);
    expect(find.textContaining('00 01 ff 48 69 80 90'), findsOneWidget);
  });

  test('hexDump shows offsets, bytes and ASCII, capped at the limit', () {
    final dump = hexDump(
      Uint8List.fromList(List.generate(20, (i) => 0x41 + i)),
    );
    expect(
      dump.split('\n').first,
      '00000000  41 42 43 44 45 46 47 48 49 4a 4b 4c 4d 4e 4f 50  '
      '|ABCDEFGHIJKLMNOP|',
    );
    expect(dump.split('\n')[1], startsWith('00000010  51 52 53 54 '));
    final big = hexDump(Uint8List(10000));
    expect(big.split('\n'), hasLength(4096 ~/ 16));
  });

  test('textChunks splits lines and cuts long ones', () {
    expect(textChunks('a\n\nbc'), ['a', '', 'bc']);
    expect(textChunks('abcdefg', maxChunk: 3), ['abc', 'def', 'g']);
    expect(textChunks(''), ['']);
  });

  testWidgets('image with broken bytes falls back to the hex view', (
    tester,
  ) async {
    final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];
    await store.upsert(_call(response: _response(_body(png, 'image/png'))));
    await pumpDetail(tester);
    expect(find.byType(Image), findsOneWidget);

    // Decoding fails asynchronously, outside the fake clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('proxie-hex-view')), findsOneWidget);
  });

  testWidgets('6 MB body shows the "Show" placeholder until tapped', (
    tester,
  ) async {
    final big = Uint8List(6 * 1024 * 1024)..fillRange(0, 6 * 1024 * 1024, 0x61);
    final body = ProxieBody(
      bytes: big,
      kind: BodyKind.text,
      contentType: 'text/plain',
    );
    await store.upsert(_call(response: _response(body)));
    await pumpDetail(tester);

    expect(find.text('Show'), findsOneWidget);
    expect(find.byKey(const ValueKey('proxie-raw-text')), findsNothing);

    await tester.tap(find.text('Show'));
    await tester.pump();
    expect(find.text('Show'), findsNothing);
    expect(find.byKey(const ValueKey('proxie-raw-text')), findsOneWidget);
  });

  testWidgets('truncated body shows the placeholder and a truncated notice', (
    tester,
  ) async {
    final body = ProxieBody(
      bytes: Uint8List.fromList(utf8.encode('partial')),
      kind: BodyKind.text,
      contentType: 'text/plain',
      truncated: true,
      originalLength: 9000000,
    );
    await store.upsert(_call(response: _response(body)));
    await pumpDetail(tester);

    expect(find.text('Show'), findsOneWidget);
    expect(find.textContaining('Truncated'), findsOneWidget);
    await tester.tap(find.text('Show'));
    await tester.pump();
    expect(find.text('partial'), findsOneWidget);
    expect(find.textContaining('Truncated'), findsOneWidget);
  });

  testWidgets('json goes through the jsonBuilder seam; raw text without it', (
    tester,
  ) async {
    final json = _body(utf8.encode('{"id":1}'), 'application/json');
    await store.upsert(_call(response: _response(json)));
    await pumpDetail(tester);
    expect(find.text('{"id":1}'), findsOneWidget);

    await pumpDetail(
      tester,
      jsonBuilder: (context, body) => const Text('json tree'),
    );
    expect(find.text('json tree'), findsOneWidget);
  });

  testWidgets('request tab shows the request body', (tester) async {
    await store.upsert(_call(response: _response(_body([], null))));
    await pumpDetail(tester);
    expect(find.text('No body'), findsOneWidget);

    await openTab(tester, 'Request');
    expect(find.text('{"name":"ada"}'), findsOneWidget);
  });

  testWidgets('headers and timing tabs show their data', (tester) async {
    await store.upsert(
      _call(response: _response(_body(utf8.encode('x'), 'text/plain'))),
    );
    await pumpDetail(tester);

    await openTab(tester, 'Headers');
    expect(find.text('accept'), findsOneWidget);
    expect(find.text('x-trace'), findsOneWidget);
    expect(find.text('abc'), findsOneWidget);

    await openTab(tester, 'Timing');
    expect(find.text('123 ms'), findsOneWidget);
    expect(find.text('http'), findsOneWidget);
  });

  testWidgets('registered custom tab appears when it applies', (tester) async {
    ProxieSections.addDetailTab(
      ProxieDetailTab(
        id: 'graphql',
        label: 'GraphQL',
        appliesTo: (call) => call.request.url.path == '/users',
        build: (context, call) => Text('gql ${call.id}'),
      ),
    );
    ProxieSections.addDetailTab(
      ProxieDetailTab(
        id: 'never',
        label: 'Never',
        appliesTo: (call) => false,
        build: (context, call) => const Text('never'),
      ),
    );
    ProxieSections.addDetailTab(
      ProxieDetailTab(
        id: 'broken',
        label: 'Broken',
        appliesTo: (call) => throw StateError('bad tab'),
        build: (context, call) => const Text('broken'),
      ),
    );
    await store.upsert(_call(response: _response(_body([], null))));
    await pumpDetail(tester);

    expect(find.widgetWithText(Tab, 'Never'), findsNothing);
    expect(find.widgetWithText(Tab, 'Broken'), findsNothing);
    expect(tester.takeException(), isA<StateError>());
    await openTab(tester, 'GraphQL');
    expect(find.text('gql c1'), findsOneWidget);
  });

  testWidgets('a pending call shows its response once it completes', (
    tester,
  ) async {
    final pending = _call();
    await store.upsert(pending);
    await pumpDetail(tester);
    expect(find.text('Waiting for response…'), findsOneWidget);

    // Another call's update does not re-fetch.
    final before = worker.gets;
    calls.add(_call(id: 'other'));
    await tester.pump();
    expect(worker.gets, before);

    final done = pending.copyWith(
      response: _response(_body(utf8.encode('done!'), 'text/plain')),
      duration: const Duration(milliseconds: 5),
    );
    await store.upsert(done);
    calls.add(done);
    await tester.pump();
    await tester.pump();
    expect(find.text('Waiting for response…'), findsNothing);
    expect(find.text('done!'), findsOneWidget);
  });

  testWidgets('a failed call shows its error', (tester) async {
    await store.upsert(
      _call(
        error: const ProxieError(type: 'timeout', message: 'took too long'),
      ),
    );
    await pumpDetail(tester);
    expect(find.textContaining('timeout'), findsWidgets);
    expect(find.textContaining('took too long'), findsOneWidget);
  });

  testWidgets('a call that is gone shows a message', (tester) async {
    await pumpDetail(tester, id: 'missing');
    expect(find.text('This request is no longer available'), findsOneWidget);
  });

  testWidgets('a worker error shows Retry, which loads the call', (
    tester,
  ) async {
    await store.upsert(_call(response: _response(_body([], null))));
    worker.failWith = StateError('worker gone');
    await pumpDetail(tester);
    expect(find.text("Couldn't load this request"), findsOneWidget);

    worker.failWith = null;
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.text("Couldn't load this request"), findsNothing);
    expect(find.widgetWithText(Tab, 'Response'), findsOneWidget);
  });

  testWidgets('rule and resend actions show only when wired', (tester) async {
    await store.upsert(_call(response: _response(_body([], null))));
    await pumpDetail(tester);
    expect(find.byTooltip('Map Local from this response'), findsNothing);
    expect(find.byTooltip('Breakpoint on this URL'), findsNothing);
    expect(find.byTooltip('Edit & resend'), findsNothing);

    final used = <String>[];
    await pumpDetail(
      tester,
      actions: ProxieDetailActions(
        onMapLocal: (call) => used.add('map ${call.id}'),
        onBreakpoint: (call) => used.add('bp ${call.id}'),
        onEditResend: (call) => used.add('resend ${call.id}'),
      ),
    );
    await tester.tap(find.byTooltip('Map Local from this response'));
    await tester.tap(find.byTooltip('Breakpoint on this URL'));
    await tester.tap(find.byTooltip('Edit & resend'));
    expect(used, ['map c1', 'bp c1', 'resend c1']);
  });

  testWidgets('Map Local is hidden while the call has no response', (
    tester,
  ) async {
    await store.upsert(_call());
    await pumpDetail(
      tester,
      actions: ProxieDetailActions(onMapLocal: (_) {}, onBreakpoint: (_) {}),
    );
    expect(find.byTooltip('Map Local from this response'), findsNothing);
    expect(find.byTooltip('Breakpoint on this URL'), findsOneWidget);
  });
}
