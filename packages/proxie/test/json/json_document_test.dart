import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

JsonDocument _doc(String s) => JsonDocument.tryParse(_bytes(s));

/// Labels rows as `depth key/index kind preview`, for compact assertions.
List<String> _labels(JsonDocument doc) => [
  for (final r in doc.rows(0, doc.visibleCount))
    '${r.depth} ${r.key ?? (r.index == null ? '-' : '[${r.index}]')} '
        '${r.kind.name} ${r.preview}',
];

/// Reference implementation of the visible rows: a preorder walk of the
/// decoded value, descending only into expanded containers.
List<List<Object>> _naivePaths(
  Object? value,
  bool Function(List<Object>) open,
) {
  final out = <List<Object>>[];
  void walk(Object? v, List<Object> path) {
    if (path.isNotEmpty) out.add(path);
    if (path.isNotEmpty && !open(path)) return;
    if (v is Map) {
      for (final e in v.entries) {
        walk(e.value, [...path, e.key as String]);
      }
    } else if (v is List) {
      for (var i = 0; i < v.length; i++) {
        walk(v[i], [...path, i]);
      }
    }
  }

  walk(value, const []);
  return out;
}

void main() {
  group('brief example', () {
    const input = '{"a":[1,2],"b":{}}';

    test('root is expanded to depth 1', () {
      final doc = _doc(input);
      expect(doc.parseError, isNull);
      expect(doc.visibleCount, 2);
      final rows = doc.rows(0, 10);
      expect(rows, hasLength(2));
      expect(rows[0].key, 'a');
      expect(rows[0].kind, JsonKind.array);
      expect(rows[0].childCount, 2);
      expect(rows[0].expanded, isFalse);
      expect(rows[0].depth, 0);
      expect(rows[0].preview, '[2 items]');
      expect(rows[1].key, 'b');
      expect(rows[1].kind, JsonKind.object);
      expect(rows[1].childCount, 0);
      expect(rows[1].preview, '{0 keys}');
    });

    test('toggling a inserts its items', () {
      final doc = _doc(input);
      final a = doc.rows(0, 1).single;
      doc.toggle(a.nodeId);
      expect(doc.visibleCount, 4);
      expect(_labels(doc), [
        '0 a array [2 items]',
        '1 [0] number 1',
        '1 [1] number 2',
        '0 b object {0 keys}',
      ]);
      expect(doc.rows(0, 1).single.expanded, isTrue);
      doc.toggle(a.nodeId);
      expect(_labels(doc), ['0 a array [2 items]', '0 b object {0 keys}']);
    });

    test('pathOf', () {
      final doc = _doc(input);
      doc.toggle(doc.rows(0, 1).single.nodeId);
      final item1 = doc.rows(2, 1).single;
      expect(item1.index, 1);
      expect(doc.pathOf(item1.nodeId), ['a', 1]);
      expect(doc.pathOf(doc.rows(0, 1).single.nodeId), ['a']);
      expect(doc.pathOf(0), isEmpty);
    });

    test('invalid UTF-8 gives a parse error and no rows', () {
      final doc = JsonDocument.tryParse(Uint8List.fromList([0xff]));
      expect(doc.parseError, isNotNull);
      expect(doc.visibleCount, 0);
      expect(doc.rows(0, 10), isEmpty);
    });

    test('compact encode of an untouched doc matches jsonEncode', () {
      final doc = _doc(input);
      expect(
        utf8.decode(doc.encode(pretty: false)),
        jsonEncode(jsonDecode(input)),
      );
    });
  });

  group('parsing', () {
    test('invalid JSON gives a parse error', () {
      for (final s in ['', '{', '{"a":}', '[1,]', 'nul', '1 2']) {
        final doc = _doc(s);
        expect(doc.parseError, startsWith('Invalid JSON: '), reason: s);
        expect(doc.visibleCount, 0, reason: s);
        expect(doc.rows(0, 5), isEmpty, reason: s);
        expect(() => doc.encode(), throwsStateError, reason: s);
        expect(() => doc.toggle(0), throwsRangeError, reason: s);
      }
    });

    test('scalar roots show one row for the root itself', () {
      for (final (src, kind, preview) in [
        ('42', JsonKind.number, '42'),
        ('-1.5', JsonKind.number, '-1.5'),
        ('"x"', JsonKind.string, '"x"'),
        ('true', JsonKind.boolean, 'true'),
        ('null', JsonKind.nullValue, 'null'),
      ]) {
        final doc = _doc(src);
        expect(doc.visibleCount, 1, reason: src);
        final row = doc.rows(0, 5).single;
        expect(row.nodeId, 0);
        expect(row.depth, 0);
        expect(row.key, isNull);
        expect(row.index, isNull);
        expect(row.kind, kind);
        expect(row.preview, preview);
        expect(row.childCount, 0);
        expect(row.expanded, isFalse);
        expect(doc.pathOf(0), isEmpty);
        doc.toggle(0); // no-op
        expect(doc.visibleCount, 1);
        expect(doc.rows(1, 5), isEmpty);
        expect(utf8.decode(doc.encode()), src);
      }
    });

    test('empty containers at the root show no rows', () {
      expect(_doc('{}').visibleCount, 0);
      expect(_doc('[]').visibleCount, 0);
      expect(_doc(' [ ] ').rows(0, 3), isEmpty);
    });

    test('deeply nested documents parse, page and encode', () {
      const depth = 50000;
      final src = '${'[' * depth}1${']' * depth}';
      final doc = _doc(src);
      expect(doc.parseError, isNull);
      doc.expandAll();
      expect(doc.visibleCount, depth);
      final last = doc.rows(depth - 1, 5).single;
      expect(last.kind, JsonKind.number);
      expect(last.depth, depth - 1);
      expect(doc.pathOf(last.nodeId), List.filled(depth, 0));
      expect(utf8.decode(doc.encode()), src);
      // Pretty output grows with depth squared; check a smaller one.
      final pretty = _doc('${'[' * 3000}${']' * 3000}').encode(pretty: true);
      expect(utf8.decode(pretty), startsWith('[\n  [\n    ['));
    });
  });

  group('preview', () {
    test('strings are JSON-quoted and escaped', () {
      final doc = _doc(r'["a\"b\\c\nd\u0001", "é😀"]');
      expect(doc.rows(0, 1).single.preview, r'"a\"b\\c\nd\u0001"');
      expect(doc.rows(1, 1).single.preview, '"é😀"');
    });

    test('long strings are cut to 120 chars with an ellipsis', () {
      final doc = _doc(jsonEncode(['x' * 500, 'y' * 118, 'z' * 119]));
      final p0 = doc.rows(0, 1).single.preview;
      expect(p0.length, 120);
      expect(p0, '"${'x' * 118}…');
      expect(doc.rows(1, 1).single.preview, '"${'y' * 118}"');
      expect(doc.rows(2, 1).single.preview, '"${'z' * 118}…');
    });

    test('cuts never split an escape or a surrogate pair', () {
      final doc = _doc(jsonEncode(['${'a' * 117}\n', '${'a' * 117}😀']));
      expect(doc.rows(0, 1).single.preview, '"${'a' * 117}…');
      expect(doc.rows(1, 1).single.preview, '"${'a' * 117}…');
    });

    test('containers summarize their size', () {
      final doc = _doc('[{"a":1},{"a":1,"b":2},[0],[0,1],1e21,false,null]');
      expect(
        [for (final r in doc.rows(0, 7)) r.preview],
        [
          '{1 key}',
          '{2 keys}',
          '[1 item]',
          '[2 items]',
          '1e+21',
          'false',
          'null',
        ],
      );
    });
  });

  group('windowed rows', () {
    test('slices agree with a naive preorder walk', () {
      final rnd = Random(7);
      Object? gen(int depth) {
        switch (rnd.nextInt(depth > 4 ? 3 : 6)) {
          case 0:
            return rnd.nextInt(100);
          case 1:
            return 's${rnd.nextInt(9)}';
          case 2:
            return null;
          case 3:
          case 4:
            return [for (var i = 0; i < rnd.nextInt(6); i++) gen(depth + 1)];
          default:
            return {
              for (var i = 0; i < rnd.nextInt(6); i++) 'k$i': gen(depth + 1),
            };
        }
      }

      final value = {'root': gen(0), 'list': gen(0), 'x': gen(0)};
      final doc = _doc(jsonEncode(value));
      final open = <String>{};
      String keyOf(List<Object> p) => p.join('/');

      void check() {
        final expected = _naivePaths(value, (p) => open.contains(keyOf(p)));
        expect(doc.visibleCount, expected.length);
        final all = doc.rows(0, doc.visibleCount);
        expect([for (final r in all) doc.pathOf(r.nodeId)], expected);
        for (final r in all) {
          expect(r.depth, doc.pathOf(r.nodeId).length - 1);
        }
        // Arbitrary windows match the full listing.
        for (var i = 0; i < 20 && expected.isNotEmpty; i++) {
          final start = rnd.nextInt(expected.length);
          final count = rnd.nextInt(10) + 1;
          expect(
            [for (final r in doc.rows(start, count)) r.nodeId],
            [for (final r in all.skip(start).take(count)) r.nodeId],
          );
        }
      }

      check();
      for (var step = 0; step < 300; step++) {
        final candidates = [
          for (final r in doc.rows(0, doc.visibleCount))
            if (r.kind == JsonKind.object || r.kind == JsonKind.array) r.nodeId,
        ];
        if (candidates.isEmpty) break;
        final id = candidates[rnd.nextInt(candidates.length)];
        final k = keyOf(doc.pathOf(id));
        doc.toggle(id);
        if (!open.remove(k)) open.add(k);
        check();
      }
    });

    test('toggling a hidden node takes effect when its parent opens', () {
      final doc = _doc('{"a":{"b":[1,2,3]}}');
      final a = doc.rows(0, 1).single;
      doc.toggle(a.nodeId);
      final b = doc.rows(1, 1).single;
      doc.toggle(a.nodeId); // collapse a; b is hidden now
      expect(doc.visibleCount, 1);
      doc.toggle(b.nodeId); // expand hidden b
      expect(doc.visibleCount, 1);
      doc.toggle(a.nodeId);
      expect(doc.visibleCount, 5);
      expect(_labels(doc), [
        '0 a object {1 key}',
        '1 b array [3 items]',
        '2 [0] number 1',
        '2 [1] number 2',
        '2 [2] number 3',
      ]);
    });

    test('out-of-range windows are clamped; negatives throw', () {
      final doc = _doc('[1,2,3]');
      expect(doc.rows(2, 10), hasLength(1));
      expect(doc.rows(3, 10), isEmpty);
      expect(doc.rows(1, 0), isEmpty);
      expect(() => doc.rows(-1, 1), throwsRangeError);
      expect(() => doc.rows(0, -1), throwsRangeError);
    });

    test('unknown node ids throw', () {
      final doc = _doc('[1]');
      expect(() => doc.toggle(5), throwsRangeError);
      expect(() => doc.pathOf(-1), throwsRangeError);
    });

    test('toggling a scalar or the root does nothing', () {
      final doc = _doc('[1,[2]]');
      doc.toggle(doc.rows(0, 1).single.nodeId);
      doc.toggle(0);
      expect(doc.visibleCount, 2);
    });
  });

  group('expandAll / collapseAll', () {
    const input = '{"a":{"b":{"c":[1]}},"d":[{"e":2}]}';

    test('expandAll opens everything', () {
      final doc = _doc(input);
      doc.expandAll();
      expect(_labels(doc), [
        '0 a object {1 key}',
        '1 b object {1 key}',
        '2 c array [1 item]',
        '3 [0] number 1',
        '0 d array [1 item]',
        '1 [0] object {1 key}',
        '2 e number 2',
      ]);
      expect(doc.rows(0, 1).single.expanded, isTrue);
    });

    test('maxDepth limits which rows are opened', () {
      final doc = _doc(input);
      doc.expandAll(maxDepth: 1);
      expect(_labels(doc), [
        '0 a object {1 key}',
        '1 b object {1 key}',
        '0 d array [1 item]',
        '1 [0] object {1 key}',
      ]);
      // Exact: rows at or below maxDepth are collapsed again.
      doc.expandAll(maxDepth: 0);
      expect(doc.visibleCount, 2);
    });

    test('collapseAll keeps the root open', () {
      final doc = _doc(input);
      doc.expandAll();
      doc.collapseAll();
      expect(_labels(doc), ['0 a object {1 key}', '0 d array [1 item]']);
      // Toggling still works after a bulk change.
      doc.toggle(doc.rows(1, 1).single.nodeId);
      expect(doc.visibleCount, 3);
    });
  });

  group('encode', () {
    const input =
        '{"s":"a\\"\\n\\u0001é😀","n":[1,-2.5,1e21,0.1,12345678901234],'
        '"e":{},"l":[],"o":{"x":null,"y":true,"z":false,"w":[[],[{}]]}}';

    test('lone surrogates are escaped like jsonEncode', () {
      const src = r'["\ud800","a\udc00b","😀"]';
      expect(utf8.decode(_doc(src).encode()), jsonEncode(jsonDecode(src)));
    });

    test('numbers too large for a double stay valid JSON', () {
      final doc = _doc('[1e400,-1e400]');
      expect(utf8.decode(doc.encode()), '[1e999,-1e999]');
      expect([for (final r in doc.rows(0, 2)) r.preview], ['1e999', '-1e999']);
    });

    test('compact matches jsonEncode', () {
      expect(utf8.decode(_doc(input).encode()), jsonEncode(jsonDecode(input)));
    });

    test('pretty matches JsonEncoder.withIndent', () {
      expect(
        utf8.decode(_doc(input).encode(pretty: true)),
        const JsonEncoder.withIndent('  ').convert(jsonDecode(input)),
      );
      expect(utf8.decode(_doc('[]').encode(pretty: true)), '[]');
    });

    test('expansion state does not affect the output', () {
      final doc = _doc(input);
      doc.expandAll();
      expect(utf8.decode(doc.encode()), jsonEncode(jsonDecode(input)));
    });
  });
}
