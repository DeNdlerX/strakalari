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
  });
}
