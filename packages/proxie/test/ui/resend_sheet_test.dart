import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/core/replay.dart';
import 'package:proxie/src/ui/detail/resend_sheet.dart';

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

  Iterable<String> get openDocs =>
      ctx.resources.keys.where(RegExp(r'^json:\d+$').hasMatch);

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

/// A replaying adapter that records what it was asked to send.
class _Adapter implements ProxieCaptureAdapter {
  _Adapter(this.name);

  @override
  final String name;

  @override
  bool get supportsReplay => true;

  final sent = <ProxieRequest>[];

  @override
  void attach(ProxieEngine engine) {}

  @override
  void detach() {}

  @override
  Future<ProxieResponse> replay(ProxieRequest request) async {
    sent.add(request);
    return ProxieResponse(
      statusCode: 201,
      headers: const {},
      body: ProxieBody.empty(),
    );
  }
}

ProxieBody _text(String text, {String type = 'application/json'}) =>
    ProxieBody.from(Uint8List.fromList(utf8.encode(text)), type);

ProxieCall _call({
  Map<String, List<String>> headers = const {
    'x-a': ['1'],
  },
  ProxieBody? body,
  String adapter = 'http',
}) => ProxieCall(
  id: 'c1',
  sessionId: 1,
  adapter: adapter,
  request: ProxieRequest(
    method: 'POST',
    url: Uri.parse('https://api.test/users?page=2'),
    headers: headers,
    body: body ?? ProxieBody.empty(),
  ),
  response: ProxieResponse(
    statusCode: 200,
    headers: const {},
    body: ProxieBody.empty(),
  ),
  startedAt: DateTime(2026, 11, 3),
  duration: const Duration(milliseconds: 4),
);

final Finder _send = find.widgetWithText(FilledButton, 'Send');

bool _sendEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_send).onPressed != null;

void main() {
  late MemoryStore store;
  late _Worker worker;

  setUp(() async {
    store = MemoryStore();
    await store.startSession();
    worker = _Worker(store);
  });

  /// A home page that opens the sheet of [call], so its closing shows.
  Future<void> pumpSheet(
    WidgetTester tester,
    ProxieCall call, {
    required ResendSender send,
    ValueChanged<String>? onOpenCall,
  }) async {
    await store.upsert(call);
    addTearDown(tester.view.reset);
    setViewSize(tester, phoneSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: ProxieTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => unawaited(
                  openResendSheet(
                    context,
                    call: call,
                    worker: worker,
                    send: send,
                    onOpenCall: onOpenCall,
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

  testWidgets('sends the edited request, says how and opens the new call', (
    tester,
  ) async {
    final engine = ProxieEngine(config: const ProxieConfig(), sink: worker);
    addTearDown(engine.dispose);
    final adapter = _Adapter('http');
    final opened = <String>[];
    await pumpSheet(
      tester,
      _call(),
      send: (original, edited) =>
          replayCall(original, edited, [adapter], engine: engine),
      onOpenCall: opened.add,
    );
    expect(find.byType(ResendSheet), findsOneWidget);
    expect(find.textContaining('masked at capture'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('request-url')),
      'https://api.test/users?page=3',
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();

    final sent = adapter.sent.single;
    expect(sent.method, 'POST');
    expect(sent.url, Uri.parse('https://api.test/users?page=3'));
    expect(sent.headers, {
      'x-a': ['1'],
    });
    expect(find.text('Sent via http · 201'), findsOneWidget);
    final recorded = (await store.query(
      const CallQuery(),
      limit: 10,
      offset: 0,
    )).where((c) => c.id != 'c1');
    expect(recorded.single.tags, {CallTag.replayed, CallTag.edited});

    await tester.tap(find.text('Open call'));
    await tester.pumpAndSettle();
    expect(opened, [recorded.single.id]);
    expect(find.byType(ResendSheet), findsNothing);
  });

  testWidgets('a fallback send says the app interceptors were skipped', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      _call(),
      send: (original, edited) async => ReplayResult(
        callId: 'new',
        response: ProxieResponse(
          statusCode: 200,
          headers: const {},
          body: ProxieBody.empty(),
        ),
        adapterName: kReplayFallbackAdapter,
        viaFallback: true,
      ),
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(
      find.text('Sent via built-in client (app interceptors skipped) · 200'),
      findsOneWidget,
    );
    // Without onOpenCall there is nothing to open.
    expect(find.text('Open call'), findsNothing);
  });

  testWidgets('masked header values are pointed out and marked; Send is '
      'not blocked but says to retype them', (tester) async {
    final sent = <ProxieRequest>[];
    await pumpSheet(
      tester,
      _call(
        headers: {
          'Authorization': [kMask],
          'x-a': ['1'],
        },
      ),
      send: (original, edited) async {
        sent.add(edited);
        throw const SocketException('offline');
      },
    );
    expect(
      find.text(
        '1 value was masked at capture and will be sent as $kMask. '
        'Replace it before sending.',
      ),
      findsOneWidget,
    );
    // The headers tile opens on its own, with the masked row marked.
    expect(find.byKey(const ValueKey('header-value-0')), findsOneWidget);
    expect(find.byTooltip('Masked at capture'), findsOneWidget);
    expect(_sendEnabled(tester), isTrue);

    // The mask is not US-ASCII: no adapter could send it as a header.
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    expect(find.text('Masked at capture; retype the value'), findsOneWidget);
    expect(
      find.text(
        'The value of "authorization" was masked at capture; '
        'retype it',
      ),
      findsOneWidget,
    );

    // Retyped, the warning goes and the request is sent.
    await tester.enterText(
      find.byKey(const ValueKey('header-value-0')),
      'Bearer real',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('will be sent as'), findsNothing);
    expect(find.text('Masked at capture; retype the value'), findsNothing);
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.single.headers['authorization'], ['Bearer real']);
    // The failure is shown in the sheet; Send works again.
    expect(find.text('Send failed: SocketException: offline'), findsOneWidget);
    expect(_sendEnabled(tester), isTrue);
  });

  testWidgets('masked JSON body values are counted and sent as they are', (
    tester,
  ) async {
    final sent = <ProxieRequest>[];
    await pumpSheet(
      tester,
      _call(body: _text('{"token":"$kMask","id":1}')),
      send: (_, edited) async {
        sent.add(edited);
        throw StateError('stop');
      },
    );
    expect(
      find.text(
        '1 value was masked at capture and will be sent as $kMask. '
        'Replace it before sending.',
      ),
      findsOneWidget,
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.single.body.text, '{"token":"$kMask","id":1}');
  });

  testWidgets('a truncated body disables Send until it is replaced', (
    tester,
  ) async {
    final sent = <ProxieRequest>[];
    await pumpSheet(
      tester,
      _call(
        body: ProxieBody(
          bytes: Uint8List.fromList(utf8.encode('partial')),
          contentType: 'text/plain',
          kind: BodyKind.text,
          truncated: true,
          originalLength: 9000,
        ),
      ),
      send: (original, edited) async {
        sent.add(edited);
        return ReplayResult(
          callId: 'n',
          response: ProxieResponse(
            statusCode: 200,
            headers: const {},
            body: ProxieBody.empty(),
          ),
          adapterName: 'http',
          viaFallback: false,
        );
      },
    );
    expect(find.textContaining('The captured body was truncated'), findsOne);
    expect(_sendEnabled(tester), isFalse);

    await tester.enterText(
      find.byKey(const ValueKey('proxie-raw-editor')),
      'whole body',
    );
    await tester.pumpAndSettle();
    expect(_sendEnabled(tester), isTrue);
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.single.body.text, 'whole body');
    expect(sent.single.body.truncated, isFalse);
  });

  testWidgets('a StateError from the send is shown as it is', (tester) async {
    await pumpSheet(
      tester,
      _call(),
      send: (_, _) async =>
          throw StateError('Cannot replay: request body was truncated'),
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(
      find.text('Cannot replay: request body was truncated'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an invalid header is refused inline and nothing is sent', (
    tester,
  ) async {
    var sends = 0;
    await pumpSheet(
      tester,
      _call(),
      send: (_, _) async {
        sends++;
        throw StateError('unused');
      },
    );
    await tester.tap(find.text('Headers (1)'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('header-name-0')),
      'bad name',
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sends, 0);
    expect(find.text('This is not a valid header name'), findsOneWidget);
    expect(find.text('"bad name" is not a valid header name'), findsOneWidget);
  });

  testWidgets('the JSON body opens in its own scope, closed with the sheet', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      _call(body: _text('{"id":1}')),
      send: (_, _) async => throw StateError('unused'),
    );
    final opens = worker.sent.whereType<OpenJson>().toList();
    expect(opens.single.scope, resendScope('c1'));
    expect(opens.single.bytes, isNull, reason: 'opened from the store');
    expect(worker.openDocs, hasLength(1));
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ResendSheet), findsNothing);
    expect(worker.openDocs, isEmpty);
  });

  group('in the inspector', () {
    tearDown(Proxie.shutdown);

    testWidgets('"Edit & resend" sends through the call\'s adapter and opens '
        'the new call', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      final adapter = _Adapter('test');
      await tester.runAsync(
        () => Proxie.init(adapters: [adapter], config: memoryConfig),
      );
      final engine = Proxie.engine!;
      final id = engine.newCallId();
      final call = _call(adapter: 'test');
      await tester.runAsync(() async {
        await engine.onRequest(id, 'test', call.request);
        await engine.onResponse(id, call.response!);
      });
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      final inspector = controllerIn(tester)..select(id);
      Future<void> settle() async {
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pumpAndSettle();
        }
      }

      await settle();
      await tester.tap(find.byTooltip('Edit & resend'));
      await settle();
      expect(find.byType(ResendSheet), findsOneWidget);
      await tester.tap(_send);
      await settle();
      expect(adapter.sent, hasLength(1));
      expect(find.text('Sent via test · 201'), findsOneWidget);
      await tester.tap(find.text('Open call'));
      await settle();
      expect(find.byType(ResendSheet), findsNothing);
      expect(inspector.selectedCallId, isNot(id));
      expect(inspector.selectedCallId, isNotNull);
      await tester.runAsync(Proxie.shutdown);
    });
  });
}
