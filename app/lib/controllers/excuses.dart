// Pending excuse tasks: listing, ignoring and one-click sending.
//
// Port of strakalari/flet_ui/state_excuses.py (`ExcuseTasksMixin`).
// Pure listing/planning logic is complete; the Bakaláři sends
// (`_excuse_worker`, threads, snackbars) are phase-6/7 work — the stubs
// below validate and stage exactly like the originals, then hand the
// payload to [ExcuseSendPort] (unimplemented until phase 7).
part of 'app_state.dart';

/// True when a one-click excuse task falls inside a persisted excuse.
/// Port of `_task_covered_by_history()`.
bool taskCoveredByHistory(Map<String, Object?> task, List<Object?> history) {
  final day = parseCzDate('${task['date'] ?? ''}');
  if (day == null) return false;
  final period = int.tryParse('${task['period'] ?? ''}');
  return taskCovered(day, period, history);
}

/// The one-lesson excuse for a pending task of [kind] on [dayLabel].
/// Port of `_lesson_excuse()`.
Map<String, Object?> lessonExcuse(Object? kind, String dayLabel, int period) {
  final k = '$kind'.toLowerCase();
  return {
    // "early" (generic early leave) uses the same hour-based web form
    // as "soon"; "late" is a late arrival.
    'type': (k == 'soon' || k == 'early')
        ? 'soon'
        : (k == 'late' ? 'income' : 'days and hours'),
    'starting_day': dayLabel,
    'ending_day': dayLabel,
    'starting_lesson': period,
    'ending_lesson': period,
  };
}

/// Excuse-task listing/ignore/send logic. Port of `ExcuseTasksMixin`.
extension ExcuseTasksLogic on AppState {
  List<Map<String, Object?>> _allExcuseTasks() {
    if (demoMode) return [];
    return [
      for (final t
          in excuseTasksFromLessons(lessonsFromTimetable(timetable())))
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
  }

  /// First day still excusable (same window as automatic excusing).
  /// Port of `_excuse_window_start()`.
  DateTime excuseWindowStart() {
    DateTime? outboxFrom;
    try {
      outboxFrom = parseCzDate('${(data)[sentExcusesFromKey] ?? ''}');
    } catch (_) {
      outboxFrom = null;
    }
    final now = clock.now();
    final today = DateTime(now.year, now.month, now.day);
    return core.excuseWindowStart(today, outboxFrom);
  }

  /// Timetable absence tasks that have not been excused yet.
  /// Port of `_unexcused_tasks()`.
  List<Map<String, Object?>> unexcusedTasks() {
    var tasks = _allExcuseTasks();
    if (tasks.isEmpty) return [];
    final sentKeys = {for (final e in excuseLog) '${e['key']}'};
    if (sentKeys.isNotEmpty) {
      tasks = [for (final t in tasks) if (!sentKeys.contains('${t['key']}')) t];
    }
    // Hide tasks already covered by the persisted excuse history
    // (already_excused_lessons.json) — otherwise a sent excuse reappears
    // after every restart.
    List<Object?> history = [];
    try {
      history = config.getExcuseHistory();
    } catch (_) {
      history = [];
    }
    if (history.isNotEmpty) {
      tasks = [
        for (final t in tasks)
          if (!taskCoveredByHistory(t, history)) t,
      ];
    }
    return tasks;
  }

  /// Pending one-click tasks (window-clipped, ignored filtered out).
  /// Port of `excuse_tasks()`.
  List<Map<String, Object?>> excuseTasks() {
    final windowStart = fmtIso(excuseWindowStart());
    return [
      for (final t in unexcusedTasks())
        if ('${t['date'] ?? ''}'.isEmpty ||
            '${t['date']}'.compareTo(windowStart) >= 0)
          if (!ignoredExcuseKeys.contains('${t['key']}')) t,
    ];
  }

  /// Currently ignored tasks (still unexcused in the timetable).
  List<Map<String, Object?>> ignoredTasks() {
    if (ignoredExcuseKeys.isEmpty) return [];
    return [
      for (final t in unexcusedTasks())
        if (ignoredExcuseKeys.contains('${t['key']}')) t,
    ];
  }

  /// Saves the ignore list; on failure restores [previous] everywhere.
  /// Port of `_persist_ignored()`.
  bool persistIgnored(Set<String> previous) {
    lastIgnoreError = '';
    try {
      config.set('ignored_excuses', ignoredExcuseKeys.toList()..sort());
      config.save();
      return true;
    } catch (err) {
      ignoredExcuseKeys = Set<String>.of(previous);
      try {
        config.set('ignored_excuses', previous.toList()..sort());
      } catch (_) {
        // Memory is what the UI shows.
      }
      lastIgnoreError = Strings.get('ignore_save_failed');
      logLine('$lastIgnoreError (${err.runtimeType}: $err)');
      return false;
    }
  }

  /// Applies one ignore-list edit, saves it and repaints. Port of
  /// `_change_ignored()`.
  bool changeIgnored(
      {Iterable<Object?> add = const [], Iterable<Object?> remove = const []}) {
    final previous = Set<String>.of(ignoredExcuseKeys);
    ignoredExcuseKeys.addAll([for (final k in add) if ('$k'.isNotEmpty) '$k']);
    ignoredExcuseKeys.removeAll([for (final k in remove) '$k']);
    if (ignoredExcuseKeys.length == previous.length &&
        ignoredExcuseKeys.containsAll(previous)) {
      return true;
    }
    final ok = persistIgnored(previous);
    if (ok && add.isNotEmpty) {
      tutorialEvent('excuse_done'); // Ignore counts as handling it.
    }
    _emit();
    return ok;
  }

  /// Hides one task (already excused manually in Bakaláři). Returns the
  /// hidden key, or '' when nothing was hidden.
  String ignoreExcuse(Object? taskOrKey) {
    lastIgnoreError = '';
    final key = taskOrKey is Map
        ? '${taskOrKey['key'] ?? ''}'
        : '${taskOrKey ?? ''}';
    if (key.isEmpty || !changeIgnored(add: [key])) return '';
    return key;
  }

  bool unignoreExcuse(String key) => changeIgnored(remove: [key]);

  /// Hides every pending task of one day. Returns the hidden keys.
  List<String> ignoreDay(String dayIso) {
    lastIgnoreError = '';
    final added = [
      for (final t in unexcusedTasks())
        if ('${t['date'] ?? ''}' == dayIso &&
            !ignoredExcuseKeys.contains('${t['key']}'))
          '${t['key']}',
    ];
    if (added.isEmpty || !changeIgnored(add: added)) return [];
    return added;
  }

  bool unignoreKeys(List<String> keys) => changeIgnored(remove: keys);

  void markExcused(Map<String, Object?> task, String template,
      {bool sent = false, bool emit = true}) {
    excuseLog.add({
      'key': '${task['key']}',
      'label': '${task['label']}',
      'template': template,
      'sent': sent,
    });
    if (emit) _emit();
  }

  /// Validates and stages a one-lesson excuse send. The real Bakaláři
  /// submit runs in phase 7 via [ExcuseSendPort]; until then the task is
  /// staged as in-flight and the caller toasts `excuse_failed`-style
  /// pending state. Returns false when a submit is already running or
  /// the task lacks the data for a request. Port of `submit_excuse()`
  /// (Flet page/snackbar/threading bits dropped — see comment there).
  bool submitExcuse(Map<String, Object?> task, [String template = '']) {
    final key = '${task['key'] ?? ''}';
    if (key.isEmpty || sendingExcuses.contains(key)) return false;
    final dayIso = '${task['date'] ?? ''}';
    final day = parseCzDate(dayIso);
    final period = int.tryParse('${task['period'] ?? ''}');
    if (day == null || period == null) {
      logLine('${Strings.get('excuse_failed')}: ${task['label'] ?? key}');
      return false;
    }
    if (demoMode && !_hasAnyCredentials()) {
      logLine(Strings.get('need_credentials'));
      return false;
    }
    lessonExcuse(task['kind'], fmtDay(day), period);
    if (sendingExcuses.contains(key)) return false;
    sendingExcuses.add(key);
    currentStep = Strings.get('excuse_sending');
    logLine('${Strings.get('excuse_sending')}: ${task['label'] ?? key}');
    tutorialEvent('excuse_done');
    _emit();
    // Flet: spawned `_excuse_worker` thread (session lock, one Bakaláři
    // session, outcomes sent/covered/dry_run/failed/unconfirmed/skipped,
    // snackbar + notification + error dialog). Phase 7 runs this via
    // ExcuseSendPort and clears `sendingExcuses` on completion.
    return true;
  }

  /// True when every lesson of the day that took place is a pending
  /// absence. Only then does a whole-day ("pure days") excuse describe
  /// what happened. Port of `day_fully_absent()`.
  bool dayFullyAbsent(String dayIso) {
    final day = parseCzDate(dayIso);
    if (day == null) return false;
    final label = fmtDay(day);
    final tasks = [
      for (final t in excuseTasks())
        if ('${t['date'] ?? ''}' == dayIso) t,
    ];
    final absentKeys = {
      for (final t in tasks)
        if ('${t['kind']}' == 'short') '${t['key']}',
    };
    final lessons = [
      for (final raw in (timetable()[label] ?? []))
        if (raw is Map && !isClassEvent(raw))
          Lesson.fromLegacy(raw.cast<String, Object?>(), label),
    ];
    final held = [for (final l in lessons) if (l.status != 'cancelled') l];
    if (held.isEmpty || absentKeys.isEmpty) return false;
    return held.every((l) =>
        absentKeys.contains('${fmtIso(day)}|${l.period}|${l.subject}'));
  }

  bool excuseDayPerLesson() => get('excuse_day_per_lesson', false) == true;

  /// Remembers the day cards' "each lesson separately" switch.
  bool setExcuseDayPerLesson(bool on) {
    final previous = excuseDayPerLesson();
    if (save({'excuse_day_per_lesson': on})) return true;
    try {
      config.set('excuse_day_per_lesson', previous);
    } catch (_) {
      // The re-render shows what holds.
    }
    _emit();
    return false;
  }

  /// The excuses covering every pending task of one day. Port of
  /// `day_excuse_plan()`.
  List<Map<String, Object?>> dayExcusePlan(String dayIso,
      [bool perLesson = false]) {
    final day = parseCzDate(dayIso);
    if (day == null) return [];
    final dayLabel = fmtDay(day);
    final tasks = [
      for (final t in excuseTasks())
        if ('${t['date'] ?? ''}' == dayIso) t,
    ];
    if (tasks.isEmpty) return [];
    if (perLesson) {
      final singles = <Map<String, Object?>>[];
      for (final task in tasks) {
        final period = int.tryParse('${task['period'] ?? ''}');
        if (period == null) continue;
        final excuse = lessonExcuse(task['kind'], dayLabel, period);
        if (!singles.any((e) =>
            e['type'] == excuse['type'] &&
            e['starting_lesson'] == excuse['starting_lesson'])) {
          singles.add(excuse);
        }
      }
      singles.sort((a, b) =>
          (a['starting_lesson'] as int).compareTo(b['starting_lesson'] as int));
      return singles;
    }
    if (dayFullyAbsent(dayIso)) {
      return [
        {
          'type': 'pure days',
          'starting_day': dayLabel,
          'ending_day': dayLabel,
        },
      ];
    }
    final plan = <Map<String, Object?>>[];
    final absent = <int>[];
    for (final task in tasks) {
      final period = int.tryParse('${task['period'] ?? ''}');
      if (period == null) continue;
      final kind = '${task['kind'] ?? 'short'}'.toLowerCase();
      if (kind == 'short') {
        absent.add(period);
        continue;
      }
      plan.add({
        'type': (kind == 'soon' || kind == 'early') ? 'soon' : 'income',
        'starting_day': dayLabel,
        'ending_day': dayLabel,
        'starting_lesson': period,
        'ending_lesson': period,
      });
    }
    final run = <int>[];
    void flush() {
      if (run.isEmpty) return;
      plan.add({
        'type': 'days and hours',
        'starting_day': dayLabel,
        'ending_day': dayLabel,
        'starting_lesson': run.first,
        'ending_lesson': run.last,
      });
      run.clear();
    }

    for (final period in (absent..sort())) {
      if (run.isNotEmpty && period != run.last + 1) flush();
      run.add(period);
    }
    flush();
    return plan;
  }

  /// Validates and stages a whole-day excuse send (phase 7 submits it).
  /// Port of `submit_day_excuse()` (worker/snackbar bits dropped).
  bool submitDayExcuse(String dayIso,
      [String template = '', bool perLesson = false]) {
    final day = parseCzDate(dayIso);
    if (day == null) return false;
    final key = 'day|$dayIso';
    if (sendingExcuses.contains(key)) return false;
    final plan = dayExcusePlan(dayIso, perLesson);
    if (plan.isEmpty) return false;
    if (demoMode && !_hasAnyCredentials()) {
      logLine(Strings.get('need_credentials'));
      return false;
    }
    sendingExcuses.add(key);
    currentStep = Strings.get('excuse_sending');
    logLine('${Strings.get('excuse_sending')}: ${fmtDay(day)}');
    tutorialEvent('excuse_done');
    _emit();
    // Flet: spawned `_excuse_worker` (see `submitExcuse` comment).
    return true;
  }
}

/// Riverpod facade for the absences screen (phase 6).
class ExcusesController extends Notifier<AppState> {
  @override
  AppState build() => ref.watch(appStateProvider);
}

final excusesControllerProvider =
    NotifierProvider<ExcusesController, AppState>(ExcusesController.new);
