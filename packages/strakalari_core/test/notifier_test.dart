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
      expect(defaults.values, everyElement(isTrue));
    });
  });

  group('isEnabled', () {
    test('defaultsToOn', () {
      expect(isEnabled(null, 'excuse_sent'), isTrue);
      expect(isEnabled({}, 'excuse_sent'), isTrue);
      expect(isEnabled({'excuse_sent': false}, 'excuse_sent'), isFalse);
      expect(isEnabled({'excuse_sent': false}, 'refresh_done'), isTrue);
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
      expect(notify('refresh_done', 'hotovo', {}), isTrue);
      expect(calls, ['refresh_done:hotovo']);
    });

    test('backendFailureFallsBackToStdout', () {
      notifierBackend = _FailingBackend();
      expect(notify('refresh_done', 'hotovo', {}), isFalse);
      // The plain "[title] message" fallback, no scary suffix.
      expect(
        () => notify('refresh_done', 'hotovo', {}),
        prints(contains('hotovo')),
      );
    });

    test('noBackendPrintsAndReturnsFalse', () {
      expect(notify('refresh_done', 'hotovo', {}), isFalse);
      expect(
        () => notify('refresh_done', 'hotovo', {}),
        prints('[Strakaláři] hotovo\n'),
      );
    });

    test('neverRaisesFromBackend', () {
      notifierBackend = _ThrowingBackend();
      expect(notify('refresh_done', 'hotovo', {}), isFalse);
    });
  });
}

class _FakeBackend implements NotifierBackend {
  final List<String> calls;
  _FakeBackend(this.calls);

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  }) {
    calls.add('$tag:$body');
    return true;
  }
}

class _FailingBackend implements NotifierBackend {
  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  }) => false;
}

class _ThrowingBackend implements NotifierBackend {
  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  }) => throw StateError('backend exploded');
}
