// Shared helpers: data dir, paths, atomic writes, locks, log redaction,
// date/room/teacher parsing, excuse templates, Fernet password codec.
//
// Port of strakalari/core/helpers.py. `secret_store.dart` is imported for
// the password codec (and imports this file for the lock) — the same
// mutual dependency Python resolves with lazy imports.
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;

import '../platform/keystore.dart' show KeyStoreUnavailable;
import '../platform/packaging.dart';
import 'accounts.dart'
    show
        accountsDirName,
        accountsFile,
        globalConfigFile,
        hasAnyAccountFolder,
        isAccountsMode,
        migratingDirName;
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

/// Calendar-day arithmetic, DST-proof.
///
/// `DateTime.add(Duration(days: n))` on a local midnight lands at 23:00 or
/// 01:00 across the Prague DST switches (29.3.2026, 25.10.2026) and breaks
/// midnight comparisons; the constructor form is real date arithmetic like
/// Python's naive `datetime + timedelta` (wall time preserved, date shifted).
DateTime addDays(DateTime d, int n) => d.isUtc
    ? DateTime.fromMicrosecondsSinceEpoch(
        d.microsecondsSinceEpoch + n * Duration.microsecondsPerDay,
        isUtc: true)
    : DateTime(d.year, d.month, d.day + n, d.hour, d.minute, d.second,
        d.millisecond, d.microsecond);

/// Whole calendar days from [a] to [b] (DST-proof: UTC has no transitions).
///
/// Python `(b - a).days` floors; Dart's `inDays` truncates, so the UTC
/// normalization also fixes negative ranges.
int daysBetween(DateTime a, DateTime b) =>
    DateTime.utc(b.year, b.month, b.day)
        .difference(DateTime.utc(a.year, a.month, a.day))
        .inDays;

/// Test seams for the data-dir resolution, like Python's tests patching
/// `sys.platform` and `sys.executable`: the OS (`'win32'`, `'darwin'`,
/// `'linux'`) and the folder of the executable. Null = the real ones.
String? dataDirPlatformOverride;
String? installDirOverride;

/// Test seam for `secret_store.carry_key` during a data move (Python's
/// tests patch it to simulate a locked keychain).
bool Function(String oldDir, String newDir)? carryKeyHook;

String get _dataDirPlatform =>
    dataDirPlatformOverride ??
    (Platform.isWindows ? 'win32' : (Platform.isMacOS ? 'darwin' : 'linux'));

/// Forgets which data dirs were resolved and migrated (tests; Python
/// resets `_MACOS_DATA_DIRS` / `_STORE_DATA_DIRS`).
void clearDataDirCaches() {
  macosDataDirCache.clear();
  _storeDataDirs.clear();
}

/// Returns a writable user data directory depending on platform and
/// installation mode. `STRAKALARI_DATA_DIR` overrides everything.
String getUserDataDir() {
  final override = (getenv('STRAKALARI_DATA_DIR') ?? '').trim();
  if (override.isNotEmpty) {
    Directory(override).createSync(recursive: true);
    return override;
  }
  if (isMobile()) return _mobileDataDir();
  if (_dataDirPlatform == 'darwin') return _macosAppDataDir();
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

String _installDir() => installDirOverride ?? projectRoot;

/// The per-user data dir of an installed app, created.
String _platformDataDir() {
  late final String dataDir;
  if (_dataDirPlatform == 'win32') {
    final appData = getenvNonEmpty('LOCALAPPDATA') ??
        getenvNonEmpty('APPDATA') ??
        _homeDir();
    dataDir = p.join(appData, 'Strakalari');
  } else if (_dataDirPlatform == 'darwin') {
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
  if (_dataDirPlatform == 'win32') {
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
/// process lifetime: every caller must agree on one location. Keyed
/// `'<bundle>\x00<target>'` (public for tests, like `_MACOS_DATA_DIRS`).
final Map<String, String> macosDataDirCache = {};

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
  final cached = macosDataDirCache[cacheKey];
  if (cached != null) return cached;
  var chosen = target;
  if (_needsBundleMigration(bundle, target) &&
      !_migrateBundleData(bundle, target)) {
    print('Warning: could not move the data out of the app bundle '
        '($bundle); using it for now, retrying on the next launch.');
    chosen = bundle;
  }
  macosDataDirCache[cacheKey] = chosen;
  return chosen;
}

bool _needsBundleMigration(String bundle, String target) {
  if (p.equals(p.absolute(bundle), p.absolute(target))) return false;
  if (File(p.join(bundle, accountsFile)).existsSync()) {
    return !File(p.join(target, accountsFile)).existsSync() &&
        !hasAnyAccountFolder(target);
  }
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
      Directory(tmp).renameSync(dst); // os.replace works on folders too
    } else {
      File(src).copySync(tmp);
      File(tmp).renameSync(dst);
    }
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
    final hasAccounts = File(p.join(bundle, accountsFile)).existsSync();
    final carry = carryKeyHook ?? carryKey;
    if (hasAccounts) {
      for (final rel in _bundleDataItems(bundle)) {
        _copyMissing(p.join(bundle, rel), p.join(target, rel));
      }
      _copyMissing(
          p.join(bundle, 'config.json'), p.join(target, 'config.json'));
      _copyMissing(
          p.join(bundle, globalConfigFile), p.join(target, globalConfigFile));
      final srcAccounts = Directory(p.join(bundle, accountsDirName));
      final accountNames = <String>[];
      if (srcAccounts.existsSync()) {
        for (final entity in srcAccounts.listSync(recursive: false)) {
          if (entity is! Directory) continue;
          final name = p.basename(entity.path);
          if (name == migratingDirName) continue;
          accountNames.add(name);
        }
      }
      // Carry root and per-account keys BEFORE writing any target
      // `accounts/<id>/config.json` or `accounts.json`, so an interrupted
      // key carry leaves `hasAnyAccountFolder(target) == false` and retries
      // cleanly on the next launch (§4.1, §11.2 item 8).
      if (!carry(bundle, target)) return false;
      for (final name in accountNames) {
        final srcAcc = p.join(bundle, accountsDirName, name);
        final dstAcc = p.join(target, accountsDirName, name);
        Directory(dstAcc).createSync(recursive: true);
        if (!carry(srcAcc, dstAcc)) return false;
      }
      for (final name in accountNames) {
        final srcAcc = p.join(bundle, accountsDirName, name);
        final dstAcc = p.join(target, accountsDirName, name);
        for (final item in Directory(srcAcc).listSync(recursive: false)) {
          final itemName = p.basename(item.path);
          if (itemName == 'config.json' || itemName == keyFile) continue;
          _copyMissing(item.path, p.join(dstAcc, itemName));
        }
        _copyMissing(p.join(srcAcc, 'config.json'), p.join(dstAcc, 'config.json'));
      }
      // Copy accounts.json LAST as the "move finished" marker (§4.1).
      _copyMissing(
          p.join(bundle, accountsFile), p.join(target, accountsFile));
      return true;
    }
    for (final rel in _bundleDataItems(bundle)) {
      _copyMissing(p.join(bundle, rel), p.join(target, rel));
    }
    if (!carry(bundle, target)) return false;
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
        final age = clock.now().difference(
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
///
/// On POSIX the lock is `flock(fd, LOCK_EX | LOCK_NB)` through libc
/// (`dart:ffi`), the same primitive Python uses (`fcntl.flock` in
/// `strakalari/core/helpers.py`), so a Python and a Dart app on one PC
/// exclude each other. `dart:io`'s `lockSync` uses `fcntl` record locks
/// instead, which belong to the process (several isolates of one process
/// can all hold one) and ignore `flock` holders. On Windows the lock stays
/// byte 0 via `lockSync` (`LockFileEx`), which overlaps Python's
/// `msvcrt.locking(0, LK_NBLCK, 1)`.
///
/// Also exclusive between handles of one process: an in-process registry
/// of held paths makes a second acquire fail, like Python's second handle
/// (a POSIX `flock` lets the same process lock twice).
class InterProcessLock {
  final String path;
  RandomAccessFile? _handle;
  int? _fd;

  /// Absolute lock paths currently held by this process (any object).
  static final Set<String> _heldPaths = {};

  InterProcessLock(this.path);

  static String _key(String path) => p.normalize(p.absolute(path));

  bool _tryOnce() {
    Directory(p.dirname(p.absolute(path))).createSync(recursive: true);
    final key = _key(path);
    if (_heldPaths.contains(key)) return false;
    if (!Platform.isWindows && _loadLibc() != null) {
      final fd = _flockExclusive(path);
      if (fd == null) return false;
      _fd = fd;
      _heldPaths.add(key);
      return true;
    }
    // Windows (`LockFileEx` overlaps Python's `msvcrt.locking`), or POSIX
    // without a usable libc (practically never): the old `lockSync`.
    final handle = File(path).openSync(mode: FileMode.append);
    try {
      // Byte 0 overlaps Python's msvcrt.locking(0, LK_NBLCK, 1), so the
      // two apps exclude each other.
      handle.lockSync(FileLock.exclusive, 0, 1);
    } on FileSystemException {
      handle.closeSync();
      return false;
    }
    _handle = handle;
    _heldPaths.add(key);
    return true;
  }

  /// True once held; False when still busy after [timeoutS].
  bool acquire({double timeoutS = 0}) {
    if (held) {
      throw StateError('lock $path is already held by this object');
    }
    final stopwatch = Stopwatch()..start();
    final timeout = Duration(microseconds: (timeoutS * 1e6).round());
    while (true) {
      try {
        if (_tryOnce()) return true;
      } on FileSystemException {
        return false;
      }
      if (stopwatch.elapsed >= timeout) return false;
      sleep(const Duration(milliseconds: 250));
    }
  }

  void release() {
    final handle = _handle;
    final fd = _fd;
    _handle = null;
    _fd = null;
    if (handle == null && fd == null) return;
    _heldPaths.remove(_key(path));
    if (handle != null) {
      try {
        handle.unlockSync();
      } on FileSystemException {
        // Closing the handle releases it anyway.
      } finally {
        handle.closeSync();
      }
    }
    if (fd != null) _flockRelease(fd);
  }

  /// Whether this object currently holds the lock.
  bool get held => _handle != null || _fd != null;
}

/// `flock(2)` operation flags (identical on Linux, macOS and Android).
const int _lockEx = 2; // LOCK_EX
const int _lockNb = 4; // LOCK_NB
const int _lockUn = 8; // LOCK_UN

/// `open(2)` flags: `O_RDWR` is 2 everywhere, `O_CREAT` differs per OS.
const int _oRdwr = 2;
int get _oCreat => Platform.isMacOS ? 0x200 : 64;

typedef _FlockC = ffi.Int32 Function(ffi.Int32 fd, ffi.Int32 operation);
/// `open` is variadic (`int open(const char *, int, ...)`): on Apple arm64
/// variadic arguments go on the stack, so the mode must be declared as one.
typedef _OpenC = ffi.Int32 Function(
    ffi.Pointer<ffi.Int8> path, ffi.Int32 flags, ffi.VarArgs<(ffi.Int32,)>);
typedef _CloseC = ffi.Int32 Function(ffi.Int32 fd);
typedef _MallocC = ffi.Pointer<ffi.Void> Function(ffi.Size size);
typedef _FreeC = ffi.Void Function(ffi.Pointer<ffi.Void> ptr);

/// Bound libc entry points for the POSIX `flock` path.
final class _Libc {
  const _Libc(this.flock, this.open, this.close, this.malloc, this.free);
  final int Function(int fd, int operation) flock;
  final int Function(ffi.Pointer<ffi.Int8> path, int flags, int mode) open;
  final int Function(int fd) close;
  final ffi.Pointer<ffi.Uint8> Function(int size) malloc;
  final void Function(ffi.Pointer<ffi.Void> ptr) free;
}

_Libc? _libcCache;
bool _libcFailed = false;

/// Opens libc and binds the calls [_flockExclusive] needs, or null when
/// no usable libc exists (then [_tryOnce] keeps the old `lockSync`).
_Libc? _loadLibc() {
  if (_libcCache != null) return _libcCache;
  if (_libcFailed) return null;
  try {
    final name = Platform.isMacOS
        ? '/usr/lib/libSystem.dylib'
        : Platform.isAndroid
            ? 'libc.so'
            : 'libc.so.6';
    ffi.DynamicLibrary lib;
    try {
      lib = ffi.DynamicLibrary.open(name);
    } catch (_) {
      lib = ffi.DynamicLibrary.process();
    }
    final flock = lib.lookupFunction<_FlockC, int Function(int, int)>('flock');
    final open = lib.lookupFunction<_OpenC,
        int Function(ffi.Pointer<ffi.Int8>, int, int)>('open');
    final close = lib.lookupFunction<_CloseC, int Function(int)>('close');
    final mallocRaw =
        lib.lookupFunction<_MallocC, ffi.Pointer<ffi.Void> Function(int)>(
            'malloc');
    final free =
        lib.lookupFunction<_FreeC, void Function(ffi.Pointer<ffi.Void>)>(
            'free');
    ffi.Pointer<ffi.Uint8> malloc(int size) {
      final ptr = mallocRaw(size);
      if (ptr.address == 0) throw StateError('malloc failed');
      return ptr.cast<ffi.Uint8>();
    }
    return _libcCache = _Libc(flock, open, close, malloc, free);
  } catch (e) {
    _libcFailed = true;
    print('Warning: could not load libc for flock ($e); falling back to lockSync.');
    return null;
  }
}

/// Opens [path] (creating it) and takes `LOCK_EX | LOCK_NB` on it.
///
/// Returns the fd, or null when another process holds the lock, the file
/// cannot be opened, or libc itself is unusable (the caller falls back to
/// `lockSync` then).
int? _flockExclusive(String path) {
  final libc = _loadLibc();
  if (libc == null) return null;
  ffi.Pointer<ffi.Uint8> native;
  try {
    final bytes = utf8.encode(path);
    native = libc.malloc(bytes.length + 1);
  } catch (_) {
    return null;
  }
  try {
    final bytes = utf8.encode(path);
    for (var i = 0; i < bytes.length; i++) {
      native[i] = bytes[i];
    }
    native[bytes.length] = 0;
    // Mode 0666 (umask applies): the lock file carries no secrets.
    final fd = libc.open(native.cast<ffi.Int8>(), _oRdwr | _oCreat, 438);
    if (fd < 0) return null;
    if (libc.flock(fd, _lockEx | _lockNb) != 0) {
      libc.close(fd);
      return null;
    }
    return fd;
  } catch (_) {
    return null;
  } finally {
    try {
      libc.free(native.cast<ffi.Void>());
    } catch (_) {
      // Nothing to do: the lock attempt already failed.
    }
  }
}

/// Drops a lock taken by [_flockExclusive] (unlock + close; closing alone
/// would release it too).
void _flockRelease(int fd) {
  final libc = _loadLibc();
  if (libc == null) return;
  try {
    libc.flock(fd, _lockUn);
  } catch (_) {
    // Closing the fd below drops the lock anyway.
  } finally {
    try {
      libc.close(fd);
    } catch (_) {
      // Already closed.
    }
  }
}

/// The line breaks Python's `str.splitlines()` splits on.
final RegExp _pyLineBreak =
    RegExp(r'\r\n|[\n\r\x0B\x0C\x1C\x1D\x1E\x85\u2028\u2029]');

/// One log line for an exception a scraper deliberately carries on after.
String describeSwallowed(String what, Object exc) {
  var first = '';
  try {
    final text = '$exc'.trim();
    if (text.isNotEmpty) {
      // Python `text.splitlines()[0][:160]` (code points, not UTF-16 units).
      final line = text.split(_pyLineBreak).first;
      first = String.fromCharCodes(line.runes.take(160));
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

/// Text-mode newline translation: Python writes LF as CRLF on Windows,
/// so files must match byte for byte there. [windows] overrides the
/// platform (tests).
String toPlatformNewlines(String text, {bool? windows}) =>
    (windows ?? Platform.isWindows) ? text.replaceAll('\n', '\r\n') : text;

/// Python `float.__repr__` / `json.dumps` float formatting:
/// scientific notation for `0 < |v| < 1e-4` and `|v| >= 1e16` with a
/// signed, at-least-two-digit exponent (`1e-07`, `1e+16`) and no trailing
/// `.0` on the mantissa; fixed-point with `.0` for whole numbers in
/// `[1e-4, 1e16)` and `±0.0`.
String _pyFloatRepr(double v) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v.isNegative ? '-Infinity' : 'Infinity';
  if (v == 0.0) return v.isNegative ? '-0.0' : '0.0';
  final sign = v.isNegative ? '-' : '';
  final absV = v.abs();
  final raw = absV.toString();
  final eIdx = raw.indexOf('e');
  if (eIdx != -1) {
    var mantissa = raw.substring(0, eIdx);
    if (mantissa.endsWith('.0')) {
      mantissa = mantissa.substring(0, mantissa.length - 2);
    }
    final expPart = raw.substring(eIdx + 1);
    final hasSign = expPart.startsWith('+') || expPart.startsWith('-');
    final expSign = hasSign ? expPart[0] : '+';
    final expDigits = hasSign ? expPart.substring(1) : expPart;
    return '$sign${mantissa}e$expSign${expDigits.padLeft(2, '0')}';
  }
  if (raw.startsWith('0.0000')) {
    final afterDot = raw.substring(2);
    var zeros = 0;
    while (zeros < afterDot.length && afterDot[zeros] == '0') {
      zeros++;
    }
    final sig = afterDot.substring(zeros);
    final exp = zeros + 1;
    final mantissa =
        sig.length <= 1 ? sig : '${sig[0]}.${sig.substring(1)}';
    return '$sign${mantissa}e-${exp.toString().padLeft(2, '0')}';
  }
  if (absV >= 1e16) {
    final digits =
        raw.endsWith('.0') ? raw.substring(0, raw.length - 2) : raw;
    final exp = digits.length - 1;
    final sig = digits.replaceFirst(RegExp(r'0+$'), '');
    final mantissa =
        sig.length <= 1 ? sig : '${sig[0]}.${sig.substring(1)}';
    return '$sign${mantissa}e+${exp.toString().padLeft(2, '0')}';
  }
  return '$sign$raw';
}

/// `json.dumps(value, ensure_ascii=False, default=str)`: Python's default
/// separators (`", "` and `": "`), non-ASCII kept as is. Values that are
/// not JSON types are written as their string form (`default=str`).
String pyJsonDumps(Object? value) {
  final out = StringBuffer();
  void write(Object? v) {
    if (v == null) {
      out.write('null');
    } else if (v is double) {
      out.write(_pyFloatRepr(v));
    } else if (v is bool || v is int || v is String) {
      out.write(jsonEncode(v));
    } else if (v is Map) {
      out.write('{');
      var first = true;
      v.forEach((k, val) {
        if (!first) out.write(', ');
        first = false;
        out.write(jsonEncode('$k'));
        out.write(': ');
        write(val);
      });
      out.write('}');
    } else if (v is Iterable) {
      out.write('[');
      var first = true;
      for (final item in v) {
        if (!first) out.write(', ');
        first = false;
        write(item);
      }
      out.write(']');
    } else {
      out.write(jsonEncode('$v'));
    }
  }

  write(value);
  return out.toString();
}

/// Python `repr()` of JSON-shaped values, for log lines that interpolate a
/// dict or list (`{excuse}` in an f-string): `{'type': 'days and hours'}`,
/// `None`, `True`, `[1, 2]`.
///
/// Strings follow `str.__repr__`: single quotes unless the text holds a
/// `'` and no `"`; backslash, the quote, `\n \r \t` and control characters
/// are escaped. Printable non-ASCII stays as is; the few invisible
/// characters that Python escapes too (no-break space, soft hyphen, zero
/// width and line/paragraph separators, BOM) are escaped here as well.
String pyRepr(Object? value) {
  if (value == null) return 'None';
  if (value is bool) return value ? 'True' : 'False';
  if (value is int) return '$value';
  if (value is double) {
    if (value.isNaN) return 'nan';
    if (value.isInfinite) return value.isNegative ? '-inf' : 'inf';
    return _pyFloatRepr(value);
  }
  if (value is String) return _pyStrRepr(value);
  if (value is Map) {
    return '{${value.entries.map((e) => '${pyRepr(e.key)}: ${pyRepr(e.value)}').join(', ')}}';
  }
  if (value is Set) return value.isEmpty ? 'set()' : '{${value.map(pyRepr).join(', ')}}';
  if (value is Iterable) return '[${value.map(pyRepr).join(', ')}]';
  return '$value';
}

String _pyStrRepr(String text) {
  final quote = text.contains("'") && !text.contains('"') ? '"' : "'";
  final out = StringBuffer(quote);
  for (final rune in text.runes) {
    if (rune == 0x5c) {
      out.write(r'\\');
    } else if (String.fromCharCode(rune) == quote) {
      out.write('\\$quote');
    } else if (rune == 0x0a) {
      out.write(r'\n');
    } else if (rune == 0x0d) {
      out.write(r'\r');
    } else if (rune == 0x09) {
      out.write(r'\t');
    } else if (rune < 0x20 || (rune >= 0x7f && rune <= 0xa0) || rune == 0xad) {
      out.write('\\x${rune.toRadixString(16).padLeft(2, '0')}');
    } else if ((rune >= 0x200b && rune <= 0x200f) ||
        (rune >= 0x2028 && rune <= 0x202f) ||
        rune == 0xfeff) {
      out.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(rune);
    }
  }
  out.write(quote);
  return out.toString();
}

/// `json.dumps(value, indent=2, ensure_ascii=False)`.
String jsonIndent2(Object? value) {
  final out = StringBuffer();
  void write(Object? v, int depth) {
    if (v == null) {
      out.write('null');
    } else if (v is double) {
      out.write(_pyFloatRepr(v));
    } else if (v is bool || v is int || v is String) {
      out.write(jsonEncode(v));
    } else if (v is Map) {
      if (v.isEmpty) {
        out.write('{}');
        return;
      }
      out.write('{\n');
      final pad = '  ' * (depth + 1);
      var first = true;
      v.forEach((k, val) {
        if (!first) out.write(',\n');
        first = false;
        out.write(pad);
        out.write(jsonEncode('$k'));
        out.write(': ');
        write(val, depth + 1);
      });
      out.write('\n');
      out.write('  ' * depth);
      out.write('}');
    } else if (v is Iterable) {
      final list = v is List ? v : v.toList();
      if (list.isEmpty) {
        out.write('[]');
        return;
      }
      out.write('[\n');
      final pad = '  ' * (depth + 1);
      for (var i = 0; i < list.length; i++) {
        if (i > 0) out.write(',\n');
        out.write(pad);
        write(list[i], depth + 1);
      }
      out.write('\n');
      out.write('  ' * depth);
      out.write(']');
    } else {
      out.write(jsonEncode('$v'));
    }
  }

  write(value, 0);
  return out.toString();
}

/// Writes JSON atomically (temp file + rename) so a crash or kill can
/// never leave a truncated file behind. Creates parent dirs as needed.
void atomicWriteJson(String path, Object? data,
    {Encoding encoding = utf8}) {
  final directory = p.dirname(p.absolute(path));
  Directory(directory).createSync(recursive: true);
  final tmpPath = mkstemp(directory, suffix: '.tmp');
  try {
    File(tmpPath).writeAsStringSync(
        toPlatformNewlines(jsonIndent2(data)),
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

final math.Random _tempNames = math.Random.secure();

/// `tempfile.mkstemp(dir=directory, suffix=suffix)`: creates a new, empty
/// file `tmpXXXXXXXX<suffix>` exclusively and returns its path. Every
/// writer gets its own name, also two isolates of one process (a
/// `<path>.<pid>.tmp` name would be shared by them).
String mkstemp(String directory, {String suffix = ''}) {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789_';
  for (var attempt = 0; attempt < 10000; attempt++) {
    final name = StringBuffer('tmp');
    for (var i = 0; i < 8; i++) {
      name.write(chars[_tempNames.nextInt(chars.length)]);
    }
    final candidate = p.join(directory, '$name$suffix');
    try {
      File(candidate).createSync(exclusive: true);
      return candidate;
    } on FileSystemException {
      if (File(candidate).existsSync()) continue; // taken: next name
      rethrow;
    }
  }
  throw FileSystemException('No usable temporary file name found', directory);
}

/// `os.replace`: renames over an existing target (also on Windows) and never
/// deletes the target first; a failure propagates.
void _replaceFile(String tmpPath, String path) {
  File(tmpPath).renameSync(path);
}

Fernet _fernetForDir(String? dataDir) {
  if (dataDir != null && dataDir.isNotEmpty) {
    return Fernet.fromKeyBytes(getKey(dataDir));
  }
  if (isAccountsMode) {
    throw StateError('per-account file used without an account folder');
  }
  return _getFernet();
}

bool _sameDir(String? a, String? b) {
  if (a == null || b == null || a.isEmpty || b.isEmpty) return false;
  return p.equals(p.normalize(p.absolute(a)), p.normalize(p.absolute(b)));
}

/// Encrypts text using Fernet. [key] is ignored and kept for backward
/// compatibility. When [dataDir] is provided, uses that folder's key.
String encrypt(String password, {String? key, String? dataDir}) {
  if (dataDir == null && isAccountsMode) {
    throw StateError('per-account file used without an account folder');
  }
  if (password.isEmpty) return '';
  return _fernetForDir(dataDir).encryptBytes(utf8.encode(password));
}

/// Decrypts text. Automatically falls back to [fallbackKeyDir] (if given and
/// distinct from [dataDir]) and then to legacy XOR if Fernet fails.
///
/// NOTE: this returns the input unchanged when nothing can decode it —
/// callers that must distinguish failure (e.g. settings UI) should use
/// decryptStrict().
String decrypt(String? passwordHash,
    {String? key, String? dataDir, String? fallbackKeyDir}) {
  if (dataDir == null && isAccountsMode) {
    throw StateError('per-account file used without an account folder');
  }
  if (passwordHash == null || passwordHash.isEmpty) return '';
  try {
    ascii.encode(passwordHash);
    return utf8.decode(_fernetForDir(dataDir).decryptToken(passwordHash));
  } on InvalidTokenException {
    // Try fallback key dir or legacy XOR below.
  } on FormatException {
    // Non-ASCII input: undecodable as a token either.
  } on FileSystemException {
    // secret.key file IO failed: try fallback below.
  } on KeyStoreUnavailable {
    // Python's `KeyStoreUnavailable` is an `OSError`: same fallback.
  }
  if (fallbackKeyDir != null &&
      fallbackKeyDir.isNotEmpty &&
      !_sameDir(dataDir, fallbackKeyDir)) {
    try {
      ascii.encode(passwordHash);
      return utf8.decode(
          Fernet.fromKeyBytes(getKey(fallbackKeyDir)).decryptToken(passwordHash));
    } on InvalidTokenException {
      // Fall through to legacy XOR.
    } on FormatException {
      // Fall through.
    } on FileSystemException {
      // Fall through.
    } on KeyStoreUnavailable {
      // Fall through.
    }
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
String? decryptStrict(String? passwordHash,
    {String? key, String? dataDir, String? fallbackKeyDir}) {
  if (dataDir == null && isAccountsMode) {
    throw StateError('per-account file used without an account folder');
  }
  if (passwordHash == null || passwordHash.isEmpty) return '';
  try {
    ascii.encode(passwordHash);
    return utf8.decode(_fernetForDir(dataDir).decryptToken(passwordHash));
  } catch (_) {
    // Try fallback key dir or legacy cipher below.
  }
  if (fallbackKeyDir != null &&
      fallbackKeyDir.isNotEmpty &&
      !_sameDir(dataDir, fallbackKeyDir)) {
    try {
      ascii.encode(passwordHash);
      return utf8.decode(
          Fernet.fromKeyBytes(getKey(fallbackKeyDir)).decryptToken(passwordHash));
    } catch (_) {
      // Try legacy cipher below.
    }
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
