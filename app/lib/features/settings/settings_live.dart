import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart';
import '../../platform/android/android_channel.dart';
import '../../widgets/safety_dialog.dart';
import 'settings_controller.dart';
import 'settings_view.dart';

/// Injectable OS autostart hooks (wired by desktop autostart in phase 7).
bool Function()? liveAutostartEnabled;
bool Function(bool wanted)? liveSetAutostart;

/// Bridges the shared [AppState] into a [SettingsController] for
/// [SettingsView].
SettingsController settingsControllerFor(
  AppState s, {
  FutureOr<String> Function(String key)? confirmAutoMode,
  WakeupPhone? wakeupPhone,
}) {
  final cfg = Map<String, dynamic>.of(s.config.data);
  final abs = s.absence();
  final allowed = s.limitSubjects();
  cfg['absence'] = {
    for (final subj in (allowed ?? abs.keys)) subj: abs[subj] ?? 0.0,
  };
  cfg['app_version'] = core.getCurrentVersion();
  cfg['cache_info'] = s.activityUpdatedLabel;

  bool storeManaged = false;
  try {
    storeManaged = core.isStorePackage();
  } catch (_) {}

  final accountIdAtBuild = s.activeAccountId;

  final c = SettingsController(
    cfg,
    confirmAutoMode: confirmAutoMode,
    persist: (updates) {
      if (s.activeAccountId != accountIdAtBuild) return false;
      return s.save(Map<String, Object?>.of(updates));
    },
    persistQuiet: (updates) {
      if (s.activeAccountId != accountIdAtBuild) return false;
      return s.saveQuiet(Map<String, Object?>.of(updates));
    },
    onDraftChanged: (key, value) {
      if (s.activeAccountId != accountIdAtBuild) return;
      s.setDraft(key, value);
    },
    onClearDrafts: (prefix) {
      if (s.activeAccountId != accountIdAtBuild) return;
      s.clearDrafts(prefix);
    },
    onSetSection: (section) => s.setSettingsSection(section),
    onCloseSection: () => s.closeSettingsSection(),
    onTestConnection: (service, overrides) =>
        s.testConnection(service, overrides),
    onSetUpdateChannel: (channel) => s.setUpdateChannel(channel),
    onClearCache: () {
      try {
        final f = File(core.resolvePath(core.cacheFile, s.activeAccountDir));
        if (f.existsSync()) f.deleteSync();
      } catch (_) {
        return false;
      }
      s.reloadCache();
      return true;
    },
    validateConfig: () => s.config.validate(),
    autostartEnabled: liveAutostartEnabled,
    setAutostart: liveSetAutostart,
    storeManaged: storeManaged,
    isAndroid: core.mobilePlatform() == 'android',
    isIos: core.mobilePlatform() == 'ios',
    wakeupAvailable: s.wakeupAvailable,
  );
  if (wakeupPhone != null) {
    c.wakeupPhone = wakeupPhone;
  } else if (s.wakeupAvailable && core.mobilePlatform() != 'ios') {
    c.wakeupPhone = channelWakeupPhone(s);
  }
  c.backgroundStatusInputs = s.backgroundStatusInputs;
  c.backgroundNotificationInterval = s.schoolHoursIntervalForCurrentNetwork;
  c.drafts.addAll(s.drafts);
  c.settingsSection = s.settingsSection;
  c.settingsOpen = s.settingsOpen;
  c.testing = s.testing;
  c.lastTest = Map<String, dynamic>.of(s.lastTest);
  c.updateChannel = s.updateChannel;
  c.accountsEnabled = s.accountsEnabled;
  c.migrationDegraded = s.migrationDegraded;
  c.activeAccountId = s.activeAccountId;
  c.activeAccountLabel = s.activeAccountDisplayLabel;
  c.primaryAccountId = s.primaryAccountId;
  c.primaryAccountLabel = s.primaryAccount != null
      ? s.accountDisplayLabel(s.primaryAccount!)
      : '';
  if (s.accountsEnabled && s.registry != null) {
    final reg = s.registry!;
    c.accounts = [
      for (final acc in reg.accounts)
        () {
          final (user, presetId) = s.accountSummary(acc.id);
          return SettingsAccountItem(
            id: acc.id,
            label: s.accountDisplayLabel(acc),
            username: user,
            presetId: presetId,
            isActive: acc.id == reg.activeId,
            isPrimary: acc.id == reg.primaryId,
            backgroundRefresh: s.accountBackgroundRefresh(acc.id),
            showBackupNoteOnDelete: s.accountDeleteShowsBackupNote(acc.id),
          );
        }(),
    ];
    c.onSwitchAccount = (id) => s.switchAccount(id);
    c.onBeginAddAccount = () => s.beginAddAccount();
    c.onRenameAccount = (id, name) => s.renameAccount(id, name);
    c.onSetPrimaryAccount = (id) => s.setPrimaryAccount(id);
    c.onDeleteAccount = (id) => s.deleteAccount(id);
    c.onSetAccountBackgroundRefresh =
        (id, enabled) => s.setAccountBackgroundRefresh(id, enabled);
    c.checkDuplicateBakalari = (url, username) {
      if (s.registry == null) return null;
      final dup = core.findDuplicateBakalariLogin(
        s.rootDir!,
        s.registry!,
        url: url,
        username: username,
        excludeAccountId: accountIdAtBuild ?? '',
      );
      return dup == null ? null : s.accountDisplayLabel(dup);
    };
    c.checkDuplicateStrava = (canteenId, username) {
      if (s.registry == null) return null;
      final dup = core.findDuplicateStravaLogin(
        s.rootDir!,
        s.registry!,
        canteenId: canteenId,
        username: username,
        excludeAccountId: accountIdAtBuild ?? '',
      );
      return dup == null ? null : s.accountDisplayLabel(dup);
    };
  }
  return c;
}

/// The wake-up card's phone side, backed by the platform channel. The two
/// permission flags are answered asynchronously, so they start as "allowed"
/// and the live screen refreshes them (see `_LiveSettingsViewState` and
/// `_LiveWizardViewState`).
WakeupPhone channelWakeupPhone(
  AppState s, {
  bool notif = true,
  bool exact = true,
  Future<void> Function()? onPermissionChecked,
}) {
  const channel = AndroidChannel();
  return WakeupPhone(
    notificationsEnabled: notif,
    exactAlarmsAllowed: exact,
    nextAlarm: () => s.nextWakeupAlarm(),
    skippedDays: () => s.skippedWakeupDays(),
    openSystemAlarm: (h, m, message, {int? weekday}) =>
        channel.openSystemAlarm(h, m, message: message, weekday: weekday),
    requestNotificationPermission: () => unawaited(() async {
      s.notificationPermissionAsked = true;
      await channel.requestNotificationPermission();
      await onPermissionChecked?.call();
    }()),
    openNotificationSettings: () =>
        unawaited(channel.openNotificationSettings()),
    openExactAlarmSettings: () => unawaited(channel.openExactAlarmSettings()),
  );
}

/// Live settings screen wired to [appStateProvider].
class LiveSettingsView extends ConsumerStatefulWidget {
  final bool narrow;

  const LiveSettingsView({super.key, this.narrow = false});

  @override
  ConsumerState<LiveSettingsView> createState() => _LiveSettingsViewState();
}

class _LiveSettingsViewState extends ConsumerState<LiveSettingsView> {
  /// Survives rebuilds (a new controller is built every time) so a cancelled
  /// switch to auto re-keys the mode pickers and they show the saved mode.
  int _modeRevision = 0;
  bool _notifOn = true;
  bool _exactOn = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appStateProvider).tutorialOffer('settings');
    });
    _loadPermissions();
  }

  Future<void> _loadPermissions() async {
    if (core.mobilePlatform() == 'ios') return;
    if (!ref.read(appStateProvider).wakeupAvailable) return;
    const channel = AndroidChannel();
    final notif = await channel.notificationsEnabled();
    final exact = await channel.exactAlarmsAllowed();
    if (!mounted) return;
    setState(() {
      _notifOn = notif;
      _exactOn = exact;
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appStateProvider);
    final controller = settingsControllerFor(
      s,
      wakeupPhone: (s.wakeupAvailable && core.mobilePlatform() != 'ios')
          ? channelWakeupPhone(
              s,
              notif: _notifOn,
              exact: _exactOn,
              onPermissionChecked: _loadPermissions,
            )
          : null,
      confirmAutoMode: (key) {
        final completer = Completer<String>();
        final unsigned =
            (s.config.data['your_signature'] as String? ?? '').trim().isEmpty;
        confirmAutoMode(
          context,
          key,
          unsigned: unsigned,
          onConfirm: () => completer.complete('confirm'),
          onCancel: () => completer.complete('cancel'),
        );
        return completer.future;
      },
    );
    controller.modeRevision = _modeRevision;
    final platform = core.mobilePlatform() ?? '';
    return SettingsView(
      key: ValueKey('settings:${s.activeAccountId ?? 'single'}'),
      controller: controller,
      narrow: widget.narrow,
      platform: platform,
      onChanged: () {
        _modeRevision = controller.modeRevision;
        ref.read(appStateProvider.notifier).emit();
      },
    );
  }
}
