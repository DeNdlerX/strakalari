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

import 'package:strakalari_core/src/automation/audit.dart';
import 'package:strakalari_core/src/automation/automation.dart';
import 'package:strakalari_core/src/automation/refresh.dart';
import 'package:strakalari_core/src/platform/packaging.dart';
import 'package:strakalari_core/src/storage/cache.dart';

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

Future<void> main(List<String> args) async {
  var url = 'http://127.0.0.1:8080';
  var user = 'demo';
  var password = 'demo';
  var dataDir = Directory.systemTemp.createTempSync('dart_dry_').path;
  String? sendDay;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--url' && i + 1 < args.length) url = args[++i];
    if (args[i] == '--user' && i + 1 < args.length) user = args[++i];
    if (args[i] == '--password' && i + 1 < args.length) {
      password = args[++i];
    }
    if (args[i] == '--data-dir' && i + 1 < args.length) {
      dataDir = args[++i];
    }
    // Opt-in REAL submit of one whole-day excuse (demo server only):
    // `--send-day DD.MM.YYYY` switches excuse_mode to confirm.
    if (args[i] == '--send-day' && i + 1 < args.length) {
      sendDay = args[++i];
    }
  }
  Directory(dataDir).createSync(recursive: true);
  setEnvironmentOverride({'STRAKALARI_DATA_DIR': dataDir});

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
  final app = Strakalari(
      configFile: '$dataDir/config.json', configData: config);
  final result = await runRefresh(app, app.configData);

  // A dry-run one-click excuse for a synthetic past absence (fill only),
  // or a REAL whole-day submit when --send-day is given (demo server only).
  final past = DateTime.now().subtract(const Duration(days: 5));
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
    'dry_run_single_filled': singleOutcome,
    'audit': recent(limit: 2000),
    'outbox': await app.bakalariClient!.fetchSentExcuses(limit: 100),
    'history': history,
    'cache_keys': (loadDataCache().keys.toList()..sort()),
  };
  stdout.write('${jsonEncode(canonical(data))}\n');
  app.close();
}
