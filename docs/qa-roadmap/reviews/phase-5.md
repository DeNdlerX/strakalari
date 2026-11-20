# R5 review: F3 (automatic lunch cancelling) and O9

Reviewed 2026-11-20 at `qa-roadmap` @ `61686ab` (base `main` @ `656e118`;
`main` has no commits the branch lacks, so no merge was needed at the
phase start). Commits since the R4 re-review 2 and the merge into `main`:

- `66dae7a` F3, one commit for the item;
- `05e28ce` O9, the owner's wizard toggle (2026-11-20), one commit;
- `61686ab` STATUS.

Checked against PLAN §6 (phase 5), §9, the owner's F3 and D3 answers and
the O9 request in STATUS (word for word), report §3.5 (background),
CONTRIBUTING §5–6 and every earlier review.

## Verdict: FAIL

F3 does what the owner chose in D3, and the safety frame around it is
right. On every refresh, even in *S potvrzením* (confirm) mode, the app
now cancels a lunch that is still ordered on a calendar free day (preset
or own, minus forced school days) or on a day planned off with *Odhlásit
oběd*, unless the user picked a meal for that day in the app. Every
cancel goes through the one Strava order path (`stravaOrderSelected`,
which checks the deadline again and saves once), inside `runRefresh`
under the session lock; it respects the order deadline,
`automation_paused` stops it, and every attempt is in the audit with its
reason (free day / planned), dry run included, where nothing is sent. A
cancel that fails is a loud automation error and is tried again on the
next refresh. A day the app cancelled, or a meal the user picked in the
app, is remembered, so a lunch the user orders again on that day is not
cancelled a second time. Settings → Pravidla has the switch (on by
default), Obědy shows a *Bez školy* tag and the free day's name, Aktivita
shows the reason, and a notification lists the cancelled days. All
suites are green, no test was removed or weakened, the config key is
added everywhere it must be, and the parity fixtures changed only by that
key.

O9 is done as the owner asked: a switch *Automaticky objednávat obědy* on
the wizard's Strava step, off by default, that asks the usual safety
question before it turns automatic ordering on.

One finding blocks the pass:

- **M1:** a day planned off only for some lessons (for example arriving
  at the third lesson after a doctor's visit) gets its lunch cancelled
  automatically, also in confirm mode. PLAN says a partial absence never
  cancels a lunch. The test that should prove it uses a made-up key and a
  "keep my lunch" tick, so it never tests a partial day.

Four should-fix:

- **S1:** the test that should prove free days in May and June still
  count uses misspelled config keys, so it would pass without the fix.
- **S2:** no tutorial mentions the new automatic cancelling or its switch
  (PLAN rule 7).
- **S3:** with the new switch turned off, automatic ordering still skips
  every free day (before F3 it ordered there), and so do the filter and
  the AI picks on Obědy; the switch's own text promises only to stop the
  cancelling.
- **S4:** two small parts of the fix have no test (a cancel the planner
  staged is dropped once the app has done it; the Obědy screen's own
  filter skips free days).

The reviewer undid 32 parts of F3 and O9 one at a time: 28 are caught by
the new tests (table below).

One owner decision is needed (Q1): older installs also get the
cancelling switched on, and the first refresh after the update cancels
every lunch still ordered on an upcoming free day or planned day off.

---

## Must-fix

### M1 (F3, `66dae7a`): a partly planned day has its lunch cancelled automatically

- **Where:** `packages/strakalari_core/lib/src/automation/refresh.dart:753–801`
  (`_autoLunch`): `plannedDays` is `plannedLunchDaysHook(cfg)` plus the
  app's `cancelledLunchDays`, and every one of those days is a cancel
  target for `planAutoCancelsHook` (`lunch_auto.dart:448–472`) and, in
  auto mode, for the deorders `planAutoOrdersHook` makes. Both sources
  hold **every** day of a planned entry with `cancel_lunch != false`,
  whole or partial: `plannedLunchDays` (`planned_skips.dart:257`) and
  `AppState.cancelledLunches` (`app/lib/controllers/app_state.dart:114–127`).
  An entry's `start_period` / `end_period` (which limit its first and last
  day, see `entryLessons`, `planner.dart:216`) are never looked at.
- **What is wrong:** PLAN §6 phase 5: "A day with only a **partial**
  absence never cancels a lunch (test)." A partial plan without a
  `cancel_lunch` key is cancelled on the next refresh, in confirm mode
  too (the default, so every user). That key is missing in every partial
  plan made before R3c S3 (the dialog ticked *Odhlásit oběd* for partial
  days then) and in every partial plan where the box is ticked now,
  because `normalizePlannedEntry` stores only `false`. The typical case is
  a late arrival (planned lessons 1–2): the student is at school for
  lunch, and the app cancels it without asking. Before F3 only `auto`
  mode did this (the reviewer checked it on `656e118`).
- **The test doesn't catch it:** `confirmModeCancelsFreeAndPlannedDaysOnlyNeverPartialOrAbsence`
  (`refresh_test.dart:1137`) builds its "partial" day as
  `{'lessons': [1, 2], 'cancel_lunch': false}` (`:1131`). `lessons` isn't a
  planned-skip key, and `cancel_lunch: false` keeps the lunch for a whole
  day as well, so the test passes for that reason alone. Its "absence"
  day has no absence data. The comment "Partial school days … are never
  cancelled" in `lunch_auto_test.dart:330` tests a normal day.
- **Reviewer's check** (throwaway test, not committed): an ordered lunch
  on `07.10.2099`, planned skip `{'start_date': '2099-10-07', 'end_date':
  '2099-10-07', 'start_period': 1, 'end_period': 2}`, refresh at
  `01.10.2099 09:00`, scope `strava`. At `66dae7a`, in `confirm` and in
  `auto`: `Expected: 't3&1&0'`, `Actual: 't3&-1&0'` (cancelled).
- **What correct looks like:** one commit,
  `F3: never cancel a lunch automatically on a partly planned day (R5 M1)`.
  - A planned day is a cancel target only when a planned entry with
    `cancel_lunch != false` covers that **whole** day: the day isn't the
    entry's first day with `start_period` set, nor its last day with
    `end_period` set (any set period counts as partial; when in doubt,
    don't cancel). A day covered whole by one entry and partly by another
    is whole.
  - Add a helper next to `plannedLunchDays` in `planned_skips.dart`, e.g.
    `Set<String> wholePlannedLunchDays(Map<String, Object?>? config)`.
    Don't change `plannedLunchDays` (frozen parity case).
  - In `_autoLunch`, keep `allCancelled` as it is for "don't order a meal
    there", but use only days in `wholePlannedLunchDays(cfg)` (plus free
    days) as cancel targets: filter `plannedDays` before
    `planAutoCancelsHook`, and drop from `planAutoOrdersHook`'s result
    every `&-1&` pick for a planned day that isn't whole. This applies in
    every mode, auto included; the plan's rule has no exception, and it
    can only cancel less than before.
  - The planner keeps staging the cancel of a ticked partial day for the
    manual *Odeslat* (`stageLunchCancel`), so a user who really wants that
    lunch cancelled still can, with one tap.
  - Tests, in `refresh_test.dart` group `f3AutoCancelLunches`; each must
    fail at `66dae7a`:
    - fix `baseF3Config`: the partial entry becomes `{'start_date':
      '2099-10-07', 'end_date': '2099-10-07', 'start_period': 1,
      'end_period': 2}` with **no** `cancel_lunch` key; keep a separate
      whole day with `cancel_lunch: false` (lunch kept) so that case stays
      covered; the partial day keeps its lunch in `confirm` **and** in
      `auto` mode;
    - a three-day entry `2099-10-05`…`2099-10-07` with `start_period: 3`
      and `end_period: 2`, lunches ordered on all three days: only
      `06.10.2099` is cancelled;
    - a unit test of `wholePlannedLunchDays` with those shapes.
  - Fix the comment at `lunch_auto_test.dart:330` (it is a normal day).

---

## Should-fix

### S1 (F3 test, `66dae7a`): the "unclipped calendar" test uses keys that don't exist

- **Where:** `packages/strakalari_core/test/lunch_auto_test.dart:291–292`
  (`freeLunchDaysUsesUnclippedCalendarAndRespectsForcedSchoolDays`) sets
  `semester_1_close` / `semester_2_close`. The config keys are `sem1_close`
  / `sem2_close` (`school_presets.dart:43–44`, `resolveClose`).
- **What is wrong:** with unknown keys nothing is clipped, so the test
  passes whether `freeLunchDays` reads the clipped calendar or not. The
  reviewer switched `freeLunchDays` to `effectiveCalendar(configData)`
  (clipped): all core tests stayed green. The choice matters: GEKOM's
  `sem2_close` is 26.04.2027, so a clipped calendar would drop every free
  day in May and June and those lunches would never be cancelled.
- **What correct looks like:** one commit,
  `F3: test free lunch days after the semester close (R5 S1)`: use
  `'sem2_close'` with a date before the free day (same `DD.MM.YYYY`
  format as the preset, e.g. `'30.04.2020'`) and keep the two
  expectations. It must fail with `clip: true` in `freeLunchDays`.

### S2 (F3, `66dae7a`): no tutorial mentions the automatic cancelling

- **Where:** `app/lib/tutorial/tours.dart` and the `tut_*` strings are
  unchanged by F3.
- **What is wrong:** PLAN rule 7 / CONTRIBUTING §5: a feature that adds a
  control updates the tutorials. F3 adds the *Automaticky odhlašovat
  obědy* switch and a behaviour that changes Strava without asking; the
  Obědy tour still says only that *Odeslat* sends staged changes.
- **What correct looks like:** one commit,
  `F3: mention automatic lunch cancelling in the Obědy tour (R5 S2)`:
  add one sentence to `tut_lunch_send_body` in `app_cs.arb`, `app_en.arb`
  and `strings.dart`, e.g. cs *"Obědy ve volné dny a v naplánovaném
  volnu se odhlásí samy při obnově (vypnete v Nastavení → Pravidla)."*,
  en *"Lunches on free days and planned days off are cancelled on refresh
  by themselves (turn it off in Settings → Rules)."* Add an assertion in
  `app/test/tutorial_test.dart` that the lunches tour mentions it in both
  languages.

### S3 (F3, `66dae7a`): the switch turned off still keeps lunches off free days

- **Where:** `lunch_auto.dart:518–521` (`planAutoOrders` adds
  `freeLunchDays(cfg)` to the days it never orders), `refresh.dart:758–761`
  (`freeDays` in `allCancelled`), `app/lib/controllers/lunches.dart:414`
  (AI picks) and `:508` (filter), and
  `app/lib/features/lunches/lunches_controller.dart:193` (filter) all skip
  free days whatever `strava_auto_cancel_lunches` says.
- **What is wrong:** with the switch off, `auto` mode no longer orders a
  lunch on a calendar free day (the reviewer's probe: on `656e118` it
  ordered `06.10.2099`, at `66dae7a` with the switch off it orders
  nothing), and the filter and AI picks never stage one. That is a change
  the plan didn't ask for and STATUS doesn't list under *Deviations*; the
  switch's hint promises only that cancelling stops. A student whose
  canteen serves lunch on a director's day off, and who turned the switch
  off for that reason, gets no lunch from automatic mode there.
- **What correct looks like:** one commit,
  `F3: free days skip ordering only while automatic cancelling is on (R5 S3)`:
  use the free days as "don't order" days only when
  `stravaAutoCancelEnabled(cfg)` is true (one small helper in
  `lunch_auto.dart`, used in `planAutoOrders`, `_autoLunch`, the two
  `lunches.dart` places and `LunchController`). The *Bez školy* tag on
  Obědy stays in both cases. Tests: `planAutoOrders` with the switch off
  orders the unordered free day `d2` (extend
  `planAutoOrdersSkipsFreeDaysAndRespectsCancelFlagAndOverrides`), and the
  app's `filterAndAiRecommendSkipFreeDays` gains the switch-off case; both
  must fail at `66dae7a`.

### S4 (F3 tests, `66dae7a`): two parts of the fix have no test

- **Where:** `app/lib/controllers/activity.dart:457–459` (after a refresh,
  days the app cancelled are removed from `pendingOrders`) and
  `app/lib/features/lunches/lunches_controller.dart:193` (the Obědy
  screen's own filter skips free days).
- **What is wrong:** the reviewer removed each alone at `66dae7a`; every
  app test stays green. Today the first is mostly tidiness (a staged
  cancel that matches the web no longer counts as a change), but nothing
  would notice if a later change made a stale staged cancel count or be
  sent again; the second is the screen's half of the free-day rule.
- **What correct looks like:** one commit,
  `F3: test the cleared staged cancel and the Obědy filter (R5 S4)`:
  - in `refreshAutoCancelsFreeDaysRespectsKeptLunchAndFiresNotification`
    (`app/test/app_state_lunches_test.dart`), stage a cancel for the free
    day first (as the planner does) and assert that `pendingOrders` no
    longer holds it after the refresh;
  - a `LunchController.applyFilter` test (`app/test/lunches_view_test.dart`
    or `lunches_live_test.dart`) where `freeDayLabels` holds a day with an
    open menu: no pick is staged there. With S3 done, also the switch-off
    case (picked again).
  Both must fail with the line removed.

---

## Owner decision needed

### Q1: older installs get it switched on too

The switch is on whenever the config has no `strava_auto_cancel_lunches`
key, which is every install from before this update. D3 answered "On by
default" for new users. So after updating, the **first refresh** on
every existing install (the Play app on your phone included) cancels, at
once and without asking, every lunch still ordered on an upcoming free
day from the school calendar or on a day planned off with *Odhlásit
oběd*, as long as the order deadline hasn't passed. A notification lists
the days. The app can't tell a lunch someone ordered on the Strava
website on purpose (say, the canteen is open on a director's day off)
from any other: it is cancelled the first time; if they order it again,
the app leaves it alone from then on.

- **(a) Keep it on for everyone** (the reviewer's recommendation; it is
  what "All free days from the calendar should have the lunch canceled"
  says). No code change.
- **(b) Older installs start with it off** and turn it on in Settings →
  Pravidla. That needs a one-time change of older configs, which the
  agent would then add.

---

## Notes (no action needed)

- **N1 (dry run):** in *Jen nanečisto* mode nothing is remembered, so
  every refresh simulates the same cancels again and writes one more
  *Nanečisto* row per day to Aktivita (hourly at the default interval)
  until the deadline passes. Nothing is sent; it is only noise. Recording
  dry-run days as handled would be wrong (they would then be skipped after
  switching to confirm), so leave it unless the owner minds.
- **N2 (redundant check):** the switch is checked in `_autoPhases` and
  again in `planAutoCancels`; undoing the first alone is caught by
  nothing, which is fine because the second still holds.
- **N3 (race, safe side):** planning a day off or adding a free day
  *while* a refresh runs that cancels some other day can put that day
  back on the "handled" list when the refresh saves. The result is a
  lunch not cancelled automatically (the planner's staged cancel still
  waits for *Odeslat*), never an extra cancel. Manual orders run under
  the session lock, so a manual re-order can't be lost this way.
- **N4 (lost cache):** the "handled" days live in `data_cache.json`. If
  that file is reset, a lunch re-ordered on a free day after an automatic
  cancel is cancelled once more; the notification says so.
- **N5 (O9):** after choosing *Nanečisto* in the safety question, the
  wizard switch shows off with the dry-run note, and turning it on and
  pressing *Zrušit* keeps dry run; going back to confirm is in Settings →
  Pravidla. Fine for a test mode.
- **N6 (O9 test):** `05e28ce` also adds `key: ObjectKey(s)` to the B7
  test helper (`wizard_live_test.dart:502`); each B7 test pumps one state,
  so it changes nothing. Harmless.
- **N7 (evidence):** the English Aktivita captures show the run line as
  "10 předmětů · Auto-cancelled lunches: 1". The run line is stored as
  text in the language of the run (as before F3); the mixed line comes
  from the capture's seeded run, not from the app. The `→` in the O9
  hint shows as a box only because the capture font lacks it (as in R2).
- **Deviations accepted:** `roundTripFiles` gains only
  `"strava_auto_cancel_lunches": true` in its two full config files (PLAN
  rule 4; the reviewer's word diff shows nothing else); O9 is the owner's
  own request, recorded word for word, off by default and behind the
  safety question; the P4 test now checks every switch on the Strava step
  with the same three assertions per switch, which is stricter, not
  looser. The `dayStatus` fix (a cancelled `&-1&` order no longer shows
  *Objednáno ve Stravě*) and the AppState constructor reorder are needed
  for F3 to show its result, and each has a test.

---

## Done when (PLAN §6, phase 5, with D3)

| Requirement | Result |
|---|---|
| Triggers as D3 says: calendar free days and planned days only | ✔ `freeLunchDays` (preset + own days − forced school days, not clipped at the semester close) and planned days with *Odhlásit oběd*; no Bakaláři absence or excuse is a trigger. But see M1 for partial planned days |
| Confirm mode as D3 says: cancel automatically, unless the user picked a lunch | ✔ runs in `confirm`; a meal picked in the app (sent: `recordWebOrders` → handled list; staged: `keptLunchDays`) is never cancelled; a newly planned day or newly added free day clears its mark (`clearCancelHandledDays`) |
| On by default, switch in Settings → Pravidla | ✔ `rule:auto_cancel_lunches`, default `true` (Q1 for older installs) |
| One order path, one verified save | ✔ `stravaOrderSelected(..., source: 'auto')` → `_orderSelected` (deadline re-checked per day, one save); end-to-end test against `FakeStravaTransport` sees one save |
| Session lock | ✔ inside `runRefresh`, whose only app caller runs under `withSessionLockAsync` (`activity.dart:365`) |
| Order deadline | ✔ `planAutoCancels` uses `orderWindowPredicate`; reviewer's probe: a free day tomorrow at 12:30 today is left alone |
| `automation_paused` | ✔ stops it (test; undoing it is caught) |
| Audit, dry run included | ✔ every attempt via `_auditOrders`, with `reason`; dry run audits `dry_run` and sends nothing |
| A partial absence never cancels a lunch (test) | ✘ M1 |
| Activity entry and notification text in cs and en | ✔ `audit_reason_free_day` / `_planned`, run line `auto_lunch_cancelled`, notification `auto_lunch_cancel_notif_*` on the existing `lunch_skipped` event; core `auto_cancels_failed` in `i18n.dart` |
| Tutorial (rule 7) | ✘ S2 |
| Screens 390/1280, cs/en, light/dark | ✔ 24 F3 captures (Obědy, Pravidla, Aktivita) and 11 O9 captures, taken right before each commit |

## Each fix's test catches it

The new tests in `config_test.dart`, `activity_view_test.dart` and
`settings_sections_test.dart` fail by assertion on `656e118` (`Expected:
true`, `Actual: <null>`; `Expected: contains 'audit_reason_free_day'`;
the switch test). `lunch_auto_test.dart`, `refresh_test.dart`,
`app_state_lunches_test.dart`, `lunches_live_test.dart`,
`lunches_view_test.dart` (F3) and `wizard_live_test.dart` (O9) don't
compile on their parents (they use the new names), so the reviewer read
them and undid each part of the fix alone on `66dae7a` / `05e28ce`:

| # | Part of the fix undone alone | Caught by |
|---|---|---|
| 1 | `automation_paused` no longer stops the cancelling | `automationPausedBlocksAutoCancel` |
| 2 | switch not checked in `_autoPhases` | — (the check in `planAutoCancels` still holds, N2) |
| 3 | switch not checked in `planAutoCancels` | `planAutoCancelsCoversFreeAndPlannedDaysAndRespectsOverrides` |
| 4 | handled days not removed from the targets | same, and `cancelHandledAndKeptLunchDaysPreventRecancel` |
| 5 | staged meals (`keptLunchDays`) ignored in core | `cancelHandledAndKeptLunchDaysPreventRecancel` |
| 6 | dry run records its days as handled | `dryRunSimulatesAutoCancelWithoutRecordingCacheHandled`, `endToEnd…` |
| 7 | audit `reason` not attached | `endToEndStrakalariFakeStravaCancelsInConfirmAndSkipsSendInDryRun` |
| 8 | failed cancel not raised | `failedCancelRaisesAutomationError` |
| 9 | free days clipped at the semester close | — (S1) |
| 10 | auto mode orders on free days | `planAutoOrdersSkipsFreeDaysAndRespectsCancelFlagAndOverrides` |
| 11 | handled list not saved after a cancel | `confirmMode…`, `endToEnd…` |
| 12 | no cancelling in confirm mode | four `f3AutoCancelLunches` tests |
| 13 | reasons swapped (free day reported as planned) | `confirmMode…`, `endToEnd…` |
| 14 | config validation removed | `defaultIsTrueAndRejectsNonBoolean` |
| 15 | a meal sent from the app not added to the handled list (`recordWebOrders`) | `manualWebPickRecordsCancelHandledAndSurvivesRestart` |
| 16 | that day kept in `cancelledLunches` | same |
| 17 | `planCustomSkip` doesn't clear the day's mark | `planningSkipOrAddingFreeDayClearsCancelHandledAfterSave` |
| 18 | `planEntries` doesn't clear it | same |
| 19 | `AppState.save` doesn't clear new free days | same |
| 20 | constructor keeps a re-ordered planned day in `cancelledLunches` | `manualWebPick…` |
| 21 | cancelled days stay staged in `pendingOrders` (`activity.dart:457–459`) | — (S4) |
| 22 | no notification | `refreshAutoCancelsFreeDaysRespectsKeptLunchAndFiresNotification`, `refreshAutoCancelMultipleDaysFormatsPluralNotification` |
| 23 | `dayStatus` shows a cancelled order as ordered | `day status: cancelled / web-ordered / to-send / none` |
| 24 | switch shows off by default | `auto cancel lunches switch defaults true and toggles` |
| 25 | the app doesn't pass `keptLunchDays` | `refreshAutoCancelsFreeDays…` |
| 26 | Obědy filter (`lunches.dart:508`) | `filterAndAiRecommendSkipFreeDays` |
| 27 | AI picks (`lunches.dart:414`) | same |
| 28 | `LunchController` filter (`lunches_controller.dart:193`) | — (S4) |
| 29 | *Bez školy* tag | `free day shows no-school badge and named or generic note` |
| 30 | run line `auto_lunch_cancelled` | `refreshAutoCancelsFreeDays…` |
| 31 | O9: switch turns on without the safety question | O9 test (`Found 0 widgets with type "AlertDialog"`) |
| 32 | O9: `saveStrava` doesn't write the mode | O9 test (`Expected: 'dry_run'`, `Actual: 'confirm'`) |

28 of 32 are caught. Of the 4 misses, #2 is a redundant second layer
(fine), #9 is S1, and #21 and #28 are S4.

---

## What the reviewer verified, and how

1. **Suites** at `61686ab` (Flutter 3.44.8 / Dart 3.12.2):
   `dart pub get --enforce-lockfile` OK; core `dart analyze` no issues,
   `dart test` **852 passed, 2 skipped** (839 at R4, +13); app
   `flutter analyze` no issues, `flutter test` **787 passed, 1 skipped**
   (777, +10). The plugin files `flutter test` rewrites were restored
   (line endings only).
2. **Tests on the parent:** a throwaway worktree in the reviewer's scratch
   space; F3's 8 changed test files (and the fixture) copied onto
   `656e118`, O9's onto `66dae7a`; results above. Then each part of the
   fix undone alone (table above); the worktree was removed afterwards.
3. **Reviewer probes** (throwaway, not committed), at `66dae7a`: partial
   planned day in `confirm` and `auto` (M1); auto mode with the switch off
   and a free day, also on `656e118` (S3); dry run three times (N1); a
   free day tomorrow after today's 12:00 deadline (left alone); a forced
   school day on an own free day (left alone); a Bakaláři-only refresh (no
   cancel).
4. **The code,** every changed file: `lunch_auto.dart`, `refresh.dart`
   (`_autoPhases`, `_autoLunch`), `automation.dart`
   (`stravaOrderSelected`, `_auditOrders`; `_orderSelected` read,
   unchanged), `config.dart`, `i18n.dart`, `config.example.json`,
   `app_state.dart`, `lunches.dart`, `planner.dart`, `activity.dart`,
   `lunches_controller.dart`, `lunches_live.dart`, `lunches_view.dart`,
   `settings_view.dart`, `activity_view.dart`, the wizard controller and
   view, the ARB files and `strings.dart`. Also read, unchanged:
   `planned_skips.dart`, `entryLessons`, `effectiveCalendar`,
   `lunch_cutoff.dart`, `stageLunchCancel`'s callers, the order submit
   under the session lock.
5. **Screens:** opened Obědy (cs dark 390, en light 1280), Pravidla (cs
   dark 390), Aktivita (cs dark 390, en light 390) and the O9 wizard step
   (on, dry run, en light 1280). Tag, note, switch, hint and the audit
   reasons render; nothing overflows.
6. **Test integrity:** `test(` / `testWidgets(` calls 1563 → 1586; the
   only removed test lines are the P4 block, rewritten as a loop with the
   same three assertions per switch. No `skip:`, no `try`/`catch` around
   assertions (one `try`/`finally` releases a lock), the one `isNotNull`
   is followed by an exact check, no `anything`. Hosts: only the fixture's
   stored config values and the fake Strava transport.
7. **Config keys:** `strava_auto_cancel_lunches` added in `config.dart`
   (default and boolean validation), `config.example.json` and the test
   in one commit; a script compared the keys of `canonicalDefaults` and
   `config.example.json`: 73 and 73, identical. `test/parity/` changed only
   by that key in `roundTripFiles` (word diff).
8. **Strings:** all 15 F3 and 3 O9 keys are in both ARB files and
   `strings.dart`, with real Czech and English; the string table tests are
   green.
9. **Safety rules:** refreshes still go only through `runRefresh` under
   the session lock; the excuse send path (`sendExcuse`,
   `excuse_history.dart`, `HistoryLock`) is untouched; every order and
   cancel attempt is audited, dry run included; `automation_paused` stops
   the new phase; the five new `catch` blocks all print a warning (cache
   hints and the free-day lookup), none in the order or save path.
   `excuse_mode` and `strava_order_mode` still default to `confirm`; the
   cancelling itself is on by default by D3 (Q1).
10. **Hygiene:** no personal file in `git log --stat 656e118..HEAD`; no
    `Co-Authored-By`, `Claude-Session` or "Generated with" lines;
    `qa-roadmap` has no upstream; `main` has nothing the branch lacks.
11. **Not checked:** the real Strava site (forbidden; the fake transport
    stands in) and macOS/iOS builds (not possible here). F3 has no phone
    item.
