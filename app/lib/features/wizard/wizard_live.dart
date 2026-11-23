import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart';
import '../../l10n/strings.dart';
import '../../platform/android/android_channel.dart';

import '../common/app_tokens.dart';
import '../settings/settings_controller.dart' show WakeupPhone;
import '../settings/settings_live.dart'
    show channelWakeupPhone, settingsControllerFor;
import 'wizard_controller.dart';
import 'wizard_view.dart';

/// Builds selectable [CalendarPreset] cards from `school_presets`.
List<CalendarPreset> buildCalendarPresets([String? language]) {
  String lang = language ?? 'cs';
  try {
    if (language == null) lang = core.getLanguage();
  } catch (_) {}
  final out = <CalendarPreset>[];
  for (final (pid, title) in core.presetOptions(lang)) {
    final (closesA, closesB) = core.presetCloses(pid);
    final daysMap = core.presetDays(pid);
    final sortedDays = daysMap.keys.toList()..sort();
    final counts = <String, int>{};
    for (final d in sortedDays) {
      final lbl = (daysMap[d] ?? '').trim();
      final key = lbl.isEmpty ? '—' : lbl;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    out.add(CalendarPreset(
      id: pid,
      title: title,
      closesA: closesA,
      closesB: closesB,
      totalDays: daysMap.length,
      groups: [
        for (final e in counts.entries) (label: e.key, count: e.value),
      ],
      endText: closesB,
      custom: false,
    ));
  }
  out.add(CalendarPreset(
    id: core.customId,
    title: Strings.get('wiz_cal_custom'),
    custom: true,
  ));
  return out;
}

/// Bridges the shared [AppState] into a [WizardController] for
/// [WizardView].
WizardController wizardControllerFor(AppState s) {
  String lang = 'cs';
  try {
    lang = core.getLanguage();
  } catch (_) {}

  final accountIdAtBuild = s.activeAccountId;

  late final WizardController c;
  c = WizardController(
    config: Map<String, Object?>.of(s.config.data),
    onSave: (updates) {
      if (s.activeAccountId != accountIdAtBuild) return false;
      return s.save(updates);
    },
    onSaveQuiet: (updates) {
      if (s.activeAccountId != accountIdAtBuild) return false;
      return s.saveQuiet(updates);
    },
    onTestRequest: (service, overrides) {
      s.testConnection(
        service,
        Map<String, Object?>.of(overrides),
        (ok, msg) {
          final err = c.recordTestResult(service, ok, msg);
          if (err == null) {
            c.consumeAutoAdvance(c.step, service);
          }
        },
      );
    },
    onFinishRefresh: () => s.finishWizardRefresh(),
    onRequestNotificationPermission: () async {
      s.notificationPermissionAsked = true;
      if (core.mobilePlatform() == 'ios') return;
      await const AndroidChannel().requestNotificationPermission();
    },
    onSetLanguage: (l) => s.setLanguage(l),
    onDraftChanged: (key, value) {
      if (s.activeAccountId != accountIdAtBuild) return;
      s.setDraft(key, value);
    },
    onClearDrafts: (prefix) {
      if (s.activeAccountId != accountIdAtBuild) return;
      s.clearDrafts(prefix);
    },
    onStepChanged: (step) => s.wizardGoto(step, WizardController.stepDone),
    onFinished: () => s.wizardFinished(),
    onVerified: (service, fp) {
      s.wizardVerified[service] = fp;
    },
    onBakalariSaved: (fp) {
      if (s.wizardEarlyRefreshedFp == fp) return;
      if (s.startRefresh('bakalari', true)) {
        s.wizardEarlyRefreshedFp = fp;
      }
    },
    onCancelAdd: () => s.cancelAddAccount(),
    checkDuplicateBakalari: (s.accountsEnabled && s.rootDir != null)
        ? (url, username) {
            if (s.registry == null) return null;
            final dup = core.findDuplicateBakalariLogin(
              s.rootDir!,
              s.registry!,
              url: url,
              username: username,
              excludeAccountId: accountIdAtBuild ?? '',
            );
            return dup == null ? null : s.accountDisplayLabel(dup);
          }
        : null,
    checkDuplicateStrava: (s.accountsEnabled && s.rootDir != null)
        ? (canteenId, username) {
            if (s.registry == null) return null;
            final dup = core.findDuplicateStravaLogin(
              s.rootDir!,
              s.registry!,
              canteenId: canteenId,
              username: username,
              excludeAccountId: accountIdAtBuild ?? '',
            );
            return dup == null ? null : s.accountDisplayLabel(dup);
          }
        : null,
  );
  c.step = s.wizardStep;
  c.dismissed = s.wizardDismissed;
  c.isAndroid = core.mobilePlatform() == 'android';
  // Add-account mode reads ONLY the active account's `adding` flag (§10.3).
  c.addingAccount = s.addingAccount;
  c.useExternalWakeupCard = true;
  c.notificationPermissionAlreadyAsked = s.notificationPermissionAsked;
  c.testing = s.testing.isEmpty ? null : s.testing;
  c.lastTest = Map<String, Object?>.of(s.lastTest);
  c.verified.addAll(s.wizardVerified);
  c.drafts.addAll(s.drafts);
  c.schoolOptions = core.schoolGroups(lang);
  c.calendarOptions = buildCalendarPresets(lang);

  return c;
}

/// Live first-run setup wizard wired to [appStateProvider].
class LiveWizardView extends ConsumerStatefulWidget {
  final AppTokens? tokens;
  final bool narrow;
  final WakeupPhone? wakeupPhone;

  const LiveWizardView({
    super.key,
    this.tokens,
    this.narrow = false,
    this.wakeupPhone,
  });

  @override
  ConsumerState<LiveWizardView> createState() => _LiveWizardViewState();
}

class _LiveWizardViewState extends ConsumerState<LiveWizardView>
    with WidgetsBindingObserver {
  bool _notifOn = true;
  bool _exactOn = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appStateProvider).wizardOpened();
    });
    _loadPermissions();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadPermissions();
    }
  }

  Future<void> _loadPermissions() async {
    if (widget.wakeupPhone != null) return;
    if (core.mobilePlatform() == 'ios') return;
    final s = ref.read(appStateProvider);
    if (core.mobilePlatform() != 'android' && !s.wakeupAvailable) return;
    const channel = AndroidChannel();
    final notif = await channel.notificationsEnabled();
    final exact = await channel.exactAlarmsAllowed();
    if (!mounted) return;
    setState(() {
      _notifOn = notif;
      _exactOn = exact;
    });
  }

  WakeupPhone _wrapInjectedPhone(AppState s, WakeupPhone p) => WakeupPhone(
        notificationsEnabled: p.notificationsEnabled,
        exactAlarmsAllowed: p.exactAlarmsAllowed,
        nextAlarm: p.nextAlarm,
        skippedDays: p.skippedDays,
        openSystemAlarm: p.openSystemAlarm,
        requestNotificationPermission: () {
          s.notificationPermissionAsked = true;
          p.requestNotificationPermission();
        },
        openNotificationSettings: p.openNotificationSettings,
        openExactAlarmSettings: p.openExactAlarmSettings,
      );

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(appStateProvider);
    final tok = widget.tokens ?? s.appTokens;
    if (s.wizardDismissed || !s.setupPending) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) context.go('/today');
      });
      return Scaffold(
        backgroundColor: tok.bg,
        body: const SizedBox.shrink(),
      );
    }
    final controller = wizardControllerFor(s);
    final phone = widget.wakeupPhone != null
        ? _wrapInjectedPhone(s, widget.wakeupPhone!)
        : (core.mobilePlatform() == 'ios'
            ? null
            : channelWakeupPhone(
                s,
                notif: _notifOn,
                exact: _exactOn,
                onPermissionChecked: _loadPermissions,
              ));
    final wakeupController = settingsControllerFor(s, wakeupPhone: phone);
    return WizardView(
      controller: controller,
      tokens: tok,
      narrow: widget.narrow,
      wakeupController: wakeupController,
    );
  }
}
