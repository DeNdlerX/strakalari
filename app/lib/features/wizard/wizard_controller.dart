import 'package:flutter/foundation.dart';

import '../common/app_strings.dart';
import '../common/format.dart';

/// First-run setup wizard — a `ChangeNotifier` port of
/// `views/wizard.py`.
///
/// Shown full-screen by the shell while setup is needed. Each
/// credential step (Bakaláři, Strava, AI key) runs a live test when
/// the user presses Continue — the wizard only advances on success.
/// Finishing kicks off the first data refresh.
///
/// Config keys and file formats are unchanged; the shell provides
/// persistence ([onSave]), live tests ([onTestRequest]) and side
/// effects ([onFinishRefresh], [onOpenUrl], [onAlarmPermission]).
class WizardController extends ChangeNotifier {
  final AppStrings s;

  /// Reads config values.
  final Map<String, Object?> config;

  /// Persists config updates. False when the write failed.
  final bool Function(Map<String, Object?> updates) onSave;

  /// Starts a live connection test for `service`
  /// (`bakalari | strava | ai`) with draft-backed overrides. The shell
  /// reports back via [recordTestResult].
  final void Function(
      String service, Map<String, String> overrides) onTestRequest;

  /// Runs the first refresh after Finish; true when started.
  final bool Function() onFinishRefresh;

  /// Opens the AI Studio key page.
  final void Function() onOpenUrl;

  /// Requests the exact-alarm permission (Android only).
  final void Function() onAlarmPermission;

  /// Starts the one-time Bakaláři-only refresh when the limits step
  /// shows with no subjects yet.
  final void Function() onLimitsRefresh;

  /// Sets the app language (`cs | en`).
  final void Function(String lang) onSetLanguage;

  /// Optional delegation hooks for shared [AppState] backing.
  final void Function(String key, String value)? onDraftChanged;
  final void Function(String prefix)? onClearDrafts;
  final void Function(int step)? onStepChanged;
  final void Function()? onFinished;
  final void Function(String service, String fp)? onVerified;

  WizardController({
    this.s = const AppStrings(),
    Map<String, Object?>? config,
    bool Function(Map<String, Object?> updates)? onSave,
    void Function(String service, Map<String, String> overrides)?
        onTestRequest,
    bool Function()? onFinishRefresh,
    void Function()? onOpenUrl,
    void Function()? onAlarmPermission,
    void Function()? onLimitsRefresh,
    void Function(String lang)? onSetLanguage,
    this.onDraftChanged,
    this.onClearDrafts,
    this.onStepChanged,
    this.onFinished,
    this.onVerified,
  })  : config = config ?? {},
        onSave = onSave ?? ((_) => false),
        onTestRequest = onTestRequest ?? ((_, _) {}),
        onFinishRefresh = onFinishRefresh ?? (() => false),
        onOpenUrl = onOpenUrl ?? (() {}),
        onAlarmPermission = onAlarmPermission ?? (() {}),
        onLimitsRefresh = onLimitsRefresh ?? (() {}),
        onSetLanguage = onSetLanguage ?? ((_) {});

  // -- steps ------------------------------------------------------------------------

  static const int stepsTotal = 10;
  static const int stepWelcome = 0;
  static const int stepDisclaimer = 1;
  static const int stepBakalari = 2;
  static const int stepLimits = 3;
  static const int stepStrava = 4;
  static const int stepAi = 5;
  static const int stepCalendar = 6;
  static const int stepAlarm = 7;
  static const int stepExcuses = 8;
  static const int stepDone = 9;

  int step = 0;
  bool dismissed = false;

  /// Whether the wake-up alarm step is part of the flow (Android only).
  bool isAndroid = false;

  /// Service currently being tested (`bakalari | strava | ai`), if any.
  String? testing;

  /// Last test result: `{service, ok, at, message}`.
  Map<String, Object?> lastTest = {};

  /// Verified fingerprints per service (`wizard_verified`).
  final Map<String, String> verified = {};

  /// Unsaved field text (`drafts`).
  final Map<String, String> drafts = {};

  /// Last user-facing message (snackbar text equivalent).
  String lastMessage = '';

  /// The limits refresh was already triggered once.
  bool get limitsRefreshStarted =>
      drafts.containsKey('wiz:limits_refresh');

  String draft(String key, [String fallback = '']) =>
      drafts[key] ?? fallback;

  void setDraft(String key, String value) {
    drafts[key] = value;
    onDraftChanged?.call(key, value);
    notifyListeners();
  }

  /// Writes a draft without notifying (free typing in text fields).
  void setDraftSilent(String key, String value) {
    drafts[key] = value;
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

  List<int> shownSteps() => [
        for (var i = 0; i < stepsTotal; i++)
          if (i != stepAlarm || isAndroid) i
      ];

  int stepAfter(int from) {
    for (final s in shownSteps()) {
      if (s > from) return s;
    }
    return stepDone;
  }

  int stepBefore(int from) {
    var prev = 0;
    for (final s in shownSteps()) {
      if (s < from) prev = s;
    }
    return prev;
  }

  void goTo(int target) {
    step = target.clamp(0, stepDone);
    onStepChanged?.call(step);
    notifyListeners();
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

  bool get aiEnabled {
    final raw = drafts['wiz:ai_enabled'];
    if (raw != null) return raw == '1';
    return '${config['gemini_api_key'] ?? ''}'.isNotEmpty;
  }

  bool get alarmEnabled {
    final raw = drafts['wiz:wakeup_enabled'];
    if (raw != null) return raw == '1';
    return (config['wakeup_enabled'] ?? false) == true;
  }

  bool get disclaimerOk =>
      drafts['wiz:disclaimer']?.isNotEmpty == true ||
      (config['disclaimer_accepted'] ?? false) == true;

  void setStravaEnabled(bool on) =>
      setDraft('wiz:strava_enabled', on ? '1' : '');

  void setAiEnabled(bool on) =>
      setDraft('wiz:ai_enabled', on ? '1' : '');

  void setAlarmEnabled(bool on) =>
      setDraft('wiz:wakeup_enabled', on ? '1' : '');

  void setDisclaimer(bool ack) =>
      setDraft('wiz:disclaimer', ack ? '1' : '');

  // -- per-step saves -------------------------------------------------------------------

  bool saveBakalari() {
    final url = draft('wiz:bakalari_url',
            '${config['bakalari_url'] ?? ''}')
        .trim();
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
    final cid = draft('wiz:strava_canteen_id',
            '${config['strava_canteen_id'] ?? ''}')
        .trim();
    final hasPw = pw.trim().isNotEmpty ||
        '${config['strava_password'] ?? ''}'.isNotEmpty;
    if (user.isEmpty || !hasPw || cid.isEmpty) return false;
    final updates = <String, Object?>{
      'use_strava': true,
      'strava_username': user,
      'strava_canteen_id': cid,
    };
    if (pw.isNotEmpty) updates['strava_password'] = pw;
    return _save(updates);
  }

  bool saveAi() {
    if (!aiEnabled) {
      // Disabling must stick: clear the stored key (encrypt("") reads
      // back falsy), otherwise the old key silently re-enables AI.
      return _save(
          {'gemini_api_key': '', 'gemini_api_key_encrypted': false});
    }
    final key = draft('wiz:ai_key', '').trim();
    final hasKey = key.isNotEmpty ||
        '${config['gemini_api_key'] ?? ''}'.isNotEmpty;
    if (!hasKey) return false;
    final updates = <String, Object?>{};
    if (key.isNotEmpty) updates['gemini_api_key'] = key;
    final model = draft('wiz:ai_model',
            '${config['gemini_model'] ?? 'gemini-3.8-flash'}')
        .trim();
    if (model.isNotEmpty) updates['gemini_model'] = model;
    if (updates.isEmpty) return true;
    return _save(updates);
  }

  // -- limits -------------------------------------------------------------------------------

  /// Subjects the limits step lists (shell: stable + tracked, else
  /// absence keys) — like `wizard._limit_subjects`.
  List<String> limitSubjectsInput = [];
  List<String> absenceKeys = [];

  List<String> limitSubjects() => limitSubjectsInput.isNotEmpty
      ? List<String>.of(limitSubjectsInput)
      : (List<String>.of(absenceKeys)..sort());

  /// Whether the limits step must trigger the one-time Bakaláři-only
  /// refresh — like `wizard._start_limits_refresh`.
  bool get limitsNeedsRefresh =>
      !limitsRefreshStarted &&
      !refreshRunning &&
      hasCredentials &&
      limitSubjects().isEmpty;

  bool refreshRunning = false;
  String refreshStep = '';
  bool hasCredentials = false;

  /// Android exact-alarm status: show the "exact alarms off" hint and
  /// the allow button when true (shell: available && !allowed).
  bool alarmExactOff = false;

  void markLimitsRefreshStarted() {
    drafts['wiz:limits_refresh'] = '1';
    notifyListeners();
  }

  /// A limit in percent; null when blank. Throws [FormatException]
  /// when invalid — like `wizard._limit_value`.
  static double? limitValue(String raw) {
    final text = raw.trim().replaceAll(',', '.');
    if (text.isEmpty) return null;
    final num = double.parse(text); // throws when invalid
    if (num < 0 || num > 100) throw FormatException(raw);
    return num;
  }

  /// Config updates for the limits step; null when a value is invalid.
  /// A blank subject falls back to the default limit (no own entry).
  Map<String, Object?>? limitsUpdates() {
    try {
      final defaultLimit = limitValue(draft('wiz:limit_default',
          '${config['absence_critical_pct'] ?? 25.0}'));
      final limits = <String, double>{
        for (final e in ((config['subject_limits'] as Map?) ?? const {})
            .entries)
          '${e.key}': (e.value as num).toDouble(),
      };
      for (final subject in limitSubjects()) {
        final value = limitValue(draft('wiz:limit:$subject',
            '${limits[subject] ?? ''}'));
        if (value == null) {
          limits.remove(subject);
        } else {
          limits[subject] = value;
        }
      }
      final updates = <String, Object?>{'subject_limits': limits};
      if (defaultLimit != null) {
        updates['absence_critical_pct'] = defaultLimit;
      }
      return updates;
    } on FormatException {
      return null;
    }
  }

  // -- calendar -------------------------------------------------------------------------------

  /// Selectable school calendars (shipped + user presets, then custom).
  List<CalendarPreset> calendarOptions = [];

  /// The explicitly picked card (`wiz:cal_preset`), or ''.
  String calPreset() {
    final raw = drafts['wiz:cal_preset'];
    if (raw == null) return '';
    if (raw.isNotEmpty &&
        calendarOptions.any((p) => p.id == raw)) {
      return raw;
    }
    return '';
  }

  bool saveCalendar() {
    final preset = calPreset();
    if (preset.isEmpty ||
        !calendarOptions.any((p) => p.id == preset)) {
      return false;
    }
    return _save({'school_preset_id': preset});
  }

  // -- alarm + signature --------------------------------------------------------------------------

  /// Typed minutes (clamped 1–720), null when not a number —
  /// like `wizard._alarm_minutes`.
  int? alarmMinutes() {
    final stored = clampWakeupMinutes(config['wakeup_minutes_before']);
    final raw = draft('wiz:wakeup_minutes', '$stored')
        .trim()
        .replaceAll(',', '.');
    if (double.tryParse(raw) == null) return null;
    return clampWakeupMinutes(raw);
  }

  bool saveAlarm() {
    if (!alarmEnabled) return _save({'wakeup_enabled': false});
    final minutes = alarmMinutes();
    if (minutes == null) return false;
    if (!_save(
        {'wakeup_enabled': true, 'wakeup_minutes_before': minutes})) {
      return false;
    }
    onAlarmPermission();
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

  /// Joined template texts per config key, edited in memory and saved
  /// on Continue (one template per non-empty line).
  final Map<String, String> excuseTemplates = {};

  void setExcuseTemplatesInitial(Map<String, List<String>> initial) {
    excuseTemplates.clear();
    initial.forEach((key, lines) {
      excuseTemplates[key] = lines.join('\n');
    });
  }

  bool saveExcuseTemplates() {
    final updates = <String, Object?>{
      for (final e in excuseTemplates.entries)
        e.key: e.value
            .split('\n')
            .map((l) => l.trimRight())
            .where((l) => l.trim().isNotEmpty)
            .toList(),
    };
    if (updates.isEmpty) return true;
    return _save(updates);
  }

  // -- live tests ----------------------------------------------------------------------------------------

  Map<String, String> overridesFor(String service) {
    switch (service) {
      case 'bakalari':
        final ov = {
          'bakalari_url': draft('wiz:bakalari_url',
                  '${config['bakalari_url'] ?? ''}')
              .trim(),
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
          'strava_canteen_id': draft(
                  'wiz:strava_canteen_id',
                  '${config['strava_canteen_id'] ?? ''}')
              .trim(),
        };
        final pw = draft('wiz:strava_password', '');
        if (pw.trim().isNotEmpty) ov['strava_password'] = pw;
        return ov;
      default:
        final ov = <String, String>{};
        final key = draft('wiz:ai_key', '').trim();
        if (key.isNotEmpty) ov['gemini_api_key'] = key;
        final model = draft('wiz:ai_model',
                '${config['gemini_model'] ?? 'gemini-3.8-flash'}')
            .trim();
        if (model.isNotEmpty) ov['gemini_model'] = model;
        return ov;
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

  bool readyAi() {
    if (!aiEnabled) return true;
    final ov = overridesFor('ai');
    return (ov['gemini_api_key']?.isNotEmpty == true) ||
        '${config['gemini_api_key'] ?? ''}'.isNotEmpty;
  }

  bool _testNeeded(String service) {
    if (service == 'strava' && !stravaEnabled) return false;
    if (service == 'ai' && !aiEnabled) return false;
    return verified[service] != fingerprintFor(service);
  }

  /// Continue handler shared by the tested steps — like
  /// `wizard._continue_test_step`. Returns a message for the shell to
  /// show (null = auto-advanced, no message).
  String? continueTestStep(
      String service, int atStep, bool readyOk, String needKey) {
    if (!readyOk) return s.get(needKey);
    if (verified[service] == fingerprintFor(service)) {
      if (!_saveFor(service)) return s.get('save_failed');
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
        return saveAi();
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
    if (!_saveFor(service)) return s.get('save_failed');
    verified[service] = fp;
    onVerified?.call(service, fp);
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
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  // -- Continue / Back / Skip ------------------------------------------------------------------------------

  /// Result of pressing Continue: `advanced` plus an optional snackbar
  /// message. `finishedMessage` is set when the DONE step completes.
  ({bool advanced, String? snack, String? finishedMessage}) pressNext() {
    final atStep = step.clamp(0, stepDone);
    switch (atStep) {
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
            snack: s.get('save_failed'),
            finishedMessage: null
          );
        }
        final snack = continueTestStep(
            'strava', atStep, readyStrava(), 'wiz_need_strava');
        return (advanced: false, snack: snack, finishedMessage: null);
      case stepAi:
        if (!aiEnabled) {
          if (saveAi()) {
            goTo(stepAfter(atStep));
            return (
              advanced: true,
              snack: null,
              finishedMessage: null
            );
          }
          return (
            advanced: false,
            snack: s.get('save_failed'),
            finishedMessage: null
          );
        }
        final snack = continueTestStep(
            'ai', atStep, readyAi(), 'wiz_need_ai_key');
        return (advanced: false, snack: snack, finishedMessage: null);
      case stepLimits:
        final updates = limitsUpdates();
        if (updates == null || !_save(updates)) {
          return (
            advanced: false,
            snack: s.get(updates == null
                ? 'wiz_limits_invalid'
                : 'save_failed'),
            finishedMessage: null
          );
        }
        break;
      case stepDisclaimer:
        if (!disclaimerOk) {
          return (
            advanced: false,
            snack: s.get('wiz_disclaimer_need'),
            finishedMessage: null
          );
        }
        if (config['disclaimer_accepted'] != true) {
          _save({'disclaimer_accepted': true});
        }
        break;
      case stepCalendar:
        if (!saveCalendar()) {
          return (
            advanced: false,
            snack: s.get(calPreset().isEmpty
                ? 'wiz_cal_pick'
                : 'save_failed'),
            finishedMessage: null
          );
        }
        break;
      case stepAlarm:
        if (!saveAlarm()) {
          return (
            advanced: false,
            snack: s.get(alarmMinutes() == null
                ? 'wakeup_minutes_invalid'
                : 'save_failed'),
            finishedMessage: null
          );
        }
        break;
      case stepExcuses:
        if (!saveSignature()) {
          return (
            advanced: false,
            snack: s.get(signature().isEmpty
                ? 'wiz_need_signature'
                : 'save_failed'),
            finishedMessage: null
          );
        }
        saveExcuseTemplates();
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
        finishedMessage: s.get(started
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
      stepAi: 'ai',
    };
    final service = tested[step];
    if (service != null && _testNeeded(service)) {
      return s.get('wiz_test_continue');
    }
    return s.get('wiz_next');
  }

  /// Whether Skip is offered on this step (welcome has nothing to
  /// skip; the disclaimer must be accepted).
  bool get canSkip =>
      step != stepWelcome &&
      step != stepDisclaimer &&
      step < stepDone;

  /// Whether Continue is enabled (calendar needs a pick, disclaimer
  /// an ack, and no advance while a test or the limits load runs).
  bool get nextEnabled {
    if (step == stepCalendar && calPreset().isEmpty) return false;
    if (step == stepDisclaimer && !disclaimerOk) return false;
    if (testing != null) return false;
    if (step == stepLimits && refreshRunning) return false;
    return true;
  }

  bool _save(Map<String, Object?> updates) {
    final ok = onSave(updates);
    if (ok) config.addAll(updates);
    return ok;
  }
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
