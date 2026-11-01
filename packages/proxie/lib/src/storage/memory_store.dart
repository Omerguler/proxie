import '../core/presets.dart';
import '../core/rule.dart';
import '../model/body.dart';
import '../model/call.dart';
import 'call_query.dart';
import 'store.dart';

class _Entry {
  _Entry._(this.map, this.call) : summary = CallSummary.fromCall(call);

  /// Stores an independent serialized copy of [source].
  factory _Entry(ProxieCall source) {
    final map = source.toMap();
    return _Entry._(map, ProxieCall.fromMap(map));
  }

  final Map<String, Object?> map;
  final ProxieCall call;
  final CallSummary summary;
}

/// A [ProxieStore] that keeps everything in memory.
///
/// Like a database it stores serialized copies, so later mutation of objects
/// passed in or handed out never changes what is stored.
class MemoryStore implements ProxieStore {
  MemoryStore({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Map<String, _Entry> _calls = {};
  final Map<int, DateTime> _sessions = {};
  final Map<String, Map<String, Object?>> _presets = {};
  List<Map<String, Object?>> _rules = [];
  int _lastSession = 0;

  @override
  Future<int> startSession() async {
    final id = ++_lastSession;
    _sessions[id] = _now();
    return id;
  }

  @override
  Future<void> upsert(ProxieCall c) async {
    _calls[c.id] = _Entry(c);
  }

  Iterable<_Entry> _matching(CallQuery q) {
    final text = q.text?.toLowerCase();
    final methods = {for (final m in q.methods) m.toUpperCase()};
    return _calls.values.where((e) {
      final s = e.summary;
      if (q.sessionId != null && s.sessionId != q.sessionId) return false;
      if (q.adapters.isNotEmpty && !q.adapters.contains(s.adapter)) {
        return false;
      }
      if (methods.isNotEmpty && !methods.contains(s.method.toUpperCase())) {
        return false;
      }
      final code = s.statusCode;
      switch (q.status) {
        case StatusFilter.all:
          break;
        case StatusFilter.success:
          if (code == null || code < 200 || code > 399 || s.hasError) {
            return false;
          }
        case StatusFilter.errors:
          if (!s.hasError && (code == null || code < 400)) return false;
      }
      if (q.onlyJson && s.kind != BodyKind.json) return false;
      if (q.hideBinary &&
          (s.kind == BodyKind.binary || s.kind == BodyKind.image)) {
        return false;
      }
      if (q.maxSize != null && s.responseSize > q.maxSize!) return false;
      if (text != null && text.isNotEmpty) {
        if (s.url.toLowerCase().contains(text)) return true;
        final body = e.call.response?.body;
        if (body == null ||
            (body.kind != BodyKind.json && body.kind != BodyKind.text)) {
          return false;
        }
        return body.text?.toLowerCase().contains(text) ?? false;
      }
      return true;
    });
  }

  @override
  Future<List<CallSummary>> query(
    CallQuery q, {
    required int offset,
    required int limit,
  }) async {
    final all = _matching(q).map((e) => e.summary).toList()..sort(_newestFirst);
    final start = offset < 0 ? 0 : offset;
    if (limit <= 0 || start >= all.length) return const [];
    final end = start + limit > all.length ? all.length : start + limit;
    return List.unmodifiable(all.sublist(start, end));
  }

  @override
  Future<int> count(CallQuery q) async => _matching(q).length;

  @override
  Future<ProxieCall?> get(String id) async {
    final e = _calls[id];
    return e == null ? null : ProxieCall.fromMap(e.map);
  }

  @override
  Future<List<SessionInfo>> sessions() async {
    final counts = <int, int>{};
    for (final e in _calls.values) {
      counts.update(e.summary.sessionId, (n) => n + 1, ifAbsent: () => 1);
    }
    final ids = _sessions.keys.toList()..sort((a, b) => b.compareTo(a));
    return [
      for (final id in ids)
        SessionInfo(
          id: id,
          startedAt: _sessions[id]!,
          callCount: counts[id] ?? 0,
        ),
    ];
  }

  @override
  Future<List<ProxieRule>> rules() async {
    final out = <ProxieRule>[];
    for (final m in _rules) {
      try {
        out.add(ProxieRule.fromMap(m));
      } catch (_) {
        // Skip rules that no longer decode (e.g. written by a newer version).
      }
    }
    return out;
  }

  @override
  Future<void> saveRules(List<ProxieRule> r) async {
    _rules = [for (final rule in r) rule.toMap()];
  }

  @override
  Future<List<ResponsePreset>> customPresets() async {
    final out = <ResponsePreset>[];
    for (final m in _presets.values) {
      try {
        final action = MapLocalAction.fromMap(m['action'] as Map);
        out.add(
          ResponsePreset(
            id: m['id'] as String,
            label: m['label'] as String,
            build: (_) => action,
          ),
        );
      } catch (_) {
        // Skip presets that no longer decode.
      }
    }
    return out;
  }

  @override
  Future<void> saveCustomPreset(
    String id,
    String label,
    MapLocalAction a,
  ) async {
    _presets[id] = {'id': id, 'label': label, 'action': a.toMap()};
  }

  @override
  Future<void> trim({required int maxCalls, required Duration maxAge}) async {
    final cutoff = _now().subtract(maxAge);
    _calls.removeWhere((_, e) => e.summary.startedAt.isBefore(cutoff));
    final keep = maxCalls < 0 ? 0 : maxCalls;
    if (_calls.length <= keep) return;
    final sorted = _calls.values.map((e) => e.summary).toList()
      ..sort(_newestFirst);
    for (final s in sorted.skip(keep)) {
      _calls.remove(s.id);
    }
  }

  @override
  Future<void> clear() async {
    _calls.clear();
    _sessions.clear();
  }

  @override
  Future<void> close() async {}
}

int _newestFirst(CallSummary a, CallSummary b) {
  final c = b.startedAt.compareTo(a.startedAt);
  return c != 0 ? c : b.id.compareTo(a.id);
}
