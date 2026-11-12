// What carries over from tests/test_minimize_to_tray.py and
// tests/test_shutdown.py to the one-process Flutter app: the
// hide-to-tray setting is read at every close (the Settings toggle
// applies without a restart), macOS always hides (the tray cannot live in
// the window process there), and the installer stops only our own
// Strakalari.exe tree before installing.
import 'dart:io';

import 'package:app/platform/desktop/tray.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settingIsReadAtEveryClose', () {
    var minimize = false;
    final tray = DesktopTrayController(hideToTraySetting: () => minimize);
    expect(tray.hideToTray, Platform.isMacOS); // off: X quits (except macOS)
    minimize = true;
    expect(tray.hideToTray, isTrue); // switched on later: X hides
    minimize = false;
    expect(tray.hideToTray, Platform.isMacOS);
  });

  test('macosHasNoEmbeddedTray', () {
    expect(embeddedTraySupported, !Platform.isMacOS);
    expect(trayHostsWindow, Platform.isMacOS);
  });

  test('installerShutsDownAppBeforeInstall', () {
    final iss = File('../installer.iss').readAsStringSync();
    expect(iss, contains('function PrepareToInstall'));
    // /T takes the whole tree.
    expect(iss, contains('/F /T /IM Strakalari.exe'));
    // No generic flet.exe sweep: that image name matches other Flet apps.
    expect(iss, isNot(contains('/IM flet.exe')));
  });
}
