// The phone's Back button, driven the way Android drives it.
//
// Found on the Pixel (2026-11-13): Back on any screen but Today closed the
// app. The Back handler sat in the shell, above go_router's inner
// navigator; that navigator kept telling Android "nothing to pop", so
// Android never handed Back to Flutter. These tests record what the app
// tells Android (`SystemNavigator.setFrameworkHandlesBack`) and press Back
// through `handlePopRoute`, so they see what the phone sees. The steps are
// Python's `back_target` / `_subpage_open` (flet_ui/app.py).
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/absences/limits_page.dart';
import 'package:app/features/planner/planner_live.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/router.dart';
import 'package:app/shell/theme.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

void main() {
  late Directory tmp;
  late List<bool> handlesBack;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_android_back_test_');
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

  Future<(GoRouter, AppState)> start(
    WidgetTester tester,
    String location, {
    void Function(AppState)? prepare,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    handlesBack = [];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
          handlesBack.add(call.arguments as bool);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final state = container.read(appStateProvider);
    state.wizardDismissed = true;
    prepare?.call(state);
    // Start on Today like the phone, then go where the test begins: Flutter
    // reports to Android only once the app is resumed.
    final router = buildRouter();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          theme: tokensFor('dark').toThemeData(),
        ),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    if (location != '/today') {
      router.go(location);
      await tester.pumpAndSettle();
    }
    return (router, state);
  }

  String where(GoRouter router) =>
      router.routerDelegate.currentConfiguration.uri.path;

  Future<void> pressBack(WidgetTester tester) async {
    // ignore: invalid_use_of_protected_member
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('backOnAMainTabGoesToToday', (tester) async {
    final (router, _) = await start(tester, '/today');
    router.go('/timetable');
    await tester.pumpAndSettle();
    expect(handlesBack.last, isTrue); // Android must hand Back to the app.
    await pressBack(tester);
    expect(where(router), '/today');
    expect(handlesBack.last, isFalse);
  });

  testWidgets('backOnAMoreScreenGoesToMore', (tester) async {
    final (router, _) = await start(tester, '/more');
    router.go('/absences');
    await tester.pumpAndSettle();
    expect(handlesBack.last, isTrue);
    await pressBack(tester);
    expect(where(router), '/more');
    expect(handlesBack.last, isTrue); // More -> Today next.
    await pressBack(tester);
    expect(where(router), '/today');
  });

  testWidgets('backClosesTheSettingsSectionFirst', (tester) async {
    // More -> Budík opens Settings straight in the alarm section.
    final (router, state) = await start(
      tester,
      '/settings',
      prepare: (s) {
        s.settingsSection = 'alarm';
        s.settingsOpen = true;
      },
    );
    expect(handlesBack.last, isTrue);
    await pressBack(tester);
    expect(where(router), '/settings');
    expect(state.settingsOpen, isFalse);
    expect(handlesBack.last, isTrue);
    await pressBack(tester);
    expect(where(router), '/more');
  });

  testWidgets(
      'O7 Limits opened from Settings returns to open Limits section via both lim:back_btn and Android Back',
      (tester) async {
    final (router, state) = await start(
      tester,
      '/settings',
      prepare: (s) {
        s.setTutorialsEnabled(false);
        s.settingsSection = 'limits';
        s.settingsOpen = true;
      },
    );
    await tester.tap(find.byKey(const Key('settings:go_absences_limits')));
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.uri.toString(),
      '/absences/limits?from=settings',
    );
    expect(find.byType(LiveLimitsPage), findsOneWidget);

    // 1. Android Back returns to /settings with limits still open.
    expect(handlesBack.last, isTrue);
    await pressBack(tester);
    expect(where(router), '/settings');
    expect(state.settingsSection, 'limits');
    expect(state.settingsOpen, isTrue);

    // 2. Re-open and use lim:back_btn -> also returns to /settings with limits open.
    await tester.tap(find.byKey(const Key('settings:go_absences_limits')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lim:back_btn')));
    await tester.pumpAndSettle();
    expect(where(router), '/settings');
    expect(state.settingsSection, 'limits');
    expect(state.settingsOpen, isTrue);
  });

  testWidgets(
      'O7 Limits opened from Absence and /planner redirect both return to /absences via Android Back',
      (tester) async {
    final (router, _) = await start(
      tester,
      '/absences',
      prepare: (s) => s.setTutorialsEnabled(false),
    );
    await tester.tap(find.byKey(const Key('abs:limits_btn')));
    await tester.pumpAndSettle();
    expect(where(router), '/absences/limits');
    expect(handlesBack.last, isTrue);
    await pressBack(tester);
    expect(where(router), '/absences');

    router.go('/planner');
    await tester.pumpAndSettle();
    expect(where(router), '/absences/plan');
    expect(handlesBack.last, isTrue);
    await pressBack(tester);
    expect(where(router), '/absences');
  });

  testWidgets(
      'O7/M4 Today tip opens /absences/plan?from=today and Android Back returns to /today',
      (tester) async {
    Strings.lang = 'cs';
    final fixedNow = DateTime(2026, 9, 10, 10, 0);
    await withClock(Clock.fixed(fixedNow), () async {
      final (router, _) = await start(
        tester,
        '/today',
        prepare: (s) {
          s.setTutorialsEnabled(false);
          s.demoMode = false;
          s.data = {
            'absence': {'Matematika': 2.0},
            'timetable': {
              '11.09.2026': [
                {'subject': 'Matematika', 'time': '1. 8:00 - 8:45'},
              ],
            },
          };
        },
      );

      final tipBtn = find.widgetWithText(
        TextButton,
        Strings.get('abs_planner_btn'),
      );
      expect(tipBtn, findsOneWidget);
      await tester.tap(tipBtn);
      await tester.pumpAndSettle();
      expect(
        router.routerDelegate.currentConfiguration.uri.toString(),
        '/absences/plan?from=today',
      );
      expect(find.byType(LivePlannerPage), findsOneWidget);

      expect(handlesBack.last, isTrue);
      await pressBack(tester);
      expect(where(router), '/today');
    });
  });

  testWidgets(
      'O4/S4 leaving Limits via Android Back flushes focused default and subject fields to config.json',
      (tester) async {
    final (router, state) = await start(
      tester,
      '/settings',
      prepare: (s) {
        s.setTutorialsEnabled(false);
        s.demoMode = false;
        s.data = {
          'absence': {'Matematika': 12.0},
        };
        s.settingsSection = 'limits';
        s.settingsOpen = true;
      },
    );

    // Edit default limit while focused and leave via Android Back -> Settings.
    await tester.tap(find.byKey(const Key('settings:go_absences_limits')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('auto:lim:default')));
    await tester.enterText(find.byKey(const Key('auto:lim:default')), '33');
    await tester.pump();
    await pressBack(tester);
    expect(where(router), '/settings');
    expect(state.get('absence_critical_pct'), 33.0);
    expect(core.ConfigManager().get('absence_critical_pct'), 33.0);

    // Open from Absence, edit subject limit while focused, leave via Android Back -> Absence.
    router.go('/absences');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('abs:limits_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lim:row:Matematika')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('lim:subj:Matematika')));
    await tester.enterText(find.byKey(const Key('lim:subj:Matematika')), '19');
    await tester.pump();
    await pressBack(tester);
    expect(where(router), '/absences');
    expect(state.get('subject_limits'), {'Matematika': 19.0});
    expect(core.ConfigManager().get('subject_limits'), {'Matematika': 19.0});
  });
}
