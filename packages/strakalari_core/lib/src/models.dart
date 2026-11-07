// Shared data models (UI-agnostic).
//
// Port of strakalari/core/models.py. These classes are the contract
// between the backend (extractors, cache, forecast engine) and any
// frontend. They accept the loose dict shapes produced by the legacy
// extractors via [Lesson.fromLegacy], so views never have to guess dict
// keys again.
import 'i18n.dart';
import 'storage/helpers.dart';

String _str(Object? value, [String defaultValue = '']) =>
    value == null ? defaultValue : '$value'.trim();

/// Parses `DD.MM.YYYY` / ISO dates; null when unparseable.
///
/// Real Bakalari cache keys carry a weekday suffix (`10.9.2026 (čtvrtek)`)
/// and single-digit day/month — both are accepted here.
/// Dates come back as local midnights (Dart has no date-only type).
DateTime? parseCzDate(Object? value) {
  if (value is DateTime) {
    return DateTime(value.year, value.month, value.day);
  }
  final text = _str(value).split('(').first.trim();
  for (final parsed in [
    _parseDmy(text),
    _parseIso(text),
    _parseShortYear(text),
    _parseIsoSlash(text),
    _parseSlashDmy(text),
  ]) {
    if (parsed != null) return parsed;
  }
  return null;
}

DateTime? _checkedDate(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1) return null;
  final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  const lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  final maxDay = lengths[month - 1] + (month == 2 && leap ? 1 : 0);
  if (day > maxDay) return null;
  return DateTime(year, month, day);
}

DateTime? _parseDmy(String clean) {
  final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(clean);
  if (m == null) return null;
  return _checkedDate(
      int.parse(m.group(3)!), int.parse(m.group(2)!), int.parse(m.group(1)!));
}

DateTime? _parseIso(String clean) {
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(clean);
  if (m == null) return null;
  return _checkedDate(
      int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

DateTime? _parseShortYear(String clean) {
  final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{2})$').firstMatch(clean);
  if (m == null) return null;
  final short = int.parse(m.group(3)!);
  final year = short >= 69 ? 1900 + short : 2000 + short;
  return _checkedDate(year, int.parse(m.group(2)!), int.parse(m.group(1)!));
}

DateTime? _parseIsoSlash(String clean) {
  final m = RegExp(r'^(\d{4})/(\d{1,2})/(\d{1,2})$').firstMatch(clean);
  if (m == null) return null;
  return _checkedDate(
      int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

DateTime? _parseSlashDmy(String clean) {
  final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(clean);
  if (m == null) return null;
  return _checkedDate(
      int.parse(m.group(3)!), int.parse(m.group(2)!), int.parse(m.group(1)!));
}

/// Normalizes any parsable day to `DD.MM.YYYY` (zero-padded).
///
/// Timetable cache keys (`7.9.2026 (pondělí)`), food keys
/// (`07.09.2026`) and [DateTime] objects all collapse to one form so
/// views can look up "today" with a plain string comparison.
/// Unparseable input is returned stripped, unchanged.
String canonicalDayKey(Object? value) {
  final day = parseCzDate(value);
  if (day == null) return _str(value);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(day.day)}.${two(day.month)}.${day.year}';
}

/// One taught lesson.
class Lesson {
  final String subject;
  final DateTime? day;
  final int? period;
  final String time;
  String room;
  final String teacher;
  final String status; // e.g. "absent" / "late" / "present" / ""
  final String change; // e.g. "suplování" / "odpadá" / "přesun" / ""
  final bool excused;

  Lesson({
    required this.subject,
    this.day,
    this.period,
    this.time = '',
    String room = '',
    this.teacher = '',
    this.status = '',
    this.change = '',
    this.excused = false,
  }) : room = _shortenRoom(room);

  /// Builds a Lesson from a legacy extractor dict.
  factory Lesson.fromLegacy(Map<String, Object?> raw, [Object? day]) {
    final parsedDay = parseCzDate(raw['date'] ?? day);
    int? period = _toInt(raw['period']);
    period ??= extractLessonNum(raw['time']);
    final status = lessonStatusFromLegacy(raw);
    return Lesson(
      subject: _str(raw['subject'], '?'),
      day: parsedDay,
      period: period,
      time: _str(raw['time']),
      room: shortRoomName(_str(raw['room'])),
      teacher: _str(raw['teacher']),
      status: status.$1,
      change: status.$2,
      excused: status.$3,
    );
  }

  static String _shortenRoom(String room) {
    // Bakalari labels rooms as "<short> - (<code>") ("4A - (104)");
    // the UI only ever shows the short part.
    try {
      return shortRoomName(room);
    } catch (_) {
      return room;
    }
  }
}

int? _toInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

/// True when free-text absence text positively marks an absence.
///
/// Plain substring matching misfires on negations that embed the stem
/// (`NoAbsent` contains `absent` but means present). Tokens carrying an
/// English `no`-prefix (`noabsent`, `no absence`) are therefore
/// skipped; Czech `neomluveno`/`neomluven` stay positive markers.
bool _absentTextMarked(String absText) {
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
  // \b is ASCII-only in Dart, so tokenize explicitly like Python's
  // findall(r"[a-zá-ž]+") instead of relying on word boundaries.
  final tokens =
      RegExp(r'[a-zá-ž]+').allMatches(absText.toLowerCase()).map((m) => m.group(0)!);
  var prev = '';
  for (final token in tokens) {
    if (markers.any(token.contains)) {
      // Negations: "no absence" or "bez absence" mean present.
      if (negations.contains(prev)) {
        prev = token;
        continue;
      }
      var rest = token;
      // Strip one English "no" negation prefix ("noabsent" -> "absent").
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

/// True when a cancel-looking text is actually negated (no cancellation).
///
/// Plain substring matching misfires on negations that embed the stem
/// (`Neodpadá` contains `odpad` but means the lesson goes ahead).
/// Texts carrying an explicit negation (`neodpadá`, `nezrušeno`,
/// `beze změny` …) must therefore never classify as cancelled.
bool cancelNegated(Object? text) {
  final low = '${text ?? ''}'.toLowerCase();
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
  // Word-boundary negations: "ne odpadá" / "není zrušeno".
  if (RegExp(r'\bne\s+(odpad|zruš|zrus)').hasMatch(low)) return true;
  if (RegExp(r'\bnení\s+(zrušen|zrusen)').hasMatch(low)) return true;
  return false;
}

/// Classifies Bakaláři's absence fields for one lesson.
///
/// Returns `"excused"`, `"soon"` (brzký odchod), `"late"`
/// (pozdní příchod), `"early"` (generic předčasný odchod),
/// `"absent"` or `""` (present / no absence). The single source of
/// truth for both the UI task list and automatic excusing.
String absenceKind(Object? absenceType, Object? absenceText) {
  final absType = _str(absenceType).toLowerCase();
  final absText = _str(absenceText).toLowerCase();
  final combined = '$absText $absType';
  // "Nezapočtená absence" (NotCounted) and "Školní akce" (School) are
  // absences on paper only — never a task, never excused. Checked
  // first: "nezapočtená absence" embeds the "absence" marker.
  if ((['nezapoč', 'nezapoc', 'notcounted', 'not counted', 'školní akce', 'skolni akce']
              .any(combined.contains) ||
          absType == 'school')) {
    return '';
  }
  // "Neomluveno"/"Unexcused" embed "omluv"/"excus" but mean the
  // opposite — isExcusedMarker() handles the negations.
  final excused = isExcusedMarker(combined);
  // Early leave is checked before late/early/absent: "absentsoon"
  // embeds "absent" and "brzký odchod" embeds "odchod".
  if (['absentsoon', 'brzk', 'soon'].any(combined.contains) ||
      absType == 'brzky odchod' ||
      absType == 'brzký odchod') {
    return excused ? 'excused' : 'soon';
  }
  if (['pozdn', 'income', 'absentlate', 'late'].any(combined.contains)) {
    return excused ? 'excused' : 'late';
  }
  if (['předčasn', 'predcasn', 'odchod', 'absentearly', 'early']
      .any(combined.contains)) {
    return excused ? 'excused' : 'early';
  }
  if (excused) return 'excused';
  if (['absent', 'unexcused', 'neomluven', 'neomluveno', 'neomluvena', 'neomluvená']
          .contains(absType) ||
      _absentTextMarked(absText)) {
    return 'absent';
  }
  return '';
}

const List<String> _cancelKeywords = [
  'odpad',
  'zruš',
  'zrus',
  'vyjm',
  'vynat',
  'vyňat',
];

const Set<String> _cancelNegators = {
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

/// True when a lesson notice marks the lesson as cancelled.
///
/// Negated forms never count: "Neodpadá" / "Nezrušeno" embed the
/// keyword stems, "nebude zrušeno" negates with a separate word, and
/// "beze změny" style phrases mean the lesson goes ahead.
bool isCancelNotice(Object? text) {
  final low = '${text ?? ''}'.toLowerCase();
  if (cancelNegated(low)) return false;
  var prev = '';
  for (final word
      in RegExp(r'[a-zá-ž]+').allMatches(low).map((m) => m.group(0)!)) {
    if (_cancelKeywords.any(word.contains)) {
      final nePrefixed = word.startsWith('ne') &&
          _cancelKeywords.any(word.substring(2).contains);
      if (!nePrefixed && !_cancelNegators.contains(prev)) return true;
    }
    prev = word;
  }
  return false;
}

/// True for a school event replacing the lesson (Bakalari class
/// absence, e.g. "beseda / přednáška / workshop"). It shows as a change,
/// but costs no absence budget and needs no excuse.
bool isClassEvent(Object? raw) =>
    raw is Map && _str(raw['type']).toLowerCase() == 'event';

/// Derives (status, change, excused) from Bakalari seed shapes.
///
/// Real cache rows carry `absenceType` / `absencetext` / `notice`
/// (e.g. `NoAbsent`, `Absent`, `AbsentLate`, `suplování`,
/// `odpadá`); demo rows and older caches carry a plain `status`
/// (`absent` / `late`). Both are normalized to
/// `"" | late | early | soon | absent | cancelled | excused` so every
/// frontend shares one vocabulary. Precedence is cancelled > late/early >
/// excused > unexcused > substitution > present.
///
/// Public in Dart (Python: `_lesson_status_from_legacy`) because the
/// ported tests call it directly; Dart privacy is per library.
(String, String, bool) lessonStatusFromLegacy(Map<String, Object?> raw) {
  final absType = raw['absenceType'];
  final absText = raw['absencetext'];
  final notice = _str(raw['notice'] ?? raw['change']);
  final noticeLower = notice.toLowerCase();
  // Bakalari cancellation signals: the classic "odpadá" notice, the
  // scraped "removed" row ("Zrušeno (FG, Dušek Filip)" in removedinfo /
  // changeinfo), or an explicit removal change code.
  final cancelSignal = [
    noticeLower,
    _str(raw['changeinfo']).toLowerCase(),
    _str(raw['removedinfo']).toLowerCase(),
  ].join(' ');
  final detailType = _str(raw['type']).toLowerCase();
  final infoCode = _str(raw['infoChangeCode']).toLowerCase();
  if (detailType == 'removed' ||
      ['removed', 'cancelled', 'canceled'].contains(infoCode) ||
      ['cancelled', 'odpadá'].contains(_str(raw['status']).toLowerCase()) ||
      isCancelNotice(cancelSignal)) {
    return (
      'cancelled',
      notice.isNotEmpty
          ? notice
          : (_str(raw['changeinfo']).isNotEmpty
              ? _str(raw['changeinfo'])
              : _str(raw['removedinfo'])),
      false
    );
  }
  final kind = absenceKind(absType, absText);
  if (kind == 'excused') return ('excused', '', true);
  if (kind == 'soon' || kind == 'late' || kind == 'early') {
    return (kind, notice, false);
  }
  if (kind == 'absent') return ('absent', '', false);
  // Demo / legacy plain-status rows win over the substitution notice —
  // an explicitly late/absent lesson stays late/absent even with a note.
  final legacy = _str(raw['status']).toLowerCase();
  if (['absent', 'absentlate', 'nepritomen', 'neprítomen', 'absence', 'unexcused']
      .contains(legacy)) {
    return ('absent', _str(raw['change']), false);
  }
  if (['soon', 'brzký odchod', 'brzky odchod'].contains(legacy)) {
    return ('soon', _str(raw['change']), false);
  }
  if (['late', 'income', 'pozdní příchod'].contains(legacy)) {
    return ('late', _str(raw['change']), false);
  }
  if (['early', 'předčasný odchod'].contains(legacy)) {
    return ('early', _str(raw['change']), false);
  }
  if (['excused', 'omluveno'].contains(legacy)) {
    return ('excused', '', true);
  }
  if (noticeLower.contains('supl') || noticeLower.contains('změn')) {
    return ('', notice, false);
  }
  if (['', 'present', 'přítomen', 'noabsent', 'none'].contains(legacy)) {
    return ('', _str(raw['change']).isNotEmpty ? _str(raw['change']) : notice, false);
  }
  if (legacy.isNotEmpty) {
    return ('', _str(raw['change']).isNotEmpty ? _str(raw['change']) : notice, false);
  }
  return ('', notice, false);
}

/// Flattens legacy `{day: [lesson_dict, ...]}` into Lessons.
List<Lesson> lessonsFromTimetable(Map<String, Object?> timetable) {
  final out = <Lesson>[];
  for (final entry in (timetable).entries) {
    final lessons = entry.value;
    if (lessons is! List) continue;
    for (final raw in lessons) {
      if (raw is Map<String, Object?>) {
        out.add(Lesson.fromLegacy(raw, entry.key));
      } else if (raw is Map) {
        out.add(Lesson.fromLegacy(raw.cast<String, Object?>(), entry.key));
      }
    }
  }
  return out;
}

/// Absence state of one subject, including its own limit.
///
/// `limitPct` / `safeHoursLeft` are the school truth. The
/// planning reserve (see `forecast_subject`) is baked into
/// `planLimitPct` / `planSafeHoursLeft` — the planner reads the
/// `effectivePlan*` getters so suggestions stop earlier.
/// `null` means "no forecast attached" (hand-built states fall
/// back to the school values).
class SubjectState {
  final String name;
  final double currentPct;
  final double limitPct;
  final int weeklyHours;
  final int safeHoursLeft;
  final double projectedPct;
  final double warnPct; // Explicit warn threshold; <=0 derives 60% of limit.
  final double? planLimitPct;
  final int? planSafeHoursLeft;
  // School verdict badges from the absence overview (display:none-gated,
  // so true always means the school actually flagged the subject).
  final bool approaching;
  final bool unclassifiable;
  // Already-taught hours (elapsed, never planned totals); 0 = unknown.
  final double taughtHours;

  const SubjectState({
    required this.name,
    this.currentPct = 0.0,
    this.limitPct = 25.0,
    this.weeklyHours = 0,
    this.safeHoursLeft = 0,
    this.projectedPct = 0.0,
    this.warnPct = 0.0,
    this.planLimitPct,
    this.planSafeHoursLeft,
    this.approaching = false,
    this.unclassifiable = false,
    this.taughtHours = 0.0,
  });

  /// Planning limit: school limit minus the safety reserve.
  double get effectivePlanLimit => planLimitPct ?? limitPct;

  /// Remaining hours the planner may still spend.
  int get effectivePlanSafe => planSafeHoursLeft ?? safeHoursLeft;

  /// ok/warning/critical against the reserve-aware planning limit.
  String get planStatus {
    if (unclassifiable || currentPct >= effectivePlanLimit) return 'critical';
    final warnAt = warnPct > 0 ? warnPct : effectivePlanLimit * 0.6;
    if (approaching || currentPct >= warnAt) return 'warning';
    return 'ok';
  }

  /// ok/warning/critical against the school limit.
  String get status {
    final warnAt = warnPct > 0 ? warnPct : limitPct * 0.6;
    if (unclassifiable || currentPct >= limitPct) return 'critical';
    if (approaching || currentPct >= warnAt) return 'warning';
    return 'ok';
  }
}

/// One absence/late arrival waiting for (one-click) excusing.
class ExcuseTask {
  final String key;
  final String kind; // "late" | "early" | "soon" | "short"
  final String label;
  final String detail;
  final DateTime? date;
  final int? period;
  final String template;
  final String status; // pending | sent | failed

  const ExcuseTask({
    required this.key,
    required this.kind,
    required this.label,
    this.detail = '',
    this.date,
    this.period,
    this.template = '',
    this.status = 'pending',
  });
}

/// Builds pending excuse tasks from unexcused absent/late lessons.
List<ExcuseTask> excuseTasksFromLessons(Iterable<Lesson> lessons) {
  final tasks = <ExcuseTask>[];
  for (final lesson in lessons) {
    if (lesson.excused ||
        ['excused', 'cancelled', '', 'present'].contains(lesson.status)) {
      continue;
    }
    if (![
      'absent',
      'absence',
      'nepritomen',
      'neprítomen',
      'unexcused',
      'late',
      'early',
      'soon',
      'absentlate',
      'absentearly',
    ].contains(lesson.status)) {
      continue;
    }
    final String kind;
    if (lesson.status == 'soon') {
      kind = 'soon';
    } else if (lesson.status == 'late' || lesson.status == 'absentlate') {
      kind = 'late';
    } else if (lesson.status == 'early' || lesson.status == 'absentearly') {
      kind = 'early';
    } else {
      kind = 'short';
    }
    final day = lesson.day;
    final dayLabel =
        day == null ? '?' : '${day.day}. ${day.month}.';
    final periodLabel = lesson.period != null
        ? ", ${t('period_label', args: {'n': lesson.period})}"
        : '';
    String isoDay;
    if (day == null) {
      isoDay = '?';
    } else {
      String two(int n) => n.toString().padLeft(2, '0');
      isoDay = '${day.year}-${two(day.month)}-${two(day.day)}';
    }
    final key = '$isoDay|${lesson.period}|${lesson.subject}';
    tasks.add(ExcuseTask(
      key: key,
      kind: kind,
      label: '${lesson.subject} — $dayLabel$periodLabel',
      detail: [lesson.teacher, lesson.room]
          .where((p) => p.isNotEmpty)
          .join(' · '),
      date: lesson.day,
      period: lesson.period,
    ));
  }
  return tasks;
}
