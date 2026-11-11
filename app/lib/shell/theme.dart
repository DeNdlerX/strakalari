// Design tokens — the single source of truth for the whole UI.
//
// Port of strakalari/flet_ui/theme.py. Both themes are first-class
// citizens: every screen reads colors only from [tokens] for the active
// mode. Nothing outside this module may contain a hardcoded color,
// radius, or spacing value.
//
// Scale: 8pt base grid. Type: system font stack, 6 sizes.
import 'package:flutter/material.dart';

/// Token set for one color mode. Field-for-field port of `Tokens`.
@immutable
class Tokens {
  final String mode;
  // Surfaces (cards are the brightest layer in both modes).
  final Color bg;
  final Color surface;
  final Color card;
  final Color overlay;
  final Color border;
  // Text.
  final Color text;
  final Color muted;
  final Color faint;
  // Accent + semantics.
  final Color accent;
  final Color accentText;
  final Color green;
  final Color yellow;
  final Color red;
  final Color orange;
  final Color purple;
  // Geometry.
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double pad;
  final double gap;
  final double railWidth;
  // Type scale.
  final double fsTitle;
  final double fsSection;
  final double fsBody;
  final double fsSmall;
  final double fsTiny;

  const Tokens({
    required this.mode,
    required this.bg,
    required this.surface,
    required this.card,
    required this.overlay,
    required this.border,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.accentText,
    required this.green,
    required this.yellow,
    required this.red,
    required this.orange,
    required this.purple,
    this.radiusSm = 8,
    this.radiusMd = 12,
    this.radiusLg = 16,
    this.pad = 16,
    this.gap = 12,
    this.railWidth = 200,
    this.fsTitle = 20,
    this.fsSection = 15,
    this.fsBody = 13,
    this.fsSmall = 12,
    this.fsTiny = 11,
  });

  /// The dark set (theme.py `DARK`).
  factory Tokens.dark() => darkTokens;

  /// The light set (theme.py `LIGHT`).
  factory Tokens.light() => lightTokens;

  /// The set for [brightness].
  factory Tokens.of(Brightness brightness) =>
      brightness == Brightness.light ? lightTokens : darkTokens;

  Brightness get brightness =>
      mode == 'light' ? Brightness.light : Brightness.dark;

  bool get isDark => brightness == Brightness.dark;

  /// Returns a copy of this token set with the given fields replaced.
  /// Port of Python's `dataclasses.replace(tok, ...)`.
  Tokens copyWith({
    String? mode,
    Color? bg,
    Color? surface,
    Color? card,
    Color? overlay,
    Color? border,
    Color? text,
    Color? muted,
    Color? faint,
    Color? accent,
    Color? accentText,
    Color? green,
    Color? yellow,
    Color? red,
    Color? orange,
    Color? purple,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? pad,
    double? gap,
    double? railWidth,
    double? fsTitle,
    double? fsSection,
    double? fsBody,
    double? fsSmall,
    double? fsTiny,
  }) =>
      Tokens(
        mode: mode ?? this.mode,
        bg: bg ?? this.bg,
        surface: surface ?? this.surface,
        card: card ?? this.card,
        overlay: overlay ?? this.overlay,
        border: border ?? this.border,
        text: text ?? this.text,
        muted: muted ?? this.muted,
        faint: faint ?? this.faint,
        accent: accent ?? this.accent,
        accentText: accentText ?? this.accentText,
        green: green ?? this.green,
        yellow: yellow ?? this.yellow,
        red: red ?? this.red,
        orange: orange ?? this.orange,
        purple: purple ?? this.purple,
        radiusSm: radiusSm ?? this.radiusSm,
        radiusMd: radiusMd ?? this.radiusMd,
        radiusLg: radiusLg ?? this.radiusLg,
        pad: pad ?? this.pad,
        gap: gap ?? this.gap,
        railWidth: railWidth ?? this.railWidth,
        fsTitle: fsTitle ?? this.fsTitle,
        fsSection: fsSection ?? this.fsSection,
        fsBody: fsBody ?? this.fsBody,
        fsSmall: fsSmall ?? this.fsSmall,
        fsTiny: fsTiny ?? this.fsTiny,
      );

  /// Builds the Material [ThemeData] for this token set.
  ThemeData toThemeData({String? fontFamily}) {
    final scheme = ColorScheme(
      brightness: mode == 'light' ? Brightness.light : Brightness.dark,
      primary: accent,
      onPrimary: accentText,
      secondary: accent,
      onSecondary: accentText,
      error: red,
      onError: mode == 'light' ? const Color(0xFFFFFFFF) : const Color(0xFF0F1115),
      surface: surface,
      onSurface: text,
      surfaceContainerHighest: card,
      outline: border,
    );
    return ThemeData(
      fontFamily: fontFamily,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      cardColor: card,
      dividerColor: border,
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        foregroundColor: text,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: surface,
        indicatorColor: accent.withValues(alpha: 0.2),
        selectedIconTheme: IconThemeData(color: text),
        unselectedIconTheme: IconThemeData(color: muted),
        selectedLabelTextStyle:
            TextStyle(fontFamily: fontFamily, color: text, fontSize: fsSmall),
        unselectedLabelTextStyle:
            TextStyle(fontFamily: fontFamily, color: muted, fontSize: fsSmall),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: accent.withValues(alpha: 0.2),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: overlay,
        contentTextStyle: TextStyle(color: text),
      ),
      dialogTheme: DialogThemeData(backgroundColor: card),
      // Flet look: flat bordered cards, outlined filled inputs, pill buttons.
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        margin: EdgeInsets.zero,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: BorderSide(color: border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        isDense: false,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4),
          borderSide: BorderSide(color: accent, width: 2),
        ),
        labelStyle: TextStyle(fontFamily: fontFamily, color: muted, fontSize: fsBody),
        hintStyle: TextStyle(fontFamily: fontFamily, color: faint, fontSize: fsBody),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: accentText,
          elevation: 0,
          shadowColor: Colors.transparent,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
          textStyle: TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w500),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: accentText,
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
          textStyle: TextStyle(fontFamily: fontFamily, fontWeight: FontWeight.w500),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: text,
          side: BorderSide(color: faint),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          shape: const StadiumBorder(),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? accentText : faint),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : overlay),
        trackOutlineColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? accent : faint),
      ),
      textTheme: TextTheme(
        headlineSmall: TextStyle(color: text, fontSize: fsTitle),
        titleMedium: TextStyle(color: text, fontSize: fsSection),
        bodyMedium: TextStyle(color: text, fontSize: fsBody),
        bodySmall: TextStyle(color: muted, fontSize: fsSmall),
        labelSmall: TextStyle(color: faint, fontSize: fsTiny),
      ),
      useMaterial3: true,
    );
  }
}

/// `#RRGGBB` tokens ported 1:1 from theme.py `DARK`.
const Tokens darkTokens = Tokens(
  mode: 'dark',
  bg: Color(0xFF0F1115),
  surface: Color(0xFF16191F),
  card: Color(0xFF1C2027),
  overlay: Color(0xFF2A2F39),
  border: Color(0xFF2E3440),
  text: Color(0xFFE8EAF0),
  muted: Color(0xFFA7ADBD),
  faint: Color(0xFF858C9B),
  accent: Color(0xFF7AA5F8),
  accentText: Color(0xFF0F1115),
  green: Color(0xFF8FD0A0),
  yellow: Color(0xFFE8C87A),
  red: Color(0xFFE88A9B),
  orange: Color(0xFFE8A87A),
  purple: Color(0xFFC4A5F5),
);

/// `#RRGGBB` tokens ported 1:1 from theme.py `LIGHT`.
const Tokens lightTokens = Tokens(
  mode: 'light',
  bg: Color(0xFFEEF1F6),
  surface: Color(0xFFF5F7FB),
  card: Color(0xFFFFFFFF),
  overlay: Color(0xFFE2E8F2),
  border: Color(0xFFC9D2E0),
  text: Color(0xFF131A26),
  muted: Color(0xFF4C5A72),
  faint: Color(0xFF6F7A90),
  accent: Color(0xFF2456D6),
  accentText: Color(0xFFFFFFFF),
  green: Color(0xFF177245),
  yellow: Color(0xFF9A6206),
  red: Color(0xFFC2243C),
  orange: Color(0xFFC2540A),
  purple: Color(0xFF6F2FC4),
);

/// `'light'` only for exactly `"light"` (case-insensitive); else `'dark'`.
/// Port of `normalize_mode()`.
String normalizeMode(String? mode) =>
    (mode ?? 'dark').toLowerCase() == 'light' ? 'light' : 'dark';

/// Active token set for [mode]. Port of `tokens()`.
Tokens tokensFor(String? mode) =>
    normalizeMode(mode) == 'light' ? lightTokens : darkTokens;

/// Semantic color for absence/status states. Port of `status_color()`.
Color statusColor(String status, Tokens tok) {
  switch (status) {
    case 'ok':
      return tok.green;
    case 'warning':
      return tok.yellow;
    case 'critical':
      return tok.red;
    case 'late':
      return tok.orange;
    case 'cancelled':
      return tok.muted;
    case 'pending':
      return tok.yellow;
    case 'sent':
      return tok.green;
    case 'failed':
      return tok.red;
    default:
      return tok.muted;
  }
}
