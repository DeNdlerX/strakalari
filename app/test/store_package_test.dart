// Port of tests/test_store_package.py: the Store (MSIX) build has no
// GitHub update checks, no Run-key autostart, and keeps its data in
// %LOCALAPPDATA%\Strakalari (copying a classic install's data once).
import 'dart:convert';
import 'dart:io';

import 'package:app/platform/desktop/autostart.dart';
import 'package:app/platform/desktop/store_package.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

File _repoFile(String relPath) {
  for (final candidate in [
    File(relPath),
    File('../$relPath'),
    File('../../$relPath'),
  ]) {
    if (candidate.existsSync()) return candidate;
  }
  throw StateError('Cannot locate $relPath from ${Directory.current.path}');
}

Future<String> _findPython() async {
  for (final cmd in const ['python3', 'python']) {
    try {
      final r = await Process.run(cmd, ['--version'])
          .timeout(const Duration(seconds: 15));
      if (r.exitCode == 0) return cmd;
    } catch (_) {
      continue;
    }
  }
  fail('No Python 3 executable found on PATH');
}

Future<ProcessResult> _runToolPython(String toolName, String body) async {
  final py = await _findPython();
  final toolPath = _repoFile('tools/$toolName.py').absolute.path;
  final script = '''
import importlib.util
spec = importlib.util.spec_from_file_location(${jsonEncode(toolName)}, ${jsonEncode(toolPath)})
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
$body
''';
  return Process.run(py, ['-c', script], environment: {
    ...Platform.environment,
    'PYTHONUTF8': '1',
  }).timeout(const Duration(seconds: 30));
}

class MemoryKeyStore implements KeyStore {
  final Map<String, String> entries = {};
  @override
  String? getPassword(String service, String account) => entries['$service/$account'];
  @override
  void setPassword(String service, String account, String password) =>
      entries['$service/$account'] = password;
  @override
  void deletePassword(String service, String account) => entries.remove('$service/$account');
}

/// `os.path.join` / `normcase` comparisons without package:path.
// ignore: camel_case_types
class p {
  static String join(String a, [String? b, String? c, String? d]) =>
      [a, b, c, d].whereType<String>().join(Platform.pathSeparator);
  static bool equals(String a, String b) => _norm(a) == _norm(b);
  static String _norm(String x) {
    var s = x.replaceAll('/', r'\').toLowerCase();
    while (s.endsWith(r'\')) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }
}

void _write(String path, String text) {
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(text);
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('store_');
    clearKeyCache();
  });

  tearDown(() {
    setStorePackageProbe(null);
    fetchReleasesHook = null;
    keyStoreBackend = null;
    clearKeyCache();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A lock file may still be open on Windows.
    }
  });

  group('TestPackageDetection', () {
    test('unpackagedHere', () {
      expect(hasPackageIdentity(), isFalse); // this test run has no package identity
      expect(storePackageProbe(release: true)(), isFalse);
    });

    test('devRunNeverCounts', () {
      // The Microsoft Store's python.exe has a package identity too; a
      // Flutter debug run is the same case.
      expect(storePackageProbe(release: false, identity: () => true)(), isFalse);
    });

    test('frozenWithIdentity', () {
      expect(storePackageProbe(release: true, identity: () => true)(), isTrue);
      expect(hasPackageIdentity(rc: () => 122, windows: true), isTrue);
      expect(hasPackageIdentity(rc: () => appModelErrorNoPackage, windows: true), isFalse);
      expect(hasPackageIdentity(rc: () => 122, windows: false), isFalse);
    });

    test('legacyDirAbsent', () {
      setEnvironmentOverride({'LOCALAPPDATA': tmp.path, 'STRAKALARI_NO_KEYRING': '1'});
      expect(legacyDesktopDataDir(), isNull);
    });
  });

  group('TestStoreDataDir', () {
    late String local;

    setUp(() {
      local = p.join(tmp.path, 'Local');
      Directory(local).createSync();
      // No STRAKALARI_DATA_DIR: the real resolution runs.
      setEnvironmentOverride({
        for (final e in Platform.environment.entries)
          if (e.key != 'STRAKALARI_DATA_DIR' && e.key != 'LOCALAPPDATA' && e.key != 'APPDATA') e.key: e.value,
        'LOCALAPPDATA': local,
        'STRAKALARI_NO_KEYRING': '1',
      });
      setStorePackageProbe(() => true);
    });

    test('neverThePackageDir', () {
      expect(p.equals(getUserDataDir(), p.join(local, 'Strakalari')), isTrue);
    });

    test('classicInstallDataIsCopied', () {
      final legacy = p.join(local, 'Programs', 'Strakalari');
      _write(p.join(legacy, 'config.json'), jsonEncode({'school': 'x'}));
      _write(p.join(legacy, 'automation_history.jsonl'), 'history');
      final target = p.join(local, 'Strakalari');
      expect(p.equals(getUserDataDir(), target), isTrue);
      expect(jsonDecode(File(p.join(target, 'config.json')).readAsStringSync()), {'school': 'x'});
      expect(File(p.join(target, 'automation_history.jsonl')).readAsStringSync(), 'history');
      // The classic install keeps its own copy.
      expect(File(p.join(legacy, 'config.json')).existsSync(), isTrue);
    });

    test('copiedPasswordsDecryptWithCredentialManager', () {
      final legacy = p.join(local, 'Programs', 'Strakalari');
      _write(p.join(legacy, 'config.json'), '{}');
      keyStoreBackend = MemoryKeyStore();
      final base = {
        for (final e in Platform.environment.entries)
          if (e.key != 'STRAKALARI_DATA_DIR' && e.key != 'LOCALAPPDATA' && e.key != 'APPDATA' &&
              e.key != 'STRAKALARI_NO_KEYRING')
            e.key: e.value,
        'LOCALAPPDATA': local,
      };
      // Encrypted by the classic install: key bound to its dir path.
      setEnvironmentOverride({...base, 'STRAKALARI_DATA_DIR': legacy});
      final token = encrypt('hunter2');
      expect(File(p.join(legacy, 'secret.key')).existsSync(), isFalse);
      setEnvironmentOverride(base);
      clearKeyCache();
      expect(p.equals(getUserDataDir(), p.join(local, 'Strakalari')), isTrue);
      expect(decrypt(token), 'hunter2');
    });

    test('existingStoreDataWins', () {
      _write(p.join(local, 'Programs', 'Strakalari', 'config.json'), '{"from": "classic"}');
      _write(p.join(local, 'Strakalari', 'config.json'), '{"from": "store"}');
      getUserDataDir();
      expect(jsonDecode(File(p.join(local, 'Strakalari', 'config.json')).readAsStringSync()),
          {'from': 'store'});
    });
  }, skip: Platform.isWindows ? false : 'the Store build exists on Windows only');

  group('TestUpdateGate', () {
    setUp(() => setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path, 'STRAKALARI_NO_KEYRING': '1'}));

    test('checkReturnsNoneWithoutNetwork', () async {
      setStorePackageProbe(() => true);
      fetchReleasesHook = (_) => throw StateError('no network in Store builds');
      expect(await checkForUpdates(), isNull);
      expect(await checkForUpdates(force: true), isNull);
    });

    test('cachedHidden', () {
      setStorePackageProbe(() => true);
      expect(loadCached(), isNull);
    });

    test('gateOffForClassic', () {
      setStorePackageProbe(() => false);
      expect(updatesManagedExternally(), isFalse);
    });
  });

  group('TestAutostartGate', () {
    setUp(() => setStorePackageProbe(() => true));

    test('setRefused', () {
      expect(setAutostart(true), isFalse);
      expect(setAutostart(false), isFalse);
    });

    test('enabledUnknown', () {
      expect(isAutostartEnabled(), isFalse);
    });
  });

  group('TestMsixVersion', () {
    test('threeParts', () async {
      final r = await _runToolPython(
        'make_msix',
        'assert mod.msix_version("0.2.0") == "0.2.0.0"\n'
            'assert mod.msix_version("v0.10.0") == "0.10.0.0"',
      );
      expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    });

    test('twoParts', () async {
      final r = await _runToolPython(
        'make_msix',
        'assert mod.msix_version("v1.2") == "1.2.0.0"',
      );
      expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    });

    test('prereleaseRefused', () async {
      final r = await _runToolPython(
        'make_msix',
        'try:\n'
            '    mod.msix_version("0.2.0-beta.1")\n'
            'except SystemExit:\n'
            '    print("SYSTEM_EXIT")\n'
            'else:\n'
            '    raise AssertionError("expected SystemExit")',
      );
      expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
      expect((r.stdout as String).trim(), 'SYSTEM_EXIT');
    });

    test('manifestTemplateTokens', () {
      var template = _repoFile('msix/AppxManifest.xml').readAsStringSync();
      if (template.startsWith('\uFEFF')) {
        template = template.substring(1);
      }
      for (final token in const [
        '@IDENTITY_NAME@',
        '@PUBLISHER@',
        '@VERSION@',
        '@ARCH@',
        '@PUBLISHER_DISPLAY@',
      ]) {
        expect(template, contains(token));
      }
      expect(template, contains('runFullTrust'));
      expect(template, contains('windows.startupTask'));
      // Autostart opens the tray, not the window (as the Run value does).
      expect(template, contains('uap10:Parameters="--minimized"'));
    });
  });

  test('storeSubmitLoads', () async {
    // Stdlib only: the publish job runs it on a bare runner.
    final r = await _runToolPython(
      'store_submit',
      'assert "preprocessing" in mod.COMMITTED_STATES',
    );
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
  });
}
