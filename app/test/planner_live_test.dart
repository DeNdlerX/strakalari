import 'dart:io';

import 'package:app/controllers/app_state.dart' hide PlannerController;
import 'package:app/features/absences/absences_live.dart';
import 'package:app/features/planner/planner_live.dart';
import 'package:app/l10n/strings.dart';
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

  testWidgets('LiveAbsencesView renders subjects, budgets and recommendations',
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
              body: LiveAbsencesView(now: DateTime(2026, 9, 10, 10, 0)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text(Strings.get('abs_subjects_section').toUpperCase()),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('abs:subjects')),
          matching: find.text('Matematika'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('abs:subjects')),
          matching: find.text('2.0 %'),
        ),
        findsOneWidget,
      );

      // Recommendations live on LivePlannerPage.
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('planner_half'),
          overrides: [
            appStateProvider.overrideWith(() => FixedAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LivePlannerPage(now: DateTime(2026, 9, 10, 10, 0)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.textContaining(Strings.get('section_plan').toUpperCase()),
        300,
      );
      expect(
        find.textContaining(Strings.get('section_plan').toUpperCase()),
        findsOneWidget,
      );
      expect(find.text(Strings.get('plan_skip')), findsWidgets);
    });
  });

  test('togglePlannerShowAllPicks flips in-memory flag without writing config.json', () {
    final s = AppState();
    final cfgFile = File('${tmp.path}/config.json');
    final beforeExists = cfgFile.existsSync();
    final beforeBytes = beforeExists ? cfgFile.readAsStringSync() : null;

    var emits = 0;
    s.onChanged = () => emits++;

    expect(s.plannerShowAllPicks, isFalse);
    expect(plannerControllerFor(s).showAllPicks, isFalse);

    s.togglePlannerShowAllPicks();
    expect(s.plannerShowAllPicks, isTrue);
    expect(emits, 1);
    expect(plannerControllerFor(s).showAllPicks, isTrue);

    final c = plannerControllerFor(s);
    c.toggleShowAllPicks();
    expect(s.plannerShowAllPicks, isFalse);
    expect(emits, 2);
    expect(plannerControllerFor(s).showAllPicks, isFalse);

    expect(cfgFile.existsSync(), beforeExists);
    if (beforeExists) {
      expect(cfgFile.readAsStringSync(), beforeBytes);
    }
  });
}

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);

  @override
  AppState build() => fixed;
}
