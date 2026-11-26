// Configuration: canonical keys, validation, load/save with merge.
// Port of strakalari/core/config.py. File names and JSON shapes stay
// identical so an update installs over the Python app with no migration.
//
// `looksLikePlaceholder` and `isDemoHistoryItem` are public (Python keeps
// them private, but strava_client/automation import them across modules).
// Cutoff/bands checks delegate to the canonical phase-3 ports
// (lunch_cutoff, grades); the channel follows update.defaultChannel and
// the status items are status_notification.items — like config.py's lazy
// imports from those modules.
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../lunches/lunch_cutoff.dart' as lunch_cutoff;
import '../morning_brief.dart' as morning_brief;
import '../planning/grades.dart' as grades;
import '../status_notification.dart' as status_notification;
import '../update.dart' as update;
import 'accounts.dart';
import 'helpers.dart';

/// Allowed values for `excuse_mode` / `strava_order_mode`.
const List<String> excuseModes = ['auto', 'confirm'];

/// Items the background notification may show (canonical:
/// status_notification.items).
const List<String> statusNotificationItems = status_notification.items;

/// Canonical config schema (single names only — no aliases, no migration).
const Map<String, Object> canonicalDefaults = {
  'bakalari_url': '',
  'bakalari_username': '',
  'bakalari_password': '',
  'bakalari_password_encrypted': false,
  'strava_url': 'https://strava.cz',
  'strava_canteen_id': '',
  'strava_username': '',
  'strava_password': '',
  'strava_password_encrypted': false,
  'use_strava': true,
  'log_file': './log.txt',
  'strava_blacklist': './strava_blacklist.json',
  'already_excused_file': './already_excused_lessons.json',
  'theme': 'dark',
  'absence_warn_pct': 15.0,
  'absence_critical_pct': 25.0,
  'absence_plan_reserve_pct': 10.0,
  'cache_ttl_hours': 24,
  'page_load_timeout_s': 60.0,
  'gemini_model': 'gemini-3.8-flash',
  'gemini_api_key': '',
  'gemini_api_key_encrypted': false,
  'gemini_auto_enabled': false,
  'gemini_prompt': '',
  'gemini_interval_days': 2,
  'gemini_last_run': '',
  'late_income_excuses': [
    {
      'name': 'Dopravní komplikace',
      'text': 'Dobrý den, omluvte prosím pozdní příchod z důvodu '
          'dopravních komplikací.\nDěkuji\n'
    },
    {
      'name': 'Lékař',
      'text': 'Dobrý den, omluvte prosím pozdní příchod z důvodu '
          'návštěvy lékaře.\nDěkuji\n'
    },
  ],
  'left_soon_excuses': [
    {
      'name': 'Rodinné důvody',
      'text': 'Dobrý den, omluvte prosím předčasný odchod z rodinných '
          'důvodů.\nDěkuji\n'
    },
    {
      'name': 'Lékař',
      'text': 'Dobrý den, omluvte prosím předčasný odchod z důvodu '
          'návštěvy lékaře.\nDěkuji\n'
    },
  ],
  'short_absence_excuses': [
    {
      'name': 'Rodinné důvody',
      'text':
          'Dobrý den, omluvte prosím absenci z rodinných důvodů.\nDěkuji\n'
    },
    {
      'name': 'Osobní důvody',
      'text':
          'Dobrý den, omluvte prosím absenci z osobních důvodů.\nDěkuji\n'
    },
  ],
  'long_absence_excuses': [
    {
      'name': 'Nemoc',
      'text': 'Dobrý den, omluvte prosím absenci z důvodu nemoci.\nDěkuji\n'
    },
    {
      'name': 'Rodinné důvody',
      'text':
          'Dobrý den, omluvte prosím absenci z rodinných důvodů.\nDěkuji\n'
    },
  ],
  'your_signature': '',
  'go_back_weeks': 4,
  'go_forward_weeks': 1,
  'excuse_delay_days': 2,
  // 0 = no limit (read the whole outbox period).
  'sent_excuses_limit': 0,
  'minimize_to_tray': true,
  // Phone app: keep refreshing and automating with the app closed
  // (Android foreground service; ignored on desktop and iOS).
  'run_in_background': true,
  // What that service's always-on notification shows (an overview; see
  // core/status_notification.ITEMS). Empty = only "running in the background".
  'background_notification_items': [
    'next_lesson',
    'lunch',
    'excuses',
    'wakeup'
  ],
  'language': 'cs',
  'excuse_mode': 'confirm',
  'default_excuse_selection': 'first',
  'strava_order_mode': 'confirm',
  'strava_auto_cancel_lunches': true,
  // Allergen numbers (1–14) the diner avoids: meals listing one are
  // hidden and never picked automatically (lunches/allergens.dart).
  'strava_allergens': [],
  // Multiple accounts: this account takes part in the scheduled
  // background refresh (per account; the device switch is
  // `run_in_background`).
  'background_refresh': true,
  'automation_paused': false,
  'disclaimer_accepted': false,
  // First-run wizard: the step of an unfinished setup, so it resumes after
  // an app restart (-1 = no setup in progress).
  'wizard_step': -1,
  'lunch_order_cutoff_time': '',
  'subject_limits': {},
  // No school is assumed: the wizard (or Settings) picks a preset.
  'school_preset_id': 'custom',
  'user_free_days': [],
  'forced_school_days': [],
  'sem1_close': '',
  'sem2_close': '',
  'holidays': [],
  'school_year_end': '',
  'check_interval_minutes': 5,
  'check_interval_mobile_minutes': 5,
  'check_interval_off_hours_minutes': 60,
  'refresh_wifi_always_fast': true,
  'notifications': {},
  'planned_skips': [],
  'planner_target_days': 0,
  // Interactive tutorials: global switch + ids of finished/skipped tours.
  'tutorials_enabled': true,
  'tutorials_done': [],
  'ignored_excuses': [],
  // Today: the day card's "Excuse day" sends every lesson as its own
  // excuse (one message each) instead of one whole-day / range excuse.
  'excuse_day_per_lesson': false,
  'timetable_view': 'table',
  'compact_density': false,
  // Marks view: "auto" detects 1–5 vs percent per subject; a per-subject
  // choice ({subject: "grade" | "percent"}) beats the global one.
  'marks_scale': 'auto',
  'marks_subject_scales': {},
  // Top of grades 2–5 in percent (a boundary is the worse grade). Empty =
  // the school preset's table, else the built-in 90/75/50/30.
  'marks_percent_bands': [],
  'marks_sort': 'name',
  // Update notifications: "stable" (full releases only) or "beta"
  // (pre-releases too, whichever is newest). ConfigManager replaces
  // this with the running build's kind (beta build -> "beta").
  'update_channel': 'stable',
  // Phone wake-up alarm before the first lesson (core/wakeup.py); the
  // skip list holds ISO days the user turned it off for.
  'wakeup_enabled': false,
  'wakeup_minutes_before': 60,
  'wakeup_skip_dates': [],
  // Phone morning brief (core/morning_brief.dart): a notification at this
  // time ("HH:MM") on every school day with the rows picked here (the
  // always-on notification's items).
  'morning_brief_enabled': false,
  'morning_brief_time': '06:30',
  'morning_brief_items': ['next_lesson', 'lunch', 'lunch_orders', 'excuses'],
};

Object? _deepCopyJson(Object? value) {
  if (value is Map) {
    return value.map((k, v) => MapEntry('$k', _deepCopyJson(v)));
  }
  if (value is List) {
    return value.map(_deepCopyJson).toList();
  }
  return value;
}

/// A fresh copy of the built-in canonical defaults.
///
/// Deliberately never reads `config.example.json`: its placeholder
/// demo values must not leak into real configs.
Map<String, Object?> defaultConfig() {
  final copy =
      _deepCopyJson(canonicalDefaults) as Map<String, Object?>;
  copy['update_channel'] = defaultUpdateChannel();
  return copy;
}

/// True for template/example values that must not count as configured.
bool looksLikePlaceholder(Object? value) {
  final low = '${value ?? ''}'.toLowerCase();
  return [
    'vas_',
    'vase_',
    'cislo_',
    'vas-bakalari',
    'vas_strava',
    'vase_heslo',
    'example',
    'placeholder',
    'your_',
  ].any(low.contains);
}

/// True for example-template history rows that must not seed real data.
///
/// Drops non-dict rows, rows without `type`/`starting_day`, and rows
/// carrying placeholder text (`VAS_…`, `example`, …). Applied only
/// to the `.example.json` fallback, never to the real history file.
/// (Day-range types carry `ending_day` too, but single-lesson types
/// legitimately do not — so it is not required here.)
bool isDemoHistoryItem(Object? item) {
  if (item is! Map) return true;
  if ('${item['type'] ?? ''}'.isEmpty ||
      '${item['starting_day'] ?? ''}'.isEmpty) {
    return true;
  }
  try {
    return item.values
        .whereType<String>()
        .any(looksLikePlaceholder);
  } on Object {
    return false;
  }
}

/// Checks configured credentials without any GUI dependency.
///
/// Returns `(hasBakalari, hasStrava)`. Used by first-run detection.
(bool, bool) hasValidCredentials(
    Map<String, Object?> cfgData) {
  final bakUser = '${cfgData['bakalari_username'] ?? ''}';
  final bakUrl = '${cfgData['bakalari_url'] ?? ''}';
  final stravaUser =
      '${cfgData['strava_username'] ?? cfgData['strava_user'] ?? ''}';
  final stravaId =
      '${cfgData['strava_canteen_id'] ?? cfgData['strava_id'] ?? ''}';

  final hasBakalari = bakUser.isNotEmpty &&
      bakUrl.isNotEmpty &&
      !looksLikePlaceholder(bakUser) &&
      !looksLikePlaceholder(bakUrl);
  final hasStrava = stravaUser.isNotEmpty &&
      stravaId.isNotEmpty &&
      !looksLikePlaceholder(stravaUser) &&
      !looksLikePlaceholder(stravaId);
  return (hasBakalari, hasStrava);
}

// -- canonical phase-3 checks (delegated, like config.py's lazy imports) ---

/// Follows the running build (beta build -> beta), like
/// update.defaultChannel. The config persists the value on first save.
String defaultUpdateChannel() => update.defaultChannel();

// -- numeric coercions (mirror Python's float()/int() semantics) ------------

double? _toDouble(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  if (value is bool) return value ? 1 : 0;
  return null;
}

/// Python `int(x)`: ints pass, doubles truncate, numeric strings parse
/// (float-like strings fail), bools become 0/1, everything else is null.
int? _toIntStrict(Object? value) {
  if (value is int) return value;
  if (value is double) {
    if (value.isNaN || value.isInfinite) return null;
    return value.truncate();
  }
  if (value is String) return int.tryParse(value.trim());
  if (value is bool) return value ? 1 : 0;
  return null;
}

/// Python `int(float(str(x).replace(',', '.')))`: commas accepted.
int? _toIntViaFloat(Object? value) {
  if (value == null) return null;
  final parsed = _toDouble('$value'.replaceAll(',', '.'));
  if (parsed == null || parsed.isNaN || parsed.isInfinite) return null;
  return parsed.truncate();
}

String _repr(Object? value) =>
    value is String ? "'$value'" : '$value';

bool _isTruthy(Object? value) {
  if (value is bool) return value;
  if (value == null) return false;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is Iterable || value is Map) {
    return (value as dynamic).isNotEmpty as bool;
  }
  return true;
}

/// Returns human-readable config problems (empty = OK).
List<String> validateConfig(Map<String, Object?> data) {
  final problems = <String>[];
  final bakUser = '${data['bakalari_username'] ?? ''}';
  final bakUrl = '${data['bakalari_url'] ?? ''}';
  if ((bakUser.isNotEmpty || bakUrl.isNotEmpty) &&
      !(bakUser.isNotEmpty && bakUrl.isNotEmpty)) {
    problems.add('Bakaláři: username and URL must both be set.');
  }
  if (bakUrl.isNotEmpty &&
      !bakUrl.contains('://') &&
      !bakUrl.contains('.')) {
    problems.add("Bakaláři URL looks invalid: ${_repr(bakUrl)}.");
  }
  final stravaFlag =
      data.containsKey('use_strava') ? data['use_strava'] : true;
  if (_isTruthy(stravaFlag)) {
    // Legacy read-aliases (strava_user / strava_id) count: the runtime
    // (StravaClient, Strakalari) and hasValidCredentials() honor
    // them, so the validator must not reject them.
    final stravaUser =
        '${data['strava_username'] ?? data['strava_user'] ?? ''}';
    final stravaId =
        '${data['strava_canteen_id'] ?? data['strava_id'] ?? ''}';
    if (stravaUser.isEmpty) {
      problems.add('Strava: username is empty (integration enabled).');
    }
    if (stravaId.isEmpty) {
      problems.add('Strava: canteen ID is empty (integration enabled).');
    }
  }
  for (final modeKey in ['excuse_mode', 'strava_order_mode']) {
    final mode = '${data[modeKey] ?? 'confirm'}'.toLowerCase();
    if (!excuseModes.contains(mode)) {
      problems.add(
          "'$modeKey' must be one of ['auto', 'confirm'], "
          'got ${_repr(data[modeKey])}.');
    }
  }
  final autoCancel = data['strava_auto_cancel_lunches'];
  if (autoCancel != null && autoCancel is! bool) {
    problems.add("'strava_auto_cancel_lunches' must be a boolean.");
  }
  final backgroundRefresh = data['background_refresh'];
  if (backgroundRefresh != null && backgroundRefresh is! bool) {
    problems.add("'background_refresh' must be a boolean.");
  }
  if (!lunch_cutoff.isValidCutoffTime(data['lunch_order_cutoff_time'] ?? '')) {
    problems.add(
        "'lunch_order_cutoff_time' must be empty (school preset, else 12:00) "
        "or 'HH:MM' ('HH.MM' accepted too).");
  }
  if (!['table', 'list']
      .contains('${data['timetable_view'] ?? 'table'}')) {
    problems.add(
        "'timetable_view' must be 'table' or 'list', "
        'got ${_repr(data['timetable_view'])}.');
  }
  if (!['auto', 'grade', 'percent']
      .contains('${data['marks_scale'] ?? 'auto'}')) {
    problems.add(
        "'marks_scale' must be 'auto', 'grade' or 'percent', "
        'got ${_repr(data['marks_scale'])}.');
  }
  final subjectScales = data['marks_subject_scales'];
  if (subjectScales is! Map ||
      subjectScales.values.any((v) => v != 'grade' && v != 'percent')) {
    problems.add(
        "'marks_subject_scales' must map subjects to 'grade' or 'percent'.");
  }
  final bands = data['marks_percent_bands'];
  if (bands != null &&
      !(bands is List && bands.isEmpty) &&
      !grades.bandsValid(bands)) {
    problems.add(
        "'marks_percent_bands' must be empty or four decreasing percentages "
        'within (0, 100].');
  }
  if (!['name', 'average', 'recent']
      .contains('${data['marks_sort'] ?? 'name'}')) {
    problems.add(
        "'marks_sort' must be 'name', 'average' or 'recent', "
        'got ${_repr(data['marks_sort'])}.');
  }
  final warn = _toDouble(data['absence_warn_pct'] ?? 15);
  final crit = _toDouble(data['absence_critical_pct'] ?? 25);
  if (warn == null ||
      crit == null ||
      !(warn > 0 && warn < crit && crit <= 100)) {
    problems.add(warn == null || crit == null
        ? 'Absence thresholds must be numbers.'
        : 'Absence thresholds must satisfy 0 < warn < critical <= 100.');
  }
  final reserve = _toDouble(data['absence_plan_reserve_pct'] ?? 10);
  if (reserve == null) {
    problems.add("'absence_plan_reserve_pct' must be a number.");
  } else if (!(reserve >= 0 && reserve < 100)) {
    problems.add("'absence_plan_reserve_pct' must be within [0, 100).");
  }
  final targetDays = _toIntStrict(data['planner_target_days'] ?? 0);
  if (targetDays == null) {
    problems.add("'planner_target_days' must be a whole number.");
  } else if (!(targetDays >= 0 && targetDays <= 200)) {
    problems.add("'planner_target_days' must be within [0, 200].");
  }
  final wizardStep = _toIntStrict(data['wizard_step'] ?? -1);
  if (wizardStep == null || wizardStep < -1) {
    problems.add("'wizard_step' must be a whole number, -1 or more.");
  }
  if (data['tutorials_done'] is! List) {
    problems.add("'tutorials_done' must be a list of tutorial ids.");
  }
  final timeoutVal = _toDouble(data['page_load_timeout_s'] ?? 5.0);
  if (timeoutVal == null) {
    problems.add("'page_load_timeout_s' must be a number.");
  } else if (!(timeoutVal >= 5.0 && timeoutVal <= 180.0)) {
    problems.add(
        "'page_load_timeout_s' must be between 5.0 and 180.0 seconds.");
  }
  if (!['stable', 'beta']
      .contains('${data['update_channel'] ?? 'stable'}'.toLowerCase())) {
    problems.add(
        "'update_channel' must be 'stable' or 'beta', "
        'got ${_repr(data['update_channel'])}.');
  }
  if (!['dark', 'light']
      .contains('${data['theme'] ?? 'dark'}'.toLowerCase())) {
    problems.add("Theme must be 'dark' or 'light'.");
  }
  if (!['cs', 'en']
      .contains('${data['language'] ?? 'cs'}'.toLowerCase())) {
    problems.add(
        "'language' must be 'cs' or 'en', "
        'got ${_repr(data['language'])}.');
  }
  if ('${data['gemini_model'] ?? 'gemini-3.8-flash'}'.trim().isEmpty) {
    problems.add("'gemini_model' must not be empty.");
  }
  final gInterval = _toIntViaFloat(data['gemini_interval_days'] ?? 2);
  if (gInterval == null) {
    problems.add("'gemini_interval_days' must be a whole number.");
  } else if (!(gInterval >= 1 && gInterval <= 30)) {
    problems.add("'gemini_interval_days' must be within [1, 30].");
  }
  final delay = _toIntStrict(data['excuse_delay_days'] ?? 2);
  if (delay == null) {
    problems.add("'excuse_delay_days' must be a whole number.");
  } else if (delay < 0) {
    problems.add("'excuse_delay_days' must be >= 0.");
  }
  final sentLimit = _toIntStrict(data['sent_excuses_limit'] ?? 0);
  if (sentLimit == null) {
    problems.add("'sent_excuses_limit' must be a whole number.");
  } else if (sentLimit < 0) {
    problems.add("'sent_excuses_limit' must be >= 0 (0 = no limit).");
  }
  for (final entry in [
    ('go_back_weeks', 0, 52),
    ('go_forward_weeks', 0, 8),
  ]) {
    final weeks = _toIntStrict(data[entry.$1] ?? 0);
    if (weeks == null) {
      problems.add("'${entry.$1}' must be a whole number.");
    } else if (!(weeks >= entry.$2 && weeks <= entry.$3)) {
      problems.add(
          "'${entry.$1}' must be within [${entry.$2}, ${entry.$3}] "
          '(runtime clamps to it).');
    }
  }
  if (!['first', 'random'].contains(
      '${data['default_excuse_selection'] ?? 'first'}'.toLowerCase())) {
    problems.add(
        "'default_excuse_selection' must be 'first' or 'random', "
        'got ${_repr(data['default_excuse_selection'])}.');
  }
  final interval = _toDouble(data['check_interval_minutes'] ?? 5);
  if (interval == null) {
    problems.add("'check_interval_minutes' must be a number.");
  } else if (interval < 1) {
    problems.add("'check_interval_minutes' must be >= 1.");
  }
  final mobileInterval =
      _toDouble(data['check_interval_mobile_minutes'] ?? 5);
  if (mobileInterval == null) {
    problems.add("'check_interval_mobile_minutes' must be a number.");
  } else if (mobileInterval < 1) {
    problems.add("'check_interval_mobile_minutes' must be >= 1.");
  }
  final offHoursInterval =
      _toDouble(data['check_interval_off_hours_minutes'] ?? 60);
  if (offHoursInterval == null) {
    problems.add("'check_interval_off_hours_minutes' must be a number.");
  } else if (offHoursInterval < 0 ||
      (offHoursInterval > 0 && offHoursInterval < 1)) {
    problems.add(
        "'check_interval_off_hours_minutes' must be 0 (paused) or >= 1.");
  }
  final wifiAlwaysFast = data['refresh_wifi_always_fast'];
  if (wifiAlwaysFast != null && wifiAlwaysFast is! bool) {
    problems.add("'refresh_wifi_always_fast' must be a boolean.");
  }
  final wakeupMin = _toIntViaFloat(data['wakeup_minutes_before'] ?? 60);
  if (wakeupMin == null) {
    problems.add("'wakeup_minutes_before' must be a whole number.");
  } else if (!(wakeupMin >= 1 && wakeupMin <= 720)) {
    problems.add("'wakeup_minutes_before' must be within [1, 720].");
  }
  if (data['wakeup_skip_dates'] is! List) {
    problems.add("'wakeup_skip_dates' must be a list of dates (YYYY-MM-DD).");
  }
  final picked = data['background_notification_items'];
  if (picked is! List ||
      picked.any((item) => !statusNotificationItems.contains(item))) {
    problems.add(
        "'background_notification_items' must be a list of "
        '$statusNotificationItems.');
  }
  final briefOn = data['morning_brief_enabled'];
  if (briefOn != null && briefOn is! bool) {
    problems.add("'morning_brief_enabled' must be a boolean.");
  }
  final briefTime = data['morning_brief_time'];
  if (briefTime != null && morning_brief.parseBriefTime(briefTime) == null) {
    problems.add("'morning_brief_time' must be a time of day (HH:MM).");
  }
  final briefItems = data['morning_brief_items'];
  if (briefItems != null &&
      (briefItems is! List ||
          briefItems.any((item) => !statusNotificationItems.contains(item)))) {
    problems.add(
        "'morning_brief_items' must be a list of $statusNotificationItems.");
  }
  final limits = data['subject_limits'];
  if (limits is! Map) {
    problems.add(
        "'subject_limits' must be an object mapping subject -> percent.");
  } else {
    for (final entry in limits.entries) {
      final value = _toDouble(entry.value);
      if (value == null) {
        problems.add(
            "Subject limit for ${_repr(entry.key)} must be a number.");
        break;
      }
      if (!(value > 0 && value <= 100)) {
        problems.add(
            "Subject limit for ${_repr(entry.key)} must be within (0, 100].");
        break;
      }
    }
  }
  return problems;
}

/// Manages loading, saving, and updating Strakalari configuration settings.
/// Handles password obfuscation, defaults fallback, and path resolution.
class ConfigManager {
  /// Resolved absolute config path.
  final String configPath;

  /// Resolved path to shared `global.json` in multi-account mode, else null.
  final String? globalPath;

  /// Account folder for per-account relative paths and keys, else null.
  final String? baseDir;

  /// Root data folder for shared `gemini_api_key` encryption and fallback, else null.
  final String? rootDir;

  /// File encoding (JSON is always written as UTF-8-compatible text).
  final Encoding encoding;

  /// Current (possibly edited) configuration.
  Map<String, Object?> data = {};

  Map<String, Object?> _baseline = {};
  Set<String> _touched = {};
  bool _unreadable = false;
  bool _globalUnreadable = false;
  bool _deleted = false;

  /// Marks this manager's account as deleted so late saves fail loudly (§9).
  void markDeleted() {
    _deleted = true;
  }

  /// True when this manager belongs to an account whose folder was deleted.
  bool get isDeleted =>
      _deleted || (baseDir != null && isAccountDirDeleted(baseDir));

  /// Test seam (simulates disk / lock failures in unit tests). Skips the
  /// lock and the "unreadable at start" guard, so production code never sets it.
  @visibleForTesting
  void Function()? saveOverride;

  /// Test seam to fail only the per-account file write during split save.
  @visibleForTesting
  void Function()? accountWriteOverride;

  factory ConfigManager([String configPath = './config.json',
      Encoding encoding = utf8]) =>
      ConfigManager.scoped(configPath, encoding: encoding);

  factory ConfigManager.scoped(
    String configPath, {
    Encoding encoding = utf8,
    String? globalPath,
    String? baseDir,
    String? rootDir,
  }) {
    final resolvedConfig = baseDir != null
        ? resolvePath(configPath, baseDir)
        : resolvePath(configPath);
    guardAccountsModeConfigPath(resolvedConfig);
    final resolvedGlobal =
        globalPath != null ? resolvePath(globalPath, rootDir) : null;
    final manager = ConfigManager._(
      resolvedConfig,
      encoding,
      globalPath: resolvedGlobal,
      baseDir: baseDir,
      rootDir: rootDir,
    );
    manager.load();
    return manager;
  }

  /// Opens the multi-account config for [accountId] under [rootDir].
  factory ConfigManager.forAccount(
    String rootDir,
    String accountId, {
    Encoding encoding = utf8,
  }) {
    final accDir = accountDirFor(rootDir, accountId);
    return ConfigManager.scoped(
      p.join(accDir, 'config.json'),
      encoding: encoding,
      globalPath: p.join(rootDir, globalConfigFile),
      baseDir: accDir,
      rootDir: rootDir,
    );
  }

  ConfigManager._(
    this.configPath,
    this.encoding, {
    this.globalPath,
    this.baseDir,
    this.rootDir,
  });

  /// Loads configuration from the JSON file and merges on top of defaults.
  Map<String, Object?> load() {
    _loadInner();
    _rememberBaseline();
    _retireDryRunMode();
    return data;
  }

  /// The dry-run mode is gone: a mode still stored as `dry_run` reads as
  /// `confirm` (what it already behaved as) and is written so with the
  /// next save.
  void _retireDryRunMode() {
    for (final key in const ['excuse_mode', 'strava_order_mode']) {
      if ('${data[key]}'.trim().toLowerCase() == 'dry_run') {
        data[key] = 'confirm';
        _touched.add(key);
      }
    }
  }

  void _rememberBaseline() {
    _baseline =
        (_deepCopyJson(data) as Map<String, Object?>);
    _touched = {};
  }

  /// Snapshot of what is on disk, so save() writes only real edits.
  void _loadInner() {
    final defaults = defaultConfig();
    if (globalPath != null) {
      _loadMultiAccount(defaults);
      return;
    }
    if (!File(configPath).existsSync()) {
      data = defaults;
      _unreadable = false;
      return;
    }
    try {
      final loaded = jsonDecode(
          File(configPath).readAsStringSync(encoding: encoding));
      if (loaded is Map) {
        // Explicit nulls never override defaults: a hand-edited
        // `"key": null` falls back to the canonical default
        // instead of poisoning the runtime with null.
        for (final entry in loaded.entries) {
          if (entry.value != null) {
            defaults['${entry.key}'] = entry.value as Object?;
          }
        }
      } else {
        print("Warning: Config '$configPath' does not contain a JSON "
            'object. Using fallback defaults.');
      }
      data = defaults;
    } on FormatException catch (e) {
      // Quarantine the corrupt file BEFORE falling back: a later
      // save() would otherwise atomically overwrite the original
      // bytes and destroy credentials/config for good.
      final backup = quarantineCorruptFile(configPath);
      final hint = backup.isNotEmpty ? ' Preserved at $backup.' : '';
      print("Warning: Failed to load '$configPath': $e. "
          'Using fallback defaults.$hint');
      data = defaults;
    } on FileSystemException catch (e) {
      // Busy or locked (antivirus, the other process mid-write), not
      // corrupt: keep the file untouched and refuse to save over it
      // until a later load succeeds.
      print("Warning: Could not read '$configPath' right now: $e. "
          'Using defaults, not saving.');
      data = defaults;
      _unreadable = true;
      return;
    }
    _unreadable = false;
    // No stored-data migration: the project is pre-release with a single
    // user, so legacy keys are simply ignored (defaults win). Unknown
    // keys stay on disk untouched but are never read.
  }

  /// Multi-account precedence (§3.4): canonical defaults -> per-account keys
  /// from `<accountDir>/config.json` -> shared keys from `<rootDir>/global.json`.
  /// Shared keys are NEVER read from the account file, even if a migrated copy
  /// still holds them.
  void _loadMultiAccount(Map<String, Object?> defaults) {
    // 1. Account file (per-account keys only).
    if (!File(configPath).existsSync()) {
      _unreadable = false;
    } else {
      try {
        final loaded = jsonDecode(
            File(configPath).readAsStringSync(encoding: encoding));
        if (loaded is Map) {
          for (final entry in loaded.entries) {
            final k = '${entry.key}';
            if (globalConfigKeys.contains(k)) continue;
            if (entry.value != null) {
              defaults[k] = entry.value as Object?;
            }
          }
        } else {
          print("Warning: Config '$configPath' does not contain a JSON "
              'object. Using fallback defaults.');
        }
        _unreadable = false;
      } on FormatException catch (e) {
        final backup = quarantineCorruptFile(configPath);
        final hint = backup.isNotEmpty ? ' Preserved at $backup.' : '';
        print("Warning: Failed to load '$configPath': $e. "
            'Using fallback defaults.$hint');
        _unreadable = false;
      } on FileSystemException catch (e) {
        print("Warning: Could not read '$configPath' right now: $e. "
            'Using defaults, not saving.');
        _unreadable = true;
      }
    }

    // 2. Global file (shared keys only).
    final gPath = globalPath!;
    if (!File(gPath).existsSync()) {
      _globalUnreadable = false;
    } else {
      try {
        final loaded =
            jsonDecode(File(gPath).readAsStringSync(encoding: encoding));
        if (loaded is Map) {
          for (final entry in loaded.entries) {
            final k = '${entry.key}';
            if (!globalConfigKeys.contains(k)) continue;
            if (entry.value != null) {
              defaults[k] = entry.value as Object?;
            }
          }
        } else {
          print("Warning: Global config '$gPath' does not contain a JSON "
              'object. Using fallback defaults.');
        }
        _globalUnreadable = false;
      } on FormatException catch (e) {
        final backup = quarantineCorruptFile(gPath);
        final hint = backup.isNotEmpty ? ' Preserved at $backup.' : '';
        print("Warning: Failed to load '$gPath': $e. "
            'Using fallback defaults.$hint');
        _globalUnreadable = false;
      } on FileSystemException catch (e) {
        print("Warning: Could not read '$gPath' right now: $e. "
            'Using defaults, not saving.');
        _globalUnreadable = true;
      }
    }

    data = defaults;
  }

  /// Reloads configuration from disk.
  Map<String, Object?> reload() => load();

  /// Saves current configuration to the JSON file (atomically).
  ///
  /// Refuses when the file existed but could not be read at load time —
  /// writing then would replace the user's settings with defaults.
  void save() {
    if (saveOverride != null) {
      saveOverride!();
      return;
    }
    if (isDeleted) {
      throw StateError(
          "Account folder for '$configPath' was deleted; refusing to save.");
    }
    if (globalPath != null) {
      _saveMultiAccount();
      return;
    }
    if (_unreadable && File(configPath).existsSync()) {
      throw StateError("Config '$configPath' could not be read at startup; "
          'not overwriting it. Restart the app.');
    }
    // The tray and the window are separate processes, each with its
    // own ConfigManager. Writing our whole (possibly hours old) copy
    // would silently undo whatever the other one saved meanwhile, so
    // only the keys edited here are applied on top of the file as it
    // is now — under a lock so two saves cannot interleave.
    final lock = InterProcessLock('$configPath.lock');
    if (!lock.acquire(timeoutS: 10.0)) {
      // Writing unlocked could interleave with the other process's
      // save and silently drop its edits: fail loudly instead (the
      // edits stay in memory and go out with the next save).
      throw StateError("Config '$configPath' is being saved by another "
          'process; not saved — try again.');
    }
    try {
      final merged = _mergeOntoDisk();
      try {
        atomicWriteJson(configPath, merged, encoding: encoding);
      } on FileSystemException catch (e) {
        throw StateError(
            "Could not save config to '$configPath': $e");
      }
      if (!identical(merged, data)) {
        // In place: other objects share it.
        data
          ..clear()
          ..addAll(merged);
      }
    } finally {
      lock.release();
    }
    _rememberBaseline();
  }

  void _saveMultiAccount() {
    final gPath = globalPath!;
    final allKeys = <String>{...data.keys, ..._baseline.keys, ..._touched};
    final editedGlobal = <String>{};
    final editedAccount = <String>{};
    for (final k in allKeys) {
      final changed = _touched.contains(k) ||
          !_baseline.containsKey(k) ||
          !data.containsKey(k) ||
          !jsonEquals(_baseline[k], data[k]);
      if (!changed) continue;
      if (globalConfigKeys.contains(k)) {
        editedGlobal.add(k);
      } else {
        editedAccount.add(k);
      }
    }
    final writeGlobal =
        editedGlobal.isNotEmpty || !File(gPath).existsSync();
    final writeAccount =
        editedAccount.isNotEmpty || !File(configPath).existsSync();

    // 1. Write global.json first (never nested with config.json.lock, §3.4).
    if (writeGlobal) {
      if (_globalUnreadable && File(gPath).existsSync()) {
        throw StateError("Config '$gPath' could not be read at startup; "
            'not overwriting it. Restart the app.');
      }
      final gLock = InterProcessLock('$gPath.lock');
      if (!gLock.acquire(timeoutS: 10.0)) {
        throw StateError("Config '$gPath' is being saved by another "
            'process; not saved — try again.');
      }
      try {
        final mergedGlobal = _mergeSplitOntoDisk(
          gPath,
          globalOnly: true,
          editedKeys: editedGlobal,
        );
        try {
          atomicWriteJson(gPath, mergedGlobal, encoding: encoding);
        } on FileSystemException catch (e) {
          throw StateError("Could not save config to '$gPath': $e");
        }
        for (final k in globalConfigKeys) {
          if (mergedGlobal.containsKey(k)) {
            data[k] = mergedGlobal[k];
            _baseline[k] = _deepCopyJson(mergedGlobal[k]);
          } else {
            data.remove(k);
            _baseline.remove(k);
          }
          _touched.remove(k);
        }
      } finally {
        gLock.release();
      }
    }

    // 2. Write per-account config.json second (§3.4).
    if (writeAccount) {
      if (isDeleted) {
        throw StateError(
            "Account folder for '$configPath' was deleted; refusing to save.");
      }
      if (_unreadable && File(configPath).existsSync()) {
        throw StateError("Config '$configPath' could not be read at startup; "
            'not overwriting it. Restart the app.');
      }
      final aLock = InterProcessLock('$configPath.lock');
      if (!aLock.acquire(timeoutS: 10.0)) {
        throw StateError("Config '$configPath' is being saved by another "
            'process; not saved — try again.');
      }
      try {
        final mergedAccount = _mergeSplitOntoDisk(
          configPath,
          globalOnly: false,
          editedKeys: editedAccount,
        );
        if (accountWriteOverride != null) {
          accountWriteOverride!();
        } else {
          try {
            atomicWriteJson(configPath, mergedAccount, encoding: encoding);
          } on FileSystemException catch (e) {
            throw StateError("Could not save config to '$configPath': $e");
          }
        }
        final accountKeys = <String>{
          ...mergedAccount.keys,
          for (final k in data.keys)
            if (!globalConfigKeys.contains(k)) k,
          for (final k in _baseline.keys)
            if (!globalConfigKeys.contains(k)) k,
        };
        for (final k in accountKeys) {
          if (mergedAccount.containsKey(k)) {
            data[k] = mergedAccount[k];
            _baseline[k] = _deepCopyJson(mergedAccount[k]);
          } else {
            data.remove(k);
            _baseline.remove(k);
          }
          _touched.remove(k);
        }
      } finally {
        aLock.release();
      }
    }
  }

  Map<String, Object?> _mergeSplitOntoDisk(
    String path, {
    required bool globalOnly,
    required Set<String> editedKeys,
  }) {
    final defaults = defaultConfig();
    final merged = <String, Object?>{
      for (final e in defaults.entries)
        if (globalConfigKeys.contains(e.key) == globalOnly) e.key: e.value,
    };
    if (File(path).existsSync()) {
      try {
        final decoded =
            jsonDecode(File(path).readAsStringSync(encoding: encoding));
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final k = '${entry.key}';
            if (globalConfigKeys.contains(k) != globalOnly) continue;
            if (entry.value != null) merged[k] = entry.value as Object?;
          }
        }
      } on FileSystemException {
        // Fall back to in-memory values for this split below.
        for (final entry in data.entries) {
          if (globalConfigKeys.contains(entry.key) == globalOnly) {
            merged[entry.key] = entry.value;
          }
        }
        return merged;
      } on FormatException {
        for (final entry in data.entries) {
          if (globalConfigKeys.contains(entry.key) == globalOnly) {
            merged[entry.key] = entry.value;
          }
        }
        return merged;
      }
    }
    for (final k in editedKeys) {
      if (globalConfigKeys.contains(k) != globalOnly) continue;
      if (data.containsKey(k)) {
        merged[k] = data[k];
      } else {
        merged.remove(k);
      }
    }
    return merged;
  }

  /// Current file content with this instance's edits applied.
  ///
  /// Falls back to this instance's full data when the file is missing
  /// or unreadable (nothing on disk worth preserving then).
  Map<String, Object?> _mergeOntoDisk() {
    if (!File(configPath).existsSync()) return data;
    late final Map<String, Object?> onDisk;
    try {
      final decoded = jsonDecode(
          File(configPath).readAsStringSync(encoding: encoding));
      if (decoded is! Map) return data;
      onDisk = decoded.map((k, v) => MapEntry('$k', v as Object?));
    } on FileSystemException {
      return data;
    } on FormatException {
      return data;
    }
    final merged = defaultConfig();
    for (final entry in onDisk.entries) {
      if (entry.value != null) merged[entry.key] = entry.value;
    }
    for (final entry in data.entries) {
      if (_touched.contains(entry.key) ||
          !_baseline.containsKey(entry.key) ||
          _baseline[entry.key] != entry.value) {
        merged[entry.key] = entry.value;
      }
    }
    for (final key in _baseline.keys) {
      if (!data.containsKey(key)) merged.remove(key);
    }
    return merged;
  }

  /// Retrieves a configuration value by key.
  Object? get(String key, [Object? defaultValue]) =>
      data.containsKey(key) ? data[key] : defaultValue;

  /// Sets a configuration value, automatically encrypting passwords.
  void set(String key, Object? value, {bool autoEncrypt = true}) {
    if (!canonicalDefaults.containsKey(key)) {
      // Warn about typos, but still store (keys of newer versions).
      print("Warning: unknown config key '$key' — storing anyway.");
    }
    _touched.add(key);
    if (autoEncrypt &&
        (key == 'strava_password' ||
            key == 'bakalari_password' ||
            key == 'gemini_api_key')) {
      _touched.add('${key}_encrypted');
    }
    if (key == 'excuse_mode' || key == 'strava_order_mode') {
      final normalized = '$value'.toLowerCase();
      if (!excuseModes.contains(normalized)) {
        throw ArgumentError(
            "'$key' must be one of $excuseModes, got ${_repr(value)}.");
      }
      data[key] = normalized;
      return;
    }
    if (autoEncrypt &&
        (key == 'strava_password' ||
            key == 'bakalari_password' ||
            key == 'gemini_api_key')) {
      // Avoid re-encrypting if value is already the encrypted string.
      if (data['${key}_encrypted'] == true && data[key] == value) return;
      final encDir = key == 'gemini_api_key' ? (rootDir ?? baseDir) : baseDir;
      data[key] = encrypt('$value', dataDir: encDir);
      data['${key}_encrypted'] = true;
    } else {
      data[key] = value;
    }
  }

  /// Sets a configuration value and immediately persists to disk.
  void setAndSave(String key, Object? value, {bool autoEncrypt = true}) {
    set(key, value, autoEncrypt: autoEncrypt);
    save();
  }

  /// Validates current config, returning human-readable problems.
  List<String> validate() => validateConfig(data);

  /// Returns the resolved absolute path to the blacklist file.
  String getBlacklistPath() => resolvePath(
      '${get('strava_blacklist', './strava_blacklist.json')}',
      requirePerAccountDir(baseDir));

  /// Loads blacklist keywords from strava_blacklist.json.
  ///
  /// Returns [] when the file is missing: the default blacklist is
  /// empty (a missing file means "no bans", never the example template).
  /// Placeholder entries from older templates (`YOUR_BLACKLIST_EXAMPLE`)
  /// are filtered from any loaded list so a copied old example stays
  /// harmless.
  List<String> getBlacklist() => _readBlacklist(strict: false);

  /// Blacklist keywords; [strict] raises when the file is busy.
  ///
  /// Only undecodable content is quarantined. A busy file reads as
  /// empty for display, but edits ([strict]) must fail instead of
  /// saving a list that would drop every existing keyword.
  List<String> _readBlacklist({bool strict = false}) {
    final path = getBlacklistPath();
    if (!File(path).existsSync()) return [];
    try {
      final decoded =
          jsonDecode(File(path).readAsStringSync(encoding: encoding));
      if (decoded is List) {
        return decoded
            .map((e) => '$e')
            .where((kw) => !looksLikePlaceholder(kw))
            .toList();
      }
      print("Warning: Blacklist file '$path' does not contain a JSON "
          'list. Treating as empty.');
      return [];
    } on FormatException catch (e) {
      final backup = quarantineCorruptFile(path);
      final hint = backup.isNotEmpty ? ' Preserved at $backup.' : '';
      print("Warning: Could not read blacklist file '$path': $e. "
          'Treating as empty.$hint');
      return [];
    } on FileSystemException catch (e) {
      if (strict) {
        throw StateError(
            "Blacklist file '$path' is not readable right now: $e");
      }
      print("Warning: Could not read blacklist file '$path' right now: $e.");
      return [];
    }
  }

  /// Saves blacklist keywords list to strava_blacklist.json (atomically).
  void setBlacklist(List<Object?> items) {
    final path = getBlacklistPath();
    // Deduplicate while preserving order, strip whitespace.
    final cleaned = <String>[];
    for (final item in items) {
      final s = '$item'.trim();
      if (s.isNotEmpty && !cleaned.contains(s)) cleaned.add(s);
    }
    atomicWriteJson(path, cleaned, encoding: encoding);
  }

  /// Adds a keyword to the blacklist if not already present.
  bool addBlacklistItem(String item) {
    final clean = item.trim();
    if (clean.isEmpty) return false;
    final current = _readBlacklist(strict: true);
    if (!current.any((x) => x.toLowerCase() == clean.toLowerCase())) {
      current.add(clean);
      setBlacklist(current);
      return true;
    }
    return false;
  }

  /// Removes a keyword from the blacklist.
  bool removeBlacklistItem(String item) {
    final clean = item.trim().toLowerCase();
    final current = _readBlacklist(strict: true);
    final next =
        current.where((x) => x.trim().toLowerCase() != clean).toList();
    if (next.length != current.length) {
      setBlacklist(next);
      return true;
    }
    return false;
  }

  /// Returns the resolved absolute path to the already excused lessons file.
  String getAlreadyExcusedPath() => resolvePath(
      '${get('already_excused_file', './already_excused_lessons.json')}',
      requirePerAccountDir(baseDir));

  /// Loads history from already_excused_lessons.json (or the example
  /// template if missing, with demo rows filtered out).
  List<Object?> getExcuseHistory() {
    final path = getAlreadyExcusedPath();
    if (!File(path).existsSync()) {
      final examplePath = examplePathFor(path);
      if (File(examplePath).existsSync()) {
        try {
          final decoded = jsonDecode(
              File(examplePath).readAsStringSync(encoding: encoding));
          final items = decoded is List ? List.of(decoded) : <Object?>[];
          // Template fallback: filter demo/placeholder rows
          // so they never seed real dedup history.
          return items.where((it) => !isDemoHistoryItem(it)).toList();
        } on Object catch (e) {
          print('Warning: Could not read excuse history template '
              "'$examplePath': $e");
        }
      }
      return [];
    }
    try {
      final decoded =
          jsonDecode(File(path).readAsStringSync(encoding: encoding));
      if (decoded is List) return List.of(decoded);
      print("Warning: Excuse history file '$path' does not contain a JSON "
          'list. Treating as empty.');
      return [];
    } on FormatException catch (e) {
      final backup = quarantineCorruptFile(path);
      final hint = backup.isNotEmpty ? ' Preserved at $backup.' : '';
      print("Warning: Could not read excuse history file '$path': $e. "
          'Treating as empty.$hint');
      return [];
    } on FileSystemException catch (e) {
      print(
          "Warning: Could not read excuse history file '$path' right now: $e.");
      return [];
    }
  }
}
