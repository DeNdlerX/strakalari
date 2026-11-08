// School calendar presets (read-only, shipped with the app) + user overrides.
//
// Port of strakalari/core/school_presets.py. Ownership split (deliberate):
// - Preset days/closures live HERE in code. Editing them in a release
//   updates every user on `school_preset_id` automatically.
// - User data lives in config: `user_free_days` (additions),
//   `forced_school_days` (exceptions re-enabling a preset day),
//   `sem1_close`/`sem2_close` (prefilled once, then user-owned).
//
// Effective calendar = (preset days + user additions) - forced school days.
// Entries accept plain `DD.MM.RRRR` strings, [DateTime] objects,
// `{"date": ..., "label": ...}` maps and `"DD.MM.RRRR|label"` strings —
// old `holidays` lists keep parsing.
//
// Local mirrors (canonical ports land in phase 3; these stay identical):
// [bandsValid] and [normalizeBands] mirror `grades.py`; [isValidCutoffTime]
// and [normalizeCutoffTime] mirror `lunch_cutoff.py`.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models.dart';
import '../storage/helpers.dart';
import '../lunches/lunch_cutoff.dart'
    show isValidCutoffTime, normalizeCutoffTime;
import 'grades.dart' show bandsValid, defaultBands, normalizeBands;

const int presetVersion = 1;

const Map<String, Object> gekom20262027 = {
  'id': 'gekom_2026_2027',
  'school': 'GEKOM',
  'year': '2026/2027',
  'title_cs': 'GEKOM 2026/2027',
  'title_en': 'GEKOM 2026/2027',
  'version': 1,
  // Absence/marks closure dates (final year ends sooner).
  'sem1_close': '25.01.2027',
  'sem2_close': '26.04.2027',
  // Lunch ordering cutoff (Strava): orders close at this time on the
  // previous business day (Mon–Fri minus free days).
  'lunch_cutoff_time': '12:00',
  // Percent -> grade conversion ("Tabulka převodu hodnocení" in
  // Bakaláři): the top of grades 2–5; each value is already the worse
  // grade. GEKOM: 1 = 100–87, 2 = 87–72, 3 = 72–55, 4 = 55–40, 5 = 40–0
  // (87 % is a 2, 40 % a 5).
  'marks_percent_bands': [87.0, 72.0, 55.0, 40.0],
  // Vacation ranges (inclusive, DD.MM.RRRR). The preset deliberately ends
  // at the absence closure (sem2_close): summer holidays are not part
  // of the school year the planner works with.
  'ranges': [
    ['28.10.2026', '30.10.2026', 'Podzimní prázdniny'],
    ['23.12.2026', '03.01.2027', 'Vánoční prázdniny'],
    ['22.02.2027', '26.02.2027', 'Jarní prázdniny'],
    ['25.03.2027', '29.03.2027', 'Velikonoční prázdniny'],
  ],
  // Single days outside the ranges above.
  'days': [
    ['28.09.2026', 'Státní svátek'],
    ['16.11.2026', 'Ředitelské volno'],
    ['17.11.2026', 'Státní svátek'],
    ['29.01.2027', 'Pololetní prázdniny'],
    ['10.02.2027', 'Ředitelské volno'],
  ],
};

/// Presets shipped with the app. To add a school, add a map shaped like
/// [gekom20262027] here (and a test), or — without touching the code —
/// drop a JSON file of the same shape into `school_presets/` in the
/// data dir (see docs/SCHOOL_PRESETS.md).
final Map<String, Map<String, Object?>> presets = {
  gekom20262027['id'] as String: gekom20262027,
};

const String customId = 'custom';

/// Folder (in the data dir) scanned for user-supplied `*.json` presets.
const String userPresetDir = './school_presets';

/// Default when a preset sets no lunch cutoff and the user entered none.
const String defaultLunchCutoff = '12:00';

// -- grade bands (canonical: grades.dart, like school_presets.py's lazy -----
// `from .grades import bands_valid`) ------------------------------------------

// -- lunch cutoff (canonical: lunch_cutoff.dart, like --------------------------
// school_presets.py's `from .lunch_cutoff import is_valid_cutoff_time`) --------

// -- validation ------------------------------------------------------------------

/// Python `repr()` rendering for validation messages: strings are
/// single-quoted (like `{entry!r}` in `validate_preset`), so a bad entry
/// reads `['bad', 'label']` instead of Dart's `[bad, label]`.
String _pyRepr(Object? value) {
  if (value is String) {
    return "'${value.replaceAll('\\', '\\\\').replaceAll("'", "\\'")}'";
  }
  if (value is bool) return value ? 'True' : 'False';
  if (value is List) return '[${value.map(_pyRepr).join(', ')}]';
  if (value is Map) {
    return '{${value.entries.map((e) => '${_pyRepr(e.key)}: ${_pyRepr(e.value)}').join(', ')}}';
  }
  return '$value';
}

/// Problems of a preset map (empty = usable).
List<String> validatePreset(Object? data) {
  final problems = <String>[];
  if (data is! Map) return ['preset must be a JSON object'];
  final pid = '${data['id'] ?? ''}';
  if (pid.isEmpty ||
      pid == customId ||
      !RegExp(r'^[\p{L}\p{N}_-]+$', unicode: true).hasMatch(pid)) {
    problems.add('\'id\' must be letters, digits, \'_\' or \'-\' (and not \'custom\')');
  }
  if ('${data['title_cs'] ?? data['title_en'] ?? ''}'.trim().isEmpty) {
    problems.add('\'title_cs\' or \'title_en\' is required');
  }
  for (final key in ['sem1_close', 'sem2_close']) {
    final raw = data[key];
    if (raw != null &&
        '$raw'.isNotEmpty &&
        parseCzDate(raw) == null) {
      problems.add('\'$key\' must be DD.MM.YYYY');
    }
  }
  final cutoff = '${data['lunch_cutoff_time'] ?? ''}'.trim();
  if (cutoff.isNotEmpty && !isValidCutoffTime(cutoff)) {
    problems.add('\'lunch_cutoff_time\' must be HH:MM');
  }
  final bands = data['marks_percent_bands'];
  if (bands != null && !(bands is List && bands.isEmpty)) {
    if (!bandsValid(bands)) {
      problems.add('\'marks_percent_bands\' must be four decreasing percentages '
          'within (0, 100] (the top of grades 2–5)');
    }
  }
  final days = data['days'];
  if (days is List) {
    for (final entry in days) {
      if (entry is! List ||
          entry.length != 2 ||
          parseCzDate(entry[0]) == null) {
        problems.add('bad \'days\' entry ${_pyRepr(entry)} '
            '(want ["DD.MM.YYYY", "label"])');
        break;
      }
    }
  }
  final ranges = data['ranges'];
  if (ranges is List) {
    for (final entry in ranges) {
      if (entry is! List ||
          entry.length != 3 ||
          parseCzDate(entry[0]) == null ||
          parseCzDate(entry[1]) == null) {
        problems.add('bad \'ranges\' entry ${_pyRepr(entry)} '
            '(want ["DD.MM.YYYY", "DD.MM.YYYY", "label"])');
        break;
      }
    }
  }
  return problems;
}

// -- user files ------------------------------------------------------------------

/// Valid presets from `school_presets/*.json`; bad files are reported, not fatal.
Map<String, Map<String, Object?>> _userPresets() {
  final folder = resolvePath(userPresetDir);
  final out = <String, Map<String, Object?>>{};
  List<String> names;
  try {
    names = Directory(folder)
        .listSync()
        .where((e) => e is File && p.basename(e.path).toLowerCase().endsWith('.json'))
        .map((e) => p.basename(e.path))
        .toList()
      ..sort();
  } on FileSystemException {
    return out;
  }
  for (final name in names) {
    final path = p.join(folder, name);
    Object? data;
    try {
      var text = File(path).readAsStringSync();
      if (text.startsWith('﻿')) text = text.substring(1);
      data = jsonDecode(text);
    } on FileSystemException catch (exc) {
      print('Warning: school preset $name ignored: $exc');
      continue;
    } on FormatException catch (exc) {
      print('Warning: school preset $name ignored: $exc');
      continue;
    }
    final problems = validatePreset(data);
    if (problems.isNotEmpty) {
      print('Warning: school preset $name ignored: ${problems.join('; ')}');
      continue;
    }
    final map = <String, Object?>{};
    for (final entry in (data as Map).entries) {
      map['${entry.key}'] = entry.value;
    }
    map['user_file'] = name;
    out['${map['id']}'] = map;
  }
  return out;
}

/// Shipped presets plus valid user files (a user file never replaces a shipped id).
Map<String, Map<String, Object?>> allPresets() {
  final merged = <String, Map<String, Object?>>{};
  for (final entry in _userPresets().entries) {
    merged[entry.key] = entry.value;
  }
  merged.addAll(presets);
  return merged;
}

String presetTitle(Map<String, Object?> preset, [String language = 'cs']) {
  final key = language == 'en' ? 'title_en' : 'title_cs';
  return '${preset[key] ?? preset['title_cs'] ?? preset['title_en'] ?? preset['id'] ?? '?'}';
}

/// `[(id, title)]` for pickers: presets by title, then `custom` last.
List<(String, String)> presetOptions([String language = 'cs']) {
  final items = allPresets().values.toList()
    ..sort((a, b) => presetTitle(a, language)
        .toLowerCase()
        .compareTo(presetTitle(b, language).toLowerCase()));
  return [for (final p in items) ('${p['id']}', presetTitle(p, language))];
}

Map<String, Object?>? getPreset(String? presetId) {
  if (presetId == null || presetId.isEmpty || presetId == customId) {
    return null;
  }
  final preset = presets[presetId];
  if (preset != null) return preset;
  return _userPresets()[presetId];
}

// -- entries -----------------------------------------------------------------------

DateTime? _parse(Object? value) => parseCzDate(value);

/// (date, label) from any accepted entry shape.
(DateTime?, String) splitEntry(Object? entry) {
  if (entry is Map) {
    return (_parse(entry['date']), '${entry['label'] ?? ''}');
  }
  if (entry is String && entry.contains('|')) {
    final idx = entry.indexOf('|');
    return (
      _parse(entry.substring(0, idx).trim()),
      entry.substring(idx + 1).trim()
    );
  }
  return (_parse(entry), '');
}

/// {date: label} for user-shaped entry lists (first label wins).
Map<DateTime, String> expandEntries(Iterable<Object?>? entries) {
  final out = <DateTime, String>{};
  for (final entry in entries ?? const <Object?>[]) {
    final (day, label) = splitEntry(entry);
    if (day == null) continue;
    if (!out.containsKey(day)) {
      out[day] = label;
    } else if (out[day]!.isEmpty && label.isNotEmpty) {
      out[day] = label;
    }
  }
  return out;
}

/// {date: label} expanded from a preset (ranges inclusive).
Map<DateTime, String> presetDays(String? presetId) {
  final preset = getPreset(presetId);
  if (preset == null) return {};
  final out = <DateTime, String>{};
  final days = preset['days'];
  if (days is List) {
    for (final single in days) {
      if (single is! List || single.length != 2) continue;
      final day = _parse(single[0]);
      if (day != null && !out.containsKey(day)) {
        out[day] = '${single[1] ?? ''}';
      }
    }
  }
  final ranges = preset['ranges'];
  if (ranges is List) {
    for (final range in ranges) {
      if (range is! List || range.length != 3) continue;
      final start = _parse(range[0]);
      final end = _parse(range[1]);
      if (start == null || end == null || end.isBefore(start)) continue;
      // Constructor date arithmetic (not `+ Duration(days: 1)`, which
      // drifts across DST): mirrors `date + timedelta`.
      var cursor = start;
      while (!cursor.isAfter(end)) {
        if (!out.containsKey(cursor)) out[cursor] = '${range[2] ?? ''}';
        cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
      }
    }
  }
  return out;
}

/// (sem1_close, sem2_close) strings from the preset, else ('','').
(String, String) presetCloses(String? presetId) {
  final preset = getPreset(presetId);
  if (preset == null) return ('', '');
  return ('${preset['sem1_close'] ?? ''}', '${preset['sem2_close'] ?? ''}');
}

/// Lunch ordering cutoff `HH:MM` from the preset, else ''.
String presetLunchCutoff(String? presetId) {
  final preset = getPreset(presetId);
  if (preset == null) return '';
  final raw = '${preset['lunch_cutoff_time'] ?? ''}'.trim();
  if (raw.isEmpty) return '';
  return normalizeCutoffTime(raw);
}

/// Percent -> grade bands from the preset, else null.
List<double>? presetMarksBands(String? presetId) {
  final preset = getPreset(presetId);
  if (preset == null || !bandsValid(preset['marks_percent_bands'])) {
    return null;
  }
  return normalizeBands(preset['marks_percent_bands']);
}

/// (bands, source): the user's own bands, then the preset's, else the
/// built-in default. `source` is `user` / `preset` / `default`.
({List<double> bands, String source}) resolveMarksBands(
    Map<String, Object?>? configData) {
  configData ??= const {};
  final user = configData['marks_percent_bands'];
  if (bandsValid(user)) return (bands: normalizeBands(user), source: 'user');
  final preset = presetMarksBands('${configData['school_preset_id'] ?? ''}');
  if (preset != null) return (bands: preset, source: 'preset');
  return (bands: List<double>.of(defaultBands), source: 'default');
}

/// Resolved lunch cutoff `HH:MM`: user override, then preset, else 12:00.
String resolveLunchCutoff(Map<String, Object?>? configData) {
  configData ??= const {};
  final user = '${configData['lunch_order_cutoff_time'] ?? ''}'.trim();
  if (user.isNotEmpty && isValidCutoffTime(user)) {
    return normalizeCutoffTime(user);
  }
  final preset =
      presetLunchCutoff('${configData['school_preset_id'] ?? ''}');
  if (preset.isNotEmpty) return preset;
  return defaultLunchCutoff;
}

/// Effective free-day set with labels + source counts.
///
/// Returns (dates, labels, info) where info carries
/// `preset_days` / `user_added` / `forced_school` counts and the
/// `preset_id` used. Legacy `holidays` entries count as user additions
/// so pre-migration configs keep working when read directly.
///
/// Days after the final sem2 absence closure (user value, else preset)
/// are excluded — even preset days — so the calendar never shows free
/// days past the end of the school year the planner works with.
/// Stored data is untouched; only the returned view is cut off.
/// [clip]=false skips that cut: lunch deadlines run past the closure
/// (May, June) and must still skip the user's days off there.
({Set<DateTime> dates, Map<DateTime, String> labels, Map<String, Object?> info})
    effectiveCalendar(Map<String, Object?>? configData, {bool clip = true}) {
  configData ??= const {};
  final presetId = '${configData['school_preset_id'] ?? ''}';
  final presetMap = presetDays(presetId);
  final userMap = expandEntries(
      (configData['user_free_days'] as List?)?.cast<Object?>());
  for (final entry in expandEntries(
      (configData['holidays'] as List?)?.cast<Object?>()).entries) {
    userMap.putIfAbsent(entry.key, () => entry.value);
  }
  final forced = expandEntries(
          (configData['forced_school_days'] as List?)?.cast<Object?>())
      .keys
      .toSet();

  var dates = (presetMap.keys.toSet()..addAll(userMap.keys))
      .difference(forced);
  final labels = <DateTime, String>{
    for (final d in presetMap.keys)
      if (dates.contains(d)) d: presetMap[d] ?? ''
  };
  for (final entry in userMap.entries) {
    if (dates.contains(entry.key) &&
        (labels[entry.key] ?? '').isEmpty &&
        entry.value.isNotEmpty) {
      labels[entry.key] = entry.value;
    }
  }
  final end = clip ? _parse(resolveClose('sem2', configData)) : null;
  if (end != null) {
    dates = {for (final d in dates) if (!d.isAfter(end)) d};
    labels.removeWhere((d, _) => d.isAfter(end));
  }
  bool inScope(DateTime d) => end == null || !d.isAfter(end);
  final info = <String, Object?>{
    'preset_id': presetId,
    'preset_days': [
      for (final d in presetMap.keys)
        if (!forced.contains(d) && inScope(d)) d
    ].length,
    'user_added': [for (final d in userMap.keys) if (dates.contains(d)) d].length,
    'forced_school': [
      for (final d in forced)
        if ((presetMap.containsKey(d) || userMap.containsKey(d)) && inScope(d))
          d
    ].length,
  };
  return (dates: dates, labels: labels, info: info);
}

/// User close wins, then preset, else '' (auto semester bound).
String resolveClose(String which, Map<String, Object?>? configData) {
  configData ??= const {};
  final key = which == 'sem1' ? 'sem1_close' : 'sem2_close';
  final user = '${configData[key] ?? ''}'.trim();
  if (user.isNotEmpty && _parse(user) != null) return user;
  final preset = getPreset('${configData['school_preset_id'] ?? ''}');
  if (preset != null) {
    final close =
        '${preset[which == 'sem1' ? 'sem1_close' : 'sem2_close'] ?? ''}';
    if (close.isNotEmpty && _parse(close) != null) return close;
  }
  return '';
}

/// Drops forced-school entries matching neither preset nor user days.
///
/// Returns true when anything was removed (caller persists).
bool pruneOrphanForced(Map<String, Object?> configData) {
  final forced = configData['forced_school_days'];
  if (forced is! List || forced.isEmpty) return false;
  final presetMap = presetDays('${configData['school_preset_id'] ?? ''}');
  final userMap = expandEntries(
      (configData['user_free_days'] as List?)?.cast<Object?>());
  for (final entry in expandEntries(
      (configData['holidays'] as List?)?.cast<Object?>()).entries) {
    userMap.putIfAbsent(entry.key, () => entry.value);
  }
  final known = presetMap.keys.toSet()..addAll(userMap.keys);
  final kept = [
    for (final e in forced)
      if (known.contains(splitEntry(e).$1)) e
  ];
  if (kept.length != forced.length) {
    configData['forced_school_days'] = kept;
    return true;
  }
  return false;
}
