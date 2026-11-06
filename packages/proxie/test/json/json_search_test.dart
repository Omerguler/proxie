import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';

JsonDocument _doc(String s) =>
    JsonDocument.tryParse(Uint8List.fromList(utf8.encode(s)));

/// Paths of the hits, for readable assertions.
List<List<Object>> _paths(JsonDocument doc, List<int> hits) => [
  for (final id in hits) doc.pathOf(id),
];

List<List<Object>> _find(JsonDocument doc, String q, {int limit = 500}) =>
    _paths(doc, doc.search(q, limit: limit));

void main() {
  group('search', () {
    test('brief example: key and value matches in document order', () {
      final doc = _doc(
        '{"users":[{"name":"Ada","email":"x@ada.dev"},'
        '{"adapter":1,"name":"Bob"}],"ADAMS":true}',
      );
      expect(_find(doc, 'ada'), [
        ['users', 0, 'name'],
        ['users', 0, 'email'],
        ['users', 1, 'adapter'],
        ['ADAMS'],
      ]);
    });

    test('is case-insensitive in both directions', () {
      final doc = _doc('["ABC","abc","aBc","xyz"]');
      expect(_find(doc, 'abc'), [
        [0],
        [1],
        [2],
      ]);
      expect(_find(doc, 'ABC'), hasLength(3));
      expect(_find(doc, 'Bc'), hasLength(3));
    });

    test('strings are matched decoded', () {
      final doc = _doc(r'["Ada","a\nb","ÉCOLE","ÉCOLE","café","x\"y"]');
      expect(_find(doc, 'ada'), [
        [0],
      ]);
      expect(_find(doc, 'a\nb'), [
        [1],
      ]);
      expect(_find(doc, r'\n'), isEmpty);
      expect(_find(doc, 'école'), [
        [2],
        [3],
      ]);
      expect(_find(doc, 'É'), [
        [2],
        [3],
        [4],
      ]);
      expect(_find(doc, 'fé'), [
        [4],
      ]);
      expect(_find(doc, 'x"y'), [
        [5],
      ]);
    });

    test('member names are matched decoded', () {
      final doc = _doc('{"Key":1,"Ünï":2,"plain":3}');
      expect(_find(doc, 'key'), [
        ['Key'],
      ]);
      expect(_find(doc, 'ünÏ'), [
        ['Ünï'],
      ]);
    });

    test('numbers by lexeme; true, false and null by name', () {
      final doc = _doc('[1E5,1.50,-0,true,false,null,"null"]');
      expect(_find(doc, 'e5'), [
        [0],
      ]);
      expect(_find(doc, '1.5'), [
        [1],
      ]);
      expect(_find(doc, '-0'), [
        [2],
      ]);
      expect(_find(doc, 'TRU'), [
        [3],
      ]);
      expect(_find(doc, 'als'), [
        [4],
      ]);
      expect(_find(doc, 'null'), [
        [5],
        [6],
      ]);
    });

    test('containers match by name only, once per node', () {
      final doc = _doc('{"items":{"items":"items"},"list":[]}');
      expect(_find(doc, 'items'), [
        ['items'],
        ['items', 'items'],
      ]);
      expect(_find(doc, '['), isEmpty);
      expect(_find(doc, '{'), isEmpty);
    });

    test('scalar roots can match', () {
      expect(_doc('"Hello"').search('ell'), [0]);
      expect(_doc('42').search('2'), [0]);
      expect(_doc('42').search('3'), isEmpty);
    });

    test('limit caps the hits; empty queries find nothing', () {
      final doc = _doc(jsonEncode(List.filled(600, 'a')));
      expect(doc.search('a'), hasLength(500));
      expect(doc.search('a', limit: 3), hasLength(3));
      expect(doc.search('a', limit: 0), isEmpty);
      expect(doc.search(''), isEmpty);
      expect(() => doc.search('a', limit: -1), throwsRangeError);
    });

    test('documents that did not parse find nothing', () {
      expect(_doc('{').search('a'), isEmpty);
    });

    test('sees edits; skips deleted nodes; keeps document order', () {
      final doc = _doc('{"a":"old","b":[{"c":1}],"d":0}');
      final rows = doc.rows(0, 3);
      doc
        ..apply(SetValue(rows[0].nodeId, 'NeW'))
        ..apply(SetValue(rows[2].nodeId, const JsonNumber('12e3')))
        ..apply(AddItem(rows[1].nodeId, 'new item', at: 0))
        ..apply(RenameKey(rows[2].nodeId, 'renamed'))
        ..apply(const AddKey(0, 'flag', true));
      expect(_find(doc, 'new'), [
        ['a'],
        ['b', 0],
      ]);
      expect(_find(doc, 'old'), isEmpty);
      expect(_find(doc, '2e3'), [
        ['renamed'],
      ]);
      expect(_find(doc, 'renam'), [
        ['renamed'],
      ]);
      expect(_find(doc, 'true'), [
        ['flag'],
      ]);
      expect(_find(doc, 'c'), [
        ['b', 1, 'c'],
      ]);
      doc.apply(DeleteNode(rows[1].nodeId));
      expect(_find(doc, 'c'), isEmpty);
      expect(_find(doc, 'new'), [
        ['a'],
      ]);
    });
  });

  group('reveal', () {
    test('opens the ancestors of a deep hit and returns its row', () {
      final doc = _doc(
        '{"a":[1,2],"b":{"c":[{"d":0},{"e":{"needle":true}}]},"z":0}',
      );
      final hit = doc.search('needle').single;
      final row = doc.reveal(hit);
      expect(doc.rows(row, 1).first.nodeId, hit);
      expect(row, 6);
      expect(doc.pathOf(hit), ['b', 'c', 1, 'e', 'needle']);
      // a stays closed; every ancestor of the hit is open.
      expect(
        [for (final r in doc.rows(0, doc.visibleCount)) r.expanded],
        [
          false, // a
          true, // b
          true, // c
          false, // [0]
          true, // [1]
          true, // e
          false, // needle
          false, // z
        ],
      );
      // Revealing again changes nothing.
      expect(doc.reveal(hit), row);
      expect(doc.visibleCount, 8);
    });

    test('counts open siblings before the hit', () {
      final doc = _doc('[[1,2,3],{"x":[4,5]},[6]]');
      doc.toggle(doc.rows(0, 1).single.nodeId);
      final six = doc.search('6').single;
      expect(doc.reveal(six), 6);
      expect(doc.rows(6, 1).single.preview, '6');
      final five = doc.search('5').single;
      expect(doc.reveal(five), 7);
      expect(doc.rows(7, 1).single.nodeId, five);
    });

    test('top-level rows and scalar roots', () {
      final doc = _doc('{"a":1,"b":2}');
      expect(doc.reveal(doc.search('b').single), 1);
      expect(_doc('7').reveal(0), 0);
    });

    test('the root container and deleted nodes have no row', () {
      final doc = _doc('[[1]]');
      expect(() => doc.reveal(0), throwsArgumentError);
      final inner = doc.rows(0, 1).single.nodeId;
      final one = doc.search('1').single;
      doc.apply(DeleteNode(inner));
      expect(() => doc.reveal(one), throwsArgumentError);
      expect(() => doc.reveal(99), throwsArgumentError);
    });

    test('works after edits for every node', () {
      final rnd = Random(19);
      final doc = _doc(
        jsonEncode([
          for (var i = 0; i < 20; i++)
            {
              'id': i,
              'tags': ['t$i', 'u$i'],
              'more': {
                'deep': [i, '$i'],
              },
            },
        ]),
      );
      doc
        ..apply(const AddItem(0, {'id': 'new'}, at: 3))
        ..apply(DuplicateItem(doc.rows(7, 1).single.nodeId));
      // Every live non-root node, via a query that matches all of them.
      final ids = [
        for (final id in doc.search('i', limit: 1 << 20)) id,
        for (final id in doc.search('t', limit: 1 << 20)) id,
        for (final id in doc.search('1', limit: 1 << 20)) id,
      ]..shuffle(rnd);
      expect(ids.length, greaterThan(50));
      for (final id in ids) {
        if (rnd.nextInt(4) == 0) doc.collapseAll();
        final row = doc.reveal(id);
        expect(doc.rows(row, 1).single.nodeId, id);
      }
    });
  });

  group('commands', () {
    test('JsonSearch and JsonReveal', () async {
      final store = MemoryStore();
      final ctx = WorkerContext(store: store, config: const ProxieConfig());
      await store.upsert(
        ProxieCall(
          id: 'c1',
          sessionId: 1,
          adapter: 'test',
          request: ProxieRequest(
            method: 'GET',
            url: Uri.parse('https://api.test/'),
            headers: const {},
            body: ProxieBody.from(
              Uint8List.fromList(utf8.encode('{"a":{"b":"Find me"},"c":1}')),
              'application/json',
            ),
          ),
          startedAt: DateTime.utc(2026),
        ),
      );
      final h = await const OpenJson('c1', JsonBodySide.request).execute(ctx);
      final hits = await JsonSearch(h.docId, 'FIND').execute(ctx);
      expect(hits, hasLength(1));
      expect(await JsonSearch(h.docId, 'a', limit: 0).execute(ctx), isEmpty);
      final row = await JsonReveal(h.docId, hits.single).execute(ctx);
      expect(row, 1);
      final rows = await JsonRows(h.docId, row, 1).execute(ctx);
      expect(rows.single.nodeId, hits.single);
      expect(
        () => const JsonSearch('x', 'a').execute(ctx),
        throwsA(isA<JsonDocumentClosed>()),
      );
      expect(
        () => const JsonReveal('x', 1).execute(ctx),
        throwsA(isA<JsonDocumentClosed>()),
      );
    });
  });
}
