# F1c design note: short Absence + one-calendar Plánovač (O3), full-page Limits (O4), real Budík step (O5), early setup refresh (O6)

Status: **design note only, awaiting R3c design review — no O3–O6 code yet.**
Written 2026-11-19 after fixing R3b code review findings M1, M2, S1–S3 (`7329221` … `64b5ccf`).

Sources: owner's 2026-11-19 phone test of F1b (`STATUS.md` *Owner decisions*) and
the reviewer's direction in [`reviews/phase-3b.md`](reviews/phase-3b.md#owner-changes-need-design-f1cmd-first-no-code-before-it-passes).

---

## 1. What changes, in one paragraph

Four follow-up improvements from the owner's phone test of F1b:
- **O3:** **Absence** (`/absences`) becomes short and focused again (header with *Limity* and **Plánovač** buttons, 3 KPI cards, optional 1-line next-recommended-day shortcut, and the unified subject + M1 stacked budget-bar list). Planning moves into a sub-route **`/absences/plan`** (no new rail or *More* tab) holding the term selector, a compact summary line, **one month-at-a-time calendar** (showing past days dimmed and non-tappable, replacing both the long multi-month semester overview and the separate *Naplánovat vlastní termín* dialog, supporting both single-day whole/partial-lesson planning via M2's `pickerSlotsFor` and a *Vybrat více dní* multi-day mode), the 3-day recommended list, planned days, and the calendar footer.
- **O4:** Limits editing moves out of its narrow 480 px `AlertDialog` into a full-width sub-route **`/absences/limits`** with default/warning/reserve settings at the top and tappable subject rows whose inline editor offers chips for the default and every value already used in `subject_limits`. *Nastavení → Limity* links straight to `/absences/limits`.
- **O5:** The Android wizard's *Telefon* step embeds the real Settings `WakeupCard` (enable switch, minutes before first lesson, notification + exact-alarm permissions, and next wake-up preview) instead of a lone switch.
- **O6:** Once the Bakaláři login test passes and saves in the wizard, the app immediately starts a background Bakaláři-only refresh with an **in-memory** `automation_paused: true` config copy, so timetable, absences, subjects, and the *Telefon* step's next wake-up are already populated while zero excuses or lunch orders can fire before setup finishes.

---

## 2. O3 — Short Absence screen + Plánovač sub-route (`/absences/plan`) with one calendar

### 2.1 Navigation, routes, and back behavior (`router.dart`, `scaffold.dart`, `today_view.dart`)

- **`shellRoutes`** stays 7 items (`today, timetable, absences, marks, lunches, activity, settings`); **`moreRoutes`** stays 3 items (`absences, activity, settings`; Android *More* stays 4 with *Budík*). No new rail or *More* entry.
- **New sub-routes inside `ShellRoute`** (`app/lib/shell/router.dart`):
  - `'/absences/plan'` (route key `'absences/plan'`) → `ShellBackScope(route: 'absences/plan', child: LivePlannerPage(tokens: tokens, narrow: narrow))`
  - `'/absences/limits'` (route key `'absences/limits'`) → `ShellBackScope(route: 'absences/limits', child: LiveLimitsPage(tokens: tokens, narrow: narrow))` (O4)
- **Compatibility redirect:**
  - `GoRoute(path: '/planner', redirect: (_, _) => '/absences/plan')`
  - `routeForLocation(location)`:
    - `'planner'` → `'absences/plan'`
    - `'absences/plan'` → `'absences/plan'`
    - `'absences/limits'` → `'absences/limits'`
    - `routeLocation(route)` already returns `'/$route'`, so `'absences/plan'` → `'/absences/plan'` and `'absences/limits'` → `'/absences/limits'`.
  - Add `'absences/plan'` and `'absences/limits'` to `PlaceholderScreen` `titles` fallback (`planner_title`, `sec_limits`) and to `AppScaffold`'s `pendingRoute` allow-list (`scaffold.dart:216`).
- **Rail / bottom bar selection (`scaffold.dart`):**
  - `final navRoute = route.startsWith('absences/') ? 'absences' : route;`
  - Wide `NavigationRail` selects `shellRoutes.indexOf(navRoute)` (*Absence* stays highlighted on both sub-routes).
  - Narrow `NavigationBar` / side `NavigationRail` keeps *Více* selected (since `'absences'` is in `moreRoutes`).
- **Back navigation (`scaffold.dart`):**
  - `backTarget`: when `!wizardShown && (route == 'absences/plan' || route == 'absences/limits')`, return `'absences'`. Android system Back (`ShellBackScope`) therefore steps from `/absences/plan` or `/absences/limits` back to `/absences` (and from `/absences` to `/more` on phone, unchanged).
  - `_buildTopBar`: suppress `topbar_back_btn` on `'absences/plan'` and `'absences/limits'` (same single-arrow rule as an open Settings section, `d7e3a78`), because both sub-pages render their own `IconButton(Icons.arrow_back)` in their page header on **both** narrow and wide viewports (giving desktop users a back button too without ever doubling arrows on phones).
- **`TodayView`** (`app/lib/features/today/today_view.dart:128`): the planner tip button opens `'absences/plan'` with label `Strings.get('abs_planner_btn')` (*Plánovač* / *Planner*).

### 2.2 Short `/absences` screen (`AbsencesView` + `LiveAbsencesView`)

`AbsencesView` (`app/lib/features/absences/absences_view.dart`) becomes short and focused:

1. **Header (`HeaderRow`)**
   - Title: `Strings.get('absence_title')`, plus `updatedLabel`.
   - Two actions (inline in `HeaderRow` on `wide`; single equal-width `Row` right under `HeaderRow` on `narrow`):
     - *Limity* (`Key('abs:limits_btn')`, `OutlinedButton.icon(Icons.tune)`) — shown when `onOpenLimits != null`; opens `/absences/limits`.
     - *Plánovač* (`Key('abs:planner_btn')`, `FilledButton.icon(Icons.event_available_outlined)`, label `abs_planner_btn`) — shown when `onOpenPlanner != null`; opens `/absences/plan`.
2. **No-limits banner** (unchanged): shown when `!c.hasSubjectLimits && onOpenLimits != null`; tapping *Limity* (`Key('abs:no_limits_btn')`) opens `/absences/limits`.
3. **Case 1 — no subjects (`c.subjects.isEmpty`)**: `EmptyState(no_data)`, plus `planner_need_refresh` when `!hasTimetable`, plus `need_credentials` when `c.demoMode`.
4. **Case 2 & 3 — subjects present**:
   - **3-card KPI row** (`TutorialAnchor(anchorKey: 'abs_stats')`, equalized with `IntrinsicHeight`): *Průměrná absence*, *Varovné předměty*, *Kritické předměty*. (Fits on a single compact row even at 390 px, so subject cards begin immediately on the first screen; *Můžete vynechat* and *Naplánováno* move into Plánovač's summary line.)
   - **Always uses the current term (`yp.defaultTerm`):** both `absencesControllerFor` (`absences_live.dart:40`) and `LiveAbsencesView` (`absences_live.dart:82`) read `yp.defaultTerm` / `planData.defaultTerm`, **never** `s.plannerTerm`. Picking *2. pololetí* in Plánovač only affects `/absences/plan`, so returning to `/absences` never silently switches Absence's budget rows or `planner_next` shortcut to another term.
   - **Optional 1-line planner shortcut** (`Key('abs:next_plan_row')`): shown when `term != null && term.recommended.isNotEmpty && onOpenPlanner != null` (using `plan.defaultTerm`). A compact clickable `Card` / `InkWell` row reading `Strings.format('planner_next', {'day': '${w.dayName(next, true)} ${w.czDay(next)}'})` + trailing `Icons.chevron_right` that opens `/absences/plan`.
   - **Subjects & hour budgets list** (`Key('abs:subjects')`, first card wrapped in `TutorialAnchor(anchorKey: 'abs_first')`):
     - Section header `abs_subjects_section` + 4-color legend when `term != null && term.budgets.isNotEmpty`.
     - Each subject appears once with its current %, single badge (same tier precedence as F1b), and the M1-fixed `plannerBudgetBar` + `budget_final` / `budget_line` when a matching budget row exists for `yp.defaultTerm`, else `w.Meter` + `c.detail(subject)`.
   - Moved out of `/absences` to `/absences/plan`: term selector, warnings card, calendar overview, recommended list, planned list, calendar footer, and `showCustomPlanDialog`.

### 2.3 Dedicated Plánovač sub-route (`/absences/plan`, `PlannerPage` + `LivePlannerPage`)

Lives in `app/lib/features/planner/planner_view.dart` (widget `PlannerPage`) and `app/lib/features/planner/planner_live.dart` (widget `LivePlannerPage`, with optional `DateTime? now` for tests). Top-to-bottom in a single `ListView`:

1. **Sub-page header**:
   - `Row` with `IconButton(key: Key('plan:back_btn'), icon: Icon(Icons.arrow_back), tooltip: MaterialLocalizations.of(context).backButtonTooltip, onPressed: onBack)` + `Expanded(Text(Strings.get('planner_title'), ...))`.
2. **Empty / closed-year cases**:
   - `plan == null || !hasData`: `EmptyState(no_data)` + `planner_need_refresh` (if `!hasTimetable`) + `need_credentials` (if `demoMode`).
   - `term == null` (closed school year): `term_nothing` card, then **Planned days** (`planned_title`, with unplan so upcoming planned days that can cancel lunches remain visible and removable), then **Calendar footer**.
3. **Term selector** (when `plan.terms.length >= 2`):
   - Same compact single row on `narrow` (`Expanded` side-by-side) / `Wrap` on `wide`: *1. pololetí · do ...* / *2. pololetí · do ...*, plus `term_fresh` accent text below if `!term.hasData`.
4. **Compact 1-line summary** (`Key('plan:summary')`, inside a compact `Card` or padded row):
   - `${Strings.get('stat_can_afford')}: ${daysText(term.capacity)} · ${Strings.get('stat_planned')}: ${daysText(plannedDays)} ($plannedHours h) · ${Strings.get('planner_horizon')}: ${term.remainingDays.length}`
   - Optional second tiny muted line only when `term.tightest != null`: `${Strings.get('stat_tightest')}: ${tight.name} (${Strings.format('hours_free', {'n': hoursText(tight.free)})})`.
5. **Warnings card** (unchanged: shown only when `over`, `reserve`, or `fastPace` is non-empty).
6. **One Month Calendar (`PlannerMonthCalendar`, `TutorialAnchor(anchorKey: 'plan_strip')`)** — replaces BOTH the old multi-month semester strip AND the separate `CustomPlanDialog`:
   - **Bounds & month navigation:**
     - `firstMonth`: September of the active school year (`DateTime(schoolYear, 9, 1)` where `schoolYear = term.start.month >= 8 ? term.start.year : term.start.year - 1`, matching `schoolYearTerms`).
     - `lastMonth`: `DateTime(term.close.year, term.close.month, 1)`.
     - Initial month: `clamp(todayMonth, termStartMonth, lastMonth)` — opens on the current month when inside the active term, or on the selected term's opening month (e.g. February when switching to *2. pololetí* during November) while still allowing `‹` back to September so earlier months remain viewable. Switching terms changes the summary line, warnings card, recommended days list, and re-clamps the calendar month to `[termStartMonth, lastMonth]` (clearing any pending multi-day selection).
     - **Per-cell term lookup (other term's days):** each cell takes its look (`option`, `recommended`, `overDays`, `plannedDates`) and tap options from the term in `plan.terms` that owns `day` (`!day.isBefore(_d(t.start)) && !day.isAfter(_d(t.close))`), rather than blanking days outside the selected term. Thus, with *2. pololetí* selected in November, paging back to December–January still colours and lets the student tap every future school day of *1. pololetí* up to the selected `term.close`.
     - Month header row: `IconButton(key: Key('cal:prev_month'), icon: chevron_left, tooltip: pick_prev_month)` | **`<Localized Month> <Year>`** (from existing `pick_months`) | `IconButton(key: Key('cal:next_month'), icon: chevron_right, tooltip: pick_next_month)`.
   - **Multi-select toggle above the grid:**
     - Compact row with `Switch` / `FilterChip` (`Key('plan:multi_toggle')`, label `plan_select_multi` = *Vybrat více dní* / *Select multiple days*). Off by default; turning it off clears `selectedDays`.
   - **5-column weekday grid (Mon–Fri, DST-proof via `core.addDays`):**
     - Weekday headers `Po Út St Čt Pá` (localized via `w.dayName(..., true)`).
     - Each in-month weekday cell has `ValueKey('day_${day.year}_${day.month}_${day.day}')`, height `44 px` (compact enough that at `390 × 844`, the entire header + summary + month calendar header + grid starts well inside the first screen — `calHeader` / month header well above `708 px`).
     - **Visual states & interactivity:**
       - Outside current month: empty `SizedBox(height: 44)`.
       - After `term.close` or before the earliest term's `start` (or `firstMonth`): muted faint text, `onTap: null`.
       - **Free day / holiday** (`p.holidays.contains(day)`): `tok.border` outline, faint number, `onTap: null`.
       - **Past day** (`day.isBefore(_d(p.firstDay))`, OR `day == _d(p.today)` with zero pickable M2 slots when `lessonsFor` is provided):
         - If planned (`isPlanned`): dimmed `tintColor(over ? tok.red : tok.accent, 0.45)` — keeps its *passed* look, `onTap: null`.
         - Otherwise: dimmed `tintColor(tok.overlay, 0.55)` with `tok.faint` number, `onTap: null`.
       - **Planned future day** — decided from the day's M2 slots (`PickerSlot`s), **not** from `term.plannedDates` alone (falling back to `term.plannedDates` as fully planned only when `lessonsFor == null`):
         - **Fully planned** (taught slots exist and none is pickable because they are `planned`, or `lessonsFor == null && isPlanned`): solid `over ? tok.red : tok.accent`.
           - Single-day mode: tap opens `showPlannedDialog(context, entries)` showing **all** planned entries touching `day` (`controller.plannedEntriesFor(_iso(day))` — `PlannerController` gains `List<Map<String, dynamic>> plannedEntriesFor(String dayIso)`, while `plannedFor` returns `plannedEntriesFor(dayIso).firstOrNull`). Each entry renders with its `entryLabel(e)`, template preview, and its own *Zrušit plán* button (calling `controller.unplanEntry(e)`, removing that row or closing when the last entry is removed, and showing `plan_removed` / `save_failed`).
           - Multi-day mode: `onTap: null` (fully planned, as in `CustomPlanDialog` today).
         - **Partly planned** (some slots are `planned`, and at least one slot is still `pickable`): keeps the planned colour (`over ? tok.red : tok.accent`) plus a small `4 px` `tok.accentText` dot marker at bottom-centre of the cell (and tooltip notes both planned and remaining pickable lessons) so the student can tell at a glance that more lessons are still open.
           - Single-day mode: tap opens the upgraded `PlanDayDialog` with *Vybrat jen některé hodiny* **already expanded**, showing planned lessons locked (`onChanged: null`) with `cal_tip_planned`, the remaining pickable lessons checked and pickable, and the whole-day toggle meaning **"all that are still pickable"** (`all pickable` ↔ `none`). Confirm builds entries via `core.entriesForSelection(picked: {day: sel}, lessons: {day: taughtPeriods}, template: tpl, cancelLunch: cancelLunch)` — splitting around already-planned lessons (e.g. period 3 planned → `(null, 2)` and `(4, null)`) — and saves them atomically with one `controller.planEntries(entries)`. The dialog also lists the day's existing planned entries (`controller.plannedEntriesFor(_iso(day))`) with a *Zrušit plán* button per entry so the student can either add more lessons or remove an existing partial plan from the same tap (existing entries also stay removable in *Naplánované* below the calendar).
           - Multi-day mode: tapping toggles the day in `selectedDays` and adds **only its still-pickable lessons** (`pickablePeriods`, matching today's `CustomPlanDialog._tapDay`); on confirm in `PlanMultiDialog`, `core.entriesForSelection` passes `taughtPeriods` as `lessons[day]` so the new entries split cleanly around already-planned lessons.
       - **Selectable future school day** (not free, not past, not planned, within `[earliestTermStart, term.close]` and either has pickable M2 slots or `lessonsFor == null` with `cellTerm.options[day] != null`):
         - Colors kept: `tok.green` (recommended), `tintColor(tok.red, 0.35)` (blocked / doesn't fit), `tok.overlay` (normal school day).
         - Today keeps its 2 px `tok.text` border.
         - In **multi-day mode**, a selected day renders with an accent fill/border (`tok.accent` with `tok.accentText` number and small check indicator) so selection is unmistakable.
   - **Single-day tap (multi-select OFF):**
     - Opens upgraded **`PlanDayDialog`** for `day` (passing `slots: daySlots`, `existingEntries: controller.plannedEntriesFor(_iso(day))`, and `impactOfEntries: impactOfEntries`):
       - Default state for an unplanned day with all lessons pickable: whole day selected (1 tap *Potvrdit* plans the whole day via `controller.planSkip(...)`).
       - When `slots` has any `planned` lesson (partly planned day), *Vybrat jen některé hodiny* opens **already expanded** with `sel = pickablePeriods` (planned lessons locked with `cal_tip_planned`, remaining pickable lessons checked). Also shows any `existingEntries` touching `day`, each with its own *Zrušit plán* button.
       - Otherwise, when `slots` is non-empty, shows a collapsible toggle **`Vybrat jen některé hodiny`** (`Key('plan:choose_lessons')`, existing string `pick_choose_lessons`).
       - Expanding it lists every `PickerSlot`:
         - `CheckboxListTile` with title `'${slot.period}. ${slot.subject}'`, subtitle combining status tag (`pick_started` / `status_lesson_cancelled` / `pick_event` / `cal_tip_planned` / `pick_change`) + `slot.detail`, disabled when `!slot.pickable`.
         - Includes a quick whole-day toggle checkbox (`Key('plan:whole_day_check')`, `all pickable` ↔ `none`).
         - Whenever `sel` does not cover every taught period (e.g. a lesson was unticked, already planned, or already started today), the dialog builds entries via `core.entriesForSelection(picked: {day: sel}, lessons: {day: taughtPeriods}, template: tpl, cancelLunch: cancelLunch)` — splitting non-contiguous periods cleanly around planned/unticked lessons, recalculating impact via `impactOfEntries`, and saving all resulting entries in one atomic `controller.planEntries(entries)` call on *Potvrdit*.
         - If zero lessons remain checked, *Potvrdit* is disabled (`onPressed: null`).
   - **Multi-day mode (multi-select ON):**
     - Tapping a selectable or partly planned future school day toggles it in `selectedDays` (`Set<DateTime>`), selecting its `pickablePeriods` (only remaining pickable lessons on a partly planned day).
     - Below the grid (inside the calendar card), a **selection bar** (`Key('plan:multi_bar')`) renders:
       - Empty: `pick_empty`.
       - Non-empty:
         - Summary: `Strings.format('plan_multi_summary', {'days': daysText(n), 'h': totalHours})` (*{days} · stojí {h} h* / *{days} · costs {h} h*), where `totalHours` sums the pickable lessons (or `option.budgetHours` / `lessonsOn(d)`) of the selected days.
         - Live impact preview (`_PlanDayDialogStaticImpact`) computed from `impactOfEntries(prospectiveEntries)`.
         - Actions: *Vymazat* (`Key('plan:multi_clear')`, `TextButton`) + **Naplánovat** (`Key('plan:multi_confirm')`, `FilledButton`).
       - Tapping *Naplánovat* opens **`PlanMultiDialog`** (one confirmation dialog listing the chosen days, template dropdown + preview, lunch-cancel checkbox when `stravaOn`, and impact preview). Confirming builds entries with `core.entriesForSelection(...)` (merging consecutive school days into one range entry just like `CustomPlanDialog` did!) and saves them in one atomic `controller.planEntries(entries)` call (rolls back on failure), shows the snackbar (`skip_planned` / `skip_planned_keep_lunch` / `skip_not_planned`), clears `selectedDays`, and exits multi-select mode.
   - **Legend + hint** below the grid/bar (same 6 swatches; hint updated to mention tapping a day or toggling *Vybrat více dní*).
   - **Removed:** `CustomPlanDialog` and `showCustomPlanDialog` (and `plan_custom` / `plan_custom_hint` strings) go away because `PlannerMonthCalendar` + upgraded `PlanDayDialog` cover both single-day partial lessons and multi-day ranges.
7. **Recommended days off**: unchanged from F1b (heading with total count, target dropdown, *Naplánovat vše (N)*, next 3 picks + *Zobrazit všechny (N)* / *Zobrazit méně* in-memory toggle, `TutorialAnchor(anchorKey: 'plan_first')` on first card; tapping *Naplánovat dovolenou* opens the same upgraded `PlanDayDialog`).
8. **Planned days** (`planned_title`, with *Zrušit plán* / *Proběhlo*).
9. **Calendar footer** (*Upravit kalendář* → Settings → Škola).

### 2.4 Tutorials split (`app/lib/tutorial/tours.dart`, `app/lib/controllers/tutorial.dart`)

- **`'absences'`** (route `'absences'`, 2 steps — offered by `LiveAbsencesView` whenever `c.subjects.isNotEmpty`):
  1. `abs_stats` (`anchor: 'abs_stats'`) — overview KPIs + *Limity* and *Plánovač* buttons.
  2. `abs_subject` (`anchor: 'abs_first'`) — per-subject progress bar, reserve note, and *Limity*.
- **`'absences_plan'`** (NEW tour id — NOT `'planner'`, so existing installs with `'planner'` in `tutorials_done` get this new tour; route `'absences/plan'`, offered by `LivePlannerPage` when active term has `hasData` and `recommended.isNotEmpty`):
  1. `plan_strip` (`anchor: 'plan_strip'`) — month calendar (tap a day to plan whole or partial lessons, toggle *Vybrat více dní* for multiple days, evenly spread picks).
  2. `plan_pick` (`anchor: 'plan_first'`, `until: 'day_planned'`) — recommended days off.
- `tutorialStepSkipped` in `app/lib/controllers/tutorial.dart` keeps its `plan_strip` and `plan_pick` guards unchanged.
- `tools/demo_data.py`: `TOURS_DONE` adds `"absences_plan"` (leaving `"absences"` out) so `--tutorials` continues to leave only the Absence tour on.

---

## 3. O4 — Full-page Limits editor (`/absences/limits`) with tappable value chips

### 3.1 Widget & route (`app/lib/features/absences/limits_page.dart`)

- **`LimitsPage`** (stateful widget) + **`LiveLimitsPage`** (`ConsumerWidget`, wired to `settingsControllerFor(s)` and `onBack: () => context.go('/absences')`, unfocusing active fields before navigating back so any typed value commits).
- **Header**: `IconButton(key: Key('lim:back_btn'), icon: Icon(Icons.arrow_back), onPressed: onBack)` + `Expanded(Text(Strings.get('sec_limits'), ...))`.
- **Top card — Global defaults** (full width; 3 `AutosaveField`s in a `Row` on `wide`, stacked on `narrow`):
  1. `default_limit` → `absence_critical_pct` (fallback `25.0`, `draftKey: 'lim:default'`)
  2. `warn_limit` → `absence_warn_pct` (fallback `15.0`, `draftKey: 'lim:warn'`)
  3. `reserve_limit` → `absence_plan_reserve_pct` (fallback `10.0`, clamped `0.0..99.9`, `draftKey: 'lim:reserve'`)
  - Followed by `reserve_hint`.
  - Saving `absence_critical_pct` calls `setState(() {})` so the default `%` shown on every subject row and on the *Výchozí* chip updates immediately.
- **Per-subject list** (full width, sorted alphabetically from `c.get('absence', {})` — same filtered `limitSubjects() ?? abs.keys` set `settingsControllerFor` builds today):
  - Helper `_usedValues(Map limits, double defaultPct)`: collects every distinct numeric value in `limits.values` (sorted ascending, deduplicated against `defaultPct` within `1e-9`).
  - **Display row (`Key('lim:row:$subject')`)**: `Card` with tappable `InkWell` / `ListTile`:
    - Subject name (bold).
    - Current limit indicator:
      - If no own entry in `subject_limits`: muted `'${fmtPct(defaultPct)} %'` + muted chip/label `limit_default_tag` (*výchozí* / *default*).
      - If own entry `v` in `subject_limits`: accent bold `'${fmtPct(v)} %'` badge.
    - Trailing `Icons.edit_outlined` (or `Icons.expand_less` when expanded).
  - **Inline editor (expanded when row is tapped; only one subject expanded at a time):**
    - Row with numeric `TextField` (`Key('lim:subj:$subject')`, prefilled with own value or empty with placeholder `'${fmtPct(defaultPct)} %'`, `keyboardType: numberWithOptions(decimal: true)`) + `IconButton(key: Key('lim:done:$subject'), icon: Icon(Icons.check))` to commit & close.
    - **Quick-pick chips (`Wrap(spacing: 8, runSpacing: 6)`):**
      - First chip (`Key('lim:chip:default')`): `ChoiceChip` / `ActionChip` labelled `Strings.format('limit_use_default', {'pct': defaultPct})` (*Výchozí ({pct:g} %)* / *Default ({pct:g} %)*). Tapping removes `subject` from `subject_limits`, saves via `c.saveQuiet({'subject_limits': current})`, clears the text field, and collapses the row.
      - One chip per distinct custom value `v` in `_usedValues` (`Key('lim:chip:${fmtPct(v)}')`): labelled `'${fmtPct(v)} %'`. Tapping sets `current[subject] = v`, saves via `c.saveQuiet({'subject_limits': current})`, updates the text field, and collapses the row.
    - **Commit & clear rules (unchanged from `LimitsEditorContent`):**
      - Blank input commits by removing `subject` from `subject_limits` via `c.saveQuiet({'subject_limits': current})`.
      - Valid number commits `current[subject] = parsed` via `c.saveQuiet({'subject_limits': current})`.
      - Commits on submit, blur, switching to another row, tapping Done, and `dispose` (when navigating back).
  - **Footer hint:** `limit_subject_hint` (*Prázdné = platí výchozí limit výše.*). When `subjects` is empty, shows `no_data` muted hint under the global defaults card.
- **`SettingsView._limits`** (`app/lib/features/settings/settings_view.dart:1034`):
  - `settings:go_absences_limits` navigates to `'/absences/limits'` (instead of `'/absences'`) with label `Strings.get('open_limits')` (*Otevřít limity* / *Open limits*).
- **Removed:** `_openLimitsDialog` in `AbsencesView` and `LimitsEditorContent` in `settings_view.dart` (replaced by `LimitsPage`).
- **Config keys:** exact same keys (`absence_critical_pct`, `absence_warn_pct`, `absence_plan_reserve_pct`, `subject_limits`), zero new keys.

---

## 4. O5 — Wizard *Telefon* step embeds real `WakeupCard`

- **Where:** `app/lib/features/wizard/wizard_view.dart` (`_phoneContent`), `app/lib/features/wizard/wizard_live.dart` (`_LiveWizardViewState`, `wizardControllerFor`), and `app/lib/features/wizard/wizard_controller.dart` (`savePhone`, `shouldAskNotificationPermission`).
- **Live permissions & `WakeupCard` wiring in `_LiveWizardViewState`:**
  - Mix in `WidgetsBindingObserver` so returning from Android's *Exact alarms* or *App notifications* settings immediately re-queries `AndroidChannel().notificationsEnabled()` and `AndroidChannel().exactAlarmsAllowed()`.
  - Build a `SettingsController` via `settingsControllerFor(s, wakeupPhone: ...)` when `Platform.isAndroid` (using the same `_channelPhone` helper exported from `settings_live.dart` as `channelWakeupPhone`, with `requestNotificationPermission` marking `s.notificationPermissionAsked = true`, awaiting `channel.requestNotificationPermission()`, and refreshing `_notifOn`).
  - Pass `SettingsController? wakeupController` to `WizardView`.
- **What `_phoneContent` renders:**
  - Keeps the short intro (`wiz_phone_p`), followed by `WakeupCard(controller: wakeupController!)` (when `wakeupController != null`; falls back to the simple switch only in headless/non-wired unit tests that don't pass `wakeupController`).
  - Inside `WakeupCard`, the student sees and controls:
    1. *Budík před první hodinou* (`wakeup_enabled` switch) — toggling ON immediately saves `wakeup_enabled: true` and asks for notification permission.
    2. *Kolik minut před první hodinou budit* (`wakeup_minutes_before` `AutosaveField`) — saves on blur/submit (clamped 1..720).
    3. Notification & exact-alarm warnings + direct permission buttons (*Povolit oznámení*, *Povolit přesné budíky*) when not yet granted.
    4. Live *Příští budík* preview (`wakeup_next` / `wakeup_next_eve`) when O6's early refresh has populated the timetable, or `wakeup_none` while the timetable isn't cached yet (rebuilding automatically the instant O6 finishes and emits!).
- **Exact config keys written by `stepPhone` and when:**
  - `wakeup_enabled`: written immediately when the user toggles the switch inside `WakeupCard` (via `SettingsController.save` → `AppState.save`).
  - `wakeup_minutes_before`: written on blur/submit of the minutes `AutosaveField` (and unfocused in `WizardView` before `pressNext()` runs so a half-typed number saves before advancing).
  - `wakeup_skip_dates`: written only if the user taps *Tento den nebudit* / restore inside `WakeupCard`.
  - **On *Pokračovat* (`pressNext` at `stepPhone`):**
    - `WizardView` calls `FocusManager.instance.primaryFocus?.unfocus()` before `c.pressNext()`.
    - When `WakeupCard` is embedded (`useExternalWakeupCard = true` on `WizardController`), `savePhone()` does NOT overwrite `wakeup_enabled` with an unset `wiz:wakeup_enabled` draft; it leaves `WakeupCard`'s saved values untouched.
    - `shouldAskNotificationPermission` checks `(config['run_in_background'] ?? true) == true || (config['wakeup_enabled'] ?? false) == true || alarmEnabled`.
    - If `shouldAskNotificationPermission` AND `!notificationPermissionAlreadyAsked` (tracked from `s.notificationPermissionAsked`), `pressNext()` still awaits `onRequestNotificationPermission()` before advancing to `stepDone` — preserving B9 so a user who leaves the alarm OFF still gets the notification permission prompt on `stepPhone` (never over the post-wizard tutorial!). If the user already granted notifications inside `WakeupCard`, `pressNext()` advances directly to `stepDone` without a duplicate prompt.
  - **On *Přeskočit* (`pressSkip` at `stepPhone`):** advances to `stepDone` without asking permission and without writing any new keys.

---

## 5. O6 — Early first refresh during setup

- **Exact place it starts:**
  - `WizardController` gains `final void Function()? onBakalariSaved;`.
  - In `wizard_live.dart` (`wizardControllerFor`), wire:
    ```dart
    onBakalariSaved: () => s.startRefresh('bakalari', pauseAutomation: true),
    ```
  - Called in `WizardController` right after `saveBakalari()` succeeds on a verified login:
    1. In `recordTestResult('bakalari', true, msg)` immediately after `_saveFor('bakalari')` succeeds (the normal first-time path when *Otestovat a pokračovat* passes).
    2. In `continueTestStep('bakalari', ...)` immediately after `_saveFor('bakalari')` succeeds when continuing on an already-verified fingerprint (idempotent: `claimFlight('refresh_running')` ensures at most one refresh runs).
  - **Scope:** `'bakalari'` only (Strava comes on the next step).
- **Exact `automation_paused` guarantee (`app/lib/controllers/activity.dart`):**
  - Update `startRefresh([String scope = 'all', {bool pauseAutomation = false}])` → `_refreshWork(scope, pauseAutomation: pauseAutomation)` → `_refreshLocked(scope, started, pauseAutomation: pauseAutomation)`.
  - Inside `_refreshLocked`:
    ```dart
    final runConfig = pauseAutomation
        ? <String, Object?>{...app.configData, 'automation_paused': true}
        : app.configData;
    result = await runRefresh(
      app,
      runConfig,
      scope: scope,
      ...
    );
    ```
  - **Safety proof (CONTRIBUTING §5):**
    - Uses the single `startRefresh` → `withSessionLockAsync` → `runRefresh` → `reloadCache` → `finishRun` pipeline.
    - `automation_paused: true` is placed ONLY on the shallow in-memory `runConfig` copy; `config.json` and `app.configData` are never written or mutated with `automation_paused: true`.
    - `runRefresh` (`packages/strakalari_core/lib/src/automation/refresh.dart:736`) already gates every auto phase on `automation_paused`, so zero excuses are sent and zero lunches are ordered before setup completes.
    - Every run (success or failure) is recorded in `runs` / `audit.dart` just like any normal refresh.
- **Failure & *Dokončit* behavior:**
  - A failed early refresh never blocks wizard navigation; it records the failed run and queues the standard error dialog/snack (already drained by `popPendingMessages` on `/wizard`, `router.dart:166`).
  - *Dokončit* (`stepDone`) still calls `onFinishRefresh: () => s.startRefresh()` (scope `'all'`, `pauseAutomation: false`), running with the student's real settings (including Strava if enabled). If the early Bakaláři refresh is still in flight at *Dokončit*, `startRefresh()` returns `false` and the existing B7 `already_running` snackbar fires.

---

## 6. Config keys, safety rules, strings, and docs

- **Config keys:** **zero** added, removed, or renamed. `config.example.json`, `config.dart`, and all frozen parity fixtures stay completely untouched.
- **Safety rules (`CONTRIBUTING.md` §5):** `runRefresh`, `withSessionLock`, `Strakalari.sendExcuse`, `HistoryLock`, `audit.dart`, `planCustomSkip` / `planEntries` / `unplanEntry` / lunch-cancel staging stay completely intact; O6's early refresh adds an in-memory-only `automation_paused: true` guard and never mutates saved config.

### Strings (`app/lib/l10n/app_cs.arb`, `app_en.arb`, `strings.dart`)

- **New keys (8):**

  | Key | `cs` | `en` | Where used |
  |---|---|---|---|
  | `abs_planner_btn` | `Plánovač` | `Planner` | Header button on `/absences` and *Dnes* tip button |
  | `plan_select_multi` | `Vybrat více dní` | `Select multiple days` | Multi-select toggle above month calendar |
  | `plan_multi_summary` | `{days} · stojí {h} h` | `{days} · costs {h} h` | Selection summary bar in multi-day mode |
  | `plan_multi_btn` | `Naplánovat` | `Plan selected` | Confirm CTA in multi-day selection bar |
  | `plan_multi_clear` | `Vymazat` | `Clear` | Clear selection button in multi-day bar |
  | `limit_default_tag` | `výchozí` | `default` | Muted tag on subject rows using default limit |
  | `limit_use_default` | `Výchozí ({pct:g} %)` | `Default ({pct:g}%)` | Quick-pick chip in Limits editor to clear override |
  | `open_limits` | `Otevřít limity` | `Open limits` | *Nastavení → Limity* button linking to `/absences/limits` |

- **Removed keys (4, verified unused via grep after F1c):**
  - `plan_custom` (separate custom dialog removed)
  - `plan_custom_hint` (separate custom dialog removed)
  - `stat_warn_crit` (4-card Absence KPI replaced by 3-card Absence KPI + Plánovač summary line)
  - `open_absences` (replaced by `open_limits` on *Nastavení → Limity*; verify via grep no other caller exists)
- **Updated keys (`cs` & `en`):**
  - `overview_hint`: mentions tapping a day to plan (whole or some lessons) or switching on *Vybrat více dní* / *Select multiple days*.
  - `tut_abs_stats_body`: describes the Absence KPIs + *Limity* and *Plánovač* buttons.
  - `tut_plan_strip_body`: describes the month calendar (past days shown unselectable, tap a day for whole/partial plan, *Vybrat více dní* for multiple days, evenly spread picks).
- **Reused existing keys:** `planner_title`, `planner_next`, `section_overview`, `pick_months`, `pick_prev_month`, `pick_next_month`, `pick_choose_lessons`, `pick_empty`, `pick_started`, `pick_event`, `pick_change`, `status_lesson_cancelled`, `cal_tip_*`, `plan_skip`, `plan_all`, `plan_all_title`, `plan_all_body`, `plan_all_done`, `plan_cancel_lunch`, `plan_show_all`, `plan_show_less`, `planned_title`, `stat_can_afford`, `stat_planned`, `planner_horizon`, `stat_tightest`, `hours_free`, `sec_limits`, `default_limit`, `warn_limit`, `reserve_limit`, `reserve_hint`, `limit_subject_hint`, `abs_limits_btn`, `abs_no_limits`, `abs_subjects_section`, `wakeup_*`.
- **Key count:** 796 − 4 + 8 = **800** (above `>= 790` check in `strings_table_parity_test.dart:90`).

### Docs & tooling (`README.md`, `README.en.md`, `tools/parity/capture_screens.dart`, `tools/demo_data.py`)

- Update `tools/demo_data.py` `TOURS_DONE` to include `"absences_plan"` so `--tutorials` leaves only `"absences"`.
- Recapture `docs/images/absences-{cs,en}.png` via `tools/parity/capture_screens.dart` (which now shows the shorter Absence screen with subject budget bars clearly visible at 1280 × 800!).
- Brief 1-line README update if needed so `README.md` / `README.en.md` accurately describe opening *Plánovač* and *Limity* from *Absence*.

---

## 7. Exact tests to update and add

Baseline after R3b fixes: core **809 passed / 2 skipped**, app **739 passed / 1 skipped**. The app count may only go up; zero tests are deleted or weakened (every test stays unless its code goes, and none is expected to be removed).

### 7.1 Every existing test that changes (one line per test)

| File | Test name | Builds & taps afterwards | Assertions kept word for word | Assertions changed / moved (with new target) |
|---|---|---|---|---|
| `app/test/plan_picker_test.dart` | `tappingADayTakesItOffWhole` | Pumps `PlannerMonthCalendar` (single mode), taps `dayCell(monday)` → `PlanDayDialog` opens → taps *Potvrdit* (`FilledButton`). | `plannedSkips` length 1, `start_date == '2026-11-09'`, `end_date == '2026-11-09'`, `start_period == null`, `end_period == null`. | Pre-tap disabled *Potvrdit* assertion (no dialog before tap in single mode) moves to `tappingAPickedDayAgainUnpicksIt` (multi-select bar `plan:multi_confirm`). |
| `app/test/plan_picker_test.dart` | `tappingAPickedDayAgainUnpicksIt` | Pumps `PlannerMonthCalendar`, enables `plan:multi_toggle`, taps `dayCell(monday)` twice. | Toggling same day selects then clears it. | Disabled/enabled check targets `plan:multi_confirm` (absent / `pick_empty` before tap and after second tap; present & enabled after first tap). |
| `app/test/plan_picker_test.dart` | `untickedLessonsStayAttended` | Pumps `PlannerMonthCalendar`, taps `dayCell(monday)` → opens `PlanDayDialog` → taps `plan:choose_lessons`, unticks `Matematika` & `Fyzika`, taps *Potvrdit*. | `plannedSkips` length 1, `start_date == '2026-11-09'`, `start_period == 3`, `end_period == null`. | Adds tapping `plan:choose_lessons` inside `PlanDayDialog` to reveal the lesson checkboxes. |
| `app/test/plan_picker_test.dart` | `daysInARowBecomeOneRange` | Pumps `PlannerMonthCalendar`, enables `plan:multi_toggle`, taps `dayCell(monday)` & `dayCell(tuesday)`, taps `plan:multi_confirm` → `PlanMultiDialog` → taps *Potvrdit*. | `plannedSkips` length 1, `start_date == '2026-11-09'`, `end_date == '2026-11-10'`. | Uses `plan:multi_toggle` + `plan:multi_confirm` + `PlanMultiDialog` *Potvrdit*. |
| `app/test/plan_picker_test.dart` | `weekChangesAreShownAndCancelledLessonsLocked` | Pumps `PlannerMonthCalendar`, taps `dayCell(tuesday)` → opens `PlanDayDialog` → taps `plan:choose_lessons`, unticks 1/2/3, taps *Potvrdit*. | `'4. Fyzika'` `CheckboxListTile.onChanged == null`; `plannedSkips` length 1, `start_period == 5`, `end_period == null`. | Adds tapping `plan:choose_lessons` inside `PlanDayDialog`. |
| `app/test/plan_picker_test.dart` | `unfetchedWeekUsesTheStableTimetable` | Pumps `PlannerMonthCalendar`, taps `dayCell(thursday)` → opens `PlanDayDialog` → taps `plan:choose_lessons`. | `find.text(Strings.get('pick_from_stable'))` finds widgets; `find.textContaining('Chemie')` finds widgets. | Adds tapping `plan:choose_lessons` inside `PlanDayDialog`. |
| `app/test/plan_picker_test.dart` | `alreadyPlannedLessonsAreLockedAndSplitThePick` | Pumps `PlannerMonthCalendar`, taps partly planned `dayCell(monday)` (period 3 planned) → `PlanDayDialog` opens already expanded (M1) → taps *Potvrdit*. | `'3. Chemie'` `CheckboxListTile.onChanged == null`; `newEntries` length 2: `(null, 2)` and `(4, null)`. | Same assertions in single mode (plus new companion test for multi-day mode split and new multi-entry `showPlannedDialog` test). |
| `app/test/plan_picker_test.dart` | `fullyPlannedDaysAndHolidaysCannotBeTapped` | Pumps `PlannerMonthCalendar`; checks multi-day mode (`plan:multi_toggle` ON) and single-day mode. | In multi mode: both `dayCell(monday)` (all 5 periods planned) and `dayCell(holiday)` have `onTap == null`. | In single mode: `dayCell(holiday)` still has `onTap == null`, while tapping `dayCell(monday)` opens `showPlannedDialog`. |
| `app/test/plan_picker_test.dart` | `startedLessonsTodayCannotBePicked` | Pumps `PlannerMonthCalendar`, taps `dayCell(monday)` → opens `PlanDayDialog` → taps `plan:choose_lessons`, taps *Potvrdit*. | `'1. Matematika'` `onChanged == null`; `'4. Dějepis'` `onChanged != null`; `plannedSkips` length 1, `start_period == 4`, `end_period == null`. | Adds tapping `plan:choose_lessons` inside `PlanDayDialog`. |
| `app/test/plan_picker_test.dart` | `pastDaysAreNotTappable` | Pumps `PlannerMonthCalendar` (replaces `CustomPlanDialog`). | `dayCell(monday)` `onTap == null`. | Host widget changes from `CustomPlanDialog` to `PlannerMonthCalendar`. |
| `app/test/plan_picker_test.dart` | `wholeDaySwitchClearsAndRefillsTheDay` | Pumps `PlannerMonthCalendar`, taps `dayCell(monday)` → opens `PlanDayDialog` → taps `plan:choose_lessons`, taps `Key('plan:whole_day_check')`, taps `'Biologie'`, taps *Potvrdit*. | *Potvrdit* enabled → disabled after whole-day untick → enabled after `'Biologie'` → `plannedSkips` length 1, `start_period == 5`, `end_period == null`. | Replaces `preselect: monday` with tapping `dayCell(monday)` + `plan:choose_lessons` + `Key('plan:whole_day_check')`. |
| `app/test/plan_picker_test.dart` | `monthNavigationStaysInsideTheSchoolYear` | Pumps `PlannerMonthCalendar` with `initialMonth: 2026-11-01`, `firstMonth: 2026-11-01`, `lastMonth: 2027-06-01`, taps `cal:next_month`. | `cal:prev_month` disabled (`onPressed == null`), `cal:next_month` enabled, `dayCell(DateTime(2026, 12, 1))` finds one widget. | Header text changes from `'12/2026'` to localized `pick_months` format (`'Prosinec 2026'` in cs). |
| `app/test/planner_view_test.dart` | `empty state without timetable`, `empty state asks for credentials when timetable exists` | Pump `PlannerPage` instead of `AbsencesView`. | `no_data`, `planner_need_refresh`, `need_credentials` (true/false). | Absence empty state stays covered by `absences_live_test.dart` case 1. |
| `app/test/planner_view_test.dart` | `year plan renders stats, calendar, budgets, planned` | Pumps `PlannerPage`. | `section_overview`, `section_plan`. | Title checks `planner_title` + `plan:summary` instead of `absence_title`; `abs_subjects_section` stays covered by `absences_view_test.dart` (`F1b each subject renders once...`) and `absences_live_test.dart` case 3. |
| `app/test/planner_view_test.dart` | `target dropdown offers the capacity (0/1 planned)`, `plan dialog confirm plans the day`, `plan dialog cancel closes without planning`, `plan-all dialog plans recommended days`, `planned entry can be unplanned`, `a planned entry in the past shows the passed badge`, `recommended list shows the next 3 days and opens to all` | Pump `PlannerPage` instead of `AbsencesView`. | Every single assertion unchanged (`target_auto`, `daysText`, `choose_template`, `skip_planned`, `plan_all`, `unplan`, `plan_removed`, `day_passed`, 3-day pick toggle, `hookCalls`, no `plan_explain`, `PlanAllDialog`). | Host widget changes from `AbsencesView` to `PlannerPage`. |
| `app/test/planner_view_test.dart` | `custom picker taps a day whole and confirms` | Pumps `PlannerPage` (with `lessonsFor`), enables `plan:multi_toggle`, taps a future weekday cell, taps `plan:multi_confirm` → `PlanMultiDialog` → taps *Potvrdit*. | `c.plannedSkips` length 1; `SnackLog.last == Strings.get('skip_planned_keep_lunch')`. | Replaces `showCustomPlanDialog` / `plan_custom` title with `plan:multi_toggle` → `plan:multi_confirm` (absent before tap, enabled after tap) → `PlanMultiDialog`. |
| `app/test/planner_view_test.dart` | `P9a+b narrow planner equalizes KPI card heights and keeps calendar visible on first screen` | Pumps `PlannerPage(narrow: true)` at `390 × 844`. | Semester buttons (`1. pololetí` / `2. pololetí`) sit on one row (`dy diff < 4`); `calHeader` (`section_overview`) bottom `dy < 708`. | Equal-height `StatCard` row (P9a) is already covered on Absence by `absences_view_test.dart:85` (`P9a KPI stat cards in row share equal height on 390px phone`); narrow `abs:limits_btn` + `abs:planner_btn` single-row check + `abs:no_limits_banner` move to a new narrow test in `absences_view_test.dart`. |
| `app/test/planner_dialog_test.dart` | `customDialogTemplateSelectAndCancel` | Pumps `PlanMultiDialog` (for `[DateTime(2026, 9, 22)]`) instead of `CustomPlanDialog`. | `Šablona 1`, select `Šablona 2`, tap `cancel`, `plannedSkips` isEmpty. | Host dialog changes from `CustomPlanDialog` to `PlanMultiDialog`. (All 5 other tests in file stay untouched.) |
| `app/test/absences_view_test.dart` | `F1 Absence tab shows no-limits hint and opens shared limits editor that saves to config` | Pumps `LiveAbsencesView` inside `buildRouter(initialLocation: '/absences')`, taps `abs:no_limits_btn` → opens `/absences/limits` (`LimitsPage`), taps `lim:row:Matematika`, enters `'18'` in `lim:subj:Matematika`, taps `lim:back_btn` → returns to `/absences`. | `abs:limits_btn`, `abs:no_limits_banner`, default `25 %` → `30 %` update, `s.get('subject_limits') == {'Matematika': 18.0}`, banner disappears, `abs:limits_btn` remains. | Replaces `find.byType(LimitsEditorContent)` + `abs:limits_done` with `find.byType(LimitsPage)` + `lim:row:Matematika` + `lim:back_btn` (save check moves intact to the live flow and `limits_page_test.dart`). |
| `app/test/absences_view_test.dart` | `F1b each subject renders once with badge precedence and Meter fallback without budget row` | Same `AbsencesView`. | Each subject once, `27.5 %`, `state_critical`, `budget_tight`, `budget_final`, 1 `Meter`, `10.0 %`. | `find.byType(StatCard)` expected count changes from `4` to `3` (`_threeCardStats`). (All other tests in `absences_view_test.dart` stay untouched.) |
| `app/test/absences_live_test.dart` | `/planner redirects to /absences` | Pumps `buildRouter(initialLocation: '/planner')`. | `NavigationRail` has 7 destinations; *Absence* selected (`selectedIndex == shellRoutes.indexOf('absences')`). | Expected path changes from `'/absences'` to `'/absences/plan'`; expected widget changes from `LiveAbsencesView` to `LivePlannerPage`. |
| `app/test/absences_live_test.dart` | `Today planner suggestion opens absences` | Pumps `TodayView`, taps tip button. | Button exists and invokes `onGo`. | Button label changes from `nav_absences` to `abs_planner_btn`; navigated target changes from `'absences'` to `'absences/plan'`. |
| `app/test/absences_live_test.dart` | `case 2: closed school year (term == null) ...` | Pumps `LiveAbsencesView` (closed year), then `LivePlannerPage` (same `s` and `closedNow`). | Keeps **both** halves: 3 `StatCard`s + 1 `Meter` on `LiveAbsencesView`; `term_nothing`, `cal_open_calendar`, `planned_title`, `20.06.2027`, tap `unplan` → `s.plannedSkips` isEmpty on `LivePlannerPage`. | Split across the two routes that now own each half. |
| `app/test/absences_live_test.dart` | `case 3: active term ...` | Pumps `LiveAbsencesView` (active term). | `Matematika`, `8.0 %`, `abs_subjects_section`, `Meter` findsNothing. | `find.byType(StatCard)` changes from `4` to `3`; adds `abs:next_plan_row` check when recommended days exist. |
| `app/test/absences_live_test.dart` | `F1b custom calendar receives real lessons and plans a day (R3b code M2)` | Pumps `LivePlannerPage` (instead of tapping `plan_custom` on `LiveAbsencesView`), taps `day_2026_9_14` → `PlanDayDialog` → taps *Potvrdit*. | Past day (`day_2026_9_8`) and free day (`day_2026_9_15`) have `onTap == null`; `s.plannedSkips` length 1 (`2026-09-14`..`2026-09-14`). | Replaces tapping `plan_custom` + pre-tap disabled confirm with tapping `day_2026_9_14` directly on `LivePlannerPage`'s month calendar. |
| `app/test/planner_live_test.dart` | `LiveAbsencesView renders subjects, budgets and recommendations` | Pumps `LiveAbsencesView` AND `LivePlannerPage` on the same `AppState`. | `abs_subjects_section`, `Matematika`, `2.0 %` on `LiveAbsencesView`; `section_plan` and `plan_skip` on `LivePlannerPage`. | Recommendations assertions move to the `LivePlannerPage` half of the same test (subjects/budgets stay on `LiveAbsencesView`). |
| `app/test/tutorial_test.dart` | `strings exist for every step` (`:345`) | Unchanged loop over `tours.values`. | All cs/en `tut_*` keys exist and are non-empty. | Adds `'absences/plan'` to `const routes = {...}`. |
| `app/test/tutorial_test.dart` | `planner tour is removed and absences tour has 4 merged steps` (`:561`) | Checks `tours` map. | `tours.containsKey('planner') == false`. | `tours['absences']!.steps` is `['abs_stats', 'abs_subject']`; `tours['absences_plan']!.steps` is `['plan_strip', 'plan_pick']` on route `'absences/plan'`. |
| `app/test/tutorial_test.dart` | `skips plan_strip and plan_pick without timetable` (`:569`) | Checks `tutorialVisibleStepIndices`. | Both `plan_strip` and `plan_pick` skipped when no timetable. | Runs against `tours['absences_plan']!` expecting `[]`, and verifies `tours['absences']!` still returns `[0, 1]`. |
| `app/test/tutorial_test.dart` | `skips plan_pick when active term has no recommended days` (`:582`) | Checks `tutorialVisibleStepIndices` on active term with empty `recommended`. | `plan_strip` visible, `plan_pick` skipped. | Runs against `tours['absences_plan']!` expecting `[0]`. |
| `app/test/tutorial_test.dart` | `LiveAbsencesView offers tour only when recommended days exist` (`:602`) | Pumps `LiveAbsencesView` and `LivePlannerPage` with blocked vs ready states. | Blocked state does NOT offer `'absences_plan'`; ready state DOES offer `'absences_plan'` with steps `[0, 1]` (even if old `'planner'` is in `tutorials_done`). | `LiveAbsencesView` offers `'absences'` whenever `subjects.isNotEmpty` (and not when empty); the recommended-days offer gate moves to `LivePlannerPage` (`'absences_plan'`). |
| `app/test/calendar_days_dst_test.dart` | `wide: today sits in the Thursday row, 13 Nov in the Friday row` (`:164`) & `phone: today sits in the Thursday column, 13 Nov in the Friday column` (`:181`) | Pump `PlannerPage` (`narrow: false` / `narrow: true`) on 12 Nov 2026, then tap `cal:prev_month` to October 2026 (across 25 Oct DST). | `cell(today)` and `cell(friday)` present, Sunday 8 Nov absent, `outlinedToday(today) == true`, `outlinedToday(friday) == false`, same weekday column before & after DST (`22 Oct` / `12 Nov`, `23 Oct` / `13 Nov`). | Wide grid now uses 5 weekday columns too (same `dx` comparison as phone), and 22/23 Oct are checked after tapping `cal:prev_month` (different month page). |
| `app/test/calendar_days_dst_test.dart` | `custom dialog: October 2026 ends with Friday 30 Oct` (`:197`) | Pumps `PlannerMonthCalendar(initialMonth: DateTime(2026, 10, 1))`. | `day(30)` & `day(26)` present, `day(25)` absent, `day(30).dx == day(2).dx`, `day(26).dx == day(5).dx`. | Host widget changes from `CustomPlanDialog` to `PlannerMonthCalendar`. |
| `app/test/settings_sections_test.dart` | `Settings → limits shows link to Absences instead of duplicate editor` (`:771`) | Opens Settings `limits` section. | `settings:go_absences_limits` present; `find.byType(AutosaveField)` findsNothing. | Replaces removed `find.byType(LimitsEditorContent)` with `find.byType(LimitsPage)` findsNothing; verifies button label `Strings.get('open_limits')` and navigation to `/absences/limits`. |
| `app/test/mobile_narrow_shell_test.dart` | `everyScreenBuilds` (`:164`) | Pumps every route at `390 × 844`. | Zero exceptions and `state.lastError == null` for all routes. | Adds `/absences/plan` and `/absences/limits`; updates `/planner` redirect assertion to `routeForLocation('/planner') == 'absences/plan'` and `uri.path == '/absences/plan'`. |
| `app/test/scroll_keeps_offset_test.dart` | `a scrolled screen keeps its offset across an AppState emit` | Pumps `LiveAbsencesView` (with enough subjects so `maxScrollExtent > 100` on short Absence) and adds a second test for `LivePlannerPage`. | Offset `100` preserved across `s.onChanged()`. | Adds extra subjects in `LiveAbsencesView` fixture if needed so the shorter screen still scrolls, plus a matching `LivePlannerPage` test. |
| `app/test/wizard_live_test.dart` | `F1 Telefon step`: `shows only wakeup switch...` & `Skip on Telefon saves nothing and asks no permission` (`:1485`, `:1549`) | Pumps `LiveWizardView` on `stepPhone` with injected/mocked `WakeupPhone`. | `run_in_background` absent; `wakeup_enable` present; permission asked on Continue; Skip asks no permission and saves nothing. | Updates first test to assert `WakeupCard` (`wakeup_minutes`, permission prompts, next alarm / `wakeup_none`, immediate `wakeup_enabled` save, `wakeup_minutes_before` save on Continue); updates Skip test not to toggle `WakeupCard`'s live-saving switch before tapping *Přeskočit*. |

### 7.2 New tests added for F1c

1. **Navigation & Back (`app/test/mobile_narrow_shell_test.dart`, `app/test/android_back_test.dart`):**
   - `backTarget` returns `'absences'` for `'absences/plan'` and `'absences/limits'` on narrow screens; Android Back on `/absences/plan` and `/absences/limits` lands on `/absences`.
   - `AppScaffold` keeps *Absence* selected in the wide rail and *Více* selected in the narrow bottom bar on `/absences/plan` and `/absences/limits`, and hides `topbar_back_btn` on both sub-routes (single back arrow).
2. **Short Absence screen (`app/test/absences_view_test.dart`, `app/test/absences_live_test.dart`):**
   - Tapping `abs:planner_btn` and `abs:next_plan_row` invokes `onOpenPlanner`; overview/recommended/planned sections are NOT rendered on `AbsencesView`; narrow `AbsencesView` places `abs:limits_btn` and `abs:planner_btn` side-by-side on one row and renders `abs:no_limits_banner` when `hasSubjectLimits == false`.
   - S1 term-isolation test (`absences_live_test.dart`): select `'sem2'` in `LivePlannerPage` (setting `s.plannerTerm = 'sem2'`), then render `LiveAbsencesView` (`/absences`) → budget rows and `planner_next` still reflect `sem1` (`yp.defaultTerm`).
3. **Plánovač calendar & partly planned days (`app/test/plan_picker_test.dart`, `app/test/ui_views_test.dart`):**
   - `alreadyPlannedLessonsSplitInMultiMode`: multi-day selection on a partly planned day (period 3 planned) splits into `(null, 2)` and `(4, null)`.
   - `showPlannedDialog` on a day with two partial entries lists both entries with independent *Zrušit plán* buttons and removes only the chosen one.
   - S2 cross-term calendar test (`absences_live_test.dart` / `planner_view_test.dart`): with `sem2` selected during November, tap `cal:prev_month` back to December and tap a future school day in `sem1` → `PlanDayDialog` opens.
   - `ui_views_test.dart` adds `LivePlannerPage` and `LiveLimitsPage` build smoke checks alongside `LiveAbsencesView`.
4. **O4 Full-page Limits (`app/test/limits_page_test.dart`):**
   - Global fields (`absence_critical_pct`, `absence_warn_pct`, `absence_plan_reserve_pct`) load and persist via `SettingsController`; changing default updates displayed defaults on subject rows.
   - Subject rows show muted `limit_default_tag` when unset and custom `%` when set.
   - Tapping a subject expands inline editor showing *Výchozí* chip + distinct already-used custom chips from `subject_limits`.
   - Tapping an already-used chip saves that value to `subject_limits[subject]` without typing; tapping *Výchozí* chip or clearing the field removes `subject` from `subject_limits`.
   - Back arrow unfocuses and invokes `onBack`.
5. **O5 Wizard `WakeupCard` (`app/test/wizard_live_test.dart`):**
   - `WakeupCard` shows permission prompts when `WakeupPhone` reports permissions off, shows next alarm preview when timetable is cached (`wakeup_none` when empty), and preserves B9 when leaving the alarm off and tapping *Pokračovat*.
6. **O6 Early setup refresh (`app/test/wizard_live_test.dart`, `app/test/app_state_excuses_and_planner_test.dart`):**
   - Unit test on `AppState.startRefresh('bakalari', pauseAutomation: true)` verifying scope `'bakalari'`, in-memory `automation_paused: true`, untouched `config.json` on disk, and zero excuses/orders.
   - Wizard tests: verified Bakaláři login triggers early refresh; failed login does NOT; failed early refresh does not block wizard navigation.

---

## 8. Done when (and commit plan)

Implement only **after** this design note passes review, in 4 green commits (one per O-item, each with its own tests, never breaking the tree):
1. `F1c (O6): start paused Bakaláři refresh after wizard login test`
2. `F1c (O5): embed WakeupCard in wizard Telefon step`
3. `F1c (O4): full-page Limits editor with quick-pick value chips`
4. `F1c (O3): short Absence screen and single-calendar Plánovač sub-route` (+ tours, strings, `demo_data.py`, README & `docs/images/absences-*.png`)

**Done when:**
- `/absences` is short (header with *Limity* + *Plánovač*, 3 KPIs, optional `planner_next` shortcut, subject cards with M1 stacked budget bars); no new rail or *More* tab.
- `/absences/plan` has a single back arrow on phone and desktop (no duplicate top-bar arrow), Android Back returns to `/absences`, `/planner` and *Dnes* tip open `/absences/plan`, and at `390 × 844` the month calendar starts on the first screen.
- One month calendar shows past days greyed and non-tappable (past planned days keep *passed* look), supports single-day tap (whole day or partial lessons via M2 `pickerSlotsFor`), and *Vybrat více dní* multi-day selection with impact preview and single-save atomic `planEntries` confirmation; separate `CustomPlanDialog` is gone.
- `/absences/limits` is a full-width page with global defaults at top, clear default/custom subject rows, tappable already-used value chips + *Výchozí* clear chip, and *Nastavení → Limity* opens it.
- Wizard *Telefon* step embeds `WakeupCard` (switch, minutes, notification + exact-alarm permissions, next wake-up preview) while preserving B9 and *Přeskočit*.
- Verified Bakaláři login in the wizard starts a `'bakalari'` refresh via `startRefresh` with in-memory `automation_paused: true` (never saved to `config.json`); *Dokončit* still runs a normal `'all'` refresh (with B7 `already_running` if busy).
- Zero config keys changed; all safety rules intact; cs/en ARBs + `strings.dart` in sync; tutorials split (`absences` + `absences_plan`).
- Visual evidence in `build/qa-evidence/F1c/` at 390 px and 1280 px (cs/en, light/dark) for `/absences`, `/absences/plan` (single & multi-select), `/absences/limits`, and wizard *Telefon*.
- Core (`dart analyze && dart test`) and app (`flutter analyze && flutter test`, count >= 739) are completely green.
