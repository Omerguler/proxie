import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:proxie/src/core/body_classifier.dart' show isLatin1Text;
import 'package:proxie/src/model/body.dart';
import 'package:proxie/src/ui/common.dart';
import 'package:proxie/src/ui/json/raw_text_view.dart';
import 'package:proxie/src/worker/worker.dart';

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

/// Shows a captured body by its kind: JSON through [jsonBuilder] (indented
/// raw text without one), text in a [RawTextView] (hex when it does not
/// decode), images decoded (hex when that fails), anything else as a hex
/// preview of its first 4 KB.
///
/// A body over [renderCap] or [ProxieBody.truncated] shows a placeholder
/// with a "Show" button until [revealed]; a truncated one keeps a notice
/// above it. The choice is the parent's, so it survives tab switches.
class BodyView extends StatelessWidget {
  /// Creates the view of [body].
  const BodyView({
    required this.worker,
    required this.body,
    required this.renderCap,
    required this.revealed,
    required this.onShow,
    super.key,
    this.jsonBuilder,
  });

  /// Where text is decoded and split into lines.
  final ProxieWorker worker;

  /// The body shown.
  final ProxieBody body;

  /// Bodies larger than this many bytes are shown only on request.
  final int renderCap;

  /// Whether a large or truncated body was asked for with "Show".
  final bool revealed;

  /// Called when "Show" is tapped.
  final VoidCallback onShow;

  /// Builds JSON bodies; null shows them as indented raw text.
  final BodyJsonBuilder? jsonBuilder;

  bool get _large => body.truncated || body.bytes.length > renderCap;

  @override
  Widget build(BuildContext context) {
    if (body.kind == BodyKind.empty || body.bytes.isEmpty) {
      return const _Note('No body');
    }
    final content = _large && !revealed
        ? _Placeholder(size: body.originalLength, onShow: onShow)
        : _content(context);
    if (!body.truncated) return content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TruncatedNotice(kept: body.bytes.length, total: body.originalLength),
        Expanded(child: content),
      ],
    );
  }

  Widget _content(BuildContext context) {
    switch (body.kind) {
      case BodyKind.json:
        final json = jsonBuilder;
        if (json != null) return json(context, body);
        return _text(prettyJson: true);
      case BodyKind.text:
        return _text();
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

  // Decoded and split in the worker, once per body.
  Widget _text({bool prettyJson = false}) => RawTextView(
    worker: worker,
    bytes: body.bytes,
    prettyJson: prettyJson,
    latin1: isLatin1Text(body.contentType),
    undecodable: (_) => _HexView(body.bytes),
  );
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
            child: SelectableText(hexDump(bytes), style: monoStyle(context)),
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
