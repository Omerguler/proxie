import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

Uint8List _u(List<int> b) => Uint8List.fromList(b);
Uint8List _s(String s) => _u(utf8.encode(s));

void main() {
  group('classifyBody', () {
    test('empty bytes are empty', () {
      expect(classifyBody(Uint8List(0), 'application/json'), BodyKind.empty);
    });

    test('json content types', () {
      expect(classifyBody(_s('{"a":1}'), 'application/json'), BodyKind.json);
      expect(
        classifyBody(_s('{"a":1}'), 'application/vnd.api+json; charset=utf-8'),
        BodyKind.json,
      );
    });

    test('text/plain utf-8 is text', () {
      expect(classifyBody(_s('héllo'), 'text/plain'), BodyKind.text);
    });

    test('image magic bytes win over octet-stream', () {
      final png = _u([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
      expect(classifyBody(png, 'application/octet-stream'), BodyKind.image);
      expect(classifyBody(_u([0xff, 0xd8, 0xff, 0xe0]), null), BodyKind.image);
      expect(classifyBody(_s('GIF89a....'), null), BodyKind.image);
      expect(
        classifyBody(_s('RIFF\x00\x00\x00\x00WEBPVP8 '), null),
        BodyKind.image,
      );
    });

    test('json content type with non-UTF-8 bytes is binary', () {
      expect(
        classifyBody(_u([0xff, 0xfe, 0x00]), 'application/json'),
        BodyKind.binary,
      );
    });

    test('no content type: NUL in first 512 bytes is binary', () {
      expect(classifyBody(_u([0x41, 0x00, 0x42]), null), BodyKind.binary);
    });

    test('no content type: sniffs json and text', () {
      expect(classifyBody(_s('  \n{"a":1}'), null), BodyKind.json);
      expect(classifyBody(_s('[1,2]'), null), BodyKind.json);
      expect(classifyBody(_s('hello'), null), BodyKind.text);
      expect(classifyBody(_u([0xc3, 0x28]), null), BodyKind.binary);
    });

    test('image content type with non-image bytes is binary', () {
      expect(classifyBody(_s('nope'), 'image/png'), BodyKind.binary);
    });
  });

  group('ProxieBody.from', () {
    test('truncates to cap and records the original length', () {
      const mb = 1024 * 1024;
      final big = Uint8List(6 * mb)..fillRange(0, 6 * mb, 0x61);
      final b = ProxieBody.from(big, 'text/plain', cap: 5 * mb);
      expect(b.bytes.length, 5 * mb);
      expect(b.truncated, isTrue);
      expect(b.originalLength, 6 * mb);
      expect(b.kind, BodyKind.text);
      expect(b.contentType, 'text/plain');
    });

    test('truncation keeps text on a UTF-8 character boundary', () {
      // 3-byte characters; cap 10 falls inside the fourth one.
      final bytes = _s('€' * 10);
      final b = ProxieBody.from(bytes, 'text/plain', cap: 10);
      expect(b.truncated, isTrue);
      expect(b.originalLength, 30);
      expect(b.bytes.length <= 10 && b.bytes.length > 10 - 4, isTrue);
      expect(b.text, '€€€');
      expect(b.kind, BodyKind.text);
    });

    test('under the cap is untouched', () {
      final b = ProxieBody.from(_s('{"a":1}'), 'application/json');
      expect(b.truncated, isFalse);
      expect(b.originalLength, 7);
      expect(b.kind, BodyKind.json);
    });
  });
}
