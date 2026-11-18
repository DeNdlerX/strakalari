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

---

## Re-review 2026-11-18

Reviewed at `qa-roadmap` @ `8756d0e` (base `main` @ `f8d5582`; `main` has
no commits the branch lacks). Commits since the review (`7479a97`):

- `9211e90` (O1, code: R3b M1 and its three tests);
- `a39ccf3`, `017963c`, `d3f5b66`, `ef57141`, `ead4ddc`, `1798aad`,
  `bdc9af4`, `386958c` (`design-F1b.md` only, one per finding);
- `8756d0e` (STATUS).

Still no F1b code.

### Verdict: PASS WITH FIXES

**O1 is done.** The hole from M1 is closed with the change asked for: when
Strava fails to load and an automatic excuse fails in the same refresh, the
student gets *Automatika selhala* again. The new test fails without the fix
and passes with it.

**The F1b note** now answers every R3b point: what replaces `PlannerView`,
the three real data cases, the subject card, the tutorial, the exact
strings, the README, the Android *Více* list and a *Done when* list. Three
gaps are left (S8–S10). The most important one: on a closed school year the
note would hide the list of planned days off. Those days can still cancel a
lunch, so the student must keep seeing them and be able to remove them.
The other two are a test the list still misses (plus two assertions it
doesn't name) and four code places that still name the old Plánovač tab.
All three are text changes to the note.

### R3b findings, checked

- **M1 fixed** (`9211e90`). `_refreshLocked` (`activity.dart:432–443`)
  now sends `automation_failed` before it throws the fetch error, only when
  an auto phase failed and not for an empty Strava account. The fetch error
  is still thrown, reported and recorded as a failed run. No new `catch`.
  Test case 1 fails on `7479a97` (`Expected: contains 'automation_failed'`,
  `Actual: []`) and passes on `9211e90`. Cases 2 and 3 pass on both, as
  they should: they pin behaviour that didn't change. The *Deviations*
  line is in STATUS (l.86). Accepted.
- **M2 fixed, with one gap (S8).** §4 decides: `PlannerView` becomes
  `PlannerSections` with the same arguments (minus `onOpenAbsences` and
  `updatedLabel`), the dialogs stay, `LiveAbsencesView` gets `now:`. §7 has
  a line for each of the 11 test files that use `PlannerView`,
  `LivePlannerView`, route `planner` or tour `planner` (checked by grep
  over `app/test`), and names the three files that stay unchanged.
- **S1 fixed, with one gap (S9).** §3 item 3 has the three real cases;
  `term_fresh` stays; the intro paragraph goes, with one reserve sentence
  in `tut_abs_subject_body`.
- **S2 fixed.** Match by `AbsencesController.canonSubject`
  (`absences_controller.dart:113`); the badge tiers match the planner's own
  colours (`planner_view.dart:1152–1163`); `budget_final` / `budget_line`
  and `AbsencesController.detail` are reused.
- **S3 fixed.** The offer rule is today's planner rule
  (`planner_live.dart:211–216`); the id stays `absences`, no migration; the
  skip flags come from `AppState` through `tutorialStepSkipped`
  (`tutorial.dart:105`). `yearPlan()` is cached per input
  (`planner.dart:328`), so reading it from the skip check is cheap. The
  `plan_budget` step, anchor and strings go.
- **S4 fixed.** Two new keys with cs and en; every reused key exists in
  both ARB files; seven removed keys listed. The table shrinks from 800 to
  795 keys and stays above the `>= 790` check
  (`strings_table_parity_test.dart:90`). `abs_no_limits` has `{pct:g}`, so
  the `:115` format test can move to it.
- **S5 fixed.** README cs and en, `capture_screens.dart:68`, the
  `planner-*.png` pictures.
- **S6 fixed.** `entries.take(entries.length - 1)` gives `absences,
  activity, alarm, settings` on Android.
- **S7 fixed.** §8 has the *Done when* list and the commit plan; §7 has the
  new student's P9b setup.

---

### Should-fix

#### S8 (F1b §7, l.341–352): `planner_view_test.dart` still misses one test and two assertions

- **Where:** `design-F1b.md` l.341–352; `app/test/planner_view_test.dart`.
- **What is wrong:**
  - The file has 12 widget tests that build `PlannerView`. The note names
    11. Missing: `empty state asks for credentials when timetable exists`
    (`:98–107`). It builds `PlannerView(plan: null, hasTimetable: true)` and
    expects `need_credentials`. In the merged screen (§3 case 1)
    `need_credentials` shows only in demo mode, as Absence does today
    (`absences_view.dart:127`). So this test can't pass unchanged, and the
    note doesn't say what it becomes. That is how tests got deleted in R3.
  - `year plan renders stats, calendar, budgets, planned` ends with
    "Intro carries the reserve note":
    `expect(find.textContaining('10'), findsWidgets)` (`:129–130`). The
    intro goes. On the merged screen some other `10` is always there (a
    date such as *5. 10.*), so the line would keep passing while it checks
    nothing.
  - P9a+b: the note lists only the new assertions. It doesn't say that the
    existing ones stay.
- **What correct looks like:** in §7's `planner_view_test.dart` line:
  - `empty state asks for credentials when timetable exists`: pumps
    `AbsencesView` with no subjects, `hasTimetable: true` and
    `demoMode: true` and expects `need_credentials`; the same with
    `demoMode: false` expects `no_data` and no `need_credentials`. The test
    stays.
  - `year plan renders…`: the `'10'` line is replaced by a check of where
    the reserve now lives: in `tutorial_test.dart`, `tut_abs_subject_body`
    mentions the reserve in cs and en (for example `rezerv` / `reserve`).
    Removing the old line goes under *Deviations*: "the planner intro
    paragraph was removed by F1b".
  - P9a+b keeps its existing checks: 4 `StatCard`s with equal heights per
    row (`:392–394`) and both semester buttons on one row (`:401–403`).
  - `custom picker taps a day whole and confirms` finds `PlannerView` by
    type (`:270–271`): say which class it finds afterwards.

#### S9 (F1b §3 item 3 case 2, l.84–89): a closed school year would hide the planned days off

- **Where:** `design-F1b.md` l.84–89 (case 2) and l.166–167 (item 10).
- **What is wrong:**
  - Today `PlannerView` shows *Naplánované* and the calendar footer also
    when there is no term: `term_nothing` at `planner_view.dart:360–369`,
    then `_planned` and `_footer` at `:429–430` for every plan.
  - The note's case 2 (`plan != null`, `term == null`) lists the KPI
    cards, the subject cards and `term_nothing`, and nothing else. Only
    case 3 lists the planned days. Item 10 says "unchanged", which reads
    as case 3 only.
  - Planned days drive the automatic lunch cancel (`_plannedDeorders`,
    `lunch_auto.dart:379`, used at `:463`). A planned day that is still
    ahead must stay visible and removable, or the student can't see why a
    lunch was cancelled and can't stop it.
- **What correct looks like:**
  - Case 2 says: with `plan != null && term == null`, show `term_nothing`,
    then *Naplánované* (`planned_title`, with unplan) and the calendar
    footer, as today.
  - §7, absence test case 2: a planned entry shows and can be unplanned
    when `term == null`.

#### S10 (F1b §2, l.26–49): four more code places name the Plánovač route

- **Where:** `design-F1b.md` §2.
- **What is wrong:** §2 lists `shellRoutes`, `moreRoutes`,
  `MorePage.entries`, `routeForLocation` and the *Dnes* tip, but not:
  - `app/lib/shell/scaffold.dart:163` (`_railIcons['planner']`) and
    `:180–181` (`_titleFor`, `nav_planner`);
  - `app/lib/shell/router.dart:83` (`PlaceholderScreen` titles,
    `nav_planner`), `:120–121` (`case 'planner': LivePlannerView`) and its
    import at `:18`;
  - `app/lib/features/today/today_controller.dart:149` (a comment naming
    `"planner"`).

  §6 removes `nav_planner`, so these have to go too. The grep in §6 would
  find them, but the note is F1b's only spec.
- **What correct looks like:** list these places in §2, each with "remove
  the `planner` entry". Nothing else in them changes.

---

### Notes (no action needed)

- **N8 (O1 M1):** a student who switched *Neúspěšná aktualizace* on now
  gets two notifications for such a run (`automation_failed` and
  `refresh_failed`). Both are true and have different tags. Accepted.
- **N9 (F1b tutorials):** an old `planner` entry in `tutorials_done` stays
  and is harmless. Validation checks only that it is a list
  (`config.dart:406`), and an unknown id is never offered
  (`tutorial.dart:120`). This agrees with "no migration" in the note.
- **N10 (F1b wording):** the button is `plan_custom`, *Naplánovat vlastní
  termín* (`app_cs.arb:487`). The note calls it *Naplánovat vlastní
  volno* in §3, §7 and §8. Use the key as it is. No new text.
- **N11 (F1b, pre-existing):** `ReserveDialog` (`planner_view.dart:2080`)
  isn't opened anywhere in `app/lib`. It was unreachable before F1b, and
  the reserve is set in Settings. That's out of scope: keep the class and
  its test `reserve dialog saves valid values only` (`:68`) as they are.

---

### What the reviewer verified, and how (re-review)

1. **Suites** (worktree, Flutter 3.44.8 / Dart 3.12.2):
   - `dart pub get --enforce-lockfile`: OK.
   - Core: `dart analyze` no issues; `dart test` **809 passed, 2 skipped**.
   - App: `flutter analyze` no issues; `flutter test` **722 passed, 1
     skipped** (719 + M1's three).
   - Baseline for F1b: these counts. The app count may only go up.
2. **M1's test catches the bug:** in a throwaway worktree at `7479a97`
   (removed afterwards), with `9211e90`'s
   `app_state_excuses_and_planner_test.dart` copied in: case 1 fails with
   the assertion above; cases 2 and 3 pass. All three pass on `9211e90`.
3. **M1's code:** read `_refreshLocked` around the change. Only one
   notification is added before the existing `throw`. The run record,
   `reportError` and the `refresh_failed` path are unchanged.
4. **The note against the code:** every file, line, key, anchor and method
   the note names was looked up (`more.dart:25–43`, `router.dart`,
   `tutorial.dart:105–130`, `planner_live.dart:200–216`,
   `absences_controller.dart:90–114`, `planner_view.dart:225–430` and
   `:1152–1200`, core `YearPlan.term` / `defaultTerm`, the ARB keys, README
   l.51–60, `capture_screens.dart:63–74`). Then grep over `app/lib` and
   `app/test` for `PlannerView`, `LivePlannerView`, `'planner'`,
   `/planner` and every removed key. The gaps are S8–S10.
5. **Scope:** `9211e90` touches `activity.dart` and one test file. The
   other commits touch only `design-F1b.md` and STATUS. No F1b code, no
   phase 4 work.
6. **Config keys and strings:** no config file, parity fixture or ARB file
   changed since `7479a97`.
7. **Safety rules:** `runRefresh`, the session lock, `sendExcuse` /
   `HistoryLock`, the audit and `automation_paused` are untouched. The only
   change in `controllers/` adds a notification. No new `catch`.
8. **Test integrity:** only `app_state_excuses_and_planner_test.dart`
   changed, with 3 new tests. The fake's new constructor arguments default
   to the old config and behaviour, so the existing tests see the same
   fake. No test removed, no `skip:`, no `try`/`catch` around assertions.
   The only host is `127.0.0.1:18080`.
9. **Screens and phone:** no UI change and no phone item this round, so
   no captures and no phone check.
10. **Hygiene:** all ten commits by the configured user, with no
    `Co-Authored-By`, `Claude-Session` or "Generated with" lines. No
    personal files. `qa-roadmap` has no upstream. The uncommitted
    `generated_plugin*` files are the known Flutter line-ending churn.
11. **Not checked:** macOS and iOS builds (not possible here), the phone
    (not needed this round).
