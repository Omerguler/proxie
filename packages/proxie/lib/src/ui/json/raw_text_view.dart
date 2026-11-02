import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:proxie/src/config.dart' show defaultRawEditableLimit;
import 'package:proxie/src/ui/common.dart';
import 'package:proxie/src/ui/json/text_lines.dart';
import 'package:proxie/src/ui/theme.dart';
import 'package:proxie/src/worker/worker.dart';

bool _isSpace(int unit) => unit == 0x20 || unit == 0x09;

/// Whether [a] and [b] hold the same bytes; only compares contents when
/// their lengths match.
bool _sameBytes(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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
    this.rawEditableLimit = defaultRawEditableLimit,
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
    if (_sameBytes(oldWidget.bytes, widget.bytes) &&
        oldWidget.prettyJson == widget.prettyJson &&
        oldWidget.latin1 == widget.latin1 &&
        oldWidget.worker == widget.worker) {
      // A reload of the same body: keep the lines, scroll and selection.
      return;
    }
    _editAnyway = false;
    _edit?.dispose();
    _edit = null;
    // The old lines stay up until the new ones arrive.
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    _edit?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
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
          // A piece cut from a long line starts mid-token, so only pieces
          // that start a line are colored.
          final startsLine = i == 0 || lines[i - 1].endsWith('\n');
          final text = widget.highlight && startsLine
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
