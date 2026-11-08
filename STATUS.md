# Flutter migration status

Branch: flutter-migration · Flutter: 3.44.8 · Last main commit ported: 0ffdcff
Current phase: 5–9 done (integration by owner-agent) · Next step: Checkpoint A rework — ALL BLOCKERS DONE (B1 ee364bd, B2 7a045dd, B3 e0d0ebf, B4 441a05e, B5 2eff0b5) + M1 DONE (56c34aa), M2 DONE (5857842), M3 DONE (73cd892), M4 DONE (e734e04, 763ec48), M5 DONE (entryName normalization + parity); next: M6–M8, S1–S10, one commit per finding, then stop for re-review. No work on phases 5–10 until Checkpoint A passes.
Phase 2 (clients) is done: Bakaláři + Strava ports are green, and
`bin/parity_fetch.dart` prints byte-identical JSON to
`tools/parity/fetch.py` against `tools/bakalari_demo_server.py`.
Phase 1 (core foundation) is done: models, helpers, config, cache, i18n,
audit, excuse_history, Fernet + secret_store, parity harness.
Phase 3 (domain logic) is done: schedule, matching, planned_skips,
forecast, grades (pure math), planner, school_presets, lunch_cutoff,
lunch_auto, gemini, news, update, status_notification, wakeup,
notify (core interface). 16 new parity JSON fixtures (344 cases);
`dart analyze` + `flutter analyze` clean.
Phase 4 (automation) is done: error_report (full), scheduler,
session_lock, automation (Strakalari), refresh (run_refresh).
A dry-run refresh against the demo server gives identical result,
cache keys (incl. `stable_baseline`), audit entries (modulo ts),
outbox and history in Python and Dart. ⛔ Checkpoint A: core review.
Phase 5 (app shell) is done: Riverpod controllers (AppState + 6 facades),
go_router (8 routes + wizard + more), adaptive scaffold (720/520
breakpoints, rail ↔ bar + More, landscape side rail), theme tokens,
ARB strings (794 keys + 13 notif_*), shared widgets, error dialog with
Copy log/Share, tutorial tours, platform seams. `flutter analyze` clean.
Phase 6 (screens) is done: all 10 screens wired into the router with
real views + controllers (wizard, today, timetable, absences, marks,
planner, lunches, activity, settings, more); 116 widget/unit tests +
app-boots/navigation smoke test green. ⛔ Checkpoint B: UI review.
Phase 7 (desktop) is done in code: tray + hide-to-tray, autostart,
single-instance loopback-TCP, notifications, desktop keystores, Inno
(AppId kept) + MSIX adaptations, CI release jobs. All UNVERIFIED on
this PC except `flutter analyze`; Sandbox over-install test pending.
Phase 8 (Android) is done in code: Java moved unchanged (+1 R import
line in 6 files), StrakalariChannel, headless backgroundMain with
UI-isolate hand-off, boot re-arm, widget/alarms, Keystore unwrap,
`.test` flavor, privacy test port. `:app:compileProd/PhonetestDebugSources`
green, `flutter analyze` clean. On-phone verification pending.
⛔ Checkpoint C: platform review.
Phase 9 (soak prep) is done: soak_compare/soak_refresh scripts,
SOAK.md routine, README/CONTRIBUTING/PRIVACY wording; dry-run parity
IDENTICAL (modulo ts), fetch parity byte-identical. Beta release waits
for the owner's go-ahead. ⛔ Checkpoint D: release review.
Phase 10 (switch) NOT started: needs reviewer sign-off + owner merge.

## Phase 0 (done)

- Dart workspace skeleton: `pubspec.yaml` (workspace root), `analysis_options.yaml`
  (lints recommended + strict-casts/inference/raw-types, `mobile/**` excluded),
  `packages/strakalari_core` (pure Dart, smoke test), `app` (flutter create,
  platforms windows/macos/linux/android, org io.github.dendlerx).
- Android identity fixed to `io.github.dendlerx.strakalari` (applicationId,
  namespace, MainActivity package) so the build installs as an update.
- CI: `.github/workflows/dart.yml` (analyze + test, ubuntu + windows,
  Flutter 3.44.8). Python CI untouched. CI minutes are limited: verify locally.
- Checks green: `dart analyze`, `flutter analyze`, `dart test` (core),
  `flutter test` (app template test; replaced by real widget tests in phase 5).

## Modules

State: todo = not started, tests = Dart tests written, done = ported + green.

| Python file | Dart file | Tests (py → dart) | State |
|---|---|---|---|
| strakalari/__init__.py | version export (core/app) | — | todo |
| strakalari/__main__.py | app/lib/main.dart | — | todo |
| strakalari/core/__init__.py | core barrel | — | todo |
| strakalari/core/android.py | core platform/android_bridge.dart + app MethodChannel | test_notify.py, test_wake_ui.py, test_wakeup_and_widget.py | todo |
| strakalari/core/audit.py | core automation/audit.dart | test_automation_safety.py (audit cases) → audit_test.dart (3) + parity_audit_test.dart | done |
| strakalari/core/automation.py | core automation/automation.dart | test_automation_safety.py + deferred send-path cases (test_excuse_generation, test_order_latch, test_strava_low_balance, test_strava_ordering, test_unconfirmed_excuses, test_excuse_history/TestSendPath…) → automation_test.dart + refresh_test.dart; `bin/refresh_dryrun.dart` dry-run parity vs demo server | done |
| strakalari/core/autostart.py | core platform/autostart.dart + app impl | test_autostart.py, test_autostart_platforms.py | todo |
| strakalari/core/bakalari_client.py | core bakalari/client.dart | test_bakalari_client.py (base cases) → bakalari_client_test.dart | done |
| strakalari/core/bakalari_common.py | core bakalari/common.dart | client/data tests (hour-index, week offsets, removed/room-move rows) → common_test.dart | done |
| strakalari/core/bakalari_data.py | core bakalari/data.dart (DataMixin) | test_bakalari_http.py (read cases), test_sent_excuses.py, test_grades.py (client cases) → bakalari_data_test.dart (15); phase 3+: `update_stable_baseline` ported, fetch order details → stable → substitutions → baseline wired in `fetchBakalariData` | done |
| strakalari/core/bakalari_excuse.py | core bakalari/excuse.dart (ExcuseFormMixin) | test_bakalari_excuse.py → bakalari_excuse_test.dart (14) + parity (excuse cases in bakalari.json) | done |
| strakalari/core/bakalari_http.py | core bakalari/http_session.dart | test_bakalari_http.py (session cases) → http_session_test.dart (10) + parity_http_session_test.dart | done |
| strakalari/core/bakalari_timetable.py | core bakalari/timetable.dart (TimetableMixin on BakalariClientBase) | test_bakalari_client.py (add/perm/stable/week cases) → timetable_test.dart | done |
| strakalari/core/cache.py | core storage/cache.dart | test_cache.py + merge/seed/busy cases from test_timetable_cache_merge, test_data_safety, test_scheduler → cache_test.dart (21) + parity_cache_test.dart | done |
| strakalari/core/cancel.py | core automation/cancel.dart | ported with the session (covered by http_session_test); test_cancel_responsive.py, test_refresh_cancel_keeps_data.py → phase 5/4 | done |
| strakalari/core/config.py | core storage/config.dart | test_config.py, test_config_save_lock.py → config_test.dart (34) + parity_config_test.dart | done |
| strakalari/core/error_report.py | core error_report.dart (full port: redaction, report builders; `UserError`/`timeoutUserMessage` API unchanged) | test_error_report.py, test_log_redaction.py → error_report_test.dart + parity_error_report_test.dart | done |
| strakalari/core/excuse_history.py | core automation/excuse_history.dart | test_excuse_history.py, test_unconfirmed_excuses.py (pure cases) → excuse_history_test.dart (17) + parity_excuse_history_test.dart | done |
| strakalari/core/extractors/__init__.py | core bakalari/ + strava/ barrels | — | todo |
| strakalari/core/extractors/bakalari.py | core bakalari/extractors.dart | grades/sent-excuses/substitution/parity cases → extractors_test.dart + parity_bakalari_test.dart | done |
| strakalari/core/extractors/strava.py | core strava/extractors.dart | menu/food asserts in strava_test.dart + parity_strava_test.dart | done |
| strakalari/core/forecast.py | core planning/forecast.dart | test_forecast.py, test_absence_details.py → forecast_test.dart + parity_forecast_test.dart | done |
| strakalari/core/gemini.py | core lunches/gemini.dart | test_gemini_key.py, test_gemini_picks.py, test_ai_recommend.py → gemini_test.dart + parity_gemini_test.dart (network calls covered by fakes/seams, never real) | done |
| strakalari/core/grades.py | core planning/grades.dart | test_grades.py, test_grades_math.py, test_grades_minus.py (pure math; extractor/client cases already in extractors/bakalari_data) → grades_test.dart + parity_grades_test.dart | done |
| strakalari/core/helpers.py | core storage/helpers.dart | test_helpers.py → helpers_test.dart (21) + parity_helpers_test.dart; test_session_lock.py → session_lock_test.dart (phase 4, done) | done |
| strakalari/core/i18n.py | core i18n.dart | test_i18n.py (core cases) → i18n_test.dart 4 + parity_i18n_test.dart | done |
| strakalari/core/lunch_auto.py | core lunches/lunch_auto.dart | test_lunch_auto.py, test_lunch_auto_user_choice.py, test_lunch_same_pick.py → lunch_auto_test.dart + parity_lunch_auto_test.dart (ban matching delegates to planning/matching.dart) | done |
| strakalari/core/lunch_cutoff.py | core lunches/lunch_cutoff.dart | test_lunch_cutoff.py, test_lunch_day_keys.py, test_lunch_deadline_calendar.py → lunch_cutoff_test.dart + parity_lunch_cutoff_test.dart | done |
| strakalari/core/matching.py | core planning/matching.dart | test_matching.py → matching_test.dart + parity_matching_test.dart | done |
| strakalari/core/models.py | core models.dart | test_models.py (minus 2 automation cases → phase 4) → models_test.dart (14) + parity_models_test.dart | done |
| strakalari/core/news.py | core news.dart | test_news.py → news_test.dart + parity_news_test.dart | done |
| strakalari/core/notify.py | core platform/notifier.dart (abstract Notifier interface; OS impls → phase 7) | test_notify.py → notifier_test.dart | done |
| strakalari/core/packaging.py | core platform/packaging.dart | test_mobile.py (predicates) → packaging_test.dart 9 | done |
| strakalari/core/planned_skips.py | core planning/planned_skips.dart | test_planned_skips.py, test_early_leave.py → planned_skips_test.dart + parity_planned_skips_test.dart | done |
| strakalari/core/planner.py | core planning/planner.dart | test_year_planner.py (pure plan cases; dialog/AppState cases → phase 5/6), test_plan_reserve.py (pure reserve parts) → planner_test.dart + parity_planner_test.dart | done |
| strakalari/core/refresh.py | core automation/refresh.dart | test_refresh_pipeline.py, test_data_safety.py, test_refresh_cancel_keeps_data.py, test_session_lock.py + deferred gate cases → refresh_test.dart; `bin/refresh_dryrun.dart` | done |
| strakalari/core/schedule.py | core planning/schedule.dart | test_schedule.py, test_substitution_feed_days.py → schedule_test.dart + parity_schedule_test.dart | done |
| strakalari/core/scheduler.py | core automation/scheduler.dart | test_scheduler.py, test_scheduler_retry.py → scheduler_test.dart + parity_scheduler_test.dart | done |
| strakalari/core/school_presets.py | core planning/school_presets.dart | test_school_calendar.py → school_presets_test.dart + parity_school_presets_test.dart | done |
| strakalari/core/secret_store.py | core storage/secret_store.dart + platform/keystore.dart (+ android_bridge.dart iface) | test_secret_store.py → secret_store_test.dart (10); Fernet roundtrip/tamper/key tests → fernet_test.dart (5) | done |
| strakalari/core/status_notification.py | core status_notification.dart | test_status_notification.py → status_notification_test.dart + parity_status_notification_test.dart | done |
| strakalari/core/strava_client.py | core strava/client.dart (StravaClientBase) | test_strava_client.py (client cases) → strava_test.dart (19) + parity (strava cases in strava.json) | done |
| strakalari/core/strava_ordering.py | core strava/ordering.dart (OrderingMixin) | test_strava_client.py (order/save cases) → strava_test.dart + order-sheet byte test | done |
| strakalari/core/tls.py | — (dropped, see below) | test_tls_bundle.py, test_frozen_ssl.py | dropped |
| strakalari/core/update.py | core update.dart | test_update.py → update_test.dart + parity_update_test.dart (network via hook seam; app startup must set `currentAppVersion`, phases 7) | done |
| strakalari/core/wakeup.py | core wakeup.dart (pure scheduling/message logic; alarms/receivers → phase 8) | test_wakeup_and_widget.py, test_wake_ui.py (pure cases; Flet/UI cases → phase 5–8) → wakeup_test.dart + parity_wakeup_test.dart | done |
| strakalari/flet_ui/__init__.py | app barrel (shell + features) | — | done |
| strakalari/flet_ui/__main__.py | app/lib/main.dart | widget_test.dart smoke (boots + rail navigation) | done |
| strakalari/flet_ui/app.py | app/lib/main.dart + shell/ | widget_test.dart smoke; navigation covered | done |
| strakalari/flet_ui/assets.py | app assets | test_icons.py | todo |
| strakalari/flet_ui/components.py | app/lib/widgets/ | overlays_test.dart (8) | done |
| strakalari/flet_ui/macos.py | app/lib/platform/desktop/ (tray hosts window, data dir) | — (macOS unverified) | done |
| strakalari/flet_ui/overlays.py | app/lib/widgets/overlays.dart + error_dialog.dart | overlays_test.dart (8) | done |
| strakalari/flet_ui/safety.py | app shell/controllers (confirm-auto guards) | settings_quietsave_test.dart | done |
| strakalari/flet_ui/single_instance.py | app/lib/platform/desktop/single_instance.dart | — (manual py↔dart exclusion proof, phase 7 notes) | done |
| strakalari/flet_ui/startup.py | app/lib/main.dart startup (stdio guards n/a on Flutter) | widget_test.dart smoke | done |
| strakalari/flet_ui/state.py | app/lib/controllers/app_state.dart | widget_test.dart + settings tests | done |
| strakalari/flet_ui/state_activity.py | app controllers/activity + features/activity | activity_state_test.dart (10) + activity_view_test.dart (6) | done |
| strakalari/flet_ui/state_excuses.py | app controllers/excuses + features/today + absences | wizard/today/absences via widget_test rail pass | done |
| strakalari/flet_ui/state_lunches.py | app controllers/lunches + features/lunches | lunches_filter_test.dart (15) + lunches_view_test.dart (9) | done |
| strakalari/flet_ui/state_marks.py | app controllers/marks + features/marks | widget_test.dart rail pass | done |
| strakalari/flet_ui/state_planner.py | app controllers/planner + features/planner | planner_reserve_test.dart (12) + planner_view_test.dart (10) | done |
| strakalari/flet_ui/state_tutorial.py | app controllers/tutorial + tutorial/tours | tutorial_test.dart (19) | done |
| strakalari/flet_ui/strings.py | app l10n ARB (app_cs/en + strings.dart) | settings_sections_test.dart (16) | done |
| strakalari/flet_ui/theme.py | app/lib/shell/theme.dart | widget_test.dart breakpoints | done |
| strakalari/flet_ui/tray.py | app/lib/platform/desktop/tray.dart | — (Sandbox test pending) | done |
| strakalari/flet_ui/tutorial.py | app/lib/tutorial/ + widgets/overlays (kTours) | tutorial_test.dart (19) | done |
| strakalari/flet_ui/views/__init__.py | app features barrel (router) | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/absences.py | app features/absences | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/activity.py | app features/activity | activity_view_test.dart (6) | done |
| strakalari/flet_ui/views/lunches.py | app features/lunches | lunches_view_test.dart (9) | done |
| strakalari/flet_ui/views/marks.py | app features/marks | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/more.py | app features/more.dart | overlays_test.dart +more (8) | done |
| strakalari/flet_ui/views/planner.py | app features/planner | planner_view_test.dart (10) | done |
| strakalari/flet_ui/views/settings/__init__.py | app features/settings | settings_sections_test.dart (16) | done |
| strakalari/flet_ui/views/settings/accounts.py | app features/settings | wizard_settings_test.dart (5) | done |
| strakalari/flet_ui/views/settings/app_prefs.py | app features/settings | settings_quietsave_test.dart (6) | done |
| strakalari/flet_ui/views/settings/automation.py | app features/settings | settings_sections_test.dart (16) | done |
| strakalari/flet_ui/views/settings/common.py | app features/settings | settings_sections_test.dart (16) | done |
| strakalari/flet_ui/views/settings/school_calendar.py | app features/settings | settings_sections_test.dart (16) | done |
| strakalari/flet_ui/views/settings/view.py | app features/settings | settings_sections_test.dart (16) | done |
| strakalari/flet_ui/views/timetable.py | app features/timetable | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/today.py | app features/today | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/wizard.py | app features/wizard | wizard_settings_test.dart (5) | done |

## Tests

Naming: `tests/test_x.py` → `x_test.dart` in core or app (`test_ui_state.py`-style
UI/platform tests go to `app/test/`, pure-logic tests to
`packages/strakalari_core/test/`). All todo unless noted.

Core: test_absence_details, test_ai_recommend, test_automation_safety,
test_bakalari_client, test_bakalari_excuse, test_bakalari_http, test_cache,
test_config, test_config_save_lock, test_data_safety, test_early_leave,
test_error_report, test_excuse_day_scope, test_excuse_generation,
test_excuse_history, test_excuse_ignore_list, test_forecast, test_gemini_key,
test_gemini_picks, test_grades, test_grades_math, test_grades_minus,
test_helpers, test_i18n, test_log_redaction, test_lunch_auto,
test_lunch_auto_user_choice, test_lunch_cutoff, test_lunch_day_keys,
test_lunch_deadline_calendar, test_lunch_filter, test_lunch_same_pick,
test_matching, test_models, test_news, test_order_latch, test_plan_picker,
test_plan_reserve, test_planned_skips, test_refresh_cancel_keeps_data,
test_refresh_pipeline, test_schedule, test_scheduler, test_scheduler_retry,
test_school_calendar, test_secret_store, test_sent_excuses, test_session_lock,
test_stable_change_signals, test_status_notification, test_strava_blacklist_edits,
test_strava_client, test_strava_low_balance, test_strava_ordering,
test_substitution_feed_days, test_timetable_cache_merge,
test_unconfirmed_excuses, test_update, test_wakeup_and_widget, test_year_planner.

App: test_autostart, test_autostart_platforms, test_cancel_responsive,
test_entry_routing, test_flet_data_wiring, test_icons,
test_macos_data_dir, test_macos_tray_host, test_marks_view, test_minimize_to_tray,
test_mobile, test_notify, test_open_url, test_packaging_privacy,
test_planner_dialog, test_settings_quiet_save, test_settings_refresh_interactive,
test_settings_sections, test_shutdown, test_single_instance, test_store_package,
test_timetable_week_nav, test_timetable_week_switch, test_tray_language,
test_tray_ui_command, test_tutorial, test_ui_state, test_ui_views,
test_version_sync, test_wake_ui, test_wizard_setup.

Support (ported as helpers/fixtures, not 1:1): tests/conftest.py,
tests/fake_bakalari.py, tests/fixtures/, tests/test_imports_resolve.py
(Python-specific, decide at port).

Expected drops (decide at port, subject likely absent in Flutter):
test_tls_bundle.py, test_frozen_ssl.py (frozen CA bundle no longer exists).

## Deferred test cases (not dropped — ported with the phase that owns their SUT)

Phase 4 resolutions (all landed in `automation_test.dart` / `refresh_test.dart`
unless noted; remaining phase-5 owners unchanged below):
- test_models.py 2 engine cases → done (need `automation.Strakalari`).
- test_config.py `TestPasswordOverridesEncrypted`,
  `test_integer_strava_id_handling`, `TestStravaEnableDefault` → done.
- test_excuse_history.py deferred cases (`test_concurrent_sends_submit_once`,
  `test_covered_excuse_is_not_resent`, `TestExampleHistoryFilter` automation
  case, `TestHistoryCoverage`, `test_excuse_dry_run_fills_without_submitting`)
  → done. `TestHistoryCoverage` UI half stays phase 5 (`AppState`).
- test_unconfirmed_excuses.py `TestSendPath`/`TestOutboxSettles`/
  `TestRefreshGate` → done.
- test_strava_ordering.py → done (needs `Strakalari`).
- test_strava_low_balance.py → done (refresh/notice/UI tail → phase 5 owners).
- test_order_latch.py → done except the AppState latch (phase 5).
- test_strava_blacklist_edits.py → still phase 5 (AppState + shipped template).
- test_grades.py extractor/client cases → already in `extractors_test.dart` /
  `bakalari_data_test.dart` (done, phase 2).
- test_excuse_generation.py → done (in `automation_test.dart`).
- test_sent_excuses.py sync tests → done.
- test_excuse_day_scope.py → still phase 5 (`AppState.day_excuse_plan`).
- test_excuse_ignore_list.py `TestIgnoredExcuses` → done (in
  `automation_test.dart`); the rest still phase 5 (AppState ignore list).
- test_absence_details.py → done in `forecast_test.dart` (+ parity).
- test_substitution_feed_days.py → done in `schedule_test.dart`.
- test_session_lock.py → done in `session_lock_test.dart` (+ manual
  cross-process proof, see Checkpoint notes).
- test_timetable_cache_merge.py dry-run send cases → covered by the phase-4
  dry-run parity (Python vs Dart audit/outbox/history identical).
- test_stable_change_signals.py → no automation/refresh-SUT cases found
  (schedule/extractors/UI only); nothing to port.
- `HistoryLock` test (`test_concurrent_sends_submit_once`) → done; the
  one-isolate static mutex restoring check-submit-write serialization is
  proven by it.
- test_timetable_week_nav.py, test_timetable_week_switch.py,
  test_marks_view.py, test_refresh_cancel_keeps_data.py UI tails,
  test_cancel_responsive.py AppState branches → still phase 5.
- test_early_leave.py → evaluated: entirely soon/early detection +
  AppState/UI wiring (no pure schedule cases); nothing to port to core.
- test_plan_picker.py (12 Flet dialog cases) → still phase 6 (no Dart
  dialog subject exists).

- test_i18n.py → `test_core_messages_follow_language` moves to phase 4
  (needs `error_report.timeout_user_message`); `test_new_flet_strings_present`
  + `test_dead_keys_removed_and_live_keys_kept` move to phase 5 (need
  `flet_ui.strings`).
- test_models.py → `test_engine_excuses_neomluveno_day` +
  `test_engine_excuses_unexcused_type` move to phase 4 (need
  `automation.Strakalari.generate_excuses`).
- test_session_lock.py → phase 4 (needs `refresh.session_lock`; the
  cross-process subprocess case needs a Python process and is proven
  manually instead, see Checkpoint notes).
- test_config.py → `TestPasswordOverridesEncrypted`,
  `test_integer_strava_id_handling`, `TestStravaEnableDefault` (incl.
  `test_partial_config_without_use_strava_stays_enabled`) move to phase 4
  (need `automation.Strakalari`).
- test_excuse_history.py → `test_concurrent_sends_submit_once`,
  `test_covered_excuse_is_not_resent`,
  `TestExampleHistoryFilter::test_automation_filters_example`,
  `TestHistoryCoverage` (needs `flet_ui.state_excuses`, phase 5),
  `test_excuse_dry_run_fills_without_submitting` move to phase 4
  (need `automation.Strakalari`); `test_manager_filters_example_fallback`
  + `test_history_quarantine` are ported in excuse_history_test.dart
  (they test `ConfigManager.getExcuseHistory`).
- test_excuse_day_scope.py → whole file moves to phase 5
  (needs `AppState.day_excuse_plan` / `submit_day_excuse`).
- test_excuse_ignore_list.py → `TestIgnoredExcuses` (needs
  `automation.generate_excuses`, phase 4), the rest moves to phase 5
  (needs `AppState` ignore list).
- test_unconfirmed_excuses.py → `TestSendPath`, `TestOutboxSettles`,
  `TestRefreshGate` move to phase 4 (need `Strakalari` / `run_refresh`).
- test_strava_ordering.py → phase 4 (needs `Strakalari.strava_order_selected`).
- test_strava_low_balance.py → phase 4 (`strava_order_selected` low-balance
  path); the refresh/notice/UI tail (`run_refresh`, `claim_low_balance_notice`,
  `AppState._warn_low_balance`) → phase 4/5 with their owners.
- test_order_latch.py → phase 4 (needs `Strakalari`).
- test_strava_blacklist_edits.py + `test_default_blacklist_template_is_empty`
  → phase 5 (needs `AppState` blacklist editing + the shipped example file).
- test_grades.py → extractor cases live in `extractors_test.dart`;
  `get_grades` client cases live in `bakalari_data_test.dart` (done).
- test_excuse_generation.py → phase 4 (needs `automation`
  `Strakalari.generate_excuses`; the form-sending half is done in
  `bakalari_excuse_test.dart`).
- test_sent_excuses.py → `TestSentExcuseEntries` + `TestMergeSentExcuses`
  are ported (`extractors_test.dart`, `excuse_history_test.dart`); the
  sync tests move to phase 4 (need `Strakalari`).
- test_absence_details.py → phase 3 (needs `forecast`).
- test_marks_view.py → phase 5 (needs Flet views).
- test_substitution_feed_days.py → phase 3 (needs `schedule`).
- `HistoryLock` is ported with excuse_history but its test lands in
  phase 4 (`test_concurrent_sends_submit_once`).

## Dropped (with reason)

- `strakalari/core/tls.py` — Dart uses the OS trust store; no frozen CA bundle
  (PLAN §3.2). Reviewer sign-off still pending at the relevant checkpoint.

## Deviations from Python (each needs reviewer sign-off)

- Phase 1 port adaptations (behavior identical for installed builds):
  - `helpers.dart` + `secret_store.dart` landed in one commit: they import
    each other (mirrors Python's lazy imports; Dart compiles the cycle).
  - Python `_`-private names used cross-module/tests are public in Dart
    (`resolvePath`, `entryName`, `looksLikePlaceholder` later): Dart
    privacy is per library.
  - `t(key, args: {...})` takes a map; Python call sites pass `**fmt`.
  - `getUserDataDir`: dev runs use the executable-dir-writability probe
    (create+delete a dotfile) instead of `os.access(root, W_OK)`; the
    override env, mobile, macOS-bundle and Store branches match.
  - `fernetFactory` seam replaces monkeypatching `_get_fernet` in tests.
  - `chmod 600` for `secret.key` via best-effort `Process.runSync`
    (dart:io has no chmod API); Windows unchanged.
  - Tests set `STRAKALARI_DATA_DIR` (hermetic tmp) instead of using the
    ambient dir like the Python suite.
  - `lessonStatusFromLegacy` is public (Python: `_lesson_status_from_legacy`);
    the ported tests call it directly.
  - `config.dart` carries local mirrors of four phase-3 checks
    (`isValidCutoffTime`, `bandsValid`, `statusNotificationItems`,
    `defaultUpdateChannel`); phase 3 rewires them to the canonical ports.
    `looksLikePlaceholder` + `isDemoHistoryItem` are public (Python:
    `_looks_like_placeholder`, `_is_demo_history_item` used cross-module).
  - `ConfigManager` uses a factory constructor (Dart forbids `this.x`
    alongside a transformed `configPath` initializer); `save()` throws
    `StateError` where Python raises `RuntimeError`.
  - `test_config_save_lock.py` is proven with a real held
    `InterProcessLock` instead of monkeypatching `acquire` (waits the
    10 s save timeout once per suite run).
  - `normalizeHistoryItem` takes a typed map (Python passes non-dicts
    through; all callers guard with `isinstance` first, and no test
    passes a non-dict).
  - Map equality is deep (`_jsonEquals`): Dart maps compare by identity,
    Python dicts by value — needed for merge dedup and coverage checks.
  - `HistoryLock` replaces the `threading.RLock` + context manager: Dart
    runs one event loop per isolate, so a static depth counter gives the
    same re-entrant semantics; callers use `acquire()` / `release()`
    instead of `with`.
  - Entity unescape uses `html_unescape` (`html`'s `parseFragment().text`
    drops attribute content, which is where `data-clasif` lives).
  - `absence_from_subjects` rounds halves to even (`_round2`), mirroring
    Python's `round()` (Dart rounds half away from zero).
  - The HTTP session runs on an injectable `HttpTransport` over `dart:io`
    (no `package:http`/`cookie_jar`: a transparent client would follow the
    login 302 before the session stores its cookie — PLAN §3.5 requires
    following redirects by hand; `FakeBakalari` replaces `MockClient` in
    tests). `RuntimeError` → `StateError`, `ValueError` → `ArgumentError`,
    `InterruptedError` → `CancelledError`.
  - `error_report.dart` lands slim in phase 2 (`UserError`,
    `timeoutUserMessage`); phase 4 ports the redaction/report builders.
  - `cancel.dart` is ported with the session; its dedicated tests
    (`test_cancel_responsive.py`) need `AppState` and land in phase 5 —
    both branches are covered by `http_session_test.dart`.
  - `test_timetable_cache_merge.py` merge cases live in `cache_test.dart`
  (the SUT `merge_timetable_days` is in `cache.dart`); the file's
  dry-run send cases belong to phase 4/5.
- `BakalariClient` mixes in `TimetableMixin` via an abstract
  `BakalariClientBase` (a mixin constrained on its own class is a
  compile error in Dart); `data.dart` / `excuse.dart` attach the same way.
- `jsonEquals` (deep JSON equality) is shared in `helpers.dart`;
  `excuse_history.dart` keeps its identical private copy (no churn).
- Password validation is eager like Python (constructor argument),
  while the provider still re-reads on every login.
- `sentExcuses` is nullable (tri-state: list = read, null = unknown),
  matching Python's `None`.
- `session.json` grew optional `queryParams` + `jsonBody` (the data and
  excuse mixins need both); `update_stable_baseline` / `fetch_data`
  stay in `data.dart`'s future: they need `schedule.dart` (phase 3).
- `UserError` carries an optional `cause` (the transport error); `_send`
  attaches it, and the excuse post's `isNeverSentCause` mirrors Python's
  connect-vs-maybe-sent rule (refused/unreachable/DNS/connect-timeout =
  never sent, read timeouts and the rest = uncertain).
- The outbox helpers are public `DataMixin.fetchOutboxIds` /
  `fetchOutboxDetail` (shared with `ExcuseFormMixin`, which is
  constrained `on BakalariClientBase, DataMixin`); the extractor's pure
  `outboxExcuseIds` parser keeps its name.
- `dateState` counts the day in UTC: a local-midnight difference loses
  an hour over DST and truncates a day off (parity case pins the value).
- Parity caught `calendarState.selectedDates` being a list, not a bare
  string — fixed before commit.
- `apiRoot` keeps the port/userinfo (Python compares the whole lowercased
  netloc, not just the host) — parity-caught.
- `stravaBlacklistJson` is `List<String>` (`'$kw'`); Python keeps raw
  values. The shipped-template/placeholder and fail-closed quarantine
  rules are ported as-is.
- The Strava retry rule reuses `isNeverSentCause` (refused/unreachable =
  no retry, like Python's ConnectError; dropped reads retry once).
- `tls.ensure_ca_bundle` has no Dart counterpart: `DartIoHttpTransport`
  uses the system store (noted, not ported).
- Phase 3/4 port adaptations (behavior identical unless noted):
  - Canonical-name unification (each mirrors Python's own imports):
    `canonSubject`/`normalizeHolidays`/`schoolDaysBetween` live in
    `forecast.dart` (planner imports them); `normalizePlannedEntry`/
    `entryDays` live in `planned_skips.dart`; `bandsValid`/`defaultBands`/
    `normalizeBands` live in `grades.dart`, `isValidCutoffTime`/
    `normalizeCutoffTime` in `lunch_cutoff.dart` (school_presets imports
    them); `handledKey` lives in `lunch_auto.dart` (refresh imports it).
    `config.dart` delegates `isValidCutoffTime`→lunch_cutoff,
    `bandsValid`→grades, `statusNotificationItems`→status_notification.items,
    `defaultUpdateChannel()`→update.defaultChannel() (follows the running
    build, like Python). Barrel hides `wakeup.periodOf` (wakeup.py keeps
    its own simpler `_period_of`, like Python) and
    `status_notification.mealText` (formats a name; strava's formats a
    meal map — both exist in Python too).
  - `lunch_auto` ban matching delegates to `matching.isFoodBanned`
    (same stems/suffixes; the mirror wrongly folded ł/ø/ß, Python NFD
    keeps them — the canonical port is the faithful one).
  - DST-safe day stepping: `schoolDaysBetween` (forecast),
    `entryDays` (planned_skips) and the planner use constructor
    arithmetic; Python `date + timedelta` has no DST. The sibling
    `Duration(days: …)` day iterations (schedule, wakeup,
    status_notification comparisons) are untouched — same latent drift,
    flagged for the reviewer.
  - `bandsValid` accepts bools (`float(True) == 1.0`, like Python).
  - `LessonSource` also accepts live `SlotBaseline` objects (Python reads
    any object with `.subject` via hasattr) — parity-oracle caught the gap.
  - `validatePreset` bad-entry messages use a `_pyRepr` (`['bad', 'label']`,
    like `{entry!r}`) instead of Dart's `[bad, label]`.
  - `mealText` blanks every falsy input (`str(name or "")`), not just
    null — parity-oracle caught `"Null"`/`"0"`.
  - `buildPrompt` (cs) reads "Odpověz ve formátu …", like Python (the port
    had "Odpověď …") — parity-oracle caught the rewording.
  - `updateStableBaseline` is ported into `DataMixin`; `fetchBakalariData`
    runs weeks → details → stable view → substitutions → baseline →
    absence → grades → directory (Python's `fetch_data` order).
  - Automation/refresh seam hooks default to the real phase-3 functions
    (`schoolYearTerms`, `baselineToDict`, `findNews`, `plannedLunchDays`,
    `updateHandledDays`, `resolveLunchCutoff`, `effectiveCalendar`,
    `isLunchOrderOpen`); tests assign fakes. Only `planAutoOrdersHook`
    still throws: the real `planAutoOrders` is async (network/Gemini)
    while the hook contract is sync.
  - Static async mutex in `Strakalari` around check-submit-write (Dart's
    `HistoryLock` is re-entrant per isolate; Python threads block on the
    file lock — the mutex restores the no-double-submit serialization,
    proven by `concurrentSendsSubmitOnce`).
  - `RefreshApp` interface replaces Python duck typing;
    `runRefresh`/`Strakalari` methods are async; `InterruptedError`→
    `CancelledError`, `RuntimeError`→`StateError`.
  - Optional params are all-named; `sendExcuseOutcome` delegates to
    `sendExcuse(source: 'manual')`; public names for test-used privates
    per the phase-1 precedent.
  - Log redaction in automation is a minimal local mirror of
    `error_report` secret-values (secret keys only); the error_report
    port owns the canonical copy.

- Phase 5–6 port adaptations (behavior identical unless noted):
  - Six subagents worked in parallel with disjoint file sets, integrated
    by the owner-agent: shell (Riverpod + router + theme + ARB + widgets),
    screens A (today/timetable/absences/marks/wizard), screens B
    (planner/lunches/activity/settings/more/overlays + 116 tests),
    desktop (phase 7), Android (phase 8), soak+docs (phase 9).
  - Three parallel string/token tables exist and all carry the same
    values: shell `Strings`/`Tokens`, features `AppStrings`/`AppTokens`,
    widgets `Str`. Same for `schedule_logic`/`grades_logic` (features)
    vs canonical core ports — unification is reviewer work (Checkpoint B).
  - Feature controllers are a mix of `ChangeNotifier` (today/timetable/
    absences/marks/wizard) and plain listener-list classes
    (planner/lunches/activity/settings); the shell passes default
    instances until the `AppState` live-data wiring lands (reviewer work).
  - `NavigationBarDestination` doesn't exist in Flutter 3.44.8 — the
    bottom bar uses `NavigationDestination` (same visuals/API shape).
  - `launch_at_startup` pinned to `^0.5.1`, `tray_manager` to `^0.5.2`
    (0.6+ needs Dart ≥3.13; SDK is 3.12.2); `go_router ^18.0.0`,
    `clock ^1.1.0` (flutter_test pins 1.1.2).
  - The flutter-create counter template test is replaced by an app-boots
    + rail-navigation smoke test (its subject no longer exists).
  - Router builders construct each screen with default controllers
    (empty data → empty-state cards, like a fresh install); live
    `AppState` wiring is the documented next step, not a silent change.
  - Root-library `backgroundMain()` is a one-line trampoline into
    `platform/android/background.dart` (the engine resolves the fallback
    name in the root library).
  - Screenshots side-by-side (`build/parity-screens/`) not produced —
    no Flet screenshots exist yet; the widget-test suite + rail pass
    stand in until the reviewer runs the comparison.
- Phase 7 adaptations: one process, async loop instead of core
  `PeriodicRunner`; macOS/Linux keystores via CLI (`security`,
  `secret-tool`) not native APIs; `dart.vm.product` instead of
  `sys.frozen`; toast GUID reuses the Inno AppId. Full list in
  `docs/flutter-migration/phase-7-desktop.md`. macOS/Linux/packaging/CI
  parts written but UNVERIFIED.
- Phase 8 adaptations: 6 Java files gain one `R` import line (namespace
  change); `prod` flavor keeps `applicationId io.github.dendlerx.strakalari`,
  new `phonetest` flavor builds the `.test` package (`test` is rejected
  by AGP as a flavor name); core keystore/wakeup bridges are sync while
  channels are async — solved with per-isolate warm-up + in-memory
  bridges, needs reviewer sign-off.
- Phase 9: soak scripts are new files under `tools/parity/`
  (`soak_refresh.py`, `soak_compare.py`); docs wording updated (README,
  PRIVACY, CONTRIBUTING); no tag/merge/push performed.

## Questions for the owner / reviewer

- ⛔ Checkpoints B + C reached: please have a reviewer model check phases
  5–8 (Checkpoint notes below) before phase 10. Open decisions:
  1. Unify the three string/token tables + feature `schedule_logic`/
     `grades_logic` onto the canonical core ports now, or keep the
     duplication until the `AppState` live-data wiring lands?
  2. `flutter build` now requires `--flavor prod|phonetest` — confirm the
     flavor names (AGP rejects `test`) and the release-signing inputs
     (`~/.strakalari-signing/android-release.properties` or env).
  3. `backgroundMain` trampoline placement (root library delegates to
     `platform/android/background.dart`) — confirm against the
     `RefreshReceiver` wiring.
  4. Confirm `--forget-secrets`/`--minimized` flags + `LSUIElement` for
     macOS + whether `launch_at_startup` stays a dependency (currently
     unused by the ported code).
  5. Screenshots parity (`build/parity-screens/`): produce Flet shots
     first (`tools/demo_data.py screenshots`), then Flutter shots?
  6. Beta release (Checkpoint D): cut from the branch only on your go.
- ⛔ Checkpoint A reached: please have a reviewer model check phases 3–4
  (Checkpoint notes below) before phase 5 starts. Open decisions:
  1. `planAutoOrdersHook` is sync but the real `planAutoOrders` is async
     (network/Gemini) — confirm the hook stays throwing until the async
     boundary is reworked (phase 5/9), or dictate the async contract now.
  2. Should `bin/refresh_dryrun.dart` (`--send-day` real-submit proof,
     demo server only) stay in-tree after review, or move to scratch-only?
  3. `planAutoOrders` has no `today` param in Python (past-day skip uses
     the real clock) — add an optional `today` seam for determinism, or
     keep line-by-line?
  4. Confirm the seam-hook names/signatures as the phase-3↔4 contract.
  5. Same-latent-DST-drift `Duration(days: …)` iterations left untouched
     in schedule/wakeup/status_notification — fix everywhere now, or
     accept (tests green either way; Prague DST only matters Mar/Oct)?
- App version stays the flutter-create template `1.0.0+1` (resolved 2026-11-07:
  CI stamps the real version from the tag at build time).
- (Resolved 2026-11-07: PLAN.md rows 7–8 and REVIEW_PROMPT.md are the owner's
  intended edits, committed as-is.)

## Checkpoint notes

- 2026-11-08 · Checkpoint A review: **FAIL** (5 blockers, 8 must-fix) — [docs/flutter-migration/reviews/checkpoint-A.md](docs/flutter-migration/reviews/checkpoint-A.md)

### ⛔ Checkpoint A: core review (phases 3–4)

Done: all 15 phase-3 modules + automation/refresh/scheduler/session_lock/
error_report ported with Dart tests first (same cases, camelCase, same
values); `tools/parity/dump.py` extended with 16 generators (344 cases);
`dart analyze` + `flutter analyze` clean; Dart suite 720/720 green;
Python suite 1643/1643 green (reference, unchanged); dry-run refresh
parity Python-vs-Dart fully equal (result, cache keys incl.
`stable_baseline`, audit modulo ts, outbox, history).

Every deviation from Python is listed under Deviations above; Python
behavior that looked wrong was ported as-is (nothing "fixed").
How to verify:
- `dart analyze` + `dart test` in `packages/strakalari_core`,
  `flutter analyze` in `app` (template test only until phase 5).
- `PYTHONUTF8=1 python tools/parity/dump.py` then
  `git diff --exit-code packages/strakalari_core/test/parity/`
  (hand-edits would show; the 4 oracle-caught fixes are recorded above).
- Dry-run parity: `python tools/bakalari_demo_server.py --port 18080`,
  Python `scratch parity4/refresh_dryrun.py --data-dir <tmp>` vs Dart
  `bin/refresh_dryrun.dart --url … --data-dir <tmp>`; canonical JSON
  must match modulo `ts`. (`--send-day DD.MM.YYYY` real-submit proof was
  run on fresh servers on both sides: sent/history/outbox equal.)
- Cross-process session lock proof: set `STRAKALARI_SESSION_LOCK_HOLDER=1`
  + `STRAKALARI_SESSION_LOCK_PATH=<lock>` and run
  `dart test/session_lock_test.dart` while Python holds the same lock
  (and vice versa) — both directions proven on this PC.
Unsure / needs a second pair of eyes:
- The sibling `Duration(days: …)` day iterations (see Deviations) and
  the `planAutoOrdersHook` async boundary (see Questions).
- `error_report.collectContext` keys `dart` (not `python`),
  `app_version: '?'` (no update module at port time — since landed,
  still `'?'`), `build: 'source'`; `currentTraceback` frames are Dart
  `#0` style. Shapes match; values are platform truth.
- `summarize` keeps insertion order on equal/None dates explicitly
  (Dart sort isn't stable; Python's is); `summarizeAll`/`canonSubject`
  use `toLowerCase` (Python `casefold` — differs only for exotic
  Unicode like ß); `int(True)`-style bool periods return null.
- Gemini `localFallbackRecommendation` keyword lists ported line by
  line (Czech stems); only covered via parity fixtures + fakes.

### ⛔ Checkpoint B: UI review (phases 5–6)

Done: shell (router/scaffold/theme/ARB/controllers/widgets/error
dialog/tutorials/platform seams) + all 10 screens wired into the
router with real views + controllers; `flutter analyze` clean;
`flutter test` 120+ green (116 feature tests + boots/navigation smoke
+ layout breakpoints), core suite 720/720 still green.
Every deviation is listed under Deviations above; Python behavior that
looked wrong was ported as-is (nothing "fixed").
How to verify:
- `flutter analyze` + `flutter test` in `app/` (template counter test
  replaced by the boots/navigation smoke test — recorded above).
- Boot on a demo data dir (`tools/demo_data.py generate DIR`,
  `STRAKALARI_DATA_DIR=DIR`): every rail destination renders its real
  screen (empty-state cards with no data, like a fresh install).
- Screenshots parity still open (see Questions 5).
Unsure / needs a second pair of eyes:
- The three string/token tables + feature-local `schedule_logic`/
  `grades_logic` duplicates (see Deviations) — unify now or later?
- Router passes default (empty) controllers; the `AppState` live-data
  wiring (config/save/send/test/refresh callbacks) is the next step.
- `wakeupAvailable` stubs to false (Android-only, phase 8).

### ⛔ Checkpoint C: platform review (phases 7–8)

Done in code, largely UNVERIFIED on this machine (see the per-area
notes): desktop tray/autostart/single-instance/notifications/keystores,
Inno (AppId kept) + MSIX adaptations, CI release jobs; Android Java
moved + MethodChannel + headless `backgroundMain` + boot re-arm +
widget/alarms + Keystore unwrap + `.test` flavor + privacy test.
How to verify:
- `flutter analyze` (clean); `:app:compileProd/PhonetestDebugSources`
  BUILD SUCCESSFUL; `packaging_privacy_test.dart` 4 pass + 1 skip
  (needs `STRAKALARI_APK/AAB`).
- Sandbox over-install test (phase 7) and on-phone `.test` test
  (phase 8) — exact steps in the agents' reports / phase-7-desktop.md.
  Before the first phone install the owner confirms the `.test` app is
  on dry run / demo server.
Unsure / needs a second pair of eyes:
- Sync-core-bridge vs async-channel seams (phase 8 warm-up design).
- macOS/Linux code paths, release builds, CI jobs — owner/CI must run.

### ⛔ Checkpoint D: release review (phase 9)

Soak prep done: `tools/parity/soak_refresh.py` + `soak_compare.py`,
`docs/flutter-migration/SOAK.md` routine, README/PRIVACY/CONTRIBUTING
wording. Dry-run parity IDENTICAL (modulo ts), fetch parity
byte-identical, both suites green. The multi-day side-by-side soak and
the beta cut wait for the owner's go-ahead — no tag/merge/push done.

Phase 1 cross-implementation proofs (for Checkpoint A):
- Fernet: Dart decrypted a Python-made token and Python decrypted a
  Dart-made token (Czech diacritics intact), via throwaway keys in the
  scratch dir (never committed). Committed fernet_test.dart covers
  roundtrip, version byte, tamper, wrong key and garbage.
- File lock: with Python holding `InterProcessLock` on a scratch file,
  Dart `InterProcessLock.acquire()` returned false (same LockFileEx byte
  on Windows, PLAN §3.5); same-process second-handle contention is
  covered by `helpers_test.dart` (`secondObjectFailsWhileHeld`).
- Session lock: both directions proven live (see Checkpoint A above).
