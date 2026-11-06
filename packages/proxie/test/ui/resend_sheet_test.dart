import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/core/masking.dart' show kFormType, kMaskInUrl;
import 'package:proxie/src/core/replay.dart';
import 'package:proxie/src/internal_api.dart';
import 'package:proxie/src/ui/detail/resend_sheet.dart';
import 'package:proxie/src/ui/json/json_tree_view.dart';

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
  ProxieError classifyReplayError(Object error) => defaultReplayError(error);

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

class _ListSink implements CallSink {
  _ListSink(this.calls);

  final List<ProxieCall> calls;

  @override
  void upsert(ProxieCall call) => calls.add(call);
}

class _GatedAdapter extends _Adapter {
  _GatedAdapter(super.name, this.gate);

  final Future<void> gate;

  @override
  Future<ProxieResponse> replay(ProxieRequest request) async {
    await gate;
    return await super.replay(request);
  }
}

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
      send: (original, edited, cancel) => replayCall(
        original,
        edited,
        [adapter],
        engine: engine,
        cancel: cancel,
      ),
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
      send: (original, edited, _) async => ReplayResult(
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
      send: (original, edited, _) async {
        sent.add(edited);
        throw const SocketException('offline');
      },
    );
    expect(
      find.text(
        '1 header value was masked at capture and must be retyped before '
        'sending.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('will be sent as'), findsNothing);
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
    expect(find.textContaining('must be retyped'), findsNothing);
    expect(find.text('Masked at capture; retype the value'), findsNothing);
    // The refusal was about the value just fixed.
    expect(find.byKey(const ValueKey('resend-error')), findsNothing);
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.single.headers['authorization'], ['Bearer real']);
    // The failure is shown in the sheet; Send works again.
    expect(find.text('Send failed: SocketException: offline'), findsOneWidget);
    expect(_sendEnabled(tester), isTrue);
  });

  group('masked query values and form fields', () {
    ProxieCall masked({String url = '', ProxieBody? body}) {
      final base = _call(body: body);
      return base.copyWith(
        request: base.request.copyWith(
          url: Uri.parse('https://api.test/users?page=2$url'),
        ),
      );
    }

    testWidgets('a masked query value warns, is marked, and is refused until '
        'retyped', (tester) async {
      final sent = <ProxieRequest>[];
      await pumpSheet(
        tester,
        masked(url: '&token=$kMaskInUrl'),
        send: (original, edited, _) async {
          sent.add(edited);
          return ReplayResult(
            callId: 'n',
            response: original.response!,
            adapterName: 'http',
            viaFallback: false,
          );
        },
      );
      final urlField = find.byKey(const ValueKey('request-url'));
      // Shown the way people read it.
      expect(
        tester.widget<TextField>(urlField).controller!.text,
        'https://api.test/users?page=2&token=$kMask',
      );
      expect(
        find.text(
          '1 query value was masked at capture and must be retyped before '
          'sending.',
        ),
        findsOneWidget,
      );
      // The query tile opens on its own, with the masked row marked.
      final value = find.byKey(const ValueKey('query-value-1'));
      expect(value, findsOneWidget);
      expect(find.byTooltip('Masked at capture'), findsOneWidget);

      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(
        find.text('A query value was masked at capture; retype it'),
        findsOneWidget,
      );

      await tester.enterText(value, 'real');
      await tester.pumpAndSettle();
      expect(find.textContaining('must be retyped'), findsNothing);
      expect(find.byTooltip('Masked at capture'), findsNothing);
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(sent.single.url.queryParameters['token'], 'real');
      expect(sent.single.url.queryParameters['page'], '2');
    });

    testWidgets('typing the value in the URL field also lifts the refusal', (
      tester,
    ) async {
      final sent = <ProxieRequest>[];
      await pumpSheet(
        tester,
        masked(url: '&token=$kMaskInUrl'),
        send: (original, edited, _) async {
          sent.add(edited);
          return ReplayResult(
            callId: 'n',
            response: original.response!,
            adapterName: 'http',
            viaFallback: false,
          );
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('request-url')),
        'https://api.test/users?token=typed',
      );
      await tester.pumpAndSettle();
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(sent.single.url.query, 'token=typed');
    });

    testWidgets('a masked form field warns and is refused until retyped', (
      tester,
    ) async {
      final sent = <ProxieRequest>[];
      await pumpSheet(
        tester,
        _call(
          headers: const {
            'content-type': [kFormType],
          },
          body: _text('user=a&password=$kMask', type: kFormType),
        ),
        send: (original, edited, _) async {
          sent.add(edited);
          return ReplayResult(
            callId: 'n',
            response: original.response!,
            adapterName: 'http',
            viaFallback: false,
          );
        },
      );
      expect(
        find.text(
          '1 form field was masked at capture and must be retyped before '
          'sending.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('will be sent as'), findsNothing);

      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      expect(
        find.text('The form field "password" was masked at capture; retype it'),
        findsOneWidget,
      );

      // The body is edited as raw text; the form is not spliced for the user.
      await tester.enterText(
        find.byKey(const ValueKey('proxie-raw-editor')),
        'user=a&password=real',
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.textContaining('must be retyped'), findsNothing);
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(sent.single.body.text, 'user=a&password=real');
    });

    testWidgets('a URL typed with other characters does not throw', (
      tester,
    ) async {
      await pumpSheet(
        tester,
        _call(),
        send: (_, _, _) async => throw StateError('unused'),
      );
      await tester.enterText(
        find.byKey(const ValueKey('request-url')),
        'https://api.test/users?q=café',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('masked JSON body values are counted and sent as they are', (
    tester,
  ) async {
    final sent = <ProxieRequest>[];
    await pumpSheet(
      tester,
      _call(body: _text('{"token":"$kMask","id":1}')),
      send: (_, edited, _) async {
        sent.add(edited);
        throw StateError('stop');
      },
    );
    expect(
      find.text(
        '1 body value was masked at capture and will be sent as $kMask. '
        'Replace it before sending.',
      ),
      findsOneWidget,
    );
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sent.single.body.text, '{"token":"$kMask","id":1}');
  });

  testWidgets('masked headers and body values get a notice each', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      _call(
        headers: {
          'authorization': [kMask],
          'cookie': [kMask],
        },
        body: _text('{"token":"$kMask","secret":"$kMask"}'),
      ),
      send: (_, _, _) async => throw StateError('unused'),
    );
    expect(
      find.text(
        '2 header values were masked at capture and must be retyped before '
        'sending.',
      ),
      findsOneWidget,
    );
    expect(
      find.text(
        '2 body values were masked at capture and will be sent as $kMask. '
        'Replace them before sending.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a partly masked header value is counted, marked and refused '
      'alike', (tester) async {
    var sends = 0;
    await pumpSheet(
      tester,
      _call(
        headers: {
          'authorization': ['Bearer $kMask'],
        },
      ),
      send: (_, _, _) async {
        sends++;
        throw StateError('unused');
      },
    );
    expect(find.textContaining('1 header value was masked'), findsOneWidget);
    expect(find.byKey(const ValueKey('header-value-0')), findsOneWidget);
    expect(find.byTooltip('Masked at capture'), findsOneWidget);
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(sends, 0);
    expect(find.text('Masked at capture; retype the value'), findsOneWidget);
  });

  testWidgets('a send failure stays until the request is edited', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      _call(),
      send: (_, _, _) async => throw const SocketException('offline'),
    );
    final error = find.byKey(const ValueKey('resend-error'));
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(error, findsOneWidget);

    // Moving the caret is not an edit.
    final url = tester.widget<TextField>(
      find.byKey(const ValueKey('request-url')),
    );
    url.controller!.selection = const TextSelection.collapsed(offset: 3);
    await tester.pumpAndSettle();
    expect(error, findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('request-url')),
      'https://api.test/other',
    );
    await tester.pumpAndSettle();
    expect(error, findsNothing);
  });

  testWidgets('editing the raw body clears a send failure', (tester) async {
    await pumpSheet(
      tester,
      _call(body: _text('plain', type: 'text/plain')),
      send: (_, _, _) async => throw const SocketException('offline'),
    );
    final error = find.byKey(const ValueKey('resend-error'));
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(error, findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('proxie-raw-editor')),
      'other',
    );
    await tester.pumpAndSettle();
    expect(error, findsNothing);
  });

  testWidgets('a JSON tree edit or revert clears a send failure', (
    tester,
  ) async {
    await pumpSheet(
      tester,
      _call(body: _text('{"a":1}')),
      send: (_, _, _) async => throw const SocketException('offline'),
    );
    final error = find.byKey(const ValueKey('resend-error'));
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(error, findsOneWidget);

    await tester.tap(find.byTooltip('Edit a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit value'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('proxie-value-field')),
      '2',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(error, findsNothing);

    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(error, findsOneWidget);
    final tree = tester.widget<JsonTreeView>(find.byType(JsonTreeView));
    await tree.controller.revert();
    await tester.pumpAndSettle();
    expect(error, findsNothing);
  });

  testWidgets('a double tap on Send sends once', (tester) async {
    final gate = Completer<ReplayResult>();
    var sends = 0;
    await pumpSheet(
      tester,
      _call(),
      send: (_, _, _) {
        sends++;
        return gate.future;
      },
    );
    await tester.tap(_send);
    await tester.tap(_send);
    await tester.pump();
    expect(sends, 1);
    expect(_sendEnabled(tester), isFalse);
    gate.complete(
      ReplayResult(
        callId: 'n',
        response: ProxieResponse(
          statusCode: 200,
          headers: const {},
          body: ProxieBody.empty(),
        ),
        adapterName: 'http',
        viaFallback: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(_sendEnabled(tester), isTrue);
  });

  testWidgets('closing the sheet mid-send is safe and the call is recorded', (
    tester,
  ) async {
    final sink = <ProxieCall>[];
    final engine = ProxieEngine(
      config: const ProxieConfig(),
      sink: _ListSink(sink),
    );
    addTearDown(engine.dispose);
    final gate = Completer<void>();
    final adapter = _GatedAdapter('http', gate.future);
    await pumpSheet(
      tester,
      _call(),
      send: (original, edited, cancel) => replayCall(
        original,
        edited,
        [adapter],
        engine: engine,
        cancel: cancel,
      ),
    );
    await tester.tap(_send);
    await tester.pump();
    await tester.pump();
    expect(sink.last.response, isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ResendSheet), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(sink.last.response!.statusCode, 201);
    expect(sink.last.tags, {CallTag.replayed});
  });

  testWidgets('Cancel records the call as cancelled and ignores the late '
      'response', (tester) async {
    final sink = <ProxieCall>[];
    final engine = ProxieEngine(
      config: const ProxieConfig(),
      sink: _ListSink(sink),
    );
    addTearDown(engine.dispose);
    final gate = Completer<void>();
    final adapter = _GatedAdapter('http', gate.future);
    final cancelButton = find.widgetWithText(OutlinedButton, 'Cancel');
    await pumpSheet(
      tester,
      _call(),
      send: (original, edited, cancel) => replayCall(
        original,
        edited,
        [adapter],
        engine: engine,
        cancel: cancel,
      ),
    );
    expect(cancelButton, findsNothing);

    await tester.tap(_send);
    await tester.pump();
    await tester.pump();
    expect(cancelButton, findsOneWidget);
    expect(_sendEnabled(tester), isFalse);

    await tester.tap(cancelButton);
    await tester.pumpAndSettle();
    expect(find.text(kReplayCancelledMessage), findsOneWidget);
    expect(cancelButton, findsNothing);
    expect(_sendEnabled(tester), isTrue);
    expect(sink.last.error!.type, 'cancelled');

    gate.complete();
    await tester.pumpAndSettle();
    expect(sink.last.error!.type, 'cancelled');
    expect(sink.last.response, isNull);
    expect(find.byKey(const ValueKey('resend-result')), findsNothing);
    expect(find.text(kReplayCancelledMessage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a sender that ignores Cancel cannot show a late result', (
    tester,
  ) async {
    final gate = Completer<ReplayResult>();
    await pumpSheet(tester, _call(), send: (_, _, _) => gate.future);
    await tester.tap(_send);
    await tester.pump();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
    await tester.pumpAndSettle();
    gate.complete(
      ReplayResult(
        callId: 'n',
        response: ProxieResponse(
          statusCode: 200,
          headers: const {},
          body: ProxieBody.empty(),
        ),
        adapterName: 'http',
        viaFallback: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('resend-result')), findsNothing);
    expect(find.text(kReplayCancelledMessage), findsOneWidget);
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
      send: (original, edited, _) async {
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
      send: (_, _, _) async =>
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
      send: (_, _, _) async {
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
      send: (_, _, _) async => throw StateError('unused'),
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
