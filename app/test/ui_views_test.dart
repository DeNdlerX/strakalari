import 'dart:io';

import 'package:app/controllers/app_state.dart' hide ActivityController;
import 'package:app/features/absences/absences_live.dart';
import 'package:app/features/activity/activity_controller.dart';
import 'package:app/features/activity/activity_live.dart';
import 'package:app/features/activity/activity_view.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/lunches/lunches_format.dart';
import 'package:app/features/lunches/lunches_live.dart';
import 'package:app/features/marks/marks_live.dart';
import 'package:app/features/planner/planner_live.dart';
import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_live.dart';
import 'package:app/features/timetable/timetable_controller.dart';
import 'package:app/features/timetable/timetable_live.dart';
import 'package:app/features/timetable/timetable_view.dart';
import 'package:app/features/today/today_controller.dart';
import 'package:app/features/today/today_live.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/widgets/app_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

Widget _app(Widget child, {ProviderContainer? container}) {
  final widget = MaterialApp(
    home: Scaffold(body: child),
  );
  if (container != null) {
    return UncontrolledProviderScope(container: container, child: widget);
  }
  return ProviderScope(child: widget);
}

void main() {
  late Directory tmp;
  final tokens = AppTokens.dark();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_ui_views_test_');
    core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
  });

  tearDown(() {
    core.setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('TestPlannerSignature', () {
    test('signatureNotDuplicated', () {
      final formatted = core.formatExcuseTemplate(
        'Omluvte absenci.\nJan Novák',
        signatureStr: 'jan novák',
      );
      final count = 'jan novák'
          .allMatches(formatted.toLowerCase())
          .length;
      expect(count, equals(1));
    });
  });

  group('TestNamedTemplates', () {
    const cfg = {
      'short_absence_excuses': [
        {'name': 'Rodina', 'text': 'Omluvte, rodina.'},
        'Omluvte, bez jména.',
        {'name': 'Prázdná', 'text': '  '},
      ],
      'long_absence_excuses': <Object>[],
      'late_income_excuses': <Object>[],
      'left_soon_excuses': <Object>[],
      'your_signature': '',
    };

    test('helpersAcceptBothShapes', () {
      expect(core.templateText({'name': 'A', 'text': 'T'}), equals('T'));
      expect(core.templateName({'name': '  A  B ', 'text': 'T'}), equals('A B'));
      expect(core.templateText('plain'), equals('plain'));
      expect(core.templateName('plain'), equals(''));
      expect(
        core.templateTexts([
          {'name': 'A', 'text': 'T'},
          'U',
        ]),
        equals(['T', 'U']),
      );
      expect(core.templateTexts('junk'), equals(<String>[]));
    });

    test('optionsCarryNamesAndSkipBlank', () {
      final controller = TodayController()
        ..templateSource = (k) => (cfg[k] as List<Object?>?) ?? [];
      final options = controller.templateOptions('short');
      expect(
        options.map((o) => (o.name, o.text)).toList(),
        equals([
          ('Rodina', 'Omluvte, rodina.'),
          ('', 'Omluvte, bez jména.'),
        ]),
      );
      final labels = controller.templateLabels(options);
      expect(labels[0], equals('Rodina'));
      expect(labels[1], endsWith('2'));
    });

    test('todayPicksTextNotName', () {
      final controller = TodayController();
      const options = [
        TemplateOption('Rodina', 'Omluvte, rodina.'),
        TemplateOption('', 'Druhá.'),
      ];
      controller.pickedTemplates['k'] = 1;
      expect(controller.pickedOption('k', options), equals('Druhá.'));
      expect(controller.pickedOption('other', options), equals('Omluvte, rodina.'));
    });

    test('corePicksTextOfNamedTemplate', () {
      final texts = core.templateTexts(cfg['short_absence_excuses']);
      final valid = texts.where((t) => t.trim().isNotEmpty).toList();
      expect(valid.first, equals('Omluvte, rodina.'));
    });
  });

  group('Timetable period and grid helpers', () {
    test('timetablePeriodHelpers', () {
      final c = TimetableController();
      expect(c.periodOf({'time': '3 (10:05 - 10:50)'}, '07.09.2026'), equals(3));
      expect(c.periodOf({'time': '1. 8:00 - 8:45'}, '07.09.2026'), equals(1));
      expect(c.periodOf({'time': 'nonsense'}, '07.09.2026'), isNull);

      final week = {
        DateTime(2026, 9, 7): [
          {'time': '1. 8:00 - 8:45'},
          {'time': '2. 8:55 - 9:40'},
        ],
        DateTime(2026, 9, 8): [
          {'time': '1. 8:00 - 8:45'},
        ],
      };
      expect(c.periodTime(week, 1), equals('8:00 - 8:45'));
      expect(c.periodTime(week, 9), equals(''));
    });

    test('timetablePeriodOfZero', () {
      final c = TimetableController();
      expect(c.periodOf({'subject': 'M', 'period': 0}, null), equals(0));
      expect(c.periodOf({'subject': 'M', 'period': 2}, null), equals(2));
      expect(c.periodOf({'subject': 'M'}, null), isNull);
    });

    test('gridSubjectUsesShortNameOnlyWhenNeeded', () {
      final c = TimetableController();
      const raw = {
        'subject': 'Informatika a výpočetní technika',
        'subject_short': 'IVT',
      };
      expect(c.cellSubject(raw, raw['subject']!, 40), equals(raw['subject']));
      expect(c.cellSubject(raw, raw['subject']!, 12), equals('IVT'));
      expect(c.cellSubject(const {}, 'Základy společenských věd', 12), equals('ZSV'));
      expect(c.abbrev('Český jazyk a literatura'), equals('ČJL'));
      expect(c.abbrev('Matematika'), equals('Matematika'));
    });

    test('focusPeriodMarksCurrentThenNextLesson', () {
      final c = TimetableController();
      final day = DateTime(2026, 9, 24);
      final lessons = [
        {'subject': 'M', 'time': '1 (8:00 - 8:45)'},
        {'subject': 'F', 'time': '2 (8:55 - 9:40)'},
        {'subject': 'C', 'time': '3 (10:00 - 10:45)', 'status': 'cancelled'},
        {'subject': 'D', 'time': '4 (10:55 - 11:40)'},
      ];
      final at810 = c.focusPeriod(lessons, day, DateTime(2026, 9, 24, 8, 10));
      expect((at810.period, at810.kind), equals((1, 'now')));

      final at850 = c.focusPeriod(lessons, day, DateTime(2026, 9, 24, 8, 50));
      expect((at850.period, at850.kind), equals((2, 'next')));

      // A cancelled lesson is never "next": skip to the one that happens.
      final at945 = c.focusPeriod(lessons, day, DateTime(2026, 9, 24, 9, 45));
      expect((at945.period, at945.kind), equals((4, 'next')));

      final at1500 = c.focusPeriod(lessons, day, DateTime(2026, 9, 24, 15, 0));
      expect((at1500.period, at1500.kind), equals((null, '')));

      final otherDay = c.focusPeriod(lessons, DateTime(2026, 9, 23), DateTime(2026, 9, 24, 8, 10));
      expect((otherDay.period, otherDay.kind), equals((null, '')));
    });

    test('lessonLookEncodesStateInTheCell', () {
      final c = TimetableController();
      final day = DateTime(2026, 9, 7);

      final plain = c.look({'subject': 'M', 'time': '1 (8:00 - 8:45)'}, day);
      expect(plain.fill, equals('card'));
      expect(plain.bar, isEmpty);
      expect(plain.tag, isEmpty);

      final absent = c.look({
        'subject': 'M',
        'time': '1 (8:00 - 8:45)',
        'absenceType': 'Absent',
      }, day);
      expect(absent.bar, equals('absent'));
      expect(absent.tag, equals(Strings.get('status_absent')));

      final cancelled = c.look({
        'subject': 'M',
        'time': '1 (8:00 - 8:45)',
        'notice': 'Odpadá',
      }, day);
      expect(cancelled.cancelled, isTrue);
      expect(cancelled.fill, equals('none'));
      expect(cancelled.tag, equals(Strings.get('status_lesson_cancelled')));

      final changed = c.look({
        'subject': 'M',
        'time': '1 (8:00 - 8:45)',
        'notice': 'Suplování',
        'infoChangeCode': 'Substitution',
      }, day);
      expect(changed.diff.isChange, isTrue);
      expect(changed.fill, isNot(equals('card')));
    });

    testWidgets('tableViewStructure', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final c = TimetableController();
      c.timetable = {
        '07.09.2026': [
          {'subject': 'M', 'time': '1. 8:00 - 8:45', 'room': 'U12', 'teacher': 'Novák'},
          {'subject': 'F', 'time': '2. 8:55 - 9:40', 'room': 'F11', 'teacher': 'Dvořák', 'status': 'late'},
        ],
        '08.09.2026': [
          {'subject': 'C', 'time': '1. 8:00 - 8:45', 'room': 'U08', 'teacher': 'Svobodová'},
        ],
      };
      c.timetableView = 'table';
      c.timetableMondayIso = '2026-09-07';

      await tester.pumpWidget(_app(
        TimetableView(
          controller: c,
          tokens: tokens,
          narrow: false,
          now: DateTime(2026, 9, 7, 12, 0),
        ),
      ));
      await tester.pumpAndSettle();

      // Table structure: find LayoutBuilder's Column containing header + 2 day rows
      // The grid has 3 rows: Header, Monday, Tuesday.
      // Monday has gutter + 2 period cells (all Expanded).
      // Tuesday has gutter + 1 period cell + 1 free blank SizedBox.
      expect(find.text('Po'), findsOneWidget);
      expect(find.text('Út'), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('2.'), findsOneWidget);
      expect(find.textContaining('Novák'), findsOneWidget);
      expect(find.textContaining('Svobodová'), findsOneWidget);
    });
  });

  group('Language and strings formatting', () {
    test('dayNameFollowsAppLanguage', () {
      final monday = DateTime(2026, 9, 14);
      final prevCore = core.getLanguage();
      final prevStrings = Strings.lang;
      try {
        core.setLanguage('cs');
        Strings.lang = 'cs';
        expect(dayName(monday), equals('Pondělí'));
        expect(dayName(monday, true), equals('Po'));
        core.setLanguage('en');
        Strings.lang = 'en';
        expect(dayName(monday), equals('Monday'));
        expect(dayName(monday, true), equals('Mon'));
      } finally {
        core.setLanguage(prevCore);
        Strings.lang = prevStrings;
      }
    });

    test('lessonsTextCzechPlurals', () {
      final prevCore = core.getLanguage();
      final prevStrings = Strings.lang;
      try {
        core.setLanguage('cs');
        Strings.lang = 'cs';
        expect(
          [0, 1, 2, 4, 5, 7].map(lessonsText).toList(),
          equals(['0 hodin', '1 hodina', '2 hodiny', '4 hodiny', '5 hodin', '7 hodin']),
        );
        core.setLanguage('en');
        Strings.lang = 'en';
        expect(
          [1, 4].map(lessonsText).toList(),
          equals(['1 lesson', '4 lessons']),
        );
      } finally {
        core.setLanguage(prevCore);
        Strings.lang = prevStrings;
      }
    });
  });

  group('Settings and lunches structure', () {
    test('settingsNavGroupsCoverEverySection', () {
      final grouped = [
        for (final (_, ids) in SettingsController.navGroups) ...ids,
      ];
      final sectionIds = SettingsController.sections.map((s) => s.$1).toList();
      final sortedGrouped = List<String>.of(grouped)..sort();
      final sortedSections = List<String>.of(sectionIds)..sort();
      expect(sortedGrouped, equals(sortedSections));
      expect(grouped.length, equals(grouped.toSet().length));
      expect(SettingsController.sectionIcons.keys.toSet(), equals(grouped.toSet()));
    });

    test('lunchMealNameSplit', () {
      expect(
        splitMeal('Kulajda; Pečené kuře, rýže (1,7,9)'),
        equals(('Kulajda', 'Pečené kuře, rýže', '1, 7, 9')),
      );
      expect(
        splitMeal('Rizoto se sýrem,okurka(1a, 7)'),
        equals(('', 'Rizoto se sýrem, okurka', '1a, 7')),
      );
    });
  });

  group('Headless builds and responsiveness', () {
    testWidgets('allViewsBuildHeadless', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      // 1. Today
      await tester.pumpWidget(_app(
        LiveTodayView(tokens: tokens, narrow: false),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveTodayView), findsOneWidget);

      // 2. Timetable
      await tester.pumpWidget(_app(
        LiveTimetableView(tokens: tokens, narrow: false),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveTimetableView), findsOneWidget);

      // 3. Absences
      await tester.pumpWidget(_app(
        LiveAbsencesView(tokens: tokens, narrow: false),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveAbsencesView), findsOneWidget);

      // 4. Marks
      await tester.pumpWidget(_app(
        LiveMarksView(tokens: tokens, narrow: false),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveMarksView), findsOneWidget);

      // 5. Planner
      await tester.pumpWidget(_app(
        const LivePlannerView(narrow: false),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LivePlannerView), findsOneWidget);

      // 6. Lunches
      await tester.pumpWidget(_app(
        const LiveLunchesView(narrow: false),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveLunchesView), findsOneWidget);

      // 7. Activity (idle)
      await tester.pumpWidget(_app(
        LiveActivityView(narrow: false, tokens: tokens),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveActivityView), findsOneWidget);

      // Activity (busy - pump instead of pumpAndSettle due to CircularProgressIndicator)
      final state = container.read(appStateProvider);
      state.refreshRunning = true;
      state.currentStep = 'fetching…';
      await tester.pumpWidget(_app(
        LiveActivityView(narrow: false, tokens: tokens),
        container: container,
      ));
      await tester.pump();
      expect(find.byType(LiveActivityView), findsOneWidget);

      // Activity (error)
      state.refreshRunning = false;
      state.status = 'error';
      state.runs.add({'ok': false, 'finished': 'x', 'started': 'x', 'detail': 'boom'});
      await tester.pumpWidget(_app(
        LiveActivityView(narrow: false, tokens: tokens),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveActivityView), findsOneWidget);

      // 8. Settings
      await tester.pumpWidget(_app(
        const LiveSettingsView(narrow: false),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveSettingsView), findsOneWidget);
    });

    testWidgets('timetableListViewBuilds', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final s = container.read(appStateProvider);
      s.data = {
        'absence': {'Matematika': 5.0},
        'timetable': {
          '07.09.2026': [
            {'subject': 'Matematika', 'time': '1 (8:00 - 8:45)', 'room': 'U12', 'teacher': 'Novak'},
          ],
        },
      };
      s.timetableView = 'list';

      await tester.pumpWidget(_app(
        LiveTimetableView(tokens: tokens, narrow: false),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveTimetableView), findsOneWidget);
    });

    testWidgets('timetableStableViewBuilds', (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final s = container.read(appStateProvider);
      s.data = {
        'absence': {'Matematika': 5.0},
        'timetable': {
          '07.09.2026': [
            {'subject': 'Matematika', 'time': '1 (8:00 - 8:45)', 'room': 'U12', 'teacher': 'Novak'},
          ],
        },
        'stable_baseline': {
          'days': {
            '1': [
              {'subject': 'Matematika', 'period': 1, 'room': 'U12', 'teacher': 'Novak'},
            ],
          },
        },
        'stable_baseline_source': 'scraped',
      };
      s.setShowStable(true);

      await tester.pumpWidget(_app(
        LiveTimetableView(tokens: tokens, narrow: false),
        container: container,
      ));
      await tester.pumpAndSettle();
      expect(find.byType(LiveTimetableView), findsOneWidget);
    });

    testWidgets('activityStacksColumnsInNarrowWindows', (tester) async {
      final actController = ActivityController({});
      // Wide layout (e.g. desktop)
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(_app(
        ActivityView(controller: actController, narrow: false),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(ActivityView), findsOneWidget);

      // Narrow layout (e.g. mobile)
      tester.view.physicalSize = const Size(400, 800);
      await tester.pumpWidget(_app(
        ActivityView(controller: actController, narrow: true),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(ActivityView), findsOneWidget);

      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  });
}
