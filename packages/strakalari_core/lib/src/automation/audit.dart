// Automation history: every excuse send and lunch order attempt.
//
// Port of strakalari/core/audit.py. An append-only JSON-lines file
// (`automation_history.jsonl` in the data dir) with one record per
// attempt. Records hold dates, lesson numbers and meal ids only — never
// credentials, excuse texts or page content. Writing never raises: a
// broken history file must not block a send.
//
// Python guards appends with a thread lock; Dart runs one event loop per
// isolate, so synchronous file writes need no lock.
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:path/path.dart' as p;

import '../storage/accounts.dart' show isAccountDirDeleted, requirePerAccountDir;
import '../storage/helpers.dart';

/// History file name, resolved against the user data dir.
const String historyFile = './automation_history.jsonl';

/// Rotation threshold: the file restarts once it passes this size.
const int maxBytes = 1024 * 1024;

/// Record kinds.
const List<String> kinds = ['excuse', 'lunch'];

/// `sent` = submitted to the site, `dry_run` = simulated only,
/// `covered` = not sent because the history already covers it,
/// `skipped` = not attempted (closed day, not on the menu, …),
/// `unconfirmed` = submitted, but the site never confirmed it (it may
/// have gone out; re-sends stay blocked until the Komens outbox shows),
/// `failed` = attempted and not confirmed by the site.
const List<String> outcomes = [
  'sent',
  'dry_run',
  'covered',
  'skipped',
  'unconfirmed',
  'failed'
];

/// Resolved history file path.
String historyPath({String? dataDir}) =>
    resolvePath(historyFile, requirePerAccountDir(dataDir));

String _two(int n) => n.toString().padLeft(2, '0');

/// Local timestamp like Python's `isoformat(timespec="seconds")`.
String _stamp(DateTime now) =>
    '${now.year}-${_two(now.month)}-${_two(now.day)}T'
    '${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}';

String _truncate(String text, int maxRunes) {
  if (text.runes.length <= maxRunes) return text;
  return String.fromCharCodes(text.runes.take(maxRunes));
}

/// Appends one record. Returns false (and prints why) when it could not.
bool record(String kind, String outcome, String source, String summary,
    {Map<String, Object?>? detail, DateTime? now, String? dataDir}) {
  final dir = requirePerAccountDir(dataDir);
  if (isAccountDirDeleted(dir)) {
    print("Warning: Account folder '$dir' was deleted; skipping audit write.");
    return false;
  }
  final entry = <String, Object?>{
    'ts': _stamp(now ?? clock.now()),
    'kind': kind,
    'outcome': outcome,
    'source': source == 'auto' ? 'auto' : 'manual',
    'summary': _truncate(summary, 300),
  };
  if (detail != null && detail.isNotEmpty) {
    entry['detail'] = detail;
  }
  final path = historyPath(dataDir: dir);
  try {
    final line = toPlatformNewlines('${pyJsonDumps(entry)}\n');
    _rotateIfLarge(path);
    Directory(p.dirname(p.absolute(path))).createSync(recursive: true);
    File(path).writeAsStringSync(line, mode: FileMode.append, encoding: utf8);
    return true;
  } on Object catch (exc) {
    // Never block a send on the audit trail.
    print('Warning: could not write automation history '
        "'$path': ${exc.runtimeType}: $exc");
    return false;
  }
}

/// Restarts the file once it passes [maxBytes]; appending is always fine.
void _rotateIfLarge(String path) {
  try {
    if (!File(path).existsSync() || File(path).lengthSync() <= maxBytes) {
      return;
    }
  } on FileSystemException {
    return;
  }
  final token = tryFileLock('$path.lock');
  if (token == null) {
    // The other process is rotating; appending is still fine.
    return;
  }
  try {
    File(path).renameSync('$path.old');
  } on FileSystemException catch (exc) {
    print('Warning: could not rotate automation history: $exc');
  } finally {
    releaseFileLock(token);
  }
}

/// The newest [limit] records, newest first. Unreadable lines are skipped.
List<Map<String, Object?>> recent({int limit = 50, String? dataDir}) {
  final path = historyPath(dataDir: dataDir);
  if (!File(path).existsSync()) return [];
  late final List<String> lines;
  try {
    lines = File(path).readAsLinesSync(encoding: utf8);
  } on FileSystemException catch (exc) {
    print('Warning: could not read automation history: $exc');
    return [];
  }
  final out = <Map<String, Object?>>[];
  final cap = limit < 0 ? 0 : limit;
  for (final raw in lines.reversed) {
    late final Object? item;
    try {
      item = jsonDecode(raw);
    } on FormatException {
      continue;
    }
    if (item is Map) {
      out.add(item.map((k, v) => MapEntry('$k', v as Object?)));
    }
    if (out.length >= cap) break;
  }
  return out;
}

/// True when at least one dry run of [kind] completed successfully.
bool hasDryRun(String kind, {String? dataDir}) =>
    recent(limit: 2000, dataDir: dataDir)
        .any((item) => item['kind'] == kind && item['outcome'] == 'dry_run');

/// Short, text-free label of an excuse range (no excuse wording).
String describeExcuse(Map<String, Object?> excuse) {
  final start = '${excuse['starting_day'] ?? '?'}';
  final end = '${excuse['ending_day'] ?? start}';
  final days = start == end ? start : '$start – $end';
  final first = excuse['starting_lesson'];
  final last = excuse['ending_lesson'];
  if (first == null) return days;
  final lessons =
      first == last || last == null ? '$first.' : '$first.–$last.';
  return '$days ($lessons)';
}
