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
  });
}
