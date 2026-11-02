import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/ui/common.dart';
import 'package:proxie/src/ui/detail/call_detail.dart';
import 'package:proxie/src/ui/json/json_row_tile.dart';
import 'package:proxie/src/ui/json/json_tree_controller.dart';
import 'package:proxie/src/ui/json/json_tree_view.dart';
import 'package:proxie/src/ui/json/raw_text_view.dart';
import 'package:proxie/src/ui/json/text_lines.dart';
import 'package:proxie/src/ui/json/value_editor.dart';

/// Runs commands straight against a [MemoryStore], wrapping failures as
/// the real workers do; records every command and can fail some.
class _Worker implements ProxieWorker {
  _Worker(this.store);

  final MemoryStore store;
  late final WorkerContext ctx = WorkerContext(
    store: store,
    config: const ProxieConfig(),
  );
  final List<WorkerCommand<Object?>> sent = [];

  /// Commands for which this returns true fail instead of running.
  bool Function(WorkerCommand<Object?> cmd)? failWhen;

  /// What a command matched by [failWhen] throws; a raw [StateError]
  /// (as from a disposed worker) when null.
  Exception? failure;

  Iterable<T> sentOf<T>() => sent.whereType<T>();

  @override
  int get sessionId => 1;

  @override
  void upsert(ProxieCall call) => unawaited(store.upsert(call));

  @override
  Future<R> run<R>(WorkerCommand<R> cmd) async {
    sent.add(cmd);
    if (failWhen?.call(cmd) ?? false) {
      final e = failure;
      if (e != null) throw e;
      throw StateError('worker down');
    }
    try {
      return await cmd.execute(ctx);
    } on Object catch (e, st) {
      throw ProxieWorkerException.wrap(e, st);
    }
  }

  @override
  Future<void> dispose() async {}
}

ProxieCall _call(String json, {String id = 'c1'}) => ProxieCall(
  id: id,
  sessionId: 1,
  adapter: 'test',
  request: ProxieRequest(
    method: 'GET',
    url: Uri.parse('https://api.test/$id'),
    headers: const {},
    body: ProxieBody.empty(),
  ),
  response: ProxieResponse(
    statusCode: 200,
    headers: const {
      'content-type': ['application/json'],
    },
    body: ProxieBody(
      bytes: Uint8List.fromList(utf8.encode(json)),
      contentType: 'application/json',
      kind: BodyKind.json,
    ),
  ),
  startedAt: DateTime(2026, 11, 2),
  duration: const Duration(milliseconds: 5),
);

Widget _app(Widget child, {ThemeData? theme}) => MaterialApp(
  theme: theme ?? ProxieTheme.dark(),
  home: Scaffold(body: child),
);

Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump();
  }
}

/// The tree's rows, without the root header.
final Finder _rows = find.descendant(
  of: find.byKey(const ValueKey('proxie-json-tree')),
  matching: find.byType(JsonRowTile),
);

String _rowText(WidgetTester tester, int nodeId) {
  final tile = tester.widget<JsonRowTile>(
    find.byWidgetPredicate((w) => w is JsonRowTile && w.row.nodeId == nodeId),
  );
  return tile.row.preview;
}

void main() {
  late MemoryStore store;
  late _Worker worker;

  setUp(() {
    store = MemoryStore();
    worker = _Worker(store);
  });

  Future<JsonTreeController> pumpTree(
    WidgetTester tester,
    String json, {
    bool editable = true,
    String scope = OpenJson.viewScope,
    bool upsert = true,
  }) async {
    if (upsert) await store.upsert(_call(json));
    final controller = JsonTreeController(
      worker,
      'c1',
      'response',
      editable: editable,
      scope: scope,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(_app(JsonTreeView(controller: controller)));
    await _settle(tester);
    return controller;
  }

  testWidgets('opening a 40k-item doc builds fewer than 60 rows', (
    tester,
  ) async {
    final json = jsonEncode([
      for (var i = 0; i < 40000; i++) {'id': i, 'name': 'user $i'},
    ]);
    final c = await pumpTree(tester, json);
    expect(c.status, JsonTreeStatus.ready);
    expect(c.visibleCount, 40000);
    final built = _rows.evaluate().length;
    expect(built, greaterThan(10));
    expect(built, lessThan(60));
    // Only the windows on screen were fetched.
    expect(worker.sentOf<JsonRows>(), hasLength(1));
    expect(worker.sentOf<JsonRows>().single.count, 200);
    expect(find.textContaining('[0]: '), findsOneWidget);
  });

  testWidgets('rows are 28 px high and indented 14 px per depth', (
    tester,
  ) async {
    final c = await pumpTree(tester, '{"a":{"b":1}}');
    expect(tester.getSize(_rows.first).height, 28);
    await c.toggle(1);
    await _settle(tester);
    final a = tester.getTopLeft(find.textContaining('a: ', findRichText: true));
    final b = tester.getTopLeft(find.textContaining('b: ', findRichText: true));
    expect(b.dx - a.dx, 14);
  });

  testWidgets('tapping a container toggles it', (tester) async {
    await pumpTree(tester, '{"user":{"id":1,"name":"ada"}}');
    expect(_rows, findsOneWidget);
    await tester.tap(_rows);
    await _settle(tester);
    expect(worker.sentOf<JsonToggle>(), hasLength(1));
    expect(_rows, findsNWidgets(3));
  });

  testWidgets('array headers show the schema', (tester) async {
    await pumpTree(tester, '{"users":[{"id":1,"avatar":"a"},{"id":2}]}');
    expect(
      find.textContaining('{id: number, avatar?: string}', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('tapping a + avatar chip sends AddMissingKey and the row '
      'updates', (tester) async {
    await pumpTree(tester, '[{"id":1,"avatar":"a.png"},{"id":2}]');
    expect(find.text('+ avatar'), findsOneWidget);
    // Item [1] is node 4: root 0, item 1 with members 2 and 3.
    expect(_rowText(tester, 4), '{1 key}');

    await tester.tap(find.text('+ avatar'));
    await _settle(tester);
    final edit = worker.sentOf<JsonApply>().single.edit as AddMissingKey;
    expect(edit.itemNodeId, 4);
    expect(edit.key, 'avatar');
    expect(_rowText(tester, 4), '{2 keys}');
    expect(find.text('+ avatar'), findsNothing);
  });

  testWidgets('the duplicate menu action sends DuplicateItem', (tester) async {
    final c = await pumpTree(tester, '[{"id":1},{"id":2}]');
    expect(c.visibleCount, 2);
    await tester.tap(find.byTooltip('Edit [0]'));
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Add key'), findsOneWidget);
    await tester.tap(find.text('Duplicate'));
    await _settle(tester);
    final edit = worker.sentOf<JsonApply>().single.edit as DuplicateItem;
    expect(edit.itemNodeId, 1);
    expect(c.visibleCount, 3);
    expect(find.textContaining('[2]: ', findRichText: true), findsOneWidget);
    expect(utf8.decode(await c.encode()), '[{"id":1},{"id":1},{"id":2}]');
  });

  testWidgets('a long press opens the same menu', (tester) async {
    await pumpTree(tester, '{"a":1}');
    await tester.longPress(_rows);
    await tester.pumpAndSettle();
    expect(find.text('Edit value'), findsOneWidget);
    expect(find.text('Rename key'), findsOneWidget);
    expect(find.text('Duplicate'), findsNothing);
  });

  testWidgets('edit value replaces a scalar with the typed kind', (
    tester,
  ) async {
    final long = 'x' * 300;
    final c = await pumpTree(tester, '{"a":"$long","n":12345678901234567890}');
    await tester.tap(find.byTooltip('Edit a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit value'));
    await tester.pumpAndSettle();
    // The whole string, not the shortened preview.
    expect(find.text(long), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('proxie-value-field')),
      'hi',
    );
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(
      utf8.decode(await c.encode()),
      '{"a":"hi","n":12345678901234567890}',
    );
  });

  testWidgets('add key and array actions reach the worker', (tester) async {
    final c = await pumpTree(tester, '{"o":{},"list":[{"id":1,"x":true}]}');
    // Add key to the object row.
    await tester.tap(find.byTooltip('Edit o'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('proxie-key-field')), 'k');
    await tester.enterText(
      find.byKey(const ValueKey('proxie-value-field')),
      'v',
    );
    await tester.tap(find.text('Save'));
    await _settle(tester);

    // Remove "x" from all items of the array row.
    await tester.tap(find.byTooltip('Edit list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove key from all'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('x'));
    await _settle(tester);

    await tester.tap(find.byTooltip('Edit list'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New item from schema'));
    await _settle(tester);

    expect(
      utf8.decode(await c.encode()),
      '{"o":{"k":"v"},"list":[{"id":1},{"id":0}]}',
    );
    expect(worker.sentOf<JsonApply>().map((a) => a.edit.runtimeType), [
      AddKey,
      RemoveKeyFromAll,
      NewItemFromSchema,
    ]);
  });

  testWidgets('a refused edit shows its reason and keeps the tree', (
    tester,
  ) async {
    final c = await pumpTree(tester, '{"a":1,"b":2}');
    await c.apply(const RenameKey(1, 'b'));
    await _settle(tester);
    expect(c.status, JsonTreeStatus.ready);
    expect(c.editError, contains('b'));
    expect(find.byTooltip('Dismiss'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pump();
    expect(c.editError, isNull);
    expect(_rows, findsNWidgets(2));
  });

  testWidgets('search jumps to the revealed row', (tester) async {
    final json = jsonEncode([
      for (var i = 0; i < 1000; i++) {'id': i, if (i == 500) 'name': 'needle'},
    ]);
    final c = await pumpTree(tester, json);
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('proxie-json-tree')),
      matching: find.byType(Scrollable),
    );
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);

    await tester.enterText(
      find.byKey(const ValueKey('proxie-json-search')),
      'NEEDLE',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);

    expect(worker.sentOf<JsonSearch>().single.query, 'NEEDLE');
    expect(worker.sentOf<JsonReveal>(), hasLength(1));
    // Items 0..500 are rows 0..500; item 500's members follow it.
    const revealed = 502;
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      revealed * 28.0,
    );
    expect(c.currentMatch, isNotNull);
    expect(find.text('1/1'), findsOneWidget);
    final tile = tester.widget<JsonRowTile>(
      find.byWidgetPredicate((w) => w is JsonRowTile && w.highlighted),
    );
    expect(tile.row.key, 'name');
  });

  testWidgets('read-only trees offer no edits', (tester) async {
    await pumpTree(tester, '[{"id":1,"avatar":"a"},{"id":2}]', editable: false);
    expect(_rows, findsNWidgets(2));
    expect(find.byTooltip(RegExp('^Edit')), findsNothing);
    expect(find.text('+ avatar'), findsNothing);
    await tester.longPress(_rows.first);
    await tester.pumpAndSettle();
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('a worker failure shows Retry instead of crashing', (
    tester,
  ) async {
    worker.failWhen = (cmd) => cmd is OpenJson;
    final c = await pumpTree(tester, '{"a":1}');
    expect(c.status, JsonTreeStatus.failed);
    expect(find.text("Couldn't show this JSON"), findsOneWidget);

    worker.failWhen = null;
    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(c.status, JsonTreeStatus.ready);
    expect(_rows, findsOneWidget);
  });

  testWidgets('a closed document shows Retry, which reopens it', (
    tester,
  ) async {
    final c = await pumpTree(tester, '{"a":{"b":1}}');
    final docId = worker.sentOf<JsonRows>().first.docId;
    await CloseJson(docId).execute(worker.ctx);

    await tester.tap(_rows);
    await _settle(tester);
    expect(c.status, JsonTreeStatus.failed);
    expect(c.closed, isTrue);
    expect(find.text('This JSON document was closed'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await _settle(tester);
    expect(c.status, JsonTreeStatus.ready);
    expect(_rows, findsOneWidget);
  });

  testWidgets('revert drops the edits', (tester) async {
    final c = await pumpTree(tester, '[1]');
    await c.apply(const DuplicateItem(1));
    await _settle(tester);
    expect(find.text('Revert'), findsOneWidget);
    await tester.tap(find.text('Revert'));
    await _settle(tester);
    expect(c.edited, isFalse);
    expect(utf8.decode(await c.encode()), '[1]');
  });

  testWidgets('the call detail shows a read-only tree, raw text on demand', (
    tester,
  ) async {
    await store.upsert(_call('{"user":{"id":1}}'));
    await tester.pumpWidget(
      _app(
        CallDetail(
          worker: worker,
          calls: const Stream.empty(),
          callId: 'c1',
          renderCap: 5 * 1024 * 1024,
        ),
      ),
    );
    await _settle(tester);
    expect(find.byType(JsonTreeView), findsOneWidget);
    expect(find.byTooltip(RegExp('^Edit')), findsNothing);
    expect(find.textContaining('user: ', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('Raw text'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('proxie-raw-text')), findsOneWidget);
    // Indented in the worker, one line per row.
    expect(find.text('  "user": {\n', findRichText: true), findsOneWidget);
    expect(worker.sentOf<RawTextLines>().single.prettyJson, isTrue);
  });

  testWidgets('a changed body opens the document again', (tester) async {
    ProxieBody body(String json) => ProxieBody(
      bytes: Uint8List.fromList(utf8.encode(json)),
      contentType: 'application/json',
      kind: BodyKind.json,
    );
    Widget view(ProxieBody b) => _app(
      JsonBodyView(worker: worker, callId: 'c1', which: 'response', body: b),
    );
    await store.upsert(_call('{"a":1}'));
    await tester.pumpWidget(view(body('{"a":1}')));
    await _settle(tester);
    expect(find.textContaining('a: 1', findRichText: true), findsOneWidget);

    await store.upsert(_call('{"b":22}'));
    await tester.pumpWidget(view(body('{"b":22}')));
    await _settle(tester);
    expect(worker.sentOf<OpenJson>(), hasLength(2));
    expect(find.textContaining('b: 22', findRichText: true), findsOneWidget);
  });

  testWidgets('invalid JSON shows why, over its raw text', (tester) async {
    await store.upsert(_call('{"a":'));
    await tester.pumpWidget(
      _app(
        JsonBodyView(
          worker: worker,
          callId: 'c1',
          which: 'response',
          body: ProxieBody(
            bytes: Uint8List.fromList(utf8.encode('{"a":')),
            contentType: 'application/json',
            kind: BodyKind.json,
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.textContaining('Invalid JSON'), findsOneWidget);
    expect(find.text('{"a":'), findsOneWidget);
  });

  testWidgets('a root array gets a header with its schema and array edits', (
    tester,
  ) async {
    final c = await pumpTree(tester, '[{"id":1,"avatar":"a"},{"id":2}]');
    final header = find.byKey(const ValueKey('proxie-json-root'));
    expect(
      find.descendant(
        of: header,
        matching: find.textContaining(
          '{id: number, avatar?: string}',
          findRichText: true,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: header,
        matching: find.textContaining('[2 items]', findRichText: true),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('Edit root'));
    await tester.pumpAndSettle();
    expect(find.text('Add key to all'), findsOneWidget);
    expect(find.text('Remove key from all'), findsOneWidget);
    expect(find.text('New item from schema'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
    await tester.tap(find.text('Add key to all'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('proxie-key-field')), 'k');
    await tester.enterText(
      find.byKey(const ValueKey('proxie-value-field')),
      'v',
    );
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(
      utf8.decode(await c.encode()),
      '[{"id":1,"avatar":"a","k":"v"},{"id":2,"k":"v"}]',
    );

    await tester.tap(find.byTooltip('Edit root'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New item from schema'));
    await _settle(tester);
    // The header follows the edit.
    expect(
      find.descendant(
        of: header,
        matching: find.textContaining('[3 items]', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(_rows, findsNWidgets(3));
  });

  testWidgets('a root object header offers Add key', (tester) async {
    final c = await pumpTree(tester, '{"a":1}');
    await tester.tap(find.byTooltip('Edit root'));
    await tester.pumpAndSettle();
    expect(find.text('Add key'), findsOneWidget);
    expect(find.text('Rename key'), findsNothing);
    await tester.tap(find.text('Add key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('proxie-key-field')), 'b');
    await tester.tap(find.byKey(const ValueKey('proxie-kind-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Number').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('proxie-value-field')),
      '12345678901234567890',
    );
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(utf8.decode(await c.encode()), '{"a":1,"b":12345678901234567890}');
  });

  testWidgets('a read-only header shows the schema but no menu', (
    tester,
  ) async {
    await pumpTree(tester, '[{"id":1}]', editable: false);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('proxie-json-root')),
        matching: find.textContaining('{id: number}', findRichText: true),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip(RegExp('^Edit')), findsNothing);
  });

  testWidgets('a scalar root has no header', (tester) async {
    await pumpTree(tester, '42');
    expect(find.byKey(const ValueKey('proxie-json-root')), findsNothing);
    expect(_rows, findsOneWidget);
  });

  testWidgets('edits in an editor scope stay out of the view scope', (
    tester,
  ) async {
    final editor = await pumpTree(tester, '[1]', scope: 'edit:rule');
    await editor.apply(const DuplicateItem(1));
    await _settle(tester);
    expect(utf8.decode(await editor.encode()), '[1,1]');

    final view = await pumpTree(tester, '[1]', upsert: false);
    expect(view.visibleCount, 1);
    expect(view.edited, isFalse);
    expect(utf8.decode(await view.encode()), '[1]');
    expect(find.text('Revert'), findsNothing);
  });

  testWidgets('reopening an edited scope keeps it dirty, with Revert', (
    tester,
  ) async {
    final first = await pumpTree(tester, '[1]', scope: 'edit:rule');
    await first.apply(const DuplicateItem(1));
    await _settle(tester);

    final again = await pumpTree(
      tester,
      '[1]',
      scope: 'edit:rule',
      upsert: false,
    );
    expect(again.edited, isTrue);
    expect(again.visibleCount, 2);
    expect(find.text('Revert'), findsOneWidget);
  });

  testWidgets('a worker failure during an edit is not a refused edit', (
    tester,
  ) async {
    final c = await pumpTree(tester, '[1]');
    worker
      ..failure = const ProxieWorkerException(
        type: 'SqliteException',
        message: 'disk I/O error',
        stackTrace: '',
      )
      ..failWhen = (cmd) => cmd is JsonApply;
    await c.apply(const DuplicateItem(1));
    await _settle(tester);
    expect(c.status, JsonTreeStatus.failed);
    expect(c.editError, isNull);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('a failed schema fetch leaves the tree usable', (tester) async {
    worker.failWhen = (cmd) => cmd is JsonSchema;
    final c = await pumpTree(tester, '[{"id":1}]');
    expect(c.status, JsonTreeStatus.ready);
    expect(c.hasSchema(0), isTrue);
    expect(c.schemaOf(0), isNull);
    expect(find.textContaining('{id', findRichText: true), findsNothing);
    expect(_rows, findsOneWidget);
  });

  testWidgets('next and previous wrap around the matches', (tester) async {
    final c = await pumpTree(tester, '[{"k":1},{"k":2},{"k":3}]');
    await c.search('k');
    await _settle(tester);
    expect(c.matches, hasLength(3));
    expect(c.matchIndex, 0);
    await tester.tap(find.byTooltip('Next match'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Next match'));
    await _settle(tester);
    expect(find.text('3/3'), findsOneWidget);
    await tester.tap(find.byTooltip('Next match'));
    await _settle(tester);
    expect(c.matchIndex, 0);
    await tester.tap(find.byTooltip('Previous match'));
    await _settle(tester);
    expect(c.matchIndex, 2);
    final tile = tester.widget<JsonRowTile>(
      find.byWidgetPredicate((w) => w is JsonRowTile && w.highlighted),
    );
    expect(tile.row.preview, '3');
  });

  testWidgets('a match in view does not scroll; one at the end clamps', (
    tester,
  ) async {
    final json = jsonEncode([
      {'near': 1},
      for (var i = 1; i < 1000; i++) {'id': i},
      {'far': 1},
    ]);
    final c = await pumpTree(tester, json);
    final position = tester
        .state<ScrollableState>(
          find.descendant(
            of: find.byKey(const ValueKey('proxie-json-tree')),
            matching: find.byType(Scrollable),
          ),
        )
        .position;
    await c.search('near');
    await _settle(tester);
    expect(c.currentMatch, isNotNull);
    expect(position.pixels, 0);

    await c.search('far');
    await _settle(tester);
    expect(position.pixels, position.maxScrollExtent);
    expect(position.maxScrollExtent, lessThan(1001 * 28.0));
  });

  testWidgets('a capped search says so', (tester) async {
    final c = await pumpTree(
      tester,
      jsonEncode([for (var i = 0; i < 600; i++) 'hit']),
    );
    await c.search('hit');
    await _settle(tester);
    expect(c.matches, hasLength(JsonTreeController.searchLimit));
    expect(find.text('1/500+'), findsOneWidget);
  });

  testWidgets('rows expose their name, state and chips to accessibility', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpTree(tester, '[{"id":1,"avatar":"a"},{"id":2}]');
    expect(find.byTooltip('Edit [0]'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('+ avatar')),
      isSemantics(label: 'Add key avatar', isButton: true, hasTapAction: true),
    );
    expect(
      tester.getSemantics(find.byKey(const ValueKey(1))),
      isSemantics(
        label: '[0]: {2 keys}',
        hasExpandedState: true,
        isExpanded: false,
        hasSelectedState: true,
        isSelected: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('switching tree and raw keeps both views', (tester) async {
    await store.upsert(_call('{"a":1}'));
    await tester.pumpWidget(
      _app(
        JsonBodyView(
          worker: worker,
          callId: 'c1',
          which: 'response',
          body: _call('{"a":1}').response!.body,
        ),
      ),
    );
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('proxie-json-search')),
      'a',
    );
    await tester.tap(find.byTooltip('Raw text'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Tree view'));
    await _settle(tester);
    await tester.tap(find.byTooltip('Raw text'));
    await _settle(tester);
    expect(worker.sentOf<RawTextLines>(), hasLength(1));
    await tester.tap(find.byTooltip('Tree view'));
    await _settle(tester);
    expect(find.text('a'), findsOneWidget); // the search text survived
    expect(worker.sentOf<OpenJson>(), hasLength(1));
  });

  testWidgets('a reload of the same body keeps the tree, scroll and search', (
    tester,
  ) async {
    final json = jsonEncode([for (var i = 0; i < 500; i++) i]);
    Widget view() => _app(
      JsonBodyView(
        worker: worker,
        callId: 'c1',
        which: 'response',
        // A fresh copy of the bytes, as each refetch of the call gives.
        body: _call(json).response!.body,
      ),
    );
    await store.upsert(_call(json));
    await tester.pumpWidget(view());
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('proxie-json-search')),
      'abc',
    );
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('proxie-json-tree')),
      matching: find.byType(Scrollable),
    );
    tester.state<ScrollableState>(scrollable).position.jumpTo(1400);
    await tester.pump();

    await tester.pumpWidget(view());
    // No blank frame: the tree is still there right away.
    expect(_rows, findsWidgets);
    await _settle(tester);
    expect(worker.sentOf<OpenJson>(), hasLength(1));
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 1400);
    expect(find.text('abc'), findsOneWidget);
  });

  testWidgets('a refused edit is recognized by its code, not its type name', (
    tester,
  ) async {
    final c = await pumpTree(tester, '[1]');
    worker
      // A minified web build mangles the type name.
      ..failure = const ProxieWorkerException(
        type: 'minified:aB',
        message: 'Invalid argument(s): Node was deleted',
        stackTrace: '',
        code: ProxieWorkerException.argumentCode,
      )
      ..failWhen = (cmd) => cmd is JsonApply;
    await c.apply(const DeleteNode(1));
    await _settle(tester);
    expect(c.status, JsonTreeStatus.ready);
    expect(c.editError, contains('Node was deleted'));
  });

  testWidgets('a closed document is recognized by its code', (tester) async {
    final c = await pumpTree(tester, '{"a":{"b":1}}');
    worker
      ..failure = const ProxieWorkerException(
        type: 'minified:cD',
        message: 'JsonDocumentClosed: no open JSON document 0',
        stackTrace: '',
        code: JsonDocumentClosed.errorCode,
      )
      ..failWhen = (cmd) => cmd is JsonToggle;
    await c.toggle(1);
    await _settle(tester);
    expect(c.status, JsonTreeStatus.failed);
    expect(c.closed, isTrue);
  });

  testWidgets('a same-length body change opens the document again', (
    tester,
  ) async {
    Widget view(String json) => _app(
      JsonBodyView(
        worker: worker,
        callId: 'c1',
        which: 'response',
        body: _call(json).response!.body,
      ),
    );
    await store.upsert(_call('{"a":1}'));
    await tester.pumpWidget(view('{"a":1}'));
    await _settle(tester);
    await store.upsert(_call('{"a":2}'));
    await tester.pumpWidget(view('{"a":2}'));
    await _settle(tester);
    expect(find.textContaining('a: 2', findRichText: true), findsOneWidget);
  });

  testWidgets('the call detail raw view is read-only', (tester) async {
    await store.upsert(_call('{"a":1}'));
    await tester.pumpWidget(
      _app(
        CallDetail(
          worker: worker,
          calls: const Stream.empty(),
          callId: 'c1',
          renderCap: 5 * 1024 * 1024,
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byTooltip('Raw text'));
    await _settle(tester);
    expect(find.byKey(const ValueKey('proxie-raw-text')), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Edit anyway'), findsNothing);
  });

  group('RawTextView', () {
    Future<void> pumpRaw(
      WidgetTester tester,
      Uint8List bytes, {
      int limit = 1024 * 1024,
    }) async {
      await tester.pumpWidget(
        _app(
          RawTextView(
            worker: worker,
            bytes: bytes,
            editable: true,
            rawEditableLimit: limit,
          ),
        ),
      );
      await _settle(tester);
    }

    testWidgets('a 2 MB body opens read-only with "Edit anyway"', (
      tester,
    ) async {
      final line = '${'a' * 99}\n';
      final bytes = Uint8List.fromList(
        utf8.encode(line * (2 * 1024 * 1024 ~/ line.length)),
      );
      await pumpRaw(tester, bytes);
      expect(find.text('Edit anyway'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      // Lines are built lazily.
      expect(find.byType(Text).evaluate().length, lessThan(80));
      expect(worker.sentOf<RawTextLines>(), hasLength(1));
    });

    testWidgets('"Edit anyway" switches to a text field', (tester) async {
      await pumpRaw(tester, Uint8List.fromList(utf8.encode('a\nb')), limit: 2);
      await tester.tap(find.text('Edit anyway'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('a\nb'), findsOneWidget);
    });

    testWidgets('a small body is editable at once', (tester) async {
      await pumpRaw(tester, Uint8List.fromList(utf8.encode('hello')));
      expect(find.text('Edit anyway'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('an editable view shows the new body after a change', (
      tester,
    ) async {
      Widget view(String text) => _app(
        RawTextView(
          worker: worker,
          bytes: Uint8List.fromList(utf8.encode(text)),
          editable: true,
        ),
      );
      await tester.pumpWidget(view('first'));
      await _settle(tester);
      await tester.enterText(find.byType(TextField), 'first, edited');
      // The same bytes again: the edit in progress is kept.
      await tester.pumpWidget(view('first'));
      await _settle(tester);
      expect(find.text('first, edited'), findsOneWidget);
      // Other bytes: the field shows them, never the old text.
      await tester.pumpWidget(view('second'));
      expect(find.text('first, edited'), findsNothing);
      await _settle(tester);
      expect(
        find.descendant(
          of: find.byType(TextField),
          matching: find.text('second'),
        ),
        findsOneWidget,
      );
      expect(find.text('first, edited'), findsNothing);
    });

    testWidgets('a reload keeps the lines until new ones arrive', (
      tester,
    ) async {
      Widget view(String text) => _app(
        RawTextView(
          worker: worker,
          bytes: Uint8List.fromList(utf8.encode(text)),
        ),
      );
      await tester.pumpWidget(view('first'));
      await _settle(tester);
      // Equal bytes in a new list: nothing is split again.
      await tester.pumpWidget(view('first'));
      await _settle(tester);
      expect(worker.sentOf<RawTextLines>(), hasLength(1));
      // New bytes: the old text stays up for the frame the worker takes.
      await tester.pumpWidget(view('second'));
      expect(find.text('first'), findsOneWidget);
      await _settle(tester);
      expect(find.text('second'), findsOneWidget);
      expect(worker.sentOf<RawTextLines>(), hasLength(2));
    });

    testWidgets('pieces of a long line are not colored mid-token', (
      tester,
    ) async {
      final json = '{"a":"${'x' * 3000}"}';
      await tester.pumpWidget(
        _app(
          RawTextView(
            worker: worker,
            bytes: Uint8List.fromList(utf8.encode(json)),
            prettyJson: true,
          ),
        ),
      );
      await _settle(tester);
      Text line(int i) => tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('proxie-line-$i')),
          matching: find.byType(Text),
        ),
      );
      expect(line(1).textSpan, isNotNull); // starts the line: colored
      expect(line(2).textSpan, isNull); // continues it: plain
      expect(line(2).data, startsWith('x'));
    });

    testWidgets('a worker failure shows Retry', (tester) async {
      worker.failWhen = (cmd) => cmd is RawTextLines;
      await pumpRaw(tester, Uint8List.fromList(utf8.encode('hello')));
      expect(find.text("Couldn't show this body"), findsOneWidget);
      worker.failWhen = null;
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      expect(find.byType(TextField), findsOneWidget);
    });
  });

  test('sameBytes compares contents, aligned or not', () {
    final a = Uint8List.fromList(List.generate(11, (i) => i));
    expect(sameBytes(a, Uint8List.fromList(a)), isTrue);
    expect(sameBytes(a, Uint8List.fromList([...a.take(10), 99])), isFalse);
    expect(sameBytes(a, Uint8List.fromList([99, ...a.skip(1)])), isFalse);
    expect(sameBytes(a, Uint8List(10)), isFalse);
    // Views at odd offsets compare byte by byte.
    final big = Uint8List.fromList([0, ...a]);
    expect(sameBytes(Uint8List.sublistView(big, 1), a), isTrue);
  });

  test('textLines keeps line breaks and caps line length', () {
    expect(textLines(''), ['']);
    expect(textLines('a\nb\n'), ['a\n', 'b\n']);
    expect(textLines('a\n\nb'), ['a\n', '\n', 'b']);
    final long = '${'x' * 4500}\ny';
    final lines = textLines(long);
    expect(lines.join(), long);
    expect(lines.every((l) => l.length <= rawLineLimit), isTrue);
    expect(lines.last, 'y');
    final emoji = List.filled(3000, '\u{1F600}').join();
    for (final l in textLines(emoji)) {
      expect(
        l.codeUnitAt(l.length - 1),
        isNot(inInclusiveRange(0xD800, 0xDBFF)),
      );
    }
  });

  test('RawTextLines indents JSON and rejects invalid UTF-8', () async {
    final ctx = WorkerContext(store: store, config: const ProxieConfig());
    final pretty = await RawTextLines(
      Uint8List.fromList(utf8.encode('{"a":[1]}')),
      prettyJson: true,
    ).execute(ctx);
    expect(pretty, ['{\n', '  "a": [\n', '    1\n', '  ]\n', '}']);
    final invalidJson = await RawTextLines(
      Uint8List.fromList(utf8.encode('{"a":')),
      prettyJson: true,
    ).execute(ctx);
    expect(invalidJson, ['{"a":']);
    expect(
      await RawTextLines(Uint8List.fromList([0xC3, 0x28])).execute(ctx),
      isNull,
    );
    expect(
      await RawTextLines(
        Uint8List.fromList([0x63, 0x61, 0x66, 0xE9]),
        latin1: true,
      ).execute(ctx),
      ['café'],
    );
  });

  test('jsonLineSpans colors keys, strings and numbers', () {
    const colors = ProxieColors();
    const line = r'  "id": 12, "n": "x\"y", "ok": true';
    final spans = jsonLineSpans(line, colors);
    expect(spans.map((s) => s.text).join(), line);
    Color? colorOf(String text) =>
        spans.firstWhere((s) => s.text == text).style?.color;
    expect(colorOf('"id"'), colors.jsonKey);
    expect(colorOf('12'), colors.jsonNumber);
    expect(colorOf(r'"x\"y"'), colors.jsonString);
    expect(colorOf('true'), colors.jsonNumber);
  });

  test('JSON colors are the brief values in dark, readable in light', () {
    final dark = ProxieTheme.dark().extension<ProxieColors>()!;
    expect(dark.jsonKey, const Color(0xFF7EE787));
    expect(dark.jsonString, const Color(0xFFA5D6FF));
    expect(dark.jsonNumber, const Color(0xFFFFA657));
    final light = ProxieTheme.light().extension<ProxieColors>()!;
    final surface = ProxieTheme.light().colorScheme.surface;
    for (final c in [light.jsonKey, light.jsonString, light.jsonNumber]) {
      final ratio =
          (surface.computeLuminance() + 0.05) / (c.computeLuminance() + 0.05);
      expect(ratio, greaterThan(4.5));
    }
  });

  test('parseJsonValue reads each kind', () {
    expect(parseJsonValue(JsonKind.string, ' a ').value, ' a ');
    expect(
      parseJsonValue(JsonKind.number, '12345678901234567890').value,
      const JsonNumber('12345678901234567890'),
    );
    expect(parseJsonValue(JsonKind.number, '1.').error, isNotNull);
    expect(parseJsonValue(JsonKind.boolean, 'false').value, false);
    expect(parseJsonValue(JsonKind.nullValue, 'x').value, isNull);
    expect(parseJsonValue(JsonKind.object, '{"a":1}').value, {
      'a': const JsonNumber('1'),
    });
    expect(parseJsonValue(JsonKind.object, '[1]').error, 'Not an object');
    expect(parseJsonValue(JsonKind.array, '[').error, startsWith('Invalid'));
    expect(parseJsonValue(JsonKind.array, '[12345678901234567890]').value, [
      const JsonNumber('12345678901234567890'),
    ]);
    expect(
      parseJsonValue(JsonKind.object, '{"a":1,"a":2}').error,
      contains('Duplicate'),
    );
  });
}
