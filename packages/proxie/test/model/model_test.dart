import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

ProxieBody _body(List<int> bytes, BodyKind kind, {String? ct}) => ProxieBody(
  bytes: Uint8List.fromList(bytes),
  contentType: ct,
  kind: kind,
  truncated: true,
  originalLength: 99,
);

void main() {
  final req = ProxieRequest(
    method: 'POST',
    url: Uri.parse('https://example.com/a?b=1'),
    headers: {
      'x-a': ['1', '2'],
    },
    body: _body([123, 125], BodyKind.json, ct: 'application/json'),
  );
  final res = ProxieResponse(
    statusCode: 201,
    reasonPhrase: 'Created',
    headers: {
      'set-cookie': ['a=b', 'c=d'],
    },
    body: _body([1, 2, 3], BodyKind.binary),
  );

  test('roundtrip preserves every field', () {
    final r = ProxieRequest.fromMap(req.toMap());
    expect(r.method, 'POST');
    expect(r.url, req.url);
    expect(r.headers, req.headers);
    expect(r.body.bytes, req.body.bytes);
    expect(r.body.bytes, isA<Uint8List>());
    expect(r.body.contentType, 'application/json');
    expect(r.body.kind, BodyKind.json);
    expect(r.body.truncated, isTrue);
    expect(r.body.originalLength, 99);

    final s = ProxieResponse.fromMap(res.toMap());
    expect(s.statusCode, 201);
    expect(s.reasonPhrase, 'Created');
    expect(s.headers, res.headers);
    expect(s.body.bytes, Uint8List.fromList([1, 2, 3]));
    expect(s.body.kind, BodyKind.binary);
    expect(s.body.contentType, isNull);

    final call = ProxieCall(
      id: 'c1',
      sessionId: 7,
      adapter: 'http',
      request: req,
      response: res,
      error: const ProxieError(type: 'SocketException', message: 'boom'),
      startedAt: DateTime.utc(2026, 11, 1, 12, 30, 15, 123, 456),
      duration: const Duration(milliseconds: 250, microseconds: 7),
      tags: {CallTag.edited, CallTag.truncated},
    );
    final c = ProxieCall.fromMap(call.toMap());
    expect(c.id, 'c1');
    expect(c.sessionId, 7);
    expect(c.adapter, 'http');
    expect(c.request.url, req.url);
    expect(c.response!.statusCode, 201);
    expect(c.error!.type, 'SocketException');
    expect(c.error!.message, 'boom');
    expect(c.startedAt, call.startedAt);
    expect(c.startedAt.isUtc, isTrue);
    expect(c.duration, call.duration);
    expect(c.tags, {CallTag.edited, CallTag.truncated});

    final bare = ProxieCall.fromMap(
      ProxieCall(
        id: 'c2',
        sessionId: 0,
        adapter: 'dio',
        request: req,
        startedAt: DateTime.utc(2026),
      ).toMap(),
    );
    expect(bare.response, isNull);
    expect(bare.error, isNull);
    expect(bare.duration, isNull);
    expect(bare.tags, isEmpty);
  });

  test('header names are lowercased', () {
    final r = ProxieRequest(
      method: 'GET',
      url: Uri.parse('https://x.dev'),
      headers: {
        'Content-Type': ['a'],
        'X-Foo': ['b'],
      },
      body: ProxieBody.empty(),
    );
    expect(r.headers.keys, ['content-type', 'x-foo']);
    final s = ProxieResponse.fromMap({
      'statusCode': 200,
      'headers': {
        'ETag': ['z'],
      },
      'body': ProxieBody.empty().toMap(),
    });
    expect(s.headers.keys, ['etag']);
  });

  test('copyWith replaces only given fields', () {
    final r = req.copyWith(method: 'PUT');
    expect(r.method, 'PUT');
    expect(r.url, req.url);
    expect(r.headers, req.headers);
    expect(r.body, same(req.body));

    final s = res.copyWith(statusCode: 500);
    expect(s.statusCode, 500);
    expect(s.reasonPhrase, 'Created');
    expect(s.headers, res.headers);
    expect(s.body, same(res.body));
  });

  test('ProxieBody.text decodes UTF-8 and returns null when malformed', () {
    expect(_body([0x68, 0xc3, 0xa9], BodyKind.text).text, 'hé');
    expect(_body([0xff, 0xfe], BodyKind.binary).text, isNull);
  });

  test('ProxieBody.empty', () {
    final b = ProxieBody.empty();
    expect(b.kind, BodyKind.empty);
    expect(b.bytes, isEmpty);
    expect(b.originalLength, 0);
    expect(b.truncated, isFalse);
  });
}
