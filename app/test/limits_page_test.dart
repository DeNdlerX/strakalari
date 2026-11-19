import 'dart:convert';
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/absences/limits_page.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/settings/settings_controller.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

class _SeededLimitsState extends AppStateController {
  final AppState seeded;
  _SeededLimitsState(this.seeded);

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

void main() {
  late Directory tmp;

  setUp(() {
    Strings.lang = 'cs';
    tmp = Directory.systemTemp.createTempSync('strakalari_limits_page_');
    core.setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
  });

  tearDown(() {
    core.setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('O4 LimitsPage', () {
    testWidgets(
        'global fields load and persist; changing default updates subject rows and chips',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final cfg = <String, dynamic>{
        'absence_critical_pct': 25.0,
        'absence_warn_pct': 15.0,
        'absence_plan_reserve_pct': 10.0,
        'absence': {'Fyzika': 5.0, 'Matematika': 12.0},
        'subject_limits': <String, dynamic>{'Fyzika': 20.0},
      };
      final c = SettingsController(cfg);
      var backCalls = 0;

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTokens.dark().toThemeData(),
          home: Scaffold(
            body: LimitsPage(
              controller: c,
              tokens: AppTokens.dark(),
              narrow: true,
              onBack: () => backCalls++,
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('25 %'), findsOneWidget);
      expect(find.text(Strings.get('limit_default_tag')), findsOneWidget);
      expect(find.text('20 %'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('auto:lim:default')), '30');
      await tester.enterText(find.byKey(const Key('auto:lim:warn')), '18');
      await tester.enterText(find.byKey(const Key('auto:lim:reserve')), '8');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();

      expect(c.get('absence_critical_pct'), 30.0);
      expect(c.get('absence_warn_pct'), 18.0);
      expect(c.get('absence_plan_reserve_pct'), 8.0);
      expect(find.text('30 %'), findsOneWidget);

      await tester.tap(find.byKey(const Key('lim:back_btn')));
      await tester.pump();
      expect(backCalls, 1);
    });

    testWidgets(
        'subject inline editor shows default and distinct used chips, applies chip without typing, clears on default chip or blank',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final cfg = <String, dynamic>{
        'absence_critical_pct': 25.0,
        'absence': {
          'Chemie': 4.0,
          'Fyzika': 5.0,
          'Matematika': 12.0,
          'Tělesná výchova': 15.0,
        },
        'subject_limits': <String, dynamic>{
          'Fyzika': 20.0,
          'Tělesná výchova': 35.0,
          'Chemie': 20.0, // duplicate value -> chip shown once
        },
      };
      final c = SettingsController(cfg);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTokens.dark().toThemeData(),
          home: Scaffold(
            body: LimitsPage(
              controller: c,
              tokens: AppTokens.dark(),
              narrow: true,
            ),
          ),
        ),
      );
      await tester.pump();

      // Matematika uses default; others show custom badges.
      expect(find.text(Strings.get('limit_default_tag')), findsOneWidget);

      // Expand Matematika -> shows default chip + distinct used chips (20 %, 35 %).
      await tester.tap(find.byKey(const Key('lim:row:Matematika')));
      await tester.pump();

      expect(find.byKey(const Key('lim:subj:Matematika')), findsOneWidget);
      expect(find.byKey(const Key('lim:chip:default')), findsOneWidget);
      expect(find.byKey(const Key('lim:chip:20')), findsOneWidget);
      expect(find.byKey(const Key('lim:chip:35')), findsOneWidget);
      expect(find.text('Výchozí (25 %)'), findsOneWidget);

      // Tap 35 % chip -> saves without typing and collapses.
      await tester.tap(find.byKey(const Key('lim:chip:35')));
      await tester.pump();

      expect(
        (c.get('subject_limits') as Map)['Matematika'],
        35.0,
      );
      expect(find.byKey(const Key('lim:subj:Matematika')), findsNothing);
      expect(find.text(Strings.get('limit_default_tag')), findsNothing);

      // Expand Matematika again and tap Default chip -> removes custom override.
      await tester.tap(find.byKey(const Key('lim:row:Matematika')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('lim:chip:default')));
      await tester.pump();

      expect(
        (c.get('subject_limits') as Map).containsKey('Matematika'),
        isFalse,
      );
      expect(find.text(Strings.get('limit_default_tag')), findsOneWidget);

      // Expand Fyzika and clear text + tap Done -> removes Fyzika override.
      await tester.tap(find.byKey(const Key('lim:row:Fyzika')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('lim:subj:Fyzika')), '');
      await tester.tap(find.byKey(const Key('lim:done:Fyzika')));
      await tester.pump();

      expect((c.get('subject_limits') as Map).containsKey('Fyzika'), isFalse);
    });

    testWidgets(
        'S4 + S10: leaving via Android Back saves focused global field and subject row to config.json and runs one normal save after',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(
        configData: {
          'language': 'cs',
          'tutorials_enabled': false,
          'absence_critical_pct': 25.0,
          'subject_limits': <String, double>{},
          'bakalari_url': 'http://127.0.0.1:18080',
          'bakalari_username': 'demo',
          'bakalari_password': 'pw',
        },
        data: {
          'absence': {'Matematika': 10.0},
        },
      );
      s.demoMode = false;

      final normalSaveSnapshots = <double>[];
      var quietSaves = 0;
      s.configListeners.add(() => quietSaves++);

      final router = buildRouter(initialLocation: '/absences/limits');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededLimitsState(s)),
          ],
          child: MaterialApp.router(
            theme: s.tok.toThemeData(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final origOnChanged = s.onChanged;
      s.onChanged = () {
        normalSaveSnapshots.add(
          (s.config.get('absence_critical_pct', 25.0) as num).toDouble(),
        );
        origOnChanged();
      };

      // Type into Výchozí limit without unfocusing, then trigger Android Back.
      await tester.enterText(find.byKey(const Key('auto:lim:default')), '30');
      await tester.pump();
      expect(normalSaveSnapshots, isEmpty);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.uri.path, '/absences');
      expect(s.get('absence_critical_pct'), 30.0);
      final diskAfterGlobal = jsonDecode(
        File('${tmp.path}/config.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(diskAfterGlobal['absence_critical_pct'], 30.0);
      // Quiet save wrote 30.0, then exactly one normal save emitted after it.
      expect(quietSaves, 2);
      expect(normalSaveSnapshots, [30.0]);

      // Re-open /absences/limits, type into focused subject field, leave via Android Back.
      final subjNormalSaves = <Map<String, Object?>>[];
      s.onChanged = () {
        final raw = s.config.get('subject_limits', {});
        subjNormalSaves.add(
          raw is Map ? Map<String, Object?>.of(raw.cast<String, Object?>()) : const {},
        );
        origOnChanged();
      };

      router.go('/absences/limits');
      await tester.pumpAndSettle();
      subjNormalSaves.clear();
      await tester.tap(find.byKey(const Key('lim:row:Matematika')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('lim:subj:Matematika')), '18');
      await tester.pump();
      expect(subjNormalSaves, isEmpty);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.uri.path, '/absences');
      expect(s.get('subject_limits'), {'Matematika': 18.0});
      final diskAfterSubj = jsonDecode(
        File('${tmp.path}/config.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(diskAfterSubj['subject_limits'], {'Matematika': 18.0});
      expect(subjNormalSaves, [
        {'Matematika': 18.0}
      ]);
    });

    testWidgets(
        'S4 + S10: leaving via back arrow while global field is focused and via wide rail saves value before the one normal save',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(
        configData: {
          'language': 'cs',
          'tutorials_enabled': false,
          'absence_critical_pct': 25.0,
          'subject_limits': <String, double>{},
          'bakalari_url': 'http://127.0.0.1:18080',
          'bakalari_username': 'demo',
          'bakalari_password': 'pw',
        },
        data: {
          'absence': {'Matematika': 10.0},
        },
      );
      s.demoMode = false;

      final router = buildRouter(initialLocation: '/absences/limits');
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededLimitsState(s)),
          ],
          child: MaterialApp.router(
            theme: s.tok.toThemeData(),
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final saveEvents = <(double, Map<String, Object?>)>[];
      final origOnChanged = s.onChanged;
      s.onChanged = () {
        final raw = s.config.get('subject_limits', {});
        saveEvents.add((
          (s.config.get('absence_critical_pct', 25.0) as num).toDouble(),
          raw is Map ? Map<String, Object?>.of(raw.cast<String, Object?>()) : {},
        ));
        origOnChanged();
      };

      // 1. Type into Výchozí limit and tap lim:back_btn while field is still focused.
      await tester.enterText(find.byKey(const Key('auto:lim:default')), '32');
      await tester.tap(find.byKey(const Key('lim:back_btn')));
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.uri.path, '/absences');
      expect(s.get('absence_critical_pct'), 32.0);
      expect(saveEvents.length, 1);
      expect(saveEvents.single.$1, 32.0);

      // 2. Re-open /absences/limits, type into subject row, and leave via wide rail (Dnes).
      router.go('/absences/limits');
      await tester.pumpAndSettle();
      saveEvents.clear();
      await tester.tap(find.byKey(const Key('lim:row:Matematika')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('lim:subj:Matematika')), '19');
      await tester.pump();

      await tester.tap(find.text(Strings.get('nav_today')).first);
      await tester.pumpAndSettle();

      expect(router.routerDelegate.currentConfiguration.uri.path, '/today');
      expect(s.get('subject_limits'), {'Matematika': 19.0});
      expect(saveEvents.length, 1);
      expect(saveEvents.single.$2, {'Matematika': 19.0});
    });
  });
}
