import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/src/internal_api.dart';
import 'package:proxie/src/ui/list/call_list.dart';

import '../support/ui_harness.dart';

final Finder _listFinder = find.byType(CallList);

class _RecordingAdapter implements ProxieNavigationAdapter {
  final shown = <Widget>[];
  VoidCallback? dismiss;
  int hides = 0;

  @override
  bool isShowing = false;

  @override
  void show(Widget inspector, {required VoidCallback onDismissed}) {
    shown.add(inspector);
    dismiss = onDismissed;
    isShowing = true;
  }

  @override
  void hide() {
    hides++;
    isShowing = false;
  }
}

class _RtlWidgetsLocalizations extends DefaultWidgetsLocalizations {
  const _RtlWidgetsLocalizations();

  static const LocalizationsDelegate<WidgetsLocalizations> delegate =
      _RtlDelegate();

  @override
  TextDirection get textDirection => TextDirection.rtl;
}

class _RtlDelegate extends LocalizationsDelegate<WidgetsLocalizations> {
  const _RtlDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'ar';

  @override
  Future<WidgetsLocalizations> load(Locale locale) =>
      SynchronousFuture(const _RtlWidgetsLocalizations());

  @override
  bool shouldReload(_RtlDelegate old) => false;
}

class _AnyCupertinoDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _AnyCupertinoDelegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      SynchronousFuture(const DefaultCupertinoLocalizations());

  @override
  bool shouldReload(_AnyCupertinoDelegate old) => false;
}

Future<void> _backGesture(WidgetTester tester, String method) async {
  final message = const StandardMethodCodec().encodeMethodCall(
    MethodCall(
      method,
      method == 'commitBackGesture'
          ? null
          : <String, Object?>{
              'touchOffset': <double>[5, 300],
              'progress': 0.0,
              'swipeEdge': 0,
            },
    ),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    message,
    (_) {},
  );
}

Brightness _proxieBrightness(WidgetTester tester) =>
    Theme.of(tester.element(_listFinder)).brightness;

Brightness _bubbleBrightness(WidgetTester tester) =>
    Theme.of(tester.element(bubbleButton)).brightness;

void main() {
  tearDown(() async {
    await Proxie.shutdown();
  });

  testWidgets('reopening during the removal frame keeps the open pages', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    setViewSize(tester, tabletSize);
    try {
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      final controller = controllerIn(tester);
      await tester.tap(find.byTooltip('Rules'));
      await tester.pumpAndSettle();
      expect(find.text('No rules yet'), findsOneWidget);

      // One frame: hidden and out of focus, about to be removed.
      controller.close();
      await tester.pump();
      expect(find.text('No rules yet'), findsNothing);

      // The same inspector comes back, on the page it was on, and works.
      controller.open();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('No rules yet'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(controller.isOpen, isFalse);
      expect(shellFinder, findsNothing);
      expect(bubbleFinder, findsOneWidget);

      // Past that frame the navigator is gone: the next open starts fresh.
      controller.open();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Rules'));
      await tester.pumpAndSettle();
      controller.close();
      await tester.pump();
      await tester.pump();
      controller.open();
      await tester.pumpAndSettle();
      expect(find.text('No rules yet'), findsNothing);
      expect(shellFinder, findsOneWidget);
    } finally {
      await tester.runAsync(Proxie.shutdown);
    }
  });

  testWidgets('the bubble is its own semantics node, the app stays outside', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      await tester.pump();

      final bubble = find.bySemanticsLabel('Open Proxie inspector');
      expect(bubble, findsOneWidget);
      expect(tester.getSize(bubble), const Size.square(ProxieBubble.size));
      // Its tap belongs to it alone, and the app is not a child of it.
      final node = tester.getSemantics(bubble);
      expect(node, isSemantics(isButton: true, hasTapAction: true));
      expect(node.childrenCount, 0);
      expect(find.bySemanticsLabel('host home'), findsOneWidget);
    } finally {
      semantics.dispose();
      await tester.runAsync(Proxie.shutdown);
    }
  });

  testWidgets('a view focus change while the inspector closes does not throw', (
    tester,
  ) async {
    // On the web, removing the focused element from the semantics tree makes
    // the browser report a view focus change in the middle of the frame:
    // after the inspector's render objects were detached, before its focus
    // nodes are disposed.
    final semantics = tester.ensureSemantics();
    void reportFocus() => tester.binding.handleViewFocusChanged(
      ViewFocusEvent(
        viewId: tester.view.viewId,
        state: ViewFocusState.focused,
        direction: ViewFocusDirection.forward,
      ),
    );
    SemanticsOwner? listened;
    try {
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      listened = tester.renderObject(bubbleFinder).owner!.semanticsOwner;
      Proxie.open();
      await tester.pumpAndSettle();

      controllerIn(tester).close();
      listened!.addListener(reportFocus);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(shellFinder, findsNothing);
      expect(bubbleFinder, findsOneWidget);
    } finally {
      listened?.removeListener(reportFocus);
      semantics.dispose();
      await tester.runAsync(Proxie.shutdown);
    }
  });

  group('theme mode', () {
    testWidgets('light: Proxie is light while the host stays dark', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(
        tester,
        config: const ProxieConfig(
          persistHistory: false,
          themeMode: ProxieThemeMode.light,
        ),
      );
      await tester.pumpWidget(
        hostApp(
          theme: ThemeData.light(),
          darkTheme: ThemeData.dark(),
          themeMode: ThemeMode.dark,
        ),
      );
      expect(_bubbleBrightness(tester), Brightness.light);
      Proxie.open();
      await tester.pumpAndSettle();
      expect(_proxieBrightness(tester), Brightness.light);
      final host = Theme.of(tester.element(find.text('host home')));
      expect(host.brightness, Brightness.dark);
      expect(host.extension<ProxieColors>(), isNull);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('dark (default): Proxie is dark while the host stays light', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(
        hostApp(theme: ThemeData.light(), themeMode: ThemeMode.light),
      );
      expect(_bubbleBrightness(tester), Brightness.dark);
      Proxie.open();
      await tester.pumpAndSettle();
      expect(_proxieBrightness(tester), Brightness.dark);
      expect(
        Theme.of(tester.element(find.text('host home'))).brightness,
        Brightness.light,
      );
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('system: follows the platform brightness live, not the host '
        'theme', (tester) async {
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      setViewSize(tester, phoneSize);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await initProxie(
        tester,
        config: const ProxieConfig(
          persistHistory: false,
          themeMode: ProxieThemeMode.system,
        ),
      );
      // The host forces dark regardless of the platform.
      await tester.pumpWidget(
        hostApp(theme: ThemeData.dark(), themeMode: ThemeMode.light),
      );
      Proxie.open();
      await tester.pumpAndSettle();
      expect(_proxieBrightness(tester), Brightness.light);

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(_proxieBrightness(tester), Brightness.dark);
      expect(
        Theme.of(tester.element(find.text('host home'))).brightness,
        Brightness.dark,
      );

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(_proxieBrightness(tester), Brightness.light);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('ProxieInspector honours its themeMode', (tester) async {
      final controller = ProxieInspectorController();
      await tester.pumpWidget(
        MaterialApp(
          home: ProxieInspector(
            controller: controller,
            themeMode: ProxieThemeMode.light,
          ),
        ),
      );
      // Its default placeholder list.
      expect(
        Theme.of(tester.element(find.text('No requests yet'))).brightness,
        Brightness.light,
      );
    });
  });

  group('wrap outside MaterialApp', () {
    testWidgets('under WidgetsApp', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFF000000),
          builder: Proxie.wrap,
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, _, _) => builder(context),
          ),
          home: const Text('widgets home'),
        ),
      );
      expect(bubbleFinder, findsOneWidget);
      await tester.tap(bubbleButton);
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('under CupertinoApp', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      await initProxie(tester);
      await tester.pumpWidget(
        const CupertinoApp(
          builder: Proxie.wrap,
          home: CupertinoPageScaffold(child: Text('cupertino home')),
        ),
      );
      await tester.tap(bubbleButton);
      await tester.pumpAndSettle();
      expect(_listFinder, findsOneWidget);
      expect(find.text('Select a request'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      expect(find.text('cupertino home'), findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('at the root, without any app', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(
        Builder(
          builder: (context) => Proxie.wrap(
            context,
            const Text('bare', textDirection: TextDirection.ltr),
          ),
        ),
      );
      Proxie.open();
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(bubbleFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('under WidgetsApp with a non-English locale', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFF000000),
          locale: const Locale('tr'),
          supportedLocales: const [Locale('tr')],
          builder: Proxie.wrap,
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, _, _) => builder(context),
          ),
          home: const Text('ev'),
        ),
      );
      await tester.tap(bubbleButton);
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('under CupertinoApp with a non-English locale', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(
        const CupertinoApp(
          locale: Locale('tr'),
          supportedLocales: [Locale('tr')],
          // Cupertino-only localizations for tr, as a real app would have;
          // no Material ones.
          localizationsDelegates: [_AnyCupertinoDelegate()],
          builder: Proxie.wrap,
          home: CupertinoPageScaffold(child: Text('ev')),
        ),
      );
      await tester.tap(bubbleButton);
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      controllerIn(tester).select('a');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(_listFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('under an rtl WidgetsApp locale keeps rtl', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(
        WidgetsApp(
          color: const Color(0xFF000000),
          locale: const Locale('ar'),
          supportedLocales: const [Locale('ar')],
          localizationsDelegates: const [_RtlWidgetsLocalizations.delegate],
          builder: Proxie.wrap,
          pageRouteBuilder: <T>(settings, builder) => PageRouteBuilder<T>(
            settings: settings,
            pageBuilder: (context, _, _) => builder(context),
          ),
          home: const Text('home'),
        ),
      );
      Proxie.open();
      await tester.pumpAndSettle();
      expect(Directionality.of(tester.element(_listFinder)), TextDirection.rtl);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('keeps the host text direction', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.rtl,
          child: Builder(
            builder: (context) => Proxie.wrap(context, const Text('bare')),
          ),
        ),
      );
      Proxie.open();
      await tester.pumpAndSettle();
      expect(Directionality.of(tester.element(_listFinder)), TextDirection.rtl);
      await tester.runAsync(Proxie.shutdown);
    });
  });

  group('accessibility', () {
    testWidgets('the bubble exposes a tap action that opens the inspector', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final semantics = tester.ensureSemantics();
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      final node = find.semantics.byLabel('Open Proxie inspector');
      expect(
        tester.getSemantics(find.bySemanticsLabel('Open Proxie inspector')),
        isSemantics(isButton: true, hasTapAction: true),
      );
      tester.semantics.tap(node);
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      semantics.dispose();
      await tester.runAsync(Proxie.shutdown);
    });

    // This cannot isolate the ExcludeSemantics wrapper: the inspector
    // route's BlockSemantics also drops the host's nodes. Kept as a guard on
    // the behaviour.
    testWidgets('the host is hidden from semantics while the overlay is '
        'open', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final semantics = tester.ensureSemantics();
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      expect(find.semantics.byLabel('host home'), findsOneWidget);
      Proxie.open();
      await tester.pumpAndSettle();
      expect(find.semantics.byLabel('host home'), findsNothing);
      expect(find.semantics.byLabel('Errors'), findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.semantics.byLabel('host home'), findsOneWidget);
      semantics.dispose();
      await tester.runAsync(Proxie.shutdown);
    });
  });

  group('back handling', () {
    testWidgets('predictive back closes only the inspector, not the host '
        'route', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final key = GlobalKey<NavigatorState>();
      await initProxie(tester);
      await tester.pumpWidget(
        hostApp(
          navigatorKey: key,
          observers: [Proxie.navigatorObserver],
          theme: ThemeData(
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
              },
            ),
          ),
        ),
      );
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('host second')),
        ),
      );
      await tester.pumpAndSettle();
      Proxie.open();
      await tester.pumpAndSettle();

      await _backGesture(tester, 'startBackGesture');
      await tester.pump();
      await _backGesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      expect(find.text('host second'), findsOneWidget);
      expect(key.currentState!.canPop(), isTrue);

      // Closed: the host's own predictive back works again.
      await _backGesture(tester, 'startBackGesture');
      await tester.pump();
      await _backGesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('host home'), findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('the guard follows a route the host pushes while open', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final key = GlobalKey<NavigatorState>();
      await initProxie(tester);
      await tester.pumpWidget(
        hostApp(navigatorKey: key, observers: [Proxie.navigatorObserver]),
      );
      Proxie.open();
      await tester.pumpAndSettle();
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('host pushed')),
        ),
      );
      await tester.pumpAndSettle();
      // The host's navigator itself cannot pop while the inspector is open.
      expect(await key.currentState!.maybePop(), isTrue);
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing, reason: 'the attempt closed Proxie');
      expect(find.text('host pushed'), findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('setFrameworkHandlesBack is true while open and restored '
        'after', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final calls = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
            calls.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final key = GlobalKey<NavigatorState>();
      await initProxie(tester);
      // With the observer, so the guard's own notifications are in play.
      await tester.pumpWidget(
        hostApp(navigatorKey: key, observers: [Proxie.navigatorObserver]),
      );
      await tester.pumpAndSettle();
      calls.clear();

      Proxie.open();
      await tester.pumpAndSettle();
      expect(calls.last, isTrue);

      calls.clear();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      // The close dispatch and the guard's release notification both report
      // false; a transient true here would be the stale guard value.
      expect(calls, isNotEmpty);
      expect(
        calls,
        everyElement(isFalse),
        reason: "the app's single route can't pop, with no transient true",
      );

      // The app navigates while the inspector is open: on close the app's
      // new state is sent, not the guard's or the stale one.
      Proxie.open();
      await tester.pumpAndSettle();
      key.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('pushed')),
      );
      await tester.pumpAndSettle();
      expect(calls.last, isTrue);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(calls.last, isTrue, reason: 'the app can pop its pushed route');

      Proxie.open();
      await tester.pumpAndSettle();
      key.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(calls.last, isFalse, reason: 'back to a single route');
      await tester.runAsync(Proxie.shutdown);
    });
  });

  group('layer', () {
    testWidgets('host taps pass through while the inspector is closed', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      var taps = 0;
      await initProxie(tester);
      await tester.pumpWidget(
        hostApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: TextButton(
                onPressed: () => taps++,
                child: const Text('host button'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('host button'));
      expect(taps, 1);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('the bubble stays on screen after rotating', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      // To the bottom-right corner.
      await tester.drag(bubbleButton, const Offset(200, 2000));
      await tester.pumpAndSettle();

      setViewSize(tester, const Size(844, 390));
      await tester.pumpAndSettle();
      final rect = tester.getRect(bubbleButton);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(844));
      expect(rect.bottom, lessThanOrEqualTo(390));
      expect(rect.right, greaterThan(844 - 70), reason: 'still on the right');
      await tester.runAsync(Proxie.shutdown);
    });
  });

  group('navigation adapters', () {
    testWidgets('navigatorKey without a mounted navigator stays closed', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final unmounted = GlobalKey<NavigatorState>();
      await initProxie(
        tester,
        navigation: ProxieNavigation.navigatorKey(unmounted),
      );
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      expect(bubbleFinder, findsOneWidget, reason: 'closed again');
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('navigatorKey hide removes the route when it is not on '
        'top', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final key = GlobalKey<NavigatorState>();
      await initProxie(tester, navigation: ProxieNavigation.navigatorKey(key));
      await tester.pumpWidget(hostApp(navigatorKey: key));
      Proxie.open();
      await tester.pumpAndSettle();
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('host on top')),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(Proxie.shutdown);
      await tester.pumpAndSettle();
      expect(find.byType(InspectorShell, skipOffstage: false), findsNothing);
      expect(find.text('host on top'), findsOneWidget);
      key.currentState!.pop();
      await tester.pumpAndSettle();
      expect(find.text('host home'), findsOneWidget);
    });

    testWidgets('custom push that throws is reported and the inspector '
        'stays closed', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      var fail = true;
      final pushed = <Widget>[];
      await initProxie(
        tester,
        navigation: ProxieNavigation.custom(
          push: (page) {
            if (fail) throw StateError('router not ready');
            pushed.add(page);
          },
          pop: () {},
        ),
      );
      await tester.pumpWidget(hostApp());
      Proxie.open();
      final error = tester.takeException();
      expect(error, isA<StateError>());
      await tester.pump();
      expect(bubbleFinder, findsOneWidget, reason: 'closed again');

      fail = false;
      Proxie.open();
      expect(pushed, hasLength(1));
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('ProxieNavigation.adapter plugs in an app adapter', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final adapter = _RecordingAdapter();
      await initProxie(tester, navigation: ProxieNavigation.adapter(adapter));
      await tester.pumpWidget(hostApp());
      await tester.tap(bubbleButton);
      await tester.pump();
      expect(adapter.shown, hasLength(1));
      expect(bubbleFinder, findsNothing, reason: 'open');

      // The page, shown by the app, closes through the adapter.
      await tester.pumpWidget(MaterialApp(home: adapter.shown.single));
      await tester.tap(find.byTooltip('Close'));
      expect(adapter.hides, 1);

      // The app dismissed it on its own.
      Proxie.open();
      expect(adapter.shown, hasLength(2));
      adapter.isShowing = false;
      adapter.dismiss!();
      Proxie.open();
      expect(adapter.shown, hasLength(3));
      expect(adapter.hides, 1);
      await tester.runAsync(Proxie.shutdown);
      expect(adapter.hides, 2);
    });
  });
}
