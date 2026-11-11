// Every app test gets a throwaway data folder and no OS credential store.
//
// Port of tests/conftest.py `_isolated_data_dir`: without it
// `getUserDataDir()` resolves next to the test runner executable (the
// Flutter SDK folder) or, if that is not writable, the installed app's real
// data folder.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari-test-');
    setEnvironmentOverride({
      ...Platform.environment,
      'STRAKALARI_DATA_DIR': '${tmp.path}${Platform.pathSeparator}data',
      'STRAKALARI_NO_KEYRING': '1',
    });
  });
  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A lock file may still be open on Windows; the OS temp folder is
      // cleaned up later.
    }
  });
  await testMain();
}
