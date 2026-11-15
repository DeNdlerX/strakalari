import 'dart:convert';
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
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
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

  group('B2 template editor', () {
    testWidgets('saves typed name and text on focus loss without + Přidat or Delete',
        (tester) async {
      final s = AppState(configData: {
        'tutorials_enabled': false,
        'late_income_excuses': ['Původní text'],
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

      final nameField = find.byKey(const Key('tpl:late_income_excuses:0:name'));
      final textField = find.byKey(const Key('tpl:late_income_excuses:0:text'));
      await tester.enterText(nameField, 'Lékař');
      await tester.enterText(textField, 'Dobrý den,\nomluvte prosím příchod.');
      await tester.pump();

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      final saved = jsonDecode(
          File(s.config.configPath).readAsStringSync()) as Map<String, dynamic>;
      expect(saved['late_income_excuses'], [
        {'name': 'Lékař', 'text': 'Dobrý den,\nomluvte prosím příchod.'},
      ]);
    });

    testWidgets('saves typed text when leaving the screen without blurring first',
        (tester) async {
      final s = AppState(configData: {
        'tutorials_enabled': false,
        'short_absence_excuses': [
          {'name': 'Rodina', 'text': 'Starý text'},
        ],
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

      final textField =
          find.byKey(const Key('tpl:short_absence_excuses:0:text'));
      await tester.scrollUntilVisible(
        textField,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(textField);
      await tester.pump();
      await tester.tap(textField);
      await tester.pump();
      await tester.enterText(textField, 'Nový text omluvenky');
      await tester.pump();

      // Navigate away without explicitly blurring the focused TextField.
      s.closeSettingsSection();
      await tester.pumpAndSettle();

      final saved = jsonDecode(
          File(s.config.configPath).readAsStringSync()) as Map<String, dynamic>;
      expect(saved['short_absence_excuses'], [
        {'name': 'Rodina', 'text': 'Nový text omluvenky'},
      ]);
    });

    testWidgets('keeps controller identity and cursor across rebuilds and disposes on unmount',
        (tester) async {
      final s = AppState(configData: {
        'tutorials_enabled': false,
        'late_income_excuses': [
          {'name': 'Doprava', 'text': 'Pozdní příchod vlakem'},
        ],
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
      final nameFinder = find.byKey(const Key('tpl:late_income_excuses:0:name'));
      await tester.tap(textFinder);
      await tester.pump();

      final textCtrl = tester.widget<TextField>(textFinder).controller!;
      final nameCtrl = tester.widget<TextField>(nameFinder).controller!;
      textCtrl.selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();

      // Trigger a full UI rebuild via AppState.
      s.onChanged();
      await tester.pump();

      expect(identical(tester.widget<TextField>(textFinder).controller, textCtrl),
          isTrue);
      expect(tester.widget<TextField>(textFinder).controller!.selection,
          const TextSelection.collapsed(offset: 6));

      // Leave the section; controllers must be disposed.
      s.closeSettingsSection();
      await tester.pumpAndSettle();
      expect(() => textCtrl.addListener(() {}), throwsFlutterError);
      expect(() => nameCtrl.addListener(() {}), throwsFlutterError);
    });

    testWidgets('name and text fields do not overlap at 390 px and text field grows with lines',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(configData: {
        'tutorials_enabled': false,
        'late_income_excuses': [
          {'name': 'Doprava', 'text': 'Krátký text'},
        ],
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

      final nameFinder = find.byKey(const Key('tpl:late_income_excuses:0:name'));
      final textFinder = find.byKey(const Key('tpl:late_income_excuses:0:text'));
      final nameRect = tester.getRect(nameFinder);
      final textRect1 = tester.getRect(textFinder);
      expect(textRect1.top - nameRect.bottom, greaterThanOrEqualTo(8.0));

      final textWidget = tester.widget<TextField>(textFinder);
      expect(textWidget.minLines, greaterThanOrEqualTo(2));
      expect(textWidget.maxLines, isNull);

      await tester.enterText(
          textFinder, 'Řádek 1\nŘádek 2\nŘádek 3\nŘádek 4\nŘádek 5');
      await tester.pumpAndSettle();
      final textRect5 = tester.getRect(textFinder);
      expect(textRect5.height, greaterThan(textRect1.height + 10));
    });

    testWidgets('adding and deleting templates while focused still works',
        (tester) async {
      final s = AppState(configData: {
        'tutorials_enabled': false,
        'late_income_excuses': ['První', 'Druhá'],
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

      // Focus row 0 and delete it directly.
      await tester.tap(find.byKey(const Key('tpl:late_income_excuses:0:text')));
      await tester.pump();
      await tester.tap(find.byTooltip(Strings.get('delete')).first);
      await tester.pumpAndSettle();

      expect(s.get('late_income_excuses'), ['Druhá']);
      expect(find.byKey(const Key('tpl:late_income_excuses:1:text')),
          findsNothing);

      // Add a new row and fill it.
      await tester.tap(find.text('+ ${Strings.get('add')}').first);
      await tester.pumpAndSettle();
      final addedText =
          find.byKey(const Key('tpl:late_income_excuses:1:text'));
      expect(addedText, findsOneWidget);
      await tester.enterText(addedText, 'Třetí');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(s.get('late_income_excuses'), ['Druhá', 'Třetí']);
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
