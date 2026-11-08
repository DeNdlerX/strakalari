// Pure-Dart core of Strakalari (must never import Flutter).
//
// Behavior parity with `strakalari/core` (Python). Modules are ported one by
// one; each port adds its export here and a `*_test.dart` counterpart under
// `test/`.
export 'src/platform/packaging.dart';
export 'src/platform/keystore.dart';
export 'src/platform/android_bridge.dart';
export 'src/storage/fernet.dart';
export 'src/storage/helpers.dart';
export 'src/storage/cache.dart';
export 'src/storage/config.dart';
export 'src/storage/secret_store.dart';
export 'src/models.dart';
export 'src/i18n.dart';
export 'src/automation/audit.dart';
export 'src/automation/excuse_history.dart';
export 'src/automation/cancel.dart';
export 'src/bakalari/common.dart';
export 'src/bakalari/extractors.dart';
export 'src/bakalari/http_session.dart';
export 'src/bakalari/client.dart';
export 'src/bakalari/timetable.dart';
export 'src/bakalari/data.dart';
export 'src/bakalari/excuse.dart';
export 'src/strava/extractors.dart';
export 'src/strava/ordering.dart';
export 'src/strava/client.dart';
export 'src/error_report.dart';
export 'src/planning/schedule.dart';
export 'src/planning/matching.dart';
export 'src/planning/planned_skips.dart';
export 'src/planning/forecast.dart';
export 'src/planning/grades.dart';
export 'src/planning/planner.dart';
export 'src/planning/school_presets.dart';
export 'src/lunches/lunch_cutoff.dart';
export 'src/lunches/lunch_auto.dart';
export 'src/lunches/gemini.dart';
export 'src/news.dart';
export 'src/update.dart';
// status_notification.mealText is hidden: it formats a meal *name* for one
// line, while strava/extractors.dart mealText renders a *meal map* —
// both exist in Python too (status_notification.meal_text vs
// extractors/strava.meal_text). Reachable via the src import.
export 'src/status_notification.dart' hide mealText;
// wakeup.periodOf is hidden: wakeup.py keeps its own simpler `_period_of`
// (clock text, else row) while schedule.py has the hourIndex fallback —
// both exist in Python. status_notification.dart uses wakeup's via its
// src import; the barrel exposes schedule's.
export 'src/wakeup.dart' hide periodOf;
export 'src/platform/notifier.dart';
export 'src/automation/scheduler.dart';
export 'src/automation/session_lock.dart';
export 'src/automation/automation.dart';
export 'src/automation/refresh.dart';
