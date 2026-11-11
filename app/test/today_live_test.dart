import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/today/today_controller.dart';
import 'package:app/features/today/today_live.dart';
import 'package:app/l10n/strings.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// The Ahem test font is far wider than the real one: a wide surface keeps
/// a picker and its buttons on one row, as on a desktop.
void _wideSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_today_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('todayControllerFor maps AppState data and delegates ignore/template', () {
    withClock(Clock.fixed(DateTime(2026, 9, 20, 12, 0)), () {
      final s = AppState(
        configData: {'your_signature': 'Jan Novák'},
        data: {
          'timetable': {
            '18.09.2026': [
              {
                'subject': 'Matematika',
                'time': '1. 8:00 - 8:45',
                'status': 'absent',
              },
            ],
          },
          'food': {
            '20.09.2026': {'1': 'Svíčková'},
          },
          'strava_ordered': {'20.09.2026': '1'},
        },
      );

      final c = todayControllerFor(s, now: DateTime(2026, 9, 20, 12, 0));
      final tasks = c.excuseTasks(today: DateTime(2026, 9, 20));
      expect(tasks, hasLength(1));
      expect(tasks.first.key, '2026-09-18|1|Matematika');
      expect(c.lunchText(DateTime(2026, 9, 20)), contains('Svíčková'));

      c.chooseTemplate(tasks.first.key, '0', 1);
      expect(s.pickedTemplates[tasks.first.key], 0);

      final hidden = c.ignoreExcuse(tasks.first.key);
      expect(hidden, tasks.first.key);
      expect(s.ignoredExcuseKeys, contains(tasks.first.key));

      expect(c.unignoreKeys([tasks.first.key]), isTrue);
      expect(s.ignoredExcuseKeys, isEmpty);
    });
  });

  testWidgets('LiveTodayView renders from appStateProvider and offers tutorial',
      (tester) async {
    await withClock(Clock.fixed(DateTime(2026, 9, 20, 12, 0)), () async {
      final s = AppState(
        configData: {
          'tutorials_done': ['intro'],
        },
        data: {
          'timetable': {
            '18.09.2026': [
              {
                'subject': 'Fyzika',
                'time': '2. 8:55 - 9:40',
                'status': 'absent',
              },
            ],
          },
        },
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => FixedAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveTodayView(
                tokens: AppTokens.dark(),
                now: DateTime(2026, 9, 20, 12, 0),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Fyzika'), findsWidgets);
      expect(s.tutorial?.$1, 'excuse');
    });
  });

  test('absentKeyFromExcuseTasksIsNeverSent', () async {
    final s = AppState(
      configData: {'your_signature': 'Jan Novák'},
      data: {
        'timetable': {
          '18.09.2026': [
            {
              'subject': 'Matematika',
              'time': '1 (8:00 - 8:45)',
              'status': 'absent',
            },
          ],
        },
      },
    );
    final c = todayControllerFor(s, now: DateTime(2026, 9, 20, 12, 0));
    final fakeRequest = ExcuseSendRequest(
      scope: 'single',
      key: '2026-09-18|99|NeznamyPredmet',
      label: 'Unknown',
      jobs: [
        const ExcuseJob(
          {'type': 'pure days'},
          'text',
        ),
      ],
    );
    final sent = await c.send(fakeRequest);
    expect(sent, isFalse);
    expect(c.lastMessage, Strings.get('excuse_failed'));
    expect(s.excuseLog, isEmpty);
  });

  testWidgets('dayCardSwitchSendsLessonsSeparately', (tester) async {
    _wideSurface(tester);
    await withClock(Clock.fixed(DateTime(2026, 9, 20, 12, 0)), () async {
      final s = AppState(
        configData: {
          'your_signature': 'Jan Novák',
          'bakalari_url': 'https://b.example.cz',
          'bakalari_username': 'u',
          'bakalari_password': 'p',
        },
        data: {
          'timetable': {
            '18.09.2026': [
              {
                'subject': 'Matematika',
                'teacher': 'T',
                'time': '1 (8:00 - 8:45)',
                'absenceType': 'Absent',
              },
              {
                'subject': 'Fyzika',
                'teacher': 'T',
                'time': '2 (8:55 - 9:40)',
                'absenceType': 'Absent',
              },
            ],
          },
          'sent_excuses_from': '2026-09-01',
        },
      )..demoMode = false;

      final calls = <(String, bool)>[];
      s.submitDayExcuseOverride = (dayIso, template, perLesson) {
        calls.add((dayIso, perLesson));
        return true;
      };

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => FixedAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveTodayView(
                tokens: AppTokens.dark(),
                now: DateTime(2026, 9, 20, 12, 0),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Initially, per_lesson is false
      final switchFinder = find.byType(Switch);
      expect(switchFinder, findsOneWidget);
      expect(tester.widget<Switch>(switchFinder).value, isFalse);

      final wholeDayBtn = find.text('Omluvit celý den');
      expect(wholeDayBtn, findsOneWidget);
      await tester.tap(wholeDayBtn);
      await tester.pumpAndSettle();

      // Switch to per_lesson = true
      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(tester.widget<Switch>(switchFinder).value, isTrue);
      final lessonsBtn = find.text('Omluvit 2 hodiny');
      expect(lessonsBtn, findsOneWidget);
      await tester.tap(lessonsBtn);
      await tester.pumpAndSettle();

      expect(calls, [
        ('2026-09-18', false),
        ('2026-09-18', true),
      ]);
    });
  });

  for (final started in [true, false]) {
    testWidgets(
        started
            ? 'startedSendNeverClaimsExcuseSent'
            : 'refusedSendShowsFailureNotSent', (tester) async {
      _wideSurface(tester);
      await withClock(Clock.fixed(DateTime(2026, 9, 20, 12, 0)), () async {
        final s = AppState(
          configData: {
            'your_signature': 'Jan Novák',
            'bakalari_url': 'https://b.example.cz',
            'bakalari_username': 'u',
            'bakalari_password': 'p',
          },
          data: {
            'timetable': {
              '18.09.2026': [
                {
                  'subject': 'Matematika',
                  'teacher': 'T',
                  'time': '1 (8:00 - 8:45)',
                  'absenceType': 'Absent',
                },
                {
                  'subject': 'Fyzika',
                  'teacher': 'T',
                  'time': '2 (8:55 - 9:40)',
                  'absenceType': 'Absent',
                },
              ],
            },
            'sent_excuses_from': '2026-09-01',
          },
        )..demoMode = false;
        // A worker that never reports back: the send has only started.
        s.submitDayExcuseOverride = (dayIso, template, perLesson) => started;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appStateProvider.overrideWith(() => FixedAppStateController(s)),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: LiveTodayView(
                  tokens: AppTokens.dark(),
                  now: DateTime(2026, 9, 20, 12, 0),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('Omluvit celý den'));
        await tester.pumpAndSettle();

        expect(find.text(Strings.get('excuse_sent')), findsNothing);
        expect(find.text(Strings.get('excuse_failed')),
            started ? findsNothing : findsOneWidget);
      });
    });
  }
}

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);

  @override
  AppState build() {
    fixed.onChanged = () {
      // ignore: avoid_self_assignment
      state = state;
    };
    return fixed;
  }
}
