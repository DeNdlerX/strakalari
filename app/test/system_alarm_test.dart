// Port of test_open_system_alarm_* (tests/test_mobile.py). The intent is
// built in Java now (StrakalariChannel.openSystemAlarm): Dart sends the
// typed values as given, Java maps Python's weekday (Monday = 0) to
// java.util.Calendar days and falls back to the alarm list.
import 'dart:io';

import 'package:app/platform/android/android_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidChannel.channel, (c) async {
      calls.add(c);
      return true;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(AndroidChannel.channel, null));

  const java = 'android/app/src/main/java/io/github/dendlerx/strakalari/android/StrakalariChannel.java';

  test('openSystemAlarmSendsTypedExtras', () async {
    expect(await const AndroidChannel().openSystemAlarm(6, 45, message: 'Strakaláři · Matematika'), isTrue);
    expect(calls.single.arguments,
        {'hour': 6, 'minute': 45, 'message': 'Strakaláři · Matematika', 'weekday': null});
    final code = File(java).readAsStringSync();
    for (final put in [
      'extras.putInt(AlarmClock.EXTRA_HOUR, hour)',
      'extras.putInt(AlarmClock.EXTRA_MINUTES, minute)',
      'extras.putString(AlarmClock.EXTRA_MESSAGE, message)',
      'extras.putBoolean(AlarmClock.EXTRA_SKIP_UI, false)',
      'new Intent(AlarmClock.ACTION_SET_ALARM)',
      'Intent.FLAG_ACTIVITY_NEW_TASK',
      // No app takes a new alarm: at least the alarm list opens.
      'new Intent(AlarmClock.ACTION_SHOW_ALARMS)',
    ]) {
      expect(code, contains(put), reason: put);
    }
  });

  test('openSystemAlarmWeekdayBecomesClockDays', () async {
    await const AndroidChannel().openSystemAlarm(7, 0, message: 'x', weekday: 0);
    expect((calls.single.arguments as Map)['weekday'], 0);
    final code = File(java).readAsStringSync();
    // Monday (0) → Calendar.MONDAY (2) … Sunday (6) → Calendar.SUNDAY (1).
    expect(code, contains('CALENDAR_DAYS = {2, 3, 4, 5, 6, 7, 1}'));
    expect(code, contains('days.add(CALENDAR_DAYS[weekday % 7])'));
    expect(code, contains('if (weekday != null)')); // no weekday: no EXTRA_DAYS
  });
}
