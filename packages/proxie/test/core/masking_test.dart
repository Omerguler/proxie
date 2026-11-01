import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

ProxieBody _json(String s) =>
    ProxieBody.from(Uint8List.fromList(utf8.encode(s)), 'application/json');

ProxieRequest _req({
  Map<String, List<String>> headers = const {},
  ProxieBody? body,
}) => ProxieRequest(
  method: 'POST',
  url: Uri.parse('https://a.com/x'),
  headers: headers,
  body: body ?? ProxieBody.empty(),
);

void main() {
  const masking = ProxieMasking.defaults;

  test('masks Authorization header value', () {
    final out = masking.maskRequest(
      _req(
        headers: {
          'Authorization': ['Bearer abc'],
          'Accept': ['*/*'],
        },
      ),
    );
    expect(out.headers['authorization'], [kMask]);
    expect(out.headers['accept'], ['*/*']);
  });

  test('header match is case-insensitive, including configured names', () {
    const custom = ProxieMasking(headers: {'X-Api-Key'});
    final out = custom.maskRequest(
      _req(
        headers: {
          'x-API-key': ['k1', 'k2'],
        },
      ),
    );
    expect(out.headers['x-api-key'], [kMask, kMask]);
  });

  test('masks response set-cookie headers', () {
    final r = ProxieResponse(
      statusCode: 200,
      headers: {
        'Set-Cookie': ['a=1', 'b=2'],
      },
      body: ProxieBody.empty(),
    );
    expect(masking.maskResponse(r).headers['set-cookie'], [kMask, kMask]);
  });

  test('masks nested json keys case-insensitively, leaves others', () {
    final out = masking.maskRequest(
      _req(
        body: _json('{"user":{"Password":"x","name":"a"},"l":[{"token":1}]}'),
      ),
    );
    final decoded = jsonDecode(out.body.text!) as Map;
    expect((decoded['user'] as Map)['Password'], kMask);
    expect((decoded['user'] as Map)['name'], 'a');
    expect(((decoded['l'] as List).first as Map)['token'], kMask);
    expect(out.body.kind, BodyKind.json);
    expect(out.body.contentType, 'application/json');
  });

  test('non-json body is untouched', () {
    final body = ProxieBody.from(
      Uint8List.fromList(utf8.encode('password=x')),
      'text/plain',
    );
    final out = masking.maskRequest(_req(body: body));
    expect(identical(out.body, body), isTrue);
  });

  test('invalid json body is untouched', () {
    final body = _json('{"password": ');
    final out = masking.maskRequest(_req(body: body));
    expect(out.body.text, '{"password": ');
  });

  test('json body over render cap is untouched', () {
    final big = '{"password":"${'a' * (defaultBodyCap + 10)}"}';
    final body = ProxieBody.from(
      Uint8List.fromList(utf8.encode(big)),
      'application/json',
      cap: defaultBodyCap + 100,
    );
    final out = masking.maskRequest(_req(body: body));
    expect(identical(out.body, body), isTrue);
  });

  test('returns new objects and leaves originals unchanged', () {
    final original = _req(
      headers: {
        'authorization': ['secret'],
      },
      body: _json('{"password":"x"}'),
    );
    final out = masking.maskRequest(original);
    expect(identical(out, original), isFalse);
    expect(original.headers['authorization'], ['secret']);
    expect(original.body.text, '{"password":"x"}');
  });

  test('maskResponse masks json body', () {
    final r = ProxieResponse(
      statusCode: 200,
      headers: const {},
      body: _json('{"access_token":"t","ok":true}'),
    );
    final decoded =
        jsonDecode(masking.maskResponse(r).body.text!) as Map<String, dynamic>;
    expect(decoded, {'access_token': kMask, 'ok': true});
  });
}
