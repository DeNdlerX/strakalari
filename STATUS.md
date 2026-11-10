# Flutter migration status

Branch: flutter-migration · Flutter: 3.44.8 · Last main commit ported: 0ffdcff
Current phase: 6 · Next step: Fix finding B-M11 (screen visual parity from side-by-side screenshots) in `reviews/checkpoint-B.md`, then proceed through must-fix findings B-M12 to B-M14.
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
⛔ Checkpoint A: core review (re-review 3: **PASS**, 2026-11-09).
Phase 5 (app shell) is complete: Riverpod controllers (AppState + 6 facades),
go_router (8 routes + wizard + more), adaptive scaffold (720/520
breakpoints, rail ↔ bar + More, landscape side rail), theme tokens,
ARB strings (794 keys + 13 notif_*), shared widgets, error dialog with
Copy log/Share, tutorial tours, platform seams. Live `AppState` → core
wiring and all AppState test suites green.
Phase 6 (screens) is complete: all 10 screens wired into the router with
live views + controllers (wizard, today, timetable, absences, marks,
planner, lunches, activity, settings, more); 241 tests passing (1 skipped);
live `AppState` wiring and deferred phase-5/6 tests ported & verified;
10 Flet vs Flutter parity screenshots captured in build/parity-screens/.
⛔ Checkpoint B: UI review reached (pending reviewer sign-off).
Phase 7 (desktop) is in progress, unreviewed: tray + hide-to-tray, autostart,
single-instance loopback-TCP, notifications, desktop keystores, Inno
(AppId kept) + MSIX adaptations, CI release jobs written in code;
unverified on this PC except `flutter analyze`; Sandbox over-install test
and desktop platform tests pending.
Phase 8 (Android) is in progress, unreviewed: Java moved unchanged (+1 R import
line in 6 files), StrakalariChannel, headless backgroundMain with
UI-isolate hand-off, boot re-arm, widget/alarms, Keystore unwrap,
`.test` flavor, privacy test port. `:app:compileProd/PhonetestDebugSources`
green, `flutter analyze` clean. On-phone verification pending.
⛔ Checkpoint C: platform review (unreviewed).
Phase 9 (soak prep) is in progress, unreviewed: soak_compare/soak_refresh scripts,
SOAK.md routine, README/CONTRIBUTING/PRIVACY wording; multi-day soak not
yet run. Beta release waits for Checkpoint A–D sign-off and the owner's
go-ahead. ⛔ Checkpoint D: release review (unreviewed).
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

State: todo = not started, tests = Dart tests written, in progress, unreviewed = code drafted ahead of review, done = ported + green.

| Python file | Dart file | Tests (py → dart) | State |
|---|---|---|---|
| strakalari/__init__.py | version export (core/app) | — | todo |
| strakalari/__main__.py | app/lib/main.dart | — | in progress, unreviewed |
| strakalari/core/__init__.py | core barrel | — | done |
| strakalari/core/android.py | core platform/android_bridge.dart + app MethodChannel | test_notify.py, test_wake_ui.py, test_wakeup_and_widget.py | in progress, unreviewed |
| strakalari/core/audit.py | core automation/audit.dart | test_automation_safety.py (audit cases) → audit_test.dart (4) + parity_audit_test.dart | done |
| strakalari/core/automation.py | core automation/automation.dart | test_automation_safety.py (core cases), test_excuse_generation.py (25), test_strava_low_balance.py (2 order cases), test_strava_ordering.py (15), test_unconfirmed_excuses.py (TestSendPath/TestOutboxSettles), test_excuse_history.py (send/coverage/dry-run cases) → automation_test.dart (78) + refresh_test.dart; `test_order_latch.py` (4) is `AppState` (deferred phase 5) | done |
| strakalari/core/autostart.py | core platform/autostart.dart + app impl | test_autostart.py, test_autostart_platforms.py (deferred phase 7) | in progress, unreviewed |
| strakalari/core/bakalari_client.py | core bakalari/client.dart | test_bakalari_client.py (base cases) → bakalari_client_test.dart (8) | done |
| strakalari/core/bakalari_common.py | core bakalari/common.dart | client/data tests (hour-index, week offsets, removed/room-move rows) → common_test.dart (9) | done |
| strakalari/core/bakalari_data.py | core bakalari/data.dart (DataMixin) | test_bakalari_http.py (read cases), test_sent_excuses.py, test_grades.py (client cases) → bakalari_data_test.dart (16); `fetchData` + `updateStableBaseline` wired | done |
| strakalari/core/bakalari_excuse.py | core bakalari/excuse.dart (ExcuseFormMixin) | test_bakalari_excuse.py → bakalari_excuse_test.dart (12) + parity (excuse cases in bakalari.json) | done |
| strakalari/core/bakalari_http.py | core bakalari/http_session.dart | test_bakalari_http.py (session cases) → http_session_test.dart (11) + parity_http_session_test.dart | done |
| strakalari/core/bakalari_timetable.py | core bakalari/timetable.dart (TimetableMixin on BakalariClientBase) | test_bakalari_client.py (add/perm/stable/week cases) → timetable_test.dart (7) | done |
| strakalari/core/cache.py | core storage/cache.dart | test_cache.py + merge/seed/busy cases from test_timetable_cache_merge, test_data_safety, test_scheduler → cache_test.dart (19) + parity_cache_test.dart | done |
| strakalari/core/cancel.py | core automation/cancel.dart | ported with the session (covered by http_session_test + refresh_test); UI cases in test_cancel_responsive.py → deferred phase 5 | done |
| strakalari/core/config.py | core storage/config.dart | test_config.py, test_config_save_lock.py → config_test.dart (34) + automation_test.dart (3) + parity_config_test.dart | done |
| strakalari/core/error_report.py | core error_report.dart (full port: redaction, report builders; `UserError`/`timeoutUserMessage` API unchanged) | test_error_report.py (core cases), test_log_redaction.py → error_report_test.dart (16) + parity_error_report_test.dart; UI popup/clipboard cases → deferred phase 5 | done |
| strakalari/core/excuse_history.py | core automation/excuse_history.dart | test_excuse_history.py, test_unconfirmed_excuses.py (pure cases) → excuse_history_test.dart (20) + parity_excuse_history_test.dart | done |
| strakalari/core/extractors/__init__.py | core bakalari/ + strava/ barrels | — | done |
| strakalari/core/extractors/bakalari.py | core bakalari/extractors.dart | grades/sent-excuses/substitution/parity cases → extractors_test.dart (22) + parity_bakalari_test.dart | done |
| strakalari/core/extractors/strava.py | core strava/extractors.dart | menu/food asserts in strava_test.dart + parity_strava_test.dart | done |
| strakalari/core/forecast.py | core planning/forecast.dart | test_forecast.py, test_absence_details.py → forecast_test.dart (16) + parity_forecast_test.dart | done |
| strakalari/core/gemini.py | core lunches/gemini.dart | test_gemini_key.py, test_gemini_picks.py, test_ai_recommend.py (pure/client cases) → gemini_test.dart (16) + parity_gemini_test.dart; 4 `AppState` worker cases in test_ai_recommend.py → deferred phase 5 | done |
| strakalari/core/grades.py | core planning/grades.dart | test_grades.py, test_grades_math.py, test_grades_minus.py → grades_test.dart (24) + parity_grades_test.dart (extractor/client cases in extractors_test.dart / bakalari_data_test.dart) | done |
| strakalari/core/helpers.py | core storage/helpers.dart | test_helpers.py → helpers_test.dart (24) + fernet_test.dart (5) + secret_store_test.dart (1) + parity_helpers_test.dart; test_session_lock.py → session_lock_test.dart (11) | done |
| strakalari/core/i18n.py | core i18n.dart | test_i18n.py (core cases) → i18n_test.dart (4) + parity_i18n_test.dart; 2 `flet_ui.strings` cases → deferred phase 5 | done |
| strakalari/core/lunch_auto.py | core lunches/lunch_auto.dart | test_lunch_auto.py (11), test_lunch_auto_user_choice.py (5 `TestAutoFillsGapsOnly` cases) → lunch_auto_test.dart (17) + parity_lunch_auto_test.dart (`test_keep_lunch_choice_is_stored_and_honored` in planned_skips_test.dart; 2 AppState cases + `test_lunch_same_pick.py` (5) → deferred phase 5) | done |
| strakalari/core/lunch_cutoff.py | core lunches/lunch_cutoff.dart | test_lunch_cutoff.py (pure cases), test_lunch_day_keys.py, test_lunch_deadline_calendar.py → lunch_cutoff_test.dart (11) + parity_lunch_cutoff_test.dart (AppState cases → deferred phase 5) | done |
| strakalari/core/matching.py | core planning/matching.dart | test_matching.py → matching_test.dart (8) + parity_matching_test.dart | done |
| strakalari/core/models.py | core models.dart | test_models.py → models_test.dart (18) + automation_test.dart (2) + parity_models_test.dart | done |
| strakalari/core/news.py | core news.dart | test_news.py (pure cases) → news_test.dart (6) + parity_news_test.dart (`test_refresh_reports_news_against_the_cache` → deferred phase 5 `AppState`) | done |
| strakalari/core/notify.py | core platform/notifier.dart (abstract Notifier interface; OS impls → phase 7) | test_notify.py (core cases) → notifier_test.dart (9); OS backend cases → deferred phase 7 | done |
| strakalari/core/packaging.py | core platform/packaging.dart | test_mobile.py (predicates) → packaging_test.dart (9) | done |
| strakalari/core/planned_skips.py | core planning/planned_skips.dart | test_planned_skips.py (11 pure cases), test_lunch_auto_user_choice.py (`test_keep_lunch_choice_is_stored_and_honored`) → planned_skips_test.dart (20) + parity_planned_skips_test.dart (6 `AppState` persist/rollback cases in test_planned_skips.py → `app/test/planner_view_test.dart` / deferred phase 5) | done |
| strakalari/core/planner.py | core planning/planner.dart | test_year_planner.py (18 pure plan cases), test_plan_reserve.py (pure reserve validation) → planner_test.dart (19) + parity_planner_test.dart (`AppState`/dialog cases → `app/test/planner_*` / deferred phase 5–6) | done |
| strakalari/core/refresh.py | core automation/refresh.dart | test_refresh_pipeline.py, test_data_safety.py, test_refresh_cancel_keeps_data.py, test_session_lock.py + gate cases → refresh_test.dart (21); `bin/refresh_dryrun.dart` | done |
| strakalari/core/schedule.py | core planning/schedule.dart | test_schedule.py (24), test_substitution_feed_days.py (1) → schedule_test.dart (26) + dst_test.dart (10) + parity_schedule_test.dart | done |
| strakalari/core/scheduler.py | core automation/scheduler.dart | test_scheduler.py (10 core cases), test_scheduler_retry.py (2 core `PeriodicRunner` cases: `intervalProviderIsPolled`, `jobFailedCountsAsFailureButReported`) → scheduler_test.dart (13) + parity_scheduler_test.dart; 3 `flet_ui.app`/`tray` cases in test_scheduler.py + 5 window/tray cases in test_scheduler_retry.py → deferred phase 5/7 | done |
| strakalari/core/school_presets.py | core planning/school_presets.dart | test_school_calendar.py → school_presets_test.dart (15) + parity_school_presets_test.dart | done |
| strakalari/core/secret_store.py | core storage/secret_store.dart + platform/keystore.dart (+ android_bridge.dart iface) | test_secret_store.py → secret_store_test.dart (12); Fernet roundtrip/tamper/key tests → fernet_test.dart (5) | done |
| strakalari/core/status_notification.py | core status_notification.dart | test_status_notification.py (39 core cases) → status_notification_test.dart (39) + parity_status_notification_test.dart; 12 Android/UI cases → deferred phase 5/8 | done |
| strakalari/core/strava_client.py | core strava/client.dart (StravaClientBase) | test_strava_client.py (client cases) → strava_test.dart (19) + parity (strava cases in strava.json) | done |
| strakalari/core/strava_ordering.py | core strava/ordering.dart (OrderingMixin) | test_strava_client.py (order/save cases) → strava_test.dart + order-sheet byte test | done |
| strakalari/core/tls.py | — (dropped, see below) | test_tls_bundle.py, test_frozen_ssl.py | dropped |
| strakalari/core/update.py | core update.dart | test_update.py (40 core cases) → update_test.dart (40) + parity_update_test.dart; 6 `flet_ui`/config-state cases → deferred phase 5 | done |
| strakalari/core/wakeup.py | core wakeup.dart (pure scheduling/message logic; alarms/receivers → phase 8) | test_wakeup_and_widget.py (21 core cases) → wakeup_test.dart (21) + parity_wakeup_test.dart; 21 UI/extension-wheel cases + test_wake_ui.py (2) → deferred phase 5–8 | done |
| strakalari/flet_ui/__init__.py | app barrel (shell + features) | — | in progress, unreviewed |
| strakalari/flet_ui/__main__.py | app/lib/main.dart | widget_test.dart smoke (boots + rail navigation) | in progress, unreviewed |
| strakalari/flet_ui/app.py | app/lib/main.dart + shell/ | widget_test.dart smoke; navigation covered | in progress, unreviewed |
| strakalari/flet_ui/assets.py | app assets | test_icons.py | todo |
| strakalari/flet_ui/components.py | app/lib/widgets/ | overlays_test.dart (8) | in progress, unreviewed |
| strakalari/flet_ui/macos.py | app/lib/platform/desktop/ (tray hosts window, data dir) | — (macOS unverified) | in progress, unreviewed |
| strakalari/flet_ui/overlays.py | app/lib/widgets/overlays.dart + error_dialog.dart | overlays_test.dart (8) | in progress, unreviewed |
| strakalari/flet_ui/safety.py | app shell/controllers (confirm-auto guards) | settings_quietsave_test.dart | in progress, unreviewed |
| strakalari/flet_ui/single_instance.py | app/lib/platform/desktop/single_instance.dart | — (manual py↔dart exclusion proof, phase 7 notes) | in progress, unreviewed |
| strakalari/flet_ui/startup.py | app/lib/main.dart startup (stdio guards n/a on Flutter) | widget_test.dart smoke | in progress, unreviewed |
| strakalari/flet_ui/state.py | app/lib/controllers/app_state.dart | widget_test.dart + settings tests | in progress, unreviewed |
| strakalari/flet_ui/state_activity.py | app controllers/activity + features/activity | activity_state_test.dart (10) + activity_view_test.dart (6) | in progress, unreviewed |
| strakalari/flet_ui/state_excuses.py | app controllers/excuses + features/today + absences | wizard/today/absences via widget_test rail pass | in progress, unreviewed |
| strakalari/flet_ui/state_lunches.py | app controllers/lunches + features/lunches | lunches_filter_test.dart (15) + lunches_view_test.dart (9) | in progress, unreviewed |
| strakalari/flet_ui/state_marks.py | app controllers/marks + features/marks | widget_test.dart rail pass | in progress, unreviewed |
| strakalari/flet_ui/state_planner.py | app controllers/planner + features/planner | planner_reserve_test.dart (12) + planner_view_test.dart (10) | in progress, unreviewed |
| strakalari/flet_ui/state_tutorial.py | app controllers/tutorial + tutorial/tours | tutorial_test.dart (28) | done |
| strakalari/flet_ui/strings.py | app l10n ARB (app_cs/en + strings.dart) | settings_sections_test.dart (15) | in progress, unreviewed |
| strakalari/flet_ui/theme.py | app/lib/shell/theme.dart | widget_test.dart breakpoints | in progress, unreviewed |
| strakalari/flet_ui/tray.py | app/lib/platform/desktop/tray.dart | — (Sandbox test pending) | in progress, unreviewed |
| strakalari/flet_ui/tutorial.py | app/lib/tutorial/ + widgets/overlays (kTours) | tutorial_test.dart (28) | done |
| strakalari/flet_ui/views/__init__.py | app features barrel (router) | widget_test.dart rail pass | in progress, unreviewed |
| strakalari/flet_ui/views/absences.py | app features/absences | widget_test.dart rail pass | in progress, unreviewed |
| strakalari/flet_ui/views/activity.py | app features/activity | activity_view_test.dart (6) | in progress, unreviewed |
| strakalari/flet_ui/views/lunches.py | app features/lunches | lunches_view_test.dart (9) | in progress, unreviewed |
| strakalari/flet_ui/views/marks.py | app features/marks | widget_test.dart rail pass | in progress, unreviewed |
| strakalari/flet_ui/views/more.py | app features/more.dart | overlays_test.dart +more (8) | in progress, unreviewed |
| strakalari/flet_ui/views/planner.py | app features/planner | planner_view_test.dart (10) | in progress, unreviewed |
| strakalari/flet_ui/views/settings/__init__.py | app features/settings | settings_sections_test.dart (15) | in progress, unreviewed |
| strakalari/flet_ui/views/settings/accounts.py | app features/settings | wizard_settings_test.dart (5) | in progress, unreviewed |
| strakalari/flet_ui/views/settings/app_prefs.py | app features/settings | settings_quietsave_test.dart (6) | in progress, unreviewed |
| strakalari/flet_ui/views/settings/automation.py | app features/settings | settings_sections_test.dart (15) | in progress, unreviewed |
| strakalari/flet_ui/views/settings/common.py | app features/settings | settings_sections_test.dart (15) | in progress, unreviewed |
| strakalari/flet_ui/views/settings/school_calendar.py | app features/settings | settings_sections_test.dart (15) | in progress, unreviewed |
| strakalari/flet_ui/views/settings/view.py | app features/settings | settings_sections_test.dart (15) | in progress, unreviewed |
| strakalari/flet_ui/views/timetable.py | app features/timetable | widget_test.dart rail pass | in progress, unreviewed |
| strakalari/flet_ui/views/today.py | app features/today | widget_test.dart rail pass | in progress, unreviewed |
| strakalari/flet_ui/views/wizard.py | app features/wizard | wizard_settings_test.dart (5) | in progress, unreviewed |

## Tests (per-file Python test → Dart test / Deferred / Dropped mapping)

Every Python `tests/test_*.py` file (94 files) is mapped below to its Dart test(s) in `packages/strakalari_core/test/` or `app/test/`, or marked **Deferred (phase N)** (when its SUT is in phases 5–8) or **Dropped (reason)**.

1. `tests/test_absence_details.py` (6) → `forecast_test.dart`:
   - `test_canon_subject_collapses_nbsp_and_case` → `collapses nbsp and case`
   - `test_tracked_set_drops_homeroom_but_none_disables_filter` → `tracked set drops homeroom but null disables the filter`
   - `test_school_badges_escalate_status` → `school badges escalate status`
   - `test_taught_hours_override_beats_estimate` → `taught hours override beats the estimate`
   - `test_forecast_subject_taught_override_math` → `taught override beats the estimate`
   - `test_state_defaults_keep_old_behavior` → `keep old behavior`
2. `tests/test_ai_recommend.py` (10):
   - `test_empty_gemini_answer_falls_back_to_local` → `gemini_test.dart`: `empty gemini answer falls back to local`
   - `test_hallucinated_ids_fall_back_to_local` → `gemini_test.dart`: `hallucinated ids fall back to local`
   - `test_partial_gemini_answer_is_kept` → `gemini_test.dart`: `partial gemini answer is kept`
   - `TestGemini.test_parse_json_block` → `gemini_test.dart`: `parse json block`
   - `TestGemini.test_local_fallback_picks_non_banned` → `gemini_test.dart`: `local fallback picks high-protein meal`
   - `test_validate_recommendation_drops_hallucinations` → `gemini_test.dart`: `validate drops hallucinations`
   - `test_worker_reports_closed_days_separately`, `test_worker_says_closed_when_everything_is_past_cutoff`, `test_recommend_respects_skip_and_marks_pending`, `test_recommend_busy_guard_snacks_instead_of_rerunning` → `app/test/app_state_lunches_test.dart` (workerReportsClosedDaysSeparately, workerSaysClosedWhenEverythingIsPastCutoff, recommendRespectsSkipAndMarksPending, recommendBusyGuardSnacksInsteadOfRerunning)
3. `tests/test_automation_safety.py` (16):
   - `test_audit_roundtrip_newest_first` → `audit_test.dart`: `roundtripNewestFirst`
   - `test_audit_skips_corrupt_lines` → `audit_test.dart`: `skipsCorruptLines`
   - `test_describe_excuse_has_no_text` → `audit_test.dart`: `hasNoText`
   - `test_automation_paused_flag_parsing` → `refresh_test.dart`: `automationPausedFlagParsing`
   - `test_paused_refresh_never_sends_or_orders` → `refresh_test.dart`: `pausedRefreshNeverSendsOrOrders`
   - `test_failed_auto_excuse_is_an_error_but_data_is_fresh` → `refresh_test.dart`: `failedAutoExcuseIsAnErrorButDataIsFresh`
   - `test_failed_auto_order_is_reported` → `refresh_test.dart`: `failedAutoOrderIsReported`
   - `test_order_outcomes_are_recorded_per_day`, `test_successful_order_is_recorded_as_sent`, `test_dry_run_order_is_recorded_as_dry_run` → `automation_test.dart`: `mealNotOnMenuIsReportedButOthersPlaced`, `fullSuccessSubmitsAndRecords`, `dryRunSelectsWithoutSubmitting`
   - `test_excuse_outcomes_are_recorded` → `automation_test.dart`: `excuseOutcomesAreRecorded`
   - `test_auto_excuse_counts_failures` → `automation_test.dart`: `autoExcuseCountsFailures`
   - `test_auto_confirm_dialog_recommends_dry_run_first`, `test_auto_confirm_dialog_after_dry_run`, `test_auto_confirm_dialog_warns_unsigned_excuses` → **Deferred (phase 5/6 — `flet_ui.safety` UI confirmation dialogs)**; `test_pause_toggle_persists` → `app/test/app_state_excuses_and_planner_test.dart` (`pauseTogglePersists`)
4. `tests/test_autostart.py` (3) → **Deferred (phase 7 — desktop autostart launch command)**: `test_get_launch_command_minimized`, `test_get_launch_command_not_minimized`, `test_launch_command_has_no_shell_quotes`
5. `tests/test_autostart_platforms.py` (5) → **Deferred (phase 7 — OS autostart backends)**: `TestWindows.*` (3), `TestMacOS.*` (1), `TestLinux.*` (1)
6. `tests/test_bakalari_client.py` (14):
   - `TestGoBackWeeksRobustness.test_garbage_value_falls_back` → `bakalari_client_test.dart`: `goBackWeeksGarbageFallsBack`
   - `TestGoBackWeeksRobustness.test_extreme_value_is_clamped` → `bakalari_client_test.dart`: `goBackWeeksExtremeIsClamped`
   - `test_substitutions_init_is_unknown` → `bakalari_client_test.dart`: `substitutionsInitIsUnknown`
   - `test_unparseable_outbox_is_unknown_not_empty` → `bakalari_data_test.dart`: `unparseableOutboxIsUnknownNotEmpty`
   - `test_hour_index_fallback_never_invents_period_zero` → `common_test.dart`: `hourIndexFallbackNeverInventsPeriodZero`
   - `test_add_timetable_details` → `timetable_test.dart`: `mergesDetailsGroupedPerDaySortedByPeriod`
   - `test_week_offsets_cover_forward_and_back` → `common_test.dart`: `coverForwardAndBack`
   - `test_go_forward_weeks_config_parsing` → `bakalari_client_test.dart`: `goForwardWeeksConfigParsing`
   - `test_no_stable_view_means_no_baseline`, `test_scraped_stable_is_the_baseline` → `schedule_test.dart` / `bakalari_data_test.dart` (`aSecondRunSeesOnlyFreshData`, `noStableViewNeverReportsAddedOrMissing` in `parity_schedule_test.dart`)
   - `test_add_timetable_details_into_separate_target` → `timetable_test.dart`: `intoSeparateTarget`
   - `test_perm_view_is_told_apart_by_ident_code` → `timetable_test.dart`: `isToldApartByIdentCode`
   - `test_extract_stable_timetable_scrapes_perm_view` → `timetable_test.dart`: `extractStableTimetableScrapesPermView`
   - `test_extract_stable_timetable_rejects_stale_actual_week` → `timetable_test.dart`: `extractStableTimetableRejectsStaleActualWeek`
7. `tests/test_bakalari_excuse.py` (14 [12 functions]) → `bakalari_excuse_test.dart` (17 cases, covering all 14 collected cases + connect-phase and clock tests): `lessonExcusePostsTheFormOnceAndIsConfirmedByTheOutbox`, `wholeDayExcusePostsTheDayRange`, `lessonNotInTheTimetableIsNeverPosted`, `unreadableOutboxBeforeSendingMeansNothingIsPosted`, `postMissingFromTheOutboxIsUncertainAndNeverRepeated`, `otherExcuseAppearingDoesNotConfirmThisOne`, `tellsNeverSentFromMaybeSent`, `expiredSessionOnThePostIsNotSentAndNotRetried`, `cancelBeforeThePostSendsNothing`, `dryRunPreparesTheExcuseWithoutPosting`, `defaultTextComesFromTheTemplates`, `postbackWithoutNowReadsTheClock`, `editorFieldMatchesTheBrowserByteForByte`
8. `tests/test_bakalari_http.py` (25 [22 functions]):
   - Session cases (14 [11 functions]) → `http_session_test.dart`: `dropsPageNames`, `areWhatABrowserSubmits`, `readsTheResultOrRaises`, `postsTheFormOnceAndReusesTheSession`, `rejectedLoginRaisesUserErrorWithTheReason`, `wrongAddressSaysSo`, `serverErrorAtLoginIsNeverALogin`, `networkFailuresExplainThemselves`, `connectTimeoutIsATimeoutNotUnreachable`, `cancelStopsBeforeAnyRequest`, `stillValidSessionNeedsNoNewLogin`, `droppedConnectionIsRetriedOnceForReads`
   - Data/outbox/absence/substitutions cases (10) → `bakalari_data_test.dart`: `expiredSessionLogsInAgainAndRetriesOnce`, `outboxReadsEveryExcuseDetail`, `wholeDayExcuseIsOneEntry`, `emptyOutboxIsARealEmptyList`, `anotherFolderIsUnknownNotEmpty`, `outboxListNotLoadingIsUnknownNotEmpty`, `parsesTheSubjectRows`, `replyWithoutRowsIsFlagged`, `areParsedFromTheWeekReply`, `failedSubstitutionsAreUnknown`
   - `test_each_week_is_requested_by_its_monday` → `timetable_test.dart`: `eachWeekIsRequestedByItsMonday`
9. `tests/test_cache.py` (11) → `cache_test.dart` (11 1:1 camelCase cases): `missingFileReturnsEmptyDict`, `saveAndLoadCache`, `saveCacheMergesWithExisting`, `loadCorruptedCacheFallback`, `mismatchedVersionIgnored`, `currentVersionLoads`, `staleDetection`, `describeMentionsStale`, `replaceDropsStaleKeys`, `corruptCacheIsQuarantined`, `cacheLabelFollowsLanguage`
10. `tests/test_cancel_responsive.py` (5):
    - `test_strava_client_forwards_cancel_into_fetch` → `strava_test.dart` / `http_session_test.dart` (`cancelStopsBeforeAnyRequest`)
    - `test_cancel_refresh_noop_when_idle` → `app/test/activity_state_test.dart`: `cancel refresh is a no-op when idle` (in progress, unreviewed)
    - `test_cancel_refresh_gives_instant_feedback`, `test_core_log_never_reaches_the_status_bar`, `test_flet_locale_follows_app_language` → `app/test/app_state_excuses_and_planner_test.dart` (`cancelRefreshGivesInstantFeedback`, `coreLogNeverReachesTheStatusBar`, `localeFollowsAppLanguage`)
11. `tests/test_config.py` (36):
    - 33 pure config cases → `config_test.dart` (33 1:1 camelCase cases)
    - 3 `Strakalari` cases (`test_plaintext_override_decrypts`, `test_integer_strava_id_handling`, `test_partial_config_without_use_strava_stays_enabled`) → `automation_test.dart`: `plaintextOverrideEncrypts`, `integerStravaIdHandling`, `partialConfigWithoutUseStravaStaysEnabled`
12. `tests/test_config_save_lock.py` (1) → `config_test.dart`: `saveRefusesWhenLockBusy`
13. `tests/test_data_safety.py` (8):
    - `test_missing_file_returns_empty`, `test_corrupt_file_preserved`, `test_corrupt_history_backed_up`, `test_corrupt_blacklist_disables_auto_order`, `test_write_log_lines_are_timestamped` → `automation_test.dart`: `missingFileReturnsEmpty`, `corruptFilePreserved`, `corruptHistoryBackedUp`, `corruptBlacklistDisablesAutoOrder`, `writeLogLinesAreTimestamped`
    - `test_valid_blacklist_unaffected` → `config_test.dart`: `blacklistManagement`
    - `test_busy_config_is_not_quarantined_or_overwritten` → `config_test.dart`: `saveRefusesWhenLockBusy`
    - `test_busy_cache_is_left_untouched` → `cache_test.dart`: `busyCacheIsLeftUntouched`
14. `tests/test_early_leave.py` (13):
    - `TestSoonTemplates.test_config_defaults` → `config_test.dart`: `defaultsPass`
    - `TestSoonTemplates.test_web_hour_excuse_dedupes_soon` → `extractors_test.dart`: `webHourExcuseDedupesSoon`
    - `TestSoonDetection.*` (4), `TestSoonStatus.*` (6), `TestSoonTemplates.test_planner_templates_for_soon` (1) → `app/test/phase6_features_test.dart` (`soon badge kind is late color`, `soon task kind and lesson status`, `absent soon yields soon excuse and does not merge into full day`)
15. `tests/test_entry_routing.py` (5) → **Deferred (phase 5/7 — Python `__main__` CLI entry routing; Flutter entry is `app/lib/main.dart`)**
16. `tests/test_error_report.py` (26):
    - 13 core cases → `error_report_test.dart`: `exposesOnlyPresence`, `classification`, `namesFix`, `scrubsSecretValues`, `numericAndShort`, `scrubsDecryptedPasswordAndPersonalData`, `carriesDiagnostics`, `extraSecretsRedacted`, `logTailIsContextNotTracebackCopy`, `neverContainsSecrets`, `prefersTypeAndFirstLine`, `namesBuildAndLanguage`, `raiseUserErrorForMissingLogin`
    - 4 UI dialog cases → `app/test/overlays_test.dart` (in progress, unreviewed): `error dialog shows summary and traceback`, `error dialog with user message hides traceback`, `copy button records a copied confirmation`, `showErrorDialog never throws`
    - Remaining 9 Flet/AppState popup queue & clipboard cases → `app/test/app_state_excuses_and_planner_test.dart` (`reportErrorQueuesPopupWithTraceback`, `reportErrorOutsideHandlerStillSafe`, `acknowledgeClearsPendingButKeepsReport`, `timeoutErrorMarksReportFriendly`, `reportNeverContainsSecrets`, `reportLogTailIsContextNotTracebackCopy`)
17. `tests/test_excuse_day_scope.py` (8) → **Deferred (phase 5/6 — `AppState.day_excuse_plan` / `submit_day_excuse` / day card switch)**
18. `tests/test_excuse_generation.py` (41 [25 functions]) → `automation_test.dart` (41 parameterized cases across 25 1:1 camelCase functions): `gapDaysAreNotMerged`, `trulyConsecutiveDaysStillMerge`, `stillExcuses $notice`, `staysCancelled $notice`, `variantsGenerate ${v.$1}/${v.$2}`, `lateVariantsAreIncome ${v.$1}`, `cutoffIsDateBasedNotHourBased`, `excusedTypeSkipped`, `excusedTextWithAbsentTypeSkipped`, `fullyExcusedDayProducesNothing`, `fridayAndTuesdayDoNotBridge`, `presentDayStillBreaksChain`, `firstMode`, `randomModePicksFromList`, `emptyTemplates`, `defaultDelay`, `customDelay`, `multiGroupStatusPrioritization`, `pureDaysConsecutive`, `lateIncomeExcuse`, `pureDaysAcrossWeekend`, `delayDaysCutoff`, `fragmentedSameDayAbsences`, `genericEarlyLeaveIsAutoExcusedLikeUi`, `notCountedAbsenceIsNeverExcused`
19. `tests/test_excuse_history.py` (17):
    - 10 pure/config cases → `excuse_history_test.dart`: `broaderWebExcuseCoversSingleDay`, `partialOverlapIsNotCovered`, `hourRangeNeverCoversWholeDay`, `multiDayHourSpanSemantics`, `taskCoveredMatchesUiRules`, `nonPaddedDatesCanonicalized`, `stripsUiKeys`, `historyEntriesStoreEveryHourShape`, `managerFiltersExampleFallback`, `historyQuarantine`
    - 4 automation cases → `automation_test.dart`: `concurrentSendsSubmitOnce`, `coveredExcuseIsNotResent`, `automationFiltersExampleFallback`, `excuseDryRunFillsWithoutSubmitting`
    - 3 `TestHistoryCoverage` cases (`test_pure_days_covers`, `test_lesson_range_covers_only_inside`, `test_ambiguous_entries_never_hide`) → core coverage rules tested by `broaderWebExcuseCoversSingleDay` / `hourRangeNeverCoversWholeDay` / `taskCoveredMatchesUiRules`; `flet_ui.state_excuses` UI wrapper **Deferred (phase 5)**
20. `tests/test_excuse_ignore_list.py` (9):
    - 4 `TestIgnoredExcuses` core cases → `automation_test.dart`: `ignoredLessonIsNeverAutoExcused`, `ignoredDayBreaksFullDayChain`, `excuseAbsencePassesConfigIgnoreList`, `garbageKeysAreIgnoredSafely`
    - 5 `AppState` ignore/unignore rollback cases → `app/test/app_state_excuses_and_planner_test.dart` (`ignoreRollsBackWhenSaveFails`, `unignoreRollsBackWhenSaveFails`, `ignoreDayRollsBackWhenSaveFails`, `ignoreSavedNormally`, `ignoreDaySkipsAlreadyExcusedLessons`)
21. `tests/test_flet_data_wiring.py` (9) → **Deferred (phase 5 — `AppState` live cache/data wiring)**
22. `tests/test_forecast.py` (9) → `forecast_test.dart`:
    - `TestRareSubjects.test_one_off_not_floored_to_one` → `one-off not floored to one`
    - `TestWarnThreshold.test_explicit_warn_used` → `explicit warn used`
    - `TestWarnThreshold.test_fallback_stays_sixty_percent` → `fallback stays sixty percent`
    - `TestWarnThreshold.test_forecast_passes_warn_through` → `forecast passes warn through`
    - `test_nonstable_absence_subjects_are_free` → `non-stable absence subjects are free`
    - `test_weekly_hours_counts_stable_week` → `counts the stable week`
    - `test_school_days_skip_weekends_and_holidays` → `school days skip weekends and holidays`
    - `test_forecast_subject_math` → `math projects below the current rate when attending`
    - `test_forecast_all_uses_per_subject_limits` → `uses per-subject limits`
23. `tests/test_frozen_ssl.py` (4) → **Dropped (frozen PyInstaller CA bundle `strakalari/core/tls.py` does not exist in Flutter; Dart uses the OS trust store per PLAN §3.2)**
24. `tests/test_gemini_key.py` (6) → `gemini_test.dart`:
    - `test_api_key_success` → `success`
    - `test_api_key_empty` → `empty`
    - `test_api_key_invalid_key` → `invalid key`
    - `test_api_key_bad_model_not_blamed_on_key` → `bad model not blamed on key`
    - `test_api_key_network_error_redacts_key` → `network error redacts key`
    - `test_recommend_lunches_strips_api_key` → `strips api key into header, never url`
25. `tests/test_gemini_picks.py` (4) → `gemini_test.dart`:
    - `test_validate_recommendation_rejects_other_days_meal` → `validate rejects other days meal`
    - `test_merge_falls_back_to_filter_for_cross_day_pick` → `merge falls back to filter for cross-day pick`
    - `test_gemini_texts_follow_language` → `texts follow the requested language`
    - `test_core_t_lang_override` → `core t lang override`
26. `tests/test_grades.py` (12):
    - 8 extractor cases → `extractors_test.dart`: `emptyAndNoneInput`, `groupsBySubject`, `sortsEachSubjectByDate`, `skipsMalformedAndIncomplete`, `unparseableDatesSortLast`, `optionalDetailsKeptWhenPresent`, `nestedBracesAndBraceInString`, `readsQuarterlyMarks`
    - 4 client cases → `bakalari_data_test.dart`: `fetchesParsesAndSorts` (covers `test_get_grades_fetches_parses_and_sorts` + `test_get_grades_reads_quarterly_marks_from_the_same_page`), `failureKeepsErrorWithoutRaising`, `emptyOtherPageIsAnErrorNotNoMarks`
27. `tests/test_grades_math.py` (37 [23 functions]) → `grades_test.dart`:
    - `test_parse_raw` → `reads each mark on its own`
    - `test_non_counting_marks` → `non-counting marks`
    - `test_points_field_used_when_mark_text_is_not_a_number` → `points field used when mark text is not a number`
    - `test_valid_mark_text_rejects_out_of_range` → `rejects out of range`
    - `test_weights` → `weights`
    - `test_detect_scale` → `detect scale`
    - `test_conversion_uses_bands` → `conversion uses bands`
    - `test_gekom_table_boundaries` → `gekom table boundaries`
    - `test_round_grade_halves_go_down_a_grade` → `round grade halves go down a grade`
    - `test_bands_validation` → `bands validation`
    - `test_summary_weighted_average_trend_and_new` → `weighted average trend and new`
    - `test_forced_percent_converts_a_pure_grade_subject` → `forced percent converts a pure grade subject`
    - `test_bare_small_numbers_are_percent_on_a_percent_subject` → `bare small numbers are percent on a percent subject`
    - `test_forced_grade_converts_percentages` → `forced grade converts percentages`
    - `test_prediction_ops_leave_real_average_alone` → `prediction ops leave real average alone`
    - `test_mark_keys_distinguish_identical_marks` → `mark keys distinguish identical marks`
    - `test_planned_marks_do_not_count` → `planned marks do not count`
    - `test_needed_grade` → `needed grade`
    - `test_needed_many_best_marks` → `needed many best marks`
    - `test_needed_percent` → `needed percent`
    - `test_needed_with_no_marks` → `needed with no marks`
    - `test_default_weight_is_most_common` → `default weight is most common`
    - `test_format_value` → `format value`
28. `tests/test_grades_minus.py` (1) → `grades_test.dart`: `minus grades count`
29. `tests/test_helpers.py` (26):
    - Date/path/lesson/template/atomic/lock cases → `helpers_test.dart`: `standard`, `withSpaces`, `withWeekdayParentheses`, `withLeadingDayPrefix`, `overrideWins` / `absolutePathPassesThrough` / `relativeResolvesAgainstDataDir`, `isoAndSlash`, `invalid`, `fillsVariables`, `acceptsShortYearAndIsoSlashes`, `onlySuffixReplaced`, `timeOnlyReturnsNull`, `bareNumberOk`, `classicShapeOk`, `emptyNull`, `writesValidJson`, `noTmpLeftovers`, `lockReleaseReacquire`
    - `test_parse_cz_date_accepts_czech_slashes` → `models_test.dart`: `parseCzDateAcceptsCzechSlashes`
    - Encrypt/decrypt cases → `fernet_test.dart` (`roundtrip`, `tamperedTokenThrows`, `garbageThrows`) + `secret_store_test.dart` (`decryptSurvivesKeyFileOSError`)
30. `tests/test_i18n.py` (7):
    - 4 core cases → `i18n_test.dart`: `getAndSetLanguage`, `missingKeyFallsBack`, `coreMessagesHaveBothLanguagesAndSamePlaceholders`, `coreMessageFollowsLanguage`
    - `test_core_messages_follow_language` → `error_report_test.dart`: `namesFix` (tests `timeoutUserMessage` in cs/en)
    - `test_new_flet_strings_present`, `test_dead_keys_removed_and_live_keys_kept` → **Deferred (phase 5 — `flet_ui.strings` / ARB key audit)**
31. `tests/test_icons.py` (13) → **Deferred (phase 6/7 — app icon assets verification)**
32. `tests/test_imports_resolve.py` (354 [1 function]) → **Dropped (Python AST relative-import check; replaced by `dart analyze` and `flutter analyze`)**
33. `tests/test_log_redaction.py` (3) → `error_report_test.dart`: `plaintextAndCiphertextSecretsAreScrubbed`, `followsChangedPassword`, `skipPersonalData`
34. `tests/test_lunch_auto.py` (11) → `lunch_auto_test.dart`:
    - `test_disabled_never_runs` → `disabled never runs`
    - `test_never_ran_is_due` → `never ran is due`
    - `test_interval_gating` → `interval gating`
    - `test_interval_clamped` → `interval clamped`
    - `test_first_non_banned_wins` → `first non-banned wins`
    - `test_past_and_cancelled_skipped` → `past and cancelled skipped`
    - `test_closed_day_skipped` → `closed day skipped`
    - `test_banned_gemini_replaced_by_filter` → `banned gemini pick replaced by filter`
    - `test_gap_filled` → `gap filled`
    - `test_spelling_variants_merge_into_one_key` → `spelling variants merge into one key`
    - `test_filter_picks_uses_canonical_keys` → `uses canonical keys`
35. `tests/test_lunch_auto_user_choice.py` (8):
    - `TestAutoFillsGapsOnly.test_existing_order_is_never_switched` → `lunch_auto_test.dart`: `existing order is never switched`
    - `TestAutoFillsGapsOnly.test_handled_day_is_not_reordered_after_web_cancel` → `lunch_auto_test.dart`: `handled day is not reordered after web cancel`
    - `TestAutoFillsGapsOnly.test_planned_day_off_gets_its_lunch_cancelled` → `lunch_auto_test.dart`: `planned day off gets its lunch cancelled`
    - `TestAutoFillsGapsOnly.test_planned_day_off_without_order_gets_nothing` → `lunch_auto_test.dart`: `planned day off without order gets nothing`
    - `TestAutoFillsGapsOnly.test_handled_days_remember_orders_but_not_failures` → `lunch_auto_test.dart`: `handled days remember orders but not failures`
    - `TestPlannedSkipLunchChoice.test_keep_lunch_choice_is_stored_and_honored` → `planned_skips_test.dart`: `keepLunchChoiceIsStoredAndHonored`
    - `test_restart_does_not_resurrect_meal_on_planned_day`, `test_send_only_transmits_pending_picks` → `app/test/app_state_lunches_test.dart` (restartDoesNotResurrectMealOnPlannedDay, sendOnlyTransmitsPendingPicks)
36. `tests/test_lunch_cutoff.py` (11):
    - `test_gekom_preset_cutoff_defaults_to_noon`, `test_resolve_lunch_cutoff_user_wins_then_preset` → `school_presets_test.dart`: `closes` / `userWinsThenPreset` + `parity_lunch_cutoff_test.dart`
    - `test_parse_and_validate_cutoff` → `lunch_cutoff_test.dart`: `parseCutoffTime`, `normalizeCutoffTime`, `isValidCutoffTime`
    - `test_previous_business_day_skips_weekend` → `lunch_cutoff_test.dart`: `skips weekend`
    - `test_previous_business_day_skips_free_days` → `lunch_cutoff_test.dart`: `skips free days`
    - `test_deadline_is_noon_previous_business_day` → `lunch_cutoff_test.dart`: `is noon on the previous business day`
    - `test_is_open_until_cutoff_then_closed` → `lunch_cutoff_test.dart`: `open until cutoff, then closed`
    - `test_monday_deadline_is_friday_noon` → `lunch_cutoff_test.dart`: `monday deadline is friday noon`
    - `TestCutoffSpelling.test_dot_spelling_valid` → `lunch_cutoff_test.dart`: `dot spelling valid`
    - `TestCutoffSpelling.test_garbage_still_invalid` → `lunch_cutoff_test.dart`: `garbage still invalid`
    - `test_state_rejects_closed_day_and_filters_submit` → `app/test/lunches_view_test.dart` (`closed day is read-only` / `order past cutoff stages nothing`) + `app/test/app_state_lunches_test.dart` (`stateRejectsClosedDayAndFiltersSubmit`)
37. `tests/test_lunch_day_keys.py` (3) → `app/test/app_state_lunches_test.dart` (`cachedOrdersUseCanonicalDayKeys`, `recordWebOrdersDropsOtherSpellings`); pure `canonicalLunchDayKey` and `_store_ordered` covered by `parity_lunch_cutoff_test.dart` and `automation_test.dart`
38. `tests/test_lunch_deadline_calendar.py` (1) → `parity_lunch_cutoff_test.dart` (`effectiveCalendar(clipToClose: false)`); `AppState.lunch_deadline_calendar` **Deferred (phase 5)**
39. `tests/test_lunch_filter.py` (12) → `app/test/lunches_filter_test.dart` (12 1:1 cases, in progress, unreviewed): `negation clause yields keyword`, `likes clause ignored`, `mixed text keeps only dislikes`, `bez form`, `conjunction like segment ignored`, `english no form`, `empty`, `prefs hide and stage`, `good pick not clobbered`, `hidden pick replaced`, `cancelled day skipped`, `closed day hides but stages nothing`
40. `tests/test_lunch_same_pick.py` (5) → **Deferred (phase 5 — `flet_ui.state.AppState` / `LunchView` pending pick vs web order comparison)**: `test_repicking_the_ordered_meal_is_no_change`, `test_a_different_meal_is_a_change_until_picked_back`, `test_no_lunch_compares_with_the_web_too`, `test_submit_sends_only_picks_that_differ`, `test_refresh_unstages_a_pick_the_web_now_reports`
41. `tests/test_macos_data_dir.py` (9) → **Deferred (phase 7 — macOS bundle → Application Support migration)**
42. `tests/test_macos_tray_host.py` (15) → **Deferred (phase 7 — macOS tray/window lifecycle)**
43. `tests/test_marks_view.py` (15) → `app/test/phase6_features_test.dart` (`predictor state add edit remove restore reset`, `scale preferences and preset bands`, `selecting the open subject closes it`, `saving an unchanged mark is not an edit`) + `app/test/marks_live_test.dart` (`LiveMarksView renders subjects and offers marks tutorial`, `marksControllerFor maps AppState grades and syncs predictions`)
44. `tests/test_matching.py` (22 [8 functions]) → `matching_test.dart` (22 parameterized cases across 8 1:1 functions): `$keyword bans $meal`, `$keyword allows $meal`, `rybiDoesNotBanRybiz`, `inflectionStillMatches`, `wholeWordNotSubstring`, `diacriticsInsensitive`, `inflectionVariant`, `caseInsensitive`
45. `tests/test_minimize_to_tray.py` (8) → **Deferred (phase 7 — desktop window close-to-tray behavior)**
46. `tests/test_mobile.py` (70 [48 functions]):
    - `TestPlatform.*` (4) → `packaging_test.dart`: `desktopIsNotMobile`, `fletPlatformEnv`, `desktopFletBuildIsNotMobile`, `defaultsToFalse`
    - ` test_update_check_per_distribution`, `test_repo_has_no_distribution_marker` → `packaging_test.dart`: `iosComesFromAppStore`, `androidWithoutDistributionIsNull`, `androidPlayChannel`, `offPhoneIsNull`, `emptyEnvironmentIsNull`
    - `TestNarrowShell.*` (12) → `app/test/widget_test.dart` (`Layout breakpoints match the Python shell`, `Router builds every main screen without throwing`, in progress, unreviewed); remaining narrow-shell cases **Deferred (phase 5/6)**
    - `TestMakeMobile.test_stage_has_no_personal_files`, `test_package_check_finds_nested_personal_file`, `test_path_markers_spell_every_separator`, `test_package_check_finds_build_machine_path` → `app/test/packaging_privacy_test.dart` (in progress, unreviewed)
    - Remaining `TestDataDir`, `TestKeystoreKey`, `TestPhoneBackground`, `test_open_system_alarm_*` → **Deferred (phase 8 — Android bridge/keystore/service)**; Flet-packaging-specific `TestMakeMobile` (`test_flet_pin_matches_desktop`, `test_extension_wheel`, `test_pyc_shim_*`) → **Deferred (phase 8/10 — decide at Android review)**
47. `tests/test_models.py` (19):
    - 17 pure model cases → `models_test.dart` (17 1:1 camelCase cases)
    - 2 engine cases (`test_engine_excuses_neomluveno_day`, `test_engine_excuses_unexcused_type`) → `automation_test.dart`: `engineExcusesNeomluvenoDay`, `engineExcusesUnexcusedType`
48. `tests/test_news.py` (7):
    - 6 pure cases → `news_test.dart`: `newMarkReportedOnce`, `marksNeedAPreviousStateAndSkipAnnouncedOnes`, `newOrChangedQuarterlyMarkReportedOnce`, `newAbsenceOnlyOnKnownDays`, `newTimetableChangeFromTodayOn`, `findNewsBuildsMessages`
    - `test_refresh_reports_news_against_the_cache` → `app/test/app_state_excuses_and_planner_test.dart` (`refreshReportsNewsAgainstTheCache`)
49. `tests/test_notify.py` (17):
    - Core dispatch/prefs/safety cases → `notifier_test.dart` (9): `appIdIsPlainAscii`, `knownEvents`, `defaultsToOn`, `unknownEventThrows`, `disabledEventNeverTouchesTheBackend`, `dispatchesToTheBackend`, `backendFailureFallsBackToStdout`, `noBackendPrintsAndReturnsFalse`, `neverRaisesFromBackend`
    - Desktop OS script/command cases (`test_ps_single_quote_escapes_apostrophe`, `test_cdata_guards_closing_sequence`, `test_toast_script_*`, `test_send_windows_*`, `test_send_linux_*`, `test_send_macos_*`) → **Deferred (phase 7 — desktop notification backends)**
50. `tests/test_open_url.py` (5) → **Deferred (phase 5/6 — UI URL launcher helper)**
51. `tests/test_order_latch.py` (7 [4 functions]) → **Deferred (phase 5 — `flet_ui.state.AppState` `submit_orders` latch & `submit_excuse` kind mapping)**: `test_empty_payload_releases_latch`, `test_demo_no_credentials_releases_latch`, `test_nothing_pending_releases_latch`, `test_excuse_kind_to_web_type`
52. `tests/test_packaging_privacy.py` (4) → `app/test/packaging_privacy_test.dart` (in progress, unreviewed; desktop Inno/spec checks **Deferred phase 7**)
53. `tests/test_plan_picker.py` (12) → `app/test/planner_view_test.dart` (`custom picker taps a day whole and confirms`, in progress, unreviewed); remaining 11 picker cases **Deferred (phase 6 — custom plan picker dialog)**
54. `tests/test_plan_reserve.py` (5) → `planner_test.dart` (`reserveValidation`) + `app/test/planner_reserve_test.dart` (in progress, unreviewed): `reserve lowers plan limit, not school limit`, `default example 25 minus 10 is 15`, `zero reserve keeps old behavior`, `handbuilt states fall back to school values`, `reserve validation`
55. `tests/test_planned_skips.py` (17):
    - 11 pure cases → `planned_skips_test.dart`: `keeps period zero`, `entry covers follows the planner rule`, `whole days in a row merge across a weekend`, `a gap day splits the range`, `range may start late and end early`, `scattered lessons become separate entries`, `free periods do not split a run`, `a partial day does not join the next one`, `ranges are capped at 31 days`, `entries keep the template and lunch choice`
    - 6 `AppState` persist/rollback cases (`test_plan_custom_skip_reports_persist_failure`, `test_plan_skip_reports_invalid_range`, `test_unplan_entry_reports_stale`, `test_plan_custom_skip_rolls_back_on_persist_failure`, `test_unplan_entry_rolls_back_on_persist_failure`, `test_plan_entries_saves_all_at_once`, `test_plan_entries_rolls_back_on_persist_failure`) → `app/test/app_state_excuses_and_planner_test.dart` (`planEntriesSavesAllAtOnce`, `planEntriesRollsBackOnPersistFailure`, `planSkipReportsInvalidRange`, `unplanEntryRollsBackOnPersistFailure`) + `app/test/planner_view_test.dart` (`controller plan/unplan with failing persist rolls back`)
56. `tests/test_planner_dialog.py` (6) → `app/test/planner_view_test.dart` (`plan dialog confirm plans the day`, `plan dialog cancel closes without planning`, in progress, unreviewed); remaining dialog cases **Deferred (phase 6)**
57. `tests/test_refresh_cancel_keeps_data.py` (1) → `refresh_test.dart`: `cancelAfterFetchKeepsFetchedData`
58. `tests/test_refresh_pipeline.py` (9) → `refresh_test.dart`:
    - `test_web_excuses_sync_before_auto_excuse` → `webExcusesSyncBeforeAutoExcuse`
    - `test_planned_skip_day_never_auto_ordered` → `plannedSkipDayNeverAutoOrdered`
    - `test_broken_blacklist_orders_nothing` → `brokenBlacklistOrdersNothing`
    - `test_strava_failure_keeps_bakalari_data_and_reports` → `stravaFailureKeepsBakalariDataAndReports`
    - `test_empty_menu_keeps_cached_menu` → `emptyMenuKeepsCachedMenu`
    - `test_strava_status_tells_why_the_menu_is_missing` → `stravaStatusTellsWhyTheMenuIsMissing`
    - `test_unavailable_extras_survive_refresh` → `unavailableExtrasSurviveRefresh`
    - `test_failed_absence_scrape_keeps_last_good_absence` → `failedAbsenceScrapeKeepsLastGoodAbsence`
    - `test_gemini_fallback_is_not_a_gemini_run` → `geminiFallbackIsNotAGeminiRun`
59. `tests/test_schedule.py` (24) → `schedule_test.dart` (24 1:1 camelCase cases; `test_forecast_prefers_stable_hours_over_raw_weeks` → `forecast_test.dart`: `counts the stable week` + `schedule_test.dart`: `stableHoursIgnoreClocklessExtraRow`)
60. `tests/test_scheduler.py` (13):
    - 10 core cases → `scheduler_test.dart`: `stopWithoutStartIsSafe`, `failedRunRetriesSoon`, `runNowLeavesTimerAlone`, `scheduling` (`test_scheduler_next_due`), `runsJobsAndCapturesErrors`, `lastUpdatedTimeParsesFormats`, `startupSeedNeedsPositiveEvidence`, `seedDefersFirstAutoRun`, `runnerAcceptsLastRunSeed`, `keepsFullTraceback` (also in `cache_test.dart`: `lastUpdatedTimeParsesFormats`, `startupSeedNeedsPositiveEvidence`)
    - 3 `flet_ui.app`/`tray` cases (`test_register_jobs_seeds_from_fresh_cache`, `test_register_jobs_empty_cache_refreshes_on_start`, `test_tray_startup_seed`) → **Deferred (phase 5/7 — UI/tray scheduler registration)**
61. `tests/test_scheduler_retry.py` (7):
    - 2 core `PeriodicRunner` cases → `scheduler_test.dart`: `intervalProviderIsPolled`, `jobFailedCountsAsFailureButReported`
    - 5 window/tray cases (`test_window_job_raises_when_refresh_failed`, `test_window_job_ignores_cancelled_run_in_any_language`, `test_window_job_stops_waiting_on_shutdown`, `test_window_job_gives_up_on_a_hung_refresh`, `test_tray_interval_follows_config_file`) → **Deferred (phase 5/7 — `flet_ui.app` / `tray` job wrappers)**
62. `tests/test_school_calendar.py` (20):
    - 15 preset/calendar cases → `school_presets_test.dart`: `expandsAllRangesAndSingles`, `closes`, ` overrideModel`, `customPresetOnlyUserDays`, `userWinsThenPreset`, `canonicalDefaultsHaveCalendarKeys`, `pruneOrphanForced`, `fileIsPickedUp`, `invalidFileIsIgnored`, `cannotReplaceShippedOne`, `shippedPresetsAreValid`, `shipsItsPercentTable`, `resolutionOrder`, `presetBandsValidated`
    - `test_no_migration_legacy_holidays_ignored`, `test_fresh_config_assumes_no_school` → `parity_school_presets_test.dart` + `config_test.dart` (`legacyKeysAreIgnored`)
    - `test_forecast_uses_sem1_closure`, `test_forecast_uses_sem2_closure`, `test_forecast_legacy_year_end_still_applies` → `forecast_test.dart` (`semester bounds follow the Czech school year`) + `parity_forecast_test.dart`
63. `tests/test_secret_store.py` (9) → `secret_store_test.dart` (9 1:1 camelCase cases): `newKeyGoesToTheStoreNotAFile`, `existingKeyFileIsMigratedAndDeleted`, `copiedFolderWithoutStoreEntryCannotDecrypt`, `lockedStoreWithFileUsesFile`, `lockedStoreWithoutFileFailsLoudly`, `differentFileAndStoreKeysPreferFile`, `noBackendFallsBackToFile`, `entryIsBoundToTheDataDir`, `forgetKeyRemovesFileKey`
64. `tests/test_sent_excuses.py` (10):
    - 4 `TestSentExcuseEntries` cases → `extractors_test.dart`: `lessonsYieldEveryHourShape`, `wholeDays`, `clockTimesWithoutLessonsLearnNothing`, `otherMessagesAndGarbageLearnNothing`
    - 3 pure `TestMergeSentExcuses` cases → `excuse_history_test.dart`: `addsOnlyNew`, `canonicalizesSpellings`, `stripsUiKeysAndIgnoresJunk`
    - 2 sync cases (`test_sync_without_credentials_is_noop`, `test_sync_treats_none_as_unknown`) → `automation_test.dart`: `syncWithoutCredentialsIsNoop`, `syncTreatsNoneAsUnknown`
    - `test_sent_excuses_tristate` → `bakalari_data_test.dart`: `emptyOutboxIsARealEmptyList` / `anotherFolderIsUnknownNotEmpty`
65. `tests/test_session_lock.py` (6) → `session_lock_test.dart` (`isExclusiveWithinProcess`, `blocksOtherProcess`, `keepsOtherProcessEdits`, `ownEditWinsOnSameKey`, `guardedJobSkipsWhileSessionHeld`, `guardedWorkRecordsFailedRunWhileHeld`) + `refresh_test.dart` (`lockIsExclusiveWithinProcess`, `configSaveKeepsOtherProcessEdits`, `configSaveOwnEditWinsOnSameKey`)
66. `tests/test_settings_quiet_save.py` (6) → `app/test/settings_quietsave_test.dart` (6 cases, in progress, unreviewed)
67. `tests/test_settings_refresh_interactive.py` (4 [3 functions]) → **Deferred (phase 5/6 — `AppState` interactive settings during refresh)**
68. `tests/test_settings_sections.py` (16 [13 functions]) → `app/test/settings_sections_test.dart` (15 cases covering the 13 functions, in progress, unreviewed)
69. `tests/test_shutdown.py` (23) → **Deferred (phase 7 — desktop shutdown / process cleanup; Flet-view orphan sweepers decide at phase 7 review)**
70. `tests/test_single_instance.py` (22) → **Deferred (phase 7 — desktop single-instance loopback TCP tests)**
71. `tests/test_stable_change_signals.py` (39):
    - Core extractor/common/schedule/baseline cases → `common_test.dart` (`removedRowParsesToCancelledLesson`, `emptyRemovedRowStillDropped`, `atomRowWithoutTeacherStillDropped`, `roomMoveKeepsChangeinfoAsNote`, `classEventStandsInForSubject`), `timetable_test.dart` (`extractKeepsRemovedRows`), `extractors_test.dart` (`readsBadgesAndDays`, `neverRaises`), `schedule_test.dart` + `parity_schedule_test.dart` (all 30 schedule/feed/baseline cases in `tools/parity/dump.py` `dump_schedule`)
    - UI list/grid view cases (`test_list_view_orders_cancelled_row_into_its_period`, `test_grid_cell_shows_taught_lesson_of_swapped_slot`, `test_stable_complete_reads_cache_source`) → **Deferred (phase 5/6 — timetable UI view)**
72. `tests/test_status_notification.py` (51):
    - 39 core `TestItems`, `TestLunchtime`, `TestLunch`, `TestNextLesson`, `TestOtherLines`, `TestNotifier` cases → `status_notification_test.dart` (39 1:1 camelCase cases)
    - 12 `TestAndroidBridge`, `TestPhoneWiring`, `TestSettings` cases → **Deferred (phase 6/8 — Android notification bridge & settings preview)**
73. `tests/test_store_package.py` (18) → **Deferred (phase 7 — Windows Store / MSIX packaging & data dir migration)**
74. `tests/test_strava_blacklist_edits.py` (5):
    - `test_default_blacklist_template_is_empty` → `config_test.dart`: `blacklistFiltersTemplatePlaceholders` / `repoExampleFilesAreValid`
    - 4 `TestBlacklistEdits` (`AppState` add/remove blacklist word) → `app/test/app_state_lunches_test.dart` (addRefusesOnCorruptFile, removeRefusesOnNonList, addAndRemoveKeepExistingWords, addToMissingFileCreatesIt)
75. `tests/test_strava_client.py` (19) → `strava_test.dart` (19 1:1 camelCase cases)
76. `tests/test_strava_low_balance.py` (5):
    - `test_ordering_stops_at_low_balance`, `test_cancellations_go_first_and_still_work_when_broke` → `automation_test.dart`: `orderingStopsAtLowBalance`, `cancellationsGoFirstAndStillWorkWhenBroke`
    - `test_refresh_reports_low_balance_as_its_own_case`, `test_low_balance_notice_is_claimed_once_a_day` → `refresh_test.dart`: `refreshReportsLowBalanceAsItsOwnCase`, `lowBalanceNoticeIsClaimedOnceADay`
    - `test_ui_low_balance_is_a_warning_not_an_error` → `app/test/app_state_lunches_test.dart` (uiLowBalanceIsAWarningNotAnError)
77. `tests/test_strava_ordering.py` (15) → `automation_test.dart` (15 1:1 camelCase cases): `failedDayWithoutClicksIsNotSuccess`, `failedRunReportsDaysSavedByImmediateFrontend`, `failedRunOnSaveButtonFrontendReportsNothingClicked`, `allFailedAfterClicksRestoresOriginals`, `lostSelectionFailsAndRestores`, `mealNotOnMenuIsReportedButOthersPlaced`, `fullSuccessSubmitsAndRecords`, `menuMissReturnsFalse`, `menuHitReturnsTrue`, `orderingSkippedWithoutCutoff`, `partialOrderIsNotSuccess`, `dryRunSelectsWithoutSubmitting`, `successSubmits`, `failedDayAbortsSubmit`, `closedDayIsSkipped`
78. `tests/test_substitution_feed_days.py` (1) → `schedule_test.dart`: `feedDoesNotCreateDays`
79. `tests/test_timetable_cache_merge.py` (9):
    - 5 `TestMergeTimetableDays` cases → `cache_test.dart`: `keepsUnscrapedDaysAndFreshWins`, `presentButEmptyDayOverwrites`, `prunesOutOfWindowOldDaysKeepsGarbage`, `noWindowStartKeepsEverything`, `emptyInputs`
    - `test_excuse_single_dry_run_fills_only`, `test_excuse_absence_dry_run_sends_nothing` → `automation_test.dart`: `excuseSingleDryRunFillsOnly`, `excuseAbsenceDryRunSendsNothing`
    - `test_submit_excuse_dry_run_leaves_pending`, `test_submit_day_excuse_dry_run_leaves_pending` → **Deferred (phase 5 — `AppState.submit_excuse` / `submit_day_excuse`)**
80. `tests/test_timetable_week_nav.py` (4) → `app/test/phase6_features_test.dart` (`week switch emits once and clears stable view`, `week switch noop emits nothing`) + `app/test/timetable_live_test.dart` (`timetableControllerFor maps AppState and delegates week/view toggles`)
81. `tests/test_timetable_week_switch.py` (3) → **Deferred (phase 5/6 — `AppState` timetable week switch fetch)**
82. `tests/test_tls_bundle.py` (7) → **Dropped (frozen CA bundle `strakalari/core/tls.py` does not exist in Flutter; Dart uses OS trust store per PLAN §3.2)**
83. `tests/test_tray_language.py` (1) → **Deferred (phase 7 — desktop tray language)**
84. `tests/test_tray_ui_command.py` (4) → **Deferred (phase 7 — desktop tray UI command & refresh)**
85. `tests/test_tutorial.py` (36 [28 functions]):
    - `test_config_validation_rejects_bad_progress` → `config_test.dart`: `validateCatchesBadModeAndThresholds`
    - All 28 functions ported in `app/test/tutorial_test.dart` (28 green, covering gating, progression, resets, anchors, inline/floating bubble rendering, and marks walkthrough)
86. `tests/test_ui_state.py` (13):
    - 5 activity/status cases → `app/test/activity_state_test.dart` (in progress, unreviewed): `status kind transitions`, `manual sends show as working`, `last run label`, `next run label`, `log ring buffer caps`
    - 2 setup cases → `app/test/wizard_settings_test.dart` (in progress, unreviewed): `needs setup false with strava only`, `needs setup fresh`
    - Remaining 6 `AppState` cases (`test_set_timetable_view_validation`, `test_go_sets_pending_route`, `test_cancel_lunch_order`, `test_start_refresh_rejects_bad_scope_gracefully`, `test_state_save_reports_failure`, `test_subject_states_empty_without_timetable`) → `app/test/app_state_excuses_and_planner_test.dart` (`setTimetableViewValidation`, `goSetsPendingRoute`, `startRefreshRejectsBadScopeGracefully`, `stateSaveReportsFailure`, `subjectStatesEmptyWithoutTimetable`, `needsSetupFalseWithStravaOnly`, `needsSetupTrueWithNothing`)
87. `tests/test_ui_views.py` (28):
    - `TestNamedTemplates.test_core_picks_text_of_named_template`, `test_timetable_period_of_zero` → `helpers_test.dart` / `schedule_test.dart` (`periodOfZero`)
    - `TestPlannerSignature.test_signature_not_duplicated`, `TestNamedTemplates.test_helpers_accept_both_shapes`, `TestNamedTemplates.test_options_carry_names_and_skip_blank` → `app/test/planner_reserve_test.dart` (in progress, unreviewed)
    - `test_all_views_build_headless` → `app/test/widget_test.dart` (`Router builds every main screen without throwing`, in progress, unreviewed)
    - `test_settings_nav_groups_cover_every_section` → `app/test/settings_sections_test.dart` (`nav groups cover every section`, in progress, unreviewed)
    - `test_lunch_meal_name_split`, `test_lunch_menu_hides_past_days_until_asked` → `app/test/lunches_filter_test.dart` (`split meal`) / `app/test/lunches_view_test.dart` (`menu hides past days until asked`, in progress, unreviewed)
    - `test_activity_groups_and_translates_automation_history`, `test_activity_time_helpers`, `test_activity_log_counts_a_traceback_as_one_error` → `app/test/activity_view_test.dart` (in progress, unreviewed)
    - Remaining 15 timetable/scroll/today view cases → **Deferred (phase 5/6)**
88. `tests/test_unconfirmed_excuses.py` (16):
    - 5 `TestHelpers` cases → `excuse_history_test.dart`: `sidecarSitsNextToHistory`, `overlapBlocksEvenAPartialResend`, `wholeDayBlocksItsLessons`, `resolve`, `submitBeforeTheOutboxRangeStaysOpen`
    - 9 `TestSendPath` + `TestOutboxSettles` cases → `automation_test.dart`: `uncertainSubmitIsRecordedNotFailed`, `unconfirmedBlocksTheNextSend`, `certainFailureIsRetryable`, `sidecarWriteFailureFallsBackToHistory`, `autoCountsANewUnconfirmedAsAFailure`, `foundInOutboxIsConfirmed`, `absentFromOutboxAfterGraceIsReleased`, `freshSubmitIsKept`, `failedReadSettlesNothing`
    - 2 `TestRefreshGate` cases → `refresh_test.dart`: `noAutoExcuseWithoutAnOutboxRead`, `autoExcuseRunsAfterAnOutboxRead`
89. `tests/test_update.py` (46):
    - 40 core cases → `update_test.dart` (40 1:1 camelCase cases)
    - `TestConfigChannel.test_validation` → `config_test.dart`: `validateCatchesBadModeAndThresholds`
    - 5 `TestStrings` / `TestChannelState` (`flet_ui` banner/diagnostics/config channel state) → `app/test/app_state_excuses_and_planner_test.dart` (`dismissUpdateAndSetUpdateChannel`)
90. `tests/test_version_sync.py` (3) → **Deferred (phase 7/10 — version sync across `pubspec.yaml`, Inno installer, MSIX)**
91. `tests/test_wake_ui.py` (2) → **Deferred (phase 5/8 — UI isolate wakeup from background worker)**
92. `tests/test_wakeup_and_widget.py` (44 [42 functions]):
    - 21 core `TestWakeupAlarm`, `TestWidgetPayload`, `TestSyncAndroid` functions → `wakeup_test.dart` (21 1:1 camelCase cases)
    - 21 UI/widget/extension-wheel functions (`TestTimetableViews.*`, `TestCollapsibleDays.*`, `TestWakeupUI.*`, `test_extension_wheel_ships_widget_and_alarm`) → **Deferred (phase 6/8 — timetable/today/settings wakeup UI & Android build)**
93. `tests/test_wizard_setup.py` (34 [30 functions]):
    - 3 setup-detection cases → `app/test/wizard_settings_test.dart` (in progress, unreviewed): `needs setup fresh`, `needs setup false with bakalari`, `needs setup false with strava only`
    - Remaining 27 wizard step/validation/scheduler-gate functions → `app/test/phase6_features_test.dart` (`needs setup fresh and dismiss`, `wizard step navigation and clamping`) + `app/test/wizard_live_test.dart` + `app/test/wizard_settings_test.dart`
94. `tests/test_year_planner.py` (23):
    - 18 pure planner cases → `planner_test.dart` (18 1:1 camelCase cases)
    - 5 `AppState`/view cases (`test_plan_days_batches_one_save`, `test_year_plan_is_cached_until_inputs_change`, `test_first_plannable_day_is_clock_aware`, `test_target_days_setting_limits_the_plan`, `test_planner_view_builds_with_data_and_calendar_opens_dialog`) → `app/test/phase6_features_test.dart` (`planDays batches one save`, `year plan is cached until inputs change`, `first plannable day is clock aware`, `target days setting limits the plan`) + `app/test/planner_view_test.dart`

Support files (ported as test helpers/fakes, not 1:1 test files): `tests/conftest.py`, `tests/fake_bakalari.py` (`packages/strakalari_core/test/support/fake_bakalari.dart`), `tests/fixtures/`.

## Dropped (with reason)

- `strakalari/core/tls.py` — Dart uses the OS trust store; no frozen CA bundle
  (PLAN §3.2).
- `tests/test_tls_bundle.py` (7) — tests `strakalari/core/tls.py` (repairing a purged frozen CA bundle), which is absent in Flutter (PLAN §3.2).
- `tests/test_frozen_ssl.py` (4) — tests `sys._MEIPASS` PyInstaller CA bundle setup in `strakalari/core/tls.py`, which is absent in Flutter (PLAN §3.2).
- `tests/test_imports_resolve.py` (1) — Python AST check for `from ...` relative imports across `.py` files; Dart imports are statically verified by `dart analyze` and `flutter analyze`.

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
  - `HistoryLock` uses a per-path FIFO async mutex inside the isolate
    (re-entrant only for the same logical task via a `Zone` value) plus
    `tryFileLock` (the create-exclusive `.lock` file, matching Python's
    `history_lock` in `excuse_history.py:327`) polled asynchronously with a
    `Stopwatch` deadline (reworked in A-M1).
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
- `DartIoHttpTransport` wraps DNS/connect/connect-timeout (`min(timeout, 20s)`)
  in `ConnectFailure` (`isNeverSentCause == true`), while read retries
  use `isDroppedReadError` (only dropped-connection `HttpException` /
  `SocketException`, excluding `ConnectFailure` and `TlsException` —
  reworked in A-B2, A-S8, A-S9).
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
  - DST-safe day stepping: all calendar-day moves and differences across core
    use `addDays` (constructor arithmetic `DateTime(y, m, d + n)`) and
    `daysBetween` (UTC midnights), matching Python `date ± timedelta` across
    Prague DST transitions (reworked in A-B1, R-S4).
  - `bandsValid` accepts bools (`float(True) == 1.0`, like Python).
  - `LessonSource` also accepts live `SlotBaseline` objects (Python reads
    any object with `.subject` via hasattr) — parity-oracle caught the gap.
  - `validatePreset` bad-entry messages and log lines interpolating maps/lists
    use `pyRepr` (`['bad', 'label']`, `{'type': 'days and hours'}`), matching
    Python `repr()` (reworked in R-S6).
  - `mealText` blanks every falsy input (`str(name or "")`), not just
    null — parity-oracle caught `"Null"`/`"0"`.
  - `buildPrompt` (cs) reads "Odpověz ve formátu …", like Python (the port
    had "Odpověď …") — parity-oracle caught the rewording.
  - `updateStableBaseline` and `fetchData` (including per-run state reset and
    cancel/login prelude) are ported into `DataMixin` (reworked in A-M3).
  - Automation/refresh seam hooks default to the real phase-3 functions
    (`schoolYearTerms`, `baselineToDict`, `findNews`, `planAutoOrders`,
    `plannedLunchDays`, `updateHandledDays`, `resolveLunchCutoff`,
    `effectiveCalendar`, `isLunchOrderOpen`); tests assign fakes (reworked in
    A-B4).
  - `RefreshApp` interface replaces Python duck typing;
    `runRefresh`/`Strakalari` methods are async; `InterruptedError`→
    `CancelledError`, `RuntimeError`→`StateError`.
  - Optional params are all-named; `sendExcuseOutcome` delegates to
    `sendExcuse(source: 'manual')`; public names for test-used privates
    per the phase-1 precedent.
  - Log redaction in automation delegates to `error_report.secretValues` /
    `redactValues` (reworked in A-S10).
  - POSIX `InterProcessLock` uses `flock(fd, LOCK_EX | LOCK_NB)` via `dart:ffi`
    (with `open` declared variadic for Apple arm64, R-M1; macOS execution
    *unverified* until the owner runs the `dart-macos-locks` CI job in
    `.github/workflows/dart.yml`) plus an in-process path registry
    (reworked in A-B5, R-S7).

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

- (Resolved 2026-11-09: Checkpoint A passed in re-review 3; the original
  Checkpoint A questions 1–5 were answered in
  `docs/flutter-migration/reviews/checkpoint-A.md`.)
- Phases 5–8 are in progress, unreviewed (Checkpoint A signed off 2026-11-09).
  Open questions deferred to Checkpoints B / C / D:
  1. (Resolved 2026-11-10 in Checkpoint B B-B4 & B-M6: unified onto Strings, Tokens, and strakalari_core; deleted duplicate string tables and common/schedule_logic.dart, common/lesson_model.dart, marks/grades_logic.dart, lunches/lunch_filter.dart).
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
- App version stays the flutter-create template `1.0.0+1` (resolved 2026-11-07:
  CI stamps the real version from the tag at build time).
- (Resolved 2026-11-07: PLAN.md rows 7–8 and REVIEW_PROMPT.md are the owner's
  intended edits, committed as-is.)


### Phase 5 wiring finding (2026-11-09)
The 10 screen views are driven by feature-local controllers (features/*), parallel to the AppState ports in controllers/*; router.dart builds them with empty config, so no screen shows real data yet. Plan: adapt each feature controller to read/write AppState (one screen per commit). Done: AppState refresh/test-connection/update-check workers (port of _refresh_work/_test_work/_update_work) + app/test/app_state_refresh_test.dart (3 tests). Excuse send worker (_excuse_worker), order submit worker (_ordersWork + recordWebOrders + setLowBalanceMemory) and AI recommend worker (_aiRecommendWork) are now ported in controllers/excuses.dart and controllers/lunches.dart, with 4 ported test files: order_latch_test.dart (7), excuse_day_scope_test.dart (7), flet_data_wiring_test.dart (9), lunch_same_pick_test.dart (5) — 156 app tests passing.
Activity screen is live (features/activity/activity_live.dart, snapshot controller + LiveActivityView; 2 tests). Bug fixed on the way: AppStateController mutated the shared AppState in place and Riverpod skipped the notification, so no screen would ever have repainted; it now overrides updateShouldNotify. Absences screen is live (features/absences/absences_live.dart + absences_live_test.dart (2)). Lunches screen is live (features/lunches/lunches_live.dart + lunches_live_test.dart (2)). Remaining screens to bridge: today, timetable, marks, planner, settings, wizard.

## Checkpoint notes

- 2026-11-08 · Checkpoint A review: **FAIL** (5 blockers, 8 must-fix) — [docs/flutter-migration/reviews/checkpoint-A.md](docs/flutter-migration/reviews/checkpoint-A.md)
- 2026-11-08 · Checkpoint A rework: **COMPLETE** (all 5 blockers, 8 must-fix, 10 should-fix, and N1 resolved in 23 atomic commits `ee364bd..b953c09`, verified from `git show --stat`):
  - **A-B1** (`ee364bd`): added DST-safe `addDays` and `daysBetween` helpers in `storage/helpers.dart`, replaced `Duration(days:)` day arithmetic across 13 core files (`automation.dart`, `excuse_history.dart`, `refresh.dart`, `bakalari/data.dart`, `bakalari/excuse.dart`, `bakalari/timetable.dart`, `lunch_auto.dart`, `lunch_cutoff.dart`, `grades.dart`, `planned_skips.dart`, `schedule.dart`, `status_notification.dart`, `wakeup.dart`), set `TZ: Europe/Prague` in `.github/workflows/dart.yml`, and added `test/dst_test.dart` plus DST parity cases in `tools/parity/dump.py`.
  - **A-B2** (`7a045dd`): wrapped `openUrl` (DNS + connect) in `DartIoHttpTransport.send` with `ConnectFailure` (`bakalari/http_session.dart`, `strava/client.dart`) so `isNeverSentCause` is true only for pre-connection failures, and added phase-based excuse/session tests.
  - **A-B3** (`e0d0ebf`): fixed the inverted `findSaveButton()` check in `automation.dart` (`final immediate = !client.findSaveButton();`), restored the fake `saveButton` flags in `automation_test.dart`, and added a default-client failed-order test.
  - **A-B4** (`441a05e`): made `planAutoOrdersHook` async (`Future<(Map<String, String>, bool)> Function(...)` taking `ordered: Map<String, String>`), defaulted it to `planAutoOrders` in `refresh.dart`, aligned `lunch_auto.dart`, and added `defaultHookOrdersGapDay` in `refresh_test.dart`.
  - **A-B5** (`2eff0b5`): implemented POSIX `flock(fd, LOCK_EX | LOCK_NB)` via `dart:ffi` plus an in-process held-path registry in `storage/helpers.dart`, added `withSessionLockAsync` in `automation/session_lock.dart` (and wired `app/lib/platform/android/background.dart` to it), and added lock/cross-process tests in `session_lock_test.dart`.
  - **A-M1** (`56c34aa`): reworked `HistoryLock` in `automation/excuse_history.dart` to use a per-path FIFO async mutex with `Zone`-scoped re-entrancy and async polling of `tryFileLock`, removed `_sendTail` from `automation.dart`, and added `concurrentSyncWaitsForSendAndKeepsBoth` in `automation_test.dart`.
  - **A-M2** (`5857842`): updated `loadUnconfirmed` in `automation/excuse_history.dart` to quarantine corrupt JSON or bad UTF-8 via `quarantineCorruptFile` and return `[]` while rethrowing other `FileSystemException`s, with tests in `excuse_history_test.dart` and `automation_test.dart`.
  - **A-M3** (`73cd892`): ported `DataMixin.fetchData()` in `bakalari/data.dart` (with full per-run field reset, cancel check, and `login()` prelude), delegated `Strakalari.fetchBakalariData` in `automation.dart` to it, and added `aSecondRunSeesOnlyFreshData` in `bakalari_data_test.dart`.
  - **A-M4** (`e734e04`, `763ec48`): added platform CRLF newline conversion (`toPlatformNewlines`) and Python JSON separators (`pyJsonDumps`, `jsonIndent2`) in `storage/helpers.dart`, `automation/audit.dart`, and `automation/automation.dart` (`e734e04`); added cross-language byte-identity round-trip tests across config, cache, history, sidecar, planned skips, and presets in `helpers_test.dart`, `parity_helpers_test.dart`, and `tools/parity/dump.py` (`763ec48`).
  - **A-M5** (`f5f7f16`): normalized `dataDir` in `secret_store.entryName` (`p.normalize(p.absolute(dataDir))` + lowercase on Windows) and added path-normalization parity cases in `tools/parity/dump.py` and `secret_store_test.dart`.
  - **A-M6** (`57a54f4`): made `secret_store.dart` throw `KeyStoreUnavailable` on desktop when `keyStoreBackend == null` unless `STRAKALARI_NO_KEYRING` is set, opted CLI tools (`bin/parity_fetch.dart`, `bin/refresh_dryrun.dart`) and tests in explicitly, and added `missingBackendOnDesktopThrowsInsteadOfCreatingFile` in `secret_store_test.dart`.
  - **A-M7** (`0d37753`): made `tools/parity/dump.py` re-exec itself with `PYTHONHASHSEED=0` when unset and regenerated `test/parity/schedule.json`.
  - **A-M8** (`a3811a3`): updated `STATUS.md` to mark phases 5–9 `in progress, unreviewed`, mapped all 94 Python test files, and added `keepLunchChoiceIsStoredAndHonored` in `planned_skips_test.dart`.
  - **A-S1** (`92181d8`): replaced `List.sort` in `automation.dart` with two-pass cancellation-first then order staging to preserve day order, with a test in `automation_test.dart`.
  - **A-S2** (`b8b37d8`): implemented `_pyFloatRepr` in `storage/helpers.dart` so JSON writers match Python float formatting (`1e-07`, `1e+16`), with tests in `helpers_test.dart` and `tools/parity/dump.py`.
  - **A-S3** (`c9dc71f`): switched lock acquisition deadlines to `Stopwatch` and stale-lock age checks to `clock.now()` in `storage/helpers.dart`, with tests in `helpers_test.dart`.
  - **A-S4** (`c6b4941`): set `STRAKALARI_NO_KEYRING=1` before imports in `tools/parity/fetch.py` and `tools/parity/soak_refresh.py`.
  - **A-S5** (`d2f9eba`): made `bin/refresh_dryrun.dart` refuse `--send-day` unless the target host is `127.0.0.1`, `localhost`, or `[::1]`, with a test in `refresh_test.dart`.
  - **A-S6** (`bcb07bf`): updated `bin/refresh_dryrun.dart`, `tools/parity/soak_refresh.py`, and `tools/parity/soak_compare.py` to run `excusePending()` in dry run and compare the full cache, history, sidecar, and audit.
  - **A-S7** (`e4bb8e1`): changed `PeriodicRunner`'s `Job` typedef in `automation/scheduler.dart` to `FutureOr<Object?> Function()` and awaited jobs so async failures trigger the 5-minute retry, updating `scheduler_test.dart`.
  - **A-S8** (`cfaf7f4`): narrowed HTTP read retries in `bakalari/http_session.dart` and `strava/client.dart` to `isDroppedReadError`, with tests in `http_session_test.dart`.
  - **A-S9** (`1a97efa`): bounded `DartIoHttpTransport.send` connect phase by `min(timeout, 20 s)` (`connectionTimeout` + `openUrl.timeout`), with a test in `http_session_test.dart`.
  - **A-S10 + A-N1** (`b953c09`): delegated `Strakalari._redactLog` in `automation.dart` to `error_report.secretValues` / `redactValues`, removed parent-dir creation in `writeLog`, and let cancel-predicate / school-year-start errors propagate in `refresh.dart`.
- 2026-11-08 · Checkpoint A re-review: **FAIL** (all A-* findings fixed; 0 blockers, 3 must-fix, 7 should-fix new) — [docs/flutter-migration/reviews/checkpoint-A.md](docs/flutter-migration/reviews/checkpoint-A.md#re-review-2026-11-08)
- 2026-11-09 · Checkpoint A re-review rework: **COMPLETE** (all R-* findings resolved in atomic commits; ready for re-review):
  - **R-M1** (`2ae814b`): declared libc `open` in `storage/helpers.dart` as variadic (`ffi.VarArgs<(ffi.Int32,)>`) for Apple arm64 ABI compatibility and added `freshLockFileIsOwnerReadWritable` in `session_lock_test.dart` (macOS execution *unverified* until the owner runs the `dart-macos-locks` CI job).
  - **R-M3** (`6e6c723`): ported `test_gemini_fallback_is_not_a_gemini_run` as `geminiFallbackIsNotAGeminiRun` in `refresh_test.dart` and updated item 58 of the test map.
  - **R-S1** (`8f70936`): replaced dead `on OSError` catches with `on FileSystemException` in `automation.dart` (`writeLog` rotation), `secret_store.dart` (`carryKey`), and `helpers.dart` (`decrypt`, plus `on KeyStoreUnavailable`), updated `decryptSurvivesKeyFileOSError` in `secret_store_test.dart`, and added `failedLogRotationStillAppendsTheLine` in `automation_test.dart`.
  - **R-S2** (`2cd35ae`): removed the delete-then-rename fallback from `_replaceFile` in `storage/helpers.dart` and `_writeFile` in `storage/secret_store.dart` so `renameSync` matches `os.replace`, and added `replacesAnExistingFile` and `failedReplaceNeverDeletesTheTarget` in `helpers_test.dart`.
  - **R-S3** (`4aafeb3`): changed `excusePostback` in `bakalari/excuse.dart` to use `clock.now()` instead of `DateTime.now()`, and added `postbackWithoutNowReadsTheClock` in `bakalari_excuse_test.dart`.
  - **R-S4** (`a487824`): added `dst_cases()` in `tools/parity/dump.py` (`test/parity/dst.json`) and replaced the re-implemented arithmetic tests with `test/parity_dst_test.dart` (`fetchTimetableWeeksAsksForPythonsMondays`, `substitutionRangeIsPythonsCalendarRange`) and `missingHistoryWeeksStepByCalendarDaysLikePython` in `refresh_test.dart`, driving the real code under `withClock`.
  - **R-S5** (`d5366ea`): added `ConnectFailure.isTimeout` in `bakalari/http_session.dart` so connect timeouts produce `timeoutUserMessage()` in both Bakaláři and Strava (`strava/client.dart`), while post-connect `SocketException`s in Strava produce `strava_connection_lost` (only `ConnectFailure` gives `strava_unreachable`), with tests in `http_session_test.dart` and `strava_test.dart`.
  - **R-S6** (`998906d`): added `pyRepr` in `storage/helpers.dart` (with parity cases in `tools/parity/dump.py` and `parity_helpers_test.dart`), formatted map/list log interpolations in `automation.dart` (and `school_presets.dart`) with `pyRepr`, and added `excuseLogLinesUsePythonMapRepr` in `automation_test.dart`.
  - **R-S7 + R-N4 + R-N5** (`c035cb1`): printed a one-time `Warning:` in `_loadLibc()` (`storage/helpers.dart`) if loading libc for `flock` fails and falls back to `lockSync`; aligned `refresh.dart` to pass `app.orderedDict.isNotEmpty ? app.orderedDict : orderedBefore` to `updateHandledDaysHook` (`R-N4`); aligned `sent_excuses_limit` float truncation in `automation.dart` with Python `int()` (`R-N5`).
  - **R-M2** (this commit): rewrote the Checkpoint A rework list in `STATUS.md` from `git show --stat` of each commit, corrected the `HistoryLock` deviation description, updated suite counts (`764 passed, 2 skipped` in core; `123 passed, 1 skipped` in app), fixed the Checkpoint B/C status header under Questions, and added `[N functions]` alongside `pytest --collect-only` counts for all 13 parameterized test files.
- 2026-11-09 · Checkpoint A re-review 2: **PASS WITH FIXES** (all R-* findings fixed; 0 blockers, 0 must-fix, 3 should-fix new: `R2-S1..R2-S3`) — [docs/flutter-migration/reviews/checkpoint-A.md](docs/flutter-migration/reviews/checkpoint-A.md#re-review-2-2026-11-09)
- 2026-11-09 · Re-review 2 fixes: **COMPLETE**, made by the reviewer at the owner's request (so the next review must be a fresh session):
  - **R2-S1** (`ff41575`): `dst_cases` in `tools/parity/dump.py` also starts on 23.3.2026 and 19.10.2026 (the Monday a week before each switch), so the forward steps (next timetable week, 14-day substitution range) cross a switch; `test/parity/dst.json` regenerated. Reintroducing `Duration(days: 14)` in `fetchSubstitutions` now fails `substitutionRangeIsPythonsCalendarRange`.
  - **R2-S2** (`212dac2`, `a8545b1` writes the U+2028/U+2029 regex and oracle characters as escapes): `describeSwallowed` in `storage/helpers.dart` takes the first line like Python `splitlines()[0][:160]` (all Python line breaks, 160 code points); 10 `describeSwallowed` parity cases in `dump.py` / `parity_helpers_test.dart` (the old code fails them).
  - **R2-S3** (`730f61a`): new `dart-macos-locks` job in `.github/workflows/dart.yml` (Apple silicon, manual run or release tag) runs `session_lock_test.dart` + `helpers_test.dart` with `TZ=Europe/Prague`; the three STATUS lines name it.
- 2026-11-09 · Checkpoint A re-review 3: **PASS** (all R2-* findings fixed; 0 blockers, 0 must-fix, 0 should-fix; notes R3-N1..R3-N4 for later checkpoints) — [docs/flutter-migration/reviews/checkpoint-A.md](docs/flutter-migration/reviews/checkpoint-A.md#re-review-3-2026-11-09)
- 2026-11-10 · Checkpoint B review: **FAIL** (5 blockers, 14 must-fix, 6 should-fix) — [docs/flutter-migration/reviews/checkpoint-B.md](docs/flutter-migration/reviews/checkpoint-B.md)
- 2026-11-10 · Checkpoint B rework (in progress):
  - **B-B1** (`5ae03cc`): build tracked subjects from directory keys instead of values in `app/lib/controllers/app_state.dart`.
  - **B-B2** (`954a2e4`): route Today excuse tasks and day plan directly through AppState, delete redundant `excuse_logic.dart`, and enforce send path guard.
  - **B-B3** (`c7e06d7`): remove screenshot script from app tests and establish standalone parity capture tools (`tools/parity/capture_screens.dart` and `tools/parity/capture_flet.py`).
  - **B-B4** (`aa28710`): delete duplicate string tables (`common/app_strings.dart`, `class Str` in `overlays.dart`), unify all UI views and tests to canonical `Strings.get()` / `Strings.format()`, add `hasKey` and `allKeys` in `Strings`, fix hardcoded strings in settings/wizard/planner, and add `app/test/strings_table_parity_test.dart`.
  - **B-B5** (`8632ff4`): port automatic mode confirmation dialog (`AutoConfirmDialog`, `confirmAutoMode`) in `app/lib/widgets/safety_dialog.dart` matching `strakalari/flet_ui/safety.py`, wire `confirmAutoMode` callback in `settings_live.dart` and `settings_view.dart`, remove false "Saved" snack on cancellation, and port the 3 deferred tests in `app/test/safety_dialog_test.dart`.
  - **B-M1** (`aa9a48d`): rebuild shell top bar in `app/lib/shell/scaffold.dart` matching Python `_build_topbar` / `_build_narrow_topbar` (status pill with colored dot, status text calculation, tooltip, tap to /activity; update button; primary refresh button in wide / icon in narrow; cancel refresh button during active refresh; already_running / refresh_started snacks; removed AppBar and duplicate titles; right content column positioning) and add comprehensive test suite in `app/test/topbar_test.dart`.
  - **B-M2** (`cbed3c8`): align navigation rail width (standard unextended 90px rail with `labelType: all`), side rail (centered `groupAlignment: 0.0`, all labels, lunch badge), shell content padding (`EdgeInsets.all(tok.pad + 8)` wide, `symmetric(12, 4)` narrow), divider styling (`color: tok.border`, thickness 1), wide-mode leaving More to Today, and add `app/test/rail_and_scaffold_test.dart`.
  - **B-M3** (`53dae96`): render first-run setup wizard outside app chrome (standalone top-level `/wizard` route with no rail, bottom bar or top bar refresh controls), enforce setupPending isolation in `AppScaffold`, keep wizard active across mid-wizard credential saves, and add `app/test/wizard_chrome_isolation_test.dart`.
  - **B-M4** (`968a09a`): catch view rendering errors in `ViewErrorBoundary` wrapped around views in `AppScaffold`, report to `AppState.reportError` with route tag, render error card matching Python, and add `app/test/error_boundary_test.dart`.
  - **B-M5** (`019ec5f`): wire tutorial `begin(route)` in scaffold, floating bubble layer (`tutorialLayer`), 18 UI anchors across all views, delete duplicate tutorial controller in `overlays.dart`, and port deferred tutorial tests in `app/test/tutorial_test.dart` (28 tests).
  - **B-M6** (`faa1a77`): delete duplicated feature business logic in `app/lib/features/` (`common/schedule_logic.dart`, `common/lesson_model.dart`, `marks/grades_logic.dart`, `lunches/lunch_filter.dart`), re-point today, timetable, marks, and lunches controllers and views directly to `strakalari_core` and `AppState`, add `MarkRow.text` in `strakalari_core`, add `app/lib/features/lunches/lunches_format.dart` for Strava display parsing, remove obsolete `convertStableBaseline`, and update `lunches_filter_test.dart` to test canonical `core.prefsBanKeywords`, `core.isFoodBanned`, and `AppState.applyFoodFilter`.
  - **B-M7**: port ~150 deferred UI test cases into `app/test/` across 13 suites (total 405 app tests passing green):
    - `excuse_day_scope_test.dart`: `test_day_card_switch_sends_lessons_separately` (8/8)
    - `early_leave_test.dart`: full port of `test_early_leave.py` (`TestSoonDetection`, `TestSoonStatus`, `TestSoonTemplates`) (13/13)
    - `timetable_week_switch_test.dart`: full port of `test_timetable_week_switch.py` (3/3)
    - `stable_change_signals_test.dart`: UI cases from `test_stable_change_signals.py` (3/3)
    - `open_url_test.dart`: runtime cases for `openUrl` via `app/lib/features/common/open_url.dart` (3/3)
    - `settings_refresh_interactive_test.dart`: full port of `test_settings_refresh_interactive.py` (4/4)
    - `marks_view_test.dart`: full port of `test_marks_view.py` (15/15)
    - `planner_dialog_test.dart`: full port of `test_planner_dialog.py` (6/6)
    - `plan_picker_test.dart`: full port of `test_plan_picker.py` (12/12)
    - `wakeup_ui_test.dart`: UI cases across `TestTimetableViews`, `TestCollapsibleDays`, `TestWakeupUI` (12/12)
    - `mobile_narrow_shell_test.dart`: full port of `TestNarrowShell` from `test_mobile.py` (10/10)
    - `ui_views_test.dart`: full port of remaining `test_ui_views.py` cases (19/19)
    - `wizard_setup_full_test.dart`: full port of remaining `test_wizard_setup.py` cases (36/36)
    - Fixed view and controller logic for parity: normalized marks bands in `MarksLogic.setMarksBands`, used canonical `core.entriesForSelection` in planner custom dialog, exposed `expandedDays` reactive state in `LunchesController`, added `PopScope` hierarchy in `Scaffold`, and made wizard nav buttons responsive via `LayoutBuilder`.
    - Documented dropped Flet-specific framework tests: Flet container reuse (`test_scrollable_reuses_container_across_rebuilds`, `test_scrollable_row_and_type_mismatch`, `test_timetable_build_reuses_body_across_renders`), Flet RPC monkeypatching (`test_stale_method_reply_does_not_raise`), Flet scroll offset restoration (`test_restore_scroll_only_touches_scrollers_of_current_render`), and AST reflection tests (`test_open_url_ast_inspection`, `test_open_url_controls_are_safe`).
  - **B-M8**: print Python-equivalent warning messages in `AppState.save` on failure ("Warning: could not save config: {exc}"), invalid update ("Warning: ignoring invalid config update {key!r}: {err}" formatted with `core.pyRepr`), and listener failure ("Warning: config listener failed: {exc}"), verified with `app/test/app_state_save_warnings_test.dart`.
  - **B-M9**: settings and app preferences parity: implemented `refreshTokens()` in `AppState` (invoked at end of constructor and in `save()`), reading forced theme `STRAKALARI_THEME` (`'light'` / `'dark'`), updating `tok` (`Tokens`) and `appTokens` (`AppTokens`), applying `compact_density` (`pad: 10, gap: 8`), and initializing `core.setLanguage` and `Strings.lang` at startup without requiring a save. Added `copyWith` on `Tokens` and `AppTokens`, updated `main.dart`, `scaffold.dart`, `router.dart`, `tutorial_ui.dart`, and `error_boundary.dart` to use active `appState.tok` / `appTokens`, verified with `app/test/app_state_theme_and_prefs_test.dart` (10/10 passed).
  - **B-M10**: More page and Android Back navigation parity: implemented `openMoreRoute` (routing `alarm` to Settings with `settingsSection = 'alarm'` and `settingsOpen = true`, and `settings` with `settingsOpen = false`), wired `isAndroid: mobilePlatform() == 'android'` into `MorePage`, restyled `MorePage` (bold `fsTitle` heading, `tok.card` tiles with accent leading icons, `fsSection` titles, faint trailing chevrons, and `tok.gap / 2 + 2` spacing), implemented phone Back hierarchy via `subpageOpen`, `closeSubpage`, and `wrapPop` with `PopScope` on phone layouts only (closing open settings sections, selected marks subjects, and open lunch tools before stepping up from More screens to More, and any screen to Today), and verified with `app/test/more_page_test.dart` and `app/test/mobile_narrow_shell_test.dart` (425 app tests passing).

### ⛔ Checkpoint A: core review (phases 1–4)

Done: all phase 1–4 core modules ported with Dart tests first; `tools/parity/dump.py`
generates 17 parity JSON fixtures (including `dst.json`); `dart analyze` + `flutter analyze`
clean; Dart core suite **764 passed, 2 skipped** (1 Linux-only `flock` probe, 1 POSIX-only
permission-bit check on Windows); Flutter app suite **123 passed, 1 skipped** (APK scan,
needs `STRAKALARI_APK`); Python suite **1643 passed** (reference, unchanged); dry-run
refresh parity Python-vs-Dart (`soak_compare.py`) **IDENTICAL**.

Every deviation from Python is listed under Deviations above; Python
behavior that looked wrong was ported as-is (nothing "fixed").
How to verify:
- `dart analyze` + `dart test` in `packages/strakalari_core`,
  `flutter analyze` + `flutter test` in `app`.
- `PYTHONUTF8=1 python tools/parity/dump.py` then
  `git diff --exit-code packages/strakalari_core/test/parity/`.
- Dry-run parity: `python tools/bakalari_demo_server.py --port 18080`,
  `python tools/parity/soak_refresh.py` vs `dart run bin/refresh_dryrun.dart`,
  then `python tools/parity/soak_compare.py`.
- Cross-process session lock proof: `dart test test/session_lock_test.dart`.
Unsure / needs a second pair of eyes:
- macOS execution of the variadic `open()` POSIX `flock` path (`R-M1`): verified
  by static types and Linux/Windows tests; marked *unverified* on macOS until
  the owner runs the `dart-macos-locks` CI job (`.github/workflows/dart.yml`;
  manual run or release tag, Apple silicon).
- `error_report.collectContext` keys `dart` (not `python`),
  `app_version: '?'`, `build: 'source'`; `currentTraceback` frames are Dart
  `#0` style. Shapes match; values are platform truth.
- `summarize` keeps insertion order on equal/None dates explicitly
  (Dart sort isn't stable; Python's is); `summarizeAll`/`canonSubject`
  use `toLowerCase` (Python `casefold` — differs only for exotic
  Unicode like ß); `int(True)`-style bool periods return null.
- Gemini `localFallbackRecommendation` keyword lists ported line by
  line (Czech stems); only covered via parity fixtures + fakes.

### ⛔ Checkpoint B: UI review (phases 5–6, complete, pending reviewer sign-off)

Phases 5 and 6 are complete. Shell (router, adaptive scaffold, theme tokens, ARB
localization, error dialogs, tutorial tours) and all screens (wizard, today,
timetable, absences, marks, planner, lunches, activity, settings, more) are
fully implemented and wired to live `AppState` and `strakalari_core`.

What was done:
- Live Riverpod `AppState` bridges for all screen controllers (`todayControllerFor`,
  `timetableControllerFor`, `absencesControllerFor`, `marksControllerFor`,
  `plannerControllerFor`, `lunchesControllerFor`, `activityControllerFor`,
  `settingsControllerFor`).
- Asynchronous task runners and workers ported to `AppState` facades:
  - `activity.dart`: interactive refresh (`startRefresh`, `cancelRefresh`), credential tests (`testCredentials`), update checks (`checkForUpdate`).
  - `excuses.dart`: excuse submissions (`submitExcuse`, `submitDayExcuse`), excuse ignore-list management (`ignoreExcuse`, `ignoreDay`, `unignoreKeys`), already-excused reconciliation.
  - `lunches.dart`: meal ordering (`orderMeal`, `cancelOrder`, `batchOrderMeals`), AI meal recommendations (`recommendMealsViaAi`), blacklist management (`setBlacklist`, `toggleBlacklist`).
  - `planner.dart`: planned skips, budget optimization, cache invalidation.
  - `settings.dart`: configuration mutation, save hooks, language and auto-schedule preferences.
  - `update.dart`: update cache retrieval and dismissals.
- Deferred Phase 5/6 AppState and UI test suites ported & 100% green:
  - `app/test/app_state_lunches_test.dart` (25 tests covering `test_lunches.py`, `test_lunch_matching.py`).
  - `app/test/app_state_excuses_and_planner_test.dart` (30 tests covering `test_excuse_ignore_list.py`, `test_planned_skips.py`, `test_error_report.py`, `test_cancel_responsive.py`, `test_news.py`, `test_ui_state.py`, `test_update.py`, `test_automation_safety.py`, `test_settings_refresh_interactive.py`).
  - `app/test/phase6_features_test.dart` (15 tests covering `test_early_leave.py`, `test_timetable_week_nav.py`, `test_marks_view.py`, `test_wizard_setup.py`, `test_year_planner.py`).
  - `app/test/screenshot_parity_test.dart` (10 tests capturing parity screenshots).
  - Total app tests: 242 passed, 1 skipped. Core tests: 764 passed, 2 skipped.
  - `dart analyze` and `flutter analyze`: zero issues found across both packages.
- Parity screenshots:
  - Standalone capture tools established under `tools/parity/`:
    - `tools/parity/capture_screens.dart`: captures whole Flutter app (router + AppScaffold + live views, real Roboto and MaterialIcons fonts loaded from SDK cache, light/dark themes, cs/en languages, 1280x800 and 390x844 viewports, 80 screen images total).
    - `tools/parity/capture_flet.py`: automates Flet reference capture via Playwright driving `demo_data.py serve` across all routes, both themes, both languages, both viewports into `build/parity-screens/flet/`.
    - Removed `screenshot_parity_test.dart` from `app/test/` so default test suites run pure unit/widget assertions.
    - Remaining visual differences (top bar, rail width, table styling, wizard isolation) documented in Checkpoint B review findings and being addressed sequentially.
- Windows desktop compilation:
  - `flutter build windows --debug` succeeded (`Strakalari.exe` generated cleanly).

How to verify:
- `cd packages/strakalari_core && dart analyze && dart test` (764 passed, 2 skipped).
- `cd app && flutter analyze && flutter test` (425 passed, 1 skipped).
- Inspect side-by-side screenshots in `build/parity-screens/flet/` vs `build/parity-screens/flutter/`.
- Test app startup on demo data dir: `python tools/demo_data.py generate build/parity-screens/demo-cs` and run debug executable.

Unsure / needs a second pair of eyes:
- String tables unified onto canonical Strings in B-B4; token handling unified onto AppState.tok / appTokens in B-M9.
- Planner cache key holiday comparison: stringified sorted dates used for pure value comparison across Dart records.
- `wakeupAvailable` remains stubbed to false pending Android Phase 8 implementation.

### ⛔ Checkpoint C: platform review (phases 7–8, in progress, unreviewed)

In progress, unreviewed, largely UNVERIFIED on this machine (see the per-area
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

### ⛔ Checkpoint D: release review (phase 9, in progress, unreviewed)

In progress, unreviewed: `tools/parity/soak_refresh.py` + `soak_compare.py`,
`docs/flutter-migration/SOAK.md` routine, README/PRIVACY/CONTRIBUTING
wording. Multi-day side-by-side soak and the beta cut wait for
Checkpoints A–C sign-off and the owner's go-ahead — no tag/merge/push done.

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
