# R8a review: F6 design note (`design-F6.md`)

Reviewed 2026-11-22 at `qa-roadmap` @ `e85af63` (base `main` @ `617eb92`;
`main` has no commits the branch lacks, the branch has no upstream). The
note came in `32c8ed2` and was updated in `e85af63` with the owner's Q1–Q3
answers. Both commits touch only `design-F6.md` and `STATUS.md`. No F6
code, test, fixture, string or config key was changed.

PLAN.md has no F6 phase. The binding spec for F6 is
`proposal-F6-low-data.md`, the step 0 research
(`research-F6-bakalari-web.md`), the owner's D6 and Q1–Q3 answers in
STATUS and, once it passes, this note. PLAN §2 and CONTRIBUTING §5–6 apply
as for every phase.

## Verdict: FAIL

The note has the right shape. It keeps one pipeline (`runRefresh` with a
new `quick` scope), never lets a quick check send an excuse, keeps every
send and order path, the audit and `automation_paused` as they are, uses
only the Bakaláři web, and answers every D6 point: 5-minute checks from an
hour before the first lesson to 17:00 on mobile data, every 5 minutes day
and night on Wi-Fi, hourly at night on mobile data, absences within 5
minutes, the session cookie stored encrypted, and Settings controls with a
data estimate. Its data figures match the step 0 measurements (checked
below). The three new config keys and the one-time overwrite of old
schedule settings are what the owner asked for.

Three points must change before any code is written. In plain words:

- **M1:** to save 200 KB, the note reads the list of sent excuses with
  three remembered form fields instead of loading the page. Nobody has
  checked that this short form still lists the **whole school year**. If
  it quietly lists only the last month, the app would believe it read
  everything, and an excuse it once couldn't confirm could be sent a
  second time.
- **M2:** today the app reads the sent-excuse list every hour. With F6 it
  reads it only in the big checks, about every 6 hours. When you send an
  excuse on the Bakaláři website, or from the app on another device, the
  app keeps showing it as "to excuse" for up to 6 hours instead of 1, and
  one tap sends it twice. Excuses can't be taken back.
- **M3:** the new timing rules aren't connected to the code that actually
  starts the checks. Built as written, "pause at night" would check
  **every minute** all night, and every 5-minute check would be a full
  1 MB download, the very thing F6 is meant to stop.

Thirteen should-fix points (S1–S13) and thirteen notes follow. No owner
decision is needed for any of them.

---

## Must-fix

### M1 (§4.4): the short Komens read may cover one month, not the school year, and nothing would notice

- **Where:** `design-F6.md` l.123–144; `research-F6-bakalari-web.md` §6
  (the three-field callback was tried on `?l=o`, the one-month default
  folder: "same 10 messages"); `research-F2-komens-outbox.md` l.40–48 (the
  period stays bound to the loaded page, tested with the page's *full*
  form); `data.dart:344–416` (`fetchAllOutboxIds`), `:429–448`
  (`_outboxPeriodStart`); `automation.dart:1206–1208` (a successful read
  settles unconfirmed submits against `sentExcusesFrom`), `:1243–1245`
  ("it was NOT sent and may be sent again").
- **What is wrong:**
  - The app reads the year folder `?s=rok&l=o` (F2). The only test of the
    three-field callback used the one-month default folder, where falling
    back to the default looks exactly like success. Which of the 56 form
    fields carries the period is unknown. If it is one of the 53 the note
    drops, the reply is a normal, shorter message list: no error, the end
    markers and the cumulative-page checks of F2 all pass.
  - The app would then take the cached `period_start` (the start of the
    school year) as `sentExcusesFrom`. The excuse window and
    `resolveUnconfirmed` would treat the whole year as read. An
    `unconfirmed` submit older than the listed month would be judged "not
    in the outbox, may be sent again", and the next auto run sends it a
    second time.
  - PLAN §6 (F2): a history read that fails on any page counts as a failed
    read, no partial success. A read that is silently shorter than it
    claims must count as failed too.
- **What correct looks like:**
  1. Self-check on every read through the cached fields: every excuse id
     already known in `komens_outbox_details_v1` (keys `id|sortDate`) whose
     sort date lies inside the cached period must be in the reply (all
     pages). If one is missing: log it loudly, drop `knownOutboxForm`, and
     do the read again from the full page in the same run (the note's
     existing fallback). Only a read that passed this check, or a
     full-page read, may set `lastOutboxSyncOk`, `sentExcusesFrom` and
     settle unconfirmed submits.
  2. Say that the first read after a fresh install, a cleared cache or a
     new school year is always the full page, and keep the 7-day full-page
     reload (l.138) as the backstop.
  3. `FakeBakalari` and `tools/bakalari_demo_server.py` get a mode in which
     the three-field callback returns only the last 30 days. Tests: with an
     older known excuse in the cache, the cached read is rejected and the
     page is loaded; an older unconfirmed submit is not released by the
     rejected read.
  4. In §4.4, mark "three fields keep the year period" as *unverified* and
     add it to the owner's real-account measurement (Q3). It can also be
     checked read-only in the owner's browser like step 0. Until then the
     self-check in point 1 is what makes the short read safe.

### M2 (§1 l.18, §5.3 l.192, §7.4): manual excuses would rely on a sent-excuse list up to ~6 hours old

- **Where:** `automation.dart:1325–1400` (`sendExcuse` checks only the
  local history, `excuseCovered` and `unconfirmedBlocks`); the local
  history learns about excuses sent elsewhere only from an outbox read
  (`syncWebExcusesToHistory`, `automation.dart:1135–1224`), which runs
  only in Bakaláři runs of scope `all`/`bakalari` (`refresh.dart:560–578`).
  Today that is every hourly refresh; with the note, the first run of the
  day and then every 6 hours.
- **What is wrong:** in `confirm` mode (the default) the user sends
  excuses from Dnes and Absence. An excuse sent elsewhere (on the
  Bakaláři website, by a parent, or by a second install of the app on the
  PC or another phone, F4) stays "pending" on this device until its next
  outbox read: up to ~1 hour today, up to ~6 hours with F6. A tap on
  *Omluvit* in that window sends a second excuse. Auto mode stays safe
  (fresh outbox in the same run); manual sending loses most of its margin.
- **What correct looks like** (no change to the send path):
  - While the account has pending excuse tasks (the same list the screens
    show, `pendingExcuseTasksFor(cfg, cache)`, `app_state.dart:171`) or
    unconfirmed entries, a scheduled quick tick whose
    `part_updated['outbox']` is missing or at least 60 minutes old also
    runs `syncWebExcusesToHistory()` (the cached-field list, ~3 KB, plus
    the details of new ids only, guarded as in M1). The quick tick still
    never runs auto-excuse: the scope lock in `_autoPhases` stays.
    `part_updated['outbox']` is stamped only after a successful read. With
    nothing pending, the outbox stays in full runs only.
  - Tests: an excuse added to the fake outbox reaches the local history
    within 60 minutes of quick ticks while a task is pending; a quick tick
    that read the outbox still never calls `excusePending`, also in `auto`
    mode; no outbox read in quick ticks when nothing is pending.
  - Add the cost to §2 (~24 × 5 KB a day while something is pending) and
    correct l.192 and the §11 risk table.
  - Not recommended now: reading the outbox right before every manual send
    changes the send path (PROMPT.md: stop and ask the owner).

### M3 (§7.3–7.5, §8.2): the new schedule isn't wired into the code that runs it

- **Where:**
  - core `scheduler.dart:23–26` (`nextDue` clamps the interval to at least
    1), `:218–245` (`intervalProvider` → `math.max(1.0, value)`; the 5 s
    tick runs when `nextDue(lastRun, intervalMinutes)` is reached);
  - `app/lib/platform/startup.dart:194–196` (desktop and Android UI runner
    interval = `check_interval_minutes`), `:233` (hand-off), `:345–355`
    (`_intervalMinutes`, notification text), `:378–392` (`scheduleWake`);
  - `app/lib/platform/android/background.dart:344–372`, `:402–405`
    (headless due check and next wake from `nextDue`);
  - `app/lib/platform/scheduler_jobs.dart:94–96` (runner interval);
  - `app/lib/controllers/activity.dart:356`, `:484–489`
    (`_intervalFromConfig` for each account's due check), `:224–239`
    (`nextRunLabel`), `:408` and `:566` (the scheduler starts `'all'`),
    `:606–608` (`startRefresh` turns every scope except
    `all`/`bakalari`/`strava` into `'all'`);
  - `app/lib/features/settings/settings_view.dart:614` (status preview).
- **What is wrong:** the note defines `effectiveCheckIntervalMinutes`,
  `nextScheduledWake` and `chooseScheduledScope`, but its commit plan never
  touches `scheduler.dart`, and §8.2 names only `PhoneBackground.sync` and
  `nextRunLabel`. Built as written:
  - off-hours `0` ("pause") reaches the runner as 0 and becomes **1
    minute**: a check every minute all night, the opposite of the setting;
  - the runner and the headless wake keep using `nextDue`, so the clamp to
    the window start (l.305) and the tick 30 minutes before the alarm
    (l.308) never happen;
  - `startRefresh` turns `'quick'` into `'all'`, and the scheduler asks for
    `'all'` anyway: every 5-minute tick would be a full ~1 MB run with an
    outbox read and auto-excuse, about 300 MB a day;
  - the network kind comes from an async channel call, but
    `intervalProvider` is synchronous.
- **What correct looks like:**
  - One function decides when the next scheduled run is
    (`nextScheduledWake`), and every call site listed above uses it. The
    `PeriodicRunner` gets a next-due provider (a core change, listed in
    commit 5 with its tests), so 0 never reaches `nextDue` or the runner's
    interval.
  - Each account's due check uses that account's effective interval and
    window (see N11).
  - `scheduledRefreshJob` calls `chooseScheduledScope` per account and
    passes the scope and `scheduled: true` through `startRefresh` and
    `_refreshBackgroundAccount` to `runRefresh`; `startRefresh` accepts
    `'quick'`. Manual refresh, the tray's *Obnovit data* and the wizard keep
    `'all'`.
  - The network kind is read once per job run (and when the app resumes)
    and cached for the synchronous providers.
  - Tests: off-hours `0` → no run between the window end and the pre-alarm
    tick, on the desktop runner and the headless wake; last run 06:20,
    window starts 06:45 → next run 06:45; a scheduled tick shortly after a
    full run sends exactly the quick request list; manual and tray refresh
    stay full.

---

## Should-fix

### S1 (§4.3 l.120, §5.3 l.183–189): an absence entered for an older week waits a day, and the "count grew" rule never fires

- **What is wrong:**
  - l.120 says that in a scheduled full run `obtainAbsenceInfo()` runs
    before `fetchTimetableWeeks()`. Today it runs after: weeks → `perm` →
    feed → baseline → absence → grades → subjects (`data.dart:553–604`).
    Moving it is a change and needs saying and a test.
  - Even after the move, the full-run rule "load the past weeks when a
    subject's `Count` grew since the cached `absence_details`" almost
    never fires: the quick ticks every 5 minutes see the growth first and
    save the new `absence_details` (l.183). They load this week, and last
    week only when this week showed nothing new (l.189). An absence entered
    for two to four weeks ago is then loaded, notified and excusable only
    in the next day's first run. D6 asks for absences within 5 minutes.
  - `_recordHistoryWeeks` (`refresh.dart:433–454`) rewrites the whole
    `timetable_history` map on every Bakaláři run, including
    `semester_reconciled: today`. The new `past_weeks_fetched` would be
    dropped by it, and a quick tick that reused this bookkeeping would mark
    F2's daily semester check as done without doing it.
- **What correct looks like:**
  - A marker that survives the quick ticks: e.g. `absence_counts_at_past_fetch`
    in the cache, the per-subject `Count`s as of the last run that loaded
    all regular past weeks. A scheduled full run loads the past weeks
    whenever a current `Count` is above that snapshot. The quick tick that
    sees the growth loads this week (and last week, as written) but leaves
    the snapshot alone.
  - State the `fetchData` reorder in §4.3.
  - Quick ticks never write `timetable_history`; full runs keep
    `past_weeks_fetched` in the map `_recordHistoryWeeks` writes.
  - Tests: an absence two weeks back is in the next full run's
    `timetableData` and notified; quick ticks leave `timetable_history`
    unchanged.

### S2 (§7.4): a failed full run is retried as a quick tick

- **Where:** `refresh.dart:304–319` (`last_updated` moves when only auto
  phases failed), `:560–566` (a failed outbox read is only a log line,
  not a result error), `:670–677` (`auto_excuse_outbox_unknown`),
  `scheduler.dart:178–186` (a failed job comes back in ~5 minutes),
  `activity.dart:978–990` (`scheduled_refresh_failed`).
- **What is wrong:** today the retry 5 minutes after a failed auto-excuse
  or an unread outbox is a full run, so the excuse goes out a few minutes
  later. With §7.4 the retry is a quick tick (the last full run is minutes
  old), which never reads the outbox and never excuses. The excuse waits
  for the next 6-hour full run. Rule 4 covers only `unconfirmed`.
- **What correct looks like:** `chooseScheduledScope` also returns `'all'`
  when the last full run didn't finish its job: it had an `auto_excuse`
  error, its outbox read failed (`part_updated['outbox']` older than
  `part_updated['full']`), or `scheduled_refresh_failed` was set by a full
  run (store the failed scope next to the stamp). Define when
  `part_updated['full']` is stamped (exactly when `last_updated` is) and
  `part_updated['outbox']` (after a read that passed M1). A test for each
  case.

### S3 (§4.3 l.116, §5.3 l.175–177): marks signal order and a broken marks page

- **What is wrong:**
  - Full runs prime the widget "right after `getGrades()`". A mark given
    between the two requests is in the widget but not in the grades. The
    next quick tick sees an unchanged widget, and the mark stays hidden
    until the next full run (up to 6 hours).
  - When the widget works but `prubzna.aspx` fails, l.175 retries it on the
    next tick: 187 KB every 5 minutes (~22 MB a school day) for as long as
    the marks page is broken.
- **What correct looks like:** fetch the widget **before** `prubzna.aspx`
  in full runs (the quick path already has this order). After a failed
  `getGrades()`, retry at most hourly until it works, logging once per
  failure streak, like the widget fallback. Tests for both.

### S4 (§5.2–5.3): full runs must store the week hashes, from a feed read before the weeks

- **What is wrong:** only the quick path writes
  `substitutions_week_hashes_v1`. If full runs don't, the first quick tick
  after each full run finds stale hashes and loads both weeks again
  (~2 × 70 KB × 4 full runs ≈ 0.5 MB a day, not in §2). And `fetchData`
  reads the feed after the weeks (`data.dart:555`, then `:573`): a hash
  saved from that feed can include a change the saved week doesn't have.
  It would stay hidden until the hourly safety net (this week) or the next
  full run (next week).
- **What correct looks like:** full runs store the hashes for the weeks
  they loaded, computed from a feed read **before** those weeks (move
  `fetchSubstitutions` ahead of `fetchTimetableWeeks`; the feed is applied
  after both anyway, in `updateStableBaseline`). Test: after a full run, a
  quick tick with an unchanged feed loads no week.

### S5 (§4.3 l.113, §5.3 l.186–188): skipping `perm` leaves the run without a stable baseline

- **What is wrong:** `updateStableBaseline()` builds the baseline only
  from this run's `stableTimetableData` (`data.dart:633–651`). When `perm`
  is skipped on purpose, the baseline is empty: `stableComplete = false`,
  no `backfillStableFacts` (cancelled lessons lose their subject and
  teacher), changes only from Bakaláři's own flags. Days saved by a quick
  or scheduled run would differ from those of a full run, and so would the
  change detection. l.113 says the cached baseline is "seeded", but not
  that `updateStableBaseline` must use it.
- **What correct looks like:** when `perm` was skipped on purpose and the
  cached `stable_baseline_source` is `scraped`, `updateStableBaseline` uses
  `baselineFromDict(cache['stable_baseline'])` (`schedule.dart:480`) with
  `stableComplete = true`. A `perm` fetch that *failed* keeps today's "no
  baseline this run". Test: for the same fake server data, the days saved
  by a quick tick equal those saved by a full run.

### S6 (§4.4 l.131, l.137–139): the Komens cache check can never pass, and l.139 is unfinished

- **What is wrong:**
  - The check `period_start >= schoolYearStart(today)` never passes: the
    year folder's label starts on 20.8.2026 (`research-F2-komens-outbox.md`
    l.30), while `schoolYearTerms(today)[0].$2` is 1.9. The cached path
    would never run. The example at l.131 shows `2026-09-01`, which the
    page doesn't give.
  - l.139 still holds a thought in progress ("— wait: or `true` only if
    older than 7 days …").
- **What correct looks like:** store `period_start` and `period_end` from
  the label and use the cache only when `period_start <= today <=
  period_end`. Replace l.139 with one rule. Recommended: a manual *Obnovit
  data* always loads the page (the user asked to check everything; it
  happens a few times a day at most).

### S7 (§4.2 l.105): the absence date range

- **What is wrong:**
  - `schoolYearTerms` switches to the new school year in **August**
    (`today.month >= 8`, `planner.dart:614`), not in September as l.105
    says. In August `dateFrom` (1 September of this year) is after
    `dateTo`.
  - A direct reply that succeeds but lists no subjects while the cache had
    some would wipe the absence numbers (`absenceError == ''`).
  - When the direct call keeps failing, every quick tick falls back to the
    58 KB page.
- **What correct looks like:** write the rule out: `dateFrom` = 1 September
  of `today.year` when `today.month >= 9`, else of `today.year - 1`;
  `dateTo` = today; tests on 31 August and 1 September. Fall back to the
  page also when the direct reply has no subjects but the cache had some.
  After a failed direct call, quick ticks use the page at most hourly
  (full runs as written).

### S8 (§4.1 l.95–100): the login check gets looser than today

- **What is wrong:** today `GET /login` counts as "already logged in" only
  when it ended on `/dashboard`; anything else is "not a Bakaláři address"
  (`http_session.dart:770–781`). The note accepts any redirect away from
  `/login` on the GET, and any `302` that doesn't point to `/login` after
  the POST, as success. A wrong address (a school homepage that
  redirects), a maintenance page or another host would count as logged in.
  The wizard's login test would say OK and the error would come later,
  unclear.
- **What correct looks like:**
  - GET: `followRedirects: false`; follow only redirects whose path is
    `/login` (or http → https on the same host). A redirect to `/dashboard`
    on the same host means logged in, without loading it. Anything else
    stays today's `bak_no_login_page`.
  - POST: a `302`/`303` to `/dashboard` (or to the `returnUrl` the form
    sent) on the same host is success without loading it; to `/login`,
    follow once and reject as written; anything else, follow it and apply
    today's `isLoginPage` check.
  - Tests: a redirect to another host or to `/` is not a login.

### S9 (§6.1): the shared session must be lent to one user at a time, and login tests must never use it

- **What is wrong:** the pool hands "the" session for (folder, address,
  user) to whoever asks. The connection test (`_testWork`,
  `activity.dart:1222–1272`) runs **without** the session lock and with
  the values typed in Settings or the wizard (`configData: overrides`),
  and `BakalariClient.login()` returns at once when its session is already
  logged in (`client.dart:258–262`). So a test could be answered by a live
  pooled session instead of checking what was typed, and it could log in
  again on the session a locked excuse send is using at that moment. l.233
  leaves open whether the digest is taken of the ciphertext or the
  password.
- **What correct looks like:** (a) a pooled session is lent to one
  `Strakalari` at a time; asking while it's lent gives a fresh session
  outside the pool; (b) connection tests and the wizard's login checks
  never use the pool or `bakalari_session.enc` and always post the login
  form with the typed values; (c) `passwordDigest` is SHA-256 of the
  decrypted password, kept only in memory and inside the encrypted file,
  so a re-encrypted equal password doesn't throw the session away. Tests
  for (a)–(c).

### S10 (§9, §10 commit 4): the test servers never end a session

- **What is wrong:** `tools/bakalari_demo_server.py` keeps every session
  forever (`login`, `logged_in`, l.528–641), and so does `FakeBakalari`.
  The Pixel check "0 extra `/Login` calls" (§9 step 3) would then prove
  that the cookie is reused, but nothing about the 15-minute sliding
  session that step 3b is built around.
- **What correct looks like:** an option (off for the existing tests) on
  both: sessions last 15 minutes, a request in the second half renews
  them with a fresh `Set-Cookie`, an expired session answers
  `302 → /login?ReturnUrl=…`. Tests: 5- and 10-minute ticks never log in
  again; an hourly tick logs in once; the renewed cookie is the one the
  next headless run loads. Use the option for the Pixel run.

### S11 (§5.4): more places show the "updated" time

- **What is wrong:** besides the screens in l.214–220, `last_updated` is
  read by the phone's ongoing notification and the widget
  (`backgroundStatusInputs`, `app_state.dart:262–280`), the desktop status
  tooltip (`scaffold.dart:480`, `updatedLabel`) and Settings → Diagnostika
  (`settings_live.dart:32`). With quick ticks the phone notification would
  say "updated 6 hours ago" while it checks every 5 minutes.
- **What correct looks like:** list each of them in §5.4 with the stamp it
  shows (the status notification and tooltip: `lastCheckedTime`).

### S12 (§3.3): the one-time switch to the new defaults

- **What is wrong:**
  - A fresh install already has `global.json` = `{}` before the helper
    runs (`ensureMultiAccountLayout` writes it, `accounts.dart:764–767`).
    So l.84's "file doesn't exist" case never happens, and the helper
    writes the four defaults into every fresh install. Harmless, but the
    case list and its tests are wrong.
  - The UI and the headless start both run it (`startup.dart:80`,
    `background.dart:133`), possibly at the same time.
- **What correct looks like:** re-check the three keys after taking the
  ConfigManager save lock; if the lock is busy, skip this start (it runs
  again at the next one) and say so. Log the old values in the one info
  line, so the overwrite isn't silent (CONTRIBUTING §6). Tests: fresh
  install, an F4 layout from before F6, degraded mode with the root
  `config.json`, two starts at once, a later change by the user kept.

### S13 (§5.4, §9 step 4): Aktivita would show only the last ~100 minutes

- **What is wrong:** the run list keeps 20 entries (`activity.dart:1027`,
  `:1192`) and the log 300 lines (`:59`, `:998`). At one run every 5
  minutes the list covers about 100 minutes, and the last full run, the
  one with the excuses and orders, scrolls out within two hours. Every
  tick also adds its log lines.
- **What correct looks like:** say in the note how a quick tick shows in
  Aktivita. Recommended: a quick tick that worked and found nothing new
  updates one "Kontrola HH:MM" line instead of adding a row; a quick tick
  that failed or brought news, and every full run, adds a row. The audit
  (`automation_history.jsonl`) doesn't change.

---

## Notes (no action needed unless stated)

- **N1 (full runs a day, §2, §8.1 l.347):** "first run of the day + every 6
  hours" gives about four full runs a day (just after midnight, then
  ~06:00, ~12:00, ~18:00), not three: about +0.34 MB a day (5-minute mobile
  ≈ 5.7 MB, 10-minute ≈ 4.7 MB). Correct §2 and the Settings text
  "(~3×/day)", or fix the times.
- **N2 (iOS):** l.276 treats iOS as always unmetered, and
  `Strings.isMobile` (l.348) is also true on iOS. iOS refreshes only in the
  foreground (`startup.dart:246–251`). Keep the Android texts (Doze,
  mobile-data interval) Android-only, and don't let the estimate say 0 MB
  of mobile data on an iPhone.
- **N3 (3b expiry, l.257):** the age is counted from the last request, but
  the server's 15 minutes run from the last renewal. A wrong "still alive"
  costs one wasted request and a login. Storing the time of the last
  `Set-Cookie` instead would be exact.
- **N4 (Wi-Fi day and night):** about 920 small requests a day per account
  to the school's server, more than today's ~670 (far fewer bytes). The
  owner chose it with this number in front of them (Q2).
- **N5 (window end):** `max(17:00, end of last lesson)` stretches the
  owner's "to 5pm" only on days that end later: accepted.
- **N6 (test changes):** the two adapted assertions
  (`http_session_test.dart:202`, call numbers without `/dashboard`;
  `bakalari_data_test.dart:791`, computed `dateFrom` plus no page call)
  keep checking the same thing and are accepted. Test fakes that implement
  `RefreshApp` will need the new members; that is fine as long as no
  assertion changes. Byte budgets measured on `FakeBakalari`'s made-up
  sizes prove little; the exact request lists are what count.
- **N7 (strings):** list the new string keys with their cs and en text in
  §8, as the F1c and F4 notes did, so the short wording the owner wants
  (D1) is checked before code.
- **N8 (battery):** say what happens if the Pixel measurement shows a high
  drain, e.g. the Wi-Fi day-and-night default switched off. That would be
  the owner's call then.
- **N9 (plan):** PLAN has no F6 phase or checkpoint; this review is
  `phase-8-design.md`, the code review will be `phase-8.md`, following
  STATUS's phase number.
- **N10 (CONTRIBUTING §6):** the one-time overwrite of the old schedule
  settings breaks the "no silent migration" rule on the owner's explicit
  word (Q1). Accepted, with S12.
- **N11 (several accounts):** the runner wakes on the union of the
  accounts' windows (l.294); each account's due check uses its own window.
  Say so in §7.
- **N12 (marks fallback):** l.177 limits the fallback for a broken widget
  to hourly after the first failure, unlike the proposal's "load the marks
  page this tick". Accepted for the bandwidth, because the first failure
  still loads it at once.
- **N13 (checked, correct):** 74 canonical keys and 19 shared keys today
  (script below), so 77 and 22 after F6; the parity fixture plan (the
  three new keys added to the two `roundTripFiles` config files,
  `check_interval_minutes: 60` kept because the fixture is its own input);
  `findNews` compares only parts present in the run's payload, so a quick
  tick gives no false news (`news.dart:33–64`, `:102–106`, `:189–196`);
  `saveDataCache` merges and moves `last_updated` only when given
  (`cache.dart:149–178`); `BakalariClient.login()` skips the login when the
  session is logged in, so a stored cookie means no login request
  (`client.dart:258–262`); the excuse post (`sendOnce`) is untouched; the
  helpers the note names exist (`baselineFromDict`, `nextWakeupAlarm`,
  `firstLesson`, `periodSlots`, `lessonsFor`, `indexDays`, `clockOf`,
  `isCancelledLesson`, `effectiveCalendar(..., clip: false).dates`,
  `resolveLunchCutoff`, `allAccountSensitiveValues`, `redactText`,
  `AccountManager.forgetAllKeys`); the update check asks GitHub at most once
  a day, so 5-minute wakes don't multiply it (`scheduler_jobs.dart:111–117`);
  manual sends and orders already hold the session lock
  (`excuses.dart:498`, `lunches.dart:235`); `ACCESS_NETWORK_STATE` is not
  yet in the manifest; the owner's D6 and Q1–Q3 answers are recorded in
  STATUS and match §2, §3 and §12.

---

## What the reviewer verified, and how

1. `git log 617eb92..HEAD` and `git diff --stat 617eb92..HEAD`: two
   commits, `design-F6.md` and `STATUS.md` only; no test file changed
   (`git log -p` on tests is empty). `git rev-list qa-roadmap..main` is
   empty; the branch has no upstream; both commit messages are plain (no
   `Co-Authored-By`, `Claude-Session` or "Generated with"); no personal data
   (the only address in the note is the school's, already in the preset).
2. Suites, run by the reviewer at `e85af63` after
   `dart pub get --enforce-lockfile`: core `dart analyze` no issues,
   `dart test` **881 passed, 2 skipped**; app `flutter analyze` no issues,
   `flutter test` **829 passed, 1 skipped**. Same counts as at R7.
3. Config keys: a script compared `config.example.json` with
   `canonicalDefaults` in `config.dart` (74 each, the same set) and counted
   `globalConfigKeys` in `accounts.dart` (19); the parity fixture holds
   `check_interval_minutes: 60` in its two config snapshots, which are both
   input and expected output of `roundTripFiles`.
4. The note's data figures recomputed from the step 0 sizes: 120 × 18 KB +
   14 × 26 KB + 2.9 MB ≈ 5.4 MB (5-minute mobile), 60 × 18 KB + 0.36 MB +
   2.9 MB ≈ 4.3 MB (10-minute), 288 × 18 KB + 2.9 MB ≈ 8.1 MB (Wi-Fi day and
   night), 288 × 3 + ~60 ≈ 920 requests; the full-run count in N1.
5. Every code claim the findings rest on, read in the code: the refresh
   pipeline and its stamps (`refresh.dart:248–327`, `:433–454`,
   `:508–615`, `:645–715`), the fetch order and the outbox read
   (`data.dart:91–160`, `:180–448`, `:529–706`), the excuse send and the
   outbox sync (`automation.dart:1135–1251`, `:1325–1400`, `:1480–1520`,
   `generateExcuses` `:1586–1789`), the login (`http_session.dart:527–860`,
   `client.dart:226–275`), the cache (`cache.dart:145–280`), the scheduler
   and every call site in M3, the run list and log caps
   (`activity.dart:55–60`, `:1002–1030`, `:1174–1200`), the connection
   test (`activity.dart:1222–1290`), the status inputs
   (`app_state.dart:255–280`), the F4 move's `global.json` writes
   (`accounts.dart:713–930`), the school-year helpers (`planner.dart:612`,
   `excuse_history.dart:101–126`), the uninstaller (`installer.iss:199–239`),
   the Android manifest and alarms (`RefreshReceiver.java`,
   `StrakalariChannel.java:462`), `FakeBakalari` and the demo server's login.
6. No throwaway worktree was needed (no code to test against a parent), so
   the shared pub cache wasn't touched. The main checkout wasn't touched.

---

## Re-review 2026-11-22

At the owner's word ("Can you fix the plan yourself?", recorded in STATUS
*Owner decisions*), the reviewer fixed the note itself, as with the F4
note at R6a: `73d3aa2` changes only `design-F6.md` (and adds the STATUS
owner line). No code. Each fixed rule in the note carries its finding's
tag, e.g. *(R8a M1)*.

### Verdict: PASS

Every must-fix and should-fix finding is fixed in the note, checked
below, and so are the notes that asked for a change (N1, N2, N3, N7, N8,
N11). Because the same reviewer wrote the fixes and checked them, this
check is less independent than usual: at R8 the code review must look
hardest at the parts written here: §4.4 (completeness check), §5.3 1(e)
and §7.5 (outbox reads while excuses are pending, scope rules), §7.3–7.4
(the runner's next-due provider and every call site), §4.3 (fetch order,
past-week snapshot, cached baseline) and §6.1 (exclusive lending).

### Findings, checked

- **M1:** §4.4 accepts a read through the 3 cached fields only when every
  excuse already known in `komens_outbox_details_v1` inside the period is
  in the reply; otherwise the same run reloads the full page. Only a
  complete or full-page read sets `lastOutboxSyncOk`, `sentExcusesFrom`
  or settles unconfirmed submits. First read, manual refresh and the
  7-day reload always use the page. "The 3 fields keep the year period"
  is marked unverified and on the Q3 list (§12). The test servers get the
  one-month failure mode with its tests.
- **M2:** while excuses are pending (`pendingExcuseTasksFor`), a quick
  tick also reads the outbox when it is 60 minutes old or more (§5.3
  1(e), §7.5 `quickOutbox`), so an excuse sent elsewhere is known within
  an hour, as today. Quick ticks still never send (scope lock, also with
  `quickOutbox`). Cost in §2 (≤ 0.12 MB a day), risk row in §11, tests in
  §7.5.
- **M3:** §7.3 keeps `0` away from `nextDue` and the runner's interval;
  §7.4 adds `nextDueProvider` / `nextDueAt` / `_retryAt` to the core
  `PeriodicRunner` (commit 1, runners without a provider unchanged),
  lists every call site, makes `scheduledRefreshJob` pick the scope per
  account and `startRefresh` accept `'quick'`; §7.1 caches the network
  kind for the synchronous providers. Tests for the pause on the desktop
  runner and the headless wake, the window-start clamp, the quick request
  list, and manual/tray staying full.
- **S1:** §4.3 states the new fetch order (absence and feed before the
  weeks) and replaces the "count grew" rule with the
  `absence_counts_at_past_fetch` snapshot; `_recordHistoryWeeks` keeps
  `past_weeks_fetched`; quick ticks never write `timetable_history` or the
  snapshot. §4.3 also says why fewer weeks never change an excuse (chains
  break at weekends, the delay cutoff moves only at midnight).
- **S2:** §7.5 rule 5 (outbox read failed in the last full run, or
  `scheduled_refresh_failed_scope == 'all'`), with the Strava-only case;
  §5.4 defines when `full` and `outbox` are stamped (same `started` time).
- **S3:** widget before `prubzna.aspx` in every run (§4.3, §5.1);
  `grades_failed_at` limits a broken marks page to hourly retries (§5.3).
- **S4:** full runs store the week hashes from a feed read before the
  weeks (§4.3, §5.2); §2 no longer needs the extra week loads.
- **S5:** a run that skipped `perm` on purpose uses
  `baselineFromDict(cached)` with `stableComplete = true`, never writes it
  back; a failed `perm` keeps today's behaviour; test that the saved days
  equal a full run's.
- **S6:** cache valid only with `period_start <= today <= period_end`
  from the label; manual refresh always loads the page; the unfinished
  sentence is gone.
- **S7:** the `dateFrom` rule is written out (September, not August),
  an empty reply with a non-empty cache falls back to the page, quick
  ticks use the page at most hourly after a failure; tests on 31 August
  and 1 September.
- **S8:** §4.1 keeps today's rules (only `/dashboard` on the same host
  counts as logged in; anything else is `bak_no_login_page` or today's
  `isLoginPage` check) and only stops downloading the dashboard.
- **S9:** §6.1: exclusive lending, connection tests and wizard login
  checks never use the pool or the stored cookie, `passwordDigest` of the
  decrypted password.
- **S10:** §6.3: opt-in 15-minute sliding sessions in the demo server
  (`--session-minutes 15`) and `FakeBakalari`, used for the Pixel run.
- **S11:** §5.4 adds the status notification and widget inputs
  (`status_checked`), the desktop tooltip and Settings → Diagnostika.
- **S12:** §3.3 handles the fresh install's `{}`, re-checks under the
  save lock, postpones when busy, logs the old value; five test cases.
- **S13:** §5.5: a silent quick tick adds no row but updates one
  quick-check line; failed or eventful ticks and full runs add rows;
  `'quick'` is not a manual refresh chip; §5.3 cuts a silent tick's log to
  one line and keeps the per-subject absence lines to full runs.
- **N1:** §2 recomputed with 4 full runs a day: ~5.8 MB a school day at
  5 minutes on mobile data, ~4.7 MB at 10, ~8.5 MB on Wi-Fi day and night;
  ~85 / ~60 MB a typical month on mobile data; the Settings text says
  "about 4×". **N2:** §8.1 uses the Android check, iOS shows only the
  interval. **N3:** §6.2 counts from the last renewal (`renewed_at`).
  **N7:** §8.3 lists 20 string keys with cs and en text. **N8:** §9 step 6
  asks the owner above 1 % battery per hour. **N11:** §7.2.

### What the reviewer verified, and how (re-review)

1. `git diff 6a7d457..73d3aa2 --stat`: only `design-F6.md` and one STATUS
   line.
2. A search of the note for the wording the findings replaced ("— wait",
   `>= schoolYearStart(today)`, "today.month < 9", "~3×/day", "non-login
   path", `lastActivityAt`, "ciphertext/plaintext", "primed right after",
   the "does not exist: no-op" case, the claim that the absence read
   already runs before the weeks): none left. Every finding M1–M3,
   S1–S13 and the notes above has its tag in the note.
3. A script over §8.3: 20 new string keys, all unique, none already in
   `app_cs.arb` / `app_en.arb`, `status_checked` not yet in core
   `i18n.dart`.
4. The code facts the fixes rely on, read again: the runner's `tick`,
   `pollInterval` and failure retry (`scheduler.dart:23–26`, `:146–200`,
   `:212–245`); `registerJobs` (`scheduler_jobs.dart:79–119`); the scope
   chips come from `_scopes` (`activity_view.dart:241–245`, `:575`);
   `_markScheduledRefreshFailed` and its callers (`activity.dart:920–993`);
   `pendingExcuseTasksFor` (`app_state.dart:171`); the config save lock
   (`config.dart:799–823`, `:850–935`); no existing test depends on the
   order of requests inside `fetchData` (grep of the core tests).
5. Suites not re-run: no code changed since the R8a run (core 881 passed
   / 2 skipped, app 829 passed / 1 skipped).
