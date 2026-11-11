import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/activity/activity_live.dart';
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
}
