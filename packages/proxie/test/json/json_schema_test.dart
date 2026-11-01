import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

JsonDocument _doc(String s) =>
    JsonDocument.tryParse(Uint8List.fromList(utf8.encode(s)));

/// Schema of the root array.
ArraySchema? _rootSchema(String s) => _doc(s).schemaOf(0);

void main() {
  test('brief example', () {
    const input = '[{"id":1,"name":"a"},{"id":2,"name":null,"avatar":"x"}]';
    final doc = _doc(input);
    final schema = doc.schemaOf(0)!;
    expect(
      schema.describe(),
      '{id: number, name: string|null, avatar?: string}',
    );
    expect(schema.toString(), schema.describe());

    final rows = doc.rows(0, 2);
    expect(rows[0].missingKeys, ['avatar']);
    expect(rows[1].missingKeys, isEmpty);

    final [id, name, avatar] = schema.fields;
    expect(id.key, 'id');
    expect(id.kinds, {JsonKind.number});
    expect((id.presentIn, id.total, id.optional), (2, 2, false));
    expect(name.kinds.toList(), [JsonKind.string, JsonKind.nullValue]);
    expect(name.optional, isFalse);
    expect((avatar.presentIn, avatar.total, avatar.optional), (1, 2, true));
  });

  test('arrays without objects have no schema', () {
    expect(_rootSchema('[1,"a",null,[{"x":1}]]'), isNull);
    expect(_rootSchema('[]'), isNull);
  });

  test('non-array nodes have no schema', () {
    final doc = _doc('{"a":{"b":1},"c":[{"d":1}]}');
    expect(doc.schemaOf(0), isNull);
    expect(doc.schemaOf(doc.rows(0, 1).single.nodeId), isNull);
    final c = doc.rows(1, 1).single;
    expect(doc.schemaOf(c.nodeId)!.describe(), '{d: number}');
    expect(() => doc.schemaOf(99), throwsRangeError);
    expect(_doc('7').schemaOf(0), isNull);
  });

  test('mixed arrays are inferred from their objects only', () {
    final doc = _doc('[{"a":1},2,{"a":"x","b":true},null]');
    final schema = doc.schemaOf(0)!;
    expect(schema.describe(), '{a: number|string, b?: boolean}');
    expect(schema.fields.first.total, 2);
    final rows = doc.rows(0, 4);
    expect(
      [for (final r in rows) r.missingKeys],
      [
        ['b'],
        <String>[],
        <String>[],
        <String>[],
      ],
    );
  });

  test('fields and kinds keep first-seen order', () {
    expect(
      _rootSchema('[{"b":1},{"a":1,"b":2}]')!.describe(),
      '{b: number, a?: number}',
    );
    expect(
      _rootSchema(
        '[{"v":{}},{"v":[]},{"v":"s"},{"v":1},{"v":true},{"v":null},{"v":2}]',
      )!.describe(),
      '{v: object|array|string|number|boolean|null}',
    );
  });

  test('a duplicate key counts once per object', () {
    final doc = _doc('[{"a":1,"a":"x"},{"b":1}]');
    final schema = doc.schemaOf(0)!;
    expect(schema.describe(), '{a?: number|string, b?: number}');
    expect(schema.fields.first.presentIn, 1);
    expect(doc.rows(0, 1).single.missingKeys, ['b']);
  });

  test('empty objects give an empty schema', () {
    final schema = _rootSchema('[{},{}]')!;
    expect(schema.fields, isEmpty);
    expect(schema.describe(), '{}');
  });

  test('missingKeys follow the schema field order', () {
    final doc = _doc('[{"a":1,"b":2,"c":3},{"c":1},{}]');
    final rows = doc.rows(0, 3);
    expect(rows[0].missingKeys, isEmpty);
    expect(rows[1].missingKeys, ['a', 'b']);
    expect(rows[2].missingKeys, ['a', 'b', 'c']);
  });

  test('rows outside arrays and nested rows get no missingKeys', () {
    final doc = _doc('{"o":{"x":1},"l":[{"a":{"p":1}},{"b":2}]}');
    doc.expandAll();
    final byPath = {
      for (final r in doc.rows(0, doc.visibleCount))
        doc.pathOf(r.nodeId).join('/'): r.missingKeys,
    };
    expect(byPath, {
      'o': isEmpty,
      'o/x': isEmpty,
      'l': isEmpty,
      'l/0': ['b'],
      'l/0/a': isEmpty,
      'l/0/a/p': isEmpty,
      'l/1': ['a'],
      'l/1/b': isEmpty,
    });
  });

  test('schemas are cached until an edit changes the items', () {
    final doc = _doc('[{"a":1},{"a":2}]');
    final first = doc.schemaOf(0);
    expect(doc.schemaOf(0), same(first));
    // Toggling and reading rows keep the cache.
    doc.toggle(doc.rows(0, 1).single.nodeId);
    doc.rows(0, 3);
    expect(doc.schemaOf(0), same(first));
    doc.apply(const AddItem(0, {'a': 3}));
    final second = doc.schemaOf(0);
    expect(second, isNot(same(first)));
    expect(second!.describe(), first!.describe());
    expect(doc.schemaOf(0), same(second));
  });

  test('fields and kinds are unmodifiable', () {
    final schema = _rootSchema('[{"a":1}]')!;
    expect(() => schema.fields.clear(), throwsUnsupportedError);
    expect(
      () => schema.fields.single.kinds.add(JsonKind.string),
      throwsUnsupportedError,
    );
  });
}
