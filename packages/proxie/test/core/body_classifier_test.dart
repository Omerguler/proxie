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

    test('GIF magic needs the full GIF87a / GIF89a signature', () {
      expect(classifyBody(_s('GIF87a....'), null), BodyKind.image);
      expect(classifyBody(_s('GIF8 hello'), null), BodyKind.text);
    });

    test('application/xml and image/svg+xml are text', () {
      expect(classifyBody(_s('<a/>'), 'application/xml'), BodyKind.text);
      expect(classifyBody(_s('<svg/>'), 'image/svg+xml'), BodyKind.text);
    });

    test('unknown content type falls back to sniffing', () {
      expect(classifyBody(_s('{"a":1}'), 'application/x-weird'), BodyKind.json);
      expect(classifyBody(_s('hello'), 'application/x-weird'), BodyKind.text);
      expect(
        classifyBody(_u([0xc3, 0x28]), 'application/x-weird'),
        BodyKind.binary,
      );
    });

    test('latin1 charset text is text even when not valid UTF-8', () {
      final bytes = _u([0x63, 0x61, 0x66, 0xe9]); // "cafe" + e-acute
      expect(
        classifyBody(bytes, 'text/plain; charset=iso-8859-1'),
        BodyKind.text,
      );
      expect(classifyBody(bytes, 'text/plain; charset=latin1'), BodyKind.text);
      expect(classifyBody(bytes, 'text/plain'), BodyKind.binary);
    });

    test('sniff window tolerates only a valid incomplete tail', () {
      // 511 ASCII bytes + first two bytes of a 3-byte char: window cut.
      final cutOk = _u([...List.filled(510, 0x61), 0xe2, 0x82, 0x61, 0x61]);
      // Window is 512 bytes: ...e2 82 at the end (valid prefix of U+20AC).
      expect(classifyBody(cutOk, null), BodyKind.text);
      // Invalid bytes at the end of the window are not forgiven.
      final bad = _u([...List.filled(510, 0x61), 0xff, 0xff, 0x61, 0x61]);
      expect(classifyBody(bad, null), BodyKind.binary);
      // A lead byte followed by an ASCII byte is not a valid prefix.
      final bad2 = _u([...List.filled(510, 0x61), 0xe2, 0x61, 0x61, 0x61]);
      expect(classifyBody(bad2, null), BodyKind.binary);
      // C0 never starts a valid sequence.
      final bad3 = _u([...List.filled(511, 0x61), 0xc0, 0x61]);
      expect(classifyBody(bad3, null), BodyKind.binary);
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

    test('sniffed text that is invalid UTF-8 past the window is binary', () {
      final bytes = _u([...List.filled(600, 0x61), 0xff, 0x61]);
      final b = ProxieBody.from(bytes, null);
      expect(b.kind, BodyKind.binary);
      expect(b.text, isNull);
    });

    test('declared utf-8 validation only covers the kept bytes', () {
      // Invalid byte beyond the cap does not affect the kept prefix.
      final bytes = _u([...List.filled(100, 0x61), 0xff]);
      final b = ProxieBody.from(bytes, 'text/plain', cap: 50);
      expect(b.kind, BodyKind.text);
      expect(b.bytes.length, 50);
      expect(b.truncated, isTrue);
    });

    test('latin1 charset decodes text with latin1', () {
      final b = ProxieBody.from(
        _u([0x63, 0x61, 0x66, 0xe9]),
        'text/plain; charset=ISO-8859-1',
      );
      expect(b.kind, BodyKind.text);
      expect(b.text, 'café');
      final back = ProxieBody.fromMap(b.toMap());
      expect(back.text, 'café');
    });

    test('under the cap is untouched', () {
      final b = ProxieBody.from(_s('{"a":1}'), 'application/json');
      expect(b.truncated, isFalse);
      expect(b.originalLength, 7);
      expect(b.kind, BodyKind.json);
    });
  });

  group('follow-ups', () {
    test('latin1 truncation keeps 0x80-0xBF characters', () {
      // 0xA9 (copyright sign) is valid latin1 and looks like a continuation.
      final bytes = _u([0x61, 0x62, 0xa9, 0xa9, 0xa9, 0x63]);
      final b = ProxieBody.from(bytes, 'text/plain; charset=latin1', cap: 4);
      expect(b.bytes.length, 4);
      expect(b.text, 'ab©©');
    });

    test('sniff honours the caller mayBeCut flag', () {
      // Whole input shorter than the window, but known to be a prefix.
      final cut = _u([0x61, 0xe2, 0x82]);
      expect(classifyBody(cut, null), BodyKind.binary);
      expect(classifyBody(cut, null, mayBeCut: true), BodyKind.text);
      // Through ProxieBody.from with a tiny cap.
      final bytes = _u([0x61, 0xe2, 0x82, 0xac, 0x62]);
      final b = ProxieBody.from(bytes, null, cap: 3);
      expect(b.kind, BodyKind.text);
      expect(b.text, 'a');
    });

    test('from stores an owned copy of the bytes', () {
      final src = _s('hello');
      final b = ProxieBody.from(src, 'text/plain');
      src[0] = 0x58;
      expect(b.text, 'hello');
    });

    test('toMap returns a copy of the bytes', () {
      final b = ProxieBody.from(_s('hello'), 'text/plain');
      (b.toMap()['bytes'] as Uint8List)[0] = 0x58;
      expect(b.text, 'hello');
    });
  });
}
