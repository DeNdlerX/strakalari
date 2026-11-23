import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_live.dart';
import 'package:app/features/settings/wakeup_card.dart';
import 'package:app/features/today/today_controller.dart';
import 'package:app/features/wizard/wizard_controller.dart';
import 'package:app/features/wizard/wizard_live.dart';
import 'package:app/features/wizard/wizard_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/platform/android/android_channel.dart';
import 'package:app/shell/theme.dart';

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
    s.wizardStep = WizardController.stepWelcome;
    s.setDraft('wiz:disclaimer', '1');

    final c = wizardControllerFor(s);
    expect(c.step, WizardController.stepWelcome);
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

  test('an unfinished wizard resumes under the F1 resume rule', () {
    // Saved step 6 with disclaimer accepted resumes at stepSchool (1);
    // without disclaimer accepted resumes at stepWelcome (0).
    final first = AppState()..wizardOpened();
    first.save({
      'disclaimer_accepted': true,
      'bakalari_url': 'https://skola.bakalari.cz',
      'bakalari_username': 'novak',
      'bakalari_password': 'secret',
    });
    first.wizardGoto(WizardController.stepDone, WizardController.stepDone);

    final restartedWithDisclaimer = AppState();
    expect(restartedWithDisclaimer.setupPending, isTrue);
    expect(restartedWithDisclaimer.needsSetup(), isTrue);
    expect(restartedWithDisclaimer.wizardStep, WizardController.stepSchool);

    first.save({'disclaimer_accepted': false});
    final restartedNoDisclaimer = AppState();
    expect(restartedNoDisclaimer.setupPending, isTrue);
    expect(restartedNoDisclaimer.wizardStep, WizardController.stepWelcome);

    first.wizardGoto(0, WizardController.stepDone);
    expect(AppState().wizardStep, WizardController.stepWelcome);

    restartedWithDisclaimer.wizardFinished();
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
        'advancing through whole wizard untouched preserves all canonical default templates and gemini keys',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(configData: {
        'language': 'cs',
        'gemini_api_key': 'AIza-keep',
        'gemini_model': 'gemini-3.8-flash',
        'gemini_auto_enabled': true,
        'gemini_prompt': 'custom prompt',
        'gemini_interval_days': 5,
      });
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark()),
            ),
          ),
          GoRoute(
            path: '/today',
            builder: (_, _) => const Scaffold(body: SizedBox.shrink()),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // Step 0: Vítejte — accept disclaimer and Continue.
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, Strings.get('wiz_next')));
      await tester.pumpAndSettle();
      expect(s.wizardStep, WizardController.stepSchool);

      // Step 1: Škola — skip.
      await tester.tap(find.text(Strings.get('wiz_skip')));
      await tester.pumpAndSettle();
      expect(s.wizardStep, WizardController.stepBakalari);

      // Step 2: Bakaláři — skip.
      await tester.tap(find.text(Strings.get('wiz_skip')));
      await tester.pumpAndSettle();
      expect(s.wizardStep, WizardController.stepStrava);

      // Step 3: Strava — skip.
      await tester.tap(find.text(Strings.get('wiz_skip')));
      await tester.pumpAndSettle();
      expect(s.wizardStep, WizardController.stepExcuses);

      // Step 4: Omluvenky — Pokročilé is collapsed by default; fill signature and Continue.
      expect(find.byKey(const Key('tpl:late_income_excuses:0:name')), findsNothing);
      await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('draft:wiz:signature')),
            matching: find.byType(TextField),
          ),
          'Jan Novák');
      await tester.tap(find.widgetWithText(FilledButton, Strings.get('wiz_next')));
      await tester.pumpAndSettle();
      if (s.wizardStep == WizardController.stepPhone) {
        await tester.tap(find.text(Strings.get('wiz_skip')));
        await tester.pumpAndSettle();
      }
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
      expect(saved['gemini_model'], 'gemini-3.8-flash');
      expect(saved['gemini_auto_enabled'], isTrue);
      expect(saved['gemini_prompt'], 'custom prompt');
      expect(saved['gemini_interval_days'], 5);
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
      await tester.tap(find.byKey(const Key('wiz:excuses_advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tpl_group:late_income_excuses')));
      await tester.pumpAndSettle();

      final nameField = find.byKey(const Key('tpl:late_income_excuses:0:name'));
      final textField = find.byKey(const Key('tpl:late_income_excuses:0:text'));
      expect(nameField, findsOneWidget);
      expect(textField, findsOneWidget);

      await tester.enterText(nameField, 'Lékař');
      await tester.enterText(textField, 'První řádek\nDruhý řádek\nS pozdravem');
      await tester.pump();

      final nextBtn = find.widgetWithText(FilledButton, Strings.get('wiz_next'));
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
      await tester.tap(find.byKey(const Key('wiz:excuses_advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tpl_group:late_income_excuses')));
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
        await tester.tap(find.byKey(const Key('wiz:excuses_advanced')));
        await tester.pumpAndSettle();

        expect(find.text('${Strings.get('tpl_late')} · 2'), findsOneWidget);
        expect(find.text('${Strings.get('tpl_soon')} · 2'), findsOneWidget);
        expect(find.text('${Strings.get('tpl_short')} · 2'), findsOneWidget);
        expect(find.text('${Strings.get('tpl_long')} · 2'), findsOneWidget);

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
      await tester.tap(find.byKey(const Key('tpl_group:late_income_excuses')));
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

    testWidgets(
        'M1: newly added row and name-only row survive AppState rebuilds in wizard',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(configData: {
        'language': 'cs',
        'disclaimer_accepted': true,
        'your_signature': 'Jan Novák',
        'late_income_excuses': [
          {'name': 'Doprava', 'text': 'Zpoždění'},
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
      await tester.tap(find.byKey(const Key('wiz:excuses_advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tpl_group:late_income_excuses')));
      await tester.pumpAndSettle();

      // (1) Tap + Přidat, trigger AppState rebuild, verify new row remains.
      await tester.tap(find.text('+ ${Strings.get('add')}').first);
      await tester.pumpAndSettle();
      s.onChanged();
      await tester.pump();

      final newName = find.byKey(const Key('tpl:late_income_excuses:1:name'));
      final newText = find.byKey(const Key('tpl:late_income_excuses:1:text'));
      expect(newName, findsOneWidget);
      expect(newText, findsOneWidget);

      // (2) Type a name only, unfocus, trigger AppState rebuild, verify typed name remains.
      await tester.enterText(newName, 'Lékař');
      await tester.pump();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      s.onChanged();
      await tester.pump();

      expect(newName, findsOneWidget);
      expect(tester.widget<TextField>(newName).controller!.text, 'Lékař');

      // Fill text and save it.
      await tester.enterText(newText, 'Návštěva lékaře');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(s.get('late_income_excuses'), [
        {'name': 'Doprava', 'text': 'Zpoždění'},
        {'name': 'Lékař', 'text': 'Návštěva lékaře'},
      ]);
    });
  });

  group('B7 adapted wizard finish refresh snackbar', () {
    Widget routerApp(AppState s) {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark()),
            ),
          ),
          GoRoute(
            path: '/today',
            builder: (_, _) => const Scaffold(body: SizedBox.shrink()),
          ),
        ],
      );
      return ProviderScope(
        key: ObjectKey(s),
        overrides: [
          appStateProvider.overrideWith(() => _SeededAppStateController(s)),
        ],
        child: MaterialApp.router(routerConfig: router),
      );
    }

    testWidgets(
        'pressing Finish when idle starts refresh with wiz_finishing_refresh snackbar',
        (tester) async {
      Strings.lang = 'cs';
      final s = AppState(configData: {'tutorials_enabled': false});
      var spawned = 0;
      s.spawn = (_, _) => spawned++;
      s.wizardStep = WizardController.stepDone;

      await tester.pumpWidget(routerApp(s));
      await tester.pump();

      await tester.tap(find.text(Strings.get('wiz_finish')));
      await tester.pump();

      expect(spawned, 1);
      expect(find.text(Strings.get('wiz_finishing_refresh')), findsOneWidget);
      expect(find.text(Strings.get('already_running')), findsNothing);
    });

    testWidgets(
        'pressing Finish when a refresh flight is already running shows already_running snackbar',
        (tester) async {
      Strings.lang = 'cs';
      final s = AppState(configData: {'tutorials_enabled': false});
      var spawned = 0;
      s.spawn = (_, _) => spawned++;
      s.wizardStep = WizardController.stepDone;
      expect(s.claimFlight('refresh_running'), isTrue);

      await tester.pumpWidget(routerApp(s));
      await tester.pump();

      await tester.tap(find.text(Strings.get('wiz_finish')));
      await tester.pump();

      expect(spawned, 0);
      expect(find.text(Strings.get('already_running')), findsOneWidget);
    });
  });

  group('B8 wizard draft field sync', () {
    testWidgets(
        'moving from Bakalari step to Strava step does not reuse username/password text across shared child slots',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      Strings.lang = 'cs';
      final s = AppState(configData: {
        'tutorials_enabled': false,
        'bakalari_url': 'https://baka.example.cz',
        'bakalari_username': 'baka_user',
        'use_strava': true,
        'strava_username': 'strava_user',
      });
      s.wizardStep = WizardController.stepBakalari;

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

      expect(find.widgetWithText(TextField, 'baka_user'), findsOneWidget);

      // Step forward from Bakalari to Strava without changing drafts: slots 3
      // and 4 in the step column are both _DraftField in both steps.
      s.wizardStep = WizardController.stepStrava;
      s.onChanged();
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'strava_user'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'baka_user'), findsNothing);
    });

    testWidgets(
        'updating config updates unfocused _DraftField when initial changes',
        (tester) async {
      tester.view.physicalSize = const Size(1920, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      Strings.lang = 'cs';
      final s = AppState(configData: {
        'tutorials_enabled': false,
        'bakalari_url': 'https://old.example.cz',
      });
      s.wizardStep = WizardController.stepBakalari;

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

      expect(
        find.widgetWithText(TextField, 'https://old.example.cz'),
        findsOneWidget,
      );

      s.config.set('bakalari_url', 'https://new.example.cz');
      s.onChanged();
      await tester.pump();

      expect(
        find.widgetWithText(TextField, 'https://new.example.cz'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(TextField, 'https://old.example.cz'),
        findsNothing,
      );
    });
  });

  group('P1 adapted wizard disclaimer wording & welcome gating', () {
    testWidgets('uses neutral device wording on mobile in cs and en and gates Continue on ack',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final wasMobile = Strings.isMobile;
      final savedLang = Strings.lang;
      addTearDown(() {
        Strings.isMobile = wasMobile;
        Strings.lang = savedLang;
      });
      Strings.isMobile = false;

      for (final lang in ['cs', 'en']) {
        setEnvironmentOverride({
          'STRAKALARI_DATA_DIR': tmp.path,
          'STRAKALARI_NO_KEYRING': '1',
          'FLET_PLATFORM': 'android',
        });
        final s = AppState(configData: {'language': lang});
        s.wizardStep = WizardController.stepWelcome;

        await tester.pumpWidget(
          ProviderScope(
            key: ValueKey('p1:$lang'),
            overrides: [
              appStateProvider.overrideWith(() => _SeededAppStateController(s)),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(Strings.isMobile, isTrue, reason: 'lang=$lang');
        expect(find.byType(WelcomeLogo), findsOneWidget);
        if (lang == 'cs') {
          expect(find.textContaining('počítači'), findsNothing);
          expect(find.textContaining('zařízení'), findsOneWidget);
        } else {
          expect(find.textContaining('computer'), findsNothing);
          expect(find.textContaining('device'), findsOneWidget);
        }

        final nextFinder =
            find.widgetWithText(FilledButton, Strings.get('wiz_next'));
        expect(tester.widget<FilledButton>(nextFinder).onPressed, isNull);
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        expect(tester.widget<FilledButton>(nextFinder).onPressed, isNotNull);
      }
    });
  });

  group('P2 wizard password show/hide toggle', () {
    testWidgets('Bakalari and Strava password fields toggle obscureText',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(configData: {'use_strava': true});
      for (final (step, draftKey) in [
        (WizardController.stepBakalari, 'wiz:bakalari_password'),
        (WizardController.stepStrava, 'wiz:strava_password'),
      ]) {
        s.wizardStep = step;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appStateProvider.overrideWith(() => _SeededAppStateController(s)),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
              ),
            ),
          ),
        );
        await tester.pump();

        final fieldFinder = find.descendant(
          of: find.byKey(ValueKey('draft:$draftKey')),
          matching: find.byType(TextField),
        );
        expect(fieldFinder, findsOneWidget, reason: draftKey);
        expect(tester.widget<TextField>(fieldFinder).obscureText, isTrue);

        final eyeFinder = find.descendant(
          of: find.byKey(ValueKey('draft:$draftKey')),
          matching: find.byIcon(Icons.visibility_outlined),
        );
        expect(eyeFinder, findsOneWidget, reason: draftKey);

        await tester.tap(eyeFinder);
        await tester.pump();

        expect(tester.widget<TextField>(fieldFinder).obscureText, isFalse);
        expect(
          find.descendant(
            of: find.byKey(ValueKey('draft:$draftKey')),
            matching: find.byIcon(Icons.visibility_off_outlined),
          ),
          findsOneWidget,
        );

        await tester.tap(find.descendant(
          of: find.byKey(ValueKey('draft:$draftKey')),
          matching: find.byIcon(Icons.visibility_off_outlined),
        ));
        await tester.pump();

        expect(tester.widget<TextField>(fieldFinder).obscureText, isTrue);
      }
    });
  });

  group('P3 adapted wizard navigation reachability', () {
    testWidgets(
        'Continue and Back stay inside the viewport without scrolling a long step',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      Strings.lang = 'cs';
      final s = AppState();
      s.wizardStep = WizardController.stepExcuses;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const Key('wiz:excuses_advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tpl_group:late_income_excuses')));
      await tester.pumpAndSettle();

      final nextBtn =
          find.widgetWithText(FilledButton, Strings.get('wiz_next'));
      final backBtn =
          find.widgetWithText(TextButton, Strings.get('wiz_back'));
      expect(nextBtn, findsOneWidget);
      expect(backBtn, findsOneWidget);

      expect(tester.getRect(nextBtn).bottom, lessThanOrEqualTo(844));
      expect(tester.getRect(backBtn).bottom, lessThanOrEqualTo(844));

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('draft:wiz:signature')),
          matching: find.byType(TextField),
        ),
        'Jan Novák',
      );
      await tester.pump();

      await tester.tap(nextBtn);
      await tester.pumpAndSettle();
      expect(s.wizardStep, WizardController.stepDone);

      await tester.tap(find.widgetWithText(TextButton, Strings.get('wiz_back')));
      await tester.pumpAndSettle();
      expect(s.wizardStep, WizardController.stepExcuses);
    });
  });

  group('P4 adapted wizard switch thumb contrast', () {
    testWidgets(
        'enabled switches use switchTheme so thumb contrasts with track in both themes',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      for (final tok in [darkTokens, lightTokens]) {
        final s = AppState(configData: {
          'theme': tok.mode,
          'use_strava': true,
          'wakeup_enabled': true,
        });

        for (final step in [
          WizardController.stepStrava,
          WizardController.stepPhone,
        ]) {
          s.wizardStep = step;
          await tester.pumpWidget(
            ProviderScope(
              key: ValueKey('${tok.mode}_$step'),
              overrides: [
                appStateProvider
                    .overrideWith(() => _SeededAppStateController(s)),
              ],
              child: MaterialApp(
                theme: lightTokens.toThemeData(),
                darkTheme: darkTokens.toThemeData(),
                themeMode:
                    tok.mode == 'light' ? ThemeMode.light : ThemeMode.dark,
                themeAnimationStyle: AnimationStyle.noAnimation,
                home: Scaffold(
                  body: LiveWizardView(tokens: tok, narrow: true),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          final primaryTitle = step == WizardController.stepStrava
              ? Strings.get('use_strava')
              : Strings.get('wakeup_enable');
          final tileFinder = find.widgetWithText(SwitchListTile, primaryTitle);
          expect(tileFinder, findsOneWidget, reason: '${tok.mode}/step=$step');
          final tile = tester.widget<SwitchListTile>(tileFinder);
          expect(tile.value, isTrue, reason: '${tok.mode}/step=$step');

          final swFinder = find.byType(Switch);
          final swCount = tester.widgetList<Switch>(swFinder).length;
          expect(
            swCount,
            step == WizardController.stepStrava ? 2 : 1,
            reason: '${tok.mode}/step=$step',
          );
          for (var i = 0; i < swCount; i++) {
            final nthFinder = swFinder.at(i);
            final sw = tester.widget<Switch>(nthFinder);
            final ctx = tester.element(nthFinder);
            final theme = SwitchTheme.of(ctx);
            final selected = {WidgetState.selected};
            final track = sw.trackColor?.resolve(selected) ??
                sw.activeTrackColor ??
                theme.trackColor?.resolve(selected);
            final thumb = sw.thumbColor?.resolve(selected) ??
                sw.activeThumbColor ??
                theme.thumbColor?.resolve(selected);

            expect(track, equals(tok.accent),
                reason: '${tok.mode}/step=$step/sw=$i');
            expect(thumb, isNotNull, reason: '${tok.mode}/step=$step/sw=$i');
            expect(thumb, isNot(equals(track)),
                reason:
                    '${tok.mode}/step=$step/sw=$i thumb must differ from track');
          }
        }
      }
    });
  });

  group('F1 Škola step', () {
    testWidgets(
        'GEKOM shows no category line, writes only school_preset_id, and Skip writes nothing',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      final s = AppState(configData: {'language': 'cs'});
      s.wizardStep = WizardController.stepSchool;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('GEKOM'), findsOneWidget);
      expect(find.text(Strings.get('wiz_cal_custom')), findsOneWidget);
      expect(find.byType(RadioListTile<String>), findsNothing);

      // Continue is disabled until a school is picked.
      final nextFinder =
          find.widgetWithText(FilledButton, Strings.get('wiz_next'));
      expect(tester.widget<FilledButton>(nextFinder).onPressed, isNull);

      // Skipping writes nothing and advances.
      await tester.tap(find.text(Strings.get('wiz_skip')));
      await tester.pumpAndSettle();
      expect(s.wizardStep, WizardController.stepBakalari);
      expect(s.get('school_preset_id'), 'custom');

      // Go back, pick GEKOM, continue -> writes only school_preset_id.
      await tester.tap(find.text(Strings.get('wiz_back')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('school:GEKOM')));
      await tester.pump();
      expect(find.text(Strings.get('wiz_school_preset_p')), findsOneWidget);
      expect(find.byType(RadioListTile<String>), findsNothing);
      expect(tester.widget<FilledButton>(nextFinder).onPressed, isNotNull);

      final beforeCfg = Map<String, Object?>.of(s.config.data);
      await tester.tap(nextFinder);
      await tester.pump();

      expect(s.wizardStep, WizardController.stepBakalari);
      expect(s.get('school_preset_id'), 'gekom_2026_2027');
      for (final k in beforeCfg.keys) {
        if (k == 'school_preset_id' || k == 'wizard_step') continue;
        expect(s.config.data[k], beforeCfg[k], reason: 'key $k must not change');
      }
    });

    testWidgets(
        'multi-preset school shows category radio list once picked and requires a preset choice',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      final saved = <String, Object?>{};
      final c = WizardController(
        config: {'language': 'cs'},
        onSave: (u) {
          saved.addAll(u);
          return true;
        },
      )
        ..step = WizardController.stepSchool
        ..schoolOptions = const [
          (
            name: 'Gymnázium XY',
            presets: [
              (id: 'xy_1', title: 'Gymnázium XY 1', category: '1. ročník'),
              (id: 'xy_4', title: 'Gymnázium XY 4', category: 'Maturitní'),
            ],
          ),
        ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WizardView(controller: c, tokens: AppTokens.dark(), narrow: true),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(RadioListTile<String>), findsNothing);
      await tester.tap(find.byKey(const ValueKey('school:Gymnázium XY')));
      await tester.pump();

      expect(find.byType(RadioListTile<String>), findsNWidgets(2));
      expect(find.text('1. ročník'), findsOneWidget);
      expect(find.text('Maturitní'), findsOneWidget);
      final nextFinder =
          find.widgetWithText(FilledButton, Strings.get('wiz_next'));
      expect(tester.widget<FilledButton>(nextFinder).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('preset:xy_4')));
      await tester.pump();
      expect(tester.widget<FilledButton>(nextFinder).onPressed, isNotNull);

      await tester.tap(nextFinder);
      await tester.pump();
      expect(saved, {'school_preset_id': 'xy_4'});
    });

    test('resumed wizard keeps saved school picked and writes nothing new on Continue',
        () {
      final first = AppState()..wizardOpened();
      first.save({
        'disclaimer_accepted': true,
        'school_preset_id': 'gekom_2026_2027',
      });
      first.wizardGoto(WizardController.stepBakalari, WizardController.stepDone);

      final restarted = AppState();
      expect(restarted.wizardStep, WizardController.stepSchool);
      final c = wizardControllerFor(restarted);
      expect(c.calPreset(), 'gekom_2026_2027');
      expect(c.selectedSchoolGroup(), 'GEKOM');
      expect(c.nextEnabled, isTrue);

      final cfgFile = File('${tmp.path}/config.json');
      final beforeJson = cfgFile.readAsStringSync();
      final res = c.pressNext();
      expect(res.advanced, isTrue);
      expect(restarted.wizardStep, WizardController.stepBakalari);
      // Only wizard_step may update on Continue; school_preset_id is not rewritten.
      expect(cfgFile.readAsStringSync().contains('"school_preset_id": "gekom_2026_2027"'),
          isTrue);
      final savedOnContinue = <String, Object?>{};
      final cNoWrite = WizardController(
        config: Map<String, Object?>.of(restarted.config.data),
        onSave: (u) {
          savedOnContinue.addAll(u);
          return true;
        },
      )
        ..step = WizardController.stepSchool
        ..schoolOptions = schoolGroups('cs')
        ..drafts.addAll(restarted.drafts);
      expect(cNoWrite.pressNext().advanced, isTrue);
      expect(savedOnContinue, isEmpty);
      expect(beforeJson, isNotEmpty);

      // Fresh install with no saved step still requires an explicit pick.
      final freshDir = Directory.systemTemp.createTempSync('strakalari_fresh_');
      addTearDown(() => freshDir.deleteSync(recursive: true));
      setEnvironmentOverride(
          {'STRAKALARI_DATA_DIR': freshDir.path, 'STRAKALARI_NO_KEYRING': '1'});
      final fresh = AppState();
      final cFresh = wizardControllerFor(fresh);
      expect(cFresh.calPreset(), isEmpty);
      expect(cFresh.nextEnabled, isFalse);
    });

    test(
        'reopened wizard after finishing without logins keeps saved real preset picked',
        () {
      final first = AppState()..wizardOpened();
      first.save({
        'disclaimer_accepted': true,
        'school_preset_id': 'gekom_2026_2027',
      });
      first.wizardGoto(WizardController.stepDone, WizardController.stepDone);
      first.wizardFinished();

      final cfgFile = File('${tmp.path}/config.json');
      final beforeCfg = cfgFile.readAsStringSync();

      final again = AppState();
      expect(again.needsSetup(), isTrue);
      expect(again.wizardStep, WizardController.stepWelcome);
      expect(cfgFile.readAsStringSync(), beforeCfg);

      again.wizardOpened();
      final c = wizardControllerFor(again);
      expect(c.calPreset(), 'gekom_2026_2027');
      expect(c.selectedSchoolGroup(), 'GEKOM');
      c.step = WizardController.stepSchool;
      expect(c.nextEnabled, isTrue);

      // Explicitly picking Jiná škola is not overwritten by wizardOpened().
      c.selectSchoolGroup(customId);
      again.wizardOpened();
      expect(wizardControllerFor(again).calPreset(), customId);
    });

    test(
        'stale school draft is not seeded when no wizard is open (R3 M3)',
        () {
      AppState().save({
        'disclaimer_accepted': true,
        'school_preset_id': 'gekom_2026_2027',
        'bakalari_url': 'http://127.0.0.1:18080',
        'bakalari_username': 'demo',
      });
      final s = AppState();
      expect(s.needsSetup(), isFalse);
      s.save({'school_preset_id': 'custom'});
      s.save({'bakalari_username': ''});
      expect(s.needsSetup(), isTrue);
      s.wizardOpened();
      final c = wizardControllerFor(s)..step = WizardController.stepSchool;
      expect(c.calPreset(), isNot('gekom_2026_2027'));
      c.pressNext();
      expect(s.config.get('school_preset_id', ''), 'custom');
    });
  });

  group('F1 login prefills', () {
    testWidgets(
        'GEKOM hides Bakaláři URL and Strava canteen when config is empty or equals preset, config override wins, custom shows both',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      // 1. GEKOM with empty config: hides address/canteen rows and Change button,
      // and passing fake testConnection saves the preset URL and canteen.
      final saved = <String, Object?>{};
      late final WizardController c;
      c = WizardController(
        config: {
          'language': 'cs',
          'school_preset_id': 'gekom_2026_2027',
          'use_strava': true,
        },
        onSave: (u) {
          saved.addAll(u);
          return true;
        },
        onTestRequest: (service, overrides) {
          c.recordTestResult(service, true, 'ok');
          c.consumeAutoAdvance(c.step, service);
        },
      )..step = WizardController.stepBakalari;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WizardView(controller: c, tokens: AppTokens.dark(), narrow: true),
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('bakaweb.gekom.cz'), findsNothing);
      expect(find.text('Změnit'), findsNothing);
      expect(find.text(Strings.get('wiz_bakalari_p_preset')), findsOneWidget);
      expect(find.text(Strings.get('wiz_bakalari_p')), findsNothing);
      expect(find.byKey(const ValueKey('draft:wiz:bakalari_url')), findsNothing);

      await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('draft:wiz:bakalari_username')),
            matching: find.byType(TextField),
          ),
          'jan');
      await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('draft:wiz:bakalari_password')),
            matching: find.byType(TextField),
          ),
          'heslo');
      await tester.tap(
          find.widgetWithText(FilledButton, Strings.get('wiz_test_continue')));
      await tester.pump();

      expect(saved['bakalari_url'], 'https://bakaweb.gekom.cz');
      expect(saved['bakalari_username'], 'jan');
      expect(c.step, WizardController.stepStrava);

      // Strava step hides canteen row and Change button; saves preset canteen 1950.
      expect(find.textContaining('1950'), findsNothing);
      expect(find.text('Změnit'), findsNothing);
      expect(find.byKey(const Key('wiz:change_strava_canteen')), findsNothing);
      expect(find.text(Strings.get('wiz_strava_p_preset')), findsOneWidget);
      expect(find.text(Strings.get('wiz_strava_p')), findsNothing);
      expect(find.byKey(const ValueKey('draft:wiz:strava_canteen_id')), findsNothing);

      await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('draft:wiz:strava_username')),
            matching: find.byType(TextField),
          ),
          'jan.s');
      await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('draft:wiz:strava_password')),
            matching: find.byType(TextField),
          ),
          'heslo2');
      await tester.tap(
          find.widgetWithText(FilledButton, Strings.get('wiz_test_continue')));
      await tester.pump();

      expect(saved['strava_canteen_id'], '1950');
      expect(saved['strava_username'], 'jan.s');
      expect(c.step, WizardController.stepExcuses);

      // 2. Resumed wizard whose saved config equals the preset hides both fields too.
      final cResumedPreset = WizardController(
        config: {
          'language': 'cs',
          'school_preset_id': 'gekom_2026_2027',
          'bakalari_url': 'https://bakaweb.gekom.cz',
          'use_strava': true,
          'strava_canteen_id': '1950',
        },
        onSave: (_) => true,
      )..step = WizardController.stepBakalari;
      expect(cResumedPreset.showBakalariUrlField, isFalse);
      expect(cResumedPreset.showStravaCanteenField, isFalse);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WizardView(
                key: const ValueKey('wiz_resumed_preset'),
                controller: cResumedPreset,
                tokens: AppTokens.dark(),
                narrow: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft:wiz:bakalari_url')), findsNothing);
      expect(find.textContaining('bakaweb.gekom.cz'), findsNothing);
      expect(find.text(Strings.get('wiz_bakalari_p_preset')), findsOneWidget);

      cResumedPreset.step = WizardController.stepStrava;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      cResumedPreset.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft:wiz:strava_canteen_id')), findsNothing);
      expect(find.textContaining('1950'), findsNothing);
      expect(find.text(Strings.get('wiz_strava_p_preset')), findsOneWidget);

      // 3. Existing config value differing from preset wins and shows the field.
      final cExisting = WizardController(
        config: {
          'school_preset_id': 'gekom_2026_2027',
          'bakalari_url': 'https://custom.school.cz',
          'strava_canteen_id': '9999',
        },
        onSave: (_) => true,
      );
      expect(cExisting.showBakalariUrlField, isTrue);
      expect(cExisting.effectiveBakalariUrl(), 'https://custom.school.cz');
      expect(cExisting.showStravaCanteenField, isTrue);
      expect(cExisting.effectiveCanteenId(), '9999');

      // 4. Jiná škola (custom) shows both fields and uses the full copy.
      final cCustom = WizardController(
        config: {'school_preset_id': 'custom', 'use_strava': true},
        onSave: (_) => true,
      )..step = WizardController.stepBakalari;
      expect(cCustom.presetBakalariUrl(), '');
      expect(cCustom.presetCanteenId(), '');
      expect(cCustom.showBakalariUrlField, isTrue);
      expect(cCustom.showStravaCanteenField, isTrue);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WizardView(
                key: const ValueKey('wiz_custom'),
                controller: cCustom,
                tokens: AppTokens.dark(),
                narrow: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft:wiz:bakalari_url')), findsOneWidget);
      expect(find.text(Strings.get('wiz_bakalari_p')), findsOneWidget);
      expect(find.text(Strings.get('wiz_bakalari_p_preset')), findsNothing);

      cCustom.step = WizardController.stepStrava;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      cCustom.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('draft:wiz:strava_canteen_id')), findsOneWidget);
      expect(find.text(Strings.get('wiz_strava_p')), findsOneWidget);
      expect(find.text(Strings.get('wiz_strava_p_preset')), findsNothing);
    });

    testWidgets(
        'clearing typed address after switching custom -> GEKOM uses preset URL on rebuild (R3 M4 path 1)',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      final s = AppState(configData: {
        'language': 'cs',
        'disclaimer_accepted': true,
      });
      s.wizardStep = WizardController.stepSchool;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('school:custom')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('wiz:next_btn')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('draft:wiz:bakalari_url')),
          matching: find.byType(TextField),
        ),
        'http://127.0.0.1:18080',
      );
      await tester.pump();

      await tester.tap(find.byKey(const Key('wiz:back_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('school:GEKOM')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('wiz:next_btn')));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('draft:wiz:bakalari_url')),
          matching: find.byType(TextField),
        ),
        '',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('draft:wiz:bakalari_username')),
          matching: find.byType(TextField),
        ),
        'jan',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('draft:wiz:bakalari_password')),
          matching: find.byType(TextField),
        ),
        'heslo',
      );
      s.onChanged();
      await tester.pump();

      expect(find.byKey(const ValueKey('draft:wiz:bakalari_url')), findsNothing);
      await tester.tap(
          find.widgetWithText(FilledButton, Strings.get('wiz_test_continue')));
      await tester.pump();

      expect(find.text(Strings.get('wiz_need_bakalari')), findsNothing);
      expect(s.testing, 'bakalari');
      expect(
        wizardControllerFor(s).effectiveBakalariUrl(),
        'https://bakaweb.gekom.cz',
      );
    });

    testWidgets(
        'erasing address under custom before switching to GEKOM uses preset URL (R3 M4 path 2)',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      final s = AppState(configData: {
        'language': 'cs',
        'disclaimer_accepted': true,
      });
      s.wizardStep = WizardController.stepSchool;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('school:custom')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('wiz:next_btn')));
      await tester.pumpAndSettle();

      final urlField = find.descendant(
        of: find.byKey(const ValueKey('draft:wiz:bakalari_url')),
        matching: find.byType(TextField),
      );
      await tester.enterText(urlField, 'http://127.0.0.1:18080');
      await tester.pump();
      await tester.enterText(urlField, '');
      await tester.pump();

      await tester.tap(find.byKey(const Key('wiz:back_btn')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('school:GEKOM')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('wiz:next_btn')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('draft:wiz:bakalari_url')), findsNothing);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('draft:wiz:bakalari_username')),
          matching: find.byType(TextField),
        ),
        'jan',
      );
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('draft:wiz:bakalari_password')),
          matching: find.byType(TextField),
        ),
        'heslo',
      );
      await tester.tap(
          find.widgetWithText(FilledButton, Strings.get('wiz_test_continue')));
      await tester.pump();

      expect(find.text(Strings.get('wiz_need_bakalari')), findsNothing);
      expect(s.testing, 'bakalari');
      expect(
        wizardControllerFor(s).effectiveBakalariUrl(),
        'https://bakaweb.gekom.cz',
      );
    });

    test(
        'clearing Strava canteen after switching custom -> GEKOM falls back to preset canteen while custom/override stay empty (R3 M4)',
        () {
      final c = WizardController(
        config: {'use_strava': true},
        onSave: (_) => true,
      )..schoolOptions = schoolGroups('cs');

      c.selectSchoolGroup(customId);
      c.setDraftSilent('wiz:strava_canteen_id', '1234');
      expect(c.effectiveCanteenId(), '1234');

      c.selectSchoolPreset('gekom_2026_2027');
      expect(c.showStravaCanteenField, isTrue);

      c.setDraftSilent('wiz:strava_canteen_id', '');
      expect(c.showStravaCanteenField, isFalse);
      expect(c.effectiveCanteenId(), '1950');

      // Clearing under Jiná škola or an own config override still means empty.
      c.selectSchoolGroup(customId);
      expect(c.showStravaCanteenField, isTrue);
      expect(c.effectiveCanteenId(), '');

      final cOverride = WizardController(
        config: {
          'school_preset_id': 'gekom_2026_2027',
          'bakalari_url': 'http://127.0.0.1:18080',
        },
        onSave: (_) => true,
      );
      cOverride.setDraftSilent('wiz:bakalari_url', '');
      expect(cOverride.showBakalariUrlField, isTrue);
      expect(cOverride.effectiveBakalariUrl(), '');
    });
  });

  group('F1 Telefon step', () {
    testWidgets(
        'embeds WakeupCard (no background switch), saves wakeup_enabled immediately and wakeup_minutes_before on Continue without duplicate permission prompt',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      var permissionCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidChannel.channel, (call) async {
        if (call.method == 'requestNotificationPermission') {
          permissionCalls++;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidChannel.channel, null);
      });

      final s = AppState(configData: {'language': 'cs'});
      s.wizardStep = WizardController.stepPhone;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(WakeupCard), findsOneWidget);
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(find.text(Strings.get('wakeup_enable')), findsOneWidget);
      expect(find.text(Strings.get('wakeup_minutes')), findsOneWidget);
      expect(find.text(Strings.get('run_in_background')), findsNothing);

      // Toggle alarm on inside WakeupCard -> saves immediately and asks permission once.
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(s.get('wakeup_enabled'), isTrue);
      expect(s.notificationPermissionAsked, isTrue);
      expect(permissionCalls, 1);
      expect(find.text(Strings.get('wakeup_none')), findsOneWidget);

      // Type new minutes and press Continue while field is still focused ->
      // unfocus saves wakeup_minutes_before and advances without asking permission again.
      await tester.enterText(find.byType(TextField), '30');
      await tester.tap(
          find.widgetWithText(FilledButton, Strings.get('wiz_next')));
      await tester.pumpAndSettle();

      expect(s.get('wakeup_minutes_before'), 30);
      expect(permissionCalls, 1);
      expect(s.wizardStep, WizardController.stepDone);
    });

    testWidgets(
        'O5 WakeupCard shows permission prompts and next alarm preview, and preserves B9 when leaving alarm off',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      final permissionCompleter = Completer<void>();
      var permissionCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidChannel.channel, (call) async {
        if (call.method == 'requestNotificationPermission') {
          permissionCalls++;
          await permissionCompleter.future;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidChannel.channel, null);
      });

      final now = DateTime(2026, 10, 12, 12, 0);
      final s = AppState(
        configData: {
          'language': 'cs',
          'wakeup_enabled': true,
          'wakeup_minutes_before': 60,
          'school_preset_id': 'custom',
          'user_free_days': <Object?>[],
          'holidays': <Object?>[],
        },
        data: {
          'timetable': {
            '13.10.2026': [
              {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'},
            ],
          },
        },
      );
      s.demoMode = false;
      s.wakeupAvailableOverride = true;
      s.wizardStep = WizardController.stepPhone;

      final fakePhone = WakeupPhone(
        notificationsEnabled: false,
        exactAlarmsAllowed: false,
        nextAlarm: () => s.nextWakeupAlarm(now),
        skippedDays: () => const [],
        openSystemAlarm: (h, m, message, {int? weekday}) async => true,
        requestNotificationPermission: () {},
        openNotificationSettings: () {},
        openExactAlarmSettings: () {},
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(
                tokens: AppTokens.dark(),
                narrow: true,
                wakeupPhone: fakePhone,
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text(Strings.get('wakeup_notif_off')), findsOneWidget);
      expect(find.text(Strings.get('notif_allow')), findsOneWidget);
      expect(find.text(Strings.get('wakeup_exact_off')), findsOneWidget);
      expect(find.text(Strings.get('wakeup_exact_allow')), findsOneWidget);
      expect(find.textContaining('07:00'), findsOneWidget);
      expect(find.textContaining('Matematika'), findsOneWidget);

      // Separate B9 check: leaving alarm OFF and pressing Continue still asks
      // notification permission and waits until answered before advancing.
      final sOff = AppState(configData: {'language': 'cs'});
      sOff.wizardStep = WizardController.stepPhone;
      await tester.pumpWidget(
        ProviderScope(
          key: const ValueKey('b9_scope'),
          overrides: [
            appStateProvider
                .overrideWith(() => _SeededAppStateController(sOff)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(
          find.widgetWithText(FilledButton, Strings.get('wiz_next')));
      await tester.pump();

      expect(permissionCalls, 1);
      expect(sOff.notificationPermissionAsked, isTrue);
      expect(sOff.wizardStep, WizardController.stepPhone);

      permissionCompleter.complete();
      await tester.pumpAndSettle();
      expect(sOff.wizardStep, WizardController.stepDone);
    });

    testWidgets('Skip on Telefon saves nothing and asks no permission',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      var permissionCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidChannel.channel, (call) async {
        if (call.method == 'requestNotificationPermission') permissionCalls++;
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(AndroidChannel.channel, null);
      });

      final s = AppState(configData: {'language': 'cs'});
      s.wizardStep = WizardController.stepPhone;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text(Strings.get('wiz_skip')));
      await tester.pumpAndSettle();

      expect(permissionCalls, 0);
      expect(s.notificationPermissionAsked, isFalse);
      expect(s.get('wakeup_enabled'), isFalse);
      expect(s.wizardStep, WizardController.stepDone);
    });
  });

  group('F1 phone wizard layout', () {
    testWidgets(
        'no Card, pinned bottom bar without wrapping at 390px on every step and above IME',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      final s = AppState(configData: {
        'language': 'cs',
        'school_preset_id': 'gekom_2026_2027',
        'use_strava': true,
      });
      final ctrl = WizardController(config: s.config.data)..isAndroid = true;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WizardView(
              controller: ctrl,
              tokens: AppTokens.dark(),
              narrow: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No card wrapper on phone; LinearProgressIndicator in pinned header.
      expect(find.byType(Card), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      for (var step = 0; step <= WizardController.stepDone; step++) {
        ctrl.step = step;
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        ctrl.notifyListeners();
        await tester.pumpAndSettle();

        // Scroll long content if scrollable and verify bottom bar stays fixed at bottom.
        if (step == WizardController.stepExcuses) {
          await tester.tap(find.byKey(const Key('wiz:excuses_advanced')));
          await tester.pumpAndSettle();
          final scrollable = find.byType(Scrollable).first;
          await tester.drag(scrollable, const Offset(0, -400));
          await tester.pump();
        }

        final barRect = tester.getRect(find.byKey(const Key('wiz:bottom_bar')));
        expect(barRect.bottom, closeTo(844.0, 1.0),
            reason: 'step $step bottom bar must pin to bottom');
        expect(barRect.right, lessThanOrEqualTo(390.0));

        final nextRect = tester.getRect(find.byKey(const Key('wiz:next_btn')));
        expect(nextRect.right, lessThanOrEqualTo(390.0));
        expect(nextRect.bottom, lessThanOrEqualTo(844.0));

        if (step > 0) {
          final backRect = tester.getRect(find.byKey(const Key('wiz:back_btn')));
          expect((backRect.center.dy - nextRect.center.dy).abs(), lessThan(4.0),
              reason: 'step $step Back and Next must sit on one row');
        }
        if (step < WizardController.stepDone && ctrl.canSkip) {
          final skipRect = tester.getRect(find.byKey(const Key('wiz:skip_btn')));
          expect((skipRect.center.dy - nextRect.center.dy).abs(), lessThan(4.0),
              reason: 'step $step Skip and Next must sit on one row');
          expect(tester.getRect(find.byKey(const Key('wiz:back_btn'))).right,
              lessThanOrEqualTo(skipRect.left));
          expect(skipRect.right, lessThanOrEqualTo(nextRect.left));
        }
      }

      // Simulated keyboard on Bakaláři keeps bottom bar above 300 px IME inset.
      ctrl.step = WizardController.stepBakalari;
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      ctrl.notifyListeners();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            viewInsets: EdgeInsets.only(bottom: 300),
          ),
          child: MaterialApp(
            home: Scaffold(
              body: WizardView(
                controller: ctrl,
                tokens: AppTokens.dark(),
                narrow: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final imeBarRect = tester.getRect(find.byKey(const Key('wiz:bottom_bar')));
      expect(imeBarRect.bottom, lessThanOrEqualTo(544.5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('AnimatedSwitcher uses 250 ms and respects disableAnimations',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final ctrl = WizardController(config: {'language': 'cs'});

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WizardView(
              controller: ctrl,
              tokens: AppTokens.dark(),
              narrow: true,
            ),
          ),
        ),
      );
      final switcher =
          tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher));
      expect(switcher.duration, const Duration(milliseconds: 250));

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            disableAnimations: true,
          ),
          child: MaterialApp(
            home: Scaffold(
              body: WizardView(
                controller: ctrl,
                tokens: AppTokens.dark(),
                narrow: true,
              ),
            ),
          ),
        ),
      );
      final staticSwitcher =
          tester.widget<AnimatedSwitcher>(find.byType(AnimatedSwitcher));
      expect(staticSwitcher.duration, Duration.zero);
    });
  });

  testWidgets(
      'F1b saved disclaimer can be unticked and re-ticked without withdrawing saved acceptance (R3b code S3)',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    Strings.lang = 'cs';

    final s = AppState(configData: {
      'language': 'cs',
      'disclaimer_accepted': true,
    });
    s.wizardStep = WizardController.stepWelcome;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => _SeededAppStateController(s)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boxFinder = find.byType(CheckboxListTile);
    final nextFinder = find.widgetWithText(
      FilledButton,
      Strings.get('wiz_next'),
    );

    // Starts ticked and Continue enabled when disclaimer_accepted is saved.
    expect(tester.widget<CheckboxListTile>(boxFinder).value, isTrue);
    expect(tester.widget<FilledButton>(nextFinder).onPressed, isNotNull);

    // First tap unticks it, disables Continue, and leaves saved acceptance true.
    await tester.tap(boxFinder);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(boxFinder).value, isFalse);
    expect(tester.widget<FilledButton>(nextFinder).onPressed, isNull);
    expect(s.config.get('disclaimer_accepted', false), isTrue);

    // Second tap ticks it again and re-enables Continue.
    await tester.tap(boxFinder);
    await tester.pump();
    expect(tester.widget<CheckboxListTile>(boxFinder).value, isTrue);
    expect(tester.widget<FilledButton>(nextFinder).onPressed, isNotNull);
  });

  group('F1c O6 early setup refresh in wizard', () {
    test(
        'verified Bakalari login starts early refresh once per fingerprint, skips on unchanged Back+Continue, re-triggers on changed credentials, ignores failed login',
        () {
      final s = AppState(configData: {
        'language': 'cs',
        'school_preset_id': 'gekom_2026_2027',
      });
      var spawnCount = 0;
      s.spawn = (fn, name) {
        spawnCount++;
        // Release the refresh flight immediately so a second call would start
        // if not deduplicated by wizardEarlyRefreshedFp.
        s.releaseFlight('refresh_running');
        s.refreshRunning = false;
        s.earlyRefreshInFlight = false;
      };

      final c1 = wizardControllerFor(s);
      c1.step = WizardController.stepBakalari;
      c1.setDraftSilent('wiz:bakalari_username', 'demo');
      c1.setDraftSilent('wiz:bakalari_password', 'secret');

      // Failed login test does NOT trigger early refresh.
      c1.testing = 'bakalari';
      c1.recordTestResult('bakalari', false, 'bad login');
      expect(spawnCount, 0);
      expect(s.wizardEarlyRefreshedFp, isNull);

      // Successful login test triggers early refresh once.
      c1.testing = 'bakalari';
      c1.recordTestResult('bakalari', true, 'ok');
      c1.consumeAutoAdvance(c1.step, 'bakalari');
      expect(spawnCount, 1);
      expect(s.wizardEarlyRefreshedFp, isNotNull);
      expect(c1.step, WizardController.stepStrava);

      // Going Back and pressing Continue with unchanged credentials does NOT re-run.
      c1.pressBack();
      expect(c1.step, WizardController.stepBakalari);
      final c2 = wizardControllerFor(s);
      c2.step = WizardController.stepBakalari;
      c2.pressNext();
      expect(spawnCount, 1);
      expect(c2.step, WizardController.stepStrava);

      // Changing credentials and re-verifying triggers a new early refresh once.
      final c3 = wizardControllerFor(s);
      c3.step = WizardController.stepBakalari;
      c3.setDraftSilent('wiz:bakalari_username', 'demo2');
      c3.testing = 'bakalari';
      c3.recordTestResult('bakalari', true, 'ok');
      expect(spawnCount, 2);
    });

    test('failed early refresh does not block wizard navigation', () {
      final s = AppState(configData: {
        'language': 'cs',
        'school_preset_id': 'gekom_2026_2027',
      });
      s.spawn = (fn, name) {
        // Simulate an immediate refresh failure.
        s.reportError('refresh (bakalari)', Exception('network down'));
        s.finishRun(DateTime(2026, 11, 19, 10, 0), 'bakalari', false, 'network down');
      };

      final c = wizardControllerFor(s);
      c.step = WizardController.stepBakalari;
      c.setDraftSilent('wiz:bakalari_username', 'demo');
      c.setDraftSilent('wiz:bakalari_password', 'secret');
      c.testing = 'bakalari';
      c.recordTestResult('bakalari', true, 'ok');
      expect(c.consumeAutoAdvance(c.step, 'bakalari'), isTrue);
      expect(c.step, WizardController.stepStrava);

      // Wizard still advances freely through the rest of the steps.
      c.pressSkip();
      expect(c.step, WizardController.stepExcuses);
    });

    test(
        'Dokoncit while early refresh is in flight returns wiz_finishing_refresh and queues full run; non-early busy still returns already_running',
        () {
      Strings.lang = 'cs';
      final s = AppState(configData: {'language': 'cs'});
      s.spawn = (fn, name) {};

      // Early refresh in flight.
      expect(s.startRefresh('bakalari', true), isTrue);
      expect(s.earlyRefreshInFlight, isTrue);

      final c = wizardControllerFor(s);
      c.step = WizardController.stepDone;
      final res = c.pressNext();
      expect(res.finishedMessage, Strings.get('wiz_finishing_refresh'));
      expect(s.pendingFullRefresh, isTrue);

      // Non-early refresh in flight -> B7 already_running.
      final s2 = AppState(configData: {'language': 'cs'});
      s2.spawn = (fn, name) {};
      expect(s2.startRefresh('all'), isTrue);
      expect(s2.earlyRefreshInFlight, isFalse);

      final c2 = wizardControllerFor(s2);
      c2.step = WizardController.stepDone;
      final res2 = c2.pressNext();
      expect(res2.finishedMessage, Strings.get('already_running'));
    });
  });

  group('O9 wizard Strava automatic ordering toggle', () {
    Widget pumpStravaStep(AppState s, {String lang = 'cs'}) {
      Strings.lang = lang;
      final tok = AppTokens.dark();
      return ProviderScope(
        key: ObjectKey(s),
        overrides: [
          appStateProvider.overrideWith(() => _SeededAppStateController(s)),
        ],
        child: MaterialApp(
          theme: tok.toThemeData(),
          home: Scaffold(
            body: LiveWizardView(tokens: tok, narrow: true),
          ),
        ),
      );
    }

    testWidgets(
        'defaults OFF, Cancel keeps confirm, Confirm saves auto, OFF resets confirm, use_strava OFF hides toggle',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final savedLang = Strings.lang;
      addTearDown(() => Strings.lang = savedLang);

      // 1. Starts OFF (confirm mode) and Cancel leaves it OFF without writing 'auto'.
      final sCancel = AppState(configData: {
        'language': 'en',
        'use_strava': true,
        'school_preset_id': 'gekom_2026_2027',
      })
        ..wizardStep = WizardController.stepStrava;
      await tester.pumpWidget(pumpStravaStep(sCancel, lang: 'en'));
      await tester.pumpAndSettle();

      final autoSwitchFinder = find.byKey(const Key('wiz:strava_auto_order'));
      expect(autoSwitchFinder, findsOneWidget);
      expect(tester.widget<SwitchListTile>(autoSwitchFinder).value, isFalse);
      expect(find.text(Strings.get('wiz_strava_auto_order_hint')),
          findsOneWidget);

      await tester.ensureVisible(autoSwitchFinder);
      await tester.tap(autoSwitchFinder);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text(Strings.get('auto_confirm_title_lunch')), findsOneWidget);

      await tester.tap(find.text(Strings.get('cancel')));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(autoSwitchFinder).value, isFalse);
      expect(sCancel.get('strava_order_mode'), 'confirm');
      expect(sCancel.drafts['wiz:strava_order_mode'], isNull);

      // 2. Confirm turns switch ON, keeps across rebuild, saves 'auto', and toggling OFF resets to 'confirm'.
      final sAuto = AppState(configData: {
        'language': 'cs',
        'use_strava': true,
        'school_preset_id': 'gekom_2026_2027',
        'strava_username': 'novak',
      })
        ..wizardStep = WizardController.stepStrava
        ..drafts['wiz:strava_password'] = 'secret';
      sAuto.wizardVerified['strava'] =
          wizardControllerFor(sAuto).fingerprintFor('strava');
      await tester.pumpWidget(pumpStravaStep(sAuto, lang: 'cs'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(autoSwitchFinder);
      await tester.tap(autoSwitchFinder);
      await tester.pumpAndSettle();
      await tester.tap(find.text(Strings.get('auto_confirm_ok')));
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(autoSwitchFinder).value, isTrue);

      // Rebuild from sAuto preserves 'auto' via draft.
      final cRebuild = wizardControllerFor(sAuto);
      expect(cRebuild.stravaAutoOrder, isTrue);
      expect(cRebuild.stravaOrderMode, 'auto');

      // Save step with Continue -> 'auto' persisted to config.
      await tester.tap(find.byKey(const Key('wiz:next_btn')));
      await tester.pumpAndSettle();
      expect(sAuto.get('strava_order_mode'), 'auto');
      expect(sAuto.wizardStep, WizardController.stepExcuses);

      // Navigate back and toggle OFF without dialog -> saves 'confirm'.
      await tester.tap(find.byKey(const Key('wiz:back_btn')));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(autoSwitchFinder).value, isTrue);

      await tester.ensureVisible(autoSwitchFinder);
      await tester.tap(autoSwitchFinder);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.widget<SwitchListTile>(autoSwitchFinder).value, isFalse);

      await tester.tap(find.byKey(const Key('wiz:next_btn')));
      await tester.pumpAndSettle();
      expect(sAuto.get('strava_order_mode'), 'confirm');

      // 3. Turning use_strava OFF hides wiz:strava_auto_order and preserves strava_order_mode config.
      await tester.tap(find.byKey(const Key('wiz:back_btn')));
      await tester.pumpAndSettle();
      sAuto.save({'strava_order_mode': 'auto'});
      await tester.tap(
          find.widgetWithText(SwitchListTile, Strings.get('use_strava')));
      await tester.pumpAndSettle();
      expect(autoSwitchFinder, findsNothing);
      await tester.tap(find.byKey(const Key('wiz:next_btn')));
      await tester.pumpAndSettle();
      expect(sAuto.get('use_strava'), isFalse);
      expect(sAuto.get('strava_order_mode'), 'auto');
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
