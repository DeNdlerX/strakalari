import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/cache.dart';

String _stamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}.${two(dt.month)}.${dt.year} '
      '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cache_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    setLanguage('cs');
  });

  tearDown(() {
    setEnvironmentOverride(null);
    setLanguage('cs');
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String cachePath() =>
      '${tmp.path}${Platform.pathSeparator}data_cache.json';

  group('loadCache', () {
    test('missingFileReturnsEmptyDict', () {
      expect(loadDataCache(), isEmpty);
    });

    test('saveAndLoadCache', () {
      final payload = <String, Object?>{
        'absences': {'Matematika': 12.5},
        'last_run': '2026-09-05',
      };
      final saved = saveDataCache(payload);
      for (final entry in payload.entries) {
        expect(saved[entry.key], entry.value);
      }
      expect(File(cachePath()).existsSync(), isTrue);

      final loaded = loadDataCache();
      for (final entry in payload.entries) {
        expect(loaded[entry.key], entry.value);
      }
    });

    test('saveCacheMergesWithExisting', () {
      saveDataCache({'key1': 'val1'});
      saveDataCache({'key2': 'val2'});

      final loaded = loadDataCache();
      expect(loaded['key1'], 'val1');
      expect(loaded['key2'], 'val2');
    });

    test('loadCorruptedCacheFallback', () {
      File(cachePath()).writeAsStringSync('{invalid_json_format!!}');
      expect(loadDataCache(), isEmpty);
    });
  });

  group('cacheVersion', () {
    test('mismatchedVersionIgnored', () {
      File(cachePath()).writeAsStringSync(
          jsonEncode({'_cache_version': 999, 'timetable': {'x': 1}}));
      expect(loadDataCache(), isEmpty);
    });

    test('currentVersionLoads', () {
      saveDataCache({
        'timetable': {'x': 1}
      });
      expect(loadDataCache()['timetable'], {'x': 1});
    });
  });

  group('cacheMeta', () {
    test('staleDetection', () {
      expect(isCacheStale({}, 24), isTrue);
      expect(isCacheStale({'last_updated': '01.01.2000 00:00:00'}, 24),
          isTrue);
    });

    test('describeMentionsStale', () {
      final label =
          describeCache({'last_updated': '01.01.2000 00:00:00'}, 24);
      expect(label, contains('zastaral'));
    });
  });

  group('cacheReplace', () {
    test('replaceDropsStaleKeys', () {
      saveDataCache({
        'old': 1,
        'timetable': <String, Object?>{
          'd': <Object?>[]
        }
      });
      final saved = saveDataCache({
        'timetable': <String, Object?>{
          'e': <Object?>[]
        }
      }, replace: true);
      expect(saved.containsKey('old'), isFalse);
      expect(loadDataCache(), saved);
    });
  });

  group('corruptCache', () {
    test('corruptCacheIsQuarantined', () {
      File(cachePath()).writeAsStringSync('{invalid_json_format!!');

      expect(loadDataCache(), isEmpty);

      final backups = Directory(tmp.path)
          .listSync()
          .where((e) => e.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
      expect(File(backups.single.path).readAsStringSync(),
          '{invalid_json_format!!');
    });

    test('busyCacheIsLeftUntouched', () {
      Directory(cachePath()).createSync();
      expect(loadDataCache(), isEmpty);
      saveDataCache({
        'absence': {'M': 1.0}
      });
      expect(Directory(cachePath()).existsSync(), isTrue);
      expect(
          Directory(tmp.path)
              .listSync()
              .where((e) => e.path.contains('.corrupt-'))
              .toList(),
          isEmpty);
    });
  });

  group('cacheLabel', () {
    test('cacheLabelFollowsLanguage', () {
      final stamp = _stamp(
          DateTime.now().subtract(const Duration(hours: 3)));
      setLanguage('en');
      try {
        expect(describeCache({'last_updated': stamp}, 24),
            contains('h ago'));
      } finally {
        setLanguage('cs');
      }
      expect(describeCache({'last_updated': stamp}, 24), contains('před'));
    });
  });

  group('mergeTimetableDays', () {
    test('keepsUnscrapedDaysAndFreshWins', () {
      final old = <String, Object?>{
        '18.09.2026': [
          {'subject': 'M'}
        ],
        '19.09.2026': [
          {'subject': 'F'}
        ],
      };
      final fresh = <String, Object?>{
        '19.09.2026': [
          {'subject': 'F2'}
        ],
        '20.09.2026': <Object?>[],
      };
      final merged = mergeTimetableDays(old, fresh,
          windowStart: DateTime(2026, 9, 1));
      expect(merged['18.09.2026'], <Object?>[
        {'subject': 'M'}
      ]);
      expect(merged['19.09.2026'], <Object?>[
        {'subject': 'F2'}
      ]);
      expect(merged['20.09.2026'], isEmpty);
    });

    test('presentButEmptyDayOverwrites', () {
      final old = <String, Object?>{
        '19.09.2026': [
          {'subject': 'F'}
        ]
      };
      final merged = mergeTimetableDays(old, {'19.09.2026': <Object?>[]},
          windowStart: DateTime(2026, 9, 1));
      expect(merged['19.09.2026'], isEmpty);
    });

    test('prunesOutOfWindowOldDaysKeepsGarbage', () {
      final old = <String, Object?>{
        '10.8.2026 (pondělí)': [
          {'subject': 'old'}
        ],
        '01.09.2026': [
          {'subject': 'boundary'}
        ],
        'not-a-date': [
          {'subject': 'kept'}
        ],
      };
      final merged =
          mergeTimetableDays(old, {}, windowStart: DateTime(2026, 9, 1));
      expect(merged.containsKey('10.8.2026 (pondělí)'), isFalse);
      expect(merged['01.09.2026'], <Object?>[
        {'subject': 'boundary'}
      ]);
      expect(merged['not-a-date'], <Object?>[
        {'subject': 'kept'}
      ]);
    });

    test('noWindowStartKeepsEverything', () {
      final old = <String, Object?>{
        '10.8.2026 (pondělí)': <Object?>[]
      };
      expect(mergeTimetableDays(old, {}), old);
    });

    test('emptyInputs', () {
      expect(mergeTimetableDays(null, null), isEmpty);
      expect(mergeTimetableDays({}, {'a': <Object?>[]}), {
        'a': <Object?>[]
      });
    });
  });

  group('cacheTimestamps', () {
    test('lastUpdatedTimeParsesFormats', () {
      final now = DateTime.now();
      final truncated =
          DateTime(now.year, now.month, now.day, now.hour, now.minute,
              now.second);
      expect(lastUpdatedTime({'last_updated': _stamp(now)}), truncated);
      expect(
          lastUpdatedTime({
            'last_updated':
                '${now.year}-${now.month.toString().padLeft(2, '0')}-'
                '${now.day.toString().padLeft(2, '0')} '
                '${now.hour.toString().padLeft(2, '0')}:'
                '${now.minute.toString().padLeft(2, '0')}:'
                '${now.second.toString().padLeft(2, '0')}'
          }),
          isNotNull);
      expect(lastUpdatedTime({}), isNull);
      expect(lastUpdatedTime({'last_updated': 'nonsense'}), isNull);
    });

    test('startupSeedNeedsPositiveEvidence', () {
      final now = DateTime.now();
      final fresh = startupSeed(
          {'last_updated': _stamp(now.subtract(const Duration(minutes: 10)))},
          now);
      expect(fresh, isNotNull);
      expect(now.difference(fresh!).inMinutes, lessThan(11));
      expect(
          startupSeed(
              {'last_updated':
                  _stamp(now.subtract(const Duration(hours: 3)))},
              now),
          isNotNull);
      expect(startupSeed({}, now), isNull);
      expect(startupSeed({'last_updated': 'nonsense'}, now), isNull);
      expect(
          startupSeed(
              {'last_updated':
                  _stamp(now.add(const Duration(hours: 1)))},
              now),
          isNull);
    });

    test('f6PerPartFreshnessAndLastCheckedTime', () {
      final now = DateTime(2026, 11, 22, 10, 30, 0);
      // Pre-F6 cache without part_updated falls back to last_updated.
      final preF6 = {'last_updated': '22.11.2026 09:00:00'};
      expect(partUpdatedTime(preF6, 'marks'), DateTime(2026, 11, 22, 9, 0));
      expect(partUpdatedTime(preF6, 'outbox'), DateTime(2026, 11, 22, 9, 0));
      expect(lastCheckedTime(preF6), DateTime(2026, 11, 22, 9, 0));

      // F6 cache with part_updated: missing part returns null (never inherits full).
      final f6 = {
        'last_updated': '22.11.2026 07:00:00',
        partUpdatedKey: {
          'full': '2026-11-22T07:00:00',
          'quick': '2026-11-22T10:25:00',
          'marks': '2026-11-22T10:25:00',
        },
      };
      expect(partUpdatedTime(f6, 'marks'), DateTime(2026, 11, 22, 10, 25));
      expect(partUpdatedTime(f6, 'strava'), isNull);
      expect(lastCheckedTime(f6), DateTime(2026, 11, 22, 10, 25));
      expect(startupSeed(f6, now), DateTime(2026, 11, 22, 10, 25));

      withClock(Clock.fixed(now), () {
        expect(describeCacheForPart(f6, 'marks'), contains('22.11.2026 10:25:00'));
        expect(describeCacheForPart(f6, 'strava'), '—');
      });
    });
  });
}
