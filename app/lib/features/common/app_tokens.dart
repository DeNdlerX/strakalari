import 'package:flutter/material.dart';

/// Theme tokens ported from `strakalari/flet_ui/theme.py`.
///
/// Same hex values for light and dark; `tint` matches `theme.tint`
/// (alpha-channel overlay of the same RGB), `statusColor` matches
/// `theme.status_color`.
@immutable
class AppTokens {
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color card;
  final Color overlay;
  final Color border;
  final Color text;
  final Color muted;
  final Color faint;
  final Color accent;
  final Color accentText;
  final Color green;
  final Color yellow;
  final Color red;
  final Color orange;
  final Color purple;

  // Type scale + geometry (theme.py: fs_title/section/body/small/tiny,
  // pad, gap, radius_sm/md/lg).
  final double fsTitle;
  final double fsSection;
  final double fsBody;
  final double fsSmall;
  final double fsTiny;
  final double pad;
  final double gap;
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;

  const AppTokens({
    required this.brightness,
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
    this.fsTitle = 20,
    this.fsSection = 15,
    this.fsBody = 13,
    this.fsSmall = 12,
    this.fsTiny = 11,
    this.pad = 16,
    this.gap = 12,
    this.radiusSm = 8,
    this.radiusMd = 12,
    this.radiusLg = 16,
  });

  /// Returns a copy of this token set with the given fields replaced.
  AppTokens copyWith({
    Brightness? brightness,
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
    double? fsTitle,
    double? fsSection,
    double? fsBody,
    double? fsSmall,
    double? fsTiny,
    double? pad,
    double? gap,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
  }) =>
      AppTokens(
        brightness: brightness ?? this.brightness,
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
        fsTitle: fsTitle ?? this.fsTitle,
        fsSection: fsSection ?? this.fsSection,
        fsBody: fsBody ?? this.fsBody,
        fsSmall: fsSmall ?? this.fsSmall,
        fsTiny: fsTiny ?? this.fsTiny,
        pad: pad ?? this.pad,
        gap: gap ?? this.gap,
        radiusSm: radiusSm ?? this.radiusSm,
        radiusMd: radiusMd ?? this.radiusMd,
        radiusLg: radiusLg ?? this.radiusLg,
      );

  bool get isDark => brightness == Brightness.dark;

  factory AppTokens.dark() => const AppTokens(
        brightness: Brightness.dark,
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

  factory AppTokens.light() => const AppTokens(
        brightness: Brightness.light,
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

  factory AppTokens.of(Brightness brightness) =>
      brightness == Brightness.light ? AppTokens.light() : AppTokens.dark();
}

/// `#RRGGBB` at `alpha` opacity — the same RGB with an alpha channel,
/// exactly like `theme.tint`.
Color tintColor(Color color, double alpha) {
  final a = (alpha.clamp(0.0, 1.0) * 255).round().clamp(0, 255);
  return Color.fromARGB(a, (color.r * 255).round().clamp(0, 255),
      (color.g * 255).round().clamp(0, 255), (color.b * 255).round().clamp(0, 255));
}

/// Semantic color for absence/status states — like `theme.status_color`.
/// Unknown kinds fall back to muted.
Color statusColor(String kind, AppTokens t) {
  switch (kind) {
    case 'ok':
      return t.green;
    case 'warning':
      return t.yellow;
    case 'critical':
      return t.red;
    case 'late':
      return t.orange;
    case 'cancelled':
      return t.muted;
    case 'pending':
      return t.yellow;
    case 'sent':
      return t.green;
    case 'failed':
      return t.red;
    default:
      return t.muted;
  }
}
