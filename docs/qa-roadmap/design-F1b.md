# F1b design note: join the Absence and Plánovač tabs

Status: **design only, no code yet.** Written 2026-11-17 after R3 PASS
(`6d4c925`) and O1 (`4eea335`).

Sources: owner's 2026-11-17 request in `STATUS.md`:
> "perhaps absence limits in the absence tab? I would also join absence and
> planner tab. They do very similar stuff"

---

## 1. What changes, in one paragraph

**Absence** and **Plánovač** merge into one **Absence** screen (`/absences`),
removing the separate **Plánovač** tab from the desktop rail (8 → 7 items) and
from the phone *More* menu (4 → 3 items, plus *Budík* on Android). The
duplicated per-subject list (previously shown once in Absence and again as
*Rozpočet hodin* in Plánovač) becomes a single unified subject list combining
each subject's current percentage with its stacked hour-budget bar, free hours,
and end-of-term projection. All existing limits editing, calendar strip,
recommended days off, custom planning, and planned-entry management remain on
this single screen.

---

## 2. Navigation, routes, and entry points

- **`shellRoutes`** (`app/lib/shell/router.dart`): remove `'planner'`.
  Order becomes `['today', 'timetable', 'absences', 'marks', 'lunches', 'activity', 'settings']` (7 items).
- **`narrowTabs`**: unchanged (`['today', 'timetable', 'marks', 'lunches', 'more']`).
- **`moreRoutes`** & **`MorePage.entries`** (`app/lib/features/more.dart:25–43`):
  remove `'planner'`. Desktop/non-Android order becomes `['absences', 'activity',
  'settings']` (3 items). In `MorePage.visibleEntries()`, replace
  `...entries.take(3)` with `...entries.take(entries.length - 1)` before
  `alarmEntry, entries.last`, so Android shows `['absences', 'activity',
  'alarm', 'settings']` (4 items) without duplicating *Nastavení*.
- **`/planner` compatibility redirect:** add
  `GoRoute(path: '/planner', redirect: (_, _) => '/absences')` in
  `buildRouter` and map `'planner'` → `'absences'` in `routeForLocation`
  (if passed directly to `AppScaffold` in tests/deep links) so any stale
  deep link or bookmark lands cleanly on `/absences` instead of falling back to
  `/today`.
- **`TodayView`** (`app/lib/features/today/today_view.dart:128`): the planner
  suggestion card's action calls `c.onGo('absences')` with label
  `Strings.get('nav_absences')`.
- **`SettingsView` → Limity**: already links to `/absences`
  (`settings:go_absences_limits`), unchanged.
- **Removed button:** *Podrobné přehledy v Absencích* (`see_absences`) is
  removed since both views are now on the same screen.

---

## 3. Unified Absence screen layout

`LiveAbsencesView` (`app/lib/features/absences/absences_live.dart`) builds both
`absencesControllerFor(s)` and `plannerControllerFor(s)` +
`yearPlanDataFor(s)` (reusing the existing `PlannerController` and
`YearPlanData` models without duplicating planner math) and passes them into
`AbsencesView`.

Top-to-bottom structure on `/absences`:

1. **Header (`HeaderRow`)**
   - Title: `Strings.get('absence_title')` (*Absence* / *Absences*), plus
     `updatedLabel`.
   - Actions:
     - *Limity* (`Key('abs:limits_btn')`, `OutlinedButton.icon`) whenever
       `createLimitsController != null` — opens `LimitsEditorContent` modal.
     - *Naplánovat vlastní volno* (`ElevatedButton.icon`, `plan_custom`) whenever
       `plan != null && hasData`.
   - On `narrow` (< 720 px): `HeaderRow` on top, followed by the action
     button(s) in a compact single row (`Expanded` side-by-side when both are
     shown, preserving P9b compactness). On `wide`: actions sit in `HeaderRow`.

2. **No-limits banner** (unchanged)
   - Shown when `!c.hasSubjectLimits && c.createLimitsController != null`:
     `abs_no_limits` with active `absence_critical_pct` + *Limity* button.

3. **Real data states (replacing separate Absence/Planner empty states)**
   - **Case 1 — no subjects (`c.subjects.isEmpty`)**: occurs when there is no
     timetable (`subjectStates()` returns `[]`) or no absence data. Show
     `EmptyState(no_data)`, plus `planner_need_refresh` when `!hasTimetable`
     and `need_credentials` when `c.demoMode` is true.
   - **Case 2 — subjects present, `term == null`** (the school year's absences
     are closed, or `plan == null` in a standalone `AbsencesView` test): show
     the 3 Absence KPI cards and unified subject cards with `w.Meter` fallback
     and today's detail line. When `plan != null && term == null`, also show
     the muted `term_nothing` card, then *Naplánované* (`planned_title`, with
     unplan so upcoming planned days that can cancel lunches stay visible and
     removable) and the calendar footer, as `PlannerView` does today (or
     `planner_need_refresh` if `plan == null && !hasTimetable`).
   - **Case 3 — active term (`plan != null && term != null`)**: show the full
     screen (term selector, `term_fresh` if `!term.hasData`, 4 KPI cards +
     summary line, warnings, calendar strip, recommended days, unified
     subjects & budgets, planned days, calendar footer). Any subject missing
     a budget row in the selected term falls back to `w.Meter` and today's
     detail line.
   - **Intro & `term_fresh`:** drop the 4-line planner intro paragraph
     (`planner_desc` + `plan_buffer_note`) from the screen (a short sentence
     about the reserve moves into `tut_abs_subject_body`), and keep the 1-line
     `term_fresh` accent note below the term buttons when `!term.hasData`.

4. **Term selector** (when `plan != null && plan.terms.length >= 2`)
   - *1. pololetí · do ...* / *2. pololetí · do ...* buttons (same compact row
     on `narrow`, `Wrap` on `wide`). Selecting a term updates both the planner
     sections and the subject budget bars/projections to match that term.
   - If `!term.hasData`, show `term_fresh` right under the term buttons.

5. **Unified KPI row (`TutorialAnchor(anchorKey: 'abs_stats')`)**
   - When `plan == null || term == null`: the existing 3 Absence KPI cards
     (*Průměrná absence*, *Varovné předměty*, *Kritické předměty*), equalized
     with `IntrinsicHeight`.
   - When `plan != null && term != null`: **4 KPI cards** (1×4 on `wide`, 2×2
     `IntrinsicHeight` on `narrow`, keeping the calendar on the first screen at
     390 px):
     1. *Průměrná absence*: `${c.average.toStringAsFixed(1)} %`
     2. *Varování / Kritické*: `${c.warnCount} / ${c.critCount}` (status `critical`
        if `critCount > 0`, `warning` if `warnCount > 0`, else `ok`)
     3. *Můžete vynechat*: `daysText(term.capacity)`
     4. *Naplánováno*: `${daysText(plannedDays)} · $plannedHours h`
   - Compact 1-line summary right below the KPIs (replacing two extra KPI cards,
     reusing existing strings):
     `${Strings.get('planner_horizon')}: ${term.remainingDays.length}` +
     (if `term.tightest != null`)
     `' · ${Strings.get('stat_tightest')}: ${tight.name} (${Strings.format('hours_free', {'n': hoursText(tight.free)})})'`.

6. **Warnings card** (unchanged from `PlannerView._warnings`)
   - Shown when `over`, `reserve`, or `fastPace` subjects exist.

7. **Calendar strip (`TutorialAnchor(anchorKey: 'plan_strip')`)**
   - *Přehled pololetí* (`section_overview`) + interactive term calendar strip
     and legend, opening `showPlanDayDialog` / `showPlannedDialog` on tap.

8. **Recommended days off**
   - *Doporučené volno* (`section_plan`), target days dropdown, *Naplánovat vše*,
     and recommended day cards (`TutorialAnchor(anchorKey: 'plan_first')` on
     the first card).

9. **Subjects & hour budgets (unified list — replaces both old subject lists)**
   - Section header: *Předměty a rozpočet* / *Subjects & budget*, plus the
     4-color legend (*Zameškáno*, *Plánováno*, *Volno*, *Rezerva*) when
     budgets are present.
   - First subject card is wrapped in `TutorialAnchor(anchorKey: 'abs_first')`
     (`plan_budget` anchor is dropped alongside the `plan_budget` tour step).
   - **Match key:** each `SubjectAbsence` matches its `BudgetRowData` in the
     selected term by `AbsencesController.canonSubject(name)` (`TermPlanData.budgets`
     carries only `name`, and both lists derive from `subjectStates()`, so no
     budget row exists without a subject).
   - One card per subject:
     - Top row: **Subject name** (bold), bare **current %** (`'${subject.currentPct.toStringAsFixed(1)} %'`,
       no `abs_current_pct` string needed), and **one status badge**:
       - Tier 3 (red `critical`): `critical` (absence) / `over` (budget)
       - Tier 2 (yellow `warning`): `warning` (absence) / `reserve` or `tight` (budget)
       - Tier 1 (green `ok`): `ok`
       - Pick the higher tier; on a tie, pick the budget status (since it
         belongs to the selected term). Badge label uses `state_<status>` when
         the absence status wins strictly, and `budget_<status>` (`budget_ok`,
         `budget_tight`, `budget_reserve`, `budget_over`) when the budget
         status wins or ties (or `state_<status>` when no budget row exists).
     - Bar: when a matching budget row exists for the active term, render the
       4-color stacked `_budgetBar`; otherwise render `w.Meter(valuePct: subject.currentPct)`.
     - Detail lines (reusing existing strings):
       - With budget: line 1 = `budget_final` (*na konci ~{p} % (limit {limit:g} %)*),
         line 2 = `budget_line` (*volno {free} h · naplánováno {planned} h · rezerva {buffer} h*).
       - Without budget: `AbsencesController.detail(subject)` (`col_limit` ·
         `safe_to` · `col_safe`).

10. **Planned days** (`planned_title`, with unplan) & **Calendar footer**
    (*Upravit kalendář* → Settings → Škola), shown whenever `plan != null`
    (both Case 2 when `term == null` and Case 3 when `term != null`),
    unchanged from `PlannerView`.

### Why this order?
- KPIs are immediately visible at the top.
- On 390 px phones, the calendar strip remains visible on the first screen
  (preserving P9b) and tapping the planner suggestion on *Dnes* lands right at
  the calendar and recommended days without scrolling past 10–15 subject cards.
- Every subject is shown **once** with all absence + budget data together.

---

## 4. Code organization & keeping planner dialogs/tests clean

- Keep `PlannerController`, `plan_reserve.dart`, `YearPlanData` /
  `TermPlanData` / `DayOptionData` / `PlannedRowData` / `BudgetRowData` /
  `TightestData` / `ImpactRowData` / `ImpactTerm` / `PickerSlot`, and
  `plannerControllerFor` / `yearPlanDataFor`.
- **Remove `LivePlannerView` and `PlannerView`.** In
  `app/lib/features/planner/planner_view.dart`, replace `PlannerView` with
  `PlannerSections` keeping the same constructor arguments `PlannerView` takes
  today (minus `onOpenAbsences` and `updatedLabel`), plus optional
  `Widget? subjectsSection` and `bool embedded = false`, and retaining the
  dialogs and helpers (`PlanDayDialog`, `PlanAllDialog`, `PlannedDialog`,
  `CustomPlanDialog`, `showPlanDayDialog`, `showPlanAllDialog`,
  `showPlannedDialog`, `showCustomPlanDialog`).
- `AbsencesView` accepts optional planner arguments (`PlannerController? planner`,
  `YearPlanData? plan`, `bool hasTimetable`, `String calendarSummary`,
  `bool stravaOn`, `impactOf`, `impactOfEntries`, `lessonsFor`, `freeDays`,
  `onOpenCalendar`, `tutorialEvent`), renders a single `ListView` on both
  narrow and wide viewports, and embeds `PlannerSections(..., embedded: true,
  subjectsSection: ...)` so warnings, calendar strip, recommended days, the
  unified subject/budget list, planned days, and the calendar footer render in
  one scroll container without duplicating dialog/picker logic.
- `LiveAbsencesView` gains an optional `DateTime? now` parameter (forwarded to
  `yearPlanDataFor(s, now)`) so tests can pin the clock, and builds both
  `absencesControllerFor(s)` and `plannerControllerFor(s)` +
  `yearPlanDataFor(s, now)`.

---

## 5. Config keys & safety rules

- **Zero config keys added, removed, or renamed.** `config.example.json`,
  `config.dart`, and all frozen parity fixtures stay untouched.
- **Safety rules (`CONTRIBUTING.md` §5):** `runRefresh`, `withSessionLock`,
  `Strakalari.sendExcuse`, `HistoryLock`, `audit.dart`, `automation_paused`,
  and `planCustomSkip` / `unplanEntry` / lunch cancellation staging in
  `controllers/planner.dart` are completely untouched.
- `LiveAbsencesView` still emits only when `AppState` changes; opening/closing
  `LimitsEditorContent` keeps `onLimitsUpdated` working without breaking
  existing tests.

---

## 6. Tutorials & strings (PLAN rule 5 & rule 7)

### Tutorials (`app/lib/tutorial/tours.dart`, `app/lib/controllers/tutorial.dart`)
- Remove the separate `'planner'` tour (including its `plan_budget` step,
  `TutorialAnchor(anchorKey: 'plan_budget')`, and `tut_plan_budget_title` /
  `tut_plan_budget_body` strings; `abs_first` sits on the unified subject
  list). Fold `plan_strip` and `plan_pick` into `'absences'` (route
  `'absences'`):
  1. `abs_stats` (`anchor: 'abs_stats'`) — covers the unified overview KPIs.
  2. `plan_strip` (`anchor: 'plan_strip'`) — calendar strip (skipped via
     `tutorialStepSkipped` when no planner calendar is active).
  3. `plan_pick` (`anchor: 'plan_first'`, `until: 'day_planned'`) — recommended
     day card (skipped when `recommended` is empty).
  4. `abs_subject` (`anchor: 'abs_first'`) — unified subject + budget card,
     reserve note, and *Limity* button.
- **When the tour is offered:** `LiveAbsencesView` calls
  `s.tutorialOffer('absences')` only once the active term has `hasData` and
  non-empty `recommended` days (matching `planner_live.dart:214` today), so
  `plan_pick` is never skipped on first offer and a new user sees the complete
  4-step tour.
- **Existing users:** keep the tour id `'absences'` with **no `tutorials_done`
  migration** (anyone wanting to see the combined steps again can replay
  tutorials in *Nastavení → Vzhled → Přehrát návody znovu*).
- **Skip flags (`AppState`):** `tutorialStepSkipped(TourStep step)` in
  `app/lib/controllers/tutorial.dart` reads directly from `AppState` (not from
  `AbsencesView`), matching `hasPresetScale` for `marks_scale`:
  - `plan_strip`: skipped when `timetable().isEmpty` or the active term
    (`yearPlan().term(plannerTerm) ?? yearPlan().defaultTerm`) is `null`.
  - `plan_pick`: skipped when `plan_strip` is skipped or the active term's
    `recommended` is empty.
- Update `intro` tour strings:
  - `tut_intro_nav_body` (cs/en): drop "Plánovač hledá volné dny" / "the
    Planner finds days off" and note that *Absence* handles both absences and
    planning days off.
  - `tut_intro_nav_body_narrow` (cs/en): remove *Plánovač* / *the Planner* from
    the list under *Více* / *More*.
- Update `tut_abs_stats_body` and `tut_abs_subject_body` (cs/en) so they
  accurately describe the unified KPIs, combined subject/budget cards, the
  illness/surprise reserve (moved from the dropped planner intro paragraph),
  and the *Limity* button.

### Strings (`app/lib/l10n/app_cs.arb`, `app_en.arb`, `strings.dart`)
- **New keys:**

  | Key | `cs` | `en` | Where used |
  |---|---|---|---|
  | `stat_warn_crit` | `Varování / Kritické` | `Warning / Critical` | 2nd KPI card when `plan != null && term != null` |
  | `abs_subjects_section` | `Předměty a rozpočet` | `Subjects & budget` | Section header above the unified subject list |

- **Reused existing keys** (not duplicated): `planner_horizon`, `stat_tightest`,
  `hours_free`, `stat_can_afford`, `stat_planned`, `budget_final`,
  `budget_line`, `col_limit`, `safe_to`, `col_safe`, `avg_absence`,
  `warn_subjects`, `crit_subjects` (still used for the 3-card row when
  `plan == null || term == null`), `planner_title` (kept for
  `strings_table_parity_test.dart:89`).
- **Removed keys** (removed from `app_cs.arb`, `app_en.arb`, and
  `strings.dart`, each verified unused via grep after F1b): `see_absences`,
  `nav_planner`, `section_budgets`, `planner_desc`, `plan_buffer_note`
  (`strings_table_parity_test.dart:115` switched to `abs_no_limits`),
  `tut_plan_budget_title`, `tut_plan_budget_body`.
- **Updated keys** (`cs` & `en`): `tut_intro_nav_body`,
  `tut_intro_nav_body_narrow`, `tut_abs_stats_body`, `tut_abs_subject_body`.

### README & screenshots (`README.md`, `README.en.md`, `tools/parity/capture_screens.dart`)
- Update `README.md:51–60` and `README.en.md:51–60` in short, non-technical
  prose: fold the *Plánovač* / *Planner* bullet into **Absence** / **Absences**
  (tracking limits + planning days off evenly up to the closure), and replace
  the `docs/images/planner-cs.png` / `planner-en.png` image cell with
  `docs/images/absences-cs.png` / `absences-en.png`.
- Remove `'planner'` from `screens` in `tools/parity/capture_screens.dart:68`,
  capture the updated `absences-cs.png` / `absences-en.png` from synthetic demo
  data into `docs/images/`, and remove the obsolete `docs/images/planner-cs.png`
  and `docs/images/planner-en.png`.
- Leave `docs/SCHOOL_PRESETS.md:5` ("the Planner") unchanged (names the
  feature, not the tab).

---

## 7. Tests to update and add

Because `'planner'` leaves the shell rail and *More*, existing route/nav/view
tests are adapted directly (every test stays; baseline is core 809 passed /
2 skipped and app 722 passed / 1 skipped after R3b M1, and the count may only
go up):

- `app/test/widget_test.dart`: remove `'planner'` from the rail route loop
  (7 shell routes + `'more'`).
- `app/test/more_page_test.dart`: `desktopOrNonAndroidHasFourEntries` expects
  3 entries (`['absences', 'activity', 'settings']`);
  `androidInsertsAlarmEntryBeforeSettings` expects 4 entries (`['absences',
  'activity', 'alarm', 'settings']`, alarm at index 2);
  `openMoreRouteStandardScreenNavigatesDirectly` opens `'absences'` and
  expects `'absences'`.
- `app/test/mobile_narrow_shell_test.dart`: `everyScreenBuilds` checks the 8
  live routes (without `'/planner'`) plus verifies `'/planner'` redirects to
  `'/absences'`; `backStepsUp` replaces `'planner'` cases with `'absences'`
  (`narrow: true` → `'more'`, `narrow: false` → `'today'`,
  `wizardShown: true` → `null`); `P9c` checks `['/absences', '/activity',
  '/settings']`.
- `app/test/android_back_test.dart`: `backOnAMoreScreenGoesToMore` navigates
  to `'/absences'` (instead of `'/planner'`) from `'/more'` and keeps the
  `'/more'` → `'/today'` Back assertions.
- `app/test/tutorial_test.dart`: remove `'planner'` from `routes` in
  `strings exist for every step`, add step-skipping tests for the merged
  `'absences'` tour (skips `plan_strip` and `plan_pick` without timetable,
  skips `plan_pick` when `recommended` is empty, offers tour only when
  `recommended` is non-empty), and assert that `tut_abs_subject_body` mentions
  the reserve in both cs and en (`rezerv` / `reserve`, replacing the dropped
  planner-intro reserve check in `planner_view_test.dart`).
- `app/test/ui_views_test.dart`: replace step 5 (`LivePlannerView`) with a
  `LiveAbsencesView(narrow: false)` check with timetable/plan data so every
  shell screen remains covered.
- `app/test/scroll_keeps_offset_test.dart`: replace `LivePlannerView(now: ...)`
  with `LiveAbsencesView(now: DateTime(2026, 9, 10, 10, 0))` and keep the
  100 px scroll-preservation assertion.
- `app/test/planner_live_test.dart`: update `LivePlannerView renders budgets
  and recommendations` to pump `LiveAbsencesView(now: DateTime(2026, 9, 10, 10, 0))`
  and assert subject, budget, and recommended-day rendering.
- `app/test/calendar_days_dst_test.dart`: update the `wide` and `phone`
  calendar-strip tests to pump `PlannerSections` (instead of `PlannerView`)
  with the same arguments and keep all DST cell/outline/alignment assertions;
  `custom dialog` stays unchanged.
- `app/test/planner_view_test.dart`: update all 12 `PlannerView` widget tests
  to pump `AbsencesView` (asserting `absence_title` instead of `planner_title`,
  and `abs_subjects_section` instead of `section_budgets`):
  - `empty state without timetable` (`no_data` + `planner_need_refresh`);
  - `empty state asks for credentials when timetable exists` (stays): pumps
    `AbsencesView` with no subjects, `hasTimetable: true`, and `demoMode: true`
    expecting `need_credentials`, and with `demoMode: false` expecting
    `no_data` and no `need_credentials`;
  - `year plan renders stats, calendar, budgets, planned`: removes the old
    `expect(find.textContaining('10'), findsWidgets)` intro-reserve check
    (recorded under *Deviations*: "the planner intro paragraph was removed by
    F1b"), replaced by the `tut_abs_subject_body` reserve check (`rezerv` /
    `reserve`) in `tutorial_test.dart`;
  - `target dropdown offers the capacity` ×2, `plan dialog confirm plans the
    day`, `plan dialog cancel closes without planning`, `plan-all dialog plans
    recommended days`, `planned entry can be unplanned`, and `a planned entry
    in the past shows the passed badge`;
  - `custom picker taps a day whole and confirms`: finds `PlannerSections` by
    type (`find.byType(PlannerSections)`) instead of `PlannerView` to call
    `showCustomPlanDialog(ctx)`;
  - `P9a+b narrow planner equalizes KPI card heights and keeps calendar visible
    on first screen`: keeps its existing assertions (4 `StatCard`s with equal
    heights per row and both semester buttons on one row), uses a new student's
    setup (`hasSubjectLimits: false`, `createLimitsController != null` so the
    *no limits* banner is showing, plus warnings card, 2 terms, and 4 KPI
    cards), asserts *Limity* (`Key('abs:limits_btn')`, string `abs_limits_btn`)
    and *Naplánovat vlastní termín* (`plan_custom`) sit on one row (replacing
    `see_absences`), and asserts *Přehled pololetí* (`section_overview`) still
    ends above `708 px` at `390 × 844`.
  - `reserve dialog saves valid values only` and `controller plan/unplan with
    failing persist rolls back` stay unchanged.
- `app/test/absences_view_test.dart` and `app/test/absences_live_test.dart`:
  keep all existing tests (`P9a` 3-card row without plan, `F1` limits editor,
  `LiveAbsencesView` snapshot/rebuild) and add tests proving:
  - each subject renders **once** (no duplicate subject cards);
  - real `AppState` data cases 1–3: (1) no timetable → `no_data` +
    `planner_need_refresh` (`need_credentials` in demo mode), (2) closed year
    (`plan != null && term == null`) → 3 Absence KPI cards, `Meter` fallback,
    `term_nothing`, calendar footer, and a planned entry shown under
    `planned_title` that can be unplanned when `term == null`, (3) active term
    → 4 KPI cards, budget bars + projected %, and `Meter` fallback for any
    subject without a budget row;
  - `/planner` redirects to `/absences`;
  - *Dnes* planner suggestion navigates to `/absences`.
- `app/test/strings_table_parity_test.dart`: update line 115 (`plan_buffer_note`)
  to test another `{name:g}` key (`abs_no_limits` with `pct`) when
  `plan_buffer_note` is removed, keeping `planner_title` and `>= 790` checks.
- (`app/test/planner_dialog_test.dart`, `app/test/plan_picker_test.dart`, and
  `app/test/planner_reserve_test.dart` stay unchanged.)

Visual evidence to capture before/after implementation: `absences` screen at
390 px and 1280 px in cs and en, light and dark (plus `MorePage` at 390 px).

---

## 8. Done when (and commit plan)

Implement as a series of green `F1b:` commits (each with its own tests, never
breaking the tree): e.g. (1) navigation/routes/`MorePage`/`TodayView`,
(2) `PlannerSections` + unified `AbsencesView` + `LiveAbsencesView` + adapted
view tests, (3) tutorials + strings + `README` + `docs/images/absences-*.png`.

**Done when:**
- Only one unified `/absences` screen exists; *Plánovač* is gone from the
  desktop rail (7 items) and phone *More* (3 items: `absences, activity,
  settings`; 4 on Android: `absences, activity, alarm, settings`).
- `/planner` redirects to `/absences`, and the *Dnes* planner tip opens
  `/absences`.
- Every subject appears **once** with combined current % + stacked budget bar
  + projected % (or `Meter` fallback when no budget/term exists); real data
  cases 1–3 behave as specified in §3 item 3.
- All planner dialogs (`PlanDayDialog`, `PlanAllDialog`, `PlannedDialog`,
  `CustomPlanDialog`), `PlannerController`, and lunch-cancel staging stay
  intact.
- `P9a+b` passes on the merged `AbsencesView` with a new student's setup (no
  limits banner + warnings + 2 terms + 4 KPIs, `Limity` + `plan_custom` on one
  row, *Přehled pololetí* ending above `708 px` at `390 × 844`).
- Merged `absences` tour, updated `intro` tour strings, and exact added/removed
  strings in `app_cs.arb`, `app_en.arb`, and `strings.dart` (verified unused
  by grep) are in place.
- `README.md`, `README.en.md`, `tools/parity/capture_screens.dart`, and
  `docs/images/absences-*.png` are updated (and `planner-*.png` removed).
- Visual evidence captured in `build/qa-evidence/F1b/` (`absences` at
  390 px and 1280 px, cs and en, light and dark, plus `MorePage` at 390 px).
- `dart analyze` + `dart test` in `packages/strakalari_core` (`809 passed, 2
  skipped`) and `flutter analyze` + `flutter test` in `app` (`>= 722 passed,
  1 skipped`, count not lower) are all green.
