import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/wizard/wizard_controller.dart';
import 'package:app/features/wizard/wizard_live.dart';
import 'package:app/features/wizard/wizard_view.dart';

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
