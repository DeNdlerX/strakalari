// Release builds of the phone app from a neutral folder.
//
// Flutter compiles its generated plugin registrant under its file path
// (`file:///<repo>/app/.dart_tool/flutter_build/dart_plugin_registrant.dart`),
// so an APK built in the repo carries the build machine's home and repo
// folders. `tools/make_mobile.py` staged the Flet build and refused any
// package with such a path or a personal file; this is the Flutter
// counterpart (owner's decision, 2026-11-12): copy only the app's own
// sources to a folder outside the home and the repo, build there, and run
// the port of `check_package` on the result.
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// `PERSONAL` in tools/make_mobile.py.
final RegExp personalFiles = RegExp(
  r'(^|[\\/])(config\.json|secret\.key|data_cache\.json|update_cache\.json|log\.txt'
  r'|console\.log|strava_blacklist\.json|already_excused_lessons\.json'
  r'|already_excused_lessons\.unconfirmed\.json|automation_history\.jsonl'
  r'|instance\.token|htmls)([\\/]|$)',
  caseSensitive: false,
);

/// What the staged copy holds, relative to the repo root.
const List<String> stagedRoots = [
  'pubspec.yaml',
  'pubspec.lock',
  'analysis_options.yaml',
  'packages/strakalari_core',
  'app',
];

/// Directory names never copied: build outputs, caches, machine files,
/// and the tests (make_mobile.py staged no tests either; their fixtures
/// use personal file names such as `config.json`).
const Set<String> skippedDirs = {
  '.dart_tool', 'build', '.gradle', '.idea', '.cxx', 'ephemeral', '.kotlin', 'test',
};

/// File names never copied (they hold this machine's paths).
const Set<String> skippedFiles = {'local.properties', '.flutter-plugins', '.flutter-plugins-dependencies'};

/// `build_path_markers`: the home and repo folders, spelled the ways they
/// could sit inside a package (`\`, `/`, JSON-escaped), lower-cased.
/// Empty on CI: a runner's /home/runner/... is nobody's private folder.
List<String> buildPathMarkers(List<String> roots, {Map<String, String>? env}) {
  if ((env ?? Platform.environment)['GITHUB_ACTIONS'] == 'true') return [];
  final markers = <String>{};
  for (final root in roots) {
    final parts = p.absolute(root).split(RegExp(r'[\\/]+')).where((s) => s.isNotEmpty).toList();
    if (parts.length < 2) continue; // "/root" or "C:\" alone would match far too much
    for (final sep in [r'\', '/', r'\\']) {
      markers.add(parts.join(sep).toLowerCase());
    }
  }
  return markers.toList()..sort();
}

/// One zip entry: its full name (nested zips joined by `!`), its own name
/// and its bytes (null for directories and for nested zips themselves).
typedef PackageEntry = (String name, String inner, Uint8List? data);

/// `_package_entries`: every entry, entries of nested zips included.
Iterable<PackageEntry> packageEntries(Uint8List zip, {String prefix = '', int depth = 0}) sync* {
  for (final (fileName, data) in _zipEntries(zip)) {
    final name = prefix + fileName;
    if (data == null) {
      yield (name, fileName, null);
      continue;
    }
    if (depth < 4 && data.length >= 4 && data[0] == 0x50 && data[1] == 0x4b && data[2] == 3 && data[3] == 4) {
      List<PackageEntry>? nested;
      try {
        nested = packageEntries(data, prefix: '$name!', depth: depth + 1).toList();
      } on FormatException {
        nested = null; // not a zip after all
      }
      if (nested != null) {
        yield (name, fileName, null);
        yield* nested;
        continue;
      }
    }
    yield (name, fileName, data);
  }
}

/// `check_package`: the personal files and the build-machine paths found.
({List<String> leaked, List<String> paths}) checkPackage(Uint8List zip, List<String> markers) {
  final leaked = <String>[];
  final paths = <String>[];
  final needles = [for (final m in markers) m.codeUnits];
  for (final (name, inner, data) in packageEntries(zip)) {
    if (personalFiles.hasMatch(inner)) leaked.add(name);
    if (data != null && needles.isNotEmpty && needles.any((n) => _containsLower(data, n))) {
      paths.add(name);
    }
  }
  return (leaked: leaked, paths: paths);
}

/// Case-insensitive (ASCII) byte search, like `marker in data.lower()`.
bool _containsLower(Uint8List data, List<int> needle) {
  if (needle.isEmpty || data.length < needle.length) return false;
  int low(int b) => (b >= 0x41 && b <= 0x5a) ? b + 32 : b;
  final first = needle[0];
  outer:
  for (var i = 0; i <= data.length - needle.length; i++) {
    if (low(data[i]) != first) continue;
    for (var j = 1; j < needle.length; j++) {
      if (low(data[i + j]) != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Minimal zip reader (central directory; stored and deflated entries).
/// Directories have null bytes.
List<(String, Uint8List?)> _zipEntries(Uint8List zip) {
  final d = ByteData.sublistView(zip);
  var eocd = -1;
  for (var i = zip.length - 22; i >= 0 && i >= zip.length - 22 - 65535; i--) {
    if (d.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw const FormatException('not a zip file');
  final count = d.getUint16(eocd + 10, Endian.little);
  var at = d.getUint32(eocd + 16, Endian.little);
  final out = <(String, Uint8List?)>[];
  for (var k = 0; k < count; k++) {
    if (at + 46 > zip.length || d.getUint32(at, Endian.little) != 0x02014b50) {
      throw const FormatException('bad zip central directory');
    }
    final method = d.getUint16(at + 10, Endian.little);
    final compSize = d.getUint32(at + 20, Endian.little);
    final nameLen = d.getUint16(at + 28, Endian.little);
    final extraLen = d.getUint16(at + 30, Endian.little);
    final commentLen = d.getUint16(at + 32, Endian.little);
    final local = d.getUint32(at + 42, Endian.little);
    final name = String.fromCharCodes(zip.sublist(at + 46, at + 46 + nameLen));
    at += 46 + nameLen + extraLen + commentLen;
    if (name.endsWith('/')) {
      out.add((name, null));
      continue;
    }
    if (local + 30 > zip.length || d.getUint32(local, Endian.little) != 0x04034b50) {
      throw const FormatException('bad zip local header');
    }
    final start = local + 30 + d.getUint16(local + 26, Endian.little) + d.getUint16(local + 28, Endian.little);
    if (start + compSize > zip.length) throw const FormatException('truncated zip entry');
    final raw = Uint8List.sublistView(zip, start, start + compSize);
    final Uint8List data;
    if (method == 0) {
      data = Uint8List.fromList(raw);
    } else if (method == 8) {
      data = Uint8List.fromList(ZLibDecoder(raw: true).convert(raw));
    } else {
      throw FormatException('unsupported zip method $method in $name');
    }
    out.add((name, data));
  }
  return out;
}

/// The default neutral folder: outside every user's home.
String defaultStageDir() => Platform.isWindows
    ? '${Platform.environment['SystemDrive'] ?? 'C:'}\\strakalari-build'
    : '/tmp/strakalari-build';

/// True when [stage] lies inside one of [roots] (home, repo).
bool stageInside(String stage, List<String> roots) {
  final s = p.normalize(p.absolute(stage)).toLowerCase();
  for (final r in roots) {
    final root = p.normalize(p.absolute(r)).toLowerCase();
    if (s == root || p.isWithin(root, s)) return true;
  }
  return false;
}

/// Copies the app's sources from [repo] into a fresh [stage] (deleted
/// first). Returns the copied paths (relative). Refuses a personal file.
List<String> stageSources(String repo, String stage) {
  final dir = Directory(stage);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  final copied = <String>[];
  void copyFile(File f, String rel) {
    if (personalFiles.hasMatch(rel)) {
      throw StateError('personal file in the sources: $rel');
    }
    final target = File(p.join(stage, rel));
    target.parent.createSync(recursive: true);
    f.copySync(target.path);
    copied.add(rel);
  }

  void walk(Directory d, String rel) {
    for (final e in d.listSync(followLinks: false)) {
      final name = p.basename(e.path);
      final childRel = rel.isEmpty ? name : '$rel/$name';
      if (e is Directory) {
        if (skippedDirs.contains(name)) continue;
        walk(e, childRel);
      } else if (e is File) {
        if (skippedFiles.contains(name)) continue;
        copyFile(e, childRel);
      }
    }
  }

  for (final root in stagedRoots) {
    final path = p.join(repo, root);
    if (FileSystemEntity.isDirectorySync(path)) {
      walk(Directory(path), root);
    } else {
      copyFile(File(path), root);
    }
  }
  copied.sort();
  return copied;
}
