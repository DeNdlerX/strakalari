// The app's scheduler: core's `PeriodicRunner` with the window's jobs.
//
// Port of `_register_jobs` (flet_ui/app.py). Both the running app
// (`startPlatformServices`) and the phone's headless wake-up
// (`runHeadlessTick`) build their runner here, so the jobs, the gates in
// `AppState.scheduledRefreshJob`, the first-run anchor and the result
// hook are one piece of code.
import 'package:clock/clock.dart';
import 'package:strakalari_core/strakalari_core.dart';

import '../controllers/app_state.dart';

/// Python `float(get("check_interval_minutes", 60) or 60)` (the runner's
/// interval; core clamps it to at least 1). A string Python's `float()`
/// would reject falls back to 60 instead of raising.
double checkIntervalMinutes(Object? raw) {
  if (raw == null || raw == false || raw == 0 || raw == '') return 60.0;
  if (raw == true) return 1.0;
  if (raw is num) return raw.toDouble();
  final parsed = double.tryParse('$raw'.trim());
  return (parsed == null || parsed == 0) ? 60.0 : parsed;
}

/// `_startup_seed`: the last successful refresh from the loaded cache
/// (null = unknown: refresh on start). In multi-account mode (§7.2 step 6),
/// anchors to the oldest `last_updated` among configured accounts with
/// `background_refresh == true` (returning null if any such account is
/// stale/unknown or failed its last scheduled run). Never throws.
DateTime? schedulerStartupSeed(AppState state) {
  try {
    if (state.accountsEnabled && state.rootDir != null && state.registry != null) {
      final rootDir = state.rootDir!;
      DateTime? oldest;
      var foundEligible = false;
      for (final acc in state.registry!.accounts) {
        if (acc.adding) continue;
        final accDir = accountDirFor(rootDir, acc.id);
        final accCfg = acc.id == state.activeAccountId
            ? state.config
            : ConfigManager.forAccount(rootDir, acc.id);
        if (accCfg.get('background_refresh', true) == false) continue;
        final wizStep = int.tryParse('${accCfg.get('wizard_step', -1)}') ?? -1;
        final (hasBak, hasStrava) = hasValidCredentials(accCfg.data);
        if (wizStep >= 0 || (!hasBak && !hasStrava)) continue;
        foundEligible = true;
        final cache = acc.id == state.activeAccountId
            ? state.data
            : loadDataCache(dataDir: accDir);
        if ('${cache[scheduledRefreshFailedKey] ?? ''}'.trim().isNotEmpty) {
          return null;
        }
        final seed = startupSeed(cache);
        if (seed == null) return null;
        if (oldest == null || seed.isBefore(oldest)) {
          oldest = seed;
        }
      }
      if (foundEligible) return oldest;
    }
    if ('${state.data[scheduledRefreshFailedKey] ?? ''}'.trim().isNotEmpty) {
      return null;
    }
    return startupSeed(state.data);
  } on Object {
    return null;
  }
}

/// `_register_jobs(state, paused)`: a runner (not started) with the
/// `refresh` and `update` jobs.
///
/// [stopped] ends the refresh job's wait at shutdown (Python:
/// `runner.wait_stopped`). [keepAwake] holds the phone's CPU awake around
/// the refresh (Python: `KeepAwake(minutes=30)`; a no-op elsewhere).
/// [intervalProvider] re-reads the interval every tick (accepted
/// deviation C-N4: Python read it once at registration).
PeriodicRunner registerJobs(
  AppState state, {
  bool Function()? paused,
  bool Function()? stopped,
  Future<T> Function<T>(Future<T> Function() body)? keepAwake,
  double? Function()? intervalProvider,
}) {
  void onResult(JobResult result) {
    // Scheduler heartbeat: track it for the "next run" label.
    state.schedulerLastRun = clock.now();
    if (!result.ok && !result.reported) {
      state.scheduledJobFailed(result.name, result.error);
    }
  }

  final runner = PeriodicRunner(
    intervalMinutes:
        checkIntervalMinutes(state.get('check_interval_minutes', 60)),
    onResult: onResult,
    // Anchor the first auto-run to the last successful refresh; with no
    // or an overdue cache (null) the app refreshes on start.
    lastRun: schedulerStartupSeed(state),
    paused: paused,
    intervalProvider: intervalProvider,
  );
  if (runner.lastRun != null) {
    // The "next run" label derives from this; seed it so it is right
    // from launch instead of showing "—" until the first tick.
    state.schedulerLastRun = runner.lastRun;
  }
  runner.addJob('refresh', () {
    Future<String> job() => state.scheduledRefreshJob(stopped: stopped);
    final hold = keepAwake;
    return hold == null ? job() : hold<String>(job);
  });
  // A new release is announced also while the app only runs in the
  // background (phone) or tray; GitHub is asked at most once a day.
  runner.addJob(
      'update',
      () => state.startUpdateCheck()
          ? 'update check started'
          : 'update check busy');
  return runner;
}
