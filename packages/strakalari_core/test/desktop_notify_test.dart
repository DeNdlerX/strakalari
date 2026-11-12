import 'dart:convert';
import 'dart:io';

import 'package:strakalari_core/strakalari_core.dart';
import 'package:test/test.dart';

/// Port of the OS-backend cases of tests/test_notify.py (the core
/// dispatch / prefs cases are in notifier_test.dart). Python monkeypatches
/// `shutil.which` and `subprocess.run`; here they are injected.
void main() {
  RunFn fakeRun(List<(String, List<String>, Duration)> capture, int code) =>
      (exe, args, {required timeout}) async {
        capture.add((exe, args, timeout));
        return code;
      };

  group('script building', () {
    test('appIdIsPlainAscii', () {
      expect(appId.codeUnits.every((c) => c < 128), isTrue);
    });

    test('psSingleQuoteEscapesApostrophe', () {
      expect(psSingleQuote('Petrův test'), 'Petrův test');
      expect(psSingleQuote("it's"), "it''s");
      // $ and backtick stay literal inside single quotes.
      expect(psSingleQuote(r'cena $5 `x`'), r'cena $5 `x`');
    });

    test('cdataGuardsClosingSequence', () {
      expect(cdata('a]]>b'), '<![CDATA[a]] >b]]>');
    });

    test('toastScriptKeepsDiacriticsAndUsesWinrt', () {
      final script =
          toastPsScript('Strakaláři', 'Příliš žluťoučký kůň', 'refresh_done');
      expect(script, contains('Strakaláři'));
      expect(script, contains('Příliš žluťoučký kůň'));
      expect(script, contains('CreateToastNotifier'));
      expect(script, contains('ToastNotification'));
      // No -Command-hostile here-strings; single-quoted literals instead.
      expect(script, isNot(contains('@"')));
    });

    test('toastScriptEscapesApostropheInMessage', () {
      final script = toastPsScript('Test', 'Petrova omluvenka', "it's");
      expect(script, contains("it''s"));
    });
  });

  group('Windows backend', () {
    test('sendWindowsWritesBomScriptWithDiacritics', () async {
      final capture = <List<String>>[];
      final seenFiles = <List<int>>[];
      final ok = await sendWindows(
        'Strakaláři',
        'Příliš žluťoučký kůň',
        'refresh_done',
        whichFn: (name) => name == 'powershell.exe' ? 'powershell.exe' : null,
        run: (exe, args, {required timeout}) async {
          capture.add([exe, ...args]);
          seenFiles.add(File(args.last).readAsBytesSync());
          return 0;
        },
      );
      expect(ok, isTrue);
      expect(capture.first.sublist(0, 4),
          ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass']);
      expect(capture.first[capture.first.length - 2], '-File');
      final raw = seenFiles.first;
      expect(raw.sublist(0, 3), [0xEF, 0xBB, 0xBF]); // UTF-8 BOM
      expect(utf8.decode(raw.sublist(3)), contains('Příliš žluťoučký kůň'));
    });

    test('sendWindowsNonzeroExitIsFailure', () async {
      expect(
          await sendWindows('T', 'M', 'refresh_done',
              whichFn: (_) => 'powershell.exe', run: fakeRun([], 1)),
          isFalse);
    });

    test('sendWindowsNoPowershellIsFailure', () async {
      expect(await sendWindows('T', 'M', 'refresh_done', whichFn: (_) => null),
          isFalse);
    });
  });

  group('Linux / macOS backends', () {
    test('sendLinuxUsesNotifySend', () async {
      final capture = <(String, List<String>, Duration)>[];
      expect(
          await sendLinux('Strakaláři', 'hotovo',
              whichFn: (_) => '/usr/bin/notify-send',
              run: fakeRun(capture, 0)),
          isTrue);
      final (exe, args, _) = capture.first;
      expect(exe, '/usr/bin/notify-send');
      expect(args, containsAll(['Strakaláři', 'hotovo']));
    });

    test('sendLinuxFailureWithoutFallback', () async {
      expect(
          await sendLinux('T', 'M',
              whichFn: (_) => '/usr/bin/notify-send', run: fakeRun([], 1)),
          isFalse);
      expect(await sendLinux('T', 'M', whichFn: (_) => null), isFalse);
    });

    test('sendMacosUsesOsascript', () async {
      final capture = <(String, List<String>, Duration)>[];
      expect(
          await sendMacos('Strakaláři', 'zpráva "s uvozovkami"',
              whichFn: (_) => '/usr/bin/osascript', run: fakeRun(capture, 0)),
          isTrue);
      final (exe, args, _) = capture.first;
      expect(exe, '/usr/bin/osascript');
      expect(args[1], contains(r'\"s uvozovkami\"'));
    });

    test('sendMacosFailure', () async {
      expect(
          await sendMacos('T', 'M',
              whichFn: (_) => '/usr/bin/osascript', run: fakeRun([], 1)),
          isFalse);
      expect(await sendMacos('T', 'M', whichFn: (_) => null), isFalse);
    });

    test('realSubprocessRunSignature', () async {
      // Guards the timeout we pass (stdin is closed by runProcess).
      final capture = <(String, List<String>, Duration)>[];
      expect(
          await sendLinux('T', 'M',
              whichFn: (_) => '/usr/bin/notify-send',
              run: fakeRun(capture, 0)),
          isTrue);
      expect(capture.first.$3, const Duration(seconds: 15));
    });
  });
}
