import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:strakalari_core/strakalari_core.dart';

import 'fake_bakalari.dart';

class _MemKeyStore implements KeyStore {
  final store = <String, String>{};

  @override
  String? getPassword(String service, String account) =>
      store['$service\x00$account'];

  @override
  void setPassword(String service, String account, String password) {
    store['$service\x00$account'] = password;
  }

  @override
  void deletePassword(String service, String account) {
    store.remove('$service\x00$account');
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('session_store_test_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': tmp.path});
    keyStoreBackend = _MemKeyStore();
    clearKeyCache();
    BakalariSessionPool.instance.resetForTesting();
  });

  tearDown(() {
    BakalariSessionPool.instance.resetForTesting();
    keyStoreBackend = null;
    allowMissingKeyStoreForTesting = false;
    setEnvironmentOverride(null);
    clearKeyCache();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('Step 3a: in-memory exclusive-lending session pool (R8a S9)', () {
    test('reusesSessionAcrossRunsAndLendsExclusively', () async {
      final server = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([]),
      });
      BakalariSessionPool.instance.transportFactory = () => server;

      // Run 1: checks out session, logs in, returns it on close().
      final c1 = BakalariClient(Map.of(fakeConfig), dataDir: tmp.path);
      await c1.login();
      final s1 = c1.bakalariSession();
      expect(server.logins, 1);

      // Concurrent checkout while c1 still holds s1 -> gets a DIFFERENT non-pooled session!
      final cConcurrent = BakalariClient(Map.of(fakeConfig), dataDir: tmp.path);
      final sConcurrent = cConcurrent.bakalariSession();
      expect(identical(s1, sConcurrent), isFalse);
      cConcurrent.close();

      // Return c1 to the pool; Run 2 gets the exact same pooled session with 0 extra logins!
      c1.close();
      final c2 = BakalariClient(Map.of(fakeConfig), dataDir: tmp.path);
      final s2 = c2.bakalariSession();
      expect(identical(s1, s2), isTrue);
      await c2.login();
      expect(server.logins, 1);
      c2.close();
    });

    test('connectionTestNeverUsesPoolAndRejectsWrongPasswordWhilePooledIsLive',
        () async {
      final server = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([]),
      });
      BakalariSessionPool.instance.transportFactory = () => server;

      // Let Strakalari build its own client (useSessionPool: true) and log in
      // once with the right password through the pool.
      final app = Strakalari(
        configData: Map.of(fakeConfig),
        dataDir: tmp.path,
      );
      expect(app.bakalariClient!.useSessionPool, isTrue);
      await app.bakalariClient!.login();
      app.bakalariClient!.close();
      expect(server.logins, 1);

      // Connection test with the right password still bypasses the pool and
      // posts /Login again (fails if checkBakalariLogin calls client.login()).
      final (okRight, _) = await app.checkBakalariLogin();
      expect(okRight, isTrue);
      expect(server.logins, 2);

      // Connection test with a wrong password in configManager rejects the login
      // and posts /Login even while app.bakalariClient and the pool have the
      // right password logged in.
      app.configManager.set('bakalari_password', 'wrong-password');
      final (okEdited, _) = await app.checkBakalariLogin();
      expect(okEdited, isFalse);
      expect(server.calls('POST', '/Login'), hasLength(3));
      app.close();

      // Fresh Strakalari building its own pooled client with a wrong password
      // also rejects and posts /Login.
      final appWrong = Strakalari(
        configData: {
          ...fakeConfig,
          'bakalari_password': 'wrong-password',
        },
        dataDir: tmp.path,
      );
      expect(appWrong.bakalariClient!.useSessionPool, isTrue);
      final (okWrong, _) = await appWrong.checkBakalariLogin();
      expect(okWrong, isFalse);
      expect(server.calls('POST', '/Login'), hasLength(4));
      appWrong.close();
    });

    test('reEncryptedEqualPasswordKeepsSessionWhileChangedPasswordEvictsIt',
        () async {
      final server = FakeBakalari();
      BakalariSessionPool.instance.transportFactory = () => server;

      final enc1 = encrypt(fakePassword, dataDir: tmp.path);
      final c1 = BakalariClient(
        {
          ...fakeConfig,
          'bakalari_password': enc1,
          'bakalari_password_encrypted': true,
        },
        dataDir: tmp.path,
      );
      await c1.login();
      final s1 = c1.bakalariSession();
      c1.close();

      // Re-encrypt the exact same plaintext -> different Fernet ciphertext, same SHA-256 -> keeps session!
      final enc2 = encrypt(fakePassword, dataDir: tmp.path);
      expect(enc2, isNot(enc1));
      final c2 = BakalariClient(
        {
          ...fakeConfig,
          'bakalari_password': enc2,
          'bakalari_password_encrypted': true,
        },
        dataDir: tmp.path,
      );
      final s2 = c2.bakalariSession();
      expect(identical(s1, s2), isTrue);
      await c2.login();
      expect(server.logins, 1);
      c2.close();

      // Different password -> evicts pooled session AND deletes bakalari_session.enc.
      expect(File(sessionFilePath(tmp.path)).existsSync(), isTrue);
      final c3 = BakalariClient(
        {...fakeConfig, 'bakalari_password': 'new-other-password'},
        dataDir: tmp.path,
      );
      final s3 = c3.bakalariSession();
      expect(identical(s1, s3), isFalse);
      expect(File(sessionFilePath(tmp.path)).existsSync(), isFalse);
      c3.close();
    });
  });

  group('Step 3b: encrypted disk cookie store (bakalari_session.enc)', () {
    test('encryptedRoundTripExpiryCredentialMismatchAndCorruptRecovery', () {
      final t0 = DateTime.utc(2026, 11, 22, 9, 0, 0);
      final digest = passwordSha256(fakePassword);
      expect(
        saveStoredSession(
          dataDir: tmp.path,
          root: fakeRoot,
          username: fakeUser,
          passwordDigest: digest,
          cookies: {'BakaAuth': 'super-secret-cookie-token'},
          renewedAt: t0,
        ),
        isTrue,
      );

      final rawFile = File(sessionFilePath(tmp.path));
      expect(rawFile.existsSync(), isTrue);
      // Never plaintext on disk!
      final diskText = rawFile.readAsStringSync();
      expect(diskText, isNot(contains('super-secret-cookie-token')));
      expect(diskText, isNot(contains(fakeUser)));

      // Valid within 13 min 59 s.
      final loaded = loadStoredSession(
        dataDir: tmp.path,
        root: fakeRoot,
        username: fakeUser,
        passwordDigest: digest,
        now: t0.add(const Duration(minutes: 13, seconds: 59)),
      );
      expect(loaded, isNotNull);
      expect(loaded!.cookies['BakaAuth'], 'super-secret-cookie-token');

      // Expired at 14 min.
      expect(
        loadStoredSession(
          dataDir: tmp.path,
          root: fakeRoot,
          username: fakeUser,
          passwordDigest: digest,
          now: t0.add(const Duration(minutes: 14)),
        ),
        isNull,
      );

      // Clock skew (< -2 min) treated as expired.
      expect(
        loadStoredSession(
          dataDir: tmp.path,
          root: fakeRoot,
          username: fakeUser,
          passwordDigest: digest,
          now: t0.subtract(const Duration(minutes: 3)),
        ),
        isNull,
      );

      // Mismatched username deletes the file immediately.
      expect(
        loadStoredSession(
          dataDir: tmp.path,
          root: fakeRoot,
          username: 'other_user',
          passwordDigest: digest,
          now: t0.add(const Duration(minutes: 1)),
        ),
        isNull,
      );
      expect(rawFile.existsSync(), isFalse);

      // Corrupt ciphertext recovers cleanly and deletes the file.
      rawFile.writeAsStringSync('not-a-valid-fernet-token');
      expect(
        loadStoredSession(
          dataDir: tmp.path,
          root: fakeRoot,
          username: fakeUser,
          passwordDigest: digest,
          now: t0,
        ),
        isNull,
      );
      expect(rawFile.existsSync(), isFalse);
    });

    test('noPlaintextFallbackWhenKeyStoreUnavailable', () {
      keyStoreBackend = null;
      allowMissingKeyStoreForTesting = false;
      clearKeyCache();
      final ok = saveStoredSession(
        dataDir: tmp.path,
        root: fakeRoot,
        username: fakeUser,
        passwordDigest: passwordSha256(fakePassword),
        cookies: {'BakaAuth': 'must-not-write-plain'},
        renewedAt: DateTime.utc(2026, 11, 22, 9, 0),
      );
      expect(ok, isFalse);
      expect(File(sessionFilePath(tmp.path)).existsSync(), isFalse);
    });

    test('loginRejectionDeletesStoredSessionAndForgetAllKeysCleansAllDirs',
        () async {
      final t0 = DateTime.utc(2026, 11, 22, 9, 0);
      saveStoredSession(
        dataDir: tmp.path,
        root: fakeRoot,
        username: fakeUser,
        passwordDigest: passwordSha256(fakePassword),
        cookies: {'BakaAuth': 'tok-root-123456'},
        renewedAt: t0,
      );
      final accDir = Directory(p.join(tmp.path, 'accounts', 'default'))
        ..createSync(recursive: true);
      saveStoredSession(
        dataDir: accDir.path,
        root: fakeRoot,
        username: fakeUser,
        passwordDigest: passwordSha256(fakePassword),
        cookies: {'BakaAuth': 'tok-acc-123456'},
        renewedAt: t0,
      );
      expect(File(sessionFilePath(tmp.path)).existsSync(), isTrue);
      expect(File(sessionFilePath(accDir.path)).existsSync(), isTrue);

      AccountManager.forgetAllKeys(tmp.path);
      expect(File(sessionFilePath(tmp.path)).existsSync(), isFalse);
      expect(File(sessionFilePath(accDir.path)).existsSync(), isFalse);
    });
  });

  group('Step 3c: 15-minute sliding session expiry (R8a S10)', () {
    test('fiveAndTenMinTicksRenewWithoutExtraLoginsHourlyLogsInOnce', () async {
      var now = DateTime(2026, 11, 22, 8, 0, 0);
      final server = FakeBakalari({
        'GET /Marks/Widget': marksWidgetHtml([]),
      }, 15);
      BakalariSessionPool.instance.transportFactory = () => server;

      Future<void> runHeadlessTickAt(DateTime t) async {
        now = t;
        // Simulate a fresh headless isolate each time by resetting the in-memory pool!
        BakalariSessionPool.instance.closeAll();
        await withClock(Clock(() => now), () async {
          final c = BakalariClient(Map.of(fakeConfig), dataDir: tmp.path);
          try {
            await c.login();
            final w = await c.fetchMarksWidget();
            expect(w, isNotNull);
          } finally {
            c.close();
          }
        });
      }

      // 08:00: first tick logs in once and persists cookie `t1`.
      await runHeadlessTickAt(DateTime(2026, 11, 22, 8, 0));
      expect(server.logins, 1);
      expect(server.renewals, 0);

      // 08:05 (+5 min, first half): reuses cookie without login or renewal.
      await runHeadlessTickAt(DateTime(2026, 11, 22, 8, 5));
      expect(server.logins, 1);
      expect(server.renewals, 0);

      // 08:10 (+10 min, second half >= 7.5 min): reuses cookie, server renews via Set-Cookie!
      await runHeadlessTickAt(DateTime(2026, 11, 22, 8, 10));
      expect(server.logins, 1);
      expect(server.renewals, 1);

      // 08:20 (+10 min after the 08:10 renewal, 20 min after original login):
      // loads the RENEWED cookie from bakalari_session.enc -> still 0 extra logins!
      await runHeadlessTickAt(DateTime(2026, 11, 22, 8, 20));
      expect(server.logins, 1);
      expect(server.renewals, 2);

      // 09:20 (+60 min, hourly tick): 3b sees renewed_at >= 14 min old and logs
      // in directly (no wasted /Marks/Widget -> 302 round-trip)!
      final widgetCallsBefore = server.calls('GET', '/Marks/Widget').length;
      await runHeadlessTickAt(DateTime(2026, 11, 22, 9, 20));
      expect(server.logins, 2);
      expect(
        server.calls('GET', '/Marks/Widget').length,
        widgetCallsBefore + 1,
      );
    });
  });
}
