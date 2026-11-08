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

String _findRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 10; i++) {
    if (File('${dir.path}${Platform.pathSeparator}strakalari'
            '${Platform.pathSeparator}core'
            '${Platform.pathSeparator}helpers.py')
        .existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('repo root containing strakalari/core/helpers.py not found');
}

Future<String> _findPythonExecutable(String repoRoot) async {
  final sep = Platform.pathSeparator;
  final candidates = <String>[
    '$repoRoot$sep.venv${sep}Scripts${sep}python.exe',
    '$repoRoot$sep..$sep..$sep..$sep.venv${sep}Scripts${sep}python.exe',
    '$repoRoot$sep.venv${sep}bin${sep}python',
    'python3',
    'python',
  ];
  for (final cmd in candidates) {
    try {
      final r = await Process.run(cmd, ['--version'])
          .timeout(const Duration(seconds: 15));
      if (r.exitCode == 0) return cmd;
    } catch (_) {
      continue;
    }
  }
  throw StateError('no usable Python 3 executable found');
}

String _pythonWriteAllSixScript(String repoRoot) => '''
import datetime, os, sys, types

repo = ${jsonEncode(repoRoot)}
pkg = types.ModuleType("strakalari")
pkg.__path__ = [os.path.join(repo, "strakalari")]
pkg.__version__ = "0.1.0"
sys.modules["strakalari"] = pkg
core = types.ModuleType("strakalari.core")
core.__path__ = [os.path.join(repo, "strakalari", "core")]
sys.modules["strakalari.core"] = core

from strakalari.core import cache, config, excuse_history, helpers, planned_skips, school_presets

tmp = os.environ["STRAKALARI_DATA_DIR"]

cm = config.ConfigManager(os.path.join(tmp, "config.json"))
cm.set("language", "en")
cm.set("bakalari_url", "https://bakalari.skola.cz")
cm.set("bakalari_username", "jan.novak")
cm.set("use_strava", False)
cm.set("marks_percent_bands", [87.0, 72.0, 55.0, 40.0])
cm.save()

cache.save_data_cache(
    {
        "timetable": {"01.09.2026": [{"hour": "1", "subject": "ČJ"}]},
        "absence": [],
        "grades": {"ČJ": {"marks": [], "average": "1,50"}},
        "strava_menu": {},
        "strava_ordered": {"01.09.2026": "1"},
        "last_updated": "01.09.2026 08:00:00",
    },
    replace=True,
)

merged_hist, _ = excuse_history.merge_sent_excuses(
    [{"type": "pure days", "starting_day": "1.9.2026", "ending_day": "02.09.2026"}],
    [{"type": "days and hours", "starting_day": "03.09.2026",
      "ending_day": "03.09.2026", "starting_lesson": 2, "ending_lesson": 4}],
)
helpers.atomic_write_json(os.path.join(tmp, "already_excused_lessons.json"), merged_hist)

excuse_history.save_unconfirmed(
    os.path.join(tmp, "already_excused_lessons.json"),
    [excuse_history.unconfirmed_entry(
        {"type": "pure days", "starting_day": "04.09.2026", "ending_day": "04.09.2026"},
        datetime.datetime(2026, 9, 4, 7, 30, 0),
    )],
)

d1, d2 = datetime.date(2026, 9, 7), datetime.date(2026, 9, 8)
skips = planned_skips.entries_for_selection(
    {d1: [1, 2], d2: [1, 2, 3]},
    {d1: [1, 2, 3], d2: [1, 2, 3]},
    template="Lékař",
    cancel_lunch=False,
)
cm_skips = config.ConfigManager(os.path.join(tmp, "skips_config.json"))
cm_skips.set_and_save("planned_skips", planned_skips.load_planned_skips({"planned_skips": skips}))

preset_data = dict(
    school_presets.GEKOM_2026_2027,
    id="test_gekom",
    ranges=[list(r) for r in school_presets.GEKOM_2026_2027["ranges"]],
    days=[list(d) for d in school_presets.GEKOM_2026_2027["days"]],
)
helpers.atomic_write_json(
    os.path.join(tmp, "school_presets", "test_gekom.json"),
    preset_data,
)
''';

void main() {
  Directory? tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('helpers_test_');
  });
  tearDown(() {
    setEnvironmentOverride(null);
    if (tmp != null && tmp!.existsSync()) {
      tmp!.deleteSync(recursive: true);
    }
  });

  group('parseDate', () {
    test('standard', () {
      expect(parseDate('15.09.2026'), DateTime(2026, 9, 15));
    });

    test('withSpaces', () {
      expect(parseDate('1. 9. 2026'), DateTime(2026, 9, 1));
      expect(parseDate(' 15 . 09 . 2026 '), DateTime(2026, 9, 15));
    });

    test('withWeekdayParentheses', () {
      expect(parseDate('3.9.2026 (čtvrtek)'), DateTime(2026, 9, 3));
      expect(parseDate('18. 10. 2026 (Pondělí)'), DateTime(2026, 10, 18));
    });

    test('withLeadingDayPrefix', () {
      expect(parseDate('Pondělí 1. 9. 2026'), DateTime(2026, 9, 1));
      expect(parseDate('Úterý 15.10.2026'), DateTime(2026, 10, 15));
      expect(parseDate('St 02.09.2026'), DateTime(2026, 9, 2));
    });

    test('isoAndSlash', () {
      expect(parseDate('2026-11-25'), DateTime(2026, 11, 25));
      expect(parseDate('25/11/2026'), DateTime(2026, 11, 25));
    });

    test('acceptsShortYearAndIsoSlashes', () {
      String fmt(DateTime d) =>
          '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
      expect(fmt(parseDate('07.09.26')), '07.09.2026');
      expect(fmt(parseDate('2026/09/07')), '07.09.2026');
    });

    test('invalid', () {
      expect(() => parseDate('not-a-date'), throwsArgumentError);
      expect(() => parseDate(''), throwsArgumentError);
    });
  });

  group('getUserDataDirAndResolvePath', () {
    test('overrideWins', () {
      final dir = Directory('${tmp!.path}/data');
      setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path});
      expect(getUserDataDir(), dir.path);
      expect(Directory(dir.path).existsSync(), isTrue);
    });

    test('absolutePathPassesThrough', () {
      setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp!.path});
      final abs = Platform.isWindows ? r'C:\x\test_file.txt' : '/x/test_file.txt';
      expect(resolvePath(abs), abs);
    });

    test('relativeResolvesAgainstDataDir', () {
      setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp!.path});
      expect(resolvePath('sub/f.txt'),
          '${tmp!.path}${Platform.pathSeparator}sub${Platform.pathSeparator}f.txt');
    });
  });

  group('examplePathFor', () {
    test('onlySuffixReplaced', () {
      expect(examplePathFor('/x/my.json.d/f.json'), '/x/my.json.d/f.example.json');
      expect(examplePathFor('a.json'), 'a.example.json');
    });
  });

  group('extractLessonNum', () {
    test('timeOnlyReturnsNull', () {
      expect(extractLessonNum('8:00 - 8:45'), isNull);
      expect(extractLessonNum('13:40 - 14:25'), isNull);
    });

    test('bareNumberOk', () {
      expect(extractLessonNum('3'), 3);
    });

    test('classicShapeOk', () {
      expect(extractLessonNum('3 (10:05 - 10:50)'), 3);
    });

    test('emptyNull', () {
      expect(extractLessonNum(''), isNull);
    });
  });

  group('formatExcuseTemplate', () {
    test('fillsVariables', () {
      const tpl =
          'Dobrý den, omluvte absenci dne {date} na hodině {lessons} z předmětu {subject}.';
      final formatted = formatExcuseTemplate(tpl,
          dateStr: '15.09.2026',
          lessonsStr: '2. hodina',
          subjectStr: 'Matematika',
          signatureStr: 'Jan Novák');
      expect(formatted, contains('dne 15.09.2026'));
      expect(formatted, contains('na hodině 2. hodina'));
      expect(formatted, contains('z předmětu Matematika'));
      expect(formatted, contains('Jan Novák'));
    });
  });

  group('atomicWriteJson', () {
    test('writesValidJson', () {
      final p = '${tmp!.path}/sub/data.json';
      atomicWriteJson(p, {
        'a': [1, 2, 3]
      });
      expect(jsonDecode(File(p).readAsStringSync()), {
        'a': [1, 2, 3]
      });
    });

    test('fileBytesFollowPythonTextModeNewlines', () {
      final p = '${tmp!.path}/nl.json';
      atomicWriteJson(p, {
        'a': [1]
      });
      final text = utf8.decode(File(p).readAsBytesSync());
      // Python text mode writes CRLF on Windows and LF elsewhere.
      expect(text.contains('\r\n'), Platform.isWindows);
      expect(text.replaceAll('\r\n', '\n'), '{\n  "a": [\n    1\n  ]\n}');
    });

    test('toPlatformNewlines', () {
      expect(toPlatformNewlines('a\nb\n\n', windows: true),
          'a\r\nb\r\n\r\n');
      expect(toPlatformNewlines('a\nb', windows: false), 'a\nb');
    });

    test('floatFormattingMatchesPython', () {
      expect(pyJsonDumps(1e-7), '1e-07');
      expect(pyJsonDumps(1e-5), '1e-05');
      expect(pyJsonDumps(1e-4), '0.0001');
      expect(pyJsonDumps(0.0), '0.0');
      expect(pyJsonDumps(-0.0), '-0.0');
      expect(pyJsonDumps(15.0), '15.0');
      expect(pyJsonDumps(1e15), '1000000000000000.0');
      expect(pyJsonDumps(1e16), '1e+16');
      expect(pyJsonDumps(1.5e16), '1.5e+16');
      expect(pyJsonDumps(-2.5e-7), '-2.5e-07');
      expect(pyJsonDumps(1e21), '1e+21');
      expect(
        jsonIndent2({
          'small': 1e-7,
          'large': 1e16,
          'whole': 15.0,
        }),
        '{\n  "small": 1e-07,\n  "large": 1e+16,\n  "whole": 15.0\n}',
      );
    });

    test('noTmpLeftovers', () {
      final p = '${tmp!.path}/data.json';
      atomicWriteJson(p, [1]);
      final leftovers = Directory(tmp!.path)
          .listSync()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('pythonWritesDartRewritesBytesMatch', () async {
      final repoRoot = _findRepoRoot();
      final pyExe = await _findPythonExecutable(repoRoot);
      final proc = await Process.run(
        pyExe,
        ['-c', _pythonWriteAllSixScript(repoRoot)],
        environment: {
          ...Platform.environment,
          'PYTHONUTF8': '1',
          'STRAKALARI_DATA_DIR': tmp!.path,
          'STRAKALARI_NO_KEYRING': '1',
        },
      ).timeout(const Duration(seconds: 30));
      expect(proc.exitCode, 0, reason: 'python stderr: ${proc.stderr}');

      final sep = Platform.pathSeparator;
      final paths = <String, String>{
        'config': '${tmp!.path}${sep}config.json',
        'cache': '${tmp!.path}${sep}data_cache.json',
        'history': '${tmp!.path}${sep}already_excused_lessons.json',
        'sidecar': '${tmp!.path}${sep}already_excused_lessons.unconfirmed.json',
        'planned_skips': '${tmp!.path}${sep}skips_config.json',
        'presets': '${tmp!.path}${sep}school_presets${sep}test_gekom.json',
      };
      final beforeBytes = <String, List<int>>{
        for (final entry in paths.entries)
          entry.key: File(entry.value).readAsBytesSync(),
      };

      setEnvironmentOverride({
        'STRAKALARI_DATA_DIR': tmp!.path,
        'STRAKALARI_NO_KEYRING': '1',
      });

      final cm = ConfigManager(paths['config']!);
      cm.save();

      final loadedCache = loadDataCache();
      saveDataCache(loadedCache, replace: true);

      final hist = cm.getExcuseHistory();
      final (mergedHist, _) = mergeSentExcuses(hist, const []);
      atomicWriteJson(paths['history']!, mergedHist);

      final sidecar = loadUnconfirmed(paths['history']!);
      saveUnconfirmed(paths['history']!, sidecar);

      final cmSkips = ConfigManager(paths['planned_skips']!);
      final skips = loadPlannedSkips(cmSkips.data);
      cmSkips.setAndSave('planned_skips', skips);

      final loadedPreset = Map<String, Object?>.of(getPreset('test_gekom')!)
        ..remove('user_file');
      atomicWriteJson(paths['presets']!, loadedPreset);

      for (final entry in paths.entries) {
        final afterBytes = File(entry.value).readAsBytesSync();
        expect(afterBytes, equals(beforeBytes[entry.key]),
            reason: '${entry.key} bytes changed after Dart rewrite');
      }
    });
  });

  group('fileLock', () {
    test('lockReleaseReacquire', () {
      final lock = '${tmp!.path}/x.lock';
      final token = tryFileLock(lock);
      expect(token, isNotNull);
      expect(tryFileLock(lock), isNull);
      releaseFileLock(token);
      expect(tryFileLock(lock), isNotNull);
    });
  });

  group('interProcessLock', () {
    test('acquireReleaseReacquire', () {
      final lock = InterProcessLock('${tmp!.path}/s.lock');
      expect(lock.acquire(), isTrue);
      expect(lock.held, isTrue);
      expect(() => lock.acquire(), throwsStateError);
      lock.release();
      expect(lock.held, isFalse);
      expect(lock.acquire(), isTrue);
      lock.release();
    });

    test('secondObjectFailsWhileHeld', () {
      final first = InterProcessLock('${tmp!.path}/s.lock');
      final second = InterProcessLock('${tmp!.path}/s.lock');
      expect(first.acquire(), isTrue);
      expect(second.acquire(), isFalse);
      expect(second.held, isFalse);
      first.release();
      expect(second.acquire(), isTrue);
      second.release();
    });
  });
}
