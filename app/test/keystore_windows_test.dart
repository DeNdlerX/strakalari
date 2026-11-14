// Windows Credential Manager the way keyring uses it (C-B2): the
// `WinVaultKeyring` port against a fake credential table, and core's
// `getKey` / `forgetKey` for two data folders sharing one Windows user.
import 'dart:io';
import 'dart:typed_data';

import 'package:app/platform/desktop/keystore_desktop.dart';
import 'package:app/platform/desktop/win_credentials.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

class Entry {
  final String user;
  final Uint8List blob;
  final String comment;
  Entry(this.user, this.blob, this.comment);
}

class FakeCredTable implements WinCredApi {
  final Map<String, Entry> table = {};
  int? failReads; // a Win32 error every CredRead gives
  int? failWrites;

  @override
  WinCredential? read(String target) {
    if (failReads != null) throw WinCredError(failReads!, 'CredRead');
    final e = table[target];
    return e == null ? null : WinCredential(e.user, e.blob);
  }

  @override
  void write(String target, String userName, Uint8List blob, String comment) {
    if (failWrites != null) throw WinCredError(failWrites!, 'CredWrite');
    table[target] = Entry(userName, blob, comment);
  }

  @override
  void delete(String target) {
    if (table.remove(target) == null) throw const WinCredError(errorNotFound, 'CredDelete');
  }

  String value(String target) => decodeCredentialBlob(table[target]!.blob);
}

void main() {
  late FakeCredTable fake;
  late WinVaultKeyring kr;

  setUp(() {
    fake = FakeCredTable();
    kr = WinVaultKeyring(fake);
  });

  group('WinVaultKeyring', () {
    test('writeOnAFreeServiceTargetUsesIt', () {
      kr.setPassword('Strakalari', 'fernet-key:a', 'KEY-A');
      expect(fake.table.keys, ['Strakalari']);
      expect(fake.table['Strakalari']!.user, 'fernet-key:a');
      expect(fake.table['Strakalari']!.comment, 'Stored using python-keyring');
      expect(fake.table['Strakalari']!.blob, encodeCredentialBlob('KEY-A'));
      expect(kr.getPassword('Strakalari', 'fernet-key:a'), 'KEY-A');
    });

    test('collisionOnWriteResavesTheOtherEntryUnderItsCompoundName', () {
      kr.setPassword('Strakalari', 'fernet-key:a', 'KEY-A');
      kr.setPassword('Strakalari', 'fernet-key:b', 'KEY-B');
      expect(fake.table.keys.toSet(), {'Strakalari', 'fernet-key:a@Strakalari'});
      expect(fake.table['Strakalari']!.user, 'fernet-key:b');
      expect(fake.table['fernet-key:a@Strakalari']!.user, 'fernet-key:a');
      expect(fake.value('fernet-key:a@Strakalari'), 'KEY-A');
      // Both folders still read their own key.
      expect(kr.getPassword('Strakalari', 'fernet-key:a'), 'KEY-A');
      expect(kr.getPassword('Strakalari', 'fernet-key:b'), 'KEY-B');
    });

    test('readGoesThroughTheCompoundNameWhenTheServiceTargetIsSomeoneElses', () {
      fake.table['Strakalari'] = Entry('fernet-key:other', encodeCredentialBlob('X'), '');
      fake.table['fernet-key:mine@Strakalari'] =
          Entry('fernet-key:mine', encodeCredentialBlob('MINE'), '');
      expect(kr.getPassword('Strakalari', 'fernet-key:mine'), 'MINE');
      expect(kr.getPassword('Strakalari', 'fernet-key:none'), isNull);
    });

    test('emptyStoredUserNameIsNotOurs', () {
      fake.table['Strakalari'] = Entry('', encodeCredentialBlob('X'), '');
      expect(kr.getPassword('Strakalari', 'fernet-key:a'), isNull);
    });

    test('deleteRemovesOnlyTargetsHoldingTheEntry', () {
      kr.setPassword('Strakalari', 'fernet-key:a', 'KEY-A');
      kr.setPassword('Strakalari', 'fernet-key:b', 'KEY-B'); // a → compound
      expect(kr.deletePassword('Strakalari', 'fernet-key:a'), isTrue);
      expect(fake.table.keys, ['Strakalari']);
      expect(kr.getPassword('Strakalari', 'fernet-key:b'), 'KEY-B');
      // And the other way round: b on the service target, a untouched.
      kr.setPassword('Strakalari', 'fernet-key:a', 'KEY-A'); // b → compound
      expect(kr.deletePassword('Strakalari', 'fernet-key:a'), isTrue);
      expect(fake.table.keys, ['fernet-key:b@Strakalari']);
      expect(kr.getPassword('Strakalari', 'fernet-key:b'), 'KEY-B');
    });

    test('deleteOfAMissingEntryIsKeyringsPasswordDeleteError', () {
      fake.table['Strakalari'] = Entry('fernet-key:other', encodeCredentialBlob('X'), '');
      expect(kr.deletePassword('Strakalari', 'fernet-key:a'), isFalse);
      expect(fake.table.keys, ['Strakalari']);
    });

    test('blobsDecodeUtf16ThenUtf8', () {
      expect(decodeCredentialBlob(encodeCredentialBlob('Zkouška')), 'Zkouška');
      expect(decodeCredentialBlob(Uint8List.fromList([0xff, 0xfe, 0x41, 0x00])), 'A');
      expect(decodeCredentialBlob(Uint8List.fromList([0xfe, 0xff, 0x00, 0x41])), 'A');
      // Odd length is not UTF-16: read as UTF-8 like DecodingCredential.
      expect(decodeCredentialBlob(Uint8List.fromList('abc'.codeUnits)), 'abc');
      expect(decodeCredentialBlob(Uint8List(0)), '');
      // A lone surrogate is not UTF-16, and these bytes are not UTF-8.
      expect(() => decodeCredentialBlob(Uint8List.fromList([0x00, 0xd8, 0x41, 0x00])),
          throwsFormatException);
    });
  });

  group('DesktopKeyStore on Windows', () {
    test('aRefusingStoreIsUnavailableNeverMissing', () {
      final store = DesktopKeyStore(windowsApi: fake);
      fake.failReads = 5; // ERROR_ACCESS_DENIED
      expect(() => store.getPassword('Strakalari', 'fernet-key:a'),
          throwsA(isA<KeyStoreUnavailable>()));
      expect(() => store.setPassword('Strakalari', 'fernet-key:a', 'K'),
          throwsA(isA<KeyStoreUnavailable>()));
      expect(() => store.deletePassword('Strakalari', 'fernet-key:a'),
          throwsA(isA<KeyStoreUnavailable>()));
    });

    test('notFoundIsNull', () {
      expect(DesktopKeyStore(windowsApi: fake).getPassword('Strakalari', 'fernet-key:a'), isNull);
    });
  });

  group('core secret_store with two data folders', () {
    late Directory root;
    late String dirA;
    late String dirB;

    setUp(() {
      root = Directory.systemTemp.createTempSync('kr_');
      dirA = (Directory('${root.path}/a')..createSync()).path;
      dirB = (Directory('${root.path}/b')..createSync()).path;
      setEnvironmentOverride({
        for (final e in Platform.environment.entries)
          if (e.key != 'STRAKALARI_NO_KEYRING') e.key: e.value,
        'STRAKALARI_DATA_DIR': dirA,
      });
      keyStoreBackend = DesktopKeyStore(windowsApi: fake);
      clearKeyCache();
    });

    tearDown(() {
      keyStoreBackend = null;
      clearKeyCache();
      root.deleteSync(recursive: true);
    });

    test('aSecondFolderNeverOverwritesTheFirstFoldersKey', () {
      final keyA = getKey(dirA);
      final keyB = getKey(dirB);
      expect(keyB, isNot(keyA));
      clearKeyCache();
      expect(getKey(dirA), keyA);
      expect(getKey(dirB), keyB);
      expect(File('$dirA/secret.key').existsSync(), isFalse);
      expect(File('$dirB/secret.key').existsSync(), isFalse);
    });

    test('forgettingOneFolderLeavesTheOtherFoldersKey', () {
      final keyA = getKey(dirA);
      getKey(dirB);
      expect(forgetKey(dirB), isTrue);
      clearKeyCache();
      expect(getKey(dirA), keyA);
      expect(fake.table.length, 1);
      // Forgetting a folder that has no entry is not a failure.
      expect(forgetKey(dirB), isTrue);
      expect(getKey(dirA), keyA);
    });

    test('aRefusingStoreNeverMakesANewKey', () {
      fake.failReads = 1312; // ERROR_NO_SUCH_LOGON_SESSION
      expect(() => getKey(dirA), throwsA(isA<KeyStoreUnavailable>()));
      expect(File('$dirA/secret.key').existsSync(), isFalse);
      expect(fake.table, isEmpty);
    });
  });

  test('realCredentialManagerAnswersNotFoundForAMissingTarget', () {
    // Read-only: proves the leaf GetLastError sees ERROR_NOT_FOUND.
    expect(Win32CredApi().read('Strakalari-test-missing-$pid-${Object().hashCode}'),
        isNull);
  }, skip: !Platform.isWindows);

  group('locateCliTool (D-M7)', () {
    late Directory root;
    late Directory binDir;
    late Directory pathDir;

    setUp(() {
      root = Directory.systemTemp.createTempSync('cli_tool_');
      binDir = Directory('${root.path}${Platform.pathSeparator}bin')..createSync();
      pathDir = Directory('${root.path}${Platform.pathSeparator}path')..createSync();
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    test('prefersExecutableDirectoryOverPath', () {
      final bundled = File('${binDir.path}${Platform.pathSeparator}secret-tool')
        ..writeAsStringSync('');
      File('${pathDir.path}${Platform.pathSeparator}secret-tool')
          .writeAsStringSync('');

      final found = locateCliTool(
        'secret-tool',
        executablePath: '${binDir.path}${Platform.pathSeparator}strakalari',
        pathEnv: pathDir.path,
      );
      expect(found, bundled.path);
    });

    test('findsBundledToolWhenPathIsEmpty', () {
      final bundled = File('${binDir.path}${Platform.pathSeparator}secret-tool')
        ..writeAsStringSync('');

      final found = locateCliTool(
        'secret-tool',
        executablePath: '${binDir.path}${Platform.pathSeparator}strakalari',
        pathEnv: '',
      );
      expect(found, bundled.path);
    });

    test('fallsBackToPathWhenAbsentFromExecutableDirectory', () {
      final emptyDir = Directory('${root.path}${Platform.pathSeparator}empty')
        ..createSync();
      final systemTool = File('${pathDir.path}${Platform.pathSeparator}secret-tool')
        ..writeAsStringSync('');
      final sep = Platform.isWindows ? ';' : ':';

      final found = locateCliTool(
        'secret-tool',
        executablePath: '${binDir.path}${Platform.pathSeparator}strakalari',
        pathEnv: '${emptyDir.path}$sep${pathDir.path}',
      );
      expect(found, systemTool.path);
    });

    test('returnsNullWhenMissingEverywhere', () {
      final found = locateCliTool(
        'secret-tool',
        executablePath: '${binDir.path}${Platform.pathSeparator}strakalari',
        pathEnv: pathDir.path,
      );
      expect(found, isNull);
    });
  });
}
