import 'package:flutter/foundation.dart';

import '../common/app_strings.dart';
import '../common/format.dart';
import '../common/lesson_model.dart';
import '../common/schedule_logic.dart';

/// How one lesson renders — identical rules for the grid and the list,
/// like `timetable._Look`.
class LessonLook {
  final LessonRow parsed;
  final LessonDiff diff;
  final bool cancelled;
  final Set<String> changed;

  /// Attendance bar color key: `absent | late | excused | ''`.
  final String bar;

  /// Tile fill key: `accent | bar | card | none`.
  final String fill;

  /// One short label (`Absence`, `Suplování`, …), or empty.
  final String tag;

  /// Tag color key.
  final String tagColor;

  final String tooltip;

  const LessonLook({
    required this.parsed,
    required this.diff,
    required this.cancelled,
    required this.changed,
    required this.bar,
    required this.fill,
    required this.tag,
    required this.tagColor,
    required this.tooltip,
  });
}

/// One field row of the lesson detail dialog.
class DetailRow {
  final String label;
  final String value;
  final bool accent;
  const DetailRow(this.label, this.value, {this.accent = false});
}

/// Lesson detail dialog content — like `timetable._detail_dialog`.
class LessonDetail {
  final String subject;
  final String subtitle;
  final List<DetailRow> fields;
  final List<String> badges;
  final String? note;
  final String? changeSummary;
  const LessonDetail({
    required this.subject,
    required this.subtitle,
    this.fields = const [],
    this.badges = const [],
    this.note,
    this.changeSummary,
  });
}

/// Timetable (Rozvrh) screen state + logic — a `ChangeNotifier` port of
/// `views/timetable.py`.
///
/// Week grouping, week navigation (stepping from live state so rapid
/// clicks never lose a week), the stable-template view, grid/list
/// toggle, the shared lesson look, focus period and the detail data
/// all live here. Rendering sizes come from the view via [cellChars]
/// / [phoneCellWidth].
class TimetableController extends ChangeNotifier {
  final AppStrings s;

  TimetableController({this.s = const AppStrings()});

  // -- inputs -------------------------------------------------------------------

  /// `{dayKey: [lessonDict, ...]}` with parseable day keys.
  Map<String, List<Object?>> timetable = {};

  /// Stable baseline for change detection (`stable_baseline()`).
  Map<String, List<SlotBaseline>> stableBaseline = {};
  bool stableComplete = false;

  bool demoMode = false;

  // -- navigation + view prefs (like AppState fields) -----------------------------

  /// Pinned week Monday ISO (`timetable_monday_iso`), null = auto.
  String? timetableMondayIso;

  /// `table` or `list` (`timetable_view`).
  String timetableView = 'table';

  /// Stable-template view toggle (`show_stable_timetable`, in-memory).
  bool showStableTimetable = false;

  /// Day cards folded open (`tt:<iso>` keys).
  final Map<String, bool> expandedDays = {};

  /// Optional live-state delegation hooks (wired by `timetable_live.dart`).
  void Function(String? mondayIso)? goTimetableWeekHook;
  void Function(String view)? setTimetableViewHook;
  void Function(bool show)? setShowStableHook;
  void Function(String key, bool expanded)? setDayExpandedHook;

  // -- week grouping ---------------------------------------------------------------

  /// Groups `{day: lessons}` by week Monday — like `timetable._weeks`.
  /// Keys in any date format; unparseable keys are skipped.
  Map<DateTime, Map<DateTime, List<Map<String, Object?>>>> weeks() {
    final out = <DateTime, Map<DateTime, List<Map<String, Object?>>>>{};
    timetable.forEach((dayKey, lessons) {
      final day = parseCzDate(dayKey);
      if (day == null) return;
      final monday = weekMonday(day);
      final rows = <Map<String, Object?>>[];
      for (final item in lessons) {
        if (item is Map) rows.add(item.cast<String, Object?>());
      }
      (out[monday] ??= {})[day] = rows;
    });
    return out;
  }

  /// Resolves the current week — like `timetable._resolve_current`.
  DateTime resolveCurrent(
      Map<DateTime, Map<DateTime, List<Map<String, Object?>>>> weeks,
      {DateTime? today}) {
    final now = today ?? DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final thisMon = weekMonday(day);
    if (timetableMondayIso != null) {
      try {
        final pinned = DateTime.parse(timetableMondayIso!);
        final key = DateTime(pinned.year, pinned.month, pinned.day);
        if (weeks.containsKey(key)) return key;
      } catch (_) {}
    }
    if (weeks.containsKey(thisMon)) return thisMon;
    final mondays = weeks.keys.toList()..sort();
    if (mondays.isEmpty) return thisMon;
    final future = mondays.where((m) => !m.isBefore(thisMon)).toList();
    return future.isNotEmpty ? future.first : mondays.last;
  }

  /// Atomic week switch: stable view off + new week, one notify —
  /// like `state.go_timetable_week`. A no-op target emits nothing.
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
    goTimetableWeekHook?.call(mondayIso);
    if (changed) notifyListeners();
  }

  /// Steps one week back/forward from live state — like the `_go`
  /// closure in `timetable.build` (resolves at click time so rapid
  /// clicks never lose a week).
  void stepWeek(int delta, {DateTime? today}) {
    final all = weeks();
    final keys = all.keys.toList()..sort();
    if (keys.isEmpty) return;
    final base = resolveCurrent(all, today: today);
    var at = keys.indexOf(base);
    if (at < 0) at = 0;
    final next = keys[(at + delta).clamp(0, keys.length - 1)];
    goTimetableWeek(isoDay(next));
  }

  void setTimetableView(String view) {
    if (view != 'table' && view != 'list') return;
    if (timetableView == view) return;
    timetableView = view;
    setTimetableViewHook?.call(view);
    notifyListeners();
  }

  void setShowStable(bool show) {
    if (showStableTimetable == show) return;
    showStableTimetable = show;
    setShowStableHook?.call(show);
    notifyListeners();
  }

  bool isDayExpanded(String key, {bool defaultValue = false}) =>
      expandedDays[key] ?? defaultValue;

  void setDayExpanded(String key, bool expanded) {
    expandedDays[key] = expanded;
    setDayExpandedHook?.call(key, expanded);
    notifyListeners();
  }

  // -- periods --------------------------------------------------------------------------

  /// Period order — like `timetable._period_of`.
  int? periodOf(Map<String, Object?> raw, Object? day) {
    final parsed = LessonRow.fromLegacy(raw, day);
    int? num = extractLessonNum(parsed.time);
    num ??= parsed.period;
    return num;
  }

  /// Most common clock time for `period` across the week —
  /// like `timetable._period_time`.
  String periodTime(
      Map<DateTime, List<Map<String, Object?>>> weekDays, int period) {
    final seen = <String, int>{};
    weekDays.forEach((day, lessons) {
      for (final raw in lessons) {
        if (periodOf(raw, day) == period) {
          final label =
              shortTime(LessonRow.fromLegacy(raw, day).time);
          if (label.isNotEmpty) {
            seen[label] = (seen[label] ?? 0) + 1;
          }
        }
      }
    });
    if (seen.isEmpty) return '';
    return seen.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
  }

  /// Lessons that take place (cancelled rows dropped) —
  /// like `timetable._taught`.
  List<Map<String, Object?>> taught(List<Map<String, Object?>> lessons) =>
      lessons
          .where((r) =>
              LessonRow.fromLegacy(r).status != 'cancelled')
          .toList();

  /// Period order; cancelled rows carry a bare clock so the period
  /// comes from the row, and in a swapped slot the lesson taught
  /// instead goes first — like `timetable._list_order`.
  int listOrderKey(Map<String, Object?> raw, Object? day) {
    final period = periodOf(raw, day) ?? 99;
    final cancelled =
        LessonRow.fromLegacy(raw, day).status == 'cancelled' ? 1 : 0;
    return period * 2 + cancelled;
  }

  /// A day's lesson numbers from period 1 (0 when it has one) to its
  /// last lesson — like `timetable._day_span`.
  List<int> daySpan(Map<int, List<Map<String, Object?>>>? byPeriod) {
    if (byPeriod == null || byPeriod.isEmpty) return const [];
    final keys = byPeriod.keys.toList()..sort();
    final first = keys.first < 1 ? keys.first : 1;
    return [for (var p = first; p <= keys.last; p++) p];
  }

  /// Merges split-group lessons sharing one period into a single
  /// cell — like `timetable._combined_cell`.
  Map<String, Object?>? combinedCell(List<Map<String, Object?>>? raws) {
    var list =
        (raws ?? const []).whereType<Map<String, Object?>>().toList();
    final held = taught(list);
    if (held.isNotEmpty) list = held;
    if (list.isEmpty) return null;
    if (list.length == 1) return list.first;
    final subjects = <String>[];
    final shorts = <String>[];
    final teachers = <String>[];
    final rooms = <String>[];
    void add(List<String> acc, Object? v) {
      final val = '${v ?? ''}'.trim();
      if (val.isNotEmpty && !acc.contains(val)) acc.add(val);
    }

    for (final r in list) {
      add(subjects, r['subject']);
      add(shorts, r['subject_short']);
      add(teachers, r['teacher']);
      add(rooms, r['room']);
    }
    final combined = Map<String, Object?>.of(list.first);
    if (subjects.isNotEmpty) combined['subject'] = subjects.join(' / ');
    if (shorts.isNotEmpty) {
      combined['subject_short'] = shorts.join(' / ');
    }
    if (teachers.length > 1) combined['teacher'] = teachers.join(', ');
    if (rooms.length > 1) combined['room'] = rooms.join(', ');
    return combined;
  }

  // -- abbreviations ----------------------------------------------------------------------

  static const Set<String> _stopwords = {
    'a', 'i', 'z', 'ze', 's', 'se', 'v', 've', 'na', 'pro',
    'and', 'of', 'the',
  };

  /// Initials of a multi-word name — like `timetable._abbrev`.
  /// PLAN §3.5: first characters via runes (UTF-16-safe), uppercased.
  String abbrev(String subject) {
    final words = subject
        .split(RegExp(r'[\s/\-]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final significant =
        words.where((w) => !_stopwords.contains(w.toLowerCase())).toList();
    if (significant.length < 2) return subject;
    return significant
        .map((w) => String.fromCharCode(w.runes.first).toUpperCase())
        .join()
        .characters(length: 5);
  }

  /// Full name when it fits, else Bakaláři's short name (or initials) —
  /// like `timetable._cell_subject`.
  String cellSubject(
      Map<String, Object?> raw, String full, int maxChars) {
    full = full.isEmpty ? '?' : full;
    if (full.length <= maxChars) return full;
    final short = '${raw['subject_short'] ?? ''}'.trim();
    if (short.isNotEmpty && short != full) return short;
    return abbrev(full);
  }

  /// Roughly how many bold characters fit on one line of a grid cell —
  /// like `timetable._cell_chars`.
  int cellChars(double widthPx, int periods) {
    final width = widthPx > 0 ? widthPx : 1240.0;
    const chrome = 100 + 2 * 24;
    const gutter = 72;
    const gap = 4;
    final usable =
        width - chrome - gutter - gap * (periods > 0 ? periods : 1);
    final cell = usable / (periods > 0 ? periods : 1);
    final chars = ((cell - 24) / 7.5).truncate();
    return chars < 3 ? 3 : chars;
  }

  /// Phone cell width: fixed minimum, stretching on wider screens —
  /// like `timetable._phone_table`.
  double phoneCellWidth(double pageWidth, int periods) {
    const gutter = 52.0;
    const chrome = 2 * 12.0;
    const gap = 4.0;
    const rowPad = 2.0;
    final free =
        (pageWidth > 0 ? pageWidth : 390.0) - chrome - gutter - gap - 2 * rowPad;
    final per = periods > 0
        ? (free - gap * (periods - 1)) / periods
        : free;
    return per < 92.0 ? 92.0 : per;
  }

  // -- focus -----------------------------------------------------------------------------

  /// `(period, 'now' | 'next')` on today's row, `(null, '')` elsewhere —
  /// like `timetable._focus_period`.
  ({int? period, String kind}) focusPeriod(
      List<Map<String, Object?>> lessons, DateTime day, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    if (day != today) return (period: null, kind: '');
    final upcoming = <({int start, int period})>[];
    for (final raw in lessons) {
      if (LessonRow.fromLegacy(raw, day).status == 'cancelled') {
        continue;
      }
      final period = periodOf(raw, day);
      final span = clockRange(
          shortTime(LessonRow.fromLegacy(raw, day).time));
      if (period == null || span == null) continue;
      final nowMin = now.hour * 60 + now.minute;
      if (span.startMin <= nowMin && nowMin < span.endMin) {
        return (period: period, kind: 'now');
      }
      if (span.startMin > nowMin) {
        upcoming.add((start: span.startMin, period: period));
      }
    }
    if (upcoming.isNotEmpty) {
      upcoming.sort((a, b) => a.start.compareTo(b.start));
      return (period: upcoming.first.period, kind: 'next');
    }
    return (period: null, kind: '');
  }

  // -- look ----------------------------------------------------------------------------------

  LessonDiff _diffOf(Map<String, Object?> lesson, DateTime day) {
    try {
      return classifyLesson(lesson,
          day: day, baseline: stableBaseline, complete: stableComplete);
    } catch (_) {
      return LessonDiff(note: '${lesson['change'] ?? ''}');
    }
  }

  /// How one lesson renders — like `timetable._look`.
  LessonLook look(Map<String, Object?> raw, DateTime day) {
    final parsed = LessonRow.fromLegacy(raw, day);
    final diff = _diffOf(raw, day);
    final status = parsed.status.toLowerCase();
    final cancelled = status == 'cancelled';
    final changed = diff.isChange ? diff.changed.toSet() : <String>{};
    // Attendance bar.
    String bar;
    switch (status) {
      case 'absent':
        bar = 'absent';
      case 'late':
      case 'early':
      case 'soon':
        bar = 'late';
      case 'excused':
        bar = 'excused';
      default:
        bar = '';
    }
    // Tile fill.
    String fill;
    if (cancelled) {
      fill = 'none';
    } else if (diff.isChange) {
      fill = 'accent';
    } else if (bar.isNotEmpty) {
      fill = 'bar';
    } else {
      fill = 'card';
    }
    // Tag.
    String tag;
    String tagColor;
    if (cancelled) {
      tag = s.get('status_lesson_cancelled');
      tagColor = 'muted';
    } else if (status.isNotEmpty) {
      tag = statusLabel(status);
      tagColor = bar.isNotEmpty ? bar : 'muted';
    } else if (diff.isChange) {
      tag = changeTag(changed);
      tagColor = 'accent';
    } else {
      tag = '';
      tagColor = 'faint';
    }
    final lines = <String>[parsed.subject.isEmpty ? '?' : parsed.subject];
    final who = [parsed.teacher, parsed.room]
        .where((p) => p.isNotEmpty)
        .join(' · ');
    if (who.isNotEmpty) lines.add(who);
    final clock = shortTime(parsed.time);
    if (clock.isNotEmpty) lines.add(clock);
    if (status.isNotEmpty && !cancelled) lines.add(statusLabel(status));
    if (diff.isChange || diff.note.isNotEmpty) {
      lines.add(diffTooltip(diff));
    }
    return LessonLook(
      parsed: parsed,
      diff: diff,
      cancelled: cancelled,
      changed: changed,
      bar: bar,
      fill: fill,
      tag: tag,
      tagColor: tagColor,
      tooltip: lines.join('\n'),
    );
  }

  /// Like `timetable._change_tag`.
  String changeTag(Set<String> changed) {
    if (changed.contains('added')) return s.get('tag_added');
    if (changed.contains('teacher')) return s.get('tag_substitution');
    if (changed.contains('room') &&
        changed.difference({'room', 'notice'}).isEmpty) {
      return s.get('tag_room_change');
    }
    return s.get('real_change');
  }

  String statusLabel(String status) {
    const keys = {
      'late': 'status_late',
      'soon': 'status_soon',
      'early': 'status_early',
      'absent': 'status_absent',
      'cancelled': 'status_lesson_cancelled',
      'excused': 'status_excused',
    };
    final key = keys[status.toLowerCase()];
    return key == null ? status : s.get(key);
  }

  /// Like `timetable._diff_summary`.
  String diffSummary(LessonDiff diff) {
    const labels = {
      'subject': 'field_subject',
      'teacher': 'field_teacher',
      'room': 'field_room',
      'time': 'field_time',
      'status': 'field_status',
      'notice': 'field_notice',
    };
    final fields = [
      for (final f in diff.changed)
        if (labels.containsKey(f)) s.get(labels[f]!)
    ];
    final joined = fields.isEmpty ? s.get('real_change') : fields.join(', ');
    return s.tr('changed_to', {'fields': joined});
  }

  /// Like `timetable._diff_tooltip`.
  String diffTooltip(LessonDiff diff) {
    var tip = diff.isChange ? diffSummary(diff) : s.get('note_label');
    if (diff.note.isNotEmpty) tip += ': ${diff.note}';
    return tip;
  }

  // -- detail -----------------------------------------------------------------------------------

  /// Lesson detail dialog content — like `timetable._detail_dialog`.
  LessonDetail detail(Map<String, Object?> lesson, DateTime day) {
    final parsed = LessonRow.fromLegacy(lesson, day);
    final subject =
        parsed.subject.isEmpty ? '?' : parsed.subject;
    final dayName_ = dayName(day, s.lang, short: false);
    final clock = shortTime(parsed.time);
    String subtitle;
    if (parsed.period != null) {
      subtitle = '$dayName_ ${czDayYear(day)} · ${parsed.period}. '
          '${s.get('period').toLowerCase()}'
          '${clock.isNotEmpty ? ' · $clock' : ''}';
    } else {
      subtitle = '$dayName_ ${czDayYear(day)}'
          '${clock.isNotEmpty ? ' · $clock' : ''}';
    }
    final badges = <String>[];
    if (parsed.status.isNotEmpty) {
      badges.add(statusLabel(parsed.status));
    }
    final diff = _diffOf(lesson, day);
    if (diff.isChange) badges.add(diffTooltip(diff));
    final fields = <DetailRow>[];
    void add(String key, String value) {
      if (value.isNotEmpty) fields.add(DetailRow(s.get(key), value));
    }

    add('room', parsed.room);
    add('teacher', parsed.teacher);
    add('group', '${lesson['group'] ?? ''}');
    add('theme', '${lesson['theme'] ?? ''}');
    String? changeSummary;
    if (diff.isChange) {
      // What changed vs the stable timetable (usual vs actual).
      Map<String, String> usual = const {};
      try {
        final key =
            slotKey(day.weekday - 1, parsed.period ?? -1);
        final variants = stableBaseline[key];
        final closest =
            closestVariant(variants, lesson, day);
        if (closest != null) {
          usual = {
            'subject': closest.subject,
            'teacher': closest.teacher,
            'room': closest.room,
          };
        }
      } catch (_) {}
      final actual = {
        'subject': parsed.subject,
        'teacher': parsed.teacher,
        'room': parsed.room,
      };
      const names = {
        'subject': 'col_subject',
        'teacher': 'teacher',
        'room': 'room',
      };
      var addedSummary = false;
      for (final field in const [
        'subject',
        'teacher',
        'room',
        'time',
        'status',
        'notice'
      ]) {
        if (!diff.changed.contains(field)) continue;
        if (usual.containsKey(field)) {
          final old = usual[field]!.isEmpty ? '—' : usual[field]!;
          final current =
              actual[field]!.isEmpty ? '—' : actual[field]!;
          if (old != current) {
            fields.add(DetailRow(
                '${s.get('stable_value')} · ${s.get(names[field]!)}',
                old));
            fields.add(DetailRow(
                '${s.get('current_value')} · ${s.get(names[field]!)}',
                current,
                accent: true));
          }
        } else if (!addedSummary) {
          changeSummary = diffSummary(diff);
          addedSummary = true;
        }
      }
    }
    return LessonDetail(
      subject: subject,
      subtitle: subtitle,
      fields: fields,
      badges: badges,
      note: diff.note.isEmpty ? null : diff.note,
      changeSummary: changeSummary,
    );
  }

  /// `7 hodin · 2× Absence · 1× Změna` summary for a day card —
  /// like `timetable._day_summary`.
  String daySummary(
      List<Map<String, Object?>> lessons, DateTime day) {
    final counts = <String, int>{};
    for (final raw in lessons) {
      final tag = look(raw, day).tag;
      if (tag.isNotEmpty) counts[tag] = (counts[tag] ?? 0) + 1;
    }
    final parts = [lessonsText(taught(lessons).length, s)];
    counts.forEach((tag, n) => parts.add('$n× $tag'));
    return parts.join(' · ');
  }
}

extension on String {
  /// First 5 runes (UTF-16-safe truncation for initials).
  String characters({int? length}) {
    if (length == null) return this;
    return runes.take(length).map(String.fromCharCode).join();
  }
}
