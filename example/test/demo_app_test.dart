import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:example/demo_requests.dart';
import 'package:example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:proxie/proxie.dart';

class _NullSink implements CallSink {
  @override
  void upsert(ProxieCall call) {}
}

http.Client _offline() =>
    MockClient((_) async => throw http.ClientException('offline'));

void main() {
  group('demo buttons', () {
    List<DemoRequest> requests() => demoRequests(
      client: _offline(),
      dio: Dio(),
      ready: Future<void>.value(),
    );

    testWidgets('each has its exact semantics label', (tester) async {
      // Not addTearDown: the test checks for open handles before tear-downs.
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(DemoApp(requests: requests()));

        for (final label in [
          'GET JSON',
          'POST JSON',
          '404',
          '500',
          'Big JSON (5 MB)',
          'Image',
          'Dio GET',
          'HttpClient GET',
        ]) {
          final finder = find.bySemanticsLabel(label);
          expect(finder, findsOneWidget, reason: label);
          expect(
            tester.getSemantics(finder),
            isSemantics(label: label, isButton: true, hasTapAction: true),
            reason: label,
          );
        }
      } finally {
        semantics.dispose();
      }
    });

    testWidgets('a failed request shows inline', (tester) async {
      await tester.pumpWidget(DemoApp(requests: requests()));

      await tester.tap(find.text('GET JSON'));
      await tester.pumpAndSettle();

      final result = tester.widget<Text>(
        find.byKey(const ValueKey('result-GET JSON')),
      );
      expect(result.data, contains('Failed'));
      expect(result.data, contains('offline'));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a request waits for ready, so an early tap is recorded', (
    tester,
  ) async {
    final ready = Completer<void>();
    var sent = 0;
    await tester.pumpWidget(
      DemoApp(
        requests: demoRequests(
          client: MockClient((_) async {
            sent++;
            return http.Response('{}', 200);
          }),
          dio: Dio(),
          ready: ready.future,
        ),
      ),
    );

    await tester.tap(find.text('GET JSON'));
    await tester.pumpAndSettle();
    expect(sent, 0);
    expect(find.text('Running...'), findsOneWidget);

    ready.complete();
    await tester.pumpAndSettle();
    expect(sent, 1);
    expect(find.text('200 (2 bytes)'), findsOneWidget);
  });

  testWidgets('Big JSON explains itself when Proxie is not running', (
    tester,
  ) async {
    var sent = 0;
    await tester.pumpWidget(
      DemoApp(
        requests: demoRequests(
          client: MockClient((_) async {
            sent++;
            return http.Response('', 200);
          }),
          dio: Dio(),
          ready: Future<void>.value(),
        ),
      ),
    );

    await tester.tap(find.text('Big JSON (5 MB)'));
    await tester.pumpAndSettle();

    expect(find.text(bigJsonProxieOff), findsOneWidget);
    expect(sent, 0);
  });

  group('Big JSON', () {
    test('is valid JSON, close to the target and under the capture cap', () {
      final bytes = generateBigJson(bigJsonBytes);
      expect(bytes.length, lessThanOrEqualTo(bigJsonBytes));
      expect(bytes.length, greaterThan(bigJsonBytes - 300));
      expect(bigJsonBytes, lessThan(defaultBodyCap));
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(decoded['items'], isNotEmpty);
    });

    test('the rule is created once and serves the whole body', () async {
      final engine = ProxieEngine(
        config: const ProxieConfig(),
        sink: _NullSink(),
      );
      addTearDown(engine.dispose);

      await ensureBigJsonRule(engine);
      await ensureBigJsonRule(engine);
      expect(engine.rules.rules.map((r) => r.id), [bigJsonRuleId]);

      final client = ProxieHttpClient(inner: _offline())..attach(engine);
      final response = await client.get(Uri.parse(bigJsonUrl));
      expect(response.statusCode, 200);
      expect(response.bodyBytes.length, greaterThan(bigJsonBytes - 300));
    });

    test('an existing rule with that id is left untouched', () async {
      final engine = ProxieEngine(
        config: const ProxieConfig(),
        sink: _NullSink(),
      );
      addTearDown(engine.dispose);
      final restored = ProxieRule(
        id: bigJsonRuleId,
        name: 'Renamed',
        enabled: false,
        kind: RuleKind.mapLocal,
        matcher: UrlMatcher(bigJsonUrl),
      );
      engine.rules = RuleSet([restored]);

      await ensureBigJsonRule(engine);

      expect(engine.rules.rules, [restored]);
    });
  });
}
