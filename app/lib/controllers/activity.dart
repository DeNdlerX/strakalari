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
      if (exc is UserError && '$exc'.trim().isNotEmpty) {
        userMessage = '$exc'.split('\n').first.trim();
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
    // Flet: spawned `_update_work` (check_for_updates, banner refresh,
    // notification). Phase 7 runs it via the update seam.
    return true;
  }

  /// Starts a refresh run. Returns false when busy. Phase 7 performs
  /// the fetch; until then flags + log match the original.
  /// Port of `start_refresh()`.
  bool startRefresh([String scope = 'all']) {
    if (!claimFlight('refresh_running')) return false;
    if (scope != 'all' && scope != 'bakalari' && scope != 'strava') {
      scope = 'all';
    }
    cancelRequested = false;
    status = 'working';
    currentStep = '';
    refreshRunning = true;
    _emit();
    // Flet: spawned `_refresh_work` (session lock, run_refresh pipeline,
    // cache reload, news notifications, `_finish_run`).
    return true;
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
      'at': fmtIso(finished),
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
  bool testConnection(String service, [Map<String, Object?>? overrides]) {
    if (service != 'bakalari' && service != 'strava' && service != 'ai') {
      return false;
    }
    if (!claimFlight('testing')) return false;
    testing = service;
    _emit();
    // Flet: spawned `_test_work` (login check, `last_test` record,
    // wizard `on_done` auto-advance). Phase 7 runs it via the test seam.
    return true;
  }
}

/// Riverpod facade for the activity screen (phase 6).
class ActivityController extends Notifier<AppState> {
  @override
  AppState build() => ref.watch(appStateProvider);
}

final activityControllerProvider =
    NotifierProvider<ActivityController, AppState>(ActivityController.new);
