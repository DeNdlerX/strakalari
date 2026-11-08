import 'package:test/test.dart';

import 'package:strakalari_core/src/planning/matching.dart';

void main() {
  group('keywordBansInflectedMeal', () {
    for (final (keyword, meal) in [
      ('ryba', 'Rybí filé s bramborem'),
      ('ryba', 'Smažené ryby'),
      ('ryby', 'Rybí prsty'),
      ('sýr', 'Smažený sýr'),
      ('sýr', 'Sýrová omáčka'),
      ('maso', 'Masová směs'),
      ('kuře', 'Kuřecí řízek'),
      ('houby', 'Houbové rizoto'),
      ('čočka', 'Čočková polévka'),
      ('vepřové', 'Vepřového guláše'),
    ]) {
      test('$keyword bans $meal', () {
        final (banned, matched) = isFoodBanned(meal, [keyword]);
        expect(banned, isTrue);
        expect(matched, keyword);
      });
    }
  });

  group('differentWordsStayAllowed', () {
    for (final (keyword, meal) in [
      ('ryb', 'Rybíz koláč'),
      ('rybí', 'Rybíz koláč'),
      ('ryb', 'Rybízový koláč'),
      ('rýže', 'Rybí filé'),
      ('sýr', 'Rajská omáčka'),
      ('vepřové maso', 'Kuřecí maso'),
    ]) {
      test('$keyword allows $meal', () {
        expect(isFoodBanned(meal, [keyword]), (false, ''));
      });
    }
  });

  group('matchingPrefix', () {
    test('rybiDoesNotBanRybiz', () {
      final (banned, _) = isFoodBanned('Rybíz koláč', ['rybí']);
      expect(banned, isFalse);
    });

    test('inflectionStillMatches', () {
      final (banned, kw) = isFoodBanned('Vepřového guláše', ['vepřové']);
      expect(banned, isTrue);
      expect(kw, 'vepřové');
    });
  });

  group('matching', () {
    test('wholeWordNotSubstring', () {
      final (banned, _) = isFoodBanned('Rybízový koláč', ['ryb']);
      expect(banned, isFalse);
    });

    test('diacriticsInsensitive', () {
      final (banned, _) = isFoodBanned('Cocka na kyselo', ['čočka']);
      expect(banned, isTrue);
    });

    test('inflectionVariant', () {
      final (banned, kw) = isFoodBanned('Vepřového guláše', ['vepřové']);
      expect(banned, isTrue);
      expect(kw, 'vepřové');
    });

    test('caseInsensitive', () {
      final (banned, _) = isFoodBanned('HOUBY smažené', ['houby']);
      expect(banned, isTrue);
    });
  });
}
