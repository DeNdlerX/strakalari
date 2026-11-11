import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/format.dart';
import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_live.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/features/today/today_live.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/widgets/overlays.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart'
    show WakeupPhoneBridge, resetWakeupSyncState, wakeupPhoneBridge;

/// Port of the UI cases of `tests/test_wakeup_and_widget.py::TestWakeupUI`
/// (the wake-up card in Settings, the Today card, planner syncs).
///
/// "Now" is fixed to Monday 12 Oct 2026, 12:00 so every case is
/// deterministic (Python uses `date.today()`).
final _now = DateTime(2026, 10, 12, 12, 0);
final _tomorrow = DateTime(2026, 10, 13);

const _on = {'wakeup_enabled': true, 'wakeup_minutes_before': 60};
const _noHolidays = {
  'school_preset_id': 'custom',
  'user_free_days': <Object?>[],
  'holidays': <Object?>[],
};

String _key(DateTime d) => dayKey(d);

AppState _state({
  Map<String, Object?> config = const {},
  Map<String, Object?>? timetable,
}) {
  final s = AppState(
    configData: {..._on, ..._noHolidays, ...config},
    data: {
      'absence': {'Matematika': 1.0},
      'timetable': timetable ??
          {
            _key(_tomorrow): [
              {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
            ],
          },
    },
  );
  s.demoMode = false;
  s.wakeupAvailableOverride = true;
  return s;
}

class _Phone {
  bool notifications;
  bool exact;
  final opened = <(int, int, int?)>[];
  bool openResult;

  _Phone({this.notifications = true, this.exact = true, this.openResult = true});

  WakeupPhone build(AppState s) => WakeupPhone(
        notificationsEnabled: notifications,
        exactAlarmsAllowed: exact,
        nextAlarm: () => s.nextWakeupAlarm(_now),
        skippedDays: () => s.skippedWakeupDays(_now),
        openSystemAlarm: (h, m, message, {int? weekday}) async {
          opened.add((h, m, weekday));
          return openResult;
        },
        requestNotificationPermission: () {},
        openNotificationSettings: () {},
        openExactAlarmSettings: () {},
      );
}

Future<void> _pumpCard(WidgetTester t, AppState s, _Phone phone) async {
  t.view.physicalSize = const Size(900, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  s.setSettingsSection('alarm');
  final c = settingsControllerFor(s, wakeupPhone: phone.build(s));
  await t.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SettingsView(controller: c, narrow: true, platform: 'android'))));
  await t.pump();
}

List<String> _texts(WidgetTester t) => [
      for (final e in find.byType(Text).evaluate())
        if ((e.widget as Text).data != null) (e.widget as Text).data!,
    ];

String _day(DateTime d) => '${dayName(d, Strings.lang, short: true)} ${czDay(d)}';

Future<void> _inClock(Future<void> Function() body) =>
    withClock(Clock.fixed(_now), body);

void main() {
  setUp(() {
    Strings.lang = 'cs';
    SnackLog.clear();
  });

  group('TestWakeupUI (settings card)', () {
    testWidgets('minutesUpdateTheTextsInPlace', (t) => _inClock(() async {
          final s = _state();
          var emits = 0;
          s.onChanged = () => emits++;
          await _pumpCard(t, s, _Phone());
          emits = 0; // opening the section is not a save
          expect(_texts(t).any((x) => x.contains('07:00')), isTrue);
          await t.enterText(find.byType(TextField), '30');
          FocusManager.instance.primaryFocus?.unfocus();
          await t.pump();
          final texts = _texts(t);
          expect(s.get('wakeup_minutes_before'), 30);
          expect(emits, 0); // the screen is not re-rendered
          expect(texts, contains(Strings.format('wakeup_hint', {'n': 30})));
          expect(texts.any((x) => x.contains('07:30')), isTrue);
          expect(texts.any((x) => x.contains('07:00')), isFalse);
        }));

    testWidgets('openClockReportsAFailure', (t) => _inClock(() async {
          final s = _state();
          final phone = _Phone(openResult: false);
          await _pumpCard(t, s, phone);
          await t.tap(find.text(Strings.get('wakeup_set_clock')));
          await t.pump();
          expect(phone.opened.map((o) => (o.$1, o.$2)), [(7, 0)]);
          expect(SnackLog.last, Strings.get('wakeup_clock_failed'));
        }));

    testWidgets('aLaterAlarmGoesToTheClockOnItsWeekday', (t) => _inClock(() async {
          // Monday's alarm asked for days before: the Clock app gets Monday
          // (a weekly alarm, it takes no date) and the page says so.
          final monday = DateTime(2026, 10, 19);
          final s = _state(timetable: {
            _key(monday): [
              {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
            ],
          });
          final phone = _Phone();
          await _pumpCard(t, s, phone);
          final weekly = Strings.get('wakeup_clock_weekly').split(':').first;
          expect(_texts(t).any((x) => x.startsWith(weekly)), isTrue);
          await t.tap(find.text(Strings.get('wakeup_set_clock')));
          await t.pump();
          // Python weekday(): Monday = 0.
          expect(phone.opened, [(7, 0, 0)]);
        }));

    testWidgets('settingsCardShowsNextAlarmAndWarnings', (t) => _inClock(() async {
          final s = _state(config: {
            'wakeup_skip_dates': [
              '2026-10-17',
              '2000-01-01',
            ],
          });
          await _pumpCard(t, s, _Phone(notifications: false, exact: false));
          final texts = _texts(t);
          expect(texts, contains(Strings.get('wakeup_title')));
          expect(texts, contains(Strings.get('wakeup_enable')));
          expect(texts, contains(Strings.get('wakeup_notif_off')));
          expect(texts, contains(Strings.get('wakeup_exact_off')));
          expect(
              texts.any((x) => x.contains('07:00') && x.contains('Matematika')),
              isTrue);
          // One restore button: the past skipped day is gone.
          final prefix = Strings.get('wakeup_restore_day').split('{').first;
          expect(texts.where((x) => x.startsWith(prefix)).length, 1);
        }));

    testWidgets('settingsCardNamesTheDayTheAlarmRings', (t) => _inClock(() async {
          // An alarm reaching back past midnight is shown on the evening it
          // rings, with the lesson's own day beside it.
          final day = DateTime(2026, 10, 14);
          final s = _state(
            config: {'wakeup_minutes_before': 600},
            timetable: {
              _key(day): [
                {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
              ],
            },
          );
          await _pumpCard(t, s, _Phone());
          expect(
              _texts(t),
              contains(Strings.format('wakeup_next_eve', {
                'day': _day(DateTime(2026, 10, 13)),
                'alarm': '22:00',
                'lesson_day': _day(day),
                'subject': 'Matematika',
                'lesson': '08:00',
              })));
        }));

    testWidgets('restoreButtonsOnlyForAlarmsStillAhead', (t) => _inClock(() async {
          // Today's skipped alarm has passed: no button for it lingers
          // through the day; tomorrow's still gives the alarm back.
          final today = DateTime(2026, 10, 12);
          final s = _state(
            config: {
              'wakeup_minutes_before': 1,
              'wakeup_skip_dates': ['2026-10-12', '2026-10-13'],
            },
            timetable: {
              _key(today): [
                {'time': '1 (0:01 - 0:45)', 'subject': 'Matematika'},
              ],
              _key(_tomorrow): [
                {'time': '1 (8:00 - 8:45)', 'subject': 'Fyzika'},
              ],
            },
          );
          await _pumpCard(t, s, _Phone());
          final prefix = Strings.get('wakeup_restore_day').split('{').first;
          expect(_texts(t).where((x) => x.startsWith(prefix)).toList(), [
            Strings.format('wakeup_restore_alarm',
                {'day': _day(_tomorrow), 'time': '07:59'}),
          ]);
        }));
  });

  group('TestWakeupUI (today card)', () {
    test('todayCardNamesAnAlarmTheEveningBefore', () {
      withClock(Clock.fixed(_now), () {
        final s = _state(config: {'wakeup_minutes_before': 600});
        final badge =
            todayControllerFor(s, now: _now).nextLesson(_now).alarmBadge;
        expect(
            badge,
            Strings.format('wakeup_badge_eve', {
              'day': dayName(DateTime(2026, 10, 12), 'cs', short: true),
              'time': '22:00',
            }));
      });
    });

    test('todayCardShowsTheAlarmOnItsDay', () {
      withClock(Clock.fixed(DateTime(2026, 10, 12, 6, 30)), () {
        final now = DateTime(2026, 10, 12, 6, 30);
        final s = _state(
          config: {'wakeup_minutes_before': 45},
          timetable: {
            _key(DateTime(2026, 10, 12)): [
              {
                'time': '1 (8:00 - 8:45)',
                'subject': 'Matematika',
                'room': '201'
              },
            ],
          },
        );
        // Without the phone bridge the card names no alarm.
        s.wakeupAvailableOverride = false;
        expect(todayControllerFor(s, now: now).nextLesson(now).alarmBadge,
            isNull);
        s.wakeupAvailableOverride = true;
        expect(todayControllerFor(s, now: now).nextLesson(now).alarmBadge,
            Strings.format('wakeup_badge', {'time': '07:15'}));
      });
    });
  });

  group('TestWakeupUI (planner reaches the phone)', () {
    // `plan_custom_skip`, `plan_days` and `unplan_entry` each hand the new
    // alarm queue to the phone (sync_android_state): the bridge is sent only
    // what changed, so every plan below changes the queue.
    test('plannerChangesReachThePhone', () {
      withClock(Clock.fixed(_now), () {
        final bridge = _CountingBridge();
        wakeupPhoneBridge = bridge;
        resetWakeupSyncState();
        addTearDown(() {
          wakeupPhoneBridge = null;
          resetWakeupSyncState();
        });
        final s = _state(timetable: {
          for (final d in [13, 14, 15])
            _key(DateTime(2026, 10, d)): [
              {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
              {'time': '2 (8:55 - 9:40)', 'subject': 'Fyzika'},
            ],
        });
        expect(s.planCustomSkip('2026-10-13', '2026-10-13', 1, 2, '',
            cancelLunch: false), isTrue);
        expect(bridge.alarmCalls, 1);
        expect(s.planDays(['2026-10-14'], '', false), 1);
        expect(bridge.alarmCalls, 2);
        expect(s.unplanEntry(s.plannedSkips.first), isTrue);
        expect(bridge.alarmCalls, 3);
      });
    });
  });
}

class _CountingBridge implements WakeupPhoneBridge {
  int alarmCalls = 0;

  @override
  bool setWakeupAlarms(String queueJson, String channel, String dismiss) {
    alarmCalls++;
    return true;
  }

  @override
  bool updateTimetableWidget(String widgetJson) => true;
}
