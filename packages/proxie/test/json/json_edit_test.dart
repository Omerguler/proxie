import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

JsonDocument _doc(String s) => JsonDocument.tryParse(_bytes(s));

String _enc(JsonDocument doc, {bool pretty = false}) =>
    utf8.decode(doc.encode(pretty: pretty));

/// Node id of the value at [path] (member names and indices from the root),
/// found by expanding the containers on the way.
int _node(JsonDocument doc, List<Object> path) {
  var id = -1;
  var row = 0;
  for (var i = 0; i < path.length; i++) {
    if (i > 0) {
      final r = doc.rows(row, 1).single;
      if (!r.expanded) doc.toggle(r.nodeId);
      row++;
    }
    while (true) {
      final r = doc.rows(row, 1).single;
      final depth = i;
      if (r.depth == depth && (r.key ?? r.index) == path[i]) {
        id = r.nodeId;
        break;
      }
      row++;
    }
  }
  return id;
}

/// Every visible row, labelled with everything a view shows.
List<String> _labels(JsonDocument doc) => [
  for (final r in doc.rows(0, doc.visibleCount))
    '${r.depth} ${r.key ?? (r.index == null ? '-' : '[${r.index}]')} '
        '${r.kind.name} ${r.preview} ${r.childCount} ${r.expanded} '
        '${r.missingKeys}',
];

/// Checks the incremental counts and caches of [doc] against a fresh parse of
/// its own output with the same rows opened: same rows, previews, missing
/// keys, and windows that agree with the full listing.
void _checkConsistent(JsonDocument doc) {
  final fresh = _doc(_enc(doc));
  final rows = doc.rows(0, doc.visibleCount);
  expect(rows, hasLength(doc.visibleCount));
  for (var i = 0; i < rows.length; i++) {
    if (!rows[i].expanded) continue;
    final f = fresh.rows(i, 1).single;
    expect(doc.pathOf(rows[i].nodeId), fresh.pathOf(f.nodeId));
    if (!f.expanded) fresh.toggle(f.nodeId);
  }
  expect(_labels(doc), _labels(fresh));
  expect(doc.nodeCount, fresh.nodeCount);
  final ids = [for (final r in rows) r.nodeId];
  for (var start = 0; start < ids.length; start += 7) {
    expect(
      [for (final r in doc.rows(start, 5)) r.nodeId],
      [...ids.skip(start).take(5)],
    );
  }
}

void main() {
  group('brief examples', () {
    test('DuplicateItem copies an item after itself', () {
      final doc = _doc('[{"id":1}]');
      expect(doc.apply(DuplicateItem(_node(doc, [0]))), 2);
      expect(_enc(doc), '[{"id":1},{"id":1}]');
      _checkConsistent(doc);
    });

    test('AddMissingKey copies the first sibling scalar', () {
      final doc = _doc('[{"id":1},{"id":2,"avatar":"x"}]');
      expect(doc.rows(0, 1).single.missingKeys, ['avatar']);
      doc.apply(AddMissingKey(_node(doc, [0]), 'avatar'));
      expect(_enc(doc), '[{"id":1,"avatar":"x"},{"id":2,"avatar":"x"}]');
      expect(doc.rows(0, 1).single.missingKeys, isEmpty);
      _checkConsistent(doc);
    });

    test('NewItemFromSchema appends type defaults', () {
      final doc = _doc('[{"id":1,"ok":true}]');
      expect(doc.apply(const NewItemFromSchema(0)), 2);
      expect(_enc(doc), '[{"id":1,"ok":true},{"id":0,"ok":false}]');
      _checkConsistent(doc);
    });

    test('RenameKey to an existing key throws ArgumentError', () {
      final doc = _doc('{"a":1,"b":2}');
      expect(
        () => doc.apply(RenameKey(_node(doc, ['a']), 'b')),
        throwsArgumentError,
      );
      expect(_enc(doc), '{"a":1,"b":2}');
      expect(doc.dirty, isFalse);
    });

    test('AddKeyToAll invalidates the schema cache', () {
      final doc = _doc('[{"id":1},{"id":2,"x":true}]');
      expect(doc.schemaOf(0)!.describe(), '{id: number, x?: boolean}');
      doc.apply(const AddKeyToAll(0, 'x', false));
      expect(_enc(doc), '[{"id":1,"x":false},{"id":2,"x":true}]');
      expect(doc.schemaOf(0)!.describe(), '{id: number, x: boolean}');
      expect(doc.rows(0, 1).single.missingKeys, isEmpty);
      _checkConsistent(doc);
    });
  });

  group('SetValue', () {
    test('replaces scalars with scalars of any kind', () {
      final doc = _doc('[1,"a",true,null]');
      doc
        ..apply(SetValue(_node(doc, [0]), 'x"\n😀'))
        ..apply(SetValue(_node(doc, [1]), 2.5))
        ..apply(SetValue(_node(doc, [2]), null))
        ..apply(SetValue(_node(doc, [3]), false));
      expect(_enc(doc), r'["x\"\n😀",2.5,null,false]');
      expect(
        [for (final r in doc.rows(0, 4)) r.preview],
        [r'"x\"\n😀"', '2.5', 'null', 'false'],
      );
      expect(doc.dirty, isTrue);
      _checkConsistent(doc);
    });

    test('numbers are stored as validated lexemes', () {
      final doc = _doc('[0,0,0,0]');
      doc
        ..apply(SetValue(_node(doc, [0]), 12))
        ..apply(
          SetValue(_node(doc, [1]), const JsonNumber('12345678901234567890')),
        )
        ..apply(SetValue(_node(doc, [2]), const JsonNumber('-0.10e+5')))
        ..apply(SetValue(_node(doc, [3]), 1e300));
      expect(_enc(doc), '[12,12345678901234567890,-0.10e+5,1e+300]');
      for (final bad in ['', '01', '1.', '.5', '+1', '1e', 'NaN', '0x10']) {
        expect(
          () => doc.apply(SetValue(_node(doc, [0]), JsonNumber(bad))),
          throwsArgumentError,
          reason: bad,
        );
      }
      for (final bad in [double.nan, double.infinity, -double.infinity]) {
        expect(
          () => doc.apply(SetValue(_node(doc, [0]), bad)),
          throwsArgumentError,
        );
      }
      expect(_enc(doc), '[12,12345678901234567890,-0.10e+5,1e+300]');
    });

    test('a scalar can become an empty or a full container', () {
      final doc = _doc('{"a":1,"b":2,"c":3}');
      doc
        ..apply(SetValue(_node(doc, ['a']), const <String, Object?>{}))
        ..apply(SetValue(_node(doc, ['b']), const []))
        ..apply(
          SetValue(_node(doc, ['c']), {
            'x': [1, 'two', null],
            'y': {'z': true},
          }),
        );
      expect(
        _enc(doc),
        '{"a":{},"b":[],"c":{"x":[1,"two",null],"y":{"z":true}}}',
      );
      final c = doc.rows(2, 1).single;
      expect(c.preview, '{2 keys}');
      expect(c.expanded, isFalse);
      doc.toggle(c.nodeId);
      expect(doc.visibleCount, 5);
      _checkConsistent(doc);
    });

    test('replacing an open container keeps it open with new children', () {
      final doc = _doc('{"a":[1,[2,3]],"b":0}');
      final a = _node(doc, ['a']);
      doc.toggle(_node(doc, ['a', 1]));
      expect(doc.visibleCount, 6);
      final before = doc.nodeCount;
      expect(doc.apply(SetValue(a, ['x'])), 3);
      expect(doc.nodeCount, before - 3);
      expect(_enc(doc), '{"a":["x"],"b":0}');
      expect(doc.rows(0, 1).single.expanded, isTrue);
      _checkConsistent(doc);
      // Back to a scalar: no longer expandable.
      expect(doc.apply(SetValue(a, 's')), 2);
      expect(doc.rows(0, 1).single.expanded, isFalse);
      doc.toggle(a);
      expect(doc.visibleCount, 2);
      _checkConsistent(doc);
    });

    test('the root can be replaced', () {
      final doc = _doc('[1,2]');
      expect(doc.apply(const SetValue(0, 'only')), 1);
      expect(_enc(doc), '"only"');
      expect(doc.rows(0, 1).single.preview, '"only"');
      expect(doc.apply(const SetValue(0, {'k': 1})), 1);
      expect(_enc(doc), '{"k":1}');
      _checkConsistent(doc);
    });

    test('rejects unsupported values without changing anything', () {
      final doc = _doc('[0]');
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      for (final bad in <Object?>[
        DateTime(2026),
        {1: 'x'},
        [Object()],
        cyclic,
      ]) {
        expect(
          () => doc.apply(SetValue(_node(doc, [0]), bad)),
          throwsArgumentError,
        );
      }
      expect(doc.dirty, isFalse);
      expect(_enc(doc), '[0]');
    });

    test('values nested 100k deep are built without recursion', () {
      Object? v = 1;
      for (var i = 0; i < 100000; i++) {
        v = [v];
      }
      final doc = _doc('[0]');
      doc.apply(SetValue(_node(doc, [0]), v));
      expect(doc.nodeCount, 100002);
      final out = _enc(doc);
      expect(out, '[${'[' * 100000}1${']' * 100000}]');
    });
  });

  group('RenameKey', () {
    test('renames in place and re-encodes the name', () {
      final doc = _doc('{"a":1,"b":2}');
      doc.apply(RenameKey(_node(doc, ['a']), 'new\t"'));
      expect(_enc(doc), r'{"new\t\"":1,"b":2}');
      expect(doc.rows(0, 1).single.key, 'new\t"');
      _checkConsistent(doc);
    });

    test('renaming to the same name changes nothing', () {
      final doc = _doc('{"a":1,"a":2}');
      doc.apply(RenameKey(doc.rows(1, 1).single.nodeId, 'a'));
      expect(doc.dirty, isFalse);
      doc.apply(RenameKey(doc.rows(1, 1).single.nodeId, 'b'));
      expect(_enc(doc), '{"a":1,"b":2}');
    });

    test('only object members can be renamed', () {
      final doc = _doc('{"a":[1]}');
      expect(() => doc.apply(const RenameKey(0, 'x')), throwsArgumentError);
      expect(
        () => doc.apply(RenameKey(_node(doc, ['a', 0]), 'x')),
        throwsArgumentError,
      );
    });

    test('renaming a member of an array item refreshes the schema', () {
      final doc = _doc('[{"a":1},{"a":2}]');
      expect(doc.schemaOf(0)!.describe(), '{a: number}');
      doc.apply(RenameKey(_node(doc, [0, 'a']), 'b'));
      expect(doc.schemaOf(0)!.describe(), '{b?: number, a?: number}');
      _checkConsistent(doc);
    });
  });

  group('DeleteNode', () {
    test('deletes members and items; later items are renumbered', () {
      final doc = _doc('{"a":[1,2,3],"b":{"c":true}}');
      final b = _node(doc, ['b']);
      final two = _node(doc, ['a', 1]);
      expect(doc.apply(DeleteNode(two)), 4);
      expect(_enc(doc), '{"a":[1,3],"b":{"c":true}}');
      expect([for (final r in doc.rows(1, 2)) r.index], [0, 1]);
      expect(doc.pathOf(doc.rows(2, 1).single.nodeId), ['a', 1]);
      doc.apply(DeleteNode(b));
      expect(_enc(doc), '{"a":[1,3]}');
      expect(doc.nodeCount, 4);
      _checkConsistent(doc);
    });

    test('deleted nodes are rejected everywhere', () {
      final doc = _doc('[[1],2]');
      final inner = _node(doc, [0]);
      doc.toggle(inner);
      final one = _node(doc, [0, 0]);
      doc.apply(DeleteNode(inner));
      for (final id in [inner, one]) {
        expect(() => doc.apply(DeleteNode(id)), throwsArgumentError);
        expect(() => doc.toggle(id), throwsArgumentError);
        expect(() => doc.pathOf(id), throwsArgumentError);
        expect(() => doc.schemaOf(id), throwsArgumentError);
      }
      expect(() => doc.apply(const DeleteNode(99)), throwsArgumentError);
      expect(() => doc.apply(const DeleteNode(-1)), throwsArgumentError);
      // expandAll / collapseAll skip the deleted subtree.
      doc.expandAll();
      expect(doc.visibleCount, 1);
      doc.collapseAll();
      expect(_labels(doc), ['0 [0] number 2 0 false []']);
    });

    test('the root cannot be deleted', () {
      final doc = _doc('[1]');
      expect(() => doc.apply(const DeleteNode(0)), throwsArgumentError);
    });

    test('deleting the last member of an array item updates missingKeys', () {
      final doc = _doc('[{"a":1},{"a":2,"b":3}]');
      expect(doc.rows(0, 1).single.missingKeys, ['b']);
      doc.apply(DeleteNode(_node(doc, [1, 'b'])));
      expect(doc.rows(0, 2).first.missingKeys, isEmpty);
      _checkConsistent(doc);
    });
  });

  group('AddKey / AddItem', () {
    test('AddKey appends a member', () {
      final doc = _doc('{"a":{}}');
      final a = _node(doc, ['a']);
      expect(doc.apply(AddKey(a, 'k', [1, 2])), 1);
      doc.apply(const AddKey(0, 'z', null));
      expect(_enc(doc), '{"a":{"k":[1,2]},"z":null}');
      doc.toggle(a);
      expect(doc.visibleCount, 3);
      _checkConsistent(doc);
    });

    test('AddKey rejects an existing name and non-objects', () {
      final doc = _doc('{"a":[1]}');
      expect(() => doc.apply(const AddKey(0, 'a', 1)), throwsArgumentError);
      expect(
        () => doc.apply(AddKey(_node(doc, ['a']), 'b', 1)),
        throwsArgumentError,
      );
    });

    test('AddItem appends or inserts at an index', () {
      final doc = _doc('[1,2]');
      expect(doc.apply(const AddItem(0, 3)), 3);
      doc
        ..apply(const AddItem(0, 0, at: 0))
        ..apply(const AddItem(0, 1.5, at: 2));
      expect(_enc(doc), '[0,1,1.5,2,3]');
      expect([for (final r in doc.rows(0, 5)) r.index], [0, 1, 2, 3, 4]);
      _checkConsistent(doc);
    });

    test('AddItem rejects bad indices and non-arrays', () {
      final doc = _doc('{"a":[1]}');
      final a = _node(doc, ['a']);
      expect(() => doc.apply(AddItem(a, 0, at: 2)), throwsRangeError);
      expect(() => doc.apply(AddItem(a, 0, at: -1)), throwsRangeError);
      expect(() => doc.apply(const AddItem(0, 1)), throwsArgumentError);
      expect(doc.dirty, isFalse);
    });

    test('items added to an array of objects refresh its schema', () {
      final doc = _doc('[{"a":1}]');
      expect(doc.schemaOf(0)!.describe(), '{a: number}');
      doc.apply(const AddItem(0, {'b': 'x'}));
      expect(doc.schemaOf(0)!.describe(), '{a?: number, b?: string}');
      expect(
        [for (final r in doc.rows(0, 2)) r.missingKeys],
        [
          ['b'],
          ['a'],
        ],
      );
      _checkConsistent(doc);
    });
  });

  group('DuplicateItem', () {
    test('copies nested values, edits and escapes', () {
      final doc = _doc(r'[{"a":[1.50,{"b":"x\n"}]},7]');
      doc.apply(SetValue(_node(doc, [0, 'a', 1, 'b']), 'edited'));
      doc.apply(DuplicateItem(_node(doc, [0])));
      expect(
        _enc(doc),
        '[{"a":[1.50,{"b":"edited"}]},{"a":[1.50,{"b":"edited"}]},7]',
      );
      // The copy is independent of the original.
      doc.apply(SetValue(_node(doc, [1, 'a', 0]), 2));
      expect(
        _enc(doc),
        '[{"a":[1.50,{"b":"edited"}]},{"a":[2,{"b":"edited"}]},7]',
      );
      expect([for (final r in doc.rows(0, doc.visibleCount)) r.index].last, 2);
      _checkConsistent(doc);
    });

    test('copies source escapes verbatim', () {
      final doc = _doc(r'["a\u0041"]');
      doc.apply(DuplicateItem(_node(doc, [0])));
      expect(_enc(doc), r'["a\u0041","a\u0041"]');
    });

    test('only array items can be duplicated', () {
      final doc = _doc('{"a":1}');
      expect(
        () => doc.apply(DuplicateItem(_node(doc, ['a']))),
        throwsArgumentError,
      );
      expect(() => doc.apply(const DuplicateItem(0)), throwsArgumentError);
    });
  });

  group('AddMissingKey', () {
    test('container values become empty containers of that kind', () {
      final doc = _doc('[{},{"o":{"x":1},"l":[1],"n":5}]');
      final item = _node(doc, [0]);
      doc
        ..apply(AddMissingKey(item, 'o'))
        ..apply(AddMissingKey(item, 'l'))
        ..apply(AddMissingKey(item, 'n'));
      expect(_enc(doc), '[{"o":{},"l":[],"n":5},{"o":{"x":1},"l":[1],"n":5}]');
      _checkConsistent(doc);
    });

    test('uses the first sibling that has the key', () {
      final doc = _doc('[{},{"k":null},{"k":"late"}]');
      doc.apply(AddMissingKey(_node(doc, [0]), 'k'));
      expect(_enc(doc), '[{"k":null},{"k":null},{"k":"late"}]');
    });

    test('rejects present keys, unknown keys and non-items', () {
      final doc = _doc('{"l":[{"a":1},{"b":2}],"o":{}}');
      final item = _node(doc, ['l', 0]);
      expect(() => doc.apply(AddMissingKey(item, 'a')), throwsArgumentError);
      expect(() => doc.apply(AddMissingKey(item, 'zzz')), throwsArgumentError);
      expect(
        () => doc.apply(AddMissingKey(_node(doc, ['o']), 'a')),
        throwsArgumentError,
      );
      expect(doc.dirty, isFalse);
    });
  });

  group('AddKeyToAll / RemoveKeyFromAll', () {
    test('AddKeyToAll skips non-objects and objects that have the key', () {
      final doc = _doc('[{"a":1},2,{"k":"keep"},{}]');
      doc.apply(const AddKeyToAll(0, 'k', {'deep': []}));
      expect(
        _enc(doc),
        '[{"a":1,"k":{"deep":[]}},2,{"k":"keep"},{"k":{"deep":[]}}]',
      );
      _checkConsistent(doc);
    });

    test('RemoveKeyFromAll removes every member with the name', () {
      final doc = _doc('[{"a":1,"b":2,"a":3},{"b":4},5,{"a":{"x":1}}]');
      doc.toggle(_node(doc, [3]));
      doc.apply(const RemoveKeyFromAll(0, 'a'));
      expect(_enc(doc), '[{"b":2},{"b":4},5,{}]');
      expect(doc.schemaOf(0)!.describe(), '{b?: number}');
      _checkConsistent(doc);
    });

    test('nothing to do leaves the document clean', () {
      final doc = _doc('[{"k":1}]');
      doc
        ..apply(const AddKeyToAll(0, 'k', 2))
        ..apply(const RemoveKeyFromAll(0, 'zz'));
      expect(doc.dirty, isFalse);
    });

    test('both need an array', () {
      final doc = _doc('{}');
      expect(
        () => doc.apply(const AddKeyToAll(0, 'k', 1)),
        throwsArgumentError,
      );
      expect(
        () => doc.apply(const RemoveKeyFromAll(0, 'k')),
        throwsArgumentError,
      );
    });
  });

  group('NewItemFromSchema', () {
    test('uses the first-seen kind of every field', () {
      final doc = _doc(
        '[{"s":"x","n":1.5,"b":true,"z":null,"o":{"a":1},"l":[1]},'
        '{"s":2,"extra":"e"},7]',
      );
      doc.apply(const NewItemFromSchema(0));
      final items = jsonDecode(_enc(doc)) as List;
      expect(items.last, {
        's': '',
        'n': 0,
        'b': false,
        'z': null,
        'o': {},
        'l': [],
        'extra': '',
      });
      _checkConsistent(doc);
    });

    test('needs an array that holds objects', () {
      final doc = _doc('{"l":[1,2],"o":{}}');
      expect(
        () => doc.apply(NewItemFromSchema(_node(doc, ['l']))),
        throwsArgumentError,
      );
      expect(
        () => doc.apply(NewItemFromSchema(_node(doc, ['o']))),
        throwsArgumentError,
      );
    });
  });

  group('documents', () {
    test('edits on an unparsed document throw StateError', () {
      final doc = _doc('{');
      expect(() => doc.apply(const SetValue(0, 1)), throwsStateError);
      expect(doc.dirty, isFalse);
    });

    test('untouched values keep their source bytes after edits', () {
      final doc = _doc(r'{"n":1.000,"s":"\u00e9","big":1e400,"x":0}');
      doc.apply(SetValue(_node(doc, ['x']), 1));
      expect(_enc(doc), r'{"n":1.000,"s":"\u00e9","big":1e400,"x":1}');
      expect(
        _enc(doc, pretty: true),
        '{\n  "n": 1.000,\n  "s": "\\u00e9",\n  "big": 1e400,\n  "x": 1\n}',
      );
    });

    test('nodeCount counts live nodes', () {
      final doc = _doc('[[1,2],3]');
      expect(doc.nodeCount, 5);
      doc.apply(DeleteNode(_node(doc, [0])));
      expect(doc.nodeCount, 2);
      doc.apply(const AddItem(0, [1, 2, 3]));
      expect(doc.nodeCount, 6);
    });

    test('random edits keep counts, caches and output consistent', () {
      final rnd = Random(18);
      Object? value(int depth) {
        final r = rnd.nextInt(depth > 2 ? 4 : 7);
        return switch (r) {
          0 => rnd.nextInt(100),
          1 => 's${rnd.nextInt(5)}',
          2 => rnd.nextBool(),
          3 => null,
          4 => [for (var i = 0; i < rnd.nextInt(4); i++) value(depth + 1)],
          _ => {
            for (var i = 0; i < rnd.nextInt(4); i++)
              'k${rnd.nextInt(4)}': value(depth + 1),
          },
        };
      }

      final applied = <Type, int>{};
      for (var round = 0; round < 40; round++) {
        final doc = _doc(
          jsonEncode([
            for (var i = 0; i < 4; i++)
              {'id': i, 'k${i % 3}': value(1), 'n': value(1)},
          ]),
        );
        for (var step = 0; step < 40; step++) {
          final rows = doc.rows(0, doc.visibleCount);
          if (rows.isEmpty) break;
          final row = rows[rnd.nextInt(rows.length)];
          final id = row.nodeId;
          // Array-wide edits mostly target the root array of objects.
          final array = rnd.nextBool() ? 0 : id;
          final edit = switch (rnd.nextInt(12)) {
            0 => SetValue(id, value(2)),
            1 => RenameKey(id, 'k${rnd.nextInt(5)}'),
            2 => DeleteNode(id),
            3 => AddKey(id, 'k${rnd.nextInt(5)}', value(2)),
            4 => AddItem(id, value(2), at: rnd.nextInt(2) == 0 ? 0 : null),
            5 => DuplicateItem(id),
            6 => AddMissingKey(id, 'k${rnd.nextInt(4)}'),
            7 => AddKeyToAll(array, 'k${rnd.nextInt(5)}', value(2)),
            8 => RemoveKeyFromAll(array, 'k${rnd.nextInt(5)}'),
            9 => NewItemFromSchema(array),
            10 => const AddItem(0, {'id': 9}),
            _ => null,
          };
          if (edit == null) {
            doc.toggle(id);
          } else {
            try {
              expect(doc.apply(edit), doc.visibleCount);
              applied[edit.runtimeType] = (applied[edit.runtimeType] ?? 0) + 1;
            } on ArgumentError {
              // Not applicable to this node; nothing changed.
            }
          }
          _checkConsistent(doc);
        }
      }
      // Every kind of edit was exercised, not just rejected.
      expect(applied.keys, hasLength(10), reason: '$applied');
      expect(applied.values.every((n) => n >= 10), isTrue, reason: '$applied');
    });
  });
}
