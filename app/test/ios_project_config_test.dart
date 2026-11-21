import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('F5 iOS project configuration', () {
    test('Runner bundle id matches D5 (io.github.dendlerx.strakalari)', () {
      final pbxproj =
          File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      final matches = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);')
          .allMatches(pbxproj)
          .map((m) => m.group(1)!.trim())
          .toList();
      expect(matches, isNotEmpty);
      expect(
        matches.where((id) => id == 'io.github.dendlerx.strakalari').length,
        3,
        reason: 'Debug, Release, and Profile Runner configs must use D5 bundle id',
      );
      expect(
        matches
            .where((id) => id == 'io.github.dendlerx.strakalari.RunnerTests')
            .length,
        3,
      );
      expect(
        matches.where((id) => id.contains('.app')),
        isEmpty,
        reason: 'Default flutter create bundle id must be replaced',
      );
    });

    test('Info.plist sets Strakaláři display name and contains only used keys',
        () {
      final plist = File('ios/Runner/Info.plist')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(
        plist,
        contains('<key>CFBundleDisplayName</key>\n\t<string>Strakaláři</string>'),
      );
      expect(plist, contains('<key>CFBundleLocalizations</key>'));
      expect(plist, contains('<string>cs</string>'));
      expect(plist, contains('<string>en</string>'));
      // Unused permissions/background modes/ATS overrides must not be added.
      for (final unused in [
        'NSCalendarsUsageDescription',
        'NSCameraUsageDescription',
        'NSPhotoLibraryUsageDescription',
        'NSLocationWhenInUseUsageDescription',
        'UIBackgroundModes',
        'BGTaskSchedulerPermittedIdentifiers',
        'NSAppTransportSecurity',
      ]) {
        expect(plist, isNot(contains(unused)), reason: 'Unused Info.plist key $unused');
      }
    });

    test('AppDelegate registers strakalari/ios Keychain channel with background-readable accessibility',
        () {
      final swift = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      expect(swift, contains('import Security'));
      expect(swift, contains('name: "strakalari/ios"'));
      expect(swift, contains('case "keychainGet":'));
      expect(swift, contains('case "keychainSet":'));
      expect(swift, contains('case "keychainDelete":'));
      expect(
        swift,
        contains('kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly'),
        reason: 'Keychain accessibility must allow background reads after first unlock',
      );
      expect(swift, contains('didInitializeImplicitFlutterEngine'));
    });

    test('AppIcon.appiconset contains every PNG referenced by Contents.json', () {
      const dir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
      final contents = jsonDecode(File('$dir/Contents.json').readAsStringSync())
          as Map<String, Object?>;
      final images = (contents['images']! as List).cast<Map<String, Object?>>();
      expect(images, isNotEmpty);
      for (final img in images) {
        final name = img['filename']! as String;
        final f = File('$dir/$name');
        expect(f.existsSync(), isTrue, reason: 'Missing icon $name');
        expect(f.lengthSync(), greaterThan(100), reason: 'Empty icon $name');
      }
    });
  });
}
