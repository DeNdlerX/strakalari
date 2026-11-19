# R3c code review: F1c (short Absence, Plánovač and Limity pages, Budík step, early refresh, back to the opener, notification taps)

Reviewed 2026-11-19 at `qa-roadmap` @ `e1a2d3b` (base `main` @ `f8d5582`;
`main` has no commits the branch lacks). Commits since the design PASS
(`daa4b55`):

- `6089a47` O6, early paused Bakaláři refresh in the wizard;
- `e8152a5` O5, the real `WakeupCard` on *Telefon*;
- `b1a1ae0` O4, the full-page limits editor `/absences/limits`;
- `2e4a2ea` O3, short Absence and the one-calendar Plánovač `/absences/plan`;
- `c62b502` O7, Limity and Plánovač go back to where they were opened;
- `05942f2` O8, notification, status, alarm and widget taps open their screen;
- `a6b0f6e` O3 follow-up, calendar cell layout (check mark and dot at the
  cell edges);
- `e1a2d3b` STATUS.

STATUS still says the agent is waiting for the Pixel to capture the phone
evidence; the owner called the reviewer anyway, so this reviews the code as
it is. Checked against `design-F1c.md` (passed at R3c re-review 2,
including the four paragraphs the reviewer wrote: M3, M4, S10, S11),
PLAN §2, CONTRIBUTING §5–6 and the owner's words in STATUS.

## Verdict: FAIL

The six items are built as the note says, and they are built well. Absence
is short again (header with *Limity* and *Plánovač*, 3 cards, the next
recommended day, the subjects with their budget bars). Plánovač is its own
page with one month calendar: past days are greyed and can't be tapped, a
day can be planned whole or by lessons, a partly planned day keeps its dot
and can get more lessons, and *Vybrat více dní* plans several days at once.
Limity is a full page with tappable values. The wizard's *Telefon* step
shows the real Budík card, with its permissions and the next wake-up. The
first Bakaláři refresh starts during setup with every automatic action
paused, and a *Dokončit* during it really runs the full refresh afterwards.
Back goes to where a page was opened, and a phone notification or the
widget opens its screen. All suites are green, no test was lost, no config
key or parity fixture changed, and nothing in the send, order, lock or
audit code was touched beyond the paused copy the note describes.

The reviewer undid each fix one at a time in a throwaway copy and ran the
test meant to catch it: 23 of 26 were caught (table below). That includes
all of M3, M4 and S11, the three paragraphs the reviewer wrote into the
note, and the pause proof (S6).

Two findings block the pass:

- **M5:** in *Vybrat více dní*, a day that was picked and then planned
  another way before *Naplánovat* (for example with the *Naplánovat
  dovolenou* button on the recommended list right below) gets a second,
  made-up plan for its 1st lesson, carrying the multi dialog's lunch
  choice. The student never picked that lesson, and it can mark a lunch
  for cancelling that the student chose to keep.
- **M6:** the phone evidence the note requires for O5, O6 and O8 is not
  there yet. The agent stopped for it; the Pixel is connected now.

One should-fix: the tests named for S10 don't reach the save they are
named after (S12). In the real app the typed limit is saved anyway; the
safety net behind it is untested.

---

## Must-fix

### M5 (O3, `2e4a2ea`): a day picked in *Vybrat více dní* and then planned another way gets a made-up lesson-1 plan

- **Where:** `app/lib/features/planner/planner_view.dart`:
  - `:1323–1338` `_pickedPeriodsForSelected` leaves out a selected day
    that has no pickable lesson any more (`:1332`);
  - `:1603` and `:1668` the *Naplánovat* button still passes **every**
    selected day (`days: chosen`) to `PlanMultiDialog`;
  - `:2327` `PlanMultiDialog._entries` then uses `{1}` for a day that has
    no picked lessons (`chosen[d] = (p != null && p.isNotEmpty) ? p : {1}`),
    with that day's taught lessons as `lessons`, so `entriesForSelection`
    makes an entry "until the 1st lesson";
  - `:2298–2311` `_anyPartial` doesn't count that day, so *Odhlásit oběd*
    starts ticked;
  - `:1751` and `:1783–1789` the day still shows as selected but is no
    longer tappable in multi mode, so the student can't untick it (only
    *Vymazat* clears everything).
- **What is wrong:** the selection lives inline on the page now, not in a
  modal dialog as the old *Naplánovat vlastní termín* did, so the plan can
  change under it: the *Naplánovat dovolenou* and *Naplánovat vše* buttons
  on *Doporučený plán* below the calendar, an unplan, a refresh, or today's
  lessons starting (the month map recomputes today live, S11). The old
  dialog kept the lessons picked at tap time and dropped empty days
  (`_CustomPlanDialogState._entries`); the new code re-reads the slots at
  confirm time, which is right, but falls back to `{1}` instead of dropping
  the day.
- **Reviewer's check** (throwaway test, not committed): multi mode,
  Monday 9 and Tuesday 10 picked, then Monday planned whole with
  `planSkip`, the calendar rebuilt, *Naplánovat* → *Potvrdit*. Result at
  `e1a2d3b`, three entries instead of two:
  `{2026-11-09, whole day}`, **`{2026-11-09, start_period: null,
  end_period: 1, cancel_lunch: true}`**, `{2026-11-10, whole day}`.
  `cancelsLunch` reads only `cancel_lunch` (core `planned_skips.dart:85`),
  so if Monday was planned keeping its lunch, the made-up entry still marks
  Monday's lunch for cancelling (`PlannerController._commit` stages it; in
  `strava_order_mode: auto` the next refresh sends it). The same `{1}`
  fallback plans the 1st lesson of today once all of today's lessons have
  started while the selection waits.
- **What correct looks like:** one commit, `F1c (O3): drop selected days
  that have nothing left to plan (R3c code M5)`.
  - The *Naplánovat* button passes only the days that still have picked
    lessons (`picked.keys`, sorted), and the selection bar counts the same
    days (the `days` part of `plan_multi_summary`). When none is left, it
    clears the selection and doesn't open the dialog.
  - In `PlanMultiDialog._entries`, `{1}` stays only for the case with no
    slot data at all (`pickedByDay == null`, the standalone widget tests
    without `lessonsFor`). A day missing from a non-null `pickedByDay` is
    skipped, never planned.
  - A selected day that is no longer pickable doesn't render as selected
    (`isSelected` also needs the day to be pickable in multi mode, the
    same condition as `canPickInMulti`).
  - Test in `app/test/plan_picker_test.dart`, which must fail on
    `e1a2d3b` (`hasLength(2)` gets 3; the reviewer checked the 3):
    ```dart
    testWidgets('a picked day planned elsewhere before confirming gets no extra entry (R3c code M5)', (tester) async {
      setViewport(tester);
      final c = createPickerPlannerController();
      String iso(DateTime d) =>
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      List<PickerSlot> lessons(DateTime d) => mockLessonsFor(d,
          plannedPeriods: c.plannedSkips.any((e) => e['start_date'] == iso(d))
              ? {1, 2, 3, 4, 5}
              : const {});
      Widget host() => buildPickerHost(controller: c, lessonsFor: lessons);

      await tester.pumpWidget(host());
      await tester.tap(find.byKey(const Key('plan:multi_toggle')));
      await tester.pumpAndSettle();
      await tester.tap(dayCell(monday));
      await tester.pump();
      await tester.tap(dayCell(tuesday));
      await tester.pump();

      // Monday is planned another way, keeping its lunch.
      expect(c.planSkip('2026-11-09', 'Důvod absence.', cancelLunch: false), isTrue);
      await tester.pumpWidget(host());
      await tester.pump();

      await tester.tap(find.byKey(const Key('plan:multi_confirm')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, Strings.get('confirm')));
      await tester.pumpAndSettle();

      expect(c.plannedSkips, hasLength(2));
      final mon = c.plannedSkips.where((e) => e['start_date'] == '2026-11-09').toList();
      expect(mon, hasLength(1));
      expect(mon.single['cancel_lunch'], isFalse);
    });
    ```

### M6 (§10 *Done when*, O5, O6, O8): the phone evidence is missing

- **Where:** `design-F1c.md` l.507–517; `build/qa-evidence/F1c/` holds the
  40 screen captures only, and `build/qa-evidence/F1c/O8/` doesn't exist.
  STATUS says so itself (F1c row, *Questions*, Next step).
- **Why it matters:** O8 is mostly Android code (`Notifications.java`,
  `StrakalariChannel.java`, `MainActivity.kt`) that no Dart test can run;
  the tests only read the Java and Kotlin text. Only the phone shows that a
  tap really lands on the screen, from a closed app and from a running one.
  For O5 and O6 the phone shows the real permission prompts, the return
  from *Alarms & reminders* and the next wake-up after the early refresh.
- **What correct looks like:** exactly the list in §10 l.507–517, on the
  Pixel 7 Pro `2C221FDH3002NZ`, `.test` app only, demo server on port
  18080, built from the branch head after M5 and S12 (so the phone runs the
  final code):
  - O5/O6 in `build/qa-evidence/F1c/`: *Telefon* with `WakeupCard`; the
    notification prompt when switching the alarm on; *Povolit přesné
    budíky* → system screen → back, the exact-alarm warning gone; the next
    wake-up on *Telefon* once the early refresh is done; after *Dokončit*
    `dumpsys alarm` listing the `.test` alarm; *Aktivita* showing the
    `bakalari` run and then the `all` run.
  - O8 in `build/qa-evidence/F1c/O8/`: an event notification tapped from a
    closed app and from a running app (on another tab) opens its screen;
    the status notification opens *Dnes*; the widget opens *Rozvrh*.
  - The Play app `io.github.dendlerx.strakalari` is never touched. Ask the
    owner before clearing or uninstalling `.test`.
  - Then write the Phase 3c notes in STATUS (done, deviations, unsure, how
    to verify) and set the F1c row to done.

---

## Should-fix

### S12 (O4, the note's S10, `b1a1ae0`): the S10 tests don't reach the save they are named after

- **Where:** tests `app/test/limits_page_test.dart:186` and `:287`
  (`S4 + S10: …`) and `app/test/android_back_test.dart:251` (`O4/S4
  leaving Limits via Android Back …`); code
  `app/lib/features/settings/settings_view.dart:100–103` (`dispose` calls
  `_commitOnDispose`) and `app/lib/features/absences/limits_page.dart:182`
  (the page's `dispose` commits the open subject row).
- **What is wrong:** with `_commitOnDispose()` removed, and separately with
  the page's dispose commit removed, all three tests still pass. Leaving by
  Android Back or the rail goes through go_router, which moves the focus to
  the new page before the old one is disposed, so the field's normal blur
  save runs first; the back arrow unfocuses on purpose. So the tests prove
  the student-visible part (a typed limit survives Back, the rail and the
  arrow, with the one normal save after it; removing that save is caught),
  but not the dispose save. The re-review 2 promised that each of its
  fixes has a test that fails without it.
- **Why the dispose save still matters:** when the page goes away without
  a focus change, only it keeps the value. Reviewer's throwaway test (not
  committed): `LimitsPage` pumped directly, *Výchozí limit* typed to 30
  (focused), then the page replaced with `pumpWidget(const MaterialApp(home:
  SizedBox()))`. With the code as it is: saved, and `onLeave` once.
  Without `_commitOnDispose()`: `Expected: <30.0>, Actual: <25.0>`. The
  same with an open subject row typed to 18: without the page's dispose
  commit, `Expected: {'Matematika': 18.0}, Actual: <null>`.
- **What correct looks like:** one commit, test only, `F1c (O4): test the
  dispose save without a route change (R3c code S12)`, adding those two
  cases to `limits_page_test.dart`: build `LimitsPage` with a plain
  `SettingsController` (`persist` / `persistQuiet` record the updates) and
  an `onLeave` counter; type without leaving the field; replace the page
  with `pumpWidget`; expect the value in the controller and in the recorded
  updates, and `onLeave` called once after it. Run each without its fix
  and note the failure in the commit message. No code change.

---

## Notes (no action needed)

- **N33 (O5, a guard no test can catch):** removing `if
  (useExternalWakeupCard) return true;` in `savePhone`
  (`wizard_controller.dart:391`) changes nothing a test can see:
  `alarmEnabled` falls back to the saved `wakeup_enabled` when there is no
  draft (`:193–197`), so the same value would be written again. Keeping the
  guard is right; no test needed.
- **N34 (`a6b0f6e`, no test):** a pure layout fix inside O3 (the `Stack`
  now fills the 44 px cell, so the check mark sits in the top-right corner
  and the dot at the bottom centre). The commit message doesn't say why it
  has no test. Accepted: the agent's `plan-multi-*` captures show the check
  in the corner, and the reviewer's own capture (below) shows the dot and
  the check where they belong. The captures (18:25:53) are 1 minute older
  than the commit (18:26:58) but already show the fixed layout, so they
  were taken from the working tree that was then committed.
- **N35 (owner, for the phone test):** in *Vybrat více dní* a picked day
  turns the same blue as a planned day; only the small check mark tells
  them apart. That is what the note asked for ("accent fill … and small
  check indicator"). If the owner finds it confusing on the phone, it is a
  change for later.
- **N36 (accepted, not in the note's wording):**
  - `AppStateController.build` ignores `onChanged` once the provider is
    gone, plus an `isMounted` getter (`app_state.dart`): the limits page's
    one normal save runs post-frame and must not touch a disposed
    container.
  - `settingsControllerFor` uses a passed `wakeupPhone` even when
    `wakeupAvailable` is false; only the wizard passes one, Settings is
    unchanged.
  - `StrakalariChannel` keeps a `launchRouteTaken` flag: a tap that arrives
    before Dart has asked for the launch route is stored instead of being
    sent to a Dart side that isn't listening yet.
  - The path-part `pendingRoute` match (the note's M4) landed in the O4
    commit, because `/absences/limits` needed it, and O3/O7 extended it.
  - `PlannerMonthCalendar` falls back to an empty lesson list when
    `lessonsFor` throws (`catch (_)` at `planner_view.dart:1300`): a
    display probe, allowed by CONTRIBUTING §5. `_commitOnDispose` skips a
    value that doesn't parse, as the note says; the parse functions on this
    page never throw.
- **N37 (STATUS deviations):** the agent listed none for F1c, and the
  reviewer found none beyond N36.

---

## Done when (`design-F1c.md` §10)

| Check | Result |
|---|---|
| `/absences` short: header with *Limity* + *Plánovač*, 3 KPIs, `planner_next` shortcut, subject cards with stacked bars; no new rail or *Více* tab | ✔ code, `O3 short Absence screen …`, `case 3 …`, captures |
| Sub-pages: one back arrow, *Absence* on the rail and *Více* on the bar, back via arrow and Android Back to the opener; calendar on the first screen at 390 × 844 | ✔ `O7 …` tests (each fails without its part), P9b `< 708 px`, captures |
| One month calendar: past greyed and not tappable, per-cell owning term, whole / partial / partly planned days, multi-entry planned dialog, lunch off for partial, one month map with today live, multi-day with impact and one atomic save; `CustomPlanDialog` gone | ✔ except M5 (stale multi selection); M1, S2, S3, S11 tests each fail without their fix; reviewer capture |
| `/absences/limits` full width, defaults on top, default/custom rows, value chips + *Výchozí*, saves on every way out with one normal save; Settings → Limity opens it | ✔ behaviour; the dispose save is untested (S12) |
| *Telefon* always embeds `WakeupCard`, B9 and *Přeskočit* kept | ✔ tests (the duplicate prompt guard fails without it); phone evidence missing (M6) |
| Early `'bakalari'` refresh once per fingerprint, paused in memory only; *Dokončit* starts `'all'` or queues it after the lock is released; non-early busy shows `already_running` | ✔ the S6 pause proof, the M3 queued-run test and the fingerprint test each fail without their fix; phone evidence missing (M6) |
| O8 on Android: all 13 events, status, alarm icon, ringing alarm, widget; distinct request codes; cold and warm; never during the wizard | ✔ code and Dart tests (route forwarding, wizard drop and request codes each fail without their fix); phone evidence missing (M6) |
| Zero config keys; safety rules; cs/en strings in sync; tours split | ✔ |
| Captures 390 / 1280, cs / en, light / dark for `/absences`, `/absences/plan` single and multi, `/absences/limits`, *Telefon* | ✔ 40 PNGs, opened |
| Phone evidence O5 / O6 and O8 | ✘ M6 |
| Suites green, app count ≥ 739 | ✔ core 809 / 2 skipped, app 771 / 1 skipped |

## Each fix's test catches it

Most new tests can't compile on their commit's parent (they call what the
commit adds), so that proves nothing either way. One throwaway worktree in
the reviewer's scratch space (removed afterwards): for each commit, its
parent with only that commit's test files copied in, and then, at
`e1a2d3b`, each fix undone on its own with the test meant to catch it run.

| Commit | Tests on the parent |
|---|---|
| `6089a47` O6 | don't compile (`startRefresh('bakalari', true)`, `earlyRefreshInFlight`, …) |
| `e8152a5` O5 | don't compile (`LiveWizardView(wakeupPhone:)`) |
| `b1a1ae0` O4 | don't compile (`limits_page.dart`) |
| `2e4a2ea` O3 | don't compile (`LivePlannerPage`, `PlannerMonthCalendar`, …) |
| `c62b502` O7 | `android_back_test` compiles: 3 of its 4 new tests fail with assertions (from Settings, the *Dnes* tip, O4/S4); the 4th (from Absence and `/planner`) passes there, as it should, since Back already went to Absence. `mobile_narrow_shell_test` doesn't compile (`backTarget(from:)`) |
| `05942f2` O8 | don't compile (`applyLaunchRoute`, `notificationEventRoutes`) |

| Fix undone at `e1a2d3b` | Test run | Result |
|---|---|---|
| M3: queued `'all'` started from `finishRun` (inside the lock) | `finishWizardRefresh queues one full all run …` | fails |
| S6: `runConfig` without `automation_paused` | `pauseAutomation blocks auto excusePending …` | fails (`Expected: <0>, Actual: <1>`) |
| S5: `finishWizardRefresh` ignores the early run | the queued-run test; `Dokoncit while early refresh is in flight …` | fails |
| O6: fingerprint check removed; trigger removed | `verified Bakalari login starts early refresh once per fingerprint …` | fails, both |
| O5: duplicate permission prompt allowed | `embeds WakeupCard … without duplicate permission prompt` | fails |
| O5: `savePhone` guard removed | the two *Telefon* tests | pass (N33) |
| M4: exact-match `pendingRoute` | both *Dnes* tip tests | fail |
| S10: no `_commitOnDispose()` | the three S4 + S10 tests | pass (S12) |
| S4: no subject commit in the page's `dispose` | the three S4 + S10 tests | pass (S12) |
| S4: no normal save on leave | `S4 + S10 …` | fails |
| S11: today served from the cache | `S11 pickerSlotsForMonth recomputes today live …` | fails |
| S1: Absence follows `plannerTerm` | `S1 selecting sem2 …` | fails |
| S2: cells only from the selected term | `S2 cross-term calendar …` | fails |
| S3: lunch box always ticked | both S3 dialog tests | fail |
| M1: partly planned treated as fully planned; split without the taught lessons; planned dialog shows one entry | `alreadyPlannedLessons…` (2), `showPlannedDialog lists multiple …` | fail |
| O7: `backTarget` ignores `from`; page arrows ignore `from`; any `from` accepted; rail/bar without `navRoute` | the O7 tests | fail, all four |
| O8: route kept during the wizard; event route not forwarded; request code `0` for all | the O8 tests | fail, all three |

## What the reviewer verified, and how

1. **Suites** at `e1a2d3b` (Flutter 3.44.8 / Dart 3.12.2):
   `dart pub get --enforce-lockfile` OK; core `dart analyze` no issues,
   `dart test` **809 passed, 2 skipped**; app `flutter analyze` no issues,
   `flutter test` **771 passed, 1 skipped** (739 at the design PASS, +32).
   Baseline for the re-review: these counts.
2. **Every commit on its own:** `flutter analyze` clean and `flutter test`
   green at `6089a47` (745), `e8152a5` (746), `b1a1ae0` (750), `2e4a2ea`
   (759), `c62b502` (766) and `05942f2` (771), each with the 1 old skip;
   `a6b0f6e` has the code of HEAD. No core file changed, so the core run at
   HEAD covers them all.
3. **The code against the note**, every item: `activity.dart`
   (`startRefresh`, `finishWizardRefresh`, `_refreshWork`'s `finally`,
   the paused `runConfig`), `wizard_controller.dart` / `wizard_live.dart` /
   `wizard_view.dart`, `settings_live.dart` (`channelWakeupPhone`),
   `settings_view.dart` (`AutosaveField.saveOnDispose`), `limits_page.dart`,
   `absences_view.dart` / `absences_live.dart`, `planner_view.dart`
   (`PlannerPage`, `PlannerMonthCalendar`, `PlanDayDialog`,
   `PlanMultiDialog`, `_PlannedEntriesDialog`), `planner_controller.dart`,
   `controllers/planner.dart` (`pickerSlotsForMonth`), `router.dart`,
   `scaffold.dart`, `today_view.dart`, `tours.dart`, `app_state.dart`
   (`applyLaunchRoute`), `android_channel.dart`,
   `android_notifications.dart`, `startup.dart`, and the Java and Kotlin
   files. Old and new dialogs compared for the lunch default and the
   snack texts (unchanged except S3).
4. **Tests catch the fixes:** tables above, plus two throwaway tests (M5,
   S12). Nothing committed; the worktree was removed.
5. **Test integrity:** a script listed every `test(` / `testWidgets(` name
   at `daa4b55` and at `e1a2d3b`: 1494 → 1526 calls, no file lost a test.
   The six names that disappeared are renames the note lists in §9.1 (e.g.
   `case 3: … 4 KPIs` → `3 KPIs`, N30; `wide: … row` → `column`). Every
   removed `expect` was read: each moved where §9.1 says (the 4-card P9a
   checks to `absences_view_test`'s new narrow test, the custom-dialog
   confirm checks to `plan:multi_confirm`, the DST rows to columns plus a
   month step) or was scoped tighter (`state_critical` inside
   `abs:subjects`, since *Kritické* is now also a KPI label). No `skip:`,
   no `try`/`catch` around assertions, no host other than `127.0.0.1`.
6. **Screens:** the agent's 40 captures in `build/qa-evidence/F1c/`
   opened (390 and 1280, cs and en, light and dark, five screens). A
   reviewer capture of the month calendar at 390 px, cs, dark and light,
   with a partly planned, a fully planned and a multi-picked day: dot,
   solid fill and corner check all where they belong, no overflow.
   `docs/images/absences-{cs,en}.png` show demo data.
7. **Scope:** every change maps to `design-F1c.md`, plus N36. No F2 or
   later work.
8. **Config keys and strings:** `git diff daa4b55..HEAD` doesn't touch
   `config.example.json`, `packages/` or `test/parity/`. A script compared
   both ARB files and both `strings.dart` tables: 800 keys each, identical
   values; the 8 new keys and the 3 updated texts are word for word the
   note's; the 4 removed keys have no use left (grep over `app` and
   `tools`).
9. **Safety rules:** every refresh still goes through `startRefresh` →
   `withSessionLockAsync` → `runRefresh`, including the early and the
   queued run. `automation_paused: true` lives only in the in-memory
   `runConfig` (the S6 test reads `config.json` back). Nothing in core, in
   `excuses.dart` or `lunches.dart`, or in the send, order, audit or lock
   code changed. Planning still goes through `planSkip` / `planEntries` /
   `unplanEntry` and the unchanged lunch-cancel staging. No new silent
   `catch` in send, order or save code (N36).
10. **Phone:** not checked by the reviewer (M6 is the agent's next step).
    `adb devices` shows the Pixel `2C221FDH3002NZ` connected.
11. **Hygiene:** all commits by the configured user, no `Co-Authored-By`,
    `Claude-Session` or "Generated with" lines, no personal files or phone
    screenshots committed, `qa-roadmap` has no upstream, `main` has no
    commits the branch lacks. The uncommitted `generated_plugin*` files
    are the known Flutter line-ending churn.
12. **Not checked:** the Android build (the agent reports the `phonetest`
    APK built; M6 will show it), macOS and iOS (not possible here).
