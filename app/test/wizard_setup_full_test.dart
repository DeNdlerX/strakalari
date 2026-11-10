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
    core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
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

    test('testAiOptional', () {
      final c = WizardController(
        config: {},
        onSave: (_) => true,
      );
      c.setAiEnabled(false);
      expect(c.saveAi(), isTrue);
      c.setAiEnabled(true);
      expect(c.saveAi(), isFalse);
      c.setDraft('wiz:ai_key', 'AIza-test');
      expect(c.saveAi(), isTrue);
    });

    test('testWizardGotoClampsAndFinishClears', () {
      final c = WizardController(
        config: {},
        onSave: (_) => true,
      );
      c.goTo(99);
      expect(c.step, equals(WizardController.stepDone));
      c.goTo(-3);
      expect(c.step, equals(0));
      c.setDraft('wiz:bakalari_username', 'novak');
      expect(c.draft('wiz:bakalari_username'), equals('novak'));
      c.finishWizard();
      expect(c.dismissed, isTrue);
      expect(c.draft('wiz:bakalari_username'), isEmpty);
    });

    test('testSkipMovesOneStepOnly', () {
      final saved = <String, Object?>{};
      final c = WizardController(
        config: {},
        onSave: (updates) {
          saved.addAll(updates);
          return true;
        },
      );
      c.goTo(WizardController.stepBakalari);
      c.pressSkip();
      expect(c.step, equals(WizardController.stepBakalari + 1));
      expect(c.dismissed, isFalse);
      expect(saved.containsKey('bakalari_username'), isFalse);
    });

    test('testNoSkipWhereNothingMayBeSkipped', () {
      final c = WizardController(
        config: {},
        onSave: (_) => true,
      );
      c.goTo(WizardController.stepWelcome);
      expect(c.canSkip, isFalse);
      c.goTo(WizardController.stepDisclaimer);
      expect(c.canSkip, isFalse);
      c.goTo(WizardController.stepDone);
      expect(c.canSkip, isFalse);
      c.goTo(WizardController.stepBakalari);
      expect(c.canSkip, isTrue);
    });
  });

  group('Calendar, limits, and signature steps', () {
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

    test('testLimitsStepUpdates', () {
      final c = WizardController(
        config: {
          'subject_limits': {'Fyzika': 20.0, 'Dějepis': 30.0},
          'absence_critical_pct': 25.0,
        },
        onSave: (_) => true,
      );
      c.limitSubjectsInput = ['Matematika', 'Fyzika'];
      c.setDraft('wiz:limit:Matematika', '30,5');
      c.setDraft('wiz:limit:Fyzika', '');
      final updates = c.limitsUpdates();
      expect(updates, isNotNull);
      final limits = updates!['subject_limits'] as Map<String, double>;
      expect(limits['Matematika'], equals(30.5));
      expect(limits['Dějepis'], equals(30.0));
      expect(limits.containsKey('Fyzika'), isFalse);

      for (final bad in ['abc', '150', '-1']) {
        c.setDraft('wiz:limit:Matematika', bad);
        expect(c.limitsUpdates(), isNull);
      }
    });

    test('testLimitsStepLoadsSubjectsOnce', () {
      final c = WizardController(
        config: {},
        onSave: (_) => true,
      );
      c.step = WizardController.stepLimits;
      expect(c.limitsNeedsRefresh, isFalse); // no credentials yet

      c.hasCredentials = true;
      expect(c.limitsNeedsRefresh, isTrue); // creds present, no subjects
      c.markLimitsRefreshStarted();
      expect(c.limitsNeedsRefresh, isFalse); // started once, never triggers again
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

  group('Step sequence and Android alarm', () {
    test('testStepOrder', () {
      expect(WizardController.stepDisclaimer < WizardController.stepBakalari, isTrue);
      expect(WizardController.stepBakalari < WizardController.stepLimits, isTrue);
      expect(WizardController.stepLimits < WizardController.stepStrava, isTrue);
      expect(WizardController.stepStrava < WizardController.stepAi, isTrue);
      expect(WizardController.stepAi < WizardController.stepCalendar, isTrue);
      expect(WizardController.stepCalendar < WizardController.stepAlarm, isTrue);
      expect(WizardController.stepAlarm < WizardController.stepExcuses, isTrue);
      expect(WizardController.stepExcuses < WizardController.stepDone, isTrue);
      expect(WizardController.stepsTotal, equals(WizardController.stepDone + 1));
    });

    test('testAlarmStepOnlyOnAndroid', () {
      final cDesktop = WizardController(config: {}, onSave: (_) => true)
        ..isAndroid = false;
      expect(cDesktop.shownSteps().contains(WizardController.stepAlarm), isFalse);
      expect(cDesktop.stepAfter(WizardController.stepCalendar), equals(WizardController.stepExcuses));
      expect(cDesktop.stepBefore(WizardController.stepExcuses), equals(WizardController.stepCalendar));
      expect(cDesktop.shownSteps().length, equals(WizardController.stepsTotal - 1));

      final cAndroid = WizardController(config: {}, onSave: (_) => true)
        ..isAndroid = true;
      expect(cAndroid.shownSteps().contains(WizardController.stepAlarm), isTrue);
      expect(cAndroid.stepAfter(WizardController.stepCalendar), equals(WizardController.stepAlarm));
      expect(cAndroid.stepBefore(WizardController.stepExcuses), equals(WizardController.stepAlarm));
      expect(cAndroid.shownSteps().length, equals(WizardController.stepsTotal));
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

      expect(c.readyAi(), isTrue); // disabled by default
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
      c.step = WizardController.stepDisclaimer;
      expect(c.disclaimerOk, isFalse);
      c.setDisclaimer(false);
      expect(c.disclaimerOk, isFalse);
      c.setDisclaimer(true);
      expect(c.disclaimerOk, isTrue);

      final cWithSaved = WizardController(
        config: {'disclaimer_accepted': true},
        onSave: (_) => true,
      );
      expect(cWithSaved.disclaimerOk, isTrue);
    });

    for (var step = 0; step < WizardController.stepsTotal; step++) {
      testWidgets('testWizardBuildsHeadlessStep$step', (tester) async {
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
