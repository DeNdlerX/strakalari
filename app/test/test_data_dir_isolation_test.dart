import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  test('data dir is isolated under the system temp folder', () {
    final dir = Directory(getUserDataDir()).resolveSymbolicLinksSync();
    final temp = Directory.systemTemp.resolveSymbolicLinksSync();
    expect(dir.startsWith(temp), isTrue, reason: dir);
    expect(getenv('STRAKALARI_NO_KEYRING'), '1');
  });
}
