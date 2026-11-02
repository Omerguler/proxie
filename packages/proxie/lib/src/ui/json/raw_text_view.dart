import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:proxie/src/json/json_document.dart';
import 'package:proxie/src/ui/theme.dart';
import 'package:proxie/src/worker/worker.dart';

/// Longest piece of a line [RawTextView] lays out as one paragraph.
const int rawLineLimit = 2000;

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isSpace(int unit) => unit == 0x20 || unit == 0x09;

/// Splits [text] into pieces of at most [maxChunk] UTF-16 code units, so a
/// large body can be laid out lazily. The pieces join back to [text]
/// exactly (a copied selection across them adds or drops nothing).
///
/// A piece ends after the last line break in its window, else after the
/// last space or tab in the window's second half, else at the window's end;
/// it never ends between the two halves of a surrogate pair.
List<String> textChunks(String text, {int maxChunk = rawLineLimit}) {
  assert(maxChunk >= 2, 'a surrogate pair needs two code units');
  if (text.length <= maxChunk) return [text];
  final chunks = <String>[];
  var start = 0;
  while (text.length - start > maxChunk) {
    final limit = start + maxChunk;
    // Searches this window only: a scan back to the text's start would make
    // a long single line quadratic.
    var end = limit;
    var lineEnd = -1;
    for (var i = limit - 1; i >= start; i--) {
      if (text.codeUnitAt(i) == 0x0A) {
        lineEnd = i + 1;
        break;
      }
    }
    if (lineEnd > start) {
      end = lineEnd;
    } else {
      for (var i = limit - 1; i > start + maxChunk ~/ 2; i--) {
        if (_isSpace(text.codeUnitAt(i))) {
          end = i + 1;
          break;
        }
      }
      if (end == limit && _isHighSurrogate(text.codeUnitAt(end - 1))) end--;
    }
    chunks.add(text.substring(start, end));
    start = end;
  }
  chunks.add(text.substring(start));
  return chunks;
}

/// Splits [text] into its lines, each keeping its line break; a line longer
/// than [maxLine] is cut further by [textChunks]. The pieces join back to
/// [text] exactly, and none ends inside a surrogate pair.
List<String> textLines(String text, {int maxLine = rawLineLimit}) {
  final lines = <String>[];
  var start = 0;
  while (start < text.length) {
    final lineBreak = text.indexOf('\n', start);
    final end = lineBreak == -1 ? text.length : lineBreak + 1;
    final line = text.substring(start, end);
    if (line.length <= maxLine) {
      lines.add(line);
    } else {
      lines.addAll(textChunks(line, maxChunk: maxLine));
    }
    start = end;
  }
  if (lines.isEmpty) lines.add('');
  return lines;
}

/// Decodes [bytes] and splits the text with [textLines] inside the worker,
/// so a large body never decodes or indents on the UI isolate. Null when
/// the bytes are not valid text.
class RawTextLines extends WorkerCommand<List<String>?> {
  /// Creates a command that splits [bytes] into lines.
  const RawTextLines(
    this.bytes, {
    this.prettyJson = false,
    this.latin1 = false,
  });

  /// The body.
  final Uint8List bytes;

  /// Whether to indent [bytes] by two spaces first when they parse as JSON;
  /// they are split as they are when they do not.
  final bool prettyJson;

  /// Whether [bytes] are ISO-8859-1 rather than UTF-8.
  final bool latin1;

  @override
  Future<List<String>?> execute(WorkerContext ctx) async {
    var source = bytes;
    if (prettyJson) {
      final doc = JsonDocument.tryParse(bytes);
      if (doc.parseError == null) source = doc.encode(pretty: true);
    }
    final String text;
    try {
      text = latin1
          ? const Latin1Decoder().convert(source)
          : utf8.decode(source);
    } on FormatException {
      return null;
    }
    return textLines(text);
  }
}

/// The colored spans of one line of indented JSON: member names, strings,
/// and numbers with `true` / `false` / `null`, by [colors]. The spans'
/// text joins back to [line].
List<TextSpan> jsonLineSpans(String line, ProxieColors colors) {
  final spans = <TextSpan>[];
  var plain = 0; // start of text not yet in a span
  var i = 0;

  void emit(int start, int end, Color color) {
    if (plain < start) spans.add(TextSpan(text: line.substring(plain, start)));
    spans.add(
      TextSpan(
        text: line.substring(start, end),
        style: TextStyle(color: color),
      ),
    );
    plain = end;
  }

  bool isNumberUnit(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      c == 0x2D ||
      c == 0x2B ||
      c == 0x2E ||
      c == 0x65 ||
      c == 0x45;

  while (i < line.length) {
    final c = line.codeUnitAt(i);
    if (c == 0x22) {
      var end = i + 1;
      while (end < line.length && line.codeUnitAt(end) != 0x22) {
        end += line.codeUnitAt(end) == 0x5C ? 2 : 1;
      }
      end = end < line.length ? end + 1 : line.length;
      var next = end;
      while (next < line.length && _isSpace(line.codeUnitAt(next))) {
        next++;
      }
      final isKey = next < line.length && line.codeUnitAt(next) == 0x3A;
      emit(i, end, isKey ? colors.jsonKey : colors.jsonString);
      i = end;
    } else if (c == 0x2D || (c >= 0x30 && c <= 0x39)) {
      var end = i + 1;
      while (end < line.length && isNumberUnit(line.codeUnitAt(end))) {
        end++;
      }
      emit(i, end, colors.jsonNumber);
      i = end;
    } else {
      final word = line.startsWith('true', i)
          ? 4
          : line.startsWith('null', i)
          ? 4
          : line.startsWith('false', i)
          ? 5
          : 0;
      if (word > 0) {
        emit(i, i + word, colors.jsonNumber);
        i += word;
      } else {
        i++;
      }
    }
  }
  if (plain < line.length) spans.add(TextSpan(text: line.substring(plain)));
  return spans;
}

/// A body as text, one lazily built line per row, decoded and split in the
/// worker once per [bytes] object.
///
/// Copying a selection across lines gives back the exact text. When
/// [editable], bodies under [rawEditableLimit] bytes show an editable
/// [TextField]; larger ones are read-only with an "Edit anyway" button.
class RawTextView extends StatefulWidget {
  /// Creates the text view of [bytes].
  const RawTextView({
    required this.worker,
    required this.bytes,
    super.key,
    this.prettyJson = false,
    this.latin1 = false,
    this.editable = false,
    this.rawEditableLimit = 1024 * 1024,
    this.onChanged,
    this.undecodable,
  });

  /// Where the text is decoded and split.
  final ProxieWorker worker;

  /// The body shown.
  final Uint8List bytes;

  /// Whether JSON is indented and colored.
  final bool prettyJson;

  /// Whether [bytes] are ISO-8859-1 rather than UTF-8.
  final bool latin1;

  /// Whether the text can be edited.
  final bool editable;

  /// Bodies of at least this many bytes open read-only even when
  /// [editable], until "Edit anyway" is tapped.
  final int rawEditableLimit;

  /// Called with the whole text after each edit.
  final ValueChanged<String>? onChanged;

  /// Shown when [bytes] are not valid text; a short note when null.
  final WidgetBuilder? undecodable;

  @override
  State<RawTextView> createState() => _RawTextViewState();
}

class _RawTextViewState extends State<RawTextView> {
  List<String>? _lines;
  bool _loaded = false;
  Object? _error;
  int _generation = 0;
  bool _editAnyway = false;
  TextEditingController? _edit;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(RawTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes) ||
        oldWidget.prettyJson != widget.prettyJson ||
        oldWidget.latin1 != widget.latin1 ||
        oldWidget.worker != widget.worker) {
      _editAnyway = false;
      _edit?.dispose();
      _edit = null;
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _generation++;
    _edit?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    _lines = null;
    _loaded = false;
    _error = null;
    try {
      final lines = await widget.worker.run(
        RawTextLines(
          widget.bytes,
          prettyJson: widget.prettyJson,
          latin1: widget.latin1,
        ),
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _lines = lines;
        _loaded = true;
      });
    } on Object catch (e, st) {
      // The host app must never crash because the worker failed.
      developer.log(
        'Proxie could not split a body into lines',
        name: 'proxie',
        error: e,
        stackTrace: st,
      );
      if (!mounted || generation != _generation) return;
      setState(() => _error = e);
    }
  }

  void _retry() {
    setState(() => _error = null);
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return InlineRetry(message: "Couldn't show this body", onRetry: _retry);
    }
    // One worker round trip; nothing animates meanwhile.
    if (!_loaded) return const SizedBox.shrink();
    final lines = _lines;
    if (lines == null) {
      return widget.undecodable?.call(context) ??
          const Center(child: Text('Not valid text'));
    }
    if (widget.editable &&
        (widget.bytes.length < widget.rawEditableLimit || _editAnyway)) {
      return _editor(context, lines);
    }
    final view = _LinesView(lines: lines, highlight: widget.prettyJson);
    if (!widget.editable) return view;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ColoredBox(
          color: theme.colorScheme.surfaceContainer,
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Read-only — large body '
                    '(${formatBytes(widget.bytes.length)})',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _editAnyway = true),
                  child: const Text('Edit anyway'),
                ),
              ],
            ),
          ),
        ),
        Expanded(child: view),
      ],
    );
  }

  Widget _editor(BuildContext context, List<String> lines) {
    final edit = _edit ??= TextEditingController(text: lines.join());
    return TextField(
      key: const ValueKey('proxie-raw-editor'),
      controller: edit,
      onChanged: widget.onChanged,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      style: monoStyle(context),
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(12),
      ),
    );
  }
}

/// The monospaced style of body text.
TextStyle? monoStyle(BuildContext context) => Theme.of(
  context,
).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.4);

/// Readable byte count, such as `512 B`, `4.0 KB` or `6.0 MB`.
String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// A short message with a Retry button, shown in place of content that
/// failed to load.
class InlineRetry extends StatelessWidget {
  /// Creates the message [message] whose button calls [onRetry].
  const InlineRetry({required this.message, required this.onRetry, super.key});

  /// What failed.
  final String message;

  /// Called when Retry is tapped.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

// Builds only the visible lines: one paragraph of megabytes would freeze
// layout.
class _LinesView extends StatefulWidget {
  const _LinesView({required this.lines, required this.highlight});

  final List<String> lines;
  final bool highlight;

  @override
  State<_LinesView> createState() => _LinesViewState();
}

class _LinesViewState extends State<_LinesView> {
  // The height of one line of text, by the inputs it was measured with.
  (TextStyle?, TextScaler, TextDirection)? _measuredFor;
  double _lineHeight = 0;

  double _lineHeightFor(TextStyle? style, BuildContext context) {
    final key = (
      style,
      MediaQuery.textScalerOf(context),
      Directionality.of(context),
    );
    if (key != _measuredFor) {
      final painter = TextPainter(
        text: TextSpan(text: ' ', style: style),
        textDirection: key.$3,
        textScaler: key.$2,
      )..layout();
      _lineHeight = painter.height;
      painter.dispose();
      _measuredFor = key;
    }
    return _lineHeight;
  }

  @override
  Widget build(BuildContext context) {
    final style = monoStyle(context);
    final colors = ProxieColors.of(context);
    // A line ending in a line break keeps it, so copying across lines gives
    // back the line breaks, but the empty line the break starts is not laid
    // out as space.
    final lineHeight = _lineHeightFor(style, context);
    final lines = widget.lines;
    return SelectionArea(
      child: ListView.builder(
        key: const ValueKey('proxie-raw-text'),
        padding: const EdgeInsets.all(12),
        itemCount: lines.length,
        itemBuilder: (context, i) {
          final line = lines[i];
          final text = widget.highlight
              ? Text.rich(
                  TextSpan(children: jsonLineSpans(line, colors)),
                  style: style,
                )
              : Text(line, style: style);
          return KeyedSubtree(
            key: ValueKey('proxie-line-$i'),
            child: line.endsWith('\n')
                ? _TrimBottom(trim: lineHeight, child: text)
                : text,
          );
        },
      ),
    );
  }
}

// Lays out its child but takes [trim] less height (the empty last line of
// a paragraph ending in a line break).
class _TrimBottom extends SingleChildRenderObjectWidget {
  const _TrimBottom({required this.trim, required Widget super.child});

  final double trim;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTrimBottom(trim);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderTrimBottom renderObject,
  ) {
    renderObject.trim = trim;
  }
}

class _RenderTrimBottom extends RenderProxyBox {
  _RenderTrimBottom(this._trim);

  double _trim;

  /// Height taken off the child's.
  double get trim => _trim;

  set trim(double value) {
    if (value == _trim) return;
    _trim = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child!..layout(constraints, parentUsesSize: true);
    final height = child.size.height - _trim;
    size = constraints.constrain(
      Size(child.size.width, height < 0 ? 0 : height),
    );
  }
}
