// Structured error reports with secrets redacted.
//
// Port of strakalari/core/error_report.py. When a background operation
// (refresh, excuse submit, lunch order, view render) fails, the UI shows
// a popup with a "copy log" button. The copied text must let us identify
// the bug without leaking credentials — that is what this module builds:
//
// * the exception type + message + full stack trace,
// * environment context (app version, build kind, OS, Dart),
// * the tail of the in-memory log (what the app was doing),
// * which config values are filled in (key names + set/empty only —
//   values never leave the machine).
//
// Phase 2 landed the foundation the HTTP session needs ([UserError],
// [timeoutUserMessage]); phase 4 ports the redaction and report builders.
import 'dart:async';
import 'dart:io';

import 'package:clock/clock.dart';

import 'i18n.dart';
import 'storage/config.dart';
import 'storage/helpers.dart';
import 'update.dart' show getCurrentVersion;

/// A failure the user can fix themselves (missing URL, bad login, ...).
class UserError implements Exception {
  final String message;

  /// The transport error that caused this failure, if any (lets the
  /// excuse post tell "certainly never sent" from "maybe sent").
  final Object? cause;

  const UserError(this.message, [this.cause]);

  @override
  String toString() => 'UserError: $message';
}

/// Friendly fix-it text for timeouts (slow/unstable connection).
String timeoutUserMessage() => t('error_timeout');

/// Marker replacing every secret value in reports and pasted logs.
const String redacted = '***';

/// Config keys containing any of these markers hold secrets.
const List<String> secretMarkers = [
  'password',
  'passwd',
  'api_key',
  'apikey',
  'token',
  'secret',
];

/// How much of the live log travels with the report.
const int logTailLines = 60;

/// Single log lines longer than this are truncated in the report.
const int maxLineChars = 500;

/// Exception type names that always mean "the page never loaded in time".
const Set<String> timeoutTypeNames = {'TimeoutError', 'TimeoutExpired'};

/// Message fragments (lowercased) identifying a wait that ran out of time.
const List<String> timeoutMessageHints = [
  'timeout',
  'timed out',
  'exceeded',
  'time-out',
  'vypršel',
  'vyprsel',
];

/// Config keys whose values identify the student (not secrets, but
/// personal data that has no business in a pasted bug report).
const List<String> personalKeys = [
  'bakalari_username',
  'strava_username',
  'strava_user',
  'your_signature',
];

/// True when [exc] is a load/wait timeout (slow connection), not a bug.
///
/// Covers [TimeoutException] and anything whose message says the wait
/// ran out (`Timeout 30000ms exceeded`, `timed out`). [UserError] is
/// never a timeout — callers branch on those first. Never raises.
///
/// Deviation: Python also excludes `InterruptedError`/`KeyboardInterrupt`;
/// Dart core has no such exception type, so cancellation surfaces as a
/// plain message (which carries no timeout hint either way).
bool isTimeoutError(Object? exc) {
  if (exc == null) return false;
  try {
    if (exc is UserError) return false;
    if (exc is TimeoutException) return true;
    if (timeoutTypeNames.contains(exc.runtimeType.toString())) return true;
    final text = '$exc'.toLowerCase();
    return timeoutMessageHints.any(text.contains);
  } catch (_) {
    return false;
  }
}

bool _isSecretKey(String key) {
  final lowered = key.toLowerCase();
  return secretMarkers.any(lowered.contains);
}

/// True when a config value counts as unset (nothing to leak).
bool _isEmptyValue(Object? value) {
  if (value == null) return true;
  if (value is bool) {
    return false; // False is a real choice, not an empty value.
  }
  if (value is String) return value.isEmpty;
  if (value is Iterable) return value.isEmpty;
  if (value is Map) return value.isEmpty;
  return false;
}

/// Maps [config] to `{key: "set" | "empty"}` — values never leave the machine.
///
/// Key names alone tell which integrations are configured (e.g. Strava
/// vs. Bakalari-only); the actual values (usernames, URLs, passwords,
/// excuse texts, signatures) are not needed to fix a bug and stay private.
Map<String, String> redactConfig(Map<String, Object?>? config) {
  final out = <String, String>{};
  for (final entry in (config ?? const <String, Object?>{}).entries) {
    out[entry.key] = _isEmptyValue(entry.value) ? 'empty' : 'set';
  }
  return out;
}

/// Every config value that must never appear in a report.
///
/// Secrets are stored encrypted, so the ciphertext alone would never
/// match a leaked plaintext password (e.g. echoed in an exception
/// text) — the decrypted value is scrubbed too. The signature (usually
/// the student's name) is also scrubbed word by word.
Set<String> _sensitiveValues(Map<String, Object?>? config) {
  final values = <String>{};
  final cfg = config ?? const <String, Object?>{};
  for (final entry in cfg.entries) {
    final key = entry.key;
    final value = entry.value;
    // Booleans choose, collections never match a secret text, numeric
    // zero is falsy in Python too: none of them leak a password.
    if (value == null || value is bool) continue;
    if (value is Map || value is Iterable) continue;
    if (value is num && value == 0) continue;
    final text = '$value';
    if (text.isEmpty) continue;
    if (_isSecretKey(key)) {
      values.add(text);
      if (cfg['${key}_encrypted'] == true) {
        try {
          final plain = decryptStrict(text);
          if (plain != null && plain.isNotEmpty) values.add(plain);
        } catch (_) {
          // Ciphertext still scrubbed.
        }
      }
    } else if (personalKeys.contains(key)) {
      final trimmed = text.trim();
      if (trimmed.isEmpty) continue;
      values.add(trimmed);
      if (key == 'your_signature') {
        values.addAll(trimmed
            .replaceAll(',', ' ')
            .split(' ')
            .where((w) => w.length >= 3));
      }
    }
  }
  values.remove('');
  return values;
}

/// Only the secrets (passwords, API keys) of [config], ciphertext and plaintext.
///
/// For the local `log.txt`: it stays on the user's machine, so names
/// and usernames may stay in it, but a password must never be written
/// to disk in the clear.
Set<String> secretValues(Map<String, Object?>? config) {
  final cfg = config ?? const <String, Object?>{};
  return _sensitiveValues({
    for (final entry in cfg.entries)
      if (_isSecretKey(entry.key) || entry.key.endsWith('_encrypted'))
        entry.key: entry.value,
  });
}

/// Replaces every value of [values] in [text] with the redaction marker.
///
/// Long secrets match as substrings (longest first so overlapping values
/// redact cleanly). Short secrets (PINs) only match on token boundaries —
/// a blanket substring replace of a 1-3 char value would nuke ordinary
/// prose. (Python uses `(?<!\S)…(?!\S)` lookarounds; Dart matches whole
/// whitespace-delimited tokens instead — same boundary semantics.)
String redactValues(String text, Set<String> values) {
  var out = text;
  final long = values.where((s) => s.length >= 4).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final short = values.where((s) => s.isNotEmpty && s.length < 4).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final secret in long) {
    if (out.contains(secret)) out = out.replaceAll(secret, redacted);
  }
  if (short.isNotEmpty) {
    final shorts = Set<String>.of(short);
    out = out.splitMapJoin(RegExp(r'\S+'),
        onMatch: (m) =>
            shorts.contains(m.group(0)) ? redacted : m.group(0)!);
  }
  return out;
}

/// Scrubs known secret and personal *values* out of free text (tracebacks, logs).
String redactText(String text, [Map<String, Object?>? config]) =>
    redactValues(text, _sensitiveValues(config));

/// [redactText] against the config on disk, for code with no config at hand.
///
/// Used before tracebacks go to the log (the scheduler): an exception
/// text can echo a password. Never raises.
String redactWithSavedConfig(String text) {
  Map<String, Object?>? config;
  try {
    config = ConfigManager().data;
  } catch (_) {
    config = null; // No config means no known secrets.
  }
  try {
    return redactText(text, config);
  } catch (_) {
    return '(redaction failed, details withheld)';
  }
}

/// One-line human summary: `TypeName: first line`.
String shortSummary([Object? error, String message = '', int limit = 200]) {
  final String text;
  if (error != null) {
    text = '${error.runtimeType}: $error'.trim();
  } else {
    text = message.trim();
  }
  final first = text.isEmpty ? '' : text.split('\n').first;
  final cut = first.length > limit ? first.substring(0, limit) : first;
  final out = cut.trim();
  return out.isEmpty ? 'unknown error' : out;
}

/// The caught failure and stack trace, or `""` when called without either.
///
/// Deviation: Python reads the active exception via
/// `traceback.format_exc()`; Dart has no ambient trace, so callers pass
/// the caught error and `StackTrace` explicitly (`catch (e, st)`). The
/// `Traceback (most recent call last):` header is kept so report shapes
/// (and their tests) match Python; the frames below it are Dart `#0`
/// style instead of `File … line …` style.
String currentTraceback([Object? error, StackTrace? stackTrace]) {
  if (error == null && stackTrace == null) return '';
  try {
    return formatTraceback(error, stackTrace);
  } catch (_) {
    return '';
  }
}

/// Formats [error] plus [stackTrace] the way `traceback.format_exc()`
/// does: header, frames, then `Type: message`.
String formatTraceback(Object? error, [StackTrace? stackTrace]) {
  final frames = stackTrace?.toString().trim() ?? '';
  final tail = error == null ? '' : '${error.runtimeType}: $error';
  final body = [
    if (frames.isNotEmpty) frames,
    if (tail.isNotEmpty) tail,
  ].join('\n');
  if (body.isEmpty) return '';
  return 'Traceback (most recent call last):\n$body';
}

/// Environment block: version, build kind, OS, Dart, UI language.
Map<String, Object?> collectContext() {
  String version;
  try {
    version = getCurrentVersion();
  } catch (_) {
    version = '?';
  }
  String language;
  try {
    language = getLanguage();
  } catch (_) {
    language = '?';
  }
  return {
    'app_version': version,
    // Installer/release AOT build vs. a debug/source run.
    'build': const bool.fromEnvironment('dart.vm.product')
        ? 'installer'
        : 'source',
    'platform': Platform.operatingSystemVersion,
    // Python names this key "python" with `sys.version`; the runtime
    // here is Dart.
    'dart': Platform.version.split(' ').first,
    'language': language,
  };
}

String _truncateLine(String line) =>
    line.length > maxLineChars ? line.substring(0, maxLineChars) : line;

/// Assembles the report dict stored on the error popup.
Map<String, Object?> buildReport(
  String operation,
  String summary, {
  String tracebackStr = '',
  List<Object?>? logTail,
  Map<String, Object?>? config,
  Map<String, Object?>? extra,
  String userMessage = '',
}) {
  final all = logTail ?? const <Object?>[];
  final tail = all.length > logTailLines
      ? all.sublist(all.length - logTailLines)
      : all;
  final cleanSummary = summary.isEmpty ? 'unknown error' : summary;
  // Extra values are free text too (labels, day counts) — scrub any secret
  // that ended up in them before the report is stored or pasted.
  var safeExtra = <String, Object?>{};
  try {
    for (final entry in (extra ?? const <String, Object?>{}).entries) {
      safeExtra[entry.key] = redactText('${entry.value}', config);
    }
  } catch (_) {
    safeExtra = {};
  }
  final now = clock.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return {
    'at': '${two(now.day)}.${two(now.month)}.${now.year} '
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
    'operation': operation.isEmpty ? '?' : operation,
    'summary': redactText(cleanSummary, config),
    'traceback': redactText(tracebackStr.trim(), config),
    'log_tail': [
      for (final line in tail) redactText(_truncateLine('$line'), config)
    ],
    'config': redactConfig(config),
    'context': collectContext(),
    'extra': safeExtra,
    // Friendly fix-it text for user-fixable failures ("") for real bugs.
    'user_message': redactText(userMessage.trim(), config),
  };
}

/// Renders the report as copy-pasteable plain text.
String formatReport(Map<String, Object?>? report) {
  if (report == null || report.isEmpty) return '';
  final lines = <String>[
    'Strakalari error report',
    "time: ${report['at'] ?? '?'}",
    "operation: ${report['operation'] ?? '?'}",
    "error: ${report['summary'] ?? '?'}",
  ];
  final context = report['context'];
  if (context is Map && context.isNotEmpty) {
    lines.add(
        "environment: ${context.entries.map((e) => '${e.key}=${e.value}').join(', ')}");
  }
  final extra = report['extra'];
  if (extra is Map && extra.isNotEmpty) {
    lines.add(
        "details: ${extra.entries.map((e) => '${e.key}=${e.value}').join(', ')}");
  }
  final tb = '${report['traceback'] ?? ''}'.trim();
  lines.add('traceback:');
  lines.add(tb.isEmpty ? '(no traceback captured)' : tb);
  final tail = report['log_tail'];
  final tailLines = tail is List ? tail : const <Object?>[];
  lines.add('recent log (${tailLines.length} lines):');
  for (final line in tailLines) {
    lines.add('$line');
  }
  final config = report['config'];
  if (config is Map && config.isNotEmpty) {
    lines.add('config (values hidden, filled status only):');
    final byName = <String, Object?>{
      for (final e in config.entries) '${e.key}': e.value
    };
    final keys = byName.keys.toList()..sort();
    for (final key in keys) {
      lines.add('  $key=${byName[key]}');
    }
  }
  return '${lines.join('\n').trim()}\n';
}
