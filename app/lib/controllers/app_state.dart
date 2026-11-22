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

import '../features/planner/planner_view.dart' show PickerSlot;
import '../l10n/strings.dart';
import '../platform/android/android_channel.dart' show AndroidChannel;
import '../platform/android/android_keystore.dart' show ensureWarmed;
import '../platform/ios/ios_keystore.dart' show ensureIosWarmed;
import '../shell/router.dart' show routeForLocation;
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

/// Computes planned lunch-cancel days (`DD.MM.YYYY`) from [configData] and
/// [cacheData], shared by [AppState._loadAccount] and background account
/// refreshes (§7.2 step 4, S6).
Set<String> cancelledLunchDaysFor(
  Map<String, Object?> configData,
  Map<String, Object?> cacheData, {
  Map<String, String>? webOrdersMap,
}) {
  final web = webOrdersMap ?? _webOrdersFromCache(cacheData);
  final rawCancelHandled = cacheData[cancelHandledKey];
  final cancelHandled = <String>{
    if (rawCancelHandled is List)
      for (final d in rawCancelHandled) canonicalDayKey(d),
  };
  final skips = loadPlannedSkips(configData);
  final out = <String>{};
  for (final entry in skips) {
    if (!cancelsLunch(entry)) continue;
    for (final day in entryDays(entry)) {
      final key = fmtDay(day);
      final ordered = web[key] ?? '';
      if (cancelHandled.contains(key) &&
          ordered.isNotEmpty &&
          !ordered.contains('&-1&')) {
        continue;
      }
      out.add(key);
    }
  }
  return out;
}

Map<String, String> _webOrdersFromCache(Map<String, Object?> cacheData) {
  final out = <String, String>{};
  final cachedOrders = cacheData['strava_ordered'];
  if (cachedOrders is Map) {
    for (final e in cachedOrders.entries) {
      out[canonicalDayKey(e.key)] = '${e.value}';
    }
  }
  return out;
}

bool _isDemoCache(Map<String, Object?> cacheData) =>
    !(cacheData.containsKey('absence') &&
            cacheData['absence'] is Map &&
            (cacheData['absence'] as Map).isNotEmpty ||
        cacheData.containsKey('timetable') &&
            cacheData['timetable'] is Map &&
            (cacheData['timetable'] as Map).isNotEmpty);

Map<String, List<Map<String, Object?>>> _timetableFromCache(
    Map<String, Object?> cacheData, bool demo) {
  final raw = demo ? null : cacheData['timetable'];
  if (raw is Map && raw.isNotEmpty) {
    final normalized = <String, List<Map<String, Object?>>>{};
    for (final e in raw.entries) {
      final canon = canonicalDayKey(e.key);
      final lessons = e.value;
      if (lessons is List) {
        normalized
            .putIfAbsent(canon, () => [])
            .addAll(lessons.whereType<Map>().map(strObjMap));
      }
    }
    return normalized;
  }
  return {};
}

Map<String, Map<String, String>> _foodFromCache(
    Map<String, Object?> cacheData, bool demo) {
  final raw = demo ? null : (cacheData['food'] ?? cacheData['strava_meals']);
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

Map<(int, int), Object> _stableBaselineFromCache(
    Map<String, Object?> cacheData) {
  final raw = cacheData['stable_baseline'];
  if (raw is! Map || raw.isEmpty) return {};
  return {
    for (final e in baselineFromDict(raw).entries) e.key: e.value,
  };
}

bool _stableCompleteFromCache(Map<String, Object?> cacheData) =>
    cacheData['stable_baseline_source'] == 'scraped';

Set<DateTime> _lunchFreeDaysFromConfig(Map<String, Object?> configData) {
  try {
    return effectiveCalendar(configData, clip: false).dates;
  } catch (_) {
    return {};
  }
}

/// Pending excuse tasks derived from [cfg] and [cacheData], shared by
/// [ExcuseTasksLogic.excuseTasks] and [buildStatusInputsFrom] (§8, S6).
List<Map<String, Object?>> pendingExcuseTasksFor(
  ConfigManager cfg,
  Map<String, Object?> cacheData, {
  Set<String>? ignoredOverride,
  Set<String>? sentKeys,
}) {
  final demo = _isDemoCache(cacheData);
  if (demo) return [];
  final tt = _timetableFromCache(cacheData, false);
  var tasks = <Map<String, Object?>>[
    for (final t in excuseTasksFromLessons(lessonsFromTimetable(tt)))
      {
        'key': t.key,
        'kind': t.kind,
        'label': t.label,
        'detail': t.detail,
        'date': t.date == null ? '' : fmtIso(t.date!),
        'period': t.period,
        'status': 'pending',
      },
  ];
  if (tasks.isEmpty) return [];
  if (sentKeys != null && sentKeys.isNotEmpty) {
    tasks = [
      for (final t in tasks)
        if (!sentKeys.contains('${t['key']}')) t,
    ];
  }
  List<Object?> history = const [];
  try {
    history = cfg.getExcuseHistory();
  } catch (_) {
    history = const [];
  }
  if (history.isNotEmpty) {
    tasks = [
      for (final t in tasks)
        if (!taskCoveredByHistory(t, history)) t,
    ];
  }
  DateTime? outboxFrom;
  try {
    outboxFrom = parseCzDate('${cacheData[sentExcusesFromKey] ?? ''}');
  } catch (_) {
    outboxFrom = null;
  }
  final now = clock.now();
  final today = DateTime(now.year, now.month, now.day);
  final windowStart = fmtIso(core.semesterExcuseWindowStart(today, outboxFrom));
  final Set<String> ignored;
  if (ignoredOverride != null) {
    ignored = ignoredOverride;
  } else {
    final stored = cfg.get('ignored_excuses', const []);
    ignored = stored is List
        ? {
            for (final k in stored)
              if ('$k'.trim().isNotEmpty) '$k',
          }
        : const <String>{};
  }
  return [
    for (final t in tasks)
      if ('${t['date'] ?? ''}'.isEmpty ||
          '${t['date']}'.compareTo(windowStart) >= 0)
        if (!ignored.contains('${t['key']}')) t,
  ];
}

/// Builds [StatusInputs] from an account's config and cache, shared by the
/// active-account path and the non-active primary-account path (§8, S6).
StatusInputs buildStatusInputsFrom(
  ConfigManager cfg,
  Map<String, Object?> cacheData, {
  Map<String, String>? webOrdersOverride,
  int? pendingExcusesOverride,
  String? accountLabel,
}) {
  final demo = _isDemoCache(cacheData);
  var pending = 0;
  if (pendingExcusesOverride != null) {
    pending = pendingExcusesOverride;
  } else {
    try {
      pending = demo ? 0 : pendingExcuseTasksFor(cfg, cacheData).length;
    } catch (exc) {
      // ignore: avoid_print
      print('Warning: pending excuses unavailable (${exc.runtimeType}: $exc)');
      pending = 0;
    }
  }
  final updated = lastUpdatedTime(cacheData);
  final checked = lastCheckedTime(cacheData);
  final tt = <String, Object?>{
    for (final e in _timetableFromCache(cacheData, demo).entries)
      e.key: e.value,
  };
  final menu = <String, Object?>{
    for (final e in _foodFromCache(cacheData, demo).entries) e.key: e.value,
  };
  final web = webOrdersOverride ?? _webOrdersFromCache(cacheData);
  return StatusInputs(
    timetable: tt,
    food: menu,
    webOrders: demo ? {} : Map<String, Object?>.of(web),
    config: Map<String, Object?>.of(cfg.data),
    stableBaseline: _stableBaselineFromCache(cacheData),
    stableComplete: _stableCompleteFromCache(cacheData),
    pendingExcuses: pending,
    lastUpdated: demo ? null : updated,
    lastChecked: demo ? null : checked,
    freeDays: _lunchFreeDaysFromConfig(cfg.data),
    accountLabel: accountLabel,
  );
}

/// Hands widget data and wake-up alarms for [cfg] + [cacheData] to Android (§8).
void syncAndroidFrom(ConfigManager cfg, Map<String, Object?> cacheData) {
  try {
    final demo = _isDemoCache(cacheData);
    final tt = <String, Object?>{
      for (final e in _timetableFromCache(cacheData, demo).entries)
        e.key: e.value,
    };
    syncAndroid(
      tt,
      config: Map<String, Object?>.of(cfg.data),
      stableBaseline: _stableBaselineFromCache(cacheData),
      stableComplete: _stableCompleteFromCache(cacheData),
    );
  } catch (_) {
    // Never break a save or a reload.
  }
}

/// Optional startup layout context provided by `prepareStartup` for
/// [AppStateController.build] (overridden in `main.dart` and tests).
final startupLayoutProvider =
    Provider<({MultiAccountLayoutResult? layout, String? rootDir})?>(
        (ref) => null);

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

  AppState({
    Map<String, Object?>? configData,
    Map<String, Object?>? data,
    MultiAccountLayoutResult? layoutResult,
    String? rootDir,
  }) {
    // Resolve multi-account layout context (null in legacy single-file unit tests).
    if (layoutResult != null) {
      this.rootDir = rootDir ?? (isAccountsMode ? accountsModeRootDir : null);
      if (layoutResult.isReady && layoutResult.registry != null) {
        registry = layoutResult.registry;
        migrationDegraded = false;
      } else if (layoutResult.isDegraded) {
        registry = null;
        migrationDegraded = true;
        migrationFailedNoticePending = true;
      } else if (layoutResult.isRegistryFailed) {
        registry = null;
        registryError = layoutResult.error ?? 'Account registry unreadable.';
      }
    } else if (isAccountsMode && accountsModeRootDir != null) {
      this.rootDir = rootDir ?? accountsModeRootDir;
      try {
        registry = AccountRegistry.load(this.rootDir!);
      } on Object catch (e) {
        registry = null;
        registryError = '$e';
      }
    } else {
      this.rootDir = rootDir;
    }

    _loadAccount(seedConfig: configData, seedData: data);
    if (migrationFailedNoticePending) {
      migrationFailedNoticePending = false;
      lastSnackMessage = Strings.get('account_migration_failed');
    }

    try {
      final cached = loadCached(updateChannel);
      if (cached != null &&
          '${cached['version'] ?? ''}'.isNotEmpty &&
          updateAvailable(cached)) {
        updateInfo = cached;
      }
    } catch (_) {
      // Missing or unreadable update cache is non-fatal.
    }
  }

  // -- multi-account metadata (survives switchAccount, §10.1 allow-list) ----
  String? rootDir;
  AccountRegistry? registry;
  bool migrationDegraded = false;
  bool migrationFailedNoticePending = false;
  String? registryError;
  String? addingAccountReturnId;
  bool backgroundAccountRunning = false;
  (String accountId, String route)? pendingBusyLaunchRoute;
  final Map<String, List<Map<String, Object?>>> runsByAccount = {};
  final Map<String, List<String>> logLinesByAccount = {};

  /// Per-account silent quick-check counters for Aktivita (F6 §5.5).
  final Map<String, int> quickChecksTodayByAccount = {};
  final Map<String, DateTime> lastQuickCheckByAccount = {};
  final Map<String, DateTime> quickChecksDayByAccount = {};

  /// Cached network classification for dynamic scheduling (F6 §7.1, R8a M3).
  /// Desktop and iOS stay `unmetered`; Android refreshes on resume, headless
  /// start, and before each scheduled job run (never blocks a refresh).
  NetworkKind networkKind = core.mobilePlatform() == 'android'
      ? NetworkKind.unknown
      : NetworkKind.unmetered;

  /// Bound by [registerJobs] so `nextRunLabel` reads the active runner's
  /// `nextDueAt(now)` (including 5-minute retry stamps).
  DateTime Function(DateTime now)? activeSchedulerNextDue;

  static NetworkKind parseNetworkKind(String raw) => switch (raw) {
        'unmetered' => NetworkKind.unmetered,
        'metered' => NetworkKind.metered,
        _ => NetworkKind.unknown,
      };

  /// Refreshes [networkKind] from Android `ConnectivityManager`.
  /// On desktop/iOS keeps `unmetered` unless an explicit test [channel]
  /// reports `'metered'` or `'unmetered'`.
  Future<NetworkKind> refreshNetworkKind([AndroidChannel? channel]) async {
    final isAndroid = core.mobilePlatform() == 'android';
    if (!isAndroid && channel == null) {
      networkKind = NetworkKind.unmetered;
      return networkKind;
    }
    try {
      final raw = await (channel ?? const AndroidChannel()).networkKind();
      if (!isAndroid && raw == 'unknown') {
        networkKind = NetworkKind.unmetered;
      } else {
        networkKind = parseNetworkKind(raw);
      }
    } catch (_) {
      networkKind = isAndroid ? NetworkKind.unknown : NetworkKind.unmetered;
    }
    return networkKind;
  }

  /// Union active school-day window across all configured accounts with
  /// `background_refresh == true` (F6 §7.2, R8a N11).
  ActiveDayWindow? deviceActiveDayWindow(DateTime day) {
    if (accountsEnabled && rootDir != null && registry != null) {
      final pairs = <({Map<String, Object?>? cache, Map<String, Object?> cfg})>[];
      for (final acc in registry!.accounts) {
        if (acc.adding) continue;
        final accCfg = acc.id == activeAccountId
            ? config
            : ConfigManager.forAccount(rootDir!, acc.id);
        if (accCfg.get('background_refresh', true) == false) continue;
        final wizStep = int.tryParse('${accCfg.get('wizard_step', -1)}') ?? -1;
        final (hasBak, hasStrava) = core.hasValidCredentials(accCfg.data);
        if (wizStep >= 0 || (!hasBak && !hasStrava)) continue;
        final accCache = acc.id == activeAccountId
            ? data
            : _safeLoadAccountCache(accountDirFor(rootDir!, acc.id));
        pairs.add((cache: accCache, cfg: accCfg.data));
      }
      if (pairs.isNotEmpty) {
        return combinedActiveDayWindow(pairs, day);
      }
    }
    return activeDayWindow(data, config.data, day);
  }

  Map<String, Object?> _safeLoadAccountCache(String dir) {
    try {
      return loadDataCache(dataDir: dir);
    } catch (_) {
      return const {};
    }
  }

  /// Next wake-up alarm for one account's config/cache, or null when disabled.
  DateTime? nextWakeupAlarmForAccount(
    Map<String, Object?> cfgData,
    Map<String, Object?> cacheData,
    DateTime now,
  ) {
    if (cfgData['wakeup_enabled'] != true) return null;
    try {
      final demo = _isDemoCache(cacheData);
      if (demo) return null;
      final tt = <String, Object?>{
        for (final e in _timetableFromCache(cacheData, false).entries)
          e.key: e.value,
      };
      return core.nextWakeupAlarm(
        tt,
        config: cfgData,
        now: now,
        stableBaseline: _stableBaselineFromCache(cacheData),
      )?.alarmDt;
    } catch (_) {
      return null;
    }
  }

  /// Primary account's next wake-up alarm (for off-hours pre-alarm wake, §7.3).
  DateTime? primaryNextAlarm(DateTime now) {
    if (accountsEnabled && rootDir != null && registry != null) {
      final pid = registry!.primaryId;
      if (pid != activeAccountId) {
        try {
          final pCfg = ConfigManager.forAccount(rootDir!, pid);
          final pCache = _safeLoadAccountCache(accountDirFor(rootDir!, pid));
          return nextWakeupAlarmForAccount(pCfg.data, pCache, now);
        } catch (_) {
          return null;
        }
      }
    }
    return nextWakeupAlarmForAccount(config.data, data, now);
  }

  /// Device-level next scheduled check time (F6 §7.3, §7.4).
  DateTime nextScheduledWakeAt(DateTime? lastRun, DateTime now) =>
      nextScheduledWake(
        lastRun,
        config.data,
        deviceActiveDayWindow,
        networkKind,
        now,
        nextAlarm: primaryNextAlarm(now),
      );

  /// Device-level effective check interval at [now] (0 = paused off-hours).
  double effectiveDeviceIntervalMinutes(DateTime now) =>
      effectiveCheckIntervalMinutes(
        config.data,
        deviceActiveDayWindow(now),
        networkKind,
        now,
      );

  /// School-hours interval for the current network (never 0, for `bg_notif_text`, §8.2).
  int schoolHoursIntervalForCurrentNetwork() {
    final fast = effectiveCheckIntervalMinutes(
      config.data,
      (start: DateTime(2000, 1, 1, 0, 0), end: DateTime(2000, 1, 2, 0, 0)),
      networkKind,
      DateTime(2000, 1, 1, 12, 0),
    );
    final n = fast.round();
    return n < 1 ? 1 : n;
  }

  String get _quickCounterKey => activeAccountId ?? '__single__';

  int get quickChecksToday {
    final key = _quickCounterKey;
    final day = quickChecksDayByAccount[key];
    final now = clock.now();
    if (day == null ||
        day.year != now.year ||
        day.month != now.month ||
        day.day != now.day) {
      return 0;
    }
    return quickChecksTodayByAccount[key] ?? 0;
  }

  DateTime? get lastQuickCheck {
    final mem =
        quickChecksToday > 0 ? lastQuickCheckByAccount[_quickCounterKey] : null;
    final saved = demoMode ? null : partUpdatedTime(data, 'quick');
    if (saved != null && (mem == null || saved.isAfter(mem))) return saved;
    return mem;
  }

  void recordSilentQuickCheck(String? accountId, DateTime at) {
    final key = accountId ?? '__single__';
    final prevDay = quickChecksDayByAccount[key];
    final sameDay = prevDay != null &&
        prevDay.year == at.year &&
        prevDay.month == at.month &&
        prevDay.day == at.day;
    quickChecksTodayByAccount[key] =
        sameDay ? (quickChecksTodayByAccount[key] ?? 0) + 1 : 1;
    quickChecksDayByAccount[key] = DateTime(at.year, at.month, at.day);
    lastQuickCheckByAccount[key] = at;
  }

  /// Fired when `primary_id` changes so `PhoneBackground` can poke status
  /// immediately (§8).
  void Function()? onPrimaryChanged;

  /// Fired after account switches so the desktop tray menu updates its label.
  void Function()? onAccountChanged;

  /// Test seam for mobile keystore warm-up (Android Keystore / iOS Keychain).
  Future<void> Function(String accountDir) ensureWarmedFn = (dir) async {
    final plat = core.mobilePlatform();
    if (plat == 'android') {
      await ensureWarmed(dir);
    } else if (plat == 'ios') {
      await ensureIosWarmed(dir);
    }
  };

  bool get accountsEnabled =>
      registry != null && !migrationDegraded && rootDir != null;

  bool get isMultiAccount => accountsEnabled && registry!.accounts.length > 1;

  String? get activeAccountId => accountsEnabled ? registry!.activeId : null;

  String? get primaryAccountId => accountsEnabled ? registry!.primaryId : null;

  AccountInfo? get activeAccount =>
      accountsEnabled ? registry!.activeAccount : null;

  AccountInfo? get primaryAccount =>
      accountsEnabled ? registry!.primaryAccount : null;

  String? get activeAccountDir =>
      accountsEnabled ? accountDirFor(rootDir!, registry!.activeId) : null;

  /// True ONLY when the active account carries `adding: true` in accounts.json (§10.3).
  bool get addingAccount => activeAccount?.adding == true;

  /// True while any operation is in flight that must block account switching,
  /// adding, or deleting (§6).
  bool get isBusyForAccountChange =>
      refreshRunning ||
      sendingExcuses.isNotEmpty ||
      orderRunning ||
      testing.isNotEmpty ||
      aiRunning ||
      earlyRefreshInFlight ||
      backgroundAccountRunning;

  /// Human display label for [acc] (explicit label -> default/numbered fallback).
  String accountDisplayLabel(AccountInfo acc) {
    final trimmed = acc.label.trim();
    if (trimmed.isNotEmpty) return trimmed;
    if (acc.id == defaultAccountId) {
      return Strings.get('account_default_label');
    }
    final list = registry?.accounts ?? const <AccountInfo>[];
    final idx = list.indexWhere((a) => a.id == acc.id);
    return Strings.format('account_numbered_label', {'n': idx >= 0 ? idx + 1 : 2});
  }

  /// Display label for the currently active account (empty in single-file mode).
  String get activeAccountDisplayLabel =>
      activeAccount != null ? accountDisplayLabel(activeAccount!) : '';

  /// Loads (or reloads on switch) all per-account state from scratch (§10.1).
  ///
  /// Both the constructor and [switchAccount] run this single path so a
  /// switched `AppState` matches a freshly constructed `AppState` field for
  /// field (except the documented allow-list).
  void _loadAccount({
    Map<String, Object?>? seedConfig,
    Map<String, Object?>? seedData,
  }) {
    // 1. Reset every non-allow-listed per-account field to cold-start defaults.
    orders.clear();
    pendingOrders.clear();
    ignoredExcuseKeys = {};
    lastIgnoreError = '';
    excuseLog.clear();
    sendingExcuses.clear();
    orderRunning = false;
    aiRunning = false;
    timetableMondayIso = null;
    showStableTimetable = false;
    status = 'idle';
    currentStep = '';
    lastError = null;
    errorDialogPending = false;
    refreshRunning = false;
    cancelRequested = false;
    lastTest = {};
    testing = '';
    lunchHidden = {};
    lunchReasons = {};
    lunchPrefs = '';
    blacklistEditError = '';
    pickedTemplates.clear();
    lunchesSidebarOpen = true;
    lunchToolsOpen = false;
    showPastCalendar = false;
    showPastLunches = false;
    expandedDays.clear();
    drafts.clear();
    wizardStep = 0;
    wizardDismissed = false;
    wizardShown = false;
    wizardVerified.clear();
    wizardEarlyRefreshedFp = null;
    earlyRefreshInFlight = false;
    pendingFullRefresh = false;
    marksPredictions = {};
    marksSelected = null;
    marksEditing = null;
    marksCalcStore.clear();
    plannerTerm = null;
    plannerShowAllPicks = false;
    yearPlanCacheKey = null;
    yearPlanCache = null;
    monthSlotsCacheKey = null;
    monthSlotsCache = null;
    baselineCacheKey = null;
    baselineCache = null;
    lastSnackMessage = '';
    _flights.clear();

    // 2. Bind per-account runs & logLines lists from the allow-listed maps.
    if (accountsEnabled) {
      final accId = registry!.activeId;
      runs = runsByAccount.putIfAbsent(accId, () => <Map<String, Object?>>[]);
      logLines = logLinesByAccount.putIfAbsent(accId, () => <String>[]);
      config = ConfigManager.forAccount(rootDir!, accId);
    } else {
      runs = <Map<String, Object?>>[];
      logLines = <String>[];
      config = ConfigManager();
    }

    if (seedConfig != null) {
      for (final e in seedConfig.entries) {
        try {
          config.set(e.key, e.value);
        } catch (_) {
          // Invalid seed values never break construction.
        }
      }
    }
    if (seedData != null) {
      data = Map<String, Object?>.of(seedData);
    } else {
      try {
        data = loadDataCache(dataDir: activeAccountDir);
      } catch (_) {
        data = {};
      }
    }
    dataRev = 0;
    demoMode = _isDemoCache(data);
    final cachedOrders = data['strava_ordered'];
    if (cachedOrders is Map) {
      for (final e in cachedOrders.entries) {
        orders[canonicalDayKey(e.key)] = '${e.value}';
      }
    }
    webOrders = Map<String, String>.of(orders);
    plannedSkips = loadPlannedSkips(config.data);
    cancelledLunches =
        cancelledLunchDaysFor(config.data, data, webOrdersMap: webOrders);
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
    for (final day in cancelledLunches) {
      if (!'${orders[day]}'.contains('&-1&')) orders.remove(day);
    }
    timetableView = () {
      final v = '${get('timetable_view', 'table')}';
      return (v == 'table' || v == 'list') ? v : 'table';
    }();
    final savedStep = _savedWizardStep;
    if (savedStep > 0) {
      wizardStep = config.get('disclaimer_accepted', false) == true
          ? (savedStep > 1 ? 1 : savedStep)
          : 0;
    }
    if (savedStep >= 0) _seedSchoolPresetDraft(savedStep);
    refreshTokens();
  }

  /// Switches the active account to [targetId] (§10.1).
  ///
  /// Refuses with [account_switch_busy] while [isBusyForAccountChange] is true.
  Future<bool> switchAccount(String targetId, {bool force = false}) async {
    if (!accountsEnabled || rootDir == null) return false;
    if (!force && isBusyForAccountChange) {
      lastSnackMessage = Strings.get('account_switch_busy');
      _emit();
      return false;
    }
    if (registry!.byId(targetId) == null) return false;
    if (targetId == registry!.activeId) return true;
    final targetDir = accountDirFor(rootDir!, targetId);
    await ensureWarmedFn(targetDir);
    registry = AccountManager.setActiveAccount(rootDir!, targetId);
    _loadAccount();
    onAccountChanged?.call();
    _emit();
    return true;
  }

  /// Starts the add-account wizard by creating a provisional `adding: true`
  /// account and switching to it (§10.3).
  Future<bool> beginAddAccount() async {
    if (!accountsEnabled || rootDir == null) return false;
    if (isBusyForAccountChange) {
      lastSnackMessage = Strings.get('account_switch_busy');
      _emit();
      return false;
    }
    final previousId = registry!.activeId;
    final disclaimerAccepted = config.get('disclaimer_accepted', false) == true;
    final initialStep = disclaimerAccepted ? 1 : 0; // stepSchool : stepWelcome
    final created = AccountManager.createProvisionalAccount(
      rootDir!,
      initialWizardStep: initialStep,
    );
    final newDir = accountDirFor(rootDir!, created.account.id);
    await ensureWarmedFn(newDir);
    addingAccountReturnId = previousId;
    registry = created.registry;
    _loadAccount();
    pendingRoute = 'wizard';
    onAccountChanged?.call();
    _emit();
    return true;
  }

  /// Cancels an active add-account wizard (`adding: true` only, §10.3).
  Future<bool> cancelAddAccount() async {
    if (!accountsEnabled || rootDir == null) return false;
    final current = activeAccount;
    if (current == null || !current.adding) return false;
    final cancelId = current.id;
    final returnTo = addingAccountReturnId;
    final prevConfig = config;
    try {
      final next = AccountManager.cancelAddingAccount(
        rootDir!,
        cancelId,
        returnToId: returnTo,
      );
      prevConfig.markDeleted();
      runsByAccount.remove(cancelId);
      logLinesByAccount.remove(cancelId);
      addingAccountReturnId = null;
      registry = next;
      await ensureWarmedFn(accountDirFor(rootDir!, next.activeId));
      _loadAccount();
      pendingRoute = 'today';
      onAccountChanged?.call();
      _emit();
      return true;
    } on SessionBusyError {
      lastSnackMessage = Strings.get('account_delete_busy');
      _emit();
      return false;
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: cancelAddAccount failed: $e');
      return false;
    }
  }

  /// Renames [accountId] (persisted to `accounts.json`, §2.1 & §10.2).
  bool renameAccount(String accountId, String newLabel) {
    if (!accountsEnabled || rootDir == null) return false;
    try {
      registry = AccountManager.renameAccount(rootDir!, accountId, newLabel);
      onAccountChanged?.call();
      if (accountId == primaryAccountId) {
        onPrimaryChanged?.call();
      }
      _emit();
      return true;
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: renameAccount failed: $e');
      return false;
    }
  }

  /// Sets [accountId] as `primary_id` and immediately re-syncs Android
  /// status notification, widget, and wake-up alarms (§8).
  Future<bool> setPrimaryAccount(String accountId) async {
    if (!accountsEnabled || rootDir == null) return false;
    if (registry!.byId(accountId) == null) return false;
    if (registry!.primaryId == accountId) return true;
    await ensureWarmedFn(accountDirFor(rootDir!, accountId));
    registry = AccountManager.setPrimaryAccount(rootDir!, accountId);
    syncAndroidState();
    onPrimaryChanged?.call();
    _emit();
    return true;
  }

  /// Toggles `background_refresh` for any account without switching to it (§7.1).
  Future<bool> setAccountBackgroundRefresh(String accountId, bool enabled) async {
    if (!accountsEnabled || rootDir == null) return false;
    if (registry!.byId(accountId) == null) return false;
    if (accountId == activeAccountId) {
      return save({'background_refresh': enabled});
    }
    try {
      final accDir = accountDirFor(rootDir!, accountId);
      await ensureWarmedFn(accDir);
      final mgr = ConfigManager.forAccount(rootDir!, accountId);
      mgr.setAndSave('background_refresh', enabled);
      _emit();
      return true;
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: setAccountBackgroundRefresh failed: $e');
      return false;
    }
  }

  /// Reads per-account `background_refresh` (defaults to `true`).
  bool accountBackgroundRefresh(String accountId) {
    if (!accountsEnabled || rootDir == null) return true;
    if (accountId == activeAccountId) {
      return get('background_refresh', true) != false;
    }
    try {
      final path = resolvePath('config.json', accountDirFor(rootDir!, accountId));
      if (!File(path).existsSync()) return true;
      final decoded = jsonDecode(File(path).readAsStringSync(encoding: utf8));
      if (decoded is Map && decoded.containsKey('background_refresh')) {
        return decoded['background_refresh'] != false;
      }
    } catch (_) {}
    return true;
  }

  /// Reads lightweight subtitle info `(username, presetId)` for account list rows.
  (String username, String presetId) accountSummary(String accountId) {
    if (!accountsEnabled || rootDir == null) return ('', '');
    if (accountId == activeAccountId) {
      return (
        '${get('bakalari_username', '')}'.trim(),
        '${get('school_preset_id', '')}'.trim(),
      );
    }
    try {
      final path = resolvePath('config.json', accountDirFor(rootDir!, accountId));
      if (!File(path).existsSync()) return ('', '');
      final decoded = jsonDecode(File(path).readAsStringSync(encoding: utf8));
      if (decoded is Map) {
        return (
          '${decoded['bakalari_username'] ?? ''}'.trim(),
          '${decoded['school_preset_id'] ?? ''}'.trim(),
        );
      }
    } catch (_) {}
    return ('', '');
  }

  /// True when deleting [accountId] leaves a pre-update root backup or files
  /// outside its folder behind (§9).
  bool accountDeleteShowsBackupNote(String accountId) {
    if (!accountsEnabled || rootDir == null) return false;
    final info = registry!.byId(accountId);
    if (info == null) return false;
    if (info.migrated) return true;
    final accDir = accountDirFor(rootDir!, accountId);
    if (accountId == activeAccountId) {
      return accountHasOutsideFiles(accDir, config.data);
    }
    try {
      final path = resolvePath('config.json', accDir);
      if (!File(path).existsSync()) return false;
      final decoded = jsonDecode(File(path).readAsStringSync(encoding: utf8));
      if (decoded is Map) {
        return accountHasOutsideFiles(accDir, strObjMap(decoded));
      }
    } catch (_) {}
    return false;
  }

  /// Crash-safe account deletion (§9): switches away first if active, holds
  /// `session.lock`, writes `accounts.json` first, forgets key, deletes only
  /// `<rootDir>/accounts/<targetId>/`, and updates primary/Android state.
  Future<bool> deleteAccount(String targetId) async {
    if (!accountsEnabled || rootDir == null) return false;
    if (registry!.accounts.length <= 1) return false;
    if (isBusyForAccountChange) {
      lastSnackMessage = Strings.get('account_delete_busy');
      _emit();
      return false;
    }
    final targetInfo = registry!.byId(targetId);
    if (targetInfo == null) return false;
    final deletedLabel = accountDisplayLabel(targetInfo);
    ConfigManager? oldLiveConfig;

    // Step 1 (§9): switch away BEFORE deleting so blur/dispose saves finish
    // against the target's own folder.
    if (targetId == registry!.activeId) {
      oldLiveConfig = config;
      final nextId =
          registry!.accounts.firstWhere((a) => a.id != targetId).id;
      final switched = await switchAccount(nextId);
      if (!switched) return false;
    }

    try {
      final res = AccountManager.deleteAccount(
        rootDir!,
        targetId,
        liveConfigManager: oldLiveConfig,
      );
      registry = res.registry;
      runsByAccount.remove(targetId);
      logLinesByAccount.remove(targetId);
      quickChecksTodayByAccount.remove(targetId);
      lastQuickCheckByAccount.remove(targetId);
      quickChecksDayByAccount.remove(targetId);
      if (res.wasPrimary) {
        await ensureWarmedFn(accountDirFor(rootDir!, res.nextPrimaryId));
        syncAndroidState();
        onPrimaryChanged?.call();
      }
      onAccountChanged?.call();
      lastSnackMessage =
          Strings.format('account_deleted', {'name': deletedLabel});
      _emit();
      return true;
    } on SessionBusyError {
      lastSnackMessage = Strings.get('account_delete_busy');
      _emit();
      return false;
    } on Object catch (e) {
      // ignore: avoid_print
      print('Warning: deleteAccount failed: $e');
      return false;
    }
  }

  /// Ensures `primary_id`'s Android Keystore entry is warmed before reading it (§5.3, §8).
  Future<void> ensurePrimaryWarmed() async {
    if (!accountsEnabled || rootDir == null) return;
    await ensureWarmedFn(accountDirFor(rootDir!, registry!.primaryId));
  }

  /// Degraded-mode guard (§4.2): called under `session.lock` right before
  /// refresh, excuse send, or lunch order. If another process finished the
  /// move meanwhile, logs and asks the user to restart instead of running.
  bool checkDegradedMigratedElsewhere() {
    if (!migrationDegraded || rootDir == null) return false;
    if (!hasMultiAccountLayoutOnDisk(rootDir!)) return false;
    final msg = Strings.get('account_migrated_elsewhere');
    // ignore: avoid_print
    print('Warning: $msg');
    lastSnackMessage = msg;
    _emit();
    return true;
  }

  late ConfigManager config;
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
  late List<String> logLines;
  late List<Map<String, Object?>> runs;
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
  bool tutorialAnchored = false;
  bool wizardDismissed = false;
  bool wizardShown = false;
  bool notificationPermissionAsked = false;
  final Map<String, String> wizardVerified = {};
  String? wizardEarlyRefreshedFp;
  bool earlyRefreshInFlight = false;
  bool pendingFullRefresh = false;

  // -- marks UI memory (predictions are what-ifs, never saved) --------------
  Map<String, Map<String, Object?>> marksPredictions = {};
  String? marksSelected;
  String? marksEditing;
  final Map<String, Map<String, String>> marksCalcStore = {};

  // -- planner UI memory ------------------------------------------------------
  String? plannerTerm;
  bool plannerShowAllPicks = false;

  // -- tutorial progress -------------------------------------------------------
  Set<String> tutorialsDoneSession = {};

  // -- update check -------------------------------------------------------------
  Map<String, Object?>? updateInfo;
  bool updateCheckRunning = false;
  String updateDismissed = '';

  // -- caches --------------------------------------------------------------------
  Object? yearPlanCacheKey;
  Object? yearPlanCache;
  Object? monthSlotsCacheKey;
  Map<DateTime, List<PickerSlot>>? monthSlotsCache;
  (int, Map<String, Object?>)? baselineCacheKey;
  Map<(int, int), Object>? baselineCache;

  // -- background jobs ------------------------------------------------------------
  /// Runs a background job (port of `_spawn`). The live app wires this to
  /// run the job on the event loop ([AppStateController]); a bare
  /// [AppState] (unit tests) only records intent and never touches the
  /// network, exactly like the earlier phase-5 stubs.
  void Function(Future<void> Function() job, String name) spawn =
      noSpawn;
  static void noSpawn(Future<void> Function() job, String name) {}

  /// The live app's [spawn]: runs the job on the event loop. Used by the
  /// UI ([AppStateController]) and the phone's headless wake-up alike.
  static void liveSpawn(Future<void> Function() job, String name) {
    // A failing job must never crash the app: the jobs report their own
    // errors, this is the last-resort net (Python: `_spawn`).
    unawaited(job().catchError((Object e, StackTrace s) {
      // ignore: avoid_print
      print('Warning: background job $name failed: $e');
    }));
  }

  /// Factory for [Strakalari] sessions (test seam: tests inject fakes
  /// without touching the network).
  Strakalari Function(
          {void Function(String)? onLog, Map<String, Object?>? configData})
      createApp = _defaultCreateApp;

  static Strakalari _defaultCreateApp(
          {void Function(String)? onLog, Map<String, Object?>? configData}) =>
      Strakalari(onLog: onLog, configData: configData);

  /// Multi-account factory seam for tests (receives explicit [dataDir] and
  /// [rootDir] for both active and background accounts).
  Strakalari Function({
    void Function(String)? onLog,
    Map<String, Object?>? configData,
    String? dataDir,
    String? rootDir,
  })? createAppForAccount;

  /// Builds a [Strakalari] instance scoped to [accountDir] (active or
  /// background account), honouring both [createAppForAccount] and legacy
  /// single-account [createApp] overrides in unit tests.
  Strakalari buildAppForAccount({
    void Function(String)? onLog,
    Map<String, Object?>? configData,
    String? dataDir,
  }) {
    final dir = dataDir ?? activeAccountDir;
    final customMulti = createAppForAccount;
    if (customMulti != null) {
      return customMulti(
        onLog: onLog,
        configData: configData,
        dataDir: dir,
        rootDir: rootDir,
      );
    }
    if (!identical(createApp, _defaultCreateApp) &&
        (dataDir == null || dataDir == activeAccountDir)) {
      return createApp(onLog: onLog, configData: configData);
    }
    return Strakalari(
      onLog: onLog,
      configData: configData,
      dataDir: dir,
      rootDir: rootDir,
    );
  }

  /// AI lunch recommendation seam (defaults to core [recommendLunches];
  /// tests inject fakes without touching the Gemini network API).
  Future<(String, Map<String, String>)> Function(
    Map<Object?, Object?> foodData,
    String pref,
    String apiKey, {
    String model,
    String language,
  }) recommendLunchesFn = recommendLunches;

  /// Gemini transport seam for the key test (Python tests monkeypatch
  /// `gemini.test_api_key`; null = the real HTTPS transport).
  GeminiTransport? geminiTransport;

  /// Optional test seam for `isLunchOrderOpen`.
  bool Function(String day, [DateTime? now])? isLunchOrderOpenOverride;

  /// Optional test seam for `_blacklistPath`.
  String Function()? blacklistPathOverride;

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

  bool _quiet = false;

  void _emit() {
    if (_quiet) return;
    onChanged();
  }

  void _emitProgress() => onProgress();

  /// Active design tokens. Port of `self.tok: Tokens`.
  late Tokens tok;

  /// Same table as [tok]; the feature views read it under this name.
  Tokens get appTokens => tok;

  /// Test seam for environment variable lookup.
  Map<String, String>? envOverride;

  String _env(String name) => (envOverride ?? Platform.environment)[name] ?? '';

  /// Refreshes active tokens and language from config and environment.
  /// Port of `_refresh_tokens()`.
  void refreshTokens() {
    final forced = _env('STRAKALARI_THEME');
    final rawMode = (forced == 'dark' || forced == 'light')
        ? forced
        : '${config.get('theme', 'dark')}';
    final mode = normalizeMode(rawMode);
    var t = tokensFor(mode);
    final compact = config.get('compact_density', false) == true;
    if (compact) {
      t = t.copyWith(pad: 10, gap: 8);
    }
    tok = t;

    try {
      final lang = '${config.get('language', 'cs')}';
      core.setLanguage(lang);
      Strings.lang = (lang == 'en') ? 'en' : 'cs';
    } catch (_) {}
    Strings.isMobile = core.isMobile();
  }

  // -- config ----------------------------------------------------------------------
  Object? get(String key, [Object? defaultValue]) {
    try {
      return config.get(key, defaultValue);
    } catch (_) {
      return defaultValue;
    }
  }

  /// Removes [days] from the cached auto-cancel override list so a freshly
  /// planned skip or newly added free day can cancel again on the next refresh.
  void clearCancelHandledDays(Iterable<String> days) {
    final targets = <String>{
      for (final d in days)
        if (d.trim().isNotEmpty) canonicalDayKey(d),
    };
    if (targets.isEmpty) return;
    try {
      final raw = loadDataCache(dataDir: activeAccountDir)[cancelHandledKey];
      if (raw is! List || raw.isEmpty) return;
      final kept = <String>[
        for (final item in raw)
          if (!targets.contains(canonicalDayKey(item))) '$item',
      ];
      if (kept.length != raw.length) {
        saveDataCache({cancelHandledKey: kept}, dataDir: activeAccountDir);
      }
    } on Object catch (exc) {
      // ignore: avoid_print
      print('Warning: could not update $cancelHandledKey: $exc');
    }
  }

  /// Persists config updates. Returns true only if the write succeeded.
  /// Port of `save()` (callers must branch on the result).
  bool save(Map<String, Object?> updates) {
    final checkFree = updates.containsKey('user_free_days') ||
        updates.containsKey('school_preset_id') ||
        updates.containsKey('forced_school_days') ||
        updates.containsKey('holidays');
    final freeBefore =
        checkFree ? freeLunchDays(config.data) : const <String>{};
    var ok = true;
    for (final e in updates.entries) {
      try {
        config.set(e.key, e.value);
      } catch (err) {
        // ignore: avoid_print
        print(
            'Warning: ignoring invalid config update ${core.pyRepr(e.key)}: $err');
        ok = false;
      }
    }
    try {
      config.save();
    } catch (exc) {
      // ignore: avoid_print
      print('Warning: could not save config: $exc');
      return false;
    }
    if (checkFree) {
      final added = freeLunchDays(config.data).difference(freeBefore);
      if (added.isNotEmpty) clearCancelHandledDays(added);
    }
    if (updates.containsKey('bakalari_url') ||
        updates.containsKey('bakalari_username') ||
        updates.containsKey('bakalari_password')) {
      core.BakalariSessionPool.instance.evict(activeAccountDir ?? rootDir);
    }
    refreshTokens();
    for (final cb in List.of(configListeners)) {
      try {
        cb();
      } catch (exc) {
        // ignore: avoid_print
        print('Warning: config listener failed: $exc');
        // A listener never breaks a save.
      }
    }
    if (updates.keys.any(phoneConfigKeys.contains)) {
      syncAndroidState();
    }
    _emit();
    return ok;
  }

  /// Like [save] without re-rendering (settings field edits).
  /// Port of `save_quiet()`.
  bool saveQuiet(Map<String, Object?> updates) {
    _quiet = true;
    try {
      return save(updates);
    } finally {
      _quiet = false;
    }
  }

  bool automationPaused() {
    // The tray toggles it in its own process: read the file so this
    // window never shows a stale state (falls back to memory).
    try {
      final f = File(config.configPath);
      if (f.existsSync()) {
        final onDisk = jsonDecode(f.readAsStringSync());
        if (onDisk is Map && onDisk.containsKey('automation_paused')) {
          return core.automationPaused(strObjMap(onDisk));
        }
      }
    } catch (_) {}
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

  /// Per-part freshness label for screens (F6 §5.4).
  String updatedLabelFor(String part) {
    if (demoMode) return Strings.get('no_data');
    try {
      return describeCacheForPart(
        data,
        part,
        num.tryParse('${get('cache_ttl_hours', 24)}') ?? 24,
      );
    } catch (_) {
      return updatedLabel;
    }
  }

  static String _shortFreshnessStamp(DateTime when, DateTime now) {
    final hm =
        '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}';
    final sameDay =
        when.year == now.year && when.month == now.month && when.day == now.day;
    if (sameDay) return hm;
    return '${when.day.toString().padLeft(2, '0')}.${when.month.toString().padLeft(2, '0')}. $hm';
  }

  /// Activity & Settings → Diagnostika freshness label (F6 §5.4):
  /// shows `Kontrola: HH:MM · Úplná: DD.MM. HH:MM` when quick is newer than full.
  String get activityUpdatedLabel {
    if (demoMode) return Strings.get('no_data');
    final quick = partUpdatedTime(data, 'quick');
    final full = partUpdatedTime(data, 'full') ?? lastUpdatedTime(data);
    if (quick != null && full != null && quick.isAfter(full)) {
      final now = clock.now();
      return Strings.format('refresh_checked_full', {
        'checked': _shortFreshnessStamp(quick, now),
        'full': _shortFreshnessStamp(full, now),
      });
    }
    return updatedLabel;
  }

  /// Desktop TopBar status tooltip freshness prefix (F6 §5.4, R8a S11).
  String get tooltipUpdatedLabel {
    if (demoMode) return '${Strings.get('last_updated')}: $updatedLabel';
    final checked = lastCheckedTime(data);
    if (checked != null) {
      final now = clock.now();
      return core.t(
        'status_checked',
        lang: Strings.lang,
        args: {'time': _shortFreshnessStamp(checked, now)},
      );
    }
    return '${Strings.get('last_updated')}: $updatedLabel';
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
    return {for (final n in directory.keys) canonSubject(n)};
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
  bool? wakeupAvailableOverride;
  bool get wakeupAvailable =>
      wakeupAvailableOverride ?? (wakeupPhoneBridge != null);

  /// The phone's next [WakeupAlarm], or null. Port of `next_wakeup_alarm()`.
  WakeupAlarm? nextWakeupAlarm([DateTime? now]) {
    if (!wakeupAvailable) return null;
    try {
      final tt = <String, Object?>{
        for (final e in phoneTimetable().entries) e.key: e.value,
      };
      return core.nextWakeupAlarm(
        tt,
        config: Map<String, Object?>.of(config.data),
        now: now,
        stableBaseline: stableBaseline(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Skipped days whose alarm is still ahead, each with the alarm a
  /// restore gives back. Port of `skipped_wakeup_days()`.
  List<(DateTime, WakeupAlarm?)> skippedWakeupDays([DateTime? now]) {
    if (!wakeupAvailable) return [];
    try {
      final tt = <String, Object?>{
        for (final e in phoneTimetable().entries) e.key: e.value,
      };
      return upcomingSkippedDays(
        tt,
        config: Map<String, Object?>.of(config.data),
        now: now,
        stableBaseline: stableBaseline(),
      );
    } catch (_) {
      final cur = now ?? clock.now();
      final today = DateTime(cur.year, cur.month, cur.day);
      final days = skippedDays(Map<String, Object?>.of(config.data))
          .where((d) => !d.isBefore(today))
          .toList()
        ..sort();
      return [for (final d in days) (d, null)];
    }
  }

  /// Hands the widget data and the alarm queue to the phone (a no-op
  /// elsewhere). Always reads from `primary_id` in multi-account mode (§8).
  void syncAndroidState() {
    if (accountsEnabled &&
        rootDir != null &&
        primaryAccountId != activeAccountId) {
      try {
        final pid = primaryAccountId!;
        final pDir = accountDirFor(rootDir!, pid);
        final pCfg = ConfigManager.forAccount(rootDir!, pid);
        final pCache = loadDataCache(dataDir: pDir);
        syncAndroidFrom(pCfg, pCache);
      } catch (_) {
        // Never break a save or a reload.
      }
      return;
    }
    syncAndroidFrom(config, data);
  }

  /// What the phone's background notification shows its overview from.
  /// Always reads from `primary_id` in multi-account mode (§8, S6).
  StatusInputs backgroundStatusInputs() {
    final label = isMultiAccount && primaryAccount != null
        ? accountDisplayLabel(primaryAccount!)
        : null;
    if (accountsEnabled &&
        rootDir != null &&
        primaryAccountId != activeAccountId) {
      final pid = primaryAccountId!;
      final pDir = accountDirFor(rootDir!, pid);
      final pCfg = ConfigManager.forAccount(rootDir!, pid);
      final pCache = loadDataCache(dataDir: pDir);
      return buildStatusInputsFrom(pCfg, pCache, accountLabel: label);
    }
    var pending = 0;
    try {
      pending = demoMode ? 0 : excuseTasks().length;
    } catch (exc) {
      // ignore: avoid_print
      print('Warning: pending excuses unavailable (${exc.runtimeType}: $exc)');
      pending = 0;
    }
    return buildStatusInputsFrom(
      config,
      data,
      webOrdersOverride: webOrders,
      pendingExcusesOverride: pending,
      accountLabel: label,
    );
  }

  /// Re-reads the data cache and reconciles local picks with web truth.
  /// Port of `reload_cache()`.
  void reloadCache() {
    try {
      data = loadDataCache(dataDir: activeAccountDir);
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

  // -- first-run wizard (gating on real credentials) -------------------------------------
  /// Config key holding the step of an unfinished wizard (-1 / absent =
  /// no wizard in progress). Persisted so that leaving the app mid-setup
  /// resumes the wizard instead of counting the setup as finished just
  /// because the first step already saved a login.
  static const String wizardStepKey = 'wizard_step';

  int get _savedWizardStep =>
      int.tryParse('${get(wizardStepKey, -1)}') ?? -1;

  void _saveWizardStep(int step) {
    if (_savedWizardStep == step) return;
    saveQuiet({wizardStepKey: step});
  }

  bool needsSetup() {
    if (wizardDismissed) return false;
    return _savedWizardStep >= 0 || !_hasAnyCredentials();
  }

  bool get setupPending {
    if (wizardDismissed) return false;
    return wizardShown || needsSetup();
  }

  void _seedSchoolPresetDraft(int savedStep) {
    if (drafts.containsKey('wiz:cal_preset')) return;
    final savedPreset = '${config.get('school_preset_id', '')}'.trim();
    if (savedPreset.isEmpty) return;
    if (savedStep > 1 || savedPreset != core.customId) {
      drafts['wiz:cal_preset'] = savedPreset;
    }
  }

  /// The wizard is on screen: remember it across app restarts.
  void wizardOpened() {
    if (wizardDismissed) return;
    wizardShown = true;
    _seedSchoolPresetDraft(_savedWizardStep);
    _saveWizardStep(wizardStep);
  }

  void dismissWizard() {
    wizardDismissed = true;
    tutorialOffer(firstTourId);
    _saveWizardStep(-1);
    _emit();
  }

  void wizardGoto(int step, int stepDone) {
    wizardStep = step.clamp(0, stepDone);
    _saveWizardStep(wizardStep);
    _emit();
  }

  void wizardFinished() {
    final wasAdding = addingAccount;
    wizardDismissed = true;
    wizardStep = 0;
    drafts.removeWhere((k, _) => k.startsWith('wiz:'));
    wizardVerified.clear();
    wizardEarlyRefreshedFp = null;
    if (wasAdding && accountsEnabled && rootDir != null && activeAccountId != null) {
      final n = registry!.accounts.length;
      final fallback = Strings.format('account_numbered_label', {'n': n});
      try {
        registry = AccountManager.finishAddingAccount(
          rootDir!,
          activeAccountId!,
          fallbackLabel: fallback,
        );
      } on Object catch (e) {
        // ignore: avoid_print
        print('Warning: finishAddingAccount failed: $e');
      }
      addingAccountReturnId = null;
      onAccountChanged?.call();
      if (isMultiAccount) {
        tutorialOffer('accounts');
      }
    } else {
      tutorialOffer(firstTourId);
    }
    _saveWizardStep(-1);
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

  /// Applies a route tapped from an Android notification or widget (O8, F4).
  ///
  /// Parses optional `?account=<id>` (§7.2 step 5, §8):
  /// - If `<id>` no longer exists (deleted), stays on the current account and
  ///   opens nothing.
  /// - If `<id>` differs from active (or no `?account=` in multi-account mode
  ///   and active != primary): switches if idle, else shows `account_tap_busy`
  ///   and remembers `(targetId, baseRoute)` to apply once idle.
  /// - Drops the route while [setupPending] is true (wizard stays in charge).
  void applyLaunchRoute(String rawRoute) {
    unawaited(applyLaunchRouteAsync(rawRoute));
  }

  Future<void> applyLaunchRouteAsync(String rawRoute) async {
    if (setupPending) return;
    final trimmed = rawRoute.trim();
    if (trimmed.isEmpty) return;

    final uri = Uri.tryParse(trimmed);
    final basePath = trimmed.split('?').first.split('#').first.trim();
    final queryAccountId = uri?.queryParameters['account']?.trim();

    if (accountsEnabled && registry != null) {
      String? targetAccountId;
      if (queryAccountId != null && queryAccountId.isNotEmpty) {
        if (registry!.byId(queryAccountId) == null) {
          // Deleted account: stay on the current account and open nothing (§7.2).
          return;
        }
        targetAccountId = queryAccountId;
      } else if (isMultiAccount && activeAccountId != primaryAccountId) {
        // Status notification / widget / alarm carry no ?account=: target primary (§8).
        targetAccountId = primaryAccountId;
      }

      if (targetAccountId != null && targetAccountId != activeAccountId) {
        if (isBusyForAccountChange) {
          // Don't open the target screen on the wrong account; queue & hint (§7.2).
          final targetInfo = registry!.byId(targetAccountId);
          final name = targetInfo != null ? accountDisplayLabel(targetInfo) : '';
          pendingBusyLaunchRoute = (targetAccountId, basePath);
          lastSnackMessage =
              Strings.format('account_tap_busy', {'name': name});
          _emit();
          return;
        }
        final switched = await switchAccount(targetAccountId);
        if (!switched) return;
        if (setupPending) return;
      }
    }

    _navigateToLaunchBase(basePath, trimmed);
  }

  void _navigateToLaunchBase(String basePath, String rawRoute) {
    if (basePath == 'alarm') {
      settingsSection = 'alarm';
      settingsOpen = true;
      pendingRoute = 'settings';
      _emit();
      return;
    }
    pendingRoute = routeForLocation(rawRoute);
    _emit();
  }

  /// Applies a queued notification/widget tap once all busy operations settle.
  void _maybeApplyPendingLaunchRoute() {
    final pending = pendingBusyLaunchRoute;
    if (pending == null || isBusyForAccountChange) return;
    pendingBusyLaunchRoute = null;
    final (targetId, basePath) = pending;
    unawaited(applyLaunchRouteAsync('$basePath?account=$targetId'));
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
    final startup = ref.read(startupLayoutProvider);
    final state = AppState(
      layoutResult: startup?.layout,
      rootDir: startup?.rootDir,
    );
    state.onChanged = () {
      if (!ref.mounted) return;
      // ignore: avoid_self_assignment
      this.state = this.state;
    };
    state.onProgress = state.onChanged;
    state.spawn = AppState.liveSpawn;
    return state;
  }

  /// True while this Riverpod provider container is still mounted.
  bool get isMounted => ref.mounted;

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
