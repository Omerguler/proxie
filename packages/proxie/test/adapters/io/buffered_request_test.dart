import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

import '../../support/io_harness.dart';

void main() {
  final h = IoHarness()..install();

  test('chunked add() x3 then close() reaches /echo byte-identical', () async {
    final res = await h.send(
      'POST',
      '/echo',
      prepare: (req) {
        req.headers.contentType = ContentType.text;
        req
          ..add(utf8.encode('one,'))
          ..add(utf8.encode('two,'))
          ..add(utf8.encode('three'));
      },
    );
    final e = await h.echo(res);
    expect(e['method'], 'POST');
    expect(e['body'], 'one,two,three');
    expect((e['headers'] as Map)['transfer-encoding'], 'chunked');
    await pumpEventQueue();
    expect(h.sink.last.request.body.text, 'one,two,three');
    expect(h.sink.last.request.headers['transfer-encoding'], ['chunked']);
  });

  test('add() keeps a copy: later changes to the buffer do not leak', () async {
    final buf = Uint8List.fromList(utf8.encode('abc'));
    final res = await h.send(
      'POST',
      '/echo',
      prepare: (req) {
        req.add(buf);
        buf[0] = 0x7a;
      },
    );
    expect((await h.echo(res))['body'], 'abc');
  });

  test(
    'write/writeln/writeAll/writeCharCode/addStream use the charset',
    () async {
      final client = HttpClient();
      final req = await client.postUrl(h.server.url('/echo'));
      req.headers.contentType = ContentType('text', 'plain', charset: 'utf-8');
      expect(req.encoding, utf8);
      req
        ..write('é')
        ..writeln('-')
        ..writeAll(['a', 'b'], '+')
        ..writeCharCode(0x21);
      await req.addStream(Stream.fromIterable([utf8.encode('>s')]));
      expect(() => req.encoding = latin1, throwsStateError);
      final e = await h.echo(await req.close());
      expect(e['body'], 'é-\na+b!>s');
    },
  );

  test('write defaults to ISO-8859-1 without a charset', () async {
    final client = HttpClient();
    final req = await client.postUrl(h.server.url('/echo'));
    expect(req.encoding, latin1);
    req.write('é');
    await req.close().then((r) => r.drain<void>());
    await pumpEventQueue();
    expect(h.sink.last.request.body.bytes, [0xe9]);
  });

  test('add while addStream is bound throws; close after close returns '
      'the same done', () async {
    final client = HttpClient();
    final req = await client.postUrl(h.server.url('/echo'));
    final ctrl = StreamController<List<int>>();
    final bound = req.addStream(ctrl.stream);
    expect(() => req.add([1]), throwsStateError);
    expect(() => req.close(), throwsStateError);
    ctrl.add(utf8.encode('x'));
    await ctrl.close();
    await bound;
    final first = req.close();
    expect(identical(req.close(), first), isTrue);
    expect(identical(req.done, first), isTrue);
    expect(() => req.add([1]), throwsStateError);
    expect((await h.echo(await first))['body'], 'x');
  });

  test('a failing addStream fails the request without sending', () async {
    final client = HttpClient();
    final req = await client.postUrl(h.server.url('/echo'));
    await expectLater(
      req.addStream(Stream.error(const FormatException('bad'))),
      throwsFormatException,
    );
    await expectLater(req.close(), throwsFormatException);
    expect(h.server.hitsFor('/echo'), 0);
    expect(h.sink.calls, isEmpty);
  });

  test('request options and cookies are copied to the real request', () async {
    final client = HttpClient();
    final req = await client.postUrl(h.server.url('/echo'));
    req
      ..contentLength = 4
      ..persistentConnection = false
      ..bufferOutput = false
      ..cookies.add(Cookie('sid', 'abc'))
      ..headers.add('X-Custom', 'v')
      ..write('body');
    final e = await h.echo(await req.close());
    final headers = e['headers'] as Map;
    expect(e['body'], 'body');
    expect(headers['content-length'], '4');
    expect(headers['connection'], 'close');
    expect(headers['cookie'], 'sid=abc');
    expect(headers['x-custom'], 'v');
    expect(() => req.followRedirects = false, throwsStateError);
    expect(() => req.maxRedirects = 1, throwsStateError);
    expect(() => req.bufferOutput = true, throwsStateError);
    expect(() => req.headers.add('x', 'y'), throwsA(isA<HttpException>()));
    await pumpEventQueue();
    final recorded = h.sink.last.request.headers;
    expect(recorded['cookie'], ['sid=abc']);
    expect(recorded['connection'], ['close']);
    expect(recorded['content-length'], ['4']);
  });

  test('removed default headers are not sent', () async {
    final res = await h.send(
      'GET',
      '/echo',
      prepare: (req) => req.headers.removeAll('accept-encoding'),
    );
    final headers = (await h.echo(res))['headers'] as Map;
    expect(headers.containsKey('accept-encoding'), isFalse);
    expect(headers['host'], '127.0.0.1:${h.server.url('/').port}');
  });

  test('followRedirects=false returns the redirect itself', () async {
    final res = await h.send(
      'GET',
      '/redirect',
      prepare: (req) => req.followRedirects = false,
    );
    expect(res.statusCode, 302);
    expect(res.isRedirect, isTrue);
    await res.drain<void>();
  });

  test('abort() before close fails done, sends and records nothing', () async {
    final client = HttpClient();
    final req = await client.postUrl(h.server.url('/echo'));
    req.write('x');
    req.abort();
    await expectLater(
      req.done,
      throwsA(
        isA<HttpException>()
            .having((e) => e.message, 'message', 'Request has been aborted')
            .having((e) => e.uri, 'uri', h.server.url('/echo')),
      ),
    );
    await expectLater(req.close(), throwsA(isA<HttpException>()));
    await pumpEventQueue();
    expect(h.server.hitsFor('/echo'), 0);
    expect(h.sink.calls, isEmpty);
  });

  test('abort() while paused at a breakpoint records cancelled', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/json', BreakpointPhase.request),
    ]);
    final client = HttpClient();
    final req = await client.getUrl(h.server.url('/json'));
    final closed = req.close();
    await pumpEventQueue();
    expect(h.engine.breakpoints.pending, hasLength(1));
    req.abort(const SocketException('gone'));
    await expectLater(closed, throwsA(isA<SocketException>()));
    await pumpEventQueue();
    expect(h.engine.breakpoints.pending, isEmpty);
    expect(h.server.hitsFor('/json'), 0);
    expect(h.sink.last.error!.type, 'cancelled');
  });

  test('abort() after the response arrived is harmless', () async {
    final client = HttpClient();
    final req = await client.getUrl(h.server.url('/json'));
    final res = await req.close();
    req.abort();
    expect(await readText(res), '{"hello":"world"}');
  });

  test('abort() during addStream cancels the source', () async {
    final client = HttpClient();
    final req = await client.postUrl(h.server.url('/echo'));
    var cancelled = false;
    final source = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    final bound = req.addStream(source.stream);
    source.add([1]);
    await pumpEventQueue();
    req.abort();
    await bound;
    expect(cancelled, isTrue);
    await expectLater(req.done, throwsA(isA<HttpException>()));
    expect(h.server.hitsFor('/echo'), 0);
  });

  test('client.close() lets a closed request finish', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/json', BreakpointPhase.request),
    ]);
    onPause(
      h.engine,
      BreakpointPhase.request,
      (_) => const ContinueUnchanged(),
    );
    final client = HttpClient();
    final req = await client.getUrl(h.server.url('/json'));
    final f = req.close();
    client.close();
    expect(() => client.getUrl(h.server.url('/json')), throwsStateError);
    final res = await f;
    expect(res.statusCode, 200);
    expect(await readText(res), '{"hello":"world"}');
  });

  test('client.close() lets a request opened earlier be sent later', () async {
    final client = HttpClient();
    final req = await client.postUrl(h.server.url('/echo'));
    client.close();
    req.write('late');
    final e = await h.echo(await req.close());
    expect(e['body'], 'late');
  });

  test('pass-through opens after close() throw like dart:io', () async {
    final client = HttpClient();
    h.adapter.detach();
    client.close();
    expect(() => client.getUrl(h.server.url('/json')), throwsStateError);
  });

  test('close(force: true) aborts a request paused at a breakpoint', () async {
    h.engine.rules = RuleSet([
      breakpointRule('*/json', BreakpointPhase.request),
    ]);
    final client = HttpClient();
    final req = await client.getUrl(h.server.url('/json'));
    final f = req.close();
    await pumpEventQueue();
    expect(h.engine.breakpoints.pending, hasLength(1));
    client.close(force: true);
    await expectLater(f, throwsA(isA<HttpException>()));
    await pumpEventQueue();
    expect(h.engine.breakpoints.pending, isEmpty);
    expect(h.server.hitsFor('/json'), 0);
    expect(h.sink.last.error!.type, 'cancelled');
  });

  test('close(force: true) stops a delayed mock from answering', () async {
    h.engine.rules = RuleSet([
      mapLocalRule(
        '*/json',
        MapLocalAction(
          response: jsonResponse(200, '{}'),
          delay: const Duration(milliseconds: 100),
        ),
      ),
    ]);
    final client = HttpClient();
    final req = await client.getUrl(h.server.url('/json'));
    final f = req.close();
    await pumpEventQueue();
    client.close(force: true);
    await expectLater(f, throwsA(isA<HttpException>()));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(h.sink.last.error!.type, 'cancelled');
    expect(h.sink.last.response, isNull);
  });

  test('close(force: true) fails requests not yet closed', () async {
    final client = HttpClient();
    final req = await client.postUrl(h.server.url('/echo'));
    client.close(force: true);
    await expectLater(req.close(), throwsA(isA<HttpException>()));
    expect(h.server.hitsFor('/echo'), 0);
  });
}
