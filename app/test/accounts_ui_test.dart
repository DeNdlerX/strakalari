import 'dart:convert';
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/features/activity/activity_live.dart';
import 'package:app/features/common/app_tokens.dart';
import 'package:app/features/more.dart';
import 'package:app/features/settings/settings_controller.dart';
import 'package:app/features/settings/settings_live.dart';
import 'package:app/features/settings/settings_view.dart';
import 'package:app/features/settings/wakeup_card.dart';
import 'package:app/features/wizard/wizard_controller.dart';
import 'package:app/features/wizard/wizard_live.dart';
import 'package:app/features/wizard/wizard_view.dart';
import 'package:app/l10n/strings.dart';
import 'package:app/shell/router.dart';
import 'package:app/tutorial/tours.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

String _j(String a, String b) => '$a${Platform.pathSeparator}$b';

Map<String, Object?> _seedAccountConfig({
  required String user,
  String url = 'https://demo1.bakalari.test',
  String stravaUser = '',
  String stravaCanteen = '',
  String signature = '',
  bool bgRefresh = true,
  int wizardStep = -1,
}) =>
    {
      'bakalari_url': url,
      'bakalari_username': user,
      'bakalari_password': 'pw_$user',
      'bakalari_password_encrypted': false,
      'use_strava': stravaUser.isNotEmpty,
      'strava_username': stravaUser,
      'strava_password': stravaUser.isNotEmpty ? 'spw_$stravaUser' : '',
      'strava_password_encrypted': false,
      'strava_canteen_id': stravaCanteen,
      'your_signature': signature,
      'school_preset_id': 'gekom_2026_2027',
      'background_refresh': bgRefresh,
      'wizard_step': wizardStep,
    };

Future<Directory> _makeTwoAccountRoot({
  bool firstMigrated = true,
  bool secondBgRefresh = true,
  String firstLabel = 'Anička',
  String secondLabel = 'Tonda',
}) async {
  final root = Directory.systemTemp.createTempSync('strak_f4_ui_');
  core.setEnvironmentOverride({
    ...Platform.environment,
    'STRAKALARI_DATA_DIR': root.path,
    'STRAKALARI_NO_KEYRING': '1',
  });
  core.enterAccountsMode(root.path);

  File(_j(root.path, core.globalConfigFile)).writeAsStringSync(jsonEncode({
    'theme': 'dark',
    'language': 'cs',
    'disclaimer_accepted': true,
    'tutorials_enabled': false,
    'tutorials_done': ['intro', 'settings', 'accounts'],
    'check_interval_minutes': 60,
    'run_in_background': true,
  }));

  final d1 = Directory(core.accountDirFor(root.path, 'default'))
    ..createSync(recursive: true);
  final d2 = Directory(core.accountDirFor(root.path, 'acc_second'))
    ..createSync(recursive: true);

  File(_j(d1.path, 'config.json')).writeAsStringSync(jsonEncode(
    _seedAccountConfig(
      user: 'anicka',
      url: 'https://school1.test',
      stravaUser: 's_anicka',
      stravaCanteen: '1111',
      signature: firstLabel,
    ),
  ));
  File(_j(d2.path, 'config.json')).writeAsStringSync(jsonEncode(
    _seedAccountConfig(
      user: 'tonda',
      url: 'https://school2.test',
      stravaUser: 's_tonda',
      stravaCanteen: '2222',
      signature: secondLabel,
      bgRefresh: secondBgRefresh,
    ),
  ));

  final reg = core.AccountRegistry(
    accounts: [
      core.AccountInfo(
        id: 'default',
        label: firstLabel,
        createdAt: '2026-11-01T08:00:00',
        migrated: firstMigrated,
      ),
      core.AccountInfo(
        id: 'acc_second',
        label: secondLabel,
        createdAt: '2026-11-02T08:00:00',
        migrated: false,
      ),
    ],
    activeId: 'default',
    primaryId: 'default',
  );
  File(_j(root.path, core.accountsFile))
      .writeAsStringSync(jsonEncode(reg.toJson()));
  return root;
}

Widget _shellApp(AppState state, {String initialLocation = '/today'}) {
  final router = buildRouter(initialLocation: initialLocation);
  return ProviderScope(
    overrides: [
      appStateProvider.overrideWith(() => _FixedAppStateController(state)),
    ],
    child: MaterialApp.router(
      theme: state.tok.toThemeData(),
      routerConfig: router,
    ),
  );
}

class _FixedAppStateController extends AppStateController {
  final AppState fixed;
  _FixedAppStateController(this.fixed);

  @override
  AppState build() {
    fixed.onChanged = emit;
    return fixed;
  }
}

void main() {
  setUp(() {
    Strings.lang = 'cs';
  });

  tearDown(() {
    core.resetAccountsModeForTesting();
    core.setEnvironmentOverride(null);
  });

  group('Account switcher pill, sheet/dialog, and MorePage card', () {
    testWidgets('hidden for single-account and degraded mode', (tester) async {
      // Single account in accounts mode
      final root = Directory.systemTemp.createTempSync('strak_f4_one_');
      addTearDown(() => root.deleteSync(recursive: true));
      core.setEnvironmentOverride({
        ...Platform.environment,
        'STRAKALARI_DATA_DIR': root.path,
        'STRAKALARI_NO_KEYRING': '1',
      });
      File(_j(root.path, 'config.json')).writeAsStringSync(jsonEncode({
        ..._seedAccountConfig(user: 'onlyone', signature: 'Pepa'),
        'disclaimer_accepted': true,
        'tutorials_enabled': false,
      }));
      final layout = await core.ensureMultiAccountLayout(root.path);
      final singleState = AppState(layoutResult: layout, rootDir: root.path);
      singleState.ensureWarmedFn = (_) async {};

      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(_shellApp(singleState));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account_switcher')), findsNothing);

      // Degraded mode: also hidden (ensureMultiAccountLayout did not enter accounts mode)
      core.resetAccountsModeForTesting();
      final degradedState = AppState(
        layoutResult: core.MultiAccountLayoutResult.degraded('boom'),
        rootDir: root.path,
        configData: {
          ..._seedAccountConfig(user: 'onlyone'),
          'disclaimer_accepted': true,
          'tutorials_enabled': false,
        },
        data: {},
      );
      await tester.pumpWidget(_shellApp(degradedState));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account_switcher')), findsNothing);
    });

    testWidgets(
      'shown at 390px and 1280px for 2 accounts, switches account, MorePage card opens switcher',
      (tester) async {
        final root = await _makeTwoAccountRoot(secondBgRefresh: false);
        addTearDown(() => root.deleteSync(recursive: true));
        final state = AppState(rootDir: root.path);
        state.ensureWarmedFn = (_) async {};

        // 390px narrow
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(_shellApp(state));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('account_switcher')), findsOneWidget);
        expect(find.text('Anička'), findsOneWidget);

        // Open narrow bottom sheet
        await tester.tap(find.byKey(const Key('account_switcher')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('account_switcher_sheet')), findsOneWidget);
        expect(find.text(Strings.get('account_primary_badge')), findsOneWidget);
        expect(find.text(Strings.get('account_bg_off_tag')), findsOneWidget);
        expect(find.byKey(const Key('switcher:add_account')), findsOneWidget);

        // Switch to Tonda
        await tester.tap(find.byKey(const Key('switcher:item:acc_second')));
        await tester.pumpAndSettle();
        expect(state.activeAccountId, 'acc_second');
        expect(find.text('Tonda'), findsOneWidget);

        // Check MorePage active-account card on narrow & "Spravovat účty" -> Settings -> Účty
        state.settingsSection = 'rules';
        state.settingsOpen = false;
        await tester.pumpWidget(_shellApp(state, initialLocation: '/more'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('more:account_card')), findsOneWidget);
        await tester.tap(find.byKey(const Key('more:account_card')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('account_switcher_sheet')), findsOneWidget);

        await tester.tap(find.byKey(const Key('switcher:manage_accounts')));
        await tester.pumpAndSettle();
        expect(state.settingsSection, 'accounts');
        expect(state.settingsOpen, isTrue);
        expect(find.byKey(const Key('settings:accounts_card')), findsOneWidget);

        // Also test TopBar pill -> "Spravovat účty" on 390px phone when another section was open
        state.settingsSection = 'rules';
        state.settingsOpen = false;
        await tester.pumpWidget(_shellApp(state, initialLocation: '/today'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('account_switcher')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('switcher:manage_accounts')));
        await tester.pumpAndSettle();
        expect(state.settingsSection, 'accounts');
        expect(state.settingsOpen, isTrue);
        expect(find.byKey(const Key('settings:accounts_card')), findsOneWidget);

        // Also test TopBar pill -> "Spravovat účty" on 390px phone when already on /settings list
        state.settingsSection = 'rules';
        state.settingsOpen = false;
        await tester.pumpWidget(_shellApp(state, initialLocation: '/settings'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('settings:accounts_card')), findsNothing);
        await tester.tap(find.byKey(const Key('account_switcher')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('switcher:manage_accounts')));
        await tester.pumpAndSettle();
        expect(state.settingsSection, 'accounts');
        expect(state.settingsOpen, isTrue);
        expect(find.byKey(const Key('settings:accounts_card')), findsOneWidget);

        // Verify 1280px wide dialog & "Spravovat účty"
        state.settingsSection = 'rules';
        tester.view.physicalSize = const Size(1280, 800);
        await tester.pumpWidget(_shellApp(state));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('account_switcher')), findsOneWidget);
        await tester.tap(find.byKey(const Key('account_switcher')));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.byKey(const Key('account_switcher_sheet')), findsOneWidget);
        await tester.tap(find.byKey(const Key('switcher:manage_accounts')));
        await tester.pumpAndSettle();
        expect(state.settingsSection, 'accounts');
        expect(find.byKey(const Key('settings:accounts_card')), findsOneWidget);
      },
    );
  });

  group('Item 14: Settings accounts manager, delete confirmation & focused field', () {
    testWidgets(
      'backup note appears only for migrated account; deleting active account with focused field leaves folder gone',
      (tester) async {
        final root = await _makeTwoAccountRoot(firstMigrated: true);
        addTearDown(() => root.deleteSync(recursive: true));
        final state = AppState(rootDir: root.path);
        state.ensureWarmedFn = (_) async {};
        state.settingsSection = 'accounts';
        state.settingsOpen = true;

        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(ProviderScope(
          overrides: [
            appStateProvider
                .overrideWith(() => _FixedAppStateController(state)),
          ],
          child: MaterialApp(
            theme: state.tok.toThemeData(),
            home: const Scaffold(body: LiveSettingsView(narrow: false)),
          ),
        ));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('settings:accounts_card')), findsOneWidget);
        expect(find.byKey(const Key('settings:scope_account')), findsOneWidget);

        // 1. Check non-migrated second account delete dialog has NO backup note
        await tester.ensureVisible(find.byKey(const Key('acc:delete:acc_second')));
        await tester.tap(find.byKey(const Key('acc:delete:acc_second')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('acc:delete_dialog')), findsOneWidget);
        expect(find.byKey(const Key('acc:delete_backup_note')), findsNothing);
        await tester.tap(find.byKey(const Key('acc:delete_cancel')));
        await tester.pumpAndSettle();

        // 2. Focus a Settings field of the active (migrated) account & edit it
        final listView = find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first;
        final userField = find.byKey(const Key('auto:acc:bakalari_username'));
        await tester.scrollUntilVisible(userField, 250, scrollable: listView);
        await tester.tap(userField);
        await tester.enterText(userField, 'anicka_edited');
        await tester.pump();

        // 3. Delete active (migrated) account while field was focused
        final delBtn = find.byKey(const Key('acc:delete:default'));
        await tester.scrollUntilVisible(delBtn, -250, scrollable: listView);
        await tester.ensureVisible(delBtn);
        await tester.pumpAndSettle();
        await tester.tap(delBtn);
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('acc:delete_dialog')), findsOneWidget);
        // Migrated account MUST show backup note
        expect(find.byKey(const Key('acc:delete_backup_note')), findsOneWidget);

        await tester.tap(find.byKey(const Key('acc:delete_confirm')));
        await tester.pumpAndSettle();

        // Active account switched to acc_second and default's folder is GONE!
        expect(state.activeAccountId, 'acc_second');
        expect(state.primaryAccountId, 'acc_second');
        expect(
          Directory(core.accountDirFor(root.path, 'default')).existsSync(),
          isFalse,
        );
        // Second account's username was NOT overwritten by the edited field!
        expect(state.get('bakalari_username'), 'tonda');
      },
    );

    testWidgets(
      'rename, set primary, toggle background_refresh, duplicate login refusal, and degraded Diagnostics hint',
      (tester) async {
        final root = await _makeTwoAccountRoot();
        addTearDown(() => root.deleteSync(recursive: true));
        final state = AppState(rootDir: root.path);
        state.ensureWarmedFn = (_) async {};
        state.settingsSection = 'accounts';
        state.settingsOpen = true;

        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(ProviderScope(
          overrides: [
            appStateProvider
                .overrideWith(() => _FixedAppStateController(state)),
          ],
          child: MaterialApp(
            theme: state.tok.toThemeData(),
            home: const Scaffold(body: LiveSettingsView(narrow: false)),
          ),
        ));
        await tester.pumpAndSettle();

        // Rename second account
        await tester.tap(find.byKey(const Key('acc:rename:acc_second')));
        await tester.pumpAndSettle();
        await tester.enterText(
            find.byKey(const Key('acc:rename_field')), 'Tomáš');
        await tester.tap(find.byKey(const Key('acc:rename_confirm')));
        await tester.pumpAndSettle();
        expect(state.registry!.byId('acc_second')!.label, 'Tomáš');

        // Toggle per-account background refresh on second account
        await tester.tap(find.byKey(const Key('acc:bg_refresh:acc_second')));
        await tester.pumpAndSettle();
        expect(state.accountBackgroundRefresh('acc_second'), isFalse);

        // Set primary to second account
        await tester.tap(find.byKey(const Key('acc:set_primary:acc_second')));
        await tester.pumpAndSettle();
        expect(state.primaryAccountId, 'acc_second');

        // Duplicate login refusal in Settings -> Ucty: set default's URL & user
        // to match acc_second's (school2.test / tonda).
        state.saveQuiet({'bakalari_url': 'https://school2.test'});
        state.onChanged();
        await tester.pumpAndSettle();

        final listView = find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first;
        final userField = find.byKey(const Key('auto:acc:bakalari_username'));
        await tester.scrollUntilVisible(userField, 250, scrollable: listView);
        await tester.tap(userField);
        await tester.enterText(userField, 'TONDA');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();

        // Refused: saved username stays 'anicka', snackbar shown
        expect(state.get('bakalari_username'), 'anicka');
        expect(find.textContaining('Tomáš'), findsWidgets);

        // Scope captions in Rules (account) & Appearance (shared)
        state.setSettingsSection('rules');
        await tester.pumpAndSettle();
        final rulesList = find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('settings:scope_account')),
          -300,
          scrollable: rulesList,
        );
        expect(find.byKey(const Key('settings:scope_account')), findsOneWidget);
        expect(find.byKey(const Key('rule:background_refresh')), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text(Strings.get('settings_interval_shared_hint')),
          200,
          scrollable: rulesList,
        );
        expect(
          find.text(Strings.get('settings_interval_shared_hint')),
          findsOneWidget,
        );

        state.setSettingsSection('appearance');
        await tester.pumpAndSettle();
        final appList = find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('settings:scope_shared')),
          -300,
          scrollable: appList,
        );
        expect(find.byKey(const Key('settings:scope_shared')), findsOneWidget);

        // Degraded mode: hides accounts card, shows Diagnostics hint
        core.resetAccountsModeForTesting();
        final degraded = AppState(
          layoutResult: core.MultiAccountLayoutResult.degraded('key err'),
          rootDir: root.path,
          configData: _seedAccountConfig(user: 'anicka'),
          data: {},
        );
        degraded.settingsSection = 'accounts';
        degraded.settingsOpen = true;
        await tester.pumpWidget(ProviderScope(
          key: const ValueKey('degraded_scope'),
          overrides: [
            appStateProvider
                .overrideWith(() => _FixedAppStateController(degraded)),
          ],
          child: MaterialApp(
            theme: degraded.tok.toThemeData(),
            home: const Scaffold(body: LiveSettingsView(narrow: false)),
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('settings:accounts_card')), findsNothing);

        degraded.setSettingsSection('diagnostics');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('diag:migration_failed')), findsOneWidget);
      },
    );
  });

  group('Item 15: Settings -> Budik on a non-primary account', () {
    testWidgets(
      'shows primary-account banner and no WakeupCard; Set as primary promotes and reveals WakeupCard',
      (tester) async {
        final root = await _makeTwoAccountRoot();
        addTearDown(() => root.deleteSync(recursive: true));
        final state = AppState(rootDir: root.path);
        state.ensureWarmedFn = (_) async {};
        await state.switchAccount('acc_second');
        state.settingsSection = 'alarm';
        state.settingsOpen = true;

        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(ProviderScope(
          overrides: [
            appStateProvider
                .overrideWith(() => _FixedAppStateController(state)),
          ],
          child: MaterialApp(
            theme: state.tok.toThemeData(),
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) {
                  final s = ref.watch(appStateProvider);
                  final base = settingsControllerFor(s);
                  final c = SettingsController(
                    base.config,
                    persist: base.persist,
                    persistQuiet: base.persistQuiet,
                    isAndroid: true,
                    wakeupAvailable: true,
                  )
                    ..settingsSection = s.settingsSection
                    ..settingsOpen = s.settingsOpen
                    ..accountsEnabled = base.accountsEnabled
                    ..accounts = base.accounts
                    ..activeAccountId = base.activeAccountId
                    ..activeAccountLabel = base.activeAccountLabel
                    ..primaryAccountId = base.primaryAccountId
                    ..primaryAccountLabel = base.primaryAccountLabel
                    ..onSetPrimaryAccount = base.onSetPrimaryAccount;
                  return SettingsView(
                    controller: c,
                    platform: 'android',
                    onChanged: () => ref.read(appStateProvider.notifier).emit(),
                  );
                },
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('alarm:non_primary_banner')), findsOneWidget);
        expect(find.byKey(const Key('alarm:set_primary')), findsOneWidget);
        expect(find.byType(WakeupCard), findsNothing);
        expect(
          find.text(Strings.format(
              'alarm_primary_account_note', {'name': 'Anička'})),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('alarm:set_primary')));
        await tester.pumpAndSettle();

        expect(state.primaryAccountId, 'acc_second');
        expect(find.byKey(const Key('alarm:non_primary_banner')), findsNothing);
        expect(find.byType(WakeupCard), findsOneWidget);
      },
    );
  });

  group('Item 14: Add-account wizard flow, Cancel, duplicate refusal & Finish', () {
    testWidgets(
      'existing account with cleared credentials opens normal wizard without Cancel and is never deleted',
      (tester) async {
        final root = await _makeTwoAccountRoot();
        addTearDown(() => root.deleteSync(recursive: true));
        final state = AppState(rootDir: root.path);
        state.ensureWarmedFn = (_) async {};
        // Clear credentials on existing account (adding == false)
        state.save({
          'bakalari_url': '',
          'bakalari_username': '',
          'bakalari_password': '',
          'strava_username': '',
          'strava_password': '',
        });
        expect(state.needsSetup(), isTrue);
        expect(state.addingAccount, isFalse);

        final wiz = wizardControllerFor(state);
        wiz.isAndroid = true;
        expect(wiz.addingAccount, isFalse);
        expect(wiz.shownSteps(), contains(WizardController.stepWelcome));
        expect(wiz.shownSteps(), contains(WizardController.stepPhone));

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: WizardView(
              controller: wiz,
              tokens: AppTokens.dark(),
              narrow: false,
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('wiz:cancel_add')), findsNothing);
        expect(await wiz.pressCancelAdd(), isFalse);
        expect(
          Directory(core.accountDirFor(root.path, 'default')).existsSync(),
          isTrue,
        );
      },
    );

    testWidgets(
      'adding account skips Welcome & Phone, keeps Cancel across restart, refuses duplicate logins, Cancel deletes only provisional folder, Finish clears adding & derives label',
      (tester) async {
        final root = await _makeTwoAccountRoot();
        addTearDown(() => root.deleteSync(recursive: true));
        final state = AppState(rootDir: root.path);
        state.ensureWarmedFn = (_) async {};

        expect(await state.beginAddAccount(), isTrue);
        final provisionalId = state.activeAccountId!;
        expect(provisionalId, isNot('default'));
        expect(state.addingAccount, isTrue);
        expect(state.wizardStep, WizardController.stepSchool);

        // Simulate app restart while adding: true
        final restarted = AppState(rootDir: root.path);
        restarted.ensureWarmedFn = (_) async {};
        expect(restarted.activeAccountId, provisionalId);
        expect(restarted.addingAccount, isTrue);

        final wiz = wizardControllerFor(restarted);
        wiz.isAndroid = true; // Phone step still skipped!
        expect(wiz.addingAccount, isTrue);
        expect(
          wiz.shownSteps(),
          [
            WizardController.stepSchool,
            WizardController.stepBakalari,
            WizardController.stepStrava,
            WizardController.stepExcuses,
            WizardController.stepDone,
          ],
        );
        expect(wiz.canSkip, isFalse);

        // Render on Bakalari step and test duplicate refusal
        wiz.step = WizardController.stepBakalari;
        wiz.setDraftSilent('wiz:bakalari_url', 'https://SCHOOL1.TEST/');
        wiz.setDraftSilent('wiz:bakalari_username', 'ANICKA');
        wiz.setDraftSilent('wiz:bakalari_password', 'pw');

        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: WizardView(
              controller: wiz,
              tokens: AppTokens.dark(),
              narrow: true,
            ),
          ),
        ));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('wiz:cancel_add')), findsOneWidget);

        await tester.tap(find.byKey(const Key('wiz:next_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('wiz:duplicate_error')), findsOneWidget);
        expect(wiz.testing, isNull); // never started live test!

        // Dismiss snackbar so it doesn't cover the bottom bar button
        ScaffoldMessenger.of(
          tester.element(find.byKey(const Key('wiz:next_btn'))),
        ).hideCurrentSnackBar();
        await tester.pumpAndSettle();

        // Test duplicate Strava login refusal too
        wiz.goTo(WizardController.stepStrava);
        wiz.setStravaEnabled(true);
        wiz.setDraftSilent('wiz:strava_canteen_id', '2222');
        wiz.setDraftSilent('wiz:strava_username', 'S_TONDA');
        wiz.setDraftSilent('wiz:strava_password', 'pw');
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('wiz:next_btn')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('wiz:duplicate_error')), findsOneWidget);
        expect(wiz.testing, isNull);

        // Cancel deletes ONLY the provisional folder and returns to an existing account
        await tester.tap(find.byKey(const Key('wiz:cancel_add')));
        await tester.pumpAndSettle();
        expect(
          Directory(core.accountDirFor(root.path, provisionalId)).existsSync(),
          isFalse,
        );
        expect(restarted.registry!.byId(provisionalId), isNull);
        expect(restarted.activeAccountId, 'default');
        expect(
          Directory(core.accountDirFor(root.path, 'default')).existsSync(),
          isTrue,
        );

        // Now start a second add-account flow and Finish it
        expect(await restarted.beginAddAccount(), isTrue);
        final addedId = restarted.activeAccountId!;
        restarted.save({
          'bakalari_url': 'https://school3.test',
          'bakalari_username': 'kuba',
          'bakalari_password': 'pw3',
          'your_signature': 'Kuba',
        });
        restarted.wizardFinished();
        expect(restarted.addingAccount, isFalse);
        expect(restarted.registry!.byId(addedId)!.adding, isFalse);
        expect(restarted.registry!.byId(addedId)!.label, 'Kuba');
        expect(restarted.primaryAccountId, 'default'); // unchanged
      },
    );
  });

  group('F4 tutorials & strings', () {
    test('accounts tour and updated settings intro strings exist in cs & en', () {
      final tour = tours['accounts'];
      expect(tour, isNotNull);
      expect(tour!.route, isNull);
      expect(tour.steps.single.key, 'acc_switch');
      expect(tour.steps.single.anchor, 'account_switcher');
      expect(tour.steps.single.place, TourPlace.topLeft);

      for (final lang in ['cs', 'en']) {
        Strings.lang = lang;
        expect(Strings.get('tut_acc_switch_title'), isNotEmpty);
        expect(Strings.get('tut_acc_switch_body'), isNotEmpty);
        expect(
          Strings.get('tut_settings_intro_body').toLowerCase(),
          anyOf(contains('účt'), contains('account')),
        );
        expect(
          Strings.get('tut_settings_intro_body_narrow').toLowerCase(),
          anyOf(contains('účt'), contains('account')),
        );
      }
    });
  });

  group('MorePage single-account remains unchanged', () {
    testWidgets('no account card when onSwitchAccount is null', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MorePage(onOpen: (_) {}),
        ),
      ));
      expect(find.byKey(const Key('more:account_card')), findsNothing);
    });
  });

  group('F4 Aktivita audit history in accounts mode (R6 M1)', () {
    testWidgets(
      'LiveActivityView reads only active account audit history and updates on switchAccount',
      (tester) async {
        final root = await _makeTwoAccountRoot();
        addTearDown(() {
          if (root.existsSync()) root.deleteSync(recursive: true);
        });

        final dir1 = core.accountDirFor(root.path, 'default');
        final dir2 = core.accountDirFor(root.path, 'acc_second');
        expect(
          core.record(
            'excuse',
            'sent',
            'manual',
            '03.11.2026 Matematika (Anička)',
            dataDir: dir1,
          ),
          isTrue,
        );
        expect(
          core.record(
            'excuse',
            'dry_run',
            'auto',
            '04.11.2026 Fyzika (Tonda)',
            dataDir: dir2,
          ),
          isTrue,
        );

        // Direct loadAuditItems reads only the requested account's log.
        final (items1, err1) = loadAuditItems(80, dir1);
        expect(err1, isEmpty);
        expect(items1, hasLength(1));
        expect(items1.single['summary'], '03.11.2026 Matematika (Anička)');
        final (items2, err2) = loadAuditItems(80, dir2);
        expect(err2, isEmpty);
        expect(items2, hasLength(1));
        expect(items2.single['summary'], '04.11.2026 Fyzika (Tonda)');

        final reg = core.AccountRegistry.load(root.path)!;
        final state = AppState(
          layoutResult: core.MultiAccountLayoutResult.ready(reg),
          rootDir: root.path,
        );
        state.ensureWarmedFn = (_) async {};

        tester.view.physicalSize = const Size(1280, 900);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);

        await tester.pumpWidget(ProviderScope(
          overrides: [
            appStateProvider.overrideWith(() => _FixedAppStateController(state)),
          ],
          child: MaterialApp(
            theme: state.tok.toThemeData(),
            home: const Scaffold(
              body: LiveActivityView(narrow: false),
            ),
          ),
        ));
        await tester.pumpAndSettle();

        // Active account ('default' / Anička): sees its own record, no error, KPI = 1.
        expect(find.textContaining('Bad state'), findsNothing);
        expect(find.textContaining('3. 11. 2026 Matematika (Anička)'),
            findsOneWidget);
        expect(
            find.textContaining('4. 11. 2026 Fyzika (Tonda)'), findsNothing);
        final sentCard1 = find.ancestor(
          of: find.text(Strings.get('stat_sent_week')),
          matching: find.byType(Container),
        );
        expect(
          find.descendant(of: sentCard1.first, matching: find.text('1')),
          findsOneWidget,
        );

        // Switch to second account ('acc_second' / Tonda): sees only Tonda's record, KPI = 0.
        expect(await state.switchAccount('acc_second'), isTrue);
        await tester.pumpAndSettle();

        expect(find.textContaining('Bad state'), findsNothing);
        expect(find.textContaining('4. 11. 2026 Fyzika (Tonda)'),
            findsOneWidget);
        expect(find.textContaining('3. 11. 2026 Matematika (Anička)'),
            findsNothing);
        final sentCard2 = find.ancestor(
          of: find.text(Strings.get('stat_sent_week')),
          matching: find.byType(Container),
        );
        expect(
          find.descendant(of: sentCard2.first, matching: find.text('0')),
          findsOneWidget,
        );
      },
    );
  });
}
