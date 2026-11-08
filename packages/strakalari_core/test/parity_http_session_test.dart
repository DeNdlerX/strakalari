import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/http_session.dart';

import 'parity_cases.dart';

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('http')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'appRoot':
          result = appRoot(args[0] as String);
        case 'formFields':
          result = [
            for (final f in formFields(args[0] as String)) [f.$1, f.$2]
          ];
        case 'dxEncodeHtml':
          result = dxEncodeHtml(args[0] as String);
        case 'dxState':
          result = dxState((args[0] as Map)
              .map((k, v) => MapEntry(k as String, v)));
        case 'dxCallbackResult':
          result = dxCallbackResult(args[0] as String);
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
