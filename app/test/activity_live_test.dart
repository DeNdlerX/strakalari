import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/activity/activity_live.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  test('activity controller snapshot mirrors the shared state', () {
    final s = AppState();
    s.addLog('hello');
    s.refreshRunning = true;
    final c = activityControllerFor(s);
    expect(c.logLines.single.endsWith('hello'), isTrue);
    expect(c.statusKind(), 'working');
    c.clearLog();
    expect(s.logLines, isEmpty);
    var jobs = 0;
    s.spawn = (job, name) => jobs++;
    s.refreshRunning = false;
    expect(activityControllerFor(s).startRefresh('strava'), isTrue);
    expect(jobs, 1);
    expect(s.refreshRunning, isTrue);
    activityControllerFor(s).cancelRefresh();
    expect(s.cancelRequested, isTrue);
  });

  testWidgets('live activity view repaints when the state emits',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
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
          home: Scaffold(body: LiveActivityView(narrow: false))),
    ));
    final s = container.read(appStateProvider);
    expect(find.textContaining('unique-line-42'), findsNothing);
    s.addLog('unique-line-42');
    await tester.pump();
    expect(find.textContaining('unique-line-42'), findsOneWidget);
  });

  // Checkpoint B B-M11: the automation card with the pause switch.
  testWidgets('automation card pauses automation and opens the rules',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final s = container.read(appStateProvider);
    s.save({'excuse_mode': 'confirm', 'strava_order_mode': 'auto'});
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
          home: Scaffold(body: LiveActivityView(narrow: false))),
    ));
    await tester.pump();

    expect(find.text(Strings.get('automation_running')), findsOneWidget);
    expect(find.text(Strings.get('mode_confirm')), findsOneWidget);
    expect(find.text(Strings.get('mode_auto')), findsOneWidget);

    await tester.tap(find.byKey(const Key('activity:pause')));
    await tester.pump();
    expect(s.automationPaused(), isTrue);
    expect(s.get('automation_paused'), true);
    expect(find.text(Strings.get('automation_paused_banner')), findsWidgets);

    await tester.tap(find.text(Strings.get('automation_edit')));
    await tester.pump();
    expect(s.settingsSection, 'rules');
    expect(s.pendingRoute, 'settings');
  });
}
