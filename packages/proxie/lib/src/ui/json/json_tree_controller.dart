import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import 'package:proxie/src/json/json_commands.dart';
import 'package:proxie/src/json/json_document.dart';
import 'package:proxie/src/json/json_row.dart';
import 'package:proxie/src/json/json_schema.dart';
import 'package:proxie/src/worker/worker.dart';

/// Where a [JsonTreeController] stands.
enum JsonTreeStatus {
  /// The document is being opened.
  loading,

  /// The document is open and has rows.
  ready,

  /// The body is not JSON (or was cut at capture); see
  /// [JsonTreeController.parseError].
  invalid,

  /// The worker failed or the document was closed; see
  /// [JsonTreeController.error] and [JsonTreeController.retry].
  failed,
}

/// The rows of one call body's JSON document, held open in the worker and
/// fetched in windows of [windowSize] for a virtualized tree.
///
/// Every operation runs in the worker; failures never throw out of this
/// controller (except [encode]) and show as [JsonTreeStatus.failed] with
/// [retry], or as [editError] for an edit the document refused.
class JsonTreeController extends ChangeNotifier {
  /// Opens the [which] (`'request'` or `'response'`) body of call [callId]
  /// in [worker]. [editable] says whether the view offers edits.
  JsonTreeController(
    this.worker,
    this.callId,
    this.which, {
    required this.editable,
  }) : side = JsonBodySide.values.byName(which) {
    unawaited(_serial(_open));
  }

  /// Rows fetched per worker round trip.
  static const int windowSize = 200;

  /// Windows kept in memory; the least recently used are dropped.
  static const int maxWindows = 8;

  /// Where the document lives.
  final ProxieWorker worker;

  /// The call whose body is shown.
  final String callId;

  /// `'request'` or `'response'`.
  final String which;

  /// [which] as a [JsonBodySide].
  final JsonBodySide side;

  /// Whether the view offers edits.
  final bool editable;

  JsonTreeStatus _status = JsonTreeStatus.loading;
  String? _docId;
  int _visibleCount = 0;
  String? _parseError;
  bool _truncated = false;
  Object? _error;
  String? _editError;
  bool _edited = false;

  // Row windows by index, least recently used first.
  final LinkedHashMap<int, List<JsonRow>> _windows = LinkedHashMap();
  final Set<int> _fetching = {};
  int _lastWindow = -1;
  // Bumped whenever cached rows stop matching the worker's document.
  int _generation = 0;
  // While a toggle, edit or reveal runs, no windows are fetched.
  bool _busy = false;

  final Map<int, ArraySchema?> _schemas = {};
  final Set<int> _schemaFetching = {};

  String _query = '';
  List<int> _matches = const [];
  int _matchIndex = -1;
  int? _pendingReveal;

  Future<void> _tail = Future.value();
  bool _disposed = false;

  /// Where the controller stands.
  JsonTreeStatus get status => _status;

  /// Rows the tree shows.
  int get visibleCount => _visibleCount;

  /// Why the body has no tree, when [status] is [JsonTreeStatus.invalid].
  String? get parseError => _parseError;

  /// Whether the body was cut at capture.
  bool get truncated => _truncated;

  /// What failed, when [status] is [JsonTreeStatus.failed].
  Object? get error => _error;

  /// Whether [error] is a document the worker closed or evicted; [retry]
  /// reopens it from the stored body, so earlier edits are gone.
  bool get closed => _isClosed(_error);

  /// Why the last edit was refused; the document is unchanged.
  String? get editError => _editError;

  /// Whether an edit was applied since the document was opened.
  bool get edited => _edited;

  /// The last search text.
  String get query => _query;

  /// Node ids matching [query], in document order.
  List<int> get matches => _matches;

  /// Index into [matches] of the revealed match; -1 when none.
  int get matchIndex => _matchIndex;

  /// The node id of the revealed match, if any.
  int? get currentMatch => _matchIndex < 0 || _matchIndex >= _matches.length
      ? null
      : _matches[_matchIndex];

  /// The row at visible index [i], or null while its window is fetched
  /// (the controller notifies when it arrives).
  JsonRow? rowAt(int i) {
    if (i < 0 || i >= _visibleCount) return null;
    final w = i ~/ windowSize;
    final rows = _windows[w];
    if (rows == null) {
      _fetch(w);
      return null;
    }
    if (w != _lastWindow) {
      _lastWindow = w;
      _windows[w] = _windows.remove(w)!;
    }
    final j = i - w * windowSize;
    return j < rows.length ? rows[j] : null;
  }

  /// The schema of array [nodeId]; null while it is fetched (the
  /// controller notifies) or when the array holds no objects.
  ArraySchema? schemaOf(int nodeId) {
    if (_schemas.containsKey(nodeId)) return _schemas[nodeId];
    final docId = _docId;
    if (docId == null || _busy || _status != JsonTreeStatus.ready) return null;
    if (!_schemaFetching.add(nodeId)) return null;
    final generation = _generation;
    unawaited(
      worker
          .run(JsonSchema(docId, nodeId))
          .then(
            (schema) {
              _schemaFetching.remove(nodeId);
              if (_disposed || generation != _generation) return;
              _schemas[nodeId] = schema;
              _notify();
            },
            onError: (Object e, StackTrace st) {
              _schemaFetching.remove(nodeId);
              if (generation == _generation) _fail(e, st);
            },
          ),
    );
    return null;
  }

  /// Whether [schemaOf] has an answer for [nodeId].
  bool hasSchema(int nodeId) => _schemas.containsKey(nodeId);

  /// Expands or collapses container [nodeId].
  Future<void> toggle(int nodeId) =>
      _mutate((docId) => worker.run(JsonToggle(docId, nodeId)));

  /// Applies [e] in the worker. An edit the document refuses sets
  /// [editError] instead; other failures set [JsonTreeStatus.failed].
  Future<void> apply(JsonEdit e) =>
      _mutate((docId) => worker.run(JsonApply(docId, e)), edit: true);

  /// Finds the nodes matching [q] and reveals the first; an empty [q]
  /// clears the search.
  Future<void> search(String q) => _serial(() async {
    _query = q;
    _matches = const [];
    _matchIndex = -1;
    final docId = _docId;
    if (q.isEmpty || docId == null || _status != JsonTreeStatus.ready) {
      _notify();
      return;
    }
    try {
      final ids = await worker.run(JsonSearch(docId, q));
      if (_disposed) return;
      _matches = ids;
      if (ids.isEmpty) {
        _notify();
        return;
      }
      await _reveal(docId, 0);
    } on Object catch (e, st) {
      _fail(e, st);
    }
  });

  /// Reveals the match after the current one, wrapping around.
  Future<void> nextMatch() => _step(1);

  /// Reveals the match before the current one, wrapping around.
  Future<void> previousMatch() => _step(-1);

  Future<void> _step(int by) => _serial(() async {
    final docId = _docId;
    if (_matches.isEmpty || docId == null) return;
    final n = _matches.length;
    try {
      await _reveal(docId, ((_matchIndex + by) % n + n) % n);
    } on Object catch (e, st) {
      _fail(e, st);
    }
  });

  /// The row index the view should scroll to, once; null when none is
  /// pending.
  int? takeReveal() {
    final row = _pendingReveal;
    _pendingReveal = null;
    return row;
  }

  /// The whole value of scalar [nodeId]; null (with [editError] set) when
  /// it cannot be read.
  Future<String?> scalarText(int nodeId) async {
    final docId = _docId;
    if (docId == null) return null;
    try {
      return await worker.run(JsonScalarText(docId, nodeId));
    } on Object catch (e, st) {
      _editFailed(e, st);
      return null;
    }
  }

  /// The document as UTF-8 JSON (see [JsonEncode]), indented when
  /// [pretty]. Throws a [StateError] when the document is not open, and
  /// the worker's error when encoding fails.
  Future<Uint8List> encode({bool pretty = false}) async {
    final docId = _docId;
    if (docId == null || _status != JsonTreeStatus.ready) {
      throw StateError('JSON document is not open');
    }
    return await worker.run(JsonEncode(docId, pretty: pretty));
  }

  /// Opens the document again after a failure.
  Future<void> retry() => _serial(_open);

  /// Drops every edit: closes the document and opens the stored body.
  Future<void> revert() => _serial(() async {
    final docId = _docId;
    if (docId != null) {
      try {
        await worker.run(CloseJson(docId));
      } on Object catch (e, st) {
        _fail(e, st);
        return;
      }
    }
    await _open();
  });

  /// Clears [editError].
  void clearEditError() {
    if (_editError == null) return;
    _editError = null;
    _notify();
  }

  Future<void> _open() async {
    _status = JsonTreeStatus.loading;
    _error = null;
    _editError = null;
    _reset();
    _notify();
    try {
      final handle = await worker.run(OpenJson(callId, side));
      if (_disposed) return;
      _docId = handle.docId;
      _visibleCount = handle.visibleCount;
      _truncated = handle.truncated;
      _parseError = handle.parseError;
      _edited = false;
      _status = handle.parseError == null
          ? JsonTreeStatus.ready
          : JsonTreeStatus.invalid;
      _notify();
    } on Object catch (e, st) {
      _fail(e, st);
    }
  }

  void _reset() {
    _generation++;
    _windows.clear();
    _lastWindow = -1;
    _schemas.clear();
    _query = '';
    _matches = const [];
    _matchIndex = -1;
    _pendingReveal = null;
  }

  void _fetch(int w) {
    final docId = _docId;
    if (docId == null || _busy || _status != JsonTreeStatus.ready) return;
    if (!_fetching.add(w)) return;
    final generation = _generation;
    unawaited(
      worker
          .run(JsonRows(docId, w * windowSize, windowSize))
          .then(
            (rows) {
              _fetching.remove(w);
              if (_disposed || generation != _generation) return;
              _store(w, rows);
              _notify();
            },
            onError: (Object e, StackTrace st) {
              _fetching.remove(w);
              if (generation == _generation) _fail(e, st);
            },
          ),
    );
  }

  void _store(int w, List<JsonRow> rows) {
    _windows
      ..remove(w)
      ..[w] = rows;
    while (_windows.length > maxWindows) {
      _windows.remove(_windows.keys.first);
    }
  }

  /// Runs [op] (which returns the new visible count), then refetches the
  /// cached windows before showing the result, so rows never show stale.
  Future<void> _mutate(
    Future<int> Function(String docId) op, {
    bool edit = false,
  }) => _serial(() async {
    final docId = _docId;
    if (docId == null || _status != JsonTreeStatus.ready) return;
    _busy = true;
    try {
      final int count;
      try {
        count = await op(docId);
      } on Object catch (e, st) {
        // A refused edit leaves the document as it was.
        if (edit && !_isClosed(e) && e is ProxieWorkerException) {
          _editFailed(e, st);
        } else {
          _fail(e, st);
        }
        return;
      }
      if (_disposed) return;
      if (edit) {
        _edited = true;
        _editError = null;
        _schemas.clear();
        _matches = const [];
        _matchIndex = -1;
      }
      await _refresh(docId, count);
    } on Object catch (e, st) {
      _fail(e, st);
    } finally {
      _busy = false;
    }
  });

  /// Expands the ancestors of match [i] and asks the view to scroll to it.
  Future<void> _reveal(String docId, int i) async {
    _busy = true;
    try {
      final row = await worker.run(JsonReveal(docId, _matches[i]));
      final count = await worker.run(JsonVisibleCount(docId));
      if (_disposed) return;
      _matchIndex = i;
      _pendingReveal = row;
      await _refresh(docId, count, also: row ~/ windowSize);
    } finally {
      _busy = false;
    }
  }

  Future<void> _refresh(String docId, int count, {int? also}) async {
    final wanted = <int>{
      for (final w in _windows.keys)
        if (w * windowSize < count) w,
      ?also,
    }.toList();
    final rows = await Future.wait([
      for (final w in wanted)
        worker.run(JsonRows(docId, w * windowSize, windowSize)),
    ]);
    if (_disposed) return;
    _generation++;
    _windows.clear();
    _lastWindow = -1;
    for (var k = 0; k < wanted.length; k++) {
      _store(wanted[k], rows[k]);
    }
    _visibleCount = count;
    _notify();
  }

  void _editFailed(Object e, StackTrace st) {
    if (_isClosed(e) || e is! ProxieWorkerException) {
      _fail(e, st);
      return;
    }
    if (_disposed) return;
    _editError = e.message;
    _notify();
  }

  void _fail(Object e, StackTrace st) {
    developer.log(
      'Proxie JSON tree failed',
      name: 'proxie',
      error: e,
      stackTrace: st,
    );
    if (_disposed) return;
    _reset();
    _error = e;
    _status = JsonTreeStatus.failed;
    _notify();
  }

  /// Runs [op] after every earlier operation.
  Future<void> _serial(Future<void> Function() op) {
    final next = _tail.then((_) => _disposed ? null : op());
    _tail = next.then((_) {}, onError: (Object _) {});
    return next.then((_) {}, onError: _fail);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

bool _isClosed(Object? e) =>
    e is JsonDocumentClosed ||
    (e is ProxieWorkerException && e.type == 'JsonDocumentClosed');
