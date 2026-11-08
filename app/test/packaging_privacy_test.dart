// APK/AAB privacy check: no personal file may ever be bundled into a build.
//
// Port of `tests/test_packaging_privacy.py`. The frozen desktop app and the
// installer are built from a checkout that usually holds a real config.json,
// secret.key, cache and scraped pages next to the sources; the same holds
// for `flutter build apk/appbundle`, which packages the whole app folder.
//
// What runs without artifacts (always): the personal-name pattern, the
// manifest/package-identity assertions and the signing-config assertion.
// The built-artifact scan runs only when `STRAKALARI_APK` (or
// `STRAKALARI_AAB`, or both) points at a file; otherwise it is skipped.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The same personal-file names `tests/test_packaging_privacy.py` and
/// `tools/make_mobile.py` guard (plus the mobile-only extras).
final RegExp personal = RegExp(
  r'(^|[\\/])(config\.json|secret\.key|data_cache\.json|update_cache\.json'
  r'|log\.txt|console\.log|strava_blacklist\.json|already_excused_lessons\.json'
  r'|already_excused_lessons\.unconfirmed\.json|automation_history\.jsonl'
  r'|instance\.token|htmls)([\\/]|$)',
  caseSensitive: false,
);

/// Names that must never appear as whole path segments of a build input.
const List<String> personalNames = [
  'config.json',
  'secret.key',
  'data_cache.json',
  'update_cache.json',
  'log.txt',
  'strava_blacklist.json',
  'already_excused_lessons.json',
  'automation_history.jsonl',
  'htmls',
];

/// Fails when [bytes] mention a personal file name or a build-machine path.
List<String> privacyLeaks(List<int> bytes, {List<String> extraMarkers = const []}) {
  final leaks = <String>[];
  // ZIP entry names are stored plainly; nested zips too (APK/AAB are zips
  // of zips). A flat byte scan catches all of them without a zip reader.
  final text =
      String.fromCharCodes(bytes.where((b) => b < 128))
          .replaceAll(RegExp(r'[^A-Za-z0-9._\-/\\]'), '/');
  String norm(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9._\-/\\]'), '/');
  for (final name in personalNames) {
    if (RegExp('(^|[\\\\/])${RegExp.escape(name)}([\\\\/]|\\\$)',
            caseSensitive: false)
        .hasMatch(text)) {
      leaks.add(name);
    }
  }
  for (final marker in extraMarkers) {
    if (marker.isNotEmpty && text.contains(norm(marker))) leaks.add(marker);
  }
  return leaks;
}

void main() {
  group('packaging_privacy', () {
    test('pattern catches personal files, ignores the templates', () {
      for (final name in personalNames) {
        expect(personal.hasMatch(name), isTrue, reason: name);
        expect(personal.hasMatch('assets/$name'), isTrue, reason: name);
      }
      expect(personal.hasMatch('config.example.json'), isFalse);
      expect(personal.hasMatch('already_excused_lessons.example.json'), isFalse);
      expect(personal.hasMatch('lib/main.dart'), isFalse);
    });

    test('byte scan finds nested personal files and path markers', () {
      final clean = 'assets/logo.png\x00lib/main.dart\x00'.codeUnits;
      expect(privacyLeaks(clean), isEmpty);
      final nested =
          'assets/app.zip\x00config.json\x00secret.key\x00'.codeUnits;
      final found = privacyLeaks(nested);
      expect(found, contains('config.json'));
      expect(found, contains('secret.key'));
      final leaked = '/Users/someone/build/httpx/_client.pyc'.codeUnits;
      expect(privacyLeaks(leaked, extraMarkers: ['/Users/someone/build']),
          isNotEmpty);
    });

    test('release keeps the store identity, test flavor stays parallel', () {
      final gradle = File('android/app/build.gradle.kts');
      if (!gradle.existsSync()) return; // run from elsewhere: skip
      final text = gradle.readAsStringSync();
      expect(text, contains('applicationId = "io.github.dendlerx.strakalari"'));
      expect(text, contains('applicationIdSuffix = ".test"'));
      // Release signing reads the release key, never the debug key; the key
      // itself lives outside the repo and is never created here.
      expect(text, contains('.strakalari-signing'));
      expect(text, isNot(contains('storePassword = "')));
    });

    test('manifest has the background components and no personal paths', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml');
      if (!manifest.existsSync()) return; // run from elsewhere: skip
      final text = manifest.readAsStringSync();
      for (final component in [
        'KeepAliveService',
        'RefreshReceiver',
        'BootReceiver',
        'AlarmReceiver',
        'TimetableWidgetProvider',
      ]) {
        expect(text, contains(component), reason: component);
      }
      expect(personal.hasMatch(text), isFalse);
      expect(text.contains('/Users/') || text.contains('C:\\'), isFalse);
    });

    test('built APK/AAB carries no personal files', () {
      final paths = [
        Platform.environment['STRAKALARI_APK'],
        Platform.environment['STRAKALARI_AAB'],
      ].whereType<String>().where((p) => p.isNotEmpty).toList();
      if (paths.isEmpty) {
        markTestSkipped('Set STRAKALARI_APK/AAB to scan a built artifact.');
      }
      for (final path in paths) {
        final bytes = File(path).readAsBytesSync();
        expect(privacyLeaks(bytes), isEmpty, reason: path);
      }
    }, skip: Platform.environment['STRAKALARI_APK'] == null &&
        Platform.environment['STRAKALARI_AAB'] == null);
  });
}
