@Tags(['perf'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

const _items = 40000;
const _targetBytes = 10 * 1024 * 1024;

/// A ~10 MB JSON array of [_items] objects.
String _bigArray() {
  final pad = 'lorem ipsum dolor sit amet ' * 4;
  final b = StringBuffer('[');
  for (var i = 0; i < _items; i++) {
    if (i > 0) b.write(',');
    b.write(
      jsonEncode({
        'id': i,
        'name': 'User $i',
        'email': 'user$i@example.com',
        'active': i.isEven,
        'score': i / 7,
        'tags': ['a', 'b', if (i % 3 == 0) 'c'],
        'address': {'city': 'City ${i % 100}', 'zip': '${10000 + i}'},
        if (i % 5 == 0) 'avatar': null,
        'bio': pad,
      }),
    );
  }
  b.write(']');
  return b.toString();
}

int _time(void Function() body) {
  final sw = Stopwatch()..start();
  body();
  return sw.elapsedMicroseconds;
}

String _ms(int micros) => '${(micros / 1000).toStringAsFixed(2)} ms';

void main() {
  late Uint8List bytes;

  setUpAll(() {
    bytes = Uint8List.fromList(utf8.encode(_bigArray()));
    expect(bytes.length, greaterThan(_targetBytes));
  });

  test('tryParse a 10 MB array of 40k objects < 1500 ms', () {
    late JsonDocument doc;
    final t = _time(() => doc = JsonDocument.tryParse(bytes));
    // ignore: avoid_print
    print('tryParse ${bytes.length} bytes: ${_ms(t)}');
    expect(doc.parseError, isNull);
    expect(doc.visibleCount, _items);
    expect(t, lessThan(1500 * 1000));
  });

  test('rows(20000, 60) < 5 ms', () {
    final doc = JsonDocument.tryParse(bytes);
    // Cold: the first page after opening, then a jump to the middle.
    final first = _time(() => doc.rows(0, 60));
    late List<JsonRow> rows;
    final jump = _time(() => rows = doc.rows(20000, 60));
    expect(rows.first.index, 20000);
    expect(rows, hasLength(60));
    // Deep: everything expanded, window in the middle of nested rows.
    doc.expandAll();
    final mid = doc.visibleCount ~/ 2;
    final deep = _time(() => rows = doc.rows(mid, 60));
    expect(rows, hasLength(60));
    final deepWarm = _time(() => doc.rows(mid + 1000, 60));
    // ignore: avoid_print
    print(
      'rows(0,60) cold: ${_ms(first)}; rows(20000,60): ${_ms(jump)}; '
      'expanded (${doc.visibleCount} rows) rows($mid,60): ${_ms(deep)}, '
      'next window: ${_ms(deepWarm)}',
    );
    // The first page also infers the root array's schema (for missingKeys).
    expect(first, lessThan(50 * 1000));
    expect(jump, lessThan(5 * 1000));
    expect(deep, lessThan(5 * 1000));
    expect(deepWarm, lessThan(5 * 1000));
  });

  test('schemaOf a 40k-object array', () {
    final doc = JsonDocument.tryParse(bytes);
    late ArraySchema? schema;
    final cold = _time(() => schema = doc.schemaOf(0));
    final cached = _time(() => doc.schemaOf(0));
    // ignore: avoid_print
    print('schemaOf(40k objects): ${_ms(cold)}; cached: ${_ms(cached)}');
    expect(
      schema!.describe(),
      '{id: number, name: string, email: string, active: boolean, '
      'score: number, tags: array, address: object, avatar?: null, '
      'bio: string}',
    );
    expect(cold, lessThan(50 * 1000));
  });

  test('toggle on a 40k-child array < 50 ms', () {
    // The same array one level down, so it is a row that can be toggled.
    final wrapped = Uint8List(bytes.length + 10)
      ..setAll(0, utf8.encode('{"items":'))
      ..setAll(9, bytes)
      ..[bytes.length + 9] = 0x7d; // }
    final doc = JsonDocument.tryParse(wrapped);
    expect(doc.parseError, isNull);
    final items = doc.rows(0, 1).single;
    expect(items.childCount, _items);

    final expand = _time(() => doc.toggle(items.nodeId));
    expect(doc.visibleCount, _items + 1);
    late List<JsonRow> rows;
    final page = _time(() => rows = doc.rows(20000, 60));
    expect(rows.first.index, 19999);
    // Toggle an item inside the big array, then page past it.
    final inner = _time(() => doc.toggle(rows.first.nodeId));
    final innerPage = _time(() => doc.rows(30000, 60));
    final collapse = _time(() => doc.toggle(items.nodeId));
    expect(doc.visibleCount, 1);
    // ignore: avoid_print
    print(
      'toggle expand: ${_ms(expand)}; rows after: ${_ms(page)}; '
      'toggle item: ${_ms(inner)}; rows after: ${_ms(innerPage)}; '
      'collapse: ${_ms(collapse)}',
    );
    expect(expand, lessThan(50 * 1000));
    expect(inner, lessThan(50 * 1000));
    expect(collapse, lessThan(50 * 1000));
    expect(page, lessThan(50 * 1000));
    expect(innerPage, lessThan(50 * 1000));
  });
}
