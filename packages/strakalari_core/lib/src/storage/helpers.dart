// Shared helpers: data dir, paths, atomic writes, locks, log redaction,
// date/room/teacher parsing, excuse templates, Fernet password codec.
//
// Port of strakalari/core/helpers.py. `secret_store.dart` is imported for
// the password codec (and imports this file for the lock) — the same
// mutual dependency Python resolves with lazy imports.
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;

import '../platform/packaging.dart';
import 'fernet.dart';
import 'secret_store.dart';

/// Repository root, or the executable's directory when installed.
final String projectRoot = File(Platform.resolvedExecutable).parent.path;

/// Legacy XOR key: only ever used to read passwords stored by old versions.
const String legacyEncryptionKey = '4f88a3b32e010dd296cb6aa3b3c';

/// Tests may replace the Fernet factory (mirrors monkeypatching
/// `_get_fernet`); production always uses [_createFernet].
Fernet Function() fernetFactory = _createFernet;

Fernet _createFernet() => Fernet.fromKeyBytes(getKey(getUserDataDir()));

Fernet _getFernet() => fernetFactory();

/// Returns a writable user data directory depending on platform and
/// installation mode. `STRAKALARI_DATA_DIR` overrides everything.
String getUserDataDir() {
  final override = (getenv('STRAKALARI_DATA_DIR') ?? '').trim();
  if (override.isNotEmpty) {
    Directory(override).createSync(recursive: true);
    return override;
  }
  if (isMobile()) return _mobileDataDir();
  if (Platform.isMacOS) return _macosAppDataDir();
  if (isStorePackage()) return _storeAppDataDir();
  final root = _installDir();
  if (Directory(root).existsSync()) {
    // Installed classic builds keep data next to the executable when
    // that folder is writable (mirrors the `os.access(root, W_OK)` gate).
    try {
      final probe = File(
          '$root${Platform.pathSeparator}.writable-$pid');
      probe.createSync(exclusive: true);
      probe.deleteSync();
      return root;
    } on FileSystemException {
      // Fall through to the per-user dir.
    }
  }
  return _platformDataDir();
}

String _installDir() => projectRoot;

/// The per-user data dir of an installed app, created.
String _platformDataDir() {
  late final String dataDir;
  if (Platform.isWindows) {
    final appData = getenvNonEmpty('LOCALAPPDATA') ??
        getenvNonEmpty('APPDATA') ??
        _homeDir();
    dataDir = p.join(appData, 'Strakalari');
  } else if (Platform.isMacOS) {
    dataDir = p.join(_homeDir(), 'Library', 'Application Support', 'Strakalari');
  } else {
    final configHome =
        getenvNonEmpty('XDG_CONFIG_HOME') ?? p.join(_homeDir(), '.config');
    dataDir = p.join(configHome, 'strakalari');
  }
  Directory(dataDir).createSync(recursive: true);
  return dataDir;
}

String _homeDir() {
  if (Platform.isWindows) {
    return getenvNonEmpty('USERPROFILE') ?? p.current;
  }
  return getenvNonEmpty('HOME') ?? p.current;
}

/// The phone app's private storage, created.
///
/// The app registers its support directory via [setMobileDataDir] (Flutter
/// has no `FLET_APP_STORAGE_DATA`); the fallback below is only for a host
/// that did not set it.
String? _mobileDataDirOverride;

/// Registers the phone's private data dir (called by the app at startup
/// from `getApplicationSupportDirectory()/data`).
void setMobileDataDir(String? dir) {
  _mobileDataDirOverride = dir;
}

String _mobileDataDir() {
  final dataDir = getenvNonEmpty('FLET_APP_STORAGE_DATA') ??
      _mobileDataDirOverride ??
      p.join(_homeDir(), 'strakalari');
  Directory(dataDir).createSync(recursive: true);
  return dataDir;
}

/// Store data dirs whose first-run migration was already attempted.
final Set<String> _storeDataDirs = {};

/// `%LOCALAPPDATA%\Strakalari` for the Store (MSIX) build.
String _storeAppDataDir() {
  final target = _platformDataDir();
  if (_storeDataDirs.contains(target)) return target;
  final legacy = legacyDesktopDataDir();
  if (legacy != null &&
      _needsBundleMigration(legacy, target) &&
      !_migrateBundleData(legacy, target)) {
    print('Warning: could not copy the data of the classic install '
        '($legacy); starting with empty settings.');
  }
  _storeDataDirs.add(target);
  return target;
}

/// Resolved macOS data dir per (bundle dir, target dir), fixed for the
/// process lifetime: every caller must agree on one location.
final Map<String, String> _macosDataDirs = {};

/// User files older builds wrote next to the executable, inside the .app
/// bundle. config.json is not listed: it is copied last and marks a
/// finished move. secret.key is carried by secret_store.carry_key.
const List<String> _bundleDataItemNames = [
  'config.json.bak',
  'data_cache.json',
  'already_excused_lessons.json',
  'already_excused_lessons.unconfirmed.json',
  'strava_blacklist.json',
  'automation_history.jsonl',
  'update_cache.json',
  'log.txt',
  'school_presets',
];

/// `~/Library/Application Support/Strakalari` for the installed macOS app.
String _macosAppDataDir() {
  final bundle = _installDir();
  final target = _platformDataDir();
  final cacheKey = '$bundle\x00$target';
  final cached = _macosDataDirs[cacheKey];
  if (cached != null) return cached;
  var chosen = target;
  if (_needsBundleMigration(bundle, target) &&
      !_migrateBundleData(bundle, target)) {
    print('Warning: could not move the data out of the app bundle '
        '($bundle); using it for now, retrying on the next launch.');
    chosen = bundle;
  }
  _macosDataDirs[cacheKey] = chosen;
  return chosen;
}

bool _needsBundleMigration(String bundle, String target) {
  if (p.equals(p.absolute(bundle), p.absolute(target))) return false;
  return File(p.join(bundle, 'config.json')).existsSync() &&
      !File(p.join(target, 'config.json')).existsSync();
}

List<String> _bundleDataItems(String bundle) {
  final items = List<String>.of(_bundleDataItemNames);
  Map<String, Object?> cfg = const {};
  try {
    final decoded =
        jsonDecode(File(p.join(bundle, 'config.json')).readAsStringSync());
    if (decoded is Map) cfg = decoded.cast<String, Object?>();
  } catch (_) {
    cfg = const {};
  }
  for (final key in ['strava_blacklist', 'already_excused_file', 'log_file']) {
    final value = cfg[key];
    if (value is! String || value.trim().isEmpty || p.isAbsolute(value)) {
      continue;
    }
    final rel = p.normalize(value);
    if (rel == '..' || rel.startsWith('..${Platform.pathSeparator}')) {
      continue; // Outside the bundle dir.
    }
    if (!items.contains(rel)) items.add(rel);
  }
  return items;
}

/// Copies `src` (file or dir) to `dst` unless `dst` exists; atomic rename.
void _copyMissing(String src, String dst) {
  if (!FileSystemEntity.isFileSync(src) &&
      !FileSystemEntity.isDirectorySync(src)) {
    return;
  }
  if (FileSystemEntity.isFileSync(dst) ||
      FileSystemEntity.isDirectorySync(dst)) {
    return;
  }
  Directory(p.dirname(dst)).createSync(recursive: true);
  final tmp = '$dst.migrating-$pid';
  try {
    if (FileSystemEntity.isDirectorySync(src)) {
      _copyDir(src, tmp);
    } else {
      File(src).copySync(tmp);
    }
    File(tmp).renameSync(dst);
  } finally {
    if (FileSystemEntity.isDirectorySync(tmp)) {
      Directory(tmp).deleteSync(recursive: true);
    } else if (FileSystemEntity.isFileSync(tmp)) {
      File(tmp).deleteSync();
    }
  }
}

void _copyDir(String src, String dst) {
  Directory(dst).createSync(recursive: true);
  for (final entity in Directory(src).listSync(recursive: false)) {
    final name = p.basename(entity.path);
    if (entity is Directory) {
      _copyDir(entity.path, p.join(dst, name));
    } else if (entity is File) {
      entity.copySync(p.join(dst, name));
    }
  }
}

/// Copies the user data from `bundle` to `target`. True when done.
bool _migrateBundleData(String bundle, String target) {
  final lock = InterProcessLock(p.join(target, 'migrate.lock'));
  if (!lock.acquire(timeoutS: 30)) return false;
  try {
    if (!_needsBundleMigration(bundle, target)) return true;
    for (final rel in _bundleDataItems(bundle)) {
      _copyMissing(p.join(bundle, rel), p.join(target, rel));
    }
    if (!carryKey(bundle, target)) return false;
    _copyMissing(
        p.join(bundle, 'config.json'), p.join(target, 'config.json'));
    return true;
  } catch (e) {
    print('Warning: copying the data from $bundle failed '
        '(${e.runtimeType}: $e).');
    return false;
  } finally {
    lock.release();
  }
}

/// Resolves relative file paths against [baseDir], the user data dir, or
/// the project root.
String resolvePath(String? path, [String? baseDir]) {
  if (path == null || path.isEmpty) return path ?? '';
  if (p.isAbsolute(path)) return path;
  final root = baseDir ?? getUserDataDir();
  return p.normalize(p.join(root, path));
}

/// Renames an unreadable JSON file aside so its bytes survive debugging.
///
/// Returns the backup path, or "" when there was nothing to preserve
/// (missing file) or the rename itself failed. Never raises.
String quarantineCorruptFile(String? path) {
  try {
    if (path == null ||
        path.isEmpty ||
        !File(path).existsSync()) {
      return '';
    }
    final now = clock.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final backup = '$path.corrupt-$stamp';
    File(path).renameSync(backup);
    return backup;
  } catch (_) {
    return '';
  }
}

/// Returns the sibling `.example.json` template path.
String examplePathFor(String path) {
  if (path.endsWith('.json')) {
    return '${path.substring(0, path.length - 5)}.example.json';
  }
  return '$path.example.json';
}

/// Best-effort inter-process lock (returns an opaque token or null).
String? tryFileLock(String lockPath, {double staleAfterS = 120}) {
  try {
    Directory(p.dirname(p.absolute(lockPath)))
        .createSync(recursive: true);
    try {
      if (File(lockPath).existsSync()) {
        final age = DateTime.now().difference(
            File(lockPath).lastModifiedSync());
        if (age.inMicroseconds < (staleAfterS * 1e6).round()) return null;
        try {
          File(lockPath).deleteSync();
        } on FileSystemException {
          return null;
        }
      }
    } on FileSystemException {
      // Fall through and attempt creation anyway.
    }
    File(lockPath).createSync(exclusive: true);
    try {
      File(lockPath).writeAsStringSync('$pid', mode: FileMode.write);
    } finally {
      // Creation holds the lock; a partial write is harmless.
    }
    return lockPath;
  } on FileSystemException {
    return null;
  } on ArgumentError {
    return null;
  }
}

/// Releases a lock acquired with [tryFileLock].
void releaseFileLock(String? token) {
  if (token == null || token.isEmpty) return;
  try {
    File(token).deleteSync();
  } on FileSystemException {
    // Already gone.
  }
}

/// Exclusive OS-level lock on [path].
///
/// Unlike [tryFileLock], the OS drops the lock when the holder dies, so a
/// killed tray or window can never leave a stale lock behind.
class InterProcessLock {
  final String path;
  RandomAccessFile? _handle;

  InterProcessLock(this.path);

  bool _tryOnce() {
    Directory(p.dirname(p.absolute(path))).createSync(recursive: true);
    final handle = File(path).openSync(mode: FileMode.append);
    try {
      // Byte 0 overlaps Python's msvcrt.locking(0, LK_NBLCK, 1), so the
      // two apps exclude each other; on POSIX flock covers the file.
      handle.lockSync(FileLock.exclusive, 0, 1);
    } on FileSystemException {
      handle.closeSync();
      return false;
    }
    _handle = handle;
    return true;
  }

  /// True once held; False when still busy after [timeoutS].
  bool acquire({double timeoutS = 0}) {
    if (_handle != null) {
      throw StateError('lock $path is already held by this object');
    }
    final deadline =
        DateTime.now().add(Duration(microseconds: (timeoutS * 1e6).round()));
    while (true) {
      try {
        if (_tryOnce()) return true;
      } on FileSystemException {
        return false;
      }
      if (!DateTime.now().isBefore(deadline)) return false;
      sleep(const Duration(milliseconds: 250));
    }
  }

  void release() {
    final handle = _handle;
    _handle = null;
    if (handle == null) return;
    try {
      handle.unlockSync();
    } on FileSystemException {
      // Closing the handle releases it anyway.
    } finally {
      handle.closeSync();
    }
  }

  /// Whether this object currently holds the lock.
  bool get held => _handle != null;
}

/// One log line for an exception a scraper deliberately carries on after.
String describeSwallowed(String what, Object exc) {
  var first = '';
  try {
    final text = '$exc'.trim();
    if (text.isNotEmpty) {
      first = text.split('\n').first.substring(
          0, text.split('\n').first.length > 160 ? 160 : text.length);
    }
  } catch (_) {
    // The type alone still helps.
  }
  final detail = first.isEmpty ? '' : ': $first';
  return 'Debug: $what — ${exc.runtimeType}$detail';
}

/// Deep equality for JSON-shaped values (Dart maps compare by identity,
/// Python dicts by value). Used for history/timetable dedup and coverage.
bool jsonEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !jsonEquals(a[key], b[key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEquals(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  return a == b;
}

/// Writes JSON atomically (temp file + rename) so a crash or kill can
/// never leave a truncated file behind. Creates parent dirs as needed.
void atomicWriteJson(String path, Object? data,
    {Encoding encoding = utf8}) {
  Directory(p.dirname(p.absolute(path))).createSync(recursive: true);
  final tmpPath = '$path.$pid.tmp';
  try {
    File(tmpPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(data),
        encoding: encoding);
    _replaceFile(tmpPath, path);
  } catch (_) {
    try {
      File(tmpPath).deleteSync();
    } on FileSystemException {
      // Nothing to clean.
    }
    rethrow;
  }
}

void _replaceFile(String tmpPath, String path) {
  try {
    File(tmpPath).renameSync(path);
  } on FileSystemException {
    // Windows: rename does not replace an existing target.
    File(path).deleteSync();
    File(tmpPath).renameSync(path);
  }
}

/// Encrypts text using Fernet. [key] is ignored and kept for backward
/// compatibility.
String encrypt(String password, [String? key]) {
  if (password.isEmpty) return '';
  return _getFernet().encryptBytes(utf8.encode(password));
}

/// Decrypts text. Automatically falls back to legacy XOR if Fernet fails,
/// migrating it seamlessly.
///
/// NOTE: this returns the input unchanged when nothing can decode it —
/// callers that must distinguish failure (e.g. settings UI) should use
/// decryptStrict().
String decrypt(String? passwordHash, [String? key]) {
  if (passwordHash == null || passwordHash.isEmpty) return '';
  try {
    ascii.encode(passwordHash);
    return utf8.decode(_getFernet().decryptToken(passwordHash));
  } on InvalidTokenException {
    // Fall through to the legacy XOR cipher below.
  } on FormatException {
    // Non-ASCII input: undecodable as a token either.
  } on OSError {
    // secret.key file IO failed: try the legacy cipher then.
  }
  try {
    final encrypted = base64.decode(passwordHash);
    final legacyKey = key ?? legacyEncryptionKey;
    final keyBytes = utf8.encode(legacyKey);
    final plain = List<int>.generate(encrypted.length,
        (i) => encrypted[i] ^ keyBytes[i % keyBytes.length]);
    return utf8.decode(plain, allowMalformed: false);
  } catch (_) {
    return passwordHash;
  }
}

/// True when a `*_encrypted` config flag means ciphertext.
bool isEncryptedFlag(Object? value) {
  if (value == true) return true;
  try {
    return ['true', '1', 'yes'].contains('$value'.trim().toLowerCase());
  } catch (_) {
    return false;
  }
}

/// Like [decrypt], but returns null when the value cannot be decoded.
String? decryptStrict(String? passwordHash, [String? key]) {
  if (passwordHash == null || passwordHash.isEmpty) return '';
  try {
    ascii.encode(passwordHash);
    return utf8.decode(_getFernet().decryptToken(passwordHash));
  } catch (_) {
    // Try the legacy cipher below.
  }
  try {
    final encrypted = base64.decode(passwordHash);
    final legacyKey = key ?? legacyEncryptionKey;
    final keyBytes = utf8.encode(legacyKey);
    final plain = List<int>.generate(encrypted.length,
        (i) => encrypted[i] ^ keyBytes[i % keyBytes.length]);
    return utf8.decode(plain, allowMalformed: false);
  } catch (_) {
    return null;
  }
}

/// Parses date string into a naive local DateTime, supporting multiple
/// formats and prefix day names.
DateTime parseDate(Object? dateStr) {
  if (dateStr == null || '$dateStr'.isEmpty) {
    throw ArgumentError('Empty date string');
  }
  // Remove parenthesized days of week, e.g. " (úterý)", " (St)".
  var s = '$dateStr'.replaceAll(RegExp(r'\(.*?\)'), '').trim();
  // Normalize spaces around dots, e.g. "1. 9. 2026" -> "1.9.2026".
  s = s.replaceAll(RegExp(r'\s*\.\s*'), '.');
  // Search for a date pattern anywhere in the string to ignore leading
  // day names (e.g. "Pondělí 1.9.2026").
  final m = RegExp(
          r'(\d{1,2}\.\d{1,2}\.\d{4})|(\d{4}-\d{1,2}-\d{1,2})|(\d{1,2}/\d{1,2}/\d{4})')
      .firstMatch(s);
  final clean =
      m != null ? m.group(0)! : s.split(' ').first.split('T').first.trim();
  final parsed = _parseDmy(clean) ??
      _parseIso(clean) ??
      _parseSlashDmy(clean) ??
      _parseShortYear(clean) ??
      _parseIsoSlash(clean);
  if (parsed != null) return parsed;
  throw ArgumentError('Unable to parse date string: $dateStr');
}

/// Builds a validated local date (null when out of range, mirroring
/// `strptime`, which rejects overflows instead of rolling them over).
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

DateTime? _parseSlashDmy(String clean) {
  final m = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{4})$').firstMatch(clean);
  if (m == null) return null;
  return _checkedDate(
      int.parse(m.group(3)!), int.parse(m.group(2)!), int.parse(m.group(1)!));
}

DateTime? _parseShortYear(String clean) {
  final m = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{2})$').firstMatch(clean);
  if (m == null) return null;
  // strptime %y pivot: 69–99 → 19xx, otherwise 20xx.
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

/// Extracts integer lesson index from a time/lesson string.
int? extractLessonNum(Object? timeStr) {
  if (timeStr == null) return null;
  final text = '$timeStr';
  if (text.isEmpty) return null;
  final paren = RegExp(r'(\d+)\s*\(').firstMatch(text);
  if (paren != null) return int.parse(paren.group(1)!);
  // Bare leading number ("3") — but never a clock time ("8:00",
  // "13:40 - 14:25"): the lookahead rejects digits followed (after
  // optional digits/spaces) by a colon, so multi-digit hours can't
  // backtrack into a bogus period ("13:40" -> 1).
  final start =
      RegExp(r'^(\d+)(?![\d\s]*:)').firstMatch(text.trim());
  return start != null ? int.parse(start.group(1)!) : null;
}

/// Strips the leading period number from both time formats.
///
/// Demo: `1. 8:00 - 8:45` -> `8:00 - 8:45`.
/// Real cache: `3 (10:05 - 10:50)` -> `10:05 - 10:50`.
String shortTime(Object? raw) {
  final text = '${raw ?? ''}'.trim();
  final m = RegExp(r'^\s*\d+\s*\((.*)\)\s*$').firstMatch(text);
  if (m != null) return m.group(1)!.trim();
  return text.replaceFirst(RegExp(r'^\s*\d+\.\s*'), '').trim();
}

/// `'Mgr. Jana Tláskalová'` -> `'Tláskalová'` (titles stripped).
String teacherSurname(Object? fullName) {
  final tokens = '$fullName'
      .split(RegExp(r'\s+'))
      .map((t) => t.trim().replaceAll(RegExp(r',+$'), ''))
      .where((t) => t.isNotEmpty)
      .toList();
  const suffixes = {
    'ph.d.', 'phd', 'csc.', 'csc', 'drsc.', 'drsc', 'dis.', 'dis', 'mba',
    'th.d.', 'thd', 'dr.', 'mgr.', 'ing.', 'bc.', 'mudr.', 'judr.', 'paeddr.',
  };
  while (tokens.isNotEmpty && suffixes.contains(tokens.first.toLowerCase())) {
    tokens.removeAt(0);
  }
  while (tokens.isNotEmpty && suffixes.contains(tokens.last.toLowerCase())) {
    tokens.removeLast();
  }
  return tokens.isEmpty ? '' : tokens.last;
}

/// True when a Bakalari absence label means 'already excused'.
///
/// Negations must NOT match: "Neomluveno"/"Neomluvená" contain "omluv"
/// and "Unexcused" contains "excus", so a naive substring check treats
/// unexcused absences as excused (and they silently never get excused).
bool isExcusedMarker(Object? text) {
  final low = '${text ?? ''}'.toLowerCase();
  if (low.contains('neomluv') ||
      low.contains('unexcus') ||
      low.contains('neexcus') ||
      // Word-boundary negations: a bare substring ("no excus") also
      // matches inside "omluveno excused" (ve-no-excus-ed).
      RegExp(r'\b(not|without|no)\s+excus').hasMatch(low) ||
      RegExp(r'\bbeze?\s+omluv').hasMatch(low)) {
    return false;
  }
  return low.contains('omluv') || low.contains('excus');
}

/// Returns the short display name of a Bakalari room.
///
/// Bakalari room labels carry the building code in parentheses, e.g.
/// `"4A - (104)"` or `"III - (P06)"` — only the part before the
/// dash (`"4A"` / `"III"`) is shown to students. Plain names
/// (`"U12"`, `""`) pass through unchanged.
String shortRoomName(Object? room) {
  final text = '${room ?? ''}'.trim();
  if (text.isEmpty) return '';
  // Canonical shape: "<short> - (<code>)", dash may be hyphen/en/em dash
  // with or without surrounding spaces.
  var m = RegExp(r'^(.*?)\s+[-–—]\s*\(.*\)\s*$').firstMatch(text);
  if (m != null && m.group(1)!.trim().isNotEmpty) {
    return m.group(1)!.trim();
  }
  m = RegExp(r'^(.*?)\s*[-–—]\s*\(.*\)\s*$').firstMatch(text);
  if (m != null && m.group(1)!.trim().isNotEmpty) {
    return m.group(1)!.trim();
  }
  // Fallback: trailing parenthesized suffix without a dash ("4A (104)").
  m = RegExp(r'^(.*?)\s+\(.*\)\s*$').firstMatch(text);
  if (m != null && m.group(1)!.trim().isNotEmpty) {
    return m.group(1)!.trim();
  }
  return text;
}

/// The excuse text of a template entry.
///
/// Entries are plain strings (older configs) or `{"name", "text"}`
/// dicts; anything else reads as an empty template.
String templateText(Object? entry) {
  if (entry is Map) return '${entry['text'] ?? ''}';
  if (entry == null) return '';
  return '$entry';
}

/// The user-given short name of a template entry ("" when unnamed).
String templateName(Object? entry) {
  if (entry is Map) {
    return '${entry['name'] ?? ''}'
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .join(' ');
  }
  return '';
}

/// Excuse texts of a configured template list (names dropped).
List<String> templateTexts(Object? entries) {
  if (entries is! List) return [];
  return entries.map(templateText).toList();
}

/// Formats an excuse template by replacing variables like {date},
/// {lessons}, {subject}, {signature}.
String formatExcuseTemplate(String? templateStr,
    {String dateStr = '',
    Object? lessonsStr = '',
    String subjectStr = '',
    String signatureStr = ''}) {
  if (templateStr == null || templateStr.isEmpty) return '';
  var res = templateStr;
  res = res.replaceAll('{date}', dateStr);
  res = res.replaceAll('{lessons}', '$lessonsStr');
  res = res.replaceAll('{subject}', subjectStr);
  if (res.contains('{signature}')) {
    res = res.replaceAll('{signature}', signatureStr);
  } else {
    final stripped = signatureStr.trim();
    // Case-insensitive check so "Jan Novák" in template isn't duplicated
    // when the configured signature is "jan novák" and vice versa.
    if (stripped.isNotEmpty &&
        !res.toLowerCase().contains(stripped.toLowerCase())) {
      res = '${res.trim()}\n$stripped';
    }
  }
  return res.trim();
}
