import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:proxie/src/config.dart' show defaultRawEditableLimit;
import 'package:proxie/src/core/body_classifier.dart';
import 'package:proxie/src/core/http_rules.dart';
import 'package:proxie/src/core/masking.dart' show kMask;
import 'package:proxie/src/json/json_commands.dart' show JsonBodySide;
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/ui/common.dart';
import 'package:proxie/src/ui/json/json_tree_controller.dart';
import 'package:proxie/src/ui/json/json_tree_view.dart';
import 'package:proxie/src/ui/json/raw_text_view.dart';
import 'package:proxie/src/worker/worker.dart';

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

/// Whether header [value] holds the mask: masking replaced all or part of
/// it. The one test for counting, marking and refusing masked values.
bool isMaskedHeaderValue(String value) => value.contains(kMask);

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

  /// Why the name was refused by the last validation, or null.
  String? get nameError => _nameError;
  String? _nameError;

  /// Why the value was refused by the last validation, or null.
  String? get valueError => _valueError;
  String? _valueError;
  VoidCallback _onEdit = _noop;
  late String _seenName = name.text;
  late String _seenValue = value.text;

  static void _noop() {}

  // Whether the text changed since last asked; controllers also notify on
  // focus and selection changes.
  bool _textChanged() {
    if (name.text == _seenName && value.text == _seenValue) return false;
    _seenName = name.text;
    _seenValue = value.text;
    return true;
  }

  void _dispose() {
    name.dispose();
    value.dispose();
  }
}

/// The headers and body an editor changes: the part a request and a
/// response share.
///
/// A body loaded with a `callId` that is JSON opens as an editable tree of
/// that call's [side] body in [scope]: the stored body, or with `live` the
/// loaded bytes themselves. Any other body, or the tree's after a switch,
/// is edited as raw text. [buildBody] gives the body as edited; an
/// untouched body comes back byte for byte.
abstract class MessageDraft extends ChangeNotifier {
  /// Creates an empty draft whose JSON body is [side] of its call, opened
  /// in [scope] of [worker].
  MessageDraft(this.worker, {required this.side, required this.scope});

  /// Opens JSON documents and splits text.
  final ProxieWorker worker;

  /// Which body of the call a JSON tree opens.
  final JsonBodySide side;

  /// The scope (see `OpenJson.scope`) the JSON tree opens in.
  final String scope;

  final List<HeaderRow> _headers = [];
  Uint8List _bytes = Uint8List(0);
  String? _contentType;
  bool _json = false;
  bool _truncated = false;
  bool _live = false;
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
  int _seenTreeEdits = 0;
  final ValueNotifier<int> _edited = ValueNotifier(0);
  bool _disposed = false;

  /// The header lines, in order.
  List<HeaderRow> get headers => List.unmodifiable(_headers);

  /// The body the raw view starts from.
  Uint8List get bytes => _bytes;

  /// Whether the body parses as JSON (and is indented in the raw view).
  bool get isJson => _json;

  /// Whether the body is the captured part of a body cut at capture, not
  /// yet edited or replaced; [validateBody] refuses it.
  bool get truncated => _truncated;

  /// Increases whenever the user changes the message: its text, a header
  /// line, the body. Unlike this draft's own notifications, it does not
  /// fire for validation, recounts or fetches.
  ValueListenable<int> get edited => _edited;

  /// Tells [edited] the user changed the message.
  @protected
  void markEdited() {
    if (!_disposed) _edited.value++;
  }

  /// Values the stored copy had masked (P19): header values and JSON
  /// strings equal to the mask, which would be sent as they are. Header
  /// values still equal to the mask count live; the body is counted again
  /// in the worker shortly after it is edited. Always 0 for a live
  /// message, which was never masked.
  int get maskedCount => _maskedHeaders + _maskedBody;

  /// The part of [maskedCount] in header values.
  int get maskedHeaderCount => _maskedHeaders;

  /// The part of [maskedCount] in the body.
  int get maskedBodyCount => _maskedBody;

  /// Bytes kept of a [truncated] body.
  int get keptBytes => _keptBytes;

  /// Length of the whole [truncated] body as it was received.
  int get totalBytes => _totalBytes;

  /// The JSON tree of the body, or null when it is edited as text only.
  JsonTreeController? get tree => _tree;

  /// Whether the raw text view is shown rather than the tree.
  bool get showsRaw => _showRaw || _tree == null;

  /// Whether the raw text was edited; the tree can no longer be shown.
  bool get rawEdited => _rawText != null;

  /// Changes whenever the body is replaced, so the raw view starts again.
  int get generation => _generation;

  /// The content type a built body is classified with.
  String? get contentType {
    for (final h in _headers) {
      if (h.name.text.trim().toLowerCase() == 'content-type') {
        return h.value.text.trim();
      }
    }
    return _contentType;
  }

  /// Starts over from [headers] and [body]. With [callId], a JSON body
  /// opens as a tree: of that call's stored body, or with [live] of
  /// [body]'s bytes (a paused call, not stored yet and never masked). A
  /// [captured] message loses its [transportHeaders]; masked values of a
  /// message that is not [live] are counted in [maskedCount].
  @protected
  void loadMessage(
    Map<String, List<String>> headers,
    ProxieBody body, {
    String? callId,
    bool captured = false,
    bool live = false,
  }) {
    for (final h in _headers) {
      h._dispose();
    }
    _headers
      ..clear()
      ..addAll([
        for (final e in headers.entries)
          if (!captured || !transportHeaders.contains(e.key))
            for (final v in e.value) HeaderRow(e.key, v),
      ]);
    _headers.forEach(_listen);
    _live = live;
    _maskedHeaders = live ? 0 : _countMaskedHeaders();
    _maskedBody = 0;
    _recount?.cancel();
    _countGeneration++;
    if (!live) {
      unawaited(
        _countBody(
          CountMasked(body.bytes, latin1: isLatin1Text(body.contentType)),
        ),
      );
    }
    _bytes = body.bytes;
    _contentType = body.contentType;
    _json = body.kind == BodyKind.json;
    _truncated = body.truncated;
    _keptBytes = body.bytes.length;
    _totalBytes = body.originalLength;
    _rawText = null;
    final old = _tree;
    final opens = callId != null && _json && !body.truncated;
    if (opens &&
        old != null &&
        old.callId == callId &&
        !live &&
        old.bytes == null) {
      // The same stored body again (a preset of the captured response):
      // start it over in place. A new controller would race the old one's
      // close of this very document.
      unawaited(old.revert());
      _showRaw = false;
      _generation++;
      _notify();
      return;
    }
    old?.dispose();
    _tree = null;
    if (opens) {
      final tree = JsonTreeController(
        worker,
        callId,
        side.name,
        editable: true,
        scope: scope,
        closeOnDispose: true,
        bytes: live ? body.bytes : null,
      );
      _tree = tree;
      _seenTreeEdits = 0;
      tree.addListener(_treeChanged);
      // A document left edited by an editor that closed without sending
      // or saving is still open in this scope; start from the body loaded.
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

  void _listen(HeaderRow row) {
    // Read now: the first change must compare with the text loaded.
    row._textChanged();
    row._onEdit = () {
      _clearRowError(row);
      if (row._textChanged()) markEdited();
    };
    row.value.addListener(_headersChanged);
    row.name.addListener(row._onEdit);
    row.value.addListener(row._onEdit);
  }

  int _countMaskedHeaders() =>
      _headers.where((h) => isMaskedHeaderValue(h.value.text)).length;

  void _headersChanged() {
    if (_live) return;
    final n = _countMaskedHeaders();
    if (n == _maskedHeaders) return;
    _maskedHeaders = n;
    _notify();
  }

  // The tree notifies for every fetch too; only edits are counted again.
  void _treeChanged() {
    final tree = _tree;
    if (tree == null) return;
    if (tree.edited) _scheduleRecount();
    if (tree.editCount != _seenTreeEdits) {
      _seenTreeEdits = tree.editCount;
      markEdited();
    }
  }

  void _scheduleRecount() {
    if (_live) return;
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
    _headers.add(HeaderRow('', ''));
    _listen(_headers.last);
    markEdited();
    _notify();
  }

  /// Removes header line [row].
  void removeHeader(HeaderRow row) {
    if (!_headers.remove(row)) return;
    row.value.removeListener(_headersChanged);
    row.name.removeListener(row._onEdit);
    row.value.removeListener(row._onEdit);
    if (!_live) _maskedHeaders = _countMaskedHeaders();
    // The row's fields are still in this frame's tree.
    WidgetsBinding.instance.addPostFrameCallback((_) => row._dispose());
    markEdited();
    _notify();
  }

  /// Shows the raw text, with the tree's edits when there are any.
  Future<void> showRaw() async {
    final tree = _tree;
    if (tree != null && tree.edited && tree.status == JsonTreeStatus.ready) {
      try {
        _bytes = await tree.encode(pretty: true);
      } on Object catch (e, st) {
        // The tree stays shown; its edits are still taken from it.
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
    markEdited();
    _scheduleRecount();
    if (first) _notify();
  }

  /// Checks every header line with the rules `dart:io` applies: names
  /// must be tokens; values must be sendable, or for a [received] message
  /// (a response handed to the app) only free of CR, LF and NUL. Marks the
  /// refused lines (see [HeaderRow.nameError]) and returns why the first
  /// one was refused, or null.
  String? validateHeaders({required bool received}) {
    String? first;
    for (final h in _headers) {
      final name = h.name.text.trim();
      final value = h.value.text;
      h
        .._nameError = null
        .._valueError = null;
      if (name.isEmpty) continue;
      if (!isHttpToken(name)) {
        h._nameError = 'This is not a valid header name';
        first ??= '"$name" is not a valid header name';
      } else if ((received
              ? unreceivableHeaderChar(value)
              : unsendableHeaderChar(value)) >=
          0) {
        // The mask is not US-ASCII, so a masked value cannot go out as is.
        if (isMaskedHeaderValue(value)) {
          h._valueError = 'Masked at capture; retype the value';
          first ??= 'The value of "$name" was masked at capture; retype it';
        } else {
          h._valueError = 'Has a character that cannot be sent';
          first ??= 'The value of "$name" has a character that cannot be sent';
        }
      }
    }
    _notify();
    return first;
  }

  void _clearRowError(HeaderRow row) {
    if (row._nameError == null && row._valueError == null) return;
    row
      .._nameError = null
      .._valueError = null;
    _notify();
  }

  /// Why the body cannot be used yet, or null.
  String? validateBody() => _truncated
      ? 'The captured body was truncated; edit or replace it first'
      : null;

  /// The header lines as a map; names lowercased, empty names skipped.
  Map<String, List<String>> buildHeaders() {
    final headers = <String, List<String>>{};
    for (final h in _headers) {
      final name = h.name.text.trim();
      if (name.isEmpty) continue;
      (headers[name.toLowerCase()] ??= []).add(h.value.text);
    }
    return headers;
  }

  /// The body as edited; check [validateBody] first. Throws when the
  /// edited tree cannot be encoded.
  Future<ProxieBody> buildBody() async {
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
    return bytes.isEmpty
        ? ProxieBody.empty()
        : ProxieBody.from(bytes, type, cap: bytes.length);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _recount?.cancel();
    for (final h in _headers) {
      h._dispose();
    }
    _tree?.dispose();
    _edited.dispose();
    super.dispose();
  }
}

/// The notices above a [MessageDraft]: a truncated body, masked values.
/// Shows nothing when there is nothing to say.
class MessageNotices extends StatelessWidget {
  /// Creates the notices of [draft], asking to fix things before
  /// [useVerb] (e.g. "saving").
  const MessageNotices({
    required this.draft,
    super.key,
    this.useVerb = 'saving',
    this.refusesMaskedHeaders = false,
  });

  /// The draft described.
  final MessageDraft draft;

  /// What the notices ask to fix things before.
  final String useVerb;

  /// Whether a masked header value is refused rather than sent as it is:
  /// the mask is not a sendable request header value. A response handed
  /// to the app can hold it.
  final bool refusesMaskedHeaders;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget notice(Color background, Color foreground, String text) =>
        ColoredBox(
          color: background,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
        );
    final scheme = theme.colorScheme;
    final headers = draft.maskedHeaderCount;
    final sentAsMask = refusesMaskedHeaders
        ? draft.maskedBodyCount
        : draft.maskedCount;
    final what = refusesMaskedHeaders ? 'body value' : 'value';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (draft.truncated)
          notice(
            scheme.tertiaryContainer,
            scheme.onTertiaryContainer,
            'The captured body was truncated '
            '(${formatBytes(draft.keptBytes)} of '
            '${formatBytes(draft.totalBytes)}). Edit or replace it '
            'before $useVerb.',
          ),
        if (refusesMaskedHeaders && headers > 0)
          notice(
            scheme.errorContainer,
            scheme.onErrorContainer,
            headers == 1
                ? '1 header value was masked at capture and must be retyped '
                      'before $useVerb.'
                : '$headers header values were masked at capture and must '
                      'be retyped before $useVerb.',
          ),
        if (sentAsMask > 0)
          notice(
            scheme.errorContainer,
            scheme.onErrorContainer,
            sentAsMask == 1
                ? '1 $what was masked at capture and will be sent as '
                      '$kMask. Replace it before $useVerb.'
                : '$sentAsMask ${what}s were masked at capture '
                      'and will be sent as $kMask. Replace them before '
                      '$useVerb.',
          ),
      ],
    );
  }
}

/// [draft]'s body: its JSON tree, or its raw text, with a switch between
/// them while the raw text is untouched.
class MessageBody extends StatelessWidget {
  /// Creates the body editor of [draft].
  const MessageBody({
    required this.draft,
    required this.worker,
    super.key,
    this.rawEditableLimit = defaultRawEditableLimit,
    this.binaryHint,
  });

  /// The draft whose body is edited.
  final MessageDraft draft;

  /// Splits the body into lines.
  final ProxieWorker worker;

  /// Bodies of at least this many bytes open read-only until "Edit
  /// anyway".
  final int rawEditableLimit;

  /// Added to the notice for a body that is not text.
  final String? binaryHint;

  @override
  Widget build(BuildContext context) {
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

  Widget _raw(BuildContext context) {
    final hint = binaryHint;
    return RawTextView(
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
            'captured.${hint == null ? '' : ' $hint'}',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}

/// [draft]'s header lines in a tile: add, edit and remove them. Masked
/// values are marked.
class MessageHeaders extends StatelessWidget {
  /// Creates the header editor of [draft]; [expanded] opens the tile.
  const MessageHeaders({
    required this.draft,
    required this.expanded,
    super.key,
  });

  /// The draft whose headers are edited.
  final MessageDraft draft;

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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('header-name-$i'),
                        controller: rows[i].name,
                        decoration: InputDecoration(
                          hintText: 'Name',
                          errorText: rows[i].nameError,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: rows[i].value,
                        builder: (context, value, _) {
                          final masked = isMaskedHeaderValue(value.text);
                          final error = Theme.of(context).colorScheme.error;
                          return TextField(
                            key: ValueKey('header-value-$i'),
                            controller: rows[i].value,
                            style: masked ? TextStyle(color: error) : null,
                            decoration: InputDecoration(
                              hintText: 'Value',
                              errorText: rows[i].valueError,
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
