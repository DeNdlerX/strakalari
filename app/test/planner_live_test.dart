import 'dart:io';

import 'package:app/controllers/app_state.dart' hide PlannerController;
import 'package:app/features/planner/planner_live.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_planner_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('plannerControllerFor delegates plan/unplan/target to AppState', () {
    withClock(Clock.fixed(DateTime(2026, 9, 10, 10, 0)), () {
      final s = AppState(
        data: {
          'absence': {'Matematika': 2.0},
          'timetable': {
            '11.09.2026': [
              {'subject': 'Matematika', 'time': '1. 8:00 - 8:45'},
            ],
          },
          'food': {
            '11.09.2026': {'1': 'Guláš', '9&-1&': 'Odhlášení'},
          },
        },
      );
      final c = plannerControllerFor(s);
      expect(c.planSkip('2026-09-11', 'Lékař'), isTrue);
      expect(s.plannedSkips, hasLength(1));
      expect(s.cancelledLunches, contains('11.09.2026'));

      expect(c.unplanEntry(c.plannedSkips.first), isTrue);
      expect(s.plannedSkips, isEmpty);
      expect(s.cancelledLunches, isEmpty);

      expect(c.setPlannerTarget(5), isTrue);
      expect(s.plannerTargetDays(), 5);
    });
  });

  testWidgets('LivePlannerView renders budgets and recommendations',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await withClock(Clock.fixed(DateTime(2026, 9, 10, 10, 0)), () async {
      final s = AppState(
        configData: {
          'tutorials_done': ['intro'],
        },
        data: {
          'absence': {'Matematika': 2.0},
          'timetable': {
            '11.09.2026': [
              {'subject': 'Matematika', 'time': '1. 8:00 - 8:45'},
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
              body: LivePlannerView(now: DateTime(2026, 9, 10, 10, 0)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('Matematika'), findsWidgets);
    });
  });
}

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);

  @override
  AppState build() => fixed;
}
