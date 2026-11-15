// Keep version numbers in sync across pubspec, update.dart, and installer.
//
// Port of tests/test_version_sync.py.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

File _repoFile(String relPath) {
  final candidates = [
    File(relPath),
    File('../$relPath'),
    File('../../$relPath'),
  ];
  for (final f in candidates) {
    if (f.existsSync()) return f;
  }
  throw StateError('Cannot locate $relPath from ${Directory.current.path}');
}

String _packageVersion() => stampedAppVersion;

void main() {
  test('pubspecMatchesPackage', () {
    final text = _repoFile('app/pubspec.yaml').readAsStringSync();
    final m = RegExp(
      r'^version:\s*(\S+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(text);
    expect(
      m,
      isNotNull,
      reason: 'version: <ver>+<code> not found in app/pubspec.yaml',
    );
    final version = _packageVersion();
    expect(m!.group(1), equals(version));
    expect(int.parse(m.group(2)!), equals(buildNumber(version)));
  });

  test('installerDefaultMatchesPackage', () {
    final text = _repoFile('installer.iss').readAsStringSync();
    final m = RegExp(
      r'#define\s+MyAppVersion\s+"([^"]+)"',
    ).firstMatch(text);
    expect(m, isNotNull, reason: 'MyAppVersion not found in installer.iss');
    expect(m!.group(1), equals(_packageVersion()));
  });
}
