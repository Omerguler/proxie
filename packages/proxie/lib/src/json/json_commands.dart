import 'dart:typed_data';

import 'package:proxie/src/json/json_document.dart';
import 'package:proxie/src/json/json_row.dart';
import 'package:proxie/src/json/json_schema.dart';
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/worker/worker.dart';

/// Documents kept open per worker; opening more evicts the least recently
/// used one.
const int maxOpenJsonDocs = 8;

/// Total node capacity kept open per worker; least recently used documents
/// are evicted to stay under it, though a single larger document is allowed
/// on its own. An edit that would grow one document's capacity beyond it is
/// rejected (see [JsonDocument.maxCapacity]).
const int maxOpenJsonNodes = 4000000;

/// Which body of a call to open.
enum JsonBodySide {
  /// The body the app sent.
  request,

  /// The body the server answered with.
  response,
}

/// The document named by [docId] was closed, evicted or never opened.
class JsonDocumentClosed implements Exception, CodedWorkerError {
  /// Creates the error for the document [docId].
  const JsonDocumentClosed(this.docId);

  /// The [ProxieWorkerException.code] of this error.
  static const errorCode = 'json_document_closed';

  @override
  String get code => errorCode;

  /// The id that named no open document.
  final String docId;

  @override
  String toString() => 'JsonDocumentClosed: no open JSON document $docId';
}

/// A JSON document opened in the worker.
class JsonHandle {
  /// Describes a document the worker has just opened.
  const JsonHandle({
    required this.docId,
    required this.visibleCount,
    required this.truncated,
    this.parseError,
    this.dirty = false,
  });

  /// Names the document in later commands; valid until [CloseJson] or
  /// eviction.
  final String docId;

  /// How many rows the tree shows with the current expansion state.
  final int visibleCount;

  /// Why there is no tree; null when the body parsed.
  final String? parseError;

  /// Whether the body was cut at capture.
  final bool truncated;

  /// Whether the document returned already holds edits (it was reopened
  /// in the same scope after edits; see [OpenJson.scope]).
  final bool dirty;
}

/// Parses the [side] body of call [callId] into a document held by the
/// worker. Bodies of any kind are attempted, since JSON is often
/// mislabeled. Documents are kept per (callId, side, [scope]): reopening
/// an unchanged body in the same scope returns the document already open
/// for it, edits and expansion state included, while another scope gets
/// its own copy.
class OpenJson extends WorkerCommand<JsonHandle> {
  /// Creates a command that opens the [side] body of call [callId] in
  /// [scope]; with [bytes], those instead of the stored body.
  const OpenJson(this.callId, this.side, {this.scope = viewScope, this.bytes});

  /// The scope read-only views share.
  static const viewScope = 'view';

  /// Which copy of the document to open: read-only views share
  /// [viewScope]; each editor uses its own, so its edits stay in it.
  final String scope;

  /// The id of the call whose body is opened.
  final String callId;

  /// Which of the call's bodies is opened.
  final JsonBodySide side;

  /// A whole body to open instead of the stored one, such as a paused
  /// call's live body (not stored yet, and stored masked once it is).
  /// Refused in [viewScope] with an [ArgumentError].
  final Uint8List? bytes;

  /// The parse error reported for a body that was cut at capture, since
  /// its tail, not the JSON, is what is missing.
  static const truncatedError =
      'Body was truncated at capture; full JSON unavailable';

  @override
  Future<JsonHandle> execute(WorkerContext ctx) async {
    final live = this.bytes;
    // The view scope is shared by the read-only detail, which must only
    // ever show the stored (masked) body.
    if (live != null && scope == viewScope) {
      throw ArgumentError.value(scope, 'scope', 'Live bytes need own scope');
    }
    final (bytes, truncated) = live != null
        ? (live, false)
        : await _stored(ctx);
    final docs = _JsonDocs.of(ctx);
    final source = '$callId\u0000${side.name}\u0000$scope';
    final (docId, doc) =
        docs.reuse(source, bytes) ??
        docs.add(source, bytes, JsonDocument.tryParse(bytes));
    return JsonHandle(
      docId: docId,
      visibleCount: doc.visibleCount,
      parseError: doc.parseError == null
          ? null
          : (truncated ? truncatedError : doc.parseError),
      truncated: truncated,
      dirty: doc.dirty,
    );
  }

  /// The stored body's bytes and whether it was cut at capture.
  Future<(Uint8List, bool)> _stored(WorkerContext ctx) async {
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
    return (body.bytes, body.truncated);
  }
}

/// Up to [count] visible rows of a document, starting at row [start].
class JsonRows extends WorkerCommand<List<JsonRow>> {
  /// Creates a command that reads rows of document [docId].
  const JsonRows(this.docId, this.start, this.count);

  /// The document to read from.
  final String docId;

  /// Index of the first visible row to return.
  final int start;

  /// The most rows to return.
  final int count;

  @override
  Future<List<JsonRow>> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).get(docId).rows(start, count);
}

/// Expands or collapses a node; returns the new visible row count.
class JsonToggle extends WorkerCommand<int> {
  /// Creates a command that toggles node [nodeId] of document [docId].
  const JsonToggle(this.docId, this.nodeId);

  /// The document holding the node.
  final String docId;

  /// The container node to expand or collapse.
  final int nodeId;

  @override
  Future<int> execute(WorkerContext ctx) async {
    final doc = _JsonDocs.of(ctx).get(docId)..toggle(nodeId);
    return doc.visibleCount;
  }
}

/// The schema of array node [nodeId]; null when it is not an array or holds
/// no objects.
class JsonSchema extends WorkerCommand<ArraySchema?> {
  /// Creates a command that infers the schema of array [nodeId].
  const JsonSchema(this.docId, this.nodeId);

  /// The document holding the array.
  final String docId;

  /// The array node whose objects are inspected.
  final int nodeId;

  @override
  Future<ArraySchema?> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).get(docId).schemaOf(nodeId);
}

/// Applies [edit] to the document; returns the new visible row count. See
/// [JsonDocument.apply]; an edit that would grow the document's capacity
/// beyond [maxOpenJsonNodes] throws `StateError('Document too large to edit
/// further')`.
class JsonApply extends WorkerCommand<int> {
  /// Creates a command that applies [edit] to document [docId].
  const JsonApply(this.docId, this.edit);

  /// The document to change.
  final String docId;

  /// The structural change to apply.
  final JsonEdit edit;

  @override
  Future<int> execute(WorkerContext ctx) async {
    final docs = _JsonDocs.of(ctx);
    final count = docs.get(docId).apply(edit);
    docs.recharge(docId);
    return count;
  }
}

/// The document as UTF-8 JSON (see [JsonDocument.encode]). A compact
/// encoding of a document no edit has changed is the original body, byte
/// for byte. Throws a [StateError] when the body did not parse.
class JsonEncode extends WorkerCommand<Uint8List> {
  /// Creates a command that encodes document [docId], indented when
  /// [pretty] is true.
  const JsonEncode(this.docId, {this.pretty = false});

  /// The document to encode.
  final String docId;

  /// Whether to indent the output; false gives compact JSON.
  final bool pretty;

  @override
  Future<Uint8List> execute(WorkerContext ctx) async {
    final docs = _JsonDocs.of(ctx);
    final doc = docs.get(docId);
    final original = docs.bytes(docId);
    if (!pretty && !doc.dirty && original != null) {
      return Uint8List.fromList(original);
    }
    return doc.encode(pretty: pretty);
  }
}

/// Ids of up to [limit] nodes matching [query]; see [JsonDocument.search].
class JsonSearch extends WorkerCommand<List<int>> {
  /// Creates a command that searches document [docId] for [query].
  const JsonSearch(this.docId, this.query, {this.limit = 500});

  /// The document to search.
  final String docId;

  /// The text to look for; see [JsonDocument.search] for what matches.
  final String query;

  /// The most node ids to return.
  final int limit;

  @override
  Future<List<int>> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).get(docId).search(query, limit: limit);
}

/// Expands the ancestors of [nodeId]; returns its visible row index. See
/// [JsonDocument.reveal].
class JsonReveal extends WorkerCommand<int> {
  /// Creates a command that makes node [nodeId] visible.
  const JsonReveal(this.docId, this.nodeId);

  /// The document holding the node.
  final String docId;

  /// The node to scroll to once its ancestors are open.
  final int nodeId;

  @override
  Future<int> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).get(docId).reveal(nodeId);
}

/// The number of rows document [docId] shows now, e.g. after [JsonReveal]
/// expanded some.
class JsonVisibleCount extends WorkerCommand<int> {
  /// Creates a command that counts the visible rows of [docId].
  const JsonVisibleCount(this.docId);

  /// The document to count.
  final String docId;

  @override
  Future<int> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).get(docId).visibleCount;
}

/// The whole value of scalar [nodeId]; see [JsonDocument.scalarText].
class JsonScalarText extends WorkerCommand<String> {
  /// Creates a command that reads scalar [nodeId] of document [docId].
  const JsonScalarText(this.docId, this.nodeId);

  /// The document holding the node.
  final String docId;

  /// The scalar node to read.
  final int nodeId;

  @override
  Future<String> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).get(docId).scalarText(nodeId);
}

/// The top-level value of document [docId] as a row (depth 0, no key or
/// index), so a view can show a header for a root object or array; see
/// [JsonDocument.rootRow].
class JsonRootRow extends WorkerCommand<JsonRow?> {
  /// Creates a command that reads the root of document [docId].
  const JsonRootRow(this.docId);

  /// The document to read.
  final String docId;

  @override
  Future<JsonRow?> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).get(docId).rootRow();
}

/// Releases a document; unknown ids are ignored.
class CloseJson extends WorkerCommand<void> {
  /// Creates a command that closes document [docId].
  const CloseJson(this.docId);

  /// The document to release.
  final String docId;

  @override
  Future<void> execute(WorkerContext ctx) async =>
      _JsonDocs.of(ctx).remove(docId);
}

class _Entry {
  _Entry(this.source, this.bytes, this.nodes);

  /// `callId \0 side \0 scope`.
  final String source;

  /// The body; null when it did not parse, as nothing needs it then.
  final Uint8List? bytes;

  /// Nodes charged to the budget for this document.
  int nodes;
}

/// Open documents, stored in [WorkerContext.resources] as `json:<docId>`,
/// plus their use order and origin.
class _JsonDocs {
  _JsonDocs(this._resources);

  factory _JsonDocs.of(WorkerContext ctx) =>
      ctx.resources.putIfAbsent(_registryKey, () => _JsonDocs(ctx.resources))
          as _JsonDocs;

  static const _registryKey = 'json:#registry';

  final Map<String, Object> _resources;

  /// Open doc ids, least recently used first.
  final Map<String, _Entry> _open = {};

  /// Doc id per `callId \0 side \0 scope`.
  final Map<String, String> _bySource = {};
  int _nextId = 0;
  int _nodes = 0;

  JsonDocument _doc(String docId) => _resources['json:$docId']! as JsonDocument;

  /// The open document for [source] if its bytes are still [bytes]; a
  /// stale one, or one that did not parse, is closed.
  (String, JsonDocument)? reuse(String source, Uint8List bytes) {
    final docId = _bySource[source];
    if (docId == null) return null;
    final open = _open[docId]!.bytes;
    if (open == null || !_sameBytes(open, bytes)) {
      remove(docId);
      return null;
    }
    return (docId, get(docId));
  }

  (String, JsonDocument) add(String source, Uint8List bytes, JsonDocument doc) {
    final nodes = doc.storedCapacity;
    doc.maxCapacity = maxOpenJsonNodes;
    while (_open.isNotEmpty &&
        (_open.length >= maxOpenJsonDocs ||
            _nodes + nodes > maxOpenJsonNodes)) {
      remove(_open.keys.first);
    }
    final id = '${_nextId++}';
    _resources['json:$id'] = doc;
    _open[id] = _Entry(source, doc.parseError == null ? bytes : null, nodes);
    _bySource[source] = id;
    _nodes += nodes;
    return (id, doc);
  }

  /// The body [docId] was opened from; null when it did not parse.
  Uint8List? bytes(String docId) => _open[docId]?.bytes;

  /// Charges the open document [docId] for nodes added since it was opened,
  /// evicting other documents (least recently used first) to stay within
  /// [maxOpenJsonNodes].
  void recharge(String docId) {
    final entry = _open[docId]!;
    final nodes = _doc(docId).storedCapacity;
    _nodes += nodes - entry.nodes;
    entry.nodes = nodes;
    while (_nodes > maxOpenJsonNodes && _open.keys.first != docId) {
      remove(_open.keys.first);
    }
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
    _nodes -= entry.nodes;
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
