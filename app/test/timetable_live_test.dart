import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/timetable/timetable_live.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_timetable_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('timetableControllerFor maps AppState and delegates week/view toggles',
      () {
    final s = AppState(
      data: {
        'timetable': {
          '07.09.2026': [
            {'subject': 'Matematika', 'time': '1. 8:00 - 8:45'},
          ],
          '14.09.2026': [
            {'subject': 'Fyzika', 'time': '2. 8:55 - 9:40'},
          ],
        },
      },
    );
    final c = timetableControllerFor(s);
    expect(c.weeks(), hasLength(2));

    c.setShowStable(true);
    expect(s.showStableTimetable, isTrue);

    c.goTimetableWeek('2026-09-14');
    expect(s.showStableTimetable, isFalse);
    expect(s.timetableMondayIso, '2026-09-14');

    c.setTimetableView('list');
    expect(s.timetableView, 'list');
    expect(s.get('timetable_view'), 'list');
  });

  testWidgets('LiveTimetableView renders lessons from appStateProvider',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final s = AppState(
      configData: {
        'tutorials_done': ['intro'],
      },
      data: {
        'timetable': {
          '07.09.2026': [
            {'subject': 'Chemie', 'time': '1. 8:00 - 8:45'},
          ],
        },
      },
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => FixedAppStateController(s)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LiveTimetableView(
              tokens: AppTokens.dark(),
              now: DateTime(2026, 9, 7, 10, 0),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Chemie'), findsWidgets);
    expect(s.tutorial?.$1, 'timetable');
  });
}

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);

  @override
  AppState build() => fixed;
}
