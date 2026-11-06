import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';
import 'package:proxie/src/ui/list/call_list.dart';

import '../support/ui_harness.dart';

final Finder _listFinder = find.byType(CallList);

/// Holds state a remount would lose.
class _Stateful extends StatefulWidget {
  const _Stateful(this.name);

  final String name;

  static int created = 0;

  @override
  State<_Stateful> createState() => _StatefulState();
}

class _StatefulState extends State<_Stateful> {
  final _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    _Stateful.created++;
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TextField(key: ValueKey(widget.name), controller: _text);
}

void main() {
  testWidgets('crossing the split width keeps list and detail state', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    _Stateful.created = 0;
    setViewSize(tester, const Size(1000, 800));
    final controller = ProxieInspectorController()..select('c1');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: InspectorShell(
          controller: controller,
          listBuilder: (_) => const _Stateful('list'),
          detailBuilder: (_, id) => _Stateful('detail-$id'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_Stateful.created, 2);
    await tester.enterText(find.byKey(const ValueKey('list')), 'kept');
    await tester.enterText(find.byKey(const ValueKey('detail-c1')), 'also');

    setViewSize(tester, phoneSize);
    await tester.pumpAndSettle();
    expect(_Stateful.created, 2);
    expect(find.text('also'), findsOneWidget);

    setViewSize(tester, const Size(1000, 800));
    await tester.pumpAndSettle();
    expect(_Stateful.created, 2);
    expect(find.text('kept'), findsOneWidget);
    expect(find.text('also'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Another call is a new detail; the list stays.
    controller.select('c2');
    await tester.pumpAndSettle();
    expect(_Stateful.created, 3);
    expect(find.text('also'), findsNothing);
    expect(find.text('kept'), findsOneWidget);
  });

  tearDown(() async {
    await Proxie.shutdown();
  });

  group('InspectorShell', () {
    late ProxieInspectorController controller;

    setUp(() => controller = ProxieInspectorController());

    Widget shell({double splitWidth = 700}) => MaterialApp(
      home: InspectorShell(
        controller: controller,
        splitWidth: splitWidth,
        listBuilder: (context) => Container(
          key: const ValueKey('list'),
          child: const Text('the list'),
        ),
        detailBuilder: (context, id) => Text('detail $id'),
      ),
    );

    testWidgets('default placeholders', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      await tester.pumpWidget(
        MaterialApp(home: InspectorShell(controller: controller)),
      );
      expect(find.text('No requests yet'), findsOneWidget);
      expect(find.text('Select a request'), findsOneWidget);
    });

    testWidgets('tablet shows list and detail side by side', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      await tester.pumpWidget(shell());
      expect(find.text('the list'), findsOneWidget);
      expect(find.text('Select a request'), findsOneWidget);
      // List takes 40% of the width.
      expect(tester.getSize(find.byKey(const ValueKey('list'))).width, 409.6);

      controller.select('a');
      await tester.pumpAndSettle();
      expect(find.text('the list'), findsOneWidget);
      expect(find.text('detail a'), findsOneWidget);
    });

    testWidgets('the list pane is at least 320 wide', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, const Size(760, 600));
      await tester.pumpWidget(shell());
      expect(find.text('Select a request'), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('list'))).width, 320);
    });

    testWidgets('the split threshold is configurable', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      await tester.pumpWidget(shell(splitWidth: 1100));
      expect(find.text('the list'), findsOneWidget);
      expect(find.text('Select a request'), findsNothing);
    });

    testWidgets('phone shows the list only; selecting pushes the detail and '
        'back pops it', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await tester.pumpWidget(shell());
      expect(find.text('the list'), findsOneWidget);
      expect(find.text('Select a request'), findsNothing);

      controller.select('a');
      await tester.pumpAndSettle();
      expect(find.text('detail a'), findsOneWidget);
      expect(find.text('the list'), findsNothing);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(controller.selectedCallId, isNull);
      expect(find.text('the list'), findsOneWidget);
      expect(find.text('detail a'), findsNothing);
    });

    testWidgets('phone: the system back pops the detail, not the host '
        'route', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await tester.pumpWidget(shell());
      controller.select('a');
      await tester.pumpAndSettle();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(controller.selectedCallId, isNull);
      expect(find.text('the list'), findsOneWidget);
    });

    testWidgets('phone: selecting another call replaces the detail', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await tester.pumpWidget(shell());
      controller.select('a');
      await tester.pumpAndSettle();
      controller.select('b');
      await tester.pumpAndSettle();
      expect(controller.selectedCallId, 'b');
      expect(find.text('detail b'), findsOneWidget);
      expect(find.text('detail a'), findsNothing);
    });

    testWidgets('resizing switches layouts live and keeps the selection', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await tester.pumpWidget(shell());
      controller.select('a');
      await tester.pumpAndSettle();

      setViewSize(tester, tabletSize);
      await tester.pumpAndSettle();
      expect(find.text('the list'), findsOneWidget);
      expect(find.text('detail a'), findsOneWidget);

      setViewSize(tester, phoneSize);
      await tester.pumpAndSettle();
      expect(find.text('detail a'), findsOneWidget);
      expect(find.text('the list'), findsNothing);
      expect(controller.selectedCallId, 'a');
    });

    testWidgets('the close button closes the controller', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      controller.open();
      await tester.pumpWidget(shell());
      await tester.tap(find.byTooltip('Close'));
      expect(controller.isOpen, isFalse);
    });
  });

  group('ProxieInspectorController', () {
    test('notifies only on change', () {
      final c = ProxieInspectorController();
      var n = 0;
      c
        ..addListener(() => n++)
        ..open()
        ..open();
      expect(c.isOpen, isTrue);
      c
        ..select('a')
        ..select('a');
      expect(c.selectedCallId, 'a');
      c
        ..close()
        ..close();
      expect(c.isOpen, isFalse);
      expect(n, 3);
    });
  });

  group('overlay navigation', () {
    testWidgets('bubble is visible after init and wrap', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      expect(bubbleFinder, findsOneWidget);
      expect(find.text('host home'), findsOneWidget);
      expect(shellFinder, findsNothing);
      await tester.runAsync(Proxie.shutdown);
      await tester.pump();
      expect(bubbleFinder, findsNothing);
      expect(find.text('host home'), findsOneWidget);
    });

    testWidgets('wrap before init shows the bubble once ready', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await tester.pumpWidget(hostApp());
      expect(bubbleFinder, findsNothing);
      await tester.runAsync(() => Proxie.init(config: memoryConfig));
      await tester.pump();
      expect(bubbleFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('bubble has a semantics label', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final semantics = tester.ensureSemantics();
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      expect(find.bySemanticsLabel('Open Proxie inspector'), findsOneWidget);
      semantics.dispose();
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('tapping the bubble opens the inspector; back closes it and '
        'leaves the host route alone', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final key = GlobalKey<NavigatorState>();
      await initProxie(tester);
      await tester.pumpWidget(hostApp(navigatorKey: key));
      key.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('host second')),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(bubbleButton);
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      expect(bubbleFinder, findsNothing, reason: 'hidden while open');

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      expect(bubbleFinder, findsOneWidget);
      expect(find.text('host second'), findsOneWidget);

      // Closed: back goes to the host again.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('host home'), findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('Proxie.open opens and the close button closes', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      expect(bubbleFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('phone: back pops the detail first, then closes', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      final controller = controllerIn(tester)..select('a');
      await tester.pumpAndSettle();
      expect(_listFinder, findsNothing);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      expect(controller.selectedCallId, isNull);
      expect(_listFinder, findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('tablet: the inspector shows both panes', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      expect(_listFinder, findsOneWidget);
      expect(find.text('Select a request'), findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('the split width comes from the config', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, tabletSize);
      await initProxie(
        tester,
        config: const ProxieConfig(persistHistory: false, splitWidth: 1100),
      );
      await tester.pumpWidget(hostApp());
      Proxie.open();
      await tester.pumpAndSettle();
      expect(_listFinder, findsOneWidget);
      expect(find.text('Select a request'), findsNothing);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('the host theme is unchanged; Proxie uses its own', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final hostTheme = ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
      );
      await initProxie(tester);
      await tester.pumpWidget(
        hostApp(
          theme: hostTheme,
          home: const Scaffold(body: Text('host')),
        ),
      );
      Proxie.open();
      await tester.pumpAndSettle();

      final host = Theme.of(tester.element(find.text('host')));
      expect(host.brightness, Brightness.light);
      expect(host.colorScheme.primary, hostTheme.colorScheme.primary);
      expect(host.extension<ProxieColors>(), isNull);

      final proxie = Theme.of(tester.element(_listFinder));
      expect(proxie.brightness, Brightness.dark);
      expect(
        proxie.colorScheme.primary,
        ProxieTheme.dark().colorScheme.primary,
      );
      expect(proxie.extension<ProxieColors>(), isNotNull);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('the badge counts distinct calls of the session', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      Finder badge(String text) =>
          find.descendant(of: bubbleFinder, matching: find.text(text));
      expect(badge('0'), findsNothing, reason: 'no badge without calls');

      final engine = Proxie.engine!;
      await engine.onRequest('c1', 'test', getRequest('/1'));
      await tester.pump();
      expect(badge('1'), findsOneWidget);

      await engine.onResponse('c1', okResponse());
      await tester.pump();
      expect(badge('1'), findsOneWidget, reason: 'same call, new snapshot');

      await engine.onRequest('c2', 'test', getRequest('/2'));
      engine.onError(
        'c2',
        const ProxieError(type: 'socket', message: 'failed'),
      );
      await tester.pump();
      expect(badge('2'), findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('the bubble pulses while a breakpoint is pending', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      double scale() =>
          tester.widget<ScaleTransition>(bubbleButton).scale.value;
      await tester.pump(const Duration(milliseconds: 300));
      expect(scale(), 1.0);

      final breakpoints = Proxie.engine!.breakpoints;
      final paused = breakpoints.pause(
        PausedCall(
          callId: 'p1',
          phase: BreakpointPhase.request,
          request: getRequest('/p'),
          pausedAt: DateTime.now(),
        ),
      );
      // The pause opens the inspector on its editor; back closes both.
      await tester.pumpAndSettle();
      expect(bubbleFinder, findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pump();
      // The first frame starts the ticker; the next one advances it.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 300));
      expect(scale(), greaterThan(1.0));

      breakpoints.resolve('p1', const ContinueUnchanged());
      await paused;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(scale(), 1.0);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('dragging the bubble snaps it to the nearest edge inside the '
        'safe area', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      tester.view.padding = const FakeViewPadding(left: 30, right: 30);
      addTearDown(tester.view.resetPadding);
      await initProxie(tester);
      await tester.pumpWidget(hostApp());
      final start = tester.getCenter(bubbleButton);
      expect(start.dx, greaterThan(195), reason: 'starts on the right');

      // Drag past the middle towards the left, then release.
      await tester.drag(bubbleButton, Offset(-(start.dx - 120), -100));
      await tester.pumpAndSettle();
      final left = tester.getTopLeft(bubbleButton);
      expect(left.dx, greaterThanOrEqualTo(30));
      expect(left.dx, lessThan(60));

      // Dragging far off-screen stays inside the screen.
      await tester.drag(bubbleButton, const Offset(600, -2000));
      await tester.pumpAndSettle();
      final right = tester.getTopLeft(bubbleButton);
      expect(right.dx + 52, lessThanOrEqualTo(390 - 30));
      expect(right.dx + 52, greaterThan(390 - 60));
      expect(right.dy, greaterThanOrEqualTo(0));
      await tester.runAsync(Proxie.shutdown);
    });
  });

  group('navigatorKey navigation', () {
    testWidgets('open pushes the inspector onto the given navigator; close '
        'pops it', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final key = GlobalKey<NavigatorState>();
      await initProxie(tester, navigation: ProxieNavigation.navigatorKey(key));
      await tester.pumpWidget(hostApp(navigatorKey: key));
      expect(key.currentState!.canPop(), isFalse);

      await tester.tap(bubbleButton);
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      expect(key.currentState!.canPop(), isTrue);
      // The inspector page is the host route; pages opened from it go on
      // the inspector's own navigator inside it.
      final route = ModalRoute.of(
        tester.element(find.byType(ProxieInspector)),
      )!;
      expect(route.navigator, same(key.currentState));
      expect(route, isA<MaterialPageRoute<void>>());
      expect((route as MaterialPageRoute<void>).fullscreenDialog, isTrue);
      expect(bubbleFinder, findsNothing);
      // Themed with Proxie's theme, not the host's.
      expect(Theme.of(tester.element(_listFinder)).brightness, Brightness.dark);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      expect(key.currentState!.canPop(), isFalse);
      expect(bubbleFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
    });

    testWidgets('the system back pops the route and Proxie notices', (
      tester,
    ) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final key = GlobalKey<NavigatorState>();
      await initProxie(tester, navigation: ProxieNavigation.navigatorKey(key));
      await tester.pumpWidget(hostApp(navigatorKey: key));
      Proxie.open();
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing);
      expect(bubbleFinder, findsOneWidget);
      expect(find.text('host home'), findsOneWidget);

      Proxie.open();
      await tester.pumpAndSettle();
      expect(shellFinder, findsOneWidget);
      await tester.runAsync(Proxie.shutdown);
      await tester.pumpAndSettle();
      expect(shellFinder, findsNothing, reason: 'shutdown hides the inspector');
    });
  });

  group('custom navigation', () {
    testWidgets('push and pop callbacks are invoked', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final pushed = <Widget>[];
      var pops = 0;
      await initProxie(
        tester,
        navigation: ProxieNavigation.custom(
          push: pushed.add,
          pop: () => pops++,
        ),
      );
      Proxie.open();
      Proxie.open();
      expect(pushed, hasLength(1));

      // The host shows the page somewhere; closing calls pop.
      await tester.pumpWidget(MaterialApp(home: pushed.single));
      expect(shellFinder, findsOneWidget);
      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      expect(pops, 1);

      Proxie.open();
      expect(pushed, hasLength(2));
      await tester.runAsync(Proxie.shutdown);
      expect(pops, 2, reason: 'shutdown hides the inspector');
    });

    testWidgets('a page the host removed counts as closed', (tester) async {
      addTearDown(tester.view.reset);
      setViewSize(tester, phoneSize);
      final pushed = <Widget>[];
      var pops = 0;
      await initProxie(
        tester,
        navigation: ProxieNavigation.custom(
          push: pushed.add,
          pop: () => pops++,
        ),
      );
      Proxie.open();
      await tester.pumpWidget(MaterialApp(home: pushed.single));
      // The host's router dropped the page (e.g. its own back handling).
      await tester.pumpWidget(const MaterialApp(home: Text('elsewhere')));
      expect(pops, 0);

      Proxie.open();
      expect(pushed, hasLength(2));
      await tester.runAsync(Proxie.shutdown);
    });
  });
}
