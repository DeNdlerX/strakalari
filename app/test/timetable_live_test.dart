import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/timetable/timetable_live.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_timetable_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
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

  // Checkpoint B BR3-M2: `timetable.py` GAP = 4 between the cells of a row,
  // the header row, the rows themselves and the phone's day column.
  for (final narrow in [false, true]) {
    testWidgets('grid cells have a 4 px gap (narrow: $narrow)', (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = Size(narrow ? 390 : 1600, 844);
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
              for (var p = 1; p <= 4; p++)
                {'subject': 'Predmet$p', 'time': '$p (8:00 - 8:45)'},
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
                narrow: narrow,
                now: DateTime(2026, 10, 12, 10, 0),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final gapped = tester
          .widgetList<Row>(find.byType(Row))
          .where((r) => r.spacing == 4)
          .toList();
      // Header row and the lesson row: one slot per period (plus the
      // day gutter on a wide screen).
      final perRow = narrow ? 4 : 5;
      expect(gapped.where((r) => r.children.length == perRow).length,
          greaterThanOrEqualTo(2));
    });
  }

  group('P6 timetable phone polish', () {
    AppState weekState(DateTime monday, {String view = 'table'}) {
      String d(int offset) {
        final dt = addDays(monday, offset);
        return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}';
      }

      final nextMon = addDays(monday, 7);
      return AppState(
        configData: {
          'tutorials_done': ['intro', 'timetable'],
          'timetable_view': view,
        },
        data: {
          'timetable': {
            for (var i = 0; i < 5; i++)
              d(i): [
                {
                  'subject': 'Matematika',
                  'teacher': 'Mgr. Jana Nováková',
                  'room': 'II',
                  'time': '1 (8:00 - 8:45)',
                },
                {
                  'subject': 'Fyzika',
                  'teacher': 'Ing. Martin Procházka',
                  'room': 'IV',
                  'time': '3 (10:00 - 10:45)',
                },
              ],
            '${nextMon.day.toString().padLeft(2, '0')}.${nextMon.month.toString().padLeft(2, '0')}.${nextMon.year}': [
              {
                'subject': 'Chemie',
                'teacher': 'Ing. Jiří Kučera',
                'room': 'IV',
                'time': '1 (8:00 - 8:45)',
              },
            ],
          },
          'stable_baseline_source': 'scraped',
          'stable_baseline': {
            '0|1': {
              'weekday': 0,
              'period': 1,
              'subject': 'Matematika',
              'teacher': 'Mgr. Jana Nováková',
              'room': 'II',
              'start_min': 480,
              'support': 5,
            },
          },
        },
      );
    }

    testWidgets(
        'table legend is fully visible above bottom bar, list rows space period from time, and selected week button stands out',
        (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(390, 844);
      Strings.lang = 'cs';

      final previous = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().contains('overflowed')) return;
        previous?.call(details);
      };
      addTearDown(() => FlutterError.onError = previous);

      final monday = DateTime(2026, 10, 12);
      final s = weekState(monday, view: 'table');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => FixedAppStateController(s)),
          ],
          child: MaterialApp(
            theme: darkTokens.toThemeData(),
            home: Scaffold(
              appBar: AppBar(toolbarHeight: 56),
              bottomNavigationBar: NavigationBar(
                selectedIndex: 1,
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.home), label: 'Dnes'),
                  NavigationDestination(
                      icon: Icon(Icons.calendar_month), label: 'Rozvrh'),
                ],
              ),
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

      // (a) Legend must sit completely inside the visible body above the bottom bar.
      final bodyRect = tester.getRect(find.byType(LiveTimetableView));
      final legendNow = find.text(Strings.get('legend_now'));
      expect(legendNow, findsOneWidget);
      expect(
        tester.getRect(legendNow).bottom,
        lessThanOrEqualTo(bodyRect.bottom),
      );

      // (c) On this week, Tento tyden is ElevatedButton and Staly is OutlinedButton.
      expect(
        find.widgetWithText(ElevatedButton, Strings.get('this_week')),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, Strings.get('stable_view')),
        findsOneWidget,
      );

      // Switching to next week turns Tento tyden back into OutlinedButton.
      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pump();
      expect(
        find.widgetWithText(OutlinedButton, Strings.get('this_week')),
        findsOneWidget,
      );

      // Switching to Staly makes Staly ElevatedButton and Tento tyden OutlinedButton.
      await tester
          .tap(find.widgetWithText(OutlinedButton, Strings.get('stable_view')));
      await tester.pump();
      expect(
        find.widgetWithText(ElevatedButton, Strings.get('stable_view')),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, Strings.get('this_week')),
        findsOneWidget,
      );

      // (b) List view separates period number from time range.
      await tester
          .tap(find.widgetWithText(OutlinedButton, Strings.get('this_week')));
      await tester.pump();
      await tester.tap(find.text(Strings.get('view_list')));
      await tester.pumpAndSettle();

      expect(find.byType(ExpansionTile), findsWidgets);
      final periodRect = tester.getRect(find.text('1.').first);
      final timeRect = tester.getRect(find.text('8:00 - 8:45').first);
      expect(timeRect.left - periodRect.right, greaterThanOrEqualTo(4));
    });
  });
}

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);

  @override
  AppState build() => fixed;
}
