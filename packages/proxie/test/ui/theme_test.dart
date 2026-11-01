import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

void main() {
  group('ProxieTheme', () {
    test('dark and light are Material 3 with ProxieColors', () {
      final dark = ProxieTheme.dark();
      final light = ProxieTheme.light();
      expect(dark.useMaterial3, isTrue);
      expect(light.useMaterial3, isTrue);
      expect(dark.brightness, Brightness.dark);
      expect(light.brightness, Brightness.light);
      expect(dark.extension<ProxieColors>(), isNotNull);
      expect(light.extension<ProxieColors>(), isNotNull);
    });

    test('method colors', () {
      for (final colors in [
        ProxieTheme.dark().extension<ProxieColors>()!,
        ProxieTheme.light().extension<ProxieColors>()!,
      ]) {
        expect(colors.methodColor('GET'), const Color(0xFF58A6FF));
        expect(colors.methodColor('post'), const Color(0xFF3FB950));
        expect(colors.methodColor('PUT'), const Color(0xFFE3B341));
        expect(colors.methodColor('PATCH'), const Color(0xFFE3B341));
        expect(colors.methodColor('DELETE'), const Color(0xFFFF7B72));
        expect(colors.methodColor('HEAD'), const Color(0xFF7D8590));
      }
    });

    test('status colors', () {
      final c = ProxieTheme.dark().extension<ProxieColors>()!;
      expect(c.statusColor(200), const Color(0xFF3FB950));
      expect(c.statusColor(204), const Color(0xFF3FB950));
      expect(c.statusColor(301), const Color(0xFF58A6FF));
      expect(c.statusColor(404), const Color(0xFFE3B341));
      expect(c.statusColor(500), const Color(0xFFFF7B72));
      expect(c.statusColor(null), const Color(0xFF7D8590));
      expect(c.statusColor(null, error: true), const Color(0xFFFF7B72));
      expect(c.statusColor(200, error: true), const Color(0xFFFF7B72));
    });

    test('accent gradient', () {
      final c = ProxieTheme.dark().extension<ProxieColors>()!;
      expect(c.accentGradient.colors, const [
        Color(0xFF7C5CFF),
        Color(0xFF20C3FF),
      ]);
    });

    test('lerp and copyWith', () {
      final c = ProxieTheme.dark().extension<ProxieColors>()!;
      expect(c.lerp(c, 0.5).methodColor('GET'), const Color(0xFF58A6FF));
      expect(
        c.copyWith(get: const Color(0xFF000000)).methodColor('GET'),
        const Color(0xFF000000),
      );
    });

    testWidgets('ProxieColors.of falls back outside a Proxie theme', (
      tester,
    ) async {
      late ProxieColors colors;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              colors = ProxieColors.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(colors.methodColor('GET'), const Color(0xFF58A6FF));
    });
  });

  group('ProxieSections', () {
    tearDown(ProxieSections.clear);

    test('registers detail tabs and list badges in order', () {
      final tab = ProxieDetailTab(
        id: 'graphql',
        label: 'GraphQL',
        appliesTo: (call) => call.request.url.path == '/graphql',
        build: (context, call) => const SizedBox(),
      );
      final badge = ProxieListBadge(
        id: 'slow',
        label: (s) => (s.durationMs ?? 0) > 1000 ? 'SLOW' : null,
        color: const Color(0xFFFF0000),
      );
      ProxieSections.addDetailTab(tab);
      ProxieSections.addListBadge(badge);
      expect(ProxieSections.detailTabs, [tab]);
      expect(ProxieSections.listBadges, [badge]);
      expect(() => ProxieSections.detailTabs.add(tab), throwsUnsupportedError);

      ProxieSections.clear();
      expect(ProxieSections.detailTabs, isEmpty);
      expect(ProxieSections.listBadges, isEmpty);
    });

    test('a second registration with the same id replaces the first', () {
      ProxieDetailTab tab(String label) => ProxieDetailTab(
        id: 'x',
        label: label,
        appliesTo: (_) => true,
        build: (context, call) => const SizedBox(),
      );
      ProxieSections.addDetailTab(tab('one'));
      ProxieSections.addDetailTab(tab('two'));
      expect(ProxieSections.detailTabs.map((t) => t.label), ['two']);
    });
  });
}
