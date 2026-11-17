import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/settings/settings_live.dart';
import 'package:app/features/today/today_controller.dart';
import 'package:app/features/wizard/wizard_controller.dart';
import 'package:app/features/wizard/wizard_live.dart';
import 'package:app/features/wizard/wizard_view.dart';
import 'package:app/l10n/strings.dart';
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
      await tester.pump();

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
            find.widgetWithText(ElevatedButton, Strings.get('wiz_next'));
        expect(tester.widget<ElevatedButton>(nextFinder).onPressed, isNull);
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        expect(tester.widget<ElevatedButton>(nextFinder).onPressed, isNotNull);
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

      final nextBtn =
          find.widgetWithText(ElevatedButton, Strings.get('wiz_next'));
      final backBtn =
          find.widgetWithText(TextButton, Strings.get('wiz_back'));
      expect(nextBtn, findsOneWidget);
      expect(backBtn, findsOneWidget);

      expect(tester.getRect(nextBtn).bottom, lessThanOrEqualTo(844));
      expect(tester.getRect(backBtn).bottom, lessThanOrEqualTo(844));

      await tester.tap(backBtn);
      await tester.pump();
      expect(s.wizardStep, WizardController.stepStrava);
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
          await tester.pump();

          final tileFinder = find.byType(SwitchListTile);
          expect(tileFinder, findsOneWidget, reason: '${tok.mode}/step=$step');
          final tile = tester.widget<SwitchListTile>(tileFinder);
          expect(tile.value, isTrue, reason: '${tok.mode}/step=$step');

          final swFinder = find.byType(Switch);
          final sw = tester.widget<Switch>(swFinder);
          final ctx = tester.element(swFinder);
          final theme = SwitchTheme.of(ctx);
          final selected = {WidgetState.selected};
          final track = sw.trackColor?.resolve(selected) ??
              sw.activeTrackColor ??
              theme.trackColor?.resolve(selected);
          final thumb = sw.thumbColor?.resolve(selected) ??
              sw.activeThumbColor ??
              theme.thumbColor?.resolve(selected);

          expect(track, equals(tok.accent), reason: '${tok.mode}/step=$step');
          expect(thumb, isNotNull, reason: '${tok.mode}/step=$step');
          expect(thumb, isNot(equals(track)),
              reason: '${tok.mode}/step=$step thumb must differ from track');
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
          find.widgetWithText(ElevatedButton, Strings.get('wiz_next'));
      expect(tester.widget<ElevatedButton>(nextFinder).onPressed, isNull);

      // Skipping writes nothing and advances.
      await tester.tap(find.text(Strings.get('wiz_skip')));
      await tester.pump();
      expect(s.wizardStep, WizardController.stepBakalari);
      expect(s.get('school_preset_id'), 'custom');

      // Go back, pick GEKOM, continue -> writes only school_preset_id.
      await tester.tap(find.text(Strings.get('wiz_back')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('school:GEKOM')));
      await tester.pump();
      expect(find.text(Strings.get('wiz_school_preset_p')), findsOneWidget);
      expect(find.byType(RadioListTile<String>), findsNothing);
      expect(tester.widget<ElevatedButton>(nextFinder).onPressed, isNotNull);

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
          find.widgetWithText(ElevatedButton, Strings.get('wiz_next'));
      expect(tester.widget<ElevatedButton>(nextFinder).onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('preset:xy_4')));
      await tester.pump();
      expect(tester.widget<ElevatedButton>(nextFinder).onPressed, isNotNull);

      await tester.tap(nextFinder);
      await tester.pump();
      expect(saved, {'school_preset_id': 'xy_4'});
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
