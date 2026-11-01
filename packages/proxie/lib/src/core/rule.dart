import '../model/request.dart';
import '../model/response.dart';
import 'url_matcher.dart';

enum RuleKind { breakpoint, mapLocal }

enum BreakpointPhase { request, response, both }

/// A failure a Map Local rule can simulate instead of responding.
enum SimulatedFailure { timeout, noConnection }

/// What a Map Local rule does: respond with [response], after [delay], or fail.
class MapLocalAction {
  const MapLocalAction({
    this.response,
    this.delay = Duration.zero,
    this.failure,
  });

  factory MapLocalAction.fromMap(Map<dynamic, dynamic> map) => MapLocalAction(
    response: map['response'] == null
        ? null
        : ProxieResponse.fromMap(map['response'] as Map),
    delay: Duration(milliseconds: map['delayMs'] as int? ?? 0),
    failure: map['failure'] == null
        ? null
        : SimulatedFailure.values.byName(map['failure'] as String),
  );

  final ProxieResponse? response;
  final Duration delay;
  final SimulatedFailure? failure;

  Map<String, Object?> toMap() => {
    'response': response?.toMap(),
    'delayMs': delay.inMilliseconds,
    'failure': failure?.name,
  };
}

/// A breakpoint or Map Local rule.
class ProxieRule {
  const ProxieRule({
    required this.id,
    required this.name,
    this.enabled = true,
    required this.kind,
    required this.matcher,
    this.method,
    this.phase = BreakpointPhase.both,
    this.mapLocal,
  });

  factory ProxieRule.fromMap(Map<dynamic, dynamic> map) => ProxieRule(
    id: map['id'] as String,
    name: map['name'] as String,
    enabled: map['enabled'] as bool? ?? true,
    kind: RuleKind.values.byName(map['kind'] as String),
    matcher: UrlMatcher.fromMap(map['matcher'] as Map),
    method: map['method'] as String?,
    phase: BreakpointPhase.values.byName(map['phase'] as String),
    mapLocal: map['mapLocal'] == null
        ? null
        : MapLocalAction.fromMap(map['mapLocal'] as Map),
  );

  final String id;
  final String name;
  final bool enabled;
  final RuleKind kind;
  final UrlMatcher matcher;

  /// Null matches any method; otherwise compared case-insensitively.
  final String? method;
  final BreakpointPhase phase;
  final MapLocalAction? mapLocal;

  bool matches(ProxieRequest request) =>
      enabled &&
      (method == null ||
          method!.toUpperCase() == request.method.toUpperCase()) &&
      matcher.matches(request.url);

  ProxieRule copyWith({
    String? id,
    String? name,
    bool? enabled,
    RuleKind? kind,
    UrlMatcher? matcher,
    String? method,
    BreakpointPhase? phase,
    MapLocalAction? mapLocal,
  }) => ProxieRule(
    id: id ?? this.id,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    kind: kind ?? this.kind,
    matcher: matcher ?? this.matcher,
    method: method ?? this.method,
    phase: phase ?? this.phase,
    mapLocal: mapLocal ?? this.mapLocal,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'kind': kind.name,
    'matcher': matcher.toMap(),
    'method': method,
    'phase': phase.name,
    'mapLocal': mapLocal?.toMap(),
  };
}

/// An ordered rule list; the first enabled match wins.
class RuleSet {
  const RuleSet(this.rules);

  final List<ProxieRule> rules;

  ProxieRule? requestBreakpointFor(ProxieRequest request) => _first(
    request,
    RuleKind.breakpoint,
    (p) => p == BreakpointPhase.request || p == BreakpointPhase.both,
  );

  ProxieRule? responseBreakpointFor(ProxieRequest request) => _first(
    request,
    RuleKind.breakpoint,
    (p) => p == BreakpointPhase.response || p == BreakpointPhase.both,
  );

  ProxieRule? mapLocalFor(ProxieRequest request) =>
      _first(request, RuleKind.mapLocal, (_) => true);

  ProxieRule? _first(
    ProxieRequest request,
    RuleKind kind,
    bool Function(BreakpointPhase) phaseOk,
  ) {
    for (final r in rules) {
      if (r.kind == kind && phaseOk(r.phase) && r.matches(request)) return r;
    }
    return null;
  }
}
