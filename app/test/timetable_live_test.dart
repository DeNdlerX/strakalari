import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/timetable/timetable_live.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_timetable_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('timetableControllerFor maps AppState and delegates week/view toggles',
      () {
    final s = AppState(
      data: {
        'timetable': {
          '07.09.2026': [
            {'subject': 'Matematika', 'time': '1. 8:00 - 8:45'},
          ],
          '14.09.2026': [
            {'subject': 'Fyzika', 'time': '2. 8:55 - 9:40'},
          ],
        },
      },
    );
    final c = timetableControllerFor(s);
    expect(c.weeks(), hasLength(2));

    c.setShowStable(true);
    expect(s.showStableTimetable, isTrue);

    c.goTimetableWeek('2026-09-14');
    expect(s.showStableTimetable, isFalse);
    expect(s.timetableMondayIso, '2026-09-14');

    c.setTimetableView('list');
    expect(s.timetableView, 'list');
    expect(s.get('timetable_view'), 'list');
  });

  testWidgets('LiveTimetableView renders lessons from appStateProvider',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final s = AppState(
      configData: {
        'tutorials_done': ['intro'],
      },
      data: {
        'timetable': {
          '07.09.2026': [
            {'subject': 'Chemie', 'time': '1. 8:00 - 8:45'},
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
            body: LiveTimetableView(
              tokens: AppTokens.dark(),
              now: DateTime(2026, 9, 7, 10, 0),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Chemie'), findsWidgets);
    expect(s.tutorial?.$1, 'timetable');
  });

  // tests/test_mobile.py::test_phone_timetable_grid_scrolls_sideways
  testWidgets('phoneTimetableGridScrollsSideways', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1.0;
    // The test engine's block font (Ahem) is far wider than the real one, so
    // the period-time labels wrap and report a RenderFlex overflow that the
    // shipped fonts do not have. Only that message is ignored.
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('overflowed')) return;
      previous?.call(details);
    };
    addTearDown(() => FlutterError.onError = previous);
    final s = AppState(
      configData: {
        'tutorials_done': ['intro'],
      },
      data: {
        'timetable': {
          '12.10.2026': [
            for (var p = 1; p <= 8; p++)
              {'subject': 'Predmet$p', 'time': '$p (8:00 - 8:45)'},
          ],
        },
      },
    );
    Future<void> pumpAt(double width) async {
      tester.view.physicalSize = Size(width, 844);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => FixedAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: LiveTimetableView(
                  tokens: AppTokens.dark(),
                  narrow: true,
                  now: DateTime(2026, 10, 12, 10, 0),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    double headerCellWidth() => tester
        .getSize(find
            .ancestor(of: find.text('1.'), matching: find.byType(SizedBox))
            .first)
        .width;

    await pumpAt(390);
    expect(
        find.byWidgetPredicate((w) =>
            w is SingleChildScrollView && w.scrollDirection == Axis.horizontal),
        findsWidgets);
    final narrowRow = tester.getSize(find.byWidgetPredicate((w) =>
            w is SingleChildScrollView &&
            w.scrollDirection == Axis.horizontal).first);
    // Eight 92 px cells never fit a 390 px page, so the grid scrolls.
    final scrollable = tester.state<ScrollableState>(find
        .descendant(
            of: find.byWidgetPredicate((w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal).first,
            matching: find.byType(Scrollable))
        .first);
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    expect(narrowRow.width, lessThan(390));
    expect(headerCellWidth(), 92); // PHONE_CELL_MIN_W

    // Landscape (915 px): cells stretch to fill the width instead.
    await pumpAt(915);
    final wide = tester.state<ScrollableState>(find
        .descendant(
            of: find.byWidgetPredicate((w) =>
                w is SingleChildScrollView &&
                w.scrollDirection == Axis.horizontal).first,
            matching: find.byType(Scrollable))
        .first);
    expect(wide.position.maxScrollExtent, 0);
    expect(headerCellWidth(), greaterThan(92));
  });
}

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);

  @override
  AppState build() => fixed;
}
