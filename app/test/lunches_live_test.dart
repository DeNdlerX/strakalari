import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/lunches/lunches_live.dart';
import 'package:app/l10n/strings.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_lunches_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  test('lunch controller snapshot mirrors and delegates to shared state', () {
    withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () {
      final s = AppState(
        configData: {'use_strava': true},
        data: {
          'strava_meals': {
            '08.09.2026': {'T1&1&0': 'Guláš', 'T1&-1&0': 'Bez jídla'}
          },
          'strava_ordered': <String, Object?>{},
        },
      )..demoMode = false;
      final c = lunchControllerFor(s);
      expect(c.food.containsKey('08.09.2026'), isTrue);
      expect(c.orderLunch('08.09.2026', 'T1&1&0'), isTrue);
      expect(s.orders['08.09.2026'], 'T1&1&0');
      expect(s.pendingOrders.contains('08.09.2026'), isTrue);
      expect(c.addBlacklistWord('houby'), isTrue);
      expect(s.blacklistWords(), contains('houby'));
    });
  });

  testWidgets('live lunches view renders menu when state updates',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: LiveLunchesView(narrow: false)),
      ),
    ));
    final s = container.read(appStateProvider);
    expect(find.textContaining('Svíčková'), findsNothing);
    s.data = {
      'strava_meals': {
        '08.12.2027': {'T1&1&0': 'Polévka; Svíčková'}
      },
    };
    s.demoMode = false;
    s.onChanged();
    await tester.pump();
    expect(find.textContaining('Svíčková'), findsOneWidget);
  });

  testWidgets('P8 lunches send disabled with reason when Strava not configured',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final savedLang = Strings.lang;
    addTearDown(() => Strings.lang = savedLang);

    for (final lang in ['cs', 'en']) {
      Strings.lang = lang;
      final s = AppState(
        configData: {
          'use_strava': true,
          'strava_username': '',
          'strava_password': '',
          'strava_canteen_id': '',
          'language': lang,
        },
        data: <String, Object?>{},
      )..demoMode = false;

      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey('p8_$lang'),
          overrides: [
            appStateProvider.overrideWith(() => _FixedAppState(s)),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: LiveLunchesView(narrow: true),
            ),
          ),
        ),
      );
      await tester.pump();

      final sendBtnFinder = find.ancestor(
        of: find.text(Strings.get('send_orders')),
        matching: find.byWidgetPredicate((w) => w is ElevatedButton),
      );
      expect(sendBtnFinder, findsOneWidget, reason: 'lang=$lang');
      final btn = tester.widget<ElevatedButton>(sendBtnFinder);
      expect(btn.onPressed, isNull,
          reason: 'lang=$lang send button must be disabled without Strava creds');

      expect(
        find.text(lang == 'cs'
            ? 'Nejprve nastavte Stravu v Nastavení → Účty.'
            : 'Set up Strava in Settings → Accounts first.'),
        findsOneWidget,
        reason: 'lang=$lang must explain why send is disabled',
      );
    }
  });

  testWidgets(
      'P8 lunches send disabled with reason before the first refresh (no data yet)',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final savedLang = Strings.lang;
    addTearDown(() => Strings.lang = savedLang);

    for (final lang in ['cs', 'en']) {
      Strings.lang = lang;
      // A new install: Strava switched on in the wizard, its login skipped,
      // nothing fetched yet (so AppState is in demo mode).
      final s = AppState(
        configData: {'use_strava': true, 'language': lang},
        data: <String, Object?>{},
      );
      expect(s.demoMode, isTrue, reason: 'lang=$lang no data yet');

      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey('p8_nodata_$lang'),
          overrides: [
            appStateProvider.overrideWith(() => _FixedAppState(s)),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: LiveLunchesView(narrow: true),
            ),
          ),
        ),
      );
      await tester.pump();

      final sendBtnFinder = find.ancestor(
        of: find.text(Strings.get('send_orders')),
        matching: find.byWidgetPredicate((w) => w is ElevatedButton),
      );
      expect(sendBtnFinder, findsOneWidget, reason: 'lang=$lang');
      expect(tester.widget<ElevatedButton>(sendBtnFinder).onPressed, isNull,
          reason: 'lang=$lang send button must be disabled without Strava creds');
      expect(
        find.text(lang == 'cs'
            ? 'Nejprve nastavte Stravu v Nastavení → Účty.'
            : 'Set up Strava in Settings → Accounts first.'),
        findsOneWidget,
        reason: 'lang=$lang must explain why send is disabled',
      );
    }
  });
}

class _FixedAppState extends AppStateController {
  final AppState fixed;
  _FixedAppState(this.fixed);

  @override
  AppState build() => fixed;
}
