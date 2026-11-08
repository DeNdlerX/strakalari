import 'package:flutter_test/flutter_test.dart';

import 'package:app/features/activity/activity_controller.dart';

ActivityController _controller() => ActivityController({});

void main() {
  group('activity_state', () {
    test('status kind transitions', () {
      final c = _controller();
      expect(c.statusKind(), 'idle');
      c.refreshRunning = true;
      expect(c.statusKind(), 'working');
      c.refreshRunning = false;
      c.runs.add({'ok': true, 'finished': 'now', 'started': 'now'});
      expect(c.statusKind(), 'ok');
      c.status = 'error';
      c.refreshRunning = true;
      expect(c.statusKind(), 'working');
      c.refreshRunning = false;
      expect(c.statusKind(), 'error');
    });

    test('manual sends show as working', () {
      final c = _controller();
      expect(c.sendingLabel, '');
      c.sendingExcuses.add('2026-09-25|1|M');
      expect(c.sendingLabel, 'excuse_sending');
      expect(c.statusKind(), 'working');
      c.sendingExcuses.clear();
      c.orderRunning = true;
      expect(c.sendingLabel, 'orders_sending');
      expect(c.statusKind(), 'working');
      c.orderRunning = false;
      expect(c.sendingLabel, '');
      expect(c.statusKind(), 'idle');
    });

    test('last run label', () {
      final c = _controller();
      expect(c.lastRunLabel, '—');
      c.runs.add({'ok': true, 'finished': '07.09. 10:05'});
      expect(c.lastRunLabel.startsWith('✓'), isTrue);
      c.runs.add({'ok': false, 'finished': '07.09. 11:00'});
      expect(c.lastRunLabel.startsWith('✗'), isTrue);
    });

    test('next run label', () {
      final c = _controller();
      expect(c.nextRunLabel(), '—');
      c.schedulerLastRun =
          DateTime.now().subtract(const Duration(minutes: 30));
      final label = c.nextRunLabel();
      expect(label, isNot('—'));
      expect(label.contains('.'), isTrue);
    });

    test('log ring buffer caps', () {
      final c = _controller();
      var emits = 0;
      c.addListener(() => emits++);
      for (var i = 0; i < 350; i++) {
        c.logLines.add('line $i');
      }
      c.log('final');
      expect(c.logLines, hasLength(300));
      expect(c.logLines.last.endsWith('final'), isTrue);
      expect(emits, 1);
    });

    test('start refresh normalizes scope and guards busy', () {
      final c = _controller();
      expect(c.startRefresh('bogus'), isTrue);
      expect(c.refreshRunning, isTrue);
      expect(c.lastScope, 'all');
      expect(c.startRefresh('all'), isFalse); // busy guard
      c.refreshRunning = false;
      final started = <String>[];
      final d = ActivityController({}, startRefreshHook: (s) {
        started.add(s);
        return true;
      });
      d.refreshRunning = true;
      expect(d.startRefresh('all'), isFalse);
    });

    test('cancel refresh is a no-op when idle', () {
      final c = _controller();
      var progress = 0;
      c.addProgressListener(() => progress++);
      c.cancelRefresh();
      expect(progress, 0);
      c.refreshRunning = true;
      c.cancelRefresh();
      expect(c.cancelRequested, isTrue);
    });

    test('worker log emits directly, throttles ticks to progress', () {
      final c = _controller();
      var full = 0;
      var progress = 0;
      c.addListener(() => full++);
      c.addProgressListener(() => progress++);
      var t = 1000.0;
      c.monotonicClock = () => t;
      c.workerLog('first');
      expect(full, 1);
      t += 0.2;
      c.workerLog('second');
      expect(full, 1);
      expect(progress, 1);
      t += 1.5;
      c.workerLog('third');
      expect(full, 2);
    });

    test('report error records and can be acknowledged', () {
      final c = _controller();
      c.log('hello');
      final report = c.reportError('refresh',
          error: Exception('boom'), message: 'Refresh failed');
      expect(report['summary'], 'Refresh failed');
      expect(c.status, 'error');
      expect(c.errorDialogPending, isTrue);
      expect(c.errorReportText(), contains('Refresh failed'));
      c.acknowledgeError();
      expect(c.errorDialogPending, isFalse);
    });

    test('update banner dismiss', () {
      final c = _controller();
      expect(c.updateBanner, isNull);
      c.updateInfo = {'version': '1.2.0'};
      expect(c.updateBanner, isNotNull);
      c.dismissUpdate();
      expect(c.updateBanner, isNull);
    });
  });
}
