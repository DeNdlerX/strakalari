import 'package:test/test.dart';

import 'package:strakalari_core/src/automation/excuse_history.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    (value as Map).map((k, v) => MapEntry(k as String, v));

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('history')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'normalizeHistoryItem':
          result = normalizeHistoryItem(strMap(args[0]));
        case 'baseExcuse':
          result = baseExcuse(strMap(args[0]));
        case 'excuseWindowStart':
          result = excuseWindowStart(args[0] as DateTime,
              args.length > 1 ? args[1] as DateTime? : null);
        case 'historyEntries':
          result = historyEntries(strMap(args[0]));
        case 'mergeSentExcuses':
          final (merged, added) = mergeSentExcuses(
              (args[0] as List).cast<Object?>(),
              (args[1] as List).cast<Object?>());
          result = [merged, added];
        case 'excuseCovered':
          result = excuseCovered(strMap(args[0]),
              (args[1] as List).cast<Object?>());
        case 'taskCovered':
          result = taskCovered(args[0] as DateTime, args[1] as int?,
              (args[2] as List).cast<Object?>());
        case 'unconfirmedPath':
          result = unconfirmedPath(args[0] as String);
        case 'unconfirmedEntry':
          result = unconfirmedEntry(
              strMap(args[0]), args[1] as DateTime);
        case 'unconfirmedBlocks':
          result = unconfirmedBlocks(strMap(args[0]),
              (args[1] as List).cast<Object?>());
        case 'resolveUnconfirmed':
          final (still, confirmed, notSent) = resolveUnconfirmed(
              (args[0] as List).cast<Object?>(),
              (args[1] as List).cast<Object?>(),
              args[2] as DateTime?,
              args.length > 3 ? args[3] as DateTime? : null);
          result = [still, confirmed, notSent];
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
