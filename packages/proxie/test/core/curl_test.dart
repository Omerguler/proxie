import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';

ProxieRequest _req(
  String method,
  String url, {
  Map<String, List<String>> headers = const {},
  ProxieBody? body,
}) => ProxieRequest(
  method: method,
  url: Uri.parse(url),
  headers: headers,
  body: body ?? ProxieBody.empty(),
);

ProxieBody _body(String s, String ct) =>
    ProxieBody.from(Uint8List.fromList(utf8.encode(s)), ct);

void main() {
  test('GET without body', () {
    expect(
      toCurl(_req('GET', 'https://a.com/x?y=1')),
      "curl 'https://a.com/x?y=1'",
    );
  });

  test('POST json', () {
    final r = _req(
      'POST',
      'https://a.com/x',
      headers: {
        'content-type': ['application/json'],
        'content-length': ['7'],
      },
      body: _body('{"a":1}', 'application/json'),
    );
    expect(
      toCurl(r),
      "curl -X POST 'https://a.com/x' -H 'content-type: application/json' "
      "--data-raw '{\"a\":1}'",
    );
  });

  test('single quote in body is escaped', () {
    final r = _req(
      'POST',
      'https://a.com/x',
      body: _body("it's", 'text/plain'),
    );
    expect(toCurl(r), contains(r"--data-raw 'it'\''s'"));
  });

  test('binary body uses --data-binary and a comment', () {
    final r = _req(
      'POST',
      'https://a.com/x',
      body: ProxieBody.from(
        Uint8List.fromList([0, 1, 2, 3, 0xff]),
        'application/octet-stream',
      ),
    );
    final out = toCurl(r);
    expect(out, contains('--data-binary @body.bin'));
    expect(out, contains('# binary body (5 bytes) omitted'));
  });

  test('non-utf8 json body is treated as binary', () {
    final r = _req(
      'POST',
      'https://a.com/x',
      body: ProxieBody.from(
        Uint8List.fromList([0x7b, 0xff]),
        'application/json',
      ),
    );
    expect(toCurl(r), contains('--data-binary @body.bin'));
  });

  test('multiple header values give one -H each', () {
    final r = _req(
      'GET',
      'https://a.com/x',
      headers: {
        'accept': ['a/b', 'c/d'],
      },
    );
    expect(
      toCurl(r),
      "curl 'https://a.com/x' -H 'accept: a/b' -H 'accept: c/d'",
    );
  });

  test('GET with a body emits -X GET', () {
    final r = _req('GET', 'https://a.com/x', body: _body('q', 'text/plain'));
    expect(toCurl(r), startsWith("curl -X GET 'https://a.com/x'"));
  });

  test('truncated request body adds a comment line', () {
    final big = Uint8List.fromList(List.filled(100, 0x61));
    final r = _req(
      'POST',
      'https://a.com/x',
      body: ProxieBody.from(big, 'text/plain', cap: 40),
    );
    final out = toCurl(r);
    expect(out.split('\n').last, '# body truncated: 40 of 100 bytes');
    expect(out, contains('--data-raw'));
  });

  test('unusual methods are shell-quoted', () {
    expect(
      toCurl(_req('M-SEARCH', 'https://a.com/x')),
      "curl -X M-SEARCH 'https://a.com/x'",
    );
    expect(
      toCurl(_req("a b'c", 'https://a.com/x')),
      r"curl -X 'a b'\''c' 'https://a.com/x'",
    );
  });
}
