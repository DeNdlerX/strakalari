import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/today/today_live.dart';
import 'package:app/features/today/today_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of `tests/test_excuse_day_scope.py` (state cases).
Map<String, Object?> _lesson(int period, String subject, {bool absent = true}) =>
    {
      'subject': subject,
      'teacher': 'T',
      'time': '$period (8:00 - 8:45)',
      'absenceType': absent ? 'Absent' : 'NoAbsent',
    };

Map<String, Object?> _lateLesson(int period, String subject) => {
      'subject': subject,
      'teacher': 'T',
      'time': '$period (8:00 - 8:45)',
      'absenceType': 'AbsentLate',
    };

Map<String, Object?> _earlyLesson(int period, String subject) => {
      'subject': subject,
      'teacher': 'T',
      'time': '$period (8:00 - 8:45)',
      'absenceType': 'AbsentSoon',
    };

class _RecordingApp extends Strakalari {
  final List<(Map<String, Object?>, String?)> sent = [];

  @override
  String get excuseMode => 'confirm';

  @override
  Future<String> sendExcuseOutcome(
      Map<String, Object?> excuse, [String? customText]) async {
    sent.add((Map<String, Object?>.of(excuse), customText));
    return 'sent';
  }

  @override
  void close() {}
}

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_day_scope_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  AppState dayState(List<Map<String, Object?>> lessons) => AppState(
        configData: {
          'bakalari_url': 'https://b.example.cz',
          'bakalari_username': 'u',
          'bakalari_password': 'p',
        },
        data: {
          'timetable': {'18.09.2026': lessons},
          'sent_excuses_from': '2026-09-01',
        },
      )..demoMode = false;

  T inSept<T>(T Function() body) =>
      withClock(Clock.fixed(DateTime(2026, 9, 20, 12, 0)), body);

  test('fullyAbsentDayIsOneWholeDayExcuse', () {
    inSept(() {
      final st = dayState([_lesson(1, 'M'), _lesson(2, 'F')]);
      expect(st.dayFullyAbsent('2026-09-18'), isTrue);
      expect(st.dayExcusePlan('2026-09-18'), [
        {
          'type': 'pure days',
          'starting_day': '18.09.2026',
          'ending_day': '18.09.2026',
        }
      ]);
    });
  });

  test('partialDayBecomesLessonRanges', () {
    inSept(() {
      final st = dayState([
        _lateLesson(1, 'M'),
        _lesson(2, 'F'),
        _lesson(3, 'Ch', absent: false),
        _lesson(4, 'D'),
        _lesson(5, 'Z'),
      ]);
      expect(st.dayFullyAbsent('2026-09-18'), isFalse);
      final plan = st.dayExcusePlan('2026-09-18');
      expect(
        plan.any((p) =>
            p['type'] == 'income' &&
            p['starting_day'] == '18.09.2026' &&
            p['ending_day'] == '18.09.2026' &&
            p['starting_lesson'] == 1 &&
            p['ending_lesson'] == 1),
        isTrue,
      );
      final ranges = [
        for (final p in plan)
          if (p['type'] == 'days and hours')
            (p['starting_lesson'] as int, p['ending_lesson'] as int),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      expect(ranges, [(2, 2), (4, 5)]);
    });
  });

  test('perLessonSplitsAFullyAbsentDay', () {
    inSept(() {
      final st = dayState([_lesson(2, 'F'), _lesson(1, 'M')]);
      expect(st.dayExcusePlan('2026-09-18', true), [
        {
          'type': 'days and hours',
          'starting_day': '18.09.2026',
          'ending_day': '18.09.2026',
          'starting_lesson': 1,
          'ending_lesson': 1,
        },
        {
          'type': 'days and hours',
          'starting_day': '18.09.2026',
          'ending_day': '18.09.2026',
          'starting_lesson': 2,
          'ending_lesson': 2,
        },
      ]);
    });
  });

  test('perLessonNeverMergesRangesAndKeepsLateArrivals', () {
    inSept(() {
      final st = dayState([
        _lateLesson(1, 'M'),
        _lesson(2, 'F'),
        _lesson(3, 'Ch', absent: false),
        _lesson(4, 'D'),
        _lesson(5, 'Z'),
        _earlyLesson(6, 'Tv'),
      ]);
      final plan = st.dayExcusePlan('2026-09-18', true);
      expect(
        [
          for (final p in plan)
            (p['type'], p['starting_lesson'], p['ending_lesson'])
        ],
        [
          ('income', 1, 1),
          ('days and hours', 2, 2),
          ('days and hours', 4, 4),
          ('days and hours', 5, 5),
          ('soon', 6, 6),
        ],
      );
    });
  });

  test('submitDayExcusePerLessonSendsOneMessagePerLesson', () async {
    await inSept(() async {
      final st = dayState([_lesson(1, 'M'), _lesson(2, 'F')]);
      final rec = _RecordingApp();
      final jobs = <Future<void> Function()>[];
      st.createApp = ({onLog, configData}) => rec;
      st.spawn = (job, name) => jobs.add(job);
      expect(st.submitDayExcuse('2026-09-18', 'Omluvte', true), isTrue);
      await jobs.single();
      expect(
        [
          for (final (e, text) in rec.sent)
            (e['type'], e['starting_lesson'], e['ending_lesson'], text)
        ],
        [
          ('days and hours', 1, 1, 'Omluvte'),
          ('days and hours', 2, 2, 'Omluvte'),
        ],
      );
      expect(
        [for (final entry in st.excuseLog) entry['key']]..sort(),
        ['2026-09-18|1|M', '2026-09-18|2|F'],
      );
      expect(st.sendingExcuses, isEmpty);
    });
  });

  test('submitDayExcuseWithoutTheSwitchStaysOneWholeDay', () async {
    await inSept(() async {
      final st = dayState([_lesson(1, 'M'), _lesson(2, 'F')]);
      final rec = _RecordingApp();
      final jobs = <Future<void> Function()>[];
      st.createApp = ({onLog, configData}) => rec;
      st.spawn = (job, name) => jobs.add(job);
      expect(st.submitDayExcuse('2026-09-18', 'Omluvte'), isTrue);
      await jobs.single();
      expect([for (final (e, _) in rec.sent) e['type']], ['pure days']);
    });
  });

  test('dayCardSwitchIsRememberedAndAFailedSaveRestoresIt', () {
    final st = dayState([_lesson(1, 'M')]);
    expect(st.excuseDayPerLesson(), isFalse);
    expect(st.setExcuseDayPerLesson(true), isTrue);
    expect(st.excuseDayPerLesson(), isTrue);

    // Make config.json a directory so save() fails.
    final cfgFile = File('${dir.path}/config.json');
    if (cfgFile.existsSync()) cfgFile.deleteSync();
    Directory('${dir.path}/config.json').createSync();
    addTearDown(() {
      final d = Directory('${dir.path}/config.json');
      if (d.existsSync()) d.deleteSync(recursive: true);
    });
    expect(st.setExcuseDayPerLesson(false), isFalse);
    expect(st.excuseDayPerLesson(), isTrue);
  });

  testWidgets('dayCardSwitchSendsLessonsSeparately', (tester) async {
    await inSept(() async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final st = dayState([_lesson(1, 'M'), _lesson(2, 'F')]);
      st.config.data['your_signature'] = 'Jan Novák';

      final c = todayControllerFor(st);
      final calls = <(String, bool)>[];
      c.onSend = (request) async {
        calls.add((request.key.replaceFirst('day|', ''), request.perLesson));
        return true;
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TodayView(
              controller: c,
              tokens: AppTokens.dark(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.text(Strings.get('excuse_day')), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, Strings.get('excuse_day')));
      await tester.pump();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      final btnLabel = Strings.format('excuse_lessons', {'lessons': '2 hodiny'});
      expect(find.text(btnLabel), findsOneWidget);
      expect(find.textContaining('2 hodiny zvlášť'), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, btnLabel));
      await tester.pump();

      expect(calls, [('2026-09-18', false), ('2026-09-18', true)]);
    });
  });
}
