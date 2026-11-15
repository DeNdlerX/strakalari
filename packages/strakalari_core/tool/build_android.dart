// Builds the phone app's release APK or AAB from a neutral folder, then
// refuses it if it holds a personal file or a path of this machine.
// Flutter counterpart of `tools/make_mobile.py apk|aab` (see
// android_build.dart for why).
//
//   cd packages/strakalari_core
//   dart run tool/build_android.dart apk [--version 0.1.0] [--flavor prod]
//       [--stage DIR] [--out DIR] [-- <extra flutter build args>]
//
// The version defaults to app/pubspec.yaml's; the versionCode is
// `buildNumber(version)` like the Flet build. The result lands in
// `dist/flutter-android/Strakalari-<version>-android.apk` (or `.aab`).
// Signing comes from ~/.strakalari-signing/ or the STRAKALARI_SIGNING_*
// variables (build.gradle.kts); a prod build without the key stops there.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:strakalari_core/strakalari_core.dart' show buildNumber;

import 'android_build.dart';

Never _fail(String message) {
  stderr.writeln('build_android: $message');
  exit(1);
}

Future<void> main(List<String> argv) async {
  final dash = argv.indexOf('--');
  final args = dash < 0 ? argv : argv.sublist(0, dash);
  final extra = dash < 0 ? <String>[] : argv.sublist(dash + 1);
  if (args.isEmpty || !{'apk', 'appbundle'}.contains(args.first)) {
    _fail('usage: build_android.dart apk|appbundle [--version V] [--flavor prod|phonetest] '
        '[--stage DIR] [--out DIR] [-- flutter args]');
  }
  final kind = args.first;
  String? option(String name) {
    final i = args.indexOf(name);
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
  }

  // packages/strakalari_core/tool/ → the repo root.
  final repo = p.normalize(p.join(p.dirname(Platform.script.toFilePath()), '..', '..', '..'));
  final pubspecFile = File(p.join(repo, 'app', 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) _fail('repo root not found at $repo');
  var version = option('--version');
  if (version == null) {
    final m = RegExp(
      r'^version:\s*(\S+)\+\d+\s*$',
      multiLine: true,
    ).firstMatch(pubspecFile.readAsStringSync());
    if (m == null) {
      _fail('Could not find version: <ver>+<code> in app/pubspec.yaml');
    }
    version = m.group(1)!;
  }
  final int code;
  try {
    code = buildNumber(version);
  } on FormatException catch (e) {
    _fail(e.message);
  }
  final flavor = option('--flavor') ?? 'prod';
  final stage = p.normalize(p.absolute(option('--stage') ?? defaultStageDir()));
  final out = p.absolute(option('--out') ?? p.join(repo, 'dist', 'flutter-android'));
  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
  final roots = [if (home.isNotEmpty) home, repo];
  if (stageInside(stage, roots)) {
    _fail('the staging folder $stage is inside your home or the repo; its path would end up '
        'in the app. Pick one outside both with --stage.');
  }

  stdout.writeln('Staging the sources in $stage …');
  final copied = stageSources(repo, stage);
  stdout.writeln('  ${copied.length} files');

  final flutter = Platform.environment['FLUTTER'] ?? 'flutter';
  Future<void> run(List<String> cmd) async {
    stdout.writeln('> $flutter ${cmd.join(' ')}');
    final proc = await Process.start(flutter, cmd,
        workingDirectory: p.join(stage, 'app'), runInShell: true, mode: ProcessStartMode.inheritStdio);
    final rc = await proc.exitCode;
    if (rc != 0) _fail('flutter ${cmd.first} failed (exit $rc)');
  }

  await run(['pub', 'get', '--enforce-lockfile']);
  await run([
    'build', kind, '--release', '--flavor', flavor,
    '--build-name', version, '--build-number', '$code',
    '--dart-define=STRAKALARI_VERSION=$version',
    // One APK per ABI like Flet's `split_per_abi = true`: Flutter then adds
    // the same versionCode offset (arm64-v8a: +2000, 10099 -> 12099), so it
    // installs over the Flet GitHub APK. Only the arm64 one is shipped.
    if (kind == 'apk') ...['--split-per-abi', '--target-platform', 'android-arm64'],
    ...extra,
  ]);

  final built = kind == 'apk'
      ? p.join(stage, 'app', 'build', 'app', 'outputs', 'flutter-apk', 'app-arm64-v8a-$flavor-release.apk')
      : p.join(stage, 'app', 'build', 'app', 'outputs', 'bundle', '${flavor}Release', 'app-$flavor-release.aab');
  if (!File(built).existsSync()) _fail('no build output at $built');

  // `check_package` with `build_path_markers` (home + repo). The neutral
  // stage path itself is expected inside (that is the point of it).
  final markers = buildPathMarkers(roots);
  final result = checkPackage(File(built).readAsBytesSync(), markers);
  if (result.leaked.isNotEmpty) _fail('$built contains personal files: ${result.leaked}');
  if (result.paths.isNotEmpty) {
    final shown = result.paths.take(15).join(', ') +
        (result.paths.length > 15 ? ' (+${result.paths.length - 15} more)' : '');
    _fail('$built contains paths of this machine in: $shown');
  }

  Directory(out).createSync(recursive: true);
  final suffix = flavor == 'prod' ? '' : '-$flavor';
  final target = p.join(out, 'Strakalari-$version$suffix-android.${kind == 'apk' ? 'apk' : 'aab'}');
  File(built).copySync(target);
  final mb = (File(target).lengthSync() / (1024 * 1024)).toStringAsFixed(1);
  // Flutter's per-ABI offset for arm64-v8a, like Flet's APK.
  final shipped = kind == 'apk' ? code + 2000 : code;
  stdout.writeln('Built $target ($mb MB, no personal files or paths, versionCode $shipped)');
}
