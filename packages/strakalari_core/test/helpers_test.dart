import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/helpers.dart';

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

    test('noTmpLeftovers', () {
      final p = '${tmp!.path}/data.json';
      atomicWriteJson(p, [1]);
      final leftovers = Directory(tmp!.path)
          .listSync()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
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
