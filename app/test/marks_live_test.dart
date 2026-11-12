import 'dart:io';

import 'package:app/controllers/app_state.dart' hide MarksController;
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/marks/marks_live.dart';
import 'package:app/widgets/app_widgets.dart' show StatCard;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_marks_live_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('marksControllerFor maps AppState grades and syncs predictions', () {
    final s = AppState(
      data: {
        'absence': {'Matematika': 0.0},
        'grades': {
          'Matematika': [
            {'Grade': '1', 'Weight': 1, 'Date': '10.09.2026'},
          ],
        },
      },
    );
    final c = marksControllerFor(s);
    expect(c.summaries(), hasLength(1));
    expect(c.summaries().first.name, 'Matematika');

    c.selectSubject('Matematika');
    expect(s.marksSelected, 'Matematika');

    expect(c.predictAdd('Matematika', '5', 2), isTrue);
    expect(s.marksPredictions['Matematika'], isNotNull);

    c.setMarksSort('average');
    expect(s.get('marks_sort'), 'average');
  });

  testWidgets('LiveMarksView renders subjects and offers marks tutorial',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final s = AppState(
      configData: {
        'tutorials_done': ['intro'],
      },
      data: {
        'absence': {'Biologie': 0.0},
        'grades': {
          'Biologie': [
            {'Grade': '2', 'Weight': 1, 'Date': '10.09.2026'},
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
            body: LiveMarksView(tokens: AppTokens.dark()),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Biologie'), findsWidgets);
    expect(s.tutorial?.$1, 'marks');
  });

  // Checkpoint B BR3-M2: stat tiles fill the width (two per line on a phone),
  // the Auto segment has its icon and the "updated" line is under the title.
  for (final narrow in [false, true]) {
    testWidgets('marks header and stat tiles like Python (narrow: $narrow)',
        (tester) async {
      tester.view.physicalSize = Size(narrow ? 390 : 1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final s = AppState(
        configData: {
          'tutorials_done': ['intro'],
        },
        data: {
          'absence': {'Biologie': 0.0},
          'grades': {
            'Biologie': [
              {'Grade': '2', 'Weight': 1, 'Date': '10.09.2026'},
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
              body: LiveMarksView(tokens: AppTokens.dark(), narrow: narrow),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text(s.updatedLabel), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
      final cards = find.byType(StatCard);
      expect(cards, findsNWidgets(4));
      final width = narrow ? 390.0 : 1280.0;
      final rects = [
        for (var i = 0; i < 4; i++) tester.getRect(cards.at(i)),
      ];
      if (narrow) {
        // Two lines of two: the first pair share a row, the second pair
        // sit below it, and each pair spans the page width.
        expect(rects[0].top, rects[1].top);
        expect(rects[2].top, rects[3].top);
        expect(rects[2].top, greaterThan(rects[0].bottom - 1));
        expect(rects[1].right - rects[0].left, greaterThan(width - 40));
      } else {
        expect(rects.map((r) => r.top).toSet(), hasLength(1));
        expect(rects[3].right - rects[0].left, greaterThan(width - 80));
      }
    });
  }
}

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);

  @override
  AppState build() => fixed;
}
