import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/features/settings/settings_live.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/tutorial/tours.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_settings_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('settingsControllerFor bridges config, drafts, section and cache clear',
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
    s.setDraft('acc:bakalari_username', 'novak2');
    s.setSettingsSection('limits');

    final c = settingsControllerFor(s);
    expect(c.settingsSection, 'limits');
    expect(c.settingsOpen, isTrue);
    expect(c.draft('acc:bakalari_username'), 'novak2');
    expect((c.get('absence') as Map)['Matematika'], 10.0);

    // Saving through SettingsController persists into AppState.config.
    expect(c.saveQuiet({'absence_critical_pct': 30.0}), isTrue);
    expect(s.get('absence_critical_pct'), 30.0);

    // Section navigation delegates back to AppState.
    c.setSettingsSection('diagnostics');
    expect(s.settingsSection, 'diagnostics');
    c.closeSettingsSection();
    expect(s.settingsOpen, isFalse);

    // Clear cache removes data_cache.json and reloads AppState.
    final cache = File(resolvePath(cacheFile));
    cache.writeAsStringSync('{"absence":{"Matematika":10.0}}');
    expect(c.clearCache(), isTrue);
    expect(cache.existsSync(), isFalse);
  });

  testWidgets('LiveSettingsView renders and offers settings tutorial',
      (tester) async {
    final s = AppState(
      configData: {
        'tutorials_enabled': true,
        'tutorials_done': [firstTourId],
      },
      data: {
        'absence': {'Matematika': 10.0},
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => _SeededAppStateController(s)),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: LiveSettingsView(),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SettingsView), findsOneWidget);
    expect(s.tutorial?.$1, 'settings');
  });

  // Checkpoint B BR-M2: the real screen builds a new SettingsController on
  // every rebuild, so the cancel/dry-run answer must reach the dropdown there.
  for (final entry in {
    'excuse_mode': 'rule:excuse_mode',
    'strava_order_mode': 'rule:order_mode',
  }.entries) {
    for (final answer in ['cancel', 'dry_run']) {
      testWidgets(
          'live screen: ${entry.key} picker shows the saved mode after $answer',
          (tester) async {
        final s = AppState(configData: {
          entry.key: 'confirm',
          'your_signature': 'Novak',
          'tutorials_enabled': false,
        });
        s.setSettingsSection('rules');
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              appStateProvider
                  .overrideWith(() => _SeededAppStateController(s)),
            ],
            child: const MaterialApp(
              home: Scaffold(body: LiveSettingsView()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final dd = find.byKey(Key(entry.value));
        await tester.ensureVisible(dd);
        await tester.tap(dd);
        await tester.pumpAndSettle();
        await tester.tap(find.text(Strings.get('mode_auto')).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text(Strings.get(
            answer == 'cancel' ? 'cancel' : 'auto_confirm_dry')));
        await tester.pumpAndSettle();
        final saved = answer == 'cancel' ? 'confirm' : 'dry_run';
        expect(s.get(entry.key), saved);
        expect(
            find.descendant(
                of: dd, matching: find.text(Strings.get('mode_$saved'))),
            findsOneWidget);
        expect(
            find.descendant(
                of: dd, matching: find.text(Strings.get('mode_auto'))),
            findsNothing);
      });
    }
  }
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
