// Background work: refresh runs, connection tests, update checks, log.
//
// Port of strakalari/flet_ui/state_activity.py (`ActivityMixin`). Pure
// presentation logic (labels, banners, error reports, run records) is a
// complete port; the threaded pipeline (`_refresh_work`, `_test_work`,
// `_update_work`, `_excuse_worker`, network sessions) runs in phase 7 —
// the entry points below validate, set flags and log exactly like the
// originals and hand off to the documented seams.
//
// All timestamps use package:clock (`clock.now()`), never
// `DateTime.now()` directly.
part of 'app_state.dart';

/// True when [cache] is due for a scheduled refresh under [intervalMinutes]
/// (F6 §7.6):
/// - Always true if `scheduled_refresh_failed` is set.
/// - When [intervalMinutes] <= 0 (paused off-hours): true only if [nextAlarm]
///   is within 30 min (pre-alarm tick) and hasn't run since `nextAlarm - 30 min`.
/// - Otherwise compares [startupSeed] (`lastCheckedTime`) against
///   `intervalMinutes - tolerance`, where `tolerance` is 5 min for >=30 min
///   intervals and `(interval * 0.1).clamp(0.25, 2.0)` for faster intervals.
bool isAccountDueForRefresh(
  Map<String, Object?> cache,
  double intervalMinutes,
  DateTime now, {
  DateTime? nextAlarm,
}) {
  final failedStamp = '${cache[scheduledRefreshFailedKey] ?? ''}'.trim();
  if (failedStamp.isNotEmpty) return true;
  final last = startupSeed(cache, now);
  if (intervalMinutes <= 0) {
    if (nextAlarm == null) return false;
    final preAlarm = nextAlarm.subtract(const Duration(minutes: 30));
    if (now.isBefore(preAlarm)) return false;
    return last == null || last.isBefore(preAlarm);
  }
  if (last == null) return true;
  final tolerance = intervalMinutes >= 30.0
      ? 5.0
      : (intervalMinutes * 0.1).clamp(0.25, 2.0);
  final thresholdMin = (intervalMinutes - tolerance).clamp(0.0, double.infinity);
  final thresholdMs = (thresholdMin * 60000).round();
  return now.difference(last).inMilliseconds >= thresholdMs;
}

class _AccountRefreshContext {
  final String? accountId;
  final String accountLabel;
  final String? accountDir;
  final ConfigManager configManager;
  final List<Map<String, Object?>> runsList;
  final List<String> logLinesList;
  final bool isActiveScreen;
  final bool isScheduled;

  const _AccountRefreshContext({
    required this.accountId,
    required this.accountLabel,
    required this.accountDir,
    required this.configManager,
    required this.runsList,
    required this.logLinesList,
    required this.isActiveScreen,
    required this.isScheduled,
  });
}

/// Activity/background-work logic. Port of `ActivityMixin`.
extension ActivityLogic on AppState {
  /// Adds a log line (capped at 300). Port of `log()`.
  void addLog(String message) {
    logLines.add('[${fmtClock(clock.now())}] $message');
    if (logLines.length > 300) {
      logLines.removeRange(0, logLines.length - 300);
    }
    _emit();
  }

  void clearLog() {
    logLines.clear();
    _emit();
  }

  /// Records a failure with full diagnostics and queues the popup.
  /// The Shell shows [lastError] in an error dialog with a copy button.
  /// Never throws. Port of `report_error()`.
  Map<String, Object?> reportError(
    String operation, [
    Object? exc,
    String message = '',
    String tracebackStr = '',
    Map<String, Object?>? extra,
  ]) =>
      _reportErrorScoped(
        operation,
        exc: exc,
        message: message,
        tracebackStr: tracebackStr,
        extra: extra,
        targetConfig: config.data,
        targetLogLines: logLines,
        targetDataDir: activeAccountDir,
        updateUi: true,
      );

  Map<String, Object?> _reportErrorScoped(
    String operation, {
    Object? exc,
    String message = '',
    String tracebackStr = '',
    Map<String, Object?>? extra,
    required Map<String, Object?> targetConfig,
    required List<String> targetLogLines,
    required String? targetDataDir,
    required bool updateUi,
  }) {
    Map<String, Object?> report;
    try {
      final summary = message.trim().isNotEmpty
          ? message.trim()
          : shortSummary(exc);
      var userMessage = '';
      if (exc is UserError && exc.message.trim().isNotEmpty) {
        userMessage = exc.message.split('\n').first.trim();
        if (userMessage.length > 300) {
          userMessage = userMessage.substring(0, 300);
        }
      }
      if (userMessage.isEmpty && isTimeoutError(exc)) {
        userMessage = timeoutUserMessage();
      }
      var tb = tracebackStr.trim();
      if (tb.isEmpty && exc != null) tb = currentTraceback(exc);
      // Tail taken before the traceback lands in the live log: the
      // report carries the traceback on its own.
      final tail = List<String>.of(targetLogLines.length > logTailLines
          ? targetLogLines.sublist(targetLogLines.length - logTailLines)
          : targetLogLines);
      if (tb.isNotEmpty) {
        final stamp = fmtClock(clock.now());
        final tbLines = tb.split('\n');
        final last = tbLines.length > 25
            ? tbLines.sublist(tbLines.length - 25)
            : tbLines;
        for (final line in last) {
          targetLogLines.add('[$stamp] ${line.trimRight()}');
        }
        if (targetLogLines.length > 500) {
          targetLogLines.removeRange(0, targetLogLines.length - 500);
        }
      }
      Map<String, Object?> configData = {};
      try {
        configData = Map<String, Object?>.of(targetConfig);
      } catch (_) {
        configData = {};
      }
      report = buildReport(
        operation,
        summary,
        tracebackStr: tb,
        logTail: tail,
        config: configData,
        extra: extra,
        userMessage: userMessage,
        dataDir: targetDataDir,
        rootDir: rootDir,
      );
      try {
        // ignore: avoid_print
        print('Error report:\n${formatReport(report)}');
      } catch (_) {
        // Reporting must not hide the original error.
      }
    } catch (_) {
      report = {
        'at': fmtDay(clock.now()),
        'operation': operation.isEmpty ? '?' : operation,
        'summary': message.isEmpty ? 'unknown error' : message,
        'traceback': '',
        'log_tail': <String>[],
        'config': <String, Object?>{},
        // Fail closed: the redactor itself crashed, so raw extra
        // must not be stored or pasted.
        'context': <String, Object?>{},
        'extra': <String, Object?>{},
        'user_message': '',
      };
    }
    if (updateUi) {
      lastError = report;
      status = 'error';
      errorDialogPending = true;
      _emit();
    }
    return report;
  }

  /// The copy-pasteable diagnostics bundle ('' when no error).
  String errorReportText() {
    final err = lastError;
    if (err == null) return '';
    try {
      return formatReport(err);
    } catch (_) {
      return '';
    }
  }

  /// Marks the queued popup as shown (called by the Shell).
  /// Deliberately no emit: the caller is already rendering.
  void acknowledgeError() {
    errorDialogPending = false;
  }

  /// The label of a manual send in flight ('' when none is).
  String get sendingLabel {
    if (sendingExcuses.isNotEmpty) return Strings.get('excuse_sending');
    if (orderRunning) return Strings.get('orders_sending');
    return '';
  }

  String statusKind() {
    if (refreshRunning || sendingLabel.isNotEmpty) return 'working';
    if (status == 'error') return 'error';
    if (runs.isNotEmpty && runs.last['ok'] == true) return 'ok';
    return 'idle';
  }

  String get lastRunLabel {
    if (runs.isEmpty) return '—';
    final last = runs.last;
    final when =
        '${last['finished'] ?? last['started'] ?? '—'}';
    final mark = last['ok'] == true ? '✓' : '✗';
    return '$mark $when';
  }

  String get nextRunLabel {
    if (schedulerLastRun == null) return '—';
    try {
      final now = clock.now();
      final due = activeSchedulerNextDue?.call(now) ??
          nextScheduledWakeAt(schedulerLastRun, now);
      final dd = due.day.toString().padLeft(2, '0');
      final mm = due.month.toString().padLeft(2, '0');
      final hh = due.hour.toString().padLeft(2, '0');
      final mi = due.minute.toString().padLeft(2, '0');
      return '$dd.$mm. $hh:$mi';
    } catch (_) {
      return '—';
    }
  }

  /// Release info to show, or null (up to date / dismissed).
  Map<String, Object?>? get updateBanner {
    final info = updateInfo;
    if (info == null) return null;
    try {
      if (!updateAvailable(info)) return null;
    } catch (_) {
      return null;
    }
    if (updateDismissed == '${info['version'] ?? ''}') return null;
    return info;
  }

  void dismissUpdate() {
    if (updateInfo != null) {
      updateDismissed = '${updateInfo!['version'] ?? ''}';
    }
    _emit();
  }

  /// 'stable' or 'beta' (beta also offers stable releases).
  String get updateChannel {
    try {
      return normalizeChannel(get('update_channel') ?? defaultChannel());
    } catch (_) {
      return 'stable';
    }
  }

  /// Persists the channel and re-evaluates the update banner.
  bool setUpdateChannel(String channel) {
    channel = normalizeChannel(channel);
    if (!save({'update_channel': channel})) return false;
    updateDismissed = '';
    try {
      final cached = loadCached(channel);
      updateInfo =
          (cached != null && updateAvailable(cached)) ? cached : null;
    } catch (_) {
      updateInfo = null;
    }
    if (!startUpdateCheck()) _emit();
    return true;
  }

  /// Fetches the latest release in the background. False if busy.
  /// Phase 7 performs the network check and clears `updateCheckRunning`;
  /// until then the flag stays claimed exactly like the original's
  /// in-flight window. Port of `start_update_check()`.
  bool startUpdateCheck([bool force = false]) {
    if (updateCheckRunning) return false;
    updateCheckRunning = true;
    _emit();
    spawn(() => _updateWork(force), 'strakalari-update-check');
    return true;
  }

  Future<void> _updateWork(bool force) async {
    try {
      final info = await checkForUpdates(force: force, channel: updateChannel);
      if (info != null && updateAvailable(info)) {
        updateInfo = info;
        final prefs = get('notifications', {});
        notifyNewRelease(
            info, prefs is Map ? prefs.cast<String, Object?>() : null);
      } else if (force || info != null) {
        // Manual re-check with no newer release clears a stale banner.
        updateInfo = null;
        updateDismissed = '';
      }
    } catch (_) {
      // Update checks never surface errors.
    } finally {
      updateCheckRunning = false;
      _emit();
    }
  }

  bool _hasUnconfirmedForAccount(ConfigManager accCfg, String? accDir) {
    try {
      final histPath = resolvePath(
        '${accCfg.get('already_excused_file', './already_excused_lessons.json')}',
        accDir,
      );
      return loadUnconfirmed(histPath, utf8).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// The scheduler's refresh job (§7.2): runs due accounts sequentially through
  /// `runRefresh` (primary first, then active, then remaining), respecting
  /// per-account `background_refresh`, the 20/28-minute pass budget, and
  /// per-account failure isolation.
  Future<String> scheduledRefreshJob({
    Duration maxWait = const Duration(minutes: 30),
    Duration passBudget = const Duration(minutes: 20),
    Duration passHardCap = const Duration(minutes: 28),
    bool forceAll = false,
    bool Function()? stopped,
  }) async {
    schedulerLastRun = clock.now();
    if (!accountsEnabled || rootDir == null) {
      return _scheduledSingleAccountRefresh(
        maxWait: maxWait,
        forceAll: forceAll,
        stopped: stopped,
      );
    }

    final reg = AccountRegistry.load(rootDir!) ?? registry!;
    registry = reg;

    // Order: primary_id first, then active_id (if different), then remaining (§7.2 step 2).
    final ordered = <AccountInfo>[];
    final seen = <String>{};
    void addIfFound(String id) {
      final info = reg.byId(id);
      if (info != null && seen.add(info.id)) ordered.add(info);
    }

    addIfFound(reg.primaryId);
    addIfFound(reg.activeId);
    for (final acc in reg.accounts) {
      if (seen.add(acc.id)) ordered.add(acc);
    }

    final passStart = clock.now();
    var anyFailed = false;
    var leftForNextRun = false;
    var ranAny = false;

    for (var i = 0; i < ordered.length; i++) {
      if (stopped?.call() ?? false) {
        return 'refresh stopped at shutdown';
      }
      final acc = ordered[i];
      if (acc.adding) continue;
      final accDir = accountDirFor(rootDir!, acc.id);
      await ensureWarmedFn(accDir);
      final isActive = acc.id == activeAccountId;
      final accCfg =
          isActive ? config : ConfigManager.forAccount(rootDir!, acc.id);
      if (accCfg.get('background_refresh', true) == false) continue;
      final wizStep = int.tryParse('${accCfg.get('wizard_step', -1)}') ?? -1;
      final (hasBak, hasStrava) = core.hasValidCredentials(accCfg.data);
      if (wizStep >= 0 || (!hasBak && !hasStrava)) continue;
      if (isActive && setupPending) continue;

      final now = clock.now();
      Map<String, Object?> accCache;
      try {
        accCache = loadDataCache(dataDir: accDir);
      } catch (_) {
        accCache = const {};
      }
      if (!forceAll) {
        final accWindow = activeDayWindow(accCache, accCfg.data, now);
        final accInterval = effectiveCheckIntervalMinutes(
            accCfg.data, accWindow, networkKind, now);
        final accAlarm = nextWakeupAlarmForAccount(accCfg.data, accCache, now);
        if (!isAccountDueForRefresh(
            accCache, accInterval, now, nextAlarm: accAlarm)) {
          continue;
        }
      }

      // Pass budget check (§7.2 step 4): start no new account past 20 minutes.
      final elapsed = clock.now().difference(passStart);
      if (elapsed >= passBudget) {
        leftForNextRun = true;
        break;
      }
      final hardLeft = passHardCap - elapsed;
      final effectiveWait = hardLeft < maxWait
          ? (hardLeft.isNegative || hardLeft.inSeconds < 1
              ? const Duration(seconds: 1)
              : hardLeft)
          : maxWait;

      final String runScope;
      final bool quickOutbox;
      final bool isScheduledRun;
      if (forceAll) {
        runScope = 'all';
        quickOutbox = false;
        isScheduledRun = false;
      } else {
        final choice = chooseScheduledScope(
          accCfg.data,
          accCache,
          now,
          hasPendingExcuses: pendingExcuseTasksFor(accCfg, accCache).isNotEmpty,
          hasUnconfirmed: _hasUnconfirmedForAccount(accCfg, accDir),
        );
        runScope = choice.scope;
        quickOutbox = choice.quickOutbox;
        isScheduledRun = true;
      }

      ranAny = true;
      if (isActive) {
        if (refreshRunning) continue;
        final activeRuns = runs;
        final before = activeRuns.isEmpty ? null : activeRuns.last;
        if (!startRefresh(runScope, false, isScheduledRun, quickOutbox)) {
          continue;
        }
        final deadline = clock.now().add(effectiveWait);
        while (refreshRunning) {
          if (stopped?.call() ?? false) {
            return 'refresh still running at shutdown';
          }
          if (!clock.now().isBefore(deadline)) {
            throw StateError(
                'refresh still running after ${effectiveWait.inMinutes} min');
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final last = activeRuns.isEmpty ? null : activeRuns.last;
        if (last != null && !identical(last, before) && last['ok'] != true) {
          if (last['cancelled'] != true) {
            anyFailed = true;
          }
        }
      } else {
        final ok = await _refreshBackgroundAccount(
          acc,
          accCfg,
          scope: runScope,
          isScheduled: isScheduledRun,
          quickOutbox: quickOutbox,
          stopped: stopped,
        );
        if (!ok) {
          anyFailed = true;
        }
      }
    }

    if (leftForNextRun) {
      // Unreported JobFailed so the runner retries in ~5 minutes without a toast (§7.2 step 4).
      throw const JobFailed('accounts left for the next run');
    }
    if (anyFailed) {
      throw const JobFailed('one or more accounts failed refresh');
    }
    return ranAny ? 'refresh finished' : 'skipped (no due accounts)';
  }

  /// Desktop tray "Obnovit data" (§7.2 step 8): refreshes all configured
  /// `background_refresh`-enabled accounts sequentially (due or not), falling
  /// back to the active account if none are enabled.
  Future<void> trayRefreshAll() async {
    if (!accountsEnabled || rootDir == null) {
      startRefresh('all');
      return;
    }
    final reg = AccountRegistry.load(rootDir!) ?? registry!;
    var hasEnabled = false;
    for (final acc in reg.accounts) {
      if (acc.adding) continue;
      final accCfg = acc.id == activeAccountId
          ? config
          : ConfigManager.forAccount(rootDir!, acc.id);
      if (accCfg.get('background_refresh', true) == false) continue;
      final wizStep = int.tryParse('${accCfg.get('wizard_step', -1)}') ?? -1;
      final (hasBak, hasStrava) = core.hasValidCredentials(accCfg.data);
      if (wizStep >= 0 || (!hasBak && !hasStrava)) continue;
      hasEnabled = true;
      break;
    }
    if (!hasEnabled) {
      startRefresh('all');
      return;
    }
    try {
      await scheduledRefreshJob(forceAll: true);
    } on JobFailed {
      // Already reported per account.
    }
  }

  Future<String> _scheduledSingleAccountRefresh({
    required Duration maxWait,
    bool forceAll = false,
    bool Function()? stopped,
  }) async {
    if (setupPending) return 'skipped (setup not finished)';
    if (refreshRunning) return 'skipped (a refresh is already running)';
    if (demoMode && !_hasCredentials()) {
      return 'skipped (no credentials configured)';
    }
    final now = clock.now();
    final String runScope;
    final bool quickOutbox;
    final bool isScheduledRun;
    if (forceAll) {
      runScope = 'all';
      quickOutbox = false;
      isScheduledRun = false;
    } else {
      final choice = chooseScheduledScope(
        config.data,
        data,
        now,
        hasPendingExcuses: pendingExcuseTasksFor(config, data).isNotEmpty,
        hasUnconfirmed: _hasUnconfirmedForAccount(config, activeAccountDir),
      );
      runScope = choice.scope;
      quickOutbox = choice.quickOutbox;
      isScheduledRun = true;
    }
    final before = runs.isEmpty ? null : runs.last;
    if (!startRefresh(runScope, false, isScheduledRun, quickOutbox)) {
      // Another refresh is running: fresh data is on its way.
      return 'refresh busy';
    }
    final deadline = clock.now().add(maxWait);
    while (refreshRunning) {
      if (stopped?.call() ?? false) return 'refresh still running at shutdown';
      if (!clock.now().isBefore(deadline)) {
        throw StateError(
            'refresh still running after ${maxWait.inMinutes} min');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final last = runs.isEmpty ? null : runs.last;
    if (last != null && !identical(last, before) && last['ok'] != true) {
      if (last['cancelled'] != true) {
        // The worker already logged and notified the failure.
        throw JobFailed('${last['detail'] ?? 'refresh failed'}');
      }
    }
    return 'refresh finished';
  }

  /// Refreshes a non-active account through the EXACT same `runRefresh`
  /// pipeline and shared [handleRefreshResult] handler (§7.2 step 4, M6).
  /// Returns true when the run succeeded (or was cancelled / low-balance only).
  Future<bool> _refreshBackgroundAccount(
    AccountInfo acc,
    ConfigManager accCfg, {
    String scope = 'all',
    required bool isScheduled,
    bool quickOutbox = false,
    bool Function()? stopped,
  }) async {
    final accDir = accountDirFor(rootDir!, acc.id);
    final accRuns =
        runsByAccount.putIfAbsent(acc.id, () => <Map<String, Object?>>[]);
    final accLogs = logLinesByAccount.putIfAbsent(acc.id, () => <String>[]);
    final label = isMultiAccount ? accountDisplayLabel(acc) : '';
    final ctx = _AccountRefreshContext(
      accountId: acc.id,
      accountLabel: label,
      accountDir: accDir,
      configManager: accCfg,
      runsList: accRuns,
      logLinesList: accLogs,
      isActiveScreen: false,
      isScheduled: isScheduled,
    );

    backgroundAccountRunning = true;
    final started = clock.now();
    var okOrBenign = true;
    try {
      await ensureWarmedFn(accDir);
      var ran = false;
      await withSessionLockAsync((held) async {
        if (!held) {
          _appendAccountLog(ctx, Strings.get('session_busy'));
          _recordRunEntry(ctx, started, scope, false,
              Strings.get('session_busy'),
              skipped: true);
          return;
        }
        ran = true;
        okOrBenign = await _executeRefreshForContext(
          ctx,
          scope: scope,
          started: started,
          pauseAutomation: false,
          quickOutbox: quickOutbox,
          cancelledLunchDays:
              cancelledLunchDaysFor(accCfg.data, _safeLoadCache(accDir)),
          keptLunchDays: const <String>{},
          lunchPrompt: '',
          isCancelled: () => stopped?.call() ?? false,
        );
      });
      if (!ran) return true;
      return okOrBenign;
    } finally {
      backgroundAccountRunning = false;
      // Reload screen if the user switched onto this account while it refreshed (§6).
      if (activeAccountId == acc.id) {
        reloadCache();
      }
      _maybeApplyPendingLaunchRoute();
    }
  }

  Map<String, Object?> _safeLoadCache(String? dir) {
    try {
      return loadDataCache(dataDir: dir);
    } catch (_) {
      return const {};
    }
  }

  /// Starts a refresh run. Returns false when busy.
  /// When [pauseAutomation] is true (O6 early wizard refresh), the run uses an
  /// in-memory `automation_paused: true` config copy without mutating saved
  /// config. Port of `start_refresh()`.
  bool startRefresh([
    String scope = 'all',
    bool pauseAutomation = false,
    bool isScheduled = false,
    bool quickOutbox = false,
  ]) {
    if (!claimFlight('refresh_running')) return false;
    if (!refreshScopes.contains(scope)) {
      scope = 'all';
    }
    cancelRequested = false;
    status = 'working';
    currentStep = '';
    refreshRunning = true;
    earlyRefreshInFlight = pauseAutomation;
    _emit();
    spawn(
      () => _refreshWork(
        scope,
        pauseAutomation: pauseAutomation,
        isScheduled: isScheduled,
        quickOutbox: quickOutbox,
      ),
      'strakalari-refresh',
    );
    return true;
  }

  /// Called when the user finishes the setup wizard.
  /// If an early paused Bakaláři refresh is still running, queues one normal
  /// `'all'` refresh to start once the early run releases the session lock and
  /// returns true (so the wizard shows `wiz_finishing_refresh`, not
  /// `already_running`). Otherwise starts `'all'` immediately.
  bool finishWizardRefresh() {
    if (earlyRefreshInFlight) {
      pendingFullRefresh = true;
      return true;
    }
    return startRefresh('all');
  }

  /// Background refresh: the shared core pipeline + UI bookkeeping.
  /// Port of `_refresh_work()`.
  Future<void> _refreshWork(
    String scope, {
    bool pauseAutomation = false,
    bool isScheduled = false,
    bool quickOutbox = false,
  }) async {
    final tokenAccountId = activeAccountId;
    final tokenDir = activeAccountDir;
    final tokenCfg = config;
    final tokenRuns = runs;
    final tokenLogs = logLines;
    final tokenLabel = isMultiAccount ? activeAccountDisplayLabel : '';
    try {
      final started = clock.now();
      if (demoMode && !_hasAnyCredentials()) {
        // No login yet (fresh install / setup not finished): abort before
        // logging in. Recorded as a failed run, never a popup.
        workerLog(Strings.get('missing_credentials_log'));
        finishRun(started, scope, false,
            'missing credentials (setup not finished)');
        return;
      }
      if (tokenDir != null) {
        await ensureWarmedFn(tokenDir);
      }
      // One refresh at a time across processes: the tray runs its own
      // scheduler, and two parallel runs would both log in, both auto-send
      // and overwrite each other's cache.
      var ran = false;
      try {
        await withSessionLockAsync((held) async {
          if (held) {
            if (checkDegradedMigratedElsewhere()) {
              ran = true;
              finishRun(started, scope, false,
                  Strings.get('account_migrated_elsewhere'),
                  skipped: true);
              return;
            }
            ran = true;
            await _refreshLocked(
              scope,
              started,
              pauseAutomation: pauseAutomation,
              isScheduled: isScheduled,
              quickOutbox: quickOutbox,
              tokenAccountId: tokenAccountId,
              tokenDir: tokenDir,
              tokenCfg: tokenCfg,
              tokenRuns: tokenRuns,
              tokenLogs: tokenLogs,
              tokenLabel: tokenLabel,
            );
          }
        });
      } catch (e) {
        // The lock itself failed (not a refresh error): fail loudly.
        if (!ran) {
          final detail = ActivityLogic.failureDetail(e);
          workerLog(Strings.format('refresh_failed_log', {'detail': detail}));
          reportError('refresh ($scope)', e, detail, '', {'scope': scope});
          finishRun(started, scope, false, detail);
          return;
        }
        rethrow;
      }
      if (ran) return;
      workerLog(Strings.get('session_busy'));
      // Not a failure: the other process is refreshing right now.
      finishRun(started, scope, false, Strings.get('session_busy'),
          skipped: true);
    } finally {
      if (pauseAutomation) {
        // Runs only after withSessionLockAsync has released the OS lock, so a
        // queued full Finish refresh never collides with the early run's lock.
        earlyRefreshInFlight = false;
        if (pendingFullRefresh) {
          pendingFullRefresh = false;
          startRefresh('all');
        }
      }
      _maybeApplyPendingLaunchRoute();
    }
  }

  /// The refresh proper; runs while the session lock is held.
  /// Port of `_refresh_locked()`.
  Future<void> _refreshLocked(
    String scope,
    DateTime started, {
    bool pauseAutomation = false,
    bool isScheduled = false,
    bool quickOutbox = false,
    String? tokenAccountId,
    String? tokenDir,
    ConfigManager? tokenCfg,
    List<Map<String, Object?>>? tokenRuns,
    List<String>? tokenLogs,
    String tokenLabel = '',
  }) async {
    final stillOnAccount = activeAccountId == tokenAccountId;
    final ctx = _AccountRefreshContext(
      accountId: tokenAccountId,
      accountLabel: tokenLabel,
      accountDir: tokenDir,
      configManager: tokenCfg ?? config,
      runsList: tokenRuns ?? runs,
      logLinesList: tokenLogs ?? logLines,
      isActiveScreen: stillOnAccount,
      isScheduled: isScheduled,
    );
    final keptLunchDays = <String>{
      for (final day in pendingOrders)
        if (LunchLogic.realMeal(orders[day]).isNotEmpty) day,
    };
    await _executeRefreshForContext(
      ctx,
      scope: scope,
      started: started,
      pauseAutomation: pauseAutomation,
      quickOutbox: quickOutbox,
      cancelledLunchDays: Set<String>.of(cancelledLunches),
      keptLunchDays: keptLunchDays,
      lunchPrompt: lunchPrefs,
      isCancelled: () => cancelRequested,
    );
  }

  /// Shared refresh execution + result handler used by BOTH the active account
  /// and background accounts (§7.2 step 4, M6).
  /// Returns `true` when the run succeeded (or cancelled / low-balance only),
  /// `false` on a reported failure.
  Future<bool> _executeRefreshForContext(
    _AccountRefreshContext ctx, {
    required String scope,
    required DateTime started,
    required bool pauseAutomation,
    bool quickOutbox = false,
    required Set<String> cancelledLunchDays,
    required Set<String> keptLunchDays,
    required String lunchPrompt,
    required bool Function() isCancelled,
  }) async {
    var detail = '';
    var ok = false;
    var cancelled = false;
    var reportedFailure = false;
    var quickEventful = false;
    final screenActive =
        ctx.isActiveScreen && activeAccountId == ctx.accountId;

    void logForCtx(String msg, [bool step = true]) {
      if (screenActive && activeAccountId == ctx.accountId) {
        workerLog(msg, step);
      } else {
        _appendAccountLog(ctx, msg);
      }
    }

    try {
      if (scope != 'quick') {
        logForCtx(Strings.format('refresh_started_log', {'scope': scope}));
      }
      final app = buildAppForAccount(
        onLog: (m) => logForCtx(m, false),
        dataDir: ctx.accountDir,
      );
      RefreshResult result;
      try {
        app.cancelCallback = isCancelled;
        final runConfig = pauseAutomation
            ? <String, Object?>{...app.configData, 'automation_paused': true}
            : app.configData;
        result = await runRefresh(
          app,
          runConfig,
          scope: scope,
          scheduled: ctx.isScheduled,
          quickOutbox: quickOutbox,
          cancelledLunchDays: cancelledLunchDays,
          keptLunchDays: keptLunchDays,
          isCancelled: isCancelled,
          emit: (key, [fmt = const {}]) =>
              logForCtx(Strings.format(key, fmt)),
          lunchPrompt: lunchPrompt,
          dataDir: ctx.accountDir,
        );
      } finally {
        try {
          app.close();
        } catch (_) {
          // Closing is best-effort.
        }
      }
      quickEventful = result.quickEventful;

      // -- Unified result handler (`handleRefreshResult`, §7.2 step 4) ------
      final stillActive =
          ctx.isActiveScreen && activeAccountId == ctx.accountId;
      if (result.usedGemini) {
        try {
          final now = clock.now();
          ctx.configManager.set('gemini_last_run', fmtIso(now));
          ctx.configManager.save();
        } catch (exc) {
          // ignore: avoid_print
          print('Warning: could not stamp gemini_last_run: $exc');
        }
      }
      if (stillActive) {
        if (result.autoOrderedDays.isNotEmpty) {
          // Auto-submitted days are web truth now - applied BEFORE
          // reloadCache emits so no frame shows a stale "to send".
          pendingOrders.removeAll(result.autoOrderedDays);
        }
        if (result.autoCancelledDays.isNotEmpty) {
          pendingOrders.removeAll(result.autoCancelledDays);
        }
        reloadCache();
      }
      for (final news in result.news) {
        _notifyForContext(ctx, news.$1, news.$2);
      }
      if (result.lunchesCancelled > 0) {
        final cancelNotice = _formatAutoCancelNotice(result);
        if (cancelNotice.isNotEmpty) {
          _notifyForContext(ctx, 'lunch_skipped', cancelNotice);
        }
      }
      final extras = <String>[];
      if (result.excusesSent > 0) {
        extras.add(Strings.format('auto_excuses_sent', {'n': result.excusesSent}));
      }
      if (result.lunchesOrdered > 0) {
        extras.add(Strings.format('auto_lunch_sent', {'n': result.lunchesOrdered}));
      }
      if (result.lunchesCancelled > 0) {
        extras.add(Strings.format(
            'auto_lunch_cancelled', {'n': result.lunchesCancelled}));
      }
      final subjectCount = stillActive ? absence().length : result.subjects;
      detail = [
        Strings.format('subjects_count', {'n': subjectCount}),
        ...extras,
      ].join(' · ');
      var autoErrors = result.automationErrors;
      final fetchErrors = [
        for (final e in result.errors)
          if (!autoErrors.contains(e)) e
      ];
      if (fetchErrors.isNotEmpty) {
        // O1 turned refresh_failed off by default: a failed auto phase in
        // the same run still gets its own notification (fail loudly).
        if (autoErrors.isNotEmpty && !result.onlyLowBalance) {
          _notifyForContext(
              ctx,
              'automation_failed',
              Strings.format('automation_failed_body',
                  {'detail': failureDetail(autoErrors.first.$2)}));
        }
        // ignore: only_throw_errors
        throw fetchErrors.first.$2;
      }
      if (autoErrors.isNotEmpty && result.onlyLowBalance) {
        // An empty Strava account is the user's to fix, not a bug: a
        // warning (toast at most once a day, banner on Obědy) instead of
        // the error popup, and the run counts as done so the scheduler
        // does not retry every 5 minutes.
        _warnLowBalanceForContext(ctx, '${autoErrors.first.$2}');
        autoErrors = [];
      }
      if (autoErrors.isNotEmpty) {
        // Fail loudly: something that should have been sent or ordered
        // under the user's account was not.
        final (phase, exc) = autoErrors.first;
        detail = failureDetail(exc);
        reportedFailure = true;
        logForCtx(Strings.format('automation_failed_body', {'detail': detail}));
        _notifyForContext(ctx, 'automation_failed',
            Strings.format('automation_failed_body', {'detail': detail}));
        _reportErrorScoped(
          'automation ($phase)',
          exc: exc,
          message: detail,
          extra: {'scope': scope},
          targetConfig: ctx.configManager.data,
          targetLogLines: ctx.logLinesList,
          targetDataDir: ctx.accountDir,
          updateUi: stillActive,
        );
        if (ctx.isScheduled) {
          _markScheduledRefreshFailed(ctx.accountDir, true, scope: scope);
        }
        return false;
      }
      ok = true;
      _markScheduledRefreshFailed(ctx.accountDir, false);
      if (scope != 'quick' || quickEventful) {
        _notifyForContext(ctx, 'refresh_done', Strings.get('refresh_done_body'));
      }
      if (scope != 'quick') {
        logForCtx(Strings.get('refresh_finished_log'));
      }
      return true;
    } on CancelledError {
      detail = Strings.get('cancelled_by_user');
      cancelled = true;
      logForCtx(Strings.get('refresh_cancelled_log'));
      return true;
    } catch (exc) {
      detail = failureDetail(exc);
      reportedFailure = true;
      logForCtx(Strings.format('refresh_failed_log', {'detail': detail}));
      final stillActive =
          ctx.isActiveScreen && activeAccountId == ctx.accountId;
      _reportErrorScoped(
        'refresh ($scope)',
        exc: exc,
        message: detail,
        extra: {'scope': scope},
        targetConfig: ctx.configManager.data,
        targetLogLines: ctx.logLinesList,
        targetDataDir: ctx.accountDir,
        updateUi: stillActive,
      );
      _notifyForContext(ctx, 'refresh_failed',
          Strings.format('refresh_failed_body', {'detail': detail}));
      if (ctx.isScheduled) {
        _markScheduledRefreshFailed(ctx.accountDir, true, scope: scope);
      }
      return false;
    } finally {
      // Silent quick checks (ok, no news, no week/outbox/strava change) roll
      // into the per-account counter instead of pushing full runs out of the
      // 20-row Aktivita history (F6 §5.5, R8a S13).
      final silentQuick = scope == 'quick' && ok && !cancelled && !quickEventful;
      if (silentQuick) {
        recordSilentQuickCheck(ctx.accountId, clock.now());
      }
      // Latch release + run record for EVERY exit.
      if (ctx.isActiveScreen) {
        if (activeAccountId == ctx.accountId) {
          if (silentQuick) {
            status = 'idle';
            currentStep = '';
            refreshRunning = false;
            releaseFlight('refresh_running');
            cancelRequested = false;
            _emit();
          } else {
            finishRun(started, scope, ok, detail, cancelled: cancelled);
          }
        } else {
          // Account switched away mid-refresh: record into original account's list
          // without clobbering the newly active account's UI flags.
          if (!silentQuick) {
            _recordRunEntry(ctx, started, scope, ok, detail,
                cancelled: cancelled);
          }
          refreshRunning = false;
          releaseFlight('refresh_running');
          cancelRequested = false;
          _emit();
        }
      } else if (!silentQuick) {
        _recordRunEntry(ctx, started, scope, ok, detail, cancelled: cancelled);
      }
      // Keep analyzer happy on reportedFailure if unused beyond readability.
      assert(reportedFailure || ok || cancelled || !ctx.isScheduled || true);
    }
  }

  void _markScheduledRefreshFailed(
    String? dir,
    bool failed, {
    String scope = 'all',
  }) {
    try {
      final current = loadDataCache(dataDir: dir);
      if (failed) {
        saveDataCache(
          {
            scheduledRefreshFailedKey: clock.now().toIso8601String(),
            scheduledRefreshFailedScopeKey: scope,
          },
          dataDir: dir,
          preserveLastUpdated: true,
        );
      } else if (current[scheduledRefreshFailedKey] != null ||
          current[scheduledRefreshFailedScopeKey] != null) {
        saveDataCache(
          {
            scheduledRefreshFailedKey: null,
            scheduledRefreshFailedScopeKey: null,
          },
          dataDir: dir,
          preserveLastUpdated: true,
        );
      }
    } catch (_) {
      // Cache failure stamp is best-effort.
    }
  }

  void _appendAccountLog(_AccountRefreshContext ctx, String message) {
    ctx.logLinesList.add('[${fmtClock(clock.now())}] ${message.trim()}');
    if (ctx.logLinesList.length > 300) {
      ctx.logLinesList.removeRange(0, ctx.logLinesList.length - 300);
    }
  }

  void _recordRunEntry(
    _AccountRefreshContext ctx,
    DateTime started,
    String scope,
    bool ok,
    String detail, {
    bool cancelled = false,
    bool skipped = false,
  }) {
    final finished = clock.now();
    ctx.runsList.add({
      'started': fmtClock(started),
      'finished':
          '${finished.day.toString().padLeft(2, '0')}.${finished.month.toString().padLeft(2, '0')}. ${fmtClock(finished).substring(0, 5)}',
      'at': finished.toIso8601String(),
      'seconds': finished.difference(started).inSeconds < 0
          ? 0
          : finished.difference(started).inSeconds,
      'ok': ok,
      'scope': scope,
      'detail': detail,
      'cancelled': cancelled,
      if (skipped) 'skipped': true,
    });
    if (ctx.runsList.length > 20) {
      ctx.runsList.removeRange(0, ctx.runsList.length - 20);
    }
  }

  void _notifyForContext(
      _AccountRefreshContext ctx, String event, String body) {
    try {
      final prefs = ctx.configManager.get('notifications', {});
      final prefMap = prefs is Map ? prefs.cast<String, Object?>() : null;
      if (ctx.accountId != null) {
        notifyForAccount(
          event,
          body,
          prefs: prefMap,
          accountId: ctx.accountId,
          accountLabel: ctx.accountLabel.isNotEmpty ? ctx.accountLabel : null,
        );
      } else {
        notify(event, body, prefMap);
      }
    } catch (_) {
      // Notifications are optional.
    }
  }

  void _warnLowBalanceForContext(_AccountRefreshContext ctx, String message) {
    if (ctx.isActiveScreen && activeAccountId == ctx.accountId) {
      workerLog(message);
    } else {
      _appendAccountLog(ctx, message);
    }
    try {
      if (claimLowBalanceNotice(null, ctx.accountDir)) {
        _notifyForContext(ctx, 'lunch_skipped', message);
      }
    } catch (_) {
      // Notifications are optional.
    }
  }

  void cancelRefresh() {
    if (!refreshRunning) return;
    cancelRequested = true;
    // Instant feedback without a full rebuild: log() would re-mount
    // every view (losing focus in half-typed settings fields). The
    // progress channel repaints topbar-only on settings.
    workerLog(Strings.get('cancel_refresh_log'));
    _emitProgress();
  }

  /// Adds a log line; [step] also shows it in the status bar. Port of
  /// `_worker_log()` (the ~1 Hz throttle lives in the Shell in phase 6;
  /// phase-5 controllers emit through the progress channel directly).
  void workerLog(String message, [bool step = true]) {
    logLines.add('[${fmtClock(clock.now())}] ${message.trim()}');
    if (logLines.length > 300) {
      logLines.removeRange(0, logLines.length - 300);
    }
    final text = message.trim();
    if (text.isNotEmpty && step) {
      currentStep =
          text.split('\n').first.trim().substring(0, text.length > 120 ? 120 : text.length);
    }
    _emitProgress();
  }

  /// Core (English diagnostic) log line: activity log only.
  void coreLog(String message) => workerLog(message, false);

  /// The scheduler's result hook for a failed job. Port of `_on_result`
  /// in `_register_jobs` (the heartbeat half lives in the job itself).
  void scheduledJobFailed(String name, Object error) {
    if (error is JobFailed) return; // already reported by the worker
    logLine(Strings.format('job_failed_log', {'name': name}));
    // The cause (last line) belongs in the live log, so a copied log /
    // error report shows why, not just which job.
    final cause = '$error'.trim().split('\n');
    if (cause.isNotEmpty && cause.last.isNotEmpty) {
      final line = cause.last;
      logLine(line.length > 300 ? line.substring(0, 300) : line);
    }
    try {
      final prefs = get('notifications', {});
      notify('refresh_failed', Strings.format('job_failed', {'name': name}),
          prefs is Map ? prefs.cast<String, Object?>() : null);
    } catch (_) {}
  }

  /// Logs the empty-account warning; notifies at most once a day.
  void warnLowBalance(String message) {
    workerLog(message);
    try {
      if (claimLowBalanceNotice(null, activeAccountDir)) {
        notifyEvent('lunch_skipped', message);
      }
    } catch (_) {
      // Notifications are optional.
    }
  }

  /// `{"at", "days"}` of the last "not enough money" rejection, or
  /// null. Days that are over cannot be ordered any more: no stale
  /// banner. Port of `low_balance_warning()`.
  Map<String, Object?>? lowBalanceWarning() {
    final info = data['strava_low_balance'];
    if (info is! Map || info['days'] is! List) return null;
    final now = clock.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [
      for (final d in (info['days'] as List))
        if ((parseCzDate('$d') ?? today).compareTo(today) >= 0) '$d',
    ];
    if (days.isEmpty) return null;
    return {...info.cast<String, Object?>(), 'days': days};
  }

  /// First line of the failure, without the exception type for
  /// user-fixable failures. Port of `_failure_detail()`.
  static String failureDetail(Object? exc) {
    var first = '$exc'.split('\n').first.trim();
    if (first.length > 200) first = first.substring(0, 200);
    if (first.isEmpty) first = Strings.get('unknown_error');
    return exc is UserError ? first : '${exc.runtimeType}: $first';
  }

  void notifyEvent(String event, String body) {
    try {
      final prefs = get('notifications', {});
      final prefMap = prefs is Map ? prefs.cast<String, Object?>() : null;
      if (accountsEnabled && activeAccountId != null) {
        notifyForAccount(
          event,
          body,
          prefs: prefMap,
          accountId: activeAccountId,
          accountLabel: isMultiAccount ? activeAccountDisplayLabel : null,
        );
      } else {
        notify(event, body, prefMap);
      }
    } catch (_) {
      // Notifications are optional.
    }
  }

  /// Records a finished run (latch release + history for EVERY exit).
  /// Port of `_finish_run()`.
  void finishRun(DateTime started, String scope, bool ok, String detail,
      {bool cancelled = false, bool skipped = false}) {
    final finished = clock.now();
    runs.add({
      'started': fmtClock(started),
      'finished':
          '${finished.day.toString().padLeft(2, '0')}.${finished.month.toString().padLeft(2, '0')}. ${fmtClock(finished).substring(0, 5)}',
      // Machine-readable twins of the labels above.
      'at': finished.toIso8601String(),
      'seconds': finished.difference(started).inSeconds < 0
          ? 0
          : finished.difference(started).inSeconds,
      'ok': ok,
      'scope': scope,
      'detail': detail,
      // Callers branch on this, never on the (translated) detail.
      'cancelled': cancelled,
    });
    if (runs.length > 20) {
      runs.removeRange(0, runs.length - 20);
    }
    status = (ok || skipped) ? 'idle' : 'error';
    currentStep = '';
    refreshRunning = false;
    releaseFlight('refresh_running');
    cancelRequested = false;
    _emit();
  }

  /// Tests a login in the background. False if busy or unknown service.
  /// Phase 7 performs the network test and clears `testing` + the flight
  /// flag; until then the flag stays claimed exactly like the original's
  /// in-flight window. Port of `test_connection()`.
  bool testConnection(String service,
      [Map<String, Object?>? overrides,
      void Function(bool ok, String message)? onDone]) {
    if (service != 'bakalari' && service != 'strava' && service != 'ai') {
      return false;
    }
    if (!claimFlight('testing')) return false;
    testing = service;
    _emit();
    spawn(() => _testWork(service, Map<String, Object?>.of(overrides ?? {}),
        onDone), 'strakalari-test-login');
    return true;
  }

  /// Port of `_test_work()`.
  Future<void> _testWork(String service, Map<String, Object?> overrides,
      void Function(bool ok, String message)? onDone) async {
    final tokenAccountId = activeAccountId;
    final tokenDir = activeAccountDir;
    var ok = false;
    var message = '';
    try {
      if (service == 'ai') {
        var key = '${overrides['gemini_api_key'] ?? ''}'.trim();
        var model = '${overrides['gemini_model'] ?? get('gemini_model', 'gemini-3.8-flash') ?? ''}'
            .trim();
        if (key.isEmpty && !_truthy(overrides['gemini_api_key'])) {
          var raw = '${get('gemini_api_key', '') ?? ''}';
          if (raw.isNotEmpty && _truthy(get('gemini_api_key_encrypted'))) {
            raw = decryptStrict(raw, dataDir: rootDir) ?? '';
          }
          key = raw.trim();
        }
        if (model.isEmpty) model = 'gemini-3.8-flash';
        String language;
        try {
          language = getLanguage();
        } catch (_) {
          language = 'cs';
        }
        addLog(Strings.format('test_ai_key_log', {'model': model}));
        (ok, message) =
            await testApiKey(key,
                model: model,
                language: language,
                transport: geminiTransport);
      } else {
        addLog(Strings.format('test_login_log', {'service': service}));
        if (tokenDir != null) {
          await ensureWarmedFn(tokenDir);
        }
        final app = buildAppForAccount(
          configData: overrides.isEmpty ? null : overrides,
          dataDir: tokenDir,
        );
        try {
          if (service == 'bakalari') {
            (ok, message) = await app.checkBakalariLogin();
          } else {
            (ok, message) = await app.checkStravaLogin();
          }
        } finally {
          try {
            app.close();
          } catch (_) {
            // Closing is best-effort.
          }
        }
      }
    } catch (exc) {
      var first = '$exc'.trim().isEmpty
          ? 'unknown error'
          : '$exc'.split('\n').first;
      if (first.length > 200) first = first.substring(0, 200);
      ok = false;
      message = '${exc.runtimeType}: $first';
    } finally {
      testing = '';
      releaseFlight('testing');
    }
    if (activeAccountId != tokenAccountId) {
      // Account switched while test was running: drop stale UI result (§6).
      // ignore: avoid_print
      print('Info: dropping stale testConnection($service) result for $tokenAccountId.');
      _maybeApplyPendingLaunchRoute();
      return;
    }
    lastTest = {
      'service': service,
      'ok': ok,
      'message': message,
      'at': fmtClock(clock.now()),
    };
    addLog('Test $service: '
        '${ok ? Strings.get('connection_ok') : Strings.get('connection_failed')}'
        ' — $message');
    _emit();
    if (onDone != null) {
      try {
        onDone(ok, message);
      } catch (exc) {
        // ignore: avoid_print
        print('Warning: test on_done failed: $exc');
      }
    }
    _maybeApplyPendingLaunchRoute();
  }

  String _formatAutoCancelNotice(RefreshResult result) {
    final days = List<String>.of(result.autoCancelledDays)
      ..sort((a, b) {
        final pa = parseCzDate(a);
        final pb = parseCzDate(b);
        if (pa == null && pb == null) return a.compareTo(b);
        if (pa == null) return -1;
        if (pb == null) return 1;
        final c = pa.compareTo(pb);
        return c != 0 ? c : a.compareTo(b);
      });
    if (days.isEmpty) return '';
    String formatDay(String raw) {
      final d = parseCzDate(raw);
      return d == null ? raw : '${d.day}. ${d.month}. ${d.year}';
    }

    if (days.length == 1) {
      final raw = days.first;
      final dayText = formatDay(raw);
      final reasonCode = result.autoCancelledReasons[raw] ??
          result.autoCancelledReasons[canonicalDayKey(raw)];
      final reason = switch (reasonCode) {
        'free_day' => Strings.get('lunch_cancel_reason_free_day'),
        'planned' => Strings.get('lunch_cancel_reason_planned'),
        _ => '',
      };
      if (reason.isNotEmpty) {
        return Strings.format('auto_lunch_cancel_notif_one', {
          'day': dayText,
          'reason': reason,
        });
      }
      return Strings.format(
          'auto_lunch_cancel_notif_one_plain', {'day': dayText});
    }
    final formatted = [for (final d in days) formatDay(d)].join(', ');
    return Strings.format('auto_lunch_cancel_notif_many', {
      'n': days.length,
      'days': formatted,
    });
  }

  static bool _truthy(Object? v) =>
      !(v == null || v == false || v == 0 || v == '' ||
          (v is Map && v.isEmpty) || (v is List && v.isEmpty));
}

/// Riverpod facade for the activity screen (phase 6).
class ActivityController extends Notifier<AppState> {
  @override
  AppState build() => ref.watch(appStateProvider);
}

final activityControllerProvider =
    NotifierProvider<ActivityController, AppState>(ActivityController.new);
