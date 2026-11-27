// Port of tests/test_autostart.py (3) and tests/test_autostart_platforms.py
// (5). Never touches the real registry or home: Windows gets a fake Run
// key, macOS/Linux a temporary HOME (like Python's fixtures).
import 'dart:io';

import 'package:app/platform/desktop/autostart.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRunKey implements RunKeyRegistry {
  FakeRunKey({this.fail = false});
  final bool fail;
  final Map<String, String> values = {};

  @override
  String? query(String name) {
    if (fail) throw const RunKeyUnavailable('denied');
    return values[name];
  }

  @override
  void set(String name, String value) {
    if (fail) throw const RunKeyUnavailable('denied');
    values[name] = value;
  }

  @override
  void delete(String name) {
    if (fail) throw const RunKeyUnavailable('denied');
    values.remove(name);
  }
}

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('autostart_');
    autostartEnvOverride = {
      'HOME': home.path,
      'USERPROFILE': home.path,
      'APPDATA': '${home.path}${Platform.pathSeparator}AppData',
    };
  });

  tearDown(() {
    autostartPlatformOverride = null;
    autostartRegistryOverride = null;
    autostartEnvOverride = null;
    autostartExecutableOverride = null;
    home.deleteSync(recursive: true);
  });

  group('TestAutostart', () {
    test('getLaunchCommandMinimized', () {
      expect(getLaunchCommand(minimized: true), contains('--minimized'));
    });

    test('getLaunchCommandNotMinimized', () {
      expect(getLaunchCommand(minimized: false), isNot(contains('--minimized')));
    });
  });

  group('TestRoutingAndLaunch', () {
    test('launchCommandHasNoShellQuotes', () {
      final cmd = getLaunchCommand(minimized: true);
      expect(cmd, contains('--minimized'));
      expect(cmd, isNot(contains("'")));
    });
  });

  group('TestWindows', () {
    late FakeRunKey reg;
    setUp(() {
      reg = FakeRunKey();
      autostartPlatformOverride = 'win32';
      autostartRegistryOverride = reg;
    });

    test('roundTrip', () {
      expect(isAutostartEnabled(), isFalse);
      expect(setAutostart(true), isTrue);
      expect(reg.values['Strakalari'], contains('--minimized'));
      expect(isAutostartEnabled(), isTrue);
      expect(setAutostart(false), isTrue);
      expect(isAutostartEnabled(), isFalse);
      // Disabling twice is not an error.
      expect(setAutostart(false), isTrue);
    });

    test('legacyStartupShortcutCountsAndIsAdopted', () {
      final lnk = File(startupShortcutPath());
      lnk.parent.createSync(recursive: true);
      lnk.writeAsStringSync('');
      expect(isAutostartEnabled(), isTrue);
      expect(setAutostart(true), isTrue);
      expect(lnk.existsSync(), isFalse); // the Run value is the only source now
    });

    test('registryFailureReportsFalse', () {
      autostartRegistryOverride = FakeRunKey(fail: true);
      expect(setAutostart(true), isFalse);
    });
  });

  group('TestMacOS', () {
    test('roundTripWritesAnEscapedPlist', () {
      autostartPlatformOverride = 'darwin';
      autostartExecutableOverride = '/Apps/A & B/python';
      expect(setAutostart(true), isTrue);
      final plist = File('${home.path}/Library/LaunchAgents/cz.strakalari.app.plist');
      final text = plist.readAsStringSync();
      expect(text, contains('<string>/Apps/A &amp; B/python</string>'));
      expect(text, contains('<string>--minimized</string>'));
      expect(isAutostartEnabled(), isTrue);
      expect(setAutostart(false), isTrue);
      expect(plist.existsSync(), isFalse);
    });
  });

  group('TestLinux', () {
    test('roundTripQuotesPathsWithSpaces', () {
      autostartPlatformOverride = 'linux';
      autostartExecutableOverride = '/opt/my apps/python';
      expect(setAutostart(true, minimized: false), isTrue);
      final entry = File('${home.path}/.config/autostart/strakalari.desktop');
      final text = entry.readAsStringSync();
      expect(text, contains('Exec="/opt/my apps/python"'));
      expect(text, isNot(contains('--minimized')));
      expect(isAutostartEnabled(), isTrue);
      expect(setAutostart(false), isTrue);
      expect(entry.existsSync(), isFalse);
    });

    test('usesAppImageEnvOverMountExecutableWhenFileExists', () {
      autostartPlatformOverride = 'linux';
      autostartExecutableOverride = '/tmp/.mount_StrakX123/usr/bin/strakalari';

      final appImage = File('${home.path}/Apps/Strakalari.AppImage')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
      autostartEnvOverride = {
        ...autostartEnvOverride!,
        'APPIMAGE': appImage.path,
      };
      expect(setAutostart(true, minimized: true), isTrue);
      final entry = File('${home.path}/.config/autostart/strakalari.desktop');
      expect(entry.readAsStringSync(),
          contains('Exec=${appImage.path} --minimized'));

      // AppImage path containing spaces is double-quoted.
      final spacedImage = File('${home.path}/My Apps/Strakalari.AppImage')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('');
      autostartEnvOverride = {
        ...autostartEnvOverride!,
        'APPIMAGE': spacedImage.path,
      };
      expect(setAutostart(true, minimized: true), isTrue);
      expect(entry.readAsStringSync(),
          contains('Exec="${spacedImage.path}" --minimized'));

      // Missing APPIMAGE target falls back to resolvedExecutable.
      autostartEnvOverride = {
        ...autostartEnvOverride!,
        'APPIMAGE': '${home.path}/Apps/missing.AppImage',
      };
      expect(setAutostart(true, minimized: true), isTrue);
      expect(entry.readAsStringSync(),
          contains('Exec=/tmp/.mount_StrakX123/usr/bin/strakalari --minimized'));
    });
  });
}
