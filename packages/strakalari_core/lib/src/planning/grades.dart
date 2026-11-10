// Marks (průběžná klasifikace) maths: parsing, scales, averages, predictions.
//
// Port of strakalari/core/grades.py. Pure logic, no UI. Two scales exist
// in Bakaláři:
//
// * `grade` — the Czech 1–5 scale (1 best). `"1-"` sits halfway to the
//   next grade (1.5), a trailing `"+"` keeps the base grade.
// * `percent` — 0–100 %, written `"85 %"`, as points (`"17/20"`) or,
//   in many schools, as a bare number (`"85"`).
//
// Every mark is read in its own right first: `"2-"` is always a grade,
// `"85"` / `"85 %"` / `"17/20"` are always percent. Only a bare
// `1`–`5` is ambiguous; it follows the subject's scale. A subject's
// scale is detected from its unambiguous marks (falling back to the whole
// school's marks) and can be forced by the user. Marks written in the
// other scale are converted through the percent bands so they still count.
//
// Predictions never touch the real marks: they are a small set of
// operations (added / edited / removed marks) applied on top, so a
// refresh that brings new real marks keeps the user's what-ifs intact.
import 'package:clock/clock.dart';

import '../models.dart';
import '../storage/helpers.dart';

/// Scales a subject can be graded on.
const List<String> scales = ['grade', 'percent'];

/// Scale choices (including the automatic detection).
const List<String> scaleChoices = ['auto', 'grade', 'percent'];

/// Grade boundaries as Bakaláři's "Tabulka převodu" lists them: the top of
/// grades 2, 3, 4 and 5. A boundary value already belongs to the worse
/// grade (87 % is the first 2 when the 2 starts at 87). Schools override
/// it through their preset or `marks_percent_bands`.
const List<double> defaultBands = [90.0, 75.0, 50.0, 30.0];

/// Grade steps a real mark can take (`1`, `1-`, `2` … `5`).
const List<double> gradeSteps = [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0];

final RegExp _gradeRe = RegExp(r'^([1-5])\s*([+\-−–])$');
final RegExp _percentRe = RegExp(r'^(\d+(?:[.,]\d+)?)\s*%$');
final RegExp _pointsRe = RegExp(r'^(\d+(?:[.,]\d+)?)\s*/\s*(\d+(?:[.,]\d+)?)$');
final RegExp _numberRe = RegExp(r'^\d+(?:[.,]\d+)?$');

// -- parsing -------------------------------------------------------------

/// A mark read on its own: `kind` is grade, percent or small (1–5).
class RawMark {
  /// `grade`, `percent` or `small`.
  final String kind;

  /// Numeric value (percent clamped to 0–100).
  final double value;

  const RawMark(this.kind, this.value);

  @override
  bool operator ==(Object other) =>
      other is RawMark && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'RawMark($kind, $value)';
}

double _num(String text) => double.parse(text.replaceAll(',', '.'));

/// Reads one mark without context. Null for non-counting marks.
///
/// `"2-"` -> grade 2.5, `"85 %"` / `"85"` / `"17/20"` -> percent,
/// bare `"1"`–`"5"` -> small (scale decides). `N`, `X`, `?`,
/// `A` and empty text do not count. [points] (Bakaláři PointsText)
/// is used when the mark text itself is not a number.
RawMark? parseRaw(Object? text, [Object? points]) {
  final raw = '${text ?? ''}'.trim();
  var m = _gradeRe.firstMatch(raw);
  if (m != null) {
    final base = double.parse(m.group(1)!);
    if (m.group(2) != '+') {
      final half = base + 0.5;
      return RawMark('grade', half > 5.0 ? 5.0 : half);
    }
    return RawMark('grade', base);
  }
  m = _percentRe.firstMatch(raw);
  if (m != null) {
    return RawMark('percent', _clampPct(_num(m.group(1)!)));
  }
  m = _pointsRe.firstMatch(raw);
  if (m != null) {
    final got = _num(m.group(1)!);
    final top = _num(m.group(2)!);
    if (top > 0) {
      return RawMark('percent', _clampPct(got / top * 100.0));
    }
    return null;
  }
  if (_numberRe.hasMatch(raw)) {
    final value = _num(raw);
    if (value >= 1.0 && value <= 5.0) {
      return RawMark('small', value);
    }
    return RawMark('percent', _clampPct(value));
  }
  if (points != null &&
      points != '' &&
      raw != '$points'.trim()) {
    final found = parseRaw(points);
    if (found != null && found.kind == 'percent') return found;
  }
  return null;
}

double _clampPct(double value) =>
    value < 0.0 ? 0.0 : (value > 100.0 ? 100.0 : value);

/// Mark weight; missing or invalid -> 1, zero stays zero (not counted).
double parseWeight(Object? value) {
  final w = double.tryParse('$value'.replaceAll(',', '.').trim());
  if (w == null || w.isNaN || w < 0) return 1.0;
  return w;
}

bool _truthy(Object? value) {
  if (value == null || value == false) return false;
  if (value is num) return value != 0;
  if (value is String) return value.isNotEmpty;
  if (value is Iterable) return value.isNotEmpty;
  if (value is Map) return value.isNotEmpty;
  return true;
}

/// True for an announced-but-not-yet-given mark (`?` in Bakaláři).
bool isPlanned(Object? mark) {
  if (mark is! Map) return false;
  if (_truthy(mark['Planned'])) return true;
  return '${mark['Grade'] ?? ''}'.trim() == '?';
}

// -- scale conversion ----------------------------------------------------

/// True for four strictly decreasing boundaries within (0, 100].
bool bandsValid(Object? bands) {
  if (bands is String || bands is! List) return false;
  if (bands.length != 4) return false;
  final vals = <double>[];
  for (final b in bands) {
    final double? v;
    if (b is bool) {
      // Python float(True) == 1.0: bools are valid band entries.
      v = b ? 1.0 : 0.0;
    } else if (b is num) {
      v = b.toDouble();
    } else {
      v = double.tryParse('$b'.trim());
    }
    if (v == null || v.isNaN) return false;
    vals.add(v);
  }
  for (var i = 0; i + 1 < vals.length; i++) {
    if (!(vals[i] > 0 && vals[i] <= 100)) return false;
  }
  if (!(vals[3] > 0 && vals[3] <= 100)) return false;
  for (var i = 0; i + 1 < vals.length; i++) {
    if (!(vals[i] > vals[i + 1])) return false;
  }
  return true;
}

/// The bands as doubles when valid, else [defaultBands].
List<double> normalizeBands(Object? bands) {
  if (!bandsValid(bands)) return List<double>.of(defaultBands);
  return [
    for (final b in (bands as List))
      b is num ? b.toDouble() : double.parse('$b'.trim()),
  ];
}

/// Final grade (1–5) a percentage earns; a boundary is the worse grade's top.
int pctToGrade(double pct, [List<double> bands = defaultBands]) {
  for (var i = 0; i < bands.length; i++) {
    if (pct > bands[i] + 1e-9) return i + 1;
  }
  return 5;
}

/// Percent equivalent of a grade: the middle of its band, interpolated
/// for in-between values (`1-` = 1.5 lands between the 1 and 2 middles).
double gradeToPct(double grade, [List<double> bands = defaultBands]) {
  final tops = [100.0, ...bands];
  final mids = [
    for (var i = 0; i < 4; i++) (tops[i] + tops[i + 1]) / 2,
    tops[4] / 2,
  ];
  final g = grade < 1.0 ? 1.0 : (grade > 5.0 ? 5.0 : grade);
  final lo = g.truncate();
  if (lo >= 5) return mids[4];
  final frac = g - lo;
  return mids[lo - 1] + (mids[lo] - mids[lo - 1]) * frac;
}

/// Czech report-card rounding: halves go down a grade (1.5 -> 2).
int roundGrade(double avg) {
  final rounded = (avg + 0.5 + 1e-9).truncate();
  return rounded < 1 ? 1 : (rounded > 5 ? 5 : rounded);
}

/// Final grade for an average, or null without one.
int? finalGrade(double? avg, String scale,
    [List<double> bands = defaultBands]) {
  if (avg == null) return null;
  return scale == 'percent' ? pctToGrade(avg, bands) : roundGrade(avg);
}

/// A value on the 1–5 axis (continuous for grades, stepped for percent).
double? gradeEquivalent(double? value, String scale,
    [List<double> bands = defaultBands]) {
  if (value == null) return null;
  return scale == 'percent'
      ? pctToGrade(value, bands).toDouble()
      : value;
}

/// Badge colour: ok (1–2), warning (3), critical (4–5), info (none).
String kindFor(double? value, String scale,
    [List<double> bands = defaultBands]) {
  final g = gradeEquivalent(value, scale, bands);
  if (g == null) return 'info';
  if (g <= 2) return 'ok';
  if (g <= 3) return 'warning';
  return 'critical';
}

/// Python `f'{value:.digitsf}'`: correctly-rounded fixed decimals,
/// halves to even.
///
/// A plain `value * 10^digits` scaling double-rounds (2.675 * 100 is
/// exactly 267.5, which would print '2.68' while Python prints '2.67'),
/// so the rounding runs on the 17-significant-digit expansion, which
/// pins down the exact binary value.
String _formatFixed(double value, int digits) {
  if (value.isNaN || value.isInfinite) return '$value';
  final neg = value < 0;
  var s = value.abs().toStringAsPrecision(17);
  var exp = 0;
  final ePos = s.indexOf('e');
  if (ePos >= 0) {
    exp = int.parse(s.substring(ePos + 1));
    s = s.substring(0, ePos);
  }
  final point = s.indexOf('.');
  var intDigits = point + exp; // digits before the decimal point
  final digitStr = s.replaceAll('.', '');
  final stripped = digitStr.replaceFirst(RegExp('^0+'), '');
  intDigits -= digitStr.length - stripped.length;
  String intPart;
  String fracPart;
  if (stripped.isEmpty) {
    intPart = '0';
    fracPart = '';
  } else if (intDigits <= 0) {
    intPart = '0';
    fracPart = '${'0' * -intDigits}$stripped';
  } else if (intDigits >= stripped.length) {
    intPart = '$stripped${'0' * (intDigits - stripped.length)}';
    fracPart = '';
  } else {
    intPart = stripped.substring(0, intDigits);
    fracPart = stripped.substring(intDigits);
  }
  var kept = '$fracPart${'0' * digits}'.substring(0, digits);
  final rest = fracPart.length > digits ? fracPart.substring(digits) : '';
  var roundUp = false;
  if (rest.isNotEmpty) {
    final next = rest.codeUnitAt(0) - 48;
    if (next != 5) {
      roundUp = next > 5;
    } else if (rest.substring(1).contains(RegExp('[1-9]'))) {
      roundUp = true; // 5 followed by non-zero: strictly more than half
    } else {
      // Exact tie (within 17 digits): to even.
      final last = kept.isEmpty
          ? intPart.codeUnitAt(intPart.length - 1) - 48
          : kept.codeUnitAt(kept.length - 1) - 48;
      roundUp = last.isOdd;
    }
  }
  if (roundUp) {
    final chars = '$intPart$kept'.split('');
    var i = chars.length - 1;
    while (i >= 0 && chars[i] == '9') {
      chars[i] = '0';
      i--;
    }
    if (i < 0) {
      chars.insert(0, '1');
    } else {
      chars[i] = String.fromCharCode(chars[i].codeUnitAt(0) + 1);
    }
    final joined = chars.join();
    final splitAt = joined.length - digits;
    intPart = joined.substring(0, splitAt);
    kept = digits == 0 ? '' : joined.substring(splitAt);
  }
  final sign = neg ? '-' : '';
  return digits == 0 ? '$sign$intPart' : '$sign$intPart.$kept';
}

/// `1.83` for grade averages, `84.5 %` for percent; `—` for null.
String formatValue(double? value, String scale, [int? digits]) {
  if (value == null) return '—';
  if (scale == 'percent') {
    final d = digits ?? 1;
    final text = _formatFixed(value, d);
    if (d == 0) return '$text %';
    final stripped = text.replaceAll(RegExp('0+\$'), '').replaceAll(RegExp(r'\.$'), '');
    return '$stripped %';
  }
  return _formatFixed(value, digits ?? 2);
}

/// `1.5` -> `1-`, `2.0` -> `2`.
String formatGradeStep(double value) {
  final base = value.truncate();
  return value - base >= 0.25 ? '$base-' : '$base';
}

/// A mark's value on [scale] (converting from the other scale).
///
/// A bare 1–5 follows the subject scale, except on a percent subject
/// with no real percentage at all (a forced switch on a 1–5 subject):
/// reading "2" as 2 % would be absurd there, so it converts instead.
double? resolve(RawMark? raw, String scale, bool subjectHasPct,
    [List<double> bands = defaultBands]) {
  if (raw == null) return null;
  var kind = raw.kind;
  if (kind == 'small') {
    kind = (scale == 'percent' && subjectHasPct) ? 'percent' : 'grade';
  }
  if (kind == scale) return raw.value;
  if (scale == 'percent') return gradeToPct(raw.value, bands);
  return pctToGrade(raw.value, bands).toDouble();
}

/// `percent` when unambiguous percentages outnumber the grade-like
/// marks; [fallback] when a subject has nothing but `?` / `N` marks.
String detectScale(Iterable<Object?>? marks, [String fallback = 'grade']) {
  var pct = 0;
  var grade = 0;
  for (final mark in marks ?? const <Object?>[]) {
    if (mark is! Map || isPlanned(mark)) continue;
    final raw = parseRaw(mark['Grade'], mark['Points']);
    if (raw == null) continue;
    if (raw.kind == 'percent') {
      pct += 1;
    } else {
      grade += 1;
    }
  }
  if (pct == 0 && grade == 0) {
    return fallback == 'percent' ? 'percent' : 'grade';
  }
  // Ties read as percent (mirrors Python's `pct >= grade`).
  return (pct >= grade && pct > 0) ? 'percent' : 'grade';
}

/// Scale of the whole marks page (the prior for subjects without evidence).
String detectSchoolScale(Map<dynamic, dynamic>? grades) {
  final everything = <Object?>[
    for (final ms in (grades ?? {}).values)
      if (ms is Iterable) ...ms,
  ];
  return detectScale(everything, 'grade');
}

// -- averages -------------------------------------------------------------

/// Weighted mean of (value, weight) pairs; null when nothing counts.
double? weightedAverage(Iterable<(double?, double)> pairs) {
  var total = 0.0;
  var weight = 0.0;
  for (final (value, w) in pairs) {
    if (value == null || w <= 0) continue;
    total += value * w;
    weight += w;
  }
  return weight > 0 ? total / weight : null;
}

// -- predictions ------------------------------------------------------------

/// Stable identity per real mark: the Bakaláři id, else its content plus
/// an occurrence counter (two identical marks on one day stay distinct).
List<String> markKeys(List<Object?>? marks) {
  final seen = <String, int>{};
  final keys = <String>[];
  for (final mark in marks ?? const <Object?>[]) {
    final m = mark is Map ? mark : <String, Object?>{};
    final ident = '${m['Id'] ?? ''}'.trim();
    final String base;
    if (ident.isNotEmpty) {
      base = 'id:$ident';
    } else {
      base =
          ['Date', 'Grade', 'Weight', 'Caption'].map((k) => '${m[k] ?? ''}').join('|');
    }
    final n = seen[base] ?? 0;
    seen[base] = n + 1;
    keys.add(n == 0 ? base : '$base#$n');
  }
  return keys;
}

/// Empty what-if operations.
Map<String, Object?> emptyPrediction() {
  return {
    'added': <Object?>[],
    'edits': <String, Object?>{},
    'removed': <Object?>[],
  };
}

/// True when any what-if operation is present.
bool predictionActive(Map<dynamic, dynamic>? ops) {
  final o = ops ?? {};
  return _truthy(o['added']) || _truthy(o['edits']) || _truthy(o['removed']);
}

/// One mark as the view shows it (real, edited, removed or hypothetical).
class MarkRow {
  /// Stable identity of the mark.
  final String key;

  /// The mark as shown (edits applied).
  final Map<String, Object?> mark;

  /// `real` | `edited` | `removed` | `added`.
  final String state;

  /// Value on the subject scale; null = does not count.
  final double? value;

  /// Mark weight.
  final double weight;

  /// The mark read on its own.
  final RawMark? raw;

  /// The real mark behind an edit.
  final Map<String, Object?>? original;

  /// Parsed mark date.
  final DateTime? date;

  const MarkRow(
    this.key,
    this.mark,
    this.state,
    this.value,
    this.weight,
    this.raw, {
    this.original,
    this.date,
  });

  /// The average the UI leads with: predicted while predicting.
  bool get counts => state != 'removed' && value != null && weight > 0;

  /// Mark text as shown (Grade field of mark map, or '?').
  String get text => '${mark['Grade'] ?? '?'}';
}

/// Everything the marks view needs about one subject.
class SubjectSummary {
  /// Subject name.
  final String name;

  /// Effective scale.
  final String scale;

  /// Detected scale (before forcing).
  final String detected;

  /// True when the user forced the scale.
  final bool forced;

  /// Marks chronological, oldest first.
  final List<MarkRow> rows;

  /// Announced-but-not-given marks.
  final List<Map<String, Object?>> planned;

  /// Real marks only.
  final double? average;

  /// With the prediction applied.
  final double? predicted;

  /// True while any what-if operation is present.
  final bool predicting;

  /// Real avg change caused by the newest mark.
  final double? trend;

  /// Marks from the last [newDays] days.
  final int newCount;

  /// Latest real mark date.
  final DateTime? lastDate;

  /// Running average over the real marks (chronological).
  final List<(DateTime?, double)> history;

  const SubjectSummary({
    required this.name,
    required this.scale,
    required this.detected,
    required this.forced,
    required this.rows,
    required this.planned,
    required this.average,
    required this.predicted,
    required this.predicting,
    required this.trend,
    required this.newCount,
    required this.lastDate,
    this.history = const [],
  });

  /// The average the UI leads with: predicted while predicting.
  double? get current => predicting ? predicted : average;

  /// Counting real marks (edited rows count once).
  int get realCount =>
      rows.where((r) => r.state != 'added' && r.value != null).length;
}

Map<String, Object?> _entry(Object? mark) =>
    mark is Map ? Map<String, Object?>.from(mark) : {};

/// Everything the marks view needs about one subject.
SubjectSummary summarize(String name, List<Object?>? marks,
    {String scalePref = 'auto',
    String fallback = 'grade',
    Map<dynamic, dynamic>? ops,
    Object? bands = defaultBands,
    DateTime? today,
    int newDays = 7}) {
  final now = today ?? clock.now();
  final todayDay = DateTime(now.year, now.month, now.day);
  final normalized = normalizeBands(bands);
  final real = <Map<String, Object?>>[
    for (final m in marks ?? const <Object?>[])
      if (m is Map) _entry(m),
  ];
  final planned = [for (final m in real) if (isPlanned(m)) m];
  final given = [for (final m in real) if (!isPlanned(m)) m];
  final detected = detectScale(given, fallback);
  final forced = scalePref == 'grade' || scalePref == 'percent';
  final scale = forced ? scalePref : detected;

  final edits = ops?['edits'] is Map<dynamic, dynamic>
      ? ops!['edits'] as Map<dynamic, dynamic>
      : <dynamic, dynamic>{};
  final removed = <Object?>{
    ...((ops?['removed'] is Iterable) ? (ops!['removed'] as Iterable) : []),
  };
  final added = <Object?>[
    ...((ops?['added'] is Iterable) ? (ops!['added'] as Iterable) : []),
  ];

  RawMark? rawOf(Map<String, Object?> m) =>
      parseRaw(m['Grade'], m['Points']);

  // Every candidate mark (real, edits, hypotheticals) decides whether
  // a bare 1–5 may be a percentage on this subject.
  var hasPct = false;
  for (final m in [
    ...given,
    for (final e in edits.values)
      if (e is Map) _entry(e),
    ...added.map(_entry),
  ]) {
    final r = rawOf(m);
    if (r != null && r.kind == 'percent') {
      hasPct = true;
      break;
    }
  }

  (RawMark?, double?) valued(Map<String, Object?> m) {
    final raw = rawOf(m);
    return (raw, resolve(raw, scale, hasPct, normalized));
  }

  final rows = <MarkRow>[];
  final keys = markKeys(given);
  for (var i = 0; i < given.length; i++) {
    final key = keys[i];
    final mark = given[i];
    final day = parseCzDate(mark['Date']);
    if (removed.contains(key)) {
      final (raw, value) = valued(mark);
      rows.add(MarkRow(key, mark, 'removed', value,
          parseWeight(mark['Weight']), raw,
          date: day));
      continue;
    }
    final edit = edits[key];
    if (edit is Map) {
      final shown = Map<String, Object?>.from(mark);
      if (edit.containsKey('Grade')) shown['Grade'] = edit['Grade'];
      if (edit.containsKey('Weight')) shown['Weight'] = edit['Weight'];
      shown.remove('Points');
      final (raw, value) = valued(shown);
      rows.add(MarkRow(key, shown, 'edited', value,
          parseWeight(shown['Weight']), raw,
          original: mark, date: day));
      continue;
    }
    final (raw, value) = valued(mark);
    rows.add(MarkRow(
        key, mark, 'real', value, parseWeight(mark['Weight']), raw,
        date: day));
  }
  // Python sort is stable; Dart's is not, so keep insertion order on ties.
  final indexed = rows.indexed.toList();
  indexed.sort((a, b) {
    final ad = a.$2.date ?? DateTime(1, 1, 1);
    final bd = b.$2.date ?? DateTime(1, 1, 1);
    final byDate = ad.compareTo(bd);
    if (byDate != 0) return byDate;
    return a.$1.compareTo(b.$1);
  });
  rows
    ..clear()
    ..addAll([for (final e in indexed) e.$2]);
  for (var i = 0; i < added.length; i++) {
    final mark = _entry(added[i]);
    final (raw, value) = valued(mark);
    rows.add(MarkRow('add:$i', mark, 'added', value,
        parseWeight(mark['Weight']), raw));
  }

  final realRows = [
    for (final r in rows)
      if (r.state == 'real' || r.state == 'edited' || r.state == 'removed') r,
  ];
  final realPairs = <(double?, double)>[];
  for (final r in realRows) {
    final source = r.state == 'edited' ? r.original! : r.mark;
    final raw = rawOf(source);
    realPairs.add((
      resolve(raw, scale, hasPct, normalized),
      parseWeight(source['Weight']),
    ));
  }
  final average = weightedAverage(realPairs);
  final predicting = predictionActive(ops);
  final predicted = predicting
      ? weightedAverage([
          for (final r in rows)
            if (r.counts) (r.value, r.weight),
        ])
      : null;

  // Running average over the real marks (chronological) — the trend line.
  final history = <(DateTime?, double)>[];
  var total = 0.0;
  var weight = 0.0;
  for (var i = 0; i < realRows.length; i++) {
    final (value, w) = realPairs[i];
    if (value == null || w <= 0) continue;
    total += value * w;
    weight += w;
    history.add((realRows[i].date, total / weight));
  }
  final trend = history.length >= 2
      ? history.last.$2 - history[history.length - 2].$2
      : null;

  final cutoff = addDays(todayDay, -newDays);
  var newCount = 0;
  for (final m in given) {
    if (_truthy(m['New'])) {
      newCount += 1;
      continue;
    }
    final d = parseCzDate(m['Date']);
    if (d != null && !d.isBefore(cutoff)) newCount += 1;
  }
  final dates = [
    for (final r in realRows)
      if (r.date != null) r.date!,
  ];
  return SubjectSummary(
    name: name,
    scale: scale,
    detected: detected,
    forced: forced,
    rows: rows,
    planned: planned,
    average: average,
    predicted: predicted,
    predicting: predicting,
    trend: trend,
    newCount: newCount,
    lastDate: dates.isEmpty
        ? null
        : dates.reduce((a, b) => a.isAfter(b) ? a : b),
    history: history,
  );
}

/// One summary per subject; a per-subject choice beats the global one.
List<SubjectSummary> summarizeAll(Map<dynamic, dynamic>? grades,
    {String scalePref = 'auto',
    Map<dynamic, dynamic>? subjectScales,
    Map<dynamic, dynamic>? predictions,
    Object? bands = defaultBands,
    DateTime? today}) {
  final school = detectSchoolScale(grades);
  final names = (grades ?? {}).keys.map((k) => '$k').toList()
    ..sort((a, b) {
      final folded = a.toLowerCase().compareTo(b.toLowerCase());
      return folded != 0 ? folded : a.compareTo(b);
    });
  final out = <SubjectSummary>[];
  for (final name in names) {
    final value = (grades ?? {})[name];
    final pref = (subjectScales ?? {})[name];
    final effective =
        (pref == 'grade' || pref == 'percent') ? pref as String : (scalePref == 'grade' || scalePref == 'percent' ? scalePref : 'auto');
    final ops = (predictions ?? {})[name];
    out.add(summarize(
      name,
      value is List ? value : [],
      scalePref: effective,
      fallback: school,
      ops: ops is Map ? ops : null,
      bands: bands,
      today: today,
    ));
  }
  return out;
}

/// True when [text] is a mark the predictor can count.
///
/// Stricter than [parseRaw] (which clamps odd page data): a typed
/// percentage above 100 or points above the maximum are refused.
bool validMarkText(Object? text) {
  final raw = '${text ?? ''}'.trim();
  if (parseRaw(raw) == null) return false;
  var m = _pointsRe.firstMatch(raw);
  if (m != null) {
    return _num(m.group(1)!) <= _num(m.group(2)!);
  }
  m = _percentRe.firstMatch(raw);
  if (m != null) {
    return _num(m.group(1)!) <= 100;
  }
  if (_numberRe.hasMatch(raw)) {
    return _num(raw) <= 100;
  }
  return true;
}

/// The subject's most common real weight (ties -> the higher one).
double defaultWeight(SubjectSummary summary) {
  final counts = <double, int>{};
  for (final r in summary.rows) {
    if (r.state == 'real' || r.state == 'edited') {
      counts[r.weight] = (counts[r.weight] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return 1.0;
  // Python max(counts, key=(count, weight)): strictly greater replaces,
  // so ties keep the first maximum in insertion order.
  var best = counts.keys.first;
  for (final w in counts.keys) {
    if (counts[w]! > counts[best]! ||
        (counts[w] == counts[best] && w > best)) {
      best = w;
    }
  }
  return best;
}

/// Python `f'{weight:g}'` (6 significant digits, exponent when tiny/huge).
String formatWeight(double weight) {
  if (!weight.isFinite) return '$weight';
  if (weight == weight.truncateToDouble() && weight.abs() < 1e15) {
    return '${weight.truncate()}';
  }
  var s = weight.toStringAsPrecision(6);
  if (s.contains('e')) {
    final parts = s.split('e');
    final mantissa = parts[0]
        .replaceAll(RegExp('0+\$'), '')
        .replaceAll(RegExp(r'\.$'), '');
    final exp = int.parse(parts[1]);
    final sign = exp < 0 ? '-' : '+';
    return '${mantissa}e$sign${exp.abs().toString().padLeft(2, '0')}';
  }
  s = s.replaceAll(RegExp('0+\$'), '').replaceAll(RegExp(r'\.$'), '');
  return s;
}

// -- "what do I need" -------------------------------------------------------

/// What the next mark must be to finish with [Needed.status] `target`.
///
/// `status`: `any` (even the worst mark keeps the target), `need`
/// (`value` is the worst acceptable mark), `impossible` (not with one
/// mark — `count` best marks of that weight would do, 0 = unreachable).
class Needed {
  /// `any` | `need` | `impossible`.
  final String status;

  /// Worst acceptable next mark (for `need`), best mark (for `impossible`).
  final double? value;

  /// How many best marks of that weight would do (for `impossible`).
  final int count;

  const Needed(this.status, [this.value, this.count = 0]);

  @override
  String toString() => 'Needed($status, $value, $count)';
}

/// Worst next mark (of [weight]) that still ends on final [target].
Needed neededFor(List<MarkRow> rows, String scale, int target, num weight,
    [List<double> bands = defaultBands]) {
  final normalized = normalizeBands(bands);
  final w = (weight.toDouble() < 0.01 ? 0.01 : weight.toDouble());
  var total = 0.0;
  var wsum = 0.0;
  for (final r in rows) {
    if (!r.counts) continue;
    total += r.value! * r.weight;
    wsum += r.weight;
  }

  bool ok(double avg) => finalGrade(avg, scale, normalized)! <= target;

  if (scale == 'percent') {
    if (ok(total / (wsum + w))) {
      // even 0 % keeps the target
      return const Needed('any');
    }
    final lower = target < 5 ? normalized[target - 1] : 0.0;
    var start = ((lower * (wsum + w) - total) / w).truncate();
    if (start < 0) start = 0;
    // Whole percents; boundaries are strict.
    for (var pct = start; pct <= 100; pct++) {
      if (ok((total + pct * w) / (wsum + w))) {
        return Needed('need', pct.toDouble());
      }
    }
    const best = 100.0;
    for (var n = 2; n <= 60; n++) {
      if (ok((total + best * w * n) / (wsum + w * n))) {
        return Needed('impossible', best, n);
      }
    }
    return const Needed('impossible', best, 0);
  } else {
    final acceptable = [
      for (final g in gradeSteps)
        if (ok((total + g * w) / (wsum + w))) g,
    ];
    if (acceptable.isNotEmpty &&
        acceptable.reduce((a, b) => a > b ? a : b) >= 5.0) {
      return const Needed('any');
    }
    if (acceptable.isNotEmpty) {
      return Needed(
          'need', acceptable.reduce((a, b) => a > b ? a : b));
    }
    const best = 1.0;
    for (var n = 2; n <= 60; n++) {
      if (ok((total + best * w * n) / (wsum + w * n))) {
        return Needed('impossible', best, n);
      }
    }
    return const Needed('impossible', best, 0);
  }
}
