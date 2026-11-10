import 'package:app/l10n/strings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/planner/plan_reserve.dart';

void main() {
  group('planner_reserve', () {
    test('reserve lowers plan limit, not school limit', () {
      final state = PlanSubject(
        name: 'M',
        currentPct: 10.0,
        limitPct: 25.0,
        safeHoursLeft: 80,
        planLimitPct: planLimit(25.0, 10.0),
        planSafeHoursLeft: 70,
      );
      expect(state.limitPct, 25.0);
      expect(state.planLimitPct, 15.0);
      expect(state.planSafeHoursLeft! <= state.safeHoursLeft, isTrue);
    });

    test('default example 25 minus 10 is 15', () {
      final states = applyReserve(
        [
          const PlanSubject(
              name: 'M',
              currentPct: 16.0,
              limitPct: 25.0,
              safeHoursLeft: 10),
        ],
        10.0,
      );
      expect(states.single.effectivePlanLimit, 15.0);
      // School status still uses the real limit: 16 % is not critical.
      expect(states.single.status, isNot('critical'));
      // ... but planning already treats it as over the safe limit.
      expect(states.single.planStatus, 'critical');
    });

    test('zero reserve keeps old behavior', () {
      final states = applyReserve(
        [
          const PlanSubject(
              name: 'M',
              currentPct: 16.0,
              limitPct: 25.0,
              safeHoursLeft: 10),
        ],
        0.0,
      );
      expect(states.single.effectivePlanLimit,
          states.single.limitPct);
      expect(states.single.planStatus, states.single.status);
      expect(states.single.effectivePlanSafe,
          states.single.safeHoursLeft);
    });

    test('handbuilt states fall back to school values', () {
      const legacy = PlanSubject(
          name: 'M',
          currentPct: 26.0,
          limitPct: 25.0,
          safeHoursLeft: 0);
      expect(legacy.effectivePlanLimit, 25.0);
      expect(legacy.effectivePlanSafe, 0);
      expect(legacy.planStatus, 'critical');
    });

    test('reserve validation', () {
      expect(validateReserve(10.0), isNull);
      expect(validateReserve(-1), 'absence_plan_reserve_pct');
      expect(validateReserve('lots'), 'absence_plan_reserve_pct');
    });

    test('clampReserve clamps and falls back', () {
      expect(clampReserve(-1), 0.0);
      expect(clampReserve(10.0), 10.0);
      expect(clampReserve('lots'), 10.0);
      expect(clampReserve(null), 10.0);
    });

    test('signature is not duplicated', () {
      final options = templateOptions({
        'long_absence_excuses': ['Omluvte absenci.\nJan Novák'],
        'short_absence_excuses': [],
        'late_income_excuses': [],
        'your_signature': 'jan novák',
      }, signature: 'jan novák');
      final texts = [for (final e in options) e.value];
      expect(
          texts.first.toLowerCase().split('jan novák').length - 1, 1);
    });

    test('template helpers accept both shapes', () {
      expect(templateTextOf({'name': 'A', 'text': 'T'}), 'T');
      expect(templateName({'name': '  A  B ', 'text': 'T'}), 'A B');
      expect(templateTextOf('plain'), 'plain');
      expect(templateName('plain'), '');
    });

    test('options carry names and skip blank', () {
      final options = templateOptions({
        'short_absence_excuses': [
          {'name': 'Rodina', 'text': 'Omluvte, rodina.'},
          'Omluvte, bez jména.',
          {'name': 'Prázdná', 'text': '  '},
        ],
        'long_absence_excuses': [],
        'late_income_excuses': [],
        'left_soon_excuses': [],
      }, kind: 'short');
      expect(options.map((e) => (e.key, e.value)).toList(), [
        ('Rodina', 'Omluvte, rodina.'),
        ('', 'Omluvte, bez jména.'),
      ]);
      final labels = templateLabels(options);
      expect(labels[0].key, '0');
      expect(labels[0].value, 'Rodina');
      expect(labels[1].key, '1');
      expect(labels[1].value, endsWith('2'));
    });

    test('days text plurals', () {
      Strings.lang = 'cs';
      expect(daysText(1), contains('1'));
      expect(daysText(3), contains('3'));
      expect(daysText(5), contains('5'));
      Strings.lang = 'en';
      expect(daysText(1), contains('1'));
    });

    test('runs label', () {
      expect(runsLabel([1, 2, 3, 4, 5], {1, 2, 3, 5}), '1.–3., 5.');
      expect(runsLabel([1, 2, 3], {2}), '2.');
    });

    test('entry label', () {
      expect(
          entryLabel({'start_date': '2026-09-15', 'end_date': '2026-09-15'}),
          contains('15.09.2026'));
      expect(
          entryLabel({
            'start_date': '2026-09-15',
            'end_date': '2026-09-17',
            'start_period': 2,
            'end_period': 3
          }),
          contains('2.–3.'));
      expect(normalizePlannedEntry({'start_date': 'x'}), isNull);
      expect(
          normalizePlannedEntry(
                  {'start_date': '2026-09-17', 'end_date': '2026-09-15'}),
          isNull);
    });
  });
}
