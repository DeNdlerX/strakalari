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

---

## Re-review 2026-11-20

Reviewed at `qa-roadmap` @ `6d5a4c7` (base `main` @ `656e118`; `main` has
no commits the branch lacks). Commits since the review (`77cae1c`):

- `7de48b3` STATUS: the owner's Q1 answer (a), word for word;
- `1879316` M1, `3859f2e` S1 (test only), `db16b60` S2, `a2f6f3d` S3,
  `2da7338` S4 (test only), one commit each;
- `6d5a4c7` STATUS.

### Verdict: PASS WITH FIXES

All five findings are fixed in the code, not just marked fixed. A day
planned off only for some lessons now keeps its lunch, in confirm and in
auto mode; only days planned off whole are cancelled automatically, and
the planner still prepares the cancel of a ticked partial day for the
manual *Odeslat* (M1). The test for free days in May and June uses the
real config keys and fails when the calendar is cut at the semester close
(S1). The Obědy tour says that lunches on free days and planned days off
are cancelled by themselves, and where to turn it off (S2). With the
switch off, automatic ordering, the filter and the AI picks use free days
again, as before F3, and the *Bez školy* tag stays (S3). The two parts
without a test now have one (S4). Every new test fails on the code before
its fix with an assertion, 13 of 15 parts of the fixes undone alone break
a test, both suites are green, no test was removed or weakened, and the
owner's Q1 (a) needs no code. In the *Done when* table above, the two ✘
rows (partial absence, tutorial) are now ✔.

One should-fix is left, **S5**. In auto mode, M1's new filter drops more
than R5 asked: also the "no lunch" pick the blacklist filter makes for a
day where every meal is on the blacklist. That is the better behaviour
(before this round, F3 reported such a day as "lunch cancelled
automatically", which wasn't true), so the code stays. But it is an
unlisted change in the order path with no test, and the code comment
doesn't say it.

### Should-fix

#### S5 (F3 / M1, `1879316`): the new filter also drops the "no lunch" pick on ordinary days, untested and unlisted

- **Where:** `packages/strakalari_core/lib/src/automation/refresh.dart:798–805`
  (`_autoLunch`, the `orders.removeWhere` after `planAutoOrdersHook`):
  `if (!cancelTargets.contains(canon)) return true;` (`:803`) drops every
  `&-1&` pick that isn't a cancel target, not only the partial planned
  days M1 was about.
- **What it changes:** in auto mode, `filterPicks`
  (`lunch_auto.dart:200–204`, `:269` `chosen ??= deorderId`) gives a day
  with nothing ordered whose every meal is on the blacklist the day's
  `&-1&` control. Gemini never sees those ids (`gemini.dart:84`), so this
  fallback is the only other source of such picks. On Strava the pick
  changes nothing: `_cancelDay` (`strava/ordering.dart:181`, `:187`)
  returns true with nothing staged when nothing is ordered.
  - **Before this round** (`66dae7a`) the pick was sent, and F3 reported it
    as an automatic cancel with reason `planned` (the `?? 'planned'`
    fallback): the *lunch cancelled* notification, an Activity row,
    `lunchesCancelled` 1, the day on `auto_lunch_cancel_handled`. A false
    report that R5 missed.
  - **Now** the pick is dropped: no false report. The side effect: the day
    is no longer put on `auto_lunch_handled` (it was since before F3), so
    auto mode looks at it again on each refresh and orders it if the menu
    later offers a meal that isn't blacklisted, the same as a day whose
    menu has no cancel control today.
- **What is wrong:** R5 M1 asked to drop the `&-1&` picks "for a planned
  day that isn't whole". The wider drop is a change in the order path
  that STATUS doesn't list (*Deviations: None added in this R5 fix
  round*). No test covers it: with `:803` narrowed to what R5 wrote
  (`if (allCancelled.contains(canon) && !cancelTargets.contains(canon))
  return true;`) all 38 `refresh_test.dart` tests pass, and the false
  report comes back. The comment at `:798–799` ("days disabled, partial,
  or already handled") doesn't mention it.
- **Reviewer's check** (throwaway test, not committed): auto mode, switch
  on, no free or planned days, blacklist `['Guláš']`; menu `05.10.2099`
  `{'t1&1&0': 'Guláš', 't1&-1&0': 'x'}` and `06.10.2099`
  `{'t2&1&0': 'Řízek', 't2&-1&0': 'x'}`; nothing ordered; clock
  `01.10.2099 09:00`; scope `strava`.
  - At `66dae7a`, and with `:803` narrowed: order call
    `{05.10.2099: t1&-1&0, 06.10.2099: t2&1&0}`, `lunchesCancelled` 1,
    `autoCancelledDays` `{05.10.2099}` with reason `planned`,
    `auto_lunch_cancel_handled` `[05.10.2099]`.
  - At `6d5a4c7`: order call `{06.10.2099: t2&1&0}`, `lunchesCancelled` 0,
    nothing reported; `auto_lunch_handled` `[06.10.2099]`.
  - With `05.10.2099` already ordered, all three versions behave the same
    (the filter never looks at an ordered day).
- **What correct looks like:** keep the code; the reviewer accepts the
  behaviour. One commit,
  `F3: test that an all-blacklisted day is not reported as cancelled (R5 S5)`:
  - **Comment** at `:798–799`: every `&-1&` pick that isn't a cancel target
    is dropped: partial planned days (M1), days where cancelling is off or
    already handled, and the filter's "everything blacklisted" fallback on
    a day with nothing ordered, which changes nothing on Strava and would
    otherwise be reported as an automatic cancel.
  - **Test** in `refresh_test.dart`, group `f3AutoCancelLunches`, e.g.
    `allBlacklistedDayIsNotReportedAsCancelled (R5 S5)`: a `FakeApp`
    subclass whose `stravaBlacklist` returns `['Guláš']` (`FakeApp`'s
    getter, `:198`, returns `const []`); the scenario above; expect exactly
    one order call holding only `{'06.10.2099': 't2&1&0'}`,
    `lunchesCancelled == 0`, `autoCancelledDays` empty, `lunchesOrdered ==
    1`, and no `cancelHandledKey` in the data cache. It must fail at
    `7de48b3` (the code before M1) and with `:803` narrowed as above.
  - **STATUS**, *Deviations from the plan*: one line saying that in auto
    mode M1's filter drops every `&-1&` pick that isn't a cancel target,
    the all-blacklisted fallback included; such a day is no longer reported
    as cancelled and no longer put on the handled list, so later refreshes
    check it again.

### R5 findings, checked

- **M1 fixed** (`1879316`).
  - `wholePlannedLunchDays` (`planned_skips.dart:277`): a day counts only
    when an entry with `cancel_lunch != false` covers it and it is neither
    the entry's first day with `start_period` set nor its last day with
    `end_period` set; a day whole in one entry and partial in another
    counts. `plannedLunchDays` is unchanged (frozen parity case).
  - `_autoLunch` (`refresh.dart:755–805`): cancel targets are the planned
    days that are whole, plus the free days (`:766`); `planAutoCancelsHook`
    gets only those (`:777`); `allCancelled` still keeps a new meal off
    every planned day (`:790`); the reasons come from the whole days; the
    filter after `planAutoOrdersHook` drops the rest (see S5).
  - The planner's whole-day entries carry no period
    (`entriesForSelection`, `planned_skips.dart:227`, `:233–234`), so whole planned
    days are still cancelled. `stageLunchCancel` is unchanged, so a ticked
    partial day still waits for the manual *Odeslat*.
  - Tests as R5 asked: `baseF3Config`'s partial entry is
    `start_period: 1, end_period: 2` with no `cancel_lunch` key, plus a
    separate whole day with `cancel_lunch: false`; the test runs in confirm
    **and** auto mode (`refresh_test.dart:1145`); the three-day entry
    cancels only `06.10.2099` (`:1185`); the unit test (`:1228`). On
    `7de48b3`, with the unit test left out (it needs the new helper), both
    refresh tests fail: `Expected: <2>`, `Actual: <3>` and `Expected: <1>`,
    `Actual: <3>`. The comment at `lunch_auto_test.dart:330` is fixed.
  - The one edited assertion, `cache.containsKey(handledKey)` is false, is
    now checked in confirm mode only, because auto mode writes that list by
    design. For confirm mode it is unchanged.
- **S1 fixed** (`3859f2e`, test only). `sem1_close` / `sem2_close` with
  `DD.MM.YYYY` dates (`lunch_auto_test.dart:291–292`). With `clip: true` in
  `freeLunchDays` the test now fails (`Expected: contains '25.12.2026'`,
  `Actual: Set:[]`).
- **S2 fixed** (`db16b60`). The sentence R5 suggested, the same in both
  ARB files and `strings.dart`. The test (`tutorial_test.dart:737`) fails on
  `3859f2e` (`Expected: contains 'Obědy ve volné dny'`). The reviewer's
  throwaway widget test put the *Odešlete objednávky* bubble on a 390 px
  screen in cs and en, light and dark: 360 × 324 px (cs) and 360 × 326 px
  (en), no overflow, about the size of the existing longest step
  (`tut_plan_strip_body`).
- **S3 fixed** (`a2f6f3d`). `autoCancelFreeLunchDays` (`lunch_auto.dart:71`)
  is empty when the switch is off, and it is used in `planAutoOrders`
  (`:533`), `_autoLunch` (`refresh.dart:764`), the AppState AI picks
  (`lunches.dart:415`) and filter (`:510`), and `LunchController`
  (`lunches_controller.dart:194`). The *Bez školy* tag doesn't look at the
  switch (`lunches_live.dart:38`). On `db16b60` the tests fail:
  `Expected: 'b&1&0'`, `Actual: <null>` (`planAutoOrders`); `Expected: <1>`,
  `Actual: <0>` (refresh, auto mode orders the free day `07.10.2099`);
  `Expected: 'a&1&0'`, `Actual: <null>` (the app's filter).
- **S4 fixed** (`2da7338`, test only). The app test stages the cancel
  through `stageLunchCancel`, as the planner does
  (`app_state_lunches_test.dart:511–516`), and the new `LunchController`
  test (`lunches_view_test.dart:211`) covers the switch on and off; both
  fail with the code they guard undone (table below). The commit also fixes
  the same wrong keys as S1 in `F3 lunchControllerFor populates unclipped
  freeDayLabels` (`lunches_live_test.dart:187–188`); that test now fails
  with `clip: true` in `lunches_live.dart:38` (N12).
- **Q1 (a):** the answer is in STATUS word for word ("Yes, on for
  everyone"); no code change, as R5 said.

### Each part of the fixes undone alone (at `6d5a4c7`)

| Part undone | Caught by |
|---|---|
| M1: `planAutoCancelsHook` gets every planned day (`allCancelled`) | `confirmMode…`, `multiDayPartialEdges…` |
| M1: the filter after `planAutoOrdersHook` as at `66dae7a` | same two, in auto mode |
| M1: the first day's `start_period` ignored | `multiDayPartialEdges…`, `wholePlannedLunchDays…` |
| M1: the last day's `end_period` ignored | same two |
| M1: reasons built from every planned day | — (no effect, N9) |
| M1: the filter narrowed to partial planned days | — (S5) |
| S1: `freeLunchDays` clipped at the semester close | `freeLunchDaysUsesUnclipped…` |
| S3: `planAutoOrders` ignores the switch | `planAutoOrdersSkipsFreeDays…` |
| S3: `_autoLunch` ignores the switch | `disabledSettingCancelsNothing…` |
| S3: AppState AI picks ignore the switch | `filterAndAiRecommendSkipFreeDays` (AI half) |
| S3: AppState filter ignores the switch | same (filter half) |
| S3: `LunchController` ignores the switch | `applyFoodFilter skips free days … (R5 S4)` |
| S4: `LunchController` skips no free days | same |
| S4: the staged cancel not cleared (`activity.dart:458`) | `refreshAutoCancelsFreeDays…` (`Expected: false`, `Actual: <true>`) |
| S4: Obědy's free-day labels clipped (`lunches_live.dart:38`) | `F3 lunchControllerFor populates unclipped freeDayLabels` |

13 of 15 are caught. R5's misses #9, #21 and #28 are now caught.

### Notes (no action needed)

- **N8 (M1, odd periods):** `wholePlannedLunchDays` also counts a period
  that `normalizePlannedEntry` throws away (text, a negative number,
  `true`) as partial (`_hasSetPeriod`, `planned_skips.dart:268`). Only a
  hand-edited config has those; the planner then treats the day as whole
  while the cancelling leaves the lunch alone. Safe side, untested, fine.
- **N9 (M1, reasons):** building `cancelReasons` from every planned day
  instead of the whole ones changes nothing, because only cancel targets
  are ever cancelled.
- **N10 (screens):** `tools/parity/capture_screens.dart` can't show a
  tutorial, so the reviewer checked the S2 bubble with a throwaway widget
  test (above). The F3 captures from before this round still hold: S3 and
  S4 change which meals the filter picks, not the layout.
- **N11:** `flutter test` rewrote the generated plugin files again (line
  endings only, as in R4); the reviewer restored them.
- **N12 (S4 scope):** fixing the wrong keys in `lunches_live_test.dart` is
  the S1 bug in the app's copy of the test; STATUS lists it under S4.
  Fine.

### What the reviewer verified, and how

1. **Suites** at `6d5a4c7` (Flutter 3.44.8 / Dart 3.12.2):
   `dart pub get --enforce-lockfile` OK; core `dart analyze` no issues,
   `dart test` **854 passed, 2 skipped** (852 at R5, +2); app
   `flutter analyze` no issues, `flutter test` **789 passed, 1 skipped**
   (787, +2). These match STATUS.
2. **Tests on the parent:** a throwaway worktree in the reviewer's scratch
   space (removed afterwards). M1's `refresh_test.dart` (without the unit
   test that needs the new helper) and `lunch_auto_test.dart` on `7de48b3`;
   S3's three test files on `db16b60`; S2's `tutorial_test.dart` on
   `3859f2e`. All fail with assertions, as listed above. S1 and S4 are test
   only, so the reviewer undid the code they guard instead (table).
3. **Probes** (throwaway, not committed): the all-blacklisted day at
   `66dae7a`, at `6d5a4c7` and with `:803` narrowed (S5); the tutorial
   bubble at 390 px in cs and en, light and dark (S2).
4. **Code:** `git diff 77cae1c..HEAD` read in full: `planned_skips.dart`,
   `refresh.dart`, `lunch_auto.dart`, `lunches.dart`,
   `lunches_controller.dart`, both ARB files, `strings.dart`, six test
   files, STATUS. Also read, unchanged: `normalizePlannedEntry`,
   `entriesForSelection`, `entryCovers`, `filterPicks`,
   `mergeGeminiWithFilter`, `planAutoOrders`, `_plannedDeorders`,
   `planAutoCancels`, `updateHandledDays`, `OrderingMixin.order` /
   `_cancelDay`, Gemini's menu block, and `_autoLunch` before F3
   (`656e118`).
5. **Test integrity:** `test(` / `testWidgets(` calls 1586 → 1590. The only
   removed test lines: the confirm test's body, rewritten as a loop over
   confirm and auto with the same assertions (plus `reason:`), its
   `handledKey` check kept for confirm; the S4 test's setup, now staged
   through `stageLunchCancel` as R5 asked; the wrong keys (S1, S4); two
   comments. No `skip:`, no `try`/`catch`, no `anything` or `isNotNull`
   added. Hosts: only `refreshConfig`'s `https://bakalari.test` and fakes.
6. **Scope, keys, strings:** each commit touches only its finding's files
   (N12). No change to `config.dart`, `config.example.json` or
   `test/parity/`. One string changed (`tut_lunch_send_body`), the same in
   both ARB files and `strings.dart`; the string table tests are green.
7. **Safety rules:** `runRefresh`'s session lock, `_autoPhases`
   (`automation_paused`, dry run), the one order path
   (`stravaOrderSelected` → audit) and the excuse send path (`sendExcuse`,
   `HistoryLock`) are unchanged. The fixes only cancel less (M1, S5) or
   give back the ordering from before F3 when the switch is off (S3). No
   new `catch`. `strava_order_mode` and `excuse_mode` still default to
   `confirm`.
8. **Hygiene:** all commits by the configured user, plain messages, no
   `Co-Authored-By`, `Claude-Session` or "Generated with" lines; no
   personal file or screenshot committed; `qa-roadmap` has no upstream;
   `main` (`656e118`) has no commits the branch lacks.
9. **Not checked:** the real Strava site (forbidden; the fakes stand in)
   and macOS/iOS builds (not possible here). F3 has no phone item.

---

## Re-review 2 (2026-11-20)

At the owner's word ("Can you do the fixing yourself?", and while it was
being done, "And I approve that as reviewed, we need to work quickly", in
STATUS), the reviewer fixed S5 itself, as in R2, R3c and R4. So this fix
was written and checked by the same person. What makes up for that: the
new test fails on the code it guards, and both suites run. Reviewed at
`qa-roadmap` @ `9d6dd5b`; `main` has no commits the branch lacks. Commits
since the re-review (`4d92b4e`):

- `9d6dd5b` S5: comment, test and the STATUS *Deviations* line, one commit.

### Verdict: PASS

S5 is done as the re-review described. No behaviour changed; the code
change is a comment. The comment above the filter in `_autoLunch` now says
what it drops, including a day where every meal is blacklisted. A test
now fails if such a day were ever again sent to Strava and reported as
"lunch cancelled automatically", and STATUS lists the change under
*Deviations*. F3 is done, and with it phase 5.

### S5, checked

- **Comment:** `packages/strakalari_core/lib/src/automation/refresh.dart:798–803`
  names every kind of `&-1&` pick the filter drops: partial planned days
  (M1), days whose cancelling is off or already handled, and the
  all-blacklisted fallback on a day with nothing ordered, which changes
  nothing on Strava and would otherwise be reported as an automatic cancel.
  The code below it is unchanged.
- **Test:** `allBlacklistedDayIsNotReportedAsCancelled (R5 S5)`
  (`refresh_test.dart:1279`), with `BlacklistApp` (`:443`, a `FakeApp`
  whose `stravaBlacklist` is set): the re-review's scenario; one order
  call holding only `{'06.10.2099': 't2&1&0'}`, no errors, one lunch
  ordered, none cancelled, no cancelled days, no
  `auto_lunch_cancel_handled` in the cache. It passes at `9d6dd5b`. With
  `refresh.dart` from `7de48b3` (the code before M1), and with `:807`
  narrowed to partial planned days, it fails: `Expected:
  {'06.10.2099': 't2&1&0'}`, `Actual: {'05.10.2099': 't1&-1&0',
  '06.10.2099': 't2&1&0'}`.
- **STATUS:** the *Deviations* line says what the filter drops and what
  follows for such a day (not reported as cancelled, not on the handled
  list, checked again on later refreshes).

### Notes

- **N13 (the reviewer's mistake, repaired):** deleting the re-review's
  throwaway worktree with `robocopy /MIR` (to get past Windows' long-path
  limit) followed the Flutter plugin links in that worktree
  (`app/windows/flutter/ephemeral/.plugin_symlinks`) into the shared pub
  cache. It emptied seven packages there: `jni` 1.1.2,
  `path_provider_windows` 2.3.0, `screen_retriever_windows` 0.2.2,
  `share_plus` 12.0.2, `tray_manager` 0.5.3, `url_launcher_windows` 3.1.6
  and `window_manager` 0.5.2. The next `dart test` failed on it, which is
  how it was found. The reviewer removed the seven empty folders (only
  empty folders, by exact path) and ran `dart pub get --enforce-lockfile`,
  which downloaded the same versions again and checked them against the
  lockfile. Afterwards no package in the cache lacks its `pubspec.yaml`,
  and both suites pass. Nothing in the repository, the main checkout or
  the owner's data was touched. **Next time:** remove a throwaway worktree
  with `git worktree remove`. If the path is too long, first delete each
  link in `app/*/flutter/ephemeral/.plugin_symlinks` on its own (removing
  a link doesn't touch its target), and never use a mirroring delete.

### What the reviewer verified, and how (re-review 2)

1. **Suites** at `9d6dd5b`, after the pub cache was repaired (Flutter
   3.44.8 / Dart 3.12.2): `dart pub get --enforce-lockfile` OK; core
   `dart analyze` no issues, `dart test` **855 passed, 2 skipped** (854,
   +1); app `flutter analyze` no issues, `flutter test` **789 passed,
   1 skipped** (unchanged). The generated plugin files `flutter test`
   rewrites were restored (line endings only).
2. **Test on the old code:** in this worktree, `refresh.dart` replaced in
   turn by the narrowed filter and by the `7de48b3` version, then restored
   from a byte-compared copy of the fixed file.
3. **Test integrity:** one test added, nothing removed or changed;
   `test(` / `testWidgets(` calls 1590 → 1591. No `skip:`, no
   `try`/`catch`, no `anything` or `isNotNull`; only `refreshConfig`'s
   `https://bakalari.test` as a host.
4. **Scope, keys, strings, safety:** one comment in `refresh.dart`, one
   test with its fake, one STATUS line. No config key, parity fixture,
   string, UI or tutorial change; no new `catch`. The order path, the
   audit, the session lock and `automation_paused` are untouched.
5. **Hygiene:** committed as the configured user, plain message, no
   `Co-Authored-By`, `Claude-Session` or "Generated with" lines; no
   personal file; `qa-roadmap` has no upstream; not merged into `main`.
6. **Not checked:** the real Strava site (forbidden) and macOS/iOS builds
   (not possible here). Neither blocks the pass.
