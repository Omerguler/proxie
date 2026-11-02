import 'dart:typed_data';

import 'package:flutter/material.dart';

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
/// with a "Show" button first; a truncated one keeps a notice above it.
class BodyView extends StatefulWidget {
  /// Creates the view of [body].
  const BodyView({
    required this.body,
    required this.renderCap,
    super.key,
    this.jsonBuilder,
  });

  /// The body shown.
  final ProxieBody body;

  /// Bodies larger than this many bytes are shown only on request.
  final int renderCap;

  /// Builds JSON bodies; null shows them as raw text.
  // Seam for the JSON tree view, which plugs in here.
  final BodyJsonBuilder? jsonBuilder;

  @override
  State<BodyView> createState() => _BodyViewState();
}

class _BodyViewState extends State<BodyView> {
  bool _revealed = false;

  @override
  void didUpdateWidget(BodyView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A re-fetched copy of the same body keeps the choice; a different body
    // asks again.
    final a = oldWidget.body;
    final b = widget.body;
    if (a.bytes.length != b.bytes.length ||
        a.originalLength != b.originalLength ||
        a.kind != b.kind) {
      _revealed = false;
    }
  }

  bool get _large =>
      widget.body.truncated || widget.body.bytes.length > widget.renderCap;

  @override
  Widget build(BuildContext context) {
    final body = widget.body;
    if (body.kind == BodyKind.empty || body.bytes.isEmpty) {
      return const _Note('No body');
    }
    final content = _large && !_revealed
        ? _Placeholder(
            size: body.originalLength,
            onShow: () => setState(() => _revealed = true),
          )
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
    final text = body.text;
    if (text == null) return _HexView(body.bytes);
    return _RawText(text);
  }
}

TextStyle? _mono(BuildContext context) => Theme.of(
  context,
).textTheme.bodySmall?.copyWith(fontFamily: 'monospace', height: 1.4);

/// Splits [text] into lines, and lines longer than [maxChunk] characters
/// into pieces of that length, so a large body can be laid out lazily.
List<String> textChunks(String text, {int maxChunk = 2000}) {
  final chunks = <String>[];
  var start = 0;
  while (start <= text.length) {
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    for (var i = start; i < end; i += maxChunk) {
      chunks.add(text.substring(i, i + maxChunk < end ? i + maxChunk : end));
    }
    if (end == start) chunks.add('');
    start = end + 1;
  }
  return chunks;
}

// Builds only the visible chunks: one paragraph of megabytes would freeze
// layout.
class _RawText extends StatefulWidget {
  const _RawText(this.text);

  final String text;

  @override
  State<_RawText> createState() => _RawTextState();
}

class _RawTextState extends State<_RawText> {
  late List<String> _chunks = textChunks(widget.text);

  @override
  void didUpdateWidget(_RawText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) _chunks = textChunks(widget.text);
  }

  @override
  Widget build(BuildContext context) {
    final style = _mono(context);
    return SelectionArea(
      child: ListView.builder(
        key: const ValueKey('proxie-raw-text'),
        padding: const EdgeInsets.all(12),
        itemCount: _chunks.length,
        itemBuilder: (context, i) => Text(_chunks[i], style: style),
      ),
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
