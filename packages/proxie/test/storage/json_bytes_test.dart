import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/storage/json_bytes.dart';

void main() {
  test('byte buffers round-trip as base64', () {
    final bytes = Uint8List.fromList([0, 1, 255, 128]);
    final json = encodeJsonBytes({
      'a': bytes,
      'list': [bytes, 1],
    });
    expect(json, isNot(contains('255')));
    final back = decodeJsonBytes(json)! as Map;
    expect(back['a'], isA<Uint8List>());
    expect(back['a'], orderedEquals(bytes));
    expect((back['list'] as List).first, orderedEquals(bytes));
    expect((back['list'] as List).last, 1);
  });

  test('maps that look like the marker round-trip unchanged', () {
    final value = {
      r'$bytes': 'AAAA',
      'one': {r'$bytes': 'AAAA'},
      'nul': {'\u0000proxie_bytes': 'AAAA'},
      'nul2': {'\u0000\u0000x': 'y', '\u0000': 1},
    };
    expect(decodeJsonBytes(encodeJsonBytes(value)), value);
  });

  test('malformed base64 throws a FormatException', () {
    expect(
      () => decodeJsonBytes('{"\\u0000proxie_bytes":"!!"}'),
      throwsFormatException,
    );
  });
}
