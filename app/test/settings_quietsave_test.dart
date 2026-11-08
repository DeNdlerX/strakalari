import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_view.dart';

SettingsController _controller([Map<String, dynamic>? config]) =>
    SettingsController(config ?? {'check_interval_minutes': 60});

void main() {
  group('settings_quiet_save', () {
    test('save quiet persists without notifying listeners', () {
      final c = _controller();
      var renders = 0;
      c.addListener(() => renders++);
      final synced = <Object?>[];
      c.addConfigListener(
          () => synced.add(c.get('check_interval_minutes')));

      expect(c.saveQuiet({'check_interval_minutes': 15}), isTrue);
      expect(c.get('check_interval_minutes'), 15);
      expect(renders, 0);
      // Config listeners (e.g. the scheduler interval) still hear it.
      expect(synced, [15]);
      // A plain save still notifies listeners.
      c.save({'check_interval_minutes': 20});
      expect(renders, 1);
    });

    test('save quiet reports failure', () {
      final c = SettingsController({},
          persist: (_) => throw StateError('disk gone'));
      var renders = 0;
      c.addListener(() => renders++);
      expect(c.saveQuiet({'x': 1}), isFalse);
      expect(renders, 0);
    });

    testWidgets('autosave field saves quietly and skips unchanged',
        (t) async {
      final writes = <Map<String, dynamic>>[];
      final c = SettingsController(
          {'bakalari_url': 'https://old.example'},
          persist: (updates) {
            writes.add(updates);
            return true;
          });
      var renders = 0;
      c.addListener(() => renders++);
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AutosaveField(
        controller: c,
        label: 'URL',
        draftKey: 'acc:url',
        configKey: 'bakalari_url',
        fallback: 'https://old.example',
      ))));
      final field =
          find.byKey(const Key('auto:acc:url'));
      // Focus moved through the field without an edit: no write at all.
      writes.clear();
      await t.tap(field);
      await t.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      expect(writes, isEmpty);
      expect(renders, 0);

      await t.enterText(field, 'https://new.example');
      await t.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      expect(writes, [
        {'bakalari_url': 'https://new.example'}
      ]);
      expect(c.get('bakalari_url'), 'https://new.example');
      expect(renders, 0);
    });

    testWidgets('autosave shows normalized value in place', (t) async {
      final c = _controller();
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AutosaveField(
        controller: c,
        label: 'Interval',
        draftKey: 'rule:interval',
        configKey: 'check_interval_minutes',
        fallback: '60',
        parse: (raw) =>
            (double.parse(raw.replaceAll(',', '.'))).toInt().clamp(1, 1 << 30),
      ))));
      final field =
          find.byKey(const Key('auto:rule:interval'));
      await t.enterText(field, '0,4');
      await t.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      expect(c.get('check_interval_minutes'), 1);
      // No re-render repaints it, so the field shows the stored value.
      expect(
          t.widget<TextField>(field).controller?.text, '1');
    });

    test('template editor saves names', () {
      final c = SettingsController(
          {'short_absence_excuses': ['Text A', 'Text B']});
      // Rename the first entry (name becomes a dict).
      expect(
          c.commitTemplates('short_absence_excuses', [
            {'name': 'Rodina', 'text': 'Text A'},
            {'name': '', 'text': 'Text B'},
          ]),
          isTrue);
      expect(c.get('short_absence_excuses'), [
        {'name': 'Rodina', 'text': 'Text A'},
        'Text B',
      ]);
      // Clearing the name turns it back into a plain string.
      expect(
          c.commitTemplates('short_absence_excuses', [
            {'name': '', 'text': 'Text A'},
            {'name': '', 'text': 'Text B'},
          ]),
          isTrue);
      expect(
          c.get('short_absence_excuses'), ['Text A', 'Text B']);
    });

    test('text fields compare as text', () {
      // A canteen number with a leading zero is a change.
      expect(SettingsController.sameValue('123', '0123'), isFalse);
      expect(SettingsController.sameValue('1234', '1234'), isTrue);
      // Numeric settings still compare by value.
      expect(SettingsController.sameValue(60, 60.0), isTrue);
      expect(SettingsController.sameValue(25.0, '25'), isTrue);
    });
  });
}
