import 'package:test/test.dart';

import 'package:strakalari_core/src/planning/grades.dart'
    as gr;

Map<String, Object?> mark(String grade,
    {Object? weight, String? date, String? id}) {
  final m = <String, Object?>{'Grade': grade};
  if (weight != null) m['Weight'] = weight;
  if (date != null) m['Date'] = date;
  if (id != null) m['Id'] = id;
  return m;
}

gr.SubjectSummary rows(List<Map<String, Object?>> marks,
    {String scale = 'auto'}) {
  return gr.summarize('M', marks, scalePref: scale);
}

void main() {
  group('parseRaw', () {
    test('reads each mark on its own', () {
      final cases = <String, (String, double)>{
        '1': ('small', 1.0),
        '1-': ('grade', 1.5),
        '5-': ('grade', 5.0),
        '2+': ('grade', 2.0),
        '85': ('percent', 85.0),
        '85 %': ('percent', 85.0),
        '72,5%': ('percent', 72.5),
        '17/20': ('percent', 85.0),
        '0': ('percent', 0.0),
      };
      for (final e in cases.entries) {
        final raw = gr.parseRaw(e.key);
        expect(raw, isNotNull, reason: e.key);
        expect(raw!.kind, e.value.$1, reason: e.key);
        expect(raw.value, closeTo(e.value.$2, 1e-9), reason: e.key);
      }
    });

    test('non-counting marks', () {
      for (final text in ['N', '?', '', 'X', 'A', null, '3/0']) {
        expect(gr.parseRaw(text), isNull, reason: '$text');
      }
    });

    test('points field used when mark text is not a number', () {
      expect(gr.parseRaw('', '9/10')!.value, closeTo(90.0, 1e-9));
    });

    test('minus grades count', () {
      expect(gr.parseRaw('1-')!.value, closeTo(1.5, 1e-9));
      expect(gr.parseRaw('2+')!.value, closeTo(2.0, 1e-9));
      expect(gr.parseRaw('N'), isNull);
      // "5-" can not be worse than the worst grade.
      expect(gr.parseRaw('5-')!.value, closeTo(5.0, 1e-9));
      expect(
        gr.summarize('M', [mark('1'), mark('2-')]).average,
        closeTo(1.75, 1e-9),
      );
    });
  });

  group('validMarkText', () {
    test('rejects out of range', () {
      expect(gr.validMarkText('100'), isTrue);
      expect(gr.validMarkText('101'), isFalse);
      expect(gr.validMarkText('120 %'), isFalse);
      expect(gr.validMarkText('21/20'), isFalse);
      expect(gr.validMarkText('abc'), isFalse);
    });
  });

  group('parseWeight', () {
    test('weights', () {
      expect(gr.parseWeight(null), 1.0);
      expect(gr.parseWeight('2,5'), 2.5);
      expect(gr.parseWeight(-3), 1.0);
      expect(gr.parseWeight(0), 0.0);
    });
  });

  group('scales', () {
    test('detect scale', () {
      expect(
        gr.detectScale([mark('53'), mark('100'), mark('?')]),
        'percent',
      );
      expect(gr.detectScale([mark('1'), mark('2-')]), 'grade');
      // Mostly grades with one percentage stays a 1–5 subject.
      expect(
        gr.detectScale([mark('1'), mark('2'), mark('85')]),
        'grade',
      );
      // No evidence -> the school-wide fallback.
      expect(gr.detectScale([mark('N')], 'percent'), 'percent');
    });

    test('conversion uses bands', () {
      expect(gr.pctToGrade(90.1), 1);
      // A boundary is the worse grade's top.
      expect(gr.pctToGrade(90), 2);
      expect(gr.pctToGrade(29), 5);
      expect(gr.pctToGrade(80.5, [95.0, 80.0, 60.0, 40.0]), 2);
    });

    test('gekom table boundaries', () {
      const gekom = [87.0, 72.0, 55.0, 40.0];
      expect(gr.pctToGrade(100, gekom), 1);
      expect(gr.pctToGrade(87.1, gekom), 1);
      // "87 is the first 2".
      expect(gr.pctToGrade(87, gekom), 2);
      expect(gr.pctToGrade(72, gekom), 3);
      expect(gr.pctToGrade(55, gekom), 4);
      expect(gr.pctToGrade(40.5, gekom), 4);
      expect(gr.pctToGrade(40, gekom), 5);
      expect(gr.pctToGrade(0, gekom), 5);
      expect(gr.gradeToPct(1), closeTo(95.0, 1e-9));
      expect(gr.gradeToPct(2), closeTo(82.5, 1e-9));
      expect(gr.gradeToPct(1.5), closeTo((95 + 82.5) / 2, 1e-9));
    });

    test('round grade halves go down a grade', () {
      expect(gr.roundGrade(1.49), 1);
      expect(gr.roundGrade(1.5), 2);
    });

    test('bands validation', () {
      expect(gr.bandsValid([90, 75, 50, 30]), isTrue);
      expect(gr.bandsValid([90, 90, 50, 30]), isFalse);
      expect(gr.bandsValid([90, 75, 50]), isFalse);
      expect(gr.bandsValid(['a', 75, 50, 30]), isFalse);
      expect(gr.bandsValid('90,75,50,30'), isFalse);
      expect(gr.normalizeBands(null), gr.defaultBands);
    });
  });

  group('summarize', () {
    test('weighted average trend and new', () {
      final s = gr.summarize(
        'M',
        [
          mark('1', weight: 10, date: '05.09.2026'),
          mark('5', weight: 1, date: '10.09.2026'),
        ],
        today: DateTime(2026, 9, 13),
      );
      expect(s.scale, 'grade');
      expect(s.average, closeTo(15 / 11, 1e-9));
      // The 5 made it worse.
      expect(s.trend, closeTo(15 / 11 - 1, 1e-9));
      expect(s.newCount, 1);
    });

    test('forced percent converts a pure grade subject', () {
      final s = gr.summarize('M', [mark('1'), mark('2')],
          scalePref: 'percent');
      expect(s.scale, 'percent');
      expect(s.forced, isTrue);
      expect(s.average, closeTo((95 + 82.5) / 2, 1e-9));
    });

    test('bare small numbers are percent on a percent subject', () {
      final s = gr.summarize('M', [mark('80'), mark('4')]);
      expect(s.scale, 'percent');
      expect(s.average, closeTo(42.0, 1e-9));
    });

    test('forced grade converts percentages', () {
      final s =
          gr.summarize('M', [mark('95'), mark('60')], scalePref: 'grade');
      // 1 and 3.
      expect(s.average, closeTo(2.0, 1e-9));
    });

    test('prediction ops leave real average alone', () {
      final marks = [
        mark('1', weight: 1, date: '1.9.2026'),
        mark('3', weight: 1, date: '2.9.2026'),
      ];
      final keys = gr.markKeys(marks);
      final ops = <String, Object?>{
        'added': [
          {'Grade': '1', 'Weight': 2},
        ],
        'edits': {
          keys[1]: {'Grade': '2', 'Weight': 1},
        },
        'removed': [keys[0]],
      };
      final s = gr.summarize('M', marks, ops: ops);
      expect(s.average, closeTo(2.0, 1e-9));
      expect(s.predicting, isTrue);
      expect(s.predicted, closeTo((2 * 1 + 1 * 2) / 3, 1e-9));
      expect(
        [for (final r in s.rows) r.state],
        ['removed', 'edited', 'added'],
      );
    });

    test('mark keys distinguish identical marks', () {
      final same = mark('1', weight: 1, date: '1.9.2026');
      final keys = gr.markKeys([same, Map.of(same), {...same, 'Id': 'X'}]);
      expect(keys.toSet(), hasLength(3));
      expect(keys[2], 'id:X');
    });

    test('planned marks do not count', () {
      final s = gr.summarize('M', [
        {'Grade': '?', 'Planned': true, 'Weight': 5},
        mark('2', weight: 1),
      ]);
      expect(s.average, closeTo(2.0, 1e-9));
      expect(s.planned, hasLength(1));
    });
  });

  group('neededFor', () {
    test('needed grade', () {
      final s = rows([mark('1', weight: 1), mark('2', weight: 1)]);
      final need = gr.neededFor(s.rows, s.scale, 1, 1);
      // (1+2+1)/3 = 1.33.
      expect(need.status, 'need');
      expect(need.value, 1.0);
      expect(gr.neededFor(s.rows, s.scale, 3, 1).status, 'any');
    });

    test('needed many best marks', () {
      final s = rows([mark('3', weight: 10)]);
      final need = gr.neededFor(s.rows, s.scale, 1, 1);
      expect(need.status, 'impossible');
      // (30 + n) / (10 + n) < 1.5 -> n > 30.
      expect(need.count, 31);
    });

    test('needed percent', () {
      final s = rows([mark('70', weight: 1)]);
      final need = gr.neededFor(s.rows, s.scale, 2, 1);
      // (70 + 80) / 2 = 75 is exactly the top of a 3, so a 2 needs 81.
      expect(need.status, 'need');
      expect(need.value, 81.0);
      // > 50.
      expect(gr.neededFor(s.rows, s.scale, 3, 1).value, 31.0);
      // 35 % > 30.
      expect(gr.neededFor(s.rows, s.scale, 4, 1).status, 'any');
    });

    test('needed with no marks', () {
      final s = rows([], scale: 'grade');
      // A lone 2- averages 2.5, which rounds to a 3.
      expect(gr.neededFor(s.rows, 'grade', 2, 1).value, 2.0);
    });
  });

  group('formatting', () {
    test('default weight is most common', () {
      final s = rows([
        mark('1', weight: 3),
        mark('1', weight: 3),
        mark('1', weight: 10),
      ]);
      expect(gr.defaultWeight(s), 3);
    });

    test('format value', () {
      expect(gr.formatValue(1.5, 'grade'), '1.50');
      expect(gr.formatValue(84.0, 'percent'), '84 %');
      expect(gr.formatValue(84.25, 'percent'), '84.2 %');
      // No double-rounding: 2.675 is 2.6749999... in binary.
      expect(gr.formatValue(2.675, 'grade'), '2.67');
      expect(gr.formatValue(4.15, 'percent'), '4.2 %');
      expect(gr.formatValue(null, 'grade'), '—');
      expect(gr.formatGradeStep(2.5), '2-');
    });
  });
}
