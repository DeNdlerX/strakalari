# Flutter migration status

Branch: flutter-migration · Flutter: 3.44.8 · Last main commit ported: 0ffdcff
Current phase: 1 · Next step: Phase 1 — port strakalari/core/helpers.py (pure part, no crypto).

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
| strakalari/core/audit.py | core automation/audit.dart | test_refresh_pipeline.py (audit entries) | todo |
| strakalari/core/automation.py | core automation/automation.dart | test_automation_safety.py | todo |
| strakalari/core/autostart.py | core platform/autostart.dart + app impl | test_autostart.py, test_autostart_platforms.py | todo |
| strakalari/core/bakalari_client.py | core bakalari/client.dart | test_bakalari_client.py | todo |
| strakalari/core/bakalari_common.py | core bakalari/common.dart | (covered by client/data tests) | todo |
| strakalari/core/bakalari_data.py | core bakalari/data.dart | test_absence_details.py, test_marks_view.py, test_sent_excuses.py, test_substitution_feed_days.py | todo |
| strakalari/core/bakalari_excuse.py | core bakalari/excuse.dart | test_bakalari_excuse.py, test_excuse_generation.py | todo |
| strakalari/core/bakalari_http.py | core bakalari/http_session.dart | test_bakalari_http.py | todo |
| strakalari/core/bakalari_timetable.py | core bakalari/timetable.dart | test_timetable_cache_merge.py | todo |
| strakalari/core/cache.py | core storage/cache.dart | test_cache.py | todo |
| strakalari/core/cancel.py | core automation/cancel.dart | test_cancel_responsive.py, test_refresh_cancel_keeps_data.py | todo |
| strakalari/core/config.py | core storage/config.dart | test_config.py, test_config_save_lock.py | todo |
| strakalari/core/error_report.py | core error_report.dart | test_error_report.py, test_log_redaction.py | todo |
| strakalari/core/excuse_history.py | core automation/excuse_history.dart | test_excuse_history.py, test_excuse_day_scope.py, test_excuse_ignore_list.py, test_unconfirmed_excuses.py | todo |
| strakalari/core/extractors/__init__.py | core bakalari/ + strava/ barrels | — | todo |
| strakalari/core/extractors/bakalari.py | core bakalari/extractors.dart | (covered by client/data tests) | todo |
| strakalari/core/extractors/strava.py | core strava/extractors.dart | (covered by strava tests) | todo |
| strakalari/core/forecast.py | core planning/forecast.dart | test_forecast.py | todo |
| strakalari/core/gemini.py | core lunches/gemini.dart | test_gemini_key.py, test_gemini_picks.py, test_ai_recommend.py | todo |
| strakalari/core/grades.py | core planning/grades.dart | test_grades.py, test_grades_math.py, test_grades_minus.py | todo |
| strakalari/core/helpers.py | core storage/helpers.dart | test_helpers.py, test_session_lock.py | todo |
| strakalari/core/i18n.py | core i18n.dart | test_i18n.py (core cases) → i18n_test.dart 4 + parity_i18n_test.dart | done |
| strakalari/core/lunch_auto.py | core lunches/lunch_auto.dart | test_lunch_auto.py, test_lunch_auto_user_choice.py, test_lunch_same_pick.py | todo |
| strakalari/core/lunch_cutoff.py | core lunches/lunch_cutoff.dart | test_lunch_cutoff.py, test_lunch_day_keys.py, test_lunch_deadline_calendar.py | todo |
| strakalari/core/matching.py | core planning/matching.dart | test_matching.py | todo |
| strakalari/core/models.py | core models/ | test_models.py | todo |
| strakalari/core/news.py | core news.dart | test_news.py | todo |
| strakalari/core/notify.py | core platform/notifier.dart + app impl | test_notify.py | todo |
| strakalari/core/packaging.py | core platform/packaging.dart | test_mobile.py (predicates) → packaging_test.dart 9 | done |
| strakalari/core/planned_skips.py | core planning/planned_skips.dart | test_planned_skips.py, test_early_leave.py | todo |
| strakalari/core/planner.py | core planning/planner.dart | test_plan_picker.py, test_plan_reserve.py, test_year_planner.py | todo |
| strakalari/core/refresh.py | core automation/refresh.dart | test_refresh_pipeline.py, test_data_safety.py | todo |
| strakalari/core/schedule.py | core planning/schedule.dart | test_schedule.py | todo |
| strakalari/core/scheduler.py | core automation/scheduler.dart | test_scheduler.py, test_scheduler_retry.py | todo |
| strakalari/core/school_presets.py | core planning/school_presets.dart | test_school_calendar.py | todo |
| strakalari/core/secret_store.py | core storage/secret_store.dart + KeyStore iface | test_secret_store.py, test_gemini_key.py | todo |
| strakalari/core/status_notification.py | core status_notification.dart | test_status_notification.py | todo |
| strakalari/core/strava_client.py | core strava/client.dart | test_strava_client.py, test_strava_low_balance.py | todo |
| strakalari/core/strava_ordering.py | core strava/ordering.dart | test_strava_ordering.py, test_order_latch.py, test_strava_blacklist_edits.py | todo |
| strakalari/core/tls.py | — (dropped, see below) | test_tls_bundle.py, test_frozen_ssl.py | dropped |
| strakalari/core/update.py | core update.dart | test_update.py | todo |
| strakalari/core/wakeup.py | core wakeup.dart | test_wakeup_and_widget.py, test_wake_ui.py | todo |
| strakalari/flet_ui/__init__.py | app barrel | — | todo |
| strakalari/flet_ui/__main__.py | app/lib/main.dart | test_entry_routing.py | todo |
| strakalari/flet_ui/app.py | app/lib/main.dart + shell/ | test_ui_views.py, test_open_url.py | todo |
| strakalari/flet_ui/assets.py | app assets | test_icons.py | todo |
| strakalari/flet_ui/components.py | app/lib/widgets/ | test_ui_views.py | todo |
| strakalari/flet_ui/macos.py | app/lib/platform/desktop/ | test_macos_tray_host.py, test_macos_data_dir.py | todo |
| strakalari/flet_ui/overlays.py | app/lib/widgets/ | test_ui_views.py | todo |
| strakalari/flet_ui/safety.py | app shell/controllers | test_automation_safety.py (UI part) | todo |
| strakalari/flet_ui/single_instance.py | app/lib/platform/desktop/ | test_single_instance.py | todo |
| strakalari/flet_ui/startup.py | app/lib/main.dart startup | test_entry_routing.py, test_shutdown.py | todo |
| strakalari/flet_ui/state.py | app controllers + appStateProvider | test_ui_state.py | todo |
| strakalari/flet_ui/state_activity.py | app features/activity controller | test_flet_data_wiring.py | todo |
| strakalari/flet_ui/state_excuses.py | app features/absences controller | test_flet_data_wiring.py | todo |
| strakalari/flet_ui/state_lunches.py | app features/lunches controller | test_lunch_filter.py | todo |
| strakalari/flet_ui/state_marks.py | app features/marks controller | test_marks_view.py | todo |
| strakalari/flet_ui/state_planner.py | app features/planner controller | test_planner_dialog.py | todo |
| strakalari/flet_ui/state_tutorial.py | app features controller | test_tutorial.py | todo |
| strakalari/flet_ui/strings.py | app l10n ARB (generated) | test_settings_sections.py | todo |
| strakalari/flet_ui/theme.py | app/lib/shell/theme.dart | (screenshots, phase 6) | todo |
| strakalari/flet_ui/tray.py | app/lib/platform/desktop/ | test_tray_ui_command.py, test_minimize_to_tray.py | todo |
| strakalari/flet_ui/tutorial.py | app/lib/tutorial/ | test_tutorial.py | todo |
| strakalari/flet_ui/views/__init__.py | app features barrel | — | todo |
| strakalari/flet_ui/views/absences.py | app features/absences | test_ui_views.py | todo |
| strakalari/flet_ui/views/activity.py | app features/activity | test_ui_views.py | todo |
| strakalari/flet_ui/views/lunches.py | app features/lunches | test_ui_views.py | todo |
| strakalari/flet_ui/views/marks.py | app features/marks | test_marks_view.py | todo |
| strakalari/flet_ui/views/more.py | app adaptive shell | test_ui_views.py | todo |
| strakalari/flet_ui/views/planner.py | app features/planner | test_ui_views.py, test_year_planner.py | todo |
| strakalari/flet_ui/views/settings/__init__.py | app features/settings | test_settings_sections.py | todo |
| strakalari/flet_ui/views/settings/accounts.py | app features/settings | test_wizard_setup.py | todo |
| strakalari/flet_ui/views/settings/app_prefs.py | app features/settings | test_settings_quiet_save.py | todo |
| strakalari/flet_ui/views/settings/automation.py | app features/settings | test_settings_refresh_interactive.py | todo |
| strakalari/flet_ui/views/settings/common.py | app features/settings | test_settings_sections.py | todo |
| strakalari/flet_ui/views/settings/school_calendar.py | app features/settings | test_school_calendar.py | todo |
| strakalari/flet_ui/views/settings/view.py | app features/settings | test_settings_sections.py | todo |
| strakalari/flet_ui/views/timetable.py | app features/timetable | test_timetable_week_nav.py, test_timetable_week_switch.py | todo |
| strakalari/flet_ui/views/today.py | app features/today | test_ui_views.py | todo |
| strakalari/flet_ui/views/wizard.py | app features/wizard | test_wizard_setup.py | todo |

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

- test_i18n.py → `test_core_messages_follow_language` moves to phase 4
  (needs `error_report.timeout_user_message`); `test_new_flet_strings_present`
  + `test_dead_keys_removed_and_live_keys_kept` move to phase 5 (need
  `flet_ui.strings`).
- test_models.py → `test_engine_excuses_neomluveno_day` +
  `test_engine_excuses_unexcused_type` move to phase 4 (need
  `automation.Strakalari.generate_excuses`).

## Dropped (with reason)

- `strakalari/core/tls.py` — Dart uses the OS trust store; no frozen CA bundle
  (PLAN §3.2). Reviewer sign-off still pending at the relevant checkpoint.

## Deviations from Python (each needs reviewer sign-off)

None yet.

## Questions for the owner / reviewer

- App version stays the flutter-create template `1.0.0+1` (resolved 2026-11-07:
  CI stamps the real version from the tag at build time).
- (Resolved 2026-11-07: PLAN.md rows 7–8 and REVIEW_PROMPT.md are the owner's
  intended edits, committed as-is.)

## Checkpoint notes

None yet (first checkpoint is A at end of phase 4).
