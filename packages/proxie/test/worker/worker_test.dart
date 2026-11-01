import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/worker/in_process_worker.dart';
import 'package:proxie/src/worker/isolate_worker.dart';
import 'package:proxie/src/worker/worker_factory_web.dart' as web;

final _dirs = <Directory>[];

Directory _tempDir() {
  final d = Directory.systemTemp.createTempSync('proxie_worker_');
  _dirs.add(d);
  return d;
}

String _join(String a, String b) => '$a${Platform.pathSeparator}$b';

ProxieBody _json(String s) =>
    ProxieBody.from(Uint8List.fromList(utf8.encode(s)), 'application/json');

ProxieCall _call(
  String id, {
  DateTime? startedAt,
  Map<String, List<String>> requestHeaders = const {},
  String requestBody = '{"q":1}',
  Map<String, List<String>> responseHeaders = const {},
}) => ProxieCall(
  id: id,
  sessionId: 1,
  adapter: 'test',
  request: ProxieRequest(
    method: 'GET',
    url: Uri.parse('https://api.test/$id'),
    headers: requestHeaders,
    body: _json(requestBody),
  ),
  response: ProxieResponse(
    statusCode: 200,
    reasonPhrase: 'OK',
    headers: responseHeaders,
    body: _json('{"ok":true}'),
  ),
  startedAt: startedAt ?? DateTime.now().toUtc(),
);

/// Throws inside the worker.
class _Boom extends WorkerCommand<void> {
  const _Boom();

  @override
  Future<void> execute(WorkerContext ctx) async => throw StateError('boom');
}

/// Kills the isolate it runs in without replying.
class _Die extends WorkerCommand<void> {
  const _Die();

  @override
  Future<void> execute(WorkerContext ctx) {
    Isolate.current.kill(priority: Isolate.immediate);
    return Future<void>.delayed(const Duration(days: 1));
  }
}

/// Returns a value that cannot cross an isolate boundary.
class _Unsendable extends WorkerCommand<Object> {
  const _Unsendable();

  @override
  Future<Object> execute(WorkerContext ctx) async => RawReceivePort();
}

/// Uses and reads back a context resource.
class _Resource extends WorkerCommand<int> {
  const _Resource();

  @override
  Future<int> execute(WorkerContext ctx) async {
    final n = (ctx.resources['n'] as int? ?? 0) + 1;
    ctx.resources['n'] = n;
    return n;
  }
}

/// Writes a marker file when closed, so a test can see the close happen.
class _ClosingStore extends MemoryStore {
  _ClosingStore(this.marker);

  final String marker;

  @override
  Future<void> close() async => File(marker).writeAsStringSync('closed');
}

// A plain function so the closure captures only [marker] and stays sendable.
ProxieStore Function() _closingOpener(String marker) =>
    () => _ClosingStore(marker);

void _contract(
  String name,
  Future<ProxieWorker> Function(ProxieConfig config) spawn,
) {
  group(name, () {
    late ProxieWorker worker;

    setUp(() async => worker = await spawn(const ProxieConfig()));
    tearDown(() => worker.dispose());

    test('starts a session on spawn', () async {
      expect(worker.sessionId, 1);
      final sessions = await worker.run(const ListSessions());
      expect(sessions.map((s) => s.id), [1]);
    });

    test('upsert then QueryCalls returns the call', () async {
      worker.upsert(_call('a'));
      final rows = await worker.run(
        const QueryCalls(CallQuery(), offset: 0, limit: 10),
      );
      expect(rows.map((r) => r.id), ['a']);
      final got = await worker.run(const GetCall('a'));
      expect(got!.request.url, Uri.parse('https://api.test/a'));
      expect(await worker.run(const GetCall('missing')), isNull);
    });

    test('1,000 upserts then CountCalls is 1000', () async {
      for (var i = 0; i < 1000; i++) {
        worker.upsert(_call('c$i'));
      }
      expect(await worker.run(const CountCalls()), 1000);
    });

    test('exceptions surface as a failed Future with the original '
        'message', () async {
      await expectLater(
        worker.run(const _Boom()),
        throwsA(
          isA<ProxieWorkerException>()
              .having((e) => e.type, 'type', 'StateError')
              .having((e) => e.message, 'message', contains('boom'))
              .having((e) => e.stackTrace, 'stackTrace', isNotEmpty),
        ),
      );
      // The worker keeps serving commands.
      expect(await worker.run(const CountCalls()), 0);
    });

    test('upsert masks sensitive headers and JSON keys', () async {
      worker.upsert(
        _call(
          'm',
          requestHeaders: {
            'Authorization': ['Bearer secret'],
            'X-Other': ['keep'],
          },
          requestBody: '{"password":"hunter2","user":"bob"}',
          responseHeaders: {
            'Set-Cookie': ['sid=1'],
          },
        ),
      );
      final got = (await worker.run(const GetCall('m')))!;
      expect(got.request.headers['authorization'], [kMask]);
      expect(got.request.headers['x-other'], ['keep']);
      expect(got.response!.headers['set-cookie'], [kMask]);
      final body = jsonDecode(utf8.decode(got.request.body.bytes)) as Map;
      expect(body['password'], kMask);
      expect(body['user'], 'bob');
    });

    test('rules and presets round-trip', () async {
      final rule = ProxieRule(
        id: 'r1',
        name: 'Rule',
        kind: RuleKind.breakpoint,
        matcher: UrlMatcher('*/a*'),
      );
      await worker.run(SaveRules([rule]));
      final rules = await worker.run(const LoadRules());
      expect(rules.map((r) => r.id), ['r1']);

      await worker.run(
        const SavePreset(
          'p1',
          'Teapot',
          MapLocalAction(delay: Duration(seconds: 2)),
        ),
      );
      final presets = await worker.run(const LoadPresets());
      expect(presets.map((p) => p.label), ['Teapot']);
      expect(presets.single.build(null).delay, const Duration(seconds: 2));
    });

    test('Trim and ClearAll', () async {
      for (var i = 0; i < 5; i++) {
        worker.upsert(
          _call(
            't$i',
            startedAt: DateTime.now().toUtc().add(Duration(seconds: i)),
          ),
        );
      }
      await worker.run(const Trim(maxCalls: 2));
      final rows = await worker.run(
        const QueryCalls(CallQuery(), offset: 0, limit: 10),
      );
      expect(rows.map((r) => r.id), ['t4', 't3']);
      await worker.run(const ClearAll());
      expect(await worker.run(const CountCalls()), 0);
    });

    test('context resources persist between commands', () async {
      expect(await worker.run(const _Resource()), 1);
      expect(await worker.run(const _Resource()), 2);
    });

    test(
      'run after dispose throws StateError; dispose is idempotent',
      () async {
        await Future.wait([worker.dispose(), worker.dispose()]);
        await worker.dispose();
        await expectLater(worker.run(const CountCalls()), throwsStateError);
        worker.upsert(_call('late')); // ignored, never throws
      },
    );

    test('commands queued before dispose still complete', () async {
      worker.upsert(_call('q'));
      final count = worker.run(const CountCalls());
      await worker.dispose();
      expect(await count, 1);
    });
  });
}

void main() {
  tearDownAll(() {
    for (final d in _dirs) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  _contract(
    'IsolateWorker',
    (config) => spawnProxieWorker(config, supportDir: _tempDir().path),
  );
  _contract('InProcessWorker', (config) => web.spawnProxieWorker(config));

  test('InProcessWorker dispose closes the store', () async {
    final marker = _join(_tempDir().path, 'closed');
    final w = await InProcessWorker.start(
      _ClosingStore(marker),
      const ProxieConfig(),
    );
    await w.run(const CountCalls());
    expect(File(marker).existsSync(), isFalse);
    await w.dispose();
    expect(File(marker).existsSync(), isTrue);
  });

  group('IsolateWorker on disk', () {
    test('stores proxie.db and spill under <supportDir>/proxie', () async {
      final dir = _tempDir();
      final w = await spawnProxieWorker(
        const ProxieConfig(),
        supportDir: dir.path,
      );
      await w.run(const CountCalls());
      final proxieDir = _join(dir.path, 'proxie');
      expect(File(_join(proxieDir, 'proxie.db')).existsSync(), isTrue);
      expect(Directory(_join(proxieDir, 'spill')).existsSync(), isTrue);
      await w.dispose();
    });

    test('dispose closes the store and the isolate exits', () async {
      final marker = _join(_tempDir().path, 'closed');
      final w = await IsolateWorker.spawn(
        const ProxieConfig(),
        _closingOpener(marker),
      );
      final exit = ReceivePort();
      w.isolate.addOnExitListener(exit.sendPort);
      w.upsert(_call('d'));
      await w.run(const CountCalls());
      expect(File(marker).existsSync(), isFalse);
      await w.dispose();
      expect(File(marker).existsSync(), isTrue);
      await exit.first.timeout(const Duration(seconds: 10));
      exit.close();
    });

    test('history survives into the next worker', () async {
      final dir = _tempDir();
      final w = await spawnProxieWorker(
        const ProxieConfig(),
        supportDir: dir.path,
      );
      w.upsert(_call('d'));
      await w.dispose();

      final again = await spawnProxieWorker(
        const ProxieConfig(),
        supportDir: dir.path,
      );
      expect(await again.run(const CountCalls()), 1);
      expect(again.sessionId, 2);
      await again.dispose();
    });

    test('persistHistory false creates no files', () async {
      final dir = _tempDir();
      final w = await spawnProxieWorker(
        const ProxieConfig(persistHistory: false),
        supportDir: dir.path,
      );
      w.upsert(_call('x'));
      expect(await w.run(const CountCalls()), 1);
      await w.dispose();
      expect(dir.listSync(), isEmpty);
    });

    test('a database that cannot be opened fails spawn', () async {
      final dir = _tempDir();
      // A directory where the database file should be.
      Directory(
        _join(_join(dir.path, 'proxie'), 'proxie.db'),
      ).createSync(recursive: true);
      await expectLater(
        spawnProxieWorker(
          const ProxieConfig(),
          supportDir: dir.path,
        ).timeout(const Duration(seconds: 20)),
        throwsA(isA<ProxieWorkerException>()),
      );
    });

    test('trim on start removes calls older than retentionAge', () async {
      final dir = _tempDir();
      final first = await spawnProxieWorker(
        const ProxieConfig(),
        supportDir: dir.path,
      );
      final now = DateTime.now().toUtc();
      first.upsert(
        _call('old', startedAt: now.subtract(const Duration(days: 8))),
      );
      first.upsert(_call('new', startedAt: now));
      expect(await first.run(const CountCalls()), 2);
      await first.dispose();

      final second = await spawnProxieWorker(
        const ProxieConfig(retentionAge: Duration(days: 7)),
        supportDir: dir.path,
      );
      final rows = await second.run(
        const QueryCalls(CallQuery(), offset: 0, limit: 10),
      );
      expect(rows.map((r) => r.id), ['new']);
      await second.dispose();
    });

    test('an unexpected isolate exit fails pending and later runs', () async {
      final w = await spawnProxieWorker(
        const ProxieConfig(persistHistory: false),
      );
      await expectLater(w.run(const _Die()), throwsStateError);
      await expectLater(w.run(const CountCalls()), throwsStateError);
      w.upsert(_call('after')); // ignored, never throws
      await w.dispose();
    });

    test('a result that cannot be sent fails that run only', () async {
      final w = await spawnProxieWorker(
        const ProxieConfig(persistHistory: false),
      );
      await expectLater(
        w.run(const _Unsendable()),
        throwsA(isA<ProxieWorkerException>()),
      );
      expect(await w.run(const CountCalls()), 0);
      await w.dispose();
    });
  });
}
