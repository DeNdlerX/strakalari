// The neutral-folder Android build (tool/android_build.dart): ports of
// `PERSONAL`, `build_path_markers`, `_package_entries` and `check_package`
// from tools/make_mobile.py (expected values printed by Python), and the
// staging copy.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/android_build.dart';

/// A zip with stored ([deflate] false) or deflated entries; a name ending
/// in `/` is a directory.
Uint8List zipOf(Map<String, List<int>> files, {bool deflate = false}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 0xff, v >> 8]);
  void u32(BytesBuilder b, int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, v >> 24]);
  for (final e in files.entries) {
    final name = ascii.encode(e.key);
    final dir = e.key.endsWith('/');
    final data = dir ? <int>[] : (deflate ? ZLibEncoder(raw: true).convert(e.value) : e.value);
    final method = (deflate && !dir) ? 8 : 0;
    final offset = out.length;
    u32(out, 0x04034b50); u16(out, 20); u16(out, 0); u16(out, method); u16(out, 0); u16(out, 0);
    u32(out, 0); u32(out, data.length); u32(out, e.value.length); u16(out, name.length); u16(out, 0);
    out.add(name); out.add(data);
    u32(central, 0x02014b50); u16(central, 20); u16(central, 20); u16(central, 0); u16(central, method);
    u16(central, 0); u16(central, 0); u32(central, 0); u32(central, data.length); u32(central, e.value.length);
    u16(central, name.length); u16(central, 0); u16(central, 0); u16(central, 0); u16(central, 0);
    u32(central, 0); u32(central, offset); central.add(name);
  }
  final cdOffset = out.length;
  final cd = central.toBytes();
  out.add(cd);
  u32(out, 0x06054b50); u16(out, 0); u16(out, 0); u16(out, files.length); u16(out, files.length);
  u32(out, cd.length); u32(out, cdOffset); u16(out, 0);
  return out.toBytes();
}

void main() {
  test('personalPatternMatchesPython', () {
    final cases = {
      'config.json': true,
      'app/secret.key': true,
      'x/htmls/a': true,
      'config.example.json': false,
      'lib/main.dart': false,
      'already_excused_lessons.unconfirmed.json': true,
      'HTMLS': true,
    };
    cases.forEach((name, hit) => expect(personalFiles.hasMatch(name), hit, reason: name));
  });

  test('buildPathMarkersMatchPython', () {
    expect(buildPathMarkers([r'C:\Users\Novak', r'D:\src\strakalari'], env: {}), [
      'c:/users/novak', r'c:\\users\\novak', r'c:\users\novak',
      'd:/src/strakalari', r'd:\\src\\strakalari', r'd:\src\strakalari',
    ]);
    expect(buildPathMarkers([r'C:\Users\Novak'], env: {'GITHUB_ACTIONS': 'true'}), isEmpty);
  }, skip: Platform.isWindows ? false : 'Windows paths are absolute only on Windows');

  test('checkPackageFindsPersonalFilesAndPathsInNestedZips', () {
    final inner = zipOf({'assets/secret.key': [1], 'ok.txt': ascii.encode('fine')}, deflate: true);
    final apk = zipOf({
      'lib/': [],
      'lib/arm64-v8a/libapp.so': ascii.encode('xx file:///C:/Users/Novak/src/app/.dart_tool/r.dart xx'),
      'assets/app.zip': inner,
      'res/a.png': [0, 1, 2],
    });
    final r = checkPackage(apk, [r'c:/users/novak']);
    expect(r.leaked, ['assets/app.zip!assets/secret.key']);
    expect(r.paths, ['lib/arm64-v8a/libapp.so']);
  });

  test('aFileNameInsideCodeIsNotAPersonalFile', () {
    // Python reads the file list, not the bytes: compiled code may name
    // `secret.key` without the package holding such a file.
    final apk = zipOf({'lib/arm64-v8a/libapp.so': ascii.encode('open secret.key and config.json')});
    final r = checkPackage(apk, const []);
    expect(r.leaked, isEmpty);
    expect(r.paths, isEmpty);
  });

  test('stageMustBeOutsideHomeAndRepo', () {
    final home = p.join(Directory.systemTemp.path, 'h');
    expect(stageInside(p.join(home, 'x'), [home]), isTrue);
    expect(stageInside(home, [home]), isTrue);
    expect(stageInside(p.join(Directory.systemTemp.path, 'neutral'), [home]), isFalse);
  });

  test('stagingCopiesTheSourcesWithoutBuildOutputsOrMachineFiles', () {
    final root = Directory.systemTemp.createTempSync('stage_');
    try {
      final repo = p.join(root.path, 'repo');
      void put(String rel, [String text = 'x']) {
        File(p.join(repo, rel))
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(text);
      }

      for (final f in ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml',
          'packages/strakalari_core/lib/a.dart', 'app/lib/main.dart', 'app/android/app/build.gradle.kts',
          'app/build/out.apk', 'app/.dart_tool/x', 'app/android/local.properties',
          'config.json', 'strakalari/core/x.py', 'packages/strakalari_core/test/parity/config.json',
          'app/test/widget_test.dart']) {
        put(f);
      }
      final stage = p.join(root.path, 'stage');
      final copied = stageSources(repo, stage);
      expect(copied, [
        'analysis_options.yaml',
        'app/android/app/build.gradle.kts',
        'app/lib/main.dart',
        'packages/strakalari_core/lib/a.dart',
        'pubspec.lock',
        'pubspec.yaml',
      ]);
      // A personal file among the sources stops the build.
      put('app/secret.key');
      expect(() => stageSources(repo, stage), throwsStateError);
    } finally {
      root.deleteSync(recursive: true);
    }
  });
}
