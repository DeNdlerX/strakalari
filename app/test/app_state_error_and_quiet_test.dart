import 'dart:async';
import 'dart:io';

import 'package:app/controllers/app_state.dart';
import 'package:app/shell/scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:strakalari_core/strakalari_core.dart';

/// Checkpoint B BR3-M3: the `AppState` cases of `tests/test_error_report.py`
/// and `tests/test_settings_quiet_save.py` that had no Dart test.
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('app_state_error_quiet_');
    setEnvironmentOverride({
      ...Platform.environment,
      'STRAKALARI_DATA_DIR': tmp.path,
      'STRAKALARI_NO_KEYRING': '1',
    });
  });

  tearDown(() {
    setEnvironmentOverride(null);
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A lock file may still be open on Windows.
    }
  });

  group('test_error_report.py (AppState)', () {
    // test_user_error_marks_report_friendly
    test('userErrorMarksReportFriendly', () {
      final state = AppState();
      final report = state.reportError(
          'refresh (all)',
          UserError('Chybí URL Bakalářů — doplňte ho v Nastavení.'));
      expect(report['user_message'],
          'Chybí URL Bakalářů — doplňte ho v Nastavení.');
      // Diagnostics are still built for the copy button.
      expect(report['traceback'].toString(), contains('Traceback'));
    });

    // test_regular_error_has_no_user_message
    test('regularErrorHasNoUserMessage', () {
      final state = AppState();
      final report = state.reportError('refresh (all)', StateError('boom'));
      expect('${report['user_message'] ?? ''}', '');
    });

    // test_report_is_persisted_redacted_to_stderr
    test('reportIsPersistedRedactedToStderr', () {
      final state = AppState();
      state.config.data['bakalari_password'] = 'hunter2secret';
      final printed = <String>[];
      runZoned(
        () => state.reportError(
            'excuse', StateError('fill failed: hunter2secret')),
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
      final out = printed.join('\n');
      expect(out, contains('Error report:'));
      expect(out, contains('operation: excuse'));
      expect(out, isNot(contains('hunter2secret')));
    });

    // test_shell_pops_queued_error_once
    testWidgets('shellPopsQueuedErrorOnce', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final state = container.read(appStateProvider);
      state.wizardDismissed = true;
      state.setTutorialsEnabled(false);
      state.reportError('refresh (all)', StateError('view boom'));
      expect(state.errorDialogPending, isTrue);

      final router = GoRouter(
        initialLocation: '/today',
        routes: [
          GoRoute(
            path: '/today',
            builder: (context, routerState) => const AppScaffold(
              location: '/today',
              child: SizedBox.shrink(),
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(state.errorDialogPending, isFalse);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('view boom'), findsWidgets);

      // A second render must not open the dialog again.
      Navigator.of(tester.element(find.byType(AlertDialog))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      container.read(appStateProvider.notifier).emit();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  group('test_settings_quiet_save.py (AppState)', () {
    // test_save_quiet_persists_without_render
    test('saveQuietPersistsWithoutRender', () {
      final state = AppState();
      var renders = 0;
      state.onChanged = () => renders++;
      final synced = <Object?>[];
      state.configListeners
          .add(() => synced.add(state.get('check_interval_minutes')));

      expect(state.saveQuiet({'check_interval_minutes': 15}), isTrue);
      expect(state.get('check_interval_minutes'), 15);
      expect(renders, 0);
      // Config listeners (e.g. the scheduler interval) still hear it.
      expect(synced, [15]);
      // A plain save still re-renders.
      state.save({'check_interval_minutes': 20});
      expect(renders, 1);
    });
  });
}
