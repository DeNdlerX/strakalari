import 'package:test/test.dart';

import 'package:strakalari_core/src/planning/grades.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

Map<String, Object?>? rawJson(RawMark? raw) =>
    raw == null ? null : {'kind': raw.kind, 'value': raw.value};

List<double> doubles(Object? value) =>
    (value as List).map((e) => (e as num).toDouble()).toList();

Map<String, Object?> summaryJson(SubjectSummary s) => {
      'name': s.name,
      'scale': s.scale,
      'detected': s.detected,
      'forced': s.forced,
      'rows': [
        for (final r in s.rows)
          {
            'key': r.key,
            'mark': r.mark,
            'state': r.state,
            'value': r.value,
            'weight': r.weight,
            'raw': rawJson(r.raw),
            'original': r.original,
            'date': r.date,
          },
      ],
      'planned': s.planned,
      'average': s.average,
      'predicted': s.predicted,
      'predicting': s.predicting,
      'trend': s.trend,
      'newCount': s.newCount,
      'lastDate': s.lastDate,
      'history': [
        for (final h in s.history) [h.$1, h.$2],
      ],
    };

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('grades')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'parseRaw':
          result = rawJson(parseRaw(
              args[0], args.length > 1 ? args[1] : null));
        case 'parseWeight':
          result = parseWeight(args[0]);
        case 'isPlanned':
          result = isPlanned(args[0]);
        case 'bandsValid':
          result = bandsValid(args[0]);
        case 'normalizeBands':
          result = normalizeBands(args[0]);
        case 'pctToGrade':
          result = pctToGrade((args[0] as num).toDouble(),
              args.length > 1 ? doubles(args[1]) : defaultBands);
        case 'gradeToPct':
          result = gradeToPct((args[0] as num).toDouble(),
              args.length > 1 ? doubles(args[1]) : defaultBands);
        case 'roundGrade':
          result = roundGrade((args[0] as num).toDouble());
        case 'finalGrade':
          result = finalGrade(
              (args[0] as num?)?.toDouble(),
              args[1] as String,
              args.length > 2 ? doubles(args[2]) : defaultBands);
        case 'gradeEquivalent':
          result = gradeEquivalent(
              (args[0] as num?)?.toDouble(),
              args[1] as String,
              args.length > 2 ? doubles(args[2]) : defaultBands);
        case 'kindFor':
          result = kindFor(
              (args[0] as num?)?.toDouble(),
              args[1] as String,
              args.length > 2 ? doubles(args[2]) : defaultBands);
        case 'formatValue':
          result = formatValue(
            (args[0] as num?)?.toDouble(),
            args[1] as String,
            args.length > 2 ? args[2] as int? : null,
          );
        case 'formatGradeStep':
          result = formatGradeStep((args[0] as num).toDouble());
        case 'resolve':
          result = resolve(
            parseRaw(args[0]),
            args[1] as String,
            args[2] as bool,
            args.length > 3 ? doubles(args[3]) : defaultBands,
          );
        case 'detectScale':
          result = detectScale((args[0] as List).cast<Object?>(),
              args.length > 1 ? args[1] as String : 'grade');
        case 'detectSchoolScale':
          result = detectSchoolScale(args[0] as Map?);
        case 'weightedAverage':
          result = weightedAverage([
            for (final p in args[0] as List)
              ((p[0] as num?)?.toDouble(), (p[1] as num).toDouble()),
          ]);
        case 'markKeys':
          result = markKeys((args[0] as List).cast<Object?>());
        case 'emptyPrediction':
          result = emptyPrediction();
        case 'predictionActive':
          result = predictionActive(args[0] as Map?);
        case 'summarize':
          final opts =
              args.length > 2 ? strMap(args[2]) : <String, Object?>{};
          result = summaryJson(summarize(
            args[0] as String,
            (args[1] as List).cast<Object?>(),
            scalePref: opts['scalePref'] as String? ?? 'auto',
            ops: opts['ops'] as Map?,
            today: opts['today'] as DateTime?,
          ));
        case 'summarizeAll':
          final opts = strMap(args[1]);
          result = [
            for (final s in summarizeAll(
              args[0] as Map?,
              scalePref: opts['scalePref'] as String? ?? 'auto',
              today: opts['today'] as DateTime?,
            ))
              summaryJson(s),
          ];
        case 'validMarkText':
          result = validMarkText(args[0]);
        case 'defaultWeight':
          result = defaultWeight(summarize('M',
              (args[0] as List).cast<Object?>(),
              today: DateTime(2026, 9, 13)));
        case 'formatWeight':
          result = formatWeight((args[0] as num).toDouble());
        case 'neededFor':
          final rows = summarize('M',
                  (args[0] as List).cast<Object?>(),
                  today: DateTime(2026, 9, 13))
              .rows;
          final n = neededFor(rows, args[1] as String, args[2] as int,
              args[3] as num);
          result = {
            'status': n.status,
            'value': n.value,
            'count': n.count,
          };
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
