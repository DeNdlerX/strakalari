import 'dart:async';

import 'package:test/test.dart';

import 'package:strakalari_core/src/error_report.dart';
import 'package:strakalari_core/src/i18n.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

Object? errorFor(String tag) {
  switch (tag) {
    case 'none':
      return null;
    case 'timeout-builtin':
      return TimeoutException('timed out');
    case 'timeout-msg':
      return Exception('Timeout 30000ms exceeded');
    case 'user':
      return const UserError('missing url');
    case 'other':
      return StateError('boom');
    default:
      throw ArgumentError('unknown error tag $tag');
  }
}

void main() {
  setUp(() => setLanguage('cs'));
  tearDown(() => setLanguage('cs'));
  test('parityWithPython', () {
    for (final c in loadParityCases('error_report')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'timeoutUserMessage':
          result = timeoutUserMessage();
        case 'isTimeoutError':
          result = isTimeoutError(errorFor(args[0] as String));
        case 'redactConfig':
          result = redactConfig(
              args[0] == null ? null : strMap(args[0]));
        case 'secretValues':
          result = secretValues(
              args[0] == null ? null : strMap(args[0])).toList()
            ..sort();
        case 'redactValues':
          result = redactValues(args[0] as String,
              (args[1] as List).cast<String>().toSet());
        case 'redactText':
          result = redactText(args[0] as String,
              args.length > 1 && args[1] != null
                  ? strMap(args[1])
                  : null);
        case 'shortSummary':
          result = shortSummary(
            null,
            args[1] as String? ?? '',
            args.length > 2 ? args[2] as int : 200,
          );
        case 'formatReport':
          result = formatReport(
              args[0] == null ? null : strMap(args[0]));
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
