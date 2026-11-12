import 'dart:io';

import 'package:app/features/planner/planner_controller.dart';
import 'package:app/features/planner/planner_view.dart';
import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/widgets/app_widgets.dart' as w;
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

/// Checkpoint B BR3-B1: calendar days are stepped with `core.addDays` and
/// measured with `core.daysBetween`, never in 24-hour units (PLAN §3.5
/// "Dates"). Europe/Prague leaves summer time on 25 Oct 2026 and enters it
/// on 28 Mar 2027; in a zone without clock changes these cases still hold.
void main() {
  test('app code never steps calendar days with Duration(days: …)', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final path = entity.path.replaceAll(r'\', '/');
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) continue;
        if (line.contains('Duration(days') || line.contains('.inDays')) {
          offenders.add('$path:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  String iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  group('entryDays across a clock change', () {
    test('autumn: 23.10.–30.10.2026', () {
      final days = core.entryDays(
          {'start_date': '2026-10-23', 'end_date': '2026-10-30'});
      expect([for (final d in days) iso(d)], [
        '2026-10-23', '2026-10-24', '2026-10-25', '2026-10-26', //
        '2026-10-27', '2026-10-28', '2026-10-29', '2026-10-30',
      ]);
    });

    test('spring: 26.3.–2.4.2027', () {
      final days = core.entryDays(
          {'start_date': '2027-03-26', 'end_date': '2027-04-02'});
      expect([for (final d in days) iso(d)], [
        '2027-03-26', '2027-03-27', '2027-03-28', '2027-03-29', //
        '2027-03-30', '2027-03-31', '2027-04-01', '2027-04-02',
      ]);
    });
  });

  group('addDayRange across a clock change', () {
    List<String> saved(String from, String to) {
      final c = SettingsController({'user_free_days': <Object?>[]});
      c.setDraft('cal:from_', from);
      c.setDraft('cal:to', to);
      expect(c.addDayRange(), isTrue);
      return [for (final d in c.userFreeDays()) d['date']!];
    }

    test('autumn: 23.10.–30.10.2026 keeps Friday 30 Oct', () {
      expect(saved('23.10.2026', '30.10.2026'), [
        '23.10.2026', '24.10.2026', '25.10.2026', '26.10.2026', //
        '27.10.2026', '28.10.2026', '29.10.2026', '30.10.2026',
      ]);
    });

    test('spring: 26.3.–2.4.2027 keeps Friday 2 Apr', () {
      expect(saved('26.3.2027', '2.4.2027').toSet(), {
        '26.03.2027', '27.03.2027', '28.03.2027', '29.03.2027', //
        '30.03.2027', '31.03.2027', '01.04.2027', '02.04.2027',
      });
    });
  });

  test('settings groups a range across a clock change into one row', () {
    final spring = SettingsView.groupDays([
      for (final d in ['26', '27', '28', '29', '30'])
        {'date': '$d.03.2027', 'label': 'Volno'},
    ]);
    expect(spring, hasLength(1));
    expect(spring.single.$3, hasLength(5));
    final autumn = SettingsView.groupDays([
      for (final d in ['24', '25', '26'])
        {'date': '$d.10.2026', 'label': ''},
    ]);
    expect(autumn, hasLength(1));
    expect(autumn.single.$3, hasLength(3));
  });

  group('semester grid on 12 Nov 2026', () {
    final today = DateTime(2026, 11, 12);

    YearPlanData plan() => YearPlanData(
          today: today,
          firstDay: today,
          terms: [
            TermPlanData(
              key: 'sem1',
              start: DateTime(2026, 9, 1),
              close: DateTime(2027, 1, 25),
              capacity: 5,
              hasData: true,
              active: true,
              remainingDays: const [],
              plannedDates: const {},
              budgets: const [],
              recommended: const [],
            ),
          ],
          lessonsOn: (_) => 5,
        );

    Finder cell(DateTime day) {
      final label = '${w.dayName(day, true)} ${w.czDay(day)}';
      return find.byWidgetPredicate((x) =>
          x is Tooltip &&
          (x.message == label || (x.message ?? '').startsWith('$label ')));
    }

    bool outlinedToday(WidgetTester t, DateTime day) {
      final boxes = t.widgetList<Container>(
          find.descendant(of: cell(day), matching: find.byType(Container)));
      return boxes.any((c) {
        final deco = c.decoration;
        return deco is BoxDecoration &&
            deco.border is Border &&
            (deco.border! as Border).top.width == 2;
      });
    }

    Future<void> pump(WidgetTester t, {required bool narrow}) async {
      t.view.physicalSize = Size(narrow ? 390 : 1280, 4000);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      await withClock(Clock.fixed(DateTime(2026, 11, 12, 10)), () async {
        await t.pumpWidget(MaterialApp(
          home: Scaffold(
            body: PlannerView(
              controller: PlannerController({
                'long_absence_excuses': ['Omluvte absenci.'],
              }),
              plan: plan(),
              hasTimetable: true,
              hasData: true,
              narrow: narrow,
            ),
          ),
        ));
      });
    }

    final thuBefore = DateTime(2026, 10, 22);
    final friBefore = DateTime(2026, 10, 23);
    final friday = DateTime(2026, 11, 13);

    testWidgets(
        'wide: today sits in the Thursday row, 13 Nov in the Friday row',
        (t) async {
      await pump(t, narrow: false);
      expect(cell(today), findsOneWidget);
      expect(cell(friday), findsOneWidget);
      // No weekend ever lands in the grid.
      expect(cell(DateTime(2026, 11, 8)), findsNothing);
      expect(outlinedToday(t, today), isTrue);
      expect(outlinedToday(t, friday), isFalse);
      // Rows are weekdays: the same row before and after the clock change.
      expect(t.getTopLeft(cell(today)).dy, t.getTopLeft(cell(thuBefore)).dy);
      expect(t.getTopLeft(cell(friday)).dy, t.getTopLeft(cell(friBefore)).dy);
      expect(t.getTopLeft(cell(friday)).dy,
          greaterThan(t.getTopLeft(cell(today)).dy));
    });

    testWidgets(
        'phone: today sits in the Thursday column, 13 Nov in the Friday column',
        (t) async {
      await pump(t, narrow: true);
      expect(cell(today), findsOneWidget);
      expect(cell(friday), findsOneWidget);
      expect(cell(DateTime(2026, 11, 8)), findsNothing);
      expect(outlinedToday(t, today), isTrue);
      // Columns are weekdays: the same column before and after the change.
      expect(t.getTopLeft(cell(today)).dx, t.getTopLeft(cell(thuBefore)).dx);
      expect(t.getTopLeft(cell(friday)).dx, t.getTopLeft(cell(friBefore)).dx);
      expect(t.getTopLeft(cell(friday)).dx,
          greaterThan(t.getTopLeft(cell(today)).dx));
    });
  });

  testWidgets('custom dialog: October 2026 ends with Friday 30 Oct',
      (t) async {
    t.view.physicalSize = const Size(1280, 1024);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    Finder day(int d) => find.byKey(ValueKey('day_2026_10_$d'));
    await withClock(Clock.fixed(DateTime(2026, 10, 1, 10)), () async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: CustomPlanDialog(
            controller: PlannerController({
              'long_absence_excuses': ['Omluvte absenci.'],
            }),
            stravaOn: false,
            lessonsFor: (_) => const [],
            freeDays: const {},
            initialMonth: DateTime(2026, 10, 1),
          ),
        ),
      ));
    });
    expect(day(30), findsOneWidget);
    expect(day(26), findsOneWidget);
    // Sunday 25 Oct is not a school day and must not appear.
    expect(day(25), findsNothing);
    // Fridays share a column, Mondays share a column.
    expect(t.getTopLeft(day(30)).dx, t.getTopLeft(day(2)).dx);
    expect(t.getTopLeft(day(26)).dx, t.getTopLeft(day(5)).dx);
  });
}
