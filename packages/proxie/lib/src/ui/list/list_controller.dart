import 'dart:async';
import 'dart:developer' as developer;

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
/// have changed) reloads the count and the loaded pages from the worker, at
/// most one reload at a time, so the list always shows what the store holds.
class ListController extends ChangeNotifier {
  /// Creates the controller and starts loading the first page.
  ListController({
    required ProxieWorker worker,
    required Stream<ProxieCall> calls,
    CallQuery query = const CallQuery(),
  }) : _worker = worker,
       _query = query {
    _sub = calls.listen(_onCall);
    refresh();
  }

  /// How many calls each worker query loads.
  static const int pageSize = 100;

  /// How long [search] waits for typing to pause before querying.
  static const Duration searchDebounce = Duration(milliseconds: 250);

  final ProxieWorker _worker;
  late final StreamSubscription<ProxieCall> _sub;
  CallQuery _query;
  int _count = 0;
  Map<int, List<CallSummary>> _pages = {};
  final Set<int> _requested = {};
  Map<int, SessionInfo> _sessions = {};
  int _generation = 0;
  bool _reloading = false;
  bool _reloadAgain = false;
  Timer? _searchTimer;
  bool _disposed = false;

  /// The filters the rows match; setting it reloads the list.
  CallQuery get query => _query;

  set query(CallQuery value) {
    if (_disposed) return;
    _searchTimer?.cancel();
    _query = value;
    // Results still on their way for the old filters are dropped.
    _generation++;
    notifyListeners();
    refresh();
  }

  /// How many calls match [query].
  int get count => _count;

  /// The [i]th matching call, or null while its page is still loading (the
  /// load starts on the first ask) or when [i] is out of range.
  CallSummary? rowAt(int i) {
    if (i < 0 || i >= _count) return null;
    final page = _pages[i ~/ pageSize];
    if (page == null) {
      _loadPage(i ~/ pageSize);
      return null;
    }
    final at = i % pageSize;
    return at < page.length ? page[at] : null;
  }

  /// The recorded session [id], or null when it is unknown.
  SessionInfo? session(int id) => _sessions[id];

  /// Sets [query]'s text once [text] has not changed for [searchDebounce].
  void search(String text) {
    if (_disposed) return;
    _searchTimer?.cancel();
    _searchTimer = Timer(searchDebounce, () {
      final trimmed = text.trim();
      query = trimmed.isEmpty
          ? _query.copyWith(clearText: true)
          : _query.copyWith(text: trimmed);
    });
  }

  /// Reloads the count, the sessions and every loaded page (at least the
  /// first) from the worker, then swaps them in at once. Asked while a reload
  /// runs, it lets that one finish and starts another, so a steady stream of
  /// calls still shows each snapshot.
  void refresh() {
    if (_disposed) return;
    if (_reloading) {
      _reloadAgain = true;
      return;
    }
    unawaited(_reload());
  }

  Future<void> _reload() async {
    _reloading = true;
    try {
      do {
        _reloadAgain = false;
        final generation = _generation;
        final q = _query;
        final pages = {0, ..._pages.keys}.toList()..sort();
        final List<Object?> results;
        try {
          results = await Future.wait<Object?>([
            _worker.run(CountCalls(q)),
            _worker.run(const ListSessions()),
            for (final p in pages)
              _worker.run(QueryCalls(q, offset: p * pageSize, limit: pageSize)),
          ]);
        } on Object catch (e, st) {
          _log('Proxie failed to load the call list', e, st);
          return;
        }
        if (_disposed) return;
        if (generation != _generation) continue;
        _count = results[0]! as int;
        _sessions = {for (final s in results[1]! as List<SessionInfo>) s.id: s};
        _pages = {
          for (var i = 0; i < pages.length; i++)
            pages[i]: List.of(results[i + 2]! as List<CallSummary>),
        };
        _requested.clear();
        notifyListeners();
      } while (_reloadAgain && !_disposed);
    } finally {
      _reloading = false;
    }
  }

  void _loadPage(int page) {
    if (_disposed || !_requested.add(page)) return;
    final generation = _generation;
    unawaited(
      _worker
          .run(QueryCalls(_query, offset: page * pageSize, limit: pageSize))
          .then(
            (rows) {
              if (_disposed || generation != _generation) return;
              // May be a snapshot off by a few new calls; the next reload
              // includes this page and corrects it.
              _pages[page] = List.of(rows);
              notifyListeners();
            },
            onError: (Object e, StackTrace st) {
              _requested.remove(page);
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
      if (!_matchesEverything(_query)) refresh();
      return;
    }
    refresh();
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
    _searchTimer?.cancel();
    unawaited(_sub.cancel());
    super.dispose();
  }
}
