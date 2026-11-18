import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import 'package:app/controllers/app_state.dart';
import 'package:app/features/absences/absences_live.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/marks/marks_live.dart';
import 'package:app/features/today/today_controller.dart';
import 'package:app/features/today/today_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/scaffold.dart';
import 'package:app/shell/theme.dart';
import 'package:app/tutorial/tours.dart';
import 'package:app/tutorial/tutorial_ui.dart';

class FixedAppStateController extends AppStateController {
  final AppState fixed;
  FixedAppStateController(this.fixed);
  @override
  AppState build() {
    fixed.onChanged = () {
      state = fixed;
    };
    fixed.onProgress = fixed.onChanged;
    return fixed;
  }
}

void main() {
  AppState freshState([Map<String, dynamic>? initialConfig]) {
    final tmp = Directory.systemTemp.createTempSync('tutorial_test_');
    core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
    return AppState(configData: initialConfig);
  }

  void finishIntro(AppState st) {
    expect(st.tutorialOffer('intro'), isTrue);
    st.tutorialSkip();
  }

  group('gating', () {
    test('intro comes first', () {
      final st = freshState();
      expect(st.tutorialOffer('excuse'), isFalse);
      expect(st.tutorialOffer('intro'), isTrue);
      // One tour at a time.
      expect(st.tutorialOffer('excuse'), isFalse);
    });

    test('contextual tour after intro', () {
      final st = freshState();
      finishIntro(st);
      expect(st.tutorialOffer('excuse'), isTrue);
      expect(st.tutorialCurrent()!.$1.id, 'excuse');
    });

    test('disabled offers nothing', () {
      final st = freshState();
      expect(st.setTutorialsEnabled(false), isTrue);
      expect(st.tutorialOffer('intro'), isFalse);
    });

    test('turning off drops the active tour', () {
      final st = freshState();
      st.tutorialOffer('intro');
      st.setTutorialsEnabled(false);
      expect(st.tutorialCurrent(), isNull);
    });

    test('unknown tour is ignored', () {
      final st = freshState();
      finishIntro(st);
      expect(st.tutorialOffer('nope'), isFalse);
    });
  });

  group('progress', () {
    test('skip is remembered across restarts', () {
      final tmp = Directory.systemTemp.createTempSync('tut_restart_');
      core.setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
      final st1 = AppState();
      finishIntro(st1);

      final st2 = AppState();
      expect(st2.tutorialsDone(), contains('intro'));
      expect(st2.tutorialOffer('intro'), isFalse);
    });

    test('next through the end marks done', () {
      final st = freshState();
      st.tutorialOffer('intro');
      for (final _ in tours['intro']!.steps) {
        st.tutorialNext();
      }
      expect(st.tutorialCurrent(), isNull);
      expect(st.tutorialsDone(), contains('intro'));
    });

    test('back stays in bounds', () {
      final st = freshState();
      st.tutorialOffer('intro');
      st.tutorialBack();
      expect(st.tutorial, ('intro', 0));
      st.tutorialNext();
      st.tutorialBack();
      expect(st.tutorial, ('intro', 0));
    });

    test('suspend does not mark done', () {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('excuse');
      st.tutorialSuspend();
      expect(st.tutorialsDone(), isNot(contains('excuse')));
      expect(st.tutorialOffer('excuse'), isTrue);
      expect(st.tutorial, ('excuse', 0));
    });

    test('event skips ahead to the waiting step', () {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('excuse'); // step 0 has no `until`
      st.tutorialEvent('excuse_done');
      // Jumped past the step that waited for it (index 1).
      expect(st.tutorial, ('excuse', 2));
    });

    test('unrelated event is ignored', () {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('excuse');
      st.tutorialEvent('orders_sent');
      expect(st.tutorial, ('excuse', 0));
    });

    test('event on last waiting step finishes', () {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('lunches');
      st.tutorialEvent('lunch_picked');
      st.tutorialEvent('orders_sent');
      expect(st.tutorial, ('lunches', 2));
      st.tutorialNext();
      expect(st.tutorialsDone(), contains('lunches'));
    });

    test('event without tour is harmless', () {
      final bare = AppState();
      bare.tutorialEvent('excuse_done');
    });

    test('reset replays everything', () {
      final st = freshState();
      finishIntro(st);
      st.setTutorialsEnabled(false);
      expect(st.resetTutorials(), isTrue);
      expect(st.tutorialsEnabled(), isTrue);
      expect(st.tutorialsDone(), isEmpty);
    });

    test('order lunch fires its event', () {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('lunches');
      st.demoMode = false;
      st.data['food'] = {
        '01.10.2026': {'meal-1': 'Test Meal'}
      };
      st.isLunchOrderOpenOverride = (day, [now]) => true;
      expect(st.orderLunch('01.10.2026', 'meal-1'), isTrue);
      expect(st.tutorial, ('lunches', 1));
    });
  });

  group('rendering', () {
    test('anchor passthrough without tour', () {
      final st = freshState();
      const control = Text('x');
      final result = tutorialAnchor(st, 'excuse_card', control);
      expect(identical(result, control), isTrue);
    });

    testWidgets('anchor wraps first match with inline bubble', (tester) async {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('excuse');
      st.tutorialBegin('today');
      const first = Text('a');
      const second = Text('b');

      final wrapped = tutorialAnchor(st, 'excuse_card', first);
      expect(wrapped, isA<Column>());

      // Only the first matching control per render is highlighted.
      final secondWrapped = tutorialAnchor(st, 'excuse_card', second);
      expect(identical(secondWrapped, second), isTrue);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            final bubble = tutorialLayer(
                st, context, tokensFor('dark'), false);
            expect(bubble, isNull); // Bubble is inline, not floating!
            return wrapped;
          }),
        ),
      ));
    });

    testWidgets('missing first anchor suspends', (tester) async {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('excuse');
      st.tutorialBegin('today');
      // The anchor never rendered (st.tutorialAnchored stays false)
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            final bubble = tutorialLayer(
                st, context, tokensFor('dark'), false);
            expect(bubble, isNull);
            return const SizedBox();
          }),
        ),
      ));
      expect(st.tutorialCurrent(), isNull);
      expect(st.tutorialsDone(), isNot(contains('excuse')));
    });

    testWidgets('missing later anchor floats', (tester) async {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('excuse');
      st.tutorialNext(); // step index 1
      st.tutorialBegin('today');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            final bubble = tutorialLayer(
                st, context, tokensFor('dark'), false);
            expect(bubble, isNotNull);
            return const SizedBox();
          }),
        ),
      ));
      expect(st.tutorial, ('excuse', 1));
    });

    test('other screen suspends the tour', () {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('excuse');
      st.tutorialBegin('lunches');
      expect(st.tutorialCurrent(), isNull);
    });

    testWidgets('intro floats on any screen', (tester) async {
      final st = freshState();
      st.tutorialBegin('settings');
      expect(st.tutorial, ('intro', 0));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (context) {
            final bubble = tutorialLayer(
                st, context, tokensFor('dark'), false);
            expect(bubble, isNotNull);
            return const SizedBox();
          }),
        ),
      ));
    });

    testWidgets('every step bubble builds', (tester) async {
      final st = freshState();
      for (final tour in tours.values) {
        for (var i = 0; i < tour.steps.length; i++) {
          for (final caret in ['', 'up', 'up_right', 'left']) {
            await tester.pumpWidget(MaterialApp(
              home: Scaffold(
                body: TutorialBubble(
                  state: st,
                  tour: tour,
                  index: i,
                  step: tour.steps[i],
                  caret: caret,
                  tok: tokensFor('dark'),
                ),
              ),
            ));
            expect(find.byType(TutorialBubble), findsOneWidget);
          }
        }
      }
    });

    testWidgets('today view anchors first excuse', (tester) async {
      final st = freshState();
      finishIntro(st);
      st.tutorialOffer('excuse');
      st.tutorialBegin('today');

      final tasks = [
        ExcuseTask.fromMap({
          'key': 'k1',
          'label': 'L1',
          'date': '2026-09-21',
          'kind': 'short',
          'period': 1,
        }),
        ExcuseTask.fromMap({
          'key': 'k2',
          'label': 'L2',
          'date': '2026-09-22',
          'kind': 'short',
          'period': 1,
        }),
      ];
      final c = TodayController(config: st.config.data);
      c.excuseTasksProvider = ({today}) => tasks;

      await tester.pumpWidget(ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => FixedAppStateController(st)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TodayView(
              controller: c,
              tokens: AppTokens.dark(),
            ),
          ),
        ),
      ));

      expect(st.tutorial, ('excuse', 0));
      expect(st.tutorialAnchored, isTrue);
    });
  });

  test('strings exist for every step', () {
    const routes = {
      'today',
      'timetable',
      'absences',
      'marks',
      'lunches',
      'activity',
      'settings'
    };
    for (final tour in tours.values) {
      for (final step in tour.steps) {
        final keys = [
          'tut_${step.key}_title',
          'tut_${step.key}_body',
          if (step.until.isNotEmpty) 'tut_${step.key}_try',
        ];
        for (final key in keys) {
          for (final lang in ['cs', 'en']) {
            Strings.lang = lang;
            final val = Strings.get(key);
            expect(val != key, isTrue, reason: '$lang/$key');
            expect(val.isNotEmpty, isTrue, reason: '$lang/$key');
          }
        }
      }
      if (tour.route != null) {
        expect(routes, contains(tour.route));
      }
    }
  });

  testWidgets('shell stacks the floating bubble', (tester) async {
    final st = freshState();
    st.wizardDismissed = true;

    await tester.pumpWidget(ProviderScope(
      overrides: [
        appStateProvider.overrideWith(() => FixedAppStateController(st)),
      ],
      child: const MaterialApp(
        home: AppScaffold(
          location: '/today',
          child: Text('Today Content'),
        ),
      ),
    ));

    // Stacks the floating welcome card
    expect(find.byType(TutorialBubble), findsOneWidget);
    expect(find.text(Strings.get('tut_intro_welcome_title')), findsOneWidget);

    // Skip tutorial emits and removes floating bubble
    st.tutorialSkip();
    await tester.pumpAndSettle();
    expect(find.byType(TutorialBubble), findsNothing);
  });

  test('config validation rejects bad progress', () {
    final bad = Map<String, dynamic>.of(core.canonicalDefaults);
    bad['tutorials_done'] = 'intro';
    expect(core.validateConfig(bad).any((p) => p.contains('tutorials_done')), isTrue);

    final good = Map<String, dynamic>.of(core.canonicalDefaults);
    expect(core.validateConfig(good).any((p) => p.contains('tutorials')), isFalse);
  });

  group('marks tour', () {
    const grades = {
      'Matematika': [
        {'Grade': '2', 'Weight': 10, 'Date': '05.09.2026'},
        {'Grade': '1', 'Weight': 10, 'Date': '12.09.2026'},
      ],
      'Fyzika': [
        {'Grade': '3', 'Weight': 5, 'Date': '06.09.2026'},
      ],
    };

    AppState marksState(AppState st) {
      st.data = {'grades': grades};
      st.demoMode = false;
      finishIntro(st);
      return st;
    }

    testWidgets('walkthrough follows the user', (tester) async {
      final st = marksState(freshState());

      Future<void> renderView() async {
        st.tutorialBegin('marks');
        await tester.pumpWidget(ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => FixedAppStateController(st)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(builder: (context) {
                final bubble = tutorialLayer(
                    st, context, tokensFor('dark'), false);
                return Stack(
                  children: [
                    LiveMarksView(
                      tokens: AppTokens.dark(),
                    ),
                    ?bubble,
                  ],
                );
              }),
            ),
          ),
        ));
      }

      await renderView();
      expect(st.tutorial, ('marks', 0));
      expect(st.tutorialAnchored, isTrue); // stats anchored

      st.tutorialNext();
      await renderView();
      expect(st.tutorial, ('marks', 1));
      expect(st.tutorialAnchored, isTrue); // first subject card anchored

      st.selectMarksSubject('Matematika'); // action advances to step 2
      expect(st.tutorial, ('marks', 2));
      await renderView();
      expect(st.tutorialAnchored, isTrue); // need card anchored

      st.tutorialNext();
      await renderView();
      expect(st.tutorial, ('marks', 3));
      expect(st.tutorialAnchored, isTrue); // predictor card anchored

      expect(st.predictAdd('Matematika', '1', 10), isTrue); // action advances to step 4
      expect(st.tutorial, ('marks', 4));
      await renderView();
      // Step 4 place is headerRight -> floats under scale toggle
      expect(find.byType(TutorialBubble), findsOneWidget);

      st.tutorialNext();
      expect(st.tutorialsDone(), contains('marks'));
    });

    testWidgets('no marks no tour', (tester) async {
      final st = freshState();
      finishIntro(st);
      st.tutorialBegin('marks');

      await tester.pumpWidget(ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => FixedAppStateController(st)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LiveMarksView(
              tokens: AppTokens.dark(),
            ),
          ),
        ),
      ));

      expect(st.tutorialCurrent(), isNull);
    });

    testWidgets(
        'F1 skips marks_scale step when active preset provides marks_scale',
        (tester) async {
      final st = marksState(
          freshState({'school_preset_id': 'gekom_2026_2027'}));
      st.tutorialOffer('marks');
      expect(st.tutorial, ('marks', 0));
      expect(st.tutorialVisibleStepIndices(tours['marks']!), [0, 1, 2, 3]);

      st.tutorialNext(); // 1
      st.selectMarksSubject('Matematika'); // -> 2
      st.tutorialNext(); // -> 3 (marks_predict, last visible step)
      expect(st.tutorial, ('marks', 3));

      await tester.pumpWidget(ProviderScope(
        overrides: [
          appStateProvider.overrideWith(() => FixedAppStateController(st)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TutorialBubble(
                state: st,
                tour: tours['marks']!,
                index: 3,
                step: tours['marks']!.steps[3],
                tok: tokensFor('dark'),
              ),
            ),
          ),
        ),
      ));
      expect(find.text(Strings.get('tut_later')), findsOneWidget);

      // Completing prediction finishes the tour directly without marks_scale.
      expect(st.predictAdd('Matematika', '1', 10), isTrue);
      expect(st.tutorialCurrent(), isNull);
      expect(st.tutorialsDone(), contains('marks'));
    });
  });

  test('F1 tut_settings_intro mentions grade conversion under School', () {
    final prev = Strings.lang;
    addTearDown(() => Strings.lang = prev);
    Strings.lang = 'cs';
    expect(Strings.get('tut_settings_intro_body'), contains('Škola'));
    expect(Strings.get('tut_settings_intro_body_narrow'), contains('Škola'));
    Strings.lang = 'en';
    expect(Strings.get('tut_settings_intro_body'), contains('School'));
    expect(Strings.get('tut_settings_intro_body_narrow'), contains('School'));
  });

  group('F1b merged absences tour', () {
    test('planner tour is removed and absences tour has 4 merged steps', () {
      expect(tours.containsKey('planner'), isFalse);
      expect(
        tours['absences']!.steps.map((s) => s.key).toList(),
        ['abs_stats', 'plan_strip', 'plan_pick', 'abs_subject'],
      );
    });

    test('skips plan_strip and plan_pick without timetable', () {
      final st = freshState();
      finishIntro(st);
      expect(st.tutorialVisibleStepIndices(tours['absences']!), [0, 3]);
    });

    Map<String, List<Map<String, Object?>>> fullWeekTimetable() => {
          for (final d in ['07.09.2026', '08.09.2026', '09.09.2026', '10.09.2026', '11.09.2026'])
            d: [
              {'subject': 'Matematika', 'time': '1. 8:00 - 8:45'},
            ],
        };

    test('skips plan_pick when active term has no recommended days', () {
      withClock(Clock.fixed(DateTime(2027, 1, 20, 10, 0)), () {
        final st = freshState({
          'absence_critical_pct': 5.0,
          'sem1_close': '25.01.2027',
        });
        finishIntro(st);
        st.data = {
          // Over limit right before closure -> 0 recommended days while term is active.
          'absence': {'Matematika': 95.0},
          'timetable': fullWeekTimetable(),
        };
        st.demoMode = false;
        final term = st.yearPlan().defaultTerm;
        expect(term, isNotNull);
        expect(term!.recommended, isEmpty);
        expect(st.tutorialVisibleStepIndices(tours['absences']!), [0, 1, 3]);
      });
    });

    testWidgets('LiveAbsencesView offers tour only when recommended days exist',
        (tester) async {
      final blockedNow = DateTime(2027, 1, 20, 10, 0);
      await withClock(Clock.fixed(blockedNow), () async {
        // Without recommended days (over limit): tour is NOT offered.
        final blocked = freshState({
          'absence_critical_pct': 5.0,
          'sem1_close': '25.01.2027',
        });
        finishIntro(blocked);
        blocked.data = {
          'absence': {'Matematika': 95.0},
          'timetable': fullWeekTimetable(),
        };
        blocked.demoMode = false;
        await tester.pumpWidget(ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => FixedAppStateController(blocked)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveAbsencesView(tokens: AppTokens.dark(), now: blockedNow),
            ),
          ),
        ));
        await tester.pump();
        expect(blocked.tutorialCurrent(), isNull);
      });

      final readyNow = DateTime(2026, 9, 10, 10, 0);
      await withClock(Clock.fixed(readyNow), () async {
        // With recommended days: tour IS offered with all 4 steps visible.
        final ready = freshState();
        finishIntro(ready);
        ready.data = {
          'absence': {'Matematika': 2.0},
          'timetable': {
            '11.09.2026': [
              {'subject': 'Matematika', 'time': '1. 8:00 - 8:45'},
            ],
          },
        };
        ready.demoMode = false;
        await tester.pumpWidget(ProviderScope(
          key: const ValueKey('ready'),
          overrides: [
            appStateProvider.overrideWith(() => FixedAppStateController(ready)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveAbsencesView(tokens: AppTokens.dark(), now: readyNow),
            ),
          ),
        ));
        await tester.pump();
        expect(ready.tutorial, ('absences', 0));
        expect(ready.tutorialVisibleStepIndices(tours['absences']!),
            [0, 1, 2, 3]);
      });
    });

    test('tut_abs_subject_body mentions reserve and tut_plan_strip_body mentions even spread in cs and en', () {
      final prev = Strings.lang;
      addTearDown(() => Strings.lang = prev);

      Strings.lang = 'cs';
      expect(Strings.get('tut_abs_subject_body').toLowerCase(),
          contains('rezerv'));
      expect(Strings.get('tut_plan_strip_body').toLowerCase(),
          contains('rovnoměrně'));

      Strings.lang = 'en';
      expect(Strings.get('tut_abs_subject_body').toLowerCase(),
          contains('reserve'));
      expect(Strings.get('tut_plan_strip_body').toLowerCase(),
          contains('evenly'));
    });
  });
}
