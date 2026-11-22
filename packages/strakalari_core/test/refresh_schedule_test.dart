import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:strakalari_core/strakalari_core.dart';

Map<String, Object?> _schoolCache({
  String dayKey = '07.09.2026', // Monday
  List<Map<String, Object?>>? lessons,
  Map<String, Object?>? extra,
}) {
  return {
    'timetable': {
      dayKey: lessons ??
          [
            {
              'hour': '1',
              'time': '8:00 - 8:45',
              'subject': 'M',
              'status': 'normal',
            },
            {
              'hour': '6',
              'time': '12:55 - 13:40',
              'subject': 'ČJ',
              'status': 'normal',
            },
          ],
    },
    ...?extra,
  };
}

void main() {
  group('activeDayWindow', () {
    test('oneHourBeforeFirstLessonTo1700OnRegularSchoolDay', () {
      final cache = _schoolCache();
      final cfg = defaultConfig();
      final w = activeDayWindow(cache, cfg, DateTime(2026, 9, 7));
      expect(w, isNotNull);
      expect(w!.start, DateTime(2026, 9, 7, 7, 0));
      expect(w.end, DateTime(2026, 9, 7, 17, 0));
    });

    test('extendsPast1700WhenLastLessonEndsLaterAndFloorsStartAt0500', () {
      final cache = _schoolCache(lessons: [
        {'hour': '0', 'time': '5:30 - 6:15', 'subject': 'M', 'status': 'normal'},
        {'hour': '10', 'time': '17:00 - 17:45', 'subject': 'TV', 'status': 'normal'},
      ]);
      final w = activeDayWindow(cache, defaultConfig(), DateTime(2026, 9, 7));
      expect(w, isNotNull);
      expect(w!.start, DateTime(2026, 9, 7, 5, 0));
      expect(w.end, DateTime(2026, 9, 7, 17, 45));
    });

    test('returnsNullOnFreeDayWeekendOrAllCancelledLessons', () {
      final cache = _schoolCache(lessons: [
        {'hour': '1', 'time': '8:00 - 8:45', 'subject': 'M', 'status': 'cancelled'},
      ]);
      // All lessons cancelled -> day off.
      expect(activeDayWindow(cache, defaultConfig(), DateTime(2026, 9, 7)), isNull);

      // Configured free day -> day off even when timetable has lessons.
      final freeCfg = defaultConfig()
        ..['user_free_days'] = ['2026-09-07'];
      expect(activeDayWindow(_schoolCache(), freeCfg, DateTime(2026, 9, 7)), isNull);

      // Weekend with no lessons -> day off.
      expect(activeDayWindow(_schoolCache(), defaultConfig(), DateTime(2026, 9, 12)), isNull);
    });

    test('coldInstallDefaultsMonFri0700To1700AndWeekendNull', () {
      final wMon = activeDayWindow({}, defaultConfig(), DateTime(2026, 9, 7));
      expect(wMon, (
        start: DateTime(2026, 9, 7, 7, 0),
        end: DateTime(2026, 9, 7, 17, 0),
      ));
      expect(activeDayWindow({}, defaultConfig(), DateTime(2026, 9, 12)), isNull);
    });

    test('plannedSkipDoesNotHideSchoolHours', () {
      final cfg = defaultConfig()
        ..['planned_skips'] = [
          {
            'start_date': '2026-09-07',
            'end_date': '2026-09-07',
            'template': 'Lékař',
          },
        ];
      final w = activeDayWindow(_schoolCache(), cfg, DateTime(2026, 9, 7));
      expect(w, isNotNull);
      expect(w!.start, DateTime(2026, 9, 7, 7, 0));
    });

    test('combinedActiveDayWindowTakesUnionAcrossEnabledAccounts', () {
      final acc1 = (
        cache: _schoolCache(lessons: [
          {'hour': '1', 'time': '8:00 - 8:45', 'subject': 'M', 'status': 'normal'},
        ]),
        cfg: defaultConfig()..['background_refresh'] = true,
      );
      final acc2 = (
        cache: _schoolCache(lessons: [
          {'hour': '0', 'time': '7:10 - 7:55', 'subject': 'F', 'status': 'normal'},
          {'hour': '11', 'time': '17:15 - 18:00', 'subject': 'TV', 'status': 'normal'},
        ]),
        cfg: defaultConfig()..['background_refresh'] = true,
      );
      final acc3Disabled = (
        cache: _schoolCache(lessons: [
          {'hour': '0', 'time': '6:00 - 6:45', 'subject': 'X', 'status': 'normal'},
        ]),
        cfg: defaultConfig()..['background_refresh'] = false,
      );
      final w = combinedActiveDayWindow(
        [acc1, acc2, acc3Disabled],
        DateTime(2026, 9, 7),
      );
      expect(w, (
        start: DateTime(2026, 9, 7, 6, 10),
        end: DateTime(2026, 9, 7, 18, 0),
      ));
    });
  });

  group('effectiveCheckIntervalMinutes', () {
    final win = (
      start: DateTime(2026, 9, 7, 7, 0),
      end: DateTime(2026, 9, 7, 17, 0),
    );
    final daytime = DateTime(2026, 9, 7, 10, 0);
    final night = DateTime(2026, 9, 7, 22, 0);

    test('wifiAlwaysFastRuns24x7AtFastInterval', () {
      final cfg = defaultConfig()
        ..['check_interval_minutes'] = 5
        ..['check_interval_off_hours_minutes'] = 60
        ..['refresh_wifi_always_fast'] = true;
      expect(effectiveCheckIntervalMinutes(cfg, win, NetworkKind.unmetered, daytime), 5);
      expect(effectiveCheckIntervalMinutes(cfg, win, NetworkKind.unmetered, night), 5);
      expect(effectiveCheckIntervalMinutes(cfg, null, NetworkKind.unmetered, night), 5);
    });

    test('wifiNotAlwaysFastSlowsDownOffHours', () {
      final cfg = defaultConfig()
        ..['check_interval_minutes'] = 5
        ..['check_interval_off_hours_minutes'] = 60
        ..['refresh_wifi_always_fast'] = false;
      expect(effectiveCheckIntervalMinutes(cfg, win, NetworkKind.unmetered, daytime), 5);
      expect(effectiveCheckIntervalMinutes(cfg, win, NetworkKind.unmetered, night), 60);
    });

    test('mobileClampsToAtLeastWifiFastAndSlowsOffHours', () {
      final cfg = defaultConfig()
        ..['check_interval_minutes'] = 15
        ..['check_interval_mobile_minutes'] = 5
        ..['check_interval_off_hours_minutes'] = 60;
      // Clamped to max(15, 5) = 15.
      expect(effectiveCheckIntervalMinutes(cfg, win, NetworkKind.metered, daytime), 15);
      expect(effectiveCheckIntervalMinutes(cfg, win, NetworkKind.unknown, daytime), 15);
      expect(effectiveCheckIntervalMinutes(cfg, win, NetworkKind.metered, night), 60);
    });
  });

  group('nextScheduledWake', () {
    ActiveDayWindow? weekdayWindow(DateTime d) => d.weekday <= 5
        ? (
            start: DateTime(d.year, d.month, d.day, 6, 45),
            end: DateTime(d.year, d.month, d.day, 17, 0),
          )
        : null;

    test('clampsOffHoursCandidateToWindowStart', () {
      final cfg = defaultConfig()
        ..['check_interval_mobile_minutes'] = 5
        ..['check_interval_off_hours_minutes'] = 60;
      final lastRun = DateTime(2026, 9, 7, 6, 20);
      final now = DateTime(2026, 9, 7, 6, 25);
      // Without clamp: 07:20; clamped to window start 06:45.
      final next = nextScheduledWake(
        lastRun,
        cfg,
        weekdayWindow,
        NetworkKind.metered,
        now,
      );
      expect(next, DateTime(2026, 9, 7, 6, 45));
    });

    test('offHoursPause0WaitsUntilWindowStartOrPreAlarmTick', () {
      final cfg = defaultConfig()
        ..['check_interval_mobile_minutes'] = 5
        ..['check_interval_off_hours_minutes'] = 0;
      final lastRun = DateTime(2026, 9, 7, 17, 0);
      final evening = DateTime(2026, 9, 7, 21, 0);

      // No alarm -> tomorrow's window start 06:45.
      expect(
        nextScheduledWake(lastRun, cfg, weekdayWindow, NetworkKind.metered, evening),
        DateTime(2026, 9, 8, 6, 45),
      );

      // With alarm at 06:45 -> pre-alarm tick at 06:15 comes earlier.
      final alarm = DateTime(2026, 9, 8, 6, 45);
      expect(
        nextScheduledWake(
          lastRun,
          cfg,
          weekdayWindow,
          NetworkKind.metered,
          evening,
          nextAlarm: alarm,
        ),
        DateTime(2026, 9, 8, 6, 15),
      );

      // After the 06:15 pre-alarm tick runs, next wake moves to 06:45 (no loop).
      expect(
        nextScheduledWake(
          DateTime(2026, 9, 8, 6, 15, 5),
          cfg,
          weekdayWindow,
          NetworkKind.metered,
          DateTime(2026, 9, 8, 6, 16),
          nextAlarm: alarm,
        ),
        DateTime(2026, 9, 8, 6, 45),
      );
    });

    test('offHoursPause0FallsBackTo6HoursWhenNoWindowIn14Days', () {
      final cfg = defaultConfig()..['check_interval_off_hours_minutes'] = 0;
      final now = DateTime(2026, 7, 15, 10, 0);
      expect(
        nextScheduledWake(
          DateTime(2026, 7, 15, 4, 0),
          cfg,
          (_) => null,
          NetworkKind.metered,
          now,
        ),
        DateTime(2026, 7, 15, 16, 0),
      );
    });
  });

  group('chooseScheduledScope', () {
    final bakCfg = defaultConfig()
      ..['bakalari_url'] = 'https://bakaweb.school.cz'
      ..['bakalari_username'] = 'student';
    final stravaOnlyCfg = defaultConfig()
      ..['strava_username'] = 's'
      ..['strava_canteen_id'] = '1950';
    final now = DateTime(2026, 9, 7, 10, 0);

    Map<String, Object?> freshCache({
      DateTime? fullAt,
      DateTime? outboxAt,
      String? failedAt,
      String? failedScope,
    }) {
      final full = fullAt ?? DateTime(2026, 9, 7, 9, 0);
      return {
        'last_updated': full.toIso8601String(),
        partUpdatedKey: {
          'full': full.toIso8601String(),
          if (outboxAt != null) 'outbox': outboxAt.toIso8601String(),
        },
        scheduledRefreshFailedKey: ?failedAt,
        scheduledRefreshFailedScopeKey: ?failedScope,
      };
    }

    test('rule1ColdCacheReturnsAll', () {
      final res = chooseScheduledScope(
        bakCfg,
        {},
        now,
        hasPendingExcuses: false,
        hasUnconfirmed: false,
      );
      expect(res, (scope: 'all', quickOutbox: false));
    });

    test('rule2EarlierCalendarDayReturnsAll', () {
      final cache = freshCache(
        fullAt: DateTime(2026, 9, 6, 23, 30),
        outboxAt: DateTime(2026, 9, 6, 23, 30),
      );
      final res = chooseScheduledScope(
        bakCfg,
        cache,
        DateTime(2026, 9, 7, 0, 5),
        hasPendingExcuses: false,
        hasUnconfirmed: false,
      );
      expect(res, (scope: 'all', quickOutbox: false));
    });

    test('rule3SixHoursOldReturnsAll', () {
      final cache = freshCache(
        fullAt: DateTime(2026, 9, 7, 4, 0),
        outboxAt: DateTime(2026, 9, 7, 4, 0),
      );
      final res = chooseScheduledScope(
        bakCfg,
        cache,
        DateTime(2026, 9, 7, 10, 0),
        hasPendingExcuses: false,
        hasUnconfirmed: false,
      );
      expect(res, (scope: 'all', quickOutbox: false));
    });

    test('rule4UnconfirmedWithOldOutboxReturnsAll', () {
      final cache = freshCache(
        fullAt: DateTime(2026, 9, 7, 9, 25),
        outboxAt: DateTime(2026, 9, 7, 9, 25),
      );
      final res = chooseScheduledScope(
        bakCfg,
        cache,
        now,
        hasPendingExcuses: false,
        hasUnconfirmed: true,
      );
      expect(res, (scope: 'all', quickOutbox: false));
    });

    test('rule5FailedOutboxOrFailedFullRunReturnsAll', () {
      // Missing outbox on Bakalari account -> full retry.
      final missingOutbox = freshCache(fullAt: DateTime(2026, 9, 7, 9, 55));
      expect(
        chooseScheduledScope(
          bakCfg,
          missingOutbox,
          now,
          hasPendingExcuses: false,
          hasUnconfirmed: false,
        ),
        (scope: 'all', quickOutbox: false),
      );

      // Outbox older than full -> full retry.
      final olderOutbox = freshCache(
        fullAt: DateTime(2026, 9, 7, 9, 55),
        outboxAt: DateTime(2026, 9, 7, 9, 0),
      );
      expect(
        chooseScheduledScope(
          bakCfg,
          olderOutbox,
          now,
          hasPendingExcuses: false,
          hasUnconfirmed: false,
        ),
        (scope: 'all', quickOutbox: false),
      );

      // Strava-only account has no outbox and stays quick.
      expect(
        chooseScheduledScope(
          stravaOnlyCfg,
          missingOutbox,
          now,
          hasPendingExcuses: false,
          hasUnconfirmed: false,
        ),
        (scope: 'quick', quickOutbox: false),
      );

      // Previous full run failed -> full retry.
      final failedFull = freshCache(
        fullAt: DateTime(2026, 9, 7, 9, 55),
        outboxAt: DateTime(2026, 9, 7, 9, 55),
        failedAt: DateTime(2026, 9, 7, 9, 55).toIso8601String(),
        failedScope: 'all',
      );
      expect(
        chooseScheduledScope(
          bakCfg,
          failedFull,
          now,
          hasPendingExcuses: false,
          hasUnconfirmed: false,
        ),
        (scope: 'all', quickOutbox: false),
      );
    });

    test('quickTickSetsQuickOutboxOnlyWhenPendingAndOutboxAtLeast60MinOld', () {
      final cacheOldOutbox = freshCache(
        fullAt: DateTime(2026, 9, 7, 9, 0),
        outboxAt: DateTime(2026, 9, 7, 9, 0),
      );
      // Pending + 60 min old -> quickOutbox = true.
      expect(
        chooseScheduledScope(
          bakCfg,
          cacheOldOutbox,
          now,
          hasPendingExcuses: true,
          hasUnconfirmed: false,
        ),
        (scope: 'quick', quickOutbox: true),
      );
      // No pending -> quickOutbox = false.
      expect(
        chooseScheduledScope(
          bakCfg,
          cacheOldOutbox,
          now,
          hasPendingExcuses: false,
          hasUnconfirmed: false,
        ),
        (scope: 'quick', quickOutbox: false),
      );
      // Pending + 30 min old outbox -> quickOutbox = false.
      final cacheFreshOutbox = freshCache(
        fullAt: DateTime(2026, 9, 7, 9, 30),
        outboxAt: DateTime(2026, 9, 7, 9, 30),
      );
      expect(
        chooseScheduledScope(
          bakCfg,
          cacheFreshOutbox,
          now,
          hasPendingExcuses: true,
          hasUnconfirmed: false,
        ),
        (scope: 'quick', quickOutbox: false),
      );
    });
  });

  group('stravaQuickFetchDue', () {
    final cfg = defaultConfig()..['lunch_order_cutoff_time'] = '12:00';
    final cache = _schoolCache();

    test('missingStampIsDue', () {
      expect(
        stravaQuickFetchDue(
          {...cache, partUpdatedKey: <String, Object?>{}},
          cfg,
          DateTime(2026, 9, 7, 9, 0),
        ),
        isTrue,
      );
    });

    test('daytimeUses30MinOffHours60MinAndPreCutoff15Min', () {
      // Daytime (09:00): 20 min old -> false, 30 min old -> true.
      expect(
        stravaQuickFetchDue(
          {
            ...cache,
            partUpdatedKey: {'strava': DateTime(2026, 9, 7, 8, 40).toIso8601String()},
          },
          cfg,
          DateTime(2026, 9, 7, 9, 0),
        ),
        isFalse,
      );
      expect(
        stravaQuickFetchDue(
          {
            ...cache,
            partUpdatedKey: {'strava': DateTime(2026, 9, 7, 8, 30).toIso8601String()},
          },
          cfg,
          DateTime(2026, 9, 7, 9, 0),
        ),
        isTrue,
      );
      // Within 60 min before 12:00 cutoff (11:30): 15 min old -> true.
      expect(
        stravaQuickFetchDue(
          {
            ...cache,
            partUpdatedKey: {'strava': DateTime(2026, 9, 7, 11, 15).toIso8601String()},
          },
          cfg,
          DateTime(2026, 9, 7, 11, 30),
        ),
        isTrue,
      );
      // Off-hours (20:00): 45 min old -> false, 60 min old -> true.
      expect(
        stravaQuickFetchDue(
          {
            ...cache,
            partUpdatedKey: {'strava': DateTime(2026, 9, 7, 19, 15).toIso8601String()},
          },
          cfg,
          DateTime(2026, 9, 7, 20, 0),
        ),
        isFalse,
      );
      expect(
        stravaQuickFetchDue(
          {
            ...cache,
            partUpdatedKey: {'strava': DateTime(2026, 9, 7, 19, 0).toIso8601String()},
          },
          cfg,
          DateTime(2026, 9, 7, 20, 0),
        ),
        isTrue,
      );
    });
  });

  group('applyF6ScheduleDefaultsOnce', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('f6_defaults_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('freshInstallEmptyGlobalJsonWritesFourDefaultsOnce', () {
      final gFile = File(p.join(tmp.path, globalConfigFile))
        ..writeAsStringSync('{}');
      expect(applyF6ScheduleDefaultsOnce(tmp.path), isTrue);
      final data = jsonDecode(gFile.readAsStringSync()) as Map;
      expect(data['check_interval_minutes'], 5);
      expect(data['check_interval_mobile_minutes'], 5);
      expect(data['check_interval_off_hours_minutes'], 60);
      expect(data['refresh_wifi_always_fast'], isTrue);
      // Second call is a no-op.
      expect(applyF6ScheduleDefaultsOnce(tmp.path), isFalse);
    });

    test('preF6GlobalJsonOverwrites60OnceThenPreservesUserEdits', () {
      final gFile = File(p.join(tmp.path, globalConfigFile))
        ..writeAsStringSync(jsonEncode({
          'theme': 'light',
          'check_interval_minutes': 60,
        }));
      expect(applyF6ScheduleDefaultsOnce(tmp.path), isTrue);
      final after = jsonDecode(gFile.readAsStringSync()) as Map;
      expect(after['theme'], 'light');
      expect(after['check_interval_minutes'], 5);
      expect(after['check_interval_mobile_minutes'], 5);
      expect(after['check_interval_off_hours_minutes'], 60);
      expect(after['refresh_wifi_always_fast'], isTrue);

      // User later changes interval back to 60 -> preserved forever.
      after['check_interval_minutes'] = 60;
      gFile.writeAsStringSync(jsonEncode(after));
      expect(applyF6ScheduleDefaultsOnce(tmp.path), isFalse);
      final preserved = jsonDecode(gFile.readAsStringSync()) as Map;
      expect(preserved['check_interval_minutes'], 60);
    });

    test('degradedModeUpdatesRootConfigJson', () {
      final cFile = File(p.join(tmp.path, 'config.json'))
        ..writeAsStringSync(jsonEncode({'check_interval_minutes': 60, 'language': 'en'}));
      expect(applyF6ScheduleDefaultsOnce(tmp.path, degraded: true), isTrue);
      final after = jsonDecode(cFile.readAsStringSync()) as Map;
      expect(after['language'], 'en');
      expect(after['check_interval_minutes'], 5);
      expect(after['check_interval_mobile_minutes'], 5);
      expect(after['check_interval_off_hours_minutes'], 60);
      expect(after['refresh_wifi_always_fast'], isTrue);
    });

    test('postponesWhenLockBusyThenAppliesOnceReleased', () {
      final gPath = p.join(tmp.path, globalConfigFile);
      File(gPath).writeAsStringSync(jsonEncode({'check_interval_minutes': 60}));
      final lock = InterProcessLock('$gPath.lock');
      expect(lock.acquire(timeoutS: 1.0), isTrue);
      try {
        expect(
          applyF6ScheduleDefaultsOnce(tmp.path, lockTimeoutS: 0.05),
          isFalse,
        );
        final untouched =
            jsonDecode(File(gPath).readAsStringSync()) as Map;
        expect(untouched['check_interval_minutes'], 60);
        expect(untouched.containsKey('check_interval_mobile_minutes'), isFalse);
      } finally {
        lock.release();
      }
      // Next call succeeds once lock is free.
      expect(applyF6ScheduleDefaultsOnce(tmp.path), isTrue);
      final updated = jsonDecode(File(gPath).readAsStringSync()) as Map;
      expect(updated['check_interval_minutes'], 5);
    });
  });

  group('estimateDataUsage', () {
    test('matchesDesignF6Section2TableRows', () {
      // Row 1: Mobile 5 min daytime + 60 min off-hours (default mobile)
      final r1 = estimateDataUsage(defaultConfig());
      expect(r1.mobileSchoolDayMb, closeTo(5.8, 0.2));
      expect(r1.typicalMonthlyMobileMb, closeTo(85.0, 5.0));
      expect(r1.allMobileMonthlyMb, closeTo(145.0, 6.0));
      expect(r1.requestsPerSchoolDay, closeTo(490, 20));

      // Row 2: Mobile 10 min daytime + 60 min off-hours
      final r2 = estimateDataUsage({
        ...defaultConfig(),
        'check_interval_mobile_minutes': 10,
      });
      expect(r2.mobileSchoolDayMb, closeTo(4.7, 0.2));
      expect(r2.typicalMonthlyMobileMb, closeTo(62.0, 5.0));
      expect(r2.allMobileMonthlyMb, closeTo(120.0, 6.0));
      expect(r2.requestsPerSchoolDay, closeTo(310, 20));

      // Row 3: Wi-Fi 5 min 24/7 (default Wi-Fi)
      expect(r1.wifiSchoolDayMb, closeTo(8.5, 0.2));
      final r3KeepAlive = estimateDataUsage(defaultConfig(), persistentTls: true);
      expect(r3KeepAlive.wifiSchoolDayMb, closeTo(6.5, 0.2));

      // Row 4: Wi-Fi 5 min daytime + 60 min off-hours
      final r4 = estimateDataUsage({
        ...defaultConfig(),
        'refresh_wifi_always_fast': false,
      });
      expect(r4.wifiSchoolDayMb, closeTo(5.8, 0.2));
      final r4KeepAlive = estimateDataUsage(
        {...defaultConfig(), 'refresh_wifi_always_fast': false},
        persistentTls: true,
      );
      expect(r4KeepAlive.wifiSchoolDayMb, closeTo(5.0, 0.2));

      // Multi-account scales linearly.
      final rTwo = estimateDataUsage(defaultConfig(), accountCount: 2);
      expect(rTwo.mobileSchoolDayMb, closeTo(r1.mobileSchoolDayMb * 2, 0.01));
    });
  });
}
