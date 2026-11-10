// Parity tests for AppState theme tokens, compact density, forced theme,
// and startup language initialization (port of strakalari/flet_ui/state.py
// `_refresh_tokens`, Checkpoint B B-M9).

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

void main() {
  tearDown(() {
    core.setLanguage('cs');
    Strings.lang = 'cs';
  });

  group('Tokens and Compact Density', () {
    test('compactDensityFalseByDefault', () {
      final state = AppState();
      expect(state.densityCompact, isFalse);
      expect(state.tok.pad, 16.0);
      expect(state.tok.gap, 12.0);
      expect(state.appTokens.pad, 16.0);
      expect(state.appTokens.gap, 12.0);
    });

    test('compactDensityTrueAppliesSmallerPadAndGap', () {
      final state = AppState(configData: {'compact_density': true});
      expect(state.densityCompact, isTrue);
      expect(state.tok.pad, 10.0);
      expect(state.tok.gap, 8.0);
      expect(state.appTokens.pad, 10.0);
      expect(state.appTokens.gap, 8.0);
    });

    test('compactDensityToggleViaSave', () {
      final state = AppState();
      expect(state.tok.pad, 16.0);
      expect(state.tok.gap, 12.0);

      final ok1 = state.save({'compact_density': true});
      expect(ok1, isTrue);
      expect(state.densityCompact, isTrue);
      expect(state.tok.pad, 10.0);
      expect(state.tok.gap, 8.0);
      expect(state.appTokens.pad, 10.0);
      expect(state.appTokens.gap, 8.0);

      final ok2 = state.save({'compact_density': false});
      expect(ok2, isTrue);
      expect(state.densityCompact, isFalse);
      expect(state.tok.pad, 16.0);
      expect(state.tok.gap, 12.0);
      expect(state.appTokens.pad, 16.0);
      expect(state.appTokens.gap, 12.0);
    });
  });

  group('Forced STRAKALARI_THEME and Theme Switching', () {
    test('forcedThemeLightOverridesConfigThemeDark', () {
      final state = AppState(configData: {'theme': 'dark'});
      state.envOverride = {'STRAKALARI_THEME': 'light'};
      state.refreshTokens();

      expect(state.tok.mode, 'light');
      expect(state.appTokens.isDark, isFalse);
    });

    test('forcedThemeDarkOverridesConfigThemeLight', () {
      final state = AppState(configData: {'theme': 'light'});
      state.envOverride = {'STRAKALARI_THEME': 'dark'};
      state.refreshTokens();

      expect(state.tok.mode, 'dark');
      expect(state.appTokens.isDark, isTrue);
    });

    test('invalidForcedThemeIgnoredInFavorOfConfig', () {
      final state = AppState(configData: {'theme': 'light'});
      state.envOverride = {'STRAKALARI_THEME': 'invalid_mode'};
      state.refreshTokens();

      expect(state.tok.mode, 'light');
      expect(state.appTokens.isDark, isFalse);
    });

    test('themeChangeViaSaveUpdatesTokAndAppTokens', () {
      final state = AppState(configData: {'theme': 'dark'});
      state.envOverride = {};
      state.refreshTokens();

      expect(state.tok.mode, 'dark');
      expect(state.appTokens.isDark, isTrue);

      final ok1 = state.setTheme('light');
      expect(ok1, isTrue);
      expect(state.tok.mode, 'light');
      expect(state.appTokens.isDark, isFalse);

      final ok2 = state.setTheme('dark');
      expect(ok2, isTrue);
      expect(state.tok.mode, 'dark');
      expect(state.appTokens.isDark, isTrue);
    });
  });

  group('Language Initialization at Startup', () {
    test('englishLanguageInitializedAtStartupWithoutSave', () {
      // Simulate startup with English in config
      final state = AppState(configData: {'language': 'en'});

      expect(core.getLanguage(), 'en');
      expect(Strings.lang, 'en');

      // Cache description should format in English
      final label = core.describeCache({
        'last_updated': DateTime.now().toUtc().toIso8601String(),
      }, 24);
      expect(label.toLowerCase(), contains('just now'));
    });

    test('czechLanguageInitializedAtStartupByDefault', () {
      final state = AppState();

      expect(core.getLanguage(), 'cs');
      expect(Strings.lang, 'cs');

      final label = core.describeCache({
        'last_updated': DateTime.now().toUtc().toIso8601String(),
      }, 24);
      expect(label.toLowerCase(), contains('právě teď'));
    });

    test('languageSwitchViaSaveUpdatesCoreAndStrings', () {
      final state = AppState();
      expect(core.getLanguage(), 'cs');

      final ok1 = state.setLanguage('en');
      expect(ok1, isTrue);
      expect(core.getLanguage(), 'en');
      expect(Strings.lang, 'en');

      final ok2 = state.setLanguage('cs');
      expect(ok2, isTrue);
      expect(core.getLanguage(), 'cs');
      expect(Strings.lang, 'cs');
    });
  });
}
