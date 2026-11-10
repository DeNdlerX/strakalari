// Live wiring of the Activity screen to the shared AppState.
//
// Port of the glue in strakalari/flet_ui/views/activity.py (`build`):
// the view reads its inputs (status, runs, log, update banner, audit
// records, version) from `AppState`; user actions call back into it.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:strakalari_core/strakalari_core.dart' as core;

import '../../controllers/app_state.dart' hide ActivityController;
import '../common/app_tokens.dart';
import 'activity_controller.dart';
import 'activity_view.dart';

/// Snapshot of [s] as the view's controller; actions delegate to [s].
ActivityController activityControllerFor(AppState s) {
  final c = ActivityController(s.config.data,
      startRefreshHook: (scope) => s.startRefresh(scope));
  c.logLines = List.of(s.logLines);
  c.runs = [for (final r in s.runs) Map<String, dynamic>.of(r)];
  c.status = s.status;
  c.refreshRunning = s.refreshRunning;
  c.cancelRequested = s.cancelRequested;
  c.currentStep = s.currentStep;
  c.sendingExcuses = Set.of(s.sendingExcuses);
  c.orderRunning = s.orderRunning;
  c.schedulerLastRun = s.schedulerLastRun;
  c.updateInfo = s.updateBanner == null
      ? null
      : Map<String, dynamic>.of(s.updateBanner!);
  c.updateDismissed = s.updateDismissed;
  c.updateCheckRunning = s.updateCheckRunning;
  c.lastError = s.lastError;
  c.errorDialogPending = s.errorDialogPending;
  c.cancelRefreshHook = s.cancelRefresh;
  c.clearLogHook = s.clearLog;
  c.dismissUpdateHook = s.dismissUpdate;
  return c;
}

/// Newest audit records + the read error ('' when fine).
/// Port of `_audit_items()`.
(List<Map<String, dynamic>>, String) loadAuditItems([int limit = 80]) {
  try {
    final items = core.recent(limit: limit);
    return ([for (final i in items) Map<String, dynamic>.of(i)], '');
  } catch (e) {
    return (<Map<String, dynamic>>[], '$e');
  }
}

/// The Activity route: rebuilds whenever the shared state emits.
class LiveActivityView extends ConsumerWidget {
  final bool narrow;
  final AppTokens? tokens;
  const LiveActivityView({super.key, required this.narrow, this.tokens});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(appStateProvider);
    s.tutorialOffer('activity');
    final (audit, auditError) = loadAuditItems();
    String version;
    try {
      version = core.getCurrentVersion();
    } catch (_) {
      version = '';
    }
    final meals = <String, String>{};
    for (final day in s.food().values) {
      meals.addAll(day);
    }
    return ActivityView(
      controller: activityControllerFor(s),
      audit: audit,
      auditError: auditError,
      narrow: narrow,
      updatedLabel: s.updatedLabel,
      appVersion: version,
      foodNames: meals,
    );
  }
}
