import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:test/test.dart';

import 'package:strakalari_core/strakalari_core.dart';

import 'fake_bakalari.dart';

const _testBakRoot = 'https://bakaweb.school.cz';

class _NoExcuseCountingApp extends Strakalari {
  int excusePendingCalls = 0;

  _NoExcuseCountingApp({
    required super.configData,
    required super.dataDir,
    required BakalariClient client,
  }) {
    bakalariClient = client;
  }

  @override
  Future<int> excusePending() async {
    excusePendingCalls++;
    return 0;
  }
}

class _StravaCountingApp extends Strakalari {
  int stravaFetchCalls = 0;
  int stravaOrderCalls = 0;
  @override
  Map<String, Map<String, String>> foodDict = {};
  @override
  Map<String, String> orderedDict = {};

  _StravaCountingApp({
    required super.configData,
    required super.dataDir,
    required BakalariClient client,
  }) {
    bakalariClient = client;
  }

  @override
  Future<void> fetchStravaData() async {
    stravaFetchCalls++;
    foodDict = {
      '22.09.2026': {'t1&1&0': 'Kuřecí řízek', 't1&-1&0': 'x'},
    };
    orderedDict = {};
  }

  @override
  Future<bool> stravaOrderSelected(Map<String, String> orders,
      {String source = 'manual'}) async {
    stravaOrderCalls++;
    orderedDict.addAll(orders);
    return true;
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('f6_quick_refresh_');
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    clearKeyCache();
    BakalariSessionPool.instance.resetForTesting();
  });

  tearDown(() {
    BakalariSessionPool.instance.resetForTesting();
    setEnvironmentOverride(null);
    clearKeyCache();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> baseCfg({String excuseMode = 'confirm'}) => {
        ...defaultConfig(),
        'bakalari_url': '$_testBakRoot/login',
        'bakalari_username': fakeUser,
        'bakalari_password': fakePassword,
        'bakalari_password_encrypted': false,
        'use_strava': false,
        'go_back_weeks': 2,
        'go_forward_weeks': 1,
        'excuse_mode': excuseMode,
      };

  String gradesPage(List<Map<String, Object?>> marks) {
    final cells = [
      for (final m in marks)
        "<div class=\"mark\" data-clasif='${jsonEncode(m)}'>${m['MarkText']}</div>",
    ].join();
    return '<html><body>prubzna.aspx $cells</body></html>';
  }

  Map<String, Object?> permLesson() => {
        'IdentCode': '1       003T2RD',
        'day': 'Pondělí',
        'time': '1 (8:00 - 8:45)',
        'subjecttext': 'Matematika',
        'teacher': 'Mgr. Novák',
        'room': '104',
      };

  Map<String, Object?> lessonOn(
    DateTime day, {
    String subject = 'Matematika',
    String type = 'atom',
    String absencetext = '',
    String absenceType = '',
  }) =>
      {
        'IdentCode': '12026090703T2RD',
        'day': '${day.day}.${day.month}.${day.year}',
        'time': '1 (8:00 - 8:45)',
        'subjecttext': subject,
        'teacher': 'Mgr. Novák',
        'room': '104',
        if (type != 'atom') 'type': type,
        if (absencetext.isNotEmpty) 'absencetext': absencetext,
        if (absenceType.isNotEmpty) 'absenceType': absenceType,
      };

  group('F6 quick tier & per-part freshness (Commit 4)', () {
    test('steadyQuickTickMakesExact3RequestsEmitsOneLogAndLeavesLastUpdated',
        () async {
      final tFull = DateTime(2026, 9, 21, 8, 0); // Monday
      final tQuick = DateTime(2026, 9, 21, 8, 5);
      final cfg = baseCfg();

      final mark1 = {
        'id': '1',
        'nazev': 'Matematika',
        'MarkText': '1',
        'vaha': 5,
        'udel_datum': '18.9.2026',
        'strdatum': '18.9.2026',
        'caption': 'Test 1',
      };
      final widget1 = [
        {
          'grade': '1',
          'subject': 'Matematika',
          'note': 'Test 1',
          'date': '18.9.',
          'is_new': true,
        }
      ];

      FakeBakalari makeServer() => FakeBakalari({
            'GET /Marks/Widget': marksWidgetHtml(widget1),
            'GET /next/prubzna.aspx': gradesPage([mark1]),
            'POST /Timetable/substitutions/dates': {'success': true, 'data': <Object?>[]},
            'GET /Absence/Continuous/GetAbsenceBySubjects': {
              'data': [
                {'Name': 'Matematika', 'LessonCount': 10, 'Count': 1, 'Percent': 0.1}
              ],
            },
            'POST /Timetable/GetContentData': (FakeRequest req) {
              final body = jsonDecode(utf8.decode(req.body)) as Map;
              if (body['term'] == 'perm') return weekContent([permLesson()]);
              final d = DateTime.parse('${body['date']}');
              return weekContent([lessonOn(d)]);
            },
            'POST /Teaching/Subjects': {
              'data': [
                {'SubjectName': 'Matematika', 'TeacherName': 'Mgr. Novák'}
              ],
            },
            'GET /next/komens.aspx': outboxPageHtml(),
            'POST /next/komens.aspx': (_) =>
                dxReply('<div class="komens-messages-wrapper"></div>'),
          });

      // 1. Full run seeds cache, week hashes, marks_widget_v1, part_updated, timetable_history.
      final fullServer = makeServer();
      await withClock(Clock.fixed(tFull), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient =
              BakalariClient(cfg, transport: fullServer, dataDir: tmp.path);
        final res = await runRefresh(app, cfg, scope: 'all', now: tFull, dataDir: tmp.path);
        expect(res.ok, isTrue);
        expect(res.saved['last_updated'], '21.09.2026 08:00:00');
      });
      final afterFull = loadDataCache(dataDir: tmp.path);
      final origHistory = jsonEncode(afterFull[timetableHistoryKey]);
      final origPastCounts = jsonEncode(afterFull[absenceCountsAtPastFetchKey]);
      final origStable = jsonEncode(afterFull['stable_baseline']);

      // 2. Quick tick 5 min later with no changes -> EXACTLY 3 data requests (after login)!
      final quickServer = makeServer();
      final emitted = <String>[];
      await withClock(Clock.fixed(tQuick), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient =
              BakalariClient(cfg, transport: quickServer, dataDir: tmp.path);
        final res = await runRefresh(
          app,
          cfg,
          scope: 'quick',
          scheduled: true,
          now: tQuick,
          dataDir: tmp.path,
          emit: (k, [_ = const {}]) => emitted.add(k),
        );
        expect(res.ok, isTrue);
        expect(res.quickEventful, isFalse);
        expect(res.news, isEmpty);
      });

      final dataCalls = quickServer.requests
          .where((r) => r.url.path != '/login' && r.url.path != '/Login')
          .map((r) => '${r.method} ${r.url.path}')
          .toList();
      expect(dataCalls, [
        'GET /Marks/Widget',
        'POST /Timetable/substitutions/dates',
        'GET /Absence/Continuous/GetAbsenceBySubjects',
      ]);
      // Zero prubzna.aspx, zero GetContentData, zero Komens!
      expect(emitted, ['quick_check_log']);

      final afterQuick = loadDataCache(dataDir: tmp.path);
      // last_updated did NOT move; part_updated['quick'] DID move.
      expect(afterQuick['last_updated'], '21.09.2026 08:00:00');
      expect(partUpdatedTime(afterQuick, 'full'), tFull);
      expect(partUpdatedTime(afterQuick, 'quick'), tQuick);
      // Quick tick never touched timetable_history, absence_counts_at_past_fetch, or stable_baseline.
      expect(jsonEncode(afterQuick[timetableHistoryKey]), origHistory);
      expect(jsonEncode(afterQuick[absenceCountsAtPastFetchKey]), origPastCounts);
      expect(jsonEncode(afterQuick['stable_baseline']), origStable);
    });

    test('quickTickNeverRunsAutoExcuseEvenInAutoModeAndWithQuickOutbox (R8a M2)',
        () async {
      final tQuick = DateTime(2026, 9, 21, 9, 5);
      final cfg = baseCfg(excuseMode: 'auto');

      saveDataCache({
        'last_updated': '21.09.2026 08:00:00',
        marksWidgetKey: <Object?>[],
        substitutionsWeekHashesKey: <String, String>{},
        'absence': {'Matematika': 10.0},
        'absence_details': {'Matematika': {'missed_hours': 1, 'total_hours': 10}},
        partUpdatedKey: {
          'full': '2026-09-21T08:00:00',
          'timetable': '2026-09-21T08:50:00',
          'outbox': '2026-09-21T08:00:00',
        },
        outboxFormKey: {
          'path': '/next/komens.aspx?s=rok&l=o',
          'viewstate': 'vs-year',
          'viewstate_generator': 'VSG12345',
          'event_validation': 'ev-year',
          'period_start': '2026-08-20',
          'period_end': '2027-08-31',
          'fetched_at': '2026-09-21T08:00:00',
        },
      }, dataDir: tmp.path);

      final server = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([]),
        'POST /Timetable/substitutions/dates': {'success': true, 'data': <Object?>[]},
        'GET /Absence/Continuous/GetAbsenceBySubjects': {
          'data': [
            {'Name': 'Matematika', 'LessonCount': 10, 'Count': 1, 'Percent': 0.1}
          ],
        },
        'POST /Timetable/GetContentData': (FakeRequest req) {
          final d = DateTime.parse('${(jsonDecode(utf8.decode(req.body)) as Map)['date']}');
          return weekContent([lessonOn(d)]);
        },
        'POST /next/komens.aspx': (_) => dxReply(
              '<div class="komens-messages-wrapper">'
              '<table data-idmsg="901" data-sortdate="0:2026-09-21T08:30:00" data-msgtype="OMLUVENKA"></table>'
              '</div>',
            ),
        'POST /Komens/GetMessageDataAsync': (_) => {
              'Kind': 'OMLUVENKA',
              'DateFrom': '18.09.2026',
              'DateTo': '18.09.2026',
            },
      });

      await withClock(Clock.fixed(tQuick), () async {
        final app = _NoExcuseCountingApp(
          configData: cfg,
          dataDir: tmp.path,
          client: BakalariClient(cfg, transport: server, dataDir: tmp.path),
        );
        final res = await runRefresh(
          app,
          cfg,
          scope: 'quick',
          scheduled: true,
          quickOutbox: true,
          now: tQuick,
          dataDir: tmp.path,
        );
        expect(res.ok, isTrue);
        expect(res.errors, isEmpty);
        // Scope lock: NEVER calls excusePending in a quick tick!
        expect(app.excusePendingCalls, 0);
        // Outbox was read via 3-field cached callback (0 GET /next/komens.aspx!)
        expect(server.calls('GET', '/next/komens.aspx'), isEmpty);
        expect(server.calls('POST', '/next/komens.aspx'), hasLength(1));
        // Web excuse was merged into local history!
        final (hist, _) = app.loadHistory();
        expect(hist.any((e) => e['starting_day'] == '18.09.2026'), isTrue);
        expect(partUpdatedTime(loadDataCache(dataDir: tmp.path), 'outbox'), tQuick);
      });
    });

    test('newMarkDetectedInOneQuickTickAndBrokenWidgetAndMarksThrottled (R8a S3)',
        () async {
      final t1 = DateTime(2026, 9, 21, 9, 0);
      final cfg = baseCfg();
      final markOld = {
        'id': '1',
        'nazev': 'Matematika',
        'MarkText': '2',
        'vaha': 5,
        'udel_datum': '18.9.2026',
        'strdatum': '18.9.2026',
        'caption': 'Test 1',
      };
      final markNew = {
        'id': '2',
        'nazev': 'Fyzika',
        'MarkText': '1',
        'vaha': 10,
        'udel_datum': '21.9.2026',
        'strdatum': '21.9.2026',
        'caption': 'Laboratoř',
      };
      saveDataCache({
        'last_updated': '21.09.2026 08:00:00',
        'grades': {
          'Matematika': [{'Grade': '2', 'Weight': 5, 'Date': '18.09.2026'}],
        },
        marksWidgetKey: [
          {'grade': '2', 'subject': 'Matematika', 'note': 'Test 1', 'date': '18.9.', 'is_new': false}
        ],
        substitutionsWeekHashesKey: substitutionsByWeekHashes(
          const [],
          [DateTime(2026, 9, 21), DateTime(2026, 9, 28)],
        ),
        'absence': {'Matematika': 10.0},
        'absence_details': {'Matematika': {'missed_hours': 1, 'total_hours': 10}},
        partUpdatedKey: {
          'full': '2026-09-21T08:00:00',
          'timetable': '2026-09-21T08:50:00',
          'marks': '2026-09-21T08:50:00',
        },
      }, dataDir: tmp.path);

      // 1. Widget changed -> loads prubzna.aspx and notifies new_mark in ONE quick tick!
      final s1 = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([
          {'grade': '1', 'subject': 'Fyzika', 'note': 'Laboratoř', 'date': '21.9.', 'is_new': true},
          {'grade': '2', 'subject': 'Matematika', 'note': 'Test 1', 'date': '18.9.', 'is_new': false},
        ]),
        'GET /next/prubzna.aspx': gradesPage([markOld, markNew]),
        'POST /Timetable/substitutions/dates': {'success': true, 'data': <Object?>[]},
        'GET /Absence/Continuous/GetAbsenceBySubjects': {
          'data': [{'Name': 'Matematika', 'LessonCount': 10, 'Count': 1, 'Percent': 0.1}],
        },
      });
      await withClock(Clock.fixed(t1), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s1, dataDir: tmp.path);
        final res = await runRefresh(app, cfg, scope: 'quick', now: t1, dataDir: tmp.path);
        expect(s1.calls('GET', '/next/prubzna.aspx'), hasLength(1));
        expect(res.news.any((n) => n.$1 == 'new_mark'), isTrue);
        expect(res.quickEventful, isTrue);
      });

      // 2. Broken marks page (HTTP 500) -> retried on t2, throttled at t2+5m!
      final t2 = DateTime(2026, 9, 21, 9, 5);
      final s2 = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([
          {'grade': '3', 'subject': 'Chemie', 'note': 'Kvíz', 'date': '21.9.', 'is_new': true},
        ]),
        'GET /next/prubzna.aspx':
            HttpResponseData(statusCode: 500, url: Uri.parse(fakeRoot)),
        'POST /Timetable/substitutions/dates': {'success': true, 'data': <Object?>[]},
        'GET /Absence/Continuous/GetAbsenceBySubjects': {
          'data': [{'Name': 'Matematika', 'LessonCount': 10, 'Count': 1, 'Percent': 0.1}],
        },
      });
      await withClock(Clock.fixed(t2), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s2, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'quick', now: t2, dataDir: tmp.path);
        expect(s2.calls('GET', '/next/prubzna.aspx'), hasLength(1));
        expect(partUpdatedTime(loadDataCache(dataDir: tmp.path), 'marks'), t1);
      });

      // 5 min later: prubzna.aspx is throttled (0 calls)!
      final t3 = DateTime(2026, 9, 21, 9, 10);
      await withClock(Clock.fixed(t3), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s2, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'quick', now: t3, dataDir: tmp.path);
        expect(s2.calls('GET', '/next/prubzna.aspx'), hasLength(1));
      });
    });

    test('feedChangeNextWeekFetchesOnlyNextWeekAndAbsenceGrowthPullsBackdatedWeek',
        () async {
      final monThis = DateTime(2026, 9, 21); // Monday
      final monNext = DateTime(2026, 9, 28);
      final monPrev = DateTime(2026, 9, 14);
      final now = DateTime(2026, 9, 21, 9, 0);
      final cfg = baseCfg();

      saveDataCache({
        'last_updated': '21.09.2026 08:00:00',
        marksWidgetKey: <Object?>[],
        substitutionsWeekHashesKey:
            substitutionsByWeekHashes(const [], [monThis, monNext]),
        'absence': {'Matematika': 10.0},
        'absence_details': {'Matematika': {'missed_hours': 1, 'total_hours': 10}},
        'timetable': {
          '14.09.2026': [
            {'hour': '1', 'time': '1 (8:00 - 8:45)', 'subject': 'Matematika', 'status': 'normal'}
          ],
          '21.09.2026': [
            {'hour': '1', 'time': '1 (8:00 - 8:45)', 'subject': 'Matematika', 'status': 'normal'}
          ],
        },
        partUpdatedKey: {
          'full': '2026-09-21T08:00:00',
          'timetable': '2026-09-21T08:50:00',
          'marks': '2026-09-21T08:50:00',
        },
      }, dataDir: tmp.path);

      // 1. Feed change ONLY on next week (28.09.2026) + LessonCount growth only -> fetches ONLY next week!
      final sNext = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([]),
        'POST /Timetable/substitutions/dates': {
          'success': true,
          'data': [
            {
              'Changes': [
                {
                  'Day': 'pondělí 28.9.2026',
                  'HourLabel': '1. hod',
                  'TimeLabel': '8:00 - 8:45',
                  'ChangeType': 'Canceled',
                  'Description': 'Odpadá',
                  'ChangeLessonInfo': {'SubjectAbbrev': 'M'},
                }
              ],
            }
          ],
        },
        'GET /Absence/Continuous/GetAbsenceBySubjects': {
          'data': [
            // LessonCount grew (10 -> 12), Count stayed 1 -> no absence week fetch!
            {'Name': 'Matematika', 'LessonCount': 12, 'Count': 1, 'Percent': 0.08}
          ],
        },
        'POST /Timetable/GetContentData': (FakeRequest req) {
          final d = DateTime.parse('${(jsonDecode(utf8.decode(req.body)) as Map)['date']}');
          return weekContent([lessonOn(d)]);
        },
      });
      await withClock(Clock.fixed(now), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: sNext, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'quick', now: now, dataDir: tmp.path);
      });
      final weekCalls = sNext.calls('POST', '/Timetable/GetContentData');
      expect(weekCalls, hasLength(1));
      expect(
        (jsonDecode(utf8.decode(weekCalls.single.body)) as Map)['date'],
        '2026-09-28',
      );

      // 2. Absence Count grows (1 -> 2) with back-dated absence on last week (14.09.2026):
      //    fetches this week (0), sees no new absence, then pulls last week (-1) and notifies!
      final now2 = DateTime(2026, 9, 21, 9, 5);
      final sAbs = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([]),
        'POST /Timetable/substitutions/dates': {
          'success': true,
          'data': [
            {
              'Changes': [
                {
                  'Day': 'pondělí 28.9.2026',
                  'HourLabel': '1. hod',
                  'TimeLabel': '8:00 - 8:45',
                  'ChangeType': 'Canceled',
                  'Description': 'Odpadá',
                  'ChangeLessonInfo': {'SubjectAbbrev': 'M'},
                }
              ],
            }
          ],
        },
        'GET /Absence/Continuous/GetAbsenceBySubjects': {
          'data': [
            {'Name': 'Matematika', 'LessonCount': 12, 'Count': 2, 'Percent': 0.16}
          ],
        },
        'POST /Timetable/GetContentData': (FakeRequest req) {
          final d = DateTime.parse('${(jsonDecode(utf8.decode(req.body)) as Map)['date']}');
          if (d == monPrev) {
            return weekContent([
              lessonOn(monPrev, absencetext: 'Neomluveno', absenceType: 'unexcused'),
            ]);
          }
          return weekContent([lessonOn(d)]);
        },
      });
      await withClock(Clock.fixed(now2), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: sAbs, dataDir: tmp.path);
        final res = await runRefresh(app, cfg, scope: 'quick', now: now2, dataDir: tmp.path);
        final dates = [
          for (final c in sAbs.calls('POST', '/Timetable/GetContentData'))
            '${(jsonDecode(utf8.decode(c.body)) as Map)['date']}',
        ];
        expect(dates, ['2026-09-21', '2026-09-14']);
        expect(res.news.any((n) => n.$1 == 'new_absence'), isTrue);
      });
    });

    test('scheduledFullRunSkipsDailyPartsUntilAbsenceCountGrowsPastSnapshot (R8a S1)',
        () async {
      final t1 = DateTime(2026, 9, 21, 7, 0);
      final t2 = DateTime(2026, 9, 21, 13, 0);
      final t3 = DateTime(2026, 9, 21, 19, 0);
      final cfg = {...baseCfg(), 'go_back_weeks': 3};
      var missedCount = 1;

      FakeBakalari makeServer() => FakeBakalari({
            'GET /Marks/Widget': marksWidgetHtml([]),
            'GET /next/prubzna.aspx': gradesPage([]),
            'POST /Timetable/substitutions/dates': {'success': true, 'data': <Object?>[]},
            'GET /Absence/Continuous/GetAbsenceBySubjects': (_) => {
                  'data': [
                    {
                      'Name': 'Matematika',
                      'LessonCount': 10,
                      'Count': missedCount,
                      'Percent': missedCount / 10,
                    }
                  ],
                },
            'POST /Timetable/GetContentData': (FakeRequest req) {
              final body = jsonDecode(utf8.decode(req.body)) as Map;
              if (body['term'] == 'perm') return weekContent([permLesson()]);
              final d = DateTime.parse('${body['date']}');
              return weekContent([lessonOn(d)]);
            },
            'POST /Teaching/Subjects': {
              'data': [
                {'SubjectName': 'Matematika', 'TeacherName': 'Mgr. Novák'}
              ],
            },
            'GET /next/komens.aspx': outboxPageHtml(),
            'POST /next/komens.aspx': (_) =>
                dxReply('<div class="komens-messages-wrapper"></div>'),
          });

      // 1. First full run of the day fetches perm, subjects, and all weeks (-2, -1, 0, +1).
      final s1 = makeServer();
      await withClock(Clock.fixed(t1), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s1, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'all', scheduled: true, now: t1, dataDir: tmp.path);
      });
      expect(s1.calls('POST', '/Teaching/Subjects'), hasLength(1));
      expect(
        s1.calls('POST', '/Timetable/GetContentData').where(
              (c) => (jsonDecode(utf8.decode(c.body)) as Map)['term'] == 'perm',
            ),
        hasLength(1),
      );

      // 2. Second scheduled full run same day with unchanged Count -> skips perm, subjects, past weeks, and Komens GET!
      final s2 = makeServer();
      await withClock(Clock.fixed(t2), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s2, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'all', scheduled: true, now: t2, dataDir: tmp.path);
      });
      expect(s2.calls('POST', '/Teaching/Subjects'), isEmpty);
      expect(s2.calls('GET', '/next/komens.aspx'), isEmpty);
      final s2Cal = s2.calls('POST', '/Timetable/GetContentData');
      expect(
        s2Cal.where((c) => (jsonDecode(utf8.decode(c.body)) as Map)['term'] == 'perm'),
        isEmpty,
      );
      // Only current + forward week (0, +1) -> 2 calls instead of 4+!
      expect(s2Cal, hasLength(2));

      // 3. Absence Count grows (1 -> 2, e.g. entered 2 weeks back): next scheduled full run pulls past weeks again!
      missedCount = 2;
      final s3 = makeServer();
      await withClock(Clock.fixed(t3), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s3, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'all', scheduled: true, now: t3, dataDir: tmp.path);
      });
      final s3Dates = [
        for (final c in s3.calls('POST', '/Timetable/GetContentData'))
          '${(jsonDecode(utf8.decode(c.body)) as Map)['date']}',
      ];
      expect(s3Dates, contains('2026-09-07')); // 2 weeks back!
    });

    test('brokenMarksWidgetFallsBackLoudlyOnceThenThrottlesHourly (R8a S3)',
        () async {
      final t1 = DateTime(2026, 9, 21, 9, 0);
      final t2 = DateTime(2026, 9, 21, 9, 5);
      final t3 = DateTime(2026, 9, 21, 10, 5);
      final cfg = baseCfg();
      saveDataCache({
        'last_updated': '21.09.2026 08:00:00',
        'grades': {
          'Matematika': [{'Grade': '2', 'Weight': 5, 'Date': '18.09.2026'}],
        },
        marksWidgetKey: [
          {'grade': '2', 'subject': 'Matematika', 'note': 'Test 1', 'date': '18.9.', 'is_new': false}
        ],
        substitutionsWeekHashesKey: substitutionsByWeekHashes(
          const [],
          [DateTime(2026, 9, 21), DateTime(2026, 9, 28)],
        ),
        'absence': {'Matematika': 10.0},
        'absence_details': {'Matematika': {'missed_hours': 1, 'total_hours': 10}},
        partUpdatedKey: {
          'full': '2026-09-21T08:00:00',
          'marks': '2026-09-21T08:00:00',
          'timetable': '2026-09-21T08:50:00',
        },
      }, dataDir: tmp.path);

      final s = FakeBakalari({
        'GET /Marks/Widget':
            HttpResponseData(statusCode: 500, url: Uri.parse(_testBakRoot)),
        'GET /next/prubzna.aspx': gradesPage([
          {
            'id': '1',
            'nazev': 'Matematika',
            'MarkText': '2',
            'vaha': 5,
            'udel_datum': '18.9.2026',
            'strdatum': '18.9.2026',
            'caption': 'Test 1',
          }
        ]),
        'POST /Timetable/substitutions/dates': {'success': true, 'data': <Object?>[]},
        'GET /Absence/Continuous/GetAbsenceBySubjects': {
          'data': [{'Name': 'Matematika', 'LessonCount': 10, 'Count': 1, 'Percent': 0.1}],
        },
        'POST /Timetable/GetContentData': (FakeRequest req) {
          final d = DateTime.parse('${(jsonDecode(utf8.decode(req.body)) as Map)['date']}');
          return weekContent([lessonOn(d)]);
        },
      });

      // First broken tick: falls back immediately to prubzna.aspx.
      await withClock(Clock.fixed(t1), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'quick', now: t1, dataDir: tmp.path);
        expect(s.calls('GET', '/next/prubzna.aspx'), hasLength(1));
        expect(partUpdatedTime(loadDataCache(dataDir: tmp.path), 'marks'), t1);
      });

      // 5 min later: consecutive broken tick is throttled (no prubzna.aspx).
      await withClock(Clock.fixed(t2), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'quick', now: t2, dataDir: tmp.path);
        expect(s.calls('GET', '/next/prubzna.aspx'), hasLength(1));
      });

      // 65 min later: hourly fallback fires again.
      await withClock(Clock.fixed(t3), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'quick', now: t3, dataDir: tmp.path);
        expect(s.calls('GET', '/next/prubzna.aspx'), hasLength(2));
        expect(partUpdatedTime(loadDataCache(dataDir: tmp.path), 'marks'), t3);
      });
    });

    test('failedQuickTierKeepsCachedDataAndLeavesPartUpdatedUntouched', () async {
      final t1 = DateTime(2026, 9, 21, 9, 0);
      final cfg = baseCfg();
      saveDataCache({
        'last_updated': '21.09.2026 08:00:00',
        'absence': {'Matematika': 12.5},
        'absence_details': {'Matematika': {'missed_hours': 1, 'total_hours': 8}},
        marksWidgetKey: <Object?>[],
        substitutionsWeekHashesKey: substitutionsByWeekHashes(
          const [],
          [DateTime(2026, 9, 21), DateTime(2026, 9, 28)],
        ),
        partUpdatedKey: {
          'full': '2026-09-21T08:00:00',
          'absence': '2026-09-21T08:00:00',
          'timetable': '2026-09-21T08:00:00',
          'marks': '2026-09-21T08:00:00',
        },
      }, dataDir: tmp.path);

      final s = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([]),
        'POST /Timetable/substitutions/dates':
            HttpResponseData(statusCode: 500, url: Uri.parse(_testBakRoot)),
        'GET /Absence/Continuous/GetAbsenceBySubjects':
            HttpResponseData(statusCode: 500, url: Uri.parse(_testBakRoot)),
        'GET /Absence/Continuous':
            HttpResponseData(statusCode: 500, url: Uri.parse(_testBakRoot)),
      });

      await withClock(Clock.fixed(t1), () async {
        final app = Strakalari(configData: cfg, dataDir: tmp.path)
          ..bakalariClient = BakalariClient(cfg, transport: s, dataDir: tmp.path);
        await runRefresh(app, cfg, scope: 'quick', now: t1, dataDir: tmp.path);
      });

      final saved = loadDataCache(dataDir: tmp.path);
      expect(saved['absence'], {'Matematika': 12.5});
      expect(partUpdatedTime(saved, 'absence'), DateTime(2026, 9, 21, 8, 0));
      expect(partUpdatedTime(saved, 'timetable'), DateTime(2026, 9, 21, 8, 0));
      expect(partUpdatedTime(saved, 'marks'), t1); // marks widget succeeded!
      expect(saved['last_updated'], '21.09.2026 08:00:00');
    });

    test('quickTickStravaConditionalFetchAndAutomationPausedStopsAutoLunch',
        () async {
      final t1 = DateTime(2026, 9, 21, 9, 0);
      final cfg = {
        ...baseCfg(),
        'use_strava': true,
        'strava_canteen_id': '1234',
        'strava_username': 'stravnik',
        'strava_password': 'tajne',
        'strava_password_encrypted': false,
        'strava_order_mode': 'auto',
        'automation_paused': true,
      };
      saveDataCache({
        'last_updated': '21.09.2026 08:00:00',
        marksWidgetKey: <Object?>[],
        substitutionsWeekHashesKey: substitutionsByWeekHashes(
          const [],
          [DateTime(2026, 9, 21), DateTime(2026, 9, 28)],
        ),
        'absence': {'Matematika': 10.0},
        'absence_details': {'Matematika': {'missed_hours': 1, 'total_hours': 10}},
        partUpdatedKey: {
          'full': '2026-09-21T08:00:00',
          'timetable': '2026-09-21T08:50:00',
          'strava': '2026-09-21T05:00:00', // > 60 min old -> Strava due!
        },
      }, dataDir: tmp.path);

      final s = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([]),
        'POST /Timetable/substitutions/dates': {'success': true, 'data': <Object?>[]},
        'GET /Absence/Continuous/GetAbsenceBySubjects': {
          'data': [{'Name': 'Matematika', 'LessonCount': 10, 'Count': 1, 'Percent': 0.1}],
        },
      });

      // 1. Lunches stale + automation_paused -> fetches Strava, but NEVER auto-orders!
      await withClock(Clock.fixed(t1), () async {
        final app = _StravaCountingApp(
          configData: cfg,
          dataDir: tmp.path,
          client: BakalariClient(cfg, transport: s, dataDir: tmp.path),
        );
        final res = await runRefresh(app, cfg, scope: 'quick', now: t1, dataDir: tmp.path);
        expect(res.ok, isTrue);
        expect(app.stravaFetchCalls, 1);
        expect(app.stravaOrderCalls, 0);
        expect(partUpdatedTime(loadDataCache(dataDir: tmp.path), 'strava'), t1);
      });

      // 2. 5 min later: lunches fresh (< 60 min) -> skips Strava completely!
      final t2 = DateTime(2026, 9, 21, 9, 5);
      await withClock(Clock.fixed(t2), () async {
        final app = _StravaCountingApp(
          configData: cfg,
          dataDir: tmp.path,
          client: BakalariClient(cfg, transport: s, dataDir: tmp.path),
        );
        final res = await runRefresh(app, cfg, scope: 'quick', now: t2, dataDir: tmp.path);
        expect(res.ok, isTrue);
        expect(app.stravaFetchCalls, 0);
      });
    });
  });
}
