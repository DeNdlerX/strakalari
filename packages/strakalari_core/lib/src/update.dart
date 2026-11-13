// GitHub release check — notifies about newer Strakalari versions.
//
// Port of strakalari/core/update.py. Queries
// ``api.github.com/repos/<owner>/<repo>/releases`` with dart:io only. All
// failures (offline, rate-limited, no releases yet) return null so the UI
// stays silent; update checks must never break the app.
//
// Two update channels (config ``update_channel``, defaulting to the kind of
// build first installed — see [defaultChannel]):
//
// * ``stable`` — only full releases (not marked pre-release on GitHub and
//   without a ``-beta``-style version suffix).
// * ``beta`` — pre-releases *and* full releases, whichever is newest.
//
// The list endpoint is used instead of ``/releases/latest`` because the
// latter never returns pre-releases. Drafts are always skipped.
//
// Results for both channels are cached for 24 h in ``update_cache.json``
// next to the user config so every launch doesn't hit the API and
// switching the channel needs no extra request.
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';

import 'i18n.dart';
import 'storage/helpers.dart';
import 'platform/notifier.dart' as notify_lib;
import 'platform/packaging.dart';

/// Test seam: raw body of the releases list request. Null = real network.
Future<String?> Function(Uri url)? fetchReleasesHook;

/// Build-time version stamped via `--dart-define=STRAKALARI_VERSION=...`
/// (defaults to the current `strakalari/__init__.py` / `app/pubspec.yaml` version).
const String stampedAppVersion = String.fromEnvironment(
  'STRAKALARI_VERSION',
  defaultValue: '0.1.0',
);

/// Currently running application version (defaults to [stampedAppVersion]).
/// Tests override it directly.
String currentAppVersion = stampedAppVersion;

const String githubRepo = 'DeNdlerX/strakalari';
final Uri apiUrl = Uri.parse(
  'https://api.github.com/repos/$githubRepo/releases?per_page=50',
);
const String releasesUrl = 'https://github.com/$githubRepo/releases';
const int checkIntervalS = 24 * 3600;
const String cacheFilename = 'update_cache.json';

const String channelStable = 'stable';
const String channelBeta = 'beta';
const List<String> updateChannels = [channelStable, channelBeta];

/// Anything but ``beta`` (case-insensitive) means ``stable``.
String normalizeChannel(Object? value) =>
    '$value'.trim().toLowerCase() == channelBeta ? channelBeta : channelStable;

/// Channel for a config that has none yet: follows the running build.
///
/// A beta build defaults to ``beta``, a stable one to ``stable``. The
/// config persists the value on its first save, so a user who first
/// installed a beta stays on beta after upgrading to a stable release
/// (and vice versa) until they switch in Settings.
String defaultChannel() =>
    isPrereleaseVersion(getCurrentVersion()) ? channelBeta : channelStable;

/// Single source: the running build's version (stamped by CI at build).
String getCurrentVersion() => currentAppVersion;

/// 'v1.2.3' -> [1, 2, 3]. Non-numeric suffixes are ignored.
List<int> parseVersion(String text) {
  final cleaned = text.trim().replaceFirst(RegExp('^[vV]+'), '');
  final parts = <int>[];
  for (final chunk in cleaned.split(RegExp(r'[.\-+_]'))) {
    final match = RegExp(r'(\d+)').firstMatch(chunk);
    if (match != null) {
      parts.add(int.parse(match.group(1)!));
    } else if (parts.isNotEmpty) {
      break;
    }
  }
  return parts.isEmpty ? [0] : parts;
}

final RegExp _coreRe = RegExp(r'^(\d+(?:\.\d+)*)(.*)$');

/// 'v0.1.0-beta.1+abc' -> ([0, 1, 0], 'beta.1'). Build metadata dropped.
({List<int> core, String pre}) splitVersion(String text) {
  final cleaned = text.trim().replaceFirst(RegExp('^[vV]+'), '').split('+')[0];
  final match = _coreRe.firstMatch(cleaned);
  if (match == null) return (core: [0], pre: '');
  final core = match.group(1)!.split('.').map((p) => int.parse(p)).toList();
  final pre = match.group(2)!.replaceFirst(RegExp(r'^[.\-_]+'), '').trim();
  return (core: core, pre: pre);
}

/// True for 'v0.1.0-beta.1', '1.0.0-rc1' etc.; False for '1.0.0'.
bool isPrereleaseVersion(String text) => splitVersion(text).pre.isNotEmpty;

/// Sortable key with SemVer ordering of pre-releases.
///
/// ``0.1.0-beta.1 < 0.1.0-beta.2 < 0.1.0-rc.1 < 0.1.0 < 0.1.1``; trailing
/// zeros don't matter (``0.1 == 0.1.0``).
VersionKey versionKey(String text) {
  final split = splitVersion(text);
  final padded = List<int>.from(split.core);
  while (padded.length > 1 && padded.last == 0) {
    padded.removeLast();
  }
  if (split.pre.isEmpty) {
    // A final release sorts after every pre-release of the same core.
    return VersionKey(padded, 1, const []);
  }
  final idents = <(int, int, String)>[];
  for (final ident in split.pre.split(RegExp(r'[.\-_]'))) {
    if (ident.isEmpty) continue;
    if (RegExp(r'^\d+$').hasMatch(ident)) {
      idents.add((0, int.parse(ident), ''));
    } else {
      // 'beta2' -> ('beta', 2) so beta10 > beta9.
      final m = RegExp(r'^([A-Za-z]+)(\d+)$').firstMatch(ident);
      if (m != null) {
        idents.add((1, 0, m.group(1)!.toLowerCase()));
        idents.add((0, int.parse(m.group(2)!), ''));
      } else {
        idents.add((1, 0, ident.toLowerCase()));
      }
    }
  }
  return VersionKey(padded, 0, idents);
}

/// Ordering key for [versionKey]: core, then final-over-prerelease flag,
/// then the pre-release identifiers.
class VersionKey implements Comparable<VersionKey> {
  final List<int> core;
  final int release;
  final List<(int, int, String)> idents;

  const VersionKey(this.core, this.release, this.idents);

  @override
  int compareTo(VersionKey other) {
    for (var i = 0; i < core.length && i < other.core.length; i++) {
      if (core[i] != other.core[i]) return core[i].compareTo(other.core[i]);
    }
    if (core.length != other.core.length) {
      return core.length.compareTo(other.core.length);
    }
    if (release != other.release) return release.compareTo(other.release);
    for (var i = 0; i < idents.length && i < other.idents.length; i++) {
      final a = idents[i];
      final b = other.idents[i];
      if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      if (a.$3 != b.$3) return a.$3.compareTo(b.$3);
    }
    return idents.length.compareTo(other.idents.length);
  }
}

/// True when [latest] is a higher version than [current].
bool isNewer(String latest, String current) {
  try {
    return versionKey(latest).compareTo(versionKey(current)) > 0;
  } catch (_) {
    return false;
  }
}

/// GitHub release JSON -> the small dict the UI and cache use.
Map<String, Object?>? releaseInfo(Map<String, Object?>? payload) {
  if (payload == null) return null;
  final tag = '${payload['tag_name'] ?? ''}'.trim();
  if (tag.isEmpty) return null;
  final url = '${payload['html_url'] ?? releasesUrl}'.trim();
  final version = tag.replaceFirst(RegExp('^[vV]+'), '');
  return {
    'version': version,
    'tag': tag,
    'url': url.isEmpty ? releasesUrl : url,
    'name': '${payload['name'] ?? tag}',
    'published_at': '${payload['published_at'] ?? ''}',
    'prerelease':
        (payload['prerelease'] == true) || isPrereleaseVersion(version),
    'draft': payload['draft'] == true,
  };
}

/// Newest release relevant to [channel] (drafts never count).
Map<String, Object?>? pickRelease(
  List<Object?>? releases, [
  String channel = channelStable,
]) {
  final beta = normalizeChannel(channel) == channelBeta;
  Map<String, Object?>? best;
  for (final payload in releases ?? const []) {
    final info = payload is Map
        ? releaseInfo(Map<String, Object?>.from(payload))
        : null;
    if (info == null || info['draft'] == true) continue;
    if (info['prerelease'] == true && !beta) continue;
    if (best == null || isNewer('${info['version']}', '${best['version']}')) {
      best = info;
    }
  }
  return best;
}

Future<String?> _httpGetBody(Uri url, Duration timeout) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url).timeout(timeout);
    request.headers.set(HttpHeaders.userAgentHeader, 'Strakalari-UpdateCheck');
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/vnd.github+json',
    );
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode ~/ 100 != 2) return null;
    return body;
  } finally {
    client.close();
  }
}

/// Raw release list from GitHub (newest first). Null on any failure.
Future<List<Object?>?> fetchReleases({
  Duration timeout = const Duration(seconds: 30),
}) async {
  try {
    final hook = fetchReleasesHook;
    final body = hook != null
        ? await hook(apiUrl)
        : await _httpGetBody(apiUrl, timeout);
    if (body == null) return null;
    final payload = jsonDecode(body);
    return payload is List ? List<Object?>.from(payload) : null;
  } catch (_) {
    return null;
  }
}

/// Newest release for [channel]. Returns None on any failure.
Future<Map<String, Object?>?> fetchLatestRelease([
  String channel = channelStable,
  Duration timeout = const Duration(seconds: 30),
]) async {
  final releases = await fetchReleases(timeout: timeout);
  if (releases == null) return null;
  final info = pickRelease(releases, channel);
  if (info != null) {
    info['checked_at'] = clock.now().millisecondsSinceEpoch / 1000.0;
  }
  return info;
}

String cachePath() {
  try {
    return resolvePath(cacheFilename);
  } catch (_) {
    return cacheFilename;
  }
}

/// ``{"checked_at": ts, "channels": {"stable": info|None, ...}}``.
///
/// Anything else (missing, corrupt, the pre-channel single-release
/// format) is null, which simply triggers a fresh check.
Map<String, Object?>? _loadCacheFile() {
  final path = cachePath();
  try {
    final file = File(path);
    if (!file.existsSync()) return null;
    final data = jsonDecode(file.readAsStringSync(encoding: utf8));
    if (data is Map && data['channels'] is Map) {
      return Map<String, Object?>.from(data);
    }
    return null;
  } on FormatException {
    try {
      quarantineCorruptFile(path);
    } catch (_) {}
    return null;
  } on FileSystemException {
    try {
      quarantineCorruptFile(path);
    } catch (_) {}
    return null;
  } catch (_) {
    return null;
  }
}

/// Last known release for [channel] (may be stale) or null.
///
/// Store builds always return null (see [updatesManagedExternally]).
Map<String, Object?>? loadCached([String channel = channelStable]) {
  if (updatesManagedExternally()) return null;
  final cache = _loadCacheFile();
  if (cache == null) return null;
  final channels = cache['channels'];
  if (channels is! Map) return null;
  final info = channels[normalizeChannel(channel)];
  if (info is Map &&
      Map<String, Object?>.from(info)['version'].toString().isNotEmpty) {
    return Map<String, Object?>.from(info);
  }
  return null;
}

void saveCached(
  Map<String, Map<String, Object?>?> channels, {
  double? checkedAt,
}) {
  try {
    atomicWriteJson(cachePath(), {
      'checked_at': checkedAt ?? clock.now().millisecondsSinceEpoch / 1000.0,
      'channels': {for (final c in updateChannels) c: channels[c]},
      // Kept across checks: see claimUpdateNotice.
      'notified': '${(_loadCacheFile() ?? {})['notified'] ?? ''}',
    });
  } catch (_) {}
}

/// True once per release newer than the running app: whether to notify
/// about [info]. The tray and the window share it through the update
/// cache file (not the data cache: that would make an empty one look
/// fresh). Never raises.
bool claimUpdateNotice(Map<String, Object?>? info) {
  if (!updateAvailable(info)) return false;
  final version = '${info!['version'] ?? ''}';
  try {
    final cache = _loadCacheFile() ?? {'checked_at': 0, 'channels': {}};
    if (cache['notified'] == version) return false;
    cache['notified'] = version;
    atomicWriteJson(cachePath(), cache);
  } catch (_) {
    return false;
  }
  return true;
}

/// Announces [info] with a notification, once per release. Never raises.
bool notifyNewRelease(
  Map<String, Object?>? info, [
  Map<String, Object?>? prefs,
]) {
  if (!claimUpdateNotice(info)) return false;
  try {
    return notify_lib.notify(
      'update_available',
      t('update_available_notice', args: {'version': info!['version']}),
      prefs,
    );
  } catch (_) {
    return false;
  }
}

/// True when there is no cache or it is older than 24 h.
bool shouldCheck(Map<String, Object?>? cached, {DateTime? now}) {
  if (cached == null) return true;
  final checkedAt = double.tryParse('${cached['checked_at'] ?? ''}');
  if (checkedAt == null) return true;
  final current =
      now?.millisecondsSinceEpoch ?? clock.now().millisecondsSinceEpoch;
  return current / 1000.0 - checkedAt >= checkIntervalS;
}

/// True when updates come from a store (Microsoft Store, Google Play,
/// App Store), not GitHub.
///
/// Store builds must never check GitHub releases or offer downloads:
/// updates (including certification) are owned by the store. The
/// Android APK is sideloaded from GitHub, so it keeps the check.
bool updatesManagedExternally() {
  try {
    return isStorePackage() || mobileStore() != null;
  } catch (_) {
    return false;
  }
}

/// Returns cached-or-fresh release info for [channel], or null.
///
/// With [force]=false a fresh cache (< 24 h) is returned without any
/// network call. One request refreshes both channels. Failures keep the
/// stale cache so the banner can still show a previously seen release.
///
/// Store builds always return null (see [updatesManagedExternally]).
Future<Map<String, Object?>?> checkForUpdates({
  bool force = false,
  String channel = channelStable,
}) async {
  if (updatesManagedExternally()) return null;
  channel = normalizeChannel(channel);
  final cache = _loadCacheFile();
  if (!force && cache != null && !shouldCheck(cache)) {
    return loadCached(channel);
  }
  final releases = await fetchReleases();
  if (releases == null) return loadCached(channel);
  final now = clock.now().millisecondsSinceEpoch / 1000.0;
  final picks = <String, Map<String, Object?>?>{};
  for (final name in updateChannels) {
    final info = pickRelease(releases, name);
    if (info != null) info['checked_at'] = now;
    picks[name] = info;
  }
  saveCached(picks, checkedAt: now);
  return picks[channel];
}

/// True when [info] names a release newer than the running app.
bool updateAvailable(Map<String, Object?>? info, {String? current}) {
  if (info == null) return false;
  return isNewer('${info['version'] ?? ''}', current ?? getCurrentVersion());
}
