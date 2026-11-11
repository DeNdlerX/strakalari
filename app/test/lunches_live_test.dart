import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/lunches/lunches_live.dart';
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
}
