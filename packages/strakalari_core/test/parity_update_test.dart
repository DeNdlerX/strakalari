import 'package:test/test.dart';

import 'package:strakalari_core/src/update.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('update')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      final expected = decodeParityValue(c['expected']);
      final Object? result;
      switch (fn) {
        case 'normalizeChannel':
          result = normalizeChannel(args[0]);
        case 'parseVersion':
          result = parseVersion(args[0] as String);
        case 'splitVersion':
          final r = splitVersion(args[0] as String);
          result = [r.core, r.pre];
        case 'isPrereleaseVersion':
          result = isPrereleaseVersion(args[0] as String);
        case 'versionKey':
          final k = versionKey(args[0] as String);
          result = [
            k.core,
            k.release,
            [for (final i in k.idents) [i.$1, i.$2, i.$3]],
          ];
        case 'isNewer':
          result = isNewer(args[0] as String, args[1] as String);
        case 'releaseInfo':
          result = releaseInfo(
              args[0] == null ? null : strMap(args[0]));
        case 'pickRelease':
          result = pickRelease(
            (args[0] as List).cast<Object?>(),
            args.length > 1 ? args[1] as String : channelStable,
          );
        case 'shouldCheck':
          result = shouldCheck(
            args[0] == null ? null : strMap(args[0]),
            now: args.length > 1 && args[1] != null
                ? DateTime.fromMillisecondsSinceEpoch(
                    ((args[1] as num) * 1000).round(),
                    isUtc: true)
                : null,
          );
        case 'updateAvailable':
          result = updateAvailable(
            args[0] == null ? null : strMap(args[0]),
            current: args.length > 1 ? args[1] as String? : null,
          );
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
