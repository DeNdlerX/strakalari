// C-S2: `atomicWriteJson` takes its temp file like `tempfile.mkstemp`
// (own name per writer), so two isolates of one process (the phone's UI
// and a headless wake-up) never write into the same temp file.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:strakalari_core/strakalari_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('atomic_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('mkstempGivesEveryCallerItsOwnNewFile', () {
    final names = {for (var i = 0; i < 50; i++) mkstemp(dir.path, suffix: '.tmp')};
    expect(names, hasLength(50));
    for (final name in names) {
      expect(p.basename(name), matches(RegExp(r'^tmp[a-z0-9_]{8}\.tmp$')));
      expect(File(name).lengthSync(), 0);
    }
  });

  test('twoIsolatesWritingOneFileLeaveValidJsonAndNoTempFiles', () async {
    final path = p.join(dir.path, 'data_cache.json');
    Future<void> writer(int id) => Isolate.run(() {
          for (var i = 0; i < 100; i++) {
            try {
              atomicWriteJson(path, {'writer': id, 'i': i, 'pad': 'x' * 2000});
            } on FileSystemException {
              // Windows may refuse a rename while the other one runs
              // (Python's os.replace too); real writers hold a lock.
            }
          }
        });
    await Future.wait([writer(1), writer(2)]);
    // Never a torn or mixed file: the last write that won is whole.
    final data = jsonDecode(File(path).readAsStringSync()) as Map;
    expect(data['pad'], 'x' * 2000);
    expect(data['writer'], anyOf(1, 2));
    expect(dir.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
  });
}
