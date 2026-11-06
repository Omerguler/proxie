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
        expect(colors.methodColor('GET'), colors.get);
        expect(colors.methodColor('post'), colors.post);
        expect(colors.methodColor('PUT'), colors.put);
        expect(colors.methodColor('PATCH'), colors.put);
        expect(colors.methodColor('DELETE'), colors.delete);
        expect(colors.methodColor('HEAD'), colors.pending);
      }
    });

    test('status colors', () {
      final c = ProxieTheme.dark().extension<ProxieColors>()!;
      expect(c.statusColor(200), c.success);
      expect(c.statusColor(204), c.success);
      expect(c.statusColor(301), c.redirect);
      expect(c.statusColor(404), c.clientError);
      expect(c.statusColor(500), c.serverError);
      expect(c.statusColor(null), c.pending);
      expect(c.statusColor(null, error: true), c.serverError);
      expect(c.statusColor(200, error: true), c.serverError);
    });

    double contrast(Color a, Color b) {
      final x = a.computeLuminance() + 0.05;
      final y = b.computeLuminance() + 0.05;
      return x > y ? x / y : y / x;
    }

    test('one accent, readable as ink on every surface and under text', () {
      for (final theme in [ProxieTheme.dark(), ProxieTheme.light()]) {
        final scheme = theme.colorScheme;
        final c = theme.extension<ProxieColors>()!;
        expect(scheme.primary, c.accent);
        expect(contrast(scheme.onPrimary, c.accent), greaterThanOrEqualTo(4.5));
        for (final surface in [
          scheme.surface,
          scheme.surfaceContainer,
          scheme.surfaceContainerHigh,
        ]) {
          expect(contrast(c.accent, surface), greaterThanOrEqualTo(4.5));
        }
      }
    });

    test('status, method and JSON ink reads on the page surface', () {
      for (final theme in [ProxieTheme.dark(), ProxieTheme.light()]) {
        final page = theme.colorScheme.surface;
        final c = theme.extension<ProxieColors>()!;
        for (final ink in [
          c.get,
          c.post,
          c.put,
          c.delete,
          c.success,
          c.redirect,
          c.clientError,
          c.serverError,
          c.muted,
          c.jsonKey,
          c.jsonString,
          c.jsonNumber,
        ]) {
          expect(contrast(ink, page), greaterThanOrEqualTo(4.5));
        }
      }
    });

    test('hairlines are primary text at 8%', () {
      for (final theme in [ProxieTheme.dark(), ProxieTheme.light()]) {
        final scheme = theme.colorScheme;
        expect(scheme.outlineVariant, scheme.onSurface.withValues(alpha: 0.08));
      }
    });

    test('lerp and copyWith', () {
      final c = ProxieTheme.dark().extension<ProxieColors>()!;
      expect(c.lerp(c, 0.5).methodColor('GET'), c.get);
      expect(c.lerp(c, 0.5).accent, c.accent);
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
      expect(colors.methodColor('GET'), const ProxieColors().get);
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
