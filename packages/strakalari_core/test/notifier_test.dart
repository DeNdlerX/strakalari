// Port of tests/test_notify.py (pure-interface cases).
//
// The OS backends (_send_windows/_send_macos/_send_linux/_send_plyer and the
// PowerShell toast script) are implemented by the app in phase 7; their cases
// live there. This file covers what platform/notifier.dart owns: event names,
// per-event preferences and dispatch.
import 'package:test/test.dart';

import 'package:strakalari_core/src/platform/notifier.dart';

void main() {
  setUp(() {
    notifierBackend = null;
  });

  tearDown(() {
    notifierBackend = null;
  });

  group('eventTypes', () {
    test('appIdIsPlainAscii', () {
      expect(RegExp(r'^[\x00-\x7F]*$').hasMatch(appId), isTrue);
    });

    test('knownEvents', () {
      expect(
        eventTypes.toSet(),
        containsAll([
          'excuse_sent',
          'refresh_failed',
          'planner_suggestion',
          'update_available',
          'new_mark',
          'new_quarterly_mark',
          'new_absence',
          'timetable_change',
        ]),
      );
      expect(defaults.keys.toSet(), eventTypes.toSet());
      expect(defaults['refresh_done'], isFalse);
      expect(defaults['refresh_failed'], isFalse);
      for (final event in eventTypes) {
        if (event == 'refresh_done' || event == 'refresh_failed') continue;
        expect(defaults[event], isTrue, reason: event);
      }
    });
  });

  group('isEnabled', () {
    test('defaultsToOn', () {
      expect(isEnabled(null, 'excuse_sent'), isTrue);
      expect(isEnabled({}, 'excuse_sent'), isTrue);
      expect(isEnabled({'excuse_sent': false}, 'excuse_sent'), isFalse);
      expect(isEnabled({'excuse_sent': false}, 'new_mark'), isTrue);
    });

    test('refreshEventsDefaultOff', () {
      const offByDefault = {'refresh_done', 'refresh_failed'};
      for (final event in offByDefault) {
        expect(defaults[event], isFalse, reason: event);
        expect(isEnabled(null, event), isFalse, reason: '$event null');
        expect(isEnabled({}, event), isFalse, reason: '$event empty');
        expect(isEnabled({event: true}, event), isTrue,
            reason: '$event explicit true');
      }
      for (final event in eventTypes) {
        if (offByDefault.contains(event)) continue;
        expect(defaults[event], isTrue, reason: event);
        expect(isEnabled(null, event), isTrue, reason: '$event null');
        expect(isEnabled({}, event), isTrue, reason: '$event empty');
      }

      final calls = <String>[];
      notifierBackend = _FakeBackend(calls);
      expect(notify('refresh_done', 'hotovo', {}), isFalse);
      expect(notify('refresh_failed', 'chyba', null), isFalse);
      expect(calls, isEmpty);
      expect(notify('refresh_done', 'hotovo', {'refresh_done': true}), isTrue);
      expect(
          notify('refresh_failed', 'chyba', {'refresh_failed': true}), isTrue);
      expect(calls, ['refresh_done:hotovo', 'refresh_failed:chyba']);
    });
  });

  group('notify', () {
    test('unknownEventThrows', () {
      expect(() => notify('no_such_event', 'x'), throwsArgumentError);
    });

    test('disabledEventNeverTouchesTheBackend', () {
      final calls = <String>[];
      notifierBackend = _FakeBackend(calls);
      expect(notify('excuse_sent', 'x', {'excuse_sent': false}), isFalse);
      expect(calls, isEmpty);
    });

    test('dispatchesToTheBackend', () {
      final calls = <String>[];
      notifierBackend = _FakeBackend(calls);
      expect(notify('refresh_done', 'hotovo', {'refresh_done': true}), isTrue);
      expect(calls, ['refresh_done:hotovo']);
    });

    test('backendFailureFallsBackToStdout', () {
      notifierBackend = _FailingBackend();
      expect(notify('refresh_done', 'hotovo', {'refresh_done': true}), isFalse);
      // The plain "[title] message" fallback, no scary suffix.
      expect(
        () => notify('refresh_done', 'hotovo', {'refresh_done': true}),
        prints(contains('hotovo')),
      );
    });

    test('noBackendPrintsAndReturnsFalse', () {
      expect(notify('refresh_done', 'hotovo', {'refresh_done': true}), isFalse);
      expect(
        () => notify('refresh_done', 'hotovo', {'refresh_done': true}),
        prints('[Strakaláři] hotovo\n'),
      );
    });

    test('neverRaisesFromBackend', () {
      notifierBackend = _ThrowingBackend();
      expect(notify('refresh_done', 'hotovo', {'refresh_done': true}), isFalse);
    });
  });
}

class _FakeBackend implements NotifierBackend {
  final List<String> calls;
  final List<String?> routes;
  _FakeBackend(this.calls, [List<String?>? routes]) : routes = routes ?? [];

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
    String? route,
  }) {
    calls.add('$tag:$body');
    routes.add(route);
    return true;
  }
}

class _FailingBackend implements NotifierBackend {
  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
    String? route,
  }) => false;
}

class _ThrowingBackend implements NotifierBackend {
  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
    String? route,
  }) => throw StateError('backend exploded');
}
