import 'package:flutter/foundation.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../l10n/strings.dart';
import '../common/format.dart';
import '../../widgets/app_widgets.dart' show lessonKind;

/// One pending excuse task (represented in AppState as a map from excuseTasks).
class ExcuseTask {
  final String key;
  final String kind; // late | early | soon | short
  final String label;
  final String detail;
  final DateTime? date;
  final int? period;
  final Map<String, Object?> rawTask;

  const ExcuseTask({
    required this.key,
    required this.kind,
    required this.label,
    this.detail = '',
    this.date,
    this.period,
    this.rawTask = const {},
  });

  factory ExcuseTask.fromMap(Map<String, Object?> t) {
    DateTime? d;
    final dateStr = '${t['date'] ?? ''}';
    if (dateStr.isNotEmpty) {
      d = DateTime.tryParse(dateStr);
    }
    return ExcuseTask(
      key: '${t['key'] ?? ''}',
      kind: '${t['kind'] ?? 'short'}',
      label: '${t['label'] ?? ''}',
      detail: '${t['detail'] ?? ''}',
      date: d,
      period: t['period'] is int
          ? t['period'] as int
          : int.tryParse('${t['period'] ?? ''}'),
      rawTask: t,
    );
  }
}

/// One template option as a `(name, text)` pair — like
/// `planner._template_options`.
class TemplateOption {
  final String name;
  final String text;
  const TemplateOption(this.name, this.text);
}

/// A send job: one Bakaláři excuse plus the user-chosen text (null =
/// configured default) — mirrors the `(excuse, custom_text)` pairs the
/// Python `_excuse_worker` sends in one session.
class ExcuseJob {
  final Map<String, Object?> excuse;
  final String? customText;
  const ExcuseJob(this.excuse, this.customText);
}

/// A send request handed to the shell's send path (which holds the
/// session lock, writes history and calls back into [markSent]).
class ExcuseSendRequest {
  /// `'single'` or `'day'`.
  final String scope;
  final String key;
  final String label;
  final List<ExcuseJob> jobs;
  final bool perLesson;

  const ExcuseSendRequest({
    required this.scope,
    required this.key,
    required this.label,
    required this.jobs,
    this.perLesson = false,
  });
}

/// Next-lesson card content — like `today._next_lesson_card`.
class NextLessonInfo {
  /// `running | before | between | next-day | empty`.
  final String phase;
  final String headline;
  final String meta;
  final String? deltaText;
  final String? statusLabel;

  /// Badge kind of the status (`lesson_kind`), for its colour.
  final String statusKind;
  final String? headingLabel;
  final String? upcomingHeadline;
  final String? alarmBadge;

  const NextLessonInfo({
    required this.phase,
    required this.headline,
    required this.meta,
    this.deltaText,
    this.statusLabel,
    this.statusKind = 'info',
    this.headingLabel,
    this.upcomingHeadline,
    this.alarmBadge,
  });
}

/// One item of the week-changes / notes blocks.
class TodayChange {
  final String title;
  final String? note;
  final bool isNote;
  const TodayChange({required this.title, this.note, this.isNote = false});
}

/// Wake-up alarm info for one day (port of the fields
/// `today._next_lesson_card._head` reads: [day], [ringDay], [timeLabel]).
class AlarmInfo {
  final DateTime day;
  final DateTime ringDay;
  final String timeLabel;
  const AlarmInfo(
      {required this.day, required this.ringDay, required this.timeLabel});
}

/// Today (Dnes) screen state + logic — a `ChangeNotifier` port of
/// `views/today.py` and the `ExcuseTasksMixin` pieces it uses.
///
/// The shell wires the data inputs (timetable, food, history, config)
/// and the send path ([onSend]); everything else — task filtering,
/// ignore list, template picks, day plans, the clock-aware next lesson,
/// week changes, lunch text and the planner tip — lives here.
class TodayController extends ChangeNotifier {
/// Reads config values (same keys as Python: `your_signature`,
  /// `excuse_day_per_lesson`, `ignored_excuses`, template lists …).
  final Map<String, Object?> config;

  /// Persists config updates. Same keys/formats as Python `state.save`.
  /// Returns false when the write failed (the caller rolls back).
  final bool Function(Map<String, Object?> updates) onSave;

  /// Starts a refresh (`state.start_refresh("all")`); true = started.
  final bool Function() onRefreshRequest;

  /// Asks the shell to navigate (`state.go("settings"|"absences")`).
  final void Function(String route) onGo;

  /// Sends one request in a Bakaláři session (holds the session lock,
  /// writes history, then calls [markSent]). Defaults to a no-op that
  /// reports failure — the shell must provide the real path.
  Future<bool> Function(ExcuseSendRequest request) onSend;

  TodayController({
    Map<String, Object?>? config,
    bool Function(Map<String, Object?> updates)? onSave,
    bool Function()? onRefreshRequest,
    void Function(String route)? onGo,
    Future<bool> Function(ExcuseSendRequest request)? onSend,
  })  : config = config ?? {},
        onSave = onSave ?? ((_) => false),
        onRefreshRequest = onRefreshRequest ?? (() => false),
        onGo = onGo ?? ((_) {}),
        onSend = onSend ?? ((_) async => false);

  // -- inputs (set by the shell, like AppState.data/config) -----------------

  /// `{dayKey: [lessonDict, ...]}` with `DD.MM.YYYY` keys.
  Map<String, List<Object?>> timetable = {};

  /// `{dayKey: {orderCode: meal}}`.
  Map<String, Map<String, String>> food = {};

  /// Orders by day (`orders` then `web_orders` fallback in Python).
  Map<String, String> orders = {};
  Map<String, String> webOrders = {};

  /// Days with a cancelled lunch (`cancelled_lunches`).
  Set<String> cancelledLunches = {};

  /// Persisted excuse history (`already_excused_lessons.json` rows).
  List<Object?> excuseHistory = [];

  /// Start of the range Komens → Odeslané actually showed
  /// (`sent_excuses_from`), or null.
  DateTime? outboxFrom;

  /// Stable baseline for change detection (`stable_baseline()`).
  Map<Object?, Object?> stableBaseline = {};
  bool stableComplete = false;

  /// Keys of tasks already sent this session (`excuse_log` keys).
  final Set<String> sentTaskKeys = {};

  /// `demo_mode` + credential presence.
  bool demoMode = false;
  bool hasCredentials = false;

  /// `updated_label` text.
  String updatedLabel = '';

  /// Next wake-up alarm (`state.next_wakeup_alarm(now)`), if any.
  AlarmInfo? nextAlarm;

  /// Planner's recommended days off within the term (`term.recommended`).
  List<DateTime> plannerRecommended = [];

  /// Template lists for the dropdowns
  /// (`late_income_excuses`, `left_soon_excuses`, `short_absence_excuses`,
  /// `long_absence_excuses`; plain strings or `{name, text}` maps).
  late List<Object?> Function(String configKey) templateSource =
      (key) => (config[key] as List?) ?? const [];

  // -- in-memory UI state (like AppState fields) ------------------------------

  /// Ignored excuse keys (`ignored_excuses`, persisted).
  final Set<String> ignoredKeys = {};

  /// Tasks currently sending (`sending_excuses`).
  final Set<String> sendingKeys = {};

  /// Template pick per card key (`picked_templates`).
  final Map<String, int> pickedTemplates = {};

  /// Day cards folded open (`tt:`/`excuse:` keys in Python; same map).
  final Map<String, bool> expandedDays = {};

  /// Last ignore error (`last_ignore_error`).
  String lastIgnoreError = '';

  /// Last user-facing message (snackbar text equivalent).
  String lastMessage = '';

  /// Pending signature-gated send (the `_when_signed` dialog state).
  ExcuseSendRequest? pendingUnsignedRequest;

  /// Optional live-state delegation hooks (wired by `today_live.dart`).
  String Function(String key)? ignoreExcuseHook;
  List<String> Function(String dayIso)? ignoreDayHook;
  bool Function(List<String> keys)? unignoreKeysHook;
  void Function(String key, int index)? chooseTemplateHook;
  void Function(String key, bool expanded)? setDayExpandedHook;
  bool Function(bool on)? setExcuseDayPerLessonHook;

  // -- config helpers -----------------------------------------------------------

  Object? get(String key, [Object? fallback]) =>
      config.containsKey(key) ? config[key] : fallback;

  String get signature => '${get('your_signature', '') ?? ''}'.trim();

  bool get excuseDayPerLesson =>
      (get('excuse_day_per_lesson', false) == true);

  int intSetting(String key, int fallback) {
    final v = get(key, fallback);
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? fallback;
  }

  // -- tasks ----------------------------------------------------------------------

  List<ExcuseTask> Function({DateTime? today})? excuseTasksProvider;
  List<ExcuseTask> Function()? ignoredTasksProvider;
  bool Function(String dayIso, {DateTime? today})? dayFullyAbsentProvider;
  List<Map<String, Object?>> Function(String dayIso, {bool perLesson})?
      dayExcusePlanProvider;

  /// Pending excuse tasks — provided directly from `AppState.excuseTasks()`.
  List<ExcuseTask> excuseTasks({DateTime? today}) {
    if (excuseTasksProvider != null) {
      return excuseTasksProvider!(today: today);
    }
    return const [];
  }

  /// Currently ignored tasks — provided directly from `AppState.ignoredTasks()`.
  List<ExcuseTask> ignoredTasks() {
    if (ignoredTasksProvider != null) {
      return ignoredTasksProvider!();
    }
    return const [];
  }

  /// Groups tasks by day ISO, capped at 12 with the overflow count —
  /// like the `tasks[:12]` slice in `_excuse_cards`.
  ({Map<String, List<ExcuseTask>> byDay, int overflow}) groupedTasks(
      {DateTime? today}) {
    final tasks = excuseTasks(today: today);
    final byDay = <String, List<ExcuseTask>>{};
    for (final t in tasks.take(12)) {
      final iso = t.date != null
          ? isoDay(t.date!)
          : ('${t.rawTask['date'] ?? ''}');
      (byDay[iso] ??= []).add(t);
    }
    return (
      byDay: byDay,
      overflow: tasks.length > 12 ? tasks.length - 12 : 0,
    );
  }

  // -- ignore list (persisted, with rollback) ---------------------------------------

  bool _persistIgnored(Set<String> previous) {
    lastIgnoreError = '';
    try {
      final sorted = ignoredKeys.toList()..sort();
      if (!onSave({'ignored_excuses': sorted})) throw StateError('save');
      return true;
    } catch (e) {
      ignoredKeys
        ..clear()
        ..addAll(previous);
      lastIgnoreError = Strings.get('ignore_save_failed');
      return false;
    }
  }

  bool _changeIgnored({List<String> add = const [], List<String> remove = const []}) {
    final previous = Set<String>.of(ignoredKeys);
    for (final k in add) {
      if (k.isNotEmpty) ignoredKeys.add(k);
    }
    for (final k in remove) {
      ignoredKeys.remove(k);
    }
    if (ignoredKeys.length == previous.length &&
        ignoredKeys.containsAll(previous)) {
      return true;
    }
    final ok = _persistIgnored(previous);
    if (ok) notifyListeners();
    return ok;
  }

  /// Hides one task — like `state.ignore_excuse`. Returns the hidden
  /// key, or `''` when nothing was hidden.
  String ignoreExcuse(String key) {
    if (ignoreExcuseHook != null) {
      final res = ignoreExcuseHook!(key);
      if (res.isNotEmpty) lastMessage = Strings.get('ignored_msg');
      notifyListeners();
      return res;
    }
    lastIgnoreError = '';
    if (key.isEmpty) return '';
    if (!_changeIgnored(add: [key])) return '';
    lastMessage = Strings.get('ignored_msg');
    notifyListeners();
    return key;
  }

  /// Hides every pending task of one day — like `state.ignore_day`.
  /// Returns the hidden keys ([] when nothing was hidden / save failed).
  List<String> ignoreDay(String dayIso, {DateTime? today}) {
    if (ignoreDayHook != null) {
      final added = ignoreDayHook!(dayIso);
      if (added.isNotEmpty) lastMessage = Strings.get('ignored_msg');
      notifyListeners();
      return added;
    }
    lastIgnoreError = '';
    final added = excuseTasks(today: today)
        .where((t) =>
            (t.date != null
                ? isoDay(t.date!)
                : ('${t.rawTask['date'] ?? ''}')) ==
            dayIso &&
            !ignoredKeys.contains(t.key))
        .map((t) => t.key)
        .toList();
    if (added.isEmpty || !_changeIgnored(add: added)) return [];
    lastMessage = Strings.get('ignored_msg');
    notifyListeners();
    return added;
  }

  /// Like `state.unignore_excuse` / `state.unignore_keys`.
  bool unignoreKeys(List<String> keys) {
    if (unignoreKeysHook != null) {
      final ok = unignoreKeysHook!(keys);
      notifyListeners();
      return ok;
    }
    return _changeIgnored(remove: keys.where((k) => k.isNotEmpty).toList());
  }

  // -- templates ----------------------------------------------------------------------

  /// Kind-matched templates as `(name, text)` pairs — like
  /// `today._options_for` over `planner._template_options`.
  List<TemplateOption> templateOptions(String kind) {
    final k = kind.toLowerCase();
    List<String> keys;
    if (k == 'late') {
      keys = const ['late_income_excuses'];
    } else if (k == 'soon' || k == 'early') {
      keys = const ['left_soon_excuses'];
    } else if (k == 'short') {
      keys = const ['short_absence_excuses'];
    } else if (k == 'long' || k == 'day') {
      keys = const ['long_absence_excuses'];
    } else {
      keys = const [
        'long_absence_excuses',
        'short_absence_excuses',
        'late_income_excuses',
        'left_soon_excuses'
      ];
    }

    List<TemplateOption> collect(List<String> listKeys) {
      final out = <TemplateOption>[];
      for (final key in listKeys) {
        final values = templateSource(key);
        for (final v in values) {
          String name;
          String text;
          if (v is Map) {
            name = '${v['name'] ?? ''}'.trim();
            text = '${v['text'] ?? ''}';
          } else {
            name = '';
            text = '$v';
          }
          if (text.trim().isNotEmpty) out.add(TemplateOption(name, text));
        }
      }
      return out;
    }

    var found = collect(keys);
    if (found.isEmpty && keys.length == 1) {
      found = collect(const [
        'long_absence_excuses',
        'short_absence_excuses',
        'late_income_excuses',
        'left_soon_excuses'
      ]);
    }
    final sig = signature;
    if (sig.isNotEmpty) {
      // Never duplicate a signature the template already ends with
      // (case-insensitive, mirroring format_excuse_template), nor one its
      // {signature} placeholder brings when it is sent.
      found = [
        for (final o in found)
          TemplateOption(
              o.name,
              o.text.toLowerCase().contains(sig.toLowerCase()) ||
                      o.text.contains('{signature}')
                  ? o.text
                  : '${o.text.trimRight()}\n$sig')
      ];
    }
    if (found.isEmpty) {
      found = [TemplateOption('', Strings.get('default_excuse_template'))];
    }
    return found;
  }

  /// Dropdown labels: the user's name, `template_n N` (Template N) for unnamed ones —
  /// like `planner._template_labels`.
  List<String> templateLabels(List<TemplateOption> options) => [
        for (var i = 0; i < options.length; i++)
          options[i].name.isNotEmpty
              ? options[i].name
              : '${Strings.get('template_n')} ${i + 1}',
      ];

  /// Clamps a template pick into range — like `today._choose`.
  void chooseTemplate(String key, String? value, int n) {
    final idx =
        (int.tryParse(value ?? '') ?? 0).clamp(0, (n - 1).clamp(0, 1 << 30));
    pickedTemplates[key] = idx;
    chooseTemplateHook?.call(key, idx);
    notifyListeners();
  }

  /// The excuse text of the template picked for `key` —
  /// like `today._picked_option`.
  String pickedOption(String key, List<TemplateOption> options) {
    if (options.isEmpty) return '';
    final idx =
        (pickedTemplates[key] ?? 0).clamp(0, options.length - 1);
    return options[idx].text;
  }

  // -- day cards ------------------------------------------------------------------------

  /// Like `state.day_fully_absent`.
  bool dayFullyAbsent(String dayIso, {DateTime? today}) {
    if (dayFullyAbsentProvider != null) {
      return dayFullyAbsentProvider!(dayIso, today: today);
    }
    return false;
  }

  /// Like `state.excuse_day_per_lesson` + `set_excuse_day_per_lesson`
  /// (saved; false restores the old mode when the save fails).
  bool setExcuseDayPerLesson(bool on) {
    if (setExcuseDayPerLessonHook != null) {
      final ok = setExcuseDayPerLessonHook!(on);
      if (ok) {
        config['excuse_day_per_lesson'] = on;
      } else {
        lastMessage = Strings.get('save_failed');
      }
      notifyListeners();
      return ok;
    }
    final previous = excuseDayPerLesson;
    config['excuse_day_per_lesson'] = on;
    if (onSave({'excuse_day_per_lesson': on})) {
      notifyListeners();
      return true;
    }
    config['excuse_day_per_lesson'] = previous;
    lastMessage = Strings.get('save_failed');
    notifyListeners();
    return false;
  }

  bool isDayExpanded(String key, {bool defaultValue = false}) =>
      expandedDays[key] ?? defaultValue;

  void setDayExpanded(String key, bool expanded) {
    expandedDays[key] = expanded;
    setDayExpandedHook?.call(key, expanded);
    notifyListeners();
  }

  // -- sending ----------------------------------------------------------------------------

  /// Builds the single-lesson send request — like the `_send` closures
  /// in `_excuse_cards` (validation only; `onSend` does the session).
  ExcuseSendRequest? singleRequest(ExcuseTask task, String template) {
    final key = task.key;
    if (key.isEmpty || sendingKeys.contains(key)) return null;
    final text = template.trim().isEmpty ? null : template;
    return ExcuseSendRequest(
      scope: 'single',
      key: key,
      label: task.label,
      jobs: [ExcuseJob(task.rawTask, text)],
    );
  }

  List<Map<String, Object?>> dayExcusePlan(String dayIso,
      {bool perLesson = false}) {
    if (dayExcusePlanProvider != null) {
      return dayExcusePlanProvider!(dayIso, perLesson: perLesson);
    }
    return const [];
  }

  /// Builds the day send request — like `state.submit_day_excuse`
  /// (plan via [dayExcusePlan]; template only on absence excuses).
  ExcuseSendRequest? dayRequest(String dayIso, String template,
      {bool perLesson = false, DateTime? today}) {
    if (dayIso.isEmpty || sendingKeys.contains('day|$dayIso')) {
      return null;
    }
    final plan = dayExcusePlan(dayIso, perLesson: perLesson);
    if (plan.isEmpty) return null;
    final text = template.trim().isEmpty ? null : template;
    final day = DateTime.tryParse(dayIso);
    final label = day == null ? dayIso : dayKey(day);
    return ExcuseSendRequest(
      scope: 'day',
      key: 'day|$dayIso',
      label: label,
      jobs: [
        for (final excuse in plan)
          ExcuseJob(
              excuse,
              const {'pure days', 'days and hours'}
                      .contains('${excuse['type']}')
                  ? text
                  : null),
      ],
      perLesson: perLesson,
    );
  }

  /// Starts a send via [onSend] (marks the key as sending while the
  /// worker runs). When no signature is configured the request is
  /// parked in [pendingUnsignedRequest] for the signature dialog —
  /// like `today._when_signed`.
  Future<bool> send(ExcuseSendRequest request) async {
    if (sendingKeys.contains(request.key)) {
      lastMessage = Strings.get('already_running');
      notifyListeners();
      return false;
    }
    if (demoMode && !hasCredentials) {
      lastMessage = Strings.get('need_credentials');
      notifyListeners();
      return false;
    }
    if (signature.isEmpty) {
      pendingUnsignedRequest = request;
      notifyListeners();
      return false;
    }
    sendingKeys.add(request.key);
    lastMessage = Strings.get('excuse_sending');
    notifyListeners();
    try {
      final ok = await onSend(request);
      if (!ok && lastMessage == Strings.get('excuse_sending')) {
        // onSend gave no reason of its own.
        lastMessage = Strings.get('excuse_failed');
      }
      return ok;
    } finally {
      sendingKeys.remove(request.key);
      notifyListeners();
    }
  }

  /// Saves the signature from the dialog, then sends the parked
  /// request — like `_when_signed._save`.
  Future<bool> saveSignatureAndSend(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      lastMessage = Strings.get('wiz_need_signature');
      notifyListeners();
      return false;
    }
    if (!onSave({'your_signature': trimmed})) {
      lastMessage = Strings.get('save_failed');
      notifyListeners();
      return false;
    }
    config['your_signature'] = trimmed;
    final request = pendingUnsignedRequest;
    pendingUnsignedRequest = null;
    if (request == null) {
      notifyListeners();
      return true;
    }
    return send(request);
  }

  /// Marks tasks sent after the server confirms — like
  /// `state.mark_excused` (never optimistic).
  void markSent(Iterable<String> keys) {
    sentTaskKeys.addAll(keys.where((k) => k.isNotEmpty));
    for (final k in keys) {
      sendingKeys.remove(k);
    }
    notifyListeners();
  }

  // -- next lesson --------------------------------------------------------------------------

  /// Clock-aware next lesson card — like `today._next_lesson_card`.
  NextLessonInfo nextLesson(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final todayKey = dayKey(today);
    String headline(core.Lesson l) {
      var h = l.subject.isEmpty ? '?' : l.subject;
      if (l.period != null) {
        h += ' · ${l.period}. ${Strings.get('period').toLowerCase()}';
      }
      return h;
    }

    String meta(core.Lesson l) {
      final clock = core.lessonClock(
          {'time': l.time}, todayKey);
      final String timeLabel;
      if (clock != null) {
        final sh = clock.$1 ~/ 60;
        final sm = clock.$1 % 60;
        final eh = clock.$2 ~/ 60;
        final em = clock.$2 % 60;
        timeLabel =
            '$sh:${sm.toString().padLeft(2, '0')} – $eh:${em.toString().padLeft(2, '0')}';
      } else {
        timeLabel = shortTime(l.time);
      }
      return [l.teacher, l.room, timeLabel]
          .where((p) => p.isNotEmpty)
          .join(' · ');
    }

    String? alarmBadge(DateTime day) {
      final alarm = nextAlarm;
      if (alarm == null) return null;
      if (alarm.day != day) return null;
      if (alarm.ringDay == day) {
        return Strings.format('wakeup_badge', {'time': alarm.timeLabel});
      }
      return Strings.format('wakeup_badge_eve', {
        'day': dayName(alarm.ringDay, Strings.lang, short: true),
        'time': alarm.timeLabel,
      });
    }

    String? statusLabel(String status) {
      const keys = {
        'late': 'status_late',
        'soon': 'status_soon',
        'early': 'status_early',
        'absent': 'status_absent',
        'cancelled': 'status_lesson_cancelled',
        'excused': 'status_excused',
      };
      final key = keys[status.toLowerCase()];
      if (key == null && status.isEmpty) return null;
      return key == null ? status : Strings.get(key);
    }

    final todays = [
      for (final item in (timetable[todayKey] ?? const []))
        if (item is Map) item.cast<String, Object?>(),
    ];
    final resolved = core.resolveDayLessons(todays, now, todayKey);
    final phase = resolved['phase'] as String? ?? 'empty';
    final current = resolved['current'] as Map<Object?, Object?>?;
    final upcoming = resolved['upcoming'] as Map<Object?, Object?>?;
    if (phase == 'running' && current != null) {
      final currentMap = current.cast<String, Object?>();
      final parsed = core.Lesson.fromLegacy(currentMap, todayKey);
      final clock = core.lessonClock(currentMap, todayKey);
      final nowMin = now.hour * 60 + now.minute;
      final left = clock == null
          ? 1
          : (clock.$2 - nowMin).clamp(1, 1 << 30);
      return NextLessonInfo(
        phase: 'running',
        headline: headline(parsed),
        meta: meta(parsed),
        deltaText: Strings.format('ends_in', {'m': left}),
        statusLabel: statusLabel(parsed.status),
        statusKind: lessonKind(parsed.status),
        headingLabel: Strings.get('now_running'),
      );
    }
    if ((phase == 'before' || phase == 'between') &&
        upcoming != null) {
      final upcomingMap = upcoming.cast<String, Object?>();
      final parsed = core.Lesson.fromLegacy(upcomingMap, todayKey);
      final clock = core.lessonClock(upcomingMap, todayKey);
      final nowMin = now.hour * 60 + now.minute;
      final wait = clock == null
          ? 1
          : (clock.$1 - nowMin).clamp(1, 1 << 30);
      return NextLessonInfo(
        phase: phase,
        headline: headline(parsed),
        meta: meta(parsed),
        deltaText: Strings.format('starts_in', {'m': wait}),
        statusLabel: statusLabel(parsed.status),
        statusKind: lessonKind(parsed.status),
        headingLabel: Strings.get(
            phase == 'before' ? 'before_school' : 'up_next'),
        alarmBadge: alarmBadge(today),
      );
    }
    // Evening / weekend / holiday: the next school day's first lesson.
    for (var ahead = 1; ahead <= 7; ahead++) {
      final day = core.addDays(today, ahead);
      final key = dayKey(day);
      final rows = [
        for (final item in (timetable[key] ?? const []))
          if (item is Map) item.cast<String, Object?>(),
      ].where((r) =>
          core.Lesson.fromLegacy(r, key).status != 'cancelled').toList();
      if (rows.isEmpty) continue;
      rows.sort((a, b) {
        final ca = core.lessonClock(a, key);
        final cb = core.lessonClock(b, key);
        return (ca?.$1 ?? 9999).compareTo(cb?.$1 ?? 9999);
      });
      final parsed = core.Lesson.fromLegacy(rows.first, key);
      return NextLessonInfo(
        phase: 'next-day',
        headline: headline(parsed),
        meta: meta(parsed),
        headingLabel:
            '${Strings.get('next_school_day')}: ${dayName(day, Strings.lang)} ${czDay(day)}',
        alarmBadge: alarmBadge(day),
      );
    }
    return NextLessonInfo(
        phase: 'empty',
        headline: demoMode ? Strings.get('no_data') : Strings.get('no_lessons_today'),
        meta: '');
  }

  // -- week changes ---------------------------------------------------------------------------

  /// Real schedule changes (diffed vs stable) + teacher notes, this
  /// week only, in timetable order — like `today._changes_block`.
  ({List<TodayChange> changes, List<TodayChange> notes}) weekChanges(
      DateTime now) {
    List<Map<String, Object?>> changes;
    List<Map<String, Object?>> notes;
    try {
      changes = core.iterChanges(timetable, stableBaseline, stableComplete);
      notes = core.iterNotes(timetable, stableBaseline, stableComplete);
    } catch (_) {
      return (changes: const [], notes: const []);
    }
    final today = DateTime(now.year, now.month, now.day);
    final monday = core.addDays(today, -(today.weekday - 1));
    final sunday = core.addDays(monday, 6);

    int orderOf(Map<String, Object?> item) {
      final rawLesson = item['lesson'] as Map<Object?, Object?>?;
      final lessonMap = rawLesson?.cast<String, Object?>() ?? const {};
      final period =
          core.Lesson.fromLegacy(lessonMap, item['day']).period;
      return period ?? 99;
    }

    final weekChanges = changes
        .where((c) {
          final day = c['day'] as DateTime?;
          return day != null &&
              !day.isBefore(monday) &&
              !day.isAfter(sunday);
        })
        .toList()
      ..sort((a, b) {
        final da = a['day'] as DateTime;
        final db = b['day'] as DateTime;
        final c = da.compareTo(db);
        return c != 0 ? c : orderOf(a).compareTo(orderOf(b));
      });
    final weekNotes = notes
        .where((n) {
          final day = n['day'] as DateTime?;
          return day != null &&
              !day.isBefore(monday) &&
              !day.isAfter(sunday);
        })
        .toList()
      ..sort((a, b) {
        final da = a['day'] as DateTime;
        final db = b['day'] as DateTime;
        final c = da.compareTo(db);
        return c != 0 ? c : orderOf(a).compareTo(orderOf(b));
      });
    String titleOf(Map<String, Object?> item) {
      final rawLesson = item['lesson'] as Map<Object?, Object?>?;
      final lessonMap = rawLesson?.cast<String, Object?>() ?? const {};
      final parsed =
          core.Lesson.fromLegacy(lessonMap, item['day']);
      var title = '${parsed.subject.isEmpty ? '?' : parsed.subject} — '
          '${czDay(item['day_key'])}';
      if (parsed.period != null) title += ' · ${parsed.period}.';
      return title;
    }

    return (
      changes: [
        for (final item in weekChanges.take(5))
          TodayChange(
            title: titleOf(item),
            note: (item['diff'] as core.LessonDiff?)?.note,
          )
      ],
      notes: [
        for (final item in weekNotes.take(3))
          TodayChange(
            title: () {
              final rawLesson = item['lesson'] as Map<Object?, Object?>?;
              final lessonMap = rawLesson?.cast<String, Object?>() ?? const {};
              final parsed = core.Lesson.fromLegacy(lessonMap, item['day']);
              final note = (item['diff'] as core.LessonDiff?)?.note ?? '';
              final subj = parsed.subject.isEmpty ? '?' : parsed.subject;
              return '$subj — ${czDay(item['day_key'])}: $note';
            }(),
            note: (item['diff'] as core.LessonDiff?)?.note,
            isNote: true,
          )
      ],
    );
  }

  /// Lunch line — like the lunch block in `today.build`.
  String lunchText(DateTime now) {
    final key = dayKey(DateTime(now.year, now.month, now.day));
    final menu = food[key] ?? const {};
    final order = orders[key] ?? webOrders[key];
    if (cancelledLunches.contains(key) ||
        (order != null && order.contains('&-1&'))) {
      return Strings.get('no_lunch');
    }
    if (order != null && order.isNotEmpty) {
      return '${Strings.get('ordered')}: ${menu[order] ?? order}';
    }
    if (menu.isNotEmpty) {
      return menu.values.take(3).join(', ');
    }
    return demoMode ? Strings.get('no_data') : Strings.get('no_lunch');
  }

  /// Planner tip: next recommended day off within two weeks —
  /// like `today._planner_tip`.
  String? plannerTip(DateTime now) {
    if (demoMode) return null;
    final today = DateTime(now.year, now.month, now.day);
    final limit = core.addDays(today, 14);
    final upcoming = plannerRecommended
        .where((d) => !d.isBefore(today) && !d.isAfter(limit))
        .toList()
      ..sort();
    if (upcoming.isEmpty) return null;
    final day = upcoming.first;
    return Strings.format('planner_next',
        {'day': '${dayName(day, Strings.lang)} ${czDay(day)}'});
  }
}
