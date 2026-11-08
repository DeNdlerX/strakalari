import 'package:test/test.dart';

import 'package:strakalari_core/src/lunches/lunch_cutoff.dart';

import 'parity_cases.dart';

String fmtWall(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}'
    'T${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

Set<DateTime> freeSet(Object? value) =>
    value == null ? <DateTime>{} : <DateTime>{...(value as List).cast<DateTime>()};

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('lunch_cutoff')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'parseCutoffTime':
          final r = parseCutoffTime(args[0]);
          result = [r.$1, r.$2];
        case 'isValidCutoffTime':
          result = isValidCutoffTime(args[0]);
        case 'normalizeCutoffTime':
          result = normalizeCutoffTime(args[0]);
        case 'isBusinessDay':
          result = isBusinessDay(args[0] as DateTime,
              args.length > 1 ? freeSet(args[1]) : null);
        case 'previousBusinessDay':
          result = previousBusinessDay(args[0] as DateTime,
              args.length > 1 ? freeSet(args[1]) : null);
        case 'lunchOrderDeadline':
          result = fmtWall(lunchOrderDeadline(
            args[0] as DateTime,
            args.length > 1 ? args[1] : '12:00',
            args.length > 2 ? freeSet(args[2]) : null,
          ));
        case 'isLunchOrderOpen':
          result = isLunchOrderOpen(
            args[0] as DateTime,
            now: args.length > 1 ? args[1] as DateTime? : null,
            cutoffTime: args.length > 2 ? args[2] : '12:00',
            freeDays: args.length > 3 ? freeSet(args[3]) : null,
          );
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
