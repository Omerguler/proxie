import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/core/masking.dart' show kFormType, kMaskInUrl;

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

  test('malformed json still masks sensitive values', () {
    final body = _json('{"Token": 12345, "a": ');
    final out = masking.maskRequest(_req(body: body));
    expect(out.body.text, '{"Token": "$kMask", "a": ');
  });

  test('truncated json masks values and keeps truncation metadata', () {
    final full =
        '{"user":{"password":"hunter2","name":"a"},"pad":"${'x' * 50}"}';
    final bytes = Uint8List.fromList(utf8.encode(full));
    final body = ProxieBody.from(bytes, 'application/json', cap: 40);
    expect(body.truncated, isTrue);
    final out = masking.maskRequest(_req(body: body));
    expect(out.body.text, contains('"password":"$kMask"'));
    expect(out.body.text, isNot(contains('hunter2')));
    expect(out.body.truncated, isTrue);
    expect(out.body.originalLength, bytes.length);
  });

  test('truncation mid-value still masks the partial value', () {
    final bytes = Uint8List.fromList(utf8.encode('{"password":"hunt'));
    final body = ProxieBody.from(bytes, 'application/json', cap: 1000);
    final cut = ProxieBody(
      bytes: bytes,
      contentType: 'application/json',
      kind: body.kind,
      truncated: true,
      originalLength: 5000,
    );
    final out = masking.maskRequest(_req(body: cut));
    expect(out.body.text, '{"password":"$kMask"');
  });

  test('escaped quote inside masked string value is fully masked', () {
    final body = _json(r'{"secret":"a\"b","next":"keep" ');
    final out = masking.maskRequest(_req(body: body));
    expect(out.body.text, '{"secret":"$kMask","next":"keep" ');
  });

  test('json body over render cap is masked via text fallback', () {
    final big = '{"password":"s3cret","pad":"${'a' * (defaultBodyCap + 10)}"}';
    final body = ProxieBody.from(
      Uint8List.fromList(utf8.encode(big)),
      'application/json',
      cap: defaultBodyCap + 100,
    );
    final out = masking.maskRequest(_req(body: body));
    expect(out.body.text, contains('"password":"$kMask"'));
    expect(out.body.text, isNot(contains('s3cret')));
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

  test('masking keeps the formatting around the masked value', () {
    final pretty = [
      '{',
      '  "password": "x",',
      '  "a": [1, 2]',
      '}',
    ].join(String.fromCharCode(10));
    final out = masking.maskRequest(_req(body: _json(pretty)));
    expect(out.body.text, pretty.replaceFirst('"x"', '"$kMask"'));
    final compact = masking.maskRequest(_req(body: _json('{"password":"x"}')));
    expect(compact.body.text, '{"password":"$kMask"}');
  });

  test('structural path preserves body metadata', () {
    final src = ProxieBody(
      bytes: Uint8List.fromList(utf8.encode('{"password":"x"}')),
      contentType: 'application/vnd.x+json',
      kind: BodyKind.json,
      originalLength: 4242,
    );
    final out = masking.maskRequest(_req(body: src)).body;
    expect(out.kind, BodyKind.json);
    expect(out.contentType, 'application/vnd.x+json');
    expect(out.originalLength, 4242);
    expect(out.truncated, isFalse);
    expect(out.text, '{"password":"$kMask"}');
  });

  test('fallback masks object and array values under sensitive keys', () {
    final obj = masking.maskRequest(
      _req(body: _json('{"token": {"a": "}", "b": [1, {"c": 2}]}, "k": 1 ')),
    );
    expect(obj.body.text, '{"token": "$kMask", "k": 1 ');
    final arr = masking.maskRequest(
      _req(body: _json(r'{"secret":["a\"]","b"],"keep":true ')),
    );
    expect(arr.body.text, '{"secret":"$kMask","keep":true ');
    final truncated = masking.maskRequest(
      _req(body: _json('{"password":{"a":"b",')),
    );
    expect(truncated.body.text, '{"password":"$kMask"');
  });

  test('masking a 6 MB malformed body completes quickly', () {
    const chunk = '{"token":"abc","x":{"y":[1,2,3]},"password":{"p":"q"},';
    final sb = StringBuffer();
    while (sb.length < 6 * 1024 * 1024) {
      sb.write(chunk);
    }
    final body = ProxieBody(
      bytes: Uint8List.fromList(utf8.encode(sb.toString())),
      contentType: 'application/json',
      kind: BodyKind.json,
    );
    final sw = Stopwatch()..start();
    final out = masking.maskRequest(_req(body: body));
    sw.stop();
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    expect(out.body.text, isNot(contains('abc')));
    expect(out.body.text, contains('"token":"$kMask"'));
    expect(out.body.text, contains('"password":"$kMask"'));
  });

  test('const ProxieMasking keeps working and defaults are usable', () {
    const a = ProxieMasking(headers: {'X-Key'}, jsonKeys: {'pin'});
    final out = a.maskRequest(
      _req(
        headers: {
          'x-key': ['1'],
        },
        body: _json('{"PIN":"1","password":"keep"}'),
      ),
    );
    expect(out.headers['x-key'], [kMask]);
    expect(out.body.text, '{"PIN":"$kMask","password":"keep"}');
    expect(identical(ProxieMasking.defaults, masking), isTrue);
  });

  test('latin1 json is re-encoded as latin1, keeping other characters', () {
    final src = ProxieBody.from(
      Uint8List.fromList(latin1.encode('{"name":"café","password":"x"}')),
      'text/json; charset=latin1',
    );
    final out = masking.maskRequest(_req(body: src)).body;
    expect(out.text, '{"name":"café","password":"******"}');
    expect(out.bytes.contains(0xe9), isTrue);
    expect(out.originalLength, src.originalLength);
  });

  test('a trailing newline stays', () {
    final nl = String.fromCharCode(10);
    final out = masking.maskRequest(
      _req(body: _json('{"password":"x","a":1}$nl')),
    );
    expect(out.body.text, '{"password":"$kMask","a":1}$nl');
  });

  group('a body without a sensitive key is byte for byte the same', () {
    for (final text in [
      r'{"price":10.50,"e":1e3,"p":"a\/b"}',
      '{"id":12345678901234567890}',
      '{"a":1,"a":2}',
      '{ "spaced" :  [ 1 , 2 ] }',
      r'{"é":"\u00e9"}',
    ]) {
      test(text, () {
        final body = _json(text);
        expect(
          identical(masking.maskRequest(_req(body: body)).body, body),
          isTrue,
        );
      });
    }
  });

  test('masking off leaves bodies alone, sensitive keys included', () {
    const off = ProxieMasking(headers: {}, jsonKeys: {});
    final body = _json('{"password":"x","n":10.50}');
    expect(identical(off.maskRequest(_req(body: body)).body, body), isTrue);
  });

  test('only the masked values change: lexemes and duplicates stay', () {
    final out = masking.maskRequest(
      _req(
        body: _json(
          '{"id":12345678901234567890,"p":10.50,"password":"x",'
          r'"token":1,"token":{"a":[1]},"a":1,"a":"\/"}',
        ),
      ),
    );
    expect(
      out.body.text,
      '{"id":12345678901234567890,"p":10.50,"password":"$kMask",'
      '"token":"$kMask","token":"$kMask","a":1,"a":"\\/"}',
    );
  });

  test('a sensitive key inside a masked value is not spliced twice', () {
    final out = masking.maskRequest(
      _req(body: _json('{"token":{"password":"x"},"a":[{"secret":1}]}')),
    );
    expect(out.body.text, '{"token":"$kMask","a":[{"secret":"$kMask"}]}');
  });

  test('a key spelled with an escape is masked', () {
    final out = masking.maskRequest(
      _req(body: _json(r'{"pass\u0077ord":"x"}')),
    );
    expect(out.body.text, endsWith('0077ord":"$kMask"}'));
  });

  test('a string equal to a sensitive key in an array stays', () {
    final body = _json('["password","x"]');
    expect(identical(masking.maskRequest(_req(body: body)).body, body), isTrue);
  });

  group('JSON that is not valid UTF-8 still masks (fails closed)', () {
    for (final type in [
      'application/json',
      'application/json; charset=iso-8859-1',
    ]) {
      test(type, () {
        final bytes = Uint8List.fromList([
          ...utf8.encode('{"password":"hunter2","n":"'),
          0xE9,
          ...utf8.encode('"}'),
        ]);
        final body = ProxieBody.from(bytes, type);
        expect(body.text, isNull);
        final out = masking.maskRequest(_req(body: body)).body;
        expect(latin1.decode(out.bytes), isNot(contains('hunter2')));
        // Everything else is the same bytes.
        expect(out.bytes.sublist(out.bytes.length - 3), [0xE9, 0x22, 0x7D]);
        expect(utf8.decode(out.bytes, allowMalformed: true), contains(kMask));
        expect(out.kind, body.kind);
        expect(out.originalLength, bytes.length);
      });
    }
  });

  test('20,000 levels of nesting are masked, not lost', () {
    const depth = 20000;
    final text = '${'[' * depth}{"password":"hunter2"}${']' * depth}';
    final out = masking.maskRequest(_req(body: _json(text))).body;
    expect(out.text, isNot(contains('hunter2')));
    expect(out.text, contains('"password":"$kMask"'));
  });

  group('JSON under another text content type', () {
    ProxieBody text(String s, [String type = 'text/plain']) =>
        ProxieBody.from(Uint8List.fromList(utf8.encode(s)), type);

    test('is masked when it parses', () {
      final out = masking.maskRequest(
        _req(body: text('{"password":"hunter2","n":1.50}')),
      );
      expect(out.body.text, '{"password":"$kMask","n":1.50}');
      expect(out.body.kind, BodyKind.text);
    });

    test('is left alone when it does not parse', () {
      final body = text('{"password": not json}');
      expect(
        identical(masking.maskRequest(_req(body: body)).body, body),
        isTrue,
      );
    });

    test('cut at the cap, it is masked as far as it goes', () {
      final bytes = Uint8List.fromList(
        utf8.encode('{"password":"hunter2","pad":"${'x' * 50}"}'),
      );
      final body = ProxieBody.from(bytes, 'text/plain', cap: 40);
      expect(body.truncated, isTrue);
      final out = masking.maskRequest(_req(body: body)).body;
      expect(out.text, isNot(contains('hunter2')));
    });

    test('stringified JSON inside a value stays (documented)', () {
      final body = _json(r'{"data":"{\"token\":\"abc\"}"}');
      expect(
        identical(masking.maskRequest(_req(body: body)).body, body),
        isTrue,
      );
    });
  });

  group('query parameters', () {
    ProxieRequest url(String u) => _req().copyWith(url: Uri.parse(u));

    test('a sensitive one is masked; the rest keep their encoding', () {
      final out = masking.maskRequest(
        url('https://a.com/x?a=b%20c+d&Token=abc&e&f=#frag?token=keep'),
      );
      expect(
        out.url.toString(),
        'https://a.com/x?a=b%20c+d&Token=$kMaskInUrl&e&f=#frag?token=keep',
      );
      expect(out.url.queryParameters['Token'], kMask);
    });

    test('a URL with nothing to mask is the same object', () {
      final r = url('https://a.com/x?a=1&token=&password');
      expect(identical(masking.maskRequest(r).url, r.url), isTrue);
    });

    test('names match encoded, in brackets and after a semicolon', () {
      final out = masking.maskRequest(
        url('https://a.com/?to%6Ben=1&user[password]=2&secret[]=3&a=1;token=4'),
      );
      final query = out.url.query;
      expect(query, isNot(contains('=1&')));
      expect(query.split(kMaskInUrl).length - 1, 4);
      expect(query, contains('a=1;token=$kMaskInUrl'));
    });

    test('a malformed name or value does not throw', () {
      final uri = Uri(
        scheme: 'https',
        host: 'a.com',
        query: 'x%zz=1&token=%zz',
      );
      final r = _req().copyWith(url: uri);
      expect(masking.maskRequest(r).url.query, contains('token=$kMaskInUrl'));
    });

    test('custom keys apply, defaults then do not', () {
      const custom = ProxieMasking(jsonKeys: {'pin'});
      final out = custom.maskRequest(url('https://a.com/?PIN=1&token=2'));
      expect(out.url.query, 'PIN=$kMaskInUrl&token=2');
    });
  });

  group('form fields', () {
    ProxieBody form(String s, {String type = kFormType, int? cap}) {
      final bytes = Uint8List.fromList(utf8.encode(s));
      return ProxieBody.from(bytes, type, cap: cap ?? bytes.length);
    }

    test('a sensitive one is masked; other bytes stay', () {
      final out = masking.maskRequest(
        _req(body: form('a=b+c%21&PassWord=hunter%32&user%5Bsecret%5D=x&e')),
      );
      expect(
        out.body.text,
        'a=b+c%21&PassWord=$kMask&user%5Bsecret%5D=$kMask&e',
      );
      expect(out.body.kind, BodyKind.text);
    });

    test('a charset parameter does not hide the type', () {
      final out = masking.maskRequest(
        _req(body: form('token=1', type: '$kFormType; charset=UTF-8')),
      );
      expect(out.body.text, 'token=$kMask');
    });

    test('a truncated form still masks what was kept', () {
      final body = form('token=abcdefghij&a=1', cap: 10);
      expect(body.truncated, isTrue);
      final out = masking.maskRequest(_req(body: body)).body;
      expect(out.text, 'token=$kMask');
      expect(out.truncated, isTrue);
      expect(out.originalLength, 20);
    });

    test('no sensitive field: the same object', () {
      final body = form('a=1&token=');
      expect(
        identical(masking.maskRequest(_req(body: body)).body, body),
        isTrue,
      );
    });

    test('a form field shape in plain text stays', () {
      final body = ProxieBody.from(
        Uint8List.fromList(utf8.encode('password=x')),
        'text/plain',
      );
      expect(
        identical(masking.maskRequest(_req(body: body)).body, body),
        isTrue,
      );
    });
  });

  group('errors and headers holding URLs', () {
    test('an error message keeps its text but not the value', () {
      final out = masking.maskError(
        const ProxieError(
          type: 'network',
          message:
              'Failed, uri=https://a.com/x?a=1&token=abc, later "?secret=z"',
        ),
      );
      expect(out.type, 'network');
      expect(
        out.message,
        'Failed, uri=https://a.com/x?a=1&token=$kMask, later "?secret=$kMask"',
      );
    });

    test('a redirect target is masked, other headers are not', () {
      final out = masking.maskResponse(
        ProxieResponse(
          statusCode: 302,
          headers: {
            'Location': ['https://a.com/cb?code=1&access_token=abc'],
            'X-Note': ['see ?token=abc'],
          },
          body: ProxieBody.empty(),
        ),
      );
      expect(out.headers['location'], [
        'https://a.com/cb?code=1&access_token=$kMask',
      ]);
      expect(out.headers['x-note'], ['see ?token=abc']);
    });
  });

  test('ProxieMasking(headers: {}, jsonKeys: {}) turns all of it off', () {
    const off = ProxieMasking(headers: {}, jsonKeys: {});
    final body = ProxieBody.from(
      Uint8List.fromList(utf8.encode('token=1')),
      kFormType,
    );
    final r = ProxieRequest(
      method: 'POST',
      url: Uri.parse('https://a.com/?token=1'),
      headers: const {
        'authorization': ['x'],
        'referer': ['https://a.com/?token=1'],
      },
      body: body,
    );
    final out = off.maskRequest(r);
    expect(out.url.toString(), 'https://a.com/?token=1');
    expect(out.headers, r.headers);
    expect(identical(out.body, body), isTrue);
    const e = ProxieError(type: 'x', message: 'https://a.com/?token=1');
    expect(off.maskError(e).message, e.message);
  });
}
