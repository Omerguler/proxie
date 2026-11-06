import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:proxie/src/config.dart';

/// The duration and easing of every hover and press change.
abstract final class ProxieMotion {
  /// How long a hover or press change takes.
  static const Duration duration = Duration(milliseconds: 150);

  /// How a hover, press or snap eases.
  static const Curve curve = Cubic(0.22, 1, 0.36, 1);
}

/// [base] in the platform's monospace face with tabular figures. No font is
/// bundled: on the web, where only loaded fonts exist, this falls back to the
/// default face and the figures still line up.
TextStyle? proxieMono(TextStyle? base) => base?.copyWith(
  fontFamily: 'monospace',
  fontFamilyFallback: const [
    'Menlo',
    'Consolas',
    'DejaVu Sans Mono',
    'Roboto Mono',
    'Courier New',
  ],
  fontFeatures: const [FontFeature.tabularFigures()],
);

/// Proxie's semantic colors, attached to [ProxieTheme] as a theme extension.
@immutable
class ProxieColors extends ThemeExtension<ProxieColors> {
  /// Creates a color set; every color has a default, those of the dark theme.
  const ProxieColors({
    this.get = const Color(0xFF8AB4D6),
    this.post = const Color(0xFF4CC38A),
    this.put = const Color(0xFFD9A25F),
    this.delete = const Color(0xFFEC6A6E),
    this.success = const Color(0xFF4CC38A),
    this.redirect = const Color(0xFF7FA8C9),
    this.clientError = const Color(0xFFE5864A),
    this.serverError = const Color(0xFFEC6A6E),
    this.pending = const Color(0xFF85858B),
    this.muted = const Color(0xFF85858B),
    this.accent = const Color(0xFFE9A23B),
    this.jsonKey = const Color(0xFF7EE787),
    this.jsonString = const Color(0xFFA5D6FF),
    this.jsonNumber = const Color(0xFFFFA657),
  });

  /// The colors of the nearest Proxie theme, or the defaults.
  factory ProxieColors.of(BuildContext context) =>
      Theme.of(context).extension<ProxieColors>() ?? const ProxieColors();

  /// The defaults of the light theme: inks that read on a light surface.
  static const ProxieColors light = ProxieColors(
    get: Color(0xFF2B6A99),
    post: Color(0xFF15803D),
    put: Color(0xFFA15C12),
    delete: Color(0xFFC8282C),
    success: Color(0xFF15803D),
    redirect: Color(0xFF2B6A99),
    clientError: Color(0xFFB4541A),
    serverError: Color(0xFFC8282C),
    pending: Color(0xFF737373),
    muted: Color(0xFF737373),
    accent: Color(0xFF8F5500),
    jsonKey: Color(0xFF116329),
    jsonString: Color(0xFF0A3069),
    jsonNumber: Color(0xFF953800),
  );

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

  /// The third text role, after the scheme's `onSurface` and
  /// `onSurfaceVariant`: meta and captions.
  final Color muted;

  /// Instrument amber: the one accent.
  final Color accent;

  /// JSON member names.
  final Color jsonKey;

  /// JSON strings.
  final Color jsonString;

  /// JSON numbers, and `true`, `false` and `null`.
  final Color jsonNumber;

  /// The color of an HTTP [method] (case-insensitive).
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
    Color? muted,
    Color? accent,
    Color? jsonKey,
    Color? jsonString,
    Color? jsonNumber,
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
    muted: muted ?? this.muted,
    accent: accent ?? this.accent,
    jsonKey: jsonKey ?? this.jsonKey,
    jsonString: jsonString ?? this.jsonString,
    jsonNumber: jsonNumber ?? this.jsonNumber,
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
      muted: l(muted, other.muted),
      accent: l(accent, other.accent),
      jsonKey: l(jsonKey, other.jsonKey),
      jsonString: l(jsonString, other.jsonString),
      jsonNumber: l(jsonNumber, other.jsonNumber),
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

  static TextStyle _style(double size, double line, FontWeight weight) =>
      TextStyle(
        fontSize: size,
        height: line / size,
        fontWeight: weight,
        letterSpacing: 0,
      );

  static final TextTheme _type = TextTheme(
    titleLarge: _style(16, 24, FontWeight.w500),
    titleMedium: _style(14, 20, FontWeight.w500),
    titleSmall: _style(13, 20, FontWeight.w500),
    bodyLarge: _style(14, 20, FontWeight.w400),
    bodyMedium: _style(13, 20, FontWeight.w400),
    bodySmall: _style(12, 16, FontWeight.w400),
    labelLarge: _style(13, 20, FontWeight.w500),
    labelMedium: _style(12, 16, FontWeight.w500),
    labelSmall: _style(11, 16, FontWeight.w500),
  );

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final colors = dark ? const ProxieColors() : ProxieColors.light;
    // The graphite ramp.
    final deepest = dark ? const Color(0xFF0F0F10) : const Color(0xFFFFFFFF);
    final page = dark ? const Color(0xFF141415) : const Color(0xFFFAFAFA);
    final card = dark ? const Color(0xFF19191B) : const Color(0xFFFFFFFF);
    final raised = dark ? const Color(0xFF232325) : const Color(0xFFF4F4F5);
    final text = dark ? const Color(0xFFEDEDED) : const Color(0xFF171717);
    final secondary = dark ? const Color(0xFFA1A1A6) : const Color(0xFF525252);
    final hairline = text.withValues(alpha: 0.08);
    final accent = colors.accent;
    final onAccent = dark ? page : const Color(0xFFFFFFFF);
    const clear = Color(0x00000000);
    final scheme = ColorScheme(
      brightness: brightness,
      primary: accent,
      onPrimary: onAccent,
      primaryContainer: raised,
      onPrimaryContainer: accent,
      secondary: secondary,
      onSecondary: page,
      secondaryContainer: raised,
      onSecondaryContainer: text,
      tertiary: accent,
      onTertiary: onAccent,
      tertiaryContainer: raised,
      onTertiaryContainer: accent,
      error: colors.serverError,
      onError: onAccent,
      errorContainer: dark ? const Color(0xFF2A1A1B) : const Color(0xFFFDECEC),
      onErrorContainer: dark
          ? const Color(0xFFF2B8BA)
          : const Color(0xFF8F1D1D),
      surface: page,
      onSurface: text,
      onSurfaceVariant: secondary,
      surfaceDim: deepest,
      surfaceBright: raised,
      surfaceContainerLowest: deepest,
      surfaceContainerLow: page,
      surfaceContainer: card,
      surfaceContainerHigh: raised,
      surfaceContainerHighest: raised,
      outline: text.withValues(alpha: 0.16),
      outlineVariant: hairline,
      shadow: const Color(0xFF000000),
      scrim: const Color(0x99000000),
      inverseSurface: text,
      onInverseSurface: page,
      inversePrimary: accent,
      surfaceTint: clear,
    );
    final side = BorderSide(color: hairline);
    final type = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: _type,
    ).textTheme;
    final control = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    );
    const buttonSize = Size(64, 36);
    const buttonPadding = EdgeInsets.symmetric(horizontal: 16);
    OutlineInputBorder inputBorder(Color color) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: color),
    );
    final icons = IconThemeData(color: secondary, size: 18);
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      textTheme: _type,
      // One size on every platform: controls are 36 px on desktop and phone.
      visualDensity: VisualDensity.standard,
      scaffoldBackgroundColor: page,
      dividerColor: hairline,
      splashFactory: NoSplash.splashFactory,
      hoverColor: text.withValues(alpha: 0.04),
      highlightColor: text.withValues(alpha: 0.08),
      focusColor: text.withValues(alpha: 0.12),
      splashColor: clear,
      iconTheme: icons,
      dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: page,
        foregroundColor: text,
        surfaceTintColor: clear,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 48,
        leadingWidth: 44,
        titleSpacing: 12,
        shape: Border(bottom: side),
        titleTextStyle: type.titleLarge?.copyWith(color: text),
        iconTheme: icons,
        actionsIconTheme: icons,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: text,
        unselectedLabelColor: secondary,
        labelStyle: type.labelLarge,
        unselectedLabelStyle: type.bodyMedium,
        labelPadding: const EdgeInsets.symmetric(horizontal: 12),
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: UnderlineTabIndicator(
          borderSide: BorderSide(color: accent, width: 2),
        ),
        dividerColor: hairline,
        dividerHeight: 1,
        splashFactory: NoSplash.splashFactory,
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? text.withValues(alpha: 0.08)
              : states.contains(WidgetState.hovered)
              ? text.withValues(alpha: 0.04)
              : null,
        ),
      ),
      chipTheme: ChipThemeData(
        color: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? raised : clear,
        ),
        side: side,
        shape: control,
        elevation: 0,
        pressElevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        labelStyle: type.bodySmall?.copyWith(
          color: WidgetStateColor.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? text : secondary,
          ),
        ),
        iconTheme: IconThemeData(color: secondary, size: 16),
      ),
      inputDecorationTheme: InputDecorationThemeData(
        isDense: true,
        filled: true,
        fillColor: card,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        hintStyle: type.bodyLarge?.copyWith(color: colors.muted),
        labelStyle: type.bodyLarge?.copyWith(color: secondary),
        floatingLabelStyle: type.bodySmall?.copyWith(color: secondary),
        helperStyle: type.bodySmall?.copyWith(color: colors.muted),
        errorStyle: type.bodySmall?.copyWith(color: colors.serverError),
        prefixIconColor: secondary,
        suffixIconColor: secondary,
        border: inputBorder(hairline),
        enabledBorder: inputBorder(hairline),
        disabledBorder: inputBorder(hairline),
        focusedBorder: inputBorder(accent),
        errorBorder: inputBorder(colors.serverError),
        focusedErrorBorder: inputBorder(colors.serverError),
      ),
      switchTheme: SwitchThemeData(
        // On is a lit amber thumb on the same dark track, not a filled bar.
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.selected) ? accent : colors.muted,
        ),
        trackColor: WidgetStatePropertyAll(raised),
        trackOutlineColor: WidgetStatePropertyAll(text.withValues(alpha: 0.16)),
        overlayColor: const WidgetStatePropertyAll(clear),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: text,
          foregroundColor: page,
          disabledBackgroundColor: raised,
          disabledForegroundColor: colors.muted,
          minimumSize: buttonSize,
          padding: buttonPadding,
          shape: control,
          textStyle: type.labelLarge,
          iconSize: 16,
          animationDuration: ProxieMotion.duration,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: raised,
          foregroundColor: text,
          disabledForegroundColor: colors.muted,
          side: side,
          minimumSize: buttonSize,
          padding: buttonPadding,
          shape: control,
          textStyle: type.labelLarge,
          iconSize: 16,
          animationDuration: ProxieMotion.duration,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: text,
          disabledForegroundColor: colors.muted,
          iconColor: secondary,
          minimumSize: buttonSize,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: control,
          textStyle: type.labelLarge,
          iconSize: 16,
          animationDuration: ProxieMotion.duration,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: secondary,
          disabledForegroundColor: colors.muted,
          iconSize: 18,
          shape: control,
          animationDuration: ProxieMotion.duration,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: text,
        foregroundColor: page,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        iconSize: 18,
        sizeConstraints: const BoxConstraints.tightFor(width: 40, height: 40),
        shape: control,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        selectedIcon: const Icon(Icons.check, size: 16),
        style: ButtonStyle(
          minimumSize: const WidgetStatePropertyAll(buttonSize),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12),
          ),
          shape: WidgetStatePropertyAll(control),
          side: WidgetStatePropertyAll(side),
          textStyle: WidgetStatePropertyAll(type.bodyMedium),
          iconSize: const WidgetStatePropertyAll(16),
          animationDuration: ProxieMotion.duration,
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected) ? raised : clear,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.selected) ? text : secondary,
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        iconColor: secondary,
        titleTextStyle: type.bodyLarge?.copyWith(color: text),
        subtitleTextStyle: type.bodySmall?.copyWith(color: secondary),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        tilePadding: const EdgeInsets.symmetric(horizontal: 12),
        shape: const Border(),
        collapsedShape: const Border(),
        iconColor: secondary,
        collapsedIconColor: secondary,
        textColor: text,
        collapsedTextColor: text,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: clear,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: side,
        ),
        titleTextStyle: type.titleLarge?.copyWith(color: text),
        contentTextStyle: type.bodyLarge?.copyWith(color: secondary),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: card,
        surfaceTintColor: clear,
        elevation: 0,
        dragHandleColor: colors.muted,
        dragHandleSize: const Size(32, 4),
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          side: side,
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: card,
        surfaceTintColor: clear,
        elevation: 4,
        shadowColor: const Color(0x66000000),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: side,
        ),
        iconSize: 18,
        iconColor: secondary,
        textStyle: type.bodyMedium?.copyWith(color: text),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: raised,
        contentTextStyle: type.bodyMedium?.copyWith(color: text),
        actionTextColor: accent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: side,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: raised,
          borderRadius: BorderRadius.circular(6),
          border: Border.fromBorderSide(side),
        ),
        textStyle: type.bodySmall?.copyWith(color: text),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      ),
      extensions: [colors],
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
