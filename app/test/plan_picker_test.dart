import 'package:app/features/planner/planner_controller.dart';
import 'package:app/features/planner/planner_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final monday = DateTime(2026, 11, 9);
final tuesday = DateTime(2026, 11, 10);
final thursday = DateTime(2026, 11, 19);

const weekDays = [
  ['Matematika', 'Fyzika', 'Chemie', 'Dějepis', 'Biologie'],
  ['Chemie', 'Matematika', 'Biologie', 'Fyzika', 'Dějepis'],
];

List<PickerSlot> mockLessonsFor(
  DateTime day, {
  Set<int> cancelledPeriods = const {},
  Set<int> pastPeriods = const {},
  Set<int> plannedPeriods = const {},
  bool isStable = false,
}) {
  final isTuesday = day.year == 2026 && day.month == 11 && day.day == 10;
  final subjects = isTuesday || day.weekday == 2 || day.weekday == 4
      ? weekDays[1]
      : weekDays[0];

  return [
    for (var i = 0; i < subjects.length; i++)
      PickerSlot(
        period: i + 1,
        subject: subjects[i],
        detail: isStable ? Strings.get('pick_from_stable') : '',
        taught: !cancelledPeriods.contains(i + 1),
        past: pastPeriods.contains(i + 1),
        planned: plannedPeriods.contains(i + 1),
        changed: isTuesday && (i + 1 == 2 || i + 1 == 4),
      ),
  ];
}

PlannerController createPickerPlannerController({
  List<Map<String, dynamic>>? planned,
}) {
  final c = PlannerController({
    'long_absence_excuses': ['Důvod absence.'],
    'short_absence_excuses': <String>[],
    'late_income_excuses': <String>[],
    'your_signature': '',
  });
  c.stravaEnabled = false;
  if (planned != null) {
    c.plannedSkips.addAll(planned);
  }
  return c;
}

Widget buildPickerHost({
  required PlannerController controller,
  required List<PickerSlot> Function(DateTime) lessonsFor,
  Set<DateTime> freeDays = const {},
  DateTime? initialMonth,
  DateTime? firstMonth,
  DateTime? lastMonth,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: PlannerMonthCalendar(
          controller: controller,
          stravaOn: false,
          lessonsFor: lessonsFor,
          freeDays: freeDays,
          initialMonth: initialMonth ?? DateTime(2026, 11, 1),
          firstMonth: firstMonth,
          lastMonth: lastMonth,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    Strings.lang = 'cs';
  });

  void setViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1024);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Finder dayCell(DateTime d) =>
      find.byKey(ValueKey('day_${d.year}_${d.month}_${d.day}'));

  testWidgets('tappingADayTakesItOffWhole', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(d),
      ),
    );

    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();

    final confirmBtn = find.widgetWithText(FilledButton, Strings.get('confirm'));
    expect(tester.widget<FilledButton>(confirmBtn).onPressed, isNotNull);

    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();

    expect(controller.plannedSkips, hasLength(1));
    final e = controller.plannedSkips.first;
    expect(e['start_date'], '2026-11-09');
    expect(e['end_date'], '2026-11-09');
    expect(e['start_period'], isNull);
    expect(e['end_period'], isNull);
  });

  testWidgets('tappingAPickedDayAgainUnpicksIt', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(d),
      ),
    );

    await tester.tap(find.byKey(const Key('plan:multi_toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plan:multi_confirm')), findsNothing);
    expect(find.text(Strings.get('pick_empty')), findsOneWidget);

    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();
    final multiConfirm = find.byKey(const Key('plan:multi_confirm'));
    expect(multiConfirm, findsOneWidget);
    expect(tester.widget<FilledButton>(multiConfirm).onPressed, isNotNull);

    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plan:multi_confirm')), findsNothing);
    expect(find.text(Strings.get('pick_empty')), findsOneWidget);
  });

  testWidgets('untickedLessonsStayAttended', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(d),
      ),
    );

    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plan:choose_lessons')));
    await tester.pumpAndSettle();

    // Untick Matematika (period 1) and Fyzika (period 2)
    await tester.tap(find.textContaining('Matematika'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Fyzika'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
    await tester.pumpAndSettle();

    expect(controller.plannedSkips, hasLength(1));
    final e = controller.plannedSkips.first;
    expect(e['start_date'], '2026-11-09');
    expect(e['start_period'], 3);
    expect(e['end_period'], isNull);
  });

  testWidgets('daysInARowBecomeOneRange', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(d),
      ),
    );

    await tester.tap(find.byKey(const Key('plan:multi_toggle')));
    await tester.pumpAndSettle();
    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();
    await tester.tap(dayCell(tuesday));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('plan:multi_confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
    await tester.pumpAndSettle();

    expect(controller.plannedSkips, hasLength(1));
    final e = controller.plannedSkips.first;
    expect(e['start_date'], '2026-11-09');
    expect(e['end_date'], '2026-11-10');
  });

  testWidgets('weekChangesAreShownAndCancelledLessonsLocked', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(d, cancelledPeriods: {4}),
      ),
    );

    await tester.tap(dayCell(tuesday));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan:choose_lessons')));
    await tester.pumpAndSettle();

    // Period 4 is cancelled: pickable is false so CheckboxListTile is disabled
    final cancelledTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, '4. Fyzika'),
    );
    expect(cancelledTile.onChanged, isNull);

    // Untick 1 (Chemie), 2 (Matematika), 3 (Biologie)
    await tester.tap(find.textContaining('Chemie'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Matematika'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Biologie'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
    await tester.pumpAndSettle();

    expect(controller.plannedSkips, hasLength(1));
    final e = controller.plannedSkips.first;
    expect(e['start_period'], 5);
    expect(e['end_period'], isNull);
  });

  testWidgets('unfetchedWeekUsesTheStableTimetable', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(d, isStable: d.day == 19),
      ),
    );

    await tester.tap(dayCell(thursday));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan:choose_lessons')));
    await tester.pumpAndSettle();

    expect(find.text(Strings.get('pick_from_stable')), findsWidgets);
    expect(find.textContaining('Chemie'), findsWidgets);
  });

  testWidgets('alreadyPlannedLessonsAreLockedAndSplitThePick', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController(
      planned: [
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'start_period': 3,
          'end_period': 3,
          'template': 'x',
        },
      ],
    );

    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(d, plannedPeriods: {3}),
      ),
    );

    // Partly planned day opens PlanDayDialog already expanded (M1).
    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();

    // Lesson 3 (Chemie) is planned: disabled
    final plannedTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, '3. Chemie'),
    );
    expect(plannedTile.onChanged, isNull);

    await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
    await tester.pumpAndSettle();

    // Split around period 3 -> [(null, 2), (4, null)]
    final newEntries = controller.plannedSkips.sublist(1);
    expect(newEntries, hasLength(2));
    expect(newEntries[0]['start_period'], isNull);
    expect(newEntries[0]['end_period'], 2);
    expect(newEntries[1]['start_period'], 4);
    expect(newEntries[1]['end_period'], isNull);
  });

  testWidgets('alreadyPlannedLessonsSplitInMultiMode', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController(
      planned: [
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'start_period': 3,
          'end_period': 3,
          'template': 'x',
        },
      ],
    );

    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(
          d,
          plannedPeriods: d.day == 9 ? {3} : const {},
        ),
      ),
    );

    await tester.tap(find.byKey(const Key('plan:multi_toggle')));
    await tester.pumpAndSettle();
    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan:multi_confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
    await tester.pumpAndSettle();

    final newEntries = controller.plannedSkips.sublist(1);
    expect(newEntries, hasLength(2));
    expect(newEntries[0]['start_period'], isNull);
    expect(newEntries[0]['end_period'], 2);
    expect(newEntries[1]['start_period'], 4);
    expect(newEntries[1]['end_period'], isNull);
  });

  testWidgets('showPlannedDialog lists multiple partial entries and removes only chosen one',
      (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController(
      planned: [
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'start_period': 1,
          'end_period': 2,
          'template': 'První část',
        },
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'start_period': 3,
          'end_period': 5,
          'template': 'Druhá část',
        },
      ],
    );

    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(
          d,
          plannedPeriods: d.day == 9 ? {1, 2, 3, 4, 5} : const {},
        ),
      ),
    );

    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();

    expect(find.text('První část'), findsOneWidget);
    expect(find.text('Druhá část'), findsOneWidget);
    final unplanBtns = find.widgetWithText(TextButton, Strings.get('unplan'));
    expect(unplanBtns, findsNWidgets(2));

    await tester.tap(unplanBtns.first);
    await tester.pumpAndSettle();

    expect(controller.plannedSkips, hasLength(1));
    expect(controller.plannedSkips.first['template'], 'Druhá část');
    expect(find.text('První část'), findsNothing);
    expect(find.text('Druhá část'), findsOneWidget);
  });

  testWidgets('fullyPlannedDaysAndHolidaysCannotBeTapped', (tester) async {
    setViewport(tester);
    final holiday = DateTime(2026, 11, 17);
    final controller = createPickerPlannerController(
      planned: [
        {
          'start_date': '2026-11-09',
          'end_date': '2026-11-09',
          'template': 'Lékař',
        },
      ],
    );
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(
          d,
          plannedPeriods: d.day == 9 ? {1, 2, 3, 4, 5} : const {},
        ),
        freeDays: {holiday},
      ),
    );

    // Single mode: holiday has onTap == null; fully planned day opens showPlannedDialog.
    expect(tester.widget<InkWell>(dayCell(holiday)).onTap, isNull);
    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();
    expect(find.text('Lékař'), findsOneWidget);
    await tester.tap(find.text(Strings.get('cancel')));
    await tester.pumpAndSettle();

    // Multi mode: both fully planned day and holiday have onTap == null.
    await tester.tap(find.byKey(const Key('plan:multi_toggle')));
    await tester.pumpAndSettle();
    expect(tester.widget<InkWell>(dayCell(monday)).onTap, isNull);
    expect(tester.widget<InkWell>(dayCell(holiday)).onTap, isNull);
  });

  testWidgets('startedLessonsTodayCannotBePicked', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(
          d,
          pastPeriods: d.day == 9 ? {1, 2, 3} : const {},
        ),
      ),
    );

    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan:choose_lessons')));
    await tester.pumpAndSettle();

    // Past lesson 1 (Matematika) cannot be picked
    final matTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, '1. Matematika'),
    );
    expect(matTile.onChanged, isNull);

    // Upcoming lesson 4 (Dějepis) is active
    final dejTile = tester.widget<CheckboxListTile>(
      find.widgetWithText(CheckboxListTile, '4. Dějepis'),
    );
    expect(dejTile.onChanged, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
    await tester.pumpAndSettle();

    expect(controller.plannedSkips, hasLength(1));
    final e = controller.plannedSkips.first;
    expect(e['start_period'], 4);
    expect(e['end_period'], isNull);
  });

  testWidgets('pastDaysAreNotTappable', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(
          d,
          pastPeriods: d.day <= 9 ? {1, 2, 3, 4, 5} : const {},
        ),
      ),
    );

    final mondayInkWell = tester.widget<InkWell>(dayCell(monday));
    expect(mondayInkWell.onTap, isNull);
  });

  testWidgets('wholeDaySwitchClearsAndRefillsTheDay', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(d),
      ),
    );

    await tester.tap(dayCell(monday));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan:choose_lessons')));
    await tester.pumpAndSettle();

    final confirmBtn = find.widgetWithText(FilledButton, Strings.get('confirm'));
    expect(tester.widget<FilledButton>(confirmBtn).onPressed, isNotNull);

    // Tapping whole day checkbox unticks all lessons
    await tester.tap(find.byKey(const Key('plan:whole_day_check')));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(confirmBtn).onPressed, isNull);

    // Tap lesson 5 (Biologie)
    await tester.tap(find.textContaining('Biologie'));
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(confirmBtn).onPressed, isNotNull);
    await tester.tap(confirmBtn);
    await tester.pumpAndSettle();

    expect(controller.plannedSkips, hasLength(1));
    final e = controller.plannedSkips.first;
    expect(e['start_period'], 5);
    expect(e['end_period'], isNull);
  });

  testWidgets('monthNavigationStaysInsideTheSchoolYear', (tester) async {
    setViewport(tester);
    final controller = createPickerPlannerController();
    await tester.pumpWidget(
      buildPickerHost(
        controller: controller,
        lessonsFor: (d) => mockLessonsFor(d),
        initialMonth: DateTime(2026, 11, 1),
        firstMonth: DateTime(2026, 11, 1),
        lastMonth: DateTime(2027, 6, 1),
      ),
    );

    // Previous month button disabled because at firstMonth (November)
    final prevBtn = tester.widget<IconButton>(
      find.byKey(const Key('cal:prev_month')),
    );
    expect(prevBtn.onPressed, isNull);

    // Next month button is enabled
    final nextFinder = find.byKey(const Key('cal:next_month'));
    final nextBtn = tester.widget<IconButton>(nextFinder);
    expect(nextBtn.onPressed, isNotNull);

    await tester.tap(nextFinder);
    await tester.pumpAndSettle();

    expect(find.text('Prosinec 2026'), findsOneWidget);
    expect(dayCell(DateTime(2026, 12, 1)), findsOneWidget);
  });

  testWidgets(
    'a picked day planned elsewhere before confirming gets no extra entry (R3c code M5)',
    (tester) async {
      setViewport(tester);
      final c = createPickerPlannerController();
      String iso(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      List<PickerSlot> lessons(DateTime d) => mockLessonsFor(
        d,
        plannedPeriods: c.plannedSkips.any((e) => e['start_date'] == iso(d))
            ? {1, 2, 3, 4, 5}
            : const {},
      );
      Widget host() => buildPickerHost(controller: c, lessonsFor: lessons);

      await tester.pumpWidget(host());
      await tester.tap(find.byKey(const Key('plan:multi_toggle')));
      await tester.pumpAndSettle();
      await tester.tap(dayCell(monday));
      await tester.pump();
      await tester.tap(dayCell(tuesday));
      await tester.pump();

      // Monday is planned another way, keeping its lunch.
      expect(
        c.planSkip('2026-11-09', 'Důvod absence.', cancelLunch: false),
        isTrue,
      );
      await tester.pumpWidget(host());
      await tester.pump();

      // Monday is no longer rendered as selected (no check icon on its cell),
      // and the selection bar counts only the 1 remaining day (Tuesday).
      expect(
        find.descendant(of: dayCell(monday), matching: find.byIcon(Icons.check)),
        findsNothing,
      );
      expect(
        find.descendant(of: dayCell(tuesday), matching: find.byIcon(Icons.check)),
        findsOneWidget,
      );
      expect(find.textContaining('1 den'), findsOneWidget);

      await tester.tap(find.byKey(const Key('plan:multi_confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
      await tester.pumpAndSettle();

      expect(c.plannedSkips, hasLength(2));
      final mon = c.plannedSkips
          .where((e) => e['start_date'] == '2026-11-09')
          .toList();
      expect(mon, hasLength(1));
      expect(mon.single['cancel_lunch'], isFalse);
    },
  );

  testWidgets(
    'confirming multi-day when all picked days became unpickable clears selection without opening dialog (R3c code M5)',
    (tester) async {
      setViewport(tester);
      final c = createPickerPlannerController();
      String iso(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      List<PickerSlot> lessons(DateTime d) => mockLessonsFor(
        d,
        plannedPeriods: c.plannedSkips.any((e) => e['start_date'] == iso(d))
            ? {1, 2, 3, 4, 5}
            : const {},
      );
      Widget host() => buildPickerHost(controller: c, lessonsFor: lessons);

      await tester.pumpWidget(host());
      await tester.tap(find.byKey(const Key('plan:multi_toggle')));
      await tester.pumpAndSettle();
      await tester.tap(dayCell(monday));
      await tester.pump();

      // Plan Monday without rebuilding the calendar first, then tap Naplánovat.
      expect(
        c.planSkip('2026-11-09', 'Důvod absence.', cancelLunch: false),
        isTrue,
      );
      await tester.tap(find.byKey(const Key('plan:multi_confirm')));
      await tester.pumpAndSettle();

      // Dialog must not open, selection must be cleared, and no extra entry added.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(Strings.get('pick_empty')), findsOneWidget);
      expect(c.plannedSkips, hasLength(1));
    },
  );
}
