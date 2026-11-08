import '../common/format.dart';

/// Marks (průběžná klasifikace) maths — a pure port of
/// `strakalari/core/grades.py` for the marks screen.
///
/// Two scales exist: `grade` (Czech 1–5, `1-` = 1.5, trailing `+` keeps
/// the base grade) and `percent` (0–100 % as `85 %`, points `17/20` or
/// bare numbers). Every mark is read on its own first; only a bare
/// `1`–`5` is ambiguous and follows the subject's scale.
const List<String> scales = ['grade', 'percent'];

/// Scale choices (including the automatic detection).
const List<String> scaleChoices = ['auto', 'grade', 'percent'];

/// Grade boundaries as Bakaláři's conversion table lists them: the top
/// of grades 2, 3, 4 and 5. A boundary value already belongs to the
/// worse grade (87 % is the first 2 when the 2 starts at 87).
const List<double> defaultBands = [90.0, 75.0, 50.0, 30.0];

/// Grade steps a real mark can take (`1`, `1-`, `2` … `5`).
const List<double> gradeSteps = [
  1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0
];

// PLAN §3.5: plain numbered groups, no inline flags, no \Z.
final RegExp _gradeRe = RegExp(r'^([1-5])\s*([+\-−–])$');
final RegExp _percentRe = RegExp(r'^(\d+(?:[.,]\d+)?)\s*%$');
final RegExp _pointsRe =
    RegExp(r'^(\d+(?:[.,]\d+)?)\s*/\s*(\d+(?:[.,]\d+)?)$');
final RegExp _numberRe = RegExp(r'^\d+(?:[.,]\d+)?$');

// -- parsing ------------------------------------------------------------------

/// A mark read on its own: `kind` is grade, percent or small (1–5).
class RawMark {
  final String kind;
  final double value;
  const RawMark(this.kind, this.value);
}

double _num(String text) =>
    double.parse(text.replaceAll(',', '.'));

/// Reads one mark without context. Null for non-counting marks —
/// like `grades.parse_raw`.
RawMark? parseRaw(Object? text, [Object? points]) {
  final raw = '${text ?? ''}'.trim();
  var m = _gradeRe.firstMatch(raw);
  if (m != null) {
    final base = double.parse(m.group(1)!);
    final plus = m.group(2) == '+';
    final value = plus ? base : base + 0.5;
    return RawMark('grade', value > 5.0 ? 5.0 : value);
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
      '$points'.trim().isNotEmpty &&
      raw != '$points'.trim()) {
    final found = parseRaw(points);
    if (found != null && found.kind == 'percent') return found;
  }
  return null;
}

double _clampPct(double value) =>
    value.clamp(0.0, 100.0).toDouble();

/// Mark weight; missing or invalid → 1, zero stays zero (not counted) —
/// like `grades.parse_weight`.
double parseWeight(Object? value) {
  final parsed =
      double.tryParse('${value ?? ''}'.replaceAll(',', '.').trim());
  if (parsed == null || parsed.isNaN || parsed < 0) return 1.0;
  return parsed;
}

/// True for an announced-but-not-yet-given mark (`?` in Bakaláři) —
/// like `grades.is_planned`.
bool isPlanned(Map<String, Object?> mark) {
  if (mark['Planned'] == true ||
      (mark['Planned'] is num && (mark['Planned'] as num) != 0)) {
    return true;
  }
  return '${mark['Grade'] ?? ''}'.trim() == '?';
}

// -- scale conversion -------------------------------------------------------------

/// True for four strictly decreasing boundaries within (0, 100] —
/// like `grades.bands_valid`.
bool bandsValid(Object? bands) {
  if (bands is String || bands is! List) return false;
  if (bands.length != 4) return false;
  final vals = <double>[];
  for (final b in bands) {
    final v = b is num ? b.toDouble() : double.tryParse('$b'.trim());
    if (v == null) return false;
    vals.add(v);
  }
  if (!vals.every((v) => v > 0 && v <= 100)) return false;
  for (var i = 0; i < 3; i++) {
    if (!(vals[i] > vals[i + 1])) return false;
  }
  return true;
}

/// The bands as floats when valid, else [defaultBands] —
/// like `grades.normalize_bands`.
List<double> normalizeBands(Object? bands) {
  if (!bandsValid(bands)) return List<double>.of(defaultBands);
  return [(bands as List).map((b) => b is num ? b.toDouble() : double.parse('$b'.trim())).toList()]
      .first;
}

/// Final grade (1–5) a percentage earns; a boundary is the worse
/// grade's top — like `grades.pct_to_grade`.
int pctToGrade(double pct, [List<double> bands = defaultBands]) {
  for (var i = 0; i < bands.length; i++) {
    if (pct > bands[i] + 1e-9) return i + 1;
  }
  return 5;
}

/// Percent equivalent of a grade: the middle of its band,
/// interpolated for in-between values — like `grades.grade_to_pct`.
double gradeToPct(double grade, [List<double> bands = defaultBands]) {
  final tops = [100.0, ...bands];
  final mids = [
    for (var i = 0; i < 4; i++) (tops[i] + tops[i + 1]) / 2,
    tops[4] / 2,
  ];
  final g = grade.clamp(1.0, 5.0);
  final lo = g.toInt();
  if (lo >= 5) return mids[4];
  final frac = g - lo;
  return mids[lo - 1] + (mids[lo] - mids[lo - 1]) * frac;
}

/// Czech report-card rounding: halves go down a grade (1.5 → 2) —
/// like `grades.round_grade`.
int roundGrade(double avg) {
  final v = (avg + 0.5 + 1e-9).toInt().clamp(1, 5);
  return v;
}

int? finalGrade(double? avg, String scale,
    [List<double> bands = defaultBands]) {
  if (avg == null) return null;
  return scale == 'percent' ? pctToGrade(avg, bands) : roundGrade(avg);
}

/// A value on the 1–5 axis (continuous for grades, stepped for
/// percent) — like `grades.grade_equivalent`.
double? gradeEquivalent(double? value, String scale,
    [List<double> bands = defaultBands]) {
  if (value == null) return null;
  return scale == 'percent'
      ? pctToGrade(value, bands).toDouble()
      : value;
}

/// Badge colour: ok (1–2), warning (3), critical (4–5), info (none) —
/// like `grades.kind_for`.
String kindFor(double? value, String scale,
    [List<double> bands = defaultBands]) {
  final g = gradeEquivalent(value, scale, bands);
  if (g == null) return 'info';
  if (g <= 2) return 'ok';
  if (g <= 3) return 'warning';
  return 'critical';
}

/// `1.83` for grade averages, `84.5 %` for percent; `—` for null —
/// like `grades.format_value`.
String formatValue(double? value, String scale, [int? digits]) {
  if (value == null) return '—';
  if (scale == 'percent') {
    final d = digits ?? 1;
    final String text;
    if (d == 0) {
      text = value.toStringAsFixed(0);
    } else {
      text = value
          .toStringAsFixed(d)
          .replaceAll(RegExp(r'0+$'), '')
          .replaceAll(RegExp(r'\.$'), '');
    }
    return '$text %';
  }
  return value.toStringAsFixed(digits ?? 2);
}

/// `1.5` → `1-`, `2.0` → `2` — like `grades.format_grade_step`.
String formatGradeStep(double value) {
  final base = value.toInt();
  return value - base >= 0.25 ? '$base-' : '$base';
}

/// A mark's value on `scale` (converting from the other scale) —
/// like `grades.resolve`.
double? resolveMark(RawMark? raw, String scale, bool subjectHasPct,
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
/// marks — like `grades.detect_scale`.
String detectScale(Iterable<Object?> marks,
    [String fallback = 'grade']) {
  var pct = 0;
  var grade = 0;
  for (final m in marks) {
    if (m is! Map) continue;
    final mm = m.cast<String, Object?>();
    if (isPlanned(mm)) continue;
    final raw = parseRaw(mm['Grade'], mm['Points']);
    if (raw == null) continue;
    if (raw.kind == 'percent') {
      pct++;
    } else {
      grade++;
    }
  }
  if (pct == 0 && grade == 0) {
    return scales.contains(fallback) ? fallback : 'grade';
  }
  return (pct >= grade && pct > 0) ? 'percent' : 'grade';
}

/// Scale of the whole marks page (the prior for subjects without
/// evidence) — like `grades.detect_school_scale`.
String detectSchoolScale(Map<String, List<Object?>> grades) {
  final everything = [
    for (final ms in grades.values) ...ms,
  ];
  return detectScale(everything, 'grade');
}

// -- averages -----------------------------------------------------------------------

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

// -- predictions ----------------------------------------------------------------------

/// Stable identity per real mark: the Bakaláři id, else its content
/// plus an occurrence counter — like `grades.mark_keys`.
List<String> markKeys(List<Map<String, Object?>> marks) {
  final seen = <String, int>{};
  final keys = <String>[];
  for (final mark in marks) {
    final ident = '${mark['Id'] ?? ''}'.trim();
    final String base;
    if (ident.isNotEmpty) {
      base = 'id:$ident';
    } else {
      base = ['Date', 'Grade', 'Weight', 'Caption']
          .map((k) => '${mark[k] ?? ''}')
          .join('|');
    }
    final n = seen[base] ?? 0;
    seen[base] = n + 1;
    keys.add(n == 0 ? base : '$base#$n');
  }
  return keys;
}

Map<String, Object?> emptyPrediction() => {
      'added': <Map<String, Object?>>[],
      'edits': <String, Map<String, Object?>>{},
      'removed': <String>[],
    };

bool predictionActive(Map<String, Object?>? ops) {
  ops ??= const {};
  final added = ops['added'];
  final edits = ops['edits'];
  final removed = ops['removed'];
  return (added is List && added.isNotEmpty) ||
      (edits is Map && edits.isNotEmpty) ||
      (removed is List && removed.isNotEmpty);
}

/// One mark as the view shows it (real, edited, removed or
/// hypothetical) — like `grades.MarkRow`.
class MarkRow {
  final String key;
  final Map<String, Object?> mark;

  /// `real | edited | removed | added`.
  final String state;

  /// Value on the subject scale; null = does not count.
  final double? value;
  final double weight;
  final RawMark? raw;

  /// The real mark behind an edit.
  final Map<String, Object?>? original;
  final DateTime? date;

  const MarkRow({
    required this.key,
    required this.mark,
    required this.state,
    required this.value,
    required this.weight,
    required this.raw,
    this.original,
    this.date,
  });

  String get text => '${mark['Grade'] ?? '?'}';

  bool get counts => state != 'removed' && value != null && weight > 0;
}

/// Everything the marks view needs about one subject —
/// like `grades.SubjectSummary`.
class SubjectSummary {
  final String name;
  final String scale;
  final String detected;
  final bool forced;
  final List<MarkRow> rows;
  final List<Map<String, Object?>> planned;

  /// Real marks only.
  final double? average;

  /// With the prediction applied.
  final double? predicted;
  final bool predicting;

  /// Real avg change caused by the newest mark.
  final double? trend;
  final int newCount;
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

RawMark? _rawOf(Map<String, Object?> m) =>
    parseRaw(m['Grade'], m['Points']);

double? _valueOf(Map<String, Object?> m, String scale, bool hasPct,
        List<double> bands) =>
    resolveMark(_rawOf(m), scale, hasPct, bands);

/// Everything the marks view needs about one subject —
/// like `grades.summarize`.
SubjectSummary summarize(String name, List<Object?>? marks,
    {String scalePref = 'auto',
    String fallback = 'grade',
    Map<String, Object?>? ops,
    Object? bands,
    DateTime? today,
    int newDays = 7}) {
  final now = today ?? DateTime.now();
  final todayDay = DateTime(now.year, now.month, now.day);
  final normalized = normalizeBands(bands);
  final real = <Map<String, Object?>>[
    for (final m in marks ?? const <Object?>[])
      if (m is Map) m.cast<String, Object?>(),
  ];
  final planned = [for (final m in real) if (isPlanned(m)) m];
  final given = [for (final m in real) if (!isPlanned(m)) m];
  final detected = detectScale(given, fallback);
  final forced = scales.contains(scalePref);
  final scale = forced ? scalePref : detected;

  final edits = (ops?['edits'] as Map?)?.cast<String, Object?>() ?? {};
  final removed = {
    for (final k in (ops?['removed'] as List? ?? const [])) '$k'
  };
  final added = [
    for (final e in (ops?['added'] as List? ?? const []))
      if (e is Map) e.cast<String, Object?>(),
  ];

  // Every candidate mark decides whether a bare 1–5 may be a
  // percentage on this subject.
  final candidates = [
    ...given,
    for (final e in edits.values)
      if (e is Map) e.cast<String, Object?>(),
    ...added,
  ];
  final hasPct = candidates.any((m) {
    final r = _rawOf(m);
    return r != null && r.kind == 'percent';
  });

  double? valueOf(Map<String, Object?> m) =>
      _valueOf(m, scale, hasPct, normalized);

  final rows = <MarkRow>[];
  final keys = markKeys(given);
  for (var i = 0; i < given.length; i++) {
    final key = keys[i];
    final mark = given[i];
    final day = parseCzDate(mark['Date']);
    if (removed.contains(key)) {
      rows.add(MarkRow(
          key: key,
          mark: mark,
          state: 'removed',
          value: valueOf(mark),
          weight: parseWeight(mark['Weight']),
          raw: _rawOf(mark),
          date: day));
      continue;
    }
    final edit = edits[key];
    if (edit is Map) {
      final shown = Map<String, Object?>.of(mark);
      final em = edit.cast<String, Object?>();
      shown['Grade'] = em['Grade'] ?? mark['Grade'];
      shown['Weight'] = em['Weight'] ?? mark['Weight'];
      shown.remove('Points');
      rows.add(MarkRow(
          key: key,
          mark: shown,
          state: 'edited',
          value: valueOf(shown),
          weight: parseWeight(shown['Weight']),
          raw: _rawOf(shown),
          original: mark,
          date: day));
      continue;
    }
    rows.add(MarkRow(
        key: key,
        mark: mark,
        state: 'real',
        value: valueOf(mark),
        weight: parseWeight(mark['Weight']),
        raw: _rawOf(mark),
        date: day));
  }
  // Stable chronological sort (oldest first); Dart's sort is not
  // stable, so ties keep insertion order via the index.
  final indexed = rows.indexed.toList();
  indexed.sort((a, b) {
    final da = a.$2.date;
    final db = b.$2.date;
    final sentinel = DateTime(1, 1, 1);
    final c = (da ?? sentinel).compareTo(db ?? sentinel);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  rows
    ..clear()
    ..addAll([for (final e in indexed) e.$2]);
  for (var i = 0; i < added.length; i++) {
    final mark = added[i];
    rows.add(MarkRow(
        key: 'add:$i',
        mark: mark,
        state: 'added',
        value: valueOf(mark),
        weight: parseWeight(mark['Weight']),
        raw: _rawOf(mark)));
  }

  final realRows = [
    for (final r in rows)
      if (r.state == 'real' ||
          r.state == 'edited' ||
          r.state == 'removed')
        r
  ];
  final realPairs = <(double?, double)>[];
  for (final r in realRows) {
    final source =
        r.state == 'edited' && r.original != null ? r.original! : r.mark;
    realPairs.add((
      _valueOf(source, scale, hasPct, normalized),
      parseWeight(source['Weight'])
    ));
  }
  final average = weightedAverage(realPairs);
  final predicting = predictionActive(ops);
  final predicted = predicting
      ? weightedAverage([
          for (final r in rows)
            if (r.counts) (r.value, r.weight)
        ])
      : null;

  // Running average over the real marks (chronological).
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
  final trend =
      history.length >= 2 ? history.last.$2 - history[history.length - 2].$2 : null;

  final cutoff = todayDay.subtract(Duration(days: newDays));
  var newCount = 0;
  for (final m in given) {
    final isNew = m['New'];
    if (isNew == true ||
        (isNew is num && isNew != 0) ||
        isNew == '1' ||
        isNew == 'true') {
      newCount++;
      continue;
    }
    final d = parseCzDate(m['Date']);
    if (d != null && !d.isBefore(cutoff)) newCount++;
  }
  final dates = [
    for (final r in realRows)
      if (r.date != null) r.date!
  ];
  dates.sort();
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
    lastDate: dates.isEmpty ? null : dates.last,
    history: history,
  );
}

/// One summary per subject; a per-subject choice beats the global one —
/// like `grades.summarize_all`.
List<SubjectSummary> summarizeAll(Map<String, List<Object?>> grades,
    {String scalePref = 'auto',
    Map<String, String> subjectScales = const {},
    Map<String, Map<String, Object?>> predictions = const {},
    Object? bands,
    DateTime? today}) {
  final school = detectSchoolScale(grades);
  final names = grades.keys.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return [
    for (final name in names)
      () {
        var pref = subjectScales[name];
        if (!scales.contains(pref)) {
          pref = scales.contains(scalePref) ? scalePref : 'auto';
        }
        return summarize(name, grades[name],
            scalePref: pref!,
            fallback: school,
            ops: predictions[name],
            bands: bands,
            today: today);
      }(),
  ];
}

/// True when `text` is a mark the predictor can count — stricter than
/// `parseRaw`: a typed percentage above 100 or points above the
/// maximum are refused. Like `grades.valid_mark_text`.
bool validMarkText(Object? text) {
  final raw = '${text ?? ''}'.trim();
  if (parseRaw(raw) == null) return false;
  var m = _pointsRe.firstMatch(raw);
  if (m != null) return _num(m.group(1)!) <= _num(m.group(2)!);
  m = _percentRe.firstMatch(raw);
  if (m != null) return _num(m.group(1)!) <= 100;
  if (_numberRe.hasMatch(raw)) return _num(raw) <= 100;
  return true;
}

/// The subject's most common real weight (ties → the higher one) —
/// like `grades.default_weight`.
double defaultWeight(SubjectSummary summary) {
  final counts = <double, int>{};
  for (final r in summary.rows) {
    if (r.state == 'real' || r.state == 'edited') {
      counts[r.weight] = (counts[r.weight] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) return 1.0;
  var best = counts.keys.first;
  for (final w in counts.keys) {
    if (counts[w]! > counts[best]! ||
        (counts[w] == counts[best] && w > best)) {
      best = w;
    }
  }
  return best;
}

/// `2.5` for a weight — like `grades.format_weight` (`f"{weight:g}"`).
String formatWeight(num weight) => gFormat(weight);

/// What the next mark must be to finish with `target` —
/// like `grades.Needed`.
class Needed {
  /// `any | need | impossible`.
  final String status;
  final double? value;

  /// Best marks of that weight that would do (0 = unreachable).
  final int count;
  const Needed(this.status, [this.value, this.count = 0]);
}

/// Worst next mark (of `weight`) that still ends on final `target` —
/// like `grades.needed_for`.
Needed neededFor(List<MarkRow> rows, String scale, int target,
    double weight, [Object? bands]) {
  final normalized = normalizeBands(bands);
  final w = weight <= 0 ? 0.01 : weight.toDouble();
  var total = 0.0;
  var wsum = 0.0;
  for (final r in rows) {
    if (!r.counts) continue;
    total += r.value! * r.weight;
    wsum += r.weight;
  }

  bool ok(double avg) =>
      (finalGrade(avg, scale, normalized) ?? 5) <= target;

  if (scale == 'percent') {
    // Even 0 % keeps the target.
    if (wsum + w > 0 && ok(total / (wsum + w))) {
      return const Needed('any');
    }
    final lower = target < 5 ? normalized[target - 1] : 0.0;
    final start = ((lower * (wsum + w) - total) / w).toInt();
    for (var pct = start < 0 ? 0 : start; pct <= 100; pct++) {
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
  }
  final acceptable = [
    for (final g in gradeSteps)
      if (ok((total + g * w) / (wsum + w))) g
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
