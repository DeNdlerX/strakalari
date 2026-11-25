// What a refresh brought since the previous one: marks, absences,
// timetable changes.
//
// Port of strakalari/core/news.py. Fresh data is compared with the data
// cache before the refresh saves over it, so each novelty is reported once
// — also across the tray and the window (separate processes take turns
// through the session lock and share the cache). Only what the previous
// state can be compared with counts: the first sync, a failed part of the
// fetch, or timetable days loaded for the first time (history weeks, a week
// entering the window) report nothing.
import 'package:clock/clock.dart';

import 'i18n.dart';
import 'models.dart';
import 'planning/grades.dart';
import 'planning/schedule.dart';

/// Lesson states that record the student's (partial) absence.
const Set<String> absenceStates = {
  'absent',
  'late',
  'early',
  'soon',
  'excused',
};

/// Items named in one notification; the rest are only counted.
const int maxItems = 4;

/// ``(event, message)`` notifications for what [fresh] adds to [previous].
///
/// [fresh] is the refresh's cache payload (only the parts fetched OK).
List<MapEntry<String, String>> findNews(
  Map<String, Object?>? previous,
  Map<String, Object?>? fresh, [
  DateTime? today,
]) {
  previous = previous ?? {};
  fresh = fresh ?? {};
  String? message(String one, String many, List<String> items) =>
      items.isEmpty ? null : _message(one, many, items);
  final found = [
    (
      'new_mark',
      message('news_mark', 'news_marks', newMarks(previous, fresh)),
    ),
    (
      'new_quarterly_mark',
      message(
        'news_quarterly',
        'news_quarterlies',
        newQuarterlyMarks(previous, fresh),
      ),
    ),
    ('new_absence', _absencesMessage(previous, fresh)),
    (
      'timetable_change',
      message(
        'news_change',
        'news_changes',
        newChanges(previous, fresh, today ?? clock.now()),
      ),
    ),
  ];
  return [
    for (final (event, text) in found)
      if (text != null) MapEntry(event, text),
  ];
}

/// Message headings (one, many) per absence kind; the rest are absences.
const Map<String, (String, String)> _absenceHeadings = {
  'late': ('news_late', 'news_lates'),
  'soon': ('news_early', 'news_earlies'),
  'early': ('news_early', 'news_earlies'),
};

/// New absences headed by their kind ("Pozdní příchod: …"), a line each.
String? _absencesMessage(
  Map<String, Object?> previous,
  Map<String, Object?> fresh,
) {
  final groups = <(String, String), List<String>>{};
  for (final (kind, label) in _newAbsenceLessons(previous, fresh)) {
    groups
        .putIfAbsent(
          _absenceHeadings[kind] ?? ('news_absence', 'news_absences'),
          () => [],
        )
        .add(label);
  }
  if (groups.isEmpty) return null;
  return [
    for (final group in groups.entries)
      _message(group.key.$1, group.key.$2, group.value),
  ].join('\n');
}

String _message(String one, String many, List<String> items) {
  var shown = items.take(maxItems).join('; ');
  if (items.length > maxItems) {
    shown += ' ${t('news_more', args: {'n': items.length - maxItems})}';
  }
  return t(items.length == 1 ? one : many, args: {'items': shown});
}

/// 'Matematika 14. 10., 3. hodina'.
String _label(String subject, DateTime? day, int? period) {
  var text = subject.isEmpty ? '?' : subject;
  if (day != null) {
    text += ' ${day.day}. ${day.month}.';
  }
  if (period != null) {
    text += ", ${t('period_label', args: {'n': period})}";
  }
  return text;
}

Map<String, Object?> _strMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return {for (final e in value.entries) '${e.key}': e.value};
  }
  return {};
}

// -- marks ---------------------------------------------------------------

/// Marks the previous grades did not have (announced ``?`` marks skipped).
List<String> newMarks(
  Map<String, Object?>? previous,
  Map<String, Object?>? fresh,
) {
  final old = previous?['grades'];
  final current = fresh?['grades'];
  if (old is! Map || current is! Map) {
    return [];
  } // first sync, or the grades did not load this time
  final items = <String>[];
  for (final entry in current.entries) {
    if (entry.value is! List) continue;
    final List<Object?> before = old[entry.key] is List
        ? old[entry.key] as List
        : [];
    // An announced mark that is now given keeps its id: still news.
    final known = <String>{};
    final beforeKeys = markKeys(before);
    for (var i = 0; i < beforeKeys.length && i < before.length; i++) {
      final mark = before[i];
      if (mark is Map && !isPlanned(_strMap(mark))) {
        known.add(beforeKeys[i]);
      }
    }
    final keys = markKeys(entry.value as List);
    final marks = entry.value as List;
    for (var i = 0; i < keys.length && i < marks.length; i++) {
      final mark = marks[i];
      if (known.contains(keys[i]) || mark is! Map || isPlanned(_strMap(mark))) {
        continue;
      }
      final markMap = _strMap(mark);
      final text = '${entry.key} ${'${markMap['Grade'] ?? ''}'.trim()}'.trim();
      final caption = '${markMap['Caption'] ?? ''}'.trim();
      items.add(caption.isNotEmpty ? '$text ($caption)' : text);
    }
  }
  return items;
}

/// Quarterly marks that are new or changed since the previous grades.
List<String> newQuarterlyMarks(
  Map<String, Object?>? previous,
  Map<String, Object?>? fresh,
) {
  final old = previous?['quarterly_marks'];
  final current = fresh?['quarterly_marks'];
  if (old is! Map || current is! Map) {
    return [];
  } // first sync (or first since the app read them), or not loaded

  String grade(Object? entry) =>
      entry is Map ? '${entry['Grade'] ?? ''}'.trim() : '';
  return [
    for (final entry in current.entries)
      if (grade(entry.value).isNotEmpty &&
          grade(entry.value) != grade(old[entry.key]))
        '${entry.key} ${grade(entry.value)}',
  ];
}

// -- timetable -----------------------------------------------------------

/// Lessons per canonical day (``DD.MM.YYYY``).
Map<String, List<Map<String, Object?>>> _days(Object? timetable) {
  final out = <String, List<Map<String, Object?>>>{};
  if (timetable is Map) {
    for (final entry in timetable.entries) {
      if (entry.value is List) {
        out.putIfAbsent(canonicalDayKey(entry.key), () => []).addAll([
          for (final raw in (entry.value as List))
            if (raw is Map) _strMap(raw),
        ]);
      }
    }
  }
  return out;
}

DateTime _byDate(MapEntry<String, List<Map<String, Object?>>> item) =>
    parseCzDate(item.key) ?? DateTime(1);

/// Which lesson of the day (period, else its time).
Object _slot(Lesson lesson) =>
    lesson.period ?? (lesson.time.isNotEmpty ? lesson.time : lesson.subject);

/// Lessons newly recorded as missed (absent, late, left early) on known days.
List<String> newAbsences(
  Map<String, Object?>? previous,
  Map<String, Object?>? fresh,
) => [for (final (_, label) in _newAbsenceLessons(previous, fresh)) label];

/// (status, label) of each lesson [newAbsences] reports.
List<(String, String)> _newAbsenceLessons(
  Map<String, Object?>? previous,
  Map<String, Object?>? fresh,
) {
  final oldDays = _days(previous?['timetable']);
  final items = <(String, String)>[];
  final freshDays = _days(fresh?['timetable']).entries.toList()
    ..sort((a, b) => _byDate(a).compareTo(_byDate(b)));
  for (final entry in freshDays) {
    if (!oldDays.containsKey(entry.key)) {
      continue; // nothing to compare with
    }
    final known = {
      for (final raw in oldDays[entry.key]!)
        if (absenceStates.contains(Lesson.fromLegacy(raw, entry.key).status))
          _slot(Lesson.fromLegacy(raw, entry.key)),
    };
    for (final raw in entry.value) {
      final lesson = Lesson.fromLegacy(raw, entry.key);
      if (absenceStates.contains(lesson.status) &&
          !known.contains(_slot(lesson))) {
        known.add(_slot(lesson));
        items.add((
          lesson.status,
          _label(lesson.subject, lesson.day, lesson.period),
        ));
      }
    }
  }
  return items;
}

/// The scraped stable timetable (this run's, else the cached one).
///
/// Both states are diffed against the same one, so a stable-view scrape
/// that failed this run does not make old changes look new.
(Map<(int, int), Object>, bool) _baseline(
  Map<String, Object?>? previous,
  Map<String, Object?>? fresh,
) {
  for (final source in [fresh ?? {}, previous ?? {}]) {
    final stored = source['stable_baseline'];
    if (source['stable_baseline_source'] != 'scraped' || stored is! Map) {
      continue;
    }
    try {
      final baseline = baselineFromDict(_strMap(stored));
      if (baseline.isNotEmpty) return (baseline, true);
    } catch (_) {
      continue;
    }
  }
  return ({}, false);
}

String _kind(Map<String, Object?> change) {
  final diff = change['diff'];
  final changed = diff is LessonDiff ? diff.changed.toSet() : <String>{};
  if (changed.intersection({'status', 'missing'}).isNotEmpty) {
    return 'cancelled';
  }
  if (changed.contains('added')) return 'added';
  return 'changed';
}

(String, Object, String) _changeKey(Map<String, Object?> change) {
  final lesson = Lesson.fromLegacy(
    _strMap(change['lesson']),
    change['day_key'],
  );
  return (canonicalDayKey(change['day_key']), _slot(lesson), _kind(change));
}

/// Timetable changes (vs the stable timetable) that are new, from today on.
List<String> newChanges(
  Map<String, Object?>? previous,
  Map<String, Object?>? fresh,
  DateTime today,
) {
  final oldDays = _days(previous?['timetable']);
  final freshDays = _days(fresh?['timetable']);
  final todayDate = DateTime(today.year, today.month, today.day);
  final days = {
    for (final entry in freshDays.entries)
      if (oldDays.containsKey(entry.key) && !_byDate(entry).isBefore(todayDate))
        entry.key: entry.value,
  };
  if (days.isEmpty) return [];
  final (baseline, complete) = _baseline(previous, fresh);
  final known = {
    for (final change in iterChanges(
      {for (final key in days.keys) key: oldDays[key]!},
      baseline,
      complete,
    ))
      _changeKey(change),
  };
  final items = <String>[];
  final freshChanges = <(DateTime, int, Lesson, Map<String, Object?>)>[];
  for (final change in iterChanges(days, baseline, complete)) {
    final lesson = Lesson.fromLegacy(
      _strMap(change['lesson']),
      change['day_key'],
    );
    freshChanges.add((
      lesson.day ?? DateTime(1),
      lesson.period ?? 99,
      lesson,
      change,
    ));
  }
  freshChanges.sort((a, b) {
    final day = a.$1.compareTo(b.$1);
    return day != 0 ? day : a.$2.compareTo(b.$2);
  });
  for (final (_, _, lesson, change) in freshChanges) {
    final key = _changeKey(change);
    if (known.contains(key)) continue;
    known.add(key);
    final diff = change['diff'];
    final changed = diff is LessonDiff ? diff.changed.toSet() : <String>{};
    final String what;
    if (key.$3 == 'cancelled') {
      what = t('news_cancelled');
    } else if (key.$3 == 'added') {
      what = t('news_added');
    } else if (changed.contains('room') && lesson.room.isNotEmpty) {
      what = t('news_room', args: {'room': lesson.room});
    } else {
      final note = (diff is LessonDiff ? diff.note : '').trim();
      what = note.length > 80
          ? note.substring(0, 80)
          : (note.isNotEmpty ? note : t('news_changed'));
    }
    items.add('${_label(lesson.subject, lesson.day, lesson.period)}: $what');
  }
  return items;
}
