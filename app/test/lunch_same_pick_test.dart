import 'dart:convert';
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of `tests/test_lunch_same_pick.py`.
const _day = '08.09.2026';
const _other = '09.09.2026';
const _noLunch = 'T1&-1&0';

void main() {
  late Directory dir;
  late AppState state;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_same_pick_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path, 'STRAKALARI_NO_KEYRING': '1'});
    state = AppState(configData: {'use_strava': true}, data: {})
      ..demoMode = false
      ..webOrders = {_day: 'T1&A&0'}
      ..orders.addAll({_day: 'T1&A&0'})
      ..pendingOrders.clear();
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  test('repickingTheOrderedMealIsNoChange', () {
    withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () {
      expect(state.orderLunch(_day, 'T1&A&0'), isTrue);
      expect(state.pendingOrders, isEmpty);
      expect(state.pendingLunchCount, 0);
      expect(state.lunchIsChange(_day), isFalse);
      expect(state.submitOrders(), isFalse);
    });
  });

  test('aDifferentMealIsAChangeUntilPickedBack', () {
    withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () {
      state.orderLunch(_day, 'T1&B&0');
      expect(state.pendingOrders, {_day});
      expect(state.pendingLunchCount, 1);
      state.orderLunch(_day, 'T1&A&0');
      expect(state.pendingOrders, isEmpty);
      expect(state.pendingLunchCount, 0);
    });
  });

  test('noLunchComparesWithTheWebToo', () {
    withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () {
      state.orderLunch(_other, _noLunch);
      expect(state.pendingOrders.contains(_other), isFalse);
      state.orderLunch(_day, _noLunch);
      expect(state.pendingOrders.contains(_day), isTrue);
      expect(state.pendingLunchCount, 1);
    });
  });

  test('submitSendsOnlyPicksThatDiffer', () {
    withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () {
      state.spawn = (job, name) {};
      state.pendingOrders.addAll([_day, _other]);
      state.orders[_other] = 'T2&C&0';
      expect(state.submitOrders(), isTrue);
      expect(
        state.logLines.any((l) => l.endsWith('${Strings.get('orders_sending')} (1)')),
        isTrue,
      );
    });
  });

  test('refreshUnstagesAPickTheWebNowReports', () {
    withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () {
      state.orderLunch(_day, 'T1&B&0');
      expect(state.pendingOrders.contains(_day), isTrue);
      File('${dir.path}/data_cache.json').writeAsStringSync(jsonEncode({
        'strava_ordered': {'8.9.2026': 'T1&B&0'},
      }));
      state.reloadCache();
      expect(state.pendingOrders, isEmpty);
      expect(state.pendingLunchCount, 0);
      expect(state.orders[_day], 'T1&B&0');
    });
  });
}
