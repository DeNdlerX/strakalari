# R3c review: F1c design note (`design-F1c.md`)

Reviewed 2026-11-19 at `qa-roadmap` @ `f8db00f` (base `main` @ `f8d5582`;
`main` has no commits the branch lacks). The note came in `12490c6`,
written from the owner's phone test and the reviewer's direction in
[`phase-3b.md`](phase-3b.md#owner-changes-need-design-f1cmd-first-no-code-before-it-passes)
(O3–O6). No O3–O6 code was written: `12490c6` touches only the note and
`f8db00f` only STATUS. The R3b code fixes in the same round passed
([`phase-3b.md`](phase-3b.md#re-review-2026-11-19)).

## Verdict: FAIL

The note has the right shape and is mostly right about the code. The
short Absence screen, the Plánovač and Limity sub-pages, the old
`/planner` link, the real Budík card in the wizard and the early setup
refresh are all designed on top of existing parts, with no new config key
and no change to how excuses are sent or lunches ordered. The reviewer
checked the early refresh closely: running it with automation paused in
memory is enough, nothing automatic can happen during setup.

Two findings block building from it:

- **M1:** the one calendar would lose a thing the app can do today. A day
  with one lesson already planned (say, a doctor at the 3rd lesson) could
  no longer get more lessons. The old custom dialog allowed it, and the
  note removes that dialog.
- **M2:** the test list promises that tests keep checks they can't keep,
  and leaves several tests without saying what happens to them. In R3
  that is how tests got deleted.

Nine smaller points (S1–S9). The ones a student would notice: Absence
could silently show the other term's numbers (S1); planning a single
lesson would cancel the lunch unless the student unticks it (S3); a value
typed on the limits page can be lost when leaving with the phone's Back
button (S4); tapping *Dokončit* while the early refresh still runs would
skip the full first refresh, so lunches would be missing for up to an
hour (S5).

---

## Must-fix

### M1 (O3, §2.3 item 6): a day that is partly planned can no longer get more lessons

- **Where:** `design-F1c.md` l.98–100 (a planned future day: single tap
  opens `showPlannedDialog`, multi mode `onTap: null`), l.124
  (`CustomPlanDialog` removed), l.298 (`alreadyPlannedLessonsAreLockedAndSplitThePick`
  "keeping every … assertion").
- **What is wrong:**
  - A day counts as planned when it is in `term.plannedDates`. Core fills
    that with every day an entry touches, also an entry for one lesson
    (`packages/strakalari_core/lib/src/planning/planner.dart:999`, through
    `entryDays`). Today's strip uses the same flag
    (`planner_view.dart:735`, `:776`), and the note keeps it.
  - So with the note's calendar, a student who planned only the 3rd
    lesson can't add lessons 1–2 or 4–5 of that day: a tap opens the
    existing plan, and multi mode ignores the day.
  - Today `CustomPlanDialog` allows it: planned lessons are locked and the
    pick splits around them (`plan_picker_test.dart:248`,
    `alreadyPlannedLessonsAreLockedAndSplitThePick`); only a fully planned
    day can't be tapped (`:290`, `fullyPlannedDaysAndHolidaysCannotBeTapped`).
    The note removes that dialog, so the feature is lost, and the test it
    says it keeps can't pass.
  - `showPlannedDialog` gets one entry: `plannedFor` returns the first
    entry that touches the day (`planner_controller.dart:293`). With two
    partial entries on one day, the calendar shows and removes only one.
- **What correct looks like** (in §2.3 item 6 and §7):
  - Decide from the day's M2 slots, not from `plannedDates` alone:
    - **Fully planned:** the day has taught slots and none is pickable
      because they are `planned`. Single tap opens the planned dialog;
      in multi mode the day can't be tapped (as today).
    - **Partly planned:** some slots `planned`, some pickable. Single tap
      opens the upgraded `PlanDayDialog` with *Vybrat jen některé hodiny*
      already open: planned lessons shown locked with `cal_tip_planned`,
      the rest pickable; the whole-day toggle means "all that are still
      pickable". Confirm builds the entries with `entriesForSelection`
      (the taught periods as `lessons`, so the pick splits around the
      planned ones, as today) and saves them with one `planEntries`. In
      multi mode a tap adds only the pickable lessons (today's `_tapDay`).
    - Both keep the planned colour. Say whether a partly planned day gets
      a marker.
  - A day with more than one entry: the planned dialog lists each entry
    with its own *Zrušit plán* (or say where the other entries are
    removed). Pick one and write it down.
  - Tests: `alreadyPlannedLessonsAreLockedAndSplitThePick` keeps its
    assertions (locked `3. Chemie`, split into `(null, 2)` and `(4, null)`)
    in single mode, and the same in multi mode;
    `fullyPlannedDaysAndHolidaysCannotBeTapped` keeps its assertions in
    multi mode, and in single mode a fully planned day opens the planned
    dialog; a day with two entries shows both.

### M2 (O3, §7 items 2, 3 and 7): the test list promises checks that can't hold, and leaves tests without a fate

- **Where:** `design-F1c.md` l.292–302 and l.321–322.
- **What is wrong:** §7 says the 12 `plan_picker_test.dart` tests keep
  "every single test name & assertion", and that `absences_view_test.dart`
  "keeps all existing tests". Checked against the files:
  - `plan_picker_test.dart` builds `CustomPlanDialog` directly
    (`buildPickerHost`, `:55–78`). Against the note's new UI:
    - `tappingADayTakesItOffWhole` (`:92`) first expects a disabled
      *Potvrdit* before any tap. On the new page a tap opens
      `PlanDayDialog`; there is no *Potvrdit* before it.
    - `tappingAPickedDayAgainUnpicksIt` (`:121`) and
      `daysInARowBecomeOneRange` (`:171`): *Potvrdit* becomes the multi
      bar's *Naplánovat* (`plan:multi_confirm`) and then the confirm in
      `PlanMultiDialog`.
    - `untickedLessonsStayAttended` (`:142`),
      `weekChangesAreShownAndCancelledLessonsLocked` (`:195`),
      `startedLessonsTodayCannotBePicked` (`:312`) and
      `wholeDaySwitchClearsAndRefillsTheDay` (`:366`, uses `preselect`):
      the lesson list is now inside `PlanDayDialog`, behind *Vybrat jen
      některé hodiny*.
    - `monthNavigationStaysInsideTheSchoolYear` (`:401`) passes
      `firstMonth` / `lastMonth` and expects the header `12/2026`. The
      note computes the bounds from the term and shows month names from
      `pick_months`.
    - `alreadyPlanned…` and `fullyPlanned…`: see M1.
  - `planner_view_test.dart`: `custom picker taps a day whole and
    confirms` (`:345`) taps `plan_custom`, which goes, and isn't in the
    note's list of what is preserved. P9a+b (`:505`) checks four
    equal-height `StatCard`s and *Limity* next to `plan_custom` on one row
    (`:608`); `PlannerPage` has no `StatCard`, no *Limity* and no
    `plan_custom`.
  - `absences_view_test.dart`: `F1b each subject renders once…` (`:180`)
    expects 4 `StatCard`s (`:275`); there will be 3. `F1 Absence tab …
    opens shared limits editor that saves to config` (`:117`) looks for
    `LimitsEditorContent` (`:168`), which goes. Its save check has to move,
    not disappear.
  - `absences_live_test.dart` case 2 (`:202`) checks two halves: 3 KPIs
    and `Meter` (stays on Absence), and `term_nothing`, the planned entry
    with unplan and the footer (moves to Plánovač). The note keeps only
    the Plánovač half.
  - `planner_live_test.dart` `LiveAbsencesView renders subjects, budgets
    and recommendations` (`:57`): the recommendations leave Absence. Not
    mentioned.
  - `tutorial_test.dart`: the F1b tour tests (`:560` on) aren't named:
    `planner tour is removed and absences tour has 4 merged steps`, the two
    skip tests (`:569`, `:582`), `LiveAbsencesView offers tour only when
    recommended days exist` (`:602`, whose offer rule the note changes),
    and `strings exist for every step` (`:345`, the route set).
  - `calendar_days_dst_test.dart`: the wide test (`:164`) compares the
    rows of 22 Oct and 12 Nov. In a one-month grid they are on different
    pages, and weekdays are columns. `custom dialog: October 2026 ends with
    Friday 30 Oct` (`:197`) builds `CustomPlanDialog`.
  - `settings_sections_test.dart:779` expects
    `find.byType(LimitsEditorContent)` to find nothing; the class goes.
  - In R3 a loose test list ended in deleted tests (R3 M1); in R3b it was
    M2 and S8.
- **What correct looks like:**
  - §7: one line per test that changes: file, test name, what it builds
    and taps afterwards, which assertions stay word for word, and which
    change, with the new expected value. At least the tests above.
  - For each assertion that moves, say which test takes it over (for
    example P9a's equal heights: `absences_view_test.dart:85` already
    covers the 3-card row; the limits save check: `limits_page_test.dart`).
  - Every test stays unless its code goes. One that really has to go is
    listed under *Deviations* with the reason. None is expected.
  - Baseline for F1c code: core 809 passed / 2 skipped, app 739 passed / 1
    skipped. The app count may only go up.

---

## Should-fix

### S1 (O3, §2.2): Absence would show whichever term was last picked in Plánovač

- **Where:** `design-F1c.md` l.62 ("the active/selected term");
  `absences_live.dart:40`, `:82` and `absences_view.dart:135` use
  `s.plannerTerm`.
- **What is wrong:** in F1b the term buttons sat on the same screen. F1c
  moves them to Plánovač. A student who looks at *2. pololetí* there and
  goes back sees the 2nd term's budget rows and `planner_next` on
  Absence, with nothing saying which term it is.
- **What correct looks like:** Absence always uses `yp.defaultTerm` (the
  current term) for the budget rows and `planner_next`; `plannerTerm`
  only changes Plánovač. Test: pick sem2 in `LivePlannerPage`, go to
  `/absences`: the budget rows are sem1's.

### S2 (O3, §2.3 item 6): days of the other term aren't defined

- **Where:** `design-F1c.md` l.81–84, l.93 and l.101.
- **What is wrong:** the months run from September to the selected term's
  closure, but a day can only be picked "within `[term.start,
  term.close]`". With *2. pololetí* selected in November, the student can
  page back to November–January: future school days of the 1st term. The
  note doesn't say how they look. Today's strip leaves days outside the
  selected term empty (`planner_view.dart:730`), so a future school day
  would look like no day.
- **What correct looks like** (reviewer's suggestion; another rule is fine
  if the note writes it down): each cell takes its look and options from
  the term it belongs to (`plan.terms`), so every future school day from
  today to the selected term's closure is coloured and can be tapped. The
  term buttons change the summary line, the recommended list, the
  warnings and the month the calendar opens on. Test: sem2 selected, page
  back to December, tap a future school day: the day dialog opens.

### S3 (O3, §2.3 item 6): planning some lessons would cancel the lunch by default

- **Where:** `design-F1c.md` l.105–113 and l.122; `planner_view.dart:1284`
  and `:1533` (`cancelLunch = true`); core `plannedLunchDays`
  (`planned_skips.dart:257–265`), which cancels the lunch on every day an
  entry touches, also a partial one.
- **What is wrong:** today, picking some lessons happens only in the
  separate custom dialog. F1c puts it one tap away in the normal day
  dialog. A student who plans only the 1st lesson for a doctor still eats
  at school, but gets the lunch cancelled unless they untick the box. A
  lunch cancelled after the cutoff can't be ordered back. The plan's F3
  already says a partial absence never cancels a lunch automatically.
- **What correct looks like:** when the picked lessons don't cover the
  whole day, *Odhlásit oběd* starts unticked (the student can tick it); a
  whole day keeps today's default (ticked). In `PlanMultiDialog` the box
  starts unticked when any chosen day is partial. Same `cancel_lunch` key,
  same staging, no change to the order path. Tests in
  `planner_dialog_test.dart` for both dialogs.

### S4 (O4, §3.1): leaving the limits page by Android Back or the rail can lose a typed value

- **Where:** `design-F1c.md` l.146 and l.170. `AutosaveField` saves on
  blur only (`settings_view.dart:78–80`), not in `dispose` (`:95–99`).
  Android Back runs `ShellBackScope` → `_stepBackOnPhone` → `context.go`
  (`scaffold.dart:105–155`) without unfocusing. The old dialog's *Zavřít*
  unfocused first (`absences_view.dart:82`) and then called
  `onLimitsUpdated` (`:90`), which is `s.save(const {})`
  (`absences_live.dart:25`).
- **What is wrong:** the note unfocuses only for the page's own back
  arrow. A student who types a new default limit and presses the phone's
  Back button (or clicks another rail item on the desktop) can lose it,
  with no message. And every save on the page is quiet; the old dialog
  ended with one normal save so the other screens and the phone's status
  notification picked up the new limits. The note drops it.
- **What correct looks like:** the note says how every way out (the back
  arrow, Android Back, the rail or bottom bar, any route change) saves the
  focused field first, and that leaving the page does the same
  `s.save(const {})` once. Tests: type in *Výchozí limit* and in a subject
  row, leave with Android Back (as `android_back_test.dart` does): both
  values are saved, and one normal save follows.

### S5 (O6, §5): *Dokončit* during the early refresh skips the full first refresh

- **Where:** `design-F1c.md` l.239. `wizard_controller.dart:623–631`
  (*Dokončit* calls `onFinishRefresh()` → `startRefresh()`);
  `activity.dart:312–313` (`claimFlight('refresh_running')` is false while
  any refresh runs).
- **What is wrong:** if the early Bakaláři run is still going when the
  student taps *Dokončit*, `startRefresh()` returns `false`, the wizard
  says `already_running`, and nothing starts the `'all'` run later. Strava
  menus and orders, and the student's own automatic modes, then wait for
  the next scheduled refresh (`check_interval_minutes`, 60 by default).
  The owner measured 6.6–8.7 s for one refresh; on the desktop the steps
  after Bakaláři (Strava off, the name, *Dokončit*) can take less. And
  "already running" is misleading there: the run that is going doesn't
  load Strava.
- **What correct looks like:** when the early run is still going at
  *Dokončit*, queue one normal `'all'` run (an in-memory flag in
  `AppState`, never saved). The early run's `finishRun` starts it through
  the normal `startRefresh` → session lock → `runRefresh`. *Dokončit*
  shows `wiz_finishing_refresh`. Tests: early run in flight at *Dokončit*
  → exactly one `'all'` run starts after it ends, without
  `pauseAutomation`; no early run → unchanged.

### S6 (O6, §5 and §7 item 6): start the early run once, and test that the pause holds

- **Where:** `design-F1c.md` l.214–217 and l.319–320;
  `wizard_controller.dart:465–472` (`continueTestStep`); `config.dart:122`
  and `:124` (`excuse_mode` and `strava_order_mode` default to `confirm`).
- **What is wrong:**
  - `continueTestStep` runs on every *Pokračovat* with an already verified
    login. Back to Bakaláři and forward again would start another full
    Bakaláři refresh each time (about 1 MB each in the owner's
    measurement).
  - With the default modes nothing automatic runs anyway, so a test with
    the default config passes also without the pause. It wouldn't notice
    if `runConfig` were replaced by `app.configData`.
- **What correct looks like:**
  - Start the early run once per verified Bakaláři fingerprint: remember
    it in memory in `AppState` (like `wizardVerified`). The continue path
    starts it only when that fingerprint hasn't had one, which also covers
    a resumed wizard.
  - The O6 test uses `excuse_mode: auto`, and a fake app whose outbox read
    succeeds and whose `excusePending` counts calls (run as
    `refreshReportsNewsAgainstTheCache` does, with `state.createApp` and
    `state.spawn`). The early run: 0 calls, `automation_paused_log` in the
    log, and `config.json` on disk has no `automation_paused: true`. The
    same run without `pauseAutomation`: `excusePending` is called, so the
    test can see a send.

### S7 (O3): work out a month's lessons once, not per cell

- **Where:** `design-F1c.md` l.95–104 and l.119; `pickerSlotsFor`
  (`controllers/planner.dart:400`).
- **What is wrong:** every cell needs its day's lessons to decide whether
  it can be tapped and how it looks, the bar needs them for the hours, the
  dialog for its list. `LivePlannerPage` rebuilds on every `AppState`
  update, including refresh progress. The reviewer timed `pickerSlotsFor`
  on `tools/demo_data.py` data in a debug test run: about 92 ms for one
  pass over a 31-day month. A release build is faster, but the calendar is
  now the main thing on the page.
- **What correct looks like:** build one `Map<DateTime, List<PickerSlot>>`
  for the visible month per build (or cache it in `AppState`, keyed by
  `dataRev`, the planned entries and today) and use it for the cells, the
  bar and the dialog. Say so in §2.3.

### S8 (§8 *Done when*): phone evidence for O5 and O6

- **Where:** `design-F1c.md` l.334–343.
- **What is wrong:** the Telefon step exists only on Android and asks for
  permissions. It is the F1 notifications step, which the reviewer must
  see on the phone. The *Done when* list has 390 / 1280 px captures only.
- **What correct looks like:** add: on the Pixel, the `.test` app only,
  against the demo server: the Telefon step showing `WakeupCard`;
  switching the alarm on (the notification prompt); *Povolit přesné
  budíky* → the system screen → back → the warning is gone; the next
  wake-up shown once the early refresh is done; after *Dokončit*,
  `adb -s 2C221FDH3002NZ shell dumpsys alarm` lists the `.test` alarm;
  Aktivita shows the early `bakalari` run and then the `all` run. Files in
  `build/qa-evidence/F1c/`.

### S9 (§6, strings): name the reused keys and keep the house style

- The three KPI cards: *Varovné předměty* / *Kritické předměty* in §2.2
  aren't the app's texts. Say that Absence reuses `_threeCardStats`
  (`absences_view.dart:329`) as it is: `avg_absence`, `warn_subjects`
  (*S varováním*), `crit_subjects` (*Kritické*). Then `_fourCardStats` and
  `stat_warn_crit` go, as the note says.
- `limit_use_default` in English: `Default ({pct:g} %)`, with the space,
  like `abs_no_limits` (`All subjects use the default limit of
  {pct:g} %.`).
- The three changed texts (`overview_hint`, `tut_abs_stats_body`,
  `tut_plan_strip_body`): write the new cs and en wording into the note,
  like the new keys. `tut_plan_strip_body` keeps its even-spread sentence
  (`tutorial_test.dart:663`).

---

## Notes (no action needed)

- **N22 (accepted):** the sub-routes `/absences/plan` and
  `/absences/limits` inside the shell, `/planner` → `/absences/plan`, no
  new rail or *Více* entry, the new tour id `absences_plan` (an old
  `planner` in `tutorials_done` stays harmless, N9), reusing `WakeupCard`
  and `pickerSlotsFor`, no config key, 800 string keys (still `>= 790`).
- **N23 (O3, navigation detail):** on the phone the bottom bar keeps
  *Více* selected only for a route in `moreRoutes`; any other route
  highlights *Dnes* (`scaffold.dart:296–304`; the side rail already falls
  back to *Více*). So the note's `navRoute` is needed for the bottom bar
  too, not only the wide rail. The real route stays for `tutorialBegin`, `ViewErrorBoundary` and
  `ShellBackScope`. The top-bar arrow already doesn't show on the
  sub-routes (they aren't in `moreRoutes`, `scaffold.dart:626–628`), so
  the note's suppression only matters if `navRoute` is used there.
- **N24 (O4, owner):** `/absences/limits` always goes back to Absence,
  also when opened from *Nastavení → Limity*. Accepted: one tap from where
  the student was. If the owner wants it to go back to Settings, say so.
- **N25 (O5, one way):** the note keeps the old lone switch "only in
  headless/non-wired unit tests". A screen that exists only for tests
  means the tests don't test the real step. Better: on Android the step
  always shows `WakeupCard`, and tests pass a fake `WakeupPhone`. Not
  required.
- **N26 (O6, a failure during setup):** a failed early run queues the
  normal error dialog, and the wizard page shows it (`router.dart:166`).
  So a slow Bakaláři server can show *Obnovení selhalo* during setup. That
  is what the review direction asked ("sees it like any failed refresh");
  accepted.
- **N27 (O6, safety, checked):** the in-memory copy is enough.
  `runRefresh` never writes the config. The only gate on the automatic
  steps reads the config it is given (`refresh.dart:590–598`);
  `AppState.automationPaused()`, which reads the file, is used only by the
  Activity banner. Scope `'bakalari'` is accepted by `startRefresh`
  (`activity.dart:314`). The first sync reports no news (`news.dart:106`,
  `:147`). `_refreshWork` still stops when there are no credentials
  (`activity.dart:330`).

---

## What the reviewer verified, and how

1. **The note against the code:** every file, line, class, key and method
   it names was looked up: `router.dart` (routes, `routeForLocation`,
   the `/planner` redirect, `popPendingMessages` on `/wizard`),
   `scaffold.dart` (`backTarget`, `ShellBackScope`, `_stepBackOnPhone`,
   the three layouts' selection, the top-bar arrow, `pendingRoute`),
   `tours.dart` and `controllers/tutorial.dart` (route matching, offer,
   skip flags), `planner_view.dart` (`_cell`, `showPlanDayDialog`,
   `showPlannedDialog`, `PlanDayDialog`, `CustomPlanDialog`,
   `PickerSlot`), `planner_controller.dart` (`plannedFor`, `planEntries`),
   core `entriesForSelection`, `plannedLunchDays` and `plannedDates`,
   `absences_view.dart` / `absences_live.dart` (KPI rows, the limits
   dialog, `plannerTerm`), `settings_view.dart` (`AutosaveField`,
   `LimitsEditorContent`, the Settings link), `wakeup_card.dart`,
   `settings_live.dart`, `wizard_controller.dart` and `wizard_live.dart`
   (test, save, permission and *Dokončit* paths), `activity.dart`
   (`startRefresh`, `_refreshWork`, `_refreshLocked`) and core
   `refresh.dart` (`runRefresh`, `_autoPhases`). The gaps are M1, M2 and
   S1–S9.
2. **The tests §7 names:** every test in `app/test` that uses
   `CustomPlanDialog`, `showCustomPlanDialog`, `LimitsEditorContent`,
   `plan_custom`, `StatCard` counts, the `absences` tour or the planner
   grid was read against the note (M2).
3. **Strings:** a script checked every reused key in both ARB files (all
   there, 796 keys each). `plan_custom`, `plan_custom_hint`,
   `stat_warn_crit` and `open_absences` have one use each in `app/lib`,
   which the note removes, plus the tests in M2.
4. **O6 safety:** read the whole refresh path from `startRefresh` to
   `finishRun` and every reader of `automation_paused` (grep over core
   `lib` and `app/lib`), N27.
5. **Timing:** a throwaway test (not committed) timed `pickerSlotsFor`
   on `tools/demo_data.py` data, S7.
6. **No O3–O6 code** and no change to config files, parity fixtures or
   ARB files in `12490c6` / `f8db00f`.
7. **Suites and hygiene:** see the re-review in `phase-3b.md` (same
   commit: core 809 passed / 2 skipped, app 739 passed / 1 skipped; no
   upstream; no trailers; no personal files).
8. **Not checked:** the phone (no code yet); macOS and iOS builds (not
   possible here).
