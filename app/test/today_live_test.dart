import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/today/today_live.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_today_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
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
}

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);

  @override
  AppState build() => fixed;
}
