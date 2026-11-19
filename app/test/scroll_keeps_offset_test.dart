import 'package:app/controllers/app_state.dart' hide PlannerController;
import 'package:app/features/absences/absences_live.dart';
import 'package:app/features/planner/planner_live.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Replaces the Flet "container reuse / scroll restore" cases of
/// `tests/test_ui_views.py` (see STATUS.md, Dropped): what those tests
/// protect is that a screen the user has scrolled keeps its offset when the
/// shared state changes and the screen is rebuilt.
void main() {
  testWidgets('a scrolled screen keeps its offset across an AppState emit',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await withClock(Clock.fixed(DateTime(2026, 9, 10, 10, 0)), () async {
      final s = AppState(
        configData: {
          'tutorials_done': ['intro'],
        },
        data: {
          'absence': {
            'Matematika': 2.0,
            'Fyzika': 4.0,
            'Chemie': 6.0,
            'Biologie': 8.0,
            'Dějepis': 10.0,
          },
          'timetable': {
            '11.09.2026': [
              {'subject': 'Matematika', 'time': '1. 8:00 - 8:45'},
              {'subject': 'Fyzika', 'time': '2. 8:55 - 9:40'},
            ],
          },
        },
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _EmittingController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveAbsencesView(now: DateTime(2026, 9, 10, 10, 0)),
            ),
          ),
        ),
      );
      await tester.pump();

      final scrollable =
          tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(scrollable.position.maxScrollExtent, greaterThan(100));
      scrollable.position.jumpTo(100);
      await tester.pump();
      expect(scrollable.position.pixels, 100);

      s.onChanged(); // any state change repaints the screen
      await tester.pump();
      await tester.pump();

      final after =
          tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(after.position.pixels, 100);
    });
  });

  testWidgets('a scrolled LivePlannerPage keeps its offset across an AppState emit',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 360);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await withClock(Clock.fixed(DateTime(2026, 9, 10, 10, 0)), () async {
      final s = AppState(
        configData: {
          'tutorials_done': ['intro', 'absences_plan'],
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
            appStateProvider.overrideWith(() => _EmittingController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LivePlannerPage(now: DateTime(2026, 9, 10, 10, 0)),
            ),
          ),
        ),
      );
      await tester.pump();

      final scrollable =
          tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(scrollable.position.maxScrollExtent, greaterThan(100));
      scrollable.position.jumpTo(100);
      await tester.pump();
      expect(scrollable.position.pixels, 100);

      s.onChanged();
      await tester.pump();
      await tester.pump();

      final after =
          tester.state<ScrollableState>(find.byType(Scrollable).first);
      expect(after.position.pixels, 100);
    });
  });
}

class _EmittingController extends AppStateController {
  final AppState seeded;
  _EmittingController(this.seeded);

  @override
  AppState build() {
    seeded.onChanged = () {
      // ignore: avoid_self_assignment
      state = state;
    };
    return seeded;
  }
}
