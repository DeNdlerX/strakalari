import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/widgets/overlays.dart';

void main() {
  group('tutorial', () {
    TutorialController fresh() => TutorialController({});

    TutorialController finishIntro(TutorialController c) {
      expect(c.offer('intro'), isTrue);
      c.skip();
      return c;
    }

    group('gating', () {
      test('intro comes first', () {
        final c = fresh();
        expect(c.offer('excuse'), isFalse);
        expect(c.offer('intro'), isTrue);
        // One tour at a time.
        expect(c.offer('excuse'), isFalse);
      });

      test('contextual tour after intro', () {
        final c = finishIntro(fresh());
        expect(c.offer('excuse'), isTrue);
        expect((c.current()![0] as Tour).id, 'excuse');
      });

      test('disabled offers nothing', () {
        final c = fresh();
        expect(c.setEnabled(false), isTrue);
        expect(c.offer('intro'), isFalse);
      });

      test('turning off drops the active tour', () {
        final c = fresh();
        c.offer('intro');
        c.setEnabled(false);
        expect(c.current(), isNull);
      });

      test('unknown tour is ignored', () {
        final c = finishIntro(fresh());
        expect(c.offer('nope'), isFalse);
      });
    });

    group('progress', () {
      test('skip is remembered', () {
        final c = finishIntro(fresh());
        expect(c.done(), contains('intro'));
        expect(c.offer('intro'), isFalse);
      });

      test('next through the end marks done', () {
        final c = fresh();
        c.offer('intro');
        for (final _ in kTours['intro']!.steps) {
          c.next();
        }
        expect(c.current(), isNull);
        expect(c.done(), contains('intro'));
      });

      test('back stays in bounds', () {
        final c = fresh();
        c.offer('intro');
        c.back();
        expect(c.active, ['intro', 0]);
        c.next();
        c.back();
        expect(c.active, ['intro', 0]);
      });

      test('suspend does not mark done', () {
        final c = finishIntro(fresh());
        c.offer('excuse');
        c.suspend();
        expect(c.done(), isNot(contains('excuse')));
        expect(c.offer('excuse'), isTrue);
        expect(c.active, ['excuse', 0]);
      });

      test('event skips ahead to the waiting step', () {
        final c = finishIntro(fresh());
        c.offer('excuse'); // step 0 has no `until`
        c.event('excuse_done');
        expect(c.active, ['excuse', 2]);
      });

      test('unrelated event is ignored', () {
        final c = finishIntro(fresh());
        c.offer('excuse');
        c.event('orders_sent');
        expect(c.active, ['excuse', 0]);
      });

      test('event on last waiting step finishes', () {
        final c = finishIntro(fresh());
        c.offer('lunches');
        c.event('lunch_picked');
        c.event('orders_sent');
        expect(c.active, ['lunches', 2]);
        c.next();
        expect(c.done(), contains('lunches'));
      });

      test('event without tour is harmless', () {
        TutorialController({}).event('excuse_done');
      });

      test('reset replays everything', () {
        final c = finishIntro(fresh());
        c.setEnabled(false);
        expect(c.reset(), isTrue);
        expect(c.enabled(), isTrue);
        expect(c.done(), isEmpty);
      });

      test('persist hook records done tours', () {
        final saved = <Map<String, dynamic>>[];
        final c = TutorialController({}, persist: (u) {
          saved.add(u);
          return true;
        });
        c.offer('intro');
        c.skip();
        expect(saved.single['tutorials_done'], ['intro']);
      });
    });

    group('rendering', () {
      testWidgets('anchor passthrough without tour', (t) async {
        final c = fresh();
        await t.pumpWidget(MaterialApp(
            home: TutorialAnchor(
                controller: c,
                anchorKey: 'excuse_card',
                child: const Text('x'))));
        // No ring/bubble: plain text only.
        expect(find.byType(Card), findsNothing);
        expect(find.text('x'), findsOneWidget);
      });

      testWidgets('anchor wraps first match with bubble', (t) async {
        final c = finishIntro(fresh());
        c.offer('excuse');
        Widget w(String label) => MaterialApp(
                home: TutorialAnchor(
                    controller: c,
                    anchorKey: 'excuse_card',
                    child: Text(label)));
        await t.pumpWidget(w('a'));
        // Ring + inline bubble.
        expect(find.byType(Card), findsOneWidget);
        expect(
            find.text(Strings.get('tut_excuse_pick_title')), findsOneWidget);
      });

      testWidgets('every step bubble builds', (t) async {
        for (final tour in kTours.values) {
          for (var i = 0; i < tour.steps.length; i++) {
            final c = fresh();
            await t.pumpWidget(MaterialApp(
                home: Scaffold(
                    body: TutorialBubble(
                        controller: c,
                        tour: tour,
                        index: i,
                        step: tour.steps[i]))));
            expect(find.byType(TutorialBubble), findsOneWidget);
          }
        }
      });
    });

    test('strings exist for every step', () {
      const routes = {
        'today',
        'timetable',
        'absences',
        'marks',
        'planner',
        'lunches',
        'activity',
        'settings'
      };
      for (final tour in kTours.values) {
        for (final step in tour.steps) {
          for (final key in [
            'tut_${step.key}_title',
            'tut_${step.key}_body',
            if (step.until.isNotEmpty) 'tut_${step.key}_try',
          ]) {
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
  });
}
