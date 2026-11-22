import 'dart:io';

import 'package:app/controllers/app_state.dart' show ActivityLogic, AppState;
import 'package:app/features/activity/activity_live.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/l10n/strings.dart';
import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/features/activity/activity_controller.dart';
import 'package:app/features/activity/activity_view.dart';
import 'package:app/widgets/overlays.dart';

ActivityController _controller() => ActivityController({});

/// The Ahem test font is far wider than the real one; a tall, wide surface
/// builds the whole screen and keeps its rows on one line.
void _surface(WidgetTester t) {
  t.view.physicalSize = const Size(1600, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

Widget _app(Widget child) {
  SnackLog.clear();
  return MaterialApp(home: Scaffold(body: child));
}

void main() {
  group('activity_view', () {
    test('groups and translates automation history', () {
      final items = [
        {
          'ts': '2026-09-25T19:29:08',
          'kind': 'lunch',
          'outcome': 'skipped',
          'source': 'auto',
          'summary': '06.10.2026: order',
          'detail': {
            'day': '06.10.2026',
            'meal': 't6&1&0',
            'reason': 'low_balance'
          },
        },
        {
          'ts': '2026-09-25T19:29:08',
          'kind': 'lunch',
          'outcome': 'skipped',
          'source': 'auto',
          'summary': '05.10.2026: order',
          'detail': {
            'day': '05.10.2026',
            'meal': 't5&1&0',
            'reason': 'low_balance'
          },
        },
        {
          'ts': '2026-09-25T19:29:08',
          'kind': 'lunch',
          'outcome': 'sent',
          'source': 'auto',
          'summary': '07.10.2026: order',
          'detail': {'day': '07.10.2026', 'meal': 't7&1&0'},
        },
        {
          'ts': '2026-09-24T08:00:00',
          'kind': 'excuse',
          'outcome': 'sent',
          'source': 'manual',
          'summary': '18.09.2026 (6.)',
        },
      ];
      final groups = groupAudit(items);
      expect(groups.map((g) => g.length).toList(), [2, 1, 1]);
      expect(auditRowTitle(groups[0]),
          "${Strings.get('audit_kind_lunch')} · ${Strings.get('audit_lunch_order')} ×2");
      final subs = auditRowSubs(groups[0], {});
      expect(subs.join(' '), contains('5. 10., 6. 10.'));
      expect(subs.join(' '), contains(Strings.get('audit_reason_low_balance')));
      expect(
          subs.any((t) => t == 'order' || t.endsWith(': order')), isFalse);
      expect(auditRowSubs(groups[2], {}).join(' '),
          contains('18. 9. 2026 (6.)'));
    });

    test('time helpers', () {
      final now = DateTime(2026, 9, 26, 12, 0);
      expect(agoText(now.subtract(const Duration(seconds: 20)), now),
          Strings.get('ago_now'));
      expect(agoText(now.subtract(const Duration(minutes: 12)), now),
          Strings.format('ago_min', {'n': 12}));
      expect(agoText(now.subtract(const Duration(hours: 2)), now),
          Strings.format('ago_hours', {'n': 2}));
      expect(
          agoText(DateTime(2026, 9, 25, 7, 5), now), '25. 9. 07:05');
      expect(agoText(null, now), '—');
      expect(durationText(47), '47 s');
      expect(durationText(84), '1 min 24 s');
      expect(runWhen({'finished': '25.09. 10:00'}, now), '25.09. 10:00');
    });

    test('log counts a traceback as one error', () {
      expect(
        countLogErrors([
          '[10:00:00] Logging in…',
          '[10:00:05] Refresh failed: TimeoutError: boom',
          '[10:00:05] Traceback (most recent call last):',
          '[10:00:05]   File "x.py", line 1, in f',
          '[10:00:05] TimeoutError: boom',
          '[10:01:00] Obnovování spuštěno (all).',
          '[10:01:30] Warning: could not stamp',
        ]),
        1,
      );
      expect(splitLog('[10:00:05] hi'), ('10:00:05', 'hi'));
      expect(splitLog('no stamp'), ('', 'no stamp'));
    });

    testWidgets('hero shows working then error states', (t) async {
      _surface(t);
      final c = _controller();
      await t.pumpWidget(_app(ActivityView(controller: c)));
      expect(find.text(Strings.get('status_idle')), findsOneWidget);
      c.refreshRunning = true;
      c.currentStep = 'fetching…';
      await t.pumpWidget(_app(ActivityView(controller: c)));
      expect(find.text(Strings.get('refreshing')), findsOneWidget);
      c.refreshRunning = false;
      c.status = 'error';
      c.runs.add(
          {'ok': false, 'finished': 'x', 'started': 'x', 'detail': 'boom'});
      await t.pumpWidget(_app(ActivityView(controller: c)));
      // The headline and the failed run's badge are both 'Chyba' (as in
      // activity.py: `status_error` and `run_failed` share the text).
      expect(find.text(Strings.get('status_error')), findsNWidgets(2));
      expect(find.text('boom'), findsWidgets);
    });

    // tests/test_error_report.py::test_activity_log_copy_redacts_secrets
    test('activityLogCopyRedactsSecrets', () {
      final c = ActivityController({'bakalari_password': 'hunter2-hunter2'})
        ..logLines = [
          '[10:00] login with hunter2-hunter2 failed',
          '[10:01] ok',
        ];
      final body = redactedLogTail(c, 200);
      expect(body, isNot(contains('hunter2-hunter2')));
      expect(body, contains('***'));
      expect(body, contains('ok'));
    });

    test('redacted log tail keeps only the last lines', () {
      final c = _controller()
        ..logLines = [for (var i = 0; i < 250; i++) 'line $i'];
      final lines = redactedLogTail(c).split('\n');
      expect(lines, hasLength(200));
      expect(lines.first, 'line 50');
      expect(lines.last, 'line 249');
    });

    testWidgets('copy log button copies the redacted log only', (t) async {
      _surface(t);
      String? copied;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final c = ActivityController({'bakalari_password': 'hunter2-hunter2'})
        ..logLines = [
          '[10:00] login with hunter2-hunter2 failed',
          '[10:01] ok',
        ];
      await t.pumpWidget(_app(ActivityView(controller: c)));
      await t.tap(find.byTooltip(Strings.get('log_copy_tooltip')));
      await t.pump();
      expect(copied, isNotNull);
      expect(copied, isNot(contains('hunter2-hunter2')));
      expect(copied, contains('***'));
      expect(copied, contains('[10:01] ok'));
      expect(SnackLog.last, Strings.get('error_copied'));
    });

    testWidgets('log card shows error badge and clears', (t) async {
      _surface(t);
      final c = _controller()
        ..logLines = [
          '[10:00:05] Refresh failed: TimeoutError: boom',
        ];
      await t.pumpWidget(_app(ActivityView(controller: c)));
      expect(
          find.text(Strings.format('log_errors', {'n': 1})), findsOneWidget);
      await t.tap(find.byTooltip(Strings.get('clear_log')));
      await t.pump();
      expect(c.logLines, isEmpty);
    });

    testWidgets('run timeline lists runs, newest last', (t) async {
      _surface(t);
      final c = _controller()
        ..runs = [
          {'ok': true, 'scope': 'all', 'at': '2026-09-26T10:00:00'},
          {'ok': false, 'scope': 'strava', 'detail': 'boom'},
        ];
      await t.pumpWidget(_app(ActivityView(controller: c)));
      expect(find.text(Strings.get('run_history').toUpperCase()), findsOneWidget);
      expect(find.textContaining('boom'), findsOneWidget);
    });
  });

  group('B4 run time', () {
    test('runTime returns null for date-only legacy at and parses full ISO timestamps',
        () {
      expect(runTime({'at': '2026-11-15'}), isNull);
      expect(runTime({'at': ''}), isNull);
      expect(runTime({}), isNull);
      expect(
        runTime({'at': '2026-11-15T14:35:20'}),
        DateTime(2026, 11, 15, 14, 35, 20),
      );
      expect(
        runTime({'at': '2026-11-15 14:35:20'}),
        DateTime(2026, 11, 15, 14, 35, 20),
      );
      final now = DateTime(2026, 11, 15, 15, 0);
      expect(
        runWhen({'at': '2026-11-15', 'finished': '15.11. 14:35'}, now),
        '15.11. 14:35',
      );
    });

    testWidgets(
        'AppState.finishRun stores full timestamp and ActivityView shows real time, never 00:00',
        (t) async {
      _surface(t);
      final dir = Directory.systemTemp.createTempSync('strakalari_b4_');
      setEnvironmentOverride({
        'STRAKALARI_DATA_DIR': dir.path,
        'STRAKALARI_NO_KEYRING': '1',
      });
      addTearDown(() {
        setEnvironmentOverride(null);
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      Strings.lang = 'cs';

      final finished = DateTime(2026, 11, 15, 14, 35, 20);
      final started = DateTime(2026, 11, 15, 14, 35, 15);
      final s = AppState();
      s.runs.add({
        'ok': true,
        'scope': 'strava',
        'finished': '14.11. 16:20',
        'at': '2026-11-14',
        'seconds': 2,
        'detail': 'legacy',
      });
      withClock(
        Clock.fixed(finished),
        () => s.finishRun(started, 'all', true, 'OK'),
      );

      expect(s.runs, hasLength(2));
      expect(runTime(s.runs.last), finished);

      await t.pumpWidget(
        _app(
          ActivityView(
            controller: activityControllerFor(s),
            nowFor: () => DateTime(2026, 11, 18, 9, 0),
          ),
        ),
      );

      expect(find.textContaining('00:00'), findsNothing);
      expect(find.textContaining('14:35'), findsAtLeastNWidgets(1));
      expect(find.text('14.11. 16:20'), findsOneWidget);
    });
  });

  group('P10 narrow hero full-width controls', () {
    testWidgets(
        'scope chips and refresh button span card width instead of right-aligning',
        (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final savedLang = Strings.lang;
      addTearDown(() => Strings.lang = savedLang);
      Strings.lang = 'cs';

      final tok = AppTokens.dark();
      final c = _controller()
        ..runs = [
          {'ok': true, 'scope': 'all', 'at': '2026-11-15T18:56:00', 'detail': '10 předmětů'},
        ];
      await t.pumpWidget(MaterialApp(
        theme: tok.toThemeData(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: ActivityView(controller: c, narrow: true),
          ),
        ),
      ));
      await t.pump();

      final segFinder = find.byType(SegmentedButton<String>);
      final refreshFinder = find.ancestor(
        of: find.text(Strings.get('refresh_data')),
        matching: find.byWidgetPredicate((w) => w is ElevatedButton),
      );
      expect(segFinder, findsOneWidget);
      expect(refreshFinder, findsOneWidget);

      // Card inner width: 390 - 2*12 (page pad) - 2*tok.pad (card pad).
      final expectedInnerWidth = 390.0 - 24.0 - 2 * tok.pad;
      final expectedLeft = 12.0 + tok.pad;

      final segRect = t.getRect(segFinder);
      final btnRect = t.getRect(refreshFinder);
      expect(segRect.left, closeTo(expectedLeft, 2.0));
      expect(segRect.width, closeTo(expectedInnerWidth, 2.0));
      expect(btnRect.left, closeTo(expectedLeft, 2.0));
      expect(btnRect.width, closeTo(expectedInnerWidth, 2.0));
    });

    test('auditRowSubs translates free_day and planned cancel reasons', () {
      final savedLang = Strings.lang;
      addTearDown(() => Strings.lang = savedLang);

      for (final lang in ['cs', 'en']) {
        Strings.lang = lang;
        final freeSubs = auditRowSubs([
          {
            'ts': '2026-10-01T09:00:00',
            'kind': 'lunch',
            'outcome': 'sent',
            'source': 'auto',
            'detail': {
              'day': '06.10.2026',
              'meal': 'a&-1&0',
              'reason': 'free_day',
            },
          },
        ], {});
        expect(freeSubs, contains(Strings.get('audit_reason_free_day')));

        final plannedSubs = auditRowSubs([
          {
            'ts': '2026-10-01T09:00:00',
            'kind': 'lunch',
            'outcome': 'sent',
            'source': 'auto',
            'detail': {
              'day': '07.10.2026',
              'meal': 'b&-1&0',
              'reason': 'planned',
            },
          },
        ], {});
        expect(plannedSubs, contains(Strings.get('audit_reason_planned')));
      }
    });

    testWidgets('F6 Aktivita shows quick-check rollup line, scope_quick badge, and keeps quick out of manual chips',
        (tester) async {
      final savedLang = Strings.lang;
      addTearDown(() => Strings.lang = savedLang);
      Strings.lang = 'cs';
      final now = DateTime(2026, 11, 20, 10, 15);
      final c = ActivityController({'check_interval_minutes': 5})
        ..quickChecksToday = 14
        ..lastQuickCheck = DateTime(2026, 11, 20, 10, 10)
        ..runs = [
          {
            'started': '10:05:00',
            'finished': '20.11. 10:05',
            'at': '2026-11-20T10:05:00',
            'seconds': 1,
            'ok': true,
            'scope': 'quick',
            'detail': '1 nová známka',
            'cancelled': false,
          },
        ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ActivityView(
              controller: c,
              nowFor: () => now,
              updatedLabel: 'Kontrola: 10:10 · Úplná: 07:00',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('activity:quick_checks')), findsOneWidget);
      expect(find.textContaining('14×'), findsOneWidget);
      expect(find.textContaining('10:10'), findsWidgets);
      expect(find.textContaining(Strings.get('scope_quick')), findsOneWidget);
      // Manual refresh SegmentedButton must NOT include 'quick' (only all / bakalari / strava).
      final seg = tester.widget<SegmentedButton<String>>(
        find.byType(SegmentedButton<String>),
      );
      expect(seg.segments.map((s) => s.value).toList(),
          ['all', 'bakalari', 'strava']);
    });
  });
}
