# R8 review: F6 (low-data tiered refresh), code

Reviewed 2026-11-22 at `qa-roadmap` @ `4098142` (base `main` @ `617eb92`;
`main` has no commits the branch lacks, the branch has no upstream).
Commits since the R8a re-review (`6e2f086`), in the order of
`design-F6.md` §10:

- `47da220` commit 1: config keys, `refresh_schedule.dart`, the runner's
  next-due provider, the data estimator;
- `2577fb3` commit 2: login without `/dashboard`, direct absence read,
  fetch order, marks widget, 3-field Komens read with completeness check;
- `52c9c5a` commit 3: session pool (3a) and `bakalari_session.enc` (3b);
- `774039e` commit 4: `scope: 'quick'` in `runRefresh`, per-part stamps;
- `71bbec4` commit 5: Android network kind, the schedule wired into every
  timer, per-part labels, Aktivita quick-check line;
- `48f45ba` commit 6: Settings → Pravidla *Kontroly a data*, strings,
  tutorial texts;
- `ec5e180` phone-found fix: Today's label after a full run;
- `b51b8f6`, `4098142` STATUS.

PLAN has no F6 phase; the binding spec is `design-F6.md` as passed at
R8a (with the reviewer's own fixes, which the R8a re-review asked this
review to check hardest: §4.4, §5.3 1(e), §7.3–7.5, §4.3, §6.1), the
owner's D6 and Q1–Q3 answers in STATUS, PLAN §2 and CONTRIBUTING §5–6.

## Verdict: FAIL

The code does what the note says, and it does it carefully. Every
5-minute check makes exactly three small requests and never sends an
excuse (the reviewer undid the lock and a test failed). The short read of
the sent-excuse list is accepted only when it contains every excuse
already known, otherwise the full page is loaded in the same run. The
night pause can't turn into a check every minute, the window start and
the pre-alarm check work, and the desktop runner, the Android wake-up,
the "next run" label and the notification all use the one schedule
function. The saved login is encrypted, lent to one user at a time,
expires after 14 minutes and is deleted on a wrong password or a
password change. The send path, the excuse history, the session lock, the
audit and `automation_paused` are untouched. Both suites are green and
grew (core 881 → 936, app 829 → 839); nothing was removed, skipped or
weakened; the only changed assertions are the four the note and STATUS
list. The phone log shows four 5-minute checks with 3 requests each and
no new login, across the 15-minute session expiry.

One finding blocks the pass:

- **M1:** the rules that stop an excuse being **sent twice** after F6
  have no test. While excuses are waiting, the app must re-read the
  sent-excuse list at least every hour, and a failed read must never
  count as a fresh one. The reviewer switched each of these off in turn
  (the app never says "excuses are waiting", the app never says "an
  unconfirmed excuse exists", a failed read is marked as fresh in a quick
  check, the same in a full run): all 1,775 tests stayed green every
  time. The code is right today; nothing would catch it breaking.

Eight should-fix (S1–S8), fifteen notes. No owner decision is needed.

---

## Must-fix

### M1 (F6, `774039e` + `71bbec4`): nothing tests the "fresh sent-excuse list while excuses wait" and "failed read is not fresh" rules

These are R8a M2 (an excuse sent on the web or from another device must
stop showing as "to excuse" within an hour, or one tap sends it twice)
and R8a S2 (a full run whose outbox read failed is retried as a full run).
The core has unit tests for `chooseScheduledScope` with the booleans
passed in, and one test of a **successful** quick outbox read. What feeds
those booleans and what happens after a **failed** read is untested. The
reviewer undid each guard alone; every core and app test stayed green:

| Undone | Where | Effect if it ever breaks |
|---|---|---|
| `hasPendingExcuses: pendingExcuseTasksFor(…).isNotEmpty` → `false` | `app/lib/controllers/activity.dart:447` (multi-account) and `:561` (single) | no quick check ever reads the outbox; a web-sent excuse shows as pending for up to ~6 h; one tap sends it again |
| `hasUnconfirmed: _hasUnconfirmedForAccount(…)` → never true | `activity.dart:448`, `:562`, `:339` | rule 4 never fires; an unconfirmed submit waits up to ~6 h to be settled |
| quick-check outbox stamp only after a good read | `packages/strakalari_core/lib/src/automation/refresh.dart:690–691` | a failed read is stamped fresh; the next read waits another hour |
| full-run outbox stamp only after a good read | `refresh.dart:942–943` | rule 5 never sees the failed read; the next tick is quick; auto-excuse and settlement wait up to ~6 h |

**Correct** (tests only, no production change; each must fail when its
row above is undone):

1. `app/test/app_state_accounts_test.dart`: an account whose cache gives
   `pendingExcuseTasksFor(cfg, cache)` at least one task, last full run
   1 h ago, `part_updated['outbox']` 70 min old → `scheduledRefreshJob`
   runs a quick check that calls `syncWebExcusesToHistory` once (count it
   in `_QuickTrackingApp`); the same cache without a pending task → no
   outbox call. Cover both the multi-account path and
   `_scheduledSingleAccountRefresh` (accounts off).
2. Same file: an `already_excused_lessons.unconfirmed.json` with one entry
   in the account folder and an outbox stamp 40 min old → the scheduled
   run is `'all'` (`fetchBakalariData` called); without the file → quick.
3. `packages/strakalari_core/test/f6_quick_refresh_test.dart`: a quick
   check with `quickOutbox: true` whose outbox read fails (callback and
   page answer 500) → `part_updated['outbox']`, `sent_excuses_from` and
   `komens_outbox_details_v1` in the saved cache are unchanged,
   `quickEventful` is true, and `chooseScheduledScope` on the saved cache
   with `hasPendingExcuses: true` still returns `quickOutbox: true`.
4. Same file: a scheduled full run whose outbox read fails →
   `part_updated['full']` moves, `part_updated['outbox']` does not, and
   `chooseScheduledScope` on the saved cache returns `'all'` (rule 5).

---

## Should-fix

### S1 (F6, `71bbec4`): Aktivita says "no run yet, press Refresh" while checks run every 5 minutes

Silent quick checks add no row (design §5.5), and the run list is kept in
memory only. So after every app start, until the next full run (up to
~6 h), Aktivita shows **Nečinné · Zatím žádný běh — stiskněte Obnovit.**
and **Poslední běh —**, right under the header *Kontrola: 13:25 · Úplná:
11:28*. On the phone the app is restarted often, so this is what a user
sees most of the day (the agent's own `phone/03_activity_after_quick1.png`;
the reviewer's `reviewer-R8/activity-*.png`). Where:
`app/lib/features/activity/activity_view.dart:516–528` (idle hero) and
`:642–651` (the *Poslední běh* card). **Correct:** when there is no run
row, or the last quick check is newer than the newest row, the hero shows
the ok state with the existing `activity_last_ok` text for the quick
check's time and the *Poslední běh* card shows that time (kind `ok`). Take
the time from the saved `part_updated['quick']` (it survives a restart;
pass it in `ActivityController`), not only the in-memory counter. No new
strings. Test in `activity_view_test.dart`: no rows, quick check at 10:10
→ no `no_runs_yet` in the hero, `10:10` in the hero and in the card.

### S2 (F6, `774039e`): a full run where no week loaded is treated as if every week loaded

`refresh.dart:886–897` stores the feed hashes for **all** watched weeks
when `app.timetableLoadedWeeks` is empty, and `:908–916` counts an empty
set as "all regular past weeks loaded", writes
`absence_counts_at_past_fetch` and `past_weeks_fetched: today`. For the
real app an empty set means no week loaded (every week came back as
another week, `timetable.dart:104–118`). Then the next quick checks see
unchanged hashes and don't load next week's changes until the next full
run, and the rest of the day's scheduled full runs skip the past weeks
with a snapshot that already includes counts whose weeks were never
loaded. This is what R8a S4 and S1 ruled out. **Correct:** in both places
use exactly the loaded set (empty = nothing loaded): hashes only for
loaded watched weeks, snapshot and `past_weeks_fetched` only when every
regular past Monday is in the set. Test fakes that implement `RefreshApp`
and need the old behaviour return their loaded weeks instead (no
assertion changes). Test: a scheduled full run where every
`GetContentData` returns a different week → no new week hashes, no
`past_weeks_fetched` and no snapshot are written.

### S3 (F6, `48f45ba`): the background-notification preview in Settings still uses the Wi-Fi interval

`app/lib/features/settings/settings_view.dart:619` builds the *Pozadí*
preview text from `check_interval_minutes`, while the real notification
uses `schoolHoursIntervalForCurrentNetwork()` (`startup.dart`,
`background.dart`). On mobile data with 10 minutes the preview says "5
min" and the notification "10 min". Design §7.4 lists this call site.
**Correct:** give the preview the same value (e.g. a callback on
`SettingsController` filled from `AppState`), test it with Wi-Fi 5 /
mobile 10 on a metered network.

### S4 (F6 test, `774039e`): no test that a manual refresh always loads the full Komens page

`refresh.dart:933` (`app.nextUseCachedOutboxForm = scheduled`) is R8a S6's
backstop for M1 of the note: a manual *Obnovit data* never uses the 3
remembered fields. Set to `true`, all tests pass (the client-level test in
`bakalari_data_test.dart:1084–1089` passes `useCachedForm: false` itself).
**Correct:** a `runRefresh(scope: 'all', scheduled: false)` test with a
valid cached form in `data_cache.json` → exactly one `GET
/next/komens.aspx?s=rok&l=o`; with `scheduled: true` → none.

### S5 (F6 test, `52c9c5a`): the login-check test doesn't test the pool bypass

`connectionTestNeverUsesPoolAndRejectsWrongPasswordWhilePooledIsLive`
(`packages/strakalari_core/test/session_store_test.dart:78–108`) gives the
app a client built with `useSessionPool: false`, so it stays green when
`checkBakalariLogin` (`automation.dart:2165`) calls that client's own
`login()`. In the real app that client uses the pool, so a logged-in
pooled session would make *Test connection* and the wizard's login check
accept a **wrong** typed password. **Correct:** let the `Strakalari` build
its own client (pool on, `BakalariSessionPool.instance.transportFactory =
() => server`), log in once with the right password through the pool,
then `checkBakalariLogin()` with a wrong `bakalari_password` →
`(false, …)` and one more `POST /Login`. It must fail when line 2165
calls `client.login()`.

### S6 (F6 test, `774039e`): no test that a quick check advances a week's hash only for a week that loaded

`automation.dart:1046–1050` (R8a S4): replaced by `if (true)`, all tests
pass. If it breaks, a week whose load failed gets the new hash and its
change is never loaded by a quick check. **Correct:** a quick check where
the feed changes next week and next week's `GetContentData` returns
another week → the saved hash for next week stays the old one, and the
following quick check loads next week again.

### S7 (F6 test, `52c9c5a`, `71bbec4`): deleting the saved login on a wrong password or a password change is untested

Removed alone, all tests pass: `deleteStoredSession(dataDir)` in
`onLoginRejected` (`packages/strakalari_core/lib/src/bakalari/session_store.dart:407–410`;
the test of that name only checks `forgetAllKeys`), and
`BakalariSessionPool.instance.evict(…)` on a credential save
(`app/lib/controllers/app_state.dart:1352–1356`). **Correct:** a core
test: stored session present, the server rejects the login (`bak_login_rejected`)
→ `bakalari_session.enc` is gone; an app test: `AppState.save` of
`bakalari_password` (and of `bakalari_url`, `bakalari_username`) → the
file is gone and the next checkout logs in again.

### S8 (F6 test, `47da220`): the "two starts at once" case of the one-time defaults has no test

Design §3.3 lists "two calls racing (lock held by the first) → written
once". The re-check under the lock (`refresh_schedule.dart:402–405`) can be
removed with all tests green. **Correct:** hold the `global.json.lock`,
start the call, write one of the new keys (a "user edit") while it waits,
release → the call returns `false` and the edit is kept.

---

## Notes (no action needed unless stated)

- **N1 (R8a hardest-look parts, checked):** §4.4: the cached path runs
  only for scheduled runs with a valid, in-period, < 7-day form; every
  known excuse in the period must be in the reply or the page is loaded
  in the same run; a page-2 failure fails the whole read; a rejected
  read with a failed reload returns `null`, which settles nothing
  (`failedReadSettlesNothing`, `automation_test.dart:1086`). §5.3 1(e):
  the read goes through the same guarded path and never sends (scope
  lock). §7.3–7.4: `nextScheduledWake` never yields 0, the runner retries
  in 5 min without rewriting `lastRun`, every call site uses
  `nextDueAt`. §4.3: absence → feed → weeks → `perm`; skipped `perm`
  uses the cached baseline (days equal to a full run's, tested); past
  weeks reload when a `Count` grows past the snapshot. §6.1: exclusive
  lending, digest of the decrypted password, connection tests on a fresh
  session (see S5 for its test).
- **N2 (fail loudly):** no new silent `catch` in send, order or save
  code. Two worth a log line when touched anyway:
  `_hasUnconfirmedForAccount` (`activity.dart:340–341`) treats an unreadable
  unconfirmed file as "none" (only the schedule; the send path still
  blocks), and `deleteStoredSession` (`session_store.dart:76`) hides a
  failed delete.
- **N3:** `checkBakalariLogin` keeps `client.login()` for test-double
  subclasses (`runtimeType != BakalariClient`); fine once S5's test covers
  the real path.
- **N4:** `rejectedCachedOutboxWithFailedReloadNeverReleasesUnconfirmed`
  only checks the `null` result; the "not released" part is covered by
  `failedReadSettlesNothing`. The name claims a little more than it tests.
- **N5:** `FakeBakalari` has no built-in "short cached outbox" option
  (§4.4); the test uses an inline route, the demo server has
  `--short-cached-outbox`. Accepted.
- **N6:** the network kind is re-read before each UI scheduler job
  (`scheduler_jobs.dart:111–114`); untested there, tested on the headless
  path. Optional test.
- **N7 (phone):** the 60-minute screen-off soak was stopped at ~14 min at
  the owner's word (recorded in STATUS); "an hourly check logs in once"
  was not shown on the phone (covered by
  `fiveAndTenMinTicksRenewWithoutExtraLoginsHourlyLogsInOnce`); battery
  ≈ 0.39 mAh/h (≈ 0.008 %/h), far below the 1 %/h limit of §9; the phone
  was on Wi-Fi, so the mobile-data cadence is shown by tests only.
- **N8 (still unverified, for the owner's real-account check Q3):** that
  the 3-field callback lists the whole school year on the real server;
  that a session renewal sends a new `Set-Cookie`; the real MB per check
  and per day; a new mark visible within one check. macOS and iOS
  builds as before.
- **N9 (deviations in STATUS, accepted):** the one-time default upgrade
  (owner Q1); the two pre-approved assertion changes
  (`http_session_test.dart` call count, `bakalari_data_test.dart`
  `dateFrom`, both still checking the same thing); three fixtures pinned
  to the old 60-minute interval or expecting the new 5-minute wake (same
  checks, new default); `StatusInputs.lastChecked`; `saveDataCache`
  dropping `part_updated` when only `last_updated` is written.
- **N10 (upgrade path, checked):** the first quick check on a pre-F6
  cache loads the marks page and the watched weeks once (no widget or
  hashes yet), then the next check is a full run (rule 5: no outbox
  stamp yet). As intended.
- **N11:** a pooled session evicted while lent can rewrite
  `bakalari_session.enc` with the old password digest at the end of its
  run; harmless, the next load deletes it on the digest mismatch.
- **N12:** the demo server now answers a Komens POST without the three
  form fields with the redirect reply (test tool only).
- **N13 (screens):** the agent captured Settings → Pravidla, Aktivita,
  Známky and Obědy; the reviewer captured Dnes, Rozvrh, Absence and
  Aktivita at 390 and 1280 px, cs and en, dark and light, with F6 stamps
  in the demo cache (`build/qa-evidence/F6/reviewer-R8/`, 32 PNGs). Each
  screen shows its own time, nothing clips. Only S1 looks wrong.
- **N14:** config keys: `config.example.json` and `canonicalDefaults`
  hold the same 77 keys; `globalConfigKeys` 22; the parity fixture got
  only the three new keys in the two `roundTripFiles` configs (its
  `check_interval_minutes: 60` kept, as the note says).
- **N15:** strings: the 19 app keys and core `status_checked` match §8.3
  word for word, in cs and en; tutorial texts updated in both languages.

---

## Each part caught by a test (reviewer undid it, one at a time, at `4098142`)

| Undone | Caught? |
|---|---|
| quick checks never auto-excuse (`refresh.dart` scope lock) | yes |
| completeness check of the 3-field read | yes |
| manual full refresh loads the Komens page | **no** (S4) |
| runner uses the next-due provider | yes |
| off-hours pause never becomes 0 | yes |
| rule 5 (outbox older than full) | yes |
| `quickOutbox` only while excuses wait | yes |
| exclusive lending of the pooled session | yes |
| login check never uses the pool | **no** (S5) |
| past weeks reloaded when a `Count` grows | yes |
| quick check advances a hash only for a loaded week | **no** (S6) |
| quick-check outbox stamp only after a good read | **no** (M1) |
| full-run outbox stamp only after a good read | **no** (M1) |
| quick check reads the outbox only with `quickOutbox` | yes |
| broken marks page retried at most hourly | yes |
| `/dashboard` counts only on the same host | yes |
| wrong password deletes `bakalari_session.enc` | **no** (S7) |
| one-time defaults re-checked under the lock | **no** (S8) |
| skipped `perm` uses the cached baseline | yes |
| empty direct absence reply falls back to the page | yes |
| 14-minute expiry of the saved session | yes |
| quick check never writes the timetable history | yes |
| `part_updated['full']` moves with `last_updated` | yes |
| app: scheduler passes the chosen scope | yes |
| app: 5-minute due tolerance | yes |
| app: runner gets the schedule provider | yes |
| app: headless due check uses the provider | yes |
| app: re-arm on a network change | yes |
| app: network kind read before each UI job | **no** (N6) |
| app: silent quick check adds no row | yes |
| app: `startRefresh` accepts `'quick'` | yes |
| app: unconfirmed submit forces a full run | **no** (M1) |
| app: waiting excuses make the quick check read the outbox | **no** (M1) |
| app: credential save evicts the saved session | **no** (S7) |

Parent runs: the new test files of commits 1–6 call code those commits
add and can't compile on their parents; they were judged by reading and
by the table above. `ec5e180`'s `cache_test.dart` on `48f45ba` fails with
an assertion (`Expected: contains '22.11.2026 10:28:00'`, `Actual:
'22.11.2026 10:20:00 · před 10 min'`) and passes on `ec5e180`.

---

## What the reviewer verified, and how

1. **Suites**, at `4098142` after `dart pub get --enforce-lockfile`: core
   `dart analyze` no issues, `dart test` **936 passed, 2 skipped**; app
   `flutter analyze` no issues, `flutter test` **839 passed, 1 skipped**.
   Both match STATUS. The review worktree stayed clean.
2. **Undo checks** (table above) and the `ec5e180` parent run, in one
   throwaway worktree in the reviewer's scratch space; a baseline run of
   the five F6 app test files there passed first.
3. **Code read** against the note: `refresh.dart` (whole diff),
   `automation.dart` (fetch plan, quick check, outbox sync, login check),
   `data.dart` (absence, outbox paging, cached form, completeness check,
   fetch order, baseline), `timetable.dart`, `http_session.dart` (login
   redirects, cookies), `session_store.dart`, `client.dart`,
   `refresh_schedule.dart`, `scheduler.dart`, `cache.dart`,
   `error_report.dart`, `accounts.dart`, `config.dart`,
   `status_notification.dart`; app `activity.dart`, `app_state.dart`,
   `startup.dart`, `background.dart`, `scheduler_jobs.dart`,
   `settings_view.dart`, the `*_live.dart` labels, `scaffold.dart`,
   `StrakalariChannel.java`, the manifest, `installer.iss`, the demo
   server and `FakeBakalari`.
4. **Safety rules:** `git diff --stat 617eb92..HEAD` on `excuse_history.dart`,
   `audit.dart`, `session_lock.dart`, `strava/`, `lunches/`,
   `bakalari/excuse.dart`, `controllers/excuses.dart` and
   `controllers/lunches.dart` is empty; `sendExcuse` is untouched; every
   quick check runs through `runRefresh` under the session lock
   (`startRefresh` / `_refreshBackgroundAccount`); auto-lunch in a quick
   check needs a Strava fetch in that check and respects
   `automation_paused` (tested); every app that borrows a pooled session
   closes it (`activity.dart:903`, `excuses.dart`, `lunches.dart`); no
   cookie value is logged; every new `catch (_)` read (N2).
5. **Test integrity:** `git log -p 617eb92..HEAD` on test files: no test
   removed, no `skip:`, no `anything`; the nine removed `expect` lines are
   the documented adaptations (N9) and the key counts in `accounts_test.dart`
   (19 → 22, 74 → 77); the `isNotNull` checks are each
   followed by a real value check; the two `try` blocks in new tests are
   `try/finally` for a lock and a client, not around assertions.
6. **Config, fixtures, strings:** a script compared `config.example.json`
   with `canonicalDefaults` (77 each) and counted `globalConfigKeys` (22);
   the `helpers.json` diff adds the three keys to the two
   `roundTripFiles` configs only; ARB diffs and core `i18n.dart` read
   against §8.3.
7. **Evidence:** all 32 agent screenshots listed and four opened
   (Pravidla 390 cs dark, 1280 en light; phone Dnes and Aktivita); the
   phone `demo_server.log` (full run at 12:44 with one login, then quick
   checks at 12:49, 12:54, 12:59, 13:04 with exactly `GET /Marks/Widget`,
   `POST /Timetable/substitutions/dates`, `GET
   …/GetAbsenceBySubjects` and no login or Komens), `dumpsys_alarm.txt`
   (next `ACTION_REFRESH_RUN` 13:09:34), `dumpsys_services.txt`
   (`isForeground=true foregroundId=7301`) and the PC
   `demo_server_verification.txt` (same-day full run without `perm`,
   subjects, past weeks or the Komens page).
8. **Screens:** 32 reviewer captures (N13), from a copy of
   `tools/parity/capture_screens.dart` limited to the four screens, with
   `part_updated` added to the demo caches.
9. **Hygiene:** no upstream; `git rev-list qa-roadmap..main` empty; all
   commits by DeNdlerX, plain messages, no `Co-Authored-By` /
   `Claude-Session` / "Generated with"; no config, cache, log, `htmls/`,
   key, APK or phone screenshot committed; the new test hosts are
   fixtures behind `FakeBakalari` (`bakaweb.school.cz`, `*.other.test`).
10. **Throwaway worktree:** plugin links removed one by one, then `git
    worktree remove --force`, which unregistered it but couldn't delete
    the folder (Windows long paths); the leftover folder has no links.
    All 338 packages in the pub cache still have their `pubspec.yaml`.
    The main checkout wasn't touched. The phone wasn't touched.

---

## Re-review 2026-11-22

Re-reviewed at `qa-roadmap` @ `c5a78e9` (base `main` @ `617eb92`; `main`
still has no commits the branch lacks; the branch has no upstream).
Commits since the R8 review (`da55839`), one per finding, blocker first:

- `a8efcfe` M1: tests for pending-excuse quick outbox sync, unconfirmed
  full-run trigger, and failed outbox stamps;
- `bacb0cc` S1: Aktivita hero and *Poslední běh* card show latest
  quick-check time (from memory or saved `part_updated['quick']`);
- `6051968` S2: require loaded weeks for substitution hashes and
  past-weeks snapshot on full runs;
- `8953b91` S3: Settings *Pozadí* notification preview uses the current
  network's interval;
- `f794b10` S4: test manual vs scheduled full refresh cached Komens form;
- `0d7df9e` S5: test `checkBakalariLogin` pool bypass with `Strakalari`'s
  own pooled client;
- `19827c2` S6: test quick check advancing week hash only for loaded
  weeks;
- `788b534` S7: tests deleting saved session on rejected login and on
  credential save;
- `0e61b49` S8: test `applyF6ScheduleDefaultsOnce` under-lock re-check on
  racing start;
- `c5a78e9` STATUS handover.

### Verdict: PASS

Every R8 finding (M1 and S1–S8) is fixed in the code and tests, and
every one of the 15 parent-commit and undo checks run by the reviewer
failed with a real assertion when its guard or fix was removed and
passed at `c5a78e9`. The rules that prevent double-sending excuses (re-reading
the sent-excuse list at least hourly while excuses wait, retrying a
failed outbox read as a full run, forcing a full run while an
unconfirmed submit exists) are now all locked down by tests on both
multi-account and single-account paths. Aktivita no longer claims "no
run yet" after a restart while 5-minute checks are running, a full run
where no timetable week loaded no longer stamps hashes or skips past
weeks, and Settings' background-notification preview matches the active
network's interval. Nothing else broke: both suites are green and grew
(core 936 → 942, app 839 → 843), with zero analyzer issues and no config
keys, parity fixtures, strings or safety invariants changed.

No open findings. No owner decision is needed.

### R8 findings, checked

- **M1 ✔ (`a8efcfe`).** `app/test/app_state_accounts_test.dart` adds
  `F6 scheduledRefreshJob passes pending excuses and unconfirmed submit to
  chooseScheduledScope (R8 M1)` covering both the multi-account path and
  `_scheduledSingleAccountRefresh` (accounts off): a 70-min-old outbox
  with a pending task triggers 1 `syncWebExcusesToHistory` call vs 0
  without a task; an `already_excused_lessons.unconfirmed.json` entry
  with a 40-min-old outbox triggers `'all'` vs `'quick'` without it.
  `packages/strakalari_core/test/f6_quick_refresh_test.dart` adds
  `failedQuickOutboxLeavesOutboxStampWindowAndDetailsUnchangedAndRetriesNextTick`
  and
  `failedFullRunOutboxMovesFullStampLeavesOutboxStampAndForcesNextScheduledFullRun`
  (500 on both POST and GET `/next/komens.aspx`). Every one of the six
  undo checks below fails with an assertion.
- **S1 ✔ (`bacb0cc`).** `AppState.lastQuickCheck` (`app_state.dart:556`)
  returns the newer of the in-memory timestamp and saved
  `partUpdatedTime(data, 'quick')` (null in `demoMode`), so it survives
  restarts. `ActivityView._hero` and `_stats` (`activity_view.dart:460–555`,
  `:650–666`) promote idle → `'ok'` with `activity_last_ok` and show the
  quick-check clock in *Poslední běh* (`kind: 'ok'`) whenever there are
  no run rows or `quickAt` is newer than the newest row, without hiding
  an active `'working'` or `'error'` hero. No new strings. Test fails on
  parent `bacb0cc~1` (`Expected: DateTime:<2026-11-20 10:10:00.000>`,
  `Actual: <null>`). All 8 screenshots in `build/qa-evidence/F6/S1/`
  (390/1280 px, cs/en, dark/light, captured after `bacb0cc`) opened and
  verified clean.
- **S2 ✔ (`6051968`).** `refresh.dart:888–891` and `:906–907` no longer
  treat an empty `app.timetableLoadedWeeks` set as "all weeks loaded":
  substitution hashes are saved only for loaded watched Mondays, and
  `absence_counts_at_past_fetch` / `past_weeks_fetched` only when every
  regular past Monday is in `app.timetableLoadedWeeks`. Test fails on
  parent `6051968~1` and passes at `6051968`.
- **S3 ✔ (`8953b91`).** `SettingsController.backgroundNotificationInterval`
  is wired in `settingsControllerFor` to
  `s.schoolHoursIntervalForCurrentNetwork` and read in
  `_BackgroundOverviewState._content()` (`settings_view.dart:619`). Test
  checks Wi-Fi 5 / mobile 10 on metered vs unmetered network, fails on
  parent `8953b91~1` (`Found 0 widgets with text "Kontroluje omluvenky a
  obědy každých 10..."`), passes at `8953b91`.
- **S4 ✔ (`f794b10`).** `manualFullRefreshAlwaysLoadsFullKomensPageWhileScheduledReusesCachedForm`
  verifies `scheduled: false` makes 1 `GET /next/komens.aspx?s=rok&l=o`
  and `scheduled: true` makes 0 `GET` / 1 `POST`. Fails when
  `nextUseCachedOutboxForm` is forced to `true`.
- **S5 ✔ (`0d7df9e`).** `BakalariClient.bakalariSession()` falls back to
  `BakalariSessionPool.instance.transportFactory?.call()` when
  `_transportOverride == null` (a test-only seam, null in production;
  `@visibleForTesting` removed on `transportFactory` to keep analyzer
  clean). `connectionTestNeverUsesPoolAndRejectsWrongPasswordWhilePooledIsLive`
  now uses `Strakalari`'s own pooled client (`useSessionPool: true`) and
  checks right password, edited wrong password, and fresh wrong-password
  `Strakalari` all post `/Login`. Fails when `checkBakalariLogin` calls
  `client.login()`.
- **S6 ✔ (`19827c2`).** `quickTickAdvancesWeekHashOnlyForLoadedWeekAndRetriesFailedWeekNextQuickTick`
  verifies a failed next-week load keeps the old hash and retries on the
  next quick tick. Fails when `automation.dart:1046` is replaced with
  `if (true)`.
- **S7 ✔ (`788b534`).** `session_store_test.dart` exercises the real
  `BakalariClient.login()` rejection path with an expired stored session
  on disk (leaving checkout intact so `onLoginRejected` is what deletes
  `bakalari_session.enc`) plus direct `onLoginRejected` on a live pooled
  session; `app_state_accounts_test.dart` verifies `AppState.save` of
  `bakalari_password` (same and changed), `bakalari_url` and
  `bakalari_username` each delete `bakalari_session.enc` and force a new
  `POST /Login`. Both fail when their respective delete/evict calls are
  removed.
- **S8 ✔ (`0e61b49`).** `rechecksUnderLockWhenAnotherStartWritesNewKeyWhileWaiting`
  holds `global.json.lock` in a helper isolate while
  `applyF6ScheduleDefaultsOnce` waits on the lock, writes new F6 keys
  before releasing, and verifies the call returns `false` and keeps the
  edit. Fails when the under-lock re-check is removed.

### Parent runs and undo checks (re-review, at `c5a78e9`)

| Check (one at a time, in throwaway worktree) | Result |
|---|---|
| Parent S1 (`bacb0cc~1`) with `activity_view_test.dart` from `bacb0cc` | fails with assertion |
| Parent S2 (`6051968~1`) with `f6_quick_refresh_test.dart` from `6051968` | fails with assertion |
| Parent S3 (`8953b91~1`) with `settings_sections_test.dart` from `8953b91` | fails with assertion |
| Undo M1a: multi-account `hasPendingExcuses` → `false` (`activity.dart:447`) | fails with assertion (`1` vs `0`) |
| Undo M1b: single-account `hasPendingExcuses` → `false` (`activity.dart:561`) | fails with assertion (`1` vs `0`) |
| Undo M1c: multi-account `hasUnconfirmed` → `false` (`activity.dart:448`) | fails with assertion (`1` vs `0`) |
| Undo M1d: single-account `hasUnconfirmed` → `false` (`activity.dart:562`) | fails with assertion (`1` vs `0`) |
| Undo M1e: quick-check outbox stamp `if (app.lastOutboxSyncOk)` → `if (true)` (`refresh.dart:690`) | fails with assertion |
| Undo M1f: full-run outbox stamp `if (app.lastOutboxSyncOk)` → `if (true)` (`refresh.dart:938`) | fails with assertion |
| Undo S4: `app.nextUseCachedOutboxForm = true` (`refresh.dart:929`) | fails with assertion |
| Undo S5: `checkBakalariLogin` calling `client.login()` (`automation.dart:2165`) | fails with assertion |
| Undo S6: quick hash advance guard → `if (true)` (`automation.dart:1046`) | fails with assertion |
| Undo S7a: remove `deleteStoredSession(dataDir)` in `onLoginRejected` (`session_store.dart:408`) | fails with assertion |
| Undo S7b: remove `BakalariSessionPool.instance.evict(...)` (`app_state.dart:1358`) | fails with assertion (`false` vs `true`) |
| Undo S8: remove under-lock F6 key re-check (`refresh_schedule.dart:403`) | fails with assertion |

### Notes (no action needed)

- **N16 (top bar pill after restart):** in the S1 screenshots, after a
  restart with only quick checks and no full-run rows yet, the Aktivita
  hero and *Poslední běh* card show *V pořádku / Healthy* and `13:25`,
  while the small top-bar dot still reads *Nečinné / Idle*
  (`scaffold.dart:456`, which checks `state.runs`). S1 scoped the fix to
  the Aktivita hero and card, so leaving `scaffold.dart` untouched is in
  scope.
- **N17 (unverified items, unchanged from R8 N7–N8):** full 60-minute
  off-charger Doze soak (stopped at ~14 min at the owner's word), macOS
  and iOS native builds, and the Q3 real-account measurement (whether the
  3-field Komens callback lists the whole school year on the real server,
  whether session renewal sends a new `Set-Cookie`, real MB/day, and a
  new mark visible within one 5-min check).

### What the reviewer verified, and how (re-review)

1. **Suites** at `c5a78e9` after `dart pub get --enforce-lockfile`: core
   `dart analyze` no issues, `dart test` **942 passed, 2 skipped** (+6
   over R8 baseline of 936); app `flutter analyze` no issues,
   `flutter test` **843 passed, 1 skipped** (+4 over R8 baseline of 839).
   Both match STATUS. The `qa-roadmap` worktree stayed clean.
2. **Parent runs and undo checks:** all 15 checks above run in one
   throwaway worktree in the reviewer's scratch space (after confirming
   baseline tests pass there at `c5a78e9`). All 15 failed with real
   assertions when undone/reverted.
3. **Code and safety rules:** every diff in `da55839..HEAD` read in full;
   no `catch` added; `refresh.dart` only tightened `timetableLoadedWeeks`
   checks (S2); `client.dart` / `session_store.dart` only wired the
   test-only `transportFactory` seam (null in production, S5); send path,
   excuse history, session lock, audit and `automation_paused` untouched.
4. **Test integrity:** `git diff da55839..HEAD` on test files deletes
   only the weak `useSessionPool: false` setup in `session_store_test.dart`
   replaced by S5's pooled-client test; no `skip:`, `anything`, or
   `try`/`catch` around assertions.
5. **Config, fixtures, strings, lockfile:** `git diff --stat
   da55839..HEAD` on `config.example.json`, `config.dart`,
   `test/parity/`, `app/lib/l10n/`, `packages/strakalari_core/lib/src/i18n.dart`
   and `pubspec.lock` is empty.
6. **Screens:** all 8 PNGs in `build/qa-evidence/F6/S1/` (captured at
   14:39, after the last UI commit `8953b91` at 14:20) opened and
   verified at 390 and 1280 px, cs and en, light and dark.
7. **Hygiene:** no upstream; `git rev-list qa-roadmap..main` empty; all
   10 commits by DeNdlerX with plain messages (no `Co-Authored-By`,
   `Claude-Session`, or `Generated with`); no personal data committed;
   only fake host (`school1.cz` behind fake transport) in new tests.
8. **Throwaway worktree & environment:** junctions removed before `git
   worktree remove --force`, worktree folder completely gone and
   unregistered from `git worktree list`; all 270 packages in
   `Pub/Cache/hosted/pub.dev` keep their `pubspec.yaml`. Main checkout
   and Pixel 7 Pro untouched.
