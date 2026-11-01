import '../model/body.dart';
import '../worker/worker.dart';
import 'json_document.dart';
import 'json_row.dart';

/// Documents kept open per worker; opening more evicts the least recently
/// used one.
const int maxOpenJsonDocs = 8;

/// A JSON document opened in the worker.
class JsonHandle {
  const JsonHandle({
    required this.docId,
    required this.visibleCount,
    this.parseError,
    required this.truncated,
  });

  /// Names the document in later commands; valid until [CloseJson] or
  /// eviction.
  final String docId;

  final int visibleCount;

  /// Why there is no tree; null when the body parsed.
  final String? parseError;

  /// Whether the body was cut at capture.
  final bool truncated;
}

/// Parses the request or response body of call [callId] into a document
/// held by the worker. Bodies of any kind are attempted, since JSON is
/// often mislabeled.
class OpenJson extends WorkerCommand<JsonHandle> {
  const OpenJson(this.callId, this.which);

  final String callId;

  /// `'request'` or `'response'`.
  final String which;

  static const truncatedError =
      'Body was truncated at capture; full JSON unavailable';

  @override
  Future<JsonHandle> execute(WorkerContext ctx) async {
    if (which != 'request' && which != 'response') {
      throw ArgumentError.value(which, 'which', "Not 'request' or 'response'");
    }
    final call = await ctx.store.get(callId);
    if (call == null) throw StateError('No call $callId');
    final ProxieBody body;
    if (which == 'request') {
      body = call.request.body;
    } else {
      final response = call.response;
      if (response == null) throw StateError('Call $callId has no response');
      body = response.body;
    }
    final doc = JsonDocument.tryParse(body.bytes);
    final docs = _JsonDocs.of(ctx);
    final docId = docs.add(doc);
    return JsonHandle(
      docId: docId,
      visibleCount: doc.visibleCount,
      parseError: doc.parseError == null
          ? null
          : (body.truncated ? truncatedError : doc.parseError),
      truncated: body.truncated,
    );
  }
}

class JsonRows extends WorkerCommand<List<JsonRow>> {
  const JsonRows(this.docId, this.start, this.count);

  final String docId;
  final int start;
  final int count;

  @override
  Future<List<JsonRow>> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).get(docId).rows(start, count);
}

/// Expands or collapses a node; returns the new visible row count.
class JsonToggle extends WorkerCommand<int> {
  const JsonToggle(this.docId, this.nodeId);

  final String docId;
  final int nodeId;

  @override
  Future<int> execute(WorkerContext ctx) async {
    final doc = _JsonDocs.of(ctx).get(docId);
    doc.toggle(nodeId);
    return doc.visibleCount;
  }
}

/// Releases a document; unknown ids are ignored.
class CloseJson extends WorkerCommand<void> {
  const CloseJson(this.docId);

  final String docId;

  @override
  Future<void> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).remove(docId);
}

/// Open documents, stored in [WorkerContext.resources] as `json:<docId>`,
/// plus their use order.
class _JsonDocs {
  _JsonDocs(this._resources);

  static const _registryKey = 'json:#registry';

  static _JsonDocs of(WorkerContext ctx) =>
      ctx.resources.putIfAbsent(_registryKey, () => _JsonDocs(ctx.resources))
          as _JsonDocs;

  final Map<String, Object> _resources;

  /// Open doc ids, least recently used first.
  final List<String> _order = [];
  int _nextId = 0;

  String add(JsonDocument doc) {
    while (_order.length >= maxOpenJsonDocs) {
      remove(_order.first);
    }
    final id = '${_nextId++}';
    _resources['json:$id'] = doc;
    _order.add(id);
    return id;
  }

  JsonDocument get(String docId) {
    final doc = _resources['json:$docId'];
    if (doc is! JsonDocument) throw StateError('No open JSON document $docId');
    _order
      ..remove(docId)
      ..add(docId);
    return doc;
  }

  void remove(String docId) {
    _order.remove(docId);
    _resources.remove('json:$docId');
  }
}
