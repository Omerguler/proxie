import 'dart:typed_data';

import '../model/body.dart';
import '../worker/worker.dart';
import 'json_document.dart';
import 'json_row.dart';
import 'json_schema.dart';

/// Documents kept open per worker; opening more evicts the least recently
/// used one.
const int maxOpenJsonDocs = 8;

/// Total nodes kept open per worker; least recently used documents are
/// evicted to stay under it, though a single larger document is allowed
/// on its own.
const int maxOpenJsonNodes = 4000000;

/// Which body of a call to open.
enum JsonBodySide { request, response }

/// The document named by [docId] was closed, evicted or never opened.
class JsonDocumentClosed implements Exception {
  const JsonDocumentClosed(this.docId);

  final String docId;

  @override
  String toString() => 'JsonDocumentClosed: no open JSON document $docId';
}

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

/// Parses the [side] body of call [callId] into a document held by the
/// worker. Bodies of any kind are attempted, since JSON is often
/// mislabeled. Reopening an unchanged body returns the document already
/// open for it, expansion state included.
class OpenJson extends WorkerCommand<JsonHandle> {
  const OpenJson(this.callId, this.side);

  final String callId;
  final JsonBodySide side;

  static const truncatedError =
      'Body was truncated at capture; full JSON unavailable';

  @override
  Future<JsonHandle> execute(WorkerContext ctx) async {
    final call = await ctx.store.get(callId);
    if (call == null) throw StateError('No call $callId');
    final ProxieBody body;
    switch (side) {
      case JsonBodySide.request:
        body = call.request.body;
      case JsonBodySide.response:
        final response = call.response;
        if (response == null) throw StateError('Call $callId has no response');
        body = response.body;
    }
    final docs = _JsonDocs.of(ctx);
    final source = '$callId\u0000${side.name}';
    final (docId, doc) =
        docs.reuse(source, body.bytes) ??
        docs.add(source, body.bytes, JsonDocument.tryParse(body.bytes));
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

/// The schema of array node [nodeId]; null when it is not an array or holds
/// no objects.
class JsonSchema extends WorkerCommand<ArraySchema?> {
  const JsonSchema(this.docId, this.nodeId);

  final String docId;
  final int nodeId;

  @override
  Future<ArraySchema?> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).get(docId).schemaOf(nodeId);
}

/// Releases a document; unknown ids are ignored.
class CloseJson extends WorkerCommand<void> {
  const CloseJson(this.docId);

  final String docId;

  @override
  Future<void> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).remove(docId);
}

class _Entry {
  _Entry(this.source, this.bytes);

  /// `callId \0 side`.
  final String source;
  final Uint8List bytes;
}

/// Open documents, stored in [WorkerContext.resources] as `json:<docId>`,
/// plus their use order and origin.
class _JsonDocs {
  _JsonDocs(this._resources);

  static const _registryKey = 'json:#registry';

  static _JsonDocs of(WorkerContext ctx) =>
      ctx.resources.putIfAbsent(_registryKey, () => _JsonDocs(ctx.resources))
          as _JsonDocs;

  final Map<String, Object> _resources;

  /// Open doc ids, least recently used first.
  final Map<String, _Entry> _open = {};

  /// Doc id per `callId \0 side`.
  final Map<String, String> _bySource = {};
  int _nextId = 0;
  int _nodes = 0;

  JsonDocument _doc(String docId) => _resources['json:$docId'] as JsonDocument;

  /// The open document for [source] if its bytes are still [bytes]; a
  /// stale one is closed.
  (String, JsonDocument)? reuse(String source, Uint8List bytes) {
    final docId = _bySource[source];
    if (docId == null) return null;
    if (!_sameBytes(_open[docId]!.bytes, bytes)) {
      remove(docId);
      return null;
    }
    return (docId, get(docId));
  }

  (String, JsonDocument) add(String source, Uint8List bytes, JsonDocument doc) {
    while (_open.isNotEmpty &&
        (_open.length >= maxOpenJsonDocs ||
            _nodes + doc.nodeCount > maxOpenJsonNodes)) {
      remove(_open.keys.first);
    }
    final id = '${_nextId++}';
    _resources['json:$id'] = doc;
    _open[id] = _Entry(source, bytes);
    _bySource[source] = id;
    _nodes += doc.nodeCount;
    return (id, doc);
  }

  /// The open document [docId], marked as most recently used.
  JsonDocument get(String docId) {
    final entry = _open.remove(docId);
    if (entry == null) throw JsonDocumentClosed(docId);
    _open[docId] = entry;
    return _doc(docId);
  }

  void remove(String docId) {
    final entry = _open.remove(docId);
    if (entry == null) return;
    _nodes -= _doc(docId).nodeCount;
    _resources.remove('json:$docId');
    _bySource.remove(entry.source);
  }
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
