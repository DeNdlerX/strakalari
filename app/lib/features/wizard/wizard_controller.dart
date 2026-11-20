import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../l10n/strings.dart';
import '../settings/settings_controller.dart' show SettingsController;

/// First-run setup wizard — a `ChangeNotifier` port of
/// `views/wizard.py`.
///
/// Shown full-screen by the shell while setup is needed. Each
/// credential step (Bakaláři, Strava) runs a live test when
/// the user presses Continue — the wizard only advances on success.
/// Finishing kicks off the first data refresh.
///
/// Config keys and file formats are unchanged; the shell provides
/// persistence ([onSave]), live tests ([onTestRequest]) and side
/// effects ([onFinishRefresh], [onAlarmPermission]).
class WizardController extends ChangeNotifier {
/// Reads config values.
  final Map<String, Object?> config;

  /// Persists config updates. False when the write failed.
  final bool Function(Map<String, Object?> updates) onSave;

  /// Persists config updates without emitting a shell rebuild (used when
  /// template rows commit during unmount/dispose). Defaults to [onSave].
  final bool Function(Map<String, Object?> updates) onSaveQuiet;

  /// Starts a live connection test for `service`
  /// (`bakalari | strava`) with draft-backed overrides. The shell
  /// reports back via [recordTestResult].
  final void Function(
      String service, Map<String, String> overrides) onTestRequest;

  /// Runs the first refresh after Finish; true when started.
  final bool Function() onFinishRefresh;

  /// Requests the exact-alarm permission (Android only).
  final void Function() onAlarmPermission;

  /// Requests Android notification permission when continuing from Telefon.
  final Future<void> Function()? onRequestNotificationPermission;

  /// Sets the app language (`cs | en`).
  final void Function(String lang) onSetLanguage;

  /// Optional delegation hooks for shared [AppState] backing.
  final void Function(String key, String value)? onDraftChanged;
  final void Function(String prefix)? onClearDrafts;
  final void Function(int step)? onStepChanged;
  final void Function()? onFinished;
  final void Function(String service, String fp)? onVerified;

  /// Called once Bakaláři credentials are verified and saved (O6 early refresh).
  final void Function(String fingerprint)? onBakalariSaved;

  /// Called when cancelling an add-account wizard (`adding: true`, F4 §10.3).
  final Future<bool> Function()? onCancelAdd;

  /// Duplicate-login checks against other accounts in the registry (F4 §10.3).
  final String? Function(String url, String username)? checkDuplicateBakalari;
  final String? Function(String canteenId, String username)?
      checkDuplicateStrava;

  WizardController({
    Map<String, Object?>? config,
    bool Function(Map<String, Object?> updates)? onSave,
    bool Function(Map<String, Object?> updates)? onSaveQuiet,
    void Function(String service, Map<String, String> overrides)?
        onTestRequest,
    bool Function()? onFinishRefresh,
    void Function()? onAlarmPermission,
    this.onRequestNotificationPermission,
    void Function(String lang)? onSetLanguage,
    this.onDraftChanged,
    this.onClearDrafts,
    this.onStepChanged,
    this.onFinished,
    this.onVerified,
    this.onBakalariSaved,
    this.onCancelAdd,
    this.checkDuplicateBakalari,
    this.checkDuplicateStrava,
  })  : config = config ?? {},
        onSave = onSave ?? ((_) => false),
        onSaveQuiet = onSaveQuiet ?? onSave ?? ((_) => false),
        onTestRequest = onTestRequest ?? ((_, _) {}),
        onFinishRefresh = onFinishRefresh ?? (() => false),
        onAlarmPermission = onAlarmPermission ?? (() {}),
        onSetLanguage = onSetLanguage ?? ((_) {});

  // -- steps ------------------------------------------------------------------------

  static const int stepsTotal = 7;
  static const int stepWelcome = 0;
  static const int stepSchool = 1;
  static const int stepBakalari = 2;
  static const int stepStrava = 3;
  static const int stepExcuses = 4;
  static const int stepPhone = 5;
  static const int stepDone = 6;

  int step = 0;
  bool dismissed = false;

  /// Whether the Phone step (alarm + notification permission) is part of the
  /// flow (Android only).
  bool isAndroid = false;

  /// Active account data dir for `hasDryRun` checks in accounts mode.
  String? accountDataDir;

  /// True ONLY when adding a new account (`activeAccount?.adding == true`, §10.3).
  bool addingAccount = false;

  /// Inline duplicate-login error message and its service (`bakalari | strava`).
  String? duplicateError;
  String? duplicateErrorService;

  /// Service currently being tested (`bakalari | strava`), if any.
  String? testing;

  /// True while awaiting Android's notification permission prompt on Telefon.
  bool requestingPermission = false;

  /// True when the Telefon step embeds Settings' live [WakeupCard], which
  /// persists `wakeup_enabled` and `wakeup_minutes_before` itself.
  bool useExternalWakeupCard = false;

  /// True once the notification permission prompt has already been shown
  /// during this session (for instance from inside [WakeupCard]).
  bool notificationPermissionAlreadyAsked = false;

  /// Last test result: `{service, ok, at, message}`.
  Map<String, Object?> lastTest = {};

  /// Verified fingerprints per service (`wizard_verified`).
  final Map<String, String> verified = {};

  /// Unsaved field text (`drafts`).
  final Map<String, String> drafts = {};

  /// Last user-facing message (snackbar text equivalent).
  String lastMessage = '';

  String draft(String key, [String fallback = '']) =>
      drafts[key] ?? fallback;

  void setDraft(String key, String value) {
    drafts[key] = value;
    duplicateError = null;
    duplicateErrorService = null;
    onDraftChanged?.call(key, value);
    notifyListeners();
  }

  /// Writes a draft without notifying (free typing in text fields).
  void setDraftSilent(String key, String value) {
    drafts[key] = value;
    duplicateError = null;
    duplicateErrorService = null;
    onDraftChanged?.call(key, value);
  }

  void clearDrafts([String prefix = '']) {
    if (prefix.isEmpty) {
      drafts.clear();
    } else {
      drafts.removeWhere((k, _) => k.startsWith(prefix));
    }
    onClearDrafts?.call(prefix);
  }

  List<int> shownSteps() {
    final skipWelcome = addingAccount && config['disclaimer_accepted'] == true;
    final skipPhone = addingAccount || !isAndroid;
    return [
      for (var i = 0; i < stepsTotal; i++)
        if ((i != stepWelcome || !skipWelcome) &&
            (i != stepPhone || !skipPhone))
          i,
    ];
  }

  int get firstShownStep => shownSteps().first;

  bool get canGoBack => step > firstShownStep;

  int stepAfter(int from) {
    for (final s in shownSteps()) {
      if (s > from) return s;
    }
    return stepDone;
  }

  int stepBefore(int from) {
    var prev = firstShownStep;
    for (final s in shownSteps()) {
      if (s < from) prev = s;
    }
    return prev;
  }

  void goTo(int target) {
    duplicateError = null;
    duplicateErrorService = null;
    step = target.clamp(0, stepDone);
    onStepChanged?.call(step);
    notifyListeners();
  }

  Future<bool> pressCancelAdd() async {
    if (!addingAccount || onCancelAdd == null) return false;
    return await onCancelAdd!();
  }

  void finishWizard() {
    dismissed = true;
    step = 0;
    clearDrafts('wiz:');
    verified.clear();
    onFinished?.call();
    notifyListeners();
  }

  // -- toggles ------------------------------------------------------------------------

  bool get stravaEnabled {
    final raw = drafts['wiz:strava_enabled'];
    if (raw != null) return raw == '1';
    return (config['use_strava'] ?? true) == true;
  }

  String get stravaOrderMode {
    final raw = drafts['wiz:strava_order_mode'] ??
        '${config['strava_order_mode'] ?? 'confirm'}';
    return (raw == 'auto' || raw == 'dry_run' || raw == 'confirm')
        ? raw
        : 'confirm';
  }

  bool get stravaAutoOrder => stravaOrderMode == 'auto';

  bool get alarmEnabled {
    final raw = drafts['wiz:wakeup_enabled'];
    if (raw != null) return raw == '1';
    return (config['wakeup_enabled'] ?? false) == true;
  }

  bool get disclaimerOk {
    final raw = drafts['wiz:disclaimer'];
    if (raw == '1') return true;
    if (raw == '0') return false;
    return (config['disclaimer_accepted'] ?? false) == true;
  }

  void setStravaEnabled(bool on) =>
      setDraft('wiz:strava_enabled', on ? '1' : '');

  void setStravaOrderMode(String mode) {
    final normalized = (mode == 'auto' || mode == 'dry_run') ? mode : 'confirm';
    setDraft('wiz:strava_order_mode', normalized);
  }

  void setAlarmEnabled(bool on) =>
      setDraft('wiz:wakeup_enabled', on ? '1' : '');

  void setDisclaimer(bool ack) =>
      setDraft('wiz:disclaimer', ack ? '1' : '0');

  // -- prefills -------------------------------------------------------------------------

  String activePresetId() {
    final picked = calPreset();
    if (picked.isNotEmpty) return picked;
    return '${config['school_preset_id'] ?? ''}'.trim();
  }

  String presetBakalariUrl() => core.presetBakalariUrl(activePresetId());

  String presetCanteenId() => core.presetCanteenId(activePresetId());

  String effectiveBakalariUrl() {
    final d = drafts['wiz:bakalari_url']?.trim();
    if (d != null && (d.isNotEmpty || showBakalariUrlField)) return d;
    final cfg = '${config['bakalari_url'] ?? ''}'.trim();
    if (cfg.isNotEmpty) return cfg;
    return presetBakalariUrl();
  }

  String effectiveCanteenId() {
    final d = drafts['wiz:strava_canteen_id']?.trim();
    if (d != null && (d.isNotEmpty || showStravaCanteenField)) return d;
    final cfg = '${config['strava_canteen_id'] ?? ''}'.trim();
    if (cfg.isNotEmpty) return cfg;
    return presetCanteenId();
  }

  bool get showBakalariUrlField {
    final preset = presetBakalariUrl();
    if (preset.isEmpty) return true;
    final cfg = '${config['bakalari_url'] ?? ''}'.trim();
    if (cfg.isNotEmpty && cfg != preset) return true;
    final d = drafts['wiz:bakalari_url']?.trim();
    return d != null && d.isNotEmpty && d != preset;
  }

  bool get showStravaCanteenField {
    final preset = presetCanteenId();
    if (preset.isEmpty) return true;
    final cfg = '${config['strava_canteen_id'] ?? ''}'.trim();
    if (cfg.isNotEmpty && cfg != preset) return true;
    final d = drafts['wiz:strava_canteen_id']?.trim();
    return d != null && d.isNotEmpty && d != preset;
  }

  // -- per-step saves -------------------------------------------------------------------

  bool saveBakalari() {
    final url = effectiveBakalariUrl();
    final user = draft('wiz:bakalari_username',
            '${config['bakalari_username'] ?? ''}')
        .trim();
    final pw = draft('wiz:bakalari_password', '');
    final hasPw = pw.trim().isNotEmpty ||
        '${config['bakalari_password'] ?? ''}'.isNotEmpty;
    if (url.isEmpty || user.isEmpty || !hasPw) return false;
    final updates = {
      'bakalari_url': url,
      'bakalari_username': user,
    };
    if (pw.isNotEmpty) updates['bakalari_password'] = pw;
    return _save(updates);
  }

  bool saveStrava() {
    if (!stravaEnabled) return _save({'use_strava': false});
    final user = draft('wiz:strava_username',
            '${config['strava_username'] ?? ''}')
        .trim();
    final pw = draft('wiz:strava_password', '');
    final cid = effectiveCanteenId();
    final hasPw = pw.trim().isNotEmpty ||
        '${config['strava_password'] ?? ''}'.isNotEmpty;
    if (user.isEmpty || !hasPw || cid.isEmpty) return false;
    final updates = <String, Object?>{
      'use_strava': true,
      'strava_username': user,
      'strava_canteen_id': cid,
    };
    final rawMode = drafts['wiz:strava_order_mode'];
    if (rawMode == 'auto' || rawMode == 'confirm' || rawMode == 'dry_run') {
      updates['strava_order_mode'] = rawMode!;
    }
    if (pw.isNotEmpty) updates['strava_password'] = pw;
    return _save(updates);
  }

  /// Android exact-alarm status: show the "exact alarms off" hint and
  /// the allow button when true (shell: available && !allowed).
  bool alarmExactOff = false;

  // -- school / calendar ---------------------------------------------------------------------

  /// Grouped school presets for the Škola step (`schoolGroups`).
  List<core.SchoolGroup> schoolOptions = [];

  /// Selectable school calendars (legacy flat list used by tests).
  List<CalendarPreset> calendarOptions = [];

  Set<String> _knownSchoolPresetIds() => {
        for (final g in schoolOptions)
          for (final p in g.presets) p.id,
        for (final p in calendarOptions) p.id,
        if (schoolOptions.isNotEmpty) core.customId,
      };

  /// The explicitly picked card (`wiz:cal_preset`), or ''.
  String calPreset() {
    final raw = drafts['wiz:cal_preset'];
    if (raw == null || raw.isEmpty) return '';
    if (_knownSchoolPresetIds().contains(raw)) return raw;
    return '';
  }

  /// Selected school card name (`SchoolGroup.name` or `core.customId`), or ''.
  String selectedSchoolGroup() {
    final rawGroup = drafts['wiz:school_group'];
    if (rawGroup != null && rawGroup.isNotEmpty) {
      if (rawGroup == core.customId ||
          schoolOptions.any((g) => g.name == rawGroup)) {
        return rawGroup;
      }
    }
    final picked = calPreset();
    if (picked == core.customId) return core.customId;
    for (final g in schoolOptions) {
      if (g.presets.any((p) => p.id == picked)) return g.name;
    }
    return '';
  }

  void selectSchoolGroup(String groupName) {
    setDraftSilent('wiz:school_group', groupName);
    if (groupName == core.customId) {
      setDraft('wiz:cal_preset', core.customId);
      return;
    }
    final match = schoolOptions.where((g) => g.name == groupName).toList();
    if (match.isEmpty) {
      notifyListeners();
      return;
    }
    final group = match.first;
    if (group.presets.length == 1) {
      setDraft('wiz:cal_preset', group.presets.single.id);
    } else if (group.presets.any((p) => p.id == calPreset())) {
      notifyListeners();
    } else {
      setDraft('wiz:cal_preset', '');
    }
  }

  void selectSchoolPreset(String presetId) {
    for (final g in schoolOptions) {
      if (g.presets.any((p) => p.id == presetId)) {
        setDraftSilent('wiz:school_group', g.name);
        break;
      }
    }
    setDraft('wiz:cal_preset', presetId);
  }

  bool saveCalendar() {
    final preset = calPreset();
    if (preset.isEmpty || !_knownSchoolPresetIds().contains(preset)) {
      return false;
    }
    if ('${config['school_preset_id'] ?? ''}' == preset) return true;
    return _save({'school_preset_id': preset});
  }

  // -- phone + signature --------------------------------------------------------------------------

  bool get shouldAskNotificationPermission =>
      (config['run_in_background'] ?? true) == true ||
      (config['wakeup_enabled'] ?? false) == true ||
      alarmEnabled;

  bool savePhone() {
    if (useExternalWakeupCard) return true;
    if (!_save({'wakeup_enabled': alarmEnabled})) return false;
    if (alarmEnabled) onAlarmPermission();
    return true;
  }

  String signature() => draft(
          'wiz:signature', '${config['your_signature'] ?? ''}')
      .trim();

  bool saveSignature() {
    final name = signature();
    if (name.isEmpty) return false;
    return _save({'your_signature': name});
  }

  // -- excuse templates (excuses step) ---------------------------------------------------------------

  bool saveTemplateList(String key, List<Map<String, String>> values) =>
      SettingsController.commitTemplatesList(
        current: config[key] ?? const [],
        values: values,
        saveCleaned: (cleaned) => _saveQuiet({key: cleaned}),
      );

  // -- live tests ----------------------------------------------------------------------------------------

  Map<String, String> overridesFor(String service) {
    switch (service) {
      case 'bakalari':
        final ov = {
          'bakalari_url': effectiveBakalariUrl(),
          'bakalari_username': draft(
                  'wiz:bakalari_username',
                  '${config['bakalari_username'] ?? ''}')
              .trim(),
        };
        final pw = draft('wiz:bakalari_password', '');
        if (pw.trim().isNotEmpty) ov['bakalari_password'] = pw;
        return ov;
      case 'strava':
        final ov = {
          'strava_username': draft('wiz:strava_username',
                  '${config['strava_username'] ?? ''}')
              .trim(),
          'strava_canteen_id': effectiveCanteenId(),
        };
        final pw = draft('wiz:strava_password', '');
        if (pw.trim().isNotEmpty) ov['strava_password'] = pw;
        return ov;
      default:
        return {};
    }
  }

  /// Fingerprint of the values a test ran against (re-test on change).
  String fingerprintFor(String service) {
    final entries = overridesFor(service).entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return '$service:${entries.map((e) => '${e.key}=${e.value}').join(',')}';
  }

  bool readyBakalari() {
    final ov = overridesFor('bakalari');
    final hasPw = (ov['bakalari_password']?.isNotEmpty == true) ||
        '${config['bakalari_password'] ?? ''}'.isNotEmpty;
    return (ov['bakalari_url']?.isNotEmpty == true) &&
        (ov['bakalari_username']?.isNotEmpty == true) &&
        hasPw;
  }

  bool readyStrava() {
    if (!stravaEnabled) return true;
    final ov = overridesFor('strava');
    final hasPw = (ov['strava_password']?.isNotEmpty == true) ||
        '${config['strava_password'] ?? ''}'.isNotEmpty;
    return (ov['strava_username']?.isNotEmpty == true) &&
        hasPw &&
        (ov['strava_canteen_id']?.isNotEmpty == true);
  }

  bool _testNeeded(String service) {
    if (service == 'strava' && !stravaEnabled) return false;
    return verified[service] != fingerprintFor(service);
  }

  /// Continue handler shared by the tested steps — like
  /// `wizard._continue_test_step`. Returns a message for the shell to
  /// show (null = auto-advanced, no message).
  String? continueTestStep(
      String service, int atStep, bool readyOk, String needKey) {
    if (!readyOk) return Strings.get(needKey);
    // Refuse duplicate logins against existing accounts (§10.3).
    if (service == 'bakalari' && checkDuplicateBakalari != null) {
      final ov = overridesFor('bakalari');
      final dup = checkDuplicateBakalari!(
        ov['bakalari_url'] ?? '',
        ov['bakalari_username'] ?? '',
      );
      if (dup != null) {
        final msg = Strings.format('account_duplicate_login', {'name': dup});
        duplicateError = msg;
        duplicateErrorService = service;
        notifyListeners();
        return msg;
      }
    }
    if (service == 'strava' && stravaEnabled && checkDuplicateStrava != null) {
      final ov = overridesFor('strava');
      final dup = checkDuplicateStrava!(
        ov['strava_canteen_id'] ?? '',
        ov['strava_username'] ?? '',
      );
      if (dup != null) {
        final msg = Strings.format('account_duplicate_login', {'name': dup});
        duplicateError = msg;
        duplicateErrorService = service;
        notifyListeners();
        return msg;
      }
    }
    duplicateError = null;
    duplicateErrorService = null;
    final fp = fingerprintFor(service);
    if (verified[service] == fp) {
      if (!_saveFor(service)) return Strings.get('save_failed');
      if (service == 'bakalari') {
        onBakalariSaved?.call(fp);
      }
      goTo(stepAfter(atStep));
      return null;
    }
    if (testing != null) return '';
    testing = service;
    notifyListeners();
    onTestRequest(service, overridesFor(service));
    return '';
  }

  bool _saveFor(String service) {
    switch (service) {
      case 'bakalari':
        return saveBakalari();
      case 'strava':
        return saveStrava();
      default:
        return false;
    }
  }

  /// Records a live-test result and runs the `_on_done` logic: on
  /// success the values are saved, the fingerprint marked verified and
  /// the wizard auto-advances (when still on the same step with
  /// unchanged fields). Returns a message to show, if any.
  String? recordTestResult(String service, bool ok, String message) {
    final wasTesting = testing;
    testing = null;
    lastTest = {
      'service': service,
      'ok': ok,
      'at': _testTimestamp(),
      'message': message,
    };
    notifyListeners();
    if (!ok || wasTesting != service) return null;
    final fp = fingerprintFor(service);
    if (!_saveFor(service)) return Strings.get('save_failed');
    verified[service] = fp;
    onVerified?.call(service, fp);
    if (service == 'bakalari') {
      onBakalariSaved?.call(fp);
    }
    // Auto-advance only when still on the same step with unchanged fields.
    if (fingerprintFor(service) == fp) {
      // The caller re-reads the current step; the view passes it in.
      _pendingAutoAdvance = service;
      notifyListeners();
    }
    return null;
  }

  String? _pendingAutoAdvance;

  /// Consumes a pending auto-advance for `atStep` (the view calls this
  /// after [recordTestResult] when the shown step still matches).
  bool consumeAutoAdvance(int atStep, String service) {
    if (_pendingAutoAdvance != service) return false;
    _pendingAutoAdvance = null;
    goTo(stepAfter(atStep));
    return true;
  }

  String _testTimestamp() {
    final now = clock.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  // -- Continue / Back / Skip ------------------------------------------------------------------------------

  /// Result of pressing Continue: `advanced` plus an optional snackbar
  /// message. `finishedMessage` is set when the DONE step completes.
  ({bool advanced, String? snack, String? finishedMessage}) pressNext() {
    final atStep = step.clamp(0, stepDone);
    switch (atStep) {
      case stepWelcome:
        if (!disclaimerOk) {
          return (
            advanced: false,
            snack: Strings.get('wiz_disclaimer_need'),
            finishedMessage: null
          );
        }
        if (config['disclaimer_accepted'] != true) {
          _save({'disclaimer_accepted': true});
        }
        break;
      case stepSchool:
        if (!saveCalendar()) {
          return (
            advanced: false,
            snack: Strings.get(calPreset().isEmpty
                ? 'wiz_cal_pick'
                : 'save_failed'),
            finishedMessage: null
          );
        }
        break;
      case stepBakalari:
        final snack = continueTestStep(
            'bakalari', atStep, readyBakalari(), 'wiz_need_bakalari');
        return (advanced: false, snack: snack, finishedMessage: null);
      case stepStrava:
        if (!stravaEnabled) {
          if (saveStrava()) {
            goTo(stepAfter(atStep));
            return (
              advanced: true,
              snack: null,
              finishedMessage: null
            );
          }
          return (
            advanced: false,
            snack: Strings.get('save_failed'),
            finishedMessage: null
          );
        }
        final snack = continueTestStep(
            'strava', atStep, readyStrava(), 'wiz_need_strava');
        return (advanced: false, snack: snack, finishedMessage: null);
      case stepExcuses:
        if (!saveSignature()) {
          return (
            advanced: false,
            snack: Strings.get(signature().isEmpty
                ? 'wiz_need_signature'
                : 'save_failed'),
            finishedMessage: null
          );
        }
        break;
      case stepPhone:
        if (!savePhone()) {
          return (
            advanced: false,
            snack: Strings.get('save_failed'),
            finishedMessage: null
          );
        }
        final ask = onRequestNotificationPermission;
        if (shouldAskNotificationPermission &&
            !notificationPermissionAlreadyAsked &&
            ask != null) {
          if (!requestingPermission) {
            requestingPermission = true;
            notifyListeners();
            ask().whenComplete(() {
              requestingPermission = false;
              goTo(stepAfter(atStep));
            });
          }
          return (advanced: false, snack: null, finishedMessage: null);
        }
        break;
      default:
        break;
    }
    if (atStep >= stepDone) {
      finishWizard();
      final started = onFinishRefresh();
      return (
        advanced: true,
        snack: null,
        finishedMessage: Strings.get(started
            ? 'wiz_finishing_refresh'
            : 'already_running')
      );
    }
    goTo(stepAfter(atStep));
    return (advanced: true, snack: null, finishedMessage: null);
  }

  void pressBack() => goTo(stepBefore(step));

  /// One step only, nothing saved — skipping must never jump past the
  /// remaining steps and finish the setup.
  void pressSkip() => goTo(stepAfter(step));

  /// Next-button label: `Test & continue` while a test is still needed.
  String nextLabel() {
    const tested = {
      stepBakalari: 'bakalari',
      stepStrava: 'strava',
    };
    final service = tested[step];
    if (service != null && _testNeeded(service)) {
      return Strings.get('wiz_test_continue');
    }
    return Strings.get('wiz_next');
  }

  /// Whether Skip is offered on this step (welcome includes the required
  /// disclaimer and cannot be skipped; add-account mode has only Finish and
  /// Cancel so no empty account is left behind, §10.3).
  bool get canSkip =>
      !addingAccount &&
      step != stepWelcome &&
      step < stepDone;

  /// Whether Continue is enabled (welcome needs disclaimer ack, school
  /// needs a pick, and no advance while a test runs).
  bool get nextEnabled {
    if (step == stepWelcome && !disclaimerOk) return false;
    if (step == stepSchool && calPreset().isEmpty) return false;
    if (testing != null || requestingPermission) return false;
    return true;
  }

  bool _persist(
    Map<String, Object?> updates,
    bool Function(Map<String, Object?> updates) writer,
  ) {
    final ok = writer(updates);
    if (ok) config.addAll(updates);
    return ok;
  }

  bool _save(Map<String, Object?> updates) => _persist(updates, onSave);

  bool _saveQuiet(Map<String, Object?> updates) =>
      _persist(updates, onSaveQuiet);
}

/// A selectable school calendar card — preset data resolved by the
/// shell (`school_presets.preset_options` + `preset_closes` +
/// day counts).
class CalendarPreset {
  final String id;
  final String title;

  /// `Uzávěrky: a / b` parts (or `auto`).
  final String closesA;
  final String closesB;

  /// `(total, [(label, count)])` grouped free days.
  final int totalDays;
  final List<({String label, int count})> groups;

  /// End date label for `{n} dní volna do {end}`.
  final String endText;
  final bool custom;

  const CalendarPreset({
    required this.id,
    required this.title,
    this.closesA = '',
    this.closesB = '',
    this.totalDays = 0,
    this.groups = const [],
    this.endText = '',
    this.custom = false,
  });
}
