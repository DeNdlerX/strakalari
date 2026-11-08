// Parity fetch: log in to the Bakalari demo server and dump everything.
//
// Dev CLI for phase-2 exit: read-only login, two timetable views, grades,
// absence, substitutions, subjects, the outbox and excuse hours. Run
// against one server instance:
//
//   dart bin/parity_fetch.dart --url http://127.0.0.1:8080 > /tmp/dart.json
//
// tools/parity/fetch.py prints the same JSON; the two files must be
// byte-identical.
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:strakalari_core/strakalari_core.dart';

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

void main(List<String> args) async {
  var url = 'http://127.0.0.1:8080';
  var user = 'demo';
  var password = 'demo';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--url' && i + 1 < args.length) url = args[++i];
    if (args[i] == '--user' && i + 1 < args.length) user = args[++i];
    if (args[i] == '--password' && i + 1 < args.length) {
      password = args[++i];
    }
  }
  final client = BakalariClient({
    'bakalari_url': url,
    'bakalari_username': user,
    'bakalari_password': password,
    'go_back_weeks': 1,
    'go_forward_weeks': 1,
  }, logger: stderr.writeln);
  await client.login();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final monday = today.subtract(Duration(days: today.weekday - 1));
  await client.obtainAbsenceInfo();
  final data = <String, Object?>{
    'timetable_perm': await client.timetableView('perm', monday),
    'timetable_week': await client.timetableView('cal', monday),
    'grades': await client.getGrades(),
    'absence_percentages': client.absencePercentages,
    'absence_details': client.absenceDetails,
    'substitutions': await client.fetchSubstitutions(),
    'subjects': await client.fetchSubjectDirectory(),
    'outbox': await client.fetchSentExcuses(),
    'excuse_hours':
        await client.excuseHours(client.bakalariSession(), monday),
  };
  stdout.write('${jsonEncode(canonical(data))}\n');
  client.close();
}
