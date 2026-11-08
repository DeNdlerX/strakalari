import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';
import 'package:strakalari_core/src/status_notification.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

Map<String, List<Map<String, Object?>>> timetableOf(Object? value) {
  if (value == null) return {};
  return (value as Map).map((k, v) => MapEntry(k as String,
      (v as List).map((e) => strMap(e)).toList()));
}

Map<String, Object?> statusJson(StatusContent c) => {
      'title': c.title,
      'text': c.text,
      'sub': c.sub,
      'rows': [
        for (final r in c.rows)
          {
            'kind': r.kind,
            'label': r.label,
            'value': r.value,
            'short': r.short,
          },
      ],
    };

StatusInputs inputsOf(Map<String, Object?> m) => StatusInputs(
      timetable: timetableOf(m['timetable']),
      food: m['food'] == null
          ? {}
          : (m['food'] as Map).map((k, v) => MapEntry(k as String, v)),
      webOrders: m['webOrders'] == null
          ? {}
          : (m['webOrders'] as Map)
              .map((k, v) => MapEntry(k as String, v)),
      config: m['config'] == null ? {} : strMap(m['config']),
      pendingExcuses: (m['pendingExcuses'] as num?)?.toInt(),
      lastUpdated: m['lastUpdated'] as DateTime?,
      freeDays: m['freeDays'] == null
          ? null
          : <DateTime>{...(m['freeDays'] as List).cast<DateTime>()},
    );

void main() {
  setUp(() => setLanguage('cs'));
  tearDown(() => setLanguage('cs'));
  test('parityWithPython', () {
    for (final c in loadParityCases('status_notification')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'selectedItems':
          result = selectedItems(
              args[0] == null ? null : strMap(args[0]));
        case 'withItem':
          result = withItem(strMap(args[0]), args[1] as String,
              args[2] as bool);
        case 'mealText':
          result = mealText(args[0]);
        case 'lunchOverAt':
          result = lunchOverAt(
              inputsOf(strMap(args[0])), args[1] as DateTime);
        case 'buildStatus':
          final opts = strMap(args[2]);
          final fb = opts['fallback'] as List?;
          result = statusJson(buildStatus(
            inputsOf(strMap(args[0])),
            now: args[1] as DateTime?,
            fallback: fb == null
                ? ('Strakaláři', '')
                : (fb[0] as String, fb[1] as String),
            lang: opts['lang'] as String?,
          ));
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
