import 'package:flutter/material.dart';

import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../shell/theme.dart';

// One token table: `Tokens` (shell/theme.dart), ported from
// `strakalari/flet_ui/theme.py`. `AppTokens` is kept as another name for it
// so feature code and tests read the same way; there is no second set of
// values to drift.
export '../../shell/theme.dart' show Tokens, statusColor;

typedef AppTokens = Tokens;

/// `#RRGGBB` at `alpha` opacity — the same RGB with an alpha channel,
/// exactly like `theme.tint`.
Color tintColor(Color color, double alpha) {
  // Python `round()`: halves go to even (`theme.tint`).
  final a = core.roundHalfEvenToInt(alpha.clamp(0.0, 1.0) * 255);
  return Color.fromARGB(
    a,
    (color.r * 255).round().clamp(0, 255),
    (color.g * 255).round().clamp(0, 255),
    (color.b * 255).round().clamp(0, 255),
  );
}

/// The token set of the running theme (light or dark).
Tokens tokensOf(BuildContext context) =>
    Tokens.of(Theme.of(context).brightness);
