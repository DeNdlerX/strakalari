# R3b code review: F1b (Absence and Plánovač joined)

Reviewed 2026-11-19 at `qa-roadmap` @ `9cfd15f` (base `main` @ `f8d5582`;
`main` has no commits the branch lacks). Commits since the design PASS
(`88fc262`):

- `5a59960` (routes, *Více*, *Dnes* tip, `/planner` redirect);
- `0797906` (`PlannerSections`, the merged `AbsencesView`, the 3-day list);
- `7b674bb` (tour, strings, README, pictures);
- `9cfd15f` (STATUS).

Checked against `design-F1b.md` (passed at R3b re-review 2, including the
reviewer's §3 item 8), PLAN §2, CONTRIBUTING §5–6 and the owner's words in
STATUS.

## Verdict: FAIL

The merge itself is done well. There is one Absence screen, *Plánovač* is
gone from the rail and from *Více*, an old `/planner` link lands on
Absence, every subject is shown once, the closed school year still shows
the planned days and lets you remove them, *Doporučený plán* shows the next
3 days with *Zobrazit všechny*, and the merged tour works. All suites are
green, every commit is green on its own, no test was lost, and nothing in
the send, order, lock or audit code was touched.

One finding blocks the pass (M1): **the coloured hour-budget bar on every
subject card is empty.** Only the grey track is drawn. The bar was already
empty on the old Plánovač, but there it was one extra list. Now it has
replaced the working gauge on the Absence screen, so a student no longer
sees at a glance how close each subject is to its limit. The fix is one
line, and the reviewer tried it.

Two smaller findings: a planner test helper stopped resetting the
message log between tests (S1), and the demo-data tool still talks about
the removed Plánovač tour (S2).

**Update the same day, after the owner's phone test** (section
[*Owner's phone test*](#owners-phone-test-2026-11-19) at the end): a
second must-fix (M2, *Naplánovat vlastní termín* can't select any day,
since the Flutter move), a should-fix (S3, *Rozumím* can't be unticked
once accepted) and four owner changes (O3–O6) that need a design note
(`design-F1c.md`) before any code.

---

## Must-fix

### M1 (F1b, `0797906`): the stacked budget bar on the subject cards draws nothing

- **Where:** `app/lib/features/planner/planner_view.dart:312`
  (`plannerBudgetBar`, `child: Row(children: parts)`), used for every
  subject card with a budget row at
  `app/lib/features/absences/absences_view.dart:593`.
- **What is wrong:**
  - Each segment is `Expanded(child: ColoredBox(color: …))` in a `Row` with
    the default `CrossAxisAlignment.center`. A `ColoredBox` without a child
    takes the smallest height it is allowed, so every segment is 0 px high.
    Only the 8 px grey track (`tok.overlay`) is painted.
  - Reviewer's captures at `7b674bb` (390 and 1280 px, cs and en, light and
    dark): on every subject card all 1107 px of the bar are the track
    colour. No grey *Zameškáno*, green *Volno* or yellow *Rezerva* at all,
    although the legend above the list names all four.
  - **It is older than F1b:** the reviewer captured the old `/planner` at
    `88fc262`, and its `_budgetBar` rows were empty in the same way. F1b
    moved the code unchanged.
  - **Why it is a must-fix now:** before F1b the Absence screen showed a
    working `Meter` gauge on each subject. F1b replaced it with this bar
    for every subject that has a budget row, which in an active term is
    every subject. So the Absence screen lost its only gauge.
    `design-F1b.md` §8 asks for "combined current % + stacked budget bar".
    The tests check that the card exists, not that the bar shows anything.
- **What correct looks like:** one commit, `F1b: draw the budget bar
  segments (R3b code M1)`.
  - In `plannerBudgetBar`:
    ```dart
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: parts,
    ),
    ```
    Nothing else changes: the segment shares, colours and the 8 px height
    stay as they are.
  - The reviewer tried exactly this at `7b674bb`: `flutter analyze` clean,
    all app tests pass (735 + the test below), and the captures show the
    grey, green and yellow segments.
  - Add a test to `app/test/absences_view_test.dart` (before
    `class _SeededAbsAppState`). It must fail on `9cfd15f`
    (`Expected: <8>, Actual: <0.0>`; the reviewer checked):
    ```dart
    testWidgets('F1b budget bar segments are drawn (R3b code M1)', (t) async {
      t.view.physicalSize = const Size(1280, 1800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final tok = AppTokens.dark();
      final abs = AbsencesController()
        ..subjects = const [
          SubjectAbsence(
            name: 'Matematika',
            currentPct: 12.0,
            status: 'ok',
            limitPct: 25.0,
            effectivePlanLimit: 22.5,
            effectivePlanSafe: 4,
          ),
        ];
      final term = TermPlanData(
        key: 'sem1',
        start: DateTime(2026, 9, 1),
        close: DateTime(2027, 1, 25),
        capacity: 4,
        hasData: true,
        active: true,
        remainingDays: [DateTime(2026, 10, 5)],
        budgets: const [
          BudgetRowData(
            name: 'Matematika',
            missed: 4,
            planned: 2,
            free: 3,
            buffer: 1,
            schoolCap: 10,
            schoolLeft: 5,
            projectedPct: 20.0,
            limitPct: 25.0,
            status: 'ok',
          ),
        ],
      );
      await t.pumpWidget(MaterialApp(
        theme: tok.toThemeData(),
        home: Scaffold(
          body: AbsencesView(
            controller: abs,
            tokens: tok,
            planner: PlannerController({}),
            plan: YearPlanData(
              today: DateTime(2026, 9, 26),
              firstDay: DateTime(2026, 9, 28),
              terms: [term],
              lessonsOn: (_) => 5,
            ),
            hasTimetable: true,
          ),
        ),
      ));
      await t.pump();
      final segments = find.descendant(
        of: find.byKey(const Key('abs:subjects')),
        matching: find.byType(ColoredBox),
      );
      // missed, planned, free, reserve
      expect(segments, findsNWidgets(4));
      for (final e in segments.evaluate()) {
        final size = (e.renderObject! as RenderBox).size;
        expect(size.height, 8);
        expect(size.width, greaterThan(0));
      }
    });
    ```
  - Evidence: the agent's captures are 390 × 844 and 1280 × 800, so they
    end above the subject list. That is how this went unseen. Put
    full-length captures of the subject list (for example 390 × 3000 and
    1280 × 2300, cs and en, light and dark) from before and after the fix
    into `build/qa-evidence/F1b/M1/`. Recapture `docs/images/absences-*.png`
    only if the subject list is in the picture (at 1280 × 800 it isn't, so
    they may stay).

---

## Should-fix

### S1 (F1b, `0797906`, test integrity): the planner test helper no longer clears `SnackLog`

- **Where:** `app/test/planner_view_test.dart:634–637` (`_app`). At
  `88fc262` it was `:423–426` and started with `SnackLog.clear();`.
- **What is wrong:** three tests in the file check the last message shown:
  `:263` (`skip_planned`), `:322` (`plan_removed`) and `:386`
  (`skip_planned_keep_lunch`). Without the clear, `SnackLog.last` carries
  over from the test before. Today each previous test happens to leave a
  different message, so the checks still mean something (the reviewer
  went through the order). But a new or reordered test can make one of
  them pass although the action showed nothing. That loosens the tests
  (PLAN rule 8), and it isn't listed under *Deviations*.
- **What correct looks like:** one commit, test only:
  ```dart
  Widget _app(Widget child) {
    SnackLog.clear();
    return MaterialApp(
      theme: AppTokens.dark().toThemeData(),
      home: Scaffold(body: child),
    );
  }
  ```
  (Keep the theme; it doesn't hurt.) The credentials test pumps `_app`
  twice, which is fine.

### S2 (F1b, missing from the note): `tools/demo_data.py --tutorials` still means the removed Plánovač tour

- **Where:** `tools/demo_data.py:80–81` (`TOURS_DONE` contains
  `absences`), the comment at `:188` ("only the Planner tour is left to
  show") and the `--tutorials` help at `:210`.
- **What is wrong:** `--tutorials` was meant to leave exactly one tour to
  show (the Plánovač one, for the README picture). With `planner` gone and
  `absences` in `TOURS_DONE`, no tour is left, and the text still names
  the Planner. It is the same kind of leftover as R3b S10.
- **What correct looks like:** one commit, `F1b: demo data leaves the
  Absence tour (R3b code S2)`: remove `"absences"` from `TOURS_DONE`, and
  change the comment and the help text to say the Absence tour (with
  planning) is left to show. Check by hand that
  `python tools/demo_data.py generate <tmp> --tutorials` writes
  `tutorials_done` without `absences`. A dev tool with no tests: say so in
  the commit message.

---

## Notes (no action needed)

- **N13 (deviations accepted):** the two F1b lines under *Deviations* (the
  `'10'` reserve line replaced by the `tutorial_test.dart` check, and
  `Key('abs:subjects')` to scope subject checks away from the lesson lists
  on the recommended cards) are accepted. Both were planned in the note.
- **N14 (accepted, not in the note's wording):** a small `PlannerListener`
  rebuilds the view when the planner controller changes, and three helpers
  became public so the Absence screen can use them (`plannerBudgetBar`,
  `convertPlannerImpacts`, `calendarSummaryFor`). `absencesControllerFor`
  now reads the selected term instead of the default one, which §3 item 4
  asks for. The `catch (_)` in `calendarSummaryFor` was moved unchanged
  from `LivePlannerView`; the two in `tutorialStepSkipped` guard a
  tutorial check only (an allowed probe).
- **N15 (untested corners, optional):** no test taps *Zobrazit méně* to
  collapse the list back to 3; no test has a budget `over` beating an
  absence `warning`; the P9a+b test has the warnings card in its data but
  doesn't assert it. The code for all three was read and is right.
- **N16 (test name):** `more_page_test.dart`
  `desktopOrNonAndroidHasFourEntries` now checks 3 entries, as the note
  said. The name is stale; leave it unless the file is touched anyway.
- **N17 (wording, owner):** *Tip plánovače* / *Planner suggestion*
  (`planner_suggestion`, `notif_planner_suggestion`) still says
  "plánovač". Like `docs/SCHOOL_PRESETS.md:5`, it names the feature, not
  the tab. Accepted.
- **N18 (owner, not a finding):** each card shows today's percentage from
  Bakaláři next to the end-of-term estimate from the hour budget. With the
  demo data they differ a lot (for example *21.4 %* and *na konci
  ~7.1 %*). That pairing was already on the old Absence screen (the
  `budget_end` detail line) and the planner maths didn't change. If the
  owner finds it confusing, it would be its own item.
- **N19 (tour):** the merged Absence tour starts only when the term has
  recommended days (approved in R3b S3). A student who is already over a
  limit, or opens the app after the closure, won't see it until then.

---

## Done when (`design-F1b.md` §8)

| Check | Result |
|---|---|
| One `/absences` screen; rail 7 items; *Více* 3 (Android 4: absences, activity, alarm, settings) | ✔ `router.dart`, `more.dart`; tests `/planner redirects…` (7 destinations), `more_page_test` exact lists; reviewer captures |
| `/planner` redirects; *Dnes* tip opens Absence | ✔ `buildRouter` and `routeForLocation`; both tests fail on the parent |
| Every subject once, current % + stacked bar + projected % (or `Meter`) | ✘ the bar is empty (M1); once, %, projected %, badge precedence and `Meter` fallback ✔ |
| Real data cases 1–3 (§3 item 3) | ✔ three live tests with a real `AppState`; the closed year shows `term_nothing`, *Naplánované* with unplan, and the footer (also in reviewer captures) |
| Plan dialogs, `PlannerController`, lunch-cancel staging intact | ✔ only the class name in three dialog titles changed; controller gained only the in-memory toggle |
| Next 3 picks, *Zobrazit všechny (N)* / *Zobrazit méně*, heading and *Naplánovat vše* cover all, in memory only, `plan_explain` gone and in `tut_plan_strip_body` | ✔ widget test, live test (no `config.json` write), string test; reviewer captures with the list open |
| P9a+b with a new student's setup, *Přehled pololetí* above 708 px | ✔ |
| Merged tour, intro strings, exact added and removed keys | ✔ 4 steps, offer rule, skip flags; 796 keys; removed keys unused |
| README, `capture_screens.dart`, `docs/images/absences-*.png`, `planner-*.png` removed | ✔ (README alt text lost "with an interactive tutorial", correct since the picture has none) |
| Evidence 390 / 1280, cs / en, light / dark, *Více* 390 | ✔ present, but only the top of the screen (see M1) |
| Suites green, app count not lower | ✔ core 809 / 2 skipped, app 735 / 1 skipped |

## Each commit's test catches its change

One throwaway worktree in the reviewer's scratch space (removed
afterwards). For each commit: its parent, with only that commit's test
files copied in.

| Commit | On the parent | On the commit |
|---|---|---|
| `5a59960` | 5 fail with assertions: both `more_page_test` lists (`Expected: <3>, Actual: <4>`; `<4>` / `<5>`), `/planner redirects…` (path stays `/planner`), the *Dnes* tip (`'planner'`), `everyScreenBuilds` (redirect). The adapted `widget_test`, `android_back_test`, `backStepsUp` and P9c pass there, as adapted tests should | pass |
| `0797906` | none compile (`now:`, `planner:`, `PlannerSections`, the toggle) | pass |
| `7b674bb` | the 5 new tour tests fail with assertions (tour still split; `[0, 1]` vs `[0, 1, 3]`; tour offered with no recommended days, `Expected: null`; `rezerv` missing), and the adapted route check fails (`planner`) | pass |

The `0797906` tests were read one by one. They check the behaviour the
note asks for: each subject once (exact text, so the joined lesson lists
on the day cards don't count), badge precedence including the tie,
canonical name matching (`'  matematika '`), `Meter` only without a
budget row, 3 cases with a real `AppState`, 3 of 5 cards and then 5, the
plan-all dialog listing the 5th day in both states, no button at 3 picks,
the flag flipping without writing `config.json`. None only re-checks what
the code does by construction. None checks that the bar paints (M1).

## What the reviewer verified, and how

1. **Suites** (worktree, Flutter 3.44.8 / Dart 3.12.2):
   - `dart pub get --enforce-lockfile`: OK.
   - Core: `dart analyze` no issues; `dart test` **809 passed, 2
     skipped** (the old POSIX skips).
   - App: `flutter analyze` no issues; `flutter test` **735 passed, 1
     skipped** (722 at the design PASS, +13).
   - Baseline for the re-review: these counts. The app count may only go
     up.
2. **Every commit green on its own:** `flutter analyze` and `flutter test`
   at `5a59960` (clean, 724 + 1 skipped) and `0797906` (clean, 730 + 1);
   `7b674bb` has the same code as HEAD. No core file changed in any of
   them, so the core run at HEAD covers all three.
3. **Tests catch the change:** table above.
4. **Test integrity:** the 13 changed test files were run with the JSON
   reporter at `88fc262` and at HEAD: 115 → 128 tests. The only name that
   disappeared is the renamed `LivePlannerView renders budgets and
   recommendations` → `LiveAbsencesView renders subjects, budgets and
   recommendations`, whose checks got stronger. Every removed `expect` has
   a replacement (route lists, More counts, `section_budgets` →
   `abs_subjects_section`, `planner_title` → `absence_title`,
   `see_absences` → *Limity*, `plan_buffer_note` → `abs_no_limits`, the
   `'10'` line as planned). No `skip:`, no `try`/`catch` around
   assertions, no new host. Exception: S1.
5. **M1:** pixel colours read along the bar on the reviewer's captures at
   `7b674bb` and on a capture of the old `/planner` at `88fc262` (both
   empty); the one-line fix tried at `7b674bb` with analyze, the full app
   suite and new captures (segments shown); the test above run with and
   without the fix.
6. **Screens:** a reviewer-only copy of `tools/parity/capture_screens.dart`
   (real router and `MyApp` setup, Roboto, `tools/demo_data.py` data) with
   tall viewports, at `7b674bb`: the full screen, the list opened, tour
   steps 3 and 4, and a closed school year (clock at 1 July 2027), at 390
   and 1280 px, cs and en, light and dark. **No render or overflow
   errors.** Everything looked right except M1. The tour's last step sits
   on the first subject card with its bubble on the phone. The agent's
   `build/qa-evidence/F1b/` images were opened;
   `docs/images/absences-{cs,en}.png` are byte-identical to
   `after_absences-{cs,en}-dark-1280.png` and show demo data only.
7. **Scope:** every change maps to `design-F1b.md`, plus N14. No other
   feature, no phase 4 work.
8. **Config keys and strings:**
   - `config.example.json`, `config.dart` and `test/parity/` are unchanged
     since `main` (`git diff f8d5582` empty).
   - Both ARB files and both `strings.dart` tables have the same 796 keys
     (script). The 4 new keys have real cs and en text. The 8 removed keys
     have no use left in `app/lib`, `app/test` or `tools` (grep).
9. **Safety rules:**
   - Nothing in core and nothing in `automation/`, `lunches/`, `strava/`,
     `bakalari/` or `storage/` changed.
   - In `app/lib/controllers/` only the in-memory `plannerShowAllPicks`
     flag and its toggle (no save, no network, no lock) and the tour skip
     checks changed.
   - Planning and unplanning still go through the unchanged
     `PlannerController` hooks, `planCustomSkip` and `unplanEntry`; the
     plan dialogs (with the lunch-cancel choice) are unchanged.
   - `runRefresh`, the session lock, `sendExcuse` / `HistoryLock`, the
     audit and `automation_paused` are untouched. No new `catch` in send,
     order or save code.
10. **Phone:** no phone item in F1b. The Android code holds no route
    names (grep for `planner` under `app/android/app/src/main`). Not
    checked on the phone.
11. **Hygiene:** all four commits by the configured user, with no
    `Co-Authored-By`, `Claude-Session` or "Generated with" lines. No
    `config.json`, `data_cache.json`, `log.txt`, `htmls/`, keys or phone
    screenshots in any commit. `qa-roadmap` has no upstream. `main` has
    no commits the branch lacks. The uncommitted `generated_plugin*` files
    are the known Flutter line-ending churn.
12. **Not checked:** macOS and iOS builds (not possible here), the phone
    (not needed this round).

---

## Owner's phone test (2026-11-19)

At the owner's request the reviewer installed the F1b build on the Pixel
over the `.test` app, keeping its data: built from `7a75eb8` (F1b code
= `7b674bb`) with `build_android.dart apk --flavor phonetest --version
0.9.99`, because the `.test` app held the owner's measure build
(versionCode 101999) and a lower code can't install over it with its
data. Package checked as `io.github.dendlerx.strakalari.test`,
`adb install -r`, *Success*; `firstInstallTime` unchanged (data kept);
the Play app still has `lastUpdateTime=2026-11-13 04:07:35`. The owner
opened the app themselves. The owner's notes are in STATUS word for word
(*Phone test of F1b*). The reviewer checked each one against the code.

| Owner's point | What the reviewer found | Becomes |
|---|---|---|
| *Rozumím* ticked from the start and can't be unticked | Ticked because this `.test` app had already accepted it (a new install starts unticked: `config.dart:126` defaults to `false`). Can't be unticked: a real bug, older than this phase | S3 |
| The first refresh could run before setup is done | A change to when the first refresh runs; safe if nothing automatic runs during it | O6 |
| The alarm step doesn't ask for permissions or set the alarm | True: the step is one switch (`wizard_view.dart:877–893`) | O5 |
| The calendar is broken, nothing can be selected | True for *Naplánovat vlastní termín*: no day can be picked in the real app, since the Flutter move | M2 |
| The semester overview is too long; the Absence screen is too long; a Plánovač button with one calendar and a range option | A design change to F1b | O3 |
| The limits page is ugly, uses part of the screen; offer values already used | A design change | O4 |

### Must-fix

#### M2 (older than F1b, `e40c3a0`): *Naplánovat vlastní termín* can't select any day

- **Where:** `app/lib/features/planner/planner_view.dart:1241`
  (`lessonsFor: lessonsFor ?? ((_) => const [])`) and `:1748` (a day with
  no pickable lesson gets `onTap: null`). `LiveAbsencesView`
  (`absences_live.dart:87–116`) never passes `lessonsFor`; neither did
  the old `LivePlannerView`. No code in `app/lib` builds a `PickerSlot`.
- **What is wrong:** in the real app every day of the custom calendar has
  no lessons, so every day is disabled and *Potvrdit* stays grey. Planning
  a range or single lessons has been impossible since the Flutter move
  (2026-11-08). The only test (`custom picker taps a day whole and
  confirms`) passes its own `lessonsFor`, so it never noticed.
  - **Reviewer's test** (throwaway, deleted): `LiveAbsencesView` with a
    real `AppState` (a week of lessons, clock 10 Sep 2026), tap
    *Naplánovat vlastní termín*, tap 14–18 Sep: `tapped=5
    confirmEnabled=false` (`Expected: not null, Actual: <null>`).
  - The Python app had this: `_Slot`, `_PickDay`, `_pick_context`,
    `_pick_rows`, `_pick_day` in `strakalari/flet_ui/views/planner.py`
    (`git show 963cfa2^:strakalari/flet_ui/views/planner.py`, l.385–560).
- **What correct looks like:** one commit, `F1b: give the custom
  calendar the day's lessons (R3b code M2)`.
  - A read-only `AppState` method in `app/lib/controllers/planner.dart`
    (no save, no network) that returns the `PickerSlot`s of a day from
    the same timetable source `yearPlan()` uses, ported from `_pick_day`:
    one slot per lesson with its period and subject; `taught: false` for
    a cancelled lesson or a class event; `past: true` for today's lesson
    that has already started; `planned: true` if a planned entry already
    covers it; `changed` for a substitution. Weekends, free days and days
    after the closure have none.
  - `LiveAbsencesView` passes it as `lessonsFor`.
  - Test in `app/test/absences_live_test.dart`, the reviewer's case
    above: tapping a school day enables *Potvrdit*; confirming adds one
    planned entry with that day; a day off and a past day can't be
    tapped. It must fail on `9cfd15f`.
  - F1c (O3) reuses this method for its calendar.

### Should-fix

#### S3 (older than F1b, `74edf74`): *Rozumím* can't be unticked once accepted

- **Where:** `app/lib/features/wizard/wizard_controller.dart:187–198`
  (`disclaimerOk`, `setDisclaimer`), shown at `wizard_view.dart:549–556`.
- **What is wrong:** `disclaimerOk` is true when the draft is set **or**
  `disclaimer_accepted` is saved. Unticking writes an empty draft, which
  the saved `true` overrides, so the box ignores the tap. Anyone who runs
  the wizard again, or resumes it after Vítejte, sees a box that doesn't
  react.
- **What correct looks like:** one commit. Unticking stores `'0'`;
  `disclaimerOk` is `true` for draft `'1'`, `false` for draft `'0'`, and
  the saved value only when there is no draft. While unticked,
  *Pokračovat* is disabled (as for a new user). `disclaimer_accepted` is
  never written `false` (acceptance isn't withdrawn). Test in
  `app/test/wizard_live_test.dart`: with `disclaimer_accepted: true`
  saved, the box starts ticked, a tap unticks it and disables
  *Pokračovat*, a second tap ticks it again; it must fail on `9cfd15f`.

### Owner changes (need `design-F1c.md` first, no code before it passes)

The owner wrote "Think this through and make it work good, I dont really
know how to make this perfect." Below is the reviewer's direction for the
note. The agent writes `docs/qa-roadmap/design-F1c.md` from it (exact
layout, keys, strings, tests and *Done when*, like `design-F1b.md`) and
stops for review. Where the agent sees a better way, the note says why.

#### O3: Absence gets short again; one calendar in its own Plánovač page

- **Absence** (`/absences`) keeps what it is about: the header with
  *Limity* and a new **Plánovač** button, the KPI row, the no-limits line,
  and the subject cards (with the budget bar from M1). Optionally one
  line under the KPIs with the next recommended day (`planner_next`)
  that opens Plánovač. The semester overview, the recommended list, the
  planned list and the calendar footer move out.
- **Plánovač** is a page opened from that button (a sub-route such as
  `/absences/plan`, with a back arrow to Absence on phones; not a new
  rail or *Více* entry). The *Dnes* tip and the old `/planner` link open
  it. It holds: the term buttons, one summary line (*Můžete vynechat*,
  *Naplánováno*, *Školních dní zbývá*), **one calendar**, the
  recommended days (3 + *Zobrazit všechny*, *Naplánovat vše*, the target
  dropdown), the planned days with *Zrušit plán*, and the calendar
  footer.
- **One calendar instead of two.** The semester strip and the custom
  calendar are the same thing twice. Keep one month-style grid:
  - **only the future**: from the current week to the selected term's
    closure (past weeks are not shown);
  - the colours stay (recommended, planned, doesn't fit, day off, today);
  - **tap a day** = today's day dialog (plan the whole day with the
    template and the lunch-cancel choice, with the cost preview), plus
    a way to pick only some lessons of that day (from the M2 slots);
  - a **Vybrat více dní** switch above the grid: taps then add or remove
    whole days, a bar shows *N dní · stojí X h* with the same impact
    preview, and *Naplánovat* opens one confirmation (template, lunch
    cancel) and plans them in one save (`planEntries`, which saves all at
    once and rolls back on failure);
  - the separate *Naplánovat vlastní termín* dialog goes away, since the
    calendar does both.
- **Must stay true:** planning and unplanning go only through the
  existing `PlannerController` hooks / `planCustomSkip` / `planEntries` /
  `unplanEntry`; every plan still asks for confirmation; the lunch-cancel
  staging is unchanged; no config key changes; at 390 px the calendar
  starts on the first screen of Plánovač.
- **Tours:** the note decides how the Absence and Plánovač steps split.
  A new tour id is needed if a Plánovač tour comes back, because old
  installs have `planner` in `tutorials_done` (N9).

#### O4: the limits editor as a full page, with values to tap

- **Where:** today `AbsencesView._openLimitsDialog` puts
  `LimitsEditorContent` into an `AlertDialog` 480 px wide
  (`absences_view.dart:64–91`), with three fields and then one text field
  per subject (`settings_view.dart:1971`).
- **Direction:** open it as its own page (sub-route such as
  `/absences/limits`, full width on the phone, a back arrow), with the
  default, warning and reserve values at the top and then one row per
  subject: the name, the limit in use (own or default), and a clear
  "default" state. When a subject's value is being edited, show the
  values already in use (the default plus each distinct value in
  `subject_limits`) as chips to tap, so the same number isn't typed ten
  times. *Nastavení → Limity* links to the same page.
- **Must stay true:** the same keys (`absence_critical_pct`,
  `absence_warn_pct`, `absence_plan_reserve_pct`, `subject_limits`) saved
  the same way; clearing a
  subject still removes it from `subject_limits`; no new config key.

#### O5: the wizard's Budík step really sets the alarm

- Embed the Settings `WakeupCard` (`app/lib/features/settings/wakeup_card.dart`)
  in the Telefon step instead of the lone switch: on/off, the minutes
  before the first lesson, the exact-alarm permission (asked on purpose
  there, like the notification permission), and the next wake-up.
- The next wake-up needs the timetable; with O6 it is usually there by
  then. Without it the card shows its own "no timetable yet" hint.
- The note says which keys the step now writes (`wakeup_enabled`,
  `wakeup_minutes_before`) and when (F1 wrote only the switch).

#### O6: the first refresh starts during setup

- The wizard already tests the Bakaláři login (`wizard_live.dart:67`).
  Once that test passes and the login is saved, start the first refresh
  in the background, so the timetable, absences and subjects are there
  when the wizard ends.
- **Must stay true** (CONTRIBUTING §5):
  - it is a normal refresh: `startRefresh` → `runRefresh`, under the
    session lock, recorded like any run;
  - **nothing automatic happens during it**: the run gets a config copy
    with `automation_paused: true` (in memory, never saved). Every auto
    phase already honours it (`refresh.dart:736`), so no excuse is sent
    and no lunch is ordered before the student has finished setup (the
    signature and the templates come later in the wizard);
  - *Dokončit* still starts the normal first refresh with the student's
    own settings (`wizard_live.dart:79`); if the early one is still
    running, the existing B7 rule applies;
  - a failed early refresh doesn't block the wizard; the student sees it
    like any failed refresh.
- The note names the exact place the run starts and its scope (Bakaláři
  only, since Strava comes later).

### Order of work

1. M1, M2, S1, S2, S3: one commit each, with their tests.
2. `design-F1c.md` for O3–O6, then stop for review.
3. F1c code only after the note passes.
