import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/more.dart';
import 'package:app/features/settings/settings_live.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/features/wizard/wizard_controller.dart';
import 'package:app/features/wizard/wizard_live.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/platform/android/android_channel.dart';
import 'package:app/platform/ios/ios_channel.dart';
import 'package:app/platform/ios/ios_keystore.dart';
import 'package:app/platform/startup.dart';
import 'package:app/shell/router.dart';

class _FakeIosKeychain {
  final Map<String, String> items = {};
  final List<String> calls = [];
  bool failRead = false;
  bool failWrite = false;

  String _key(String service, String account) => '$service\x00$account';

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    final args = call.arguments as Map<Object?, Object?>;
    final service = args['service']! as String;
    final account = args['account']! as String;
    switch (call.method) {
      case 'keychainGet':
        if (failRead) {
          throw PlatformException(
            code: 'KEYCHAIN_READ_FAILED',
            message: 'errSecInteractionNotAllowed',
          );
        }
        return items[_key(service, account)];
      case 'keychainSet':
        if (failWrite) {
          throw PlatformException(
            code: 'KEYCHAIN_WRITE_FAILED',
            message: 'errSecAuthFailed',
          );
        }
        items[_key(service, account)] = args['value']! as String;
        return true;
      case 'keychainDelete':
        items.remove(_key(service, account));
        return true;
    }
    throw MissingPluginException();
  }
}

class _SeededAppStateController extends AppStateController {
  final AppState _seeded;
  _SeededAppStateController(this._seeded);
  @override
  AppState build() => _seeded;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late _FakeIosKeychain keychain;
  late List<String> androidCalls;
  late bool savedIsMobile;
  late String savedLang;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('strakalari_ios_');
    keychain = _FakeIosKeychain();
    androidCalls = [];
    savedIsMobile = Strings.isMobile;
    savedLang = Strings.lang;
    Strings.lang = 'cs';

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(IosChannel.channel, keychain.handle);
    messenger.setMockMethodCallHandler(AndroidChannel.channel, (call) async {
      androidCalls.add(call.method);
      return null;
    });

    clearKeyCache();
    keyStoreBackend = null;
    androidKeystoreBridge = null;
    wakeupPhoneBridge = null;
    onForgetKeyHook = null;
    setMobileDataDir(null);
    setEnvironmentOverride({
      for (final e in Platform.environment.entries)
        if (e.key != 'STRAKALARI_NO_KEYRING' && e.key != 'STRAKALARI_DATA_DIR')
          e.key: e.value,
      'FLET_PLATFORM': 'ios',
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(IosChannel.channel, null);
    messenger.setMockMethodCallHandler(AndroidChannel.channel, null);

    clearKeyCache();
    keyStoreBackend = null;
    androidKeystoreBridge = null;
    wakeupPhoneBridge = null;
    onForgetKeyHook = null;
    setMobileDataDir(null);
    setEnvironmentOverride(null);
    Strings.isMobile = savedIsMobile;
    Strings.lang = savedLang;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('F5 iOS Keychain backend', () {
    test('fresh install stores key in iOS Keychain with no plain secret.key',
        () async {
      final key1 = await warmIosKeystore(tmp.path);
      expect(Fernet.isValidKeyBytes(key1), isTrue);
      expect(File('${tmp.path}/secret.key').existsSync(), isFalse);
      expect(keychain.items.length, 1);
      expect(getKey(tmp.path), key1);
      expect(storageLocation(tmp.path), 'keyring');

      // Second launch reuses the same Keychain entry.
      clearKeyCache();
      keyStoreBackend = null;
      final key2 = await warmIosKeystore(tmp.path);
      expect(key2, key1);
      expect(getKey(tmp.path), key1);
      expect(androidCalls, isEmpty);
    });

    test('migrates existing plain secret.key into Keychain and keeps passwords',
        () async {
      final old = Fernet.generateKey();
      File('${tmp.path}/secret.key').writeAsBytesSync(old);
      final cipher = encrypt('tajne_heslo', dataDir: tmp.path);
      clearKeyCache();

      final warmed = await warmIosKeystore(tmp.path);
      expect(warmed, old);
      expect(File('${tmp.path}/secret.key').existsSync(), isFalse);
      expect(decryptStrict(cipher, dataDir: tmp.path), 'tajne_heslo');
      expect(storageLocation(tmp.path), 'keyring');
    });

    test('differing plain secret.key is preserved instead of guessing',
        () async {
      final keychainKey = await warmIosKeystore(tmp.path);
      final fileKey = Fernet.generateKey();
      File('${tmp.path}/secret.key').writeAsBytesSync(fileKey);
      clearKeyCache();
      keyStoreBackend = null;

      final chosen = await warmIosKeystore(tmp.path);
      expect(chosen, fileKey);
      expect(chosen, isNot(keychainKey));
      expect(getKey(tmp.path), fileKey);
      expect(File('${tmp.path}/secret.key').existsSync(), isTrue);
    });

    test('locked Keychain throws KeyStoreUnavailable and never regenerates key',
        () async {
      await warmIosKeystore(tmp.path);
      clearKeyCache();
      keyStoreBackend = null;
      keychain.failRead = true;

      await expectLater(
        warmIosKeystore(tmp.path),
        throwsA(isA<KeyStoreUnavailable>()),
      );
      expect(
        () => getKey(tmp.path),
        throwsA(isA<KeyStoreUnavailable>()),
      );
      expect(File('${tmp.path}/secret.key').existsSync(), isFalse);
    });

    test('write failure keeps plain secret.key fallback even with store installed',
        () async {
      final acc1 = Directory('${tmp.path}/acc1')..createSync(recursive: true);
      final acc2 = Directory('${tmp.path}/acc2')..createSync(recursive: true);
      await warmIosKeystore(acc1.path);

      keychain.failWrite = true;
      final fallbackKey = await warmIosKeystore(acc2.path);
      expect(File('${acc2.path}/secret.key').existsSync(), isTrue);
      clearKeyCache();
      expect(getKey(acc2.path), fallbackKey);
      // Core must not delete secret.key after an unverified sync write.
      expect(File('${acc2.path}/secret.key').existsSync(), isTrue);
    });

    test('warmIosKeystoreAll and forgetKey isolate multi-account keys',
        () async {
      final acc1 = Directory('${tmp.path}/accounts/default')
        ..createSync(recursive: true);
      final acc2 = Directory('${tmp.path}/accounts/acc_112233445566')
        ..createSync(recursive: true);

      await warmIosKeystoreAll(
        tmp.path,
        const ['default', 'acc_112233445566'],
      );

      final k1 = getKey(acc1.path);
      final k2 = getKey(acc2.path);
      expect(k1, isNot(equals(k2)));

      final c1 = encrypt('child1', dataDir: acc1.path);
      final c2 = encrypt('child2', dataDir: acc2.path);
      clearKeyCache();
      expect(decryptStrict(c1, dataDir: acc1.path), 'child1');
      expect(decryptStrict(c2, dataDir: acc2.path), 'child2');
      expect(decryptStrict(c1, dataDir: acc2.path), isNull);

      expect(forgetKey(acc2.path), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(keychain.calls, contains('keychainDelete'));
      expect(keychain.items.containsKey('$serviceName\x00${entryName(acc2.path)}'),
          isFalse);
      expect(keychain.items.containsKey('$serviceName\x00${entryName(acc1.path)}'),
          isTrue);
    });

    test('saved passwords stay readable when iOS container path changes on update (R7 M1)',
        () async {
      void copyTree(Directory src, Directory dst) {
        dst.createSync(recursive: true);
        for (final entity in src.listSync(recursive: false)) {
          final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (entity is Directory) {
            copyTree(entity, Directory('${dst.path}/$name'));
          } else if (entity is File) {
            entity.copySync('${dst.path}/$name');
          }
        }
      }

      final containerA = Directory('${tmp.path}/container-UUID-A')
        ..createSync(recursive: true);
      final containerB = Directory('${tmp.path}/container-UUID-B')
        ..createSync(recursive: true);

      final ctxA = await prepareStartup(
        const [],
        supportDirProvider: () async => containerA,
      );
      expect(ctxA.layoutResult!.isReady, isTrue);
      final rootA = '${containerA.path}/data';
      final defaultA = '$rootA/accounts/default';
      final accCipher = encrypt('bakalari_pw_123', dataDir: defaultA);
      final rootCipher = encrypt('gemini_key_456', dataDir: rootA);
      final itemsBefore = Map<String, String>.of(keychain.items);
      expect(itemsBefore.length, 2);

      // Simulate iOS update / 7-day re-sign: app files move to a new container
      // UUID while the Keychain keeps the same items.
      copyTree(containerA, containerB);
      containerA.deleteSync(recursive: true);
      clearKeyCache();
      keyStoreBackend = null;
      setMobileDataDir(null);

      final ctxB = await prepareStartup(
        const [],
        supportDirProvider: () async => containerB,
      );
      expect(ctxB.layoutResult!.isReady, isTrue);

      final rootB = '${containerB.path}/data';
      final defaultB = '$rootB/accounts/default';
      expect(keychain.items, itemsBefore,
          reason: 'Container move must reuse existing Keychain entries, not create new ones');
      expect(File('$rootB/secret.key').existsSync(), isFalse);
      expect(File('$defaultB/secret.key').existsSync(), isFalse);
      expect(decryptStrict(accCipher, dataDir: defaultB), 'bakalari_pw_123');
      expect(decryptStrict(rootCipher, dataDir: rootB), 'gemini_key_456');
    });
  });

  group('F5 iOS startup and platform guards', () {
    test('prepareStartup and startPlatformServices initialize iOS without Android calls',
        () async {
      final ctx = await prepareStartup(
        const [],
        supportDirProvider: () async => tmp,
      );

      final expectedDataDir = '${tmp.path}/data';
      expect(Strings.isMobile, isTrue);
      expect(ctx.rootDir, expectedDataDir);
      expect(getUserDataDir(), expectedDataDir);
      expect(ctx.layoutResult, isNotNull);
      expect(ctx.layoutResult!.isReady, isTrue);
      expect(keyStoreBackend, isA<WarmedIosKeyStore>());
      expect(androidKeystoreBridge, isNull);
      expect(wakeupPhoneBridge, isNull);
      expect(androidCalls, isEmpty);

      PeriodicRunner? createdLoop;
      final container = ProviderContainer(
        overrides: [
          startupLayoutProvider.overrideWithValue(
            (layout: ctx.layoutResult, rootDir: ctx.rootDir),
          ),
        ],
      );
      addTearDown(() {
        createdLoop?.stop();
        container.dispose();
      });

      await startPlatformServices(
        container,
        ctx,
        onLoopCreated: (loop) => createdLoop = loop,
      );
      expect(createdLoop, isNotNull);
      expect(androidCalls, isEmpty);
    });

    test('startPlatformServices pauses scheduler when iOS app backgrounds and resumes on foreground (R7 S2)',
        () async {
      final ctx = await prepareStartup(
        const [],
        supportDirProvider: () async => tmp,
      );
      PeriodicRunner? createdLoop;
      final container = ProviderContainer(
        overrides: [
          startupLayoutProvider.overrideWithValue(
            (layout: ctx.layoutResult, rootDir: ctx.rootDir),
          ),
        ],
      );
      final binding = TestWidgetsFlutterBinding.instance;
      addTearDown(() {
        createdLoop?.stop();
        container.dispose();
        if (binding.lifecycleState != AppLifecycleState.resumed) {
          binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
          binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        }
      });

      await startPlatformServices(
        container,
        ctx,
        onLoopCreated: (loop) => createdLoop = loop,
      );
      expect(createdLoop?.paused, isNotNull);
      expect(createdLoop!.paused!(), isFalse);

      // Follow Flutter's AppLifecycleListener state machine to background:
      // resumed -> inactive -> hidden -> paused.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(createdLoop!.paused!(), isTrue);

      // Return to foreground: paused -> hidden -> inactive -> resumed.
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(createdLoop!.paused!(), isFalse);
    });

    test('AppState ensureWarmedFn warms iOS Keychain without touching Android',
        () async {
      final accDir = Directory('${tmp.path}/accounts/acc_ios')
        ..createSync(recursive: true);
      final state = AppState(configData: const {'language': 'cs'});

      await state.ensureWarmedFn(accDir.path);
      expect(keyStoreBackend, isA<WarmedIosKeyStore>());
      expect((keyStoreBackend! as WarmedIosKeyStore).hasEntry(accDir.path),
          isTrue);
      expect(androidCalls, isEmpty);
    });

    testWidgets('LiveSettingsView hides Android/desktop sections and makes no AndroidChannel calls on iOS',
        (tester) async {
      final s = AppState(configData: const {'language': 'cs'});

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: const MaterialApp(
            home: Scaffold(body: LiveSettingsView(narrow: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final view = tester.widget<SettingsView>(find.byType(SettingsView));
      expect(view.platform, 'ios');
      final sectionIds =
          view.controller.sectionsHere(platform: view.platform).map((e) => e.$1);
      expect(sectionIds, isNot(contains('alarm')));
      expect(sectionIds, isNot(contains('browser')));
      expect(sectionIds, isNot(contains('notifications')));
      expect(view.controller.isAndroid, isFalse);
      expect(view.controller.wakeupPhone, isNull);
      expect(androidCalls, isEmpty);
    });

    testWidgets('LiveWizardView skips stepPhone and makes no AndroidChannel calls on iOS',
        (tester) async {
      final s = AppState(configData: const {'language': 'cs'});
      s.wizardStep = WizardController.stepWelcome;

      final c = wizardControllerFor(s);
      expect(c.isAndroid, isFalse);
      expect(c.shownSteps(), isNot(contains(WizardController.stepPhone)));
      expect(c.stepAfter(WizardController.stepExcuses), WizardController.stepDone);
      await c.onRequestNotificationPermission?.call();
      expect(androidCalls, isEmpty);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: LiveWizardView(tokens: AppTokens.dark(), narrow: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(androidCalls, isEmpty);
    });

    testWidgets('MorePage via router hides alarm shortcut on iOS',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final s = AppState(configData: const {
        'language': 'cs',
        'disclaimer_accepted': true,
        'wizard_step': -1,
      });
      s.wizardDismissed = true;
      final router = buildRouter(initialLocation: '/more');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _SeededAppStateController(s)),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      final more = tester.widget<MorePage>(find.byType(MorePage));
      expect(more.isAndroid, isFalse);
      expect(more.visibleEntries().map((e) => e.$1), isNot(contains('alarm')));
      expect(androidCalls, isEmpty);
    });
  });
}
