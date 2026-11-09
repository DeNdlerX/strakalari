import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
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
