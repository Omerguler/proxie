import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:proxie/proxie.dart';

import 'support/temp_dir.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.support);

  final String support;
  int calls = 0;

  @override
  Future<String?> getApplicationSupportPath() async {
    calls++;
    return support;
  }
}

class _FakeAdapter implements ProxieCaptureAdapter {
  int attached = 0;
  int detached = 0;

  @override
  String get name => 'fake';

  @override
  bool get supportsReplay => false;

  @override
  void attach(ProxieEngine engine) => attached++;

  @override
  void detach() => detached++;

  @override
  Future<ProxieResponse> replay(ProxieRequest request) =>
      throw UnimplementedError();
}

class _LogAdapter implements ProxieCaptureAdapter {
  _LogAdapter(this.name, this.log);

  @override
  final String name;
  final List<String> log;

  @override
  bool get supportsReplay => false;

  @override
  void attach(ProxieEngine engine) => log.add('$name.attach');

  @override
  void detach() => log.add('$name.detach');

  @override
  Future<ProxieResponse> replay(ProxieRequest request) =>
      throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late PathProviderPlatform originalProvider;
  late _FakePathProvider provider;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('proxie_enablement_');
    originalProvider = PathProviderPlatform.instance;
    provider = _FakePathProvider(tmp.path);
    PathProviderPlatform.instance = provider;
  });

  tearDown(() async {
    await Proxie.shutdown();
    PathProviderPlatform.instance = originalProvider;
    await deleteTempDir(tmp);
  });

  bool dbExists() => File(
    '${tmp.path}${Platform.pathSeparator}proxie'
    '${Platform.pathSeparator}proxie.db',
  ).existsSync();

  test('kProxieEnabled is kDebugMode || PROXIE define', () {
    expect(kProxieEnabled, kDebugMode || const bool.fromEnvironment('PROXIE'));
    // Tests run in debug mode.
    expect(kProxieEnabled, isTrue);
  });

  group('enabled: false (Review Focus 4)', () {
    test('spawns no worker and creates no proxie.db', () async {
      final adapter = _FakeAdapter();
      await Proxie.init(enabled: false, adapters: [adapter]);
      // Give a stray spawn time to touch the disk.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(Proxie.isActive, isFalse);
      expect(Proxie.engine, isNull);
      expect(provider.calls, 0, reason: 'support dir was never resolved');
      expect(Directory('${tmp.path}/proxie').existsSync(), isFalse);
      expect(dbExists(), isFalse);
      expect(adapter.attached, 0);
    });

    test('httpClient returns the inner client unchanged', () async {
      await Proxie.init(enabled: false);
      final inner = MockClient((_) async => http.Response('ok', 200));
      expect(identical(Proxie.httpClient(inner: inner), inner), isTrue);
      expect(Proxie.httpClient(), isNot(isA<ProxieHttpClient>()));
    });

    test('a later init(enabled: true) is ignored', () async {
      await Proxie.init(enabled: false);
      await Proxie.init(config: const ProxieConfig(persistHistory: false));
      expect(Proxie.isActive, isFalse);
      expect(provider.calls, 0);
    });

    test('open is a no-op', () async {
      await Proxie.init(enabled: false);
      Proxie.open();
      expect(Proxie.isActive, isFalse);
    });

    testWidgets('wrap returns the exact child', (tester) async {
      await Proxie.init(enabled: false);
      const child = Text('host', textDirection: TextDirection.ltr);
      late Widget wrapped;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            return wrapped = Proxie.wrap(context, child);
          },
        ),
      );
      expect(identical(wrapped, child), isTrue);
    });
  });

  group('enabled: true', () {
    test('control: the same setup creates proxie.db', () async {
      final adapter = _FakeAdapter();
      await Proxie.init(adapters: [adapter]);
      expect(Proxie.isActive, isTrue);
      expect(Proxie.engine, isNotNull);
      expect(provider.calls, 1);
      expect(dbExists(), isTrue);
      expect(adapter.attached, 1);
      await Proxie.shutdown();
      expect(adapter.detached, 1);
      expect(Proxie.isActive, isFalse);
      expect(Proxie.engine, isNull);
    });

    test('engine uses the worker session and the given config', () async {
      const config = ProxieConfig(persistHistory: false, splitWidth: 900);
      await Proxie.init(config: config);
      expect(Proxie.engine!.sessionId, 1);
      expect(identical(Proxie.engine!.config, config), isTrue);
    });

    test('init twice returns the same future and ignores the second '
        'call', () async {
      final a = _FakeAdapter();
      final b = _FakeAdapter();
      final first = Proxie.init(
        adapters: [a],
        config: const ProxieConfig(persistHistory: false),
      );
      final second = Proxie.init(adapters: [b], enabled: false);
      expect(identical(first, second), isTrue);
      await first;
      expect(Proxie.isActive, isTrue);
      expect(a.attached, 1);
      expect(b.attached, 0);
    });

    test('shutdown allows a fresh init', () async {
      await Proxie.init(config: const ProxieConfig(persistHistory: false));
      final engine = Proxie.engine;
      await Proxie.shutdown();
      await Proxie.init(config: const ProxieConfig(persistHistory: false));
      expect(Proxie.isActive, isTrue);
      expect(identical(Proxie.engine, engine), isFalse);
    });

    test('shutdown while init is running waits for it', () async {
      final adapter = _FakeAdapter();
      final init = Proxie.init(
        adapters: [adapter],
        config: const ProxieConfig(persistHistory: false),
      );
      await Proxie.shutdown();
      await init;
      expect(Proxie.isActive, isFalse);
      expect(adapter.attached, 1);
      expect(adapter.detached, 1);
    });

    test('rules are loaded from the worker', () async {
      await Proxie.init();
      final engine = Proxie.engine!;
      expect(engine.rules.rules, isEmpty);
    });

    test('a failed init is reported, leaves Proxie inactive and can be '
        'retried', () async {
      final errors = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = errors.add;
      addTearDown(() => FlutterError.onError = previous);
      // A file where the proxie directory must go: the store cannot open.
      File('${tmp.path}${Platform.pathSeparator}proxie').writeAsStringSync('');

      await Proxie.init();
      expect(Proxie.isActive, isFalse);
      expect(errors, hasLength(1));
      expect(errors.single.library, 'proxie');

      await Proxie.init(config: const ProxieConfig(persistHistory: false));
      expect(Proxie.isActive, isTrue);
    });
  });

  group('lifecycle races', () {
    test('init during shutdown waits for the teardown, then opens the same '
        'database again', () async {
      final log = <String>[];
      await Proxie.init(adapters: [_LogAdapter('a', log)]);
      final down = Proxie.shutdown();
      final up = Proxie.init(adapters: [_LogAdapter('b', log)]);
      await Future.wait([down, up]);
      expect(log, ['a.attach', 'a.detach', 'b.attach']);
      expect(Proxie.isActive, isTrue);
      // A second session in the same proxie.db: the first was closed first.
      expect(Proxie.engine!.sessionId, 2);
    });

    test('concurrent shutdowns both complete after the teardown', () async {
      final log = <String>[];
      await Proxie.init(adapters: [_LogAdapter('a', log)]);
      var streamClosed = false;
      Proxie.engine!.calls.listen(null, onDone: () => streamClosed = true);
      final seen = <String>[];
      final first = Proxie.shutdown().then((_) {
        seen.add('first:${log.join(',')}:$streamClosed');
      });
      final second = Proxie.shutdown().then((_) {
        seen.add('second:${log.join(',')}:$streamClosed');
      });
      await Future.wait([first, second]);
      expect(
        seen,
        unorderedEquals([
          'first:a.attach,a.detach:true',
          'second:a.attach,a.detach:true',
        ]),
      );
      expect(Proxie.isActive, isFalse);
    });

    test('an init called while shutdown waits for a running init ends '
        'active', () async {
      final log = <String>[];
      final first = Proxie.init(
        adapters: [_LogAdapter('a', log)],
        config: const ProxieConfig(persistHistory: false),
      );
      final down = Proxie.shutdown();
      final second = Proxie.init(
        adapters: [_LogAdapter('b', log)],
        config: const ProxieConfig(persistHistory: false),
      );
      expect(identical(first, second), isFalse);
      await Future.wait([first, down, second]);
      expect(log, ['a.attach', 'a.detach', 'b.attach']);
      expect(Proxie.isActive, isTrue);
    });

    test('a shutdown after an init queued behind another shutdown tears that '
        'init down too', () async {
      final log = <String>[];
      await Proxie.init(adapters: [_LogAdapter('a', log)]);
      final down1 = Proxie.shutdown();
      final up = Proxie.init(adapters: [_LogAdapter('b', log)]);
      final down2 = Proxie.shutdown();
      await Future.wait([down1, up, down2]);
      expect(log, ['a.attach', 'a.detach', 'b.attach', 'b.detach']);
      expect(Proxie.isActive, isFalse);
    });
  });

  group('httpClient', () {
    MockClient inner() => MockClient((_) async => http.Response('ok', 200));

    test('a client created before init is captured once init '
        'completes', () async {
      final client = Proxie.httpClient(inner: inner());
      expect(client, isA<ProxieHttpClient>());
      // Before init: plain pass-through.
      expect((await client.get(Uri.parse('https://a.test/1'))).body, 'ok');

      final init = Proxie.init(
        config: const ProxieConfig(persistHistory: false),
      );
      // Still running: not attached yet, still pass-through.
      expect((await client.get(Uri.parse('https://a.test/2'))).body, 'ok');
      await init;

      final calls = <ProxieCall>[];
      final sub = Proxie.engine!.calls.listen(calls.add);
      addTearDown(sub.cancel);
      await client.get(Uri.parse('https://a.test/3'));
      await Future<void>.delayed(Duration.zero);
      expect(calls.map((c) => c.request.url.path).toSet(), {'/3'});
    });

    test('a client created after init is captured', () async {
      await Proxie.init(config: const ProxieConfig(persistHistory: false));
      final client = Proxie.httpClient(inner: inner());
      final calls = <ProxieCall>[];
      final sub = Proxie.engine!.calls.listen(calls.add);
      addTearDown(sub.cancel);
      await client.get(Uri.parse('https://a.test/x'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, isNotEmpty);
    });

    test('shutdown detaches clients: later requests pass through', () async {
      await Proxie.init(config: const ProxieConfig(persistHistory: false));
      final engine = Proxie.engine!;
      final calls = <ProxieCall>[];
      final sub = engine.calls.listen(calls.add);
      addTearDown(sub.cancel);
      final client = Proxie.httpClient(inner: inner());
      await Proxie.shutdown();
      expect((await client.get(Uri.parse('https://a.test/y'))).body, 'ok');
      expect(calls, isEmpty);
    });

    test('a client created during shutdown is captured by the next '
        'init', () async {
      await Proxie.init(config: const ProxieConfig(persistHistory: false));
      final down = Proxie.shutdown();
      final client = Proxie.httpClient(inner: inner());
      await Future.wait([
        down,
        Proxie.init(config: const ProxieConfig(persistHistory: false)),
      ]);
      final calls = <ProxieCall>[];
      final sub = Proxie.engine!.calls.listen(calls.add);
      addTearDown(sub.cancel);
      await client.get(Uri.parse('https://a.test/w'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, isNotEmpty);
    });

    test('a client from before an init(enabled: false) stays '
        'pass-through', () async {
      final client = Proxie.httpClient(inner: inner());
      await Proxie.init(enabled: false);
      expect((await client.get(Uri.parse('https://a.test/z'))).body, 'ok');
    });
  });
}
