# R3b review: F1b design note (`design-F1b.md`) and O1

Reviewed 2026-11-17 at `qa-roadmap` @ `acb0fd0` (base `main` @ `f8d5582`;
`main` has no commits the branch lacks). Commits since R3 re-review 4
(`6d4c925`):

- `4eea335` (O1, code: refresh notifications off by default);
- `acb0fd0` (F1b design note and STATUS, docs only).

No F1b code was written before this review.

## Verdict: FAIL

**O1** does what the owner asked: *Dokončená aktualizace* and *Neúspěšná
aktualizace* are off by default, the other eleven events stay on, and
Settings shows the new defaults. Both new tests fail on the old code. But
O1 opened a hole in the "fail loudly" rule (M1): when Strava fails to load
and the automatic excuse step also fails in the same refresh, the student
now gets **no notification at all**. Before O1 they got "Obnovení selhalo".
The fix is a few lines, and the reviewer tested it.

**The F1b note** has the right idea and is mostly correct about the code:
one Absence screen, no Plánovač tab, each subject once, the planner math
and dialogs reused, no config keys, the send and lunch paths untouched. But
it isn't complete enough to build from yet. The list of tests to adapt
misses two test files, and it doesn't say whether `PlannerView` stays (M2).
In R3, a loose test list ended in deleted tests. Several smaller gaps follow
(S1–S7): empty states that can't happen, open choices on the subject card
and the tutorial, an unclear string list, the README, and a duplicate
*Nastavení* in the Android *Více* list.

---

## Must-fix

### M1 (O1, `4eea335`): a failed automatic send can now pass without any notification

- **Where:** `app/lib/controllers/activity.dart:427–435` (`_refreshLocked`),
  together with `packages/strakalari_core/lib/src/platform/notifier.dart:41–42`.
- **What is wrong:**
  - A refresh can end with a fetch error (for example Strava didn't load)
    **and** a failed auto phase in the same run (for example auto-excuse:
    the Komens outbox couldn't be read, or an excuse failed to send). In
    that case `_refreshLocked` throws the first fetch error at `:432–435`
    before it reaches the `automation_failed` notification at `:445–451`.
    The only notification of that run is `refresh_failed` (`:466`).
  - Before O1, `refresh_failed` was on by default, so the student still
    heard "Obnovení selhalo: …". Since O1 it is off by default, so the run
    sends nothing. Excuses that should have gone out in the student's name
    didn't, and nobody is told.
  - CONTRIBUTING §5, *Fail loudly*: an auto phase that didn't do its job is
    surfaced by the UI and the notifications. The owner kept
    `automation_failed` on. O1 must not switch it off by the back door.
  - **Reviewer's test** (throwaway, not committed): a real `AppState` with
    `excuse_mode: auto` and a Strava login, and a fake app whose Strava
    fetch throws and whose outbox read never succeeds
    (`lastOutboxSyncOk` stays `false`, so auto-excuse records
    `auto_excuse_outbox_unknown`). Notifications sent:
    - at `6d4c925` (before O1): `[refresh_failed]`;
    - at `acb0fd0`: `[]`;
    - without the Strava error, both commits send `[automation_failed]`.
- **What correct looks like:** one commit, `O1: notify a failed auto phase
  also when a fetch failed (R3b M1)`.
  - In `_refreshLocked`, before throwing the fetch error, send the
    automation notification when an auto phase failed for a reason other
    than an empty Strava account:
    ```dart
    if (fetchErrors.isNotEmpty) {
      // O1 turned refresh_failed off by default: a failed auto phase in
      // the same run still gets its own notification (fail loudly).
      if (autoErrors.isNotEmpty && !result.onlyLowBalance) {
        notifyEvent(
            'automation_failed',
            Strings.format('automation_failed_body',
                {'detail': failureDetail(autoErrors.first.$2)}));
      }
      // ignore: only_throw_errors
      throw fetchErrors.first.$2;
    }
    ```
    Nothing else changes: the fetch error is still thrown, reported and
    recorded as a failed run, exactly as today.
  - The reviewer tried exactly this change at `acb0fd0`: `flutter analyze`
    clean, all 719 app tests pass, and the reviewer's three cases below
    pass.
  - Add the test to `app/test/app_state_excuses_and_planner_test.dart`
    (it already has `_CallbackNotifier` and a `Strakalari` fake). It must
    fail on `acb0fd0`. Use `http://127.0.0.1:18080` as the Bakaláři
    address and default `notifications` (none saved):
    1. `excuse_mode: auto`, Strava login, `fetchStravaData` throws,
       `syncWebExcusesToHistory` overridden to return 0 (outbox never
       read) → the notifications include `automation_failed` and not
       `refresh_failed`;
    2. the same with `excuse_mode: confirm` → no notification at all
       (O1 still holds);
    3. `excuse_mode: auto` without the Strava error → `automation_failed`
       (unchanged).

    The fake needs `absencePercentages => {'M': 0.0}`,
    `fetchBakalariData() async {}` and `close() {}`, like `_NewsRefreshApp`.
    Run it with `state.createApp`, `state.spawn` and
    `state.startRefresh('all')`, as `refreshReportsNewsAgainstTheCache`
    does.
  - Add one line under *Deviations*: O1 also changed `activity.dart`, so a
    failed auto phase still notifies when a fetch failed in the same run.

### M2 (F1b §4, §7): the test list is incomplete, and it doesn't say whether `PlannerView` stays

- **Where:** `design-F1b.md` §4 (l.147–157) and §7 (l.213–241).
- **What is wrong:**
  - §4 removes `LivePlannerView` and moves the planner sections into
    `AbsencesView`, but doesn't say whether the `PlannerView` class
    stays. Many tests build it directly.
  - Two test files that build `LivePlannerView` or `PlannerView` are
    missing from §7:
    - `app/test/planner_live_test.dart:55` (`LivePlannerView renders
      budgets and recommendations`);
    - `app/test/calendar_days_dst_test.dart:146` (a `PlannerView` used by
      the widget tests at `:164`, `:181` and `:197` to open the planner
      dialogs across a clock change).
  - Assertions that will have to change are not named:
    - `planner_view_test.dart:120`, the `planner_title` heading;
    - `planner_view_test.dart:397–399` (P9b), `see_absences` next to
      `plan_custom`. That button goes away;
    - `mobile_narrow_shell_test.dart:197–214` (`backStepsUp`, route
      `planner`) and `:171`, `:271` (the `/planner` loops);
    - `more_page_test.dart:19`, `:31`, `:69–71`;
    - `widget_test.dart:64`, `tutorial_test.dart:349`,
      `android_back_test.dart:115`;
    - `ui_views_test.dart:388–392` and `scroll_keeps_offset_test.dart:39`
      (`LivePlannerView`; note its `now:` parameter, which
      `LiveAbsencesView` will need too).
  - In R3, two still-valid tests were deleted because the note's test
    list was loose (R3 M1). PLAN rule 8 forbids that.
- **What correct looks like:**
  - §4: decide and write down what the planner part becomes. One way that
    keeps the tests simple: keep the planner sections and their dialogs
    (`showPlanDayDialog`, `showPlanAllDialog`, `showPlannedDialog`,
    `showCustomPlanDialog`) in one widget that `AbsencesView` embeds, with
    the same constructor arguments `PlannerView` takes today. Then the DST
    and dialog tests change only the class they build.
  - §7: one line per test file that uses `PlannerView`,
    `LivePlannerView`, route `planner` or tour `planner`, naming each test
    that changes and what it asserts afterwards. Every test in those files
    stays. If one really has to go with its code, it is listed under
    *Deviations* with the reason. None is expected.
  - Baseline for F1b: core 809 passed / 2 skipped, app 719 passed / 1
    skipped, plus M1's new tests. The app count may only go up.

---

## Should-fix

### S1 (F1b §3 item 3, §7): the empty and partial states don't match how the data is built

- **Where:** `design-F1b.md` l.76–83 and l.238–239.
- **What is wrong:**
  - `subjectStates()` returns nothing without a timetable
    (`app/lib/controllers/planner.dart:70`), so the Absence screen has no
    subjects without a timetable. `yearPlanDataFor` is `null` only without a
    timetable (`planner_live.dart:99`).
  - So "absences present, no planner data (`plan == null`)" never happens
    with real data. The §7 test "`Meter` fallback shows when no timetable
    exists" can't be built with a real `AppState`.
  - Two planner texts aren't mentioned: `term_fresh` (one line under the
    term buttons on a fresh term, `planner_view.dart:409–416`) and the
    planner intro paragraph (`planner_desc` + `plan_buffer_note`,
    `:270–273`, `:359`; four lines on a phone).
- **What correct looks like:**
  - Rewrite §3 item 3 to the three real cases:
    1. no subjects (no timetable, or no absence) → `no_data`, plus
       `planner_need_refresh` when there's no timetable and
       `need_credentials` in `demoMode`;
    2. subjects but `term == null` (the year's absence is closed) → the 3
       Absence KPI cards, subject cards with `Meter`, and `term_nothing`;
    3. a term → the full screen. A subject with no budget row in the
       selected term shows `Meter` and today's detail line.
  - Say what happens to `term_fresh` and the intro paragraph. Reviewer's
    suggestion, given the owner's "as little text as possible": keep
    `term_fresh` (one line, only on a fresh term); drop the intro
    paragraph and put one short sentence about the reserve into the new
    `tut_abs_subject_body`.
  - §7: test cases 1–3 with a real `AppState` where possible.

### S2 (F1b §3 item 9): the merged subject card leaves three things open

- **Where:** `design-F1b.md` l.118–133.
- **What correct looks like:**
  - **Match key:** the budget row is found by canonical name, as today
    (`AbsencesController.canonSubject`, `absences_controller.dart:91`,
    `:113–114`). `TermPlanData.budgets` carries only `name`. Both lists
    come from the same `subjectStates()`, so there is no budget row
    without a subject. Say so in the note.
  - **Badge label:** say which text the one badge shows. Suggestion: the
    label of the more severe status (`state_*` for the absence status,
    `budget_*` for the budget status), and the budget label on a tie,
    because it belongs to the selected term. Colour as in the note.
  - **Detail lines:** reuse the existing strings. With a budget row:
    `budget_final` (*na konci ~{p} % (limit {limit} %)*) and
    `budget_line` (*volno … · naplánováno … · rezerva …*). Without one:
    `col_limit` / `safe_to` / `col_safe`, as `AbsencesController.detail`
    does today. Then `abs_current_pct` isn't needed: the % shows as a bare
    number, as the note's own card description says.

### S3 (F1b §6, tutorials): three decisions for the merged tour are missing

- **Where:** `design-F1b.md` l.177–199.
- **What is wrong and what correct looks like:**
  - **When the tour is offered.** Today the planner tour starts only once
    the term has recommended days (`planner_live.dart:211–216`). The
    Absence tour starts on every Absence build (`absences_live.dart:74`).
    If the merged `absences` tour runs while there are no recommended
    days, `plan_pick` is skipped, and because the tour then counts as
    done, it is never shown later. Pick one and write it down. The
    reviewer suggests offering the merged tour only once recommended days
    exist (today's stricter rule).
  - **Existing users.** `tutorials_done` already holds `absences` and/or
    `planner`. With the id `absences`, someone who finished the old
    Absence tour never sees the planning steps, and someone who finished
    only the planner tour sees them again. The reviewer accepts "keep the
    id `absences`, no migration" (*Přehrát návody znovu* in Settings shows
    them all again), but the note must say it.
  - **Skip flags.** `tutorialStepSkipped` lives in `AppState`
    (`app/lib/controllers/tutorial.dart:105–106`), so the flags must come
    from `AppState` (timetable, `yearPlan()`, the selected term's
    recommended days), not from `AbsencesView`. Remove the "or".
  - **`plan_budget`.** The merged tour drops the `plan_budget` step but
    §3 keeps its anchor. Say whether the step, its anchor and
    `tut_plan_budget_*` go. Suggestion: drop all three; `abs_first` sits
    on the same list.

### S4 (F1b §6, strings): give the exact list of keys

- **Where:** `design-F1b.md` l.201–209.
- **What is wrong:** "`abs_horizon_tightest` / `abs_days_left`" doesn't
  say which key holds which text. `abs_current_pct` isn't used by the
  layout. `nav_planner` stays "only if needed". No key to remove is listed
  except `see_absences`.
- **What correct looks like:**
  - One table of every new key: key, cs, en, where it is used. Reuse
    before adding: `planner_horizon` (*Školních dní zbývá*),
    `stat_tightest`, `stat_can_afford`, `stat_planned`, `budget_final`,
    `budget_line`.
  - One list of keys removed from both ARB files and `strings.dart`, each
    checked unused by grep after F1b. Likely candidates: `see_absences`,
    `nav_planner`, `warn_subjects`, `crit_subjects`, `section_budgets`,
    `planner_desc`, `plan_buffer_note`, `tut_plan_budget_title/body`.
  - Keep `planner_title` (`strings_table_parity_test.dart:89`).

### S5 (F1b, missing from the note): README and its pictures

- **Where:** `README.md:53`, `:59–60` and `README.en.md:53`, `:59–60`
  describe *Plánovač* as its own screen and show
  `docs/images/planner-cs.png` / `planner-en.png`.
  `tools/parity/capture_screens.dart:68` still captures `planner`.
- **What correct looks like:** add to the note that the README (cs and en,
  short and non-technical) says Absence also plans days off, and that its
  picture shows the merged Absence screen, captured from demo data with
  `capture_screens.dart` (with `planner` removed from its list). The old
  `planner-*.png` are replaced or removed. `docs/SCHOOL_PRESETS.md:5`
  ("the Planner") names the feature, not the tab, and may stay.

### S6 (F1b §2): the Android *Více* list would show *Nastavení* twice

- **Where:** `app/lib/features/more.dart:35–42` (`visibleEntries`);
  `design-F1b.md` l.31–33.
- **What is wrong:** on Android the list is built as `entries.take(3)`,
  then the alarm, then `entries.last`. With `planner` removed, `entries`
  has three items, so `take(3)` already includes *Nastavení*, and it
  appears twice.
- **What correct looks like:** §2 says to insert the alarm before the last
  entry (`entries.take(entries.length - 1)`), and the *Více* test checks
  the exact Android list `absences, activity, alarm, settings`.

### S7 (F1b): no *Done when* list, and the P9b check must use a new student's setup

- **Where:** the whole note; `design-F1b.md` l.233–236.
- **What correct looks like:**
  - F1b isn't in PLAN, so the note is its only spec. Add a short *Done
    when* list the reviewer can tick: one Absence screen; no *Plánovač* in
    the rail or *Více*; `/planner` lands on `/absences`; the *Dnes* tip
    opens Absence; every subject shown once; the planner dialogs and the
    lunch-cancel option unchanged; tutorials and strings as §6 says;
    README; screenshots at 390 / 1280 px, cs / en, light / dark; the test
    count not lower.
  - P9b on the merged screen: the adapted test uses what a new student
    has, so no own subject limits and the *no limits* banner showing,
    plus the warnings card, two terms and four KPI cards. *Přehled
    pololetí* must still end above 708 px at 390 × 844. The `see_absences`
    check becomes *Limity* and *Naplánovat vlastní termín* on one row.
  - Commits: as in F1, several green `F1b:` commits, each with its tests.

---

## Notes (no action needed)

- **N1 (F1b, section order; STATUS asks the reviewer):** accepted as the
  note has it: KPIs, the calendar strip, recommended days, then the
  subjects. The calendar stays on the first phone screen (P9b), the *Dnes*
  tip lands on it, and the KPIs, the tightest-subject line and the
  warnings card name the subjects in trouble above it. If the owner
  prefers the subjects first, that's a swap of two blocks and changes
  nothing else.
- **N2 (F1b, `/planner`):** the redirect to `/absences` is accepted. It
  doesn't exist yet (the note says "keep"; it means "add"). The only
  caller of `go('planner')` is the *Dnes* tip (`today_view.dart:128`),
  which the note changes. The Android code holds no route names.
- **N3 (F1b, not in PLAN):** the owner asked for it word for word (STATUS,
  *D1 / F1 limits and tabs*), and it was split off from F1 at the R3a
  re-review. Accepted as the owner's go.
- **N4 (O1, existing installs):** the two events are off also for people
  who installed earlier, unless they switched them on themselves
  (Settings only ever saved the switches that were touched). That is what
  the owner asked. The consequence: a broken login or a Bakaláři outage
  is now visible only in the app (Aktivita, and the error dialog when the
  app is opened), not as a phone notification, and automatic excuses
  don't go out until it's fixed. It can be switched back on in
  *Nastavení → Oznámení → Neúspěšná aktualizace*.
- **N5 (O1, scheduler):** `scheduledJobFailed`
  (`activity.dart:292–306`) also uses `refresh_failed`, so a refresh job
  that crashes outside the worker is silent by default too. That falls
  under the owner's words; no action.
- **N6 (O1, deviations accepted):** the four `notify` tests in
  `notifier_test.dart` now pass `{'refresh_done': true}`, so they still
  test dispatch and fallback; `defaultsToOn` uses `new_mark`; `knownEvents`
  checks every event's default one by one. Settings now reads
  `core.isEnabled`, the same rule the sender uses, which is needed for the
  switches to show the new defaults. No config key changed:
  `notifications` still defaults to `{}` in `config.dart:141` and
  `config.example.json:72`.
- **N7 (O1, screens):** only two switch defaults changed on *Nastavení →
  Oznámení*, no layout. The widget test covers it, so no captures.

---

## What the reviewer verified, and how

1. **Suites** (worktree, Flutter 3.44.8 / Dart 3.12.2):
   - `dart pub get --enforce-lockfile`: OK.
   - Core: `dart analyze` no issues; `dart test` **809 passed, 2
     skipped** (808 at R3 re-review 4 plus `refreshEventsDefaultOff`; the
     skips are the old POSIX ones).
   - App: `flutter analyze` no issues; `flutter test` **719 passed, 1
     skipped** (718 plus `O1 notification defaults`).
   - Use these counts as the baseline for the re-review.
2. **O1's tests catch the change:** in a throwaway worktree (removed
   afterwards), `4eea335`'s `notifier_test.dart` and
   `settings_sections_test.dart` were copied onto `6d4c925`.
   `knownEvents`, `refreshEventsDefaultOff` and the `O1 notification
   defaults` widget test fail there with assertions (`Expected: false,
   Actual: true`). The four adapted `notify` tests pass on both, as they
   should. On `acb0fd0` all pass.
3. **Reviewer's own tests** (not committed): the M1 case at `6d4c925`
   (`[refresh_failed]`), at `acb0fd0` (`[]`), and with the suggested
   change at `acb0fd0` (`[automation_failed]`; confirm mode with the
   Strava error alone: no notification; auto-excuse failing alone:
   `[automation_failed]`). With the change, the whole app suite passes
   (719 + the reviewer's 3).
4. **Every reader of the notification settings:** the update check
   (`activity.dart:235`, through `update.dart:349`), `scheduledJobFailed`
   (`:303`) and `notifyEvent` (`:542`, used by `excuses.dart:547/556`
   and `lunches.dart:296`) all end in core `notify`, which asks
   `isEnabled`. No other code keeps its own default (grep over
   `app/lib`, core `lib` and the Android Java).
5. **The design note against the code:** every route, key, anchor, string
   and file it names was looked up. Correct: `shellRoutes` (8),
   `narrowTabs`, `moreRoutes`, `MorePage.entries`, `routeForLocation`,
   the *Dnes* tip (`today_view.dart:128`), `settings:go_absences_limits`,
   `see_absences`, the anchors `abs_stats`, `abs_first`, `plan_strip`,
   `plan_first`, `plan_budget`, the P9b compact rows, `tutorialStepSkipped`,
   `planner_title` in the string test. The gaps are M2 and S1–S7.
6. **Scope:** `4eea335` touches only `notifier.dart`, the Settings
   notification switches and their two tests. `acb0fd0` is docs only. No
   F1b code, no phase 4 work.
7. **Config keys and strings:** no key added, removed or renamed;
   `config.example.json`, `config.dart` and `test/parity/` match `main`.
   No new UI string in O1.
8. **Safety rules:** O1 changes only which events notify by default.
   `runRefresh`, the session lock, `sendExcuse` / `HistoryLock`, the audit
   and `automation_paused` are untouched. No new `catch`. The fail-loudly
   hole is M1. The F1b note leaves `controllers/planner.dart`, the plan
   dialogs and the lunch-cancel staging untouched.
9. **Test integrity:** since `6d4c925`, only `notifier_test.dart` (+1
   test, inputs of four tests changed, N6) and `settings_sections_test.dart`
   (+1 group) changed. No test removed, no `skip:`, no `try`/`catch`
   around assertions, no host.
10. **Phone:** not checked. `adb devices` showed only a stale offline
    emulator; this round has no phone item.
11. **Hygiene:**
    - Both commits touch only the six files above; no personal files or
      screenshots.
    - Both are by the configured user, with no `Co-Authored-By`,
      `Claude-Session` or "Generated with" lines.
    - `qa-roadmap` has no upstream, so nothing was pushed. `main` has no
      commits the branch lacks.
    - The worktree's uncommitted `generated_plugin*` files are the known
      Flutter line-ending churn.
12. **Not checked:** macOS and iOS builds (not possible here), and the
    phone (not connected).
