// Port of tests/test_single_instance.py: a second launch shows the first
// window, never duplicates; another OS user's launch runs on its own.
// (The Flet window and two-process tray cases are under Dropped.)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app/platform/desktop/single_instance.dart';
import 'package:flutter_test/flutter_test.dart';

Future<int> _freePort() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

/// Completes true when [c] completes within [timeout].
Future<bool> _waitFor(Completer<void> c, [Duration timeout = const Duration(seconds: 5)]) =>
    c.future.then((_) => true).timeout(timeout, onTimeout: () => false);

void main() {
  late Directory dataDir;
  late List<int> token;

  setUp(() async {
    dataDir = Directory.systemTemp.createTempSync('si_');
    token = await instanceToken(dataDir.path);
  });

  tearDown(() {
    try {
      dataDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort on Windows.
    }
  });

  group('TestSingleInstance', () {
    test('firstAcquireWins', () async {
      final port = await _freePort();
      final first = SingleInstance(port: port);
      final second = SingleInstance(port: port);
      try {
        expect(await first.acquire(token), isTrue);
        expect(first.isPrimary, isTrue);
        expect(await second.acquire(token), isFalse);
      } finally {
        await first.close();
        await second.close();
      }
    });

    test('showFiresCallback', () async {
      final port = await _freePort();
      final fired = Completer<void>();
      final primary = SingleInstance(port: port, onShow: fired.complete);
      try {
        expect(await primary.acquire(token), isTrue);
        expect(await SingleInstance(port: port).signal(token, kind: 'show'), isTrue);
        expect(await _waitFor(fired), isTrue);
      } finally {
        await primary.close();
      }
    });

    test('pingAcknowledgesWithoutFiring', () async {
      final port = await _freePort();
      final fired = Completer<void>();
      final primary = SingleInstance(port: port, onShow: fired.complete);
      try {
        expect(await primary.acquire(token), isTrue);
        expect(await SingleInstance(port: port).signal(token, kind: 'ping'), isTrue);
        expect(await _waitFor(fired, const Duration(milliseconds: 300)), isFalse);
      } finally {
        await primary.close();
      }
    });

    test('signalWithoutPrimaryFails', () async {
      expect(await SingleInstance(port: await _freePort()).signal(token, kind: 'show'), isFalse);
    });

    test('badKindRaises', () async {
      expect(() => SingleInstance(port: 1).signal(token, kind: 'bogus'), throwsArgumentError);
    });

    test('garbageGetsNoReplyAndNoCallback', () async {
      final port = await _freePort();
      final fired = Completer<void>();
      final primary = SingleInstance(port: port, onShow: fired.complete);
      try {
        expect(await primary.acquire(token), isTrue);
        final conn = await Socket.connect(InternetAddress.loopbackIPv4, port);
        conn.add(ascii.encode('not-strakalari\n'));
        await conn.flush();
        final reply = await conn.timeout(const Duration(seconds: 2)).fold<List<int>>([], (a, b) => a..addAll(b));
        await conn.close();
        expect(reply, isEmpty);
        expect(await _waitFor(fired, const Duration(milliseconds: 300)), isFalse);
      } finally {
        await primary.close();
      }
    });

    test('showBeforeCallbackIsDeliveredLate', () async {
      // A show arriving between acquire() and UI-ready must not be lost.
      final port = await _freePort();
      final fired = Completer<void>();
      final primary = SingleInstance(port: port);
      try {
        expect(await primary.acquire(token), isTrue);
        expect(await SingleInstance(port: port).signal(token, kind: 'show'), isTrue);
        primary.setOnShow(fired.complete);
        expect(await _waitFor(fired), isTrue);
      } finally {
        await primary.close();
      }
    });

    test('closeReleasesPort', () async {
      final port = await _freePort();
      final primary = SingleInstance(port: port);
      expect(await primary.acquire(token), isTrue);
      await primary.close();
      final again = SingleInstance(port: port);
      try {
        expect(await again.acquire(token), isTrue);
      } finally {
        await again.close();
      }
    });
  });

  group('TestEnsureSinglePrimary', () {
    test('secondaryShow', () async {
      final port = await _freePort();
      final fired = Completer<void>();
      final (status, guard) = await ensureSinglePrimary(dataDir: dataDir.path, port: port, mode: 'show');
      expect(status, 'primary');
      expect(guard, isNotNull);
      try {
        guard!.setOnShow(fired.complete);
        final (status2, guard2) = await ensureSinglePrimary(dataDir: dataDir.path, port: port, mode: 'show');
        expect((status2, guard2), ('secondary', null));
        expect(await _waitFor(fired), isTrue);
      } finally {
        await guard?.close();
      }
    });

    test('secondaryPingStaysSilent', () async {
      final port = await _freePort();
      final fired = Completer<void>();
      final (status, guard) = await ensureSinglePrimary(dataDir: dataDir.path, port: port, mode: 'show');
      expect(status, 'primary');
      try {
        guard!.setOnShow(fired.complete);
        final (status2, guard2) = await ensureSinglePrimary(dataDir: dataDir.path, port: port, mode: 'ping');
        expect((status2, guard2), ('secondary', null));
        expect(await _waitFor(fired, const Duration(milliseconds: 300)), isFalse);
      } finally {
        await guard?.close();
      }
    });

    test('squattedPortStillStarts', () async {
      // An unrelated process on the port must not prevent startup.
      final squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final sub = squatter.listen((c) {}); // accepts, never answers
      final printed = <String>[];
      try {
        final result = await runZoned(
            () => ensureSinglePrimary(dataDir: dataDir.path, port: squatter.port, mode: 'show'),
            zoneSpecification: ZoneSpecification(print: (_, _, _, line) => printed.add(line)));
        expect(result, ('solo', null));
        expect(printed.join('\n'), contains('Warning'));
      } finally {
        await sub.cancel();
        await squatter.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('badModeRaises', () async {
      expect(() => ensureSinglePrimary(dataDir: dataDir.path, port: 1, mode: 'bogus'), throwsArgumentError);
    });
  });

  // From tests/test_macos_tray_host.py (the rest of that file is the
  // macOS two-process tray host, see Dropped).
  group('TestQuitSignal', () {
    test('quitFiresHandler', () async {
      final port = await _freePort();
      final fired = Completer<void>();
      final primary = SingleInstance(port: port, onQuit: fired.complete);
      try {
        expect(await primary.acquire(token), isTrue);
        expect(await SingleInstance(port: port).signal(token, kind: 'quit'), isTrue);
        expect(await _waitFor(fired), isTrue);
      } finally {
        await primary.close();
      }
    });

    test('quitWithoutHandlerIsNotAcknowledged', () async {
      // The sender must know nobody closed the window, and kill instead.
      final port = await _freePort();
      final shown = Completer<void>();
      final primary = SingleInstance(port: port, onShow: shown.complete);
      try {
        expect(await primary.acquire(token), isTrue);
        expect(await SingleInstance(port: port).signal(token, kind: 'quit'), isFalse);
        expect(await _waitFor(shown, const Duration(milliseconds: 300)), isFalse);
      } finally {
        await primary.close();
      }
    });
  });

  group('TestPerUserIsolation', () {
    test('tokenIsPrivateAndStable', () async {
      final file = File('${dataDir.path}${Platform.pathSeparator}$instanceTokenFile');
      expect(file.readAsBytesSync(), token);
      expect(token, hasLength(32));
      expect(await instanceToken(dataDir.path), token);
      if (!Platform.isWindows) {
        expect(file.statSync().mode & 0x3f, 0); // 0o077
      }
    });

    test('otherUsersMessageIsIgnored', () async {
      final port = await _freePort();
      final fired = Completer<void>();
      final primary = SingleInstance(port: port, onShow: fired.complete);
      try {
        expect(await primary.acquire(token), isTrue);
        final conn = await Socket.connect(InternetAddress.loopbackIPv4, port);
        conn.add(ascii.encode('$magicShow ${'0' * 32}\n'));
        await conn.flush();
        final reply = await conn.timeout(const Duration(seconds: 2)).fold<List<int>>([], (a, b) => a..addAll(b));
        await conn.close();
        expect(reply, isEmpty);
        expect(await _waitFor(fired, const Duration(milliseconds: 300)), isFalse);
      } finally {
        await primary.close();
      }
    });

    test('otherUsersLaunchRunsOnItsOwn', () async {
      final port = await _freePort();
      final fired = Completer<void>();
      final (status, guard) = await ensureSinglePrimary(dataDir: dataDir.path, port: port, mode: 'show');
      expect(status, 'primary');
      final other = Directory('${dataDir.path}${Platform.pathSeparator}other-user')..createSync();
      try {
        guard!.setOnShow(fired.complete);
        // A second user: different data dir, so a different token.
        final (status2, guard2) = await ensureSinglePrimary(dataDir: other.path, port: port, mode: 'show');
        expect((status2, guard2), ('solo', null));
        expect(await _waitFor(fired, const Duration(milliseconds: 300)), isFalse);
      } finally {
        await guard?.close();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('usersGetDifferentPorts', () {
      final slots = {for (var i = 0; i < 20; i++) userSlot('user$i|/home/user$i')};
      expect(slots.length, greaterThan(10));
      expect(mainPort(), inInclusiveRange(42000, 47999));
      expect(uiPort(), mainPort() + 1);
    });
  });
}
