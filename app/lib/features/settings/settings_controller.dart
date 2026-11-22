import 'dart:async';

import 'package:strakalari_core/strakalari_core.dart' as core;

/// Lightweight account row model displayed by Settings → Účty (F4).
class SettingsAccountItem {
  final String id;
  final String label;
  final String username;
  final String presetId;
  final bool isActive;
  final bool isPrimary;
  final bool backgroundRefresh;
  final bool showBackupNoteOnDelete;

  const SettingsAccountItem({
    required this.id,
    required this.label,
    this.username = '',
    this.presetId = '',
    this.isActive = false,
    this.isPrimary = false,
    this.backgroundRefresh = true,
    this.showBackupNoteOnDelete = false,
  });
}

/// Settings state. Port of the settings-related AppState surface used by
/// views/settings/*: navigation, drafts, quiet saves, calendar ops,
/// automation rules, autostart handling and credential gating.
///
/// Plain-Dart controller; persistence/confirm dialogs/OS calls are
/// injectable so widget tests use fakes and never touch disk or servers.
class SettingsController {
  final Map<String, dynamic> config;
  final List<void Function()> _listeners = [];
  final List<void Function()> _configListeners = [];
  final Map<String, String> drafts = {};

  /// Persist [updates] into [config]. False/throw = save failed.
  /// Null = write into [config] directly (tests).
  final bool Function(Map<String, dynamic> updates)? persist;
  final bool Function(Map<String, dynamic> updates)? persistQuiet;

  /// Optional delegation hooks for shared [AppState] backing.
  final void Function(String key, String value)? onDraftChanged;
  final void Function(String prefix)? onClearDrafts;
  final void Function(String section)? onSetSection;
  final void Function()? onCloseSection;
  final bool Function(String service, Map<String, Object?> overrides)?
      onTestConnection;
  final bool Function()? onClearCache;
  final bool Function(String channel)? onSetUpdateChannel;
  final List<String> Function()? validateConfig;

  /// Confirm switching a mode to auto. Return 'confirm' | 'dry_run' |
  /// 'cancel' (mirrors safety.confirm_auto_mode callbacks).
  final FutureOr<String> Function(String key)? confirmAutoMode;

  /// OS autostart hooks: (isEnabled, setAutostart). Null = unavailable.
  final bool Function()? autostartEnabled;
  final bool Function(bool wanted)? setAutostart;
  final bool storeManaged;

  /// Phone-only flags.
  final bool isAndroid;
  final bool isIos;
  final bool wakeupAvailable;

  /// Phone-side facts and actions the wake-up card needs (Android only).
  WakeupPhone? wakeupPhone;

  /// What the background notification's preview is built from (Android
  /// only; `AppState.backgroundStatusInputs`).
  core.StatusInputs Function()? backgroundStatusInputs;

  String settingsSection = 'accounts';
  bool settingsOpen = false;
  String testing = '';
  Map<String, dynamic> lastTest = {};
  String updateChannel = 'stable';

  // -- multi-account metadata & callbacks (F4) ------------------------------
  bool accountsEnabled = false;
  bool migrationDegraded = false;
  List<SettingsAccountItem> accounts = const [];
  String? activeAccountId;
  String activeAccountLabel = '';
  String? primaryAccountId;
  String primaryAccountLabel = '';

  bool get isMultiAccount => accountsEnabled && accounts.length > 1;

  /// Number of accounts participating in background refresh (at least 1).
  int get backgroundRefreshAccountCount {
    if (!accountsEnabled || accounts.isEmpty) return 1;
    final n = accounts.where((a) => a.backgroundRefresh).length;
    return n < 1 ? 1 : n;
  }

  Future<bool> Function(String accountId)? onSwitchAccount;
  Future<bool> Function()? onBeginAddAccount;
  bool Function(String accountId, String newLabel)? onRenameAccount;
  Future<bool> Function(String accountId)? onSetPrimaryAccount;
  Future<bool> Function(String accountId)? onDeleteAccount;
  Future<bool> Function(String accountId, bool enabled)?
      onSetAccountBackgroundRefresh;

  /// Returns conflicting account's display label if another account already
  /// uses this Bakaláři or Strava login (§10.2, §10.3).
  String? Function(String url, String username)? checkDuplicateBakalari;
  String? Function(String canteenId, String username)? checkDuplicateStrava;

  /// Checks whether saving [newValue] into [configKey] would duplicate another
  /// account's Bakaláři or Strava login. Returns conflicting label or `null`.
  String? duplicateLoginLabelForEdit(String configKey, String newValue) {
    if (configKey == 'bakalari_url' || configKey == 'bakalari_username') {
      if (checkDuplicateBakalari == null) return null;
      final url = configKey == 'bakalari_url'
          ? newValue
          : draft('acc:bakalari_url', '${get('bakalari_url', '')}');
      final user = configKey == 'bakalari_username'
          ? newValue
          : draft('acc:bakalari_username', '${get('bakalari_username', '')}');
      return checkDuplicateBakalari!(url, user);
    }
    if (configKey == 'strava_canteen_id' || configKey == 'strava_username') {
      if (checkDuplicateStrava == null) return null;
      final cid = configKey == 'strava_canteen_id'
          ? newValue
          : draft('acc:strava_canteen_id', '${get('strava_canteen_id', '')}');
      final user = configKey == 'strava_username'
          ? newValue
          : draft('acc:strava_username', '${get('strava_username', '')}');
      return checkDuplicateStrava!(cid, user);
    }
    return null;
  }

  SettingsController(
    this.config, {
    this.persist,
    this.persistQuiet,
    this.onDraftChanged,
    this.onClearDrafts,
    this.onSetSection,
    this.onCloseSection,
    this.onTestConnection,
    this.onClearCache,
    this.onSetUpdateChannel,
    this.validateConfig,
    this.confirmAutoMode,
    this.autostartEnabled,
    this.setAutostart,
    this.storeManaged = false,
    this.isAndroid = false,
    this.isIos = false,
    this.wakeupAvailable = false,
  });

  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);
  void addConfigListener(void Function() fn) => _configListeners.add(fn);

  void _emit() {
    for (final fn in List.of(_listeners)) {
      fn();
    }
  }

  void _emitConfig() {
    for (final fn in List.of(_configListeners)) {
      fn();
    }
  }

  dynamic get(String key, [dynamic fallback]) =>
      config.containsKey(key) ? config[key] : fallback;

  // -- saves ---------------------------------------------------------------------
  /// Full save: updates memory, persists, notifies config listeners,
  /// re-renders. Returns false when persistence failed.
  bool save(Map<String, dynamic> updates) {
    config.addAll(updates);
    try {
      if (persist != null && persist!(updates) == false) return false;
    } catch (exc) {
      // ignore: avoid_print
      print('Warning: could not save settings: $exc');
      return false;
    }
    _emitConfig();
    _emit();
    return true;
  }

  /// Quiet save: updates memory, persists and notifies config listeners,
  /// but does NOT re-render (mirrors `save_quiet`: no lost clicks/focus
  /// on blur-saves).
  bool saveQuiet(Map<String, dynamic> updates) {
    config.addAll(updates);
    try {
      final writer = persistQuiet ?? persist;
      if (writer != null && writer(updates) == false) return false;
    } catch (exc) {
      // ignore: avoid_print
      print('Warning: could not save settings: $exc');
      return false;
    }
    _emitConfig();
    return true;
  }

  // -- drafts ----------------------------------------------------------------------
  String draft(String key, [String fallback = '']) =>
      drafts.containsKey(key) ? drafts[key]! : fallback;

  void setDraft(String key, String value) {
    drafts[key] = value;
    onDraftChanged?.call(key, value);
  }

  void clearDrafts(String prefix) {
    drafts.removeWhere((k, _) => k.startsWith(prefix));
    onClearDrafts?.call(prefix);
  }

  bool testConnection(String service, [Map<String, Object?> overrides = const {}]) {
    if (onTestConnection != null) return onTestConnection!(service, overrides);
    testing = service;
    _emit();
    return true;
  }

  bool clearCache() {
    if (onClearCache != null) return onClearCache!();
    return true;
  }

  bool changeUpdateChannel(String channel) {
    updateChannel = channel;
    if (onSetUpdateChannel != null) return onSetUpdateChannel!(channel);
    _emit();
    return true;
  }

  // -- navigation -------------------------------------------------------------------
  static const List<(String, String)> sections = [
    ('accounts', 'sec_accounts'),
    ('limits', 'sec_limits'),
    ('calendar', 'sec_calendar'),
    ('alarm', 'sec_alarm'),
    ('templates', 'sec_templates'),
    ('rules', 'sec_rules'),
    ('browser', 'sec_browser'),
    ('appearance', 'sec_appearance'),
    ('ai', 'sec_ai'),
    ('advanced', 'sec_advanced'),
    ('notifications', 'sec_notifications'),
    ('diagnostics', 'sec_diagnostics'),
  ];

  static const List<(String, List<String>)> navGroups = [
    ('sec_group_school', ['accounts', 'limits', 'calendar', 'alarm']),
    ('sec_group_automation', ['rules', 'templates', 'ai', 'browser']),
    ('sec_group_app', ['appearance', 'notifications']),
    ('sec_group_advanced', ['advanced', 'diagnostics']),
  ];

  static const Map<String, String> sectionIcons = {
    'accounts': 'person',
    'limits': 'percent',
    'calendar': 'calendar',
    'alarm': 'alarm',
    'templates': 'description',
    'rules': 'bolt',
    'browser': 'sync',
    'appearance': 'palette',
    'ai': 'auto_awesome',
    'advanced': 'tune',
    'notifications': 'notifications',
    'diagnostics': 'bug',
  };

  /// Sections visible on this platform (iOS hides browser/notifications,
  /// non-Android hides the alarm section).
  List<(String, String)> sectionsHere({String platform = ''}) {
    var ids = sections.map((s) => s.$1).toSet();
    if (platform == 'ios') {
      ids.removeAll({'browser', 'notifications'});
    }
    if (platform != 'android') {
      ids.remove('alarm');
    }
    return [for (final s in sections) if (ids.contains(s.$1)) s];
  }

  void setSettingsSection(String section) {
    settingsSection = section;
    settingsOpen = true;
    for (final k in ['acc:bakalari_password', 'acc:strava_password', 'ai:key']) {
      drafts.remove(k);
    }
    onSetSection?.call(section);
    _emit();
  }

  void closeSettingsSection() {
    settingsOpen = false;
    for (final k in ['acc:bakalari_password', 'acc:strava_password', 'ai:key']) {
      drafts.remove(k);
    }
    onCloseSection?.call();
    _emit();
  }

  // -- quiet-save helpers (port of settings/common.py) ------------------------------
  /// True when a stored config value already equals the new one.
  static bool sameValue(Object? a, Object? b) {
    if (a == b) return true;
    if (a is String && b is String) {
      // Text stays text: '0123' is not '123'.
      return false;
    }
    try {
      return double.parse('$a') == double.parse('$b');
    } catch (_) {
      final sa = a == null ? '' : '$a';
      final sb = b == null ? '' : '$b';
      return sa == sb;
    }
  }

  // -- automation rules ----------------------------------------------------------------
  bool automationPaused() => get('automation_paused', false) == true;

  bool setAutomationPaused(bool paused) {
    return save({'automation_paused': paused});
  }

  /// Mode picker commit. Switching to `auto` needs explicit confirmation;
  /// other modes save without asking (port of `_commit_guarded`).
  /// Returns 'saved' | 'unchanged' | 'cancelled'.
  Future<String> commitMode(String key, String value, String fallback) async {
    try {
      return await _commitMode(key, value, fallback);
    } finally {
      // Every answer rebuilds the picker from the saved value, so a
      // cancelled switch to auto shows the old mode again (python
      // `_set(previous)`).
      modeRevision++;
    }
  }

  /// Bumped by every [commitMode]; keys the mode pickers.
  int modeRevision = 0;

  Future<String> _commitMode(String key, String value, String fallback) async {
    value = value.isEmpty ? fallback : value;
    final previous = '${get(key, fallback) ?? fallback}';
    if (value != 'auto' || previous == 'auto') {
      saveQuiet({key: value});
      return 'saved';
    }
    final answer = await (confirmAutoMode?.call(key) ?? 'cancel');
    if (answer == 'confirm') {
      saveQuiet({key: 'auto'});
      return 'saved';
    }
    if (answer == 'dry_run') {
      saveQuiet({key: 'dry_run'});
      return 'saved';
    }
    return 'cancelled';
  }

  /// `0` → 1 clamp and parse for the check-interval field
  /// (port of the `rule:interval` handler: 0→1, '2,7'→2).
  int clampInterval(String raw) {
    try {
      return (double.parse(raw.replaceAll(',', '.'))).toInt().clamp(1, 1 << 30);
    } catch (_) {
      return 1;
    }
  }

  bool commitInterval(String raw) {
    return saveQuiet({'check_interval_minutes': clampInterval(raw)});
  }

  static final _cutoffRe = RegExp(r'^([01]\d|2[0-3]):[0-5]\d$');

  static bool isValidCutoff(String raw) =>
      _cutoffRe.hasMatch(raw.trim());

  /// Empty = inherit preset; otherwise must be HH:MM.
  bool commitCutoff(String raw) {
    final cleaned = raw.trim();
    if (cleaned.isNotEmpty && !isValidCutoff(cleaned)) return false;
    return saveQuiet({'lunch_order_cutoff_time': cleaned});
  }

  // -- autostart ------------------------------------------------------------------
  /// Toggles autostart; on failure the switch must NOT claim the new
  /// state (returns false, caller reverts the switch).
  bool toggleAutostart(bool wanted) {
    if (setAutostart == null) return false;
    try {
      return setAutostart!(wanted);
    } catch (_) {
      return false;
    }
  }

  bool readAutostart() {
    if (storeManaged) return false;
    try {
      return autostartEnabled?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  // -- school calendar ---------------------------------------------------------------
  DateTime? parseCzDate(String raw) {
    final m =
        RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(raw.trim());
    if (m == null) return null;
    try {
      final d = DateTime(int.parse(m.group(3)!),
          int.parse(m.group(2)!), int.parse(m.group(1)!));
      if (d.day != int.parse(m.group(1)!) ||
          d.month != int.parse(m.group(2)!)) {
        return null;
      }
      return d;
    } catch (_) {
      return null;
    }
  }

  List<Map<String, String>> userFreeDays() {
    final out = <Map<String, String>>[];
    final raw = get('user_free_days', []);
    if (raw is List) {
      for (final e in raw) {
        if (e is Map) {
          out.add({
            'date': '${e['date'] ?? ''}',
            'label': '${e['label'] ?? ''}',
          });
        } else if ('$e'.isNotEmpty) {
          out.add({'date': '$e', 'label': ''});
        }
      }
    }
    return out;
  }

  /// Adds a single free day from drafts (`cal:add_date`, `cal:add_label`).
  /// Invalid dates save nothing. Returns true when stored.
  bool addSingleDay() {
    final day = parseCzDate(draft('cal:add_date', ''));
    if (day == null) return false;
    final label = draft('cal:add_label', '').trim();
    final days = userFreeDays();
    final key =
        '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}.${day.year}';
    if (days.any((d) => d['date'] == key)) return true; // duplicate
    days.add({'date': key, 'label': label});
    if (!save({'user_free_days': _packDays(days)})) return false;
    clearDrafts('cal:add_');
    return true;
  }

  /// Adds a date range from drafts. Reversed/invalid ranges save nothing.
  bool addDayRange() {
    final start = parseCzDate(draft('cal:from_', ''));
    final end = parseCzDate(draft('cal:to', ''));
    if (start == null || end == null || end.isBefore(start)) return false;
    final label = draft('cal:range_label', '').trim();
    final days = userFreeDays();
    var added = 0;
    for (var d = start; !d.isAfter(end); d = core.addDays(d, 1)) {
      final key =
          '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
      if (days.any((x) => x['date'] == key)) continue;
      days.add({'date': key, 'label': label});
      added++;
    }
    if (added == 0) return true;
    if (!save({'user_free_days': _packDays(days)})) return false;
    clearDrafts('cal:from_');
    clearDrafts('cal:to');
    clearDrafts('cal:range_label');
    return true;
  }

  bool deleteFreeDay(String dateKey) {
    final days = userFreeDays()
        .where((d) => d['date'] != dateKey)
        .toList();
    return save({'user_free_days': _packDays(days)});
  }

  List<dynamic> _packDays(List<Map<String, String>> days) {
    days.sort((a, b) => '${a['date']}'.compareTo('${b['date']}'));
    return [
      for (final d in days)
        if ((d['label'] ?? '').isNotEmpty) d else d['date']!,
    ];
  }

  /// Closure field commit: invalid dates are not saved.
  bool commitClosure(String key, String raw) {
    final cleaned = raw.trim();
    if (cleaned.isNotEmpty && parseCzDate(cleaned) == null) return false;
    return saveQuiet({key: cleaned});
  }

  // -- template editor -----------------------------------------------------------------
  /// Normalizes and persists a template list if changed, preserving structured
  /// `{name, text}` maps and plain strings alike.
  static bool commitTemplatesList({
    required Object? current,
    required List<Map<String, String>> values,
    required bool Function(List<Object?> cleaned) saveCleaned,
  }) {
    final cleaned = <Object?>[];
    for (final v in values) {
      final text = (v['text'] ?? '').trim();
      if (text.isEmpty) continue;
      final name = (v['name'] ?? '').trim();
      cleaned.add(name.isNotEmpty
          ? {'name': name, 'text': v['text']}
          : v['text']);
    }
    if (_deepEquals(cleaned, current)) return true; // nothing to save
    return saveCleaned(cleaned);
  }

  /// Commits one template-list edit (port of `_tpl_editor._commit`).
  bool commitTemplates(String key, List<Map<String, String>> values) =>
      commitTemplatesList(
        current: get(key, []),
        values: values,
        saveCleaned: (cleaned) => saveQuiet({key: cleaned}),
      );

  static bool _deepEquals(Object? a, Object? b) {
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k) || !_deepEquals(a[k], b[k])) return false;
      }
      return true;
    }
    return a == b;
  }

  // -- credential gating (settings half of test_wizard_setup) ----------------------------
  bool hasBakalariCredentials() {
    return '${get('bakalari_url', '')}'.isNotEmpty &&
        '${get('bakalari_username', '')}'.isNotEmpty &&
        '${get('bakalari_password', '')}'.isNotEmpty;
  }

  bool hasStravaCredentials() {
    return '${get('strava_username', '')}'.isNotEmpty &&
        '${get('strava_password', '')}'.isNotEmpty &&
        '${get('strava_canteen_id', '')}'.isNotEmpty;
  }

  bool hasAnyCredentials() =>
      hasBakalariCredentials() || hasStravaCredentials();

  bool needsSetup() => !hasAnyCredentials();

  bool stravaEnabledFlag() => get('use_strava', true) == true;
}


/// What the wake-up card asks the phone (port of the `android` calls and the
/// `AppState` alarm queries used by `automation.py::_wakeup`). The live
/// screen wires it to the platform channel; tests pass fakes.
class WakeupPhone {
  bool notificationsEnabled;
  bool exactAlarmsAllowed;
  final core.WakeupAlarm? Function() nextAlarm;
  final List<(DateTime, core.WakeupAlarm?)> Function() skippedDays;
  final Future<bool> Function(int hour, int minute, String message,
      {int? weekday}) openSystemAlarm;
  final void Function() requestNotificationPermission;
  final void Function() openNotificationSettings;
  final void Function() openExactAlarmSettings;

  WakeupPhone({
    this.notificationsEnabled = true,
    this.exactAlarmsAllowed = true,
    required this.nextAlarm,
    required this.skippedDays,
    required this.openSystemAlarm,
    required this.requestNotificationPermission,
    required this.openNotificationSettings,
    required this.openExactAlarmSettings,
  });
}
