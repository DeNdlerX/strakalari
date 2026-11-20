// Dev-only dry-run refresh against the Bakalari demo server.
//
// Prints canonical JSON of what a dry-run refresh observed and recorded:
// the audit trail, the Komens outbox, the excuse history and the saved
// cache keys. Run against one server instance, e.g.:
//
//   python tools/bakalari_demo_server.py --port 18080 &
//   dart bin/refresh_dryrun.dart --url http://127.0.0.1:18080 \
//     --data-dir /tmp/dart_dry > /tmp/dart.json
//
// A sibling Python snippet (see the phase-4 report) prints the same JSON;
// the two files must match modulo timestamps. Never sends anything:
// `excuse_mode` is forced to `dry_run` and Strava is disabled.
//
// Opt-in `--send-day DD.MM.YYYY` performs one REAL whole-day submit —
// demo server only, for send-path parity proof.
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:strakalari_core/src/automation/audit.dart';
import 'package:strakalari_core/src/automation/automation.dart';
import 'package:strakalari_core/src/automation/excuse_history.dart';
import 'package:strakalari_core/src/automation/refresh.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/cache.dart';
import 'package:strakalari_core/src/storage/helpers.dart';

/// Recursively sorted copy (map keys as strings, ascending), so the JSON
/// below is canonical no matter what order either side iterated in.
Object? canonical(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      sorted['${entry.key}'] = canonical(entry.value);
    }
    return sorted;
  }
  if (value is List) {
    return [for (final item in value) canonical(item)];
  }
  return value;
}

/// True when [url] targets a loopback host (`127.0.0.1`, `localhost`,
/// `::1` / `[::1]`). `--send-day` is refused for any other host so the
/// CLI can never submit a real excuse to a school server.
bool isLoopbackSendUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !uri.hasScheme || !uri.hasAuthority) return false;
  final host = uri.host.toLowerCase();
  return host == '127.0.0.1' ||
      host == 'localhost' ||
      host == '::1' ||
      host == '[::1]';
}

Future<void> main(List<String> args) async {
  var url = 'http://127.0.0.1:8080';
  var user = 'demo';
  var password = 'demo';
  String? dataDirArg;
  String? sendDay;
  String? todayArg;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--url' && i + 1 < args.length) url = args[++i];
    if (args[i] == '--user' && i + 1 < args.length) user = args[++i];
    if (args[i] == '--password' && i + 1 < args.length) {
      password = args[++i];
    }
    if (args[i] == '--data-dir' && i + 1 < args.length) {
      dataDirArg = args[++i];
    }
    // Opt-in REAL submit of one whole-day excuse (demo server only):
    // `--send-day DD.MM.YYYY` switches excuse_mode to confirm.
    if (args[i] == '--send-day' && i + 1 < args.length) {
      sendDay = args[++i];
    }
    if (args[i] == '--today' && i + 1 < args.length) {
      todayArg = args[++i];
    }
  }
  if (sendDay != null && !isLoopbackSendUrl(url)) {
    throw ArgumentError(
        'Refusing --send-day unless target host is localhost/127.0.0.1/[::1]: $url');
  }
  DateTime? fixedNow;
  if (todayArg != null) {
    final parts = todayArg.split('-').map(int.parse).toList();
    fixedNow = DateTime(parts[0], parts[1], parts[2], 12, 0, 0);
  }
  final dataDir =
      dataDirArg ?? Directory.systemTemp.createTempSync('dart_dry_').path;
  Directory(dataDir).createSync(recursive: true);
  setEnvironmentOverride({
    'STRAKALARI_DATA_DIR': dataDir,
    'STRAKALARI_NO_KEYRING': '1',
  });

  // Production hook defaults (real phase-3 functions) are exercised as-is;
  // tests assign fakes only in the unit suite.

  final config = <String, Object?>{
    'bakalari_url': url,
    'bakalari_username': user,
    'bakalari_password': password,
    'go_back_weeks': 1,
    'go_forward_weeks': 1,
    'excuse_mode': sendDay == null ? 'dry_run' : 'confirm',
    'strava_order_mode': 'confirm',
    'use_strava': false,
  };
  Future<void> runBody() async {
    final app = Strakalari(
        configFile: '$dataDir/config.json', configData: config);
    final result = await runRefresh(app, app.configData);

    // Seed a deterministic unexcused lesson on the latest loaded school
    // day at least 3 days before today so excusePending() exercises
    // generateExcuses + sendExcuse in dry_run mode against the server.
    var pendingSent = 0;
    if (sendDay == null) {
      final now = clock.now();
      final todayD = DateTime(now.year, now.month, now.day);
      final eligibleDays = <(DateTime, String, List<Object?>)>[];
      for (final entry in app.timetableData.entries) {
        final lessons = entry.value;
        if (lessons is! List || lessons.isEmpty) continue;
        DateTime parsed;
        try {
          final p = parseDate(entry.key);
          parsed = DateTime(p.year, p.month, p.day);
        } on Object {
          continue;
        }
        if (daysBetween(parsed, todayD) >= 3) {
          eligibleDays.add((parsed, entry.key, lessons));
        }
      }
      if (eligibleDays.isNotEmpty) {
        eligibleDays.sort((a, b) => b.$1.compareTo(a.$1));
        final firstLesson = eligibleDays.first.$3.first;
        if (firstLesson is Map) {
          firstLesson['absenceType'] = 'Absent';
          firstLesson['absencetext'] = 'neomluveno';
        }
      }
      pendingSent = await app.excusePending();
    }

    // A dry-run one-click excuse for a synthetic past absence (fill only),
    // or a REAL whole-day submit when --send-day is given (demo server only).
    final now = clock.now();
    final past = addDays(DateTime(now.year, now.month, now.day), -5);
    String two(int n) => n.toString().padLeft(2, '0');
    final day = sendDay ??
        '${two(past.day)}.${two(past.month)}.${past.year}';
    final singleOutcome = sendDay == null
        ? await app.excuseSingle({
            'type': 'days and hours',
            'starting_day': day,
            'ending_day': day,
            'starting_lesson': 2,
            'ending_lesson': 4,
          }, 'Omluvte prosim absenci.')
        : await app.excuseSingle({
            'type': 'pure days',
            'starting_day': day,
            'ending_day': day,
          }, 'Omluvenka test');

    final historyFile = app.alreadyExcusedFile;
    List<Object?> history = const [];
    if (File(historyFile).existsSync()) {
      history = jsonDecode(File(historyFile).readAsStringSync()) as List;
    }
    final cache = loadDataCache();
    final data = <String, Object?>{
      'result': {
        'scope': result.scope,
        'bakalari_fetched': result.bakalariFetched,
        'strava_fetched': result.stravaFetched,
        'subjects': result.subjects,
        'menu_days': result.menuDays,
        'excuses_sent': result.excusesSent,
        'excuses_failed': result.excusesFailed,
        'lunches_ordered': result.lunchesOrdered,
        'automation_paused': result.automationPaused,
        'low_balance': result.lowBalance,
        'errors': [for (final e in result.errors) '${e.$1}: ${e.$2}'],
        'news': [for (final n in result.news) '${n.$1}: ${n.$2}'],
        'saved_keys': (result.saved.keys.toList()..sort()),
      },
      'dry_run_pending_sent': pendingSent,
      'dry_run_single_filled': singleOutcome,
      'audit': recent(limit: 2000),
      'outbox': await app.bakalariClient!.fetchSentExcuses(),
      'history': history,
      'sidecar': loadUnconfirmed(historyFile),
      'cache_keys': (cache.keys.toList()..sort()),
      'cache': cache,
    };
    stdout.write('${jsonEncode(canonical(data))}\n');
    app.close();
  }

  if (fixedNow != null) {
    await withClock(Clock.fixed(fixedNow), runBody);
  } else {
    await runBody();
  }
}
