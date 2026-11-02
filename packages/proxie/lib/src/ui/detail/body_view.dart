import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:proxie/src/model/body.dart';

/// Builds the view of a JSON body.
typedef BodyJsonBuilder =
    Widget Function(BuildContext context, ProxieBody body);

/// The most bytes the hex preview shows.
const int hexPreviewLimit = 4096;

/// A hex dump of the first [limit] bytes of [bytes]: 16 per line, as
/// `offset  hex bytes  |ASCII|`, with `.` for unprintable bytes.
String hexDump(Uint8List bytes, {int limit = hexPreviewLimit}) {
  final end = bytes.length < limit ? bytes.length : limit;
  final out = StringBuffer();
  for (var row = 0; row < end; row += 16) {
    if (row > 0) out.write('\n');
    out
      ..write(row.toRadixString(16).padLeft(8, '0'))
      ..write('  ');
    final ascii = StringBuffer();
    for (var i = row; i < row + 16; i++) {
      if (i < end) {
        final b = bytes[i];
        out
          ..write(b.toRadixString(16).padLeft(2, '0'))
          ..write(' ');
        ascii.writeCharCode(b >= 0x20 && b < 0x7F ? b : 0x2E);
      } else {
        out.write('   ');
      }
    }
    out.write(' |$ascii|');
  }
  return out.toString();
}

/// Shows a captured body by its kind: JSON through [jsonBuilder] (raw text
/// without one), text as selectable text, images decoded (hex when that
/// fails), anything else as a hex preview of its first 4 KB.
///
/// A body over [renderCap] or [ProxieBody.truncated] shows a placeholder
/// with a "Show" button until [revealed]; a truncated one keeps a notice
/// above it. The choice is the parent's, so it survives tab switches.
class BodyView extends StatefulWidget {
  /// Creates the view of [body].
  const BodyView({
    required this.body,
    required this.renderCap,
    required this.revealed,
    required this.onShow,
    super.key,
    this.jsonBuilder,
  });

  /// The body shown.
  final ProxieBody body;

  /// Bodies larger than this many bytes are shown only on request.
  final int renderCap;

  /// Whether a large or truncated body was asked for with "Show".
  final bool revealed;

  /// Called when "Show" is tapped.
  final VoidCallback onShow;

  /// Builds JSON bodies; null shows them as raw text.
  // Seam for the JSON tree view, which plugs in here.
  final BodyJsonBuilder? jsonBuilder;

  @override
  State<BodyView> createState() => _BodyViewState();
}

class _BodyViewState extends State<BodyView> {
  // The decoded text of [_decodedFor], split for lazy layout; null when it
  // does not decode. Decoding reads the whole body, so it runs once per
  // body object, not once per build.
  ProxieBody? _decodedFor;
  List<String>? _chunks;

  List<String>? _chunksOf(ProxieBody body) {
    if (!identical(_decodedFor, body)) {
      _decodedFor = body;
      final text = body.text;
      _chunks = text == null ? null : textChunks(text);
    }
    return _chunks;
  }

  bool get _large =>
      widget.body.truncated || widget.body.bytes.length > widget.renderCap;

  @override
  Widget build(BuildContext context) {
    final body = widget.body;
    if (body.kind == BodyKind.empty || body.bytes.isEmpty) {
      return const _Note('No body');
    }
    final content = _large && !widget.revealed
        ? _Placeholder(size: body.originalLength, onShow: widget.onShow)
        : _content(context, body);
    if (!body.truncated) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TruncatedNotice(kept: body.bytes.length, total: body.originalLength),
        Expanded(child: content),
      ],
    );
  }

  Widget _content(BuildContext context, ProxieBody body) {
    switch (body.kind) {
      case BodyKind.json:
        final json = widget.jsonBuilder;
        if (json != null) return json(context, body);
        return _text(body);
      case BodyKind.text:
        return _text(body);
      case BodyKind.image:
        return SingleChildScrollView(
          padding: const EdgeInsets.all(12),
          child: Image.memory(
            body.bytes,
            alignment: Alignment.topLeft,
            gaplessPlayback: true,
            errorBuilder: (context, error, stack) => _HexView(body.bytes),
          ),
        );
      case BodyKind.binary:
      case BodyKind.empty:
        return _HexView(body.bytes);
    }
  }

  Widget _text(ProxieBody body) {
    final chunks = _chunksOf(body);
    if (chunks == null) return _HexView(body.bytes);
    return _RawText(chunks);
  }
}

TextStyle? _mono(BuildContext context) => Theme.of(
  context,
).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.4);

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isSpace(int unit) => unit == 0x20 || unit == 0x09;

/// Splits [text] into pieces of at most [maxChunk] UTF-16 code units, so a
/// large body can be laid out lazily. The pieces join back to [text]
/// exactly (a copied selection across them adds or drops nothing).
///
/// A piece ends after the last line break in its window, else after the
/// last space or tab in the window's second half, else at the window's end;
/// it never ends between the two halves of a surrogate pair.
List<String> textChunks(String text, {int maxChunk = 2000}) {
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

// Builds only the visible chunks: one paragraph of megabytes would freeze
// layout.
class _RawText extends StatelessWidget {
  const _RawText(this.chunks);

  final List<String> chunks;

  @override
  Widget build(BuildContext context) {
    final style = _mono(context);
    // A chunk ending in a line break keeps it, so copying across chunks
    // gives back the line breaks, but the empty line the break starts is
    // not laid out as space.
    final painter = TextPainter(
      text: TextSpan(text: ' ', style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final lineHeight = painter.height;
    painter.dispose();
    return SelectionArea(
      child: ListView.builder(
        key: const ValueKey('proxie-raw-text'),
        padding: const EdgeInsets.all(12),
        itemCount: chunks.length,
        itemBuilder: (context, i) {
          final chunk = chunks[i];
          final text = Text(chunk, style: style);
          return KeyedSubtree(
            key: ValueKey('proxie-chunk-$i'),
            child: chunk.endsWith('\n')
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

/// Readable byte count, such as `512 B`, `4.0 KB` or `6.0 MB`.
String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
}

class _HexView extends StatelessWidget {
  const _HexView(this.bytes);

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = bytes.length < hexPreviewLimit
        ? bytes.length
        : hexPreviewLimit;
    return SingleChildScrollView(
      key: const ValueKey('proxie-hex-view'),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            shown < bytes.length
                ? 'Binary — first ${formatBytes(shown)} of '
                      '${formatBytes(bytes.length)}'
                : 'Binary — ${formatBytes(bytes.length)}',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(hexDump(bytes), style: _mono(context)),
          ),
        ],
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.size, required this.onShow});

  final int size;
  final VoidCallback onShow;

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
              'Large body (${formatBytes(size)})',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(onPressed: onShow, child: const Text('Show')),
          ],
        ),
      ),
    );
  }
}

class _TruncatedNotice extends StatelessWidget {
  const _TruncatedNotice({required this.kept, required this.total});

  final int kept;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          'Truncated — captured ${formatBytes(kept)} of '
          '${formatBytes(total)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onTertiaryContainer,
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        text,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
