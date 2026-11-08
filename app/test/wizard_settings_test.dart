import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/settings/settings_controller.dart';

/// Settings half of test_wizard_setup: credential gating.
void main() {
  SettingsController blank() => SettingsController({
        'bakalari_url': '',
        'bakalari_username': '',
        'bakalari_password': '',
        'strava_username': '',
        'strava_password': '',
        'strava_canteen_id': '',
        'gemini_api_key': '',
      });

  group('wizard_settings', () {
    test('needs setup fresh', () {
      final c = blank();
      expect(c.needsSetup(), isTrue);
      expect(c.hasBakalariCredentials(), isFalse);
      expect(c.hasStravaCredentials(), isFalse);
      expect(c.hasAnyCredentials(), isFalse);
    });

    test('needs setup false with bakalari', () {
      final c = blank()
        ..config.addAll({
          'bakalari_url': 'https://skola.bakalari.cz',
          'bakalari_username': 'novak',
          'bakalari_password': 'x',
        });
      expect(c.hasBakalariCredentials(), isTrue);
      expect(c.hasAnyCredentials(), isTrue);
      expect(c.needsSetup(), isFalse);
    });

    test('needs setup false with strava only', () {
      final c = blank()
        ..config.addAll({
          'strava_username': 'novak',
          'strava_password': 'x',
          'strava_canteen_id': '123',
        });
      expect(c.hasBakalariCredentials(), isFalse);
      expect(c.hasStravaCredentials(), isTrue);
      expect(c.hasAnyCredentials(), isTrue);
      expect(c.needsSetup(), isFalse);
    });

    test('partial credentials still need setup', () {
      final c = blank()
        ..config.addAll({
          'bakalari_url': 'https://skola.bakalari.cz',
          'bakalari_username': 'novak',
        });
      expect(c.needsSetup(), isTrue);
    });

    test('strava flag defaults on', () {
      expect(blank().stravaEnabledFlag(), isTrue);
      expect(
          SettingsController(
              {'use_strava': false}).stravaEnabledFlag(),
          isFalse);
    });
  });
}
