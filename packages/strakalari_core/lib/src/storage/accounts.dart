// Multiple school accounts: registry, shared/per-account split, one-time
// lossless migration from pre-F4 single-account layouts, and crash-safe
// account lifecycle (create, rename, switch, primary, delete).
//
// See `docs/qa-roadmap/design-F4.md` for the binding specification.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../platform/android_bridge.dart';
import '../platform/keystore.dart';
import '../platform/packaging.dart';
import 'config.dart';
import 'fernet.dart';
import 'helpers.dart';
import 'secret_store.dart';

/// Raised when `<rootDir>/session.lock` is held by another operation.
class SessionBusyError implements Exception {
  final String message;
  const SessionBusyError(this.message);
  @override
  String toString() => 'SessionBusyError: $message';
}

/// Account registry file at `<rootDir>/accounts.json` (commit marker of the move).
const String accountsFile = 'accounts.json';

/// Shared app-wide settings file at `<rootDir>/global.json`.
const String globalConfigFile = 'global.json';

/// Folder under `<rootDir>` holding per-account directories.
const String accountsDirName = 'accounts';

/// Staging directory inside `<rootDir>/accounts/` during an unfinished move.
/// Starts with `.` so [isValidAccountId] always rejects it.
const String migratingDirName = '.migrating';

/// ID of the first / migrated account.
const String defaultAccountId = 'default';

/// Registry schema version.
const int accountsRegistryVersion = 1;

/// Maximum length of a user-facing account label.
const int maxAccountLabelLength = 60;

/// Valid account ID format: lowercase alphanumeric, `_` or `-`, 1–40 chars.
final RegExp validAccountIdPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,39}$');

/// Shared settings stored once in `<rootDir>/global.json` (19 keys).
///
/// Every other canonical key in [canonicalDefaults] lives in
/// `<rootDir>/accounts/<id>/config.json` (55 keys).
const Set<String> globalConfigKeys = {
  // Appearance & UI layout (5)
  'theme',
  'language',
  'compact_density',
  'timetable_view',
  'marks_sort',
  // Onboarding & legal (3)
  'disclaimer_accepted',
  'tutorials_enabled',
  'tutorials_done',
  // Device & background shell (4)
  'minimize_to_tray',
  'run_in_background',
  'background_notification_items',
  'check_interval_minutes',
  // Notifications & updates (2)
  'notifications',
  'update_channel',
  // Network & cache display (2)
  'page_load_timeout_s',
  'cache_ttl_hours',
  // Shared Gemini API credentials (3)
  'gemini_api_key',
  'gemini_api_key_encrypted',
  'gemini_model',
};

/// Standard pre-F4 per-account files copied during the one-time move.
const List<String> _migrationStandardFiles = [
  'config.json',
  'config.json.bak',
  'data_cache.json',
  'already_excused_lessons.json',
  'already_excused_lessons.unconfirmed.json',
  'strava_blacklist.json',
  'automation_history.jsonl',
  'automation_history.jsonl.old',
  'log.txt',
  'log.txt.old',
];

// -- Process-wide accounts mode & deleted-folder guard ---------------------

String? _accountsModeRootDir;
final Set<String> _deletedAccountDirs = <String>{};

String _normDirKey(String dir) {
  final norm = p.normalize(p.absolute(dir));
  return Platform.isWindows ? norm.toLowerCase() : norm;
}

/// True once the process has entered multi-account mode (one-way in production).
bool get isAccountsMode => _accountsModeRootDir != null;

/// Root user data directory registered when entering accounts mode, or null.
String? get accountsModeRootDir => _accountsModeRootDir;

/// Activates accounts mode for [rootDir] in this isolate (one-way).
///
/// While active, per-account file functions called without an explicit
/// `dataDir`, `ConfigManager` targeting `<rootDir>/config.json`, and
/// `encrypt`/`decrypt`/`decryptStrict` without `dataDir` throw [StateError]
/// instead of silently falling back to the pre-update root files.
void enterAccountsMode(String rootDir) {
  _accountsModeRootDir = p.normalize(p.absolute(rootDir));
}

/// Resets accounts mode and deleted-folder markers (tests only).
@visibleForTesting
void resetAccountsModeForTesting() {
  _accountsModeRootDir = null;
  _deletedAccountDirs.clear();
}

/// Resolves [dataDir] for a per-account file, failing loudly in accounts mode
/// when [dataDir] is omitted.
String requirePerAccountDir(String? dataDir) {
  if (dataDir != null && dataDir.isNotEmpty) return dataDir;
  if (isAccountsMode) {
    throw StateError('per-account file used without an account folder');
  }
  return getUserDataDir();
}

/// Rejects opening `<rootDir>/config.json` via [ConfigManager] once accounts
/// mode is active.
void guardAccountsModeConfigPath(String resolvedConfigPath) {
  final root = _accountsModeRootDir;
  if (root == null) return;
  final rootCfg = p.normalize(p.join(root, 'config.json'));
  final target = p.normalize(p.absolute(resolvedConfigPath));
  if (p.equals(target, rootCfg)) {
    throw StateError('per-account file used without an account folder');
  }
}

/// Marks [accountDir] as deleted so late saves / cache writes refuse to
/// recreate it.
void markAccountDirDeleted(String accountDir) {
  _deletedAccountDirs.add(_normDirKey(accountDir));
}

/// Clears a deleted marker (e.g. if a new account is created).
void clearAccountDirDeleted(String accountDir) {
  _deletedAccountDirs.remove(_normDirKey(accountDir));
}

/// True when [dir] was marked deleted or is an account directory under
/// `<accountsModeRootDir>/accounts/` that no longer exists on disk.
bool isAccountDirDeleted(String? dir) {
  if (dir == null || dir.isEmpty) return false;
  if (_deletedAccountDirs.contains(_normDirKey(dir))) return true;
  final root = _accountsModeRootDir;
  if (root != null) {
    final absDir = p.normalize(p.absolute(dir));
    final accRoot = accountsRootDir(root);
    if (p.isWithin(accRoot, absDir) && !Directory(absDir).existsSync()) {
      return true;
    }
  }
  return false;
}

// -- Path & ID helpers -----------------------------------------------------

/// True when [id] matches [validAccountIdPattern].
bool isValidAccountId(String id) => validAccountIdPattern.hasMatch(id);

/// `<rootDir>/accounts` (absolute, normalized).
String accountsRootDir(String rootDir) =>
    p.normalize(p.join(p.absolute(rootDir), accountsDirName));

/// `<rootDir>/accounts/<accountId>`, validated and containment-checked.
String accountDirFor(String rootDir, String accountId) {
  if (!isValidAccountId(accountId)) {
    throw ArgumentError('Invalid account id: "$accountId"');
  }
  final root = accountsRootDir(rootDir);
  final dir = p.normalize(p.join(root, accountId));
  if (!p.isWithin(root, dir)) {
    throw ArgumentError('Account path escapes accounts root: "$accountId"');
  }
  return dir;
}

/// Generates a new random account id (`acc_<12 lowercase hex chars>`).
String generateAccountId([Random? rng]) {
  final random = rng ?? Random.secure();
  final buf = StringBuffer('acc_');
  for (var i = 0; i < 6; i++) {
    buf.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

/// Lists valid account IDs whose `<rootDir>/accounts/<id>/config.json` exists.
List<String> discoverAccountFolderIds(String rootDir) {
  final accRoot = Directory(accountsRootDir(rootDir));
  if (!accRoot.existsSync()) return const <String>[];
  final ids = <String>[];
  try {
    for (final entity in accRoot.listSync(recursive: false)) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!isValidAccountId(name)) continue;
      if (File(p.join(entity.path, 'config.json')).existsSync()) {
        ids.add(name);
      }
    }
  } on FileSystemException {
    return const <String>[];
  }
  ids.sort();
  return ids;
}

/// True when at least one valid account folder with `config.json` exists.
bool hasAnyAccountFolder(String rootDir) =>
    discoverAccountFolderIds(rootDir).isNotEmpty;

/// True when [rootDir] already has either `accounts.json` or an account folder.
bool hasMultiAccountLayoutOnDisk(String rootDir) =>
    File(p.join(rootDir, accountsFile)).existsSync() ||
    hasAnyAccountFolder(rootDir);

// -- Labels & duplicate login checks ---------------------------------------

/// Derives a display label from a config map (`your_signature` -> `bakalari_username` -> `''`).
String deriveAccountLabelFromConfig(Map<String, Object?> cfg) {
  for (final key in const ['your_signature', 'bakalari_username']) {
    final raw = '${cfg[key] ?? ''}'.trim();
    if (raw.isNotEmpty && !looksLikePlaceholder(raw)) {
      return truncateAccountLabel(raw);
    }
  }
  return '';
}

/// Trims and caps an account label to [maxAccountLabelLength] characters.
String truncateAccountLabel(String raw) {
  final trimmed = raw.trim();
  final runes = trimmed.runes;
  if (runes.length <= maxAccountLabelLength) return trimmed;
  return String.fromCharCodes(runes.take(maxAccountLabelLength)).trim();
}

/// Makes [candidate] unique (case-insensitive) among [existing], appending
/// ` 2`, ` 3`, ... on clash.
String uniqueAccountLabel(
  String candidate,
  Iterable<AccountInfo> existing, {
  String? excludeId,
}) {
  final base = truncateAccountLabel(candidate);
  if (base.isEmpty) return '';
  final taken = <String>{
    for (final acc in existing)
      if (acc.id != excludeId && acc.label.trim().isNotEmpty)
        acc.label.trim().toLowerCase(),
  };
  if (!taken.contains(base.toLowerCase())) return base;
  for (var n = 2; n < 10000; n++) {
    final suffix = ' $n';
    final maxBase = maxAccountLabelLength - suffix.length;
    final baseRunes = base.runes;
    final clipped = baseRunes.length > maxBase
        ? String.fromCharCodes(baseRunes.take(maxBase)).trimRight()
        : base;
    final next = '$clipped$suffix';
    if (!taken.contains(next.toLowerCase())) return next;
  }
  return base;
}

/// Normalizes a Bakaláři URL for duplicate-login comparison (scheme/host case,
/// trailing slashes and whitespace ignored).
String normalizeBakalariUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  final parsed = Uri.tryParse(s);
  if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
    final scheme = parsed.scheme.toLowerCase();
    final host = parsed.host.toLowerCase();
    final port = parsed.hasPort ? ':${parsed.port}' : '';
    var path = parsed.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return '$scheme://$host$port$path';
  }
  s = s.toLowerCase();
  while (s.endsWith('/')) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Returns another account already using the same Bakaláři URL + username, or null.
AccountInfo? findDuplicateBakalariLogin(
  String rootDir,
  AccountRegistry registry, {
  required String excludeAccountId,
  required String url,
  required String username,
}) {
  final normUrl = normalizeBakalariUrl(url);
  final normUser = username.trim().toLowerCase();
  if (normUrl.isEmpty || normUser.isEmpty) return null;
  for (final acc in registry.accounts) {
    if (acc.id == excludeAccountId || acc.adding) continue;
    final cfg = _readAccountConfigRaw(rootDir, acc.id);
    if (cfg == null) continue;
    final otherUrl = normalizeBakalariUrl('${cfg['bakalari_url'] ?? ''}');
    final otherUser = '${cfg['bakalari_username'] ?? ''}'.trim().toLowerCase();
    if (otherUrl == normUrl && otherUser == normUser) {
      return acc;
    }
  }
  return null;
}

/// Returns another account already using the same Strava canteen + username, or null.
AccountInfo? findDuplicateStravaLogin(
  String rootDir,
  AccountRegistry registry, {
  required String excludeAccountId,
  required String canteenId,
  required String username,
}) {
  final normCanteen = canteenId.trim().toLowerCase();
  final normUser = username.trim().toLowerCase();
  if (normCanteen.isEmpty || normUser.isEmpty) return null;
  for (final acc in registry.accounts) {
    if (acc.id == excludeAccountId || acc.adding) continue;
    final cfg = _readAccountConfigRaw(rootDir, acc.id);
    if (cfg == null) continue;
    final useStrava = cfg['use_strava'];
    if (useStrava == false || '$useStrava'.toLowerCase() == 'false') continue;
    final otherCanteen =
        '${cfg['strava_canteen_id'] ?? ''}'.trim().toLowerCase();
    final otherUser = '${cfg['strava_username'] ?? ''}'.trim().toLowerCase();
    if (otherCanteen == normCanteen && otherUser == normUser) {
      return acc;
    }
  }
  return null;
}

/// True when any configured per-account path resolves outside [accountDir].
bool accountHasOutsideFiles(
    String accountDir, Map<String, Object?> cfg) {
  final normAcc = p.normalize(p.absolute(accountDir));
  for (final key in const ['log_file', 'already_excused_file', 'strava_blacklist']) {
    final raw = '${cfg[key] ?? ''}'.trim();
    if (raw.isEmpty) continue;
    final resolved = p.normalize(p.absolute(resolvePath(raw, normAcc)));
    if (!p.equals(resolved, normAcc) && !p.isWithin(normAcc, resolved)) {
      return true;
    }
  }
  return false;
}

Map<String, Object?>? _readAccountConfigRaw(String rootDir, String accountId) {
  try {
    final path = p.join(accountDirFor(rootDir, accountId), 'config.json');
    if (!File(path).existsSync()) return null;
    final decoded = jsonDecode(File(path).readAsStringSync(encoding: utf8));
    if (decoded is! Map) return null;
    return decoded.map((k, v) => MapEntry('$k', v as Object?));
  } on Object {
    return null;
  }
}

// -- Registry models -------------------------------------------------------

/// Metadata for one school account in `accounts.json`.
class AccountInfo {
  final String id;
  final String label;
  final String createdAt;
  final bool migrated;
  final bool adding;

  const AccountInfo({
    required this.id,
    required this.label,
    required this.createdAt,
    this.migrated = false,
    this.adding = false,
  });

  AccountInfo copyWith({
    String? label,
    bool? migrated,
    bool? adding,
  }) =>
      AccountInfo(
        id: id,
        label: label ?? this.label,
        createdAt: createdAt,
        migrated: migrated ?? this.migrated,
        adding: adding ?? this.adding,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'label': label,
        'created_at': createdAt,
        if (migrated) 'migrated': true,
        if (adding) 'adding': true,
      };

  static AccountInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = '${raw['id'] ?? ''}'.trim();
    if (!isValidAccountId(id)) return null;
    final label = truncateAccountLabel('${raw['label'] ?? ''}');
    final createdAt = '${raw['created_at'] ?? ''}';
    final migrated = raw['migrated'] == true;
    final adding = raw['adding'] == true;
    return AccountInfo(
      id: id,
      label: label,
      createdAt: createdAt,
      migrated: migrated,
      adding: adding,
    );
  }
}

/// Loaded contents of `<rootDir>/accounts.json`.
class AccountRegistry {
  final int version;
  final String activeId;
  final String primaryId;
  final List<AccountInfo> accounts;

  AccountRegistry({
    this.version = accountsRegistryVersion,
    required this.activeId,
    required this.primaryId,
    required List<AccountInfo> accounts,
  }) : accounts = List<AccountInfo>.unmodifiable(accounts);

  bool get isMultiAccount => accounts.length > 1;

  AccountInfo? byId(String id) {
    for (final acc in accounts) {
      if (acc.id == id) return acc;
    }
    return null;
  }

  AccountInfo get activeAccount => byId(activeId) ?? accounts.first;

  AccountInfo get primaryAccount => byId(primaryId) ?? activeAccount;

  AccountRegistry copyWith({
    String? activeId,
    String? primaryId,
    List<AccountInfo>? accounts,
  }) =>
      AccountRegistry(
        version: version,
        activeId: activeId ?? this.activeId,
        primaryId: primaryId ?? this.primaryId,
        accounts: accounts ?? this.accounts,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'active_id': activeId,
        'primary_id': primaryId,
        'accounts': [for (final acc in accounts) acc.toJson()],
      };

  /// Plain read of `<rootDir>/accounts.json`.
  ///
  /// Returns `null` when neither `accounts.json` nor any account folder exists
  /// (fresh install or pre-F4 layout not moved yet).
  ///
  /// When `accounts.json` is missing or unreadable while account folders exist,
  /// rebuilds `accounts.json` from the folders under `migrate.lock` +
  /// `accounts.json.lock` (never reading root files and never running the move).
  /// Throws [StateError] if the rebuild itself fails.
  static AccountRegistry? load(String rootDir, {DateTime? now}) {
    final path = p.join(rootDir, accountsFile);
    final file = File(path);
    if (file.existsSync()) {
      final parsed = _tryParseRegistryFile(rootDir, path);
      if (parsed != null) return parsed;
      // Unreadable or empty registry.
      if (hasAnyAccountFolder(rootDir)) {
        return _rebuildRegistryFromFolders(rootDir, now: now);
      }
      quarantineCorruptFile(path);
      throw StateError(
          "Account registry '$path' is unreadable and no account folders exist.");
    }
    if (hasAnyAccountFolder(rootDir)) {
      return _rebuildRegistryFromFolders(rootDir, now: now);
    }
    return null;
  }

  static AccountRegistry? _tryParseRegistryFile(String rootDir, String path) {
    final Object? decoded;
    try {
      decoded = jsonDecode(File(path).readAsStringSync(encoding: utf8));
    } on FormatException catch (e) {
      print("Warning: Account registry '$path' is corrupt: $e.");
      return null;
    } on FileSystemException catch (e) {
      print("Warning: Could not read account registry '$path': $e.");
      return null;
    }
    if (decoded is! Map) {
      print("Warning: Account registry '$path' is not a JSON object.");
      return null;
    }
    final rawAccounts = decoded['accounts'];
    if (rawAccounts is! List) {
      print("Warning: Account registry '$path' has invalid 'accounts' list.");
      return null;
    }
    final seen = <String>{};
    final valid = <AccountInfo>[];
    for (final raw in rawAccounts) {
      final info = AccountInfo.fromJson(raw);
      if (info == null) continue;
      if (!seen.add(info.id)) continue;
      final dir = accountDirFor(rootDir, info.id);
      if (!Directory(dir).existsSync()) {
        print("Warning: Dropping account '${info.id}' from registry because "
            "folder '$dir' does not exist.");
        continue;
      }
      valid.add(info);
    }
    if (valid.isEmpty) {
      print("Warning: Account registry '$path' contains no valid accounts.");
      return null;
    }
    final rawActive = '${decoded['active_id'] ?? ''}'.trim();
    final activeId =
        valid.any((a) => a.id == rawActive) ? rawActive : valid.first.id;
    final rawPrimary = '${decoded['primary_id'] ?? ''}'.trim();
    final primaryId =
        valid.any((a) => a.id == rawPrimary) ? rawPrimary : activeId;
    return AccountRegistry(
      version: accountsRegistryVersion,
      activeId: activeId,
      primaryId: primaryId,
      accounts: valid,
    );
  }

  static AccountRegistry _rebuildRegistryFromFolders(
    String rootDir, {
    DateTime? now,
  }) {
    final migrateLock = InterProcessLock(p.join(rootDir, 'migrate.lock'));
    if (!migrateLock.acquire(timeoutS: 30.0)) {
      throw StateError('Could not lock migrate.lock to rebuild accounts.json.');
    }
    try {
      final regLock = InterProcessLock(p.join(rootDir, '$accountsFile.lock'));
      if (!regLock.acquire(timeoutS: 10.0)) {
        throw StateError(
            'Could not lock accounts.json.lock to rebuild accounts.json.');
      }
      try {
        final regPath = p.join(rootDir, accountsFile);
        if (File(regPath).existsSync()) {
          // Re-check inside lock: another process may have rebuilt it.
          final already = _tryParseRegistryFile(rootDir, regPath);
          if (already != null) return already;
          final backup = quarantineCorruptFile(regPath);
          final hint = backup.isNotEmpty ? ' Preserved at $backup.' : '';
          print("Warning: Rebuilding unreadable account registry '$regPath'.$hint");
        } else {
          print("Warning: Account registry '$regPath' is missing; "
              'rebuilding from account folders.');
        }
        final ids = discoverAccountFolderIds(rootDir);
        if (ids.isEmpty) {
          throw StateError(
              'No valid account folders found under ${accountsRootDir(rootDir)}.');
        }
        final hasRootBackup = File(p.join(rootDir, 'config.json')).existsSync();
        final stamp = _isoStamp(now ?? clock.now());
        final built = <AccountInfo>[];
        for (final id in ids) {
          final cfg = _readAccountConfigRaw(rootDir, id) ?? const <String, Object?>{};
          final candidate = deriveAccountLabelFromConfig(cfg);
          final label = uniqueAccountLabel(candidate, built);
          built.add(AccountInfo(
            id: id,
            label: label,
            createdAt: stamp,
            migrated: id == defaultAccountId && hasRootBackup,
            adding: false,
          ));
        }
        final activeId =
            ids.contains(defaultAccountId) ? defaultAccountId : ids.first;
        final registry = AccountRegistry(
          version: accountsRegistryVersion,
          activeId: activeId,
          primaryId: activeId,
          accounts: built,
        );
        try {
          atomicWriteJson(regPath, registry.toJson());
        } on Object catch (e) {
          throw StateError(
              "Could not write rebuilt account registry '$regPath': $e");
        }
        return registry;
      } finally {
        regLock.release();
      }
    } finally {
      migrateLock.release();
    }
  }
}

// -- One-time move & layout initialization (§4.2) --------------------------

enum MultiAccountLayoutStatus {
  /// Accounts layout is ready and accounts mode has been entered.
  ready,

  /// Pre-F4 move could not finish; run in degraded single-account mode.
  degraded,

  /// Account folders exist, but `accounts.json` could not be loaded or rebuilt.
  registryFailed,
}

/// Outcome of [ensureMultiAccountLayout].
class MultiAccountLayoutResult {
  final MultiAccountLayoutStatus status;
  final AccountRegistry? registry;
  final bool migratedNow;
  final String? error;

  const MultiAccountLayoutResult._({
    required this.status,
    this.registry,
    this.migratedNow = false,
    this.error,
  });

  const MultiAccountLayoutResult.ready(
    AccountRegistry registry, {
    bool migratedNow = false,
  }) : this._(
          status: MultiAccountLayoutStatus.ready,
          registry: registry,
          migratedNow: migratedNow,
        );

  const MultiAccountLayoutResult.degraded(String error)
      : this._(
          status: MultiAccountLayoutStatus.degraded,
          error: error,
        );

  const MultiAccountLayoutResult.registryFailed(String error)
      : this._(
          status: MultiAccountLayoutStatus.registryFailed,
          error: error,
        );

  bool get isReady => status == MultiAccountLayoutStatus.ready;
  bool get isDegraded => status == MultiAccountLayoutStatus.degraded;
  bool get isRegistryFailed => status == MultiAccountLayoutStatus.registryFailed;
}

/// Ensures `<rootDir>` has a valid multi-account layout, performing the
/// one-time lossless move from a pre-F4 flat layout when needed (§4.2).
///
/// - Never deletes or modifies any pre-F4 root file.
/// - Holds `<rootDir>/session.lock` then `<rootDir>/migrate.lock` during the move.
/// - Once any account folder exists, never runs the move again and never falls
///   back to the root files.
Future<MultiAccountLayoutResult> ensureMultiAccountLayout(
  String rootDir, {
  FutureOr<bool> Function(String rootDir)? warmAndroidRootKey,
  double sessionLockTimeoutS = 120.0,
  double migrateLockTimeoutS = 30.0,
  DateTime? now,
  @visibleForTesting void Function(String step)? onMigrationStep,
}) async {
  Directory(rootDir).createSync(recursive: true);

  // Fast path: registry or account folders already exist -> load or rebuild.
  if (hasMultiAccountLayoutOnDisk(rootDir)) {
    try {
      final reg = AccountRegistry.load(rootDir, now: now);
      if (reg != null) {
        enterAccountsMode(rootDir);
        return MultiAccountLayoutResult.ready(reg);
      }
      return const MultiAccountLayoutResult.registryFailed(
          'Account registry returned null despite existing layout.');
    } on Object catch (e) {
      print('Warning: Account registry load/rebuild failed: $e');
      return MultiAccountLayoutResult.registryFailed('$e');
    }
  }

  final rootConfigPath = p.join(rootDir, 'config.json');

  // Fresh install path: no root config.json, no accounts.json, no account folders.
  if (!File(rootConfigPath).existsSync()) {
    final migrateLock = InterProcessLock(p.join(rootDir, 'migrate.lock'));
    if (!migrateLock.acquire(timeoutS: migrateLockTimeoutS)) {
      return const MultiAccountLayoutResult.degraded(
          'Could not acquire migrate.lock for fresh account layout.');
    }
    try {
      if (hasMultiAccountLayoutOnDisk(rootDir)) {
        final reg = AccountRegistry.load(rootDir, now: now);
        if (reg != null) {
          enterAccountsMode(rootDir);
          return MultiAccountLayoutResult.ready(reg);
        }
      }
      if (!File(rootConfigPath).existsSync()) {
        final stagingDir = p.join(accountsRootDir(rootDir), migratingDirName);
        if (Directory(stagingDir).existsSync()) {
          Directory(stagingDir).deleteSync(recursive: true);
        }
        final defDir = accountDirFor(rootDir, defaultAccountId);
        Directory(defDir).createSync(recursive: true);
        clearAccountDirDeleted(defDir);
        final globalPath = p.join(rootDir, globalConfigFile);
        if (!File(globalPath).existsSync()) {
          atomicWriteJson(globalPath, <String, Object?>{});
        }
        final defCfgPath = p.join(defDir, 'config.json');
        if (!File(defCfgPath).existsSync()) {
          atomicWriteJson(defCfgPath, <String, Object?>{});
        }
        final registry = AccountRegistry(
          version: accountsRegistryVersion,
          activeId: defaultAccountId,
          primaryId: defaultAccountId,
          accounts: [
            AccountInfo(
              id: defaultAccountId,
              label: '',
              createdAt: _isoStamp(now ?? clock.now()),
              migrated: false,
              adding: false,
            ),
          ],
        );
        atomicWriteJson(p.join(rootDir, accountsFile), registry.toJson());
        enterAccountsMode(rootDir);
        return MultiAccountLayoutResult.ready(registry);
      }
    } on Object catch (e) {
      print('Warning: Fresh account layout setup failed: $e');
      return MultiAccountLayoutResult.degraded('$e');
    } finally {
      migrateLock.release();
    }
  }

  // One-time move path (§4.2): root config.json exists, no accounts.json, no account folder.
  final sessionLock = InterProcessLock(p.join(rootDir, 'session.lock'));
  if (!sessionLock.acquire(timeoutS: sessionLockTimeoutS)) {
    const msg = 'Could not acquire session.lock before multi-account move.';
    print('Warning: $msg');
    return const MultiAccountLayoutResult.degraded(msg);
  }
  try {
    final migrateLock = InterProcessLock(p.join(rootDir, 'migrate.lock'));
    if (!migrateLock.acquire(timeoutS: migrateLockTimeoutS)) {
      const msg = 'Could not acquire migrate.lock before multi-account move.';
      print('Warning: $msg');
      return const MultiAccountLayoutResult.degraded(msg);
    }
    try {
      // Step 1: Re-check inside locks.
      if (hasMultiAccountLayoutOnDisk(rootDir)) {
        try {
          final reg = AccountRegistry.load(rootDir, now: now);
          if (reg != null) {
            enterAccountsMode(rootDir);
            return MultiAccountLayoutResult.ready(reg);
          }
          return const MultiAccountLayoutResult.registryFailed(
              'Account registry unavailable after concurrent move.');
        } on Object catch (e) {
          return MultiAccountLayoutResult.registryFailed('$e');
        }
      }

      // Step 2: Parse source config.json.
      late final Map<String, Object?> srcCfg;
      try {
        final decoded = jsonDecode(
            File(rootConfigPath).readAsStringSync(encoding: utf8));
        if (decoded is! Map) {
          const msg = 'Root config.json does not contain a JSON object.';
          print('Warning: F4 move aborted: $msg');
          return const MultiAccountLayoutResult.degraded(msg);
        }
        srcCfg = decoded.map((k, v) => MapEntry('$k', v as Object?));
      } on Object catch (e) {
        final msg = 'Could not parse root config.json: $e';
        print('Warning: F4 move aborted: $msg');
        return MultiAccountLayoutResult.degraded(msg);
      }

      // Step 3: Build file list (relative paths under rootDir that currently exist).
      final filesToCopy = _buildMigrationFileList(rootDir, srcCfg);

      // Step 4: Fresh staging copy into accounts/.migrating/.
      final accRoot = accountsRootDir(rootDir);
      final stagingDir = p.join(accRoot, migratingDirName);
      try {
        if (Directory(stagingDir).existsSync()) {
          Directory(stagingDir).deleteSync(recursive: true);
        }
        Directory(stagingDir).createSync(recursive: true);
        for (final rel in filesToCopy) {
          _copyFileAtomic(p.join(rootDir, rel), p.join(stagingDir, rel));
        }
      } on Object catch (e) {
        final msg = 'Staging copy failed: $e';
        print('Warning: F4 move aborted: $msg');
        return MultiAccountLayoutResult.degraded(msg);
      }
      onMigrationStep?.call('staging_copy');

      // Step 5: Carry the credential key (never calling getKey on finalDefaultDir).
      final finalDefaultDir = accountDirFor(rootDir, defaultAccountId);
      final keyCarry = await _carryKeyForMigration(
        rootDir: rootDir,
        stagingDir: stagingDir,
        finalDefaultDir: finalDefaultDir,
        srcCfg: srcCfg,
        warmAndroidRootKey: warmAndroidRootKey,
      );
      if (!keyCarry.ok) {
        print('Warning: F4 move aborted at key carry: ${keyCarry.error}');
        return MultiAccountLayoutResult.degraded(
            keyCarry.error ?? 'Key carry failed');
      }
      onMigrationStep?.call('key_carry');

      // Step 6: Verify everything before committing (NO decrypt fallback!).
      final verifyError = _verifyMigration(
        rootDir: rootDir,
        stagingDir: stagingDir,
        finalDefaultDir: finalDefaultDir,
        srcCfg: srcCfg,
        copiedFiles: [...filesToCopy, ...keyCarry.extraCopiedFiles],
        keyCarry: keyCarry,
      );
      if (verifyError != null) {
        print('Warning: F4 move aborted at verification: $verifyError');
        return MultiAccountLayoutResult.degraded(verifyError);
      }
      onMigrationStep?.call('verify');

      // Step 8: Write global.json every attempt and verify it parses back.
      final globalPath = p.join(rootDir, globalConfigFile);
      try {
        final globalData = <String, Object?>{
          for (final k in globalConfigKeys)
            if (srcCfg.containsKey(k) && srcCfg[k] != null) k: srcCfg[k],
        };
        atomicWriteJson(globalPath, globalData);
        final back =
            jsonDecode(File(globalPath).readAsStringSync(encoding: utf8));
        if (back is! Map) {
          throw const FormatException('global.json did not decode as a Map');
        }
      } on Object catch (e) {
        final msg = 'Could not write/verify global.json: $e';
        print('Warning: F4 move aborted: $msg');
        return MultiAccountLayoutResult.degraded(msg);
      }
      onMigrationStep?.call('global_json');

      // Step 9: Commit — rename staging -> accounts/default/, then write accounts.json last.
      try {
        if (Directory(finalDefaultDir).existsSync()) {
          // Step 1 already verified no config.json exists in any account folder.
          Directory(finalDefaultDir).deleteSync(recursive: true);
        }
        Directory(stagingDir).renameSync(finalDefaultDir);
        clearAccountDirDeleted(finalDefaultDir);
      } on Object catch (e) {
        final msg = 'Could not rename staging folder to accounts/default: $e';
        print('Warning: F4 move aborted: $msg');
        return MultiAccountLayoutResult.degraded(msg);
      }
      onMigrationStep?.call('rename');

      final label = deriveAccountLabelFromConfig(srcCfg);
      final registry = AccountRegistry(
        version: accountsRegistryVersion,
        activeId: defaultAccountId,
        primaryId: defaultAccountId,
        accounts: [
          AccountInfo(
            id: defaultAccountId,
            label: label,
            createdAt: _isoStamp(now ?? clock.now()),
            migrated: true,
            adding: false,
          ),
        ],
      );
      try {
        atomicWriteJson(p.join(rootDir, accountsFile), registry.toJson());
      } on Object catch (e) {
        // Rename already happened: folders exist, so next start rebuilds registry.
        final msg = 'Could not write accounts.json after rename: $e';
        print('Warning: $msg');
        return MultiAccountLayoutResult.registryFailed(msg);
      }
      evictKeyCache(finalDefaultDir);
      enterAccountsMode(rootDir);
      return MultiAccountLayoutResult.ready(registry, migratedNow: true);
    } finally {
      migrateLock.release();
    }
  } finally {
    sessionLock.release();
  }
}

List<String> _buildMigrationFileList(
    String rootDir, Map<String, Object?> srcCfg) {
  final candidates = <String>[..._migrationStandardFiles];
  for (final key in const ['strava_blacklist', 'already_excused_file', 'log_file']) {
    final value = srcCfg[key];
    if (value is! String || value.trim().isEmpty || p.isAbsolute(value)) {
      continue;
    }
    final rel = p.normalize(value);
    if (rel == '.' ||
        rel == '..' ||
        rel.startsWith('..${Platform.pathSeparator}') ||
        rel.startsWith('../')) {
      continue;
    }
    final resolved = p.normalize(p.join(p.absolute(rootDir), rel));
    if (!p.isWithin(p.normalize(p.absolute(rootDir)), resolved)) continue;
    if (!candidates.contains(rel)) candidates.add(rel);
  }
  final existing = <String>[];
  final seenNorm = <String>{};
  for (final rel in candidates) {
    final full = p.join(rootDir, rel);
    if (!FileSystemEntity.isFileSync(full)) continue;
    final key = Platform.isWindows ? rel.toLowerCase() : rel;
    if (seenNorm.add(key)) existing.add(rel);
  }
  return existing;
}

void _copyFileAtomic(String src, String dst) {
  final dir = p.dirname(p.absolute(dst));
  Directory(dir).createSync(recursive: true);
  final tmp = mkstemp(dir, suffix: '.mig');
  try {
    File(tmp).writeAsBytesSync(File(src).readAsBytesSync(), flush: true);
    File(tmp).renameSync(dst);
  } catch (_) {
    try {
      if (File(tmp).existsSync()) File(tmp).deleteSync();
    } on FileSystemException {
      // Best-effort cleanup.
    }
    rethrow;
  }
}

enum _KeyCarryMode { none, androidWrapped, file, desktopStore }

class _KeyCarryResult {
  final bool ok;
  final String? error;
  final _KeyCarryMode mode;
  final Uint8List? rootKey;
  final List<String> extraCopiedFiles;

  const _KeyCarryResult({
    required this.ok,
    this.error,
    this.mode = _KeyCarryMode.none,
    this.rootKey,
    this.extraCopiedFiles = const [],
  });
}

bool _hasEncryptedAccountSecret(Map<String, Object?> cfg) {
  for (final key in const ['bakalari_password', 'strava_password']) {
    if (isEncryptedFlag(cfg['${key}_encrypted']) &&
        '${cfg[key] ?? ''}'.isNotEmpty) {
      return true;
    }
  }
  return false;
}

bool _hasEncryptedGeminiKey(Map<String, Object?> cfg) =>
    isEncryptedFlag(cfg['gemini_api_key_encrypted']) &&
    '${cfg['gemini_api_key'] ?? ''}'.isNotEmpty;

Future<_KeyCarryResult> _carryKeyForMigration({
  required String rootDir,
  required String stagingDir,
  required String finalDefaultDir,
  required Map<String, Object?> srcCfg,
  FutureOr<bool> Function(String rootDir)? warmAndroidRootKey,
}) async {
  final rootWrappedPath = p.join(rootDir, wrappedFile);
  final rootKeyFilePath = p.join(rootDir, keyFile);
  final hasWrapped = File(rootWrappedPath).existsSync();
  final hasKeyFile = File(rootKeyFilePath).existsSync();
  final needsKey =
      _hasEncryptedAccountSecret(srcCfg) || _hasEncryptedGeminiKey(srcCfg);

  // Android path: wrapped blob or plain secret.key.
  final noKeyringEnv = (getenv('STRAKALARI_NO_KEYRING') ?? '').trim();
  final noKeyring = noKeyringEnv.isNotEmpty && noKeyringEnv != '0';
  final androidAvailable = !noKeyring &&
      (isMobile() ||
          (androidKeystoreBridge != null && androidKeystoreBridge!.available));

  if (androidAvailable && (hasWrapped || warmAndroidRootKey != null)) {
    if (hasWrapped) {
      if (warmAndroidRootKey != null) {
        final clean = await warmAndroidRootKey(rootDir);
        if (!clean) {
          return const _KeyCarryResult(
            ok: false,
            error: 'Android root key warm-up did not unwrap cleanly.',
          );
        }
      }
      final bridge = androidKeystoreBridge;
      if (bridge == null || !bridge.available) {
        return const _KeyCarryResult(
          ok: false,
          error: 'Android Keystore bridge unavailable while root has wrapped key.',
        );
      }
      final extra = <String>[];
      try {
        final rawText = ascii.decode(File(rootWrappedPath).readAsBytesSync()).trim();
        final unwrapped = bridge.unwrap(base64.decode(rawText));
        if (!Fernet.isValidKeyBytes(unwrapped)) {
          return const _KeyCarryResult(
            ok: false,
            error: 'Unwrapped Android root key is invalid.',
          );
        }
        _copyFileAtomic(rootWrappedPath, p.join(stagingDir, wrappedFile));
        extra.add(wrappedFile);
        if (hasKeyFile) {
          _copyFileAtomic(rootKeyFilePath, p.join(stagingDir, keyFile));
          extra.add(keyFile);
          final fileKey = readKeyFromFileOnly(rootDir);
          if (fileKey != null &&
              Fernet.isValidKeyBytes(fileKey) &&
              !_uint8Equals(fileKey, unwrapped)) {
            // Mirrors secret_store._androidLoadOrCreate: when both files exist
            // and differ, getKey() uses the plain secret.key file.
            return _KeyCarryResult(
              ok: true,
              mode: _KeyCarryMode.file,
              rootKey: fileKey,
              extraCopiedFiles: extra,
            );
          }
        }
        return _KeyCarryResult(
          ok: true,
          mode: _KeyCarryMode.androidWrapped,
          rootKey: unwrapped,
          extraCopiedFiles: extra,
        );
      } on Object catch (e) {
        return _KeyCarryResult(
          ok: false,
          error: 'Failed to unwrap/copy Android wrapped key: $e',
        );
      }
    }
  }

  // File-based key (Android plain secret.key, STRAKALARI_NO_KEYRING, or root secret.key file).
  if (hasKeyFile) {
    final fileKey = readKeyFromFileOnly(rootDir);
    if (fileKey == null || !Fernet.isValidKeyBytes(fileKey)) {
      return const _KeyCarryResult(
        ok: false,
        error: 'Root secret.key is corrupt or invalid.',
      );
    }
    try {
      writeKeyFileDirect(p.join(stagingDir, keyFile), fileKey);
    } on Object catch (e) {
      return _KeyCarryResult(
        ok: false,
        error: 'Could not write staged secret.key: $e',
      );
    }
    return _KeyCarryResult(
      ok: true,
      mode: _KeyCarryMode.file,
      rootKey: fileKey,
      extraCopiedFiles: const [keyFile],
    );
  }

  // Desktop OS credential store path.
  if (!isMobile() && hasDesktopKeyStore()) {
    late final Uint8List? storeKey;
    try {
      storeKey = readKeyFromStoreOnly(rootDir);
    } on KeyStoreUnavailable catch (e) {
      return _KeyCarryResult(
        ok: false,
        error: 'Could not read root key from OS credential store: $e',
      );
    }
    if (storeKey == null) {
      if (needsKey) {
        // Legacy XOR passwords may exist without a Fernet key; allow if none look like Fernet.
        if (_hasFernetToken(srcCfg)) {
          return const _KeyCarryResult(
            ok: false,
            error: 'Encrypted Fernet password present but no root key found.',
          );
        }
      }
      return const _KeyCarryResult(ok: true, mode: _KeyCarryMode.none);
    }
    final stored = writeKeyToStoreOnly(finalDefaultDir, storeKey);
    if (!stored) {
      return const _KeyCarryResult(
        ok: false,
        error: 'OS credential store refused to save carried default account key.',
      );
    }
    return _KeyCarryResult(
      ok: true,
      mode: _KeyCarryMode.desktopStore,
      rootKey: storeKey,
    );
  }

  // No key file and no OS store.
  if (needsKey && _hasFernetToken(srcCfg)) {
    return const _KeyCarryResult(
      ok: false,
      error: 'Encrypted Fernet password present but no root key exists.',
    );
  }
  return const _KeyCarryResult(ok: true, mode: _KeyCarryMode.none);
}

bool _hasFernetToken(Map<String, Object?> cfg) {
  for (final k in const ['bakalari_password', 'strava_password', 'gemini_api_key']) {
    if (isEncryptedFlag(cfg['${k}_encrypted'])) {
      final v = '${cfg[k] ?? ''}';
      if (v.startsWith('gAAAAA')) return true;
    }
  }
  return false;
}

String? _verifyMigration({
  required String rootDir,
  required String stagingDir,
  required String finalDefaultDir,
  required Map<String, Object?> srcCfg,
  required List<String> copiedFiles,
  required _KeyCarryResult keyCarry,
}) {
  // 1. Every copied file exists in staging with identical length + SHA-256.
  for (final rel in copiedFiles) {
    final srcPath = p.join(rootDir, rel);
    final dstPath = p.join(stagingDir, rel);
    if (!File(dstPath).existsSync()) {
      return "Staged file missing: '$rel'";
    }
    try {
      final srcBytes = File(srcPath).readAsBytesSync();
      final dstBytes = File(dstPath).readAsBytesSync();
      // Note: secret.key written via writeKeyFileDirect trims surrounding ASCII
      // whitespace; compare raw bytes for all regular files, and trimmed bytes
      // for secret.key only if needed.
      if (rel == keyFile && keyCarry.mode == _KeyCarryMode.file) {
        final stagedKey = readKeyFromFileOnly(stagingDir);
        if (stagedKey == null ||
            keyCarry.rootKey == null ||
            !_uint8Equals(stagedKey, keyCarry.rootKey!)) {
          return "Staged '$keyFile' does not match root key.";
        }
      } else {
        if (srcBytes.length != dstBytes.length) {
          return "Byte length mismatch for '$rel' "
              '(${dstBytes.length} != ${srcBytes.length}).';
        }
        final srcHash = sha256.convert(srcBytes).toString();
        final dstHash = sha256.convert(dstBytes).toString();
        if (srcHash != dstHash) {
          return "SHA-256 mismatch for '$rel'.";
        }
      }
    } on Object catch (e) {
      return "Could not verify '$rel': $e";
    }
  }

  // 2. Staged config.json decodes cleanly as a JSON Map.
  try {
    final stagedCfg = jsonDecode(
        File(p.join(stagingDir, 'config.json')).readAsStringSync(encoding: utf8));
    if (stagedCfg is! Map) {
      return 'Staged config.json does not decode as a JSON object.';
    }
  } on Object catch (e) {
    return 'Staged config.json is unreadable: $e';
  }

  // 3. Verify carried key directly (no fallback, never getKey on finalDefaultDir).
  final rootKey = keyCarry.rootKey;
  switch (keyCarry.mode) {
    case _KeyCarryMode.desktopStore:
      if (rootKey == null) return 'Missing root key for desktopStore mode.';
      late final Uint8List? readBack;
      try {
        readBack = readKeyFromStoreOnly(finalDefaultDir);
      } on Object catch (e) {
        return 'Could not read back carried desktop store key: $e';
      }
      if (readBack == null || !_uint8Equals(readBack, rootKey)) {
        return 'Carried OS credential store key does not match root key.';
      }
    case _KeyCarryMode.file:
      if (rootKey == null) return 'Missing root key for file mode.';
      final stagedKey = readKeyFromFileOnly(stagingDir);
      if (stagedKey == null || !_uint8Equals(stagedKey, rootKey)) {
        return 'Staged secret.key does not match root key.';
      }
    case _KeyCarryMode.androidWrapped:
      if (rootKey == null) return 'Missing root key for androidWrapped mode.';
      final bridge = androidKeystoreBridge;
      if (bridge == null || !bridge.available) {
        return 'Android Keystore bridge unavailable during verify.';
      }
      try {
        final stagedText = ascii
            .decode(File(p.join(stagingDir, wrappedFile)).readAsBytesSync())
            .trim();
        final unwrapped = bridge.unwrap(base64.decode(stagedText));
        if (!_uint8Equals(unwrapped, rootKey)) {
          return 'Staged Android wrapped key does not unwrap to root key.';
        }
      } on Object catch (e) {
        return 'Staged Android wrapped key verification failed: $e';
      }
    case _KeyCarryMode.none:
      break;
  }

  // 4. Verify account passwords decrypt with K ALONE (no fallbackKeyDir!).
  final fernet = rootKey != null ? Fernet.fromKeyBytes(rootKey) : null;
  for (final key in const ['bakalari_password', 'strava_password']) {
    if (!isEncryptedFlag(srcCfg['${key}_encrypted'])) continue;
    final token = '${srcCfg[key] ?? ''}';
    if (token.isEmpty) continue;
    if (!_decryptsWithKeyOnly(token, fernet)) {
      return "Account secret '$key' failed to decrypt with carried key alone.";
    }
  }

  // 5. Verify shared gemini_api_key decrypts with rootDir key.
  if (_hasEncryptedGeminiKey(srcCfg)) {
    final token = '${srcCfg['gemini_api_key'] ?? ''}';
    if (!_decryptsWithKeyOnly(token, fernet)) {
      return "Shared 'gemini_api_key' failed to decrypt with root key.";
    }
  }

  return null;
}

bool _decryptsWithKeyOnly(String token, Fernet? fernet) {
  if (fernet != null) {
    try {
      ascii.encode(token);
      utf8.decode(fernet.decryptToken(token));
      return true;
    } on Object {
      // If it looks like a Fernet token, do NOT fall back to legacy XOR.
      if (token.startsWith('gAAAAA')) return false;
    }
  } else if (token.startsWith('gAAAAA')) {
    return false;
  }
  // Legacy XOR ciphertext only.
  try {
    final encrypted = base64.decode(token);
    final keyBytes = utf8.encode(legacyEncryptionKey);
    final plain = List<int>.generate(
        encrypted.length, (i) => encrypted[i] ^ keyBytes[i % keyBytes.length]);
    utf8.decode(plain, allowMalformed: false);
    return true;
  } on Object {
    return false;
  }
}

bool _uint8Equals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// -- Account lifecycle manager (§2.1, §9, §10.3) ---------------------------

/// Mutations on `<rootDir>/accounts.json` and `<rootDir>/accounts/<id>/`.
class AccountManager {
  /// Creates a provisional account with `adding: true` and sets it active.
  static ({AccountRegistry registry, AccountInfo account})
      createProvisionalAccount(
    String rootDir, {
    required int initialWizardStep,
    DateTime? now,
    Random? rng,
  }) {
    final lock = InterProcessLock(p.join(rootDir, '$accountsFile.lock'));
    if (!lock.acquire(timeoutS: 10.0)) {
      throw StateError('accounts.json is locked by another process.');
    }
    try {
      final current = AccountRegistry.load(rootDir, now: now);
      if (current == null) {
        throw StateError('Account registry not initialized.');
      }
      late String newId;
      for (var attempt = 0; attempt < 100; attempt++) {
        final candidate = generateAccountId(rng);
        final dir = accountDirFor(rootDir, candidate);
        if (current.byId(candidate) == null && !Directory(dir).existsSync()) {
          newId = candidate;
          break;
        }
      }
      final newDir = accountDirFor(rootDir, newId);
      Directory(newDir).createSync(recursive: true);
      clearAccountDirDeleted(newDir);
      atomicWriteJson(
        p.join(newDir, 'config.json'),
        <String, Object?>{'wizard_step': initialWizardStep},
      );
      final info = AccountInfo(
        id: newId,
        label: '',
        createdAt: _isoStamp(now ?? clock.now()),
        migrated: false,
        adding: true,
      );
      final next = current.copyWith(
        activeId: newId,
        accounts: [...current.accounts, info],
      );
      atomicWriteJson(p.join(rootDir, accountsFile), next.toJson());
      return (registry: next, account: info);
    } finally {
      lock.release();
    }
  }

  /// Finalizes an `adding: true` account: derives/uniquifies its label and
  /// clears `adding` in one atomic `accounts.json` write (§10.3).
  static AccountRegistry finishAddingAccount(
    String rootDir,
    String accountId, {
    required String fallbackLabel,
    DateTime? now,
  }) {
    final lock = InterProcessLock(p.join(rootDir, '$accountsFile.lock'));
    if (!lock.acquire(timeoutS: 10.0)) {
      throw StateError('accounts.json is locked by another process.');
    }
    try {
      final current = AccountRegistry.load(rootDir, now: now);
      if (current == null) {
        throw StateError('Account registry not initialized.');
      }
      final existing = current.byId(accountId);
      if (existing == null) {
        throw StateError("Account '$accountId' not found.");
      }
      final cfg = _readAccountConfigRaw(rootDir, accountId) ??
          const <String, Object?>{};
      var candidate = deriveAccountLabelFromConfig(cfg);
      if (candidate.isEmpty) candidate = fallbackLabel;
      final unique = uniqueAccountLabel(
        candidate,
        current.accounts,
        excludeId: accountId,
      );
      final updated = [
        for (final acc in current.accounts)
          if (acc.id == accountId)
            acc.copyWith(label: unique, adding: false)
          else
            acc,
      ];
      final next = current.copyWith(accounts: updated);
      atomicWriteJson(p.join(rootDir, accountsFile), next.toJson());
      return next;
    } finally {
      lock.release();
    }
  }

  /// Cancels an unfinished add-account wizard (§10.3).
  ///
  /// Acts ONLY on an account with `adding: true`, holds `<rootDir>/session.lock`,
  /// updates `accounts.json` first, forgets its key, and removes its folder.
  static AccountRegistry cancelAddingAccount(
    String rootDir,
    String accountId, {
    String? returnToId,
    double sessionLockTimeoutS = 120.0,
    DateTime? now,
  }) {
    final pre = AccountRegistry.load(rootDir, now: now);
    if (pre == null) throw StateError('Account registry not initialized.');
    final targetPre = pre.byId(accountId);
    if (targetPre == null || !targetPre.adding) {
      throw StateError(
          "Refusing to cancel account '$accountId': account is not in add mode.");
    }
    if (pre.accounts.length <= 1) {
      throw StateError('Cannot cancel the last remaining account.');
    }

    final sessionLock = InterProcessLock(p.join(rootDir, 'session.lock'));
    if (!sessionLock.acquire(timeoutS: sessionLockTimeoutS)) {
      throw const SessionBusyError(
          'Another operation is running; cannot cancel add-account right now.');
    }
    try {
      final regLock = InterProcessLock(p.join(rootDir, '$accountsFile.lock'));
      if (!regLock.acquire(timeoutS: 10.0)) {
        throw StateError('accounts.json is locked by another process.');
      }
      late final AccountRegistry next;
      try {
        final current = AccountRegistry.load(rootDir, now: now);
        if (current == null) {
          throw StateError('Account registry not initialized.');
        }
        final target = current.byId(accountId);
        if (target == null || !target.adding) {
          throw StateError(
              "Refusing to cancel account '$accountId': account is not in add mode.");
        }
        final remaining = [
          for (final a in current.accounts)
            if (a.id != accountId) a,
        ];
        if (remaining.isEmpty) {
          throw StateError('Cannot cancel the last remaining account.');
        }
        final nextActive = returnToId != null &&
                remaining.any((a) => a.id == returnToId)
            ? returnToId
            : remaining.first.id;
        final nextPrimary = remaining.any((a) => a.id == current.primaryId)
            ? current.primaryId
            : nextActive;
        next = current.copyWith(
          activeId: nextActive,
          primaryId: nextPrimary,
          accounts: remaining,
        );
        atomicWriteJson(p.join(rootDir, accountsFile), next.toJson());
      } finally {
        regLock.release();
      }

      final targetDir = accountDirFor(rootDir, accountId);
      forgetKey(targetDir);
      markAccountDirDeleted(targetDir);
      _deleteAccountDirSafe(rootDir, targetDir);
      return next;
    } finally {
      sessionLock.release();
    }
  }

  /// Sets `active_id` in `accounts.json`.
  static AccountRegistry setActiveAccount(
    String rootDir,
    String accountId, {
    DateTime? now,
  }) {
    final lock = InterProcessLock(p.join(rootDir, '$accountsFile.lock'));
    if (!lock.acquire(timeoutS: 10.0)) {
      throw StateError('accounts.json is locked by another process.');
    }
    try {
      final current = AccountRegistry.load(rootDir, now: now);
      if (current == null) throw StateError('Account registry not initialized.');
      if (current.byId(accountId) == null) {
        throw ArgumentError("Unknown account id: '$accountId'");
      }
      if (current.activeId == accountId) return current;
      final next = current.copyWith(activeId: accountId);
      atomicWriteJson(p.join(rootDir, accountsFile), next.toJson());
      return next;
    } finally {
      lock.release();
    }
  }

  /// Sets `primary_id` in `accounts.json`.
  static AccountRegistry setPrimaryAccount(
    String rootDir,
    String accountId, {
    DateTime? now,
  }) {
    final lock = InterProcessLock(p.join(rootDir, '$accountsFile.lock'));
    if (!lock.acquire(timeoutS: 10.0)) {
      throw StateError('accounts.json is locked by another process.');
    }
    try {
      final current = AccountRegistry.load(rootDir, now: now);
      if (current == null) throw StateError('Account registry not initialized.');
      if (current.byId(accountId) == null) {
        throw ArgumentError("Unknown account id: '$accountId'");
      }
      if (current.primaryId == accountId) return current;
      final next = current.copyWith(primaryId: accountId);
      atomicWriteJson(p.join(rootDir, accountsFile), next.toJson());
      return next;
    } finally {
      lock.release();
    }
  }

  /// Renames [accountId] (trimmed, non-empty, max 60 chars, unique across accounts).
  static AccountRegistry renameAccount(
    String rootDir,
    String accountId,
    String newLabel, {
    DateTime? now,
  }) {
    final trimmed = truncateAccountLabel(newLabel);
    if (trimmed.isEmpty) {
      throw ArgumentError('Account label must not be empty.');
    }
    final lock = InterProcessLock(p.join(rootDir, '$accountsFile.lock'));
    if (!lock.acquire(timeoutS: 10.0)) {
      throw StateError('accounts.json is locked by another process.');
    }
    try {
      final current = AccountRegistry.load(rootDir, now: now);
      if (current == null) throw StateError('Account registry not initialized.');
      if (current.byId(accountId) == null) {
        throw ArgumentError("Unknown account id: '$accountId'");
      }
      final unique = uniqueAccountLabel(
        trimmed,
        current.accounts,
        excludeId: accountId,
      );
      final updated = [
        for (final acc in current.accounts)
          if (acc.id == accountId) acc.copyWith(label: unique) else acc,
      ];
      final next = current.copyWith(accounts: updated);
      atomicWriteJson(p.join(rootDir, accountsFile), next.toJson());
      return next;
    } finally {
      lock.release();
    }
  }

  /// Crash-safe account deletion (§9 steps 2–7).
  ///
  /// The caller must switch away from [targetId] first if it is currently active.
  /// Throws [SessionBusyError] if `<rootDir>/session.lock` is held.
  static ({AccountRegistry registry, bool wasPrimary, String nextPrimaryId})
      deleteAccount(
    String rootDir,
    String targetId, {
    ConfigManager? liveConfigManager,
    DateTime? now,
  }) {
    final sessionLock = InterProcessLock(p.join(rootDir, 'session.lock'));
    if (!sessionLock.acquire(timeoutS: 0)) {
      throw const SessionBusyError(
          'Another operation is running; cannot delete account right now.');
    }
    try {
      final regLock = InterProcessLock(p.join(rootDir, '$accountsFile.lock'));
      if (!regLock.acquire(timeoutS: 10.0)) {
        throw StateError('accounts.json is locked by another process.');
      }
      late final AccountRegistry next;
      late final bool wasPrimary;
      late final String nextPrimaryId;
      try {
        final current = AccountRegistry.load(rootDir, now: now);
        if (current == null) {
          throw StateError('Account registry not initialized.');
        }
        if (current.accounts.length <= 1) {
          throw StateError('Cannot delete the last remaining account.');
        }
        if (current.byId(targetId) == null) {
          throw ArgumentError("Unknown account id: '$targetId'");
        }
        wasPrimary = current.primaryId == targetId;
        final remaining = [
          for (final a in current.accounts)
            if (a.id != targetId) a,
        ];
        final nextActive = current.activeId == targetId
            ? remaining.first.id
            : current.activeId;
        nextPrimaryId = wasPrimary ? nextActive : current.primaryId;
        next = current.copyWith(
          activeId: nextActive,
          primaryId: nextPrimaryId,
          accounts: remaining,
        );
        // Write updated accounts.json FIRST (crash-safe, §9 step 3).
        atomicWriteJson(p.join(rootDir, accountsFile), next.toJson());
      } finally {
        regLock.release();
      }

      final targetDir = accountDirFor(rootDir, targetId);
      // Step 4: Forget encryption key.
      forgetKey(targetDir);
      // Step 5: Refuse any late saves / cache writes to this deleted folder.
      liveConfigManager?.markDeleted();
      markAccountDirDeleted(targetDir);
      // Step 6: Recursively delete ONLY `<rootDir>/accounts/<targetId>/`.
      _deleteAccountDirSafe(rootDir, targetDir);
      return (
        registry: next,
        wasPrimary: wasPrimary,
        nextPrimaryId: nextPrimaryId,
      );
    } finally {
      sessionLock.release();
    }
  }

  /// Forgets the root key AND the key of every folder on disk under
  /// `<rootDir>/accounts/` (registry or not, §5.3).
  static bool forgetAllKeys(String rootDir) {
    var ok = forgetKey(rootDir);
    final accRoot = Directory(accountsRootDir(rootDir));
    if (accRoot.existsSync()) {
      try {
        for (final entity in accRoot.listSync(recursive: false)) {
          if (entity is Directory) {
            final subOk = forgetKey(entity.path);
            ok = ok && subOk;
          }
        }
      } on FileSystemException {
        ok = false;
      }
    }
    return ok;
  }

  static void _deleteAccountDirSafe(String rootDir, String targetDir) {
    final accRoot = accountsRootDir(rootDir);
    final normTarget = p.normalize(p.absolute(targetDir));
    if (!p.isWithin(accRoot, normTarget)) {
      throw StateError(
          "Refusing to delete path outside accounts root: '$normTarget'");
    }
    final dir = Directory(normTarget);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  }
}

String _isoStamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year.toString().padLeft(4, '0')}-${two(dt.month)}-${two(dt.day)}T'
      '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
}
