import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';

ResponsePreset _preset(String id) =>
    builtInPresets.firstWhere((p) => p.id == id);

void main() {
  test('15 presets with unique ids', () {
    expect(builtInPresets, hasLength(15));
    expect(builtInPresets.map((p) => p.id).toSet(), hasLength(15));
  });

  test('not_found has status 404 and json error body', () {
    final r = _preset('not_found').build(null).response!;
    expect(r.statusCode, 404);
    expect(r.reasonPhrase, 'Not Found');
    expect(r.headers['content-type'], ['application/json']);
    expect(jsonDecode(r.body.text!), {
      'error': {'code': 404, 'message': 'Not Found'},
    });
  });

  test('error presets use the standard reason phrase', () {
    final expected = {
      'bad_request': (400, 'Bad Request'),
      'unauthorized': (401, 'Unauthorized'),
      'forbidden': (403, 'Forbidden'),
      'server_error': (500, 'Internal Server Error'),
      'unavailable': (503, 'Service Unavailable'),
    };
    for (final MapEntry(key: id, value: e) in expected.entries) {
      final r = _preset(id).build(null).response!;
      expect(r.statusCode, e.$1);
      expect(jsonDecode(r.body.text!), {
        'error': {'code': e.$1, 'message': e.$2},
      });
    }
  });

  test('ok_captured with null captured is an empty 200', () {
    final r = _preset('ok_captured').build(null).response!;
    expect(r.statusCode, 200);
    expect(r.body.bytes, isEmpty);
  });

  test('ok_captured and slow copy the captured response', () {
    final captured = ProxieResponse(
      statusCode: 202,
      reasonPhrase: 'Accepted',
      headers: {
        'x-a': ['1'],
      },
      body: ProxieBody.from(
        Uint8List.fromList(utf8.encode('{"a":1}')),
        'application/json',
      ),
    );
    for (final id in ['ok_captured', 'slow']) {
      final r = _preset(id).build(captured).response!;
      expect(r.statusCode, 202);
      expect(r.headers['x-a'], ['1']);
      expect(r.body.text, '{"a":1}');
    }
  });

  test('slow delays 3 s', () {
    expect(_preset('slow').build(null).delay, const Duration(seconds: 3));
  });

  test('fixed presets', () {
    expect(_preset('ok_empty_list').build(null).response!.body.text, '[]');
    expect(_preset('created').build(null).response!.statusCode, 201);
    expect(_preset('created').build(null).response!.body.text, '{}');
    final nc = _preset('no_content').build(null).response!;
    expect(nc.statusCode, 204);
    expect(nc.body.bytes, isEmpty);
    final u = _preset('unprocessable').build(null).response!;
    expect(u.statusCode, 422);
    expect(jsonDecode(u.body.text!), {
      'errors': {
        'field': ['is invalid'],
      },
    });
    final t = _preset('too_many').build(null).response!;
    expect(t.statusCode, 429);
    expect(t.headers['retry-after'], ['30']);
    expect(t.headers['content-type'], ['application/json']);
    expect(jsonDecode(t.body.text!), {
      'error': {'code': 429, 'message': 'Too Many Requests'},
    });
  });

  test('failure presets', () {
    expect(_preset('timeout').build(null).failure, SimulatedFailure.timeout);
    expect(
      _preset('no_connection').build(null).failure,
      SimulatedFailure.noConnection,
    );
    expect(_preset('timeout').build(null).response, isNull);
  });
}
