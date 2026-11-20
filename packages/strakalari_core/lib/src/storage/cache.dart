// The on-disk data cache (timetable, absences, marks, menu).
//
// Port of strakalari/core/cache.py. The cache file keeps the same name,
// version and JSON shape as the Python app so an update installs over it
// with no migration step.
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

import '../i18n.dart';
import '../models.dart';
import 'helpers.dart';

/// Cache file name, resolved against the user data dir (mirrors
/// `CACHE_FILE = './data_cache.json'`).
const String cacheFile = './data_cache.json';

/// Cache schema version (mismatched files are ignored, not migrated).
const int cacheVersion = 2;

/// Data-cache key: parsed sent-excuse entries keyed by Komens message key
/// (`id` or `id|sortDate`), so routine refreshes skip `GetMessageDataAsync`
/// for messages already read.
const String outboxDetailsKey = 'komens_outbox_details';

/// Parses a `last_updated` stamp; null when missing or unparsable.
///
/// Accepts the same shapes Python does: `DD.MM.YYYY HH:MM:SS`,
/// `YYYY-MM-DDTHH:MM:SS`, `YYYY-MM-DD HH:MM:SS`, and anything
/// [DateTime.tryParse] reads (the `fromisoformat` fallback).
DateTime? _parseTs(Object? value) {
  if (value == null) return null;
  final text = '$value'.trim();
  if (text.isEmpty) return null;
  return _parseDmyHms(text) ??
      _parseIsoTHms(text) ??
      _parseIsoSpaceHms(text) ??
      DateTime.tryParse(text);
}

DateTime? _checkedTimestamp(
    int year, int month, int day, int hour, int minute, int second) {
  if (month < 1 || month > 12 || day < 1) return null;
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
  if (second < 0 || second > 59) return null;
  final leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
  const lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  final maxDay = lengths[month - 1] + (month == 2 && leap ? 1 : 0);
  if (day > maxDay) return null;
  return DateTime(year, month, day, hour, minute, second);
}

DateTime? _parseDmyHms(String text) {
  final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4}) (\d{1,2}):(\d{2}):(\d{2})$')
      .firstMatch(text);
  if (m == null) return null;
  return _checkedTimestamp(
      int.parse(m.group(3)!),
      int.parse(m.group(2)!),
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!));
}

DateTime? _parseIsoTHms(String text) {
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})T(\d{1,2}):(\d{2}):(\d{2})$')
      .firstMatch(text);
  if (m == null) return null;
  return _checkedTimestamp(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!));
}

DateTime? _parseIsoSpaceHms(String text) {
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2}) (\d{1,2}):(\d{2}):(\d{2})$')
      .firstMatch(text);
  if (m == null) return null;
  return _checkedTimestamp(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!));
}

/// The on-disk cache; [strict] raises when the file is busy.
///
/// Only undecodable content is quarantined — a merely locked file must
/// survive untouched.
Map<String, Object?> _readCache({bool strict = false}) {
  final path = resolvePath(cacheFile);
  if (!File(path).existsSync()) return <String, Object?>{};
  try {
    final decoded =
        jsonDecode(File(path).readAsStringSync(encoding: utf8));
    if (decoded is! Map) return <String, Object?>{};
    final data = decoded.map((k, v) => MapEntry('$k', v as Object?));
    if (data.containsKey('_cache_version') &&
        data['_cache_version'] != cacheVersion) {
      print('Warning: ignoring data cache with version '
          '${data['_cache_version']} (expected $cacheVersion).');
      return <String, Object?>{};
    }
    return data;
  } on FormatException catch (e) {
    final backup = quarantineCorruptFile(path);
    final hint = backup.isNotEmpty ? ' Preserved at $backup.' : '';
    print('Warning: Could not read data cache: $e.$hint Starting fresh.');
    return <String, Object?>{};
  } on FileSystemException catch (e) {
    if (strict) rethrow;
    print('Warning: Could not read data cache right now: $e.');
    return <String, Object?>{};
  }
}

/// Reads the on-disk data cache (empty map when missing/unreadable).
Map<String, Object?> loadDataCache() => _readCache(strict: false);

String _stampNow() {
  final now = clock.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(now.day)}.${two(now.month)}.${now.year} '
      '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
}

/// Merges [data] into the on-disk cache (default) or replaces it entirely
/// when [replace] is true. A busy cache file is left untouched: merging
/// against an unreadable file would drop every other key.
Map<String, Object?> saveDataCache(Map<String, Object?>? data,
    {bool replace = false}) {
  final path = resolvePath(cacheFile);
  late Map<String, Object?> current;
  try {
    current = replace ? <String, Object?>{} : _readCache(strict: true);
  } on FileSystemException catch (e) {
    print('Warning: Could not save data cache: $e — disk cache unchanged.');
    return Map<String, Object?>.of(data ?? <String, Object?>{});
  }
  current.addAll(data ?? <String, Object?>{});
  current['_cache_version'] = cacheVersion;
  if (!current.containsKey('last_updated') ||
      ((data ?? <String, Object?>{}).containsKey('last_updated'))) {
    current['last_updated'] = (data ?? <String, Object?>{})['last_updated'] ??
        current['last_updated'] ??
        _stampNow();
  }
  try {
    atomicWriteJson(path, current);
  } on Object catch (e) {
    print('Warning: Could not save data cache: $e — '
        'in-memory data kept, disk cache unchanged.');
  }
  return current;
}

/// Day-granular merge of timetables for full-refresh saves.
///
/// A week that fails to render (slow link, session hiccup) contributes
/// no days to the fresh scrape — a blind full replace would then delete
/// previously scraped days and with them pending excuse tasks, so an
/// unsent lesson vanishes from pending as if excused. Unscraped days
/// therefore survive: fresh days win (including present-but-empty),
/// days missing from fresh are kept, and parseable days older than
/// [windowStart] are pruned so stale semester data still drops.
/// Unparseable keys are always kept, never dropped on ambiguity.
Map<String, Object?> mergeTimetableDays(
    Map<String, Object?>? old, Map<String, Object?>? fresh,
    {DateTime? windowStart}) {
  final merged = Map<String, Object?>.of(old ?? <String, Object?>{});
  for (final entry in (fresh ?? <String, Object?>{}).entries) {
    merged[entry.key] = entry.value;
  }
  if (windowStart == null) return merged;
  final freshKeys = (fresh ?? <String, Object?>{}).keys.toSet();
  for (final key in merged.keys.toList()) {
    if (freshKeys.contains(key)) continue;
    final day = parseCzDate(key);
    if (day != null && day.isBefore(windowStart)) {
      merged.remove(key);
    }
  }
  return merged;
}

/// Age of the cache based on its `last_updated` stamp (null = unknown).
Duration? cacheAge([Map<String, Object?>? cache]) {
  final data = cache ?? loadDataCache();
  final ts = _parseTs(data['last_updated']);
  if (ts == null) return null;
  return clock.now().difference(ts);
}

/// Parsed `last_updated` stamp of the data cache (null when unknown).
DateTime? lastUpdatedTime([Map<String, Object?>? cache]) {
  final data = cache ?? loadDataCache();
  return _parseTs(data['last_updated']);
}

/// Scheduler seed: when the cached data was last refreshed.
///
/// Returns null when the stamp is missing, unparsable, or in the future
/// (clock skew / bogus stamp) — callers then refresh on start, exactly
/// like before. Only positive evidence of fresh data defers the run.
DateTime? startupSeed([Map<String, Object?>? cache, DateTime? now]) {
  late final DateTime? seed;
  try {
    seed = lastUpdatedTime(cache);
  } on Object {
    return null;
  }
  if (seed == null) return null;
  try {
    if (seed.isAfter(now ?? clock.now())) return null;
  } on Object {
    return null;
  }
  return seed;
}

/// True when the cache is missing, unparsable, or older than [ttlHours].
bool isCacheStale([Map<String, Object?>? cache, num ttlHours = 24]) {
  final data = cache ?? loadDataCache();
  if (data.isEmpty) return true;
  final age = cacheAge(data);
  if (age == null) return true;
  try {
    return age >
        Duration(microseconds: (ttlHours * 3600 * 1000000).round());
  } on UnsupportedError {
    return age > const Duration(hours: 24);
  }
}

/// Short human label for the UI header, e.g. 'Aktualizováno: … (zastaralé)'.
String describeCache([Map<String, Object?>? cache, num ttlHours = 24]) {
  final data = cache ?? loadDataCache();
  final lastValue = data['last_updated'];
  final last = lastValue?.toString().isNotEmpty == true
      ? '${data['last_updated']}'
      : '—';
  final age = cacheAge(data);
  if (age == null) return last;
  final hours = age.inMicroseconds / 3600000000;
  late final String ageS;
  if (hours < 1) {
    final mins = age.inSeconds ~/ 60;
    ageS = mins >= 1 ? t('cache_age_min', args: {'n': mins}) : t('cache_age_now');
  } else if (hours < 48) {
    ageS = t('cache_age_hours', args: {'n': hours.toStringAsFixed(1)});
  } else {
    ageS = t('cache_age_days', args: {'n': hours ~/ 24});
  }
  final stale = isCacheStale(data, ttlHours) ? " (${t('cache_stale')})" : '';
  return '$last · $ageS$stale';
}
