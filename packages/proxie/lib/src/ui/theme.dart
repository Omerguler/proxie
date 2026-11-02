import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:proxie/src/config.dart';

/// Proxie's semantic colors, attached to [ProxieTheme] as a theme extension.
@immutable
class ProxieColors extends ThemeExtension<ProxieColors> {
  /// Creates a color set; every color has a default.
  const ProxieColors({
    this.get = const Color(0xFF58A6FF),
    this.post = const Color(0xFF3FB950),
    this.put = const Color(0xFFE3B341),
    this.delete = const Color(0xFFFF7B72),
    this.success = const Color(0xFF3FB950),
    this.redirect = const Color(0xFF58A6FF),
    this.clientError = const Color(0xFFE3B341),
    this.serverError = const Color(0xFFFF7B72),
    this.pending = const Color(0xFF7D8590),
    this.accentStart = const Color(0xFF7C5CFF),
    this.accentEnd = const Color(0xFF20C3FF),
  });

  /// The colors of the nearest Proxie theme, or the defaults.
  factory ProxieColors.of(BuildContext context) =>
      Theme.of(context).extension<ProxieColors>() ?? const ProxieColors();

  /// GET.
  final Color get;

  /// POST.
  final Color post;

  /// PUT and PATCH.
  final Color put;

  /// DELETE.
  final Color delete;

  /// 2xx.
  final Color success;

  /// 3xx.
  final Color redirect;

  /// 4xx.
  final Color clientError;

  /// 5xx and failed calls.
  final Color serverError;

  /// Calls without a response yet; also other methods and status codes.
  final Color pending;

  /// The first color of [accentGradient].
  final Color accentStart;

  /// The last color of [accentGradient].
  final Color accentEnd;

  /// The accent gradient, top-left to bottom-right.
  LinearGradient get accentGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [accentStart, accentEnd],
  );

  /// The color of an HTTP [method] badge (case-insensitive).
  Color methodColor(String method) => switch (method.toUpperCase()) {
    'GET' => get,
    'POST' => post,
    'PUT' || 'PATCH' => put,
    'DELETE' => delete,
    _ => pending,
  };

  /// The color for a response status; [error] marks a failed call.
  Color statusColor(int? statusCode, {bool error = false}) {
    if (error) return serverError;
    final code = statusCode;
    if (code == null) return pending;
    if (code >= 200 && code < 300) return success;
    if (code >= 300 && code < 400) return redirect;
    if (code >= 400 && code < 500) return clientError;
    if (code >= 500) return serverError;
    return pending;
  }

  @override
  ProxieColors copyWith({
    Color? get,
    Color? post,
    Color? put,
    Color? delete,
    Color? success,
    Color? redirect,
    Color? clientError,
    Color? serverError,
    Color? pending,
    Color? accentStart,
    Color? accentEnd,
  }) => ProxieColors(
    get: get ?? this.get,
    post: post ?? this.post,
    put: put ?? this.put,
    delete: delete ?? this.delete,
    success: success ?? this.success,
    redirect: redirect ?? this.redirect,
    clientError: clientError ?? this.clientError,
    serverError: serverError ?? this.serverError,
    pending: pending ?? this.pending,
    accentStart: accentStart ?? this.accentStart,
    accentEnd: accentEnd ?? this.accentEnd,
  );

  @override
  ProxieColors lerp(ProxieColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return ProxieColors(
      get: l(get, other.get),
      post: l(post, other.post),
      put: l(put, other.put),
      delete: l(delete, other.delete),
      success: l(success, other.success),
      redirect: l(redirect, other.redirect),
      clientError: l(clientError, other.clientError),
      serverError: l(serverError, other.serverError),
      pending: l(pending, other.pending),
      accentStart: l(accentStart, other.accentStart),
      accentEnd: l(accentEnd, other.accentEnd),
    );
  }
}

/// Proxie's own themes. They never read the host app's theme; Proxie applies
/// them with a [Theme] widget around its own subtree only.
abstract final class ProxieTheme {
  static final ThemeData _dark = _build(Brightness.dark);
  static final ThemeData _light = _build(Brightness.light);

  /// The default theme.
  static ThemeData dark() => _dark;

  /// The light theme.
  static ThemeData light() => _light;

  /// The theme for [mode]; [ProxieThemeMode.system] picks by
  /// [platformBrightness] (never by the host app's theme).
  static ThemeData resolve(
    ProxieThemeMode mode,
    Brightness platformBrightness,
  ) => switch (mode) {
    ProxieThemeMode.dark => _dark,
    ProxieThemeMode.light => _light,
    ProxieThemeMode.system =>
      platformBrightness == Brightness.dark ? _dark : _light,
  };

  static ThemeData _build(Brightness brightness) {
    const colors = ProxieColors();
    final dark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: colors.accentStart,
          brightness: brightness,
        ).copyWith(
          primary: dark ? const Color(0xFF9D86FF) : colors.accentStart,
          secondary: colors.accentEnd,
          surface: dark ? const Color(0xFF0D1117) : const Color(0xFFFFFFFF),
          onSurface: dark ? const Color(0xFFE6EDF3) : const Color(0xFF1F2328),
          surfaceContainer: dark
              ? const Color(0xFF161B22)
              : const Color(0xFFF6F8FA),
          outlineVariant: dark
              ? const Color(0xFF30363D)
              : const Color(0xFFD0D7DE),
          error: colors.serverError,
        );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      dividerColor: scheme.outlineVariant,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainer,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      extensions: const [colors],
    );
  }
}

/// Puts [child] in Proxie's theme for [mode], and supplies what Proxie's
/// Material widgets need when the host does not: a [MediaQuery] (from the
/// view), Material/Cupertino/Widgets localizations (English defaults,
/// whatever the host's locale) and
/// a [Directionality] (the host's, else left-to-right). Lets `Proxie.wrap`
/// work under a `WidgetsApp`, a `CupertinoApp` or no app at all.
class ProxieThemed extends StatelessWidget {
  /// Creates the wrapper that themes [child] by [mode].
  const ProxieThemed({required this.mode, required this.child, super.key});

  /// Which of Proxie's themes applies.
  final ProxieThemeMode mode;

  /// The Proxie UI to theme.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    Widget result = Directionality(
      textDirection: direction,
      child: Builder(
        builder: (context) => Theme(
          data: ProxieTheme.resolve(
            mode,
            MediaQuery.platformBrightnessOf(context),
          ),
          child: child,
        ),
      ),
    );
    if (Localizations.of<MaterialLocalizations>(
          context,
          MaterialLocalizations,
        ) ==
        null) {
      // The default delegates only support English, so the fallback is
      // always en_US whatever the host's locale; the Directionality inside
      // keeps the host's text direction.
      result = Localizations(
        locale: const Locale('en', 'US'),
        delegates: const [
          DefaultMaterialLocalizations.delegate,
          DefaultCupertinoLocalizations.delegate,
          DefaultWidgetsLocalizations.delegate,
        ],
        child: result,
      );
    }
    if (MediaQuery.maybeOf(context) == null) {
      result = MediaQuery.fromView(view: View.of(context), child: result);
    }
    return result;
  }
}
