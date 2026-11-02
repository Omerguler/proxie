import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

// Widget tests run the real worker isolate (in-memory store, no files) via
// `tester.runAsync`: isolate spawn and its messages need real async, while
// the UI stays on the fake clock.

const phoneSize = Size(390, 844);
const tabletSize = Size(1024, 768);
const memoryConfig = ProxieConfig(persistHistory: false);

/// Sets the test view to [size] logical pixels; reset with `view.reset`.
void setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
}

Future<void> initProxie(
  WidgetTester tester, {
  ProxieNavigation navigation = const ProxieNavigation.overlay(),
  ProxieConfig config = memoryConfig,
}) async {
  await tester.runAsync(
    () => Proxie.init(navigation: navigation, config: config),
  );
  expect(Proxie.isActive, isTrue);
}

ProxieRequest getRequest(String path) => ProxieRequest(
  method: 'GET',
  url: Uri.parse('https://api.test$path'),
  headers: const {},
  body: ProxieBody.empty(),
);

ProxieResponse okResponse() => ProxieResponse(
  statusCode: 200,
  headers: const {},
  body: ProxieBody.empty(),
);

Widget hostApp({
  GlobalKey<NavigatorState>? navigatorKey,
  ThemeData? theme,
  ThemeData? darkTheme,
  ThemeMode themeMode = ThemeMode.system,
  Widget? home,
  List<NavigatorObserver> observers = const [],
}) => MaterialApp(
  navigatorKey: navigatorKey,
  theme: theme,
  darkTheme: darkTheme,
  themeMode: themeMode,
  navigatorObservers: observers,
  builder: Proxie.wrap,
  home: home ?? const Scaffold(body: Center(child: Text('host home'))),
);

final bubbleFinder = find.byType(ProxieBubble);

/// The button itself; the bubble widget fills the screen.
final bubbleButton = find.descendant(
  of: bubbleFinder,
  matching: find.byType(ScaleTransition),
);

final shellFinder = find.byType(InspectorShell);

ProxieInspectorController controllerIn(WidgetTester tester) =>
    ProxieInspectorController.of(tester.element(find.text('No requests yet')));
