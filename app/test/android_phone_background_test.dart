// Ports of TestPhoneBackground (tests/test_mobile.py), TestPhoneWiring and
// TestAndroidBridge (tests/test_status_notification.py): the phone's
// background service, its overview notification and the wake-up, wired
// like Python's `_setup_phone_background`, against a fake channel.
import 'dart:convert';
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/platform/android/android_channel.dart';
import 'package:app/platform/startup.dart';
import 'package:app/tutorial/tours.dart';
import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _key(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<MethodCall> calls;
  final now = DateTime(2026, 11, 12, 7, 0); // a Thursday, before the lesson

  setUp(() {
    Strings.lang = 'cs';
    setLanguage('cs');
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidChannel.channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'startBackground' || 'scheduleWake' || 'updateBackgroundNotification' => true,
        'keepAwake' => 1,
        _ => null,
      };
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(AndroidChannel.channel, null);
  });

  List<String> methods() => [for (final c in calls) c.method];
  List<Map<Object?, Object?>> started() => [
        for (final c in calls)
          if (c.method == 'startBackground') (c.arguments as Map)['texts'] as Map<Object?, Object?>
      ];

  /// `_wire`: background running on, every 30 minutes.
  Future<(AppState, PeriodicRunner, PhoneBackground)> wire({bool on = true, AppState? state}) async {
    final s = state ?? AppState(data: {});
    s.wizardDismissed = true;
    s.save({'run_in_background': on, 'check_interval_minutes': 30});
    final runner = PeriodicRunner(intervalMinutes: 30);
    final phone = PhoneBackground(s, runner, const AndroidChannel(),
        onAndroid: () => true, startNotifier: false);
    phone.start();
    await _settle();
    return (s, runner, phone);
  }

  group('TestPhoneBackground', () {
    test('startsServiceWithTextsAndWakeUp', () async {
      await wire();
      final texts = started().single;
      expect('${texts['text']}', contains('30'));
      expect('${texts['boot_text']}', isNotEmpty);
      expect('${texts['channel']}', isNotEmpty);
      expect(methods(), contains('requestNotificationPermission'));
      expect(methods(), contains('scheduleWake'));
    });

    test('switchingOffStopsAndOnRestarts', () async {
      final (s, _, _) = await wire();
      calls.clear();
      s.save({'run_in_background': false});
      await _settle();
      expect(methods().where((m) => m != 'updateBackgroundNotification'), ['stopBackground']);
      calls.clear();
      s.save({'theme': 'dark'}); // unrelated save: nothing happens
      await _settle();
      expect(methods().where((m) => m == 'startBackground' || m == 'stopBackground'), isEmpty);
      s.save({'run_in_background': true});
      await _settle();
      expect(started(), isNotEmpty);
    });

    test('everyRunSetsTheNextWakeUp', () async {
      final (_, runner, _) = await wire();
      calls.clear();
      runner.addJob('refresh', () => 'ok');
      await runner.runAllOnce();
      await _settle();
      expect(methods(), contains('scheduleWake'));
    });

    test('scheduleWakeUsesRunnersFractionalInterval', () async {
      final s = AppState(data: {})..wizardDismissed = true;
      s.save({'run_in_background': true, 'check_interval_minutes': 2.5});
      final runner = PeriodicRunner(intervalMinutes: 2.5);
      final phone = PhoneBackground(s, runner, const AndroidChannel(),
          onAndroid: () => true, startNotifier: false);
      runner.lastRun = now;
      calls.clear();
      await withClock(Clock.fixed(now), () => phone.scheduleWake());
      final wake = calls.singleWhere((c) => c.method == 'scheduleWake');
      final epochSeconds = (wake.arguments as Map)['epochSeconds'] as double;
      final expected = now.add(const Duration(minutes: 2, seconds: 40));
      expect(epochSeconds, expected.millisecondsSinceEpoch / 1000.0);
    });
  });

  group('TestPhoneWiring', () {
    /// `phone_state`: a lunch ordered for today, a lesson ahead, one excuse.
    AppState phoneState() {
      final key = _key(now);
      final s = AppState(data: {
        'timetable': {
          key: [
            {'time': '1 (8:00 - 8:45)', 'subject': 'Matematika'}
          ]
        },
        'strava_meals': {
          key: {'t0&-1&0': 'x', 't0&1&0': 'oběd 1 - Řízek'}
        },
        'strava_ordered': {key: 't0&1&0'},
        'last_updated': '$key 07:00:00',
      });
      s.demoMode = false;
      s.webOrders = {key: 't0&1&0'};
      s.excuseTasksOverride = () => [
            {'key': 'a'}
          ];
      return s;
    }

    test('theServiceStartsWithTheOverview', () async {
      await withClock(Clock.fixed(now), () async {
        await wire(state: phoneState());
        final texts = started().single;
        final rows = {
          for (final r in jsonDecode('${texts['rows']}') as List) (r as Map)['kind']: r
        };
        expect(rows['lunch']!['label'], 'Oběd dnes');
        expect('${rows['lunch']!['value']}', startsWith('Oběd 1 - Řízek'));
        expect(rows['excuses']!['value'], '1');
        expect('${texts['title']}', isNotEmpty);
        expect(texts['sub'], '');
        expect('${texts['channel']}', isNotEmpty);
      });
    });

    test('settingsChangesReachTheNotification', () async {
      await withClock(Clock.fixed(now), () async {
        final (s, _, phone) = await wire(state: phoneState());
        calls.clear();
        s.save({'background_notification_items': <String>[]});
        await _settle();
        expect(phone.notifier.tick(now.add(const Duration(minutes: 1))), isTrue);
        await _settle();
        final update = calls.lastWhere((c) => c.method == 'updateBackgroundNotification');
        final args = update.arguments as Map;
        expect('${args['text']}', contains('30')); // the plain "running in the background"
        expect(args['sub'], '');
        expect(args['rows'], '');
        expect(started(), isEmpty); // updated in place, no new start
      });
    });

    test('newDataReachesTheNotification', () async {
      await withClock(Clock.fixed(now), () async {
        final (s, _, phone) = await wire(state: phoneState());
        s.excuseTasksOverride = () => [];
        phone.notifier.poke(); // `state._emit()`: the app pokes on every change
        calls.clear();
        expect(phone.notifier.tick(now.add(const Duration(minutes: 1))), isTrue);
        await _settle();
        final args = calls.lastWhere((c) => c.method == 'updateBackgroundNotification').arguments as Map;
        final rows = '${args['rows']}'.isEmpty ? <Object?>[] : jsonDecode('${args['rows']}') as List;
        for (final r in rows) {
          if ((r as Map)['kind'] == 'excuses') expect(r['value'], '0');
        }
      });
    });

    test('nothingIsPostedWithBackgroundRunningOff', () async {
      await withClock(Clock.fixed(now), () async {
        final (s, _, phone) = await wire(state: phoneState());
        s.save({'run_in_background': false});
        await _settle();
        calls.clear();
        expect(phone.notifier.tick(now.add(const Duration(minutes: 1))), isFalse);
        await _settle();
        expect(methods(), isNot(contains('updateBackgroundNotification')));
      });
    });
  });

  group('TestAndroidBridge', () {
    const java = 'android/app/src/main/java/io/github/dendlerx/strakalari/android';

    test('updateGoesToTheStatusReceiver', () async {
      expect(
          await const AndroidChannel()
              .updateBackgroundNotification(title: 'Oběd dnes', text: 'Řízek', rows: '[]'),
          isTrue);
      final call = calls.single;
      expect(call.method, 'updateBackgroundNotification');
      expect(call.arguments, {'title': 'Oběd dnes', 'text': 'Řízek', 'sub': '', 'rows': '[]'});
      // The Java side sends it to StatusReceiver with these extras.
      final channel = File('$java/StrakalariChannel.java').readAsStringSync();
      expect(channel, contains('StatusReceiver'));
    });

    test('theServiceStartCarriesTheTextsInABundle', () async {
      expect(await const AndroidChannel().startBackground({'title': 'Další hodina', 'rows': '[]'}), isTrue);
      expect(calls.single.arguments, {
        'texts': {'title': 'Další hodina', 'rows': '[]'}
      });
    });

    test('noOpOffAndroid', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidChannel.channel, null); // no plugin
      expect(await const AndroidChannel().updateBackgroundNotification(title: 't', text: 'x'), isFalse);
    });

    test('javaSideMatches', () {
      final receiver = File('$java/StatusReceiver.java').readAsStringSync();
      expect(receiver, contains('"io.github.dendlerx.strakalari.android.ACTION_UPDATE_STATUS"'));
      for (final key in ['title', 'text', 'sub', 'rows']) {
        expect(receiver, contains('getStringExtra("$key")'), reason: key);
      }
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(RegExp(r'android:name="[\w.]+\.StatusReceiver"\s+android:exported="false"').hasMatch(manifest),
          isTrue);
      final service = File('$java/KeepAliveService.java').readAsStringSync();
      expect(service, contains('"sub"'));
      expect(File('$java/Notifications.java').readAsStringSync(), contains('setSubText'));
      expect(service, contains('"rows"'));
      expect(service, contains('StatusViews.apply'));
    });

    test('notificationLayoutResourcesExist', () {
      // Every resource StatusViews names exists, and every row kind has an icon.
      final views = File('$java/StatusViews.java').readAsStringSync();
      const res = 'android/app/src/main/res';
      for (final m in RegExp(r'R\.(layout|drawable)\.(\w+)').allMatches(views)) {
        expect(File('$res/${m.group(1)}/${m.group(2)}.xml').existsSync(), isTrue, reason: m.group(2));
      }
      final layouts = Directory('$res/layout')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.xml'))
          .map((f) => f.readAsStringSync())
          .join();
      for (final name in {for (final m in RegExp(r'R\.id\.(\w+)').allMatches(views)) m.group(1)!}) {
        expect(layouts, contains('android:id="@+id/$name"'), reason: name);
      }
      for (final item in items) {
        if (item != 'updated') expect(views, contains('case "$item":'), reason: item);
      }
      final tint = RegExp(r'android:tint="@color/(\w+)"');
      final colors = File('$res/values/strakalari_colors.xml').readAsStringSync();
      final night = File('$res/values-night/strakalari_colors.xml').readAsStringSync();
      for (final icon in Directory('$res/drawable')
          .listSync()
          .whereType<File>()
          .where((f) => f.uri.pathSegments.last.startsWith('strakalari_status_'))) {
        final color = tint.firstMatch(icon.readAsStringSync())!.group(1)!;
        expect(colors, contains('name="$color"'));
        expect(night, contains('name="$color"'));
      }
    });

    test('theAppShipsTheReceiver', () {
      // `test_extension_wheel_ships_the_receiver`: the Flutter app carries
      // the classes and resources itself (no extension wheel any more).
      for (final path in [
        '$java/StatusReceiver.java',
        '$java/StatusViews.java',
        'android/app/src/main/res/layout/strakalari_status_collapsed.xml',
        'android/app/src/main/res/values-night/strakalari_colors.xml',
      ]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    });
  });

  group('B9 notification permission and background start', () {
    test('defers permission prompt until intro tutorial finishes', () async {
      final s = AppState(
        data: {},
        configData: {
          'wizard_step': 0,
          'run_in_background': true,
          'tutorials_enabled': true,
          'tutorials_done': <String>[],
        },
      );
      final runner = PeriodicRunner(intervalMinutes: 60);
      final phone = PhoneBackground(
        s,
        runner,
        const AndroidChannel(),
        onAndroid: () => true,
        startNotifier: false,
      );
      phone.start();
      await _settle();

      // Wizard still open: never ask yet.
      expect(s.setupPending, isTrue);
      expect(methods(), isNot(contains('requestNotificationPermission')));

      // Finishing (or dismissing) the wizard offers the intro tour first so
      // Android's permission prompt does not cover the tutorial (also holds when
      // a wizard notifications step is skipped in F1).
      s.wizardFinished();
      await _settle();
      expect(s.tutorial?.$1, firstTourId);
      expect(methods(), isNot(contains('requestNotificationPermission')));

      // Once the tutorial ends/skips, sync asks for notification permission.
      s.tutorialSkip();
      await _settle();
      expect(s.tutorial, isNull);
      expect(methods(), contains('requestNotificationPermission'));
    });

    test('dismissWizard defers permission over active intro tutorial', () async {
      final s = AppState(
        data: {},
        configData: {
          'wizard_step': 0,
          'run_in_background': true,
          'tutorials_enabled': true,
          'tutorials_done': <String>[],
        },
      );
      final runner = PeriodicRunner(intervalMinutes: 60);
      final phone = PhoneBackground(
        s,
        runner,
        const AndroidChannel(),
        onAndroid: () => true,
        startNotifier: false,
      );
      phone.start();
      await _settle();

      s.dismissWizard();
      await _settle();
      expect(s.tutorial?.$1, firstTourId);
      expect(methods(), isNot(contains('requestNotificationPermission')));

      s.tutorialSkip();
      await _settle();
      expect(methods(), contains('requestNotificationPermission'));
    });

    test('cold launch with intro pending defers permission until intro closes',
        () async {
      final s = AppState(
        data: {},
        configData: {
          'wizard_step': -1,
          'run_in_background': true,
          'tutorials_enabled': true,
          'tutorials_done': <String>[],
        },
      )..wizardDismissed = true;
      final runner = PeriodicRunner(intervalMinutes: 60);
      final phone = PhoneBackground(
        s,
        runner,
        const AndroidChannel(),
        onAndroid: () => true,
        startNotifier: false,
      );
      startPhoneBackground(s, phone);
      await _settle();

      expect(s.tutorial?.$1, firstTourId);
      expect(methods(), isNot(contains('requestNotificationPermission')));

      s.tutorialSkip();
      await _settle();
      expect(methods(), contains('requestNotificationPermission'));
    });

    test('starts background service when notifications become enabled without restart',
        () async {
      var notificationsAllowed = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(AndroidChannel.channel, (call) async {
        calls.add(call);
        return switch (call.method) {
          'notificationsEnabled' => notificationsAllowed,
          'startBackground' ||
          'scheduleWake' ||
          'updateBackgroundNotification' =>
            true,
          _ => null,
        };
      });

      final s = AppState(
        data: {},
        configData: {
          'wizard_step': -1,
          'run_in_background': true,
          'tutorials_enabled': false,
        },
      );
      final runner = PeriodicRunner(intervalMinutes: 60);
      final phone = PhoneBackground(
        s,
        runner,
        const AndroidChannel(),
        onAndroid: () => true,
        startNotifier: false,
      );
      phone.start();
      await _settle();

      // Permission granted asynchronously (e.g. after Allow or System Settings
      // on resume) while _on and _interval already matched: next sync() starts
      // the foreground service immediately.
      calls.clear();
      notificationsAllowed = true;
      await phone.sync();
      await _settle();

      expect(started(), isNotEmpty);
      expect(methods(), contains('scheduleWake'));
    });

    test('Android bridge waits for onRequestPermissionsResult before returning', () {
      final channel = File(
        'android/app/src/main/java/io/github/dendlerx/strakalari/android/StrakalariChannel.java',
      ).readAsStringSync();
      final activity = File(
        'android/app/src/main/kotlin/io/github/dendlerx/strakalari/MainActivity.kt',
      ).readAsStringSync();
      expect(channel, contains('onRequestPermissionsResult'));
      expect(channel, contains('pendingPermissionResult'));
      expect(activity, contains('onRequestPermissionsResult'));
    });
  });
}
