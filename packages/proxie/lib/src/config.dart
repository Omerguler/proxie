import 'package:proxie/src/core/masking.dart';

/// Which of Proxie's own themes the inspector uses. Proxie never follows the
/// host app's theme; [system] follows the platform brightness.
enum ProxieThemeMode {
  /// Always the dark theme.
  dark,

  /// Always the light theme.
  light,

  /// Dark or light to match the platform brightness.
  system,
}

/// Tunable limits and behavior; defaults follow the global constraints.
class ProxieConfig {
  /// Creates a configuration; every limit has a default.
  const ProxieConfig({
    this.masking = ProxieMasking.defaults,
    this.persistHistory = true,
    this.spillThreshold = 256 * 1024,
    this.renderCap = 5 * 1024 * 1024,
    this.teeCap = 5 * 1024 * 1024,
    this.rawEditableLimit = 1024 * 1024,
    this.retentionCalls = 5000,
    this.retentionAge = const Duration(days: 7),
    this.breakpointTimeout = const Duration(seconds: 60),
    this.splitWidth = 700,
    this.themeMode = ProxieThemeMode.dark,
  });

  /// Which headers and JSON keys are masked in stored and shown copies.
  final ProxieMasking masking;

  /// Whether calls are kept in a database across app runs; false keeps
  /// them in memory only.
  final bool persistHistory;

  /// Bodies larger than this many bytes are stored in files instead of
  /// the database.
  final int spillThreshold;

  /// The largest body, in bytes, the inspector renders.
  final int renderCap;

  /// The most bytes of each body that are captured; the rest still reaches
  /// the app but is not recorded.
  final int teeCap;

  /// Bodies below this many bytes can be edited as raw text.
  final int rawEditableLimit;

  /// The most calls kept; older ones are removed.
  final int retentionCalls;

  /// How long calls are kept before they are removed.
  final Duration retentionAge;

  /// How long a call waits at a breakpoint before it continues unchanged.
  final Duration breakpointTimeout;

  /// The window width, in logical pixels, from which the inspector shows
  /// the list and the details side by side.
  final double splitWidth;

  /// Which of Proxie's themes the inspector uses.
  final ProxieThemeMode themeMode;
}
