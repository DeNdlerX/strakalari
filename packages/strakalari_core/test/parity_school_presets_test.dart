import 'package:test/test.dart';

import 'package:strakalari_core/src/planning/school_presets.dart';

import 'parity_cases.dart';

Map<String, Object?> strMap(Object? value) =>
    Map<String, Object?>.from(value as Map);

String iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

Map<String, String> isoMap(Map<DateTime, String> m) =>
    {for (final e in m.entries) iso(e.key): e.value};

// F1 (owner's D1, 2026-11-17): fields the Python app never had. The
// frozen fixture stays as Python wrote it; they are added here.
const _f1GekomFields = {
  'bakalari_url': 'https://bakaweb.gekom.cz',
  'strava_canteen_id': '1950',
  'marks_scale': 'percent',
};

void main() {
  test('parityWithPython', () {
    for (final c in loadParityCases('school_presets')) {
      final fn = c['fn'] as String;
      final args =
          (c['args'] as List).map(decodeParityValue).toList();
      var expected = decodeParityValue(c['expected']);
      if (fn == 'getPreset' && args[0] == 'gekom_2026_2027') {
        expected = {...(expected as Map), ..._f1GekomFields};
      }
      final Object? result;
      switch (fn) {
        case 'validatePreset':
          result = validatePreset(args[0]);
        case 'presetTitle':
          result = presetTitle(strMap(args[0]),
              args.length > 1 ? args[1] as String : 'cs');
        case 'splitEntry':
          final r = splitEntry(args[0]);
          result = [r.$1, r.$2];
        case 'expandEntries':
          result = isoMap(expandEntries(
              (args[0] as List).cast<Object?>()));
        case 'getPreset':
          result = getPreset(args[0] as String?);
        case 'presetDays':
          result = isoMap(presetDays(args[0] as String?));
        case 'presetCloses':
          final r = presetCloses(args[0] as String?);
          result = [r.$1, r.$2];
        case 'presetLunchCutoff':
          result = presetLunchCutoff(args[0] as String?);
        case 'presetMarksBands':
          result = presetMarksBands(args[0] as String?);
        case 'resolveMarksBands':
          final r = resolveMarksBands(
              args[0] == null ? null : strMap(args[0]));
          result = [r.bands, r.source];
        case 'resolveLunchCutoff':
          result = resolveLunchCutoff(
              args[0] == null ? null : strMap(args[0]));
        case 'resolveClose':
          result = resolveClose(args[0] as String,
              args.length > 1 && args[1] != null
                  ? strMap(args[1])
                  : null);
        case 'effectiveCalendar':
          final r = effectiveCalendar(
            strMap(args[0]),
            clip: args.length > 1 ? args[1] as bool : true,
          );
          result = [
            (r.dates.map(iso).toList()..sort()),
            isoMap(r.labels),
            r.info,
          ];
        case 'pruneOrphanForced':
          final cfg = strMap(args[0]);
          final changed = pruneOrphanForced(cfg);
          result = [changed, cfg];
        default:
          fail('unknown parity fn $fn');
      }
      expect(result, expected, reason: '$fn(${c['args']})');
    }
  });
}
