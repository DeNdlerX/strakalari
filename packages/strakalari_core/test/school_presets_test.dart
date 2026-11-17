// Port of tests/test_school_calendar.py.
//
// Not ported here:
// - test_no_migration_legacy_holidays_ignored and
//   test_fresh_config_assumes_no_school: ConfigManager domain, covered by
//   test/config_test.dart.
// - test_forecast_uses_sem1_close, test_forecast_uses_sem2_close and
//   test_forecast_legacy_year_end_still_applies: need forecast.dart
//   (phase 3).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/planning/grades.dart';
import 'package:strakalari_core/src/planning/school_presets.dart';
import 'package:strakalari_core/src/storage/config.dart';
import 'package:strakalari_core/src/storage/helpers.dart';

void writeUserPreset(Directory tmp, String name, Object data) {
  final folder = Directory(resolvePath(userPresetDir));
  folder.createSync(recursive: true);
  File('${folder.path}${Platform.pathSeparator}$name')
      .writeAsStringSync(jsonEncode(data));
}

void main() {
  group('gekomPreset', () {
    test('expandsAllRangesAndSingles', () {
      final days = presetDays('gekom_2026_2027');
      // 3 podzimni + 12 vanocni + 5 jarni + 5 velikonocni + 5 singles.
      // No summer range: the preset ends at the sem2 absence closure.
      expect(days.length, equals(30));
      expect(days[DateTime(2026, 10, 28)], equals('Podzimní prázdniny'));
      expect(days[DateTime(2026, 11, 16)], equals('Ředitelské volno'));
      expect(days[DateTime(2027, 1, 29)], equals('Pololetní prázdniny'));
      expect(days[DateTime(2026, 9, 28)], equals('Státní svátek'));
      expect(days.containsKey(DateTime(2027, 7, 15)), isFalse);
    });

    test('closes', () {
      expect(presetCloses('gekom_2026_2027'), ('25.01.2027', '26.04.2027'));
      expect(presetCloses('custom'), ('', ''));
      expect(presetCloses('unknown-id'), ('', ''));
    });

    test('shipsItsPercentTable', () {
      expect(presetMarksBands('gekom_2026_2027'), [87.0, 72.0, 55.0, 40.0]);
      expect(presetMarksBands('custom'), isNull);
    });

    test('shipsDefaultsAndHelpers', () {
      expect(presetBakalariUrl('gekom_2026_2027'), 'https://bakaweb.gekom.cz');
      expect(presetCanteenId('gekom_2026_2027'), '1950');
      expect(presetMarksScale('gekom_2026_2027'), 'percent');

      expect(presetBakalariUrl('custom'), '');
      expect(presetCanteenId('custom'), '');
      expect(presetMarksScale('custom'), isNull);

      expect(presetBakalariUrl('unknown-id'), '');
      expect(presetCanteenId('unknown-id'), '');
      expect(presetMarksScale('unknown-id'), isNull);
      expect(presetBakalariUrl(null), '');
      expect(presetCanteenId(null), '');
      expect(presetMarksScale(null), isNull);
    });
  });

  group('effectiveCalendar', () {
    test('overrideModel', () {
      final cfg = <String, Object?>{
        'school_preset_id': 'gekom_2026_2027',
        // Cancel one preset day (force school) and add a custom one.
        'forced_school_days': ['29.01.2027'],
        'user_free_days': [
          {'date': '15.03.2027', 'label': 'Zubař'}
        ],
        'holidays': [],
      };
      final cal = effectiveCalendar(cfg);
      expect(cal.dates.contains(DateTime(2027, 1, 29)), isFalse);
      expect(cal.dates.contains(DateTime(2027, 3, 15)), isTrue);
      expect(cal.labels[DateTime(2027, 3, 15)], equals('Zubař'));
      expect(cal.labels[DateTime(2026, 10, 28)],
          equals('Podzimní prázdniny'));
      expect(cal.info['forced_school'], equals(1));
      expect(cal.info['user_added'], equals(1));
    });

    test('customPresetOnlyUserDays', () {
      final cfg = <String, Object?>{
        'school_preset_id': 'custom',
        'user_free_days': ['05.05.2027'],
        'forced_school_days': [],
      };
      final cal = effectiveCalendar(cfg);
      expect(cal.dates, {DateTime(2027, 5, 5)});
      expect(cal.info['preset_days'], equals(0));
    });

    test('customSetupWorksWithoutAnyPreset', () {
      final cfg = <String, Object?>{
        'school_preset_id': 'custom',
        'user_free_days': ['02.11.2026'],
      };
      final cal = effectiveCalendar(cfg);
      expect(cal.dates, {DateTime(2026, 11, 2)});
      expect(resolveLunchCutoff(cfg), equals('12:00'));
      expect(resolveClose('sem2', cfg), equals(''));
    });
  });

  group('closes', () {
    test('userWinsThenPreset', () {
      expect(resolveClose('sem1', {'school_preset_id': 'gekom_2026_2027'}),
          equals('25.01.2027'));
      final cfg = <String, Object?>{
        'school_preset_id': 'gekom_2026_2027',
        'sem1_close': '20.01.2027',
      };
      expect(resolveClose('sem1', cfg), equals('20.01.2027'));
      expect(
          resolveClose('sem1', {'school_preset_id': 'custom'}), equals(''));
    });
  });

  test('canonicalDefaultsHaveCalendarKeys', () {
    for (final key in [
      'school_preset_id',
      'user_free_days',
      'forced_school_days',
      'sem1_close',
      'sem2_close'
    ]) {
      expect(canonicalDefaults.containsKey(key), isTrue, reason: key);
    }
  });

  test('pruneOrphanForced', () {
    final cfg = <String, Object?>{
      'school_preset_id': 'gekom_2026_2027',
      'user_free_days': [],
      'forced_school_days': ['01.05.2027', '29.01.2027'],
    };
    expect(pruneOrphanForced(cfg), isTrue);
    expect(cfg['forced_school_days'], ['29.01.2027']);
  });

  group('userPresets', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('school_presets_test_');
      setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    });

    tearDown(() {
      setEnvironmentOverride(null);
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('fileIsPickedUp', () {
      writeUserPreset(tmp, 'gymxy.json', {
        'id': 'gymxy_2026',
        'title_cs': 'Gymnázium XY 2026/2027',
        'sem2_close': '25.06.2027',
        'lunch_cutoff_time': '13:30',
        'ranges': [
          ['23.12.2026', '01.01.2027', 'Vánoce']
        ],
        'days': [
          ['17.11.2026', 'Svátek']
        ],
      });
      final ids = [for (final (id, _) in presetOptions('cs')) id];
      expect(ids, contains('gymxy_2026'));
      expect(ids, contains('gekom_2026_2027'));
      final cfg = <String, Object?>{'school_preset_id': 'gymxy_2026'};
      final cal = effectiveCalendar(cfg);
      expect(cal.dates.contains(DateTime(2026, 11, 17)), isTrue);
      expect(cal.dates.contains(DateTime(2026, 12, 24)), isTrue);
      expect(resolveLunchCutoff(cfg), equals('13:30'));
    });

    test('invalidFileIsIgnored', () {
      writeUserPreset(
          tmp, 'bad.json', {'id': 'custom', 'sem1_close': 'never'});
      writeUserPreset(tmp, 'broken.json', '{not json');
      final output = StringBuffer();
      var ids = <String>[];
      runZoned(() {
        ids = <String>[for (final (id, _) in presetOptions('cs')) id];
      },
          zoneSpecification: ZoneSpecification(
              print: (self, parent, zone, line) {
            output.writeln(line);
          }));
      expect(ids, ['gekom_2026_2027']);
      expect(output.toString(), contains('ignored'));
    });

    test('cannotReplaceShippedOne', () {
      writeUserPreset(tmp, 'x.json', {
        'id': 'gekom_2026_2027',
        'title_cs': 'Fake',
        'days': [
          ['01.03.2027', 'x']
        ],
      });
      expect(
          identical(getPreset('gekom_2026_2027'),
              presets['gekom_2026_2027']),
          isTrue);
    });
  });

  test('shippedPresetsAreValid', () {
    for (final preset in presets.values) {
      expect(validatePreset(preset), isEmpty);
    }
  });

  group('marksBands', () {
    test('resolutionOrder', () {
      final gekom = <String, Object?>{'school_preset_id': 'gekom_2026_2027'};
      final fromPreset = resolveMarksBands(gekom);
      expect(fromPreset.bands, [87.0, 72.0, 55.0, 40.0]);
      expect(fromPreset.source, 'preset');
      final own = Map<String, Object?>.of(gekom)
        ..['marks_percent_bands'] = [95, 80, 60, 40];
      final fromUser = resolveMarksBands(own);
      expect(fromUser.bands, [95.0, 80.0, 60.0, 40.0]);
      expect(fromUser.source, 'user');
      final broken = Map<String, Object?>.of(gekom)
        ..['marks_percent_bands'] = [10, 20, 30, 40];
      expect(resolveMarksBands(broken).source, 'preset');
      final fallback =
          resolveMarksBands({'school_preset_id': 'custom'});
      expect(fallback.bands, defaultBands);
      expect(fallback.source, 'default');
    });

    test('presetBandsValidated', () {
      final base = {'id': 'x', 'title_cs': 'X'};
      expect(
          validatePreset({...base, 'marks_percent_bands': [87, 72, 55, 40]}),
          isEmpty);
      expect(
          validatePreset({...base, 'marks_percent_bands': <int>[]}), isEmpty);
      expect(
          validatePreset({...base, 'marks_percent_bands': [40, 55, 72, 87]}),
          isNotEmpty);
      expect(validatePreset({...base, 'marks_percent_bands': '87,72'}),
          isNotEmpty);
    });

    test('newFieldsAcceptedAndRejectedOneByOne', () {
      final base = <String, Object?>{'id': 'x', 'title_cs': 'X'};
      expect(
          validatePreset({
            ...base,
            'school': 'Gymnasium XY',
            'category_cs': 'Maturitní ročník',
            'category_en': 'Final year',
            'bakalari_url': 'https://baka.example.cz',
            'strava_canteen_id': '1234',
            'marks_scale': 'percent',
          }),
          isEmpty);
      expect(validatePreset({...base, 'marks_scale': 'grade'}), isEmpty);
      expect(
          validatePreset({
            ...base,
            'bakalari_url': '',
            'strava_canteen_id': '',
            'marks_scale': '',
          }),
          isEmpty);

      expect(
          validatePreset({...base, 'bakalari_url': 'baka.example.cz'}),
          isNotEmpty);
      expect(
          validatePreset({...base, 'bakalari_url': 'https://localhost'}),
          isNotEmpty);
      expect(validatePreset({...base, 'bakalari_url': 123}), isNotEmpty);

      expect(validatePreset({...base, 'strava_canteen_id': '19a0'}),
          isNotEmpty);
      expect(validatePreset({...base, 'strava_canteen_id': '-1'}), isNotEmpty);
      expect(validatePreset({...base, 'strava_canteen_id': 1950}), isNotEmpty);

      expect(validatePreset({...base, 'marks_scale': 'auto'}), isNotEmpty);
      expect(validatePreset({...base, 'marks_scale': 'points'}), isNotEmpty);
      expect(validatePreset({...base, 'marks_scale': 1}), isNotEmpty);
    });

    test('presetCategoryFallbackOrder', () {
      expect(
          presetCategory({
            'id': 'p1',
            'title_cs': 'Titul CS',
            'title_en': 'Title EN',
            'year': '2026/2027',
            'category_cs': 'Kategorie CS',
            'category_en': 'Category EN',
          }, 'cs'),
          'Kategorie CS');
      expect(
          presetCategory({
            'id': 'p1',
            'title_cs': 'Titul CS',
            'title_en': 'Title EN',
            'year': '2026/2027',
            'category_cs': 'Kategorie CS',
            'category_en': 'Category EN',
          }, 'en'),
          'Category EN');
      expect(
          presetCategory({
            'id': 'p1',
            'title_cs': 'Titul CS',
            'year': '2026/2027',
            'category_cs': 'Kategorie CS',
          }, 'en'),
          'Kategorie CS');
      expect(
          presetCategory({
            'id': 'p1',
            'title_cs': 'Titul CS',
            'year': '2026/2027',
          }, 'cs'),
          '2026/2027');
      expect(
          presetCategory({
            'id': 'p1',
            'title_cs': 'Titul CS',
            'title_en': 'Title EN',
          }, 'en'),
          'Title EN');
    });

    test('schoolGroupsAndLegacyUserPreset', () {
      final tmp = Directory.systemTemp.createTempSync('school_groups_test_');
      setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
      try {
        // Legacy user preset without any new fields loads cleanly and gets its own card.
        writeUserPreset(tmp, 'legacy.json', {
          'id': 'legacy_school',
          'title_cs': 'Stará škola',
          'title_en': 'Legacy School',
          'sem1_close': '20.01.2027',
        });
        // Multi-preset school grouping.
        writeUserPreset(tmp, 'alpha_a.json', {
          'id': 'alpha_1',
          'school': 'Alpha',
          'category_cs': '1. ročník',
          'category_en': 'Year 1',
          'title_cs': 'Alpha 1',
          'bakalari_url': 'https://alpha.example.cz',
          'strava_canteen_id': '4242',
          'marks_scale': 'grade',
        });
        writeUserPreset(tmp, 'alpha_b.json', {
          'id': 'alpha_4',
          'school': 'Alpha',
          'category_cs': '4. ročník',
          'category_en': 'Year 4',
          'title_cs': 'Alpha 4',
        });

        expect(presetBakalariUrl('legacy_school'), '');
        expect(presetCanteenId('legacy_school'), '');
        expect(presetMarksScale('legacy_school'), isNull);
        expect(presetBakalariUrl('alpha_1'), 'https://alpha.example.cz');
        expect(presetCanteenId('alpha_1'), '4242');
        expect(presetMarksScale('alpha_1'), 'grade');

        final groupsCs = schoolGroups('cs');
        expect(groupsCs.map((g) => g.name).toList(),
            ['Alpha', 'GEKOM', 'Stará škola']);
        final alpha = groupsCs.firstWhere((g) => g.name == 'Alpha');
        expect(alpha.presets.map((p) => (p.id, p.category)).toList(), [
          ('alpha_1', '1. ročník'),
          ('alpha_4', '4. ročník'),
        ]);
        final legacy = groupsCs.firstWhere((g) => g.name == 'Stará škola');
        expect(legacy.presets.length, 1);
        expect(legacy.presets.single.id, 'legacy_school');

        final groupsEn = schoolGroups('en');
        expect(groupsEn.map((g) => g.name).toList(),
            ['Alpha', 'GEKOM', 'Legacy School']);
        final alphaEn = groupsEn.firstWhere((g) => g.name == 'Alpha');
        expect(alphaEn.presets.map((p) => p.category).toList(),
            ['Year 1', 'Year 4']);
      } finally {
        setEnvironmentOverride(null);
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });
  });
}
