import 'package:proxie/src/core/masking.dart';

/// Which of Proxie's own themes the inspector uses. Proxie never follows the
/// host app's theme; [system] follows the platform brightness.
enum ProxieThemeMode { dark, light, system }

/// Tunable limits and behavior; defaults follow the global constraints.
class ProxieConfig {
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

  final ProxieMasking masking;
  final bool persistHistory;
  final int spillThreshold;
  final int renderCap;
  final int teeCap;
  final int rawEditableLimit;
  final int retentionCalls;
  final Duration retentionAge;
  final Duration breakpointTimeout;
  final double splitWidth;
  final ProxieThemeMode themeMode;
}
