import 'package:test/test.dart';

import 'package:strakalari_core/src/i18n.dart';

void main() {
  tearDown(() {
    setLanguage('cs');
  });

  test('getAndSetLanguage', () {
    setLanguage('en');
    expect(getLanguage(), 'en');
    setLanguage('xx');
    expect(getLanguage(), 'en');
  });

  test('missingKeyFallsBack', () {
    expect(t('non_existent_key_xyz', defaultValue: 'Fallback'), 'Fallback');
    expect(t('non_existent_key_xyz'), 'non_existent_key_xyz');
  });

  test('coreMessagesHaveBothLanguagesAndSamePlaceholders', () {
    final fields = RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}');
    Set<String> names(String text) =>
        fields.allMatches(text).map((m) => m.group(1)!).toSet();
    for (final entry in messages.entries) {
      expect(entry.value['cs'], isNotNull, reason: entry.key);
      expect(entry.value['en'], isNotNull, reason: entry.key);
      expect(entry.value['cs']!.isNotEmpty, isTrue, reason: entry.key);
      expect(entry.value['en']!.isNotEmpty, isTrue, reason: entry.key);
      expect(names(entry.value['en']!), names(entry.value['cs']!),
          reason: entry.key);
    }
  });

  test('coreMessageFollowsLanguage', () {
    final before = getLanguage();
    try {
      setLanguage('en');
      expect(t('auto_excuses_failed', args: {'n': 2}),
          '2 excuse(s) could not be sent');
      setLanguage('cs');
      expect(t('auto_excuses_failed', args: {'n': 2}),
          startsWith('2 omluvenek'));
      expect(t('bak_login_rejected'), startsWith('Přihlášení'));
    } finally {
      setLanguage(before);
    }
  });
}
