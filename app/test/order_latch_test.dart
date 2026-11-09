import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of `tests/test_order_latch.py`:
/// `submitOrders()` claims the `order_running` latch; every staging exit
/// that does NOT hand the payload to the worker must release it again,
/// or Odeslat stays dead until restart. `submitExcuse()` must map the
/// task kind `early` to the hour-based `soon` web excuse type (the same
/// form as `soon`; `income` is late arrival).
class _StubApp extends Strakalari {
  final void Function(Map<String, Object?> excuse, String? customText)
      onExcuse;

  _StubApp(this.onExcuse);

  @override
  String get excuseMode => '';

  @override
  Future<String> sendExcuseOutcome(
      Map<String, Object?> excuse, [String? customText]) async {
    onExcuse(excuse, customText);
    return 'sent';
  }

  @override
  void close() {}
}

void main() {
  late Directory dir;
  late AppState state;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_latch_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path});
    state = AppState(configData: {'use_strava': true}, data: {})
      ..demoMode = false;
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  test('emptyPayloadReleasesLatch', () {
    // Staged pick on a closed day filters to an empty payload -> false,
    // but the latch must be free for the next attempt.
    withClock(Clock.fixed(DateTime(2026, 9, 10, 10, 0)), () {
      state.orders['08.09.2026'] = 'm1';
      state.pendingOrders.add('08.09.2026'); // only staged picks are sent
      expect(state.submitOrders(), isFalse);
      expect(state.orderRunning, isFalse);
    });
    // A later (open) attempt must not be stuck behind the leaked latch.
    withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () {
      state.spawn = (job, name) {};
      expect(state.submitOrders(), isTrue);
      expect(state.orderRunning, isTrue);
    });
  });

  test('demoNoCredentialsReleasesLatch', () {
    withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () {
      state.orders['08.09.2026'] = 'm1';
      state.pendingOrders.add('08.09.2026');
      state.demoMode = true;
      expect(state.submitOrders(), isFalse);
      expect(state.orderRunning, isFalse);
    });
  });

  test('nothingPendingReleasesLatch', () {
    state.orders.clear();
    state.cancelledLunches.clear();
    expect(state.submitOrders(), isFalse);
    expect(state.orderRunning, isFalse);
  });

  for (final (kind, expected) in const [
    ('early', 'soon'),
    ('soon', 'soon'),
    ('late', 'income'),
    ('short', 'days and hours'),
  ]) {
    test('excuseKindToWebType ($kind -> $expected)', () async {
      final captured = <String, Object?>{};
      final jobs = <Future<void> Function()>[];
      state.createApp = ({onLog, configData}) => _StubApp((excuse, customText) {
            captured.addAll(excuse);
            captured['custom_text'] = customText;
          });
      state.spawn = (job, name) => jobs.add(job);
      state.demoMode = false;
      final task = <String, Object?>{
        'key': 'k-$kind',
        'kind': kind,
        'label': 'M',
        'date': '2026-09-10',
        'period': 2,
      };
      expect(state.submitExcuse(task, 'Omluvte prosím.'), isTrue);
      expect(jobs, hasLength(1));
      await jobs.single();
      expect(captured['type'], expected);
      expect(captured['starting_lesson'], 2);
      expect(captured['ending_lesson'], 2);
      expect(captured['custom_text'], 'Omluvte prosím.');
      expect(state.sendingExcuses, isEmpty);
      expect(state.excuseLog.any((e) => e['key'] == 'k-$kind'), isTrue);
    });
  }
}
