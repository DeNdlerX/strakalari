import 'format.dart';

/// Lesson model + absence-status derivation ported from
/// `strakalari/core/models.py` (`Lesson.from_legacy`,
/// `_lesson_status_from_legacy`, `absence_kind`, `is_excused_marker`,
/// `cancel_negated`, `is_cancel_notice`, `is_class_event`,
/// `extract_lesson_num`) and `core/helpers.py` (`short_room_name`).
///
/// Statuses are normalized to the shared vocabulary:
/// `'' | late | early | soon | absent | cancelled | excused`.
/// Precedence: cancelled > late/early > excused > unexcused > substitution.

/// One taught lesson (timetable row).
class LessonRow {
  final String subject;
  final DateTime? day;
  final int? period;
  final String time;
  final String room;
  final String teacher;
  final String status;
  final String change;
  final bool excused;

  const LessonRow({
    required this.subject,
    this.day,
    this.period,
    this.time = '',
    this.room = '',
    this.teacher = '',
    this.status = '',
    this.change = '',
    this.excused = false,
  });

  /// Builds a lesson from a legacy extractor dict — like
  /// `Lesson.from_legacy`. Real Bakaláři rows carry no `period` key,
  /// only a `time` string like `3 (10:05 - 10:50)`.
  factory LessonRow.fromLegacy(Map<String, Object?> raw, [Object? day]) {
    final parsedDay = parseCzDate(raw['date'] ?? day);
    int? period = _toInt(raw['period']);
    period ??= extractLessonNum(raw['time']);
    final derived = lessonStatusFromLegacy(raw);
    var subject = '${raw['subject'] ?? ''}'.trim();
    if (subject.isEmpty) subject = '?';
    return LessonRow(
      subject: subject,
      day: parsedDay,
      period: period,
      time: '${raw['time'] ?? ''}',
      room: shortRoomName('${raw['room'] ?? ''}'),
      teacher: '${raw['teacher'] ?? ''}',
      status: derived.status,
      change: derived.change,
      excused: derived.excused,
    );
  }
}

/// First non-empty of two raw values, trimmed — Python's
/// `raw.get("notice") or raw.get("change")` under `_str`.
String _firstNonEmpty(Object? a, Object? b) {
  final sa = '${a ?? ''}'.trim();
  if (sa.isNotEmpty) return sa;
  return '${b ?? ''}'.trim();
}

int? _toInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// Lesson number from a Bakaláři time label — like
/// `helpers.extract_lesson_num`. The lookahead rejects digits followed
/// (after optional digits/spaces) by a colon, so multi-digit hours can't
/// backtrack into a bogus period (`13:40` → null, not 1).
int? extractLessonNum(Object? timeStr) {
  final m =
      RegExp(r'^(\d+)(?![\d\s]*:)').firstMatch('${timeStr ?? ''}'.trim());
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// Short display name of a Bakaláři room — like
/// `helpers.short_room_name`: `4A - (104)` → `4A`, plain names pass
/// through unchanged.
String shortRoomName(Object? room) {
  final text = '${room ?? ''}'.trim();
  if (text.isEmpty) return '';
  var m = RegExp(r'^(.*?)\s+[-–—]\s*\(.*\)\s*$').firstMatch(text);
  if (m != null && m.group(1)!.trim().isNotEmpty) return m.group(1)!.trim();
  m = RegExp(r'^(.*?)\s*[-–—]\s*\(.*\)\s*$').firstMatch(text);
  if (m != null && m.group(1)!.trim().isNotEmpty) return m.group(1)!.trim();
  m = RegExp(r'^(.*?)\s+\(.*\)\s*$').firstMatch(text);
  if (m != null && m.group(1)!.trim().isNotEmpty) return m.group(1)!.trim();
  return text;
}

/// `(status, change, excused)` derived from Bakaláři seed shapes.
class DerivedStatus {
  final String status;
  final String change;
  final bool excused;
  const DerivedStatus(this.status, this.change, this.excused);
}

/// Like `models._lesson_status_from_legacy`.
DerivedStatus lessonStatusFromLegacy(Map<String, Object?> raw) {
  String s(Object? v) => '${v ?? ''}'.trim();
  final absType = raw['absenceType'];
  final absText = raw['absencetext'];
  final notice = _firstNonEmpty(raw['notice'], raw['change']);
  final noticeLower = notice.toLowerCase();
  final cancelSignal = [
    noticeLower,
    s(raw['changeinfo']).toLowerCase(),
    s(raw['removedinfo']).toLowerCase(),
  ].join(' ');
  final detailType = s(raw['type']).toLowerCase();
  final infoCode = s(raw['infoChangeCode']).toLowerCase();
  if (detailType == 'removed' ||
      infoCode == 'removed' ||
      infoCode == 'cancelled' ||
      infoCode == 'canceled' ||
      s(raw['status']).toLowerCase() == 'cancelled' ||
      s(raw['status']).toLowerCase() == 'odpadá' ||
      isCancelNotice(cancelSignal)) {
    return DerivedStatus(
        'cancelled',
        notice.isNotEmpty
            ? notice
            : (s(raw['changeinfo']).isNotEmpty
                ? s(raw['changeinfo'])
                : s(raw['removedinfo'])),
        false);
  }
  final kind = absenceKind(absType, absText);
  if (kind == 'excused') return const DerivedStatus('excused', '', true);
  if (kind == 'soon' || kind == 'late' || kind == 'early') {
    return DerivedStatus(kind, notice, false);
  }
  if (kind == 'absent') return const DerivedStatus('absent', '', false);
  final legacy = s(raw['status']).toLowerCase();
  if (const {'absent', 'absentlate', 'nepritomen', 'neprítomen', 'absence', 'unexcused'}
      .contains(legacy)) {
    return DerivedStatus('absent', s(raw['change']), false);
  }
  if (const {'soon', 'brzký odchod', 'brzky odchod'}.contains(legacy)) {
    return DerivedStatus('soon', s(raw['change']), false);
  }
  if (const {'late', 'income', 'pozdní příchod'}.contains(legacy)) {
    return DerivedStatus('late', s(raw['change']), false);
  }
  if (const {'early', 'předčasný odchod'}.contains(legacy)) {
    return DerivedStatus('early', s(raw['change']), false);
  }
  if (const {'excused', 'omluveno'}.contains(legacy)) {
    return const DerivedStatus('excused', '', true);
  }
  if (noticeLower.contains('supl') || noticeLower.contains('změn')) {
    return DerivedStatus('', notice, false);
  }
  if (const {'', 'present', 'přítomen', 'noabsent', 'none'}.contains(legacy)) {
    final change = s(raw['change']);
    return DerivedStatus('', change.isNotEmpty ? change : notice, false);
  }
  if (legacy.isNotEmpty) {
    final change = s(raw['change']);
    return DerivedStatus('', change.isNotEmpty ? change : notice, false);
  }
  return DerivedStatus('', notice, false);
}

/// Classifies Bakaláři's absence fields — like `models.absence_kind`.
/// Returns `excused | soon | late | early | absent | ''`.
String absenceKind(Object? absenceType, Object? absenceText) {
  final absType = '${absenceType ?? ''}'.trim().toLowerCase();
  final absText = '${absenceText ?? ''}'.trim().toLowerCase();
  final combined = '$absText $absType';
  // `Nezapočtená absence` (NotCounted) and `Školní akce` (School) are
  // absences on paper only — never a task, never excused.
  if (const {
    'nezapoč',
    'nezapoc',
    'notcounted',
    'not counted',
    'školní akce',
    'skolni akce',
  }.any(combined.contains) ||
      absType == 'school') {
    return '';
  }
  final excused = isExcusedMarker(combined);
  // Early leave is checked before late/early/absent: `absentsoon`
  // embeds `absent` and `brzký odchod` embeds `odchod`.
  if (const {'absentsoon', 'brzk', 'soon'}.any(combined.contains) ||
      absType == 'brzky odchod' ||
      absType == 'brzký odchod') {
    return excused ? 'excused' : 'soon';
  }
  if (const {'pozdn', 'income', 'absentlate', 'late'}.any(combined.contains)) {
    return excused ? 'excused' : 'late';
  }
  if (const {'předčasn', 'predcasn', 'odchod', 'absentearly', 'early'}
      .any(combined.contains)) {
    return excused ? 'excused' : 'early';
  }
  if (excused) return 'excused';
  if (const {
        'absent',
        'unexcused',
        'neomluven',
        'neomluveno',
        'neomluvena',
        'neomluvená',
      }.contains(absType) ||
      absentTextMarked(absText)) {
    return 'absent';
  }
  return '';
}

/// Like `models.is_excused_marker`: negations (`Neomluveno`,
/// `Unexcused`, `no absence`) never count as excused.
bool isExcusedMarker(Object? text) {
  final low = '${text ?? ''}'.toLowerCase();
  if (low.contains('neomluv') ||
      low.contains('unexcus') ||
      low.contains('neexcus') ||
      RegExp(r'\b(not|without|no)\s+excus').hasMatch(low) ||
      RegExp(r'\bbeze?\s+omluv').hasMatch(low)) {
    return false;
  }
  return low.contains('omluv') || low.contains('excus');
}

/// Like `models.cancel_negated`: cancel-looking text that is actually
/// negated (`Neodpadá`, `beze změny`) — never a cancellation.
bool cancelNegated(String text) {
  final low = text.toLowerCase();
  const markers = [
    'neodpad',
    'nezruš',
    'nezrus',
    'neruší',
    'nerusi',
    'neodpadne',
    'nezruší',
    'nezrusi',
    'beze změn',
    'beze zmen',
    'bez změn',
    'bez zmen',
    'nedošlo ke změně',
    'nedoslo ke zmene',
  ];
  if (markers.any(low.contains)) return true;
  if (RegExp(r'\bne\s+(odpad|zruš|zrus)').hasMatch(low)) return true;
  if (RegExp(r'\bnení\s+(zrušen|zrusen)').hasMatch(low)) return true;
  return false;
}

/// Like `models.is_cancel_notice`: negated forms never count.
bool isCancelNotice(Object? text) {
  final low = '${text ?? ''}'.toLowerCase();
  if (cancelNegated(low)) return false;
  const keywords = ['odpad', 'zruš', 'zrus', 'vyjm', 'vynat', 'vyňat'];
  const negators = {
    'ne',
    'neni',
    'není',
    'nebude',
    'nebudou',
    'nebyl',
    'nebyla',
    'nebylo',
    'nebyly',
    'nedojde',
    'nedošlo',
    'nedoslo',
  };
  var prev = '';
  // `\b` is ASCII-only in Dart: tokenize explicitly like Python's
  // `findall(r"[a-zá-ž]+")`.
  final tokens =
      RegExp(r'[a-zá-ž]+').allMatches(low).map((m) => m.group(0)!);
  for (final word in tokens) {
    if (keywords.any(word.contains)) {
      final nePrefixed =
          word.startsWith('ne') && keywords.any(word.substring(2).contains);
      if (!nePrefixed && !negators.contains(prev)) return true;
    }
    prev = word;
  }
  return false;
}

/// Like `models._absent_text_marked`: free-text absence text positively
/// marking an absence (`NoAbsent` / `no absence` stay negative).
bool absentTextMarked(String absText) {
  const markers = [
    'neomluv',
    'neomluveno',
    'zamešk',
    'chyb',
    'absence',
    'absent',
    'unexcused',
  ];
  const negations = {'no', 'bez', 'beze'};
  var prev = '';
  final tokens =
      RegExp(r'[a-zá-ž]+').allMatches(absText.toLowerCase()).map((m) => m.group(0)!);
  for (final token in tokens) {
    if (markers.any(token.contains)) {
      if (negations.contains(prev)) {
        prev = token;
        continue;
      }
      final rest = token;
      if (rest != 'no' &&
          rest.startsWith('no') &&
          markers.any(rest.substring(2).contains)) {
        prev = token;
        continue;
      }
      return true;
    }
    prev = token;
  }
  return false;
}

/// True for a school event replacing the lesson — like
/// `models.is_class_event`. Shows as a change, costs no absence budget,
/// needs no excuse.
bool isClassEvent(Object? raw) =>
    raw is Map && '${raw['type'] ?? ''}'.trim().toLowerCase() == 'event';
