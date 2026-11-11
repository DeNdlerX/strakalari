# Checkpoint B review: UI (phases 5–6)

Reviewed 2026-11-10 at `6a425cd` (branch `flutter-migration`), against the Python app on
the same branch (`strakalari/flet_ui/`, unchanged against `main` = `0ffdcff`).
Commits reviewed: `96d7159..6a425cd` (14 commits since the Checkpoint A pass, `a12cdca`),
plus the phase 5–6 code they build on.

## Verdict: **FAIL**

The tests are green and the core is untouched, but the UI is not a port of the Python UI
yet. Two main screens (Absences, Planner) stay empty for every real user, the Today screen
decides on its own what to excuse, one of the three text tables was rewritten by hand (and
stays Czech for English users), the tutorials never start, switching to automatic mode
cannot work, the shell's top bar and rail look and behave differently, and about 150
Python UI test cases are still not ported. The "side-by-side screenshots" in STATUS.md were
not real screenshots: they show grey boxes instead of letters and no app shell.

5 blockers, 14 must-fix, 6 should-fix, 4 notes.

Fix order: blockers first (B-B1 … B-B5), then the must-fix items. One commit per finding,
named `Checkpoint B <ID>: …`.

---

## Blockers

### B-B1 Absences and Planner are empty for every user with a subject list

- Dart: `app/lib/controllers/app_state.dart:423-427` (`trackedSubjects`)
- Python: `strakalari/flet_ui/state.py:443-455` (`tracked_subjects`)

Python builds the tracked set from the subject directory's **keys** (subject names:
`{canon_subject(name) for name in directory}`). Dart uses `directory.values`, which are the
**teachers' names** (`{'Matematika': 'Mgr. Karel Novák', …}`). Every subject is then
filtered out: `subjectStates()` returns 0 subjects although the cache holds 25 timetable
days and 12 absence entries (I checked this with a probe on the demo data), so Absences
shows "Zatím žádná data" and Planner shows "Nejprve se přihlas", while the Python app shows
8 subjects and a full plan from the same folder. Bakaláři always fills `subject_directory`,
so this hits every real user. The Today screen's planner hints are empty for the same
reason.

Correct: `return {for (final n in directory.keys) canonSubject(n)};`. Add an `AppState`
test with a realistic directory (`{'Matematika': 'Mgr. X'}` plus absence and timetable)
asserting `subjectStates()` is non-empty and that a subject missing from the directory is
dropped (the Python behaviour). The existing live tests did not catch it because their
fixtures have no directory.

### B-B2 The Today screen builds its own excuse list and can send a task Python would never offer

- Dart: `app/lib/features/today/excuse_logic.dart` (whole file; its header says "subset
  used by the UI"), `app/lib/features/today/today_controller.dart:239-260, 330, 455, 527`
  (`excuseTasks()` from that copy), `app/lib/features/today/today_live.dart:80-101`
- Python: `strakalari/flet_ui/views/today.py:599` (`_excuse_cards(state, page,
  state.excuse_tasks())`), `:218` and `:299` (sends exactly that task dict),
  `strakalari/flet_ui/state_excuses.py:44-87` (`_all_excuse_tasks` / `excuse_tasks`, built
  on `core.models.excuse_tasks_from_lessons` and `core.excuse_history.task_covered`)

The Today view does not use `AppState.excuseTasks()` (the correct port in
`controllers/excuses.dart`, built on core). It uses a second, partial re-implementation of
task generation, coverage and the day plan. When the user presses *Omluvit*,
`today_live.dart` looks the key up in `s.excuseTasks()` and, if it is **not** there,
fabricates a task (`existing ?? {…}`, kind guessed from the excuse `type`) and sends it
anyway. So whenever the two implementations disagree, the app sends an excuse the Python
app (and the core rules) would not have offered, with a guessed kind. A sent excuse cannot
be taken back. This breaks the "one send path" rule.

Correct:
- The Today view lists exactly `s.excuseTasks()` and `s.dayExcusePlan(...)`; the per-day
  grouping, the "Nebo jednotlivě" list and the badges come from those results.
- `onSend` passes the `AppState` task dict unchanged. If the key is not in
  `s.excuseTasks()` it sends nothing, logs `excuse_failed`, and returns false (Python never
  sends a task that is not in the state's list).
- Delete `excuse_logic.dart` (and the copies of `lessons_from_timetable`,
  `excuse_window_start`, `task_covered`, `day_excuse_plan` in it).
- Port the missing `test_day_card_switch_sends_lessons_separately`
  (`tests/test_excuse_day_scope.py:156`) as a widget test against the live Today view, and
  add one that a key absent from `s.excuseTasks()` is never sent.

### B-B3 Screenshot parity was not done; STATUS.md says it was

- Dart: `app/test/screenshot_parity_test.dart` (whole file); STATUS.md "Parity screenshots"
  and the Checkpoint B notes
- Plan: PLAN §4 phase 6 "Done when" (every screen, cs/en, light/dark, 1280 and 390 px, side
  by side under `build/parity-screens/`)

The committed "screenshots" are bare views rendered by `flutter test` with the test font:
every letter is a grey box, there is no rail, no top bar, no theme switch, only 5 screens,
only dark, only 1280 px. Nobody could compare anything with them, yet STATUS.md says they
were "generated … with exact matching names and dimensions". In addition, this file runs
inside every `flutter test`, writes into `build/` and asserts nothing.

Correct:
- Remove `screenshot_parity_test.dart` from `app/test/` (a capture script is a tool, not a
  test). Put the capture under `tools/parity/` (for example a Flutter integration test or a
  script run on demand), never in the default test run.
- Capture the **whole app**: router + `AppScaffold` + live views, real fonts (load Roboto
  and MaterialIcons, as below), the demo folder from `tools/demo_data.py generate`, and the
  wizard dismissed exactly as `tools/demo_data.py serve` does (`wizard_dismissed = True`).
  Every screen including More and the wizard, cs/en, dark/light, 1280×800 and 390×844.
- Capture Flet the same way (`demo_data.py serve` + Playwright, every route through the
  rail / bottom bar / More menu, both widths, both themes, both languages). Write both sets
  to `build/parity-screens/{flet,flutter}/<screen>-<lang>-<theme>-<width>.png`.
- In STATUS.md list every remaining visible difference with its reason, and say plainly
  what was and was not captured.

How I captured them for this review (scratch only, not committed): a temporary widget test
that loads `~/flutter/3.44.8/bin/cache/artifacts/material_fonts/roboto-*.ttf` and
`materialicons-regular.otf` with `FontLoader`, builds `MaterialApp.router(buildRouter())`
in an `UncontrolledProviderScope` whose `AppState.wizardDismissed = true`, navigates with
`router.go`, and saves a `RepaintBoundary` image; and a Playwright script driving
`demo_data.py serve`. 70 + 70 images. The differences I saw are in B-M1 … B-M4 and B-M11.

### B-B4 One of the three text tables was rewritten by hand, and it ignores the language at start

- Dart: `app/lib/widgets/overlays.dart:9-…` (`class Str`, `tables`), used 303 times by
  `features/settings/settings_view.dart` (122), `features/planner/planner_view.dart` (75),
  `features/lunches/lunches_view.dart` (46), `features/activity/activity_view.dart` (31),
  `widgets/overlays.dart` (18), `features/planner/plan_reserve.dart` (9),
  `features/more.dart` (2); `Str.language` is only set in
  `features/settings/settings_view.dart:1138` (when the user changes the language)
- Python: `strakalari/flet_ui/strings.py` (`STRINGS`, `MOBILE_STRINGS`)

I compared every key by script (Python `STRINGS`/`MOBILE_STRINGS` dumped to JSON, every
Dart table dumped from a temporary test):

| Table | Keys | Same text as Python |
|---|---|---|
| ARB `app_cs.arb` / `app_en.arb` | 794 + 13 `notif_*` | all 794 (but the ARB files are not used, see B-S3) |
| `l10n/strings.dart` `Strings` (desktop and mobile) | 794 + 7 mobile | **all**, cs and en |
| `features/common/app_strings.dart` `AppStrings` | 266 | cs: 265 (`wiz_need_strava` "Zapnete-li" instead of "Zapněte-li"); en: 252 (14 have a curly `’` where Python has `'`) |
| `widgets/overlays.dart` `Str` | 479 Python keys (+2 not in Python: `reserve_title`, `reserve_body`) | cs: **139** (340 differ), en: **152** (327 differ) |

`Str` holds invented, shortened texts, mostly in the informal "ty" form, including the
safety texts: `automation_disclaimer` is "Automatizace posílá omluvenky tvým jménem."
instead of Python's warning about acting under the user's account and the school rules;
`automation_pause_hint` is "Pozastaví všechny automatické běhy." instead of "Dokud je
zapnuto, obnova nic neodešle ani neobjedná (ani v režimu Automaticky)."; `mode_dry_run` is
"Zkušební" instead of "Jen nanečisto". And because `Str.language` starts as `'cs'` and is
only changed from the settings dropdown, an English user sees Czech on Planner, Lunches,
Activity, Settings and More after every start (visible in the en screenshots).

Also hardcoded Czech in `features/settings/settings_view.dart:626` ('Vlastní'),
`:1120` ('Tmavý'), `:1122` ('Světlý'); English users see them too.

Correct: one string table. Delete `Str` and `AppStrings`; every widget calls
`Strings.get` / `Strings.format` (the generated table, which matches Python exactly) with
the same keys; `reserve_title` / `reserve_body` go away or are replaced by the Python keys
the Python view uses. Replace the hardcoded labels with their `strings.py` keys. Add a test
that fails if any `.dart` file under `app/lib` other than `l10n/strings.dart` contains a
string map, and a test that every key used in `app/lib` exists in `strings.py`'s dump.

### B-B5 Switching to automatic mode can never work, and the safety dialog is missing

- Dart: `app/lib/features/settings/settings_controller.dart:247-263` (`commitMode`),
  `app/lib/features/settings/settings_live.dart:32-…` (no `confirmAutoMode` passed),
  `app/lib/features/settings/settings_view.dart:909-916` (snack on cancel)
- Python: `strakalari/flet_ui/safety.py:22-78` (`confirm_auto_mode`), its callers in
  `strakalari/flet_ui/views/settings/automation.py:70-72`

`commitMode` asks `confirmAutoMode?.call(key) ?? 'cancel'`, but the live screen never
passes `confirmAutoMode`, so choosing *Automaticky* is always cancelled, and the screen
then shows "Uloženo" (`if (r == 'cancelled') appSnack(context, Str.t('saved'))`), which is
false. The confirmation dialog itself (`auto_confirm_title`, `auto_confirm_excuse` /
`auto_confirm_lunch`, `auto_confirm_no_dry_run`, `auto_confirm_unsigned`,
`auto_confirm_pause_hint`, buttons cancel / `auto_confirm_dry` / `auto_confirm_ok`, width
`dialog_width(page, 440)`; called from `views/settings/automation.py:70-72`) exists
nowhere in `app/lib`: the `auto_confirm_*` keys are not
used. Failing closed is safe today, but the feature is broken, the user is told something
untrue, and as soon as someone wires a callback without the dialog, automatic sending would
turn on without the warning.

Correct: port `confirm_auto_mode` as a dialog (same texts, same three buttons, same
conditions for the "no dry run yet" and "unsigned excuses" lines, same callbacks) and pass
it from `settings_live.dart` (and from the wizard, if the Python wizard offers the modes).
On cancel, restore the previous value in the dropdown and show nothing (or what Python
shows). Port the three Python tests that are still deferred:
`test_auto_confirm_dialog_recommends_dry_run_first`, `test_auto_confirm_dialog_after_dry_run`,
`test_auto_confirm_dialog_warns_unsigned_excuses` (`tests/test_automation_safety.py`).

---

## Must-fix

### B-M1 The top bar is not the Python top bar

- Dart: `app/lib/shell/scaffold.dart:175-214`
- Python: `strakalari/flet_ui/app.py:328-462` (`_status_text`, `_refresh_clicked`,
  `_build_narrow_topbar`, `_build_topbar`)

Missing or different:
- No status pill: Python shows a status dot plus `_status_text()` (current step while
  refreshing, `status_error: detail`, `status_ok · last_run: …`, `status_idle`), clickable
  to Activity, with the tooltip "last updated / next run". Dart shows `updatedLabel` only.
- No update button ("Je dostupná nová verze 0.2.1", ghost button → Activity; on the phone
  an icon button).
- Refresh is an icon only; Python's wide layout has the primary button "Obnovit data".
- While a refresh runs, Python shows a spinner, "Obnovuji" and an **X that cancels the
  refresh** (`cancel_refresh`). Dart shows a spinner and nothing to cancel with.
- Python's `_refresh_clicked` snacks `already_running` / `refresh_started`; Dart does not.
- Dart adds an `AppBar` with the screen title ("Dnes", "Rozvrh", …); Python has no title
  bar (each view has its own heading), so Flutter shows every title twice.
- The tutorial anchors `status` and `refresh` (see B-M5) belong on these controls.

Correct: rebuild the top bar as in `_build_topbar` / `_build_narrow_topbar`, without an
`AppBar` title. Port the `TestNarrowShell` and topbar cases (B-M7).

### B-M2 Rail, side rail and page padding differ

- Dart: `app/lib/shell/scaffold.dart:251-305`
- Python: `strakalari/flet_ui/app.py:132-152, 296-326, 639-708`

- Wide: Dart uses `NavigationRail(extended: true)` (icon beside a long label, a 200 px
  column). Python uses the standard rail: label under the icon, about 90 px wide.
- Side rail (landscape phone): Python `label_type=ALL`, `group_alignment=0.0`, lunch badge
  on the icon; Dart `labelType: selected`, no badge.
- Content padding: Python pads `tok.pad + 8` on wide pages and 12 / 4 px on phones; Dart
  adds none in the shell.
- Divider: Python `VerticalDivider(width=1, color=tok.border)`; Dart uses the default color.

### B-M3 The wizard is shown inside the app chrome

- Dart: `app/lib/shell/scaffold.dart:119-136`, `app/lib/shell/router.dart:124-125`
- Python: `strakalari/flet_ui/app.py:561-595`

Python's wizard owns the whole page: no rail, no bottom bar, no top bar, and it stays until
finished or dismissed even after step 2 saves a login. Dart routes to `/wizard` inside
`AppScaffold`, so the user sees the rail / bottom bar and the refresh button (which starts a
refresh before setup is finished). Correct: render the wizard outside the shell (a separate
top-level route or an early return in `AppScaffold`) with the same `setupPending` /
`wizardShown` rules, and no navigation or refresh controls while it is shown.

### B-M4 A crashing screen is not caught

- Dart: `app/lib/shell/router.dart:97-130`, `app/lib/shell/scaffold.dart`
- Python: `strakalari/flet_ui/app.py:619-634`

Python wraps the view build: on an exception it calls `report_error(f"view ({route})",
exc)` (so the error dialog with *Copy log* appears) and shows a card with `status_error`
instead of a blank app. Dart has no such guard; a throwing build shows Flutter's red error
screen in debug and a grey box in release, and nothing is reported. Correct: catch build
errors per screen (for example an `ErrorWidget.builder` / error boundary widget around
`child` that reports through `AppState.reportError` once per failure and shows the same
card).

### B-M5 Tutorials never start

- Dart: `app/lib/widgets/overlays.dart:1591-1639` (`TutorialAnchor`, used nowhere),
  `app/lib/widgets/overlays.dart:1392` (a second `offer`/tutorial controller),
  `app/lib/controllers/tutorial.dart:98-110`, `app/lib/shell/scaffold.dart` (no `begin`, no
  layer)
- Python: `strakalari/flet_ui/tutorial.py:140-151` (`begin`), `:168-201` (`anchor`),
  `:203-255` (`layer`), `strakalari/flet_ui/app.py:614, 647-652`

The tour definitions match Python (9 tours, every step, anchor and `until` event; only the
planner `plan_strip` icon differs, B-S4), and the screens call `tutorialOffer` and fire the
events. But: the shell never calls the port of `begin` (suspend another screen's tour,
offer `intro`), and every tour except `intro` waits for `intro` to be done, so no tour ever
starts; no view wraps a single control in `TutorialAnchor` (Python has 18 anchors:
`refresh`, `status`, `excuse_card`, `tt_nav`, `tt_legend`, `abs_stats`, `abs_first`,
`plan_strip`, `plan_first`, `plan_budget`, `lunch_day`, `lunch_send`, `lunch_tools`,
`marks_stats`, `marks_subject`, `marks_need`, `marks_predict`, `marks_scale`); and the
shell has no floating bubble layer. The Flet screenshot of a fresh demo shows the welcome
bubble; Flutter shows nothing.

Correct: one tutorial implementation (keep `controllers/tutorial.dart`, delete the second
one in `overlays.dart`), `begin` called by the shell before each screen, the 18 anchors
placed on the same controls, the floating layer stacked over the content as in `app.py`.
Then port the 8 deferred `test_tutorial.py` functions (B-M7).

### B-M6 Business logic duplicated inside the app

- Dart: `app/lib/features/marks/grades_logic.dart` (731 lines, "a pure port of
  core/grades.py"), `app/lib/features/common/schedule_logic.dart` (462 lines, port of
  `core/schedule.py`), `app/lib/features/lunches/lunch_filter.dart` (port of
  `core/matching.py`), `app/lib/features/today/excuse_logic.dart` (B-B2),
  `app/lib/features/common/lesson_model.dart`, `convertStableBaseline` in
  `app/lib/features/today/today_live.dart:16-48`
- Python: the views call core (`strakalari.core.grades`, `.schedule`, `.matching`) through
  `AppState`

The core already has parity-tested ports of these modules
(`packages/strakalari_core/lib/src/planning/grades.dart`, `schedule.dart`, `matching.dart`).
The app carries second copies that no parity JSON checks. `lunch_filter.dart`'s hand-made
diacritics table folds `ł`, `ø`, `ß`… — the exact bug STATUS.md's Deviations say the core
port fixed ("the mirror wrongly folded ł/ø/ß, Python NFD keeps them"); it decides which
meal the filter stages for ordering. `test_lunch_filter.py`'s cases were ported against
this copy, not against `AppState`.

Correct: delete the copies; marks, timetable, today and lunches read through `AppState` and
core (`core.SlotBaseline` directly, no local class). Re-point `lunches_filter_test.dart`
(and the other tests of the copies) to `AppState` / core, like the Python tests
(`tests/test_lunch_filter.py:11-12` import `core.matching` and `AppState`). This also
answers STATUS question 1 ("unify … onto the canonical core ports"): yes, now.

### B-M7 About 150 Python UI test cases are not ported

PLAN rule 4: every Python test file gets a Dart counterpart with the same cases. Phases 5
and 6 are where these belong; STATUS.md still lists many as "Deferred (phase 5/6)".
Collected with `pytest --collect-only` vs `test(` / `testWidgets(` in `app/test`:

| Python file (cases) | Dart now | Missing |
|---|---|---|
| `test_wizard_setup.py` (34) | `wizard_settings_test` 5, `wizard_live_test` 2, `phase6_features_test` 2 | ~25 step/validation/scheduler-gate cases |
| `test_ui_views.py` (28) | ~8 | 15 timetable/scroll/today cases (STATUS item 87 still says deferred) and others |
| `test_tutorial.py` (36) | `tutorial_test` 19 | 8 functions (anchors, floating, suspend, intro on any screen, today anchor, shell bubble, marks tour) |
| `test_mobile.py` `TestNarrowShell` (12) | `widget_test` 2 | `refresh_ticks_repaint_only_the_topbar`, `more_screens_select_more`, `landscape_phone_gets_side_rail`, `rotating_swaps_bar_and_side_rail`, `phone_timetable_grid_scrolls_sideways`, `widening_leaves_more`, `every_screen_builds` (per route), `back_steps_up`, `back_closes_open_settings_section_first` |
| `test_early_leave.py` (13) | 2 + 1 | 10 detection/status cases |
| `test_marks_view.py` (15) | 6 | 9 |
| `test_plan_picker.py` (12) | 1 | 11 |
| `test_planner_dialog.py` (6) | 2 | 4 |
| `test_excuse_day_scope.py` (8) | 7 | `test_day_card_switch_sends_lessons_separately` |
| `test_settings_refresh_interactive.py` (4) | 1 test that is not any of them | all 4 (`worker_tick_does_not_rebuild_settings`, `user_nav_rebuilds_settings_during_refresh`, `progress_tick_rebuilds_only_the_live_log` ×2) |
| `test_timetable_week_switch.py` (3) | 0 | 3 |
| `test_stable_change_signals.py` UI (3) | 0 | 3 |
| `test_open_url.py` (5) | 0 | 5 |
| `test_wakeup_and_widget.py` `TestTimetableViews`, `TestCollapsibleDays`, `TestWakeupUI` | 0 | the UI ones (the Android ones may wait for phase 8) |
| `test_automation_safety.py` confirm dialog (3) | 0 | 3 (B-B5) |
| `test_order_latch.py` (7) | 4 tests, 7 cases | — (ok) |

Correct: port each case 1:1 (same name in camelCase, same assertions) against the live
`AppState` / shell / views, or list it under *Dropped* with a reason I can accept (a Flet
mechanism that has no Flutter counterpart, e.g. `render_progress` repaint counting, may be
dropped if replaced by an equivalent check). Update the test map so no phase 5/6 item says
"Deferred".

### B-M8 `AppState.save` swallows failures silently

- Dart: `app/lib/controllers/app_state.dart:298-329`
- Python: `strakalari/flet_ui/state.py:318-347`

Python prints `Warning: ignoring invalid config update {key!r}: {exc}`, `Warning: could not
save config: {exc}` and `Warning: config listener failed: {exc}`. Dart catches all three
with no output (`catch (err) { ok = false; }`, `catch (_) { return false; }`,
`catch (_) {}`). CONTRIBUTING §5 "Fail loudly" applies to save code. Correct: print the same
three warnings (Python `repr` of the key via `pyRepr`).

### B-M9 Settings and app preferences: missing behaviour

- Dart: `app/lib/controllers/app_state.dart:372` (`densityCompact`, used nowhere),
  `app_state.dart:296-329`, `main.dart:43-46`
- Python: `strakalari/flet_ui/state.py:297-309` (`_refresh_tokens`)

- *Kompaktní zobrazení* (`compact_density`) is saved but changes nothing; Python uses
  `pad=10, gap=8`.
- `STRAKALARI_THEME` (forced theme, used by tools) is ignored.
- The core language (`core.setLanguage`) is only set on a save, not at start-up, so core
  texts stay Czech for English users until they save something: the English Today and
  Lunches screens show "právě teď" in the date line (`describeCache`). Python sets it in
  `_refresh_tokens`, which runs at start and on every save.

Correct: one `refreshTokens()` called from the `AppState` constructor and from `save()`,
doing what `_refresh_tokens` does.

### B-M10 More page and Android Back

- Dart: `app/lib/shell/router.dart:122-123`, `app/lib/features/more.dart:7-51`, no
  `PopScope` anywhere
- Python: `strakalari/flet_ui/views/more.py:22-53`, `strakalari/flet_ui/app.py:216-287`

- The router builds `MorePage` without `isAndroid`, so the *Budík* entry never appears on
  Android; tapping it would go to `/alarm`, which `routeForLocation` turns into Today.
  Python opens Settings straight in the alarm section (`settings_section = "alarm"`,
  `settings_open = True`) and opens Settings from More on its list (`settings_open = False`).
- The More page has its own `ListTile` title and plain `Card`s; Python uses `C.title` and
  tiles with `bgcolor=tok.card`, accent icons and `radius_md`.
- Android Back is not handled: Python steps up (More screen → More, anything else →
  Today, Today → leave) and first closes an open settings section, open marks subject or
  open lunch tools (`back_target`, `_subpage_open`, `_close_subpage`).

Correct: port `_open`, `back_target`, `_subpage_open`, `_close_subpage` (a `PopScope` in
the shell, phone layouts only) and the two Back tests (B-M7).

### B-M11 Visible differences on the screens (from my side-by-side screenshots)

Same demo data, same date, cs dark 1280/390 unless noted. Each line is a difference to fix
unless STATUS.md gives a reason I accept.

| Screen | Python (Flet) | Flutter now |
|---|---|---|
| all | top bar, rail, padding: see B-M1, B-M2 | |
| all | headings with the date line under them (`header_with_actions`) | date at the right edge or missing |
| all | section headers small, upper-case, muted (`C.section_header`) | bold, normal case |
| Today | excuse card: outlined dropdown, buttons *Omluvit* (filled) and *Ignorovat* (outlined) beside it | filled dropdown, buttons below, *Omluvit* outlined, *Ignorovat* a text link |
| Today | day card badge "Krátká absence" / "Short absence" next to the date, accent border | "Absence" / "Absent" at the right edge |
| Today (en) | "Matematika — 2. 11., period 1" | "1. period" |
| Timetable | full subject names at 1280 px ("Tělesná výchova"), short names only when narrow (`on_resize` 60 px buckets) | "TV" at 1280 px |
| Timetable | *Tento týden* / *Stálý* both outlined buttons | text link + outlined |
| Absences | 3 stat cards + subject rows | empty (B-B1) |
| Marks | stat cards fill the width; "POSLEDNÍ ZNÁMKY" small header | narrow fixed cards; large header |
| Planner | full plan | empty (B-B1); the intro line is invented informal text (B-B4) |
| Lunches | day header "Pondělí 16. 11. 2026"; button "Odeslat objednávky do Stravy" (not full width); "Bez oběda (odhlásit)"; AI card with model badge, *Získat klíč zdarma*, *Otevřít nastavení*, *Doporučit (AI)*, two hint lines; blacklist card with "Blacklist je prázdný." and "Přidat slovo" | "16.11.2026"; full-width "Odeslat"; "Bez oběda"; AI card with other texts and buttons; "Slovo" field |
| Lunches (en) | English | Czech (B-B4) |
| Activity | update card (*Stáhnout aktualizaci*, *Skrýt*), status card with scope switch *Vše / Bakaláři / Strava* + *Obnovit data*, 4 stat cards (next run "19:05"), automation card with **Pozastavit automatizaci** switch, mode lines and *Upravit pravidla*, automation history filter *Vše / Omluvenky / Obědy* | none of these; "Zatím klid" + *Obnovit*; next run "—" |
| Settings | groups "Škola a účty / Automatizace / Aplikace / Pokročilé", items with icons ("Limity předmětů", "AI doporučení", "Diagnostika"), filled fields with labels above, password "Nevyplněno" with eye toggle | other group and item names, underline fields, "Test Bakalářů / Test Stravy" at the bottom, invented hints ("Najdeš ho v adrese objednávky") |
| More | see B-M10 | |
| Wizard | full page, no chrome (B-M3) | inside the shell |

The *Pozastavit automatizaci* switch on Activity matters most: Python's texts tell users
they can stop automation "Activity or Settings" (`auto_confirm_pause_hint`).

### B-M12 `DateTime.now()` in the app

- `app/lib/features/activity/activity_controller.dart:70, 106, 145, 212`,
  `app/lib/features/activity/activity_view.dart:228`,
  `app/lib/features/lunches/lunches_view.dart:56`,
  `app/lib/features/marks/grades_logic.dart:417` (goes away with B-M6)

PLAN §3.3: `clock.now()`, never `DateTime.now()`. Replace each; the tests then control time
with `withClock`.

### B-M13 STATUS.md claims that are not true

- "Flutter screenshots generated into `build/parity-screens/flutter/` with exact matching
  names and dimensions" (B-B3).
- "`app_state_lunches_test.dart` (25 tests covering `test_lunches.py`,
  `test_lunch_matching.py`)": the file has 14 tests, and neither Python file exists.
- "Shell … and all screens … are fully implemented and wired to live `AppState`" (B-B1,
  B-B2, B-B5, B-M1 … B-M11).
- `test_settings_refresh_interactive.py` is listed as covered by
  `app_state_excuses_and_planner_test.dart`; that test (`workerTickEmitsProgressNotOnChanged`)
  is none of the 4 Python cases.
- The test map still says "Deferred (phase 5/6)" for items that phases 5 and 6 owned.

Correct: rewrite the Checkpoint B notes and the test map from the code and from test runs,
with counts that match `flutter test`.

### B-M14 Error dialog width

- Dart: `app/lib/widgets/error_dialog.dart:80, 112` (`(width - 128).clamp(280, 560)`)
- Python: `strakalari/flet_ui/overlays.py:262` (`dialog_width(page, 560)`),
  `strakalari/flet_ui/components.py:31-40` (`max(240, min(preferred, width - 64))`)

At 390 px Python's dialog is 326 px wide, Flutter's 280 px. Use `dialogWidth(context,
560)` and fix that helper (`app/lib/widgets/app_widgets.dart:105-109`) to clamp at 240, not
280. The *Copy log* button itself is there and copies the report (good).

---

## Should-fix

- **B-S1** Dialog widths elsewhere: the Python dialogs use `dialog_width(page, 520)`
  (planner custom range, `views/planner.py:1016`), 380 (`views/timetable.py:232`), 440
  (`views/today.py:110`, `safety.py:69`); the Flutter `AlertDialog`s in `planner_view.dart`,
  `timetable_view.dart:1018`, `today_view.dart:569` use the default width. Wrap their content
  in `SizedBox(width: dialogWidth(context, N))`.
- **B-S2** `packages/strakalari_core/lib/src/storage/config.dart:517-519, 600-603`: the new
  public `saveOverride` test seam in production `ConfigManager.save()` skips the lock and the
  "unreadable at start" guard. Mark it `@visibleForTesting` (package `meta`) or replace it
  with a test double in `app/test`, and list it under Deviations (like `fernetFactory`).
- **B-S3** The ARB files (`app/lib/l10n/app_cs.arb`, `app_en.arb`) are generated but never
  used (no `l10n.yaml`, no `generate: true`, no `AppLocalizations`); PLAN §3.2 says ARB +
  gen-l10n. The `Strings` map matches Python exactly, so I accept it **if** STATUS.md lists
  it as a deviation (and the ARB files are either removed or kept in sync by the same
  generator, with a test that they equal `strings.py`).
- **B-S4** `app/lib/tutorial/tours.dart:113`: `plan_strip` uses
  `Icons.calendar_month_outlined`; Python uses `CALENDAR_VIEW_MONTH_OUTLINED`
  (`tutorial.py:105`).
- **B-S5** `app/lib/widgets/error_dialog.dart:109-150` adds a *Share* button (and the
  `share_plus` dependency). The Python app has no share anywhere (`grep -ri share
  strakalari/flet_ui` finds none). PLAN §3.3 lists `share_plus` "(Share log on the phone)",
  but rule 1 (parity) wins: remove it, or ask the owner under *Questions* and keep it only
  with their yes, listed as a deviation.
- **B-S6** `app/lib/features/timetable/timetable_view.dart:143-151` `_isoWeek` steps days
  with `Duration` on local dates (PLAN §3.5 / A-B1 say `addDays`). The result is right
  today because the Thursday–Monday gap is never a whole number of weeks, but use `addDays`
  / `daysBetween` like the core does.

## Notes

- **B-N1** Test hosts: `https://skola.bakalari.cz` appears as a config value in
  `settings_live_test.dart:32`, `wizard_live_test.dart:33`, `wizard_settings_test.dart:29,
  54`, the same as `tests/test_wizard_setup.py`; nothing contacts it. Fine.
- **B-N2** The send and order workers themselves are faithful:
  `controllers/excuses.dart:462-548` (`_excuseWorker`) equals `state_excuses.py:418-497`
  line by line (session lock, `sendExcuseOutcome`, busy / dry run / covered / unconfirmed /
  skipped / failed messages, notification, `reportError`, `close` warning); refresh goes
  through `withSessionLockAsync` + `runRefresh` (`controllers/activity.dart:285-322`);
  orders through `withSessionLockAsync` (`controllers/lunches.dart:229`). The problems are
  in what the views feed them (B-B2).
- **B-N3** Config keys: I found no new or renamed config key in `app/lib` against
  `config.example.json` and the Python sources; core config validation is unchanged since
  Checkpoint A.
- **B-N4** Open notes from Checkpoint A (R3-N1 macOS Python↔Dart lock, R3-N2 broken
  `installer.iss` paths, R-N*/R2-N*) stay open for Checkpoint C.

## Deviations listed for phases 5–6: sign-off

- `NavigationDestination` instead of `NavigationBarDestination`: accepted (Flutter name).
- Package pins (`launch_at_startup ^0.5.1`, `tray_manager ^0.5.2`, `go_router ^18`,
  `clock ^1.1.0`): accepted for B; the lockfile pins exact versions.
- Template smoke test replaced: accepted.
- "Three parallel string/token tables", "feature controllers a mix of `ChangeNotifier` and
  listener lists", "router builders with default controllers": **not accepted** (B-B4,
  B-M6). Token tables: keep one (`shell/theme.dart`); `features/common/app_tokens.dart`
  duplicates it.
- "Screenshots side-by-side not produced" (older line) vs "generated" (newer line): see B-B3.
- `backgroundMain` trampoline and the phase 7–9 items: Checkpoint C/D.
- Six parallel subagents built phases 5–9: noted. It explains the duplicated tables and
  logic; the fix is B-B4 and B-M6.

The *Dropped* list (`tls.py`, `test_tls_bundle.py`, `test_frozen_ssl.py`,
`test_imports_resolve.py`) is unchanged and its reasons stay valid.

## What I verified, and how

Flutter 3.44.8 / Dart 3.12.2, Windows 11 (Europe/Prague). Scratch probes and screenshots
were written to the reviewer's scratchpad; three temporary test files in `app/test/` were
deleted right after use, and `git status` was clean before this commit. No real server, key
store or personal data was touched (`STRAKALARI_NO_KEYRING=1`, demo folders only, the Flet
demo server on 127.0.0.1).

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / 764 passed, 2 skipped (same two as Checkpoint A) |
| `flutter analyze` / `flutter test` (app) | clean / 241 passed, 1 skipped (APK scan) |
| Python suite | 1643 passed |
| `tools/parity/dump.py` + `git diff --exit-code` on `test/parity/` | clean |
| Strings | Python `STRINGS`/`MOBILE_STRINGS` dumped; all Dart tables dumped by a temporary test; compared key by key, cs and en, desktop and mobile (table in B-B4) |
| Tutorials | `TOURS` vs `tours.dart` step by step (match except one icon); anchors / events / offers grepped on both sides (B-M5) |
| Screenshots | 70 Flet (Playwright on `demo_data.py serve`) and 70 Flutter (full router + shell, real fonts) images: 8 screens + More + wizard, cs/en, dark/light, 1280 and 390 px; paired and inspected (B-M11). The committed `build/parity-screens/flutter/*.png` are test-font renders (B-B3) |
| Root cause of empty Absences/Planner | probe: `AppState` on the demo folder → 25 timetable days, 12 absences, `subjectStates()` = 0; directory values are teacher names (B-B1) |
| Layout | breakpoints 720 / 520 and `layoutForSize` match `is_narrow` / `layout_for`; bar tabs and More routes match; differences in B-M1, B-M2, B-M10 |
| Wiring | `runRefresh`, session lock, excuse and order workers read against Python (B-N2); Today send path (B-B2); duplicated logic (B-M6) |
| Test parity / integrity | pytest collection counts vs Dart counts (B-M7); `git log -p a12cdca..HEAD -- app/test`: no assertion removed; no `skip:` except the APK scan; `isNotNull` only where Python also checks presence; no `try`/`catch` around `expect`; `screenshot_parity_test.dart` asserts nothing (B-B3) |
| §3.5 | `DateTime.now()` (B-M12); `DateTime.parse` only on ISO dates; no `jsonEncode` in the app; `~/` / `round` sites checked (B-S6) |
| Fail loudly | every `catch` in `controllers/{excuses,lunches,activity,app_state}.dart` read; the send/order workers report; `save` does not (B-M8) |
| Architecture | no `package:flutter` in `packages/strakalari_core`; no build_runner / `*.g.dart`; `pubspec.lock` committed; Flutter 3.44.8 pinned in `dart.yml` with `--enforce-lockfile` |
| Hygiene | no `config.json`, `data_cache.json`, `log.txt`, `htmls/`, `*.key`, `*.jks` in the branch history except the test fixture `test/parity/config.json`; no upstream for `flutter-migration`; all 14 new commits by DeNdlerX, none with `Co-Authored-By` / `Claude-Session` |
| `main` ported | `main` = `0ffdcff`, an ancestor of the branch; `strakalari/` and `tests/` unchanged against `main` |

**Not verified at this checkpoint:** the desktop and Android platform code (phases 7–8,
Checkpoint C), macOS/Linux, and the release work (Checkpoint D).

---

## Re-review (2026-11-10)

Reviewed at `4f095ec`, commits `5ae03cc..4f095ec` (15 commits since the review commit
`645eb97`: B-B1 … B-B5 and B-M1 … B-M10). STATUS.md's Next step still names B-M11 … B-M14,
so the rework was stopped half-way; B-M11 … B-M14 and every should-fix item were not
attempted.

### Verdict: **FAIL**

All five blockers are fixed in the code, and so are most of the must-fix items that were
attempted. The two main screens that were empty (Absences, Planner) now show the same data
as the Python app, the Today screen can no longer send a task the state did not offer, and
there is one string table. But four original must-fix items are untouched (B-M11 … B-M14),
two are only partly done (B-B3 capture, B-M7 test ports), and the rework added new defects
on the screens it touched: the Today screen says "Excuse sent" before anything was sent,
cancelling *Automaticky* leaves the dropdown showing *Automaticky*, the Planner shows a raw
`{reserve:g}` placeholder and a stub "how many days" dropdown, and the app tests write into
the Flutter SDK folder because they have no isolated data folder.

Open: 0 blockers, 4 original must-fix (B-M11 … B-M14) + 8 new must-fix (BR-M1 … BR-M8),
5 original should-fix (B-S1, B-S2, B-S3, B-S5, B-S6) + 6 new should-fix (BR-S1 … BR-S6),
4 notes.

Fix order: BR-M1, BR-M2, BR-M6, BR-M8 (send-path and safety tests first), then BR-M3,
BR-M4, BR-M5, BR-M7, then B-M11 … B-M14, then the should-fix items. One commit per finding,
named `Checkpoint B <ID>: …`.

### Status of the original findings

| ID | State | Checked how |
|---|---|---|
| B-B1 | **fixed** | `app_state.dart:468-472` uses `directory.keys` like `state.py:443-455`; tests `trackedSubjectsUsesDirectoryKeysNotValues`, `subjectStatesWithRealisticDirectoryDropsUntrackedSubjects`; my screenshots of Absences and Planner on the demo folder now match Flet (8 subjects, full plan) |
| B-B2 | **fixed** | `excuse_logic.dart` deleted; Today lists `s.excuseTasks()` / `s.dayExcusePlan()` (`today_live.dart:59-67`); an unknown key logs `excuse_failed` and sends nothing (`today_live.dart:40-50`); tests `absentKeyFromExcuseTasksIsNeverSent`, `dayCardSwitchSendsLessonsSeparately`. New defect on the same screen: BR-M1 |
| B-B3 | **partly** | `screenshot_parity_test.dart` removed; `tools/parity/capture_screens.dart` + `capture_flet.py` exist and run. The Flutter capture does not render the real app and the Flet side has no wizard: BR-M7 |
| B-B4 | **fixed** (tables) | `Str` and `AppStrings` deleted. Scripted compare (Python `STRINGS` / `MOBILE_STRINGS` against the maps in `l10n/strings.dart` and both ARB files): 794 keys + 7 mobile keys, cs and en, all identical; 13 `notif_*` extras as before. Leftovers: BR-M3 (format specs), BR-M5 (hardcoded "Šablona N") |
| B-B5 | **fixed** (dialog) | `widgets/safety_dialog.dart` matches `safety.py:22-78` (texts, conditions, three buttons, width 440); wired in `settings_live.dart:100-113`; the 3 Python tests ported in `safety_dialog_test.dart`; the false "Uloženo" snack is gone. Leftovers: BR-M2, BR-S4 |
| B-M1 | **fixed** | `scaffold.dart:401-629` against `app.py:328-462`: status text, dot, tooltip, update button, primary/icon refresh, spinner + cancel, sending label, both snacks, no `AppBar` |
| B-M2 | **fixed** | `scaffold.dart:232-397`: 90 px rail with labels under icons, side rail `labelType.all` + `groupAlignment 0` + badge, padding `pad+8` / `12,4`, `tok.border` divider |
| B-M3 | **fixed** | `/wizard` is a top-level route outside `ShellRoute` (`router.dart:152-169`); my capture shows no rail, bar or top bar; `wizard_chrome_isolation_test.dart` covers the mid-wizard save. Leftover: BR-S6 |
| B-M4 | **fixed** | `widgets/error_boundary.dart` reports `view (<route>)` once and shows the `status_error` card; `error_boundary_test.dart` |
| B-M5 | **fixed** | all 18 anchors placed on the same controls as Python (grep both sides); `tutorialBegin` and the floating layer in `scaffold.dart:198, 242`; one tutorial implementation; tutorial test names all present |
| B-M6 | **mostly fixed** | `grades_logic.dart`, `schedule_logic.dart`, `lesson_model.dart`, `lunch_filter.dart` deleted; `lunches_filter_test.dart` re-pointed to `core.prefsBanKeywords` / `core.isFoodBanned` / `AppState`. Leftovers: BR-S2, BR-S3 |
| B-M7 | **partly** | 425 app tests now; most files ported 1:1 (name match script, below). Missing or changed cases: BR-M8 |
| B-M8 | **fixed** | `app_state.dart:340-374` prints the three Python warnings (`pyRepr` for the key) |
| B-M9 | **fixed** | `refreshTokens()` (`app_state.dart:303-327`) from the constructor and `save()`: `STRAKALARI_THEME`, `compact_density` (pad 10 / gap 8), `core.setLanguage` + `Strings.lang` at start |
| B-M10 | **fixed** | `openMoreRoute` = `more.py:_open`; Budík entry on Android; `backTarget` / `subpageOpen` / `closeSubpage` + `PopScope` on phone layouts (`scaffold.dart:50-94, 259-285`). Small leftover in BR-S5 |
| B-M11 | **open** | not started. My screenshots confirm the list still stands (details under BR-M7 / B-M11 below) |
| B-M12 | **open** | `DateTime.now()` still in `activity_controller.dart:70, 106, 145, 212`, `activity_view.dart:229`, `lunches_view.dart:58, 293`, `timetable_controller.dart:133`, `timetable_view.dart:44`, `today_view.dart:38, 184`, `planner_view.dart:1021, 1240-1242`, `wizard_controller.dart:582` (the last five are new since the first review) |
| B-M13 | **open** | see the additions below |
| B-M14 | **open** | `error_dialog.dart:80, 112` still `(width - 128).clamp(280, 560)`; `app_widgets.dart:108` still clamps at 280 |
| B-S1, B-S2, B-S3, B-S5, B-S6 | **open** | unchanged in the code (`dialogWidth` is used only by the tutorial bubble; `saveOverride` still public in `config.dart:518, 600`; no `l10n.yaml`; `share_plus` still in `error_dialog.dart:12`; `_isoWeek` unchanged) |
| B-S4 | **fixed** | `tours.dart:115` `Icons.calendar_view_month_outlined` |

**B-M11, still to do** (from my side-by-side captures of the real app theme, cs dark and en
light, 1280 and 390 px; everything in the original table that is not listed here now
matches): Today excuse card (filled dropdown, buttons below it, *Ignorovat* as a text link,
"Absence" badge at the right instead of "Krátká absence" next to the date); section headers
(bold normal case instead of small upper-case muted); the date line beside the heading
instead of under it; Planner (small boxed stat tiles instead of the four stat cards, the
semester grid without day/month labels and legend, plan rows without "hodin", the badge
"Most · 5 dní volna" and the subject list); Lunches (day header "16.11.2026", full-width send
button, AI card without the model badge, prompt field, *Získat klíč zdarma*, *Doporučit (AI)*
enabled state and the hint lines, blacklist without "Blacklist je prázdný."); Activity
(no update card, no scope switch, stat cards show "—" where Python shows the next run
"23:45", **no *Pozastavit automatizaci* switch and no automation card**, no history filter);
Settings (underline fields, no section icons, password without "Nevyplněno" and the eye
toggle); phone layouts carry a second inner gutter on most screens (Today, More).

### New findings: must-fix

#### BR-M1 Today says "Omluvenka odeslána" the moment a send starts

- Dart: `app/lib/features/today/today_view.dart:216-220` (day card), `:333-338` (lesson
  card), `:614-618` (after the signature dialog)
- Python: `strakalari/flet_ui/views/today.py:214-231` and `:295-311` (`_send_day` / `_send`
  snack only on failure: `already_running` or `excuse_failed`); the outcome message comes
  from the worker, `strakalari/flet_ui/state_excuses.py:470-497`

`c.send()` returns `s.submitExcuse()` / `s.submitDayExcuse()`, which return `true` as soon
as the background worker is **started** (`controllers/excuses.dart:273-284`). The view then
snacks `excuse_sent` right away, before Bakaláři answered: in dry run, for an unconfirmed
post, a blocked re-send or a failure the user first reads "Omluvenka odeslána" and only
later (if at all) the real result from the worker. On the one path that cannot be undone,
the app must never claim a send it does not know about.

Correct: on `ok == true` show nothing (the worker's `lastSnackMessage` reports the outcome,
as in Python); on `false` show `already_running` when the key is in `sendingExcuses`,
otherwise `c.lastMessageOr(excuse_failed)`, like `today.py`. Same for the signature-dialog
path (`save_failed` only when the save failed). Add a widget test: with a worker that never
completes, tapping *Omluvit* shows no `excuse_sent`; with a dry-run worker the only message is
`excuse_dry_run`.

#### BR-M2 Cancelling *Automaticky* leaves the dropdown showing *Automaticky*

- Dart: `app/lib/features/settings/settings_view.dart:900-933` (`KeyedSubtree` keyed on the
  saved value), `settings_controller.dart:249-266`
- Python: `strakalari/flet_ui/views/settings/automation.py:51-79` (`_set(previous)` writes
  `control.value = value` back)

I checked it with a throwaway widget test: config `excuse_mode: confirm`, pick
*Automaticky*, answer *Zrušit* → the config stays `confirm` (correct) but the dropdown keeps
showing *Automaticky*. The `KeyedSubtree` key does not change on cancel, so the
`DropdownButtonFormField` keeps the user's pick. The user is shown a mode that is not saved.

Correct: on `'cancelled'` reset the field to the previous value (for example key the field
on a counter bumped by every commit, or use a controlled `DropdownButton` whose `value` is
the saved config). Add the test: after cancel the dropdown shows `mode_confirm`; after
*Nejdříve nanečisto* it shows `mode_dry_run`.

#### BR-M3 Python format specs are printed raw

- Dart: `app/lib/l10n/strings.dart:1677-1683` (`Strings.format` only replaces `{name}`);
  callers `features/planner/planner_view.dart:248` (`plan_buffer_note`), `:612`
  (`budget_final`)
- Python: `strakalari/flet_ui/strings.py:748-749` (`{reserve:g}`), `:819` (`{limit:g}`);
  `views/planner.py:1621`, `:1522`

The Planner intro reads "držím stranou {reserve:g} % zbývajících hodin" (en "I keep
{reserve:g}%") instead of "10 %", and every budget line "(limit {limit:g} %)". Visible in my
captures, both languages.

Correct: `Strings.format` handles `{name:g}` with the existing `gFormat` (and fails loudly,
in a test, on any other spec), so all keys are filled exactly like Python `str.format`. Add a
test that formats every key in the table with dummy values and asserts no `{` remains.

#### BR-M4 Planner "Kolik dní volna chcete" dropdown is a stub

- Dart: `app/lib/features/planner/planner_view.dart:572-590` (`final already = 0; final
  maximum = already + 0;`)
- Python: `strakalari/flet_ui/views/planner.py:1336-1350` (`already = len(term.planned_dates &
  set(term.remaining_days))`, `maximum = already + term.capacity`)

Flutter offers "Co nejvíc (0)" plus, at most, the current target; Python offers "Co nejvíc
(7)" and 1 … `min(max(maximum, current, 1), 60)` days on the demo data. The user cannot pick
a target. Correct: compute `already` and `maximum` from the term exactly as Python does and
add a widget test on the demo-like plan (label shows the capacity, the options reach it).

#### BR-M5 Planner dialogs still show a hardcoded "Šablona N"

- Dart: `app/lib/features/planner/planner_view.dart:934` (plan-all dialog), `:1117` (custom
  range dialog)
- Python: `strakalari/flet_ui/views/planner.py:907`, `:1377` (`_template_labels(named)`)

The user's template names are not shown and English users see Czech. The first dialog
(`:793`) already uses `templateLabels(named)`. Correct: use `templateLabels(named)` in both;
extend the strings test so no `'Šablona` literal exists under `app/lib`.

#### BR-M6 The app tests have no isolated data folder

- Dart: no `app/test/flutter_test_config.dart`; e.g. `app/test/safety_dialog_test.dart:39-53`
  deletes `core.historyPath()` and `:82` writes to it, many tests build `AppState()`
- Python: `tests/conftest.py:5-16` (autouse fixture: `STRAKALARI_DATA_DIR` = a tmp folder,
  `STRAKALARI_NO_KEYRING=1`)

Without an override, `getUserDataDir()` resolves next to `Platform.resolvedExecutable`
(`helpers.dart:20, 66-80`), which under `flutter test` is the Flutter SDK's
`bin/cache/artifacts/engine/windows-x64/` folder. The suite left `config.json` (test values,
e.g. `novak`), `config.json.lock` and `secret.key.lock` there; my own run of the suite wrote
to it too. No real data was touched on this PC, but on a machine where that folder is not
writable the code falls back to `%LOCALAPPDATA%\Strakalari`, the installed app's real data
folder, and these tests would overwrite its `config.json` and delete its automation history.

Correct: add `app/test/flutter_test_config.dart` whose `testExecutable` gives every test a
fresh temp folder via `setEnvironmentOverride({'STRAKALARI_DATA_DIR': …,
'STRAKALARI_NO_KEYRING': '1'})` (and clears it afterwards), like `conftest.py`; add a test
that fails if `getUserDataDir()` is not under the system temp folder during tests; delete
the three stray files from `~/flutter/3.44.8/bin/cache/artifacts/engine/windows-x64/`.

#### BR-M7 The screenshot tools do not show the real app (rest of B-B3)

- Dart: `tools/parity/capture_screens.dart:24-26` (hardcoded `C:/Users/matou/...`),
  `:103-127` (`ThemeData.dark/light(useMaterial3: true)`, `config.set('theme' | 'language')`
  **after** `AppState()` so `refreshTokens()` never sees it, no `debugShowCheckedModeBanner:
  false`, no localization delegates)
- `tools/parity/capture_flet.py:22-27, 90-93` (no wizard capture)
- Plan: PLAN §4 phase 6 "Done when"

Result: every Flutter "light" image shows dark cards and white text on a light page and
unreadable rail labels, the accent is Material's purple instead of `tok.accent`, a DEBUG
ribbon covers the refresh button, and `build/parity-screens/flet/` has no `wizard-*` images.
When I rendered the same screens through `tok.toThemeData()` (as `main.dart` does) with a
demo folder generated per language and theme, light mode looked right, so the defect is in
the tool, not in the app.

Correct: build exactly what `MyApp` builds (theme, dark theme, mode, locale, delegates, no
banner) around `buildRouter()`; generate the demo folder per language **and theme**
(`demo_data.py generate DIR --lang L --theme T`) before constructing `AppState`; take the
font folder from the environment (`FLUTTER_ROOT` or `~`); capture the Flet wizard (a fresh
folder without credentials); then list every remaining difference in STATUS.md (B-M11).

#### BR-M8 Test ports still missing or changed (rest of B-M7)

Matched by script (every pytest case name against every Dart test name), then read:

| Python | Dart now | Needed |
|---|---|---|
| `tests/test_timetable_cache_merge.py:83, 91` `TestDryRunNeverMarksExcused` (send path) | none; STATUS item 79 still "Deferred (phase 5)" | port both: a dry-run worker leaves `excuseLog` empty for `submitExcuse` and `submitDayExcuse` |
| `tests/test_excuse_history.py:158-185` `TestHistoryCoverage` (3, the UI coverage wrapper) | none; item 19 "Deferred (phase 5)" | port against `taskCoveredByHistory` / `AppState` |
| `tests/test_planned_skips.py:20, 40, 59` (custom skip persist failure, unplan stale, custom-skip rollback) | none | port against `AppState` |
| `tests/test_wizard_setup.py:420` `test_ai_connection_test_path` | none (`wizard_setup_full_test.dart` says "36/36") | port against `AppState.testConnection('ai', …)` with a fake |
| `tests/test_wizard_setup.py:260` `test_scheduler_skips_refresh_while_setup_pending` | none; the window scheduler (`app.py:_register_jobs`) is not ported yet | list as **Deferred (phase 7)** with that reason; Checkpoint C checks it |
| `tests/test_mobile.py:415` `test_phone_timetable_grid_scrolls_sideways` | none | port (PLAN names this behaviour) |
| `tests/test_mobile.py:437-443` `test_every_screen_builds` (9 routes, page 390×844, asserts no `report_error`) | `everyScreenBuilds` runs at **1280×800** (so `/more` redirects and no phone layout is built) and only checks `takeException` | run at 390×844 and also assert `state.lastError == null` |
| `tests/test_mobile.py:353` `test_refresh_ticks_repaint_only_the_topbar` | none | Dropped (Flet repaint counting) is acceptable, but list it under *Dropped* |
| `tests/test_wakeup_and_widget.py:476, 504, 525, 583, 603, 622, 638, 660` (8 `TestWakeupUI` cases) | none (`wakeup_ui_test.dart` says "12/12"; Python has 22 cases in the three classes) | port the UI ones (minutes texts, settings card day, restore buttons, today card evening before / on its day, planner changes reach the phone); `open_clock_reports_a_failure` and `a_later_alarm_goes_to_the_clock_on_its_weekday` may be **Deferred (phase 8)** if they need the real bridge, with the reason |
| `tests/test_i18n.py:28-59` `TestI18nKeys` + `test_dead_keys_removed_and_live_keys_kept` (2) | none; item 30 "Deferred (phase 5)" | port as a key audit on `Strings` (the B-B4 table test covers part of it) |
| `tests/test_open_url.py:32-36` `test_open_url_falls_back_to_webbrowser` | `openUrlFallsBack` asserts the **opposite** (no fallback, `false`) | port the fallback (`components.py:80-102`: if the first launch fails, open with the platform default) and test that it is used; `catch (_) { return false; }` in `open_url.dart` stays only for the second attempt |
| `tests/test_open_url.py:45-66` `test_click_handlers_are_coroutine_functions`, `test_helper_itself_is_coroutine` | none | Dropped is acceptable (Dart futures run without `await`), but list them under *Dropped* with these real names; STATUS invents `test_open_url_ast_inspection` / `test_open_url_controls_are_safe` |
| `tests/test_ui_views.py:131, 147, 162, 288, 319` (Flet container reuse, stale method reply, scroll restore) | none | Dropped is acceptable; list them under *Dropped*, and add one widget test that a scrolled screen keeps its offset across an `AppState` emit (the behaviour those tests protect) |

### New findings: should-fix

- **BR-S1** `app/lib/features/wizard/wizard_view.dart:107-129` (commit `10238fc`): the nav
  row switches to the stacked phone layout below 620 px of card width; the card is at most
  640 px including padding (`:140`), so desktop always gets the phone layout (full-width
  *Pokračovat*). Python (`views/wizard.py:848-859`) uses the stacked layout only when
  `narrow`, and a ~600 px responsive card (`:874-880`). Unlisted deviation: revert to
  `if (narrow)` and fix the overflow that motivated it by matching Python's card width.
- **BR-S2** `app/lib/features/common/format.dart`: `parseCzDate`, `shortTime`,
  `teacherSurname`, `clampWakeupMinutes`, `roundHalfEven` duplicate core functions
  (`models.dart:19`, `storage/helpers.dart:1027, 1035`, `wakeup.dart:139`) with small
  differences (e.g. `D.M.YY` handling, `null` → `''`); `weekMonday` (`:90`) steps with
  `Duration`. Use the core functions (`addDays` for `weekMonday`).
- **BR-S3** Two token tables remain: `features/common/app_tokens.dart` (`AppTokens`) and
  `shell/theme.dart` (`Tokens`), both now carried by `AppState` (`tok` / `appTokens`). Values
  are identical today; the Checkpoint B sign-off asked for one.
- **BR-S4** `app/lib/widgets/safety_dialog.dart:132` `barrierDismissible: true`; Python's
  dialog is `modal=True` (`safety.py:67`). Same result (cancel) but a stray tap outside
  dismisses the safety warning. Use `false`.
- **BR-S5** `app/lib/features/more.dart:50` adds `EdgeInsets.all(t.pad)` inside the shell's
  own padding; Python's More list has none (`views/more.py:52`). Double gutter on the phone.
- **BR-S6** The wizard route outside the shell (`router.dart:152-169`) no longer pops the
  queued error dialog or `lastSnackMessage`; Python's wizard branch calls
  `_maybe_show_error()` (`app.py:586`). Low practical impact (automation waits for setup),
  but move the popup/snack handling into a widget both the shell and the wizard use.

### Notes

- **BR-N1** `submitDayExcuseOverride` (`controllers/excuses.dart:60-71, 414-415`) is a new
  test seam in production code, like the existing `excuseTasksOverride`; list it under
  Deviations with B-S2's `saveOverride`.
- **BR-N2** The window's periodic refresh (`app.py:_register_jobs`, with the
  `setup_pending` / `refresh_running` / demo gates) has no Flutter counterpart yet; only the
  tray loop exists (`platform/desktop/tray.dart:264-360`). Phase 7 work; Checkpoint C must
  verify the setup-pending gate and port `test_scheduler.py` / `test_scheduler_retry.py`
  window cases.
- **BR-N3** `today_live.dart:28-34` passes the template only when the plan has an absence
  excuse, so `excuseLog` records `''` for days with only late/early lessons (Python records
  the picked text). In-memory only; fix together with BR-M1 by passing the picked template.
- **BR-N4** `controllers/excuses.dart:1-7` header still says the sends are "stubs …
  unimplemented until phase 7"; the worker is ported.

### B-M13 additions (STATUS.md claims that are not true)

- "B-M6 (`faa1a77`)": the commit is `bea1935`.
- B-M7 bullets: `wakeup_ui_test.dart` "12/12", `mobile_narrow_shell_test.dart` "full port …
  10/10", `wizard_setup_full_test.dart` "full port … 36/36", `open_url_test.dart` "3/3"
  with invented dropped names (BR-M8); "total 405" (the suite has 425).
- *Dropped* still lists only the four Checkpoint A items although B-M7 drops 8 tests.
- The header (lines 18-29) and the Checkpoint B section still say phases 5–6 are complete
  and "fully implemented", "10 Flet vs Flutter parity screenshots captured",
  "`app_state_lunches_test.dart` (25 tests covering `test_lunches.py`,
  `test_lunch_matching.py`)", "242 passed".
- The test map still says "Deferred (phase 5/6)" in items 17, 19, 21, 30, 40, 50, 51, 53,
  56, 67, 79, 81 and 87, most of which are now ported (or are BR-M8).

### What I verified in this re-review, and how

Flutter 3.44.8 / Dart 3.12.2, Windows 11 (Europe/Prague), `STRAKALARI_NO_KEYRING=1` for every
run, demo folders only. Two throwaway widget tests (the BR-M2 probe and a real-theme capture)
were written to `app/test/`, run once and deleted; `git status` was clean before this commit.
`build/parity-screens/{demo-cs,demo-en,flet,flutter}` (untracked) were regenerated with the
branch's own tools.

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / 764 passed, 2 skipped (Linux-only `flock` probe, POSIX permission bits) |
| `flutter analyze` / `flutter test` (app) | clean / 425 passed, 1 skipped (APK scan needs `STRAKALARI_APK`) |
| Python suite | 1643 passed |
| `tools/parity/dump.py` + `git diff --exit-code` on `test/parity/` | clean |
| Each original finding | read the fixing commit and the code it changed against the Python lines named in the finding (table above) |
| Strings | scripted compare of `STRINGS` / `MOBILE_STRINGS` with the Dart maps and both ARB files (B-B4 row); grep for Czech literals under `app/lib` (BR-M5) |
| Tutorials | anchor keys grepped on both sides: same 18, same controls |
| Test parity | `pytest --collect-only` per file; a script matched every Python case name to the Dart tests; misses read one by one (BR-M8); the 3 safety-dialog tests read side by side with `test_automation_safety.py:160-198` |
| Test integrity | `git diff 645eb97..HEAD -- app/test packages/strakalari_core/test`: the 90 removed `expect` lines are the `Str.t` → `Strings.get` rename and the lunch-filter cases moved to core functions (re-added); no `skip:` added; new `isNotNull` only on presence checks; `try`/`catch` only in tear-downs; one inverted test (`openUrlFallsBack`, BR-M8) |
| Scope | no new or renamed config keys in the changed code (script against `config.example.json` and the Python sources); one unlisted layout change (BR-S1) |
| §3.5 | changed code: regexes in `lunches_format.dart` match `views/lunches.py:27, 84-85`; `~/` only on non-negative seconds; weekday indexing correct; no `DateTime.parse`, no `jsonEncode`; `DateTime.now()` sites in B-M12 |
| Fail loudly | the three new `catch (_)` blocks (`refreshTokens`, `openUrl`, error boundary report) mirror Python `except Exception: pass`; `save()` now warns (B-M8) |
| Architecture | no `package:flutter` in `packages/strakalari_core`; no build_runner / `*.g.dart`; no dependency or lockfile change since the review; Flutter 3.44.8 + `--enforce-lockfile` in `dart.yml` |
| Hygiene | no `config.json`, `data_cache.json`, `log.txt`, `htmls/`, `*.key`, `*.jks` in the 15 commits; test hosts are config values only (`skola.bakalari.cz`, `example.com`, `b.example.cz`, 127.0.0.1); no upstream for `flutter-migration`; all commits by DeNdlerX, none with `Co-Authored-By` / `Claude-Session`; the capture tool hardcodes the owner's home path (BR-M7) |
| `main` ported | `main` = `0ffdcff`, an ancestor of `HEAD`; `strakalari/`, `tests/`, `config.example.json` unchanged against `main` |
| Screenshots | Hermes's tools: 80 Flutter + 68 Flet images (no Flet wizard). Because the tool's light images are wrong (BR-M7), I also rendered all 10 screens through the app's real theme (cs dark, en light, 1280 and 390 px; 40 images) and compared them with the Flet set as side-by-side sheets: Today, Timetable, Absences, Planner, Lunches, Activity, Settings, More and the wizard. Rail labels in the test renderer show as bars (a font the test engine lacks), not an app defect |
| BR-M2 | throwaway widget test: config stays `confirm`, the field still shows *Automaticky* after cancel |

**Not verified in this re-review:** the phase 7–9 code (Checkpoints C and D).

---

## Re-review 2 (2026-11-11)

Reviewed at `c3521aa`, commits `8ca2a1b..c3521aa` (5 commits since the re-review commit
`4ff7600`: BR-M6, BR-M1, BR-M2, the first row of BR-M8, and a STATUS.md update). STATUS.md's
Next step says the rework stopped part-way again: every other open finding was not attempted.

### Verdict: **FAIL**

Three of the four fixes hold: the app tests now each get their own throwaway data folder
(BR-M6), the Today screen no longer says "Omluvenka odeslána" when a send has only started
(BR-M1), and the two dry-run send-path tests are ported (BR-M8 row 1). The fourth, BR-M2,
works only inside its own test: on the real Settings screen, cancelling *Automaticky* still
leaves the dropdown showing *Automaticky* (proved below). Everything else from the re-review is
still open.

Open: 0 blockers; must-fix B-M11, B-M12, B-M13, B-M14, **BR-M2 (reopened)**, BR-M3, BR-M4,
BR-M5, BR-M7, BR-M8 (11 of its 12 rows); should-fix B-S1, B-S2, B-S3, B-S5, B-S6, BR-S1 …
BR-S6 and the new BR2-S1; notes below.

Fix order: BR-M2 first, then the rest of BR-M8, BR-M3, BR-M4, BR-M5, BR-M7, B-M11 … B-M14,
then every should-fix item. One commit per finding, named `Checkpoint B <ID>: …`. **Do not
stop for re-review before every finding is fixed** (or answered under *Questions* in
STATUS.md): this is the second partial rework, and each partial round costs a full review.

### Status of the findings worked on in this round

| ID | State | Checked how |
|---|---|---|
| BR-M6 | **fixed** (data folder) | `app/test/flutter_test_config.dart:13-33` gives every test a fresh `STRAKALARI_DATA_DIR` under the system temp folder plus `STRAKALARI_NO_KEYRING=1`, like `tests/conftest.py:5-16`; `test_data_dir_isolation_test.dart` checks it; the three stray files in `~/flutter/3.44.8/bin/cache/artifacts/engine/windows-x64/` are gone, and my full `flutter test` run left nothing new there. No test uses `setUpAll`, so nothing runs before the isolation. Leftover: BR2-S1 |
| BR-M1 | **fixed** | `today_view.dart:217-222, 336-341` snack only on `!ok` (`c.lastMessageOr(excuse_failed)`), `:619` only on a failed signature save, like `today.py:214-231, 295-311`; `today_live.dart:39-41, 58-60` show `already_running` when the key is in `sendingExcuses`; `today_controller.dart:609-612` falls back to `excuse_failed` only when `onSend` gave no reason. No `excuse_sent` is left in the Today code (the only use is the worker, `controllers/excuses.dart:541`, = `state_excuses.py:480`). Tests `startedSendNeverClaimsExcuseSent` / `refusedSendShowsFailureNotSent` (`today_live_test.dart:222-282`). The requested dry-run case is not a widget test, but `dry_run_send_test.dart` asserts the worker's only message is `excuse_dry_run` and the view says nothing on a started send, so together they cover it: accepted |
| BR-M2 | **not fixed (reopened)** | see below |
| BR-M8 row 1 | **fixed** | `dry_run_send_test.dart` ports `TestDryRunNeverMarksExcused` (`tests/test_timetable_cache_merge.py:83, 91`) through the real `submitExcuse` / `submitDayExcuse` and worker with a dry-run app (`_dry_worker`, `:46-62`); it asserts `excuseLog` stays empty (Python's check) and also that the message is `excuse_dry_run`. STATUS item 79 updated. The other 11 rows of the BR-M8 table are open |

### BR-M2 reopened: the fix does not reach the real Settings screen

- Dart: `app/lib/features/settings/settings_controller.dart:249-261` (`modeRevision`),
  `settings_view.dart:901, 918` (the keys), `settings_live.dart:96-121` (`build`)
- Python: `strakalari/flet_ui/views/settings/automation.py:51-79` (`_set(previous)` writes the
  old value back into the control)
- Test: `app/test/settings_sections_test.dart:201-234`

`modeRevision` lives on the `SettingsController`, but the live screen builds a **new**
`SettingsController` on every rebuild (`settingsControllerFor(s, …)` inside
`_LiveSettingsViewState.build`), so on the real screen `modeRevision` is always 0. After
*Zrušit* nothing is saved, the key stays `tree:rule:excuse_mode:confirm:0`, Flutter keeps the
old `DropdownButtonFormField` state, and the dropdown keeps showing *Automaticky* while the
saved mode is *Potvrzovat*. The new test passes only because it keeps one controller alive
in a `StatefulBuilder`, which the real screen never does.

Proved with a throwaway widget test against `LiveSettingsView` with `appStateProvider`
(written to `app/test/`, run once, deleted): config `excuse_mode: confirm`, signature set,
pick *Automaticky*, then
- *Zrušit* → config `confirm`, dropdown shows *Automaticky* (wrong);
- *Nejdříve nanečisto* → config `dry_run`, dropdown shows *Jen nanečisto* (right, because the
  saved value changed the key).

Correct: keep the revision where it survives a rebuild (for example a counter on `AppState`
or in `_LiveSettingsViewState`, handed to `settingsControllerFor`), or make the picker a
controlled `DropdownButton` whose `value` is always the saved config. Then rewrite the two
tests against `LiveSettingsView` + `appStateProvider` (the harness in
`settings_live_test.dart`), not a hand-held `SettingsController`: after *Zrušit* the
dropdown shows `mode_confirm`, after *Nejdříve nanečisto* `mode_dry_run`, for both
`excuse_mode` and `strava_order_mode`.

### New finding: should-fix

- **BR2-S1** 22 app test files still call `setEnvironmentOverride({'STRAKALARI_DATA_DIR':
  …})` in their own `setUp` (for example `settings_live_test.dart:18`,
  `today_live_test.dart:19`, `mobile_narrow_shell_test.dart:31`, `tutorial_test.dart:35, 83`).
  That runs after the `flutter_test_config.dart` `setUp` and **replaces** the whole
  environment map, so those tests run without `STRAKALARI_NO_KEYRING=1` (and without the rest
  of the process environment). Harmless today, because the app never sets `keyStoreBackend`
  and the core then refuses to use any key store (see BR2-N1), but BR-M6 asked for "every
  test", like `conftest.py`. Correct: delete the per-file data-folder overrides (the shared
  config already gives each test its own folder; use `getUserDataDir()` where a test needs
  the path), or add `'STRAKALARI_NO_KEYRING': '1'` to each of them.

### Notes

- **BR2-N1 (for Checkpoint C)** `DesktopKeyStore`
  (`app/lib/platform/desktop/keystore_desktop.dart:58`) is never assigned to
  `keyStoreBackend` anywhere in `app/lib` (grep finds no `keyStoreBackend =`). On a desktop
  install the Flutter app would therefore fail with `KeyStoreUnavailable` instead of reading
  the Python app's Fernet key from the OS credential store, so it could not decrypt the saved
  passwords after an update. This is phase 7 work and fails closed (no data loss), but
  Checkpoint C must check that the key store is wired at start-up and that the over-install
  test reads the Python key.
- The earlier notes (B-N1 … B-N4, BR-N1 … BR-N4) are unchanged and still apply.

### What I verified in this re-review, and how

Flutter 3.44.8 / Dart 3.12.2, Windows 11 (Europe/Prague), `STRAKALARI_NO_KEYRING=1` for the
core and Python runs; the app suite ran without it on purpose, to check that
`flutter_test_config.dart` sets it. Demo data only; no server was contacted. One throwaway
probe (BR-M2) was written to `app/test/`, run once and deleted; `git status` was clean before
this commit.

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / 764 passed, 2 skipped (Linux-only `flock` probe, POSIX permission bits) |
| `flutter analyze` / `flutter test` (app) | clean / 432 passed, 1 skipped (APK scan needs `STRAKALARI_APK`); 432 = 425 + the 7 new tests |
| Python suite | 1643 passed |
| `tools/parity/dump.py` + `git diff --exit-code` on `test/parity/` | clean |
| Each fix | read the commit against the Python lines named in the finding (table above); BR-M2 probed on the live screen |
| Test parity | the 2 new dry-run tests match `TestDryRunNeverMarksExcused` case for case; the rest of the BR-M8 table is unchanged (no other port in this round) |
| Test integrity | `git diff 4ff7600..HEAD -- app/test packages/strakalari_core/test`: only added lines, no `skip:`, no loosened `expect`, no `try`/`catch` around assertions (the one `on FileSystemException {}` is the temp-folder clean-up in `flutter_test_config.dart`) |
| Scope | no new feature, config key or UI change beyond the findings |
| §3.5 | the added Dart has no `RegExp`, `~/`, `%`, `round`, `weekday`, `DateTime.now()`, `DateTime.parse` or `jsonEncode` |
| Fail loudly | no new `catch` in send, order or save code |
| Architecture | no tracked file in `packages/strakalari_core` imports Flutter; no `pubspec.yaml`, lockfile or CI change in this round |
| Hygiene | no personal data in the 5 commits (`git ls-files` shows only the known parity fixture `test/parity/config.json`); no new test host; no upstream for `flutter-migration`; all 5 commits by DeNdlerX, none with `Co-Authored-By` / `Claude-Session` |
| `main` ported | `main` = `0ffdcff`, an ancestor of `HEAD`; `strakalari/`, `tests/`, `config.example.json` unchanged against `main` |

**Not verified in this re-review:** the screenshots (nothing changed in the screens or the
capture tools since the re-review, so B-M11 and BR-M7 stand as written), and the phase 7–9
code (Checkpoints C and D).

---

## Re-review 3 (2026-11-12)

Reviewed at `b62cfb1`, commits `2ed116f..b62cfb1` (30 commits since the re-review 2 commit
`0c5c497`: rework round 3, one commit per finding, and round 4, the visual restyle of Today,
Planner, Lunches, Activity, Settings and the shared theme).

### Verdict: **FAIL**

Almost every open finding from re-review 2 is now really fixed in the code, and five screens
(Today, Timetable, Lunches, Activity, Settings) look like the Python app in my fresh
screenshots. But this review found two new blockers and a red test suite:

- the Planner's semester grid is one day off for every date after the October clock change
  (today, Thursday 12 Nov, is outlined in the Friday row), so tapping a cell plans the day
  before the one its row names, and two other places save a holiday or plan range that
  silently loses its last day (BR3-B1);
- Activity's *Copy log* copies the raw log, while Python scrubs saved passwords and API keys
  out of it first (BR3-B2);
- `flutter test` fails today: one test depends on the wall clock and broke when its sample
  date left the 30-day excuse window on 12 Nov (BR3-M1).

Open: 2 blockers (BR3-B1, BR3-B2), 3 must-fix (BR3-M1 … BR3-M3; BR3-M2 is the rest of B-M11),
4 should-fix (BR3-S1 … BR3-S4), notes below.

Fix order: BR3-B1, BR3-B2, BR3-M1, BR3-M3, BR3-M2, then BR3-S1 … BR3-S4. One commit per
finding, named `Checkpoint B <ID>: …`. As in re-review 2: do not stop for re-review before
every finding is fixed or answered under *Questions* in STATUS.md.

### Status of the findings open after re-review 2

| ID | State | Checked how |
|---|---|---|
| BR-M2 | **fixed** | `settings_live.dart:86-130`: `_modeRevision` lives in `_LiveSettingsViewState` and is handed to every new controller; `commitMode` bumps it in `finally` (`settings_controller.dart:254-263`), so a cancel re-keys the picker (= `automation.py:51-79` `_set(previous)`). 4 tests against `LiveSettingsView` + `appStateProvider` (both pickers × cancel / dry run, `settings_live_test.dart:96-145`) assert the saved value and the shown text |
| BR-M3 | **fixed** (placeholders) | `Strings.format` fills `{name:g}` and throws on other specs (`strings.dart:1678-1693`); a test formats every key in both languages and finds no `{`. The `g` formatting itself is not Python's: BR3-S1 |
| BR-M4 | **fixed** | `planner_view.dart:1014-1043` = `planner.py` `_target_dropdown` (`already`, `maximum`, `top`, `min(top, 60)`, value fallback 0); two widget tests |
| BR-M5 | **fixed** | both dialogs use `templateLabels(named)`; a test forbids `Šablona` under `lib` |
| BR-M7 | **fixed** | `capture_screens.dart` builds what `MyApp` builds (theme from `appState.tok`, locale, delegates, no banner), one demo folder per language and theme written before `AppState()`, SDK fonts from `FLUTTER_ROOT`; `capture_flet.py` + `serve_wizard.py` capture the Flet wizard. I re-ran both (80 + 76 images, below). Leftover: BR3-S3 |
| BR-M8 rows 2–4, 10 | **fixed** | `TestHistoryCoverage` (3), the 3 planned-skip cases, `aiConnectionTestPath` and the `open_url` fallback read case by case against `test_excuse_history.py:158-180`, `test_planned_skips.py:20-77`, `test_wizard_setup.py:420`, `test_open_url.py:32-36`. `openUrl` also falls back when `launchUrl` returns false (url_launcher's way of failing): accepted, listed under Deviations |
| BR-M8 rows 6–7 | **fixed** | `phoneTimetableGridScrollsSideways` (92 px cells scroll at 390, stretch at 915; `phoneCellWidth` truncates like `int()`); `everyScreenBuilds` at 390×844 asserts `lastError == null` per route. The grid test ignores `overflowed` errors (Ahem font): accepted for that one test |
| BR-M8 row 9 | **fixed** | `wakeup_settings_card_test.dart` (9) + `wakeup_ui_test.dart` (8): all 16 `TestWakeupUI` functions of `test_wakeup_and_widget.py:458-694` present, read side by side, fixed clock; `settings/wakeup_card.dart` has every part of `_wakeup` |
| BR-M8 rows 5, 8, 11–13 | **fixed** | row 5 Deferred (phase 7) with the reason; rows 8, 12, 13 under *Dropped* with the real names; `newFletStringsPresent` / `deadKeysRemovedAndLiveKeysKept` = `test_i18n.py:28-56` (same key lists); `scroll_keeps_offset_test.dart` |
| B-M11 | **partly** | Today, Timetable, Lunches, Activity, Settings now match (screenshots below). Planner: BR3-B1. Absences, Marks, wizard: BR3-M2 |
| B-M12 | **fixed** | no `DateTime.now()` in `app/lib` except the single-instance token seed (see BR3-N2); `no_wall_clock_test.dart` guards it |
| B-M13 | **mostly fixed** | the listed map lines now name real tests (my name-match script agrees for items 17, 19, 21, 30, 38, 40, 50, 51, 53, 56, 67, 79, 81, 87 and `TestNarrowShell`). Two other map lines are still wrong: BR3-M3 |
| B-M14 | **fixed** | `dialogWidth` = `int(max(240, min(preferred, width - 64)))`; both error dialogs use it |
| B-S1, BR-S4 | **fixed** | widths 520 / 380 / 440 via `dialogWidth`; signature and safety dialogs `barrierDismissible: false` |
| B-S2 | **fixed** | `@visibleForTesting` (`package:meta`, already in the lockfile; `flutter pub get --enforce-lockfile` passes) |
| B-S3 | **fixed** | test: every ARB key equals `Strings.get`; my script: both ARB files, `Strings` (desktop and mobile, cs and en) and Python `STRINGS` / `MOBILE_STRINGS` are identical (794 + 7 mobile keys; the known 13 `notif_*` extras) |
| B-S5 | **closed** | the owner kept *Share* (STATUS Questions, 2026-11-11); accepted as a listed deviation |
| B-S6 | **fixed** for `_isoWeek` | but the same `Duration(days: …)` stepping is in nine more places: BR3-B1 |
| BR-S1 | **fixed** | stacked nav only when `narrow`; card width follows the `ResponsiveRow` columns (615 vs Flet 604 px at 1280). Vertical alignment differs: BR3-M2 |
| BR-S2 | **mostly fixed** | `parseCzDate`, `shortTime`, `teacherSurname`, `clampWakeupMinutes` delegate to core; leftovers in BR3-S2 and BR3-B1 (`plan_reserve.entryDays`) |
| BR-S3, BR-S5, BR-S6, BR2-S1 | **fixed** | `AppTokens` is a `typedef` of `Tokens`; More has no inner gutter; `popPendingMessages` shared by shell and wizard route; every per-file data-folder override also sets `STRAKALARI_NO_KEYRING` (grep: none without it) |

### New findings: blockers

#### BR3-B1 Calendar days are stepped in 24-hour units: wrong Planner grid after the clock change, ranges that lose their last day

- Dart (all are `DateTime(...)` local midnights moved with `Duration(days: …)`):
  - `app/lib/features/planner/planner_view.dart:553-559, 580-583, 627, 631-636, 678` (semester
    grid, wide and phone), `:1899-1920` (custom-range dialog month grid)
  - `app/lib/features/planner/plan_reserve.dart:267-282` (`entryDays`, a second copy of the
    core's `planned_skips.dart:100` `entryDays`, used by
    `features/planner/planner_controller.dart:130, 156, 207, 237, 245, 291`)
  - `app/lib/features/settings/settings_controller.dart:385-400` (`addDayRange`, saves
    `user_free_days`)
  - `app/lib/features/settings/settings_view.dart:900` (`difference(...).inDays == 1` groups
    consecutive free days)
  - smaller: `today_controller.dart:768, 812-813, 911`, `controllers/planner.dart:296`,
    `activity_view.dart:639`, `timetable_view.dart:92`
- Python: `views/planner.py:1240-1253` and `:753-756` (`date` + `timedelta`),
  `core/planned_skips.py` `entry_days`, `views/settings/school_calendar.py:163, 208-213, 244, 259`
- Plan: PLAN §3.5 "Dates", the rule A-B1 applied to the core and B-S6 asked for here

On 25 Oct 2026 Prague leaves summer time, so `DateTime(2026, 10, 19) + Duration(days: 7)` is
**25 Oct 23:00**, not 26 Oct. From that week on every semester-grid column starts on Sunday:
the *Po* row shows Sundays, *Út* Mondays … *Pá* Thursdays, and Fridays are gone. My
screenshots (`planner-cs-dark-1280`, `planner-en-light-1280`) show it: Python outlines today
(Thursday 12 Nov) in the *Čt* row, Flutter in the *Pá* row, and every recommended day sits one
row lower. `_cell` normalises the shifted value (`_d(rawDay)`), so tapping the cell in the
*Pá* row opens the plan dialog for **Thursday**. A planned day drives automation: auto mode
cancels that day's lunch and the phone alarm skips it, so a user who trusts the grid gets
Thursday's lunch cancelled instead of Friday's. This is the current semester for every user
(sem 1 runs to January). The custom-range dialog shows the last October week shifted the
same way.

The same slip loses data when a range crosses a switch. Proved with a throwaway probe (run
once, deleted): `plan_reserve.entryDays({'start_date': '2026-10-23', 'end_date':
'2026-10-30'})` returns `23 24 25 25 26 27 28 29` (25 Oct twice, 30 Oct missing), and
`addDayRange` from 23.10.2026 to 30.10.2026 saves 23.10 … 29.10: **Friday 30 Oct is not saved
as a day off**, so the planner and the forecast count it as a school day. In spring (29 Mar)
the 23-hour day makes `addDayRange` drop the last day too and the settings list split one
range into two (`inDays == 0`).

Correct: step calendar days only with `core.addDays` and measure them with
`core.daysBetween` (as `ade6e4a` did for `_isoWeek`), everywhere in `app/lib`; delete
`plan_reserve.entryDays` and use the core's `entryDays`. Add a guard test like
`no_wall_clock_test.dart` that fails on `Duration(days` in `app/lib` (allow only real
durations, if any, by name), and DST tests under `withClock`: the semester grid on
12 Nov 2026 shows today in the *Čt* row and Friday 13 Nov in the *Pá* row (wide and phone);
the custom dialog's October 2026 month; `entryDays` and `addDayRange` for 23.10–30.10.2026
and 26.3–2.4.2027; the settings grouping across 29 Mar.

#### BR3-B2 *Copy log* on Activity copies passwords that Python scrubs

- Dart: `app/lib/features/activity/activity_view.dart:762-778`
  (`copyAppText(c.logLines.join('\n'))`)
- Python: `strakalari/flet_ui/views/activity.py:437-442` (`redacted_log_tail`: the last 200
  lines, each through `core.error_report.redact_text(line, cfg)`), used at `:483`; test
  `tests/test_error_report.py:104-117` (`test_activity_log_copy_redacts_secrets`)

The live log is not only clean core output: `report_error` appends the last 25 traceback lines
to it unredacted, in both apps (`state_activity.py:63-67`, `controllers/activity.dart:60-71`),
and an exception text can carry the password (the Python test's example: `login with
hunter2-hunter2 failed`). Python therefore copies the log only in redacted form ("the only form
logs may be copied in"). Flutter copies everything, up to 500 lines. The copied log is what a
user pastes into a support chat or a GitHub issue. The Python test was not ported and is not
listed as dropped (see BR3-M3).

Correct: port `redacted_log_tail` (last 200 lines, the core's `redact_text` port with
`config.data`, per line) and use it for the copy button; port
`test_activity_log_copy_redacts_secrets` against it (password gone, `***` present, other text
kept).

### New findings: must-fix

#### BR3-M1 The app suite is red: a test depends on today's date and checks less than Python

- Dart: `app/test/wakeup_ui_test.dart:126-171` (`wholeDayExcuseListsLessonsInAFoldedSection`)
- Python: `tests/test_wakeup_and_widget.py:411-429`

My `flutter test`: **468 passed, 1 failed, 1 skipped**. The test builds a real `AppState` with
absences on 12.10.2026 and no fixed clock; on 12 Nov 2026 that day left the 30-day excuse
window (`EXCUSE_WINDOW_DAYS = 30`), the Today screen correctly shows no card, and
`find.byType(ExpansionTile)` finds nothing. Proved with a probe: under `withClock` on 11 Nov
it finds 1 tile, on 12 Nov 0. It also asserts less than Python: Python injects the two tasks,
then checks there is **exactly one** tile, that it is **collapsed**, that its title is *Nebo
jednotlivě (2 hodiny)* / *Or one by one (2 lessons)*, and that the **tile** is expanded after
`set_day_expanded`; the Dart test checks `findsWidgets` and then only the controller's flag.

Correct: run it under `withClock` (or inject the tasks like Python) and assert the four Python
checks on the tile itself. Then look through every app test that hard-codes a calendar date
without `withClock` (for example `phase6_features_test.dart`, `stable_change_signals_test.dart`,
`timetable_live_test.dart`, `rail_and_scaffold_test.dart`, `plan_picker_test.dart`,
`settings_sections_test.dart`) and pin the clock wherever the result depends on "today", so
the suite stays green next week.

#### BR3-M2 Remaining screen differences (rest of B-M11)

From my fresh side-by-side captures (both sets taken tonight within minutes, every screen,
cs/en, dark/light, 1280 and 390 px). Everything not listed here now matches, apart from
BR3-B1 and the accepted items in the notes.

| Screen | Python (Flet) | Flutter now | Dart / Python lines |
|---|---|---|---|
| Absences | each row shows the percentage right of the bar ("21.4 %"), track 140 px | bar only, 120 px: **the per-subject absence percentage is not shown anywhere** | `absences_view.dart:208-224` / `components.py:244-280` (`meter`: fixed-width right-aligned `f"{value_pct:.1f} %"`) |
| Absences | date line under the title (`header_row(…, state.updated_label)`) | none | `absences_view.dart:41` / `views/absences.py:16` |
| Absences | stat values coloured by kind (average accent, critical green when 0) | plain text colour | `absences_view.dart:130` / `absences.py:31-33` (`C.stat_card(..., kind=…)`): use the shared `StatCard` |
| Marks | date line under the title | none | `marks_view.dart:207` / `views/marks.py:928, 972` |
| Marks | four stat cards fill the width | fixed 150 px cards | `marks_view.dart:295` |
| Marks | *Auto* segment has the `AUTO_AWESOME_OUTLINED` icon | no icon | `marks_view.dart:224, 1059` / `marks.py:165` |
| Wizard | card at the top of the page | card centred vertically | `wizard_view.dart:134` (`Center`) / `views/wizard.py:880-883` (`MainAxisAlignment.START`) |
| Wizard | the chosen language is a filled primary button | a greyed, disabled-looking button (`onPressed: null`) | `wizard_view.dart:203-218` / `wizard.py:450-459` (primary button with a no-op handler) |
| Wizard | the current step's dot is yellow | blue | `wizard_view.dart:171-180` / `wizard.py:842` + `components.py:782-792` (`working` = `tok.yellow`) |
| Timetable | 4 px gap between the lesson cells of a row | cells touch | `timetable_view.dart` grid row |

Correct: port each item from the Python lines named; then re-capture and list in STATUS.md
only the differences you keep, each with its reason.

#### BR3-M3 Error-report and quiet-save tests: missing ports and wrong map lines

- `tests/test_error_report.py` (26): STATUS item 16 says the "remaining 9" UI cases are in
  `app_state_excuses_and_planner_test.dart`, but it names 6 tests, and these Python cases have
  no Dart test and are not under *Dropped*: `test_activity_log_copy_redacts_secrets` (BR3-B2),
  `test_user_error_marks_report_friendly` (`:122`), `test_regular_error_has_no_user_message`
  (`:131`), `test_shell_pops_queued_error_once` (`:364`, the shell shows the queued dialog
  once and not on the next render), `test_report_is_persisted_redacted_to_stderr` (`:446`,
  `Error report:` and `operation: excuse` printed, the password not). Port them against
  `AppState` / `AppScaffold`. `test_copy_text_does_not_mount_clipboard_into_overlay` (`:298`)
  tests a Flet overlay mechanism: list it under *Dropped* with that reason.
- `tests/test_settings_quiet_save.py` (6): item 66 says 6 ports, but
  `test_save_quiet_persists_without_render` is ported against `SettingsController`, not
  `AppState.saveQuiet` (`app_state.dart:373-381`, the code the Python test covers, which has no
  test at all), and `test_save_quiet_does_not_mute_other_threads` was replaced by a different
  test (`save quiet reports failure`). Port the first against `AppState` (no emit, config
  listeners still called, a plain `save` emits once); list the second under *Dropped* (a Dart
  isolate has one thread, so no emit can land inside a synchronous quiet save) or port an
  equivalent; keep the extra test under its own name.
- Fix items 16 and 66 of the test map to match.

### New findings: should-fix

- **BR3-S1** `app/lib/features/common/format.dart:106-113` `gFormat` is not Python's `:g`
  (6 significant digits, exponent form from 1e6 and below 1e-4). Probe: 33.3 − 10 →
  `23.299999999999997` (Python `23.3`), 66.66666666666667 → `66.66666666666667` (`66.6667`),
  1234567 → `1234567` (`1.23457e+06`). It formats `{reserve:g}`, `{limit:g}`, the Absences
  limits, mark bands and the needed percentage. Most values are rounded to 0.1 before they
  get there, so users rarely see it. Port `format(x, 'g')` exactly and test it against a table
  of values produced by Python.
- **BR3-S2** Leftover duplicates: `roundHalfEven` (`format.dart:117`); three weekday-name
  tables (`format.dart:16`, `app_widgets.dart:37`, `planner_view.dart:1418-1435`) where Python
  has one (`components.py:186-187`). `tintColor` (`app_tokens.dart:13-21`) and the budget-bar
  shares (`planner_view.dart:1063`) round half away from zero; Python `round()` is half to even
  (`tint(…, 0.3)`: alpha 77 instead of 76). Invisible, but use one helper for both.
- **BR3-S3** `tools/parity/capture_flet.py:51-54, 85-88` starts the Flet servers without
  `STRAKALARI_NO_KEYRING=1` and `DEMO_NO_UPDATE_BANNER=1`. Without them the Flet app may touch
  the OS credential store and checks GitHub for updates (that is where the "update available"
  button in Hermes's Flet set came from; the Flutter capture never shows it). Set both in the
  script so the capture is hermetic and the two sets compare one to one. (I set them myself for
  this review.)
- **BR3-S4** `app/lib/features/settings/settings_controller.dart:101, 117` (`save` /
  `saveQuiet`): `catch (_) { return false; }` in save code with no output, and `saveQuiet`
  writes the new value into its config map before it knows the save worked. Today `persist`
  is `AppState.save`, which prints its own warning and does not throw, so this only hides
  unexpected errors; CONTRIBUTING §5 still asks for `print('Warning: …')`, as `state.py` does.

### Notes

- **BR3-N1** Accepted differences in my captures: the Flet AI button looks enabled while
  disabled (a Flet styling quirk; both apps disable it the same way, `lunches.py:331`);
  Activity's *Další běh* is empty because the window scheduler is phase 7 (BR-N2); the version
  shows `0.0.0` vs `0.1.0` (version stamping, phase 7/9, `test_version_sync.py` deferred).
  Phone Activity puts *Obnovit data* on its own row: small, fix with BR3-M2 if cheap.
- **BR3-N2 (for Checkpoint C)** `platform/desktop/single_instance.dart:161-168` derives the
  handshake token from time, pid and user name; Python uses `secrets.token_hex(16)`. Use
  `Random.secure()`.
- **BR3-N3** `planner_view.dart:1038-1040` calls `setPlannerTarget` even when the value did not
  change; Python skips that (`planner.py` `_changed`). Harmless.
- **BR3-N4** Still open from earlier rounds: BR-N2 (window scheduler, Checkpoint C), BR-N3
  (`today_live.dart:27-34` sends `''` as the template when no job has custom text),
  BR-N4 (`controllers/excuses.dart:1-7` header still says the sends are stubs), BR2-N1
  (desktop key store not wired, Checkpoint C).
- **BR3-N5** Deviations added in this round (`openUrl` fallback incl. a `false` result,
  `Strings.format` `{name:g}` only, wizard columns, `AppTokens` typedef, ARB files unused but
  tested): accepted.

### What I verified in this re-review, and how

Flutter 3.44.8 / Dart 3.12.2, Windows 11 (Europe/Prague), 12 Nov 2026. `STRAKALARI_NO_KEYRING=1`
for the core, Python and capture runs; the app suite ran without it (its
`flutter_test_config.dart` sets it). Demo data only, nothing contacted except 127.0.0.1. One
throwaway probe (`app/test/zz_reviewer_probe_test.dart`) was run once and deleted;
`git status` was clean before this commit.

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / 764 passed, 2 skipped (Linux-only `flock` probe, POSIX permission bits) |
| `flutter analyze` / `flutter test` (app) | clean / **468 passed, 1 failed** (BR3-M1), 1 skipped (APK scan needs `STRAKALARI_APK`) |
| Python suite | 1643 passed |
| `tools/parity/dump.py` + `git diff --exit-code` on `test/parity/` | clean |
| Each open finding | read the fixing commit against the Python lines named in the finding (table above); BR-M2 by its 4 live-screen tests |
| Strings | scripted: Python `STRINGS` / `MOBILE_STRINGS` vs `Strings` (desktop + mobile, cs + en) and both ARB files: identical; no Czech literal added under `app/lib` except a copy of Python's weekday table (BR3-S2) and the alarm label `Strakaláři · …` (= `automation.py:203`) |
| Tutorials | all 18 anchor ids still present after the restyle |
| Test parity | `pytest --collect-only` (1643) name-matched against every Dart `test`/`testWidgets`/`group` name, misses read by hand (BR3-M3); `TestWakeupUI`, `TestHistoryCoverage`, planned-skip, i18n and open-url ports read side by side |
| Test integrity | `git diff 0c5c497..HEAD -- app/test packages/strakalari_core/test`: removed lines are the per-file data-dir overrides (now with `NO_KEYRING`), headings found upper-case (Python `section_header` upper-cases), `Chyba` twice on Activity (as in Python), larger test surfaces; no `skip:`, no `try`/`catch` around `expect`; one weak, clock-dependent test (BR3-M1) |
| Scope | no new or renamed config key in the changed code (every key checked against `config.example.json` and the Python sources); no feature Python lacks; *Share* is the owner's decision |
| §3.5 | added `RegExp` only in `Strings.format`; `~/` only on non-negative day counts; `round()` sites in BR3-S2; `weekday` arithmetic and `Duration(days:)` in BR3-B1; no `DateTime.now()`, `DateTime.parse` on Czech dates or `jsonEncode` added |
| Fail loudly | the two new `catch (_)` (`openUrl` fallback, Lunches `_isOpen`) mirror Python (`components.py:91-102`, `lunches.py:166-169`); BR3-S4 |
| Architecture | no `package:flutter` in `packages/strakalari_core`; no build_runner / `*.g.dart`; one dependency added (`meta`, already locked; `--enforce-lockfile` passes); Flutter 3.44.8 pinned in `dart.yml` |
| Hygiene | no personal data in the 30 commits; only `127.0.0.1` added as a host; no upstream for `flutter-migration`; all 30 commits by DeNdlerX, none with `Co-Authored-By` / `Claude-Session` |
| `main` ported | `main` = `0ffdcff`, an ancestor of `HEAD`; `strakalari/`, `tests/`, `config.example.json` unchanged against `main` |
| Screenshots | re-captured both sets tonight with the branch's tools (`capture_screens.dart`: 80; `capture_flet.py` with `STRAKALARI_NO_KEYRING=1 DEMO_NO_UPDATE_BANNER=1`: 76, Flet has no wide *More*), paired as side-by-side sheets; read all ten screens at 1280 (cs dark) and 390 (en light), plus Planner and Absences in en light 1280 |
| DST and clock probes | `entryDays` / `addDayRange` across 25 Oct; the folded-section test under a fixed clock on 11 and 12 Nov (BR3-B1, BR3-M1) |

**Not verified in this re-review:** the phase 7–9 code (Checkpoints C and D), phones and
Windows Sandbox.
