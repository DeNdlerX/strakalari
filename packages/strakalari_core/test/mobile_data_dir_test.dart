// Port of TestDataDir (tests/test_mobile.py): the phone app keeps its data
// in the app's private storage; STRAKALARI_DATA_DIR still wins.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:strakalari_core/strakalari_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('mobile_dir_'));
  tearDown(() {
    setEnvironmentOverride(null);
    setMobileDataDir(null);
    tmp.deleteSync(recursive: true);
  });

  Map<String, String> android([Map<String, String> extra = const {}]) => {
        for (final e in Platform.environment.entries)
          if (e.key != 'STRAKALARI_DATA_DIR') e.key: e.value,
        'FLET_PLATFORM': 'android',
        ...extra,
      };

  test('appStorage', () {
    final target = p.join(tmp.path, 'app', 'data');
    setEnvironmentOverride(android({'FLET_APP_STORAGE_DATA': target}));
    expect(getUserDataDir(), target);
    expect(Directory(target).existsSync(), isTrue);
  });

  test('appStorageFromTheFlutterApp', () {
    // Flutter has no FLET_APP_STORAGE_DATA: the app registers
    // getApplicationSupportDirectory()/data at start-up.
    final target = p.join(tmp.path, 'support', 'data');
    setEnvironmentOverride(android());
    setMobileDataDir(target);
    expect(getUserDataDir(), target);
    expect(Directory(target).existsSync(), isTrue);
  });

  test('overrideStillWins', () {
    setEnvironmentOverride(android({
      'STRAKALARI_DATA_DIR': p.join(tmp.path, 'x'),
      'FLET_APP_STORAGE_DATA': p.join(tmp.path, 'y'),
    }));
    expect(getUserDataDir(), p.join(tmp.path, 'x'));
  });
}
