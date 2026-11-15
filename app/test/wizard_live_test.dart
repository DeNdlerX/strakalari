import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/settings/settings_live.dart';
import 'package:app/features/today/today_controller.dart';
import 'package:app/features/wizard/wizard_controller.dart';
import 'package:app/features/wizard/wizard_live.dart';
import 'package:app/features/wizard/wizard_view.dart';
import 'package:app/l10n/strings.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_wizard_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('wizardControllerFor bridges step, drafts, presets and finish to AppState',
      () {
    final s = AppState(
      configData: {
        'bakalari_url': 'https://skola.bakalari.cz',
        'bakalari_username': 'novak',
      },
      data: {
        'absence': {'Matematika': 10.0},
      },
    );
    s.wizardStep = WizardController.stepDisclaimer;
    s.setDraft('wiz:disclaimer', '1');

    final c = wizardControllerFor(s);
    expect(c.step, WizardController.stepDisclaimer);
    expect(c.disclaimerOk, isTrue);
    expect(c.calendarOptions.map((p) => p.id), contains('gekom_2026_2027'));
    expect(c.calendarOptions.map((p) => p.id), contains('custom'));

    // Step changes sync to AppState.wizardStep.
    c.goTo(WizardController.stepBakalari);
    expect(s.wizardStep, WizardController.stepBakalari);

    // Finishing the wizard dismisses it and clears wiz: drafts in AppState.
    c.finishWizard();
    expect(s.wizardDismissed, isTrue);
    expect(s.wizardStep, 0);
    expect(s.drafts.containsKey('wiz:disclaimer'), isFalse);
  });

  test('an unfinished wizard resumes after the app restarts', () {
    // The first step already saved a login; leaving the app there must not
    // count as a finished setup.
    final first = AppState()..wizardOpened();
    first.save({
      'bakalari_url': 'https://skola.bakalari.cz',
      'bakalari_username': 'novak',
      'bakalari_password': 'secret',
    });
    first.wizardGoto(WizardController.stepStrava, WizardController.stepDone);

    final restarted = AppState();
    expect(restarted.setupPending, isTrue);
    expect(restarted.wizardStep, WizardController.stepStrava);

    restarted.wizardFinished();
    expect(AppState().setupPending, isFalse);
  });

  testWidgets('LiveWizardView renders and marks wizardShown on AppState',
      (tester) async {
    final s = AppState();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => _SeededAppStateController(s)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LiveWizardView(tokens: AppTokens.dark()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(WizardView), findsOneWidget);
    expect(s.wizardShown, isTrue);
  });

  group('B1 wizard excuse templates', () {
    setUp(() {
      Strings.lang = 'cs';
    });
    tearDown(() {
      Strings.lang = 'cs';
    });

    testWidgets(
        'advancing past stepExcuses untouched preserves all canonical default templates',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(configData: {
        'language': 'cs',
        'disclaimer_accepted': true,
        'bakalari_url': 'https://skola.bakalari.cz',
        'bakalari_username': 'novak',
        'bakalari_password': 'secret',
        'your_signature': 'Jan Novák',
      });
      s.wizardStep = WizardController.stepExcuses;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final nextBtn = find.widgetWithText(ElevatedButton, Strings.get('wiz_next'));
      await tester.ensureVisible(nextBtn);
      await tester.pump();
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();

      expect(s.wizardStep, WizardController.stepDone);
      final saved = jsonDecode(
          File(s.config.configPath).readAsStringSync()) as Map<String, dynamic>;
      for (final key in [
        'late_income_excuses',
        'left_soon_excuses',
        'short_absence_excuses',
        'long_absence_excuses',
      ]) {
        expect(saved[key], equals(canonicalDefaults[key]),
            reason: '$key must stay byte-identical when untouched in wizard');
      }
    });

    testWidgets(
        'editing name and multiline text saves structured map without splitting on newline',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(configData: {
        'language': 'cs',
        'disclaimer_accepted': true,
        'your_signature': 'Jan Novák',
        'late_income_excuses': [
          {'name': 'Doprava', 'text': 'Řádek 1\nDěkuji'},
        ],
      });
      s.wizardStep = WizardController.stepExcuses;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final nameField = find.byKey(const Key('tpl:late_income_excuses:0:name'));
      final textField = find.byKey(const Key('tpl:late_income_excuses:0:text'));
      expect(nameField, findsOneWidget);
      expect(textField, findsOneWidget);

      await tester.enterText(nameField, 'Lékař');
      await tester.enterText(textField, 'První řádek\nDruhý řádek\nS pozdravem');
      await tester.pump();

      final nextBtn = find.widgetWithText(ElevatedButton, Strings.get('wiz_next'));
      await tester.ensureVisible(nextBtn);
      await tester.pump();
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();

      final saved = jsonDecode(
          File(s.config.configPath).readAsStringSync()) as Map<String, dynamic>;
      expect(saved['late_income_excuses'], [
        {'name': 'Lékař', 'text': 'První řádek\nDruhý řádek\nS pozdravem'},
      ]);
    });

    testWidgets('template edits survive an AppState rebuild during stepExcuses',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(configData: {
        'language': 'cs',
        'late_income_excuses': [
          {'name': 'Doprava', 'text': 'Původní text'},
        ],
      });
      s.wizardStep = WizardController.stepExcuses;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFinder = find.byKey(const Key('tpl:late_income_excuses:0:text'));
      await tester.tap(textFinder);
      await tester.pump();
      await tester.enterText(textFinder, 'Upravený řádek 1\nŘádek 2');
      await tester.pump();

      final ctrlBefore = tester.widget<TextField>(textFinder).controller!;
      ctrlBefore.selection = const TextSelection.collapsed(offset: 4);
      await tester.pump();

      s.onChanged();
      await tester.pump();

      final ctrlAfter = tester.widget<TextField>(textFinder).controller!;
      expect(identical(ctrlAfter, ctrlBefore), isTrue);
      expect(ctrlAfter.text, 'Upravený řádek 1\nŘádek 2');
      expect(ctrlAfter.selection, const TextSelection.collapsed(offset: 4));
    });

    testWidgets(
        'renders localized Settings category labels in cs and en without raw keys',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      for (final lang in ['cs', 'en']) {
        Strings.lang = lang;
        final s = AppState(configData: {'language': lang});
        s.wizardStep = WizardController.stepExcuses;

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appStateProvider.overrideWith(() => _SeededAppStateController(s)),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: LiveWizardView(tokens: AppTokens.dark()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text(Strings.get('tpl_late')), findsOneWidget);
        expect(find.text(Strings.get('tpl_soon')), findsOneWidget);
        expect(find.text(Strings.get('tpl_short')), findsOneWidget);
        expect(find.text(Strings.get('tpl_long')), findsOneWidget);

        for (final rawKey in [
          'late_income_excuses',
          'left_soon_excuses',
          'short_absence_excuses',
          'long_absence_excuses',
        ]) {
          expect(find.text(rawKey), findsNothing);
        }
      }
    });

    testWidgets(
        'legacy plain-string templates load cleanly in Settings, TodayController and templateTexts',
        (tester) async {
      const legacy = ['Dobrý den,\nDěkuji', 'Osobní důvody'];
      final s = AppState(configData: {
        'tutorials_enabled': false,
        'your_signature': 'Jan Novák',
        'late_income_excuses': legacy,
        'left_soon_excuses': legacy,
        'short_absence_excuses': legacy,
        'long_absence_excuses': legacy,
      });
      s.setSettingsSection('templates');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: const MaterialApp(
            home: Scaffold(body: LiveSettingsView(narrow: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final textFinder = find.byKey(const Key('tpl:late_income_excuses:0:text'));
      expect(textFinder, findsOneWidget);
      expect(tester.widget<TextField>(textFinder).controller!.text,
          'Dobrý den,\nDěkuji');

      final options =
          TodayController(config: s.config.data).templateOptions('late');
      expect(options.length, 2);
      expect(options[0].name, isEmpty);
      expect(options[0].text, contains('Dobrý den,'));
      expect(templateTexts(legacy), equals(legacy));
    });
  });
}

class _SeededAppStateController extends AppStateController {
  final AppState seeded;
  _SeededAppStateController(this.seeded);

  @override
  AppState build() {
    seeded.onChanged = () {
      // ignore: avoid_self_assignment
      state = state;
    };
    seeded.onProgress = seeded.onChanged;
    return seeded;
  }
}
