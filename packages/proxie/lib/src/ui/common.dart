import 'package:flutter/material.dart';

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
