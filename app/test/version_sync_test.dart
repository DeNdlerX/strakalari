// Port of tests/test_version_sync.py: the committed version must not
// drift between the places a local build reads it from. The Flutter app
// reads `app/pubspec.yaml` (build-name + Android versionCode) and the Inno
// installer's default; the Python package version stays the reference.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

String _read(String repoPath) => File('../$repoPath').readAsStringSync();

String _packageVersion() =>
    RegExp(r'__version__ = "([^"]+)"').firstMatch(_read('strakalari/__init__.py'))!.group(1)!;

void main() {
  test('pubspecMatchesPackage', () {
    final m = RegExp(r'^version: (\S+)\+(\d+)$', multiLine: true).firstMatch(_read('app/pubspec.yaml'));
    expect(m, isNotNull);
    final version = _packageVersion();
    expect(m!.group(1), version);
    // versionCode as the Flet build stamped it (tools/make_mobile.py).
    expect(int.parse(m.group(2)!), buildNumber(version));
  });

  test('installerDefaultMatchesPackage', () {
    final m = RegExp(r'#define MyAppVersion "([^"]+)"').firstMatch(_read('installer.iss'));
    expect(m, isNotNull);
    expect(m!.group(1), _packageVersion());
  });
}
