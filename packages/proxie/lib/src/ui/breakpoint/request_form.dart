import 'package:flutter/material.dart';

import 'package:proxie/src/config.dart' show defaultRawEditableLimit;
import 'package:proxie/src/core/http_rules.dart';
import 'package:proxie/src/json/json_commands.dart' show JsonBodySide;
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/ui/rules/message_draft.dart';
import 'package:proxie/src/worker/worker.dart';

/// One query parameter of a [RequestDraft]'s URL, shown decoded. An
/// untouched part keeps its original encoding when the query is written
/// back.
class QueryRow {
  QueryRow._(this._rawName, this._rawValue)
    : name = TextEditingController(text: _decode(_rawName)),
      value = TextEditingController(text: _decode(_rawValue ?? ''));

  /// The parameter name, decoded.
  final TextEditingController name;

  /// The parameter value, decoded.
  final TextEditingController value;

  // As they were in the URL; a null value is a parameter without `=`.
  final String _rawName;
  final String? _rawValue;

  // A `%` not followed by two hex digits would make decoding throw.
  static final RegExp _badEscape = RegExp('%(?![0-9a-fA-F]{2})');

  /// [s] decoded; kept as it is when it holds a malformed escape or bytes
  /// that are not UTF-8 (such as a Latin-1 `%E9`), never thrown.
  static String _decode(String s) {
    if (_badEscape.hasMatch(s)) return s;
    try {
      return Uri.decodeQueryComponent(s);
    } on FormatException {
      return s;
    }
  }

  bool get _isEmpty => name.text.isEmpty && value.text.isEmpty;

  late String _seenName = name.text;
  late String _seenValue = value.text;
  VoidCallback _onText = _noop;

  static void _noop() {}

  // Whether the text changed since last asked.
  bool _textChanged() {
    if (name.text == _seenName && value.text == _seenValue) return false;
    _seenName = name.text;
    _seenValue = value.text;
    return true;
  }

  String get _encoded {
    final n = name.text == _decode(_rawName)
        ? _rawName
        : Uri.encodeQueryComponent(name.text);
    final raw = _rawValue;
    if (raw == null && value.text.isEmpty) return n;
    final v = raw != null && value.text == _decode(raw)
        ? raw
        : Uri.encodeQueryComponent(value.text);
    return '$n=$v';
  }

  void _dispose() {
    name.dispose();
    value.dispose();
  }
}

/// The request a [RequestForm] edits: method, URL, headers and body.
///
/// The URL field is the source of truth: the [query] rows are parsed from
/// it (leniently, see [QueryRow]) whenever it is edited, and editing a row
/// rewrites only the query part of the field. An untouched request builds
/// back to the very URL it was loaded with.
class RequestDraft extends MessageDraft {
  /// Creates a draft whose JSON body opens in [scope] of [worker].
  RequestDraft(super.worker, {required super.scope})
    : super(side: JsonBodySide.request) {
    method.addListener(_clearMethodError);
    url.addListener(_urlChanged);
  }

  /// The method, as typed.
  final TextEditingController method = TextEditingController();

  /// The whole URL, query included.
  final TextEditingController url = TextEditingController();

  final List<QueryRow> _query = [];
  bool _writing = false;
  String? _methodError;
  String? _urlError;
  bool _closed = false;

  /// The query parameters, in order.
  List<QueryRow> get query => List.unmodifiable(_query);

  /// Why the method was refused by the last [validate], or null.
  String? get methodError => _methodError;

  /// Why the URL was refused by the last [validate], or null.
  String? get urlError => _urlError;

  /// Starts over from [request] of call [callId], live: a JSON body opens
  /// as a tree of its bytes.
  void load(ProxieRequest request, {required String callId}) {
    method.text = request.method;
    url.text = request.url.toString();
    _methodError = null;
    _urlError = null;
    loadMessage(request.headers, request.body, callId: callId, live: true);
  }

  /// The query part of [text]: from the first `?` to the first `#` (a
  /// `?` inside the fragment belongs to it); null when there is none.
  static (int, int)? _querySpan(String text) {
    final hash = text.indexOf('#');
    final end = hash < 0 ? text.length : hash;
    final q = text.substring(0, end).indexOf('?');
    if (q < 0) return null;
    return (q + 1, end);
  }

  void _urlChanged() {
    if (_urlError != null) {
      _urlError = null;
      _notifyIfOpen();
    }
    if (_writing) return;
    final text = url.text;
    final span = _querySpan(text);
    final query = span == null ? '' : text.substring(span.$1, span.$2);
    final parsed = [
      for (final part in query.split('&'))
        if (part.isNotEmpty) _split(part),
    ];
    final current = [
      for (final q in _query)
        if (!q._isEmpty) q._encoded,
    ];
    final next = [for (final (n, v) in parsed) _join(n, v)];
    if (_sameList(current, next)) return;
    _replaceRows([for (final (n, v) in parsed) QueryRow._(n, v)]);
  }

  // A query part as (name, value); value null when there is no `=`.
  static (String, String?) _split(String part) {
    final eq = part.indexOf('=');
    return eq < 0
        ? (part, null)
        : (part.substring(0, eq), part.substring(eq + 1));
  }

  static String _join(String name, String? value) =>
      value == null ? name : '$name=$value';

  void _replaceRows(List<QueryRow> rows) {
    final old = [..._query];
    _query
      ..clear()
      ..addAll(rows);
    rows.forEach(_listenRow);
    // Their fields are still in this frame's tree.
    if (old.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final row in old) {
          row._dispose();
        }
      });
    }
    _notifyIfOpen();
  }

  // Controllers also notify on focus and selection changes; only a text
  // change rewrites the URL, so an untouched one is sent verbatim.
  void _listenRow(QueryRow row) {
    row._onText = () {
      if (row._textChanged()) _writeQuery();
    };
    row.name.addListener(row._onText);
    row.value.addListener(row._onText);
  }

  // Rewrites only the query part of the URL field from the rows.
  void _writeQuery() {
    final query = [
      for (final q in _query)
        if (!q._isEmpty) q._encoded,
    ].join('&');
    final text = url.text;
    final span = _querySpan(text);
    final String next;
    if (span == null) {
      if (query.isEmpty) return;
      final hash = text.indexOf('#');
      next = hash < 0
          ? '$text?$query'
          : '${text.substring(0, hash)}?$query${text.substring(hash)}';
    } else {
      final (start, end) = span;
      if (text.substring(start, end) == query) return;
      next = query.isEmpty
          ? text.substring(0, start - 1) + text.substring(end)
          : text.substring(0, start) + query + text.substring(end);
    }
    _writing = true;
    try {
      url.text = next;
    } finally {
      _writing = false;
    }
  }

  /// Adds an empty query parameter.
  void addQuery() {
    final row = QueryRow._('', '');
    _query.add(row);
    _listenRow(row);
    _notifyIfOpen();
  }

  /// Removes query parameter [row].
  void removeQuery(QueryRow row) {
    if (!_query.remove(row)) return;
    row.name.removeListener(row._onText);
    row.value.removeListener(row._onText);
    _writeQuery();
    // The row's fields are still in this frame's tree.
    WidgetsBinding.instance.addPostFrameCallback((_) => row._dispose());
    _notifyIfOpen();
  }

  void _clearMethodError() {
    if (_methodError == null) return;
    _methodError = null;
    _notifyIfOpen();
  }

  /// The URL as typed, or null when it is not an absolute http(s) URL.
  Uri? get builtUrl {
    final uri = Uri.tryParse(url.text.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  /// Why the request cannot be sent yet, or null; refused fields show
  /// [methodError], [urlError] and [HeaderRow.nameError] inline. The rules
  /// are the ones `dart:io` applies.
  String? validate() {
    final m = method.text.trim();
    _methodError = m.isEmpty || !isHttpToken(m)
        ? 'This is not a valid method'
        : null;
    _urlError = builtUrl == null
        ? 'Must be an absolute http or https URL'
        : null;
    final headers = validateHeaders(received: false);
    if (_methodError != null) return '"$m" is not a valid method';
    if (_urlError != null) {
      return 'The URL must be absolute and use http or https';
    }
    return headers ?? validateBody();
  }

  /// The request as edited; check [validate] first. Throws when the edited
  /// tree cannot be encoded.
  Future<ProxieRequest> build() async => ProxieRequest(
    method: method.text.trim().toUpperCase(),
    url: builtUrl!,
    headers: buildHeaders(),
    body: await buildBody(),
  );

  void _notifyIfOpen() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    method.dispose();
    url.dispose();
    for (final q in _query) {
      q._dispose();
    }
    super.dispose();
  }
}

bool _sameList(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Edits [draft]: method, URL, query parameters, headers and body.
class RequestForm extends StatelessWidget {
  /// Creates the form of [draft].
  const RequestForm({
    required this.draft,
    required this.worker,
    super.key,
    this.rawEditableLimit = defaultRawEditableLimit,
  });

  /// The request edited.
  final RequestDraft draft;

  /// Splits the body into lines.
  final ProxieWorker worker;

  /// Bodies of at least this many bytes open read-only until "Edit
  /// anyway".
  final int rawEditableLimit;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: draft,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 96,
                child: TextField(
                  key: const ValueKey('request-method'),
                  controller: draft.method,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'Method',
                    errorText: draft.methodError,
                    errorMaxLines: 3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey('request-url'),
                  controller: draft.url,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'URL',
                    errorText: draft.urlError,
                  ),
                ),
              ),
            ],
          ),
        ),
        MessageNotices(draft: draft, useVerb: 'sending'),
        _QueryTile(key: ValueKey(draft.generation), draft: draft),
        MessageHeaders(
          key: ValueKey(('headers', draft.generation)),
          draft: draft,
          expanded: false,
        ),
        const Divider(height: 1),
        Expanded(
          child: MessageBody(
            draft: draft,
            worker: worker,
            rawEditableLimit: rawEditableLimit,
          ),
        ),
      ],
    ),
  );
}

class _QueryTile extends StatelessWidget {
  const _QueryTile({required this.draft, super.key});

  final RequestDraft draft;

  @override
  Widget build(BuildContext context) {
    final rows = draft.query;
    return ExpansionTile(
      title: Text('Query parameters (${rows.length})'),
      dense: true,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (var i = 0; i < rows.length; i++)
                Row(
                  key: ObjectKey(rows[i]),
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('query-name-$i'),
                        controller: rows[i].name,
                        decoration: const InputDecoration(hintText: 'Name'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: TextField(
                        key: ValueKey('query-value-$i'),
                        controller: rows[i].value,
                        decoration: const InputDecoration(hintText: 'Value'),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove parameter',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => draft.removeQuery(rows[i]),
                    ),
                  ],
                ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: draft.addQuery,
            icon: const Icon(Icons.add),
            label: const Text('Add parameter'),
          ),
        ),
      ],
    );
  }
}
