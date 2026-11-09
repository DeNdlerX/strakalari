/// Activity state. Port of state_activity.ActivityMixin (UI-owned parts).
///
/// Plain-Dart controller; background work is injected so widget tests
/// never spawn threads or touch the network.
class ActivityController {
  final Map<String, dynamic> config;
  final List<void Function()> _listeners = [];
  final List<void Function()> _progressListeners = [];

  List<String> logLines = [];
  List<Map<String, dynamic>> runs = [];
  String status = 'idle';
  bool refreshRunning = false;
  bool cancelRequested = false;
  String currentStep = '';
  Set<String> sendingExcuses = {};
  bool orderRunning = false;
  DateTime? schedulerLastRun;
  Map<String, dynamic>? updateInfo;
  String updateDismissed = '';
  bool updateCheckRunning = false;
  Map<String, dynamic>? lastError;
  bool errorDialogPending = false;
  String lastLogEmitKey = '';

  /// Monotonic clock for the ~1 Hz log throttle (injectable in tests).
  double Function()? monotonicClock;
  double _lastLogEmit = -1e9;

  /// Spawn work (tests run it inline or drop it).
  void Function(void Function() work, String name)? spawn;

  bool Function(String scope)? startRefreshHook;

  /// Live wiring: the actions below delegate to the shared AppState.
  void Function()? cancelRefreshHook;
  void Function()? clearLogHook;
  void Function()? dismissUpdateHook;

  /// Last normalized scope (tests assert 'bogus' → 'all').
  String lastScope = 'all';

  ActivityController(this.config,
      {this.spawn, this.monotonicClock, this.startRefreshHook});

  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);

  /// Progress listeners repaint only the topbar (mirrors `_emit_progress`).
  void addProgressListener(void Function() fn) =>
      _progressListeners.add(fn);

  void _emit() {
    for (final fn in List.of(_listeners)) {
      fn();
    }
  }

  void _emitProgress() {
    for (final fn in List.of(_progressListeners)) {
      fn();
    }
  }

  dynamic get(String key, [dynamic fallback]) =>
      config.containsKey(key) ? config[key] : fallback;

  // -- log (ring buffer, 300 lines) -------------------------------------------
  String _stamp() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
  }

  void log(String message) {
    logLines.add('[$_stamp()] $message');
    if (logLines.length > 300) {
      logLines = logLines.sublist(logLines.length - 300);
    }
    _emit();
  }

  void clearLog() {
    if (clearLogHook != null) return clearLogHook!();
    logLines = [];
    _emit();
  }

  /// Throttled worker log: full UI emit at most ~1 Hz, progress channel
  /// otherwise (mirrors `_worker_log`).
  void workerLog(String message, {bool step = true}) {
    logLines.add('[$_stamp()] ${message.trim()}');
    if (logLines.length > 300) {
      logLines = logLines.sublist(logLines.length - 300);
    }
    final text = message.trim();
    if (text.isNotEmpty && step) {
      currentStep = text.split('\n').first;
      if (currentStep.length > 120) {
        currentStep = currentStep.substring(0, 120);
      }
    }
    final now = monotonicClock != null
        ? monotonicClock!()
        : DateTime.now().millisecondsSinceEpoch / 1000.0;
    if (now - _lastLogEmit >= 1.0) {
      _lastLogEmit = now;
      _emit();
    } else {
      _emitProgress();
    }
  }

  // -- status ------------------------------------------------------------------
  String get sendingLabel {
    if (sendingExcuses.isNotEmpty) return 'excuse_sending';
    if (orderRunning) return 'orders_sending';
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
    final when = last['finished'] ?? last['started'] ?? '—';
    final mark = last['ok'] == true ? '✓' : '✗';
    return '$mark $when';
  }

  String nextRunLabel({DateTime? now}) {
    if (schedulerLastRun == null) return '—';
    try {
      final interval =
          double.tryParse('${get('check_interval_minutes', 60) ?? 60}') ??
              60.0;
      final due = schedulerLastRun!
          .add(Duration(seconds: (interval * 60).round()));
      final n = now ?? DateTime.now();
      if (due.isBefore(n)) return '—';
      return '${due.day.toString().padLeft(2, '0')}.'
          '${due.month.toString().padLeft(2, '0')}. '
          '${due.hour.toString().padLeft(2, '0')}:'
          '${due.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '—';
    }
  }

  // -- refresh --------------------------------------------------------------------
  bool startRefresh([String scope = 'all']) {
    if (refreshRunning) return false;
    if (startRefreshHook != null) return startRefreshHook!(scope);
    if (!['all', 'bakalari', 'strava'].contains(scope)) scope = 'all';
    lastScope = scope;
    refreshRunning = true;
    cancelRequested = false;
    status = 'working';
    currentStep = '';
    _emit();
    return true;
  }

  void cancelRefresh() {
    if (cancelRefreshHook != null) return cancelRefreshHook!();
    if (!refreshRunning) return;
    cancelRequested = true;
    workerLog('cancel_refresh_log');
    _emitProgress();
  }

  // -- update banner ----------------------------------------------------------------
  Map<String, dynamic>? get updateBanner {
    final info = updateInfo;
    if (info == null || info.isEmpty) return null;
    if (updateDismissed == '${info['version'] ?? ''}') return null;
    return info;
  }

  void dismissUpdate() {
    if (dismissUpdateHook != null) return dismissUpdateHook!();
    if (updateInfo != null) {
      updateDismissed = '${updateInfo!['version'] ?? ''}';
    }
    _emit();
  }

  // -- errors -------------------------------------------------------------------------
  Map<String, dynamic> reportError(
    String operation, {
    Object? error,
    String message = '',
    String traceback = '',
    Map<String, dynamic>? extra,
    String userMessage = '',
  }) {
    final summary = message.trim().isNotEmpty
        ? message.trim()
        : error != null
            ? '$error'.split('\n').first
            : 'unknown error';
    final tail = logLines.length > 60
        ? logLines.sublist(logLines.length - 60)
        : List.of(logLines);
    final report = {
      'at': DateTime.now().toIso8601String(),
      'operation': operation,
      'summary': summary,
      'traceback': traceback,
      'log_tail': tail,
      'extra': extra ?? {},
      'user_message': userMessage,
    };
    lastError = report;
    status = 'error';
    errorDialogPending = true;
    _emit();
    return report;
  }

  String errorReportText() {
    final report = lastError;
    if (report == null) return '';
    final buf = StringBuffer()
      ..writeln('operation: ${report['operation']}')
      ..writeln('summary: ${report['summary']}');
    final tb = '${report['traceback'] ?? ''}';
    if (tb.isNotEmpty) buf.writeln(tb);
    return buf.toString();
  }

  void acknowledgeError() {
    errorDialogPending = false;
  }
}
