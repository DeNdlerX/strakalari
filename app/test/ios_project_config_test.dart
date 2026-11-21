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

    test('GitHub Actions dart.yml has SHA-pinned build-flutter-ios job gated like Android',
        () {
      final yml = File('../.github/workflows/dart.yml')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final start = yml.indexOf('  build-flutter-ios:\n');
      expect(start, greaterThan(0), reason: 'Missing build-flutter-ios job');
      final nextJob = yml.indexOf('\n  release-flutter:\n', start);
      expect(nextJob, greaterThan(start));
      final job = yml.substring(start, nextJob);

      expect(job, contains('needs: meta'));
      expect(job, contains("if: needs.meta.outputs.release == 'true'"));
      expect(job, contains('runs-on: macos-latest'));
      expect(job, contains('flutter build ios --release --no-codesign'));
      expect(job, contains('-ios-unsigned.ipa'));

      final usesMatches = RegExp(r'uses:\s*([^\s#]+)').allMatches(job).toList();
      expect(usesMatches.length, greaterThanOrEqualTo(3));
      for (final m in usesMatches) {
        final ref = m.group(1)!;
        expect(
          RegExp(r'^[^@]+@[0-9a-f]{40}$').hasMatch(ref),
          isTrue,
          reason: 'Action $ref in build-flutter-ios must be pinned to a 40-char commit SHA',
        );
      }
    });

    test('docs/IOS_SIDELOADING.md exists and covers key sideloading steps', () {
      final doc = File('../docs/IOS_SIDELOADING.md').readAsStringSync();
      expect(doc, contains('Sideloadly'));
      expect(doc, contains('Xcode'));
      expect(doc, contains('Developer Mode'));
      expect(doc, contains('7 days'));
      expect(doc, contains('14 days'));
      // R7 S4: an expired .ipa needs a new release; never reuse a released tag.
      expect(doc, contains('built only together with a new release'));
      expect(doc, contains("Never start a run with the tag of a version that's already out"));
      expect(doc, isNot(contains('start a new release run')));
      expect(doc, contains('Flutter 3.44.8'));
      expect(doc, contains('Generated.xcconfig'));
      expect(doc, contains('io.github.dendlerx.strakalari'));
      expect(doc, isNot(contains('push notifications')));
    });
  });
}
