import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:strakalari_core/strakalari_core.dart';

import 'package:app/controllers/app_state.dart';
import 'package:app/l10n/strings.dart';

class _CallbackNotifier implements NotifierBackend {
  final void Function(String tag, String body) onNotify;
  _CallbackNotifier(this.onNotify);

  @override
  bool sendNotification({
    required String title,
    required String body,
    required String tag,
  }) {
    onNotify(tag, body);
    return true;
  }
}

class _NewsRefreshApp extends Strakalari {
  Map<String, List<Map<String, Object?>>> testGrades = {};

  _NewsRefreshApp()
      : super(configData: {
          'bakalari_url': 'https://demo',
          'bakalari_username': 'student',
        });

  @override
  Map<String, List<Map<String, Object?>>> get grades => testGrades;

  @override
  Map<String, double> get absencePercentages => {'M': 0.0};

  @override
  Future<void> fetchBakalariData() async {}

  @override
  Future<int> syncWebExcusesToHistory({int? limit}) async => 0;

  @override
  Future<void> fetchStravaData() async {}

  @override
  void close() {}
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app_state_tests_');
    setEnvironmentOverride({
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
    allowMissingKeyStoreForTesting = true;
    clearKeyCache();
  });

  tearDown(() {
    setEnvironmentOverride(null);
    allowMissingKeyStoreForTesting = false;
    clearKeyCache();
    notifierBackend = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('test_excuse_ignore_list (AppState)', () {
    test('ignoreRollsBackWhenSaveFails', () {
      final state = AppState();
      state.config.saveOverride =
          () => throw const FileSystemException('lock busy');
      expect(state.ignoreExcuse('2026-09-01|2|Matematika'), '');
      expect(state.ignoredExcuseKeys, isEmpty);
      expect(state.config.get('ignored_excuses', []), []);
      expect(state.lastIgnoreError, isNotEmpty);
    });

    test('unignoreRollsBackWhenSaveFails', () {
      final state = AppState();
      expect(state.ignoreExcuse('2026-09-01|2|Matematika'),
          '2026-09-01|2|Matematika');
      state.config.saveOverride =
          () => throw const FileSystemException('lock busy');
      expect(state.unignoreExcuse('2026-09-01|2|Matematika'), isFalse);
      expect(state.ignoredExcuseKeys, {'2026-09-01|2|Matematika'});
      expect(state.config.get('ignored_excuses'), ['2026-09-01|2|Matematika']);
    });

    test('ignoreDayRollsBackWhenSaveFails', () {
      final state = AppState();
      final tasks = [
        {'key': '2026-09-01|1|A', 'date': '2026-09-01'},
        {'key': '2026-09-01|2|B', 'date': '2026-09-01'},
      ];
      state.allExcuseTasksOverride = () => tasks;
      state.config.saveOverride =
          () => throw const FileSystemException('lock busy');
      expect(state.ignoreDay('2026-09-01'), isEmpty);
      expect(state.ignoredExcuseKeys, isEmpty);
      expect(state.lastIgnoreError, isNotEmpty);
    });

    test('ignoreSavedNormally', () {
      final state = AppState();
      expect(state.ignoreExcuse('2026-09-01|2|Matematika'),
          '2026-09-01|2|Matematika');
      expect(state.lastIgnoreError, isEmpty);
      expect(state.unignoreKeys(['2026-09-01|2|Matematika']), isTrue);
      expect(state.ignoredExcuseKeys, isEmpty);
    });

    test('ignoreDaySkipsAlreadyExcusedLessons', () {
      final state = AppState();
      final tasks = [
        {
          'key': '2026-09-08|1|M',
          'label': 'M (1.)',
          'date': '2026-09-08',
          'period': 1
        },
        {
          'key': '2026-09-08|2|F',
          'label': 'F (2.)',
          'date': '2026-09-08',
          'period': 2
        },
        {
          'key': '2026-09-08|3|C',
          'label': 'C (3.)',
          'date': '2026-09-08',
          'period': 3
        },
      ];
      state.allExcuseTasksOverride = () => tasks;
      state.markExcused(tasks[0], '', true);
      File(state.config.getAlreadyExcusedPath())
          .writeAsStringSync(jsonEncode([
            {
              'type': 'days and hours',
              'starting_day': '08.09.2026',
              'ending_day': '08.09.2026',
              'starting_lesson': 2,
              'ending_lesson': 2,
            }
          ]));
      final added = state.ignoreDay('2026-09-08');
      expect(added, ['2026-09-08|3|C']);
      expect(state.ignoredExcuseKeys, {'2026-09-08|3|C'});
      expect(state.ignoredTasks().map((t) => t['key']).toList(),
          ['2026-09-08|3|C']);
      state.ignoredExcuseKeys.add('2026-09-08|1|M');
      state.ignoredExcuseKeys.add('2026-09-08|2|F');
      expect(state.ignoredTasks().map((t) => t['key']).toList(),
          ['2026-09-08|3|C']);
    });
  });

  group('test_planned_skips (AppState)', () {
    test('planEntriesSavesAllAtOnce', () {
      final state = AppState();
      final entries = [
        {
          'start_date': '2030-10-07',
          'end_date': '2030-10-08',
          'template': 'a'
        },
        {
          'start_date': '2030-10-10',
          'end_date': '2030-10-10',
          'start_period': 3,
          'template': 'a'
        },
        {
          'start_date': '2030-10-10',
          'end_date': '2030-10-10',
          'start_period': 3,
          'template': 'a'
        }, // duplicate
        {
          'start_date': '2030-10-01',
          'end_date': '2030-11-15',
          'template': 'a'
        }, // > 31 days
      ];
      expect(state.planEntries(entries), 2);
      expect(state.plannedSkips.length, 2);
      expect(state.planEntries(entries.sublist(0, 2)), 0); // already planned
    });

    test('planEntriesRollsBackOnPersistFailure', () {
      final state = AppState();
      state.config.saveOverride =
          () => throw const FileSystemException('disk full');
      expect(
          state.planEntries([
            {
              'start_date': '2030-10-07',
              'end_date': '2030-10-07',
              'template': 'a'
            }
          ]),
          0);
      expect(state.plannedSkips, isEmpty);
    });

    test('planSkipReportsInvalidRange', () {
      final state = AppState();
      expect(state.planSkip('2026-09-08', 'template'), isTrue);
      expect(state.planSkip('not-a-date', 'template'), isFalse);
    });

    test('unplanEntryRollsBackOnPersistFailure', () {
      final state = AppState();
      final entry = {
        'start_date': '2030-10-07',
        'end_date': '2030-10-07',
        'template': 'a'
      };
      expect(state.planEntries([entry]), 1);
      state.config.saveOverride =
          () => throw const FileSystemException('disk full');
      expect(state.unplanEntry(entry), isFalse);
      expect(state.plannedSkips.length, 1);
    });
  });

  group('test_error_report (AppState)', () {
    test('reportErrorQueuesPopupWithTraceback', () {
      final state = AppState();
      state.logLine('[10:00:01] Stahuji data z Bakalářů…');
      const exc = SocketException('login timed out');
      final report = state.reportError('refresh (all)', exc);
      expect(state.lastError, report);
      expect(state.errorDialogPending, isTrue);
      expect(state.status, 'error');
      expect(report['summary'].toString(), contains('SocketException'));
      expect(report['traceback'].toString(), contains('Traceback'));
      final text = state.errorReportText();
      expect(text, contains('operation: refresh (all)'));
      expect(text, contains('Stahuji data'));
    });

    test('reportErrorOutsideHandlerStillSafe', () {
      final state = AppState();
      final report = state.reportError('orders', null, 'empty payload');
      expect(report['traceback'], '');
      expect(state.errorReportText(), contains('no traceback'));
    });

    test('acknowledgeClearsPendingButKeepsReport', () {
      final state = AppState();
      state.reportError('excuse', null, 'nope');
      state.acknowledgeError();
      expect(state.errorDialogPending, isFalse);
      expect(state.errorReportText(), contains('nope'));
    });

    test('timeoutErrorMarksReportFriendly', () {
      final state = AppState();
      const exc = SocketException('Timeout 30000ms exceeded.');
      final report = state.reportError('refresh (all)', exc);
      expect(report['user_message'], timeoutUserMessage());
      expect(report['traceback'].toString(), contains('Traceback'));
    });

    test('reportNeverContainsSecrets', () {
      final state = AppState();
      state.config.data['bakalari_password'] = 'hunter2-hunter2';
      final exc = Exception('boom hunter2-hunter2');
      final report = state.reportError('refresh (all)', exc);
      final text = formatReport(report);
      expect(text, isNot(contains('hunter2-hunter2')));
      expect(text, contains('boom'));
    });

    test('reportLogTailIsContextNotTracebackCopy', () {
      final state = AppState();
      for (var i = 0; i < 80; i++) {
        state.logLine('step $i');
      }
      final report = state.reportError('refresh (all)', Exception('boom'));
      final tail = report['log_tail'] as List;
      expect(tail.length, logTailLines);
      expect(tail.last.toString(), contains('step 79'));
      expect(tail.any((l) => l.toString().contains('Traceback')), isFalse);
      expect(report['traceback'].toString(), contains('Traceback'));
    });
  });

  group('test_cancel_responsive (AppState)', () {
    test('cancelRefreshGivesInstantFeedback', () {
      final state = AppState();
      state.refreshRunning = true;
      state.currentStep = 'Stahuji data z Bakalářů…';
      state.cancelRefresh();
      expect(state.cancelRequested, isTrue);
      expect(state.currentStep, isNot('Stahuji data z Bakalářů…'));
      expect(
          state.logLines.any(
              (l) => l.contains('Rušení') || l.contains('cancelled')),
          isTrue);
    });

    test('cancelRefreshNoopWhenIdle', () {
      final state = AppState();
      state.cancelRefresh();
      expect(state.cancelRequested, isFalse);
      expect(state.logLines, isEmpty);
    });

    test('coreLogNeverReachesTheStatusBar', () {
      final state = AppState();
      state.workerLog('Stahuji data z Bakalářů…');
      state.coreLog('Stable view opened (testid:timetable-permanent-link).');
      expect(state.currentStep, 'Stahuji data z Bakalářů…');
      expect(state.logLines.last, contains('Stable view opened'));
    });

    test('localeFollowsAppLanguage', () {
      final state = AppState();
      state.setLanguage('cs');
      expect(getLanguage(), 'cs');
      expect(Strings.get('absence_title'), 'Absence');
      state.setLanguage('en');
      expect(getLanguage(), 'en');
      expect(Strings.get('absence_title'), 'Absences');
      state.setLanguage('cs');
    });
  });

  group('test_news (AppState)', () {
    test('refreshReportsNewsAgainstTheCache', () async {
      final notified = <(String, String)>[];
      final state = AppState(data: {
        'absence': {'M': 1.0},
        'grades': <String, Object?>{},
      });
      state.config.set('bakalari_username', 'student');
      state.config.set('bakalari_url', 'https://demo');
      state.demoMode = false;
      notifierBackend =
          _CallbackNotifier((tag, body) => notified.add((tag, body)));
      final app = _NewsRefreshApp();
      state.createApp = ({onLog, configData}) => app;
      Future<void>? job;
      state.spawn = (fn, name) {
        job = fn();
      };
      // Save data cache with initial grades
      saveDataCache({
        'grades': {'M': <Object?>[]},
        'absence': {'M': 0.0},
      });
      app.testGrades = {
        'M': [
          {'Id': '7', 'Grade': '1'}
        ]
      };
      state.startRefresh('bakalari');
      await job;
      expect(notified.any((n) => n.$1 == 'new_mark'), isTrue);
    });
  });

  group('test_ui_state (AppState)', () {
    test('setTimetableViewValidation', () {
      final state = AppState();
      state.setTimetableView('nonsense');
      expect(state.timetableView, 'table');
      state.setTimetableView('list');
      expect(state.timetableView, 'list');
    });

    test('goSetsPendingRoute', () {
      final state = AppState();
      state.go('settings');
      expect(state.pendingRoute, 'settings');
    });

    test('startRefreshRejectsBadScopeGracefully', () {
      final state = AppState();
      expect(state.startRefresh('bogus'), isTrue);
      expect(state.startRefresh('all'), isFalse); // busy guard
    });

    test('stateSaveReportsFailure', () {
      final state = AppState();
      state.config.saveOverride =
          () => throw const FileSystemException('disk gone');
      expect(state.save({'a': 1}), isFalse);
    });

    test('subjectStatesEmptyWithoutTimetable', () {
      final state = AppState(data: {});
      final (states, days) = state.subjectStates();
      expect(states, isEmpty);
      expect(days, isEmpty);
    });

    test('needsSetupFalseWithStravaOnly', () {
      final state = AppState();
      state.config.set('strava_username', 'novak');
      state.config.set('strava_password', 'x');
      state.config.set('strava_canteen_id', '123');
      expect(state.needsSetup(), isFalse);
    });

    test('needsSetupTrueWithNothing', () {
      final state = AppState();
      expect(state.needsSetup(), isTrue);
    });
  });

  group('test_automation_safety (AppState)', () {
    test('pauseTogglePersists', () {
      final state = AppState();
      expect(state.automationPaused(), isFalse);
      expect(state.setAutomationPaused(true), isTrue);
      expect(state.automationPaused(), isTrue);
      expect(state.config.get('automation_paused'), isTrue);
    });
  });

  group('test_settings_refresh_interactive (AppState)', () {
    test('workerTickEmitsProgressNotOnChanged', () {
      final state = AppState();
      var changedCount = 0;
      var progressCount = 0;
      state.onChanged = () => changedCount++;
      state.onProgress = () => progressCount++;
      state.workerLog('downloading...');
      expect(changedCount, 0);
      expect(progressCount, 1);
      state.setSettingsSection('limits');
      expect(changedCount, 1);
    });
  });

  group('test_update (AppState)', () {
    test('dismissUpdateAndSetUpdateChannel', () {
      final state = AppState();
      expect(state.updateBanner, isNull);
      state.updateInfo = {
        'version': '9.9.9',
        'url': 'https://example.com/v9.9.9'
      };
      expect(state.updateBanner, isNotNull);
      state.dismissUpdate();
      expect(state.updateBanner, isNull);

      expect(state.updateChannel, 'stable');
      state.setUpdateChannel('beta');
      expect(state.updateChannel, 'beta');
    });
  });
}
