import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/adapters/io/http_tokens.dart';
import 'package:proxie/src/adapters/io/proxie_http_headers.dart';

void main() {
  late ProxieHttpHeaders h;

  setUp(() => h = ProxieHttpHeaders());

  Map<String, List<String>> each(HttpHeaders headers) {
    final out = <String, List<String>>{};
    headers.forEach((name, values) => out[name] = List.of(values));
    return out;
  }

  test('names are case-insensitive and stored lowercase', () {
    h.add('X-Thing', 'a');
    h.add('x-thing', 'b');
    expect(h['X-THING'], ['a', 'b']);
    expect(each(h), {
      'x-thing': ['a', 'b'],
    });
    expect(h.toMap(), {
      'x-thing': ['a', 'b'],
    });
  });

  test('preserveHeaderCase keeps the spelling for forEach', () {
    h.add('X-Thing', 'a', preserveHeaderCase: true);
    expect(each(h).keys, ['X-Thing']);
    expect(h.originalName('x-thing'), 'X-Thing');
    h.set('x-thing', 'b');
    expect(each(h).keys, ['x-thing']);
  });

  test('value: null when absent, throws on several values', () {
    expect(h.value('a'), isNull);
    h.add('a', '1');
    expect(h.value('A'), '1');
    h.add('a', '2');
    expect(() => h.value('a'), throwsA(isA<HttpException>()));
  });

  test('set replaces; remove one value; removeAll', () {
    h
      ..add('a', '1')
      ..add('a', '2')
      ..set('a', '3');
    expect(h['a'], ['3']);
    h
      ..add('a', '4')
      ..remove('a', '3');
    expect(h['a'], ['4']);
    h.remove('a', '4');
    expect(h['a'], isNull);
    h
      ..add('b', ['1', '2'])
      ..removeAll('B');
    expect(h['b'], isNull);
  });

  test('non-string values: iterable, DateTime, int', () {
    final d = DateTime.utc(2026, 11, 1, 8, 49, 37);
    h
      ..add('x-list', ['a', 'b'])
      ..add('x-date', d)
      ..add('x-int', 7);
    expect(h['x-list'], ['a', 'b']);
    expect(h['x-date'], [HttpDate.format(d)]);
    expect(h['x-int'], ['7']);
  });

  test('contentLength and chunkedTransferEncoding stay in sync', () {
    expect(h.contentLength, -1);
    expect(h.chunkedTransferEncoding, isFalse);
    h.chunkedTransferEncoding = true;
    expect(h['transfer-encoding'], ['chunked']);
    h.contentLength = 5;
    expect(h['content-length'], ['5']);
    expect(h.chunkedTransferEncoding, isFalse);
    expect(h['transfer-encoding'], isNull);
    h.contentLength = -1;
    expect(h['content-length'], isNull);
    expect(h.chunkedTransferEncoding, isTrue);
    h.set('content-length', '012');
    expect(h.contentLength, 12);
    h.add('transfer-encoding', 'chunked');
    expect(h.contentLength, -1);
    expect(() => h.set('content-length', 'x'), throwsA(isA<HttpException>()));
  });

  test('host and port build the host header', () {
    h.host = 'example.com';
    expect(h['host'], ['example.com']);
    h.port = 8080;
    expect(h['host'], ['example.com:8080']);
    h.port = 80;
    expect(h['host'], ['example.com']);
    h.set('host', 'other:9');
    expect(h.host, 'other');
    expect(h.port, 9);
    h.set('host', '[::1]');
    expect(h.host, '[::1]');
    expect(h.port, 80);
    final https = ProxieHttpHeaders(defaultPort: 443)
      ..host = 'a'
      ..port = 443;
    expect(https['host'], ['a']);
  });

  test('contentType, dates', () {
    h.contentType = ContentType.json;
    expect(h.contentType!.mimeType, 'application/json');
    expect(h.contentType!.charset, 'utf-8');
    h.add('content-type', 'text/plain');
    expect(h['content-type'], ['text/plain']);
    h.contentType = null;
    expect(h['content-type'], isNull);
    final d = DateTime.utc(2026, 1, 2, 3, 4, 5);
    h
      ..date = d
      ..expires = d
      ..ifModifiedSince = d;
    expect(h.date, d);
    expect(h.expires, d);
    expect(h.ifModifiedSince, d);
    expect(h['date'], [HttpDate.format(d)]);
    h.date = null;
    expect(h.date, isNull);
    h.set('expires', 'not a date');
    expect(h.expires, isNull);
  });

  test('persistentConnection maps to connection: close', () {
    expect(h.persistentConnection, isTrue);
    h.persistentConnection = false;
    expect(h['connection'], ['close']);
    h.persistentConnection = true;
    expect(h['connection'], isNull);
    h.add('Connection', 'close');
    expect(h.persistentConnection, isFalse);
  });

  test('noFolding and set-cookie print on separate lines', () {
    h
      ..add('a', '1')
      ..add('a', '2')
      ..add('b', '1')
      ..add('b', '2')
      ..add('set-cookie', 'x=1')
      ..add('set-cookie', 'y=2')
      ..noFolding('B');
    expect(h.isNoFolding('b'), isTrue);
    expect(
      h.toString(),
      'a: 1, 2\nb: 1\nb: 2\nset-cookie: x=1\nset-cookie: y=2\n',
    );
  });

  test('clear resets everything', () {
    h
      ..add('a', '1')
      ..contentLength = 3
      ..persistentConnection = false
      ..host = 'x';
    h.clear();
    expect(each(h), isEmpty);
    expect(h.contentLength, -1);
    expect(h.persistentConnection, isTrue);
    expect(h.host, isNull);
  });

  test('invalid names and values throw FormatException', () {
    expect(() => h.add('bad name', 'v'), throwsFormatException);
    expect(() => h.add('a', 'line\r\nbreak'), throwsFormatException);
    expect(() => h.add('a', 'café'), throwsFormatException);
    expect(() => h['bad:name'], throwsFormatException);
  });

  test('received keeps every value and is immutable', () {
    final m = ProxieHttpHeaders.received({
      'set-cookie': ['a=1', 'b=2'],
      'content-length': ['3'],
    });
    expect(m['set-cookie'], ['a=1', 'b=2']);
    expect(m.contentLength, 3);
    expect(() => m.add('x', '1'), throwsA(isA<HttpException>()));
    expect(() => m.clear(), throwsA(isA<HttpException>()));
  });

  test('freeze makes headers immutable', () {
    h.freeze();
    expect(() => h.set('x', '1'), throwsA(isA<HttpException>()));
    expect(() => h.contentLength = 1, throwsA(isA<HttpException>()));
  });

  test('headersToMap merges spellings and keeps values separate', () {
    h
      ..add('X-A', '1', preserveHeaderCase: true)
      ..add('set-cookie', 'a=1')
      ..add('set-cookie', 'b=2');
    expect(headersToMap(h), {
      'x-a': ['1'],
      'set-cookie': ['a=1', 'b=2'],
    });
  });

  test('DEL (0x7F) is a valid value character, as in dart:io', () {
    h.add('a', 'x\u007fy');
    expect(h['a'], ['x\u007fy']);
  });

  test('received headers accept any byte but CR, LF and NUL', () {
    final r = ProxieHttpHeaders.received({
      'content-disposition': ['cafÃ©'],
      'content-type': ['text/plain', 'application/json'],
      'date': ['a', 'b'],
    });
    expect(r['content-disposition'], ['cafÃ©']);
    expect(r['content-type'], ['text/plain', 'application/json']);
    expect(r.contentType!.mimeType, 'text/plain');
    expect(r['date'], ['a', 'b']);
    expect(() => r.add('x', '1'), throwsA(isA<HttpException>()));
    for (final bad in ['a\rb', 'a\nb', 'a\u0000b']) {
      expect(
        () => ProxieHttpHeaders.received({
          'x': [bad],
        }),
        throwsFormatException,
      );
    }
  });
}
