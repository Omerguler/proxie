import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:proxie/proxie.dart';

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
    tmp.deleteSync(recursive: true);
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
            wrapped = Proxie.wrap(context, child);
            return wrapped;
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

    test('a client from before an init(enabled: false) stays '
        'pass-through', () async {
      final client = Proxie.httpClient(inner: inner());
      await Proxie.init(enabled: false);
      expect((await client.get(Uri.parse('https://a.test/z'))).body, 'ok');
    });
  });
}
