import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

import '../../support/io_harness.dart';

void main() {
  final h = IoHarness()..install();

  test('plain HttpClient().getUrl(/json) is captured once', () async {
    final client = HttpClient();
    final req = await client.getUrl(h.server.url('/json'));
    final res = await req.close();
    expect(res.statusCode, 200);
    expect(await readText(res), '{"hello":"world"}');
    await pumpEventQueue();
    expect(h.sink.latest, hasLength(1));
    final call = h.sink.last;
    expect(call.adapter, 'io');
    expect(call.request.method, 'GET');
    expect(call.request.url, h.server.url('/json'));
    expect(call.request.headers['accept-encoding'], ['gzip']);
    expect(call.request.headers['content-length'], ['0']);
    expect(call.response!.statusCode, 200);
    expect(call.response!.body.text, '{"hello":"world"}');
    expect(call.response!.body.kind, BodyKind.json);
    expect(call.duration, isNotNull);
    expect(call.error, isNull);
    expect(h.server.hitsFor('/json'), 1);
  });

  test('redirects are followed (streamed)', () async {
    final res = await h.send('GET', '/redirect', closeClient: false);
    expect(res.statusCode, 200);
    expect(res.redirects.single.location, h.server.url('/json'));
    expect(await readText(res), '{"hello":"world"}');
    await pumpEventQueue();
    expect(h.sink.latest, hasLength(1));
    expect(h.sink.last.request.url, h.server.url('/redirect'));
  });

  test('maxRedirects is honoured', () async {
    await expectLater(
      h.send('GET', '/redirect', prepare: (req) => req.maxRedirects = 0),
      throwsA(isA<RedirectException>()),
    );
    await pumpEventQueue();
    expect(h.sink.last.error!.type, 'network');
  });

  test('map-local mock returns 503 with body, server not hit', () async {
    h.engine.rules = RuleSet([
      mapLocalRule(
        '*/json',
        MapLocalAction(
          response: jsonResponse(
            503,
            '{"down":true}',
            h: {
              'content-type': ['application/json'],
              'set-cookie': ['a=1; Path=/', 'b=2'],
              'x-multi': ['1', '2'],
            },
          ),
        ),
      ),
    ]);
    final res = await h.send('GET', '/json');
    expect(res.statusCode, 503);
    expect(res.contentLength, 13);
    expect(res.headers.value('content-length'), '13');
    expect(res.headers['x-multi'], ['1', '2']);
    expect(res.cookies.map((c) => c.name), ['a', 'b']);
    expect(
      res.compressionState,
      HttpClientResponseCompressionState.notCompressed,
    );
    expect(res.redirects, isEmpty);
    expect(res.isRedirect, isFalse);
    expect(res.certificate, isNull);
    expect(res.connectionInfo, isNull);
    expect(res.reasonPhrase, 'Service Unavailable');
    expect(() => res.redirect(), throwsUnsupportedError);
    expect(() => res.detachSocket(), throwsUnsupportedError);
    expect(await readText(res), '{"down":true}');
    expect(h.server.hitsFor('/json'), 0);
    await pumpEventQueue();
    expect(h.sink.last.response!.statusCode, 503);
    expect(h.sink.last.tags, contains(CallTag.mapLocal));
  });

  test('map-local without a response answers 200 with an empty body', () async {
    h.engine.rules = RuleSet([mapLocalRule('*/json', const MapLocalAction())]);
    final res = await h.send('GET', '/json');
    expect(res.statusCode, 200);
    expect(await res.toList(), isEmpty);
  });

  test('map-local delay is honoured', () async {
    h.engine.rules = RuleSet([
      mapLocalRule(
        '*/json',
        MapLocalAction(
          response: jsonResponse(200, '{}'),
          delay: const Duration(milliseconds: 150),
        ),
      ),
    ]);
    final sw = Stopwatch()..start();
    final res = await h.send('GET', '/json');
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(140));
    expect(res.statusCode, 200);
  });

  test('map-local timeout failure throws TimeoutException', () async {
    h.engine.rules = RuleSet([
      mapLocalRule(
        '*/json',
        const MapLocalAction(failure: SimulatedFailure.timeout),
      ),
    ]);
    await expectLater(h.send('GET', '/json'), throwsA(isA<TimeoutException>()));
    expect(h.server.hitsFor('/json'), 0);
    expect(h.sink.last.error!.type, 'timeout');
  });

  test('map-local noConnection failure throws SocketException', () async {
    h.engine.rules = RuleSet([
      mapLocalRule(
        '*/json',
        const MapLocalAction(failure: SimulatedFailure.noConnection),
      ),
    ]);
    await expectLater(
      h.send('GET', '/json'),
      throwsA(
        isA<SocketException>().having(
          (e) => e.message,
          'message',
          'Connection failed (simulated by Proxie)',
        ),
      ),
    );
    expect(h.server.hitsFor('/json'), 0);
    expect(h.sink.last.error!.type, 'no_connection');
  });

  test(
    '6 MB response: app gets every byte, stored body capped at 5 MB',
    () async {
      final res = await h.send('GET', '/big?mb=6');
      final bytes = await res.fold<BytesBuilder>(
        BytesBuilder(copy: false),
        (b, c) => b..add(c),
      );
      const total = 6 * 1024 * 1024;
      final all = bytes.takeBytes();
      expect(all, hasLength(total));
      expect(all.every((b) => b == 0x61), isTrue);
      expect(res.contentLength, total);
      await pumpEventQueue();
      final body = h.sink.last.response!.body;
      expect(body.truncated, isTrue);
      expect(body.bytes, hasLength(5 * 1024 * 1024));
      expect(body.originalLength, total);
      expect(h.sink.last.tags, contains(CallTag.truncated));
    },
  );

  test(
    'request body larger than teeCap is sent in full, stored capped',
    () async {
      h.engine.dispose();
      h.engine = h.makeEngine(config: const ProxieConfig(teeCap: 10));
      h.adapter.attach(h.engine);
      final payload = 'x' * 100;
      final res = await h.send(
        'POST',
        '/echo',
        prepare: (r) => r.write(payload),
      );
      expect((await h.echo(res))['body'], payload);
      await pumpEventQueue();
      final body = h.sink.last.request.body;
      expect(body.truncated, isTrue);
      expect(body.bytes, hasLength(10));
      expect(body.originalLength, 100);
    },
  );

  test('Set-Cookie values are recorded separately (streamed)', () async {
    final res = await h.send('GET', '/cookies');
    expect(res.cookies, hasLength(2));
    expect(await readText(res), 'ok');
    await pumpEventQueue();
    expect(h.sink.last.response!.headers['set-cookie'], [
      'a=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT',
      'b=2',
    ]);
  });

  test('cancelling the response early does not throw or leak', () async {
    final res = await h.send('GET', '/stream');
    final first = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = res.listen((_) {
      if (!first.isCompleted) {
        first.complete();
        sub.cancel();
      }
    });
    await first.future;
    // The connection is closed instead of streaming on.
    await h.server.waitForNoConnections();
    await pumpEventQueue();
    final call = h.sink.last;
    expect(call.error!.type, 'cancelled');
    expect(call.response!.statusCode, 200);
    expect(call.response!.body.truncated, isTrue);
    expect(call.response!.body.bytes, isNotEmpty);
  });

  test('cancelling a large response early records cancelled', () async {
    final res = await h.send('GET', '/big?mb=6');
    final first = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = res.listen((_) {
      if (!first.isCompleted) {
        first.complete();
        sub.cancel();
      }
    });
    await first.future;
    await pumpEventQueue();
    expect(h.sink.last.error!.type, 'cancelled');
  });

  test('stream error is recorded and forwarded to the app', () async {
    final res = await h.send('GET', '/drop');
    await expectLater(readText(res), throwsA(isA<HttpException>()));
    await pumpEventQueue();
    final call = h.sink.last;
    expect(call.error!.type, 'stream_error');
    expect(call.response!.body.bytes, utf8.encode('partial'));
    expect(call.response!.body.truncated, isTrue);
    expect(call.response!.body.originalLength, 7);
    expect(h.sink.latest, hasLength(1));
  });

  test('a streamed response that is never listened to stays pending', () async {
    final res = await h.send('GET', '/json');
    await pumpEventQueue();
    expect(h.sink.last.response, isNull);
    expect(h.sink.last.error, isNull);
    await res.drain<void>();
    await pumpEventQueue();
    expect(h.sink.last.response!.statusCode, 200);
  });

  test('connection failure records a network error and rethrows', () async {
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = dead.port;
    await dead.close();
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/x'));
    await expectLater(req.close(), throwsA(isA<SocketException>()));
    expect(h.sink.last.error!.type, 'network');
  });

  test('mock header values with non-ASCII bytes reach the app', () async {
    h.engine.rules = RuleSet([
      mapLocalRule(
        '*/json',
        MapLocalAction(
          response: jsonResponse(
            200,
            '{}',
            h: {
              'content-disposition': ['attachment; filename="cafÃ©"'],
            },
          ),
        ),
      ),
    ]);
    final res = await h.send('GET', '/json');
    expect(
      res.headers.value('content-disposition'),
      'attachment; filename="cafÃ©"',
    );
    await res.drain<void>();
  });

  test('mock reason phrase, redirect flag and connection follow it', () async {
    h.engine.rules = RuleSet([
      mapLocalRule(
        '*/json',
        MapLocalAction(
          response: jsonResponse(
            503,
            '{}',
            h: {
              'connection': ['close'],
            },
          ),
        ),
      ),
    ]);
    final res = await h.send('GET', '/json');
    expect(res.reasonPhrase, 'Service Unavailable');
    expect(res.persistentConnection, isFalse);
    expect(res.isRedirect, isFalse);
    await res.drain<void>();
  });

  test('mock with several content-type values keeps them all', () async {
    h.engine.rules = RuleSet([
      mapLocalRule(
        '*/json',
        MapLocalAction(
          response: jsonResponse(
            200,
            '{}',
            h: {
              'content-type': ['application/json', 'text/plain'],
            },
          ),
        ),
      ),
    ]);
    final res = await h.send('GET', '/json');
    expect(res.headers['content-type'], ['application/json', 'text/plain']);
    expect(res.headers.contentType!.mimeType, 'application/json');
    await res.drain<void>();
  });

  test('mock copied from a gzip call drops content-encoding', () async {
    final real = await h.send('GET', '/gzip');
    await real.drain<void>();
    await pumpEventQueue();
    final captured = h.sink.last.response!;
    expect(captured.headers['content-encoding'], ['gzip']);
    h.engine.rules = RuleSet([
      mapLocalRule('*/gzip', MapLocalAction(response: captured)),
    ]);
    final res = await h.send('GET', '/gzip');
    expect(res.headers['content-encoding'], isNull);
    expect(
      res.compressionState,
      HttpClientResponseCompressionState.notCompressed,
    );
    final text = await readText(res);
    expect(text, '{"zipped":true}');
    expect(res.contentLength, text.length);
  });

  test('the app gets a copy of mocked body bytes', () async {
    final mocked = jsonResponse(200, '{"a":1}');
    h.engine.rules = RuleSet([
      mapLocalRule('*/json', MapLocalAction(response: mocked)),
    ]);
    final first = await h.send('GET', '/json');
    final chunks = await first.toList();
    chunks.single[0] = 0x58;
    expect(utf8.decode(mocked.body.bytes), '{"a":1}');
    final second = await h.send('GET', '/json');
    expect(await readText(second), '{"a":1}');
  });
}
