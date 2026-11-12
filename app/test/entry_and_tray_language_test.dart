// Ports of tests/test_entry_routing.py (the two routing cases) and
// tests/test_tray_language.py. One process in Flutter: `--minimized`
// starts the window hidden in the tray instead of a separate tray
// process; the tray labels come from the configured language.
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/platform/startup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  test('defaultRoutesToTheWindow', () {
    expect(launchMinimized(['strakalari']), isFalse);
    expect(launchMinimized([]), isFalse);
  });

  test('minimizedRoutesToTray', () {
    expect(launchMinimized(['--minimized']), isTrue);
    expect(launchMinimized(['strakalari', '--minimized']), isTrue);
  });

  test('trayUsesConfiguredLanguage', () {
    final dir = Directory.systemTemp.createTempSync('tray_lang_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path, 'STRAKALARI_NO_KEYRING': '1'});
    setLanguage('cs');
    Strings.lang = 'cs';
    try {
      AppState(configData: {'language': 'en'}, data: {});
      expect(getLanguage(), 'en');
      expect(trayStrings().quit, 'Quit');
    } finally {
      setLanguage('cs');
      Strings.lang = 'cs';
      setEnvironmentOverride(null);
      dir.deleteSync(recursive: true);
    }
  });
}
