import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/wizard/wizard_controller.dart';
import 'package:app/features/wizard/wizard_live.dart';
import 'package:app/features/wizard/wizard_view.dart';
import 'package:app/shell/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

Widget _app(Widget child) {
  return MaterialApp(
    theme: tokensFor('dark').toThemeData(),
    home: Scaffold(body: child),
  );
}

void main() {
  late Directory tmp;
  final tokens = AppTokens.dark();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_wizard_full_test_');
    core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    core.setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Wizard setup credentials and validation', () {
    test('testNeedsSetupFreshAndDismiss', () {
      final state = AppState();
      expect(state.needsSetup(), isTrue);
      state.dismissWizard();
      expect(state.needsSetup(), isFalse);
    });

    test('testNeedsSetupFalseWithBakalari', () {
      final state = AppState(configData: {
        'bakalari_url': 'https://skola.bakalari.cz',
        'bakalari_username': 'novak',
        'bakalari_password': 'x',
      });
      expect(state.needsSetup(), isFalse);
    });

    test('testBakalariStepValidation', () {
      final saved = <String, Object?>{};
      final c = WizardController(
        config: {},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
      );
      expect(c.saveBakalari(), isFalse);
      c.setDraft('wiz:bakalari_url', 'https://skola.bakalari.cz');
      c.setDraft('wiz:bakalari_username', 'novak');
      expect(c.saveBakalari(), isFalse);
      c.setDraft('wiz:bakalari_password', 'secret');
      expect(c.saveBakalari(), isTrue);
      expect(saved['bakalari_username'], equals('novak'));
    });

    test('testStravaDisabledSkipsCredentials', () {
      final saved = <String, Object?>{};
      final c = WizardController(
        config: {},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
      );
      c.setStravaEnabled(false);
      expect(c.saveStrava(), isTrue);
      expect(saved['use_strava'], isFalse);
    });

    test('testStravaEnabledRequiresFields', () {
      final saved = <String, Object?>{};
      final c = WizardController(
        config: {},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
      );
      c.setStravaEnabled(true);
      expect(c.saveStrava(), isFalse);
      c.setDraft('wiz:strava_username', 'jidelna');
      c.setDraft('wiz:strava_password', 'pw');
      c.setDraft('wiz:strava_canteen_id', '123');
      expect(c.saveStrava(), isTrue);
      expect(saved['use_strava'], isTrue);
    });

    test('testNoSkipWhereNothingMayBeSkipped', () {
      final c = WizardController(
        config: {},
        onSave: (_) => true,
      );
      c.goTo(WizardController.stepWelcome);
      expect(c.canSkip, isFalse);
      c.goTo(WizardController.stepDone);
      expect(c.canSkip, isFalse);
      c.goTo(WizardController.stepSchool);
      expect(c.canSkip, isTrue);
      c.goTo(WizardController.stepBakalari);
      expect(c.canSkip, isTrue);
    });
  });

  group('School, signature, and step order', () {
    test('testCalendarStepRequiresExplicitPick', () {
      final saved = <String, Object?>{};
      final c = WizardController(
        config: {},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
      )..calendarOptions = buildCalendarPresets('cs');
      expect(c.calPreset(), isEmpty);
      expect(c.saveCalendar(), isFalse);
      c.setDraft('wiz:cal_preset', 'gekom_2026_2027');
      expect(c.saveCalendar(), isTrue);
      expect(saved['school_preset_id'], equals('gekom_2026_2027'));
      expect(saved.containsKey('sem1_close'), isFalse);
      c.setDraft('wiz:cal_preset', 'custom');
      expect(c.saveCalendar(), isTrue);
      expect(saved['school_preset_id'], equals('custom'));
    });

    test('testExcusesStepRequiresSignature', () {
      final saved = <String, Object?>{};
      final c = WizardController(
        config: {'your_signature': ''},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
      );
      expect(c.saveSignature(), isFalse);
      c.setDraft('wiz:signature', '  Jan Novák  ');
      expect(c.saveSignature(), isTrue);
      expect(saved['your_signature'], equals('Jan Novák'));
    });

    test('testCalendarPresetLinesTotal', () {
      final presets = buildCalendarPresets('cs');
      final gekom = presets.firstWhere((p) => p.id == 'gekom_2026_2027');
      expect(gekom.totalDays, equals(30));
      final sumGroups = gekom.groups.fold<int>(0, (acc, g) => acc + g.count);
      expect(sumGroups, equals(30));
      expect(gekom.groups.any((g) => g.label == 'Vánoční prázdniny' && g.count == 12), isTrue);
    });
  });

  group('Setup pending and scheduler lifecycle', () {
    test('testSetupPendingFreshAndMidWizard', () {
      final state = AppState();
      expect(state.setupPending, isTrue);

      state.save({
        'bakalari_url': 'https://skola.bakalari.cz',
        'bakalari_username': 'novak',
        'bakalari_password': 'secret',
      });
      expect(state.needsSetup(), isFalse);
      state.wizardShown = true;
      expect(state.setupPending, isTrue);

      state.wizardFinished();
      expect(state.setupPending, isFalse);
    });

    test('testSetupPendingDismissReleases', () {
      final state = AppState();
      expect(state.setupPending, isTrue);
      state.dismissWizard();
      expect(state.setupPending, isFalse);
    });

    test('testSetupPendingFalseWithCredentialsNeverShown', () {
      final state = AppState(configData: {
        'bakalari_url': 'https://skola.bakalari.cz',
        'bakalari_username': 'novak',
        'bakalari_password': 'x',
      });
      expect(state.wizardShown, isFalse);
      expect(state.setupPending, isFalse);
    });

    test('testRefreshWorkerAbortsWithoutCredentials', () async {
      final state = AppState();
      state.spawn = (job, name) async {
        await job();
      };
      expect(state.demoMode, isTrue);
      expect(core.hasValidCredentials(state.config.data).$1, isFalse);
      state.startRefresh('all');
      expect(state.refreshRunning, isFalse);
      expect(state.errorDialogPending, isFalse);
      expect(state.lastError, isNull);
      expect(state.runs.isNotEmpty, isTrue);
      expect(state.runs.last['ok'], isFalse);
      expect(state.runs.last['detail'], contains('missing credentials'));
    });
  });

  group('Step sequence and Android phone step', () {
    test('testStepOrder', () {
      expect(WizardController.stepWelcome, equals(0));
      expect(WizardController.stepSchool, equals(1));
      expect(WizardController.stepBakalari, equals(2));
      expect(WizardController.stepStrava, equals(3));
      expect(WizardController.stepExcuses, equals(4));
      expect(WizardController.stepPhone, equals(5));
      expect(WizardController.stepDone, equals(6));
      expect(WizardController.stepsTotal, equals(7));
    });

    test('testPhoneStepOnlyOnAndroid', () {
      final cDesktop = WizardController(config: {}, onSave: (_) => true)
        ..isAndroid = false;
      expect(cDesktop.shownSteps(), equals([0, 1, 2, 3, 4, 6]));
      expect(cDesktop.stepAfter(WizardController.stepExcuses), equals(WizardController.stepDone));
      expect(cDesktop.stepBefore(WizardController.stepDone), equals(WizardController.stepExcuses));

      final cAndroid = WizardController(config: {}, onSave: (_) => true)
        ..isAndroid = true;
      expect(cAndroid.shownSteps(), equals([0, 1, 2, 3, 4, 5, 6]));
      expect(cAndroid.stepAfter(WizardController.stepExcuses), equals(WizardController.stepPhone));
      expect(cAndroid.stepBefore(WizardController.stepDone), equals(WizardController.stepPhone));
    });

    test('testAlarmStepSavesTheAlarm', () {
      final saved = <String, Object?>{};
      var askedPermission = false;
      final c = WizardController(
        config: {},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
        onAlarmPermission: () {
          askedPermission = true;
        },
      );
      // Off by default: Continue saves false, no permission asked
      expect(c.saveAlarm(), isTrue);
      expect(saved['wakeup_enabled'], isFalse);
      expect(askedPermission, isFalse);

      c.setAlarmEnabled(true);
      c.setDraft('wiz:wakeup_minutes', 'abc');
      expect(c.saveAlarm(), isFalse); // not a valid number
      expect(saved['wakeup_enabled'], isFalse);

      c.setDraft('wiz:wakeup_minutes', '45');
      expect(c.saveAlarm(), isTrue);
      expect(saved['wakeup_enabled'], isTrue);
      expect(saved['wakeup_minutes_before'], equals(45));
      expect(askedPermission, isTrue);
    });
  });

  group('Connection testing and verification in wizard', () {
    test('testReadyHelpersUseDrafts', () {
      final c = WizardController(config: {}, onSave: (_) => true);
      expect(c.readyBakalari(), isFalse);
      c.setDraft('wiz:bakalari_url', 'https://skola.bakalari.cz');
      c.setDraft('wiz:bakalari_username', 'novak');
      c.setDraft('wiz:bakalari_password', 'secret');
      expect(c.readyBakalari(), isTrue);

      expect(c.readyStrava(), isFalse);
      c.setStravaEnabled(false);
      expect(c.readyStrava(), isTrue);
    });

    test('testFingerprintChangesOnEdit', () {
      final c = WizardController(config: {}, onSave: (_) => true);
      c.setDraft('wiz:bakalari_url', 'https://a.bakalari.cz');
      c.setDraft('wiz:bakalari_username', 'novak');
      c.setDraft('wiz:bakalari_password', 'one');
      final before = c.fingerprintFor('bakalari');
      c.setDraft('wiz:bakalari_password', 'two');
      expect(c.fingerprintFor('bakalari'), isNot(equals(before)));
    });

    test('testBeginTestSuccessSavesAndAdvances', () {
      final saved = <String, Object?>{};
      final verified = <String, String>{};
      late final WizardController c;
      c = WizardController(
        config: {},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
        onTestRequest: (service, overrides) {
          c.recordTestResult(service, true, 'ok');
          c.consumeAutoAdvance(c.step, service);
        },
        onVerified: (service, fp) {
          verified[service] = fp;
        },
      );
      c.step = WizardController.stepBakalari;
      c.setDraft('wiz:bakalari_url', 'https://skola.bakalari.cz');
      c.setDraft('wiz:bakalari_username', 'novak');
      c.setDraft('wiz:bakalari_password', 'secret');

      c.pressNext();
      expect(c.step, equals(WizardController.stepBakalari + 1));
      expect(c.verified['bakalari'], equals(c.fingerprintFor('bakalari')));
      expect(saved['bakalari_username'], equals('novak'));
    });

    test('testBeginTestFailureStaysPut', () {
      final saved = <String, Object?>{};
      late final WizardController c;
      c = WizardController(
        config: {},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
        onTestRequest: (service, overrides) {
          c.recordTestResult(service, false, 'bad password');
          c.consumeAutoAdvance(c.step, service);
        },
      );
      c.step = WizardController.stepBakalari;
      c.setDraft('wiz:bakalari_url', 'https://skola.bakalari.cz');
      c.setDraft('wiz:bakalari_username', 'novak');
      c.setDraft('wiz:bakalari_password', 'wrong');

      c.pressNext();
      expect(c.step, equals(WizardController.stepBakalari));
      expect(c.verified.containsKey('bakalari'), isFalse);
    });

    test('testDisclaimerMustBeAcknowledged', () {
      final saved = <String, Object?>{};
      final c = WizardController(
        config: {},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
      );
      c.step = WizardController.stepWelcome;
      expect(c.disclaimerOk, isFalse);
      expect(c.nextEnabled, isFalse);
      c.setDisclaimer(false);
      expect(c.disclaimerOk, isFalse);
      c.setDisclaimer(true);
      expect(c.disclaimerOk, isTrue);
      expect(c.nextEnabled, isTrue);

      final cWithSaved = WizardController(
        config: {'disclaimer_accepted': true},
        onSave: (_) => true,
      );
      expect(cWithSaved.disclaimerOk, isTrue);
    });

    for (var step = 0; step < WizardController.stepsTotal; step++) {
      testWidgets('testWizardBuildsHeadlessStep$step', (tester) async {
        // The test engine's block font (Ahem) is much wider than the real
        // one, so the button row can report a RenderFlex overflow that the
        // shipped fonts do not have. Only that message is ignored.
        final previousHandler = FlutterError.onError;
        FlutterError.onError = (details) {
          if (details.exceptionAsString().contains('overflowed')) return;
          previousHandler?.call(details);
        };
        addTearDown(() => FlutterError.onError = previousHandler);
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });

        final c = WizardController(
          config: {},
          onSave: (_) => true,
        )
          ..calendarOptions = buildCalendarPresets('cs')
          ..step = step;
        await tester.pumpWidget(_app(
          WizardView(controller: c, tokens: tokens),
        ));
        await tester.pumpAndSettle();
        expect(find.byType(WizardView), findsOneWidget);
      });
    }
  });
}
