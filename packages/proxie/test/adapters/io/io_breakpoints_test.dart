import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';

import '../../support/io_harness.dart';

void main() {
  final h = IoHarness()..install();

  test('redirects are followed (response breakpoint)', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/redirect', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.response,
      (_) => const ContinueUnchanged(),
    );
    final res = await h.send('GET', '/redirect', closeClient: false);
    expect(res.statusCode, 200);
    expect(res.redirects, hasLength(1));
    expect(await readText(res), '{"hello":"world"}');
  });

  test(
    'response breakpoint changing status to 500 is seen by the app',
    () async {
      h.engine.rules = RuleSet([
        breakpointRule('*/json', BreakpointPhase.response),
      ]);
      onPause(
        h.engine,
        BreakpointPhase.response,
        (p) => ExecuteResponse(p.response!.copyWith(statusCode: 500)),
      );
      final res = await h.send('GET', '/json');
      expect(res.statusCode, 500);
      expect(res.contentLength, 17);
      expect(res.headers.contentType!.mimeType, 'application/json');
      expect(await readText(res), '{"hello":"world"}');
      await pumpEventQueue();
      expect(h.sink.last.response!.statusCode, 500);
      expect(h.sink.last.tags, contains(CallTag.edited));
    },
  );

  test('response breakpoint body edit updates content-length', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/json', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(
        p.response!.copyWith(
          body: ProxieBody.from(
            Uint8List.fromList(utf8.encode('{"a":12345}')),
            'application/json',
          ),
        ),
      ),
    );
    final res = await h.send('GET', '/json');
    expect(res.contentLength, 11);
    expect(res.headers.value('content-length'), '11');
    expect(await readText(res), '{"a":12345}');
  });

  test(
    'response breakpoint left unchanged delivers the full large body',
    () async {
      h.engine.dispose();
      h.engine = h.makeEngine(config: const ProxieConfig(teeCap: 1024));
      h.adapter.attach(h.engine);
      h.engine.rules = RuleSet([
        breakpointRule('*/big*', BreakpointPhase.response),
      ]);
      onPause(
        h.engine,
        BreakpointPhase.response,
        (_) => const ContinueUnchanged(),
      );
      final res = await h.send('GET', '/big?mb=1');
      final got = await res.fold<int>(0, (n, c) => n + c.length);
      expect(got, 1024 * 1024);
      expect(res.contentLength, 1024 * 1024);
      await pumpEventQueue();
      expect(h.sink.last.response!.body.truncated, isTrue);
      expect(h.sink.last.response!.body.originalLength, 1024 * 1024);
    },
  );

  test('response breakpoint abort throws HttpException', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/json', BreakpointPhase.response),
    ]);
    onPause(h.engine, BreakpointPhase.response, (_) => const Abort());
    await expectLater(
      h.send('GET', '/json'),
      throwsA(
        isA<HttpException>()
            .having(
              (e) => e.message,
              'message',
              'Aborted at response breakpoint',
            )
            .having((e) => e.uri, 'uri', h.server.url('/json')),
      ),
    );
    expect(h.sink.last.error!.type, 'aborted');
  });

  test('response breakpoints apply to mocked responses', () async {
    h.engine.rules = RuleSet([
      mapLocalRule('*/json', MapLocalAction(response: jsonResponse(404, '{}'))),
      breakpointRule('*/json', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(p.response!.copyWith(statusCode: 418)),
    );
    final res = await h.send('GET', '/json');
    expect(res.statusCode, 418);
    expect(h.server.hitsFor('/json'), 0);
  });

  test(
    'request breakpoint abort throws HttpException, server not hit',
    () async {
      h.engine.rules = RuleSet([
        breakpointRule('*/json', BreakpointPhase.request),
      ]);
      onPause(h.engine, BreakpointPhase.request, (_) => const Abort());
      await expectLater(
        h.send('GET', '/json'),
        throwsA(
          isA<HttpException>()
              .having((e) => e.message, 'message', 'Aborted at breakpoint')
              .having((e) => e.uri, 'uri', h.server.url('/json')),
        ),
      );
      expect(h.server.hitsFor('/json'), 0);
      expect(h.sink.last.error!.type, 'aborted');
    },
  );

  test('request breakpoint edit of method, url, header and body reaches '
      '/echo', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/json', BreakpointPhase.request),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.request,
      (p) => ExecuteRequest(
        p.request.copyWith(
          method: 'PUT',
          url: h.server.url('/echo?x=1'),
          headers: {
            ...p.request.headers,
            'x-test': ['1'],
          },
          body: ProxieBody.from(
            Uint8List.fromList(utf8.encode('edited')),
            'text/plain',
          ),
        ),
      ),
    );
    final res = await h.send(
      'POST',
      '/json',
      prepare: (req) => req
        ..headers.set('X-App', 'kept', preserveHeaderCase: true)
        ..write('original'),
    );
    final e = await h.echo(res);
    final headers = e['headers'] as Map;
    expect(e['method'], 'PUT');
    expect(e['uri'], '/echo?x=1');
    expect(e['body'], 'edited');
    expect(headers['x-test'], '1');
    expect(headers['x-app'], 'kept');
    expect(headers['content-length'], '6');
    expect(headers.containsKey('transfer-encoding'), isFalse);
    expect(headers['host'], '127.0.0.1:${h.server.url('/').port}');
    expect(h.server.hitsFor('/json'), 0);
    await pumpEventQueue();
    expect(h.sink.last.tags, contains(CallTag.edited));
    expect(h.sink.last.request.method, 'PUT');
  });

  test('request breakpoint continue keeps the full truncated body', () async {
    h.engine.dispose();
    h.engine = h.makeEngine(config: const ProxieConfig(teeCap: 10));
    h.adapter.attach(h.engine);
    h.engine.rules = RuleSet([
      breakpointRule('*/echo', BreakpointPhase.request),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.request,
      (p) => ExecuteRequest(
        p.request.copyWith(
          headers: {
            ...p.request.headers,
            'x-test': ['1'],
          },
        ),
      ),
    );
    final payload = 'y' * 50;
    final res = await h.send('POST', '/echo', prepare: (r) => r.write(payload));
    final e = await h.echo(res);
    expect(e['body'], payload);
    expect((e['headers'] as Map)['x-test'], '1');
  });

  test('Set-Cookie values stay separate (breakpoint)', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/cookies', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.response,
      (_) => const ContinueUnchanged(),
    );
    final res = await h.send('GET', '/cookies');
    expect(res.headers['set-cookie'], hasLength(2));
    expect(res.cookies.map((c) => c.name), ['a', 'b']);
    await res.drain<void>();
    await pumpEventQueue();
    expect(h.sink.last.response!.headers['set-cookie'], hasLength(2));
  });

  test('stream error while buffering for a breakpoint is recorded', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/drop', BreakpointPhase.response),
    ]);
    await expectLater(h.send('GET', '/drop'), throwsA(isA<HttpException>()));
    expect(h.sink.last.error!.type, 'stream_error');
  });

  test('non-ASCII header bytes pass a response breakpoint', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/utf8-header', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.response,
      (_) => const ContinueUnchanged(),
    );
    final res = await h.send('GET', '/utf8-header');
    final value = res.headers.value('content-disposition')!;
    expect(value.codeUnits, contains(0xc3));
    expect(await readText(res), 'ok');
  });

  test('edited status brings its reason phrase and redirect flag', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/json', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(p.response!.copyWith(statusCode: 302)),
    );
    final res = await h.send('GET', '/json');
    expect(res.statusCode, 302);
    expect(res.reasonPhrase, 'Found');
    expect(res.isRedirect, isTrue);
    await res.drain<void>();
  });

  test('an explicitly edited reason phrase is kept', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/json', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(
        p.response!.copyWith(statusCode: 404, reasonPhrase: 'Gone Fishing'),
      ),
    );
    final res = await h.send('GET', '/json');
    expect(res.reasonPhrase, 'Gone Fishing');
    expect(res.isRedirect, isFalse);
    await res.drain<void>();
  });

  test('unchanged status keeps the server reason phrase', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/status/*', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.response,
      (_) => const ContinueUnchanged(),
    );
    final res = await h.send('GET', '/status/418');
    expect(res.reasonPhrase, 'Status 418');
    await res.drain<void>();
  });

  test('gzip response through a response breakpoint', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/gzip', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.response,
      (_) => const ContinueUnchanged(),
    );
    final res = await h.send('GET', '/gzip');
    expect(
      res.compressionState,
      HttpClientResponseCompressionState.decompressed,
    );
    // Like dart:io for a decompressed body: length unknown.
    expect(res.contentLength, -1);
    expect(res.headers.value('content-length'), isNull);
    expect(await readText(res), '{"zipped":true}');
    await pumpEventQueue();
    expect(h.sink.last.response!.body.text, '{"zipped":true}');
  });

  test(
    'close(force: true) fails a call paused at a response breakpoint',
    () async {
      h.engine.rules = RuleSet([
        breakpointRule('*/json', BreakpointPhase.response),
      ]);
      final client = HttpClient();
      final req = await client.getUrl(h.server.url('/json'));
      final f = req.close();
      while (h.engine.breakpoints.pending.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      client.close(force: true);
      await expectLater(
        f,
        throwsA(
          isA<HttpException>()
              .having((e) => e.message, 'message', 'Client closed forcefully')
              .having((e) => e.uri, 'uri', h.server.url('/json')),
        ),
      );
      await pumpEventQueue();
      expect(h.engine.breakpoints.pending, isEmpty);
      expect(h.sink.last.error!.type, 'cancelled');
    },
  );

  test('an edited lowercase method still gets redirect detection', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/json', BreakpointPhase.request),
      breakpointRule('*/echo', BreakpointPhase.response),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.request,
      (p) => ExecuteRequest(
        p.request.copyWith(method: 'get', url: h.server.url('/echo')),
      ),
    );
    onPause(
      h.engine,
      BreakpointPhase.response,
      (p) => ExecuteResponse(p.response!.copyWith(statusCode: 302)),
    );
    final res = await h.send('POST', '/json');
    expect(res.statusCode, 302);
    expect(res.isRedirect, isTrue);
    await res.drain<void>();
  });

  test('an abort on an endless response at a response breakpoint closes the '
      'connection', () async {
    h.adapter.detach();
    final e = ProxieEngine(
      config: const ProxieConfig(
        breakpointTimeout: Duration(milliseconds: 300),
      ),
      sink: h.sink,
    )..rules = RuleSet([breakpointRule('*/stream', BreakpointPhase.response)]);
    addTearDown(e.dispose);
    h.adapter.attach(e);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final req = await client.openUrl('GET', h.server.url('/stream'));
    final res = req.close();
    // After the response has arrived, while it is being buffered.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    req.abort();
    await expectLater(res, throwsA(anything));
    await h.server.waitForNoStreams();
  });

  test('a response breakpoint past the capture cap streams through, keeping '
      'every byte', () async {
    h.adapter.detach();
    final e = ProxieEngine(
      config: const ProxieConfig(teeCap: 1024),
      sink: h.sink,
    )..rules = RuleSet([breakpointRule('*/stream', BreakpointPhase.response)]);
    addTearDown(e.dispose);
    h.adapter.attach(e);
    final res = await h
        .send('GET', '/stream')
        .timeout(const Duration(seconds: 5));
    expect(e.breakpoints.pending, isEmpty);
    expect(res.statusCode, 200);
    final first = await res.first;
    expect(first, isNotEmpty);
    await h.server.waitForNoStreams();
  });
}
