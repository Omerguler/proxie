import 'package:flutter/material.dart';

import 'package:proxie/src/config.dart' show defaultRawEditableLimit;
import 'package:proxie/src/json/json_commands.dart' show JsonBodySide;
import 'package:proxie/src/model/request.dart';
import 'package:proxie/src/ui/rules/response_editor.dart';
import 'package:proxie/src/worker/worker.dart';

/// One editable query parameter. Its text is decoded; an untouched part
/// keeps its original encoding when the URL is built again.
class QueryRow {
  QueryRow._(this._rawName, this._rawValue)
    : name = TextEditingController(text: _decode(_rawName)),
      value = TextEditingController(text: _decode(_rawValue ?? ''));

  /// An empty, new parameter.
  QueryRow.empty() : this._('', '');

  /// The parameter name, decoded.
  final TextEditingController name;

  /// The parameter value, decoded.
  final TextEditingController value;

  // As they were in the URL; a null value is a parameter without `=`.
  final String _rawName;
  final String? _rawValue;

  // A `%` not followed by two hex digits would make decoding throw.
  static final RegExp _badEscape = RegExp('%(?![0-9a-fA-F]{2})');

  // Malformed escapes are shown as they are.
  static String _decode(String s) =>
      _badEscape.hasMatch(s) ? s : Uri.decodeQueryComponent(s);

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

/// The request a [RequestForm] edits: method, URL, query parameters,
/// headers and body. The URL field holds the URL without its query, which
/// is edited as [query] rows; an untouched request builds back to the
/// same URL, byte for byte.
class RequestDraft extends MessageDraft {
  /// Creates a draft whose JSON body opens in [scope] of [worker].
  RequestDraft(super.worker, {super.scope}) : super(side: JsonBodySide.request);

  /// The method, as typed.
  final TextEditingController method = TextEditingController();

  /// The URL without its query.
  final TextEditingController url = TextEditingController();

  final List<QueryRow> _query = [];

  /// The query parameters, in order.
  List<QueryRow> get query => List.unmodifiable(_query);

  /// Starts over from [request] of call [callId], live: a JSON body opens
  /// as a tree of its bytes.
  void load(ProxieRequest request, {required String callId}) {
    method.text = request.method;
    final u = request.url;
    final s = u.toString();
    final fragment = u.hasFragment ? '#${u.fragment}' : '';
    var prefix = s.substring(0, s.length - fragment.length);
    if (u.hasQuery) {
      prefix = prefix.substring(0, prefix.length - u.query.length - 1);
    }
    url.text = '$prefix$fragment';
    for (final q in _query) {
      q._dispose();
    }
    _query
      ..clear()
      ..addAll([
        if (u.query.isNotEmpty)
          for (final part in u.query.split('&'))
            if (part.contains('='))
              QueryRow._(
                part.substring(0, part.indexOf('=')),
                part.substring(part.indexOf('=') + 1),
              )
            else
              QueryRow._(part, null),
      ]);
    loadMessage(request.headers, request.body, callId: callId, live: true);
  }

  /// Adds an empty query parameter.
  void addQuery() {
    _query.add(QueryRow.empty());
    notifyListeners();
  }

  /// Removes query parameter [row].
  void removeQuery(QueryRow row) {
    if (!_query.remove(row)) return;
    // The row's fields are still in this frame's tree.
    WidgetsBinding.instance.addPostFrameCallback((_) => row._dispose());
    notifyListeners();
  }

  /// The URL as edited, or null when it is not an absolute URL.
  Uri? get builtUrl {
    final text = url.text.trim();
    final hash = text.indexOf('#');
    final path = hash < 0 ? text : text.substring(0, hash);
    final fragment = hash < 0 ? '' : text.substring(hash);
    final parts = [
      for (final q in _query)
        if (q.name.text.isNotEmpty || q.value.text.isNotEmpty) q._encoded,
    ];
    final query = parts.join('&');
    final sep = path.contains('?') ? (query.isEmpty ? '' : '&') : '?';
    final uri = Uri.tryParse(
      '$path${query.isEmpty ? '' : '$sep$query'}$fragment',
    );
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    return uri;
  }

  /// Why the request cannot be sent yet, or null.
  String? validate() {
    if (method.text.trim().isEmpty) return 'Enter a method';
    if (builtUrl == null) return 'Enter an absolute URL';
    return validateBody();
  }

  /// The request as edited; check [validate] first. Throws when the edited
  /// tree cannot be encoded.
  Future<ProxieRequest> build() async => ProxieRequest(
    method: method.text.trim().toUpperCase(),
    url: builtUrl!,
    headers: buildHeaders(),
    body: await buildBody(),
  );

  @override
  void dispose() {
    method.dispose();
    url.dispose();
    for (final q in _query) {
      q._dispose();
    }
    super.dispose();
  }
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
            children: [
              SizedBox(
                width: 96,
                child: TextField(
                  key: const ValueKey('request-method'),
                  controller: draft.method,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Method'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const ValueKey('request-url'),
                  controller: draft.url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(labelText: 'URL'),
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
