import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:proxie/src/ui/theme.dart';

/// Whether [a] and [b] hold the same bytes. Contents are compared only
/// when the lengths match, four bytes at a time where both are aligned.
bool sameBytes(Uint8List a, Uint8List b) {
  if (identical(a, b)) return true;
  final n = a.length;
  if (n != b.length) return false;
  var i = 0;
  if (a.offsetInBytes % 4 == 0 && b.offsetInBytes % 4 == 0) {
    final words = n ~/ 4;
    final wa = a.buffer.asUint32List(a.offsetInBytes, words);
    final wb = b.buffer.asUint32List(b.offsetInBytes, words);
    for (var w = 0; w < words; w++) {
      if (wa[w] != wb[w]) return false;
    }
    i = words * 4;
  }
  for (; i < n; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The monospaced style of body text.
TextStyle? monoStyle(BuildContext context) =>
    proxieMono(Theme.of(context).textTheme.bodySmall)?.copyWith(height: 1.4);

/// The decoration of the search boxes above the list and the JSON tree: one
/// height, radius and hairline, from the theme. [clear] goes at the end.
InputDecoration searchDecoration(
  String hint, {
  Widget? clear,
}) => InputDecoration(
  hintText: hint,
  prefixIcon: const Icon(Icons.search),
  prefixIconConstraints: const BoxConstraints.tightFor(width: 36, height: 36),
  suffixIcon: clear,
  suffixIconConstraints: const BoxConstraints.tightFor(width: 36, height: 36),
);

/// A still 2 px accent line that says work is under way. Not animated: the
/// only looping motion in Proxie is the paused bubble.
class BusyLine extends StatelessWidget {
  /// Creates the line.
  const BusyLine({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Working',
    child: SizedBox(
      height: 2,
      child: ColoredBox(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

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
