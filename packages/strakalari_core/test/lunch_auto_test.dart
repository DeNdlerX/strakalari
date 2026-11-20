// Automatic lunch picks (auto mode): due gating, blacklist filter, Gemini
// merge, gap filling, user-choice preservation.
//
// Port of tests/test_lunch_auto.py (all cases), tests/test_lunch_auto_user_choice.py
// (TestAutoFillsGapsOnly + handled-days cases) and tests/test_lunch_same_pick.py
// (UI-state cases, not portable yet).
//
// Cases NOT ported here (their subjects live in other modules):
// - TestPlannedSkipLunchChoice (normalize_planned_entry, planned_lunch_days)
//   -> planned_skips port (planning/planned_skips.dart).
// - test_restart_does_not_resurrect_meal_on_planned_day,
//   test_send_only_transmits_pending_picks -> AppState/automation ports
//   (phase 4/5).
// - test_lunch_same_pick.py (5 tests: order_lunch pending/lunch_is_change/
//   _day_status/submit_orders/reload_cache) -> lunches controller + Lunches
//   view (phase 5, AppState port).
import 'dart:convert';

import 'package:test/test.dart';

import 'package:strakalari_core/src/lunches/gemini.dart';
import 'package:strakalari_core/src/lunches/lunch_auto.dart';

Map<String, Map<String, String>> menu() => {
      '21.09.2026': {'a&1&x': 'Kuřecí steak', 'a&2&x': 'Vepřová sekaná'},
      '22.09.2026': {'b&1&x': 'Smažený sýr', 'b&-1&x': 'Odhlásit'},
    };

DateTime day(int year, int month, int d) => DateTime(year, month, d);

String czDay(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

// Dynamic future days (mirrors the FUTURE-based Python user-choice tests):
// auto mode never touches the past, and "today" is the real clock here.
DateTime get futureBase {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day).add(const Duration(days: 30));
}

Map<String, Map<String, String>> futureMenu() {
  final d1 = futureBase;
  final d2 = d1.add(const Duration(days: 1));
  final d3 = d2.add(const Duration(days: 1));
  return {
    czDay(d1): {'a&1&0': 'Guláš', 'a&2&0': 'Kuře', 'a&-1&0': 'x'},
    czDay(d2): {'b&1&0': 'Řízek', 'b&2&0': 'Rizoto', 'b&-1&0': 'x'},
    czDay(d3): {'c&1&0': 'Polévka', 'c&2&0': 'Těstoviny', 'c&-1&0': 'x'},
  };
}

void main() {
  group('gemini due', () {
    test('disabled never runs', () {
      expect(
        shouldRunGeminiAuto(false, '', 2, day(2026, 9, 21)),
        isFalse,
      );
    });

    test('never ran is due', () {
      expect(
        shouldRunGeminiAuto(true, '', 2, day(2026, 9, 21)),
        isTrue,
      );
    });

    test('interval gating', () {
      expect(
        shouldRunGeminiAuto(true, '2026-09-20', 2, day(2026, 9, 21)),
        isFalse,
      );
      expect(
        shouldRunGeminiAuto(true, '2026-09-19', 2, day(2026, 9, 21)),
        isTrue,
      );
      expect(
        shouldRunGeminiAuto(true, '2026-09-21', 2, day(2026, 9, 21)),
        isFalse,
      );
    });

    test('interval clamped', () {
      expect(clampGeminiInterval(0), 1);
      expect(clampGeminiInterval(99), 30);
      expect(clampGeminiInterval('x'), 2);
    });
  });

  group('filter picks', () {
    test('first non-banned wins', () {
      final picks = filterPicks(
        menu(),
        blacklist: ['vepř'],
        today: day(2026, 9, 20),
      );
      expect(picks['21.09.2026'], 'a&1&x');
    });

    test('past and cancelled skipped', () {
      final picks = filterPicks(
        menu(),
        blacklist: [],
        cancelledDays: ['22.09.2026'],
        today: day(2026, 9, 21),
      );
      expect(picks.containsKey('22.09.2026'), isFalse);
      final picks2 = filterPicks(menu(), blacklist: [], today: day(2026, 9, 23));
      expect(picks2, isEmpty);
    });

    test('closed day skipped', () {
      final picks = filterPicks(
        menu(),
        blacklist: [],
        isOpen: (_) => false,
        today: day(2026, 9, 20),
      );
      expect(picks, isEmpty);
    });

    test('uses canonical keys', () {
      final picks = filterPicks(
        {
          '1.10.2026': {'g&1&x': 'Kuřecí'}
        },
        blacklist: [],
        today: day(2026, 9, 24),
      );
      expect(picks.keys.toList(), ['01.10.2026']);
    });
  });

  group('merge', () {
    test('banned gemini pick replaced by filter', () {
      final merged = mergeGeminiWithFilter(
        {'21.09.2026': 'a&2&x'},
        menu(),
        blacklist: ['vepř'],
        today: day(2026, 9, 20),
      );
      expect(merged['21.09.2026'], 'a&1&x');
    });

    test('gap filled', () {
      final merged = mergeGeminiWithFilter(
        {},
        menu(),
        blacklist: [],
        today: day(2026, 9, 20),
      );
      expect(merged['21.09.2026'], 'a&1&x');
      expect(merged['22.09.2026'], 'b&1&x');
    });

    test('spelling variants merge into one key', () {
      final food = {
        '01.10.2026': {'g&1&x': 'Kuřecí', 'g&2&x': 'Vepřové'}
      };
      final merged = mergeGeminiWithFilter(
        {'1.10.2026': 'g&1&x'},
        food,
        blacklist: [],
        today: day(2026, 9, 24),
      );
      expect(merged.keys.toList(), ['01.10.2026']);
      expect(merged['01.10.2026'], 'g&1&x');
    });
  });

  group('auto fills gaps only', () {
    test('existing order is never switched', () async {
      final food = futureMenu();
      final day1 = food.keys.first;
      final day2 = food.keys.elementAt(1);
      final (orders, _) = await planAutoOrders(
        food,
        {},
        ordered: {day1: 'a&2&0'},
        isOpen: (_) => true,
      );
      expect(orders.containsKey(day1), isFalse); // the user's meal 2 stays
      expect(orders[day2], 'b&1&0');
    });

    test('handled day is not reordered after web cancel', () async {
      final food = futureMenu();
      final day1 = food.keys.first;
      final day2 = food.keys.elementAt(1);
      final day3 = food.keys.elementAt(2);
      final (orders, _) = await planAutoOrders(
        food,
        {},
        ordered: {},
        handled: [day2],
        isOpen: (_) => true,
      );
      expect(orders.containsKey(day2), isFalse);
      expect(orders.containsKey(day1), isTrue);
      expect(orders.containsKey(day3), isTrue);
    });

    test('planned day off gets its lunch cancelled', () async {
      final food = futureMenu();
      final day3 = food.keys.elementAt(2);
      final (orders, _) = await planAutoOrders(
        food,
        {},
        ordered: {day3: 'c&1&0'},
        cancelledDays: {day3},
        isOpen: (_) => true,
      );
      expect(orders[day3], 'c&-1&0');
    });

    test('planned day off without order gets nothing', () async {
      final food = futureMenu();
      final day3 = food.keys.elementAt(2);
      final (orders, _) = await planAutoOrders(
        food,
        {},
        ordered: {},
        cancelledDays: {day3},
        isOpen: (_) => true,
      );
      expect(orders.containsKey(day3), isFalse);
    });

    test('handled days remember orders but not failures', () {
      final food = futureMenu();
      final day1 = food.keys.first;
      final day2 = food.keys.elementAt(1);
      final days = updateHandledDays([], {day1: 'a&2&0'}, [day2]);
      expect(days.toSet(), {day1, day2});
      final now = DateTime.now();
      final old = now.subtract(const Duration(days: 30));
      expect(
        updateHandledDays([czDay(old)], {}, []),
        isNot(contains(czDay(old))),
      );
    });

    test('gemini answer is used when due', () async {
      final food = futureMenu();
      final day1 = food.keys.first;
      Future<GeminiHttpResponse> fake(
        Uri url, {
        required Map<String, String> headers,
        List<int>? body,
        required Duration timeout,
      }) async {
        final text =
            'Rybka je super. ```json {"$day1": "a&1&0"}```';
        final payload =
            '{"candidates": [{"content": {"parts": [{"text": ${jsonEncode(text)}}]}}]}';
        return GeminiHttpResponse(200, payload.codeUnits);
      }

      final (orders, usedGemini) = await planAutoOrders(
        food,
        {
          'gemini_auto_enabled': true,
          'gemini_last_run': '',
          'gemini_interval_days': 2,
          'gemini_api_key': 'KEY',
        },
        isOpen: (_) => true,
        geminiTransport: fake,
      );
      expect(usedGemini, isTrue);
      expect(orders[day1], 'a&1&0');
    });
  });

  group('autoCancelLunches (F3)', () {
    test('stravaAutoCancelEnabledDefaultsTrue', () {
      expect(stravaAutoCancelEnabled({}), isTrue);
      expect(stravaAutoCancelEnabled({'strava_auto_cancel_lunches': true}),
          isTrue);
      expect(stravaAutoCancelEnabled({'strava_auto_cancel_lunches': false}),
          isFalse);
    });

    test('freeLunchDaysUsesUnclippedCalendarAndRespectsForcedSchoolDays', () {
      final dFree = futureBase.add(const Duration(days: 5));
      final dForced = futureBase.add(const Duration(days: 6));
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final cfg = <String, Object?>{
        // Far past semester closure would clip if clip: true were used.
        'semester_1_close': '2020-01-31',
        'semester_2_close': '2020-06-30',
        'user_free_days': [iso(dFree), iso(dForced)],
        'forced_school_days': [iso(dForced)],
      };
      final days = freeLunchDays(cfg);
      expect(days, contains(czDay(dFree)));
      expect(days, isNot(contains(czDay(dForced))));
    });

    test('planAutoCancelsCoversFreeAndPlannedDaysAndRespectsOverrides', () {
      final d1 = futureBase;
      final d2 = d1.add(const Duration(days: 1));
      final d3 = d2.add(const Duration(days: 1));
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final food = futureMenu();
      final cfg = <String, Object?>{
        'user_free_days': [iso(d1)],
      };
      final ordered = {
        czDay(d1): 'a&1&0',
        czDay(d2): 'b&1&0',
        czDay(d3): 'c&-1&0', // already cancelled
      };

      // Free day (d1) + planned day (d2) are cancelled; d3 already cancelled.
      final cancels = planAutoCancels(
        food,
        cfg,
        cancelledDays: {czDay(d2)},
        ordered: ordered,
        isOpen: (_) => true,
      );
      expect(cancels, {
        czDay(d1): 'a&-1&0',
        czDay(d2): 'b&-1&0',
      });

      // Partial school days not in cancelledDays/freeDays are never cancelled.
      final noneWhenNormalDay = planAutoCancels(
        food,
        const <String, Object?>{},
        cancelledDays: const <String>{},
        ordered: {czDay(d2): 'b&1&0'},
        isOpen: (_) => true,
      );
      expect(noneWhenNormalDay, isEmpty);

      // Manual override in cancelHandled suppresses re-cancelling d1.
      final withOverride = planAutoCancels(
        food,
        cfg,
        cancelledDays: {czDay(d2)},
        ordered: ordered,
        cancelHandled: {czDay(d1)},
        isOpen: (_) => true,
      );
      expect(withOverride, {czDay(d2): 'b&-1&0'});

      // Disabled toggle or closed cutoff cancels nothing.
      expect(
        planAutoCancels(
          food,
          {...cfg, 'strava_auto_cancel_lunches': false},
          cancelledDays: {czDay(d2)},
          ordered: ordered,
          isOpen: (_) => true,
        ),
        isEmpty,
      );
      expect(
        planAutoCancels(
          food,
          cfg,
          cancelledDays: {czDay(d2)},
          ordered: ordered,
          isOpen: (_) => false,
        ),
        isEmpty,
      );
    });

    test('planAutoOrdersSkipsFreeDaysAndRespectsCancelFlagAndOverrides',
        () async {
      final d1 = futureBase;
      final d2 = d1.add(const Duration(days: 1));
      final d3 = d2.add(const Duration(days: 1));
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      final food = futureMenu();
      final cfg = <String, Object?>{
        'user_free_days': [iso(d1), iso(d2)],
      };

      // d1 is already ordered (gets cancelled), d2 is unordered free day (stays
      // empty!), d3 is normal unordered day (gets ordered).
      final (orders, _) = await planAutoOrders(
        food,
        cfg,
        ordered: {czDay(d1): 'a&1&0'},
        isOpen: (_) => true,
      );
      expect(orders[czDay(d1)], 'a&-1&0');
      expect(orders.containsKey(czDay(d2)), isFalse);
      expect(orders[czDay(d3)], 'c&1&0');

      // When user manually overrode d1, auto mode neither cancels nor replaces d1.
      final (keptOrders, _) = await planAutoOrders(
        food,
        cfg,
        ordered: {czDay(d1): 'a&1&0'},
        cancelHandled: {czDay(d1)},
        isOpen: (_) => true,
      );
      expect(keptOrders.containsKey(czDay(d1)), isFalse);
      expect(keptOrders[czDay(d3)], 'c&1&0');

      // When auto-cancel is disabled, d1 stays ordered (neither cancelled nor replaced).
      final (disabledOrders, _) = await planAutoOrders(
        food,
        {...cfg, 'strava_auto_cancel_lunches': false},
        ordered: {czDay(d1): 'a&1&0'},
        isOpen: (_) => true,
      );
      expect(disabledOrders.containsKey(czDay(d1)), isFalse);
      expect(disabledOrders[czDay(d3)], 'c&1&0');
    });

    test('updateCancelHandledDaysDedupsSortsAndPrunesPastWeek', () {
      final today = DateTime(2026, 11, 20);
      final kept = updateCancelHandledDays(
        ['12.11.2026', '13.11.2026', '25.11.2026'],
        ['25.11.2026', '22.11.2026'],
        today,
      );
      expect(kept, ['13.11.2026', '22.11.2026', '25.11.2026']);
    });
  });
}
