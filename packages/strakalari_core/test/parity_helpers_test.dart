import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/excuse_history.dart';
import 'package:strakalari_core/src/planning/planned_skips.dart';
import 'package:strakalari_core/src/planning/school_presets.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/cache.dart';
import 'package:strakalari_core/src/storage/config.dart';
import 'package:strakalari_core/src/storage/helpers.dart';
import 'package:strakalari_core/src/storage/secret_store.dart';

import 'parity_cases.dart';

/// Mirrors dump.py's `ProbeError`: the text is the whole message, so
/// `describeSwallowed` prints the same type name and line as Python.
class ProbeError implements Exception {
  ProbeError(this.message);

  final String message;

  @override
  String toString() => message;
}

Map<String, String> _runRoundTripFiles(Map<String, Object?> pyFiles) {
  final tmp = Directory.systemTemp.createTempSync('parity_rt_files_');
  try {
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    final sep = Platform.pathSeparator;
    final paths = <String, String>{
      'config': '${tmp.path}${sep}config.json',
      'cache': '${tmp.path}${sep}data_cache.json',
      'history': '${tmp.path}${sep}already_excused_lessons.json',
      'sidecar': '${tmp.path}${sep}already_excused_lessons.unconfirmed.json',
      'planned_skips': '${tmp.path}${sep}skips_config.json',
      'presets': '${tmp.path}${sep}school_presets${sep}test_gekom.json',
    };
    final beforeBytes = <String, List<int>>{};
    for (final entry in paths.entries) {
      final file = File(entry.value);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        toPlatformNewlines(pyFiles[entry.key] as String),
        encoding: utf8,
      );
      beforeBytes[entry.key] = file.readAsBytesSync();
    }

    // 1. config: load and rewrite via ConfigManager.save().
    final cm = ConfigManager(paths['config']!);
    cm.save();

    // 2. cache: load and rewrite via loadDataCache / saveDataCache.
    final loadedCache = loadDataCache();
    saveDataCache(loadedCache, replace: true);

    // 3. history: load via ConfigManager.getExcuseHistory, normalize via
    //    mergeSentExcuses, rewrite via atomicWriteJson.
    final hist = cm.getExcuseHistory();
    final (mergedHist, _) = mergeSentExcuses(hist, const []);
    atomicWriteJson(paths['history']!, mergedHist);

    // 4. sidecar: load and rewrite via loadUnconfirmed / saveUnconfirmed.
    final sidecar = loadUnconfirmed(paths['history']!);
    saveUnconfirmed(paths['history']!, sidecar);

    // 5. planned skips: load and rewrite via loadPlannedSkips + ConfigManager.
    final cmSkips = ConfigManager(paths['planned_skips']!);
    final skips = loadPlannedSkips(cmSkips.data);
    cmSkips.setAndSave('planned_skips', skips);

    // 6. presets: load via getPreset and rewrite via atomicWriteJson.
    final loadedPreset =
        Map<String, Object?>.of(getPreset('test_gekom')!)..remove('user_file');
    atomicWriteJson(paths['presets']!, loadedPreset);

    final out = <String, String>{};
    for (final entry in paths.entries) {
      final afterBytes = File(entry.value).readAsBytesSync();
      expect(afterBytes, equals(beforeBytes[entry.key]),
          reason: '${entry.key} raw file bytes changed on Dart rewrite');
      out[entry.key] =
          utf8.decode(afterBytes).replaceAll('\r\n', '\n');
    }
    return out;
  } finally {
    setEnvironmentOverride(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('helpers')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'parseDate':
          result = parseDate(args[0]);
        case 'extractLessonNum':
          result = extractLessonNum(args[0]);
        case 'shortTime':
          result = shortTime(args[0]);
        case 'teacherSurname':
          result = teacherSurname(args[0]);
        case 'isExcusedMarker':
          result = isExcusedMarker(args[0]);
        case 'shortRoomName':
          result = shortRoomName(args[0]);
        case 'formatExcuseTemplate':
          result = formatExcuseTemplate(args[0] as String,
              dateStr: args[1] as String,
              lessonsStr: args[2],
              subjectStr: args[3] as String,
              signatureStr: args[4] as String);
        case 'templateText':
          result = templateText(args[0]);
        case 'isEncryptedFlag':
          result = isEncryptedFlag(args[0]);
        case 'addDays':
          result = addDays(args[0] as DateTime, args[1] as int);
        case 'pyJsonDumps':
          result = pyJsonDumps(args[0]);
        case 'pyRepr':
          result = pyRepr(args[0]);
        case 'describeSwallowed':
          result =
              describeSwallowed(args[0] as String, ProbeError(args[1] as String));
        case 'jsonIndent2':
          result = jsonIndent2(args[0]);
        case 'entryName':
          result = entryName(args[0] as String, windows: args[1] as bool);
        case 'roundTripFiles':
          result = _runRoundTripFiles(expected as Map<String, Object?>);
        case 'daysBetween':
          result = daysBetween(args[0] as DateTime, args[1] as DateTime);
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
