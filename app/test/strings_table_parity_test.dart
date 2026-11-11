import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:app/l10n/strings.dart';

void main() {
  group('strings table parity and unification', () {
    test('no other file in lib defines string translation tables', () {
      final libDir = Directory('lib');
      expect(libDir.existsSync(), isTrue, reason: 'lib directory must exist');

      final forbiddenTablePattern = RegExp(
        r'(?:Map<String,\s*(?:Map<String,\s*String>|String)>\s*([a-zA-Z0-9_]+)\s*=\s*\{|class\s+(?:AppStrings|Str)\b)',
      );

      final filesWithTables = <String>[];

      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        // Normalize slashes for cross-platform checking
        final normalized = entity.path.replaceAll(r'\', '/');
        if (normalized.endsWith('lib/l10n/strings.dart')) continue;

        final content = entity.readAsStringSync();
        if (forbiddenTablePattern.hasMatch(content)) {
          // Allow small local UI configuration maps (e.g., icons, routes), but forbid translation tables.
          // Check if it looks like a localization table (has cs/en or translations).
          if (content.contains("'wiz_bakalari'") ||
              content.contains('"wiz_bakalari"') ||
              content.contains('class AppStrings') ||
              content.contains('class Str {') ||
              (content.contains("'cs':") && content.contains("'en':"))) {
            filesWithTables.add(normalized);
          }
        }
      }

      expect(
        filesWithTables,
        isEmpty,
        reason: 'All localization tables must live in lib/l10n/strings.dart',
      );
    });

    test('every Strings.get and Strings.format key in lib exists in Strings.allKeys', () {
      final libDir = Directory('lib');
      expect(libDir.existsSync(), isTrue);

      final keyPattern = RegExp(
        r'Strings\.(?:get|format)\(\s*[\x27\x22]([a-zA-Z0-9_]+)[\x27\x22]',
      );

      final allKnown = Strings.allKeys;
      expect(allKnown, isNotEmpty, reason: 'Strings.allKeys must not be empty');

      final missing = <String, Set<String>>{};
      var totalFound = 0;

      for (final entity in libDir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final normalized = entity.path.replaceAll(r'\', '/');
        if (normalized.endsWith('lib/l10n/strings.dart')) continue;

        final content = entity.readAsStringSync();
        for (final match in keyPattern.allMatches(content)) {
          totalFound++;
          final key = match.group(1)!;
          if (!Strings.hasKey(key)) {
            missing.putIfAbsent(key, () => {}).add(normalized);
          }
        }
      }

      expect(
        missing,
        isEmpty,
        reason: 'Every key referenced via Strings.get / Strings.format must exist in Strings. '
            'Missing keys: $missing',
      );
      expect(totalFound, greaterThan(100),
          reason: 'Expected hundreds of Strings usages across lib');
    });

    test('canonical Strings table contains expected core keys', () {
      expect(Strings.hasKey('app_title'), isTrue);
      expect(Strings.hasKey('settings_title'), isTrue);
      expect(Strings.hasKey('activity_title'), isTrue);
      expect(Strings.hasKey('planner_title'), isTrue);
      expect(Strings.allKeys.length, greaterThanOrEqualTo(790));
    });
  
    // Checkpoint B BR-M3: Python format specs must not be printed raw.
    test('format fills every placeholder of every key, both languages', () {
      final saved = Strings.lang;
      addTearDown(() => Strings.lang = saved);
      final placeholder = RegExp(r'\{(\w+)(?::([^}]*))?\}');
      for (final lang in ['cs', 'en']) {
        Strings.lang = lang;
        for (final key in Strings.allKeys) {
          final args = <String, Object?>{};
          for (final m in placeholder.allMatches(Strings.get(key))) {
            args[m.group(1)!] = m.group(2) == 'g' ? 12.5 : 'x';
          }
          final out = Strings.format(key, args);
          expect(out.contains('{'), isFalse, reason: '$lang/$key -> $out');
        }
      }
    });

    test('format applies {name:g} like Python and rejects other specs', () {
      final saved = Strings.lang;
      addTearDown(() => Strings.lang = saved);
      Strings.lang = 'cs';
      expect(Strings.format('plan_buffer_note', {'reserve': 10.0}),
          contains(' 10 %'));
      expect(Strings.format('plan_buffer_note', {'reserve': 12.5}),
          contains('12.5'));
      expect(() => Strings.format('plan_buffer_note', {'reserve': 'x'}),
          throwsFormatException);
    });

    test('no hardcoded "Šablona" literal remains under lib', () {
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.replaceAll(r'\', '/').endsWith('lib/l10n/strings.dart')) {
          continue;
        }
        expect(entity.readAsStringSync().contains("Šablona"), isFalse,
            reason: entity.path);
      }
    });

    // tests/test_i18n.py::TestI18nKeys::test_new_flet_strings_present
    test('newFletStringsPresent', () {
      final saved = Strings.lang;
      addTearDown(() => Strings.lang = saved);
      for (final key in [
        'excuse_sending',
        'excuse_failed',
        'need_credentials',
        'send_orders',
        'orders_sending',
        'orders_sent',
        'orders_failed',
      ]) {
        expect(Strings.allKeys, contains(key));
        for (final lang in ['cs', 'en']) {
          Strings.lang = lang;
          expect(Strings.get(key), isNot(key), reason: '$lang/$key');
          expect(Strings.get(key), isNotEmpty);
        }
      }
    });

    // tests/test_i18n.py::test_dead_keys_removed_and_live_keys_kept
    test('deadKeysRemovedAndLiveKeysKept', () {
      const deadKeys = [
        'apply_filter', 'cal_preset_days', 'cal_use_preset', 'cancel_order',
        'change', 'col_pct', 'col_state', 'current_task', 'demo_data',
        'density_comfort', 'empty_lesson', 'ends_at', 'excuse_one_click',
        'leave_blank_keeps', 'leave_blank_keeps_key', 'password_kept',
        'lesson_detail', 'lunch_will_cancel', 'notes_count',
        'notif_section_hint', 'order', 'order_cancelled', 'orders_partial',
        'refresh_cancelled', 'refresh_finished', 'save', 'saves_instantly',
        'school_done', 'stale', 'status', 'status_working',
        'today_subtitle', 'holidays', 'school_year_end', 'limit_pct',
        'best_days', 'no_suggestions', 'plan_safe_note', 'tightest',
        'budget_left',
      ];
      for (final key in deadKeys) {
        expect(Strings.allKeys, isNot(contains(key)),
            reason: 'dead key still present: $key');
      }
      final saved = Strings.lang;
      addTearDown(() => Strings.lang = saved);
      for (final key in [
        'need_credentials', 'already_running', 'bakalari_skipped_log',
        'update_open_releases', 'wiz_finishing_refresh', 'theme',
        'blacklist_broken_log',
      ]) {
        for (final lang in ['cs', 'en']) {
          Strings.lang = lang;
          expect(Strings.get(key), isNot(key), reason: '$lang/$key');
        }
      }
    });

    // Checkpoint B B-S3: the ARB files are generated and not used by the
    // app (STATUS.md, Deviations); they must stay equal to the `Strings`
    // tables, which are the source the app reads.
    test('ARB files equal the Strings tables', () {
      final saved = Strings.lang;
      final wasMobile = Strings.isMobile;
      addTearDown(() {
        Strings.lang = saved;
        Strings.isMobile = wasMobile;
      });
      Strings.isMobile = false;
      for (final lang in ['cs', 'en']) {
        Strings.lang = lang;
        final arb = jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync())
            as Map<String, dynamic>;
        final keys = arb.keys.where((k) => !k.startsWith('@')).toList();
        expect(keys, isNotEmpty);
        for (final key in keys) {
          expect(arb[key], Strings.get(key), reason: '$lang/$key');
        }
      }
    });
  });
}
