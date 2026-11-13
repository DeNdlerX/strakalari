# Flutter migration status

Branch: flutter-migration · Flutter: 3.44.8 · Last main commit ported: 0ffdcff
Current phase: 9 (Parity soak & release prep — Day 1 complete) · Next step: **Checkpoint passed (C). Continue phase 9: soak Days 2–3 per `docs/flutter-migration/SOAK.md`, then stop at Checkpoint D.** The Windows Sandbox re-test (C-M7, desktop half) stays deferred by the owner and must pass before Checkpoint D can pass: do not start it without the owner.
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
Phase 6 (screens) is complete and passed Checkpoint B: all 10 screens are wired to live state and
restyled like the Flet screens (round 4: Today, Planner, Lunches, Activity, Settings, shared theme); both screenshot
sets were re-captured and compared on 1280 and 390 px, light and dark. App suite: 502 passed, 1 skipped
(APK scan needs `STRAKALARI_APK`); core: 764 passed, 2 skipped; both analyzers clean.
⛔ Checkpoint B: UI review (re-review 5: **PASS**, 2026-11-12; nothing verified on a phone or in Windows Sandbox).
Phase 7 (desktop) is done and reviewed: tray + hide-to-tray, autostart,
single-instance loopback-TCP, notifications, desktop keystores, Inno
(AppId kept) + MSIX adaptations, CI release jobs. Still open: the
Windows Sandbox over-install test (C-M7, desktop half, deferred by the
owner); macOS and Linux are unverified until the owner's CI run.
Phase 8 (Android) is done and reviewed: Java moved (R import line in 6
files, the reboot notice removed from BootReceiver), StrakalariChannel,
headless backgroundMain with UI-isolate hand-off, boot re-arm,
widget/alarms, Keystore unwrap, `.test` flavor, privacy test port.
Verified on the test phone by the migrating agent (2026-11-13).
⛔ Checkpoint C: platform review (re-review 3: **PASS**, 2026-11-13; Sandbox half of C-M7 open).
Phase 9 (parity soak & release prep) has Day 1 green and CR-N5 fixes landed
(`9d868c5`, `2f2b0f6`); Days 2–3 soak and the Windows Sandbox re-test (`C-M7`)
remain before Checkpoint D. Beta release waits for Checkpoints A–D sign-off
and the owner's go-ahead. ⛔ Checkpoint D: release review (unreviewed).
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
| strakalari/__main__.py | app/lib/main.dart | — | done |
| strakalari/core/__init__.py | core barrel | — | done |
| strakalari/core/android.py | core platform/android_bridge.dart + app MethodChannel | test_notify.py, test_wake_ui.py, test_wakeup_and_widget.py | done |
| strakalari/core/audit.py | core automation/audit.dart | test_automation_safety.py (audit cases) → audit_test.dart (4) + parity_audit_test.dart | done |
| strakalari/core/automation.py | core automation/automation.dart | test_automation_safety.py (core cases), test_excuse_generation.py (25), test_strava_low_balance.py (2 order cases), test_strava_ordering.py (15), test_unconfirmed_excuses.py (TestSendPath/TestOutboxSettles), test_excuse_history.py (send/coverage/dry-run cases) → automation_test.dart (78) + refresh_test.dart; `test_order_latch.py` (4) is `AppState` (deferred phase 5) | done |
| strakalari/core/autostart.py | app platform/desktop/autostart.dart | test_autostart.py 3 + test_autostart_platforms.py 5 → autostart_test.dart 8 | done (macOS/Linux unverified) |
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
| strakalari/core/wakeup.py | core wakeup.dart (pure scheduling/message logic; alarms/receivers in the app) | test_wakeup_and_widget.py (21 core cases) → wakeup_test.dart (21) + parity_wakeup_test.dart; the UI cases → wakeup_ui_test.dart / wakeup_settings_card_test.dart; test_wake_ui.py (2) dropped | done |
| strakalari/flet_ui/__init__.py | app barrel (shell + features) | — | done |
| strakalari/flet_ui/__main__.py | app/lib/main.dart | widget_test.dart smoke (boots + rail navigation) | done |
| strakalari/flet_ui/app.py | app/lib/main.dart + shell/ | widget_test.dart smoke; navigation covered | done |
| strakalari/flet_ui/assets.py | app assets | test_icons.py 13 → icons_test.dart 15 | done |
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
| strakalari/flet_ui/state_tutorial.py | app controllers/tutorial + tutorial/tours | tutorial_test.dart (28) | done |
| strakalari/flet_ui/strings.py | app l10n ARB (app_cs/en + strings.dart) | settings_sections_test.dart (15) | done |
| strakalari/flet_ui/theme.py | app/lib/shell/theme.dart | widget_test.dart breakpoints | done |
| strakalari/flet_ui/tray.py | app/lib/platform/desktop/tray.dart | — (Sandbox test pending) | done |
| strakalari/flet_ui/tutorial.py | app/lib/tutorial/ + widgets/overlays (kTours) | tutorial_test.dart (28) | done |
| strakalari/flet_ui/views/__init__.py | app features barrel (router) | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/absences.py | app features/absences | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/activity.py | app features/activity | activity_view_test.dart (6) | done |
| strakalari/flet_ui/views/lunches.py | app features/lunches | lunches_view_test.dart (9) | done |
| strakalari/flet_ui/views/marks.py | app features/marks | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/more.py | app features/more.dart | overlays_test.dart +more (8) | done |
| strakalari/flet_ui/views/planner.py | app features/planner | planner_view_test.dart (10) | done |
| strakalari/flet_ui/views/settings/__init__.py | app features/settings | settings_sections_test.dart (15) | done |
| strakalari/flet_ui/views/settings/accounts.py | app features/settings | wizard_settings_test.dart (5) | done |
| strakalari/flet_ui/views/settings/app_prefs.py | app features/settings | settings_quietsave_test.dart (6) | done |
| strakalari/flet_ui/views/settings/automation.py | app features/settings | settings_sections_test.dart (15) | done |
| strakalari/flet_ui/views/settings/common.py | app features/settings | settings_sections_test.dart (15) | done |
| strakalari/flet_ui/views/settings/school_calendar.py | app features/settings | settings_sections_test.dart (15) | done |
| strakalari/flet_ui/views/settings/view.py | app features/settings | settings_sections_test.dart (15) | done |
| strakalari/flet_ui/views/timetable.py | app features/timetable | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/today.py | app features/today | widget_test.dart rail pass | done |
| strakalari/flet_ui/views/wizard.py | app features/wizard | wizard_settings_test.dart (5) | done |

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
4. `tests/test_autostart.py` (3) → `app/test/autostart_test.dart`: `getLaunchCommandMinimized`, `getLaunchCommandNotMinimized`, `launchCommandHasNoShellQuotes`
5. `tests/test_autostart_platforms.py` (5) → `app/test/autostart_test.dart`: `TestWindows` (3, fake Run key), `TestMacOS` (1), `TestLinux` (1), temporary HOME
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
    - `test_cancel_refresh_noop_when_idle` → `app/test/activity_state_test.dart`: `cancel refresh is a no-op when idle`
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
15. `tests/test_entry_routing.py` (5) → `app/test/entry_and_tray_language_test.dart`: `defaultRoutesToTheWindow`, `minimizedRoutesToTray`; the other 3 under *Dropped*
16. `tests/test_error_report.py` (26):
    - 11 pure core cases → `error_report_test.dart` (13 tests: the 11 below plus `logTailIsContextNotTracebackCopy` and `neverContainsSecrets`, which check the report builder that the two `AppState` cases further down go through): `exposesOnlyPresence`, `classification`, `namesFix`, `scrubsSecretValues`, `numericAndShort`, `scrubsDecryptedPasswordAndPersonalData`, `carriesDiagnostics`, `extraSecretsRedacted`, `logTailIsContextNotTracebackCopy`, `neverContainsSecrets`, `prefersTypeAndFirstLine`, `namesBuildAndLanguage`, `raiseUserErrorForMissingLogin`
    - 3 UI dialog cases (`test_user_dialog_hides_traceback_but_copies`, `test_copy_text_writes_to_clipboard_service`, `test_error_dialog_copy_button_copies_report`) → `app/test/overlays_test.dart`: `error dialog with user message hides traceback`, `copy button records a copied confirmation`, plus the extra `error dialog shows summary and traceback` and `showErrorDialog never throws`
    - 11 `AppState` / shell / Activity cases → `app/test/app_state_excuses_and_planner_test.dart` (`reportErrorQueuesPopupWithTraceback`, `reportErrorOutsideHandlerStillSafe`, `acknowledgeClearsPendingButKeepsReport`, `timeoutErrorMarksReportFriendly`, `reportNeverContainsSecrets`, `reportLogTailIsContextNotTracebackCopy`) + `app/test/app_state_error_and_quiet_test.dart` (`userErrorMarksReportFriendly`, `regularErrorHasNoUserMessage`, `reportIsPersistedRedactedToStderr`, `shellPopsQueuedErrorOnce`) + `app/test/activity_view_test.dart` (`activityLogCopyRedactsSecrets`); the last one, `test_copy_text_does_not_mount_clipboard_into_overlay`, is under *Dropped* (11 + 3 + 11 + 1 = 26)
17. `tests/test_excuse_day_scope.py` (8) → `app/test/excuse_day_scope_test.dart` (8 tests, every Python case has a same-named Dart test; checked by name)
18. `tests/test_excuse_generation.py` (41 [25 functions]) → `automation_test.dart` (41 parameterized cases across 25 1:1 camelCase functions): `gapDaysAreNotMerged`, `trulyConsecutiveDaysStillMerge`, `stillExcuses $notice`, `staysCancelled $notice`, `variantsGenerate ${v.$1}/${v.$2}`, `lateVariantsAreIncome ${v.$1}`, `cutoffIsDateBasedNotHourBased`, `excusedTypeSkipped`, `excusedTextWithAbsentTypeSkipped`, `fullyExcusedDayProducesNothing`, `fridayAndTuesdayDoNotBridge`, `presentDayStillBreaksChain`, `firstMode`, `randomModePicksFromList`, `emptyTemplates`, `defaultDelay`, `customDelay`, `multiGroupStatusPrioritization`, `pureDaysConsecutive`, `lateIncomeExcuse`, `pureDaysAcrossWeekend`, `delayDaysCutoff`, `fragmentedSameDayAbsences`, `genericEarlyLeaveIsAutoExcusedLikeUi`, `notCountedAbsenceIsNeverExcused`
19. `tests/test_excuse_history.py` (17):
    - 10 pure/config cases → `excuse_history_test.dart`: `broaderWebExcuseCoversSingleDay`, `partialOverlapIsNotCovered`, `hourRangeNeverCoversWholeDay`, `multiDayHourSpanSemantics`, `taskCoveredMatchesUiRules`, `nonPaddedDatesCanonicalized`, `stripsUiKeys`, `historyEntriesStoreEveryHourShape`, `managerFiltersExampleFallback`, `historyQuarantine`
    - 4 automation cases → `automation_test.dart`: `concurrentSendsSubmitOnce`, `coveredExcuseIsNotResent`, `automationFiltersExampleFallback`, `excuseDryRunFillsWithoutSubmitting`
    - 3 `TestHistoryCoverage` cases (`test_pure_days_covers`, `test_lesson_range_covers_only_inside`, `test_ambiguous_entries_never_hide`) → core coverage rules `broaderWebExcuseCoversSingleDay` / `hourRangeNeverCoversWholeDay` / `taskCoveredMatchesUiRules`, and through the UI wrapper `AppState` in `app/test/app_state_excuses_and_planner_test.dart` (`TestHistoryCoverage` group, 3 tests)
20. `tests/test_excuse_ignore_list.py` (9):
    - 4 `TestIgnoredExcuses` core cases → `automation_test.dart`: `ignoredLessonIsNeverAutoExcused`, `ignoredDayBreaksFullDayChain`, `excuseAbsencePassesConfigIgnoreList`, `garbageKeysAreIgnoredSafely`
    - 5 `AppState` ignore/unignore rollback cases → `app/test/app_state_excuses_and_planner_test.dart` (`ignoreRollsBackWhenSaveFails`, `unignoreRollsBackWhenSaveFails`, `ignoreDayRollsBackWhenSaveFails`, `ignoreSavedNormally`, `ignoreDaySkipsAlreadyExcusedLessons`)
21. `tests/test_flet_data_wiring.py` (9) → `app/test/flet_data_wiring_test.dart` (9 tests, same names as the Python cases)
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
    - `test_new_flet_strings_present`, `test_dead_keys_removed_and_live_keys_kept` → `app/test/strings_table_parity_test.dart` (the string table has the same keys in both languages, every placeholder formats, no dead key under `lib`)
31. `tests/test_icons.py` (13) → `app/test/icons_test.dart` (15): every case by name; the helper cases check the Flutter places (exe icon, bundled tray glyphs, the 64 px glyph) plus the Android launcher icon and manifest identity (C-M4).
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
38. `tests/test_lunch_deadline_calendar.py` (1) → `parity_lunch_cutoff_test.dart` (`effectiveCalendar(clipToClose: false)`); the `AppState.lunchDeadlineCalendar` use is covered by `app_state_lunches_test.dart`
39. `tests/test_lunch_filter.py` (12) → `app/test/lunches_filter_test.dart` (12 1:1 cases): `negation clause yields keyword`, `likes clause ignored`, `mixed text keeps only dislikes`, `bez form`, `conjunction like segment ignored`, `english no form`, `empty`, `prefs hide and stage`, `good pick not clobbered`, `hidden pick replaced`, `cancelled day skipped`, `closed day hides but stages nothing`
40. `tests/test_lunch_same_pick.py` (5) → `app/test/lunch_same_pick_test.dart` (5 tests, same names): `repickingTheOrderedMealIsNoChange`, `aDifferentMealIsAChangeUntilPickedBack`, `noLunchComparesWithTheWebToo`, `submitSendsOnlyPicksThatDiffer`, `refreshUnstagesAPickTheWebNowReports`
41. `tests/test_macos_data_dir.py` (9) → `packages/strakalari_core/test/macos_data_dir_test.dart` (8, through the data-dir seams); `test_source_run_uses_repo_root` under *Dropped*
42. `tests/test_macos_tray_host.py` (15) → `TestQuitSignal` (2) in `app/test/single_instance_test.dart`; the other 13 under *Dropped*
43. `tests/test_marks_view.py` (15) → `app/test/phase6_features_test.dart` (`predictor state add edit remove restore reset`, `scale preferences and preset bands`, `selecting the open subject closes it`, `saving an unchanged mark is not an edit`) + `app/test/marks_live_test.dart` (`LiveMarksView renders subjects and offers marks tutorial`, `marksControllerFor maps AppState grades and syncs predictions`)
44. `tests/test_matching.py` (22 [8 functions]) → `matching_test.dart` (22 parameterized cases across 8 1:1 functions): `$keyword bans $meal`, `$keyword allows $meal`, `rybiDoesNotBanRybiz`, `inflectionStillMatches`, `wholeWordNotSubstring`, `diacriticsInsensitive`, `inflectionVariant`, `caseInsensitive`
45. `tests/test_minimize_to_tray.py` (8) → `app/test/tray_close_test.dart`: `settingIsReadAtEveryClose`, `macosHasNoEmbeddedTray`; the other 6 under *Dropped*
46. `tests/test_mobile.py` (70 [48 functions]):
    - `TestPlatform.*` (4) → `packaging_test.dart`: `desktopIsNotMobile`, `fletPlatformEnv`, `desktopFletBuildIsNotMobile`, `defaultsToFalse`
    - ` test_update_check_per_distribution`, `test_repo_has_no_distribution_marker` → `packaging_test.dart`: `iosComesFromAppStore`, `androidWithoutDistributionIsNull`, `androidPlayChannel`, `offPhoneIsNull`, `emptyEnvironmentIsNull`
    - `TestNarrowShell.*` (12) → `app/test/mobile_narrow_shell_test.dart` (11 same-named tests) + `app/test/widget_test.dart` (`Layout breakpoints match the Python shell`, `Router builds every main screen without throwing`); `test_refresh_ticks_repaint_only_the_topbar` is under *Dropped*
    - `TestMakeMobile.test_stage_has_no_personal_files`, `test_package_check_finds_nested_personal_file`, `test_path_markers_spell_every_separator`, `test_package_check_finds_build_machine_path` → `app/test/packaging_privacy_test.dart`
    - `TestKeystoreKey` (4) → `app/test/android_keystore_test.dart` (4 + 2: Keystore down on a fresh install, two isolates at once), run through the warm-up and core `getKey` (C-B1). `test_build_numbers_grow` → `packages/strakalari_core/test/build_number_test.dart`. `TestDataDir` (2) → `packages/strakalari_core/test/mobile_data_dir_test.dart` (2 + 1: the Flutter-registered folder). `TestPhoneBackground` (3) → `app/test/android_phone_background_test.dart`. `test_open_system_alarm_*` (2 functions, 3 cases) → `app/test/system_alarm_test.dart`. `test_scheduler_holds_runs_while_paused` → `scheduler_test.dart` `schedulerHoldsRunsWhilePaused`. Flet-packaging `TestMakeMobile` (`test_flet_pin_matches_desktop`, `test_extension_wheel`, `test_pyc_shim_*`) under *Dropped*; its package checks are ported in `packages/strakalari_core/test/android_build_test.dart`.
47. `tests/test_models.py` (19):
    - 17 pure model cases → `models_test.dart` (17 1:1 camelCase cases)
    - 2 engine cases (`test_engine_excuses_neomluveno_day`, `test_engine_excuses_unexcused_type`) → `automation_test.dart`: `engineExcusesNeomluvenoDay`, `engineExcusesUnexcusedType`
48. `tests/test_news.py` (7):
    - 6 pure cases → `news_test.dart`: `newMarkReportedOnce`, `marksNeedAPreviousStateAndSkipAnnouncedOnes`, `newOrChangedQuarterlyMarkReportedOnce`, `newAbsenceOnlyOnKnownDays`, `newTimetableChangeFromTodayOn`, `findNewsBuildsMessages`
    - `test_refresh_reports_news_against_the_cache` → `app/test/app_state_excuses_and_planner_test.dart` (`refreshReportsNewsAgainstTheCache`)
49. `tests/test_notify.py` (17):
    - Core dispatch/prefs/safety cases → `notifier_test.dart` (9): `appIdIsPlainAscii`, `knownEvents`, `defaultsToOn`, `unknownEventThrows`, `disabledEventNeverTouchesTheBackend`, `dispatchesToTheBackend`, `backendFailureFallsBackToStdout`, `noBackendPrintsAndReturnsFalse`, `neverRaisesFromBackend`
    - Desktop OS script/command cases (`test_ps_single_quote_escapes_apostrophe`, `test_cdata_guards_closing_sequence`, `test_toast_script_*`, `test_send_windows_*`, `test_send_linux_*`, `test_send_macos_*`) → **Deferred (phase 7 — desktop notification backends)**
50. `tests/test_open_url.py` (5) → `app/test/open_url_test.dart` (4 tests: empty URL, launcher result, falls back to the platform default when the launcher throws or says false, the fallback seam); the two Flet-coroutine cases are under *Dropped*
51. `tests/test_order_latch.py` (7 [4 functions]) → `app/test/order_latch_test.dart` (4 tests, same names): `emptyPayloadReleasesLatch`, `demoNoCredentialsReleasesLatch`, `nothingPendingReleasesLatch`, `excuseKindToWebType`
52. `tests/test_packaging_privacy.py` (4) → `app/test/packaging_privacy_test.dart` (desktop Inno/spec checks **Deferred phase 7**)
53. `tests/test_plan_picker.py` (12) → `app/test/plan_picker_test.dart` (12 tests, every Python case has a same-named Dart test; checked by name)
54. `tests/test_plan_reserve.py` (5) → `planner_test.dart` (`reserveValidation`) + `app/test/planner_reserve_test.dart`: `reserve lowers plan limit, not school limit`, `default example 25 minus 10 is 15`, `zero reserve keeps old behavior`, `handbuilt states fall back to school values`, `reserve validation`
55. `tests/test_planned_skips.py` (17):
    - 11 pure cases → `planned_skips_test.dart`: `keeps period zero`, `entry covers follows the planner rule`, `whole days in a row merge across a weekend`, `a gap day splits the range`, `range may start late and end early`, `scattered lessons become separate entries`, `free periods do not split a run`, `a partial day does not join the next one`, `ranges are capped at 31 days`, `entries keep the template and lunch choice`
    - 6 `AppState` persist/rollback cases (`test_plan_custom_skip_reports_persist_failure`, `test_plan_skip_reports_invalid_range`, `test_unplan_entry_reports_stale`, `test_plan_custom_skip_rolls_back_on_persist_failure`, `test_unplan_entry_rolls_back_on_persist_failure`, `test_plan_entries_saves_all_at_once`, `test_plan_entries_rolls_back_on_persist_failure`) → `app/test/app_state_excuses_and_planner_test.dart` (`planEntriesSavesAllAtOnce`, `planEntriesRollsBackOnPersistFailure`, `planSkipReportsInvalidRange`, `unplanEntryRollsBackOnPersistFailure`) + `app/test/planner_view_test.dart` (`controller plan/unplan with failing persist rolls back`)
56. `tests/test_planner_dialog.py` (6) → `app/test/planner_dialog_test.dart` (6 tests, same names) + `app/test/planner_view_test.dart` (`plan dialog confirm plans the day`, `plan dialog cancel closes without planning`)
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
    - `test_register_jobs_seeds_from_fresh_cache`, `test_register_jobs_empty_cache_refreshes_on_start` → `app/test/register_jobs_test.dart` (with `test_wizard_setup.py::test_scheduler_skips_refresh_while_setup_pending` and one result-hook case). `test_tray_startup_seed` → *Dropped* (one process).
61. `tests/test_scheduler_retry.py` (7):
    - 2 core `PeriodicRunner` cases → `scheduler_test.dart`: `intervalProviderIsPolled`, `jobFailedCountsAsFailureButReported`
    - 4 window-job cases → `app/test/scheduler_retry_test.dart` (`AppState.scheduledRefreshJob`): `windowJobRaisesWhenRefreshFailed`, `windowJobIgnoresCancelledRunInAnyLanguage`, `windowJobStopsWaitingOnShutdown`, `windowJobGivesUpOnAHungRefresh`
    - `test_tray_interval_follows_config_file` → **Deferred (phase 7 — one-process loop reads the interval from the live `AppState`, not a separate tray process's config file; decide at review)**
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
66. `tests/test_settings_quiet_save.py` (6) → `app/test/settings_quietsave_test.dart` (`SettingsController` cases, autosave field, template editor, `same`) + `app/test/app_state_error_and_quiet_test.dart` (`saveQuietPersistsWithoutRender` against `AppState.saveQuiet`); `test_save_quiet_does_not_mute_other_threads` is under *Dropped*; the extra test `save quiet reports failure` is kept under its own name
67. `tests/test_settings_refresh_interactive.py` (4 [3 functions]) → `app/test/settings_refresh_interactive_test.dart` (4 tests, same names)
68. `tests/test_settings_sections.py` (16 [13 functions]) → `app/test/settings_sections_test.dart` (15 cases covering the 13 functions)
69. `tests/test_shutdown.py` (23) → `app/test/console_log_test.dart` (`TestEnsureStdio`: `windowedWarningsLandInConsoleLog` + 4 on append, rotation, failure, the windowed gate) and `app/test/tray_close_test.dart` (`installerShutsDownAppBeforeInstall`); the rest under *Dropped*
70. `tests/test_single_instance.py` (22) → `app/test/single_instance_test.dart` (16: `TestSingleInstance` 8, `TestEnsureSinglePrimary` 4, `TestPerUserIsolation` 4) + `single_instance_identity_test.dart` (5, C-S1); the other 6 under *Dropped*
71. `tests/test_stable_change_signals.py` (39):
    - Core extractor/common/schedule/baseline cases → `common_test.dart` (`removedRowParsesToCancelledLesson`, `emptyRemovedRowStillDropped`, `atomRowWithoutTeacherStillDropped`, `roomMoveKeepsChangeinfoAsNote`, `classEventStandsInForSubject`), `timetable_test.dart` (`extractKeepsRemovedRows`), `extractors_test.dart` (`readsBadgesAndDays`, `neverRaises`), `schedule_test.dart` + `parity_schedule_test.dart` (all 30 schedule/feed/baseline cases in `tools/parity/dump.py` `dump_schedule`)
    - UI list/grid view cases (`test_list_view_orders_cancelled_row_into_its_period`, `test_grid_cell_shows_taught_lesson_of_swapped_slot`, `test_stable_complete_reads_cache_source`) → **Deferred (phase 5/6 — timetable UI view)**
72. `tests/test_status_notification.py` (51):
    - 39 core `TestItems`, `TestLunchtime`, `TestLunch`, `TestNextLesson`, `TestOtherLines`, `TestNotifier` cases → `status_notification_test.dart` (39 1:1 camelCase cases)
    - `TestAndroidBridge` (6) and `TestPhoneWiring` (4) → `app/test/android_phone_background_test.dart`; `TestSettings` (2) → `app/test/background_settings_test.dart` (+ the Store startup card)
73. `tests/test_store_package.py` (18) → `app/test/store_package_test.dart` (13: detection 4, data dir 4, update gate 3, autostart gate 2); `TestMsixVersion` (4) and `test_store_submit_loads` test Python tools that still pack and publish the MSIX and stay in the Python suite until phase 10
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
    - `test_submit_excuse_dry_run_leaves_pending`, `test_submit_day_excuse_dry_run_leaves_pending` → `app/test/dry_run_send_test.dart`: `submitExcuseDryRunLeavesPending`, `submitDayExcuseDryRunLeavesPending`
80. `tests/test_timetable_week_nav.py` (4) → `app/test/phase6_features_test.dart` (`week switch emits once and clears stable view`, `week switch noop emits nothing`) + `app/test/timetable_live_test.dart` (`timetableControllerFor maps AppState and delegates week/view toggles`)
81. `tests/test_timetable_week_switch.py` (3) → `app/test/timetable_week_switch_test.dart` (3 tests, same names)
82. `tests/test_tls_bundle.py` (7) → **Dropped (frozen CA bundle `strakalari/core/tls.py` does not exist in Flutter; Dart uses OS trust store per PLAN §3.2)**
83. `tests/test_tray_language.py` (1) → `app/test/entry_and_tray_language_test.dart` `trayUsesConfiguredLanguage`
84. `tests/test_tray_ui_command.py` (4) → `test_tray_refresh_preserves_baseline_and_strava` as `refresh_test.dart` `trayRefreshPreservesBaselineAndStrava` (the tray's refresh is the window's pipeline); the other 3 under *Dropped*
85. `tests/test_tutorial.py` (36 [28 functions]):
    - `test_config_validation_rejects_bad_progress` → `config_test.dart`: `validateCatchesBadModeAndThresholds`
    - All 28 functions ported in `app/test/tutorial_test.dart` (28 green, covering gating, progression, resets, anchors, inline/floating bubble rendering, and marks walkthrough)
86. `tests/test_ui_state.py` (13):
    - 5 activity/status cases → `app/test/activity_state_test.dart`: `status kind transitions`, `manual sends show as working`, `last run label`, `next run label`, `log ring buffer caps`
    - 2 setup cases → `app/test/wizard_settings_test.dart`: `needs setup false with strava only`, `needs setup fresh`
    - Remaining 6 `AppState` cases (`test_set_timetable_view_validation`, `test_go_sets_pending_route`, `test_cancel_lunch_order`, `test_start_refresh_rejects_bad_scope_gracefully`, `test_state_save_reports_failure`, `test_subject_states_empty_without_timetable`) → `app/test/app_state_excuses_and_planner_test.dart` (`setTimetableViewValidation`, `goSetsPendingRoute`, `startRefreshRejectsBadScopeGracefully`, `stateSaveReportsFailure`, `subjectStatesEmptyWithoutTimetable`, `needsSetupFalseWithStravaOnly`, `needsSetupTrueWithNothing`)
87. `tests/test_ui_views.py` (28):
    - `TestNamedTemplates.test_core_picks_text_of_named_template`, `test_timetable_period_of_zero` → `helpers_test.dart` / `schedule_test.dart` (`periodOfZero`)
    - `TestPlannerSignature.test_signature_not_duplicated`, `TestNamedTemplates.test_helpers_accept_both_shapes`, `TestNamedTemplates.test_options_carry_names_and_skip_blank` → `app/test/planner_reserve_test.dart`
    - `test_all_views_build_headless` → `app/test/widget_test.dart` (`Router builds every main screen without throwing`)
    - `test_settings_nav_groups_cover_every_section` → `app/test/settings_sections_test.dart` (`nav groups cover every section`)
    - `test_lunch_meal_name_split`, `test_lunch_menu_hides_past_days_until_asked` → `app/test/lunches_filter_test.dart` (`split meal`) / `app/test/lunches_view_test.dart` (`menu hides past days until asked`)
    - `test_activity_groups_and_translates_automation_history`, `test_activity_time_helpers`, `test_activity_log_counts_a_traceback_as_one_error` → `app/test/activity_view_test.dart`
    - `test_table_view_structure`, `test_timetable_list_view_builds`, `test_timetable_stable_view_builds`, `test_grid_subject_uses_short_name_only_when_needed`, `test_focus_period_marks_current_then_next_lesson`, `test_lesson_look_encodes_state_in_the_cell`, `test_today_picks_text_not_name`, `test_day_name_follows_app_language`, `test_lessons_text_czech_plurals`, `test_activity_stacks_columns_in_narrow_windows` → `app/test/ui_views_test.dart` (same names)
    - the Flet container-reuse and stale-reply cases → *Dropped* (see the list above)
88. `tests/test_unconfirmed_excuses.py` (16):
    - 5 `TestHelpers` cases → `excuse_history_test.dart`: `sidecarSitsNextToHistory`, `overlapBlocksEvenAPartialResend`, `wholeDayBlocksItsLessons`, `resolve`, `submitBeforeTheOutboxRangeStaysOpen`
    - 9 `TestSendPath` + `TestOutboxSettles` cases → `automation_test.dart`: `uncertainSubmitIsRecordedNotFailed`, `unconfirmedBlocksTheNextSend`, `certainFailureIsRetryable`, `sidecarWriteFailureFallsBackToHistory`, `autoCountsANewUnconfirmedAsAFailure`, `foundInOutboxIsConfirmed`, `absentFromOutboxAfterGraceIsReleased`, `freshSubmitIsKept`, `failedReadSettlesNothing`
    - 2 `TestRefreshGate` cases → `refresh_test.dart`: `noAutoExcuseWithoutAnOutboxRead`, `autoExcuseRunsAfterAnOutboxRead`
89. `tests/test_update.py` (46):
    - 40 core cases → `update_test.dart` (40 1:1 camelCase cases)
    - `TestConfigChannel.test_validation` → `config_test.dart`: `validateCatchesBadModeAndThresholds`
    - 5 `TestStrings` / `TestChannelState` (`flet_ui` banner/diagnostics/config channel state) → `app/test/app_state_excuses_and_planner_test.dart` (`dismissUpdateAndSetUpdateChannel`)
90. `tests/test_version_sync.py` (3) → `app/test/version_sync_test.dart` (2): `pubspecMatchesPackage` (build-name = `__version__`, build-number = `build_number(__version__)`), `installerDefaultMatchesPackage`; `test_pep440_mapping` → *Dropped*.
91. `tests/test_wake_ui.py` (2) → *Dropped*
92. `tests/test_wakeup_and_widget.py` (44 [42 functions]):
    - 21 core `TestWakeupAlarm`, `TestWidgetPayload`, `TestSyncAndroid` functions → `wakeup_test.dart` (21 1:1 camelCase cases)
    - 20 UI functions (`TestTimetableViews.*`, `TestCollapsibleDays.*`, `TestWakeupUI.*`) → ported at Checkpoint B (`wakeup_ui_test.dart`, `wakeup_settings_card_test.dart`); `test_extension_wheel_ships_widget_and_alarm` → the app ships the classes itself: `packaging_privacy_test.dart` (manifest receivers and widget) and `android_phone_background_test.dart` `theAppShipsTheReceiver`
93. `tests/test_wizard_setup.py` (34 [30 functions]):
    - 3 setup-detection cases → `app/test/wizard_settings_test.dart`: `needs setup fresh`, `needs setup false with bakalari`, `needs setup false with strava only`
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

- Flet-only UI tests (Checkpoint B, BR-M8), real Python names:
  - `tests/test_error_report.py::test_copy_text_does_not_mount_clipboard_into_overlay` — guards against mounting a Flet `Clipboard` service into `page.overlay`; Flutter copies through `Clipboard.setData`, there is no overlay.
  - `tests/test_settings_quiet_save.py::test_save_quiet_does_not_mute_other_threads` — protects against a quiet save muting an emit from another thread; a Dart isolate has one thread, so no emit can land inside a synchronous quiet save.
  - `tests/test_mobile.py::test_refresh_ticks_repaint_only_the_topbar` — counts Flet repaints of one control; a Flutter rebuild has no such notion. The behaviour it protects (a progress tick must not rebuild the whole page) is covered by `workerTickEmitsProgressNotOnChanged` in `app_state_excuses_and_planner_test.dart`.
  - `tests/test_open_url.py::test_click_handlers_are_coroutine_functions`, `::test_helper_itself_is_coroutine` — protect against a Flet handler that forgot `await`; Dart futures need no such handler shape.
  - `tests/test_ui_views.py` Flet container reuse and stale-reply cases (lines 131, 147, 162, 288, 319) — Flet control identity and RPC replies; replaced by `scroll_keeps_offset_test.dart`, which checks the behaviour they protect (a scrolled screen keeps its offset when the state changes).

- Checkpoint C round 1, C-M6 (subjects that do not exist in the one-process Flutter app):
  - `tests/test_wake_ui.py` (2) — wakes Flet's asyncio loop after an off-loop update; Flutter has no cross-thread send queue (Dart isolates post to their own event loop).
  - `tests/test_entry_routing.py::test_import_has_no_side_effect`, `::test_package_entry_shares_main`, `::test_package_root_exports_legacy_names` — Python module import side effects and package exports; a Dart import runs nothing and there is no `strakalari` Python package.
  - `tests/test_single_instance.py` `TestShowWindow` (2: Flet page window restore, `STRAKALARI_TRAY_CHILD`), `TestTrayWiring` (3: the tray parent spawning and forwarding to its Flet child), `test_our_flet_view_attribution` (the Flet view orphan sweep) — no Flet view, no second process. Showing the window is `DesktopTrayController.showWindow` (window_manager).
  - `tests/test_minimize_to_tray.py` `TestIsCloseEvent` (3: Flet window event shapes), `test_env_opt_out_quits` and `test_tray_child_gets_no_tray_env` (`STRAKALARI_NO_TRAY`, set by the tray parent for its child), `test_close_hides_and_quit_destroys` (pystray menu callbacks on a Flet page; the window_manager calls cannot run in a test, the decision is `settingIsReadAtEveryClose`).
  - `tests/test_shutdown.py` `TestInvokeWindow` (4: Flet sync/async window methods), `TestTerminateProcessTree` (4: reaping the Flet child; `terminateProcessTree` has no caller in the one-process app), `TestNoSameImageSweep` (2), `TestKillOrphanedFletViews` (5), `TestTrayQuit` (3: tray parent quitting its child), and `TestEnsureStdio` `test_none_streams_point_at_devnull`, `test_broken_stream_replaced`, `test_healthy_streams_kept` (Python stream objects; Dart's `print` cannot be missing or broken — the console.log redirect is tested instead).
  - `tests/test_macos_tray_host.py` except `TestQuitSignal` (13: the macOS tray process hosting the Flet window process; one process here, the window hides to the tray on macOS: `macosHasNoEmbeddedTray`).
  - `tests/test_tray_ui_command.py` `test_source_uses_module`, `test_frozen_runs_bare_exe`, `TestTrayQuit::test_quit_terminates_ui_process` — the command the tray used to start its Flet child.
  - `tests/test_macos_data_dir.py::test_source_run_uses_repo_root` — a Python source run resolves the repo root; a Flutter run has no source mode (the data dir follows the executable like an installed build, or `STRAKALARI_DATA_DIR`).
  - `tests/test_mobile.py` `TestMakeMobile::test_flet_pin_matches_desktop`, `::test_extension_wheel`, `::test_pyc_shim_*` — the Flet build, its extension wheel and `.pyc` path scrubbing; the Flutter build is `tool/build_android.dart` (tested in `android_build_test.dart`).
- `tests/test_scheduler.py::test_tray_startup_seed` — `TrayApp._startup_seed` is the tray process's own seed; Flutter has one process, the tray uses the window's runner, seeded by `registerJobs` (covered by `registerJobsSeedsFromFreshCache`).
- `tests/test_version_sync.py::test_pep440_mapping` — the PEP 440 spelling exists only for `pyproject.toml`; no Flutter file is written in it (the build number has its own test).

## Deviations from Python (each needs reviewer sign-off)

- Checkpoint C round 1 (2026-11-12):
  - The phone's headless wake (new in Flutter, PLAN §3.4) builds the UI's `AppState` and runs one due tick of the same runner (`registerJobs`); its run record lives only in that isolate (Python had no screenless runs at all).
  - `KeepAwake` wraps the whole refresh job, gates included (Python takes it after the gates; the gates return at once).
  - A living UI that takes a hand-off holds a 1-minute wakelock for 15 s so its runner's next 5 s tick can start the job (Python: the alarm just woke the CPU for the running scheduler).
  - `checkIntervalMinutes`: a string Python's `float()` rejects falls back to 60 instead of raising.
  - The Android launcher icon resources are copied from the last Flet phone build's output (`build/mobile/.../res`: the five `ic_launcher.png`, the adaptive icon, its foreground PNGs, `ic_launcher_background` #ffffff); the splash images were not copied.
  - `WinVaultKeyring.deletePassword` returns false where keyring raises `PasswordDeleteError`; `forgetKey` treats both as "nothing left behind".
  - Owner's decisions (2026-11-12): no "open the app once" notification after a reboot or an update (`BootReceiver`; the headless entry restarts the refresh, also on the first update from the Flet app via the `backgroundMain` fallback); release phone builds come from a neutral folder (`tool/build_android.dart`, default `C:\strakalari-build` / `/tmp/strakalari-build`).
  - `console.log`: only the Windows release build redirects (Python's windowed build was the PyInstaller Windows build without stdio); uncaught errors are written as `Unhandled error: <error>` + the Dart stack.
  - `PeriodicRunner.tick()` is the timer's body as a method (Python's `_loop` body), so tests can drive it.
  - Test seams added in core (`dataDirPlatformOverride`, `installDirOverride`, `carryKeyHook`, `macosDataDirCache`, `clearDataDirCaches`) and app (`autostart*Override`, `PhoneBackground(onAndroid:, startNotifier:)`, `storePackageProbe(release:, identity:)`), like Python's monkeypatching.

- Test seams in production code (BR-N1, B-S2): `ConfigManager.saveOverride` (now `@visibleForTesting`, core depends on `package:meta`), `AppState.geminiTransport` (the AI key test; Python tests monkeypatch `gemini.test_api_key`), `AppState.createApp`, `excuseTasksOverride`, `submitDayExcuseOverride`, `wakeupAvailableOverride`.
- ARB files (B-S3): `app/lib/l10n/app_cs.arb` / `app_en.arb` are generated and kept equal to the `Strings` tables by `strings_table_parity_test.dart`; the app reads `Strings` (background code has no `BuildContext`), so there is no `l10n.yaml` / `gen-l10n` wiring (PLAN §3.2 says ARB + gen-l10n).
- `AppTokens` is a `typedef` of `Tokens` (BR-S3): one token table.
- `openUrl` falls back to the platform default (`rundll32` / `open` / `xdg-open`), like Python's `webbrowser.open`; Android has no fallback (returns false).
- `Strings.format` supports `{name:g}` only; any other format spec throws.
- The wizard card width follows the `ResponsiveRow` columns of `wizard.py` (9/12 from 768 px, 7/12 from 992, 6/12 from 1200, 5/12 from 1400); not yet visually compared (BR-M7).

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

- (Answered 2026-11-13: the owner allowed the phone test, done in part, see Checkpoint notes.) **Was:** Phone test (C-M7, 2026-11-12), for the owner: the review asks to install the Flutter `.test` build *over* the Flet `.test` build, so the saved login is checked across the update. That means: uninstall the Flutter `.test` app now on the Pixel (it only holds demo data), build and install the Flet `.test` app, set it up on the demo server in dry run, then install the Flutter `.test` build over it. OK to do that? The real Play Store app is never touched.
- (Answered 2026-11-12 by the owner: release phone builds come from a neutral folder — done, `tool/build_android.dart`; the APK built that way passes Python's `check_package`, same release key, versionCode 10099.)
- (Answered 2026-11-13 in `reviews/checkpoint-C.md` CR-S1; fixed in `c474019`.) **Was:** `packaging_privacy_test.dart` scans an APK's raw bytes, so on a release APK it also flags the file *names* `secret.key` and `already_excused_lessons.json` that the compiled code mentions; Python's `check_package` reads the APK's file list (ported in `tool/android_build.dart`, which the release build runs). Should the Dart test use that check instead? I did not change the test.
- (Answered 2026-11-12 by the owner, C-N3: the reboot notice is not needed — removed.)
- **Open (found on the phone 2026-11-13):** the phone's Settings → Background hint (`run_in_background_hint`, ported from Python's strings) still says "after a reboot or an app update, open it once". Since the reboot notice is gone and the refresh restarts by itself, should the text drop that sentence (cs + en)? Not changed.
- **Python behaviour that looks wrong (found on the phone 2026-11-13, ported as is, not fixed):** the Flet app could not wrap the password key on the Pixel 7 Pro: `Warning: Android Keystore unavailable (TypeError: Invalid instance of 'javax/crypto/SecretKey' passed for a 'java/security/cert/Certificate'); keeping secret.key.` (pyjnius picks the wrong `KeyStore` overload in `core/android.py`). So Flet users keep a plain `secret.key`; the Flutter update moves it into the Keystore (seen on the phone, below).
- (Answered 2026-11-13: the owner let me place the `.test` widget; checked and removed again, see Checkpoint notes.)
- (Decided 2026-11-13 by the owner: the Windows Sandbox over-install tests (keyring-held key, MSIX) wait until the whole migration is done; the phone is what matters now. For the reviewer: C-M7's desktop part is therefore open on purpose, not forgotten.)
- **Open (phone test 2026-11-13):** after an update Android revokes the exact-alarm permission, so refreshes and the wake-up alarm become inexact until the user taps *Povolit přesné budíky*. The app warns about it on the Budík card, like Python. Nothing to change unless you want a hint elsewhere.
- **Note for the Python build (not ours to fix):** a Flet APK built on this PC fails `make_mobile.py check_package` (machine paths in `libapp.so` and `assets/app.zip!pyproject.toml`); releases are built on CI, so this only affects local Flet builds.

- Phase 8 (2026-11-12): the APK build failed until core library desugaring was enabled (`flutter_local_notifications` requires it). The owner agreed to wipe the old Flet `.test` app; the Flutter `.test` debug build is installed on the Pixel 7 Pro with demo data (local demo server over `adb reverse`, dry run, Strava off).
- Desktop toasts (2026-11-12): `flutter_local_notifications` crashed the Windows AOT build (gen_snapshot "Class with illegal cid" in its Windows FFI code, also in 4.0.1) once start-up used it. Replaced by a port of Python's own senders (PowerShell WinRT toast / osascript / notify-send) in core `desktop_notify.dart` with the 13 OS-backend cases of test_notify.py; the plugin and the Android desugaring it needed are gone. Not ported: Python's `plyer` fallback (stdout stays the last resort). Unverified: whether PowerShell flashes a console window from the Flutter app.
- Phone (2026-11-12): the wired build starts, shows the demo data, refreshes against the demo server in dry run (only reads, no excuse sent), starts background running and arms the next wake-up; the post-update wake-up is handed to the running app. Not yet checked: notifications, widget, wake-up alarm, reboot.
- Start-up wiring was missing (found on the phone, 2026-11-12): `main.dart` never called the phase 7/8 platform code. The phone hung on the splash (no data dir → `AppState` failed → the error card re-threw forever); on Windows there was no tray, single instance, OS key store, toasts or automatic refresh. Now wired in `app/lib/platform/startup.dart` (port of `main.py`, `run()`, `run_mobile()` and the platform half of `main(page)`). Please review it as new code.
- Android key race (Flutter-only): the UI and a headless wake-up are two isolates in one process and each created its own password key (the second write won). Now only the first creates `secret.key.wrapped`, the other adopts it (exclusive create). Seen fixed on the phone.
- One-process deviations to sign off: the tray icon is always shown (Python's in-window tray appeared on the first hide) and its menu has Pause like the `--minimized` tray; `test_tray_interval_follows_config_file` has no direct twin.

- Phase 7: the MSIX package probably needs the VC++ runtime too (the Inno installer now ships it app-local; `tools/make_msix.py --app-dir` stages only the Release folder). Untested.
- Phase 7: the over-install test seeded the key as `secret.key`; reading a Python-keyring entry from Credential Manager after the upgrade is still untested in Sandbox.

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
- **B-S5 (decided by the owner, 2026-11-11):** the error dialog's *Share* button (`share_plus`) stays as an intended phone feature (PLAN §3.3 "Share log on the phone"). It is listed under Deviations; no change was needed.
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
  - **B-M6** (`bea1935`): delete duplicated feature business logic in `app/lib/features/` (`common/schedule_logic.dart`, `common/lesson_model.dart`, `marks/grades_logic.dart`, `lunches/lunch_filter.dart`), re-point today, timetable, marks, and lunches controllers and views directly to `strakalari_core` and `AppState`, add `MarkRow.text` in `strakalari_core`, add `app/lib/features/lunches/lunches_format.dart` for Strava display parsing, remove obsolete `convertStableBaseline`, and update `lunches_filter_test.dart` to test canonical `core.prefsBanKeywords`, `core.isFoodBanned`, and `AppState.applyFoodFilter`.
  - **B-M7**: port ~150 deferred UI test cases into `app/test/` across 13 suites (total at that time 405 app tests; see the rework log for the later counts):
    - `excuse_day_scope_test.dart`: `test_day_card_switch_sends_lessons_separately` (8/8)
    - `early_leave_test.dart`: full port of `test_early_leave.py` (`TestSoonDetection`, `TestSoonStatus`, `TestSoonTemplates`) (13/13)
    - `timetable_week_switch_test.dart`: full port of `test_timetable_week_switch.py` (3/3)
    - `stable_change_signals_test.dart`: UI cases from `test_stable_change_signals.py` (3/3)
    - `open_url_test.dart`: `test_open_url.py` runtime cases, including the fallback to the platform default (rework round 3)
    - `settings_refresh_interactive_test.dart`: full port of `test_settings_refresh_interactive.py` (4/4)
    - `marks_view_test.dart`: full port of `test_marks_view.py` (15/15)
    - `planner_dialog_test.dart`: full port of `test_planner_dialog.py` (6/6)
    - `plan_picker_test.dart`: full port of `test_plan_picker.py` (12/12)
    - `wakeup_ui_test.dart`: the timetable-view and collapsible-day cases of `test_wakeup_and_widget.py` plus 5 `TestWakeupUI` basics; the other `TestWakeupUI` cases are in `wakeup_settings_card_test.dart` (rework round 3)
    - `mobile_narrow_shell_test.dart`: `TestNarrowShell` from `test_mobile.py` (10 cases; `test_every_screen_builds` now runs at 390x844 and checks `lastError`)
    - `ui_views_test.dart`: full port of remaining `test_ui_views.py` cases (19/19)
    - `wizard_setup_full_test.dart`: the `test_wizard_setup.py` cases (the AI connection test is in `app_state_refresh_test.dart`; `test_scheduler_skips_refresh_while_setup_pending` is Deferred to phase 7)
    - Fixed view and controller logic for parity: normalized marks bands in `MarksLogic.setMarksBands`, used canonical `core.entriesForSelection` in planner custom dialog, exposed `expandedDays` reactive state in `LunchesController`, added `PopScope` hierarchy in `Scaffold`, and made wizard nav buttons responsive via `LayoutBuilder`.
    - The dropped Flet-only tests are listed under *Dropped* with their real names.
  - **B-M8**: print Python-equivalent warning messages in `AppState.save` on failure ("Warning: could not save config: {exc}"), invalid update ("Warning: ignoring invalid config update {key!r}: {err}" formatted with `core.pyRepr`), and listener failure ("Warning: config listener failed: {exc}"), verified with `app/test/app_state_save_warnings_test.dart`.
  - **B-M9**: settings and app preferences parity: implemented `refreshTokens()` in `AppState` (invoked at end of constructor and in `save()`), reading forced theme `STRAKALARI_THEME` (`'light'` / `'dark'`), updating `tok` (`Tokens`) and `appTokens` (`AppTokens`), applying `compact_density` (`pad: 10, gap: 8`), and initializing `core.setLanguage` and `Strings.lang` at startup without requiring a save. Added `copyWith` on `Tokens` and `AppTokens`, updated `main.dart`, `scaffold.dart`, `router.dart`, `tutorial_ui.dart`, and `error_boundary.dart` to use active `appState.tok` / `appTokens`, verified with `app/test/app_state_theme_and_prefs_test.dart` (10/10 passed).
  - **B-M10**: More page and Android Back navigation parity: implemented `openMoreRoute` (routing `alarm` to Settings with `settingsSection = 'alarm'` and `settingsOpen = true`, and `settings` with `settingsOpen = false`), wired `isAndroid: mobilePlatform() == 'android'` into `MorePage`, restyled `MorePage` (bold `fsTitle` heading, `tok.card` tiles with accent leading icons, `fsSection` titles, faint trailing chevrons, and `tok.gap / 2 + 2` spacing), implemented phone Back hierarchy via `subpageOpen`, `closeSubpage`, and `wrapPop` with `PopScope` on phone layouts only (closing open settings sections, selected marks subjects, and open lunch tools before stepping up from More screens to More, and any screen to Today), and verified with `app/test/more_page_test.dart` and `app/test/mobile_narrow_shell_test.dart` (425 app tests passing).
- 2026-11-10 · Checkpoint B re-review: **FAIL** (all 5 blockers fixed; open: 4 original must-fix B-M11 … B-M14 + 8 new must-fix BR-M1 … BR-M8, 11 should-fix) — [docs/flutter-migration/reviews/checkpoint-B.md](docs/flutter-migration/reviews/checkpoint-B.md#re-review-2026-11-10)
- 2026-11-11 · Checkpoint B re-review 2: **FAIL** (BR-M1, BR-M6 and BR-M8 row 1 fixed; BR-M2 reopened; open: 10 must-fix, 12 should-fix incl. new BR2-S1; note BR2-N1 for Checkpoint C) — [docs/flutter-migration/reviews/checkpoint-B.md](docs/flutter-migration/reviews/checkpoint-B.md#re-review-2-2026-11-11)
- 2026-11-11 · Checkpoint B rework, round 3 (after re-review 2). Fixed, one commit each:
  - **BR-M2** (`2ed116f`): the mode-picker revision lives in `_LiveSettingsViewState`, not in the throw-away `SettingsController`; 4 tests against `LiveSettingsView` (both pickers, cancel and dry run) fail without the fix.
  - **BR-M8** (rows 2–4, 6, 7, 9–11, 13 by `a0e3834`, `5e0cec9`, `27dd19f`, `f34464b`): `TestHistoryCoverage` (3), the three planned-skip persistence cases, `test_ai_connection_test_path` (new seam `AppState.geminiTransport`), the `open_url` fallback (the inverted test is replaced by the real one), `test_phone_timetable_grid_scrolls_sideways` (also `phoneCellWidth` now truncates like Python's `int()`), `test_every_screen_builds` at 390x844 with `lastError`, `TestI18nKeys` + dead-key audit, a scroll-offset test, and the wake-up card. Row 5 (`test_scheduler_skips_refresh_while_setup_pending`) is **Deferred (phase 7)**: the window scheduler (`app.py:_register_jobs`) is not ported yet (BR-N2); Checkpoint C checks it. Rows 8, 12, 13's Flet-only cases are under *Dropped*.
  - **Wake-up card** (part of BR-M8 row 9): the Settings alarm card was a stub; it now has everything `_wakeup` has (hint, notification/exact-alarm warnings with their buttons, next alarm, skip, open Clock, weekly note, restore buttons) in `settings/wakeup_card.dart`, wired to the platform channel in `settings_live.dart` (permission flags are read once when the screen opens). The minutes field used `clamp(5, 240)`; Python's `clamp_wakeup_minutes` is 1–720, now used. Unverified on a phone.
  - **BR-M3** (`2652330`): `Strings.format` handles `{name:g}`; test formats every key in both languages. **BR-M4** (`950c3e1`): target dropdown computes `already`/`maximum` from the term; 2 widget tests. **BR-M5** (`d8ab9ad`): both plan dialogs use `templateLabels`; a test forbids `Šablona` literals under `lib`.
  - **B-M12** (`41efef2`): every `DateTime.now()` in `app/lib` is `clock.now()` (a test guards it; only the single-instance token seed keeps the wall clock). **B-M14** (`e6f2979`): `dialogWidth` is `int(max(240, min(preferred, width - 64)))`; both error dialogs use it (326 px at 390 px).
  - **B-S1, BR-S4** (`4a13fa1`): dialog widths 520/380/440 for the planner custom range, the lesson detail and the signature dialog; the signature and safety dialogs are modal. **B-S2** (`2947ec0`), **B-S3** (`d9743a3`), **B-S6 + BR-S2** (`ade6e4a`), **BR-S1** (`8cbaa0b`), **BR-S3** (`bcf9a43`), **BR-S5 + BR-S6** (`03c0ee4`), **BR2-S1** (`5aecdb0`): see the review and *Deviations*. **B-S5** is a question (below).
  - **B-M11 (part)** (`de91d39`): Activity now has the automation card with the *Pozastavit automatizaci* switch, the two current modes and *Upravit pravidla* (test in `activity_live_test.dart`).
  - **BR-M7** (`tools/parity/capture_screens.dart`, `capture_flet.py`, new `serve_wizard.py`): the Flutter capture now builds what `MyApp` builds (real theme, locale, delegates, no debug banner), writes a demo folder per language **and theme** before `AppState` exists, takes the font folder from `FLUTTER_ROOT`/`~`, and captures the wizard on a fresh folder; the Flet side captures the wizard through `serve_wizard.py` (`demo_data.py serve` skips the wizard, and `tools/demo_data.py` is Python, which stays read-only). Checked on one image (`today-cs-light-1280`: light page, white cards, accent blue, no ribbon). The full 80+68 image sets were NOT re-captured this session. Commands: `cd app; STRAKALARI_PYTHON=<venv python> flutter test ../tools/parity/capture_screens.dart` and `python tools/parity/capture_flet.py` (needs Playwright + Chromium); output in `build/parity-screens/{flutter,flet}/` (not committed).
  - **Not done in round 3 (done in round 4, below):** the rest of B-M11 and a fresh screenshot comparison. B-M13: the stale claims listed in the review are corrected here (header, B-M7 bullets, Dropped, `faa1a77` → `bea1935`); the long test map below still says "Deferred (phase 5/6)" for items 17, 19, 21, 30, 40, 50, 51, 53, 56, 67, 79, 81, 87. Those subjects are ported (files named in the rework entries above and in the Checkpoint B notes), but the map lines themselves were not rewritten.

- 2026-11-11 · Checkpoint B rework, round 4 (visual parity, **B-M11** and **B-M13**). One commit per screen:
  - **Shared look** (`shell/theme.dart`, `widgets/app_widgets.dart`): flat bordered cards, outlined filled inputs with the accent focus border, stadium buttons (filled accent / outlined / text), leading-style switch colours, segmented buttons, divider and rail indicator colours, tap targets shrink-wrapped, `Tokens.toThemeData({fontFamily})` (only the screenshot tool passes a family: the test engine has no platform font). `SectionHeader` is small, upper-case, faint and bold; `HeaderRow` has the date line under the title; `StatCard` is the Flet tile (card colour, accent/status value, one line with a tooltip for the tightest subject); `EmptyState` is the inbox icon + text. `tokensOf(context)` gives a view the running token set.
  - **Today** (`today_view.dart`): the excuse cards use `HeaderRow`/`SectionHeader`/`KindBadge`/`Badge`; dropdown + *Omluvit* + *Ignorovat* on one row (stacked on a phone or in a narrow card), the "Krátká absence" badge next to the date, the *Každou hodinu zvlášť* switch with its tooltip, the status badge in the running-lesson heading. The double gutters are gone on Today, Absences, Marks and Timetable (the shell already pads the content).
  - **Planner** (`planner_view.dart`, `planner_live.dart`): full port of `planner.build`: header with the two buttons, term switcher, stat tiles, warnings with real subject names, the semester grid (Mon–Fri columns, month labels, day labels, legend, hint, tooltips, today outline, the phone calendar with numbered days), recommended plan rows with tag badges and the "hours from the budget" line, the budget bars and legend, planned rows (cost, over/reserve badges, *day passed* badge) and the footer. The view had shown *Unplan* on rows in the past; it now shows the badge like Python (the old test only passed because it ran against today's date; it now fixes the clock and a new test covers the past case).
  - **Lunches** (`lunches_view.dart`): day cards with the day name and status badges, radio rows with allergens, the closed note with the deadline, the low-balance card, the past-days button, the side panel (AI card with model badge, preference field that keeps its own controller, *Získat klíč zdarma*, hints, progress; blacklist card with word rows and its own add field).
  - **Activity** (`activity_view.dart`): update banner, status hero (icon disc, scope picker, refresh/cancel, error details), four stat tiles, run history rows, live log, the right column (automation card, history filter), narrow stacking at 1120 px.
  - **Settings** (`settings_view.dart`): grouped nav with section icons and the active pill, captioned fields (label above, placeholder inside, eye toggle on passwords), card spacing, hint and title texts, switches with the switch on the left.
  - **Tests changed for the new look, not weakened:** section headings are upper-case now (the finders upper-case the expected text); screens that are taller or wider than the 800x600 test surface use a larger surface (the Ahem test font is far wider than the real one); `Chyba` appears twice on the Activity screen exactly as in Python.
  - **B-M13**: the test map lines for items 17, 19, 21, 30, 38, 40, 50, 51, 53, 56, 67, 79 (unchanged, it was already complete), 81 and 87 and `TestNarrowShell` name the real Dart tests. Every Python test in those files has a same-named Dart test (checked by a script that compares the camel-cased names) except the Flet-only ones, which are under *Dropped*.
  - **Screenshots:** `build/parity-screens/{flutter,flet}/` were re-captured (80 and 76 images) and compared by eye on Today, Planner, Lunches, Activity and Settings (1280 and 390, light and dark). Known differences: the Flet captures show an "update available" button and a next-run time that the demo data in the Flutter capture does not produce; Absences, Marks, Timetable, More and the wizard were not compared again in this round; the wake-up card and the wizard card widths are still unchecked.
- 2026-11-12 · Checkpoint B re-review 3: **FAIL** (all re-review 2 findings fixed except B-M11 in part; new: 2 blockers BR3-B1 Planner grid / day ranges off by a day after the clock change, BR3-B2 *Copy log* not redacted; 3 must-fix incl. a red app suite; 4 should-fix) — [docs/flutter-migration/reviews/checkpoint-B.md](docs/flutter-migration/reviews/checkpoint-B.md#re-review-3-2026-11-12)
- 2026-11-12 · Checkpoint B rework, round 5 (after re-review 3). One commit per finding, in the reviewer's order:
  - **BR3-B1**: every calendar-day step in `app/lib` is `core.addDays` / `core.daysBetween` (semester grid wide + phone, the custom-range dialog month, `addDayRange`, the free-day grouping, Today, Timetable, Activity, planner); the app's second `entryDays` is deleted (the core's is used). New `calendar_days_dst_test.dart`: a guard that fails on `Duration(days` / `.inDays` under `app/lib`, `entryDays` and `addDayRange` for 23.10.–30.10.2026 and 26.3.–2.4.2027, the free-day grouping across 28 Mar, the semester grid on 12 Nov 2026 under `withClock` (today in the *Čt* row/column, 13 Nov in *Pá*, wide and phone), the custom dialog's October 2026. The grid and dialog tests fail on the old code.
  - **BR3-B2**: *Copy log* copies `redactedLogTail` (last 200 lines, `core.redactText` with the config, fail closed). Tests: `activityLogCopyRedactsSecrets` (= `test_activity_log_copy_redacts_secrets`), the 200-line cut, and the button itself against a mocked clipboard.
  - **BR3-M1**: `wholeDayExcuseListsLessonsInAFoldedSection` injects the two tasks like Python (`excuseTasksOverride`), pins the clock and checks exactly one tile, collapsed, its title (`Nebo jednotlivě (2 hodiny)`), and the tile itself opened after `setDayExpanded`. To find any other date-dependent test I ran the whole app suite with the clock fixed to 2026-08-20, 2026-12-15 and 2027-03-10 (a temporary hook in `flutter_test_config.dart`, removed again): all green on all three, and the same hook fails the old version of the wake-up test. So no other test depends on today's date.
  - **BR3-M3**: the missing ports are in `app_state_error_and_quiet_test.dart` (`userErrorMarksReportFriendly`, `regularErrorHasNoUserMessage`, `reportIsPersistedRedactedToStderr`, `shellPopsQueuedErrorOnce`, `saveQuietPersistsWithoutRender` against `AppState.saveQuiet`) and `activity_view_test.dart`; the two Flet-only cases are under *Dropped*; test map items 16 and 66 are corrected. **A real bug found by the first port:** `reportError` built the friendly message from `'$exc'`, so it showed `UserError: …` with the type name; Python uses the message only. Fixed (`exc.message`).
  - **BR3-M2**: Absences (percentage `21.4 %` right of a 140 px track via the shared `Meter`, the date line, stat values coloured by the shared `StatCard`, shared `Badge`), Marks (date line, four stat tiles filling the width, two per line on a phone, *Auto* icon on the global toggle only: that is where `marks.py:165` has it, the per-subject toggle has none), Wizard (card at the top, chosen language is a filled primary button, current step dot yellow), Timetable (4 px between cells, header row, rows and the phone day column). Each has a widget test (`absences_view_test.dart`, `marks_live_test.dart`, `wizard_look_test.dart`, `timetable_live_test.dart`).
  - **BR3-S1**: `gFormat` is Python's `format(x, 'g')`; `gformat_test.dart` compares 38 values against a table printed by Python. **BR3-S2**: one half-even helper (core `roundHalfEvenToInt`, now public; the app copy is gone), `tintColor` and the budget shares use it; one weekday-name table (`format.dart`; `app_widgets.dayName` and the planner dialog use it). **BR3-S3**: `capture_flet.py` sets `STRAKALARI_NO_KEYRING` and `DEMO_NO_UPDATE_BANNER`. **BR3-S4**: `save` / `saveQuiet` in `SettingsController` print `Warning: could not save settings: …` on a thrown error (test); the "value is in memory before the save worked" part is the same as Python's `save_quiet` and was left alone.
  - **Screenshots:** both sets re-captured (80 Flutter, 76 Flet) and Absences and Marks (cs dark 1280) compared by eye: they match. The Flet wizard capture caught only the start-up logo (timing in `capture_flet.py`, not a difference in the app), so the wizard changes are checked by `wizard_look_test.dart` against the Python lines, not by a screenshot. Timetable and the phone layouts were not compared by eye this round. (Corrected in re-review 4: 15 of those 76 Flet images were only the start-up logo; see BR4-S2 below.)
  - Checks: core `dart analyze` clean, `dart test` 764 passed / 2 skipped; app `flutter analyze` clean, `flutter test` 498 passed / 1 skipped.
- 2026-11-12 · Checkpoint B re-review 4: **PASS WITH FIXES** (all re-review 3 findings fixed; 0 blockers, 0 must-fix; 4 should-fix BR4-S1 … BR4-S4: card outlines, the Flet capture saving the start-up logo, the Flutter capture's control size at 1280 px, STATUS wording) — [docs/flutter-migration/reviews/checkpoint-B.md](docs/flutter-migration/reviews/checkpoint-B.md#re-review-4-2026-11-12)
- 2026-11-12 · Re-review 4 fixes: **COMPLETE**, made by the reviewer at the owner's request (so the next review, Checkpoint C, must be a fresh session):
  - **BR4-S1** (`021b20b`): the four card helpers (Absences, Marks, Timetable, wizard) keep the 1 px `tok.border` outline of `components.card`; Absences rows are `tok.gap // 2` apart (`+ 2` on a phone) like `absences.py`; `card_outline_test.dart` (4 tests, one a guard over `lib/features`).
  - **BR4-S3** (`a505226`): `capture_screens.dart` renders the 1280 px images with `TargetPlatform.windows` (390 px stay Android); buttons are now the same height as in the Flet desktop capture.
  - **BR4-S2** (`2988b6a`): `capture_flet.py` waits until the page is no longer the start-up logo (up to 120 s, fails loudly) and retries a timed-out screenshot; a full run gave 76 images, none logo-only.
  - **BR4-S4** (this commit): test map item 16 counts (11 + 3 + 11 + 1 = 26), stale words and suite counts (app 502 passed / 1 skipped) corrected.
- 2026-11-12 · Checkpoint B re-review 5: **PASS** (BR4-S1 … BR4-S4 fixed; 0 open findings; notes for Checkpoint C) — [docs/flutter-migration/reviews/checkpoint-B.md](docs/flutter-migration/reviews/checkpoint-B.md#re-review-5-2026-11-12)
- 2026-11-12 · Checkpoint C review: **FAIL** (4 blockers, 8 must-fix, 7 should-fix; phases 7–8 were not finished) — [docs/flutter-migration/reviews/checkpoint-C.md](docs/flutter-migration/reviews/checkpoint-C.md)

- 2026-11-12 · Checkpoint C rework, round 1 (after the review). One commit per finding, blockers first:
  - **C-B1** (`351525d`): the warmed bridge keeps the raw Keystore blob (not the base64 text), so core's unwrap matches and no start throws the key away; a Keystore that failed at warm-up now refuses `wrap` (before, core would have written an empty `secret.key.wrapped` and deleted the plain key). `android_keystore_test.dart`: the four `TestKeystoreKey` cases + Keystore down on a fresh install + two isolates at once, each through warm-up and core `getKey`, checking key and files.
  - **C-B2 + C-S4** (`5ddd024`): `win_credentials.dart` ports `WinVaultKeyring` line by line (compound re-save before a write, `Comment`, read through the compound name, an empty stored user is not ours, delete only where `UserName` matches) behind a `WinCredApi` seam; failures other than `ERROR_NOT_FOUND` are `KeyStoreUnavailable`; `GetLastError` is a leaf call resolved before the Win32 call (a lazy lookup cleared it: the first real run read error 0). `keystore_windows_test.dart` (13): fake credential table + two data folders through core, and one read-only real Credential Manager lookup of a missing name.
  - **C-B4** (`a2f4c46`): `INTERNET` in the main manifest; the manifest test checks it.
  - **C-B3 + C-S7** (`8e251bf`): the headless wake reads `run_in_background` first (off: cancel the wake, nothing runs, nothing is re-armed), then hands off or runs one due tick on the UI's `AppState` (setup / login gates, the worker's notifications, language, run record, `bg_notif_*` fallback); not due (reboot, app update) only arms the due time; a failed run comes back in 5 minutes. `android_background_test.dart` (7).
  - **C-M8** (`24a3aed`): `platform/scheduler_jobs.dart` ports `_register_jobs` on core `PeriodicRunner` for the app and the headless wake; `DesktopBackgroundLoop` is deleted. `register_jobs_test.dart` (4).
  - **C-M3** (`05f0f3d`): channel `keepAwake` / `releaseAwake` (a new partial wakelock `strakalari:refresh` per use, 30 min timeout) around the scheduled refresh.
  - **C-M1** (`e4bc44b`): hand-off is acknowledged at once (`'taken'`); no acknowledgement in 5 s = dead UI, the stale name is removed and the job runs headless; the UI drops its name on `detached`. `android_handoff_test.dart` (4, one with a closed port).
  - **C-M2** (`5a11cac`): `MainActivity` passes itself to the channel (`setActivity`), so the permission prompt has a screen.
  - **C-M5** (`4dd13b2`): `preProdReleaseBuild` fails without the real key (checked: with key OK, without key stops, phonetest still allowed); the env vars work without the properties file.
  - **C-M4** (`f444505`): label `Strakaláři`, `allowBackup="false"`, `enableOnBackInvokedCallback="true"`, the Flet build's launcher icon, `assets/icon.ico` as the exe icon, core `buildNumber` + `bin/build_number.dart` (port of `build_number`), app version `0.1.0+10099`; `icons_test.dart`, `version_sync_test.dart`, `build_number_test.dart`.
  - **C-S1** (`7aff23a`), **C-S2** (`edd87ab`, `mkstemp`), **C-S3** (`0723eb1`, Python's `Warning:` lines on the channel), **C-S6** (`9f4bd37`, flock test on macOS too), **C-S5** (this round: `build-flutter-android` job in `dart.yml`, same secrets/alias/arch as `build.yml`, versionCode from `build_number`, APK attached to the release).
  - **Not done yet:** **C-M7** (phone over-install over the Flet `.test` build, notifications / alarm / widget / reboot on the phone, Sandbox re-test with a keyring-held key, MSIX): the phone part waits for the owner (Questions). C-M6 is done (see below). Nothing of this round ran on the phone or in Sandbox.
  - Checks: core `dart analyze` clean, `dart test` 782 passed / 2 skipped; app `flutter analyze` clean, `flutter test` 564 passed / 1 skipped; Java/Kotlin compile (`:app:compilePhonetestDebugJavaWithJavac`, `…Kotlin`, `processPhonetestDebugResources`).
  - Release APK built locally with the CI job's commands (`build_number 0.1.0` = 10099, `--flavor prod --target-platform android-arm64`): `aapt2 dump badging` shows `io.github.dendlerx.strakalari`, versionCode 10099, versionName 0.1.0, label `Strakaláři`, INTERNET; `apksigner` shows a certificate that is not the debug key's. It fails the privacy checks (see Questions). The APK was not installed anywhere.
  - **After the owner's answers (same day):** `9484561` no reboot notice (C-N3); `6704a98` neutral-folder release build (`tool/build_android.dart` + port of `check_package`, CI uses it; its APK passes Python's `check_package`).
  - **C-M6, ported** (one commit per file or two): autostart (`a8c8ddd`, also fixed: XML escaping, quoting, warning text), entry routing + tray language (`8cfa571`), single instance (`277f0bc`, also: token file 0600 on POSIX), console.log (`dee4904`, **new: was missing**, Python's windowed build wrote all warnings there), tray close + installer (`393cd42`), Store package (`cb3baf8`, **fix: the Store detection was never registered**, so a Store install behaved like a classic one), macOS data dir (`c302f75`, **fix: a copied folder was renamed with a file rename**, so a `school_presets` folder made the macOS move and the Store copy of a classic install fail), quit signal + tray refresh (`32d495e`), Settings → Background overview (`d95b1a2`, **new: the per-line switches and preview were missing**; the Store startup button did nothing and its tray switch was missing), phone wiring (`69cba89`, **fix: the notification counted unfiltered excuse tasks**), data dir + system alarm + paused scheduler (`5ba7d6d`). Everything else of C-M6 is under *Dropped* with its reason.
  - Checks after C-M6: core 801 passed / 2 skipped, app 631 passed / 1 skipped, both analyzers clean.
  - console.log checked in a real `flutter build windows --release` run (throwaway data folder, `STRAKALARI_NO_KEYRING=1`, `--minimized`, stopped after 8 s): the start header and the single-instance warning landed in `console.log`.

- 2026-11-13 · **Phone test (C-M7), part 1** (Pixel 7 Pro `2C221FDH3002NZ`, owner's go-ahead; the real Play Store app was never touched):
  - **Set-up:** the old Flutter `.test` app (demo data) was uninstalled. The Flet `.test` app was built with `tools/make_mobile.py` unchanged through a scratch wrapper that only sets `BUNDLE_ID = "io.github.dendlerx.strakalari.test"` (`--release`, the real key, arm64), installed, and set up through its own wizard against `tools/bakalari_demo_server.py` over `adb reverse tcp:8080 tcp:8080` (URL `http://127.0.0.1:8080`, `demo`/`demo`, Strava off, AI off, custom days, modes left on "confirm"). It refreshed fine and started background running.
  - **Found and fixed:** the Flet APK's versionCode is 12099 (Flet builds one APK per ABI and adds +2000 for arm64), the Flutter APK had 10099 and could not have installed over a GitHub Flet install. `tool/build_android.dart` now builds `--split-per-abi` like Flet (`8cf1260`); the Flutter `.test` APK is 12099 with the same release certificate as the Flet one.
  - **Over-install: PASSED.** `adb install -r` of the Flutter `.test` build over the Flet one kept the data: `MY_PACKAGE_REPLACED` started the headless entry (`Info: headless background run (boot).`), which **moved the Flet app's plain `secret.key` into the Android Keystore** (`Info: password key moved into the Android Keystore.`), saw no refresh due and armed 09:25. The app opened on the Flet-written data with no wizard; a manual refresh logged in with the saved, Flet-encrypted password (`POST /Login` 302 → dashboard on the demo server), status "V pořádku". No warnings in logcat.
  - **Notifications: PASSED.** The permission prompt came up; the event notification ("Data byla aktualizována.") and the ongoing overview (`Další hodina` / `2. Anglický jazyk · 8:55 · III …`, foreground service) were posted. Settings → Background shows the new per-line switches.
  - **Reboot: FOUND A BUG, fixed, NOT re-tested.** With the interval set to 5 min, after `adb reboot` the alarm started the headless run (`Info: headless background run (alarm).`, 08:33, app not opened), but it never reached the server: the headless `AppState` had the no-op job runner, so the refresh was "started" and never ran, and the job would have waited 30 minutes. Fixed in `eaa4dc0` (`AppState.liveSpawn`, shared with the UI; test `theHeadlessRunActuallyRunsItsJobs`). The phone still has the build **without** this fix.
  - **To do next session (exact steps):**
    1. `cd packages/strakalari_core` and `dart run tool/build_android.dart apk --flavor phonetest --stage "C:\strakalari-build-test"` (JAVA_HOME `~/java/17.0.13+11`, ANDROID_HOME `~/Android/sdk`, Flutter 3.44.8 on PATH) → `dist/flutter-android/Strakalari-0.1.0-phonetest-android.apk` (versionCode 12099).
    2. Start `python tools/bakalari_demo_server.py --port 8080 --user demo --password demo`, then `adb -s 2C221FDH3002NZ reverse tcp:8080 tcp:8080`.
    3. `adb -s 2C221FDH3002NZ install -r <apk>` (keeps the data; the interval is already 5 min).
    4. `adb -s 2C221FDH3002NZ reboot`; after boot, `adb reverse` again (it does not survive a reboot); do not open the app.
    5. Within ~5 min logcat (`adb logcat -d | grep " flutter "`) must show `headless background run (alarm)`, then `next background check at …`, and the demo server must log `POST /Login` and the timetable requests.
    6. Then: set the interval back to 60, check the wake-up alarm (Settings → Budík) and the home-screen widget, and note the results here.

- 2026-11-13 · **Phone test (C-M7), part 2** (same phone, same `.test` app, demo server over `adb reverse`, both modes "S potvrzením", Strava off):
  - **Install:** the rebuilt APK (with `eaa4dc0`) installed over the part-1 build with `adb install -r` (versionCode 12099). No headless run followed, because the app was in Android's *stopped* state (`stopped=true` in `dumpsys package`; Android sends no `MY_PACKAGE_REPLACED` / `BOOT_COMPLETED` to a stopped app until it is opened). Opened once before the reboot: it logged `background running on (every 5 min)` and armed the refresh alarm. This is Android's rule, the same for the Flet app.
  - **Reboot: PASSED.** `adb reboot` at 08:42, the app not opened afterwards. At 08:49:58 the alarm started the headless run (`Info: headless background run (alarm).`), which logged in to the demo server (`POST /Login` 302) and fetched the timetable, substitutions, absences, subjects and messages (only reads, no excuse posted), then armed 08:54. The app, opened later, showed the data stamped 08:49:58. The next runs kept coming every 5 min.
  - **Exact alarms:** the update made Android revoke the exact-alarm permission (`AlarmManager: … lost permission to set exact alarms!`), so the refresh alarm is inexact (a window of a few minutes; the run above came at 08:49 for 08:47). The app shows this correctly (below).
  - **Wake-up alarm: CHECKED (armed, not rung).** Settings → Budík, switched on: "Příští budík: Po 16. 11. v 07:00 (Matematika v 08:00)" (60 min before the first lesson of the demo week), `ACTION_WAKEUP_ALARM` armed in `dumpsys alarm` for 16.11. 07:00; the yellow "Přesné budíky nejsou povolené" warning with *Povolit přesné budíky*, which opens Android's *Alarms & reminders* page of the `.test` app (not changed). Switched off again: Android logged `alarm_cancelled`. Not checked: the alarm actually ringing (the next school day is Monday).
  - **Widget: PASSED** (placed with the owner's go-ahead, removed again afterwards). The `.test` "Strakaláři · Timetable" widget (4×3, bound as widget 25 to `io.github.dendlerx.strakalari.test`) showed the demo data written by the background run: "Dnes · Pátek 13. 11.", 5 lessons, the running 2nd lesson (8:55–9:40) outlined, the 5th marked "Změna" (the room change also on Today). › skipped the weekend to "Pondělí 16. 11." (6 lessons, Mathematics at 8:00 marked "Změna", matching the wake-up alarm), ‹ went back to Today, tapping a lesson opened the `.test` app. (The picker lists both apps' widgets under the same name; the first try placed the Play Store app's one, which was removed at once.)
  - **Found and fixed: Back closed the app on every screen.** On the phone, Back on Timetable (or Budík, or any screen but Today) left the app instead of going to Today / More / closing the section like Python's `back_target` / `_subpage_open`. Cause: the `PopScope` sat in the shell, above go_router's inner navigator, and that navigator kept telling Android "nothing to pop" (`setTopOnBackInvokedCallback: null` in logcat). Fixed in `3a057e1`: each page wraps itself in `ShellBackScope` (same steps, now under the inner navigator). New `app/test/android_back_test.dart` (3) presses Back through `handlePopRoute` and checks what Android is told; all 3 fail on the old code. Re-checked on the phone with the rebuilt APK: Timetable → Back → Today; Budík → Back → Settings list → Back → More → Back → Today → Back leaves the app (Python's order).
  - The interval is back at 60 min (`background running on (every 60 min)`, next check 09:56). The real Play Store app was not touched (its own wake-up alarm for 18.11. is still armed).
  - Checks: app `flutter analyze` clean, `flutter test` 637 passed / 1 skipped.

- 2026-11-13 · **Windows Sandbox re-test (C-M7, desktop part): DEFERRED by the owner** ("the phone is key"; the Sandbox test runs once the whole migration is done). Not reviewed as part of Checkpoint C. What was prepared and found, for whoever runs it later:
  - Plan: (1) classic: Python Inno install → seed with Python's own `ConfigManager` + `secret_store` through `keyring` (the key in Credential Manager, no `secret.key`), cache removed so the app logs in on start → run the Python app → wait past a 2-min interval → Flutter installer over it → the Flutter app must log in to the demo server (run inside the Sandbox, network off). (2) Store: the same classic seed → Python MSIX (first start copies the classic data and carries the key) → Flutter MSIX 0.1.1 as an update (same identity, signed in the Sandbox with a throwaway certificate) → the Flutter Store app must log in.
  - Built for it (outside the repo, nothing committed): the Python app with PyInstaller, its installer from `main`'s `installer.iss`, the Flutter installer from the branch's `installer.iss`, and both MSIX packages with `tools/make_msix.py` (`--exe` / `--app-dir`). All four built without errors.
  - **Blocker found:** in today's Windows Sandbox every unsigned program is refused ("An Application Control policy has blocked this file"): the installers and Python, both from the shared folders and after copying them onto the Sandbox's own disk. On the host, Smart App Control is off (`VerifiedAndReputablePolicyState 0`). The 2026-11-12 Sandbox run did not hit this, so something changed in the Sandbox since. Whoever runs the test later has to solve this first (e.g. look at the Sandbox's CodeIntegrity event log for the policy).

- 2026-11-13 · Checkpoint C re-review: **FAIL** (narrow: all 4 blockers, C-M1 … C-M6, C-M8 and C-S1 … C-S7 fixed; open: 2 new must-fix CR-M1 differing `secret.key` deleted on the phone, CR-M2 a headless run over ten minutes is killed and nothing is re-armed; 2 should-fix CR-S1, CR-S2; the Windows Sandbox half of C-M7 stays open by the owner's decision and must pass before Checkpoint D) — [docs/flutter-migration/reviews/checkpoint-C.md](docs/flutter-migration/reviews/checkpoint-C.md#re-review-2026-11-13)
- 2026-11-13 · Checkpoint C rework, round 2 (after re-review). Fixed, one commit each:
  - **CR-M1** (`4ad019b`): in `app/lib/platform/android/android_keystore.dart`, when `secret.key` differs from `secret.key.wrapped`, register `WarmedAndroidKeystore(key, blob)` with the Keystore's unwrapped `key` (not `fileKey`), so core's `_androidLoadOrCreate` enters the differing-file branch and keeps `secret.key` untouched alongside `secret.key.wrapped`. Added `differingPlainKeyIsKeptAlongsideWrappedKeyAcrossStarts` in `app/test/android_keystore_test.dart` (7/7 passed).
  - **CR-M2** (`02646b5`): in `RefreshReceiver.java`, extended `HOLD_MS` from 10 min to 32 min (30 min refresh wait + 60 s update wait + margin), saved `appContext` while running, logged a warning in `giveUp()`, and armed a 5-min retry wake (`AlarmManager.setAndAllowWhileIdle` with `wakeIntent`) on timeout; in `app/lib/platform/android/background.dart`, `runHeadlessTick` now arms a fallback wake (`nextDue(now, interval, now) + 10 s`) before `runner.runAllOnce()` and always re-arms in `finally`. Added `fallbackWakeIsArmedBeforeTheJobStarts` in `app/test/android_background_test.dart` (9/9 passed); `:app:compilePhonetestDebugJavaWithJavac` and `:app:compileProdReleaseJavaWithJavac` succeeded.
  - **CR-S1** (`c474019`): `app/test/packaging_privacy_test.dart` now uses `checkPackage` + `buildPathMarkers` from `packages/strakalari_core/tool/android_build.dart` for the `STRAKALARI_APK` / `STRAKALARI_AAB` check (5/5 passed against `dist/flutter-android/Strakalari-0.1.0-android.apk`).
  - **CR-S2** (`45c5d6c`): `PhoneBackground.scheduleWake` in `app/lib/platform/startup.dart` now uses `loop.intervalMinutes` instead of truncating to a whole number. Added `scheduleWakeUsesRunnersFractionalInterval` in `app/test/android_phone_background_test.dart` (14/14 passed).
  - Checks: core `dart analyze` clean, `dart test` 801 passed / 2 skipped; app `flutter analyze` clean, `flutter test` 640 passed / 1 skipped (and 5/5 passed with `STRAKALARI_APK=dist/flutter-android/Strakalari-0.1.0-android.apk`); Python reference suite 1643 passed; `tools/parity/dump.py` + `git diff --exit-code packages/strakalari_core/test/parity/` clean.
- 2026-11-13 · Checkpoint C re-review 2: **PASS WITH FIXES** (CR-M1, CR-M2, CR-S1, CR-S2 fixed; open: 3 should-fix CR2-S1 … CR2-S3; the Sandbox half of C-M7 stays a release condition for Checkpoint D) — [docs/flutter-migration/reviews/checkpoint-C.md](docs/flutter-migration/reviews/checkpoint-C.md)
- 2026-11-13 · Checkpoint C re-review 3: **PASS** (CR2-S1 … CR2-S3 fixed by the reviewer on the owner's instruction; the Sandbox half of C-M7 stays a release condition for Checkpoint D) — [docs/flutter-migration/reviews/checkpoint-C.md](docs/flutter-migration/reviews/checkpoint-C.md)

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

### ⛔ Checkpoint B: UI review (phases 5–6, passed in re-review 5 on 2026-11-12)

The shell and all ten screens exist and are wired to live `AppState` and
`strakalari_core`. Round 4 restyled Today, Planner, Lunches, Activity and Settings
like the Flet screens (B-M11) and the screenshot tools were fixed and re-run (BR-M7).
Read the rework log above for the current state; the list below is the original
round-1 description.

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
  - `app/test/app_state_lunches_test.dart` (lunch AppState cases).
  - `app/test/app_state_excuses_and_planner_test.dart` (30 tests in round 1; the per-file test map above has the current names; covering `test_excuse_ignore_list.py`, `test_planned_skips.py`, `test_error_report.py`, `test_cancel_responsive.py`, `test_news.py`, `test_ui_state.py`, `test_update.py`, `test_automation_safety.py`, `test_settings_refresh_interactive.py`).
  - `app/test/phase6_features_test.dart` (15 tests covering `test_early_leave.py`, `test_timetable_week_nav.py`, `test_marks_view.py`, `test_wizard_setup.py`, `test_year_planner.py`).
  - (`screenshot_parity_test.dart` was removed in B-B3; the capture tools replace it.)
  - (Round 1 count; now app 502 passed + 1 skipped, core 764 passed + 2 skipped.)
  - `dart analyze` and `flutter analyze`: zero issues found across both packages.
- Parity screenshots (NOT yet valid, see BR-M7):
  - Standalone capture tools established under `tools/parity/`:
    - `tools/parity/capture_screens.dart`: captures whole Flutter app (router + AppScaffold + live views, real Roboto and MaterialIcons fonts loaded from SDK cache, light/dark themes, cs/en languages, 1280x800 and 390x844 viewports, 80 screen images total).
    - `tools/parity/capture_flet.py`: automates Flet reference capture via Playwright driving `demo_data.py serve` across all routes, both themes, both languages, both viewports into `build/parity-screens/flet/`.
    - Removed `screenshot_parity_test.dart` from `app/test/` so default test suites run pure unit/widget assertions.
    - Remaining visual differences after round 4 are listed in the round-4 entry of the rework log.
- Windows desktop compilation:
  - `flutter build windows --debug` succeeded (`Strakalari.exe` generated cleanly).

How to verify:
- `cd packages/strakalari_core && dart analyze && dart test` (764 passed, 2 skipped).
- `cd app && flutter analyze && flutter test` (502 passed, 1 skipped).
- Re-capture and compare: `cd app; STRAKALARI_PYTHON=<venv python> flutter test ../tools/parity/capture_screens.dart` and `python tools/parity/capture_flet.py` (needs Playwright + Chromium), then look at `build/parity-screens/flet/` vs `build/parity-screens/flutter/`.
- Test app startup on demo data dir: `python tools/demo_data.py generate build/parity-screens/demo-cs` and run debug executable.

Unsure / needs a second pair of eyes:
- String tables unified onto canonical Strings in B-B4; token handling unified onto AppState.tok / appTokens in B-M9.
- Planner cache key holiday comparison: stringified sorted dates used for pure value comparison across Dart records.
- `wakeupAvailable` remains stubbed to false pending Android Phase 8 implementation.

### ⛔ Checkpoint C: platform review (phases 7–8, passed in re-review 3 on 2026-11-13; Sandbox half of C-M7 open)

Done: desktop tray/autostart/single-instance/notifications/keystores,
Inno (AppId kept) + MSIX adaptations, CI release jobs (including
`build-flutter-android`); Android Java moved + MethodChannel + headless
`backgroundMain` + UI-isolate hand-off + boot re-arm + widget/alarms +
Keystore unwrap + `.test` flavor + privacy test; all Checkpoint C
review and re-review code findings (`C-B1..C-B4`, `C-M1..C-M6`, `C-M8`,
`C-S1..C-S7`, `CR-M1..CR-M2`, `CR-S1..CR-S2`) fixed with tests; phone
tests (parts 1 & 2) passed on the Pixel 7 Pro for over-install over Flet
`.test`, notifications, reboot background alarm, wake-up alarm arming,
home-screen widget, and Back navigation.
Deferred by the owner until the migration is done: Windows Sandbox
over-install re-test (`C-M7` desktop half: Credential Manager key + MSIX;
hit an unsigned-binary Application Control block in Sandbox on 2026-11-13).
How to verify:
- `cd packages/strakalari_core && dart analyze && dart test` (801 passed, 2 skipped: POSIX permissions + Linux/macOS flock probe).
- `cd app && flutter analyze && flutter test` (640 passed, 1 skipped unless `STRAKALARI_APK`/`STRAKALARI_AAB` is set; 5/5 passed with `STRAKALARI_APK=dist/flutter-android/Strakalari-0.1.0-android.apk`).
- `PYTHONUTF8=1 python -m pytest tests/ -q` (1643 passed) and `PYTHONUTF8=1 python tools/parity/dump.py` + `git diff --exit-code packages/strakalari_core/test/parity/` (clean).
- Java/Kotlin compile: `:app:compilePhonetestDebugJavaWithJavac` and `:app:compileProdReleaseJavaWithJavac` pass (`BUILD SUCCESSFUL`).
Phase 7 build check (2026-11-12): `flutter build windows --release` succeeds
(`Strakalari.exe` + plugin DLLs). Inno Setup 6 is at `%LOCALAPPDATA%\Programs\Inno Setup 6`.
Sandbox over-install test still not run.
Phase 7 Sandbox over-install test (2026-11-12, Windows Sandbox, network off):
- Python `Strakalari-Setup-0.1.0.exe` installed, demo data seeded (dry run,
  fake login encrypted with a throwaway `secret.key`), then the Flutter
  installer run over it. Both installers exit 0; `config.json`,
  `data_cache.json`, `excuse_history.json`, `secret.key` byte-identical
  after the install and after 25 s of the Flutter app running; same HKCU
  Run value; still one uninstall entry (same AppId). The Flutter app
  opened on Today with the Python-written demo data.
- Found and fixed: `installer.iss` had broken bundle paths (never compiled
  before); a clean Windows lacks the VC++ runtime, so the installer now
  ships `vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll` app-local;
  the window title was `app`, now `Strakaláři` like Python.
- NOT covered: a key held in Windows Credential Manager by Python keyring
  (only the `secret.key` file path was seeded); MSIX over-install; tray,
  autostart, notifications and single instance by hand.
Unsure / needs a second pair of eyes:
- Sync-core-bridge vs async-channel seams (phase 8 warm-up design).
- macOS/Linux code paths, release builds, CI jobs — owner/CI must run.

### ⛔ Checkpoint D: release review (phase 9, Day 1 green, unreviewed)

Done in Phase 9 so far:
- `main` check (`0ffdcff`): `git log --oneline flutter-migration..main` empty; no unported Python changes on `main`.
- Docs audit: `README.md`, `README.en.md`, `PRIVACY.md`, `CONTRIBUTING.md` updated for Flutter identity/auto-carryover and Android alarm wording.
- Day 1 parity soak against local `tools/bakalari_demo_server.py` (scratch dirs, [SOAK.md](docs/flutter-migration/SOAK.md)):
  - Fresh refresh soak (`soak_refresh.py` vs `dart bin/refresh_dryrun.dart` -> `soak_compare.py`): `IDENTICAL (modulo ts)`.
  - Accumulating refresh soak (reusing Day 1 scratch dirs): `IDENTICAL (modulo ts)`.
  - Fetch parity (`fetch.py` vs `dart bin/parity_fetch.dart`): `FETCH-OK (31116 bytes identical)`.
  - Real-submit proof (`--send-day 09.11.2026` in `confirm` mode, separate fresh local demo server per side; repeated by the reviewer with the committed `soak_refresh.py --send-day`, CR2-S2): `IDENTICAL (modulo ts)` across `result`, `audit`, `outbox`, `history`, `sidecar`, and `cache`.
  - Local Windows Release + MSIX verification (`2f2b0f6`): `flutter build windows --release` succeeded (`Strakalari.exe`), and `tools/make_msix.py` packed `vcruntime140.dll`, `vcruntime140_1.dll`, and `msvcp140.dll` into the root of an unsigned MSIX (34 zip entries, zero personal files).
- Carry-over review notes fixed / verified (`CR-N5`, `R-N2`, `R-N1`, `CR-N4`, `A-N3`):
  - **Windows toast console flash (`CR-N5`, `9d868c5`):** `runProcess` in `packages/strakalari_core/lib/src/platform/desktop_notify.dart` now launches Windows processes via `CreateProcessW` (`CREATE_NO_WINDOW` + `SW_HIDE`) in `Isolate.run`, preventing a flashing PowerShell console window from the GUI app; added `runProcess` test in `desktop_notify_test.dart`.
  - **MSIX VC++ runtime & comment typo (`CR-N5` / `R-N2`, `2f2b0f6`):** `.github/workflows/dart.yml` `build-flutter-msix` now copies `vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll` into `flutter-bundle/` before `tools/make_msix.py`; fixed the stale `{D94B0F7F-...}` AppId comment typo (`{D94B0B7F-...}`).
  - **`R-N1` & `CR-N4`:** `clockAppWeekday` (`wakeup.dart:509`) real-elapsed 24 h check and `A-N3` JSON key ordering are unchanged/covered by parity; `TestMsixVersion` and `test_store_submit_loads` remain in `tests/test_store_package.py` until Phase 10 removes Python packaging tools.
- Latest verification (`2f2b0f6`): core `dart analyze` clean, `dart test` 802 passed / 2 skipped (POSIX permission bits + Linux/macOS flock probe); app `flutter analyze` clean, `flutter test` 640 passed / 1 skipped (and 5/5 passed with `STRAKALARI_APK=dist/flutter-android/Strakalari-0.1.0-android.apk`); Python reference suite `pytest tests/` 1643 passed; `tools/parity/dump.py` + `git diff --exit-code packages/strakalari_core/test/parity/` clean.

Still required before Phase 9 exit / beta cut:
- Multi-day soak Days 2–3 (minimum 3 consecutive days green on fresh + reused dirs per `SOAK.md`).
- Windows Sandbox desktop over-install re-test (`C-M7` desktop half, previously blocked by Sandbox Application Control policy).
- Combined Checkpoints A–D review and explicit owner go-ahead before tagging any beta or starting Phase 10.

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
