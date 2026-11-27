// C-S3: a refused channel call prints the same `Warning: could not …`
// line Python's core/android.py prints, instead of failing silently.
import 'dart:async';

import 'package:app/platform/android/android_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<List<String>> printed(Future<void> Function() body) async {
    final lines = <String>[];
    await runZoned(body, zoneSpecification: ZoneSpecification(print: (_, _, _, line) => lines.add(line)));
    return lines;
  }

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        AndroidChannel.channel, (call) async => throw PlatformException(code: 'X', message: 'denied'));
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidChannel.channel, null);
  });

  test('refusedCallsPrintPythonsWarnings', () async {
    const ch = AndroidChannel();
    expect(await printed(() => ch.scheduleWake(DateTime(2026, 11, 12))),
        ['Warning: could not schedule the next wake-up (PlatformException: denied)']);
    expect(await printed(() => ch.stopBackground()),
        ['Warning: could not stop the background service (denied)']);
    expect(await printed(() => ch.notify(title: 't', text: 'x', channelName: 'c')),
        ['Warning: notification failed (PlatformException: denied)']);
    // Probes stay silent, like Python.
    expect(await printed(() => ch.notificationsEnabled()), isEmpty);
    expect(await printed(() => ch.cancelWake()), isEmpty);
    expect(await printed(() => ch.openBatterySettings()),
        ['Warning: could not open the battery settings (denied)']);
    // Can't tell: no battery warning to show.
    expect(await ch.batteryUnrestricted(), isTrue);
  });
}
