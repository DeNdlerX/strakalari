// Parsers for what the Bakaláři web returns (see docs/BAKALARI_API.md).
//
// Port of strakalari/core/extractors/bakalari.py. The grades page is a
// WebForms page whose marks sit in `data-clasif` attributes; everything
// else comes from the pages' own JSON endpoints.
import 'dart:convert';

import 'package:html_unescape/html_unescape.dart';

import '../storage/helpers.dart';

/// Normalizes `D.M.YYYY` to zero-padded `DD.MM.YYYY`.
///
/// Tolerates surrounding whitespace and trailing dots (the web renders
/// e.g. `"24. 9. 2026."`); throws [ArgumentError] when unparseable (the
/// caller treats that as "no entry", never a crash).
String zeroPadDay(Object? dateStr) {
  final parts = '${dateStr ?? ''}'
      .trim()
      .replaceAll(RegExp(r'\.+$'), '')
      .split('.')
      .map((p) => p.trim())
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.length != 3) {
    throw ArgumentError('Unparseable date: $dateStr');
  }
  return '${parts[0].padLeft(2, '0')}.${parts[1].padLeft(2, '0')}.${parts[2]}';
}

final _gradesLegacyRe = RegExp(
  'data-clasif\\s*=\\s*(["\'])(\\{[^}]*?MarkText[^}]*?\\})\\1',
  dotAll: true,
  caseSensitive: false,
);

final _attrOpenRe = RegExp(
  'data-clasif\\s*=\\s*(["\'])',
  caseSensitive: false,
);

/// Yields `data-clasif` JSON blobs with balanced-brace scanning.
///
/// The old `[^}]*` regex broke on nested objects or a `}` inside a
/// string value. This scanner counts braces while respecting quoted
/// strings (both quote styles, backslash escapes), so nested/escaped
/// content parses. Yields raw blob strings.
Iterable<String> _iterGradeBlobs(String source) sync* {
  final n = source.length;
  for (final m in _attrOpenRe.allMatches(source)) {
    var i = m.end;
    while (i < n && RegExp(r'\s').hasMatch(source[i])) {
      i += 1;
    }
    if (i >= n || source[i] != '{') continue;
    var depth = 0;
    String? inStr;
    var esc = false;
    var j = i;
    var closed = false;
    while (j < n) {
      final ch = source[j];
      if (inStr != null) {
        if (esc) {
          esc = false;
        } else if (ch == '\\') {
          esc = true;
        } else if (ch == inStr) {
          inStr = null;
        }
      } else {
        if (ch == '"' || ch == "'") {
          inStr = ch;
        } else if (ch == '{') {
          depth += 1;
        } else if (ch == '}') {
          depth -= 1;
          if (depth == 0) {
            closed = true;
            break;
          }
        }
      }
      j += 1;
    }
    if (closed) yield source.substring(i, j + 1);
  }
}

/// Unescapes HTML entities (mirrors `html.unescape`).
String htmlUnescape(String text) => HtmlUnescape().convert(text);

/// Sort key for `udel_datum` values (Czech `D.M.YYYY` or ISO).
///
/// Unparseable/missing dates sort after real ones, ordered by their raw
/// string so the order stays deterministic. Never raises.
(int, Object) _gradeDateKey(Object? dateStr) {
  try {
    return (0, parseDate('${dateStr ?? ''}'));
  } on Object {
    return (1, '${dateStr ?? ''}');
  }
}

int _compareGradeKeys((int, Object) a, (int, Object) b) {
  if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
  if (a.$2 is DateTime && b.$2 is DateTime) {
    return (a.$2 as DateTime).compareTo(b.$2 as DateTime);
  }
  return '${a.$2}'.compareTo('${b.$2}');
}

String _gradeText(Map<String, Object?> grade, String key) =>
    '${grade[key] ?? ''}'.trim();

/// Optional mark details, only the ones the page actually filled in.
///
/// `caption` is the topic ("pololetní test"), `strdatum` the day the
/// test was (or is planned to be) written, `PointsText` a points mark,
/// `MarkTooltip` "plánovaná klasifikace" flags an announced mark ("?").
/// Empty values are left out so plain marks keep their three keys.
Map<String, Object?> _gradeExtras(
    Map<String, Object?> grade, Map<String, Object?> entry) {
  final extras = <String, Object?>{};
  if (_gradeText(grade, 'id').isNotEmpty) {
    extras['Id'] = _gradeText(grade, 'id');
  }
  if (_gradeText(grade, 'caption').isNotEmpty) {
    extras['Caption'] = _gradeText(grade, 'caption');
  }
  final note = [
    _gradeText(grade, 'poznamkakzobrazeni'),
    _gradeText(grade, 'VerbalEvaluation')
  ].where((t) => t.isNotEmpty).join(' · ');
  if (note.isNotEmpty) extras['Note'] = note;
  final testDay = _gradeText(grade, 'strdatum');
  if (testDay.isNotEmpty &&
      testDay != '${entry['Date'] ?? ''}'.trim()) {
    extras['TestDate'] = testDay;
  }
  if (_gradeText(grade, 'PointsText').isNotEmpty) {
    extras['Points'] = _gradeText(grade, 'PointsText');
  }
  if (grade['IsNew'] == true) extras['New'] = true;
  final tooltip = _gradeText(grade, 'MarkTooltip').toLowerCase();
  if (entry['Grade'] == '?' || tooltip.contains('plánovan')) {
    extras['Planned'] = true;
  }
  return extras;
}

/// Extracts průběžná klasifikace marks from the Bakalari grades page.
///
/// Parses the `data-clasif` JSON blobs (`nazev` / `MarkText` /
/// `vaha` / `udel_datum`) and groups them per subject:
///
///     {"Matematika": [{"Grade": "1", "Weight": 10, "Date": "5.9.2026"}]}
///
/// Optional details (Id, Caption, Note, TestDate, Points, New, Planned)
/// are added per mark only when the page provides them.
///
/// Every subject list is sorted by date (oldest first); the raw page
/// groups by subject but leaves dates unordered. Never raises —
/// returns {} on empty or unparseable input.
Map<String, List<Map<String, Object?>>> extractGrades(
    Object? htmlString) {
  final result = <String, List<Map<String, Object?>>>{};
  if (htmlString == null || '$htmlString'.isEmpty) return result;
  late final String source;
  try {
    source = htmlUnescape('$htmlString');
  } on Object {
    return result;
  }
  var blobs = _iterGradeBlobs(source).toList();
  if (blobs.isEmpty) {
    // Fallback: the legacy regex for markups the scanner misses.
    blobs = [
      for (final m in _gradesLegacyRe.allMatches(source)) m.group(2)!
    ];
  }
  for (final blob in blobs) {
    late final Object? decoded;
    try {
      decoded = jsonDecode(blob);
    } on FormatException {
      continue;
    }
    if (decoded is! Map) continue;
    final grade = decoded
        .map((k, v) => MapEntry('$k', v as Object?));
    final subject = grade['nazev'];
    final score = grade['MarkText'];
    if (subject == null || score == null) continue;
    if ('$subject'.trim().isEmpty) continue;
    final entry = <String, Object?>{
      'Grade': '$score'.trim(),
      'Weight': grade['vaha'],
      'Date': grade['udel_datum'],
    };
    entry.addAll(_gradeExtras(grade, entry));
    result.putIfAbsent('$subject'.trim(), () => []).add(entry);
  }
  for (final marks in result.values) {
    try {
      marks.sort((a, b) => _compareGradeKeys(
          _gradeDateKey(a['Date']), _gradeDateKey(b['Date'])));
    } on Object {
      continue;
    }
  }
  return result;
}

final _subjectRowRe = RegExp(
  '<div\\s+id="[^"]*"\\s+class="predmet-radek"',
  caseSensitive: false,
);
final _rowTitleRe = RegExp(
  '<h3[^>]*>(.*?)</h3>',
  dotAll: true,
  caseSensitive: false,
);
final _quarterlyRe = RegExp(
  '<div\\s+class="hlavni">\\s*<div\\s+title=(["\'])(.*?)\\1[^>]*>(.*?)</div>',
  dotAll: true,
  caseSensitive: false,
);
final _quarterlyNoteRe = RegExp(
  'data-testid="subjectview-grade-details-note"[^>]*>(.*?)</span>',
  dotAll: true,
  caseSensitive: false,
);

String _cleanName(Object? value) =>
    '${value ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();

String _plain(String fragment) =>
    _cleanName(htmlUnescape(fragment.replaceAll(RegExp(r'<[^>]+>'), ' ')));

/// Quarterly marks (čtvrtletní, the interim final grade) of the grades page.
///
/// Each subject row holds one in `<div class="hlavni"><div title=
/// "Čtvrtletní (prozatímní výsledná známka)">2</div>`, its note in the
/// row's detail (`subjectview-grade-details-note`):
///
///     {"Matematika": {"Grade": "1"}, "Dějepis": {"Grade": "3", "Note": "…"}}
///
/// Subjects without one are left out. Never raises — {} on garbage.
Map<String, Map<String, Object?>> extractQuarterlyMarks(
    Object? htmlString) {
  final result = <String, Map<String, Object?>>{};
  final source = '${htmlString ?? ''}';
  final starts = [
    for (final m in _subjectRowRe.allMatches(source)) m.start
  ];
  for (var i = 0; i < starts.length; i++) {
    final row = source.substring(
        starts[i], i + 1 < starts.length ? starts[i + 1] : source.length);
    final title = _rowTitleRe.firstMatch(row);
    final slot = _quarterlyRe.firstMatch(row);
    if (title == null || slot == null) continue;
    if (!htmlUnescape(slot.group(2)!).toLowerCase().contains('čtvrtlet')) {
      continue;
    }
    // Unescaped but otherwise as written, like the marks' `nazev`
    // ("Seminář z matematiky S" keeps its no-break space).
    final subject = htmlUnescape(
            title.group(1)!.replaceAll(RegExp(r'<[^>]+>'), ''))
        .trim();
    final grade = _plain(slot.group(3)!);
    if (subject.isEmpty || grade.isEmpty) continue;
    final entry = <String, Object?>{'Grade': grade};
    final note = _quarterlyNoteRe.firstMatch(row);
    if (note != null && _plain(note.group(1)!).isNotEmpty) {
      entry['Note'] = _plain(note.group(1)!);
    }
    result[subject] = entry;
  }
  return result;
}

// -- Web JSON endpoints -------------------------------------------------------

const List<String> _summaryWords = [
  'zameškanost',
  'zameskanost',
  'celkem',
  'součet',
  'soucet',
  'souhrn',
  'průměr',
  'prumer'
];

double? _number(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is bool) return value ? 1 : 0;
  if (value == null) return null;
  return double.tryParse('$value'.trim());
}

/// Rounds to 2 decimals, halves to even (mirrors Python's `round()`).
double _round2(double value) {
  final scaled = value * 100;
  final floored = scaled.floor();
  final frac = scaled - floored;
  if (frac == 0.5) {
    return ((floored.isEven ? floored : floored + 1)) / 100;
  }
  return scaled.roundToDouble() / 100;
}

/// Rows of a DevExtreme `AspNet.createStore` reply (a bare list or
/// `{"data": [...], "totalCount": …}`); null when it carries no rows list.
List<Object?>? storeRows(Object? reply) {
  if (reply is Map) reply = reply['data'];
  return reply is List ? reply.cast<Object?>() : null;
}

/// Lesson details of a `/Timetable/GetContentData` reply.
///
/// Every atom carries `TooltipDetails`: the same JSON the rendered
/// page puts into `data-detail` (see `parse_timetable_detail`).
/// Unparseable atoms are skipped. Never raises.
List<Map<String, Object?>> timetableDetails(Object? content) {
  final details = <Map<String, Object?>>[];
  if (content is! Map) return details;
  final days = content['Days'];
  if (days is! List) return details;
  for (final day in days) {
    if (day is! Map) continue;
    final hours = day['Hours'];
    if (hours is! List) continue;
    for (final hour in hours) {
      if (hour is! Map) continue;
      final atoms = hour['Atoms'];
      if (atoms is! List) continue;
      for (final atom in atoms) {
        if (atom is! Map) continue;
        late final Object? decoded;
        try {
          decoded = jsonDecode('${atom['TooltipDetails'] ?? ''}');
        } on FormatException {
          continue;
        }
        if (decoded is Map) {
          details.add(
              decoded.map((k, v) => MapEntry('$k', v as Object?)));
        }
      }
    }
  }
  return details;
}

/// Default `(dateFrom, dateTo)` the absence page queries, or null.
(String, String)? absenceDateRange(Object? pageHtml) {
  final match = RegExp(
    r'DatesInformations\s*=\s*ko\.mapping\.fromJS\((\{.*?\})\);',
    dotAll: true,
  ).firstMatch('${pageHtml ?? ''}');
  if (match == null) return null;
  try {
    final info = jsonDecode(match.group(1)!) as Map;
    return (
      '${info['DefaultDateFrom']['DefaultValue']}',
      '${info['DefaultDateTo']['DefaultValue']}'
    );
  } on Object {
    return null;
  }
}

/// `(percentages, details)` from `/Absence/Continuous/GetAbsenceBySubjects` rows.
///
/// Rows are `{Name, LessonCount, Count, Percent}` with `Percent` as a
/// 0–1 fraction (the page shows it with two decimals). The school's
/// verdict badges are deliberately not used: the app judges absence by
/// its own limits, so `approaching` / `unclassifiable` stay false
/// (exactly what the rendered-page parser reported). Never raises.
(
  Map<String, double>,
  Map<String, Map<String, Object?>>
) absenceFromSubjects(Object? rows) {
  final percentages = <String, double>{};
  final details = <String, Map<String, Object?>>{};
  for (final row in storeRows(rows) ?? <Object?>[]) {
    if (row is! Map) continue;
    final subject = _cleanName(row['Name']);
    final fraction = _number(row['Percent']);
    if (subject.isEmpty || fraction == null) continue;
    if (_summaryWords.any((w) => subject.toLowerCase().contains(w))) {
      continue;
    }
    final pct = _round2(fraction * 100);
    if (percentages.containsKey(subject) &&
        pct <= percentages[subject]!) {
      continue;
    }
    percentages[subject] = pct;
    details[subject] = {
      'percent': pct,
      'total_hours': _number(row['LessonCount']),
      'missed_hours': _number(row['Count']),
      'approaching': false,
      'unclassifiable': false,
    };
  }
  return (percentages, details);
}

/// `{subject: teacher}` from the `/Teaching/Subjects` grid rows. Never raises.
Map<String, String> subjectDirectoryFromRows(Object? rows) {
  final directory = <String, String>{};
  for (final row in storeRows(rows) ?? <Object?>[]) {
    if (row is! Map) continue;
    final subject = _cleanName(row['SubjectName']);
    final teacher = _cleanName(row['TeacherName']);
    if (subject.isNotEmpty) directory[subject] = teacher;
  }
  return directory;
}

/// `ChangeType` -> feed badge, as the substitutions page maps it.
const Map<String, String> substitutionBadges = {
  'Canceled': 'O',
  'Removed': 'O',
  'Substitution': 'S',
  'Added': 'N',
  'RoomChanged': 'M',
  'Absence': 'A'
};

/// Feed entries from `/Timetable/substitutions/dates` (same shape as
/// `parse_substitutions`). Never raises: [] on garbage.
List<Map<String, Object?>> substitutionsFromWeeks(Object? weeks) {
  final entries = <Map<String, Object?>>[];
  if (weeks is! List) return entries;
  for (final week in weeks) {
    if (week is! Map) continue;
    final changes = week['Changes'];
    if (changes is! List) continue;
    for (final change in changes) {
      try {
        if (change is! Map) continue;
        final day = RegExp(r'\d{1,2}\.\d{1,2}\.\d{4}')
            .firstMatch('${change['Day'] ?? ''}');
        if (day == null) continue;
        final hour = RegExp(r'\d+')
            .firstMatch('${change['HourLabel'] ?? ''}');
        final info = change['ChangeLessonInfo'];
        if (info != null && info is! Map) continue;
        final infoMap = info as Map? ?? {};
        String classText = '';
        if ('${infoMap['ClassAbbrev'] ?? ''}'.isNotEmpty) {
          final group = '${infoMap['GroupAbbrev'] ?? ''}';
          final isGroup = infoMap['IsClassGroup'];
          final grouped = (isGroup is bool && isGroup) ||
              (isGroup is num && isGroup != 0) ||
              (isGroup is String && isGroup.isNotEmpty);
          classText = (grouped || group.isEmpty)
              ? '${infoMap['ClassAbbrev']}'
              : '${infoMap['ClassAbbrev']} ($group)';
        }
        final parts = [
          classText,
          '${infoMap['SubjectAbbrev'] ?? ''}',
          '${infoMap['RoomAbbrev'] ?? ''}'
        ];
        entries.add({
          'day': day.group(0)!,
          'period':
              hour == null ? null : int.parse(hour.group(0)!),
          'time': _cleanName(change['TimeLabel']),
          'badge': substitutionBadges[
                  '${change['ChangeType'] ?? ''}'] ??
              '-',
          'info': parts
              .where((p) => p.trim().isNotEmpty)
              .join(' | '),
          'subject_short': _cleanName(infoMap['SubjectAbbrev']),
          'description': _cleanName(change['Description']),
        });
      } on Object {
        continue;
      }
    }
  }
  return entries;
}

/// Message ids of the excuse (OMLUVENKA) rows of the Komens list, in order.
List<String> outboxExcuseIds(Object? listHtml) {
  final ids = <String>[];
  final re = RegExp(
      '<table\\b[^>]*?data-idmsg="(\\d+)"[^>]*?data-msgtype="([^"]*)"');
  for (final match in re.allMatches('${listHtml ?? ''}')) {
    if (match.group(2) == 'OMLUVENKA' &&
        !ids.contains(match.group(1))) {
      ids.add(match.group(1)!);
    }
  }
  return ids;
}

int? _lessonCaption(Object? hour) {
  if (hour is! Map) return null;
  try {
    return int.parse('${hour['Caption'] ?? ''}'.trim());
  } on FormatException {
    return null;
  }
}

/// History entries of one `/Komens/GetMessageDataAsync` excuse detail.
///
/// Same rules as the rendered-detail parser: lessons -> three entries
/// (`income` + `soon` + `days and hours`, so web excuses dedupe
/// against every locally generated shape); no lessons and no clock times
/// -> a whole-day entry; clock times without lessons -> the covered
/// lessons are unknown, so nothing is learned. Never raises.
List<Map<String, Object?>> sentExcuseEntries(Object? detail) {
  if (detail is! Map) return [];
  try {
    if ('${detail['Kind'] ?? 'OMLUVENKA'}' != 'OMLUVENKA') return [];
    final startDay = zeroPadDay(detail['DateFrom']);
    final endDay = zeroPadDay(detail['DateTo']);
    final startLesson = _lessonCaption(detail['HourFrom']);
    final endLesson = _lessonCaption(detail['HourTo']);
    if (startLesson == null || endLesson == null) {
      if ('${detail['TimeFrom'] ?? ''}'.trim().isNotEmpty ||
          '${detail['TimeTo'] ?? ''}'.trim().isNotEmpty) {
        return [];
      }
      return [
        {
          'type': 'pure days',
          'starting_day': startDay,
          'ending_day': endDay,
        }
      ];
    }
    final base = {
      'starting_day': startDay,
      'ending_day': endDay,
      'starting_lesson': startLesson,
      'ending_lesson': endLesson,
    };
    return [
      for (final kind in ['income', 'soon', 'days and hours'])
        {'type': kind, ...base}
    ];
  } on ArgumentError {
    return [];
  }
}
