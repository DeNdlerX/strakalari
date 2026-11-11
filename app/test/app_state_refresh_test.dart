import 'dart:convert';
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Port of the first-run cases of `AppState._refresh_work`
/// (flet_ui/state_activity.py): without any login the refresh aborts
/// before touching the network and is recorded as a failed run, with no
/// error popup.
void main() {
  late Directory dir;
  late AppState state;
  final jobs = <Future<void> Function()>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('strakalari_state_');
    setEnvironmentOverride({'STRAKALARI_DATA_DIR': dir.path, 'STRAKALARI_NO_KEYRING': '1'});
    jobs.clear();
    state = AppState()..spawn = (job, name) => jobs.add(job);
  });

  tearDown(() {
    setEnvironmentOverride(null);
    dir.deleteSync(recursive: true);
  });

  test('refresh without credentials is a failed run, never a popup', () async {
    expect(state.startRefresh('bogus'), isTrue);
    expect(state.refreshRunning, isTrue);
    expect(state.startRefresh('all'), isFalse); // busy guard
    expect(jobs, hasLength(1));
    await jobs.single();
    expect(state.refreshRunning, isFalse);
    expect(state.runs, hasLength(1));
    expect(state.runs.single['ok'], isFalse);
    expect(state.runs.single['scope'], 'all');
    expect(state.runs.single['cancelled'], isFalse);
    expect(state.errorDialogPending, isFalse);
    expect(state.lastError, isNull);
    // The flight is released: a second refresh may start.
    expect(state.startRefresh('all'), isTrue);
  });

  test('connection test with an unknown service is refused', () {
    expect(state.testConnection('nope'), isFalse);
    expect(jobs, isEmpty);
  });

  test('update check spawns once and guards busy', () {
    expect(state.startUpdateCheck(), isTrue);
    expect(state.startUpdateCheck(), isFalse);
    expect(jobs, hasLength(1));
  });

  // tests/test_wizard_setup.py::test_ai_connection_test_path
  test('aiConnectionTestPath', () async {
    state.geminiTransport = (uri,
        {required headers, body, required timeout}) async {
      expect(headers['x-goog-api-key'], 'AIza-test');
      return GeminiHttpResponse(200, utf8.encode('{"name":"models/x"}'));
    };
    expect(state.testConnection('ai', {'gemini_api_key': 'AIza-test'}), isTrue);
    expect(state.testing, 'ai');
    await jobs.single();
    expect(state.lastTest['service'], 'ai');
    expect(state.lastTest['ok'], isTrue);
    expect(state.testing, '');
  });
}
