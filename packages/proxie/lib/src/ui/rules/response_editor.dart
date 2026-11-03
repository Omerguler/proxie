import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:proxie/src/config.dart' show defaultRawEditableLimit;
import 'package:proxie/src/core/body_classifier.dart';
import 'package:proxie/src/core/masking.dart' show kMask;
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/model/response.dart';
import 'package:proxie/src/ui/common.dart';
import 'package:proxie/src/ui/json/json_tree_controller.dart';
import 'package:proxie/src/ui/json/json_tree_view.dart';
import 'package:proxie/src/ui/json/raw_text_view.dart';
import 'package:proxie/src/worker/worker.dart';

/// The scope (see `OpenJson.scope`) rule editors open captured bodies in,
/// so their edits never reach the read-only detail.
const String ruleEditorScope = 'rule-editor';

/// Headers that describe how a response travelled, not its body; a
/// captured body is stored decoded and whole, so they would be wrong on a
/// mock.
const Set<String> transportHeaders = {
  'content-encoding',
  'content-length',
  'transfer-encoding',
};

/// How many values [bytes] (or [text]) hold that masking replaced: JSON
/// strings equal to the mask, `"******"` in a [latin1] body. Runs in the
/// worker, so a large body is never scanned on the UI isolate.
class CountMasked extends WorkerCommand<int> {
  /// Counts in the body [bytes].
  const CountMasked(Uint8List this.bytes, {this.latin1 = false}) : text = null;

  /// Counts in an edited body's [text].
  const CountMasked.text(String this.text, {this.latin1 = false})
    : bytes = null;

  /// The body as stored, or null when [text] is given.
  final Uint8List? bytes;

  /// The body as edited, or null when [bytes] are given.
  final String? text;

  /// Whether the body is ISO-8859-1, masked as `******`.
  final bool latin1;

  @override
  Future<int> execute(WorkerContext ctx) async {
    final t = text;
    if (t != null) {
      final pattern = latin1 ? '"******"' : '"$kMask"';
      return pattern.allMatches(t).length;
    }
    return _count(bytes!, latin1 ? _maskedLatin1 : _maskedUtf8);
  }
}

/// How often [pattern] occurs in [bytes].
int _count(Uint8List bytes, List<int> pattern) {
  var n = 0;
  final last = bytes.length - pattern.length;
  outer:
  for (var i = 0; i <= last; i++) {
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) continue outer;
    }
    n++;
    i += pattern.length - 1;
  }
  return n;
}

final List<int> _maskedUtf8 = utf8.encode('"$kMask"');
final List<int> _maskedLatin1 = latin1.encode('"******"');

/// One editable header line.
class HeaderRow {
  /// Creates a row holding [name] and [value].
  HeaderRow(String name, String value)
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value);

  /// The header name.
  final TextEditingController name;

  /// The header value.
  final TextEditingController value;

  void _dispose() {
    name.dispose();
    value.dispose();
  }
}

/// The response a [ResponseEditor] edits: status, headers and body.
///
/// A body captured from call [load]'s `callId` that is JSON opens as an
/// editable tree in [ruleEditorScope]; any other body, or the tree's after
/// a switch, is edited as raw text. [build] gives the response as edited;
/// an untouched body comes back byte for byte.
class ResponseDraft extends ChangeNotifier {
  /// Creates an empty 200 response; [worker] holds the body's JSON
  /// document.
  ResponseDraft(this.worker);

  /// Opens JSON documents and splits text.
  final ProxieWorker worker;

  /// The status code, as typed.
  final TextEditingController status = TextEditingController(text: '200');

  final List<HeaderRow> _headers = [];
  int? _loadedStatus;
  String? _reason;
  Uint8List _bytes = Uint8List(0);
  String? _contentType;
  bool _json = false;
  bool _truncated = false;
  int _maskedHeaders = 0;
  int _maskedBody = 0;
  int _countGeneration = 0;
  Timer? _recount;
  int _keptBytes = 0;
  int _totalBytes = 0;
  String? _rawText;
  JsonTreeController? _tree;
  bool _showRaw = true;
  int _generation = 0;
  bool _disposed = false;

  /// The header lines, in order.
  List<HeaderRow> get headers => List.unmodifiable(_headers);

  /// The body the raw view starts from.
  Uint8List get bytes => _bytes;

  /// Whether the body parses as JSON (and is indented in the raw view).
  bool get isJson => _json;

  /// Whether the body is the captured part of a body cut at capture, not
  /// yet edited or replaced; [validate] refuses it.
  bool get truncated => _truncated;

  /// Values the stored copy had masked (P19): header values and JSON
  /// strings equal to the mask, which a mock would send as they are.
  /// Header values still equal to the mask count live; the body is
  /// counted again in the worker shortly after it is edited.
  int get maskedCount => _maskedHeaders + _maskedBody;

  /// Bytes kept of a [truncated] body.
  int get keptBytes => _keptBytes;

  /// Length of the whole [truncated] body as it was received.
  int get totalBytes => _totalBytes;

  /// The JSON tree of the captured body, or null when it is edited as text
  /// only.
  JsonTreeController? get tree => _tree;

  /// Whether the raw text view is shown rather than the tree.
  bool get showsRaw => _showRaw || _tree == null;

  /// Whether the raw text was edited; the tree can no longer be shown.
  bool get rawEdited => _rawText != null;

  /// Changes whenever the body is replaced, so the raw view starts again.
  int get generation => _generation;

  /// The content type a saved body is classified with.
  String? get contentType {
    for (final h in _headers) {
      if (h.name.text.trim().toLowerCase() == 'content-type') {
        return h.value.text.trim();
      }
    }
    return _contentType;
  }

  /// Starts over from [response]. With [callId], a JSON body opens as a
  /// tree of that call's stored response. A [captured] response loses its
  /// [transportHeaders]; its masked values are counted in [maskedCount].
  void load(ProxieResponse response, {String? callId, bool captured = false}) {
    status.text = '${response.statusCode}';
    _loadedStatus = response.statusCode;
    _reason = response.reasonPhrase;
    for (final h in _headers) {
      h._dispose();
    }
    _headers
      ..clear()
      ..addAll([
        for (final e in response.headers.entries)
          if (!captured || !transportHeaders.contains(e.key))
            for (final v in e.value) HeaderRow(e.key, v),
      ]);
    final body = response.body;
    for (final h in _headers) {
      h.value.addListener(_headersChanged);
    }
    _maskedHeaders = _countMaskedHeaders();
    _maskedBody = 0;
    _recount?.cancel();
    unawaited(
      _countBody(
        CountMasked(body.bytes, latin1: isLatin1Text(body.contentType)),
      ),
    );
    _bytes = body.bytes;
    _contentType = body.contentType;
    _json = body.kind == BodyKind.json;
    _truncated = body.truncated;
    _keptBytes = body.bytes.length;
    _totalBytes = body.originalLength;
    _rawText = null;
    _tree?.dispose();
    _tree = null;
    if (callId != null && _json && !body.truncated) {
      final tree = JsonTreeController(
        worker,
        callId,
        'response',
        editable: true,
        scope: ruleEditorScope,
      );
      _tree = tree;
      tree.addListener(_treeChanged);
      // A document left edited by an editor that closed without saving is
      // still open in this scope; start from the captured body.
      void fresh() {
        if (tree.status == JsonTreeStatus.loading) return;
        tree.removeListener(fresh);
        if (tree.edited) unawaited(tree.revert());
      }

      tree.addListener(fresh);
    }
    _showRaw = _tree == null;
    _generation++;
    _notify();
  }

  int _countMaskedHeaders() =>
      _headers.where((h) => h.value.text == kMask).length;

  void _headersChanged() {
    final n = _countMaskedHeaders();
    if (n == _maskedHeaders) return;
    _maskedHeaders = n;
    _notify();
  }

  // The tree notifies for every fetch too; only edits are counted again.
  void _treeChanged() {
    if (_tree?.edited ?? false) _scheduleRecount();
  }

  void _scheduleRecount() {
    _recount?.cancel();
    _recount = Timer(const Duration(milliseconds: 300), () {
      final raw = _rawText;
      final latin = isLatin1Text(contentType);
      if (raw != null) {
        unawaited(_countBody(CountMasked.text(raw, latin1: latin)));
        return;
      }
      final tree = _tree;
      if (tree == null || !tree.edited) return;
      final generation = _countGeneration;
      unawaited(() async {
        try {
          final bytes = await tree.encode();
          if (generation != _countGeneration) return;
          await _countBody(CountMasked(bytes, latin1: latin));
        } on Object catch (e, st) {
          developer.log(
            'Proxie could not encode the body to look for masked values',
            name: 'proxie',
            error: e,
            stackTrace: st,
          );
        }
      }());
    });
  }

  // The latest count wins; a failed count keeps the last one shown.
  Future<void> _countBody(CountMasked command) async {
    final generation = ++_countGeneration;
    try {
      final n = await worker.run(command);
      if (_disposed || generation != _countGeneration) return;
      if (n == _maskedBody) return;
      _maskedBody = n;
      _notify();
    } on Object catch (e, st) {
      developer.log(
        'Proxie could not look for masked values',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Adds an empty header line.
  void addHeader() {
    _headers.add(HeaderRow('', '')..value.addListener(_headersChanged));
    _notify();
  }

  /// Removes header line [row].
  void removeHeader(HeaderRow row) {
    if (!_headers.remove(row)) return;
    row.value.removeListener(_headersChanged);
    _maskedHeaders = _countMaskedHeaders();
    // The row's fields are still in this frame's tree.
    WidgetsBinding.instance.addPostFrameCallback((_) => row._dispose());
    _notify();
  }

  /// Shows the raw text, with the tree's edits when there are any.
  Future<void> showRaw() async {
    final tree = _tree;
    if (tree != null && tree.edited && tree.status == JsonTreeStatus.ready) {
      try {
        _bytes = await tree.encode(pretty: true);
      } on Object catch (e, st) {
        // The tree stays shown; its edits are still saved from it.
        developer.log(
          'Proxie could not encode the edited body',
          name: 'proxie',
          error: e,
          stackTrace: st,
        );
        return;
      }
      if (_disposed) return;
    }
    _showRaw = true;
    _notify();
  }

  /// Shows the tree again, unless the raw text was edited.
  void showTree() {
    if (_tree == null || _rawText != null) return;
    _showRaw = false;
    _notify();
  }

  /// Takes the raw view's whole [text] as the body.
  void rawChanged(String text) {
    final first = _rawText == null || _truncated;
    _rawText = text;
    _truncated = false;
    _scheduleRecount();
    if (first) _notify();
  }

  /// Why the response cannot be saved yet, or null.
  String? validate() {
    final code = int.tryParse(status.text.trim());
    if (code == null || code < 100 || code > 599) {
      return 'Status must be a number from 100 to 599';
    }
    if (_truncated) {
      return 'The captured body was truncated; edit or replace it first';
    }
    return null;
  }

  /// The response as edited; check [validate] first. Throws when the
  /// edited tree cannot be encoded.
  Future<ProxieResponse> build() async {
    final code = int.parse(status.text.trim());
    final headers = <String, List<String>>{};
    for (final h in _headers) {
      final name = h.name.text.trim();
      if (name.isEmpty) continue;
      (headers[name.toLowerCase()] ??= []).add(h.value.text);
    }
    final type = contentType;
    final raw = _rawText;
    final tree = _tree;
    final Uint8List bytes;
    if (raw != null) {
      bytes = isLatin1Text(type) && raw.codeUnits.every((u) => u <= 0xFF)
          ? Uint8List.fromList(latin1.encode(raw))
          : Uint8List.fromList(utf8.encode(raw));
    } else if (tree != null && tree.edited) {
      bytes = await tree.encode();
    } else {
      bytes = _bytes;
    }
    return ProxieResponse(
      statusCode: code,
      reasonPhrase: code == _loadedStatus ? _reason : null,
      headers: headers,
      body: bytes.isEmpty
          ? ProxieBody.empty()
          : ProxieBody.from(bytes, type, cap: bytes.length),
    );
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _recount?.cancel();
    status.dispose();
    for (final h in _headers) {
      h._dispose();
    }
    _tree?.dispose();
    super.dispose();
  }
}

/// Edits [draft]'s status, headers (add, edit, delete) and body, as a JSON
/// tree or raw text.
class ResponseEditor extends StatelessWidget {
  /// Creates the editor of [draft].
  const ResponseEditor({
    required this.draft,
    required this.worker,
    super.key,
    this.rawEditableLimit = defaultRawEditableLimit,
    this.onPresets,
    this.onSaveAsPreset,
  });

  /// The response edited.
  final ResponseDraft draft;

  /// Splits the body into lines.
  final ProxieWorker worker;

  /// Bodies of at least this many bytes open read-only until "Edit
  /// anyway".
  final int rawEditableLimit;

  /// Opens the preset picker; hidden when null.
  final VoidCallback? onPresets;

  /// Saves the response as a custom preset; hidden when null.
  final VoidCallback? onSaveAsPreset;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: draft,
    builder: (context, _) {
      final theme = Theme.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 96,
                  child: TextField(
                    key: const ValueKey('response-status'),
                    controller: draft.status,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(labelText: 'Status'),
                  ),
                ),
                if (onPresets != null)
                  TextButton.icon(
                    onPressed: onPresets,
                    icon: const Icon(Icons.library_books_outlined),
                    label: const Text('Presets'),
                  ),
                if (onSaveAsPreset != null)
                  TextButton.icon(
                    onPressed: onSaveAsPreset,
                    icon: const Icon(Icons.bookmark_add_outlined),
                    label: const Text('Save as preset'),
                  ),
              ],
            ),
          ),
          if (draft.truncated)
            ColoredBox(
              color: theme.colorScheme.tertiaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  'The captured body was truncated '
                  '(${formatBytes(draft.keptBytes)} of '
                  '${formatBytes(draft.totalBytes)}). Edit or replace it '
                  'before saving.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
            ),
          if (draft.maskedCount > 0)
            ColoredBox(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Text(
                  draft.maskedCount == 1
                      ? '1 value was masked at capture and will be sent as '
                            '$kMask. Replace it before saving.'
                      : '${draft.maskedCount} values were masked at capture '
                            'and will be sent as $kMask. Replace them before '
                            'saving.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            ),
          _Headers(
            key: ValueKey(draft.generation),
            draft: draft,
            expanded: draft.headers.any((h) => h.value.text == kMask),
          ),
          const Divider(height: 1),
          Expanded(child: _body(context)),
        ],
      );
    },
  );

  Widget _body(BuildContext context) {
    final tree = draft.tree;
    if (tree != null && !draft.showsRaw) {
      return ListenableBuilder(
        listenable: tree,
        builder: (context, _) {
          // A body declared JSON that does not parse is edited as text.
          if (tree.status == JsonTreeStatus.invalid) return _raw(context);
          return JsonTreeView(
            controller: tree,
            actions: [
              IconButton(
                tooltip: 'Raw text',
                icon: const Icon(Icons.notes),
                onPressed: () => unawaited(draft.showRaw()),
              ),
            ],
          );
        },
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (tree != null &&
            !draft.rawEdited &&
            tree.status != JsonTreeStatus.invalid)
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              tooltip: 'Tree view',
              icon: const Icon(Icons.account_tree_outlined),
              onPressed: draft.showTree,
            ),
          ),
        Expanded(child: _raw(context)),
      ],
    );
  }

  Widget _raw(BuildContext context) => RawTextView(
    key: ValueKey(draft.generation),
    worker: worker,
    bytes: draft.bytes,
    prettyJson: draft.isJson,
    latin1: isLatin1Text(draft.contentType),
    editable: true,
    rawEditableLimit: rawEditableLimit,
    onChanged: draft.rawChanged,
    undecodable: (_) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          'Binary body (${formatBytes(draft.bytes.length)}), kept as '
          'captured. Pick a preset to replace it.',
          textAlign: TextAlign.center,
        ),
      ),
    ),
  );
}

class _Headers extends StatelessWidget {
  const _Headers({required this.draft, required this.expanded, super.key});

  final ResponseDraft draft;

  /// Whether the tile starts open, as when a value is masked.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final rows = draft.headers;
    return ExpansionTile(
      title: Text('Headers (${rows.length})'),
      dense: true,
      initiallyExpanded: expanded,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
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
                        key: ValueKey('header-name-$i'),
                        controller: rows[i].name,
                        decoration: const InputDecoration(hintText: 'Name'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: rows[i].value,
                        builder: (context, value, _) {
                          final masked = value.text == kMask;
                          final error = Theme.of(context).colorScheme.error;
                          return TextField(
                            key: ValueKey('header-value-$i'),
                            controller: rows[i].value,
                            style: masked ? TextStyle(color: error) : null,
                            decoration: InputDecoration(
                              hintText: 'Value',
                              prefixIcon: masked
                                  ? Tooltip(
                                      message: 'Masked at capture',
                                      child: Icon(
                                        Icons.warning_amber,
                                        color: error,
                                      ),
                                    )
                                  : null,
                            ),
                          );
                        },
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove header',
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: () => draft.removeHeader(rows[i]),
                    ),
                  ],
                ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: draft.addHeader,
            icon: const Icon(Icons.add),
            label: const Text('Add header'),
          ),
        ),
      ],
    );
  }
}
