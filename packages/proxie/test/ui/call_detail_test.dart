import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/core/masking.dart' show kMaskInUrl;
import 'package:proxie/src/runtime.dart';
import 'package:proxie/src/ui/detail/body_view.dart';
import 'package:proxie/src/ui/detail/call_detail.dart';
import 'package:proxie/src/ui/detail/copy_actions.dart';
import 'package:proxie/src/ui/detail/timing_tab.dart';
import 'package:proxie/src/ui/json/json_tree_view.dart';
import 'package:proxie/src/ui/json/text_lines.dart';

import '../support/ui_harness.dart';

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
  final List<WorkerCommand<Object?>> log = [];

  @override
  int get sessionId => 1;

  @override
  void upsert(ProxieCall call) => unawaited(store.upsert(call));

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) async {
    log.add(cmd);
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
    // The call, then its body's lines or tree rows, each a worker trip.
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
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

  test('textChunks rejoins to the text and prefers line ends', () {
    expect(textChunks(''), ['']);
    expect(textChunks('short'), ['short']);
    expect(textChunks('aaa\nbbb\nccc', maxChunk: 5), ['aaa\n', 'bbb\n', 'ccc']);
    expect(textChunks('a\nb\nc', maxChunk: 4), ['a\nb\n', 'c']);
    expect(textChunks('abcd efghij', maxChunk: 6), ['abcd ', 'efghij']);
    expect(textChunks('abcdefg', maxChunk: 3), ['abc', 'def', 'g']);
  });

  test('textChunks never splits a surrogate pair', () {
    // a, b, then the two code units of the emoji.
    expect(textChunks('ab\u{1F600}cd', maxChunk: 3), ['ab', '\u{1F600}c', 'd']);
    final text = List.filled(3000, '\u{1F600}').join();
    final chunks = textChunks(text, maxChunk: 2001);
    expect(chunks.join(), text);
    for (final c in chunks) {
      expect(c.codeUnitAt(0), isNot(inInclusiveRange(0xDC00, 0xDFFF)));
      expect(
        c.codeUnitAt(c.length - 1),
        isNot(inInclusiveRange(0xD800, 0xDBFF)),
      );
    }
  });

  test('textChunks keeps every character for mixed input', () {
    final text = [
      for (var i = 0; i < 50; i++) 'line $i ${'w' * (i * 97)}\n\n\t x',
    ].join();
    for (final max in [3, 17, 100, 2000]) {
      final chunks = textChunks(text, maxChunk: max);
      expect(chunks.join(), text, reason: 'maxChunk $max');
      expect(chunks.every((c) => c.length <= max), isTrue);
    }
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
    await tester.pump();
    expect(find.text('partial'), findsOneWidget);
    expect(find.textContaining('Truncated'), findsOneWidget);
  });

  testWidgets('json goes through the jsonBuilder seam; a tree without it', (
    tester,
  ) async {
    final json = _body(utf8.encode('{"id":1}'), 'application/json');
    await store.upsert(_call(response: _response(json)));
    await pumpDetail(tester);
    expect(find.byType(JsonTreeView), findsOneWidget);
    expect(find.textContaining('id: 1', findRichText: true), findsOneWidget);

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
    expect(
      find.textContaining('name: "ada"', findRichText: true),
      findsOneWidget,
    );
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
    expect(find.byKey(const ValueKey('proxie-timing-trace')), findsOneWidget);
  });

  testWidgets('a masked query value shows as the mask, not its encoding', (
    tester,
  ) async {
    final c = _call(response: _response(_body([], null)));
    await store.upsert(
      c.copyWith(
        request: c.request.copyWith(
          url: Uri.parse('https://api.test/users?token=$kMaskInUrl'),
        ),
      ),
    );
    await pumpDetail(tester);
    expect(find.text('https://api.test/users?token=$kMask'), findsOneWidget);
  });

  group('timing trace', () {
    test('ticks are round steps from zero, within the duration', () {
      expect(traceTicks(0), [0]);
      expect(traceTicks(123, maxTicks: 3), [0, 50, 100]);
      expect(traceTicks(850), [0, 200, 400, 600, 800]);
      expect(traceTicks(1000, maxTicks: 2), [0, 500, 1000]);
      expect(traceTicks(7), [0, 2, 4, 6]);
    });

    test('tick labels', () {
      expect(traceTickLabel(0), '0');
      expect(traceTickLabel(200), '200 ms');
      expect(traceTickLabel(1000), '1 s');
      expect(traceTickLabel(1500), '1.5 s');
    });
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

  testWidgets('body text is decoded once per body, not on every build', (
    tester,
  ) async {
    final body = _body(utf8.encode('hello'), 'text/plain');
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return BodyView(
                worker: worker,
                body: body,
                renderCap: 100,
                revealed: false,
                onShow: () {},
              );
            },
          ),
        ),
      ),
    );
    for (var i = 0; i < 3; i++) {
      rebuild(() {});
      await tester.pump();
    }
    expect(find.text('hello'), findsOneWidget);
    // Decoded and split in the worker, once.
    expect(worker.log.whereType<RawTextLines>(), hasLength(1));
  });

  testWidgets('lines ending in a break lay out without a blank line', (
    tester,
  ) async {
    final text = 'a\n${'b' * 2000}';
    await store.upsert(
      _call(response: _response(_body(utf8.encode(text), 'text/plain'))),
    );
    await pumpDetail(tester);
    final first = tester.getSize(find.byKey(const ValueKey('proxie-line-0')));
    final paragraph = tester.getSize(find.text('a\n')).height;
    // The paragraph holds the text line and the empty line after the break;
    // only the first takes space.
    expect(first.height, closeTo(paragraph / 2, 1));
  });

  testWidgets('copying a selection across lines gives back the exact text', (
    tester,
  ) async {
    mockClipboard(tester);
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(2400, 4000);
    tester.view.devicePixelRatio = 1;
    final text = '${'x' * 1500}\n${'y' * 1500}\n${'z' * 2500}';
    await store.upsert(
      _call(response: _response(_body(utf8.encode(text), 'text/plain'))),
    );
    await pumpDetail(tester);
    expect(find.byKey(const ValueKey('proxie-line-3')), findsOneWidget);

    // Select all, then copy, as the keyboard shortcuts would.
    final inside = tester.element(find.byKey(const ValueKey('proxie-line-0')));
    Actions.invoke(
      inside,
      const SelectAllTextIntent(SelectionChangedCause.keyboard),
    );
    await tester.pump();
    Actions.invoke(inside, CopySelectionTextIntent.copy);
    await tester.pump();
    expect(clipboard.single, text);
  });

  testWidgets('the selected tab and the Show choice survive a tab change', (
    tester,
  ) async {
    ProxieSections.addDetailTab(
      ProxieDetailTab(
        id: 'edited',
        label: 'Edits',
        appliesTo: (call) => call.tags.contains(CallTag.edited),
        build: (context, call) => const Text('edits'),
      ),
    );
    final big = ProxieBody(
      bytes: Uint8List(6 * 1024 * 1024)..fillRange(0, 6 * 1024 * 1024, 0x61),
      kind: BodyKind.text,
      contentType: 'text/plain',
    );
    final c = _call(response: _response(big));
    await store.upsert(c);
    await pumpDetail(tester);
    await tester.tap(find.text('Show'));
    await tester.pump();

    // Leaving the tab and coming back keeps the body shown.
    await openTab(tester, 'Timing');
    await openTab(tester, 'Response');
    expect(find.byKey(const ValueKey('proxie-raw-text')), findsOneWidget);

    // A new tab appearing keeps the selected tab and the choice.
    final edited = c.copyWith(tags: {CallTag.edited});
    await store.upsert(edited);
    calls.add(edited);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.widgetWithText(Tab, 'Edits'), findsOneWidget);
    expect(find.byKey(const ValueKey('proxie-raw-text')), findsOneWidget);

    // So does a tab going away while another one is selected.
    await openTab(tester, 'Headers');
    final plain = edited.copyWith(tags: {});
    await store.upsert(plain);
    calls.add(plain);
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.widgetWithText(Tab, 'Edits'), findsNothing);
    expect(find.text('x-trace'), findsOneWidget);
  });

  testWidgets('the selected tab falls back when its tab goes away', (
    tester,
  ) async {
    ProxieSections.addDetailTab(
      ProxieDetailTab(
        id: 'edited',
        label: 'Edits',
        appliesTo: (call) => call.tags.contains(CallTag.edited),
        build: (context, call) => const Text('edits'),
      ),
    );
    final c = _call(
      response: _response(_body(utf8.encode('body'), 'text/plain')),
    ).copyWith(tags: {CallTag.edited});
    await store.upsert(c);
    await pumpDetail(tester);
    await openTab(tester, 'Edits');
    expect(find.text('edits'), findsOneWidget);

    final plain = c.copyWith(tags: {});
    await store.upsert(plain);
    calls.add(plain);
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('edits'), findsNothing);
    // The last tab left, Timing, is selected.
    expect(find.text('Started'), findsOneWidget);
  });

  testWidgets('a faulty registered tab is reported once per detail', (
    tester,
  ) async {
    var checks = 0;
    ProxieSections.addDetailTab(
      ProxieDetailTab(
        id: 'broken',
        label: 'Broken',
        appliesTo: (call) {
          checks++;
          throw StateError('bad tab');
        },
        build: (context, call) => const Text('broken'),
      ),
    );
    final reports = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = reports.add;
    try {
      final c = _call(response: _response(_body([], null)));
      await store.upsert(c);
      await pumpDetail(tester);
      for (var i = 0; i < 3; i++) {
        calls.add(c);
        await tester.pump();
        await tester.pump();
      }
    } finally {
      FlutterError.onError = previous;
    }
    expect(checks, greaterThan(1));
    expect(reports, hasLength(1));
    expect(reports.single.exception, isA<StateError>());
  });

  testWidgets('copying a truncated body says so', (tester) async {
    mockClipboard(tester);
    final body = ProxieBody(
      bytes: Uint8List.fromList(utf8.encode('partial')),
      kind: BodyKind.text,
      contentType: 'text/plain',
      truncated: true,
      originalLength: 9000000,
    );
    await store.upsert(_call(response: _response(body)));
    await pumpDetail(tester);

    await chooseCopy(tester, 'Copy response body');
    expect(clipboard, ['partial']);
    expect(find.text('Response body copied (truncated)'), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the call and offers Retry', (
    tester,
  ) async {
    final c = _call(
      response: _response(_body(utf8.encode('v1'), 'text/plain')),
    );
    await store.upsert(c);
    await pumpDetail(tester);
    expect(find.text('v1'), findsOneWidget);

    worker.failWith = StateError('worker busy');
    calls.add(c);
    await tester.pump();
    await tester.pump();
    expect(find.text("Couldn't refresh this request"), findsOneWidget);
    expect(find.text('v1'), findsOneWidget);

    worker.failWith = null;
    await store.upsert(
      c.copyWith(response: _response(_body(utf8.encode('v2'), 'text/plain'))),
    );
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    expect(find.text("Couldn't refresh this request"), findsNothing);
    expect(find.text('v2'), findsOneWidget);
  });

  testWidgets('the inspector shows the detail of the selected call', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    setViewSize(tester, tabletSize);
    await initProxie(tester);
    addTearDown(() => tester.runAsync(Proxie.shutdown));
    await tester.pumpWidget(hostApp());
    final runtime = proxieActive.value!;
    final c = _call(
      response: _response(_body(utf8.encode('from the worker'), 'text/plain')),
    );
    await tester.runAsync(() async {
      runtime.worker.upsert(c);
      // Commands run in order, so this returns after the upsert.
      await runtime.worker.run(const ListSessions());
    });
    Proxie.open();
    await tester.pumpAndSettle();

    runtime.controller.select(c.id);
    for (
      var i = 0;
      i < 50 && find.text('from the worker').evaluate().isEmpty;
      i++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(find.byType(CallDetail), findsOneWidget);
    expect(find.text('from the worker'), findsOneWidget);

    mockClipboard(tester);
    await chooseCopy(tester, 'Copy URL');
    expect(clipboard, ['https://api.test/users?page=2']);
    expect(find.text('URL copied'), findsOneWidget);
  });
}
