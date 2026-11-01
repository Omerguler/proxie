import 'package:flutter_test/flutter_test.dart';
import 'package:proxie/proxie.dart';

ProxieRequest _req(String method, String url) => ProxieRequest(
  method: method,
  url: Uri.parse(url),
  headers: const {},
  body: ProxieBody.empty(),
);

ProxieRule _rule(
  String id,
  String pattern, {
  bool regex = false,
  String? method,
  bool enabled = true,
  RuleKind kind = RuleKind.breakpoint,
  BreakpointPhase phase = BreakpointPhase.request,
  MapLocalAction? mapLocal,
}) => ProxieRule(
  id: id,
  name: id,
  enabled: enabled,
  kind: kind,
  matcher: UrlMatcher(pattern, isRegex: regex),
  method: method,
  phase: phase,
  mapLocal: mapLocal,
);

void main() {
  group('UrlMatcher', () {
    final url = Uri.parse('https://api.a.com/v1/users/42?x=1');

    test('wildcard matches full url', () {
      expect(UrlMatcher('*/users/*').matches(url), isTrue);
      expect(UrlMatcher('https://api.a.com/*').matches(url), isTrue);
      expect(UrlMatcher('*/orders/*').matches(url), isFalse);
    });

    test('scheme-less pattern matches host/path', () {
      expect(UrlMatcher('api.a.com/v1/*').matches(url), isTrue);
      expect(UrlMatcher('api.a.com/v1/users/42?x=1').matches(url), isTrue);
      expect(UrlMatcher('a.com/v1/*').matches(url), isFalse);
    });

    test('wildcard escapes regex metacharacters', () {
      expect(
        UrlMatcher('a.com/(x)+').matches(Uri.parse('https://a.com/(x)+')),
        isTrue,
      );
      expect(
        UrlMatcher('a.com/x').matches(Uri.parse('https://aXcom/x')),
        isFalse,
      );
    });

    test('regex', () {
      final m = UrlMatcher(r'^https://a\.com/\d+$', isRegex: true);
      expect(m.matches(Uri.parse('https://a.com/123')), isTrue);
      expect(m.matches(Uri.parse('https://a.com/abc')), isFalse);
    });

    test('invalid regex never matches and never throws', () {
      expect(UrlMatcher('(', isRegex: true).matches(url), isFalse);
    });
  });

  group('RuleSet', () {
    final get = _req('GET', 'https://api.a.com/v1/users/42');

    test('method filter rejects other methods, case-insensitively', () {
      final set = RuleSet([_rule('r', '*/users/*', method: 'POST')]);
      expect(set.requestBreakpointFor(get), isNull);
      final lower = RuleSet([_rule('r', '*/users/*', method: 'get')]);
      expect(lower.requestBreakpointFor(get)?.id, 'r');
    });

    test('disabled rule ignored', () {
      final set = RuleSet([
        _rule('off', '*/users/*', enabled: false),
        _rule('on', '*/users/*'),
      ]);
      expect(set.requestBreakpointFor(get)?.id, 'on');
    });

    test('order decides between map-local rules', () {
      final set = RuleSet([
        _rule('a', '*/users/*', kind: RuleKind.mapLocal),
        _rule('b', '*/users/*', kind: RuleKind.mapLocal),
      ]);
      expect(set.mapLocalFor(get)?.id, 'a');
      expect(set.requestBreakpointFor(get), isNull);
    });

    test('phase both is returned by both breakpoint lookups', () {
      final set = RuleSet([
        _rule('both', '*/users/*', phase: BreakpointPhase.both),
      ]);
      expect(set.requestBreakpointFor(get)?.id, 'both');
      expect(set.responseBreakpointFor(get)?.id, 'both');
    });

    test('phase request is not returned by response lookup', () {
      final set = RuleSet([_rule('req', '*/users/*')]);
      expect(set.responseBreakpointFor(get), isNull);
    });
  });

  test('rule roundtrips through toMap/fromMap', () {
    final rule = _rule(
      'm',
      '*/users/*',
      method: 'GET',
      kind: RuleKind.mapLocal,
      phase: BreakpointPhase.both,
      mapLocal: MapLocalAction(
        response: ProxieResponse(
          statusCode: 404,
          reasonPhrase: 'Not Found',
          headers: {
            'content-type': ['application/json'],
          },
          body: ProxieBody.empty(),
        ),
        delay: const Duration(seconds: 3),
        failure: SimulatedFailure.timeout,
      ),
    );
    final back = ProxieRule.fromMap(rule.toMap());
    expect(back.toMap(), rule.toMap());
    expect(back.mapLocal!.delay, const Duration(seconds: 3));
    expect(back.mapLocal!.failure, SimulatedFailure.timeout);
    expect(back.mapLocal!.response!.statusCode, 404);
    expect(back.matcher.pattern, '*/users/*');
  });
}
