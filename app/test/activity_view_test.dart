import 'package:app/l10n/strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
