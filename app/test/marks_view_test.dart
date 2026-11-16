import 'dart:io';

import 'package:app/controllers/app_state.dart' hide MarksController;
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/marks/marks_controller.dart';
import 'package:app/features/marks/marks_live.dart';
import 'package:app/features/marks/marks_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

const testGrades = {
  'Matematika': [
    {'Grade': '2', 'Weight': 10, 'Date': '05.09.2026'},
    {'Grade': '1', 'Weight': 10, 'Date': '12.09.2026', 'Caption': 'Rovnice'},
  ],
  'Fyzika': [
    {'Grade': '3', 'Weight': 5, 'Date': '06.09.2026'},
  ],
};

List<String> extractTexts(WidgetTester tester) {
  final out = <String>[];
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    final text = widget.data ?? widget.textSpan?.toPlainText();
    if (text != null && text.isNotEmpty) {
      out.add(text);
    }
  }
  return out;
}

List<String> getCardChips(WidgetTester tester, String subject) {
  final cardFinder = find.byKey(ValueKey('marks:subject:$subject'));
  expect(cardFinder, findsOneWidget);
  final wraps = tester.widgetList<Wrap>(
    find.descendant(of: cardFinder, matching: find.byType(Wrap)),
  ).toList();
  expect(wraps, isNotEmpty);
  final chipsWrap = wraps.last;
  final chipTexts = <String>[];

  void collect(Widget w) {
    if (w is Text) {
      final t = w.data ?? w.textSpan?.toPlainText();
      if (t != null && t.isNotEmpty) chipTexts.add(t);
    } else if (w is Tooltip) {
      if (w.child != null) collect(w.child!);
    } else if (w is Opacity) {
      if (w.child != null) collect(w.child!);
    } else if (w is Container) {
      if (w.child != null) collect(w.child!);
    }
  }

  for (final child in chipsWrap.children) {
    collect(child);
  }
  return chipTexts;
}

Widget buildMarksView(MarksController controller, [WidgetTester? tester]) {
  if (tester != null) {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }
  return MaterialApp(
    home: Scaffold(
      body: MarksView(
        controller: controller,
        tokens: AppTokens.dark(),
        narrow: false,
      ),
    ),
  );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_marks_view_test_');
    core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
  });

  tearDown(() {
    core.setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  AppState createState({
    Map<String, Object?>? grades,
    Map<String, Object?>? config,
    Map<String, Object?>? data,
  }) {
    final state = AppState(
      configData: config ?? {},
      data: {
        'grades': grades ?? testGrades,
        ...?data,
      },
    );
    state.demoMode = false;
    return state;
  }

  testWidgets('emptyBuilds', (tester) async {
    final state = createState(grades: {});
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final texts = extractTexts(tester);
    expect(texts, contains(Strings.get('no_data')));
  });

  testWidgets('subjectCardsShowAverageAndFinalGrade', (tester) async {
    final state = createState();
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final texts = extractTexts(tester);
    expect(texts, contains('Matematika'));
    expect(texts, contains('Fyzika'));
    expect(texts, contains('1.50')); // Matematika (1 + 2) / 2
    expect(texts, contains('3.00')); // Fyzika
    expect(texts, contains('2.25')); // Overall
    expect(texts, contains(Strings.get('marks_recent').toUpperCase()));
  });

  testWidgets('detailPanelListsMarksNewestFirstWithTopic', (tester) async {
    final state = createState();
    state.selectMarksSubject('Matematika');
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final texts = extractTexts(tester);
    expect(texts, contains(Strings.get('marks_predictor').toUpperCase()));
    expect(texts, contains('Rovnice'));
    final newestIdx = texts.indexWhere((t) => t.contains('12. 9. 2026'));
    final oldestIdx = texts.indexWhere((t) => t.contains('5. 9. 2026'));
    expect(newestIdx != -1 && oldestIdx != -1, isTrue);
    expect(newestIdx, lessThan(oldestIdx));
  });

  testWidgets('subjectCardShowsQuarterlyMark', (tester) async {
    final state = createState(data: {
      'quarterly_marks': {
        'Matematika': {'Grade': '1'},
      },
    });
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final texts = extractTexts(tester);
    expect(texts, contains(Strings.format('marks_quarterly', {'mark': '1'})));
    final prefix = Strings.format('marks_quarterly', {'mark': ''});
    final count = texts.where((t) => t.startsWith(prefix)).length;
    expect(count, 1);
  });

  testWidgets('cardChipsRunOldestLeftNewestRight', (tester) async {
    final state = createState(grades: {
      'Dějepis': [
        {'Grade': '3', 'Weight': 1, 'Date': '20.09.2026'},
        {'Grade': '1', 'Weight': 1, 'Date': '01.09.2026'},
        {'Grade': '2', 'Weight': 1, 'Date': '10.09.2026'},
      ],
    });
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    expect(getCardChips(tester, 'Dějepis'), ['1', '2', '3']);
  });

  testWidgets('cardChipsKeepNewestAndCountOlderOnTheLeft', (tester) async {
    const n = MarksView.maxChips + 3;
    final marks = [
      for (var i = 0; i < n; i++)
        {
          'Grade': i < 3 ? '1' : '2',
          'Weight': 1,
          'Date': '${(i + 1).toString().padLeft(2, '0')}.09.2026',
        },
    ];
    final state = createState(grades: {'Dějepis': marks});
    expect(state.predictAdd('Dějepis', '5', 1), isTrue);
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final chips = getCardChips(tester, 'Dějepis');
    expect(chips.first, '+4');
    expect(
      chips.sublist(1),
      [...List.filled(MarksView.maxChips - 1, '2'), '5'],
    );
  });

  testWidgets('percentSubjectsAutodetected', (tester) async {
    final state = createState(grades: {
      'Chemie': [
        {'Grade': '53', 'Weight': 5, 'Date': '10.09.2026'},
        {'Grade': '100', 'Weight': 1, 'Date': '15.09.2026'},
      ],
    });
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final texts = extractTexts(tester);
    expect(texts, contains('60.8 %'));
    expect(texts, contains('53 %'));
  });

  testWidgets('predictionChangesAverageAndShowsBanner', (tester) async {
    final state = createState();
    expect(state.predictAdd('Fyzika', '1', 5), isTrue);
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final texts = extractTexts(tester);
    expect(texts, contains('2.00')); // (3 + 1) / 2
    expect(texts, contains(Strings.format('marks_prediction_on', {'n': 1})));
  });

  testWidgets('nonNumericGradeDoesNotBreakAverage', (tester) async {
    final state = createState(grades: {
      'Chemie': [
        {'Grade': 'N', 'Weight': 5, 'Date': '01.09.2026'},
        {'Grade': '2', 'Weight': 5, 'Date': '02.09.2026'},
      ],
    });
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final texts = extractTexts(tester);
    expect(texts, contains('2.00'));
  });

  testWidgets('plannedMarkListedNotCounted', (tester) async {
    final state = createState(grades: {
      'FG': [
        {
          'Grade': '?',
          'Weight': 2,
          'Date': '13.9.2026',
          'Planned': true,
          'TestDate': '15.1.2027',
          'Caption': 'pololetní test',
        },
        {'Grade': '1', 'Weight': 1, 'Date': '10.09.2026'},
      ],
    });
    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final texts = extractTexts(tester);
    expect(texts, contains(Strings.get('marks_planned').toUpperCase()));
    expect(texts, contains('1.00'));
  });

  test('predictorStateAddEditRemoveRestore', () {
    final state = createState();
    expect(state.predictAdd('Fyzika', 'abc', 1), isFalse);
    expect(state.predictAdd('Fyzika', '1', 0), isFalse);
    expect(state.predictAdd('Fyzika', '2', '2,5'), isTrue);
    expect(state.marksPredictions['Fyzika']?['added'], [
      {'Grade': '2', 'Weight': 2.5},
    ]);

    expect(state.predictEdit('Fyzika', 'add:0', '1', 5), isTrue);
    expect(state.marksPredictions['Fyzika']?['added'], [
      {'Grade': '1', 'Weight': 5.0},
    ]);

    final key = state
        .marksSummaries()
        .firstWhere((s) => s.name == 'Fyzika')
        .rows
        .firstWhere((r) => r.state == 'real')
        .key;
    state.predictRemove('Fyzika', key);
    final fyz = state.marksSummaries().firstWhere((s) => s.name == 'Fyzika');
    expect(fyz.average, 3.0);
    expect(fyz.predicted, 1.0);

    state.predictRestore('Fyzika', key);
    state.predictRemove('Fyzika', 'add:0');
    expect(state.marksPredictions.containsKey('Fyzika'), isFalse);

    state.predictAdd('Fyzika', '1', 1);
    state.predictReset();
    expect(state.marksPredictions, isEmpty);
  });

  test('scalePreferences', () {
    final state = createState();
    expect(state.setMarksScale('percent'), isTrue);
    expect(state.get('marks_scale'), 'percent');
    expect(state.get('marks_subject_scales'), <String, Object?>{});
    expect(state.marksScale(), 'percent');
    expect(state.marksSubjectScales(), isEmpty);

    expect(state.setMarksScale('bogus'), isFalse);

    state.setSubjectScale('Fyzika', 'grade');
    expect(state.get('marks_subject_scales'), {'Fyzika': 'grade'});
    expect(state.marksSubjectScales(), {'Fyzika': 'grade'});

    expect(state.setMarksBands([90, 95, 50, 30]), isFalse);
    expect(state.setMarksBands(['85', 70, 50, 30]), isTrue);
    expect(state.get('marks_percent_bands'), [85.0, 70.0, 50.0, 30.0]);
    expect(state.marksBands(), [85.0, 70.0, 50.0, 30.0]);

    expect(state.setMarksBands(null), isTrue);
    expect(state.get('marks_percent_bands'), <double>[]);
  });

  test('selectingTheOpenSubjectClosesIt', () {
    final state = createState();
    state.selectMarksSubject('Fyzika');
    expect(state.marksSelected, 'Fyzika');
    state.selectMarksSubject('Fyzika');
    expect(state.marksSelected, isNull);
  });

  test('savingAnUnchangedMarkIsNotAnEdit', () {
    final state = createState();
    final key = state
        .marksSummaries()
        .firstWhere((s) => s.name == 'Fyzika')
        .rows
        .first
        .key;
    expect(state.predictEdit('Fyzika', key, '3', '5'), isTrue);
    expect(state.marksPredictions.containsKey('Fyzika'), isFalse);
    expect(state.predictEdit('Fyzika', key, '2', '5'), isTrue);
    expect((state.marksPredictions['Fyzika']?['edits'] as Map?)?[key], {
      'Grade': '2',
      'Weight': 5.0,
    });
  });

  testWidgets('presetBandsDriveConversionAndAreLabelled', (tester) async {
    final state = createState(
      config: {'school_preset_id': 'gekom_2026_2027'},
      grades: {
        'Chemie': [
          {'Grade': '88', 'Weight': 1, 'Date': '01.09.2026'},
        ],
      },
    );
    final (bands, source) = state.marksBandsSource();
    expect(source, 'preset');
    expect(bands, [87.0, 72.0, 55.0, 40.0]);

    final controller = marksControllerFor(state);
    await tester.pumpWidget(buildMarksView(controller, tester));
    final texts = extractTexts(tester);
    expect(
      texts,
      contains(
        Strings.format(
          'marks_bands_src_preset',
          {'school': 'GEKOM 2026/2027'},
        ),
      ),
    );
    expect(
      texts,
      contains('1: 100–87 · 2: 87–72 · 3: 72–55 · 4: 55–40 · 5: 40–0 %'),
    );
    final chem = state.marksSummaries().first;
    expect(
      core.finalGrade(chem.average, chem.scale, state.marksBands()),
      1,
    );
    expect(
      core.finalGrade(87.0, 'percent', state.marksBands()),
      2,
    );
  });

  group('B8 marks band controllers', () {
    testWidgets(
        'rebuilding MarksView preserves band TextEditingController identity, focus, edit, and cursor position',
        (tester) async {
      Strings.lang = 'cs';
      final state = createState();
      final controller = marksControllerFor(state);

      await tester.pumpWidget(buildMarksView(controller, tester));

      // Locate the 2nd band TextField inside the bands card (first 4 TextFields
      // in MarksView's non-dialog tree are the 4 percentage band fields).
      final bandFields = find.byType(TextField);
      expect(bandFields, findsNWidgets(4));
      final secondFieldFinder = bandFields.at(1);

      await tester.tap(secondFieldFinder);
      await tester.pump();
      await tester.enterText(secondFieldFinder, '74.5');
      await tester.pump();

      final beforeCtrl = tester.widget<TextField>(secondFieldFinder).controller!;
      beforeCtrl.selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();
      expect(beforeCtrl.selection.baseOffset, 2);

      // Trigger a controller-driven rebuild (e.g., changing subject sort order).
      controller.setMarksSort('worst');
      await tester.pumpWidget(buildMarksView(controller, tester));
      await tester.pump();

      final afterWidget = tester.widget<TextField>(secondFieldFinder);
      final afterCtrl = afterWidget.controller!;
      expect(identical(afterCtrl, beforeCtrl), isTrue);
      expect(afterCtrl.text, '74.5');
      expect(afterCtrl.selection.baseOffset, 2);
      expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);

      // Verify unmount/dispose runs cleanly without errors.
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('P7 marks trend chart with axes and labels', () {
    testWidgets('shows CustomPaint line chart with Y and X axis labels for grade and percent',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      Strings.lang = 'cs';

      final gradeState = createState(grades: {
        'Anglický jazyk': [
          {'Grade': '1', 'Weight': 10, 'Date': '06.10.2026', 'Caption': 'Unit 2 test'},
          {'Grade': '1', 'Weight': 5, 'Date': '28.10.2026', 'Caption': 'Vocabulary quiz'},
          {'Grade': '2', 'Weight': 10, 'Date': '12.11.2026', 'Caption': 'Reading'},
        ],
      })..selectMarksSubject('Anglický jazyk');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MarksView(
            controller: marksControllerFor(gradeState),
            tokens: AppTokens.dark(),
            narrow: true,
          ),
        ),
      ));
      await tester.pump();

      final chartFinder = find.byKey(const ValueKey('marks:trend_chart'));
      expect(chartFinder, findsOneWidget);
      expect(
        find.descendant(of: chartFinder, matching: find.byType(CustomPaint)),
        findsOneWidget,
      );
      for (final label in ['1', '3', '5', '6. 10.', '12. 11.']) {
        expect(
          find.descendant(of: chartFinder, matching: find.text(label)),
          findsOneWidget,
          reason: 'grade chart missing axis label $label',
        );
      }

      final pctState = createState(grades: {
        'Chemie': [
          {'Grade': '53', 'Weight': 5, 'Date': '10.09.2026'},
          {'Grade': '100', 'Weight': 5, 'Date': '15.09.2026'},
        ],
      })..selectMarksSubject('Chemie');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MarksView(
            controller: marksControllerFor(pctState),
            tokens: AppTokens.dark(),
            narrow: true,
          ),
        ),
      ));
      await tester.pump();

      expect(chartFinder, findsOneWidget);
      for (final label in ['100 %', '50 %', '0 %', '10. 9.', '15. 9.']) {
        expect(
          find.descendant(of: chartFinder, matching: find.text(label)),
          findsOneWidget,
          reason: 'percent chart missing axis label $label',
        );
      }
    });
  });
}
