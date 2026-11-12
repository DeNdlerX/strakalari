import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/lunches/lunches_controller.dart';
import 'package:app/features/lunches/lunches_view.dart';
import 'package:app/features/more.dart';
import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/features/timetable/timetable_controller.dart';
import 'package:app/features/timetable/timetable_view.dart';
import 'package:app/features/today/today_live.dart';
import 'package:app/features/today/today_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

List<String> extractTexts(WidgetTester tester) {
  final out = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final text = widget.data ?? widget.textSpan?.toPlainText();
    if (text != null && text.isNotEmpty) {
      out.add(text);
    }
  }
  return out;
}

void _noop(String _) {}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_wakeup_ui_test_');
    core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    core.setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('TestTimetableViews', () {
    testWidgets('gridFramesOnlyFreePeriodsWithinADay', (tester) async {
      tester.view.physicalSize = const Size(1280, 1024);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final controller = TimetableController();
      controller.timetable = {
        '12.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
          {'time': '3 (10:00 - 10:45)', 'subject': 'Fyzika'},
        ],
        '13.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Chemie'},
        ],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimetableView(
              controller: controller,
              tokens: AppTokens.dark(),
              narrow: false,
            ),
          ),
        ),
      );

      final texts = extractTexts(tester);
      expect(texts, contains('Matematika'));
      expect(texts, contains('Fyzika'));
      expect(texts, contains('Chemie'));
    });

    testWidgets('listViewShowsPausesAndFoldsDays', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final controller = TimetableController();
      controller.timetableView = 'list';
      controller.timetable = {
        '12.10.2026': [
          {'time': '2 (8:55 - 9:40)', 'subject': 'Matematika'},
          {'time': '4 (10:55 - 11:40)', 'subject': 'Čeština'},
        ],
        '13.10.2026': [
          {'time': '1 (8:00 - 8:45)', 'subject': 'Angličtina'},
        ],
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimetableView(
              controller: controller,
              tokens: AppTokens.dark(),
              narrow: true,
            ),
          ),
        ),
      );

      expect(find.byType(ExpansionTile), findsWidgets);

      controller.setDayExpanded('tt:2026-10-12', false);
      expect(controller.isDayExpanded('tt:2026-10-12'), isFalse);
    });
  });

  group('TestCollapsibleDays', () {
    testWidgets('wholeDayExcuseListsLessonsInAFoldedSection', (tester) async {
      // The Ahem test font is far wider than the real one: a wide surface
      // keeps the picker and its buttons on one row, as on a desktop.
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      // Like Python: the two tasks are injected, so the result does not
      // depend on today's date (the 30-day excuse window).
      final tasks = <Map<String, Object?>>[
        {
          'key': '2026-10-12#1',
          'label': 'Po 12.10. · 1. hodina (M)',
          'date': '2026-10-12',
          'kind': 'short',
          'period': 1,
        },
        {
          'key': '2026-10-12#2',
          'label': 'Po 12.10. · 2. hodina (ČJ)',
          'date': '2026-10-12',
          'kind': 'short',
          'period': 2,
        },
      ];
      final s = AppState()..excuseTasksOverride = () => tasks;

      Future<void> build(int round) => withClock(
            Clock.fixed(DateTime(2026, 10, 13, 10)),
            () => tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  // A new key per round: built from scratch, like Python
                  // calling `_excuse_cards` again.
                  body: TodayView(
                    key: ValueKey(round),
                    controller: todayControllerFor(s),
                    tokens: AppTokens.dark(),
                  ),
                ),
              ),
            ),
          );

      bool isOpen() => ExpansionTileController.of(
            tester.element(find.descendant(
              of: find.byType(ExpansionTile),
              matching: find.byType(ListTile),
            ).first),
          ).isExpanded;

      await build(0);
      final tiles = find.byType(ExpansionTile);
      expect(tiles, findsOneWidget);
      expect(isOpen(), isFalse);
      final title = tester.widget<ExpansionTile>(tiles).title as Text;
      expect(
        title.data,
        anyOf('Nebo jednotlivě (2 hodiny)', 'Or one by one (2 lessons)'),
      );

      s.setDayExpanded('excuse:2026-10-12', true);
      await build(1);
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsOneWidget);
      expect(isOpen(), isTrue);
    });

    testWidgets('lunchDaysOpenFromTodayOn', (tester) async {
      final now = DateTime.now();
      final future = now.add(const Duration(days: 3));
      final past = now.subtract(const Duration(days: 3));

      final futureStr = '${future.day.toString().padLeft(2, '0')}.${future.month.toString().padLeft(2, '0')}.${future.year}';
      final pastStr = '${past.day.toString().padLeft(2, '0')}.${past.month.toString().padLeft(2, '0')}.${past.year}';

      final controller = LunchController({});
      controller.stravaOn = true;
      controller.showPastLunches = true;
      controller.food = {
        pastStr: {'m1': 'Polévka; Řízek'},
        futureStr: {'m1': 'Polévka; Řízek'},
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LunchesView(
              controller: controller,
            ),
          ),
        ),
      );

      final pastTile = tester.widget<ExpansionTile>(find.byKey(ValueKey('tile_$pastStr')));
      final futureTile = tester.widget<ExpansionTile>(find.byKey(ValueKey('tile_$futureStr')));
      expect(pastTile.initiallyExpanded, isFalse);
      expect(futureTile.initiallyExpanded, isTrue);

      controller.setDayExpanded('lunch:$futureStr', false);
      expect(controller.isDayExpanded('lunch:$futureStr'), isFalse);
    });
  });

  group('TestWakeupUI', () {
    test('alarmSectionIsAndroidOnly', () {
      final c = SettingsController({});
      expect(c.sectionsHere(platform: 'android').any((s) => s.$1 == 'alarm'), isTrue);
      expect(c.sectionsHere(platform: 'windows').any((s) => s.$1 == 'alarm'), isFalse);
      expect(c.sectionsHere(platform: 'ios').any((s) => s.$1 == 'alarm'), isFalse);
      expect(c.sectionsHere().any((s) => s.$1 == 'alarm'), isFalse);
    });

    test('alarmIsItsOwnSectionNotUnderRules', () {
      expect(SettingsController.sections.any((s) => s.$1 == 'alarm'), isTrue);
      expect(SettingsController.sections.any((s) => s.$1 == 'rules'), isTrue);
      final schoolGroup = SettingsController.navGroups
          .firstWhere((g) => g.$1 == 'sec_group_school');
      expect(schoolGroup.$2.contains('alarm'), isTrue);
      final automationGroup = SettingsController.navGroups
          .firstWhere((g) => g.$1 == 'sec_group_automation');
      expect(automationGroup.$2.contains('rules'), isTrue);
      expect(automationGroup.$2.contains('alarm'), isFalse);
    });

    testWidgets('sectionExplainsAMissingBridge', (tester) async {
      final c = SettingsController({}, wakeupAvailable: false);
      c.settingsSection = 'alarm';
      c.settingsOpen = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsView(
              controller: c,
              narrow: true,
              platform: 'android',
            ),
          ),
        ),
      );

      final texts = extractTexts(tester);
      expect(texts, contains(Strings.get('wakeup_title')));
      expect(texts, contains(Strings.get('wakeup_unavailable')));
      expect(texts.contains(Strings.get('wakeup_enable')), isFalse);
    });

    test('moreMenuOpensTheAlarmOnAndroid', () {
      final normalEntries = const MorePage(onOpen: _noop, isAndroid: false).visibleEntries();
      expect(normalEntries.any((e) => e.$1 == 'alarm'), isFalse);

      final androidEntries = const MorePage(onOpen: _noop, isAndroid: true).visibleEntries();
      expect(androidEntries.any((e) => e.$1 == 'alarm'), isTrue);
      expect(androidEntries[androidEntries.length - 2].$1, 'alarm');
    });

    testWidgets('settingsCardShowsNextAlarmAndWarnings', (tester) async {
      final c = SettingsController(
        {'wakeup_enabled': true},
        wakeupAvailable: true,
      );
      c.settingsSection = 'alarm';
      c.settingsOpen = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsView(
              controller: c,
              narrow: true,
              platform: 'android',
            ),
          ),
        ),
      );

      final texts = extractTexts(tester);
      expect(texts, contains(Strings.get('wakeup_title')));
      expect(texts, contains(Strings.get('wakeup_enable')));
    });

    test('onlyRelevantSavesReachThePhone', () {
      expect(core.phoneConfigKeys.contains('theme'), isFalse);
      expect(core.phoneConfigKeys.contains('wakeup_enabled'), isTrue);
      expect(core.phoneConfigKeys.contains('wakeup_minutes_before'), isTrue);
      expect(core.phoneConfigKeys.contains('wakeup_skip_dates'), isTrue);

      final s = AppState();
      var notified = 0;
      s.configListeners.add(() => notified++);
      expect(s.save({'theme': 'light'}), isTrue);
      expect(notified, 1);
    });

    test('plannedFirstLessonsMoveTheAlarm', () {
      final tomorrow = DateTime.now().add(const Duration(days: 1));
      final tomorrowStr = '${tomorrow.day.toString().padLeft(2, '0')}.${tomorrow.month.toString().padLeft(2, '0')}.${tomorrow.year}';
      final tomorrowIso = '${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}';

      final s = AppState(
        configData: {
          'wakeup_enabled': true,
          'wakeup_minutes_before': 60,
          'planned_skips': [
            {
              'start_date': tomorrowIso,
              'end_date': tomorrowIso,
              'start_period': 1,
              'end_period': 2,
            },
          ],
        },
        data: {
          'timetable': {
            tomorrowStr: [
              {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
              {'time': '2 (8:55 - 9:40)', 'subject': 'Fyzika'},
              {'time': '3 (10:00 - 10:45)', 'subject': 'Chemie'},
            ],
          },
        },
      );
      s.wakeupAvailableOverride = true;
      s.demoMode = false;

      final alarm = s.nextWakeupAlarm();
      expect(alarm, isNotNull);
      expect(alarm!.subject, 'Chemie');
      expect(alarm.alarmTimeLabel, '09:00');
    });

    test('demoLessonsNeverRing', () {
      final s = AppState(
        configData: {'wakeup_enabled': true},
      );
      s.wakeupAvailableOverride = true;
      s.demoMode = true;

      expect(s.nextWakeupAlarm(), isNull);
    });
  });
}
