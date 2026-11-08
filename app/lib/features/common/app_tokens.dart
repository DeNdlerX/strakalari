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
  });

  // Type scale + geometry (theme.py: fs_title/section/body/small/tiny,
  // pad, gap, radius_sm/md/lg).
  double get fsTitle => 20;
  double get fsSection => 15;
  double get fsBody => 13;
  double get fsSmall => 12;
  double get fsTiny => 11;
  double get pad => 16;
  double get gap => 12;
  double get radiusSm => 8;
  double get radiusMd => 12;
  double get radiusLg => 16;

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
