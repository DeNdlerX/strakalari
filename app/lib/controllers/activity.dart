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
  Map<String, Object?> reportError(String operation,
      [Object? exc,
      String message = '',
      String tracebackStr = '',
      Map<String, Object?>? extra]) {
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
      final tail = List<String>.of(logLines.length > logTailLines
          ? logLines.sublist(logLines.length - logTailLines)
          : logLines);
      if (tb.isNotEmpty) {
        final stamp = fmtClock(clock.now());
        final tbLines = tb.split('\n');
        final last = tbLines.length > 25
            ? tbLines.sublist(tbLines.length - 25)
            : tbLines;
        for (final line in last) {
          logLines.add('[$stamp] ${line.trimRight()}');
        }
        if (logLines.length > 500) {
          logLines.removeRange(0, logLines.length - 500);
        }
      }
      Map<String, Object?> configData = {};
      try {
        configData = Map<String, Object?>.of(config.data);
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
    lastError = report;
    status = 'error';
    errorDialogPending = true;
    _emit();
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
      final interval =
          double.tryParse('${get('check_interval_minutes', 60) ?? 60}') ??
              60.0;
      final due = nextDue(schedulerLastRun, interval, clock.now());
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

  /// The scheduler's refresh job. Port of `_refresh_job` + `_run_refresh`
  /// in `flet_ui/app.py` (`_register_jobs`): skips while setup is pending,
  /// a refresh runs or no login exists; otherwise starts a refresh and
  /// waits for its outcome (bounded by [maxWait]), so a failed run gets
  /// the scheduler's early retry. [stopped] ends the wait at shutdown.
  Future<String> scheduledRefreshJob({
    Duration maxWait = const Duration(minutes: 30),
    bool Function()? stopped,
  }) async {
    schedulerLastRun = clock.now();
    if (setupPending) return 'skipped (setup not finished)';
    if (refreshRunning) return 'skipped (a refresh is already running)';
    if (demoMode && !_hasCredentials()) {
      return 'skipped (no credentials configured)';
    }
    final before = runs.isEmpty ? null : runs.last;
    if (!startRefresh('all')) {
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
      await Future<void>.delayed(const Duration(seconds: 1));
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

  /// Starts a refresh run. Returns false when busy.
  /// When [pauseAutomation] is true (O6 early wizard refresh), the run uses an
  /// in-memory `automation_paused: true` config copy without mutating saved
  /// config. Port of `start_refresh()`.
  bool startRefresh([String scope = 'all', bool pauseAutomation = false]) {
    if (!claimFlight('refresh_running')) return false;
    if (scope != 'all' && scope != 'bakalari' && scope != 'strava') {
      scope = 'all';
    }
    cancelRequested = false;
    status = 'working';
    currentStep = '';
    refreshRunning = true;
    earlyRefreshInFlight = pauseAutomation;
    _emit();
    spawn(
      () => _refreshWork(scope, pauseAutomation: pauseAutomation),
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
  }) async {
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
      // One refresh at a time across processes: the tray runs its own
      // scheduler, and two parallel runs would both log in, both auto-send
      // and overwrite each other's cache.
      var ran = false;
      try {
        await withSessionLockAsync((held) async {
          if (held) {
            ran = true;
            await _refreshLocked(scope, started,
                pauseAutomation: pauseAutomation);
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
    }
  }

  /// The refresh proper; runs while the session lock is held.
  /// Port of `_refresh_locked()`.
  Future<void> _refreshLocked(
    String scope,
    DateTime started, {
    bool pauseAutomation = false,
  }) async {
    var detail = '';
    var ok = false;
    var cancelled = false;
    try {
      workerLog(Strings.format('refresh_started_log', {'scope': scope}));
      final app = createApp(onLog: coreLog);
      RefreshResult result;
      try {
        app.cancelCallback = () => cancelRequested;
        final runConfig = pauseAutomation
            ? <String, Object?>{...app.configData, 'automation_paused': true}
            : app.configData;
        result = await runRefresh(
          app,
          runConfig,
          scope: scope,
          cancelledLunchDays: Set<String>.of(cancelledLunches),
          isCancelled: () => cancelRequested,
          emit: (key, [fmt = const {}]) =>
              workerLog(Strings.format(key, fmt)),
          lunchPrompt: lunchPrefs,
        );
      } finally {
        try {
          app.close();
        } catch (_) {
          // Closing is best-effort.
        }
      }
      if (result.usedGemini) {
        try {
          final now = clock.now();
          config.set('gemini_last_run', fmtIso(now));
          config.save();
        } catch (exc) {
          // ignore: avoid_print
          print('Warning: could not stamp gemini_last_run: $exc');
        }
      }
      if (result.autoOrderedDays.isNotEmpty) {
        // Auto-submitted days are web truth now - applied BEFORE
        // reloadCache emits so no frame shows a stale "to send".
        pendingOrders.removeAll(result.autoOrderedDays);
      }
      reloadCache();
      for (final news in result.news) {
        notifyEvent(news.$1, news.$2);
      }
      final extras = <String>[];
      if (result.excusesSent > 0) {
        extras.add(Strings.format('auto_excuses_sent', {'n': result.excusesSent}));
      }
      if (result.lunchesOrdered > 0) {
        extras.add(Strings.format('auto_lunch_sent', {'n': result.lunchesOrdered}));
      }
      detail = [
        Strings.format('subjects_count', {'n': absence().length}),
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
          notifyEvent(
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
        warnLowBalance('${autoErrors.first.$2}');
        autoErrors = [];
      }
      if (autoErrors.isNotEmpty) {
        // Fail loudly: something that should have been sent or ordered
        // under the user's account was not.
        final (phase, exc) = autoErrors.first;
        detail = failureDetail(exc);
        workerLog(Strings.format('automation_failed_body', {'detail': detail}));
        notifyEvent('automation_failed',
            Strings.format('automation_failed_body', {'detail': detail}));
        reportError('automation ($phase)', exc, detail, '', {'scope': scope});
        return;
      }
      ok = true;
      notifyEvent('refresh_done', Strings.get('refresh_done_body'));
      workerLog(Strings.get('refresh_finished_log'));
    } on CancelledError {
      detail = Strings.get('cancelled_by_user');
      cancelled = true;
      workerLog(Strings.get('refresh_cancelled_log'));
    } catch (exc) {
      detail = failureDetail(exc);
      workerLog(Strings.format('refresh_failed_log', {'detail': detail}));
      reportError('refresh ($scope)', exc, detail, '', {'scope': scope});
      notifyEvent('refresh_failed',
          Strings.format('refresh_failed_body', {'detail': detail}));
    } finally {
      // Latch release + run record for EVERY exit.
      finishRun(started, scope, ok, detail, cancelled: cancelled);
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

  /// Logs the empty-account warning; notifies at most once a day.
  void warnLowBalance(String message) {
    workerLog(message);
    try {
      if (claimLowBalanceNotice()) {
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
      notify(event, body, prefs is Map ? prefs.cast<String, Object?>() : null);
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
            raw = decryptStrict(raw) ?? '';
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
        final app = createApp(
            configData: overrides.isEmpty ? null : overrides);
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
    testing = '';
    releaseFlight('testing');
    _emit();
    if (onDone != null) {
      try {
        onDone(ok, message);
      } catch (exc) {
        // ignore: avoid_print
        print('Warning: test on_done failed: $exc');
      }
    }
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
