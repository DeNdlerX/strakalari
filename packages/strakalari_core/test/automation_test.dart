// Port of the safety-critical send-path tests.
//
// Covers test_excuse_generation.py, test_strava_ordering.py (order-selected
// path), test_strava_low_balance.py (ordering half), test_unconfirmed_excuses.py
// (TestSendPath, TestOutboxSettles), test_excuse_history.py (phase-4 cases:
// concurrent sends, covered-not-resent, example fallback, dry-run fill),
// test_sent_excuses.py (sync half), test_excuse_ignore_list.py
// (TestIgnoredExcuses), test_models.py (2 engine cases), test_config.py
// (phase-4 cases), test_data_safety.py (history/write-log/blacklist/quarantine
// cases), test_automation_safety.py (send/audit/count cases) and the dry-run
// excuse cases of test_timetable_cache_merge.py.
//
// Phase-3 hooks (resolveLunchCutoffHook etc.) are assigned fakes here —
// the Dart mirror of monkeypatching the module functions. Cases whose SUT
// lives in the Flutter UI or another phase are NOT here (see the
// delivery report): AppState/tray/dialog cases, the gemini fallback,
// and the pure excuse_history/config/cache cases already covered by
// excuse_history_test.dart, config_test.dart, cache_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/audit.dart' as audit;
import 'package:strakalari_core/src/automation/automation.dart';
import 'package:strakalari_core/src/automation/excuse_history.dart';
import 'package:strakalari_core/src/bakalari/client.dart';
import 'package:strakalari_core/src/models.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/helpers.dart';
import 'package:strakalari_core/src/storage/secret_store.dart';
import 'package:strakalari_core/src/strava/client.dart';

/// Scripted Bakaláři client (mirrors the MagicMock clients in Python).
class FakeBak extends BakalariClient {
  FakeBak({Map<String, Object?> cfg = const {}}) : super(cfg);

  int loginCalls = 0;
  int executeCalls = 0;
  int fillCalls = 0;
  bool executeResult = true;
  bool executeUncertain = false;
  bool fillResult = true;
  Duration executeDelay = Duration.zero;
  Completer<void>? executeGate;
  List<List<Object?>> executeArgs = [];
  List<Map<String, Object?>>? sentExcusesResult = [];

  @override
  Future<void> login() async {
    loginCalls++;
  }

  @override
  Future<bool> executeExcuse(String dayStart, String dayEnd,
      [Object? startLesson,
      Object? endLesson,
      String? customText,
      bool isDays = false,
      String? excuseType]) async {
    executeCalls++;
    executeArgs.add(
        [dayStart, dayEnd, startLesson, endLesson, customText, isDays, excuseType]);
    final gate = executeGate;
    if (gate != null) await gate.future;
    if (executeDelay > Duration.zero) {
      await Future<void>.delayed(executeDelay);
    }
    lastSubmitUncertain = executeUncertain;
    return executeResult;
  }

  @override
  Future<bool> fillExcuseForm(String dayStart, String dayEnd,
      [Object? startLesson,
      Object? endLesson,
      String? customText,
      bool isDays = false,
      String? excuseType]) async {
    fillCalls++;
    return fillResult;
  }

  @override
  Future<List<Map<String, Object?>>?> fetchSentExcuses(
      {int limit = 100}) async {
    return sentExcusesResult;
  }
}

/// Scripted Strava client (mirrors the hand fakes in Python).
class FakeStrava extends StravaClient {
  FakeStrava({Map<String, Object?> cfg = const {}}) : super(cfg);

  Map<String, bool> orderOk = {};
  List<bool> orderScript = [];
  bool clickOnOrder = true;

  /// null = missing (like the Python hand fakes): the persisted check
  /// falls back to "not immediate".
  bool? saveButton;
  bool saveResult = true;
  List<String>? saved;
  List<String>? restoredDays;
  int orderCalls = 0;

  @override
  Future<void> login() async {}

  @override
  Future<Map<String, Object?>> fetchData() async => {};

  @override
  bool order(Object? mealId, [List<Object?>? allDayIds]) {
    orderCalls++;
    final m = '$mealId';
    final ok = orderScript.isNotEmpty
        ? orderScript.removeAt(0)
        : (orderOk[m] ?? false);
    if (clickOnOrder && !orderedDict.values.contains(m)) {
      clicksMade++;
    }
    return ok;
  }

  Set<String>? verifiedIds;

  @override
  bool verified(Object? mealId) =>
      verifiedIds == null ? true : verifiedIds!.contains('$mealId');

  @override
  String noticeSuffix() => '';

  @override
  void restoreOriginal(
      List<Object?> failed, Map<String, Object?> originalOrdered) {
    restoredDays = [
      for (final p in failed) '${(p as Map)['day']}'
    ];
  }

  @override
  Future<bool> saveConfirm([List<String>? verifyIds]) async {
    saved = verifyIds == null ? null : List<String>.of(verifyIds);
    return saveResult;
  }

  @override
  bool findSaveButton([int timeoutMs = 0]) {
    final b = saveButton;
    if (b == null) throw UnimplementedError('no save button seam');
    return b;
  }
}

/// Orders the first meal, then Strava refuses everything for lack of money.
class BrokeStrava extends StravaClient {
  BrokeStrava(this.seedMenu) : super(const {});

  final Map<String, Map<String, String>> seedMenu;
  final List<String> ordered = [];

  @override
  Future<void> login() async {}

  @override
  Future<Map<String, Object?>> fetchData() async {
    foodDict.clear();
    foodDict.addAll(seedMenu);
    return {};
  }

  @override
  bool order(Object? mealId, [List<Object?>? allDayIds]) {
    final m = '$mealId';
    if (m.contains('&-1&')) {
      ordered.add(m);
      return true;
    }
    if (ordered.isNotEmpty && !insufficientBalance) {
      insufficientBalance = true;
      return false;
    }
    if (insufficientBalance) {
      throw StateError('no meal order may be tried after a low-balance refusal');
    }
    clicksMade++;
    ordered.add(m);
    return true;
  }

  @override
  bool verified(Object? mealId) => ordered.contains('$mealId');

  @override
  bool findSaveButton([int timeoutMs = 0]) => true;

  @override
  void restoreOriginal(
      List<Object?> failed, Map<String, Object?> originalOrdered) {
    throw StateError('a refused (unchanged) day needs no restore');
  }

  @override
  Future<bool> saveConfirm([List<String>? verifyIds]) async => true;
}

Strakalari realApp(Directory tmp,
    [Map<String, Object?> configData = const {}]) {
  return Strakalari(
      configFile: '${tmp.path}/config.json', configData: configData);
}

/// Strakalari with a stubbed timetable (mirrors monkeypatching
/// `timetableData` plus a failing `_send_excuse` tripwire in Python).
class _PendingApp extends Strakalari {
  _PendingApp(this.raw,
      {required super.configFile, super.configData})
      : super();

  final Map<String, Object?> raw;

  @override
  Map<String, Object?> get timetableData => raw;

  @override
  Future<String> sendExcuse(Map<String, Object?> excuse,
      String? customText, {String source = 'manual'}) async {
    throw StateError('ignored absence was sent');
  }
}

/// Strakalari with a stubbed pending list (mirrors monkeypatching
/// `Strakalari.generate_excuses` in Python).
class _PendingLessonApp extends Strakalari {
  _PendingLessonApp(this.pending,
      {required super.configFile, super.configData})
      : super();

  @override
  List<Map<String, Object?>> pendingExcuses() => pending;

  final List<Map<String, Object?>> pending;
}

/// Strakalari with a stubbed excuse text (mirrors monkeypatching
/// `default_excuse_text` in Python).
class _TextApp extends Strakalari {
  _TextApp({required super.configFile, super.configData}) : super();

  @override
  String defaultExcuseText(Map<String, Object?> excuse) => 'x';
}

Map<String, Object?> absentLesson(
        {String time = '1 (8:00-8:45)',
        String absType = 'Absent',
        String absText = 'Absence',
        String notice = ''}) =>
    {
      'teacher': 'T',
      'subject': 'M',
      'time': time,
      'absenceType': absType,
      'absencetext': absText,
      'notice': notice,
    };

String dmy(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

void main() {
  late Directory tmp;

  final defaultResolve = resolveLunchCutoffHook;
  final defaultCalendar = effectiveCalendarFreeHook;
  final defaultIsOpen = isLunchOrderOpenHook;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('automation_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    clearKeyCache();
    // Open future days; past days stay closed (mirrors the real cutoff
    // for the far-future/past dates the tests use).
    resolveLunchCutoffHook = (_) => '12:00';
    effectiveCalendarFreeHook = (_) => <DateTime>{};
    isLunchOrderOpenHook = (day, now, cutoff, free) =>
        !dateOnly(day).isBefore(dateOnly(now));
  });

  tearDown(() {
    resolveLunchCutoffHook = defaultResolve;
    effectiveCalendarFreeHook = defaultCalendar;
    isLunchOrderOpenHook = defaultIsOpen;
    setEnvironmentOverride(null);
    clearKeyCache();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // -- generate_excuses --------------------------------------------------------

  group('weekendBridging', () {
    test('gapDaysAreNotMerged', () {
      final Map<String, Object?> raw = {
        '07.09.2026': [absentLesson()],
        '09.09.2026': [absentLesson()],
      };
      final excuses = Strakalari.generateExcuses(raw,
          delayDays: 0, overrideToday: DateTime(2026, 9, 20));
      final ranges = [
        for (final e in excuses)
          if (e['type'] == 'pure days') (e['starting_day'], e['ending_day'])
      ];
      expect(ranges, contains(('07.09.2026', '07.09.2026')));
      expect(ranges, contains(('09.09.2026', '09.09.2026')));
      expect(ranges.every((r) => r.$1 == r.$2), isTrue);
    });

    test('trulyConsecutiveDaysStillMerge', () {
      final Map<String, Object?> raw = {
        '07.09.2026': [absentLesson()],
        '08.09.2026': [absentLesson()],
      };
      final excuses = Strakalari.generateExcuses(raw,
          delayDays: 0, overrideToday: DateTime(2026, 9, 20));
      expect(
          excuses.map(jsonEncode).toList(),
          contains(jsonEncode({
            'type': 'pure days',
            'starting_day': '07.09.2026',
            'ending_day': '08.09.2026',
          })));
    });
  });

  group('negatedCancelNotice', () {
    for (final notice in [
      'Neodpadá - beze změny',
      'NEODPADÁ',
      'Nezrušeno',
      'nezruseno',
      'Hodina nevyjmuta ze suplování',
      'ne odpadá',
    ]) {
      test('stillExcuses $notice', () {
        final Map<String, Object?> raw = {
          '10.09.2026': [absentLesson(notice: notice)]
        };
        expect(
            Strakalari.generateExcuses(raw,
                delayDays: 0,
                overrideToday: DateTime(2026, 9, 20)),
            hasLength(1));
      });
    }
    for (final notice in [
      'Odpadá',
      'Hodina odpadá',
      'Zrušeno',
      'Zruseno',
      'Vyjmuto ze suplování',
      'Vyňato',
    ]) {
      test('staysCancelled $notice', () {
        final Map<String, Object?> raw = {
          '10.09.2026': [absentLesson(notice: notice)]
        };
        expect(
            Strakalari.generateExcuses(raw,
                delayDays: 0,
                overrideToday: DateTime(2026, 9, 20)),
            isEmpty);
      });
    }
  });

  group('absenceCaseInsensitive', () {
    final bugfixToday = DateTime(2026, 9, 15);
    for (final v in [
      ('absent', 'neomluveno'),
      ('ABSENT', 'NEOMLUVENO'),
      ('Absent', 'Neomluvena'),
      ('Absent', 'Neomluvená'),
      ('Unexcused', 'Absence'),
      ('unexcused', 'absence'),
    ]) {
      test('variantsGenerate ${v.$1}/${v.$2}', () {
        final Map<String, Object?> raw = {
          '10.09.2026': [absentLesson(absType: v.$1, absText: v.$2)]
        };
        expect(
            generateExcuses(raw,
                delayDays: 0, overrideToday: bugfixToday),
            hasLength(1));
      });
    }
    for (final v in [
      ('AbsentLate', 'Pozdni prichod'),
      ('absentlate', 'pozdní příchod'),
    ]) {
      test('lateVariantsAreIncome ${v.$1}', () {
        final Map<String, Object?> raw = {
          '10.09.2026': [absentLesson(absType: v.$1, absText: v.$2)]
        };
        final excuses = generateExcuses(raw,
            delayDays: 0, overrideToday: bugfixToday);
        expect(excuses, hasLength(1));
        expect(excuses[0]['type'], 'income');
      });
    }

    test('cutoffIsDateBasedNotHourBased', () {
      final Map<String, Object?> raw = {
        '13.09.2026': [absentLesson()]
      };
      final morning = DateTime(2026, 9, 15, 0, 30);
      final night = DateTime(2026, 9, 15, 23, 30);
      expect(
          generateExcuses(raw, delayDays: 2, overrideToday: morning),
          generateExcuses(raw, delayDays: 2, overrideToday: night));
    });
  });

  group('excusedLessonsSkipped', () {
    Map<String, Object?> lesson(String teacher, String subject, String time,
            {String absText = '', String absType = ''}) =>
        {
          'teacher': teacher,
          'subject': subject,
          'time': time,
          'absencetext': absText,
          'absenceType': absType,
        };
    final today = DateTime(2026, 9, 15);

    test('excusedTypeSkipped', () {
      final Map<String, Object?> raw = {
        '10.09.2026': [
          lesson('T1', 'M', '1', absText: 'Omluveno', absType: 'Excused'),
          lesson('T2', 'F', '2', absText: 'Absence', absType: 'Absent'),
        ]
      };
      final excuses =
          generateExcuses(raw, delayDays: 1, overrideToday: today);
      expect(excuses, hasLength(1));
      expect(excuses[0]['starting_lesson'], 2);
      expect(excuses[0]['ending_lesson'], 2);
    });

    test('excusedTextWithAbsentTypeSkipped', () {
      final Map<String, Object?> raw = {
        '10.09.2026': [
          lesson('T1', 'M', '1', absText: 'Omluvená', absType: 'Absent'),
        ]
      };
      expect(generateExcuses(raw, delayDays: 1, overrideToday: today),
          isEmpty);
    });

    test('fullyExcusedDayProducesNothing', () {
      final Map<String, Object?> raw = {
        '10.09.2026': [
          lesson('T1', 'M', '1', absText: 'Omluveno'),
          lesson('T2', 'F', '2', absText: 'Omluveno'),
        ]
      };
      expect(generateExcuses(raw, delayDays: 1, overrideToday: today),
          isEmpty);
    });
  });

  group('holidayBridging', () {
    Map<String, Object?> lesson(String t, String s, String time,
            {String absText = '', String absType = ''}) =>
        {
          'teacher': t,
          'subject': s,
          'time': time,
          'absencetext': absText,
          'absenceType': absType,
        };
    final today = DateTime(2026, 9, 15);

    test('fridayAndTuesdayDoNotBridge', () {
      final Map<String, Object?> raw = {
        '04.09.2026': [
          lesson('T1', 'M', '1', absText: 'Absence'),
          lesson('T2', 'F', '2', absText: 'Absence')
        ],
        '08.09.2026': [
          lesson('T1', 'M', '1', absText: 'Absence'),
          lesson('T2', 'F', '2', absText: 'Absence')
        ],
      };
      final excuses =
          generateExcuses(raw, delayDays: 1, overrideToday: today);
      expect(excuses, hasLength(2));
      expect(excuses.every((e) => e['type'] == 'pure days'), isTrue);
      expect(excuses[0]['starting_day'], '04.09.2026');
      expect(excuses[0]['ending_day'], '04.09.2026');
      expect(excuses[1]['starting_day'], '08.09.2026');
      expect(excuses[1]['ending_day'], '08.09.2026');
    });

    test('presentDayStillBreaksChain', () {
      final Map<String, Object?> raw = {
        '07.09.2026': [
          lesson('T1', 'M', '1', absText: 'Absence'),
          lesson('T2', 'F', '2', absText: 'Absence')
        ],
        '08.09.2026': [lesson('T1', 'M', '1'), lesson('T2', 'F', '2')],
        '09.09.2026': [
          lesson('T1', 'M', '1', absText: 'Absence'),
          lesson('T2', 'F', '2', absText: 'Absence')
        ],
      };
      final excuses =
          generateExcuses(raw, delayDays: 1, overrideToday: today);
      expect(excuses, hasLength(2));
      expect(excuses[0]['starting_day'], '07.09.2026');
      expect(excuses[1]['starting_day'], '09.09.2026');
    });
  });

  group('templatePick', () {
    test('firstMode', () {
      expect(Strakalari.pickTemplate(['a', 'b'], 'first'), 'a');
    });

    test('randomModePicksFromList', () {
      for (var i = 0; i < 20; i++) {
        expect(Strakalari.pickTemplate(['a', 'b', 'c'], 'random'),
            isIn(['a', 'b', 'c']));
      }
    });

    test('emptyTemplates', () {
      expect(Strakalari.pickTemplate([], 'random'), '');
    });
  });

  group('excuseDelayConfig', () {
    test('defaultDelay', () {
      expect(realApp(tmp).excuseDelayDays, 2);
    });

    test('customDelay', () {
      expect(
          realApp(tmp, {'excuse_delay_days': 5}).excuseDelayDays, 5);
    });
  });

  group('generateExcusesCases', () {
    final today = DateTime(2026, 9, 15);

    test('multiGroupStatusPrioritization', () {
      final Map<String, Object?> raw = {
        '10.09.2026': [
          {
            'teacher': 'Mgr. Jan Novák',
            'subject': 'Matematika',
            'time': '1 (8:00 - 8:45)',
            'absencetext': '',
            'absenceType': '',
          },
          {
            'teacher': 'Mgr. Eva Bílá',
            'subject': 'Německý jazyk (sk. 1)',
            'time': '2 (8:55 - 9:40)',
            'absencetext': 'Absence',
            'absenceType': 'Absent',
          },
          {
            'teacher': 'Mgr. Petr Černý',
            'subject': 'Francouzský jazyk (sk. 2)',
            'time': '2 (8:55 - 9:40)',
            'absencetext': '',
            'absenceType': '',
          },
        ]
      };
      final excuses =
          generateExcuses(raw, delayDays: 1, overrideToday: today);
      expect(excuses, hasLength(1));
      expect(excuses[0]['type'], 'days and hours');
      expect(excuses[0]['starting_day'], '10.09.2026');
      expect(excuses[0]['starting_lesson'], 2);
      expect(excuses[0]['ending_lesson'], 2);
    });

    test('pureDaysConsecutive', () {
      Map<String, Object?> l(String t, String s, String time) =>
          {'teacher': t, 'subject': s, 'time': time, 'absencetext': 'Absence'};
      final Map<String, Object?> raw = {
        '07.09.2026': [l('T1', 'M', '1'), l('T2', 'F', '2')],
        '08.09.2026': [l('T1', 'M', '1'), l('T2', 'F', '2')],
      };
      final excuses =
          generateExcuses(raw, delayDays: 1, overrideToday: today);
      expect(excuses, hasLength(1));
      expect(excuses[0]['type'], 'pure days');
      expect(excuses[0]['starting_day'], '07.09.2026');
      expect(excuses[0]['ending_day'], '08.09.2026');
    });

    test('lateIncomeExcuse', () {
      final Map<String, Object?> raw = {
        '10.09.2026': [
          {
            'teacher': 'T1',
            'subject': 'M',
            'time': '1',
            'absencetext': 'Pozdní příchod',
            'absenceType': 'AbsentLate',
          },
          {'teacher': 'T2', 'subject': 'F', 'time': '2', 'absencetext': ''},
        ]
      };
      final excuses =
          generateExcuses(raw, delayDays: 1, overrideToday: today);
      expect(excuses, hasLength(1));
      expect(excuses[0]['type'], 'income');
      expect(excuses[0]['starting_lesson'], 1);
      expect(excuses[0]['ending_lesson'], 1);
    });

    test('pureDaysAcrossWeekend', () {
      Map<String, Object?> l(String t, String s, String time) =>
          {'teacher': t, 'subject': s, 'time': time, 'absencetext': 'Absence'};
      final Map<String, Object?> raw = {
        '04.09.2026': [l('T1', 'M', '1'), l('T2', 'F', '2')],
        '07.09.2026': [l('T1', 'M', '1'), l('T2', 'F', '2')],
      };
      final excuses =
          generateExcuses(raw, delayDays: 1, overrideToday: today);
      expect(excuses, hasLength(2));
      expect(excuses.every((e) => e['type'] == 'pure days'), isTrue);
      expect(excuses[0]['starting_day'], '04.09.2026');
      expect(excuses[0]['ending_day'], '04.09.2026');
      expect(excuses[1]['starting_day'], '07.09.2026');
      expect(excuses[1]['ending_day'], '07.09.2026');
    });

    test('delayDaysCutoff', () {
      Map<String, Object?> l(String t, String s, String time) =>
          {'teacher': t, 'subject': s, 'time': time, 'absencetext': 'Absence'};
      final Map<String, Object?> raw = {
        '10.09.2026': [l('T1', 'M', '1')],
        '14.09.2026': [l('T1', 'M', '1')],
      };
      final excuses =
          generateExcuses(raw, delayDays: 2, overrideToday: today);
      expect(excuses, hasLength(1));
      expect(excuses[0]['starting_day'], '10.09.2026');
    });

    test('fragmentedSameDayAbsences', () {
      final Map<String, Object?> raw = {
        '10.09.2026': [
          {
            'teacher': 'T1',
            'subject': 'M',
            'time': '1 (8:00 - 8:45)',
            'absencetext': 'Absence'
          },
          {
            'teacher': 'T2',
            'subject': 'ČJ',
            'time': '2 (8:55 - 9:40)',
            'absencetext': ''
          },
          {
            'teacher': 'T3',
            'subject': 'AJ',
            'time': '3 (10:00 - 10:45)',
            'absencetext': ''
          },
          {
            'teacher': 'T4',
            'subject': 'D',
            'time': '4 (10:55 - 11:40)',
            'absencetext': 'Absence'
          },
        ]
      };
      final excuses =
          generateExcuses(raw, delayDays: 1, overrideToday: today);
      expect(excuses, hasLength(2));
      expect(excuses[0]['starting_lesson'], 1);
      expect(excuses[0]['ending_lesson'], 1);
      expect(excuses[1]['starting_lesson'], 4);
      expect(excuses[1]['ending_lesson'], 4);
    });

    test('genericEarlyLeaveIsAutoExcusedLikeUi', () {
      expect(absenceKind('AbsentEarly', 'Předčasný odchod'), 'early');
      final Map<String, Object?> raw = {
        '10.09.2026': [
          {
            'teacher': 'T',
            'subject': 'M',
            'time': '1',
            'absencetext': '',
            'absenceType': ''
          },
          {
            'teacher': 'T',
            'subject': 'F',
            'time': '2',
            'absencetext': 'Předčasný odchod',
            'absenceType': 'AbsentEarly'
          },
        ]
      };
      final excuses =
          generateExcuses(raw, delayDays: 1, overrideToday: today);
      expect(
          excuses
              .map((e) => (e['type'], e['starting_lesson']))
              .toList(),
          [('soon', 2)]);
    });

    test('notCountedAbsenceIsNeverExcused', () {
      expect(absenceKind('NotCounted', 'Nezapočtená absence'), '');
      expect(absenceKind('', 'Nezapočtená absence'), '');
      expect(absenceKind('School', 'Školní akce'), '');
      expect(absenceKind('Absent', 'Absence'), 'absent');
      final Map<String, Object?> raw = {
        '10.09.2026': [
          {
            'teacher': 'T',
            'subject': 'M',
            'time': '1',
            'absencetext': 'Nezapočtená absence',
            'absenceType': 'NotCounted'
          },
          {
            'teacher': 'T',
            'subject': 'F',
            'time': '2',
            'absencetext': 'Nezapočtená absence',
            'absenceType': 'NotCounted'
          },
        ]
      };
      expect(generateExcuses(raw, delayDays: 1, overrideToday: today),
          isEmpty);
    });
  });

  group('engineCases', () {
    Map<String, Object?> l({String absText = 'Absence', String absType = 'Absent'}) =>
        absentLesson(time: '1 (8:00-8:45)', absType: absType, absText: absText);

    test('engineExcusesNeomluvenoDay', () {
      final Map<String, Object?> raw = {
        '07.09.2026': [l(absText: 'Neomluveno')]
      };
      expect(
          Strakalari.generateExcuses(raw,
                  delayDays: 0,
                  overrideToday: DateTime(2026, 9, 20))
              .map(jsonEncode)
              .toList(),
          contains(jsonEncode({
            'type': 'pure days',
            'starting_day': '07.09.2026',
            'ending_day': '07.09.2026',
          })));
    });

    test('engineExcusesUnexcusedType', () {
      final Map<String, Object?> raw = {
        '07.09.2026': [l(absType: 'Unexcused')]
      };
      expect(
          Strakalari.generateExcuses(raw,
              delayDays: 0,
              overrideToday: DateTime(2026, 9, 20)),
          hasLength(1));
    });
  });

  group('ignoredExcuses', () {
    Map<String, Object?> absent(String time) => absentLesson(time: time);
    final today = DateTime(2026, 9, 20);

    String uiKey(Map<String, Object?> raw, int period) {
      final tasks = excuseTasksFromLessons(
          lessonsFromTimetable(Map<String, Object?>.of(raw)));
      return tasks.firstWhere((t) => t.period == period).key;
    }

    test('ignoredLessonIsNeverAutoExcused', () {
      final Map<String, Object?> raw = {
        '08.09.2026': [
          absent('1 (8:00-8:45)'),
          absent('2 (8:55-9:40)'),
          absent('3 (10:00-10:45)')
        ]
      };
      final key = uiKey(raw, 2);
      final excuses = generateExcuses(raw,
          delayDays: 0, overrideToday: today, ignored: [key]);
      expect(
          excuses
              .map((e) =>
                  (e['type'], e['starting_lesson'], e['ending_lesson']))
              .toSet(),
          {('days and hours', 1, 1), ('days and hours', 3, 3)});
    });

    test('ignoredDayBreaksFullDayChain', () {
      final Map<String, Object?> raw = {
        '07.09.2026': [absent('1 (8:00-8:45)')],
        '08.09.2026': [absent('1 (8:00-8:45)')],
        '09.09.2026': [absent('1 (8:00-8:45)')],
      };
      final key = uiKey(
          <String, Object?>{'08.09.2026': raw['08.09.2026']!}, 1);
      final excuses = generateExcuses(raw,
          delayDays: 0, overrideToday: today, ignored: [key]);
      expect(
          excuses
              .map((e) => (e['starting_day'], e['ending_day']))
              .toList(),
          [('07.09.2026', '07.09.2026'), ('09.09.2026', '09.09.2026')]);
    });

    test('excuseAbsencePassesConfigIgnoreList', () async {
      final day = dmy(clock.now().subtract(const Duration(days: 1)));
      final Map<String, Object?> raw = {
        day: [absent('1 (8:00-8:45)')]
      };
      final key = uiKey(raw, 1);
      final app = _PendingApp(raw,
          configFile: '${tmp.path}/config.json',
          configData: {
            'excuse_mode': 'auto',
            'excuse_delay_days': 0,
            'ignored_excuses': [key],
          });
      app.bakalariClient = FakeBak();
      expect(await app.excusePending(), 0);
    });

    test('garbageKeysAreIgnoredSafely', () {
      final Map<String, Object?> raw = {
        '08.09.2026': [absent('1 (8:00-8:45)')]
      };
      expect(
          generateExcuses(raw,
              delayDays: 0,
              overrideToday: today,
              ignored: const ['nonsense', '2026-13-01|1|M', null]),
          generateExcuses(raw, delayDays: 0, overrideToday: today));
    });
  });

  // -- the send path -----------------------------------------------------------

  group('sendPath', () {
    Map<String, Object?> lesson() => {
          'type': 'days and hours',
          'starting_day': '21.09.2026',
          'ending_day': '21.09.2026',
          'starting_lesson': 3,
          'ending_lesson': 4,
        };

    (Strakalari, FakeBak) app({bool uncertain = true}) {
      final client = FakeBak()
        ..executeUncertain = uncertain
        ..executeResult = false;
      final a = realApp(tmp, {
        'already_excused_file': '${tmp.path}/history.json',
      });
      a.bakalariClient = client;
      return (a, client);
    }

    test('uncertainSubmitIsRecordedNotFailed', () async {
      final (a, _) = app();
      expect(await a.sendExcuse(Map<String, Object?>.of(lesson()), 'x'),
          'unconfirmed');
      final pending =
          loadUnconfirmed('${tmp.path}/history.json', utf8);
      expect(pending, hasLength(1));
      expect(pending[0]['starting_lesson'], 3);
      expect(File('${tmp.path}/history.json').existsSync(), isFalse);
    });

    test('unconfirmedBlocksTheNextSend', () async {
      final (a, client) = app();
      await a.sendExcuse(Map<String, Object?>.of(lesson()), 'x');
      expect(await a.sendExcuse(Map<String, Object?>.of(lesson()), 'x'),
          'skipped');
      expect(client.executeCalls, 1);
    });

    test('certainFailureIsRetryable', () async {
      final (a, client) = app(uncertain: false);
      expect(await a.sendExcuse(Map<String, Object?>.of(lesson()), 'x'),
          'failed');
      expect(loadUnconfirmed('${tmp.path}/history.json', utf8), isEmpty);
      expect(await a.sendExcuse(Map<String, Object?>.of(lesson()), 'x'),
          'failed');
      expect(client.executeCalls, 2);
    });

    test('sidecarWriteFailureFallsBackToHistory', () async {
      final (a, _) = app();
      // A directory at the sidecar path: the sidecar write fails like a
      // full disk, while the history write next to it still works.
      Directory(unconfirmedPath('${tmp.path}/history.json'))
          .createSync();
      expect(await a.sendExcuse(Map<String, Object?>.of(lesson()), 'x'),
          'unconfirmed');
      final decoded = jsonDecode(
          await File('${tmp.path}/history.json').readAsString()) as List;
      expect(
          decoded.any((h) =>
              h is Map &&
              h['type'] == 'days and hours' &&
              h['starting_lesson'] == 3),
          isTrue);
      // The fallback entry covers the absence: no second submit.
      expect(await a.sendExcuse(Map<String, Object?>.of(lesson()), 'x'),
          'covered');
    });

    test('autoCountsANewUnconfirmedAsAFailure', () async {
      final (a, _) = app();
      final app2 = _PendingLessonApp(
          [Map<String, Object?>.of(lesson())],
          configFile: '${tmp.path}/config.json',
          configData: {
            'excuse_mode': 'auto',
            'excuse_delay_days': 0,
          });
      app2.bakalariClient =
          (a.bakalariClient as FakeBak)..executeResult = false;
      expect(await app2.excusePending(), 0);
      expect(app2.lastExcuseFailures, 1);
    });

    test('concurrentSyncWaitsForSendAndKeepsBoth', () async {
      // A-M1: a send blocked mid-submit plus a concurrent web sync. The
      // sync must wait for the send's history lock (not rewrite the
      // history mid-send), and afterwards the history holds both.
      final gate = Completer<void>();
      final (a, client) = app(uncertain: false);
      client.executeResult = true;
      client.executeGate = gate;
      client.sentExcusesResult = [
        {
          'type': 'pure days',
          'starting_day': '22.09.2026',
          'ending_day': '22.09.2026',
        },
      ];
      client.sentExcusesFrom = DateTime(2026, 8, 26);
      final sendFuture =
          a.sendExcuse(Map<String, Object?>.of(lesson()), 'x');
      // Wait until the send holds the lock inside the submit.
      final spinDeadline = DateTime.now().add(const Duration(seconds: 5));
      while (client.executeCalls == 0) {
        if (!DateTime.now().isBefore(spinDeadline)) {
          throw StateError('the send never reached the submit');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      var syncDone = false;
      final syncFuture =
          a.syncWebExcusesToHistory().whenComplete(() => syncDone = true);
      // The sync must still be waiting while the submit is gated.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(syncDone, isFalse);
      gate.complete();
      final results = await Future.wait([sendFuture, syncFuture]);
      expect(results[0], 'sent');
      expect(results[1], 1);
      expect(client.executeCalls, 1);
      final stored = (jsonDecode(
              await File('${tmp.path}/history.json').readAsString())
          as List)
          .whereType<Map<String, Object?>>()
          .toList();
      expect(
          stored.any((h) =>
              h['type'] == 'days and hours' &&
              h['starting_day'] == '21.09.2026'),
          isTrue);
      expect(
          stored.any((h) =>
              h['type'] == 'pure days' &&
              h['starting_day'] == '22.09.2026'),
          isTrue);
    });
  });

  group('outboxSettles', () {
    (Strakalari, FakeBak) syncApp(List<Map<String, Object?>> discovered) {
      final client = FakeBak()
        ..sentExcusesResult = discovered
        ..sentExcusesFrom = DateTime(2026, 8, 26);
      final a = realApp(tmp, {
        'already_excused_file': '${tmp.path}/history.json',
      });
      a.bakalariClient = client;
      return (a, client);
    }

    void seed(Strakalari a, Map<String, Object?> entry) {
      File(unconfirmedPath(a.alreadyExcusedFile))
          .writeAsStringSync(jsonEncode([entry]));
    }

    Map<String, Object?> lesson() => {
          'type': 'days and hours',
          'starting_day': '21.09.2026',
          'ending_day': '21.09.2026',
          'starting_lesson': 3,
          'ending_lesson': 4,
        };
    test('foundInOutboxIsConfirmed', () async {
      final (a, _) = syncApp([Map<String, Object?>.of(lesson())]);
      seed(a, unconfirmedEntry(lesson(), clock.now()));
      await a.syncWebExcusesToHistory();
      expect(a.lastOutboxSyncOk, isTrue);
      expect(loadUnconfirmed(a.alreadyExcusedFile, utf8), isEmpty);
    });

    test('absentFromOutboxAfterGraceIsReleased', () async {
      final logs = <String>[];
      final (a, _) = syncApp([]);
      a.onLog = logs.add;
      seed(
          a,
          unconfirmedEntry(lesson(),
              clock.now().subtract(const Duration(hours: 1))));
      await a.syncWebExcusesToHistory();
      expect(a.lastOutboxSyncOk, isTrue);
      expect(loadUnconfirmed(a.alreadyExcusedFile, utf8), isEmpty);
      expect(logs.any((m) => m.contains('NOT sent')), isTrue);
    });

    test('freshSubmitIsKept', () async {
      final (a, _) = syncApp([]);
      seed(a, unconfirmedEntry(lesson(), clock.now()));
      await a.syncWebExcusesToHistory();
      expect(loadUnconfirmed(a.alreadyExcusedFile, utf8), hasLength(1));
    });

    test('failedReadSettlesNothing', () async {
      final (a, _) = syncApp(const []);
      (a.bakalariClient as FakeBak).sentExcusesResult = null;
      seed(
          a,
          unconfirmedEntry(lesson(),
              clock.now().subtract(const Duration(hours: 1))));
      await a.syncWebExcusesToHistory();
      expect(a.lastOutboxSyncOk, isFalse);
      expect(loadUnconfirmed(a.alreadyExcusedFile, utf8), hasLength(1));
    });
  });

  group('syncPath', () {
    test('syncWithoutCredentialsIsNoop', () async {
      final hist = File('${tmp.path}/already_excused_lessons.json')
        ..writeAsStringSync('[]');
      final app = realApp(tmp, {'already_excused_file': hist.path});
      try {
        // No Bakaláři URL/username: the read fails, nothing is written.
        expect(await app.syncWebExcusesToHistory(), 0);
      } finally {
        app.close();
      }
      expect(hist.readAsStringSync().trim(), '[]');
    });

    test('syncTreatsNoneAsUnknown', () async {
      final app = realApp(tmp);
      final fake = FakeBak()..sentExcusesResult = null;
      app.bakalariClient = fake;
      expect(await app.syncWebExcusesToHistory(), 0);
    });
  });

  // -- strava_order_selected -----------------------------------------------------

  group('orderSelected', () {
    const day1 = '05.10.2099';
    const day2 = '06.10.2099';

    FakeStrava client(Map<String, bool> orderOk,
        {bool clickOnOrder = true}) {
      final c = FakeStrava()
        ..orderOk = orderOk
        ..clickOnOrder = clickOnOrder;
      c.foodDict.addAll({
        day1: {'a&1&0': 'A', 'a&2&0': 'B'},
        day2: {'b&1&0': 'C', 'b&2&0': 'D'},
      });
      c.orderedDict.addAll({day1: 'a&1&0', day2: 'b&1&0'});
      return c;
    }

    Strakalari app(FakeStrava c, [String mode = 'auto']) {
      final a = realApp(tmp, {'strava_order_mode': mode});
      a.stravaClient = c;
      return a;
    }

    test('failedDayWithoutClicksIsNotSuccess', () async {
      final c = client({'a&1&0': true}, clickOnOrder: false);
      final a = app(c);
      expect(await a.stravaOrderSelected({day1: 'a&1&0', day2: 'b&2&0'}),
          isFalse);
      // DAY1 already held the pick: web truth, reported even though
      // DAY2 failed.
      expect(a.lastOrderedDays, {day1});
    });

    test('failedRunReportsDaysSavedByImmediateFrontend', () async {
      final c = client({'a&2&0': true})..saveButton = false;
      final a = app(c);
      expect(await a.stravaOrderSelected({day1: 'a&2&0', day2: 'b&2&0'}),
          isFalse);
      expect(c.restoredDays, [day2]);
      expect(a.lastOrderedDays, {day1});
      expect(c.orderedDict[day1], 'a&2&0');
    });

    test('failedRunOnSaveButtonFrontendReportsNothingClicked', () async {
      final c = client({'a&2&0': true})..saveButton = true;
      final a = app(c);
      expect(await a.stravaOrderSelected({day1: 'a&2&0', day2: 'b&2&0'}),
          isFalse);
      expect(c.restoredDays, [day2]);
      expect(a.lastOrderedDays, isEmpty);
      expect(c.orderedDict[day1], 'a&1&0');
    });

    test('failedRunWithDefaultClientReportsNothingClicked', () async {
      final c = client({'a&2&0': true});
      final a = app(c);
      expect(await a.stravaOrderSelected({day1: 'a&2&0', day2: 'b&2&0'}),
          isFalse);
      expect(c.restoredDays, [day2]);
      expect(a.lastOrderedDays, isEmpty);
      expect(c.orderedDict[day1], 'a&1&0');
    });

    test('allFailedAfterClicksRestoresOriginals', () async {
      final c = client({});
      final a = app(c);
      expect(await a.stravaOrderSelected({day2: 'b&2&0'}), isFalse);
      expect(c.restoredDays, [day2]);
      expect(c.saved, isNull);
    });

    test('lostSelectionFailsAndRestores', () async {
      final c = client({'a&2&0': true, 'b&2&0': true})
        ..verifiedIds = {'a&2&0'};
      final a = app(c);
      expect(await a.stravaOrderSelected({day1: 'a&2&0', day2: 'b&2&0'}),
          isFalse);
      expect(c.restoredDays, [day2]);
      expect(c.saved, isNull);
    });

    test('mealNotOnMenuIsReportedButOthersPlaced', () async {
      final c = client({'a&2&0': true})..saveButton = true;
      final a = app(c);
      expect(await a.stravaOrderSelected({day1: 'a&2&0', day2: 'zzz&9&0'}),
          isFalse);
      expect(a.lastOrderedDays, {day1});
      expect(c.saved, ['a&2&0']);
    });

    test('fullSuccessSubmitsAndRecords', () async {
      final c = client({'a&2&0': true, 'b&2&0': true});
      final a = app(c);
      expect(await a.stravaOrderSelected({day1: 'a&2&0', day2: 'b&2&0'}),
          isTrue);
      expect(c.saved, ['a&2&0', 'b&2&0']);
      expect(c.orderedDict, {day1: 'a&2&0', day2: 'b&2&0'});
      expect(a.lastOrderedDays, {day1, day2});
    });
  });

  group('orderDryRunAndCutoff', () {
    test('menuMissReturnsFalse', () async {
      final c = FakeStrava();
      c.foodDict.addAll({
        '20.09.2030': {'m1': 'A'}
      });
      final a = realApp(tmp, {'strava_order_mode': 'dry_run'});
      a.stravaClient = c;
      expect(await a.stravaOrderSelected({'20.09.2030': 'nope&9&x'}),
          isFalse);
    });

    test('menuHitReturnsTrue', () async {
      final c = FakeStrava();
      c.foodDict.addAll({
        '20.09.2030': {'m1': 'A'}
      });
      final a = realApp(tmp, {'strava_order_mode': 'dry_run'});
      a.stravaClient = c;
      expect(
          await a.stravaOrderSelected({'20.09.2030': 'm1'}), isTrue);
    });

    test('orderingSkippedWithoutCutoff', () async {
      resolveLunchCutoffHook = (_) =>
          throw StateError('boom');
      final c = FakeStrava();
      c.foodDict.addAll({
        '20.09.2030': {'m1': 'A'}
      });
      final a = realApp(tmp);
      a.stravaClient = c;
      expect(
          await a.stravaOrderSelected({'20.09.2030': 'm1'}), isFalse);
      expect(c.orderCalls, 0);
    });

    test('partialOrderIsNotSuccess', () async {
      final c = FakeStrava()..orderOk = {'m1': true};
      c.foodDict.addAll({
        'd1': {'m1': 'A'},
        'd2': {'m2': 'B'},
      });
      final a = realApp(tmp, {'strava_order_mode': 'confirm'});
      a.stravaClient = c;
      expect(
          await a.stravaOrderSelected({'d1': 'm1', 'd2': 'm2'}), isFalse);
    });

    test('dryRunSelectsWithoutSubmitting', () async {
      final c = FakeStrava()..clickOnOrder = false;
      c.foodDict.addAll({
        '20.09.2030': {'m1': 'A'}
      });
      final a = realApp(tmp, {'strava_order_mode': 'dry_run'});
      a.stravaClient = c;
      expect(
          await a.stravaOrderSelected({'20.09.2030': 'm1'}), isTrue);
      expect(c.clicksMade, 0);
      expect(c.orderedDict, isEmpty);
      expect(c.orderCalls, 0);
    });

    test('successSubmits', () async {
      final c = FakeStrava()
        ..orderScript = [true]
        ..saveButton = true;
      c.foodDict.addAll({
        '01.01.2030': {'m1': 'A'},
        '02.01.2030': {'m2': 'B'},
      });
      final a = realApp(tmp, {'strava_order_mode': 'confirm'});
      a.stravaClient = c;
      expect(await a.stravaOrderSelected({'01.01.2030': 'm1'}), isTrue);
      expect(c.saved, ['m1']);
    });

    test('failedDayAbortsSubmit', () async {
      final c = FakeStrava()
        ..orderScript = [true, false]
        ..saveButton = true;
      c.foodDict.addAll({
        '01.01.2030': {'m1': 'A'},
        '02.01.2030': {'m2': 'B'},
      });
      final a = realApp(tmp, {'strava_order_mode': 'confirm'});
      a.stravaClient = c;
      expect(
          await a.stravaOrderSelected(
              {'01.01.2030': 'm1', '02.01.2030': 'm2'}),
          isFalse);
      expect(c.saved, isNull);
    });

    test('closedDayIsSkipped', () async {
      final c = FakeStrava()
        ..orderScript = [true]
        ..saveButton = true;
      c.foodDict.addAll({
        '01.01.2030': {'m1': 'A'},
        '01.01.2020': {'m0': 'X'},
      });
      final a = realApp(tmp, {'strava_order_mode': 'confirm'});
      a.stravaClient = c;
      expect(await a.stravaOrderSelected({'01.01.2020': 'm0'}), isFalse);
      expect(c.saved, isNull);
    });
  });

  group('lowBalanceOrdering', () {
    Map<String, Map<String, String>> menu(
        String day1, String day2, String day3) {
      return {
        day1: {'a&1&0': 'Guláš', 'a&2&0': 'Kuře', 'a&-1&0': 'x'},
        day2: {'b&1&0': 'Řízek', 'b&2&0': 'Rizoto', 'b&-1&0': 'x'},
        day3: {'c&1&0': 'Polévka', 'c&2&0': 'Těstoviny', 'c&-1&0': 'x'},
      };
    }

    List<String> futureDays(int count) {
      final start = dateOnly(clock.now()).add(const Duration(days: 30));
      return [
        for (var i = 0; i < count; i++) dmy(start.add(Duration(days: i)))
      ];
    }

    Strakalari app(BrokeStrava c) {
      final a = realApp(tmp, {'strava_order_mode': 'auto'});
      a.stravaClient = c;
      return a;
    }

    test('orderingStopsAtLowBalance', () async {
      final days = futureDays(3);
      final c = BrokeStrava(menu(days[0], days[1], days[2]));
      final a = app(c);
      expect(
          await a.stravaOrderSelected({
            days[0]: 'a&1&0',
            days[1]: 'b&1&0',
            days[2]: 'c&1&0',
          }),
          isFalse);
      expect(a.lastOrderLowBalance, isTrue);
      expect(a.lastUnfundedDays, [days[1], days[2]]);
      expect(a.lastOrderedDays, {days[0]});
    });

    test('cancellationsGoFirstAndStillWorkWhenBroke', () async {
      final days = futureDays(2);
      final c = BrokeStrava(menu(days[0], days[1], days[0]));
      final a = app(c);
      await a.stravaOrderSelected({days[0]: 'a&1&0', days[1]: 'b&-1&0'});
      expect(c.ordered.first, 'b&-1&0');
    });
  });

  group('dryRunExcuse', () {
    Map<String, Object?> excuse() => {
          'type': 'days and hours',
          'starting_day': '18.09.2026',
          'ending_day': '18.09.2026',
          'starting_lesson': 6,
          'ending_lesson': 6,
        };

    test('excuseSingleDryRunFillsOnly', () async {
      final fake = FakeBak();
      final app = realApp(tmp, {'excuse_mode': 'dry_run'});
      app.bakalariClient = fake;
      expect(
          await app.excuseSingle(
              Map<String, Object?>.of(excuse()), 'text'),
          isTrue);
      expect(fake.fillCalls, 1);
      expect(fake.executeCalls, 0);
      expect(File('${tmp.path}/already_excused_lessons.json').existsSync(),
          isFalse);
    });

    test('excuseAbsenceDryRunSendsNothing', () async {
      final fake = FakeBak();
      final app = _PendingLessonApp(
          [excuse()],
          configFile: '${tmp.path}/config.json',
          configData: {
            'excuse_mode': 'dry_run',
            'excuse_delay_days': 2,
          });
      app.bakalariClient = fake;
      expect(await app.excusePending(), 0);
      expect(fake.executeCalls, 0);
      expect(File('${tmp.path}/already_excused_lessons.json').existsSync(),
          isFalse);
    });

    test('excuseDryRunFillsWithoutSubmitting', () async {
      final fake = FakeBak();
      final app = realApp(tmp, {'excuse_mode': 'dry_run'});
      app.bakalariClient = fake;
      expect(
          await app.excuseSingle(
              {
                'type': 'pure days',
                'starting_day': '01.09.2026',
                'ending_day': '01.09.2026',
              },
              'text'),
          isTrue);
      expect(fake.fillCalls, 1);
      expect(fake.executeCalls, 0);
    });
  });

  group('autoExcuse', () {
    Map<String, Object?> day(String d, int first, int last,
            [String kind = 'days and hours']) =>
        {
          'type': kind,
          'starting_day': d,
          'ending_day': d,
          'starting_lesson': first,
          'ending_lesson': last,
        };

    (Strakalari, FakeBak) app() {
      final client = FakeBak();
      final a = realApp(tmp, {
        'already_excused_file': '${tmp.path}/history.json',
      });
      a.bakalariClient = client;
      return (a, client);
    }

    test('excuseOutcomesAreRecorded', () async {
      final (a, client) = app();
      final excuse = day('21.09.2026', 3, 3);
      expect(await a.sendExcuse(Map<String, Object?>.of(excuse), 'x',
          source: 'auto'), 'sent');
      expect(
          await a.sendExcuse(Map<String, Object?>.of(excuse), 'x'),
          'covered');
      client.executeResult = false;
      expect(await a.sendExcuse(day('22.09.2026', 1, 1), 'x'),
          'failed');
      final items = audit.recent();
      expect(items.map((i) => i['outcome']).toList(),
          ['failed', 'covered', 'sent']);
      expect(items.last['source'], 'auto');
      // Only dates/lessons are stored — never the excuse wording.
      expect(items.every((i) => 'x' != i['summary']), isTrue);
    });

    test('autoExcuseCountsFailures', () async {
      final (_, client) = app();
      client.executeResult = false;
      client.timetableData = {
        dmy(clock.now().subtract(const Duration(days: 1))): [
          {
            'teacher': 'T',
            'subject': 'M',
            'time': '1 (8:00)',
            'absenceType': 'absent',
          },
        ]
      };
      final app2 = _TextApp(
          configFile: '${tmp.path}/config.json',
          configData: {'excuse_mode': 'auto', 'excuse_delay_days': 0});
      app2.bakalariClient = client;
      expect(await app2.excusePending(), 0);
      expect(app2.lastExcuseFailures, 1);
    });

    test('coveredExcuseIsNotResent', () async {
      final (a, client) = app();
      File('${tmp.path}/history.json').writeAsStringSync(jsonEncode([
        {
          'type': 'pure days',
          'starting_day': '07.09.2026',
          'ending_day': '11.09.2026',
        }
      ]));
      expect(
          await a.excuseSingle({
            'type': 'pure days',
            'starting_day': '08.09.2026',
            'ending_day': '08.09.2026',
          }),
          isTrue);
      expect(client.executeCalls, 0);
    });
  });

  group('concurrentSends', () {
    test('concurrentSendsSubmitOnce', () async {
      final client = FakeBak()
        ..executeDelay = const Duration(milliseconds: 200);
      final a = realApp(tmp, {
        'excuse_mode': 'auto',
        'already_excused_file': '${tmp.path}/history.json',
      });
      a.bakalariClient = client;
      final excuse = {
        'type': 'days and hours',
        'starting_day': '21.09.2026',
        'ending_day': '21.09.2026',
        'starting_lesson': 3,
        'ending_lesson': 3,
      };
      final results = await Future.wait([
        a.sendExcuse(Map<String, Object?>.of(excuse), 'x'),
        a.sendExcuse(Map<String, Object?>.of(excuse), 'x'),
      ]);
      expect(results..sort(), ['covered', 'sent']);
      expect(client.executeCalls, 1);
    });

    test('automationFiltersExampleFallback', () async {
      final histExample = File('${tmp.path}/hist.example.json')
        ..writeAsStringSync(jsonEncode([
          {
            'type': 'pure days',
            'starting_day': 'VAS_DEMO_DEN',
            'ending_day': 'VAS_DEMO_DEN'
          },
          {
            'type': 'pure days',
            'starting_day': '01.09.2026',
            'ending_day': '02.09.2026'
          },
          'junk',
          {'no': 'days'},
        ]));
      expect(histExample.existsSync(), isTrue);
      final a = realApp(tmp, {
        'already_excused_file': '${tmp.path}/hist.json',
      });
      final (history, _) = a.loadHistory();
      expect(history, isNotEmpty);
      for (final item in history) {
        expect(item, isA<Map<String, Object?>>());
        expect('$item', isNot(contains('VAS_DEMO')));
      }
      expect(history.any((h) => h['starting_day'] == '01.09.2026'),
          isTrue);
    });
  });

  group('configBehavior', () {
    test('plaintextOverrideEncrypts', () async {
      final app = realApp(
          tmp, {'bakalari_password': 'tajneheslo123'});
      try {
        final stored = app.configManager.data['bakalari_password'];
        expect(app.configManager.data['bakalari_password_encrypted'],
            isTrue);
        expect(decryptStrict('$stored'), 'tajneheslo123');
      } finally {
        app.close();
      }
    });

    test('integerStravaIdHandling', () {
      final app = realApp(tmp,
          {'strava_canteen_id': 9876, 'use_strava': false});
      try {
        expect(app.stravaId, '9876');
        expect(app.stravaId, isA<String>());
      } finally {
        app.close();
      }
    });

    test('partialConfigWithoutUseStravaStaysEnabled', () {
      final app = Strakalari(
          configFile: '${tmp.path}/config.json',
          configData: {'bakalari_url': 'https://example.test'});
      try {
        expect(app.stravaEnable, isTrue);
        expect(app.stravaClient!.stravaEnable, isTrue);
      } finally {
        app.close();
      }
    });
  });

  group('dataSafety', () {
    test('missingFileReturnsEmpty', () {
      expect(quarantineCorruptFile('${tmp.path}/nope.json'), '');
    });

    test('corruptFilePreserved', () {
      final target = File('${tmp.path}/data.json')
        ..writeAsStringSync('{broken');
      final backup = quarantineCorruptFile(target.path);
      expect(backup, isNotEmpty);
      expect(File(backup).existsSync(), isTrue);
      expect(target.existsSync(), isFalse);
      expect(File(backup).readAsStringSync(), '{broken');
    });

    test('corruptHistoryBackedUp', () {
      final bad = File('${tmp.path}/already_excused_lessons.json')
        ..writeAsStringSync('{oops');
      final app = realApp(tmp, {'already_excused_file': bad.path});
      final (history, path) = app.loadHistory();
      expect(history, isEmpty);
      expect(path, bad.path);
      expect(bad.existsSync(), isFalse);
      final backups = Directory(tmp.path)
          .listSync()
          .where((e) => e.path.contains('.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
      expect((backups.first as File).readAsStringSync(), '{oops');
    });

    test('corruptBlacklistDisablesAutoOrder', () {
      final bad = File('${tmp.path}/strava_blacklist.json')
        ..writeAsStringSync('["unclosed');
      final logs = <String>[];
      final client = StravaClient({
        'strava_order_mode': 'auto',
        'use_strava': true,
        'strava_blacklist': bad.path,
      }, logger: logs.add);
      try {
        expect(client.blacklistBroken, isTrue);
        expect(logs.any((m) => m.toLowerCase().contains('blacklist')),
            isTrue);
        expect(bad.existsSync(), isFalse);
        expect(
            Directory(tmp.path)
                .listSync()
                .where((e) => e.path.contains('.corrupt-'))
                .isNotEmpty,
            isTrue);
      } finally {
        client.close();
      }
    });

    test('writeLogLinesAreTimestamped', () {
      final app = realApp(tmp, {'log_file': '${tmp.path}/log.txt'});
      app.writeLog('hello');
      final text = File('${tmp.path}/log.txt').readAsStringSync();
      expect(
          text,
          matches(RegExp(
              r'^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] hello\n')));
    });
  });
}
