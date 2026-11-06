import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

import 'support/common_names.dart';

void main() {
  test('importing Proxie does not clash with common names', () {
    // Each would be an ambiguous_import compile error if proxie.dart exported
    // it too.
    expect(Mock(), isA<Mock>());
    expect(Abort(), isA<Abort>());
    expect(Proceed(), isA<Proceed>());
    expect(Trim(), isA<Trim>());
    expect(GetCall(), isA<GetCall>());
    expect(ClearAll(), isA<ClearAll>());
    expect(JsonDocument(), isA<JsonDocument>());
    expect(ProxieWorker(), isA<ProxieWorker>());
  });

  test('what the README documents is public', () {
    expect(kProxieVersion, isNotEmpty);
    expect(kMask, isNotEmpty);
    expect(ProxieMasking.defaults.jsonKeys, contains('token'));
    expect(const ProxieConfig().themeMode, ProxieThemeMode.dark);
    expect(ProxieHttpClient().name, 'http');
    expect(ProxieHttpOverridesAdapter().name, isNotEmpty);
    expect(
      const MapLocalAction(failure: SimulatedFailure.timeout).failure,
      isNotNull,
    );
    expect(UrlMatcher('*').matches(Uri.parse('https://a.test')), isTrue);
    expect(RuleKind.values, isNotEmpty);
    expect(BreakpointPhase.values, isNotEmpty);
    expect(RuleSet(const []).rules, isEmpty);
    expect(CallTag.values, isNotEmpty);
    expect(BodyKind.values, isNotEmpty);
    expect(defaultBodyCap, greaterThan(0));
    expect(ProxieSections.detailTabs, isA<List<ProxieDetailTab>>());
    expect(ProxieSections.listBadges, isA<List<ProxieListBadge>>());
  });
}
