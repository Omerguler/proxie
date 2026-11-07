import 'package:flutter/foundation.dart';

import 'package:proxie/src/core/presets.dart';
import 'package:proxie/src/core/rule.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/call_query.dart';
import 'package:proxie/src/storage/store.dart';

class _Entry {
  /// Stores an independent serialized copy of [source].
  factory _Entry(ProxieCall source) {
    final map = source.toMap();
    return _Entry._(map, ProxieCall.fromMap(map));
  }
  _Entry._(this.map, this.call)
    : summary = CallSummary.fromCall(call),
      bodyBytes =
          call.request.body.bytes.length +
          (call.response?.body.bytes.length ?? 0);

  final Map<String, Object?> map;
  final ProxieCall call;
  final CallSummary summary;
  final int bodyBytes;
}

/// A [ProxieStore] that keeps everything in memory.
///
/// Like a database it stores serialized copies, so later mutation of objects
/// passed in or handed out never changes what is stored.
///
/// The bodies it holds stay within [maxBodyBytes], which a device can run out
/// of long before the retention count: the oldest calls go first, and the
/// newest always stays, however large.
class MemoryStore implements ProxieStore {
  /// Creates an empty store; [now] stands in for the clock in tests.
  MemoryStore({DateTime Function()? now, this.maxBodyBytes = _defaultBudget})
    : _now = now ?? DateTime.now;

  static const int _defaultBudget = 100 * 1024 * 1024;

  /// How many bytes of request and response bodies to hold.
  final int maxBodyBytes;

  int _bodyBytes = 0;
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
    final entry = _Entry(c);
    _bodyBytes += entry.bodyBytes - (_calls[c.id]?.bodyBytes ?? 0);
    _calls[c.id] = entry;
    if (_bodyBytes > maxBodyBytes) _evictOldest();
  }

  /// Removes the oldest calls, never the newest, until the bodies fit.
  void _evictOldest() {
    final newestFirst = _calls.values.toList()
      ..sort((a, b) => _newestFirst(a.summary, b.summary));
    for (final e in newestFirst.skip(1).toList().reversed) {
      if (_bodyBytes <= maxBodyBytes) return;
      _calls.remove(e.summary.id);
      _bodyBytes -= e.bodyBytes;
    }
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
    // Round-trip through toMap to hand out copies of the body bytes.
    return e == null ? null : ProxieCall.fromMap(e.call.toMap());
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
        // Decode twice: the first validates, the second yields copies that
        // share no byte buffers with the stored map.
        out.add(ProxieRule.fromMap(ProxieRule.fromMap(m).toMap()));
      } on Object catch (e) {
        // Skip rules that no longer decode (e.g. written by a newer version).
        if (!isStoredRowError(e)) rethrow;
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
        final action = MapLocalAction.fromMap(m['action']! as Map);
        out.add(
          ResponsePreset(
            id: m['id']! as String,
            label: m['label']! as String,
            build: (_) => MapLocalAction.fromMap(action.toMap()),
          ),
        );
      } on Object catch (e) {
        // Skip presets that no longer decode.
        if (!isStoredRowError(e)) rethrow;
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

  /// Test hook: appends [raw] as a stored rule without validating it.
  @visibleForTesting
  void debugInsertRawRule(Map<String, Object?> raw) => _rules.add(raw);

  /// Test hook: stores [raw] as the custom preset [id] without validating it.
  @visibleForTesting
  void debugInsertRawPreset(String id, Map<String, Object?> raw) =>
      _presets[id] = raw;

  @override
  Future<void> trim({required int maxCalls, required Duration maxAge}) async {
    final cutoff = _now().subtract(maxAge);
    _calls.removeWhere((_, e) {
      final old = e.summary.startedAt.isBefore(cutoff);
      if (old) _bodyBytes -= e.bodyBytes;
      return old;
    });
    final keep = maxCalls < 0 ? 0 : maxCalls;
    if (_calls.length <= keep) return;
    final sorted = _calls.values.map((e) => e.summary).toList()
      ..sort(_newestFirst);
    for (final s in sorted.skip(keep)) {
      _bodyBytes -= _calls.remove(s.id)!.bodyBytes;
    }
  }

  @override
  Future<void> clear() async {
    _calls.clear();
    _bodyBytes = 0;
    _sessions.clear();
  }

  @override
  Future<void> close() async {}
}

int _newestFirst(CallSummary a, CallSummary b) {
  final c = b.startedAt.compareTo(a.startedAt);
  return c != 0 ? c : b.id.compareTo(a.id);
}
