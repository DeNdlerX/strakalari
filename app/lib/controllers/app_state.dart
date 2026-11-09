// Shared application state + the root Riverpod provider.
//
// Port of strakalari/flet_ui/state.py (`AppState`). The per-area logic
// from the `state_*.py` mixins lives in this folder as extensions on
// [AppState] plus one thin [Notifier] facade each (activity, excuses,
// lunches, marks, planner, tutorial); widgets and facades share the
// single [AppState] instance owned by [appStateProvider].
//
// Flet page bits (`page.update()`, `run_task`, overlays/snackbars) are
// dropped — noted with `// Flet:` comments at each site. Background
// threads become Dart `Future`s in phase 6/7; the phase-5 stubs record
// intent (flags + log lines) and return the same booleans.
//
// All timestamps use package:clock (`clock.now()`), never `DateTime.now()`
// directly, so tests can run inside `withClock()`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../l10n/strings.dart';
import '../shell/theme.dart';
import '../tutorial/tours.dart';

part 'activity.dart';
part 'excuses.dart';
part 'lunches.dart';
part 'marks.dart';
part 'planner.dart';
part 'tutorial.dart';

/// Canonical `Map<String, Object?>` copy of a decoded-JSON map.
Map<String, Object?> strObjMap(Map m) => {
      for (final e in m.entries) '${e.key}': e.value,
    };

/// `DD.MM.YYYY` — the canonical day-label format used across caches,
/// orders and planned skips (port of `strftime("%d.%m.%Y")`).
String fmtDay(DateTime day) =>
    '${day.day.toString().padLeft(2, '0')}.'
    '${day.month.toString().padLeft(2, '0')}.'
    '${day.year}';

/// `YYYY-MM-DD` ISO day (port of `date.isoformat()`).
String fmtIso(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// `HH:MM:SS` log stamp (port of `strftime("%H:%M:%S")`).
String fmtClock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:'
    '${t.minute.toString().padLeft(2, '0')}:'
    '${t.second.toString().padLeft(2, '0')}';

/// Mutable UI + cache state. Field-for-field port of `AppState.__init__`.
class AppState {
  /// Called after every mutation that used to `_emit()` in Flet
  /// (wired by [AppStateController] to re-emit the provider).
  void Function() onChanged = _noop;
  static void _noop() {}

  /// Progress-tick channel (former `_progress_listeners`): repaints only
  /// the status line so half-typed settings inputs survive refresh ticks.
  void Function() onProgress = _noop;

  /// Fired after every config save, including quiet ones.
  final List<void Function()> configListeners = [];

  AppState({Map<String, Object?>? configData, Map<String, Object?>? data}) {
    if (configData != null) {
      for (final e in configData.entries) {
        try {
          config.set(e.key, e.value);
        } catch (_) {
          // Invalid seed values never break construction.
        }
      }
    }
    if (data != null) {
      this.data = Map<String, Object?>.of(data);
    } else {
      try {
        this.data = loadDataCache();
      } catch (_) {
        this.data = {};
      }
    }
    dataRev = 0;
    demoMode = !(this.data.containsKey('absence') &&
        this.data['absence'] is Map &&
        (this.data['absence'] as Map).isNotEmpty ||
        this.data.containsKey('timetable') &&
            this.data['timetable'] is Map &&
            (this.data['timetable'] as Map).isNotEmpty);
    plannedSkips = loadPlannedSkips(config.data);
    cancelledLunches = {};
    for (final entry in plannedSkips) {
      if (!cancelsLunch(entry)) continue;
      for (final day in entryDays(entry)) {
        cancelledLunches.add(fmtDay(day));
      }
    }
    try {
      final stored = config.get('ignored_excuses', []);
      if (stored is List) {
        ignoredExcuseKeys = {
          for (final k in stored)
            if ('$k'.trim().isNotEmpty) '$k',
        };
      }
    } catch (_) {
      // Memory default stands when the config cannot be read.
    }
    final cachedOrders = this.data['strava_ordered'];
    if (cachedOrders is Map) {
      for (final e in cachedOrders.entries) {
        orders[canonicalDayKey(e.key)] = '${e.value}';
      }
    }
    webOrders = Map<String, String>.of(orders);
    for (final day in cancelledLunches) {
      if (!'${orders[day]}'.contains('&-1&')) orders.remove(day);
    }
    timetableView = () {
      final v = '${get('timetable_view', 'table')}';
      return (v == 'table' || v == 'list') ? v : 'table';
    }();
  }

  final ConfigManager config = ConfigManager();
  late Map<String, Object?> data;
  late int dataRev;
  late bool demoMode;

  // -- planned skips / lunches -------------------------------------------
  late List<Map<String, Object?>> plannedSkips;
  late Set<String> cancelledLunches;
  Set<String> ignoredExcuseKeys = {};
  String lastIgnoreError = '';
  final List<Map<String, Object?>> excuseLog = [];
  final Set<String> sendingExcuses = {};
  bool orderRunning = false;
  bool aiRunning = false;
  final Map<String, String> orders = {};
  late Map<String, String> webOrders;
  final Set<String> pendingOrders = {};

  // -- timetable view prefs -----------------------------------------------
  String? timetableMondayIso;
  bool showStableTimetable = false;
  late String timetableView;

  // -- activity / automation status ----------------------------------------
  String status = 'idle'; // idle | working | error
  String currentStep = '';
  final List<String> logLines = [];
  final List<Map<String, Object?>> runs = [];
  Map<String, Object?>? lastError;
  bool errorDialogPending = false;
  bool refreshRunning = false;
  bool cancelRequested = false;
  Map<String, Object?> lastTest = {};
  String testing = '';
  DateTime? schedulerLastRun;
  String? pendingRoute;
  bool narrow = false;
  bool navSide = false;

  // -- lunches UI memory ----------------------------------------------------
  Set<String> lunchHidden = {};
  Map<String, String> lunchReasons = {};
  String lunchPrefs = '';
  String blacklistEditError = '';

  // -- per-render UI memory (in-memory only) --------------------------------
  final Map<String, int> pickedTemplates = {};
  String settingsSection = 'accounts';
  bool settingsOpen = false;
  bool lunchesSidebarOpen = true;
  bool lunchToolsOpen = false;
  bool showPastCalendar = false;
  bool showPastLunches = false;
  final Map<String, bool> expandedDays = {};
  final Map<String, String> drafts = {};
  int wizardStep = 0;
  (String, int)? tutorial;
  bool wizardDismissed = false;
  bool wizardShown = false;
  final Map<String, String> wizardVerified = {};

  // -- marks UI memory (predictions are what-ifs, never saved) --------------
  Map<String, Map<String, Object?>> marksPredictions = {};
  String? marksSelected;
  String? marksEditing;
  final Map<String, Map<String, String>> marksCalcStore = {};

  // -- planner UI memory ------------------------------------------------------
  String? plannerTerm;

  // -- tutorial progress -------------------------------------------------------
  Set<String> tutorialsDoneSession = {};

  // -- update check -------------------------------------------------------------
  Map<String, Object?>? updateInfo;
  bool updateCheckRunning = false;
  String updateDismissed = '';

  // -- caches --------------------------------------------------------------------
  Object? yearPlanCacheKey;
  Object? yearPlanCache;
  (int, Map<String, Object?>)? baselineCacheKey;
  Map<(int, int), Object>? baselineCache;

  // -- background jobs ------------------------------------------------------------
  /// Runs a background job (port of `_spawn`). The live app wires this to
  /// run the job on the event loop ([AppStateController]); a bare
  /// [AppState] (unit tests) only records intent and never touches the
  /// network, exactly like the earlier phase-5 stubs.
  void Function(Future<void> Function() job, String name) spawn =
      _noSpawn;
  static void _noSpawn(Future<void> Function() job, String name) {}

  /// Factory for [Strakalari] sessions (test seam: tests inject fakes
  /// without touching the network).
  Strakalari Function(
          {void Function(String)? onLog, Map<String, Object?>? configData})
      createApp = (
              {void Function(String)? onLog,
              Map<String, Object?>? configData}) =>
          Strakalari(onLog: onLog, configData: configData);

  /// AI lunch recommendation seam (defaults to core [recommendLunches];
  /// tests inject fakes without touching the Gemini network API).
  Future<(String, Map<String, String>)> Function(
    Map<Object?, Object?> foodData,
    String pref,
    String apiKey, {
    String model,
    String language,
  }) recommendLunchesFn = recommendLunches;

  /// Last snackbar-equivalent message from a background worker
  /// (excuse send, order submit, AI recommend).
  String lastSnackMessage = '';

  // -- reactive ---------------------------------------------------------------
  final Set<String> _flights = {};

  /// Atomically test-and-set a flight flag. True when claimed.
  /// Port of `_claim_flight()`.
  bool claimFlight(String name) => _flights.add(name);

  /// Releases a flight flag. Port of `_release_flight()`.
  void releaseFlight(String name) {
    _flights.remove(name);
  }

  void _emit() => onChanged();

  void _emitProgress() => onProgress();

  // -- config ----------------------------------------------------------------------
  Object? get(String key, [Object? defaultValue]) {
    try {
      return config.get(key, defaultValue);
    } catch (_) {
      return defaultValue;
    }
  }

  /// Persists config updates. Returns true only if the write succeeded.
  /// Port of `save()` (callers must branch on the result).
  bool save(Map<String, Object?> updates) {
    var ok = true;
    for (final e in updates.entries) {
      try {
        config.set(e.key, e.value);
      } catch (err) {
        ok = false;
      }
    }
    try {
      config.save();
    } catch (_) {
      return false;
    }
    for (final cb in List.of(configListeners)) {
      try {
        cb();
      } catch (_) {
        // A listener never breaks a save.
      }
    }
    _emit();
    return ok;
  }

  /// Like [save] without re-rendering (settings field edits).
  /// Port of `save_quiet()`.
  bool saveQuiet(Map<String, Object?> updates) => save(updates);

  bool automationPaused() {
    try {
      return core.automationPaused(config.data);
    } catch (_) {
      return false;
    }
  }

  bool setAutomationPaused(bool paused) {
    final ok = save({'automation_paused': paused});
    if (!ok) logLine(Strings.get('save_failed'));
    return ok;
  }

  bool setTheme(String mode) => save({'theme': normalizeMode(mode)});

  bool setLanguage(String lang) =>
      save({'language': (lang == 'cs' || lang == 'en') ? lang : 'cs'});

  bool get densityCompact => get('compact_density', false) == true;

  // -- data accessors -----------------------------------------------------------------
  String get updatedLabel {
    if (demoMode) return Strings.get('no_data');
    try {
      return describeCache(
          data, (num.tryParse('${get('cache_ttl_hours', 24)}') ?? 24));
    } catch (_) {
      return '${data['last_updated'] ?? ''}';
    }
  }

  Map<String, double> absence() {
    final raw = demoMode ? null : data['absence'];
    if (raw is Map && raw.isNotEmpty) {
      final out = <String, double>{};
      for (final e in raw.entries) {
        final v = double.tryParse('${e.value}');
        if (v != null) out['${e.key}'] = v;
      }
      if (out.isNotEmpty) return out;
    }
    return {};
  }

  Map<String, Map<String, Object?>> absenceDetails() {
    final raw = demoMode ? null : data['absence_details'];
    if (raw is Map && raw.isNotEmpty) {
      return {
        for (final e in raw.entries)
          if (e.value is Map) e.key.toString(): strObjMap(e.value as Map),
      };
    }
    return {};
  }

  Map<String, String> subjectDirectory() {
    final raw = demoMode ? null : data['subject_directory'];
    if (raw is Map && raw.isNotEmpty) {
      return {
        for (final e in raw.entries)
          if ('${e.key}'.isNotEmpty && '${e.value}'.isNotEmpty)
            '${e.key}': '${e.value}',
      };
    }
    return {};
  }

  /// Canonical tracked subject names, or null when unknown (never filter
  /// then). Port of `tracked_subjects()`.
  Set<String>? trackedSubjects() {
    final directory = subjectDirectory();
    if (directory.isEmpty) return null;
    return {for (final n in directory.values) canonSubject(n)};
  }

  Map<String, Object?> grades() {
    final raw = demoMode ? null : data['grades'];
    if (raw is Map && raw.isNotEmpty) return strObjMap(raw);
    return {};
  }

  Map<String, Map<String, Object?>> quarterlyMarks() {
    final raw = demoMode ? null : data['quarterly_marks'];
    if (raw is Map) {
      return {
        for (final e in raw.entries)
          if (e.value is Map) e.key.toString(): strObjMap(e.value as Map),
      };
    }
    return {};
  }

  /// Timetable keyed by canonical `DD.MM.YYYY` (real cache keys carry the
  /// weekday: `"7.9.2026 (pondělí)"`). Port of `timetable()`.
  Map<String, List<Map<String, Object?>>> timetable() {
    final raw = demoMode ? null : data['timetable'];
    if (raw is Map && raw.isNotEmpty) {
      final normalized = <String, List<Map<String, Object?>>>{};
      for (final e in raw.entries) {
        final canon = canonicalDayKey(e.key);
        final lessons = e.value;
        if (lessons is List) {
          normalized.putIfAbsent(canon, () => []).addAll(
              lessons.whereType<Map>().map(strObjMap));
        }
      }
      return normalized;
    }
    return {};
  }

  Map<String, Map<String, String>> food() {
    final raw =
        demoMode ? null : (data['food'] ?? data['strava_meals']);
    if (raw is Map && raw.isNotEmpty) {
      final normalized = <String, Map<String, String>>{};
      for (final e in raw.entries) {
        if (e.value is! Map) continue;
        normalized.putIfAbsent(canonicalDayKey(e.key), () => {}).addAll({
          for (final m in (e.value as Map).entries) '${m.key}': '${m.value}',
        });
      }
      if (normalized.isNotEmpty) return normalized;
    }
    return {};
  }

  // -- in-memory UI helpers (no config writes) ------------------------------------------
  String draft(String key, [String fallback = '']) => drafts[key] ?? fallback;

  void setDraft(String key, String value) {
    drafts[key] = value;
  }

  void clearDrafts([String prefix = '']) {
    if (prefix.isEmpty) {
      drafts.clear();
    } else {
      drafts.removeWhere((k, _) => k.startsWith(prefix));
    }
  }

  void setSettingsSection(String section) {
    settingsSection = section;
    settingsOpen = true;
    for (final k in ['acc:bakalari_password', 'acc:strava_password', 'ai:key']) {
      drafts.remove(k);
    }
    _emit();
  }

  void closeSettingsSection() {
    settingsOpen = false;
    for (final k in ['acc:bakalari_password', 'acc:strava_password', 'ai:key']) {
      drafts.remove(k);
    }
    _emit();
  }

  void setLunchesSidebar(bool open) {
    lunchesSidebarOpen = open;
    _emit();
  }

  void setLunchTools(bool open) {
    lunchToolsOpen = open;
    _emit();
  }

  void setShowPastCalendar(bool show) {
    showPastCalendar = show;
    _emit();
  }

  void setShowPastLunches(bool show) {
    showPastLunches = show;
    _emit();
  }

  bool isDayExpanded(String key, [bool defaultValue = false]) =>
      expandedDays[key] ?? defaultValue;

  void setDayExpanded(String key, bool expanded) {
    expandedDays[key] = expanded;
  }

  bool stravaEnabled() {
    try {
      return get('use_strava', true) != false;
    } catch (_) {
      return true;
    }
  }

  // -- phone: wake-up alarm and home-screen widget -------------------------
  // (Android-only behavior; elsewhere these are documented no-ops.)

  /// Demo lessons must neither ring nor fill the home screen.
  Map<String, List<Map<String, Object?>>> phoneTimetable() =>
      demoMode ? {} : timetable();

  /// The wake-up alarm rings on the Android phone only; phase 8 reports
  /// it via the platform channel. Port of `wakeup_available()`.
  bool get wakeupAvailable => false;

  /// Hands the widget data and the alarm queue to the phone (a no-op
  /// elsewhere). Port of `sync_android_state()`.
  void syncAndroidState() {
    try {
      final tt = <String, Object?>{};
      for (final e in phoneTimetable().entries) {
        tt[e.key] = e.value;
      }
      syncAndroid(
        tt,
        config: Map<String, Object?>.of(config.data),
        stableBaseline: stableBaseline(),
        stableComplete: stableComplete(),
      );
    } catch (_) {
      // Never break a save or a reload.
    }
  }

  /// What the phone's background notification shows its overview from.
  /// Port of `background_status_inputs()`.
  StatusInputs backgroundStatusInputs() {
    final demo = demoMode;
    var pending = 0;
    try {
      pending = demo ? 0 : unexcusedTasks().length;
    } catch (_) {
      pending = 0;
    }
    DateTime? updated;
    try {
      final raw = '${data['last_updated'] ?? ''}';
      final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4}) (\d{1,2}):(\d{2}):(\d{2})$')
          .firstMatch(raw);
      if (m != null) {
        updated = DateTime(
          int.parse(m.group(3)!),
          int.parse(m.group(2)!),
          int.parse(m.group(1)!),
          int.parse(m.group(4)!),
          int.parse(m.group(5)!),
          int.parse(m.group(6)!),
        );
      }
    } catch (_) {
      updated = null;
    }
    final tt = <String, Object?>{};
    for (final e in phoneTimetable().entries) {
      tt[e.key] = e.value;
    }
    final menu = <String, Object?>{};
    for (final e in food().entries) {
      menu[e.key] = e.value;
    }
    return StatusInputs(
      timetable: tt,
      food: menu,
      webOrders: demo ? {} : Map<String, Object?>.of(webOrders),
      config: Map<String, Object?>.of(config.data),
      stableBaseline: stableBaseline(),
      stableComplete: stableComplete(),
      pendingExcuses: pending,
      lastUpdated: demo ? null : updated,
      freeDays: lunchFreeDays(),
    );
  }

  /// Re-reads the data cache and reconciles local picks with web truth.
  /// Port of `reload_cache()`.
  void reloadCache() {
    try {
      data = loadDataCache();
    } catch (_) {
      // Keep the previous snapshot when the cache cannot be read.
    }
    dataRev++;
    demoMode = !(data['absence'] is Map &&
            (data['absence'] as Map).isNotEmpty ||
        data['timetable'] is Map && (data['timetable'] as Map).isNotEmpty);
    final cachedOrders = data['strava_ordered'];
    if (cachedOrders is Map) {
      final canon = {
        for (final e in cachedOrders.entries) canonicalDayKey(e.key): e.value,
      };
      for (final e in canon.entries) {
        final day = e.key;
        final meal = '${e.value ?? ''}';
        if (cancelledLunches.contains(day)) {
          final staged = orders[day];
          if (staged != null && staged.contains('&-1&')) continue;
          orders.remove(day);
          continue;
        }
        if (pendingOrders.contains(day)) {
          orders.putIfAbsent(day, () => meal);
        } else if (meal.isNotEmpty) {
          orders[day] = meal;
        } else {
          orders.remove(day);
        }
      }
      for (final day in orders.keys.toList()) {
        if (!canon.containsKey(day) && !pendingOrders.contains(day)) {
          orders.remove(day);
        }
      }
      webOrders = {
        for (final e in canon.entries)
          if ('${e.value ?? ''}'.isNotEmpty) e.key: '${e.value}',
      };
      pendingOrders.removeWhere(
          (d) => !cancelledLunches.contains(d) && !_lunchIsChange(d));
    }
    _emit();
  }

  /// Local pick differs from web truth (the Obědy badge counts these).
  /// Backing check for `pending_lunch_count`; full port in lunches.dart.
  bool _lunchIsChange(String day) {
    if (!orders.containsKey(day)) return false;
    return _realMeal(orders[day]) != _realMeal(webOrders[day]);
  }

  static String _realMeal(Object? mealId) {
    final mid = '$mealId';
    return mid.contains('&-1&') ? '' : mid;
  }

  void setTimetableView(String view) {
    if (view != 'table' && view != 'list') return;
    timetableView = view;
    save({'timetable_view': view});
  }

  bool _hasCredentials() {
    try {
      return core.hasValidCredentials(config.data).$1;
    } catch (_) {
      return false;
    }
  }

  bool _hasStravaCredentials() {
    try {
      return core.hasValidCredentials(config.data).$2;
    } catch (_) {
      return false;
    }
  }

  bool _hasAnyCredentials() => _hasCredentials() || _hasStravaCredentials();

  // -- first-run wizard (in-memory step, gating on real credentials) ---------------------
  bool needsSetup() {
    if (wizardDismissed) return false;
    return !_hasAnyCredentials();
  }

  bool get setupPending {
    if (wizardDismissed) return false;
    return wizardShown || needsSetup();
  }

  void dismissWizard() {
    wizardDismissed = true;
    _emit();
  }

  void wizardGoto(int step, int stepDone) {
    wizardStep = step.clamp(0, stepDone);
    _emit();
  }

  void wizardFinished() {
    wizardDismissed = true;
    wizardStep = 0;
    drafts.removeWhere((k, _) => k.startsWith('wiz:'));
    wizardVerified.clear();
    _emit();
  }

  // -- timetable week nav ------------------------------------------------------------------------
  static const List<String> timetableScrollKeys = [
    'timetable:table',
    'timetable:list',
  ];

  void setTimetableMonday(String? mondayIso) {
    if (timetableMondayIso == mondayIso) return;
    timetableMondayIso = mondayIso;
    _emit();
  }

  void setShowStable(bool show) {
    if (showStableTimetable == show) return;
    showStableTimetable = show;
    _emit();
  }

  /// Atomic week switch: stable view off + new week, one emit.
  /// Port of `go_timetable_week()`.
  void goTimetableWeek(String? mondayIso) {
    var changed = false;
    if (showStableTimetable) {
      showStableTimetable = false;
      changed = true;
    }
    if (timetableMondayIso != mondayIso) {
      timetableMondayIso = mondayIso;
      changed = true;
    }
    if (!changed) return;
    _emit();
  }

  // -- navigation ------------------------------------------------------------------------
  /// Asks the shell to switch routes (views have no shell access).
  /// Port of `go()`.
  void go(String route) {
    pendingRoute = route;
    _emit();
  }

  // -- logging (activity mixin backing; richer API in activity.dart) ---------
  void logLine(String message) {
    final stamp = fmtClock(clock.now());
    logLines.add('[$stamp] $message');
    if (logLines.length > 300) {
      logLines.removeRange(0, logLines.length - 300);
    }
    _emit();
  }
}

/// Riverpod owner of the shared [AppState].
class AppStateController extends Notifier<AppState> {
  @override
  AppState build() {
    final state = AppState();
    state.onChanged = () {
      // ignore: avoid_self_assignment
      this.state = this.state;
    };
    state.onProgress = state.onChanged;
    state.spawn = (job, name) {
      // A failing job must never crash the app: the jobs report their
      // own errors, this is the last-resort net (Python: `_spawn`).
      unawaited(job().catchError((Object e, StackTrace s) {
        // ignore: avoid_print
        print('Warning: background job $name failed: $e');
      }));
    };
    return state;
  }

  /// The shared [AppState] is mutated in place, so the same instance must
  /// still notify listeners (Riverpod skips equal values by default).
  @override
  bool updateShouldNotify(AppState previous, AppState next) => true;

  /// Re-emits after mutations made through a mixin facade.
  void emit() {
    // ignore: avoid_self_assignment
    state = state;
  }
}

final appStateProvider =
    NotifierProvider<AppStateController, AppState>(AppStateController.new);
