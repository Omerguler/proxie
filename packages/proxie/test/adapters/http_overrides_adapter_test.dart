import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/adapters/http_overrides_stub.dart' as stub;
import 'package:proxie/src/internal_api.dart';

import '../support/io_harness.dart';

/// Overrides whose clients carry `user-agent: prev`.
class _PrevOverrides extends HttpOverrides {
  int created = 0;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    created++;
    return super.createHttpClient(context)..userAgent = 'prev';
  }
}

/// Overrides answering every proxy lookup with `PROXY prev:1`.
class _ProxyOverrides extends HttpOverrides {
  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) =>
      'PROXY prev:1';
}

/// Overrides handing out [client].
class _FixedOverrides extends HttpOverrides {
  _FixedOverrides(this.client);
  final HttpClient client;

  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

/// Records [close] calls; everything else is unused.
class _FakeClient implements HttpClient {
  bool? closedForce;

  @override
  void close({bool force = false}) => closedForce = force;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final h = IoHarness()..install();

  test('name and replay support', () {
    expect(h.adapter.name, 'io');
    expect(h.adapter.supportsReplay, isTrue);
    expect(h.adapter, isA<ProxieCaptureAdapter>());
  });

  test('inside runMarkedCaptured nothing is captured', () async {
    final body = await runMarkedCaptured(() async {
      final res = await h.send('GET', '/json');
      return await readText(res);
    });
    expect(body, '{"hello":"world"}');
    await pumpEventQueue();
    expect(h.sink.calls, isEmpty);
  });

  test('previous overrides are chained (user-agent: prev)', () async {
    h.adapter.detach();
    final prev = _PrevOverrides();
    HttpOverrides.global = prev;
    h.adapter.attach(h.engine);
    final res = await h.send('GET', '/echo');
    expect(((await h.echo(res))['headers'] as Map)['user-agent'], 'prev');
    expect(prev.created, 1);
    await pumpEventQueue();
    expect(h.sink.last.request.headers['user-agent'], ['prev']);
    h.adapter.detach();
    expect(identical(globalOverrides(), prev), isTrue);
  });

  test('findProxyFromEnvironment delegates to previous overrides', () {
    final direct = HttpClient.findProxyFromEnvironment(h.server.url('/'));
    expect(direct, 'DIRECT');
    h.adapter.detach();
    HttpOverrides.global = _ProxyOverrides();
    h.adapter.attach(h.engine);
    expect(
      HttpClient.findProxyFromEnvironment(h.server.url('/')),
      'PROXY prev:1',
    );
    h.adapter.detach();
  });

  test('the default user agent is recorded like dart:io sends it', () async {
    final res = await h.send('GET', '/echo');
    final sent = ((await h.echo(res))['headers'] as Map)['user-agent'];
    await pumpEventQueue();
    expect(h.sink.last.request.headers['user-agent'], [sent]);
  });

  test('replay re-sends through a fresh client and is not recorded', () async {
    final res = await h.send('POST', '/echo', prepare: (r) => r.write('rb'));
    await res.drain<void>();
    await pumpEventQueue();
    final recorded = h.sink.calls.length;
    final replayed = await h.adapter.replay(h.sink.last.request);
    expect(h.server.hitsFor('/echo'), 2);
    expect(replayed.statusCode, 200);
    final e = jsonDecode(replayed.body.text!) as Map;
    expect(e['method'], 'POST');
    expect(e['body'], 'rb');
    expect(h.sink.calls, hasLength(recorded));
  });

  test(
    'replay sends method, headers and body; set-cookie stays separate',
    () async {
      final r = await h.adapter.replay(
        ProxieRequest(
          method: 'PUT',
          url: h.server.url('/echo'),
          headers: {
            'x-r': ['1'],
            'content-length': ['999'],
            'host': ['stale:1'],
          },
          body: ProxieBody.from(Uint8List.fromList(utf8.encode('rb')), null),
        ),
      );
      final e = jsonDecode(r.body.text!) as Map;
      expect(e['method'], 'PUT');
      expect(e['body'], 'rb');
      expect((e['headers'] as Map)['x-r'], '1');
      final c = await h.adapter.replay(
        ProxieRequest(
          method: 'GET',
          url: h.server.url('/cookies'),
          headers: {},
          body: ProxieBody.empty(),
        ),
      );
      expect(c.headers['set-cookie'], hasLength(2));
    },
  );

  test('replay uses the chained overrides', () async {
    h.adapter.detach();
    HttpOverrides.global = _PrevOverrides();
    h.adapter.attach(h.engine);
    final r = await h.adapter.replay(
      ProxieRequest(
        method: 'GET',
        url: h.server.url('/echo'),
        headers: {},
        body: ProxieBody.empty(),
      ),
    );
    expect(
      ((jsonDecode(r.body.text!) as Map)['headers'] as Map)['user-agent'],
      'prev',
    );
  });

  test('replay of a truncated request body throws StateError', () async {
    final body = ProxieBody.from(Uint8List(20), null, cap: 10);
    await expectLater(
      h.adapter.replay(
        ProxieRequest(
          method: 'POST',
          url: h.server.url('/echo'),
          headers: {},
          body: body,
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'Cannot replay: request body was truncated',
        ),
      ),
    );
    expect(h.server.hitsFor('/echo'), 0);
  });

  test('pass-through before attach and after detach', () async {
    h.adapter.detach();
    expect(globalOverrides(), isNull);
    final before = HttpClient();
    final req0 = await before.getUrl(h.server.url('/json'));
    expect(req0.runtimeType.toString(), isNot('BufferedHttpClientRequest'));
    await (await req0.close()).drain<void>();

    h.adapter.attach(h.engine);
    final attachedClient = HttpClient();
    final opened = await attachedClient.getUrl(h.server.url('/json'));
    h.adapter.detach();
    // Opened while attached, closed after detach: sent unrecorded.
    await (await opened.close()).drain<void>();
    // A client created while attached passes through after detach.
    final req = await attachedClient.getUrl(h.server.url('/json'));
    expect(req.runtimeType.toString(), isNot('BufferedHttpClientRequest'));
    final res = await req.close();
    expect(await readText(res), '{"hello":"world"}');
    await pumpEventQueue();
    expect(h.sink.calls, isEmpty);
    expect(h.server.hitsFor('/json'), 3);
    expect(globalOverrides(), isNull);
  });

  test('attach twice swaps the engine without re-wrapping', () async {
    final other = h.makeEngine();
    h.adapter.attach(other);
    final res = await h.send('GET', '/json');
    await res.drain<void>();
    await pumpEventQueue();
    expect(h.sink.latest, hasLength(1));
    h.adapter.detach();
    expect(globalOverrides(), isNull);
    other.dispose();
  });

  test('detach leaves overrides installed later in place', () async {
    final later = _PrevOverrides();
    HttpOverrides.global = later;
    h.adapter.detach();
    expect(identical(globalOverrides(), later), isTrue);
    // Re-attaching does not revive the stale wrapper inside `later`'s
    // chain: one call, one record.
    h.adapter.attach(h.engine);
    final res = await h.send('GET', '/json');
    await res.drain<void>();
    await pumpEventQueue();
    expect(h.sink.latest, hasLength(1));
  });

  test(
    'client config and close(force:) delegate to the inner client',
    () async {
      h.adapter.detach();
      final real = HttpClient();
      final fake = _FakeClient();
      HttpOverrides.global = _FixedOverrides(fake);
      h.adapter.attach(h.engine);
      final client = HttpClient()..close(force: true);
      expect(fake.closedForce, isTrue);
      expect(() => client.getUrl(h.server.url('/json')), throwsStateError);

      h.adapter.detach();
      HttpOverrides.global = _FixedOverrides(real);
      h.adapter.attach(h.engine);
      final wrapped = HttpClient()
        ..userAgent = 'ua'
        ..idleTimeout = const Duration(seconds: 3)
        ..connectionTimeout = const Duration(seconds: 4)
        ..maxConnectionsPerHost = 2
        ..autoUncompress = false;
      expect(real.userAgent, 'ua');
      expect(real.idleTimeout, const Duration(seconds: 3));
      expect(real.connectionTimeout, const Duration(seconds: 4));
      expect(real.maxConnectionsPerHost, 2);
      expect(real.autoUncompress, isFalse);
      expect(wrapped.userAgent, 'ua');
      final res = await (await wrapped.getUrl(h.server.url('/echo'))).close();
      expect(((await h.echo(res))['headers'] as Map)['user-agent'], 'ua');
      wrapped.close();
    },
  );

  test('open(host, port, path) splits query and drops the fragment', () async {
    final client = HttpClient();
    final req = await client.open(
      'get',
      '127.0.0.1',
      h.server.url('/').port,
      '/echo?a=1#frag',
    );
    expect(req.method, 'GET');
    expect(req.uri.query, 'a=1');
    final e = await h.echo(await req.close());
    expect(e['uri'], '/echo?a=1');
    await pumpEventQueue();
    expect(h.sink.last.request.url.fragment, isEmpty);
  });

  test('invalid method or scheme throws like dart:io', () {
    final client = HttpClient();
    expect(
      () => client.openUrl('BAD METHOD', h.server.url('/')),
      throwsArgumentError,
    );
    expect(
      () => client.getUrl(Uri.parse('ftp://127.0.0.1/x')),
      throwsArgumentError,
    );
    expect(() => client.getUrl(Uri.parse('/relative')), throwsArgumentError);
  });

  test('web stub is a no-op adapter', () async {
    final s = stub.ProxieHttpOverridesAdapter();
    expect(s.name, 'io');
    expect(s.supportsReplay, isFalse);
    s
      ..attach(h.engine)
      ..detach();
    expect(
      () => s.replay(
        ProxieRequest(
          method: 'GET',
          url: h.server.url('/'),
          headers: {},
          body: ProxieBody.empty(),
        ),
      ),
      throwsUnsupportedError,
    );
  });

  test('attach inside a zone override chains to the global overrides', () {
    h.adapter.detach();
    final zoned = _PrevOverrides();
    HttpOverrides.runWithHttpOverrides(() {
      h.adapter.attach(h.engine);
    }, zoned);
    h.adapter.detach();
    expect(globalOverrides(), isNull);
  });

  test('replay skips framing headers whatever their case', () async {
    final r = await h.adapter.replay(
      ProxieRequest(
        method: 'POST',
        url: h.server.url('/echo'),
        headers: {
          'Content-Length': ['999'],
          'Transfer-Encoding': ['chunked'],
        },
        body: ProxieBody.from(Uint8List.fromList(utf8.encode('ok')), null),
      ),
    );
    final e = jsonDecode(r.body.text!) as Map;
    expect(e['body'], 'ok');
    expect((e['headers'] as Map)['content-length'], '2');
  });
}
