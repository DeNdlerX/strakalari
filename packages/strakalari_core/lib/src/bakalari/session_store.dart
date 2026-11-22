// Bakaláři session reuse: in-memory exclusive-lending pool (3a) and
// Fernet-encrypted on-disk cookie store `bakalari_session.enc` (3b).
//
// See `docs/qa-roadmap/design-F6.md` §6.
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../platform/packaging.dart';
import '../storage/accounts.dart' show isAccountDirDeleted;
import '../storage/helpers.dart';
import 'http_session.dart';

/// Encrypted per-account Bakaláři session cookie store filename (F6 §6.2).
const String bakalariSessionFile = 'bakalari_session.enc';

/// 1-minute safety margin below Bakaláři's 15-minute sliding session.
const Duration bakalariSessionMaxAge = Duration(minutes: 14);

/// Maximum tolerated backwards clock skew when validating `renewed_at`.
const Duration bakalariSessionMaxClockSkew = Duration(minutes: 2);

/// SHA-256 hex digest of the decrypted password (stored only in memory and
/// inside the Fernet-encrypted session payload, never in plaintext files).
String passwordSha256(String plainPassword) =>
    sha256.convert(utf8.encode(plainPassword)).toString();

/// Path to `<dataDir>/bakalari_session.enc`.
String sessionFilePath(String dataDir) => p.join(dataDir, bakalariSessionFile);

String _normDir(String? dir) {
  if (dir == null || dir.isEmpty) return '';
  final norm = p.normalize(p.absolute(dir));
  return Platform.isWindows ? norm.toLowerCase() : norm;
}

void _chmod600(String path) {
  if (Platform.isWindows || mobilePlatform() == 'ios') return;
  try {
    Process.runSync('chmod', ['600', path]);
  } catch (_) {
    // Best-effort POSIX permissions.
  }
}

void _atomicWriteSecretText(String path, String content) {
  final dir = p.dirname(p.absolute(path));
  Directory(dir).createSync(recursive: true);
  final tmp = mkstemp(dir, suffix: '.tmp');
  try {
    _chmod600(tmp);
    File(tmp).writeAsStringSync(content, encoding: utf8);
    _chmod600(tmp);
    File(tmp).renameSync(path);
    _chmod600(path);
  } catch (_) {
    try {
      File(tmp).deleteSync();
    } on FileSystemException {
      // Nothing to clean.
    }
    rethrow;
  }
}

/// Deletes `<dataDir>/bakalari_session.enc` if present (best-effort).
void deleteStoredSession(String? dataDir) {
  if (dataDir == null || dataDir.isEmpty) return;
  try {
    final file = File(sessionFilePath(dataDir));
    if (file.existsSync()) file.deleteSync();
  } catch (_) {
    // Best-effort cleanup.
  }
}

/// Persists [cookies] encrypted with the account's Fernet key into
/// `<dataDir>/bakalari_session.enc` (`0600` on POSIX, never plaintext).
///
/// If encryption fails (e.g., `KeyStoreUnavailable`), logs a warning and skips
/// persistence without writing plaintext.
bool saveStoredSession({
  required String dataDir,
  required String root,
  required String username,
  required String passwordDigest,
  required Map<String, String> cookies,
  required DateTime renewedAt,
  void Function(String)? logger,
}) {
  if (dataDir.isEmpty || cookies.isEmpty || isAccountDirDeleted(dataDir)) {
    return false;
  }
  final payload = <String, Object?>{
    'v': 1,
    'root': root,
    'username': username,
    'password_sha256': passwordDigest,
    'cookies': Map<String, String>.of(cookies),
    'renewed_at': renewedAt.toUtc().toIso8601String(),
  };
  try {
    final ciphertext = encrypt(jsonEncode(payload), dataDir: dataDir);
    _atomicWriteSecretText(sessionFilePath(dataDir), ciphertext);
    return true;
  } on Object catch (e) {
    final msg = 'Warning: could not persist encrypted Bakaláři session ($e); '
        'skipping disk cache.';
    if (logger != null) {
      logger(msg);
    } else {
      print(msg);
    }
    return false;
  }
}

/// Loads and validates `<dataDir>/bakalari_session.enc`.
///
/// Deletes the file immediately if corrupt or if `root`, `username`, or
/// `passwordDigest` changed. Returns null if missing, deleted, or expired
/// (`age >= 14 min` or `< -2 min` from `renewed_at`).
({Map<String, String> cookies, DateTime renewedAt})? loadStoredSession({
  required String dataDir,
  String? fallbackKeyDir,
  required String root,
  required String username,
  required String passwordDigest,
  DateTime? now,
  void Function(String)? logger,
}) {
  if (dataDir.isEmpty) return null;
  final path = sessionFilePath(dataDir);
  final file = File(path);
  if (!file.existsSync()) return null;

  String? plaintext;
  try {
    final raw = file.readAsStringSync(encoding: utf8).trim();
    if (raw.isEmpty) {
      deleteStoredSession(dataDir);
      return null;
    }
    plaintext = decryptStrict(
      raw,
      dataDir: dataDir,
      fallbackKeyDir: fallbackKeyDir,
    );
  } on Object catch (e) {
    logger?.call('Debug: unreadable Bakaláři session store ($e); discarding.');
    deleteStoredSession(dataDir);
    return null;
  }
  if (plaintext == null || plaintext.isEmpty) {
    logger?.call('Debug: Bakaláři session store failed decryption; discarding.');
    deleteStoredSession(dataDir);
    return null;
  }

  Map<String, Object?> parsed;
  try {
    final decoded = jsonDecode(plaintext);
    if (decoded is! Map) {
      deleteStoredSession(dataDir);
      return null;
    }
    parsed = {for (final e in decoded.entries) '${e.key}': e.value as Object?};
  } on Object {
    deleteStoredSession(dataDir);
    return null;
  }

  if (parsed['v'] != 1 ||
      parsed['root'] != root ||
      parsed['username'] != username ||
      parsed['password_sha256'] != passwordDigest) {
    deleteStoredSession(dataDir);
    return null;
  }

  final renewed = DateTime.tryParse('${parsed['renewed_at'] ?? ''}')?.toUtc();
  if (renewed == null) {
    deleteStoredSession(dataDir);
    return null;
  }

  final rawCookies = parsed['cookies'];
  if (rawCookies is! Map || rawCookies.isEmpty) {
    deleteStoredSession(dataDir);
    return null;
  }
  final cookies = <String, String>{};
  for (final e in rawCookies.entries) {
    final k = '${e.key}'.trim();
    final v = '${e.value ?? ''}';
    if (k.isNotEmpty && v.isNotEmpty) cookies[k] = v;
  }
  if (cookies.isEmpty) {
    deleteStoredSession(dataDir);
    return null;
  }

  final refNow = (now ?? clock.now()).toUtc();
  final age = refNow.difference(renewed);
  if (age >= bakalariSessionMaxAge || age < -bakalariSessionMaxClockSkew) {
    // Expired or clock skewed: log in fresh directly without wasting a request.
    return null;
  }

  return (cookies: cookies, renewedAt: renewed);
}

/// Best-effort extraction of stored cookie values (`length >= 6`) for
/// error-report redaction (`error_report.dart`). Never raises.
Set<String> readStoredSessionCookieValues(
  String dataDir, {
  String? fallbackKeyDir,
}) {
  if (dataDir.isEmpty) return const <String>{};
  try {
    final file = File(sessionFilePath(dataDir));
    if (!file.existsSync()) return const <String>{};
    final raw = file.readAsStringSync(encoding: utf8).trim();
    if (raw.isEmpty) return const <String>{};
    final plain = decryptStrict(
      raw,
      dataDir: dataDir,
      fallbackKeyDir: fallbackKeyDir,
    );
    if (plain == null || plain.isEmpty) return const <String>{};
    final decoded = jsonDecode(plain);
    if (decoded is! Map) return const <String>{};
    final cookies = decoded['cookies'];
    if (cookies is! Map) return const <String>{};
    return {
      for (final v in cookies.values)
        if (v != null && '$v'.length >= 6) '$v',
    };
  } on Object {
    return const <String>{};
  }
}

class _PoolKey {
  final String dataDir;
  final String root;
  final String username;

  const _PoolKey(this.dataDir, this.root, this.username);

  @override
  bool operator ==(Object other) =>
      other is _PoolKey &&
      other.dataDir == dataDir &&
      other.root == root &&
      other.username == username;

  @override
  int get hashCode => Object.hash(dataDir, root, username);
}

class _PoolEntry {
  final BakalariSession session;
  final String passwordDigest;
  DateTime? renewedAt;
  bool lent;
  bool evicted = false;

  _PoolEntry({
    required this.session,
    required this.passwordDigest,
    required this.lent,
  });
}

/// Process-wide exclusive-lending pool of kept-alive [BakalariSession]s (3a)
/// backed by `<accountDir>/bakalari_session.enc` (3b).
class BakalariSessionPool {
  BakalariSessionPool._();

  static final BakalariSessionPool instance = BakalariSessionPool._();

  final Map<_PoolKey, _PoolEntry> _entries = {};
  final Set<_PoolEntry> _evictedWhileLent = {};

  /// Test seam: overrides the transport created for new sessions so tests can
  /// exercise 3a + 3b and pool-bypass checks with `FakeBakalari`.
  HttpTransport Function()? transportFactory;

  HttpTransport _makeTransport() =>
      transportFactory?.call() ??
      DartIoHttpTransport(idleTimeout: const Duration(minutes: 6));

  /// Checks out a pooled session exclusively for one [BakalariClient].
  ///
  /// If a matching session is already lent to another caller, returns a fresh
  /// non-pooled session (`pooled: false`) so no two callers ever share one
  /// [BakalariSession] (R8a S9).
  ({BakalariSession session, bool pooled}) checkout({
    required String? dataDir,
    String? fallbackKeyDir,
    required String url,
    required String username,
    required String Function() passwordProvider,
    required String passwordDigest,
    double timeoutS = 60.0,
    String userAgent = '',
    bool Function()? isCancelled,
    void Function(String)? logger,
  }) {
    final normDir = _normDir(dataDir);
    final root = appRoot(url);
    final key = _PoolKey(normDir, root, username);
    final existing = _entries[key];

    if (existing != null && existing.passwordDigest != passwordDigest) {
      _entries.remove(key);
      existing.evicted = true;
      if (existing.lent) {
        _evictedWhileLent.add(existing);
      } else {
        existing.session.close();
      }
      deleteStoredSession(dataDir);
    } else if (existing != null) {
      if (existing.lent) {
        // Exclusive lending: hand a fresh non-pooled session instead.
        final fresh = BakalariSession(
          url,
          username,
          passwordProvider,
          timeoutS: timeoutS,
          userAgent: userAgent,
          isCancelled: isCancelled,
          logger: logger,
          transport: _makeTransport(),
        );
        return (session: fresh, pooled: false);
      }
      existing.lent = true;
      existing.session.timeoutS = timeoutS;
      existing.session.isCancelled = isCancelled;
      existing.session.logger = logger;
      // Expire in-memory cookies past 14 min since last renewal so we don't
      // waste a round-trip against an expired sliding session.
      final renewed = existing.renewedAt;
      if (renewed != null) {
        final age = clock.now().toUtc().difference(renewed);
        if (age >= bakalariSessionMaxAge ||
            age < -bakalariSessionMaxClockSkew) {
          existing.session.loggedIn = false;
        }
      }
      return (session: existing.session, pooled: true);
    }

    final session = BakalariSession(
      url,
      username,
      passwordProvider,
      timeoutS: timeoutS,
      userAgent: userAgent,
      isCancelled: isCancelled,
      logger: logger,
      transport: _makeTransport(),
    );
    final entry = _PoolEntry(
      session: session,
      passwordDigest: passwordDigest,
      lent: true,
    );

    if (dataDir != null && dataDir.isNotEmpty) {
      final stored = loadStoredSession(
        dataDir: dataDir,
        fallbackKeyDir: fallbackKeyDir,
        root: root,
        username: username,
        passwordDigest: passwordDigest,
        logger: logger,
      );
      if (stored != null) {
        session.seedCookies(stored.cookies, markLoggedIn: true);
        entry.renewedAt = stored.renewedAt;
      }
    }

    session.onCookiesChanged = (cookies, renewedAt) {
      entry.renewedAt = renewedAt.toUtc();
      if (dataDir != null && dataDir.isNotEmpty) {
        saveStoredSession(
          dataDir: dataDir,
          root: root,
          username: username,
          passwordDigest: passwordDigest,
          cookies: cookies,
          renewedAt: renewedAt,
          logger: session.logger,
        );
      }
    };
    session.onLoginRejected = () {
      entry.renewedAt = null;
      deleteStoredSession(dataDir);
    };

    _entries[key] = entry;
    return (session: session, pooled: true);
  }

  /// Returns a pooled session after a run completes, keeping its keep-alive
  /// sockets open for the next tick.
  void checkin(BakalariSession session) {
    session.isCancelled = null;
    session.logger = null;
    for (final entry in _evictedWhileLent.toList()) {
      if (identical(entry.session, session)) {
        _evictedWhileLent.remove(entry);
        entry.lent = false;
        entry.session.close();
        return;
      }
    }
    for (final entry in _entries.values) {
      if (identical(entry.session, session)) {
        entry.lent = false;
        return;
      }
    }
    session.close();
  }

  /// Evicts all pooled sessions for [dataDir] and deletes its stored
  /// `bakalari_session.enc`.
  void evict(String? dataDir) {
    final normDir = _normDir(dataDir);
    for (final key in _entries.keys.toList()) {
      if (key.dataDir == normDir) {
        final entry = _entries.remove(key)!;
        entry.evicted = true;
        if (entry.lent) {
          _evictedWhileLent.add(entry);
        } else {
          entry.session.close();
        }
      }
    }
    deleteStoredSession(dataDir);
  }

  /// Closes every pooled session (desktop quit, `--forget-secrets`, tests).
  void closeAll() {
    for (final entry in _entries.values) {
      entry.evicted = true;
      entry.session.close();
    }
    _entries.clear();
    for (final entry in _evictedWhileLent) {
      entry.session.close();
    }
    _evictedWhileLent.clear();
  }

  /// Live cookie values (`length >= 6`) across all active pooled sessions, for
  /// error-report redaction.
  Set<String> activeCookieValues() {
    final values = <String>{};
    for (final entry in _entries.values) {
      for (final v in entry.session.cookies.values) {
        if (v.length >= 6) values.add(v);
      }
    }
    return values;
  }

  /// Resets pool state and test hooks between unit tests.
  @visibleForTesting
  void resetForTesting() {
    closeAll();
    transportFactory = null;
  }
}
