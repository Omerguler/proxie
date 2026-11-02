import 'dart:convert';
import 'dart:typed_data';

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

    test('wildcard host matching is case-insensitive', () {
      expect(UrlMatcher('API.A.com/*').matches(url), isTrue);
      expect(UrlMatcher('HTTPS://API.a.com/*').matches(url), isTrue);
      // Regex patterns keep the case the author wrote.
      expect(
        UrlMatcher(r'^https://API\.a\.com', isRegex: true).matches(url),
        isFalse,
      );
    });

    test('equality is by pattern and isRegex', () {
      expect(UrlMatcher('a*'), UrlMatcher('a*'));
      expect(UrlMatcher('a*').hashCode, UrlMatcher('a*').hashCode);
      expect(UrlMatcher('a*') == UrlMatcher('a*', isRegex: true), isFalse);
      expect(UrlMatcher('a*') == UrlMatcher('b*'), isFalse);
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

    test('stores an unmodifiable copy of the caller list', () {
      final list = [_rule('a', '*/users/*')];
      final set = RuleSet(list);
      list.add(_rule('b', '*'));
      expect(set.rules, hasLength(1));
      expect(() => set.rules.add(_rule('c', '*')), throwsUnsupportedError);
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

  test('MapLocalAction roundtrips a json body and headers', () {
    final action = MapLocalAction(
      response: ProxieResponse(
        statusCode: 201,
        reasonPhrase: 'Created',
        headers: {
          'content-type': ['application/json'],
          'x-multi': ['a', 'b'],
        },
        body: ProxieBody.from(
          Uint8List.fromList(utf8.encode('{"id":7,"ok":true}')),
          'application/json',
        ),
      ),
      delay: const Duration(milliseconds: 1500),
    );
    final back = MapLocalAction.fromMap(action.toMap());
    expect(back.delay, const Duration(milliseconds: 1500));
    expect(back.failure, isNull);
    final r = back.response!;
    expect(r.statusCode, 201);
    expect(r.reasonPhrase, 'Created');
    expect(r.headers['x-multi'], ['a', 'b']);
    expect(r.headers['content-type'], ['application/json']);
    expect(r.body.kind, BodyKind.json);
    expect(r.body.text, '{"id":7,"ok":true}');
    expect(back.toMap().toString(), action.toMap().toString());
  });

  group('ProxieRule.fromMap', () {
    Map<String, Object?> base() => _rule('x', '*').toMap();

    test('missing phase means both', () {
      final m = base()..remove('phase');
      expect(ProxieRule.fromMap(m).phase, BreakpointPhase.both);
    });

    test('unknown kind, phase or failure throw FormatException', () {
      expect(
        () => ProxieRule.fromMap(base()..['kind'] = 'nope'),
        throwsFormatException,
      );
      expect(
        () => ProxieRule.fromMap(base()..remove('kind')),
        throwsFormatException,
      );
      expect(
        () => ProxieRule.fromMap(base()..['phase'] = 'nope'),
        throwsFormatException,
      );
      expect(
        () => MapLocalAction.fromMap({'failure': 'nope'}),
        throwsFormatException,
      );
      expect(
        () => ProxieRule.fromMap(
          base()..['mapLocal'] = {'delayMs': 0, 'failure': 'nope'},
        ),
        throwsFormatException,
      );
    });
  });

  test('copyWith can clear method and mapLocal', () {
    final rule = _rule(
      'm',
      '*',
      method: 'GET',
      kind: RuleKind.mapLocal,
      mapLocal: const MapLocalAction(failure: SimulatedFailure.timeout),
    );
    expect(rule.copyWith(name: 'n').method, 'GET');
    expect(rule.copyWith(name: 'n').mapLocal, isNotNull);
    final cleared = rule.copyWith(clearMethod: true, clearMapLocal: true);
    expect(cleared.method, isNull);
    expect(cleared.mapLocal, isNull);
    expect(cleared.id, 'm');
  });
}
