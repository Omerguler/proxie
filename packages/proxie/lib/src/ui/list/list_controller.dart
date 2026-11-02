import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:proxie/src/model/call.dart';
import 'package:proxie/src/storage/call_query.dart';
import 'package:proxie/src/storage/store.dart';
import 'package:proxie/src/worker/commands.dart';
import 'package:proxie/src/worker/worker.dart';

/// The rows of the call list: the calls matching [query], newest first,
/// loaded from the worker in pages of [pageSize] as they are asked for.
///
/// Listens to the engine's call stream: a call already loaded is updated in
/// place; anything else (a new call, or a filtered list whose matches may
/// have changed) schedules a reload, at most one per [reloadInterval]. A
/// reload fetches the count, the sessions and only the pages around the rows
/// last asked for; other pages are dropped and load again when needed, so
/// its cost does not grow with how far the list was scrolled.
class ListController extends ChangeNotifier {
  /// Creates the controller and starts loading the first page.
  ListController({
    required ProxieWorker worker,
    required Stream<ProxieCall> calls,
    CallQuery query = const CallQuery(),
    this.reloadInterval = const Duration(milliseconds: 250),
  }) : _worker = worker,
       _query = query {
    _sub = calls.listen(_onCall);
    refresh();
  }

  /// How many calls each worker query loads.
  static const int pageSize = 100;

  /// How long [search] waits for typing to pause before querying.
  static const Duration searchDebounce = Duration(milliseconds: 250);

  /// The shortest time between two reloads caused by the call stream.
  final Duration reloadInterval;

  final ProxieWorker _worker;
  late final StreamSubscription<ProxieCall> _sub;
  CallQuery _query;
  int _count = 0;
  Map<int, List<CallSummary>> _pages = {};
  Map<int, SessionInfo> _sessions = {};
  Map<int, int> _sessionMatches = {};
  Object? _error;

  // Pages with a query in flight (lazy loads and the running reload).
  final Set<int> _requested = {};
  Set<int> _reloadPages = const {};
  // Pages lazily loaded since the running reload started; its swap keeps
  // them.
  final Set<int> _loadedDuringReload = {};
  // The pages the last reload covered; reused while no rows are asked for.
  Set<int> _covered = {0};
  // The row asked for last since the last reload; it is on or near the
  // screen, since only built rows are asked for.
  int? _lastAsked;

  // Bumped by every query change: older results are dropped.
  int _generation = 0;
  // Bumped by every reload start: page loads started earlier are dropped.
  int _reloadEpoch = 0;
  bool _reloading = false;
  bool _reloadAgain = false;

  Timer? _cooldown;
  bool _changedDuringCooldown = false;
  Timer? _searchTimer;
  String? _pendingSearch;
  bool _disposed = false;

  /// The filters the rows match. Setting it drops the loaded rows and
  /// reloads from the first page; search text still waiting for its
  /// debounce is applied too.
  CallQuery get query => _query;

  set query(CallQuery value) {
    if (_disposed) return;
    final pending = _pendingSearch;
    _cancelSearch();
    _apply(pending == null ? value : _withText(value, pending));
  }

  /// Increases on every [query] change, so listeners can tell a new query
  /// from new calls.
  int get generation => _generation;

  /// How many calls match [query].
  int get count => _count;

  /// Why the last reload failed, or null when it succeeded.
  Object? get error => _error;

  /// The [i]th matching call, or null while its page is still loading (the
  /// load starts on the first ask) or when [i] is out of range.
  CallSummary? rowAt(int i) {
    if (i < 0 || i >= _count) return null;
    _lastAsked = i;
    final page = _pages[i ~/ pageSize];
    if (page == null) {
      _loadPage(i ~/ pageSize);
      return null;
    }
    final at = i % pageSize;
    return at < page.length ? page[at] : null;
  }

  /// The index of the loaded call [id], or null when no loaded page holds
  /// it.
  int? indexOf(String id) {
    for (final MapEntry(key: page, value: rows) in _pages.entries) {
      final i = rows.indexWhere((s) => s.id == id);
      if (i >= 0) return page * pageSize + i;
    }
    return null;
  }

  /// The recorded session [id], or null when it is unknown.
  SessionInfo? session(int id) => _sessions[id];

  /// How many calls of session [id] match [query]; null when [query] keeps
  /// every call (the session's own count applies) or it is unknown.
  int? sessionMatches(int id) => _sessionMatches[id];

  /// Sets [query]'s text once [text] has not changed for [searchDebounce].
  void search(String text) {
    if (_disposed) return;
    _searchTimer?.cancel();
    _pendingSearch = text;
    _searchTimer = Timer(searchDebounce, () {
      final pending = _pendingSearch;
      _cancelSearch();
      if (pending != null) _apply(_withText(_query, pending));
    });
  }

  /// Drops any pending search and clears [query]'s text now.
  void clearSearch() {
    if (_disposed) return;
    _cancelSearch();
    _apply(_query.copyWith(clearText: true));
  }

  /// Reloads the count, the sessions and the pages around the rows last
  /// asked for, then swaps them in at once. Asked while a reload runs, it
  /// lets that one finish and starts another.
  void refresh() {
    if (_disposed) return;
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    unawaited(_reload());
  }

  void _cancelSearch() {
    _searchTimer?.cancel();
    _searchTimer = null;
    _pendingSearch = null;
  }

  static CallQuery _withText(CallQuery q, String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty
        ? q.copyWith(clearText: true)
        : q.copyWith(text: trimmed);
  }

  void _apply(CallQuery value) {
    _query = value;
    _generation++;
    // Rows of the old query must not show while the new ones load.
    _pages = {};
    _loadedDuringReload.clear();
    _sessionMatches = {};
    _lastAsked = null;
    _covered = {0};
    _requested
      ..clear()
      ..add(0);
    notifyListeners();
    refresh();
  }

  Set<int> _pagesToReload() {
    final last = _lastAsked;
    _lastAsked = null;
    if (last == null) return _covered;
    // A screen holds far fewer than half a page of rows, so the pages within
    // half a page of the last asked row (at most two) cover it.
    const half = pageSize ~/ 2;
    return {math.max(0, last - half) ~/ pageSize, (last + half) ~/ pageSize};
  }

  Future<void> _reload() async {
    _reloading = true;
    try {
      do {
        _reloadAgain = false;
        final generation = _generation;
        final q = _query;
        final pages = _pagesToReload().toList()..sort();
        _reloadEpoch++;
        _reloadPages = pages.toSet();
        _loadedDuringReload.clear();
        _requested.addAll(pages);
        final List<Object?> results;
        final Map<int, int> matches;
        try {
          results = await Future.wait<Object?>([
            _worker.run(CountCalls(q)),
            _worker.run(const ListSessions()),
            for (final p in pages)
              _worker.run(QueryCalls(q, offset: p * pageSize, limit: pageSize)),
          ]);
          matches = _matchesEverything(q)
              ? const {}
              : await _countPerSession(q, results.skip(2));
        } on Object catch (e, st) {
          if (_disposed) return;
          if (generation != _generation) continue;
          _requested.removeAll(pages);
          _reloadPages = const {};
          _error = e;
          _log('Proxie failed to load the call list', e, st);
          notifyListeners();
          // A reload asked for meanwhile still runs (the loop condition).
          continue;
        }
        if (_disposed) return;
        // A query change cleared the requests and asked for another reload.
        if (generation != _generation) continue;
        _requested.removeAll(pages);
        _reloadPages = const {};
        _count = results[0]! as int;
        _sessions = {for (final s in results[1]! as List<SessionInfo>) s.id: s};
        _sessionMatches = matches;
        _pages = {
          for (final p in _loadedDuringReload) p: ?_pages[p],
          for (var i = 0; i < pages.length; i++)
            pages[i]: List.of(results[i + 2]! as List<CallSummary>),
        };
        _loadedDuringReload.clear();
        _covered = pages.toSet();
        _error = null;
        notifyListeners();
      } while (_reloadAgain && !_disposed);
    } finally {
      _reloading = false;
    }
  }

  Future<Map<int, int>> _countPerSession(
    CallQuery q,
    Iterable<Object?> pages,
  ) async {
    final ids = {
      for (final page in pages)
        for (final s in page! as List<CallSummary>) s.sessionId,
    }.toList();
    final counts = await Future.wait([
      for (final id in ids) _worker.run(CountCalls(q.copyWith(sessionId: id))),
    ]);
    return {for (var i = 0; i < ids.length; i++) ids[i]: counts[i]};
  }

  void _loadPage(int page) {
    if (_disposed || !_requested.add(page)) return;
    final generation = _generation;
    final epoch = _reloadEpoch;
    unawaited(
      _worker
          .run(QueryCalls(_query, offset: page * pageSize, limit: pageSize))
          .then(
            (rows) {
              if (_disposed || generation != _generation) return;
              if (epoch != _reloadEpoch) {
                // Older than the latest reload's snapshot: drop it and let
                // the next build ask again, unless that reload loads it.
                if (!_reloadPages.contains(page)) {
                  _requested.remove(page);
                  notifyListeners();
                }
                return;
              }
              _requested.remove(page);
              _pages[page] = List.of(rows);
              if (_reloading) _loadedDuringReload.add(page);
              notifyListeners();
            },
            onError: (Object e, StackTrace st) {
              if (generation == _generation) _requested.remove(page);
              _log('Proxie failed to load calls', e, st);
            },
          ),
    );
  }

  void _onCall(ProxieCall call) {
    if (_disposed) return;
    for (final page in _pages.values) {
      final i = page.indexWhere((s) => s.id == call.id);
      if (i < 0) continue;
      page[i] = CallSummary.fromCall(call);
      notifyListeners();
      // Unfiltered, a known call keeps its place; a filter may now drop it.
      if (!_matchesEverything(_query)) _scheduleReload();
      return;
    }
    _scheduleReload();
  }

  // Leading and trailing throttle: the first change reloads at once, later
  // ones within [reloadInterval] share one reload at its end.
  void _scheduleReload() {
    if (_cooldown != null) {
      _changedDuringCooldown = true;
      return;
    }
    refresh();
    _cooldown = Timer(reloadInterval, () {
      _cooldown = null;
      if (_changedDuringCooldown && !_disposed) {
        _changedDuringCooldown = false;
        _scheduleReload();
      }
    });
  }

  static bool _matchesEverything(CallQuery q) =>
      (q.text?.isEmpty ?? true) &&
      q.methods.isEmpty &&
      q.status == StatusFilter.all &&
      !q.onlyJson &&
      !q.hideBinary &&
      q.maxSize == null &&
      q.sessionId == null &&
      q.adapters.isEmpty;

  void _log(String message, Object error, StackTrace stack) {
    // A worker shut down under an open list is expected; nothing to report.
    if (_disposed) return;
    developer.log(message, name: 'proxie', error: error, stackTrace: stack);
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelSearch();
    _cooldown?.cancel();
    unawaited(_sub.cancel());
    super.dispose();
  }
}
