// End-to-end flows of the example app on a desktop: the real worker isolate
// with SQLite, real sockets through all three capture adapters, and the real
// clipboard (a run overwrites it). All requests go to a server on loopback, so
// it needs no network. Only Windows has been run so far:
//
//   cd example && flutter test integration_test -d windows

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:example/demo_requests.dart';
import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie_dio/proxie_dio.dart';

const _todo = '{"userId":1,"id":1,"title":"delectus aut autem"}';
const _user = '{"id":1,"name":"Leanne Graham"}';
const _created = '{"id":101}';
const _echo = '{"url":"/get"}';

// A 1x1 PNG.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M/wHwAEAQH/'
  '7yMK/gAAAABJRU5ErkJggg==',
);

/// What the local server was asked.
class _Hit {
  _Hit(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;
  final HttpHeaders headers;
  final String body;
}

/// Answers the demo buttons' requests on loopback and records them.
class _Server {
  _Server._(this._server) {
    unawaited(_server.forEach(_answer));
  }

  static Future<_Server> start() async =>
      _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;
  final List<_Hit> hits = [];

  String get base => 'http://127.0.0.1:${_server.port}';

  int hitsOn(String path) => hits.where((h) => h.path == path).length;

  Future<void> _answer(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    hits.add(_Hit(request.method, request.uri.path, request.headers, body));
    final response = request.response;
    void json(int status, String text) {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(text);
    }

    switch (request.uri.path) {
      case '/todos/1' || '/todos/2':
        json(200, _todo);
      case '/posts':
        json(201, _created);
      case '/users/1':
        json(200, _user);
      case '/get':
        json(200, _echo);
      case '/status/404':
        response.statusCode = 404;
      case '/status/500':
        response.statusCode = 500;
      case '/image/png':
        response
          ..headers.contentType = ContentType('image', 'png')
          ..add(_png);
      default:
        json(599, '{"unexpected":true}');
    }
    await response.close();
  }

  Future<void> close() => _server.close(force: true);
}

/// The app on [tester], driven through its accessibility tree.
class _App {
  _App(this.tester, this.server);

  final WidgetTester tester;
  final _Server server;

  static const _timeout = Duration(seconds: 30);

  /// Pumps until [finder] finds something; the app works on real sockets and
  /// another isolate, so there is no fixed number of frames to wait.
  Future<void> shows(Finder finder) async {
    final end = DateTime.now().add(_timeout);
    while (finder.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) {
        fail('Timed out waiting for $finder');
      }
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Pumps until [finder] finds nothing.
  Future<void> gone(Finder finder) async {
    final end = DateTime.now().add(_timeout);
    while (finder.evaluate().isNotEmpty) {
      if (DateTime.now().isAfter(end)) {
        fail('Timed out waiting for $finder to go');
      }
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Pumps until [condition] holds.
  Future<void> until(String what, bool Function() condition) async {
    final end = DateTime.now().add(_timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(end)) fail('Timed out waiting until $what');
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Finder get bubble => find.bySemanticsLabel('Open Proxie inspector');

  /// The list row whose accessible name holds [parts], in order. A status
  /// part ('404', 'ERR') must be the status itself, which comes right before
  /// the duration, so '200' does not match '200 ms' or '200 B'.
  Finder row(List<String> parts) => find.bySemanticsLabel(
    RegExp(
      parts
          .map(
            (p) => RegExp(r'^(\d{3}|ERR)$').hasMatch(p)
                ? '\\b$p\\s+\\d[\\d.]* m?s\\b'
                : RegExp.escape(p),
          )
          .join('.*'),
      dotAll: true,
    ),
  );

  Finder result(String label) => find.byKey(ValueKey('result-$label'));

  String resultText(String label) =>
      tester.widget<Text>(result(label)).data ?? '';

  /// Taps [finder] once it is there, in view, no longer moving and on top:
  /// frames run in real time here, so a tap on something sliding in would drag
  /// it, and one during a page transition could land on the page behind.
  Future<void> tap(Finder finder) async {
    await shows(finder);
    final target = finder.first;
    await tester.ensureVisible(target);
    Rect? last;
    await until('$target can be tapped', () {
      final rect = tester.getRect(target);
      final settled = rect == last;
      last = rect;
      return settled && _hits(target);
    });
    await tester.tap(target);
    await tester.pump();
  }

  bool _hits(Finder target) {
    final box = target.evaluate().single.renderObject;
    final result = HitTestResult();
    tester.binding.hitTestInView(
      result,
      tester.getCenter(target),
      tester.view.viewId,
    );
    return result.path.any((entry) => entry.target == box);
  }

  /// Taps a demo button and waits for what it shows under it.
  Future<void> press(String label, Pattern expected) async {
    await tap(find.bySemanticsLabel(label));
    await until(
      '"$label" shows $expected',
      () =>
          result(label).evaluate().isNotEmpty &&
          expected.allMatches(resultText(label)).isNotEmpty,
    );
  }

  Future<void> openInspector() async {
    await tap(bubble);
    await shows(find.byTooltip('Rules'));
  }

  Future<void> closeInspector() async {
    await tap(find.byTooltip('Close'));
    await shows(bubble);
  }

  Future<void> openRow(String path) async {
    await tap(row([path]));
    await shows(find.text('Response'));
  }

  Future<void> back() => tap(find.byTooltip('Back'));

  /// A Map Local rule answering 404, from the call open in the detail.
  Future<void> map404FromOpenCall() async {
    await tap(find.byTooltip('Map Local from this response'));
    await shows(find.text('New rule'));
    await tap(find.text('Response').last);
    await tap(find.text('Presets'));
    await tap(find.text('404 Not Found'));
    await until(
      'the status is 404',
      () =>
          tester
              .widget<TextField>(find.byKey(const ValueKey('response-status')))
              .controller!
              .text ==
          '404',
    );
    await tap(find.byTooltip('Save rule'));
    await gone(find.text('New rule'));
  }

  /// A breakpoint on the todo URL at [phase]; leaves the inspector closed.
  Future<void> addBreakpoint(String phase) async {
    await press('GET JSON', RegExp('^200 '));
    await openInspector();
    await openRow('/todos/1');
    await tap(find.byTooltip('Breakpoint on this URL'));
    await shows(find.text('New rule'));
    await tap(find.text(phase).last);
    await tap(find.byTooltip('Save rule'));
    await gone(find.text('New rule'));
    await closeInspector();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  WidgetController.hitTestWarningShouldBeFatal = true;

  late _Server server;
  late Directory support;

  setUp(() async {
    server = await _Server.start();
    // A fresh database each time, away from the example app's own.
    support = await Directory.systemTemp.createTemp('proxie-e2e-');
  });

  tearDown(() async {
    await Proxie.shutdown();
    await server.close();
    try {
      await support.delete(recursive: true);
    } on FileSystemException {
      // Windows may hold the database a moment longer; it is in the temp dir.
    }
  });

  /// Runs the example app against the local server, with the adapters of
  /// `startProxie`. Unlike `main()` it calls `Proxie.init` itself, for
  /// `supportDir`, and creates the client before starting Proxie, which then
  /// attaches it.
  Future<_App> launch(WidgetTester tester) async {
    final dio = Dio();
    final client = Proxie.httpClient();
    final interceptor = ProxieDio.install(dio);
    final ready = Proxie.init(
      adapters: [ProxieHttpOverridesAdapter(), interceptor],
      supportDir: support.path,
    );
    await tester.pumpWidget(
      DemoApp(
        requests: demoRequests(
          client: client,
          dio: dio,
          ready: ready,
          jsonApi: server.base,
          httpbin: server.base,
        ),
      ),
    );
    final app = _App(tester, server);
    await ready;
    await app.shows(app.bubble);
    return app;
  }

  /// [body] with the accessibility tree on, as on a device with a screen
  /// reader, and without the failure a test framework hides otherwise.
  void flow(String name, Future<void> Function(_App app) body) {
    testWidgets(name, (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await body(await launch(tester));
        expect(tester.takeException(), isNull);
      } finally {
        // Back to an empty tree, so the engine and the worker go down quietly.
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
      }
    });
  }

  flow('every button is captured once, through its own adapter', (app) async {
    await app.press('GET JSON', '200 (${_todo.length} bytes)');
    await app.press('POST JSON', '201 (${_created.length} bytes)');
    await app.press('404', '404 (0 bytes)');
    await app.press('500', '500 (0 bytes)');
    await app.press('Big JSON (5 MB)', RegExp(r'^200 \(\d{7} bytes\)$'));
    await app.press('Image', '200 (${_png.length} bytes)');
    await app.press('Dio GET', '200 (${_user.length} bytes)');
    await app.press('HttpClient GET', '200 (${_echo.length} bytes)');

    // Each request reached the server exactly once; the body was sent whole.
    expect(
      [for (final hit in app.server.hits) hit.path],
      [
        '/todos/1',
        '/posts',
        '/status/404',
        '/status/500',
        '/image/png',
        '/users/1',
        '/get',
      ],
    );
    final post = app.server.hits[1];
    expect(post.method, 'POST');
    expect(jsonDecode(post.body), containsPair('title', 'Proxie'));

    // One row per call: no double capture by the HttpOverrides adapter.
    expect(
      app.tester.getSemantics(app.bubble).value,
      '8 calls',
      reason: 'the bubble counts calls',
    );

    await app.openInspector();
    await app.shows(app.row(['GET', '/todos/1', '200']));
    expect(app.row(['/todos/1']), findsOneWidget);
    expect(app.row(['POST', '/posts', '201']), findsOneWidget);
    expect(app.row(['/status/404', '404']), findsOneWidget);
    expect(app.row(['/status/500', '500']), findsOneWidget);
    expect(app.row(['/data.json', 'MAP', '200']), findsOneWidget);
    expect(app.row(['/image/png', '200']), findsOneWidget);
    expect(app.row(['/users/1', '200']), findsOneWidget);
    expect(app.row(['/get', '200']), findsOneWidget);

    // The adapter chips: each client's calls are under its own name.
    Future<void> only(String adapter, String kept, String hidden) async {
      await app.tap(find.widgetWithText(FilterChip, adapter));
      await app.gone(app.row([hidden]));
      await app.shows(app.row([kept]));
      await app.tap(find.widgetWithText(FilterChip, adapter));
      await app.shows(app.row([hidden]));
    }

    await only('dio', '/users/1', '/todos/1');
    await only('http', '/todos/1', '/users/1');
    await only('io', '/get', '/todos/1');

    // The real worker opens the 5 MB body as a tree.
    await app.openRow('/data.json');
    await app.shows(find.textContaining('generated'));
  });

  flow('a call opens and copies as cURL', (app) async {
    await app.press('GET JSON', '200 (${_todo.length} bytes)');
    await app.openInspector();
    await app.openRow('/todos/1');
    await app.shows(find.textContaining('delectus aut autem'));

    await app.tap(find.byTooltip('Copy'));
    await app.tap(find.text('Copy cURL'));
    await app.shows(find.text('cURL copied'));
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    expect(clip?.text, contains("curl '${app.server.base}/todos/1'"));
  });

  flow('Errors shows only 4xx and 5xx', (app) async {
    await app.press('GET JSON', '200 (${_todo.length} bytes)');
    await app.press('POST JSON', '201 (${_created.length} bytes)');
    await app.press('404', '404 (0 bytes)');
    await app.press('500', '500 (0 bytes)');
    await app.openInspector();
    await app.shows(app.row(['/todos/1']));

    await app.tap(find.widgetWithText(FilterChip, 'Errors'));
    await app.gone(app.row(['/todos/1']));
    // A new filter shows a new list, empty until its rows load.
    await app.shows(app.row(['/status/404', '404']));
    await app.shows(app.row(['/status/500', '500']));
    expect(app.row(['/todos/1']), findsNothing);
    expect(app.row(['/posts']), findsNothing);

    await app.tap(find.widgetWithText(FilterChip, 'Errors'));
    await app.shows(app.row(['/todos/1']));
    await app.shows(app.row(['/posts']));
  });

  flow('a Map Local 404 from a call answers the next tap', (app) async {
    await app.press('GET JSON', '200 (${_todo.length} bytes)');
    await app.openInspector();
    await app.openRow('/todos/1');
    await app.map404FromOpenCall();
    await app.closeInspector();

    await app.press('GET JSON', RegExp('^404 '));
    expect(app.server.hitsOn('/todos/1'), 1, reason: 'answered locally');

    await app.openInspector();
    await app.shows(app.row(['/todos/1', 'MAP', '404']));
    expect(app.row(['/todos/1', '200']), findsOneWidget);
  });

  flow('the rules screen switches a rule off and on, and deletes it', (
    app,
  ) async {
    await app.press('GET JSON', '200 (${_todo.length} bytes)');
    await app.openInspector();
    await app.openRow('/todos/1');
    await app.map404FromOpenCall();

    Future<void> openRules() async {
      await app.openInspector();
      await app.tap(find.byTooltip('Rules'));
      await app.shows(find.byType(Switch));
    }

    Future<void> leaveRules() async {
      await app.back();
      await app.closeInspector();
    }

    await app.tap(find.byTooltip('Rules'));
    await app.tap(find.byType(Switch));
    await app.until(
      'the switch is off',
      () => !app.tester.widget<Switch>(find.byType(Switch)).value,
    );
    await leaveRules();
    await app.press('GET JSON', '200 (${_todo.length} bytes)');
    expect(app.server.hitsOn('/todos/1'), 2, reason: 'rule off: sent');

    await openRules();
    await app.tap(find.byType(Switch));
    await app.until(
      'the switch is on',
      () => app.tester.widget<Switch>(find.byType(Switch)).value,
    );
    await leaveRules();
    await app.press('GET JSON', RegExp('^404 '));
    expect(app.server.hitsOn('/todos/1'), 2, reason: 'rule on: answered');

    await openRules();
    await app.tap(find.byTooltip('Delete rule'));
    await app.shows(find.text('No rules yet'));
    // The messenger shows it in every scaffold; the top page's comes last.
    await app.tap(find.text('Undo').last);
    await app.shows(find.byType(Switch));
    await app.tap(find.byTooltip('Delete rule'));
    await app.shows(find.text('No rules yet'));
    await leaveRules();
    await app.press('GET JSON', '200 (${_todo.length} bytes)');
    expect(app.server.hitsOn('/todos/1'), 3, reason: 'rule deleted: sent');
  });

  flow('an edited resend reaches the server and is tagged', (app) async {
    await app.press('GET JSON', '200 (${_todo.length} bytes)');
    await app.openInspector();
    await app.openRow('/todos/1');
    await app.tap(find.byTooltip('Edit & resend'));

    final url = find.byKey(const ValueKey('request-url'));
    await app.shows(url);
    await app.tester.enterText(url, '${app.server.base}/todos/2');
    await app.tester.pump();
    await app.tap(find.text('Send'));
    await app.shows(find.byKey(const ValueKey('resend-result')));
    expect(app.server.hitsOn('/todos/2'), 1);

    await app.tap(find.text('Open call'));
    await app.shows(app.row(['/todos/2', 'REPLAY', 'EDITED', '200']));
    expect(app.row(['/todos/1', 'REPLAY']), findsNothing);
  });

  flow('an unchanged resend is tagged REPLAY only', (app) async {
    await app.press('GET JSON', '200 (${_todo.length} bytes)');
    await app.openInspector();
    await app.openRow('/todos/1');
    await app.tap(find.byTooltip('Edit & resend'));
    await app.tap(find.text('Send'));
    await app.shows(find.byKey(const ValueKey('resend-result')));
    expect(app.server.hitsOn('/todos/1'), 2);
    await app.back();

    await app.shows(app.row(['/todos/1', 'REPLAY', '200']));
    expect(app.row(['/todos/1', 'EDITED']), findsNothing);
  });

  flow('a pause opens the editor; Execute sends the edited header', (
    app,
  ) async {
    await app.addBreakpoint('Request');

    await app.tap(find.bySemanticsLabel('GET JSON'));
    await app.shows(find.text('Request breakpoint'));
    await app.shows(find.text('1 of 1 paused'));
    expect(app.server.hitsOn('/todos/1'), 1, reason: 'paused: not sent');

    await app.tap(find.textContaining('Headers ('));
    await app.tap(find.text('Add header'));
    Finder field(String prefix) => find.byWidgetPredicate((widget) {
      final key = widget.key;
      return widget is TextField &&
          key is ValueKey<String> &&
          key.value.startsWith(prefix);
    });
    final name = field('header-name-');
    final value = field('header-value-');
    await app.shows(name);
    await app.tester.enterText(name.last, 'x-e2e');
    await app.tester.enterText(value.last, 'edited');
    await app.tester.pump();
    await app.tap(find.text('Execute'));

    await app.gone(find.text('Request breakpoint'));
    await app.until(
      'the edited request arrives',
      () => app.server.hitsOn('/todos/1') == 2,
    );
    expect(app.server.hits.last.headers.value('x-e2e'), 'edited');

    await app.shows(app.bubble);
    await app.openInspector();
    await app.shows(app.row(['/todos/1', 'BREAK', 'EDITED', '200']));
  });

  flow('Abort fails the call without sending it', (app) async {
    await app.addBreakpoint('Request');

    await app.tap(find.bySemanticsLabel('GET JSON'));
    await app.tap(find.text('Abort'));
    await app.until(
      'the demo shows the failure',
      () => app.resultText('GET JSON').startsWith('Failed:'),
    );
    expect(app.server.hitsOn('/todos/1'), 1);

    await app.shows(app.bubble);
    await app.openInspector();
    await app.shows(app.row(['/todos/1', 'BREAK', 'ERR']));
  });

  flow('Continue unchanged sends the request as it was', (app) async {
    await app.addBreakpoint('Request');

    await app.tap(find.bySemanticsLabel('GET JSON'));
    await app.tap(find.text('Continue unchanged'));
    await app.until(
      'the request arrives',
      () => app.server.hitsOn('/todos/1') == 2,
    );
    expect(app.server.hits.last.headers.value('x-e2e'), isNull);

    await app.shows(app.bubble);
    await app.openInspector();
    await app.shows(app.row(['/todos/1', 'BREAK', '200']));
    expect(app.row(['/todos/1', 'EDITED']), findsNothing);
  });

  flow('a response breakpoint hands the app the edited status', (app) async {
    await app.addBreakpoint('Response');

    await app.tap(find.bySemanticsLabel('GET JSON'));
    await app.shows(find.text('Response breakpoint'));
    expect(app.server.hitsOn('/todos/1'), 2, reason: 'paused after the send');

    final status = find.byKey(const ValueKey('response-status'));
    await app.shows(status);
    await app.tester.enterText(status, '418');
    await app.tester.pump();
    await app.tap(find.text('Execute'));

    await app.until(
      'the app gets the edited status',
      () => app.resultText('GET JSON').startsWith('418 '),
    );
    await app.shows(app.bubble);
    await app.openInspector();
    await app.shows(app.row(['/todos/1', 'BREAK', 'EDITED', '418']));
  });
}
