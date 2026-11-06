import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';

Uint8List _bytes(String s) => Uint8List.fromList(utf8.encode(s));

JsonDocument _doc(String s) => JsonDocument.tryParse(_bytes(s));

/// Labels rows as `depth key/index kind preview`, for compact assertions.
List<String> _labels(JsonDocument doc) => doc
    .rows(0, doc.visibleCount)
    .map(
      (r) =>
          '${r.depth} ${r.key ?? (r.index == null ? '-' : '[${r.index}]')} '
          '${r.kind.name} ${r.preview}',
    )
    .toList();

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

    test('compact encode of an untouched doc is the input', () {
      expect(utf8.decode(_doc(input).encode()), input);
    });
  });

  group('parsing', () {
    test('invalid JSON gives a parse error', () {
      for (final s in [
        '',
        '   ',
        '{',
        '[',
        '{"a":}',
        '{"a" 1}',
        '{1:1}',
        '{"a":1,}',
        '[1,]',
        '[,1]',
        '[1 2]',
        '[1,,2]',
        '{"a":1 "b":2}',
        '}',
        'nul',
        'tru',
        'True',
        '1 2',
        '01',
        '-01',
        '00',
        '-',
        '1.',
        '.5',
        '+1',
        '1e',
        '1e+',
        '1.e5',
        'NaN',
        'Infinity',
        '-Infinity',
        '"abc',
        '"a\nb"',
        '"a\tb"',
        '"\u0000"',
        r'"\x"',
        r'"\u12"',
        r'"\u12G4"',
        r'"\',
        "'a'",
        '[1]]',
        '{"a":1}}',
        '/* c */ 1',
      ]) {
        final doc = _doc(s);
        expect(doc.parseError, startsWith('Invalid JSON: '), reason: s);
        expect(doc.visibleCount, 0, reason: s);
        expect(doc.rows(0, 5), isEmpty, reason: s);
        expect(doc.encode, throwsStateError, reason: s);
        expect(() => doc.toggle(0), throwsRangeError, reason: s);
      }
    });

    test('errors name the problem and its byte offset', () {
      expect(
        _doc('[1,]').parseError,
        'Invalid JSON: Unexpected character (at offset 3)',
      );
      expect(
        _doc('{"a":1').parseError,
        'Invalid JSON: Unexpected end of input (at offset 6)',
      );
      expect(
        _doc('"abc').parseError,
        'Invalid JSON: Unterminated string (at offset 0)',
      );
      expect(
        _doc('["a\u0001"]').parseError,
        'Invalid JSON: Control character in string (at offset 3)',
      );
      expect(
        JsonDocument.tryParse(
          Uint8List.fromList([0x22, 0xC3, 0x28, 0x22]),
        ).parseError,
        'Invalid JSON: Invalid UTF-8 (at offset 1)',
      );
    });

    test('UTF-8 is validated strictly', () {
      List<int> str(List<int> inner) => [0x22, ...inner, 0x22];
      final invalid = {
        'lone continuation': [0x80],
        'overlong 2-byte': [0xC0, 0xAF],
        'overlong C1': [0xC1, 0xBF],
        'overlong 3-byte': [0xE0, 0x80, 0xAF],
        'encoded surrogate': [0xED, 0xA0, 0x80],
        'overlong 4-byte': [0xF0, 0x80, 0x80, 0xAF],
        'above U+10FFFF': [0xF4, 0x90, 0x80, 0x80],
        'F5 lead': [0xF5, 0x80, 0x80, 0x80],
        'cut 3-byte': [0xE2, 0x82],
        'cut 4-byte': [0xF0, 0x9F, 0x98],
        'bad continuation': [0xE2, 0x28, 0xA1],
        'FF': [0xFF],
      };
      for (final MapEntry(:key, :value) in invalid.entries) {
        final doc = JsonDocument.tryParse(Uint8List.fromList(str(value)));
        expect(doc.parseError, contains('Invalid UTF-8'), reason: key);
      }
      // Valid boundaries: U+0080, U+07FF, U+0800, U+D7FF, U+E000, U+FFFF,
      // U+10000, U+10FFFF.
      const valid = '\u0080߿ࠀ퟿￿\u{10000}\u{10FFFF}';
      final doc = JsonDocument.tryParse(
        Uint8List.fromList(utf8.encode(jsonEncode(valid))),
      );
      expect(doc.parseError, isNull);
      expect(jsonDecode(utf8.decode(doc.encode())), valid);
      // Non-ASCII outside strings is an unexpected character.
      expect(
        JsonDocument.tryParse(
          Uint8List.fromList([0x5B, 0xC3, 0xA9, 0x5D]),
        ).parseError,
        'Invalid JSON: Unexpected character (at offset 1)',
      );
    });

    test('accepts a leading BOM, whitespace and lone surrogate escapes', () {
      final bom = JsonDocument.tryParse(
        Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('[1]')]),
      );
      expect(bom.parseError, isNull);
      expect(bom.visibleCount, 1);
      expect(_doc(' \t\r\n[ 1 , 2 ]\n').visibleCount, 2);
      final lone = _doc(r'["\ud800","\uDC00x"]');
      expect(lone.parseError, isNull);
      expect(
        [for (final r in lone.rows(0, 2)) r.preview],
        [r'"\ud800"', r'"\udc00x"'],
      );
    });

    test('accepts exactly what jsonDecode accepts', () {
      // Random inputs over a JSON-ish alphabet; validity must match.
      final rnd = Random(3);
      const alphabet = [
        '[',
        ']',
        '{',
        '}',
        ',',
        ':',
        '"',
        r'\',
        'u',
        '0',
        '1',
        '9',
        '-',
        '+',
        '.',
        'e',
        'E',
        ' ',
        'a',
        'true',
        'false',
        'null',
        '"k"',
        '\n',
        r'\n',
        'é',
        'é',
      ];
      var valid = 0;
      for (var i = 0; i < 20000; i++) {
        final s = [
          for (var j = 0; j < 1 + rnd.nextInt(10); j++)
            alphabet[rnd.nextInt(alphabet.length)],
        ].join();
        Object? expected;
        var ok = true;
        try {
          expected = jsonDecode(s);
        } on FormatException {
          ok = false;
        }
        final doc = _doc(s);
        expect(doc.parseError == null, ok, reason: s);
        if (ok) {
          valid++;
          expect(jsonDecode(utf8.decode(doc.encode())), expected, reason: s);
        }
      }
      expect(valid, greaterThan(500));
    });

    test('nodeCount counts every value', () {
      expect(_doc('{"a":[1,2],"b":{}}').nodeCount, 5);
      expect(_doc('1').nodeCount, 1);
      expect(_doc('[').nodeCount, 0);
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
    });

    test('pretty output indents at most 512 levels, else is compact', () {
      // Indentation would make pretty output grow with depth squared.
      String pretty(String s) => utf8.decode(_doc(s).encode(pretty: true));
      // 512 levels: the innermost array is the 512th container.
      final ok = '${'[' * 510}{"a":[]}${']' * 510}';
      expect(
        pretty(ok),
        const JsonEncoder.withIndent('  ').convert(jsonDecode(ok)),
      );
      final over = '${'[' * 511}{"a":[]}${']' * 511}';
      expect(pretty(over), over);
      final deep = '${'[' * 10000}1${']' * 10000}';
      final sw = Stopwatch()..start();
      expect(pretty(deep), deep);
      expect(sw.elapsedMilliseconds, lessThan(1000));
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

    test('long numbers are cut to 120 chars with an ellipsis', () {
      final digits = '1' * 200;
      final doc = _doc('[$digits, ${'2' * 120}]');
      expect(doc.rows(0, 1).single.preview, '${'1' * 119}…');
      expect(doc.rows(1, 1).single.preview, '2' * 120);
      expect(utf8.decode(doc.encode()), '[$digits,${'2' * 120}]');
    });

    test('long strings are decoded only as far as the preview needs', () {
      final big = 'é' * 300000;
      final doc = _doc(jsonEncode([big, '${'a' * 200}\\n']));
      expect(doc.rows(0, 1).single.preview, '"${'é' * 118}…');
      expect(doc.rows(1, 1).single.preview, '"${'a' * 118}…');
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
          '1e21',
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
      final doc = _doc(input)..expandAll();
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
      final doc = _doc(input)..expandAll(maxDepth: 1);
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
      final doc = _doc(input)
        ..expandAll()
        ..collapseAll();
      expect(_labels(doc), ['0 a object {1 key}', '0 d array [1 item]']);
      // Toggling still works after a bulk change.
      doc.toggle(doc.rows(1, 1).single.nodeId);
      expect(doc.visibleCount, 3);
    });
  });

  group('fidelity', () {
    test('numbers keep their source text', () {
      for (final n in [
        '12345678901234567890',
        '9007199254740993',
        '0.10',
        '1e2',
        '1E+2',
        '1e400',
        '-1e400',
        '-0',
        '-0.0e-0',
        '123.4560',
      ]) {
        final doc = _doc('[$n]');
        expect(doc.rows(0, 1).single.preview, n);
        expect(utf8.decode(doc.encode()), '[$n]');
        expect(utf8.decode(doc.encode(pretty: true)), '[\n  $n\n]');
        final root = _doc(n);
        expect(root.rows(0, 1).single.preview, n);
        expect(utf8.decode(root.encode()), n);
      }
    });

    test('duplicate keys are kept as separate members', () {
      final doc = _doc('{"a":1,"a":2}');
      expect(doc.visibleCount, 2);
      expect(_labels(doc), ['0 a number 1', '0 a number 2']);
      expect(utf8.decode(doc.encode()), '{"a":1,"a":2}');
    });

    test('strings keep their source escapes', () {
      const src = r'["é\/\"",{"ké":"\ud800"}]';
      final doc = _doc(src);
      expect(doc.rows(0, 1).single.preview, r'"é/\""');
      // Keys are re-encoded from their decoded text; values verbatim.
      expect(utf8.decode(doc.encode()), r'["é\/\"",{"ké":"\ud800"}]');
    });
  });

  group('encode', () {
    /// [s] without whitespace outside strings.
    String minify(String s) {
      final out = StringBuffer();
      var inString = false;
      for (var i = 0; i < s.length; i++) {
        final c = s[i];
        if (inString) {
          out.write(c);
          if (c == r'\') {
            out.write(s[++i]);
          } else if (c == '"') {
            inString = false;
          }
        } else if (c == '"') {
          inString = true;
          out.write(c);
        } else if (!' \t\r\n'.contains(c)) {
          out.write(c);
        }
      }
      return out.toString();
    }

    const plain = '''
{
  "id": 12345678901234567890, "ratio": 0.10, "exp": 1e2, "big": 1e400,
  "neg": -0, "s": "a b é 😀 /", "e": {}, "l": [ ],
  "o": {"x": null, "y": true, "z": false, "w": [[], [{}], [1, [2, [3]]]]},
  "dup": 1, "dup": 2
}
''';
    const fixtures = [
      plain,
      r'{"s":"a\"\n\u0001é😀\t\\","n":[1,-2.5,1e21,0.1,12345678901234]}',
      r'["\ud800","a\udc00b","😀"]',
      '[[[[[]]]],{"a":{"b":{"c":{}}}}]',
      '"just a string"',
      'null',
    ];

    test('compact output is the input without insignificant whitespace', () {
      expect(utf8.decode(_doc(plain).encode()), minify(plain));
    });

    test('output decodes to the same value', () {
      for (final f in fixtures) {
        for (final pretty in [false, true]) {
          expect(
            jsonDecode(utf8.decode(_doc(f).encode(pretty: pretty))),
            jsonDecode(f),
            reason: '$f pretty: $pretty',
          );
        }
      }
    });

    test('pretty matches JsonEncoder.withIndent for canonical input', () {
      final value = {
        's': 'a"\n\u0001é😀',
        'n': [1, -2.5, 0.1, 12345678901234],
        'e': <String, Object?>{},
        'l': <Object?>[],
        'o': {
          'x': null,
          'y': true,
          'z': false,
          'w': [
            <Object?>[],
            [<String, Object?>{}],
          ],
        },
      };
      final canonical = jsonEncode(value);
      expect(utf8.decode(_doc(canonical).encode()), canonical);
      expect(
        utf8.decode(_doc(canonical).encode(pretty: true)),
        const JsonEncoder.withIndent('  ').convert(value),
      );
      expect(utf8.decode(_doc('[]').encode(pretty: true)), '[]');
    });

    test('expansion state does not affect the output', () {
      final doc = _doc(plain)..expandAll();
      expect(utf8.decode(doc.encode()), minify(plain));
    });
  });
}
