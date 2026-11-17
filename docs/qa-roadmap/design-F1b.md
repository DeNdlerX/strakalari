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
- **`moreRoutes`** & **`MorePage.entries`** (`app/lib/features/more.dart`):
  remove `'planner'`. Order becomes `['absences', 'activity', 'settings']`
  (plus `'alarm'` before `'settings'` on Android).
- **`/planner` compatibility redirect:** keep
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

3. **Empty / partial-data states**
   - **No absence data (`subjects.isEmpty`)**: show `EmptyState(no_data)` plus
     `need_credentials` (in `demoMode`) or `planner_need_refresh` (when
     `!hasTimetable`).
   - **Absences present, no planner data (`plan == null`)**: show the 3
     Absence KPI cards and unified subject cards (using `w.Meter` fallback, as
     today), plus a compact muted card at the bottom with
     `planner_need_refresh` (or `term_nothing` when `plan != null && term == null`).

4. **Term selector** (when `plan != null && plan.terms.length >= 2`)
   - *1. pololetí · do ...* / *2. pololetí · do ...* buttons (same compact row
     on `narrow`, `Wrap` on `wide`). Selecting a term updates both the planner
     sections and the subject budget bars/projections to match that term.

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
   - Compact 1-line summary right below the KPIs (replacing two extra KPI cards):
     `Zbývá N školních dní` + (if `term.tightest != null`)
     `· Nejtěsnější: <name> (<free> h volno)`.

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
   - Wrapped in `TutorialAnchor(anchorKey: 'plan_budget')` around the list (and
     `TutorialAnchor(anchorKey: 'abs_first')` on the first subject card).
   - One card per subject:
     - Top row: **Subject name** (bold), **Current %** (e.g. `12.5 %`), and
       **Status badge** (most severe of current absence status and budget
       status: `critical`/`over` > `warning`/`reserve`/`tight` > `ok`).
     - Bar: when a matching budget row exists for the active term, render the
       4-color stacked `_budgetBar`; otherwise render `w.Meter(valuePct: subject.currentPct)`.
     - Detail lines:
       - With budget: `Limit: X % · na konci ~P %` and
         `N h volno · P h plánováno · B h rezerva`.
       - Without budget: `Limit: X % · Bezpečně do: Y % · Zbývá hodin: Z`.

10. **Planned days** (`planned_title`) & **Calendar footer** (*Upravit kalendář*
    → Settings → Škola), unchanged from `PlannerView`.

### Why this order?
- KPIs are immediately visible at the top.
- On 390 px phones, the calendar strip remains visible on the first screen
  (preserving P9b) and tapping the planner suggestion on *Dnes* lands right at
  the calendar and recommended days without scrolling past 10–15 subject cards.
- Every subject is shown **once** with all absence + budget data together.

---

## 4. Code organization & keeping planner dialogs/tests clean

- Keep `PlannerController`, `plan_reserve.dart`, `YearPlanData` /
  `TermPlanData` / `DayOptionData` / `PlannedRowData` / `BudgetRowData`, and
  `plannerControllerFor` / `yearPlanDataFor`.
- Extract the reusable planner sections and dialogs (`showPlanDayDialog`,
  `showPlanAllDialog`, `showCustomPlanDialog`, `showPlannedDialog`, calendar
  strip, target dropdown, budget bar) so `AbsencesView` renders them directly
  without duplicating dialog/picker logic.
- Remove `LivePlannerView` (replaced by `LiveAbsencesView`) and keep unit/dialog
  tests working against `AbsencesView` / `PlannerController` (see §7).

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
- Remove the separate `'planner'` tour; fold its steps into the `'absences'`
  tour (route `'absences'`):
  1. `abs_stats` (`anchor: 'abs_stats'`) — covers the unified overview KPIs.
  2. `plan_strip` (`anchor: 'plan_strip'`) — calendar strip (skipped via
     `tutorialStepSkipped` when no planner calendar is on screen).
  3. `plan_pick` (`anchor: 'plan_first'`, `until: 'day_planned'`) — recommended
     day card (skipped when `recommended` is empty).
  4. `abs_subject` (`anchor: 'abs_first'`) — unified subject + budget card and
     the *Limity* button.
- `AbsencesView` exposes `bool hasPlannerData` / `bool hasRecommendedDays` (or
  `AppState` checks `timetable().isNotEmpty` / current `YearPlan` state) for
  `tutorialStepSkipped`, matching how `marks_scale` is skipped when a preset sets
  the scale.
- Update `intro` tour strings:
  - `tut_intro_nav_body` (cs/en): drop "Plánovač hledá volné dny" / "the
    Planner finds days off" and note that *Absence* handles both absences and
    planning days off.
  - `tut_intro_nav_body_narrow` (cs/en): remove *Plánovač* / *the Planner* from
    the list under *Více* / *More*.
- Update `tut_abs_stats_body` and `tut_abs_subject_body` (cs/en) so they
  accurately describe the unified KPIs and combined subject/budget cards +
  *Limity* button.

### Strings (`app/lib/l10n/app_cs.arb`, `app_en.arb`, `strings.dart`)
- Add new cs/en strings for:
  - `stat_warn_crit` (*Varování / Kritické* | *Warning / Critical*)
  - `abs_horizon_tightest` / `abs_days_left` (*Zbývá {n} školních dní* | *{n} school days left* and *Nejtěsnější: {name} ({h} h volno)* | *Tightest: {name} ({h} h free)*)
  - `abs_subjects_section` (*Předměty a rozpočet* | *Subjects & budget*)
  - `abs_current_pct` (*Aktuálně {p} %* | *Current {p} %*)
- Keep `planner_title` (checked by `strings_table_parity_test.dart` and usable
  as a section header) and `nav_planner` only if needed; remove `see_absences`
  (no longer shown anywhere).

---

## 7. Tests to update and add

Because `'planner'` leaves the shell rail and *More*, existing route/nav/tour
tests need direct adaptation (no test logic weakened or deleted):
- `app/test/widget_test.dart`: remove `'planner'` from the rail route loop
  (7 shell routes + `'more'`).
- `app/test/more_page_test.dart`: update `MorePage` expected entry counts
  (3 desktop, 4 Android) and replace `'planner'` with `'absences'` in
  `openMoreRouteStandardScreenNavigatesDirectly`.
- `app/test/mobile_narrow_shell_test.dart`: update `everyScreenBuilds`,
  `backStepsUp`, and `P9c` loops to expect `/absences` instead of `/planner`
  (plus a check that `/planner` redirects to `/absences`).
- `app/test/android_back_test.dart`: `backOnAMoreScreenGoesToMore` navigates
  to `/absences` (instead of `/planner`) from `/more`.
- `app/test/tutorial_test.dart`: remove `'planner'` from `routes` set and add
  step-skipping tests for the merged `'absences'` tour (with and without
  timetable/recommended days).
- `app/test/planner_view_test.dart`, `app/test/scroll_keeps_offset_test.dart`,
  `app/test/ui_views_test.dart`, `app/test/absences_view_test.dart`,
  `app/test/absences_live_test.dart`: update view tests from `PlannerView` /
  `LivePlannerView` to the unified `AbsencesView` / `LiveAbsencesView` (keeping
  all assertions on KPIs, calendar strip, recommended days, target dropdown,
  planned entries, P9a equal heights, P9b calendar on first screen at 390 px,
  and scroll preservation), and add tests proving:
  - each subject renders **once** (no duplicate subject cards);
  - both current % + budget bar + projected % show together when planner data
    exists, and `Meter` fallback shows when no timetable exists;
  - `/planner` redirects to `/absences`;
  - *Dnes* planner suggestion navigates to `/absences`.

Visual evidence to capture before/after implementation: `absences` screen at
390 px and 1280 px in cs and en, light and dark (plus `MorePage` at 390 px).
