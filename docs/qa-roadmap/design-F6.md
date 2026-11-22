# F6 design note: Low-data tiered refresh (towards every 5 minutes)

Status: **design note only, no F6 code written yet.** Written 2026-11-22 against `qa-roadmap` / `main` @ `617eb92` (after R7 passed and merged). Reviewed at `⛔ R8a` (FAIL, [`reviews/phase-8-design.md`](reviews/phase-8-design.md)); the findings M1–M3 and S1–S13 were then fixed in this note by the reviewer at the owner's word ("Can you fix the plan yourself?", 2026-11-22). Each fixed rule is tagged with its finding, e.g. *(R8a M1)*.

Sources: [`proposal-F6-low-data.md`](proposal-F6-low-data.md), [`research-F6-bakalari-web.md`](research-F6-bakalari-web.md) (Step 0 real-GEKOM web measurements), [`research-F2-komens-outbox.md`](research-F2-komens-outbox.md), owner's D6 and Q1–Q3 answers recorded word for word in [`STATUS.md`](STATUS.md) (2026-11-22), [`PLAN.md`](PLAN.md) §2 (Ground rules), and [`CONTRIBUTING.md`](../../CONTRIBUTING.md) §5–6. PLAN has no F6 phase: these sources and this note are the binding spec.

---

## 1. Summary & Goals

Cut routine Bakaláři bandwidth so Strakaláři can check for **new marks, new absences, and timetable changes every 5–10 minutes** while using **less data per school day on mobile data than today's hourly ~1 MB full refresh (~25 MB/day)**:

- **Step 1 — Free wins (zero freshness loss):** stop following the login `302` to the 49 KB `/dashboard`, compute the absence date range locally instead of loading the 58 KB `/Absence/Continuous` page (with page fallback), fetch the permanent timetable (`perm`, 85 KB) and subject directory (4 KB) once per day, fetch past weeks (`-1 … -go_back_weeks`) once per day plus whenever an absence count grew past the last past-week load, and post the Komens outbox callback with 3 cached hidden fields instead of loading the 207 KB `/next/komens.aspx?s=rok&l=o` page every run — **only when the reply passes a completeness check against the excuses already known** (R8a M1), with automatic full-page fallback. *(Komens detail caching is already done in F2 via `komens_outbox_details_v1`.)*
- **Step 2 & Step 5 — Tiered `runRefresh` pipeline:** add `scope: 'quick'` inside the single `runRefresh` pipeline. Quick ticks make only 3 tiny requests (~6–10 KB payload, ~18 KB total wire with headers + new TLS, or ~11 KB on a kept-alive connection):
  1. `GET /Marks/Widget` (2 KB) → loads `GET /next/prubzna.aspx` (187 KB) in the same tick **only** when the 5 newest marks changed (or on parse failure, logged loudly).
  2. `POST /Timetable/substitutions/dates` (3–5 KB) → loads `POST /Timetable/GetContentData` (50–85 KB) **only** for week(s) whose feed entries changed, plus an hourly daytime safety net for this week (to catch short-notice whole free days).
  3. `GET /Absence/Continuous/GetAbsenceBySubjects` (1.2–3 KB) → updates absence numbers immediately (**within 5 minutes**, D6 A3) and fetches this week's `GetContentData` (and last week's, if this week shows nothing new) when any subject's missed-lesson `Count` grew.
  4. **While excuses are waiting to be sent** (the same pending list the screens show), at most every 60 minutes also the Komens outbox list (~3–5 KB), so an excuse sent elsewhere stops showing as "to excuse" within an hour, as today (R8a M2). Quick ticks still **never** send.
  - Full runs (`scope: 'all'`) run on cold start, first run of the day, every 6 hours (**~4×/day**), when an unconfirmed excuse needs settlement, when the last full run did not finish its job (R8a S2), and on every manual *Obnovit data*. **Auto-excuse runs ONLY in full runs after a fresh, complete Komens outbox read in the same run** — never in a quick tick.
- **Step 3 — Session reuse (3a in-memory + 3b encrypted cookie file, D6 A5):** keep live `BakalariSession` + `HttpClient` (`idleTimeout: 6 min`) in a per-account in-memory pool (desktop & live Android UI isolate), lent to **one user at a time** (R8a S9), and persist encrypted session cookies to `<accountDir>/bakalari_session.enc` using the account's existing Fernet key so Android headless wakes reuse the 15-minute sliding session without re-logging in on every 5–10 min tick.
- **Dynamic network-aware schedule & Settings data predictor (D6 A2, A4, A6 + Q1–Q2):**
  - **On Wi-Fi / unmetered** (and desktop): **5 min 24/7** by default (`check_interval_minutes: 5`, `refresh_wifi_always_fast: true`), configurable.
  - **On mobile data (Android metered):** **5 min** by default (`check_interval_mobile_minutes: 5`, configurable to 5, 10, 15, …) during active school hours (**1 hour before first lesson → 17:00**, or end of last lesson if later), and **60 min** hourly overnight & on days off by default (`check_interval_off_hours_minutes: 60`; `0` = pause off-hours with one quick tick 30 min before the Wake-up alarm).
  - **One schedule function drives every timer** (the desktop/UI runner, the Android headless wake, the "next check" labels and the notification text), so the pause and the window start actually take effect (R8a M3).
  - **One-time upgrade to the new defaults (owner Q1, 2026-11-22):** on first launch after updating from a pre-F6 install (when none of the 3 new F6 schedule keys exist in `global.json` / `config.json` yet), `applyF6ScheduleDefaultsOnce` overwrites the schedule keys once to the new defaults (`5` / `5` / `60` / `true`) and logs the old values; after that, every user change is preserved forever.
  - **Settings → Rules** gets plain-language refresh schedule controls with a **live estimated data usage readout** (MB/school day on mobile & Wi-Fi, typical MB/month, honest Android Doze note).
- **Honest per-part freshness:** `data_cache.json` records `part_updated` timestamps per subsystem (`quick`, `full`, `timetable`, `stable_timetable`, `subject_directory`, `marks`, `absence`, `outbox`, `strava`) so every screen, the phone's status notification and the desktop tooltip show the true freshness of their own data and a failed tier never makes stale data look fresh.
- **Safety rules preserved (`CONTRIBUTING.md` §5):** one pipeline (`runRefresh`), one session lock (`<rootDir>/session.lock`), one send path (`Strakalari.sendExcuse` + `excuse_history.dart` + `HistoryLock`, unchanged), everything audited (`audit.dart`, dry run included), `automation_paused` stops every tier's auto phase, Bakaláři web only (never `/api/3`), fail loudly.

---

## 2. Bandwidth & Request-Count Estimates (Answering D6 A2 & A6)

All sizes come from the real GEKOM measurements in [`research-F6-bakalari-web.md`](research-F6-bakalari-web.md) §2–9:
- Quick tick (session reused, new TLS handshake — Android headless): **~18 KB** (`Marks/Widget` 2 KB + `substitutions/dates` 4 KB + `GetAbsenceBySubjects` 2 KB + ~3 KB HTTP headers + ~7 KB TLS).
- Quick tick (session reused, kept-alive TLS — desktop / live Android UI): **~11 KB**.
- Quick tick (session expired, gap ≥ 15 min — new login without `/dashboard`): **~26 KB** (+6 KB `GET /login` + 1.5 KB `POST /Login` `302`).
- Quick tick that also reads the outbox list (only while excuses are pending, at most hourly, R8a M2): **+~5 KB**, i.e. at most ~0.12 MB/day.
- Note on Bakaláři's 15-minute sliding session (`research-F6-bakalari-web.md` §5.1): a request in the second half (> 7.5 min after the last renewal) renews it to 15 min. Any steady rhythm under 15 min (5 or 10 min) keeps the session alive without extra logins; hourly ticks always log in.
- School-day baseline (non-quick-tick traffic, 10 h window 07:00–17:00):
  - Triggered `prubzna.aspx` on new marks (~3 × 187 KB): **0.56 MB**
  - Triggered changed timetable weeks (~3 × 70 KB): **0.21 MB**
  - Hourly daytime safety net for this week (10 × 65 KB): **0.65 MB**
  - Strava every 30 min daytime, hourly otherwise, + pre-cutoff (~37 × 6 KB): **0.22 MB**
  - Full runs: first of day (~640 KB with `perm`, subject dir, past weeks) + 3 routine full runs every 6 h (~340 KB each, Komens via the 3 cached fields): **1.66 MB** (R8a N1: first run after midnight + every 6 h = ~4 full runs, not 3)
  - **Baseline subtotal:** **~3.3 MB / school day**.
- Full runs store the per-week feed hashes (R8a S4), so the first quick tick after a full run loads no week unless the feed changed.

| Scenario (1 account, 10 h school day: 1 h before 8:00 = 07:00 → 17:00) | Quick ticks / day | Total / school day | Typical mobile / month* | 100% mobile / month** | School requests / day |
|---|---|---|---|---|---|
| **Today (hourly full refresh)** | 24 full | **~25 MB** | ~220 MB | ~750 MB | ~670 (heavy) |
| **Mobile 5 min daytime + 60 min off-hours** *(default mobile)* | 120 + 14 | **~5.8 MB** | **~85 MB** | ~145 MB | ~490 (tiny) |
| **Mobile 10 min daytime + 60 min off-hours** | 60 + 14 | **~4.7 MB** | **~60 MB** | ~120 MB | ~310 (tiny) |
| **Wi-Fi 5 min 24/7** *(default Wi-Fi)* | 288 | **~8.5 MB** (~6.5 MB kept-alive) | **0 MB** | — | ~920 (tiny) |
| **Wi-Fi 5 min daytime + 60 min off-hours** (`refresh_wifi_always_fast: false`) | 120 + 14 | **~5.8 MB** (~5.0 MB kept-alive) | **0 MB** | — | ~490 (tiny) |

*\*Typical mobile/month: mobile data only during the 10 daytime hours on ~21 school days/month (~4.0 MB per such day at 5 min, ~3.0 MB at 10 min), Wi-Fi at home and at weekends.*
*\*\*100% mobile/month: 21 school days + 9 days off (a day off on mobile data with hourly checks ≈ 2.4 MB). Multi-account installs multiply linearly by the number of `background_refresh: true` accounts.*

How the totals add up (5-min mobile): 120 × 18 KB + 14 × 26 KB + 3.3 MB ≈ 5.8 MB. Requests: 120 × 3 + 14 × 5 + ~42 in the 4 full runs + ~16 triggered ≈ 490. Wi-Fi 24/7: 288 × 18 KB + 3.3 MB ≈ 8.5 MB; 288 × 3 + ~58 ≈ 920 requests. **Wi-Fi 24/7 sends more (small) requests to the school's server than today's ~670** (owner accepted in Q2).

All mobile configurations stay below `proposal-F6-low-data.md` §6's ≤ 8 MB/day target (4.7 MB/day at 10 min, 5.8 MB/day at 5 min). The owner's real-account measurement (Q3) checks these numbers after the code review.

---

## 3. Configuration Keys (PLAN Rule 4 & F4 Shared Split)

All schedule keys live in `<rootDir>/global.json` (`globalConfigKeys` in `packages/strakalari_core/lib/src/storage/accounts.dart`) because one device / scheduler wakes on one rhythm.

### 3.1 Existing & new canonical keys (3 new keys; total canonical keys 74 → 77, `globalConfigKeys` 19 → 22)

| Key | Type | Default | Validation (`config.dart`) | Meaning |
|---|---|---|---|---|
| `check_interval_minutes` *(existing)* | `num` | **`5`** *(was `60`)* | `>= 1` | Fast check interval in minutes (Wi-Fi / desktop / iOS; also the lower bound for mobile). Upgraded pre-F6 installs are overwritten once to `5` at startup via `applyF6ScheduleDefaultsOnce` (owner Q1, §3.3). |
| `check_interval_mobile_minutes` *(new)* | `num` | **`5`** | `>= 1` | Daytime check interval in minutes on mobile data (Android metered; owner Q1: 5 min default, configurable). Runtime uses `max(check_interval_minutes, check_interval_mobile_minutes)` so mobile never polls faster than Wi-Fi. |
| `check_interval_off_hours_minutes` *(new)* | `num` | **`60`** | `== 0 || >= 1` (i.e. `>= 0` and not in `(0, 1)`) | Off-hours / overnight & day-off check interval in minutes. `0` = pause off-hours (with one quick tick 30 min before the Wake-up alarm if enabled); `>= 1` = check every N minutes (default `60` per D6 A4). |
| `refresh_wifi_always_fast` *(new)* | `bool` | **`true`** | `is bool` | When `true`, Wi-Fi / unmetered connections keep using `check_interval_minutes` 24/7 including nights and weekends (D6 A6, owner Q2). When `false`, Wi-Fi also slows to `check_interval_off_hours_minutes` outside school daytime hours and on days off. |

### 3.2 Files updated in the same commit (PLAN Rule 4)
1. `config.example.json` (add the 3 new keys; update `check_interval_minutes` to `5`).
2. `packages/strakalari_core/lib/src/storage/config.dart` (`canonicalDefaults` + `validateConfig`).
3. `packages/strakalari_core/lib/src/storage/accounts.dart` (add the 3 new keys to `globalConfigKeys`; update its "19 keys" comment).
4. `packages/strakalari_core/test/parity/helpers.json` (`roundTripFiles` — add the 3 new keys to the two full canonical config snapshots only; keep `check_interval_minutes: 60` unchanged inside those two snapshots: they are both the input and the expected output of the round trip, so a saved `60` stays `60`).
5. `packages/strakalari_core/test/config_test.dart` and `packages/strakalari_core/test/accounts_test.dart`.

### 3.3 One-time startup upgrade of pre-F6 schedule defaults (`applyF6ScheduleDefaultsOnce`)
Per owner Q1 (2026-11-22: *"It should get overwritten to the new default settings. And wifi should be 5 minutes 24/7. And we should make the 5 minutes default anyway."*). This is the owner-approved exception to CONTRIBUTING §6's "no silent migration": it runs once and is logged.
- Implemented as an explicit, idempotent helper `bool applyF6ScheduleDefaultsOnce(String rootDir, {bool degraded = false})` in `packages/strakalari_core/lib/src/automation/refresh_schedule.dart` (NOT inside `ConfigManager.load()`, so loading stays read-only).
- Called once at startup in `prepareStartup` (`app/lib/platform/startup.dart`, Android, iOS and desktop paths) and `_runHeadless` (`app/lib/platform/android/background.dart`) immediately after `ensureMultiAccountLayout(rootDir)` returned `ready` or `degraded` (not after `registryFailed`).
- Target file: `<rootDir>/global.json` when the layout is ready, `<rootDir>/config.json` in degraded mode. *(R8a S12)* A fresh install already has `global.json` = `{}` at this point (`ensureMultiAccountLayout` writes it, `accounts.dart:764–767`); the rules below handle it like any file without the new keys, which writes the defaults it would get anyway.
- Steps *(R8a S12)*:
  1. Read the raw JSON without a lock. If the file is missing, or already contains **any** of `check_interval_mobile_minutes`, `check_interval_off_hours_minutes`, `refresh_wifi_always_fast`: no-op (already on F6; any later user choice, including `60`, is kept forever).
  2. Take the same lock `ConfigManager` saves under (`<file>.lock`, `InterProcessLock`, 10 s). If it is busy: log `Info: F6 schedule defaults postponed (settings busy).` and return (the next start tries again; nothing else writes the new keys before then).
  3. Re-read the file under the lock and repeat the check of step 1 (the UI and the headless isolate may both get here).
  4. Write the 4 defaults (`check_interval_minutes: 5`, `check_interval_mobile_minutes: 5`, `check_interval_off_hours_minutes: 60`, `refresh_wifi_always_fast: true`) atomically, every other key untouched, and log one line with the old value: `Info: F6 schedule defaults applied (check_interval_minutes <old> -> 5).`
- Tests in `refresh_schedule_test.dart`: fresh install (`{}` → the 4 defaults); a pre-F6 F4 layout with `check_interval_minutes: 60` → `5`/`5`/`60`/`true` once; a later user edit to `60` → second call is a no-op; degraded root `config.json`; lock busy → nothing written, `false` returned, the next call writes; two calls racing (lock held by the first) → written once.

---

## 4. Step 1: Free Wins in Bakaláři HTTP & Client

### 4.1 Login without downloading `/dashboard` (`http_session.dart`) *(R8a S8)*
Today `login()` follows every redirect and treats a `GET /login` that ends on `/dashboard` as "already logged in"; anything else without the login form is `bak_no_login_page` (`http_session.dart:760–808`). F6 keeps exactly these rules and only stops downloading the dashboard:
- `GET /login` with `followRedirects: false`, following redirects by hand only while the target is on the same host and its path is `/login` (case-insensitive, trailing `/` stripped, any query such as `?ReturnUrl=`), plus an `http → https` redirect to the same host; at most 5 hops.
  - A redirect to **`/dashboard` on the same host** = the session cookie is still valid: set `loggedIn = true` and return without loading `/dashboard`.
  - Any other redirect target, or a final page without `id="loginButton"`: today's `bak_no_login_page` (log the URL as today).
- `POST /Login` with `followRedirects: false` (`_storeCookies(resp)` already captures every `Set-Cookie` on the `302`):
  - `301/302/303/307/308` → resolve `Location` against the POST URL:
    - same host and path `/dashboard` (or exactly the `returnUrl` the form sent, if non-empty): **success** without loading it (`loggedIn = true`, record the renewal time for 3b, §6.2);
    - same host and path `/login`: follow it once with `GET` so `loginErrorText(resp)` extracts any error message, set `loggedIn = false`, clear the stored session (§6.2), and throw `UserError(bak_login_rejected)`;
    - anything else (another host, `/`, an error page): follow it as today and apply today's `isLoginPage(resp)` check (rejected → `bak_login_rejected`, otherwise logged in).
  - `200`: keep the exact `isLoginPage(resp)` rejection check (wrong password returns `200` with error markup on `FakeBakalari` and the demo server; on real Bakaláři *unverified*, which is why every branch above ends in the same check).
- `sendOnce()` (excuse post) is **completely untouched**.
- Tests (`http_session_test.dart`): no `/dashboard` request after a successful login; `GET /login` → `302 /dashboard` with a valid cookie = logged in, no further request; `GET /login` redirecting to another host or to `/` = `bak_no_login_page`; `POST` `302` to `/login` = rejected; `POST` `302` to another host = followed and checked as today.

### 4.2 Absence without loading `/Absence/Continuous` (`data.dart`) *(R8a S7)*
- In `DataMixin.obtainAbsenceInfo()`:
  - `dateFrom` = 1 September of `today.year` when `today.month >= 9`, else of `today.year - 1` (written out in code; **not** `schoolYearTerms`, which switches to the new school year in August, `planner.dart:614`); `dateTo` = today; both `YYYY-MM-DD`.
  - Call `GET /Absence/Continuous/GetAbsenceBySubjects?dateFrom=<iso>&dateTo=<iso>&lateChecked=false&schoolChecked=false&soonChecked=false` directly.
  - **Fail-loud fallback** to the legacy path (`GET /Absence/Continuous` → `absenceDateRange(page)` → `GetAbsenceBySubjects`) once, with `Warning: direct GetAbsenceBySubjects failed ($e); falling back to /Absence/Continuous`, when the direct request throws (other than `CancelledError`), or `storeRows(rows) == null`, or the reply has **no subjects while the cached `absence` had some** (an empty success must not wipe the numbers).
  - Throttle in quick ticks: after a failed direct call (`absence_direct_failed_at` in the cache), quick ticks use the page path at most hourly and otherwise keep the cached numbers; full runs always try direct, then the page. A successful direct call clears the stamp.
  - Only if both fail: clear `absencePercentages = {}`, `absenceDetails = {}`, and set `absenceError` (as today).
- Tests: 31 August and 1 September (`dateFrom` 2025-09-01 / 2026-09-01); empty direct reply with a non-empty cache → page fallback; throttle in quick ticks.

### 4.3 Fetch order, permanent timetable (`perm`), subject directory and past weeks (`data.dart`, `timetable.dart`, `refresh.dart`)
- **Fetch order change in `DataMixin.fetchData()`** *(R8a S1, S4)*: login → **absence** → **substitution feed** → weeks → `perm` → baseline → grades → subjects (today: weeks → `perm` → feed → baseline → absence → grades → subjects, `data.dart:553–604`). The absence read comes first so a grown `Count` can pull the past weeks in the same run; the feed comes before the weeks so the stored week hashes never describe a change the stored week lacks (§5.2). Both moved calls keep their own `try`/`catch` exactly as today; no existing test depends on the order (checked at R8a).
- `DataMixin.fetchData()` gains optional parameters with backward-compatible defaults (so direct callers and all existing tests behave identically):
  - `List<int>? weekOffsetsOverride` (null = standard `weekOffsets(goBackWeeks, goForwardWeeks)` + `historyWeeks`).
  - `bool fetchStable = true`, with `Map<String, Object?>? cachedStableBaseline` (*R8a S5*): when `fetchStable` is `false` on purpose and the cache's `stable_baseline_source == 'scraped'`, `updateStableBaseline()` uses `baselineFromDict(cachedStableBaseline)` (`schedule.dart:480`) as the baseline with `stableComplete = true` (so `applySubstitutionFeed`, `backfillStableFacts` and `iterChanges` run exactly as in a full run). A `perm` fetch that was attempted and **failed** keeps today's behaviour ("no stable timetable this run"). A run that skipped `perm` never writes `stable_baseline` back (the cached one stays).
  - `bool fetchSubjects = true`.
  - `bool fetchMarks = true`.
  - `bool fetchMarksWidget = false` (set `true` by `runRefresh` on full runs; the widget is read **before** `getGrades()`, *R8a S3*, see §5.1).
- In `runRefresh` for **scheduled full runs** (`scheduled: true`):
  - Skip `perm` when `part_updated['stable_timetable']` is from today AND the cached `stable_baseline` is non-empty with `stable_baseline_source == 'scraped'`.
  - Skip `/Teaching/Subjects` when `part_updated['subject_directory']` is from today AND the cached `subject_directory` is non-empty.
  - Skip past regular weeks (`-1 … -goBackWeeks`) only when ALL hold *(R8a S1)*: `timetable_history.past_weeks_fetched == todayIso`; all past regular Mondays are in `timetable_history.weeks`; this run's absence read (done first) succeeded; and no subject's current `Count` (`missed_hours`) is greater than in `absence_counts_at_past_fetch` (cache key; missing subject = 0; missing snapshot = load the weeks).
  - Why a shorter set of weeks is safe for auto-excuse: `generateExcuses` breaks every full-day chain at a gap (a weekend), so no excuse spans a week boundary on a Monday–Friday school; missing weeks only mean fewer excuses that run, never different ones; and the delay cutoff (`excuse_delay_days`) moves only at midnight, when the first run of the day loads every week.
- On **manual full runs** (`scheduled: false`) or the first run of the day: fetch everything fresh (no daily skipping).
- **Bookkeeping** *(R8a S1)*: a run that loaded all regular past weeks writes `absence_counts_at_past_fetch` (the `Count` per subject from the same run) and `past_weeks_fetched: todayIso`. `_recordHistoryWeeks` (`refresh.dart:433–454`) keeps `past_weeks_fetched` in the map it writes (it rewrites the whole `timetable_history` map). **Quick ticks never write `timetable_history` or `absence_counts_at_past_fetch`.**
- Effect for absences entered late: this week and last week arrive within one quick tick (§5.3); an absence entered for 2–4 weeks ago arrives with the next scheduled full run (≤ 6 h), because its `Count` growth stays above the snapshot until a run loads the past weeks.

### 4.4 Komens list callback with 3 cached hidden fields (`data.dart`, `cache.dart`) *(R8a M1, S6)*
- Cache key in `data_cache.json`: `const String outboxFormKey = 'komens_outbox_form_v1';`
  ```json
  {
    "path": "/next/komens.aspx?s=rok&l=o",
    "viewstate": "...",
    "viewstate_generator": "...",
    "event_validation": "...",
    "period_start": "2026-08-20",
    "period_end": "2027-08-31",
    "fetched_at": "2026-11-22T07:05:00"
  }
  ```
  (`period_start` / `period_end` are the two dates of the page's `cphmain_obdobiLabel`, e.g. `20.8.2026 - 31.8.2027`, `research-F2-komens-outbox.md` §1.)
- Not a secret (`research-F6-bakalari-web.md` §6.1: useless without the session cookie, and survives across new logins).
- **Unverified:** that a callback with only these 3 fields still lists the period of the page they came from. Step 0 tried it only on the one-month default folder (`?l=o`), where a fall-back to the default period would look the same. It goes on the owner's real-account check list (Q3) and may be checked read-only in the owner's browser like step 0. Until then the completeness check below is what makes the short read safe.
- `DataMixin.fetchAllOutboxIds` uses the cached fields only when ALL hold:
  - `knownOutboxForm.path == _outboxYearPath`, all 3 fields non-empty, `period_start` and `period_end` valid ISO dates with `period_start <= today <= period_end` *(R8a S6; the old check against 1 September could never pass)*;
  - `fetched_at` is `< 7 days` old (the weekly full-page reload is the backstop);
  - the run is **scheduled** (`scheduled: true`, or a quick tick's outbox read, §5.3). A manual *Obnovit data* (`scheduled: false`) always loads the page *(R8a S6)*;
  - the first read after a fresh install, a cleared cache, or a new school year has no valid cache and therefore always loads the page.
- **Cached callback path:** sends `POST /next/komens.aspx?s=rok&l=o` with `[('__VIEWSTATE', ...), ('__VIEWSTATEGENERATOR', ...), ('__EVENTVALIDATION', ...), ('__CALLBACKID', _outboxCallbackId), ('__CALLBACKPARAM', 'c0:$param')]`, paging exactly as F2 does (cumulative pages, end markers, `maxOutboxPages`).
- **Completeness check on every cached-path read** *(R8a M1)*: every excuse id already known in `komens_outbox_details_v1` (keys `id|sortDate`) whose sort date (`parseOutboxSortDate`) lies inside `[period_start, period_end]` must appear in the ids of the cached-path reply (all pages). A missing one means the reply is shorter than it claims (for example only the default month): treat it exactly like a rejected callback below.
- **Fail-safe self-healing fallback:**
  - If page 1's cached callback throws (`ArgumentError` on `0|/*DX*/({'redirect':'/dashboard?e='})`, `StateError` on callback error or missing `komens-messages-wrapper`, or HTTP error — never `CancelledError`) **or fails the completeness check**: log loudly (`Komens cached form fields rejected ($reason); reloading outbox page`), clear `knownOutboxForm`, and **retry once from scratch with the full `GET /next/komens.aspx?s=rok&l=o`** (`hfListType == 'odeslane'` verified + `cphmain_obdobiLabel` parsed + full form fields), as F2 does today.
  - If the full-page path succeeds, extract `__VIEWSTATE`, `__VIEWSTATEGENERATOR`, `__EVENTVALIDATION`, `period_start` and `period_end` from the page HTML and store them in `knownOutboxForm` (persisted to `data_cache.json` only when `lastOutboxSyncOk == true`).
  - If page 2+ fails OR the full-page fallback fails: abort the entire outbox read (`sentExcuses = null`, `lastOutboxSyncOk = false`, `knownOutboxForm` not updated) — **zero partial success, auto-excuse blocked, no unconfirmed submit settled**.
  - Only a read that passed the completeness check, or a full-page read, may set `lastOutboxSyncOk`, `sentExcusesFrom` (= `period_start`) and settle unconfirmed submits (`automation.dart:1206–1208`).
- `FakeBakalari` and `tools/bakalari_demo_server.py` get an option in which a 3-field callback returns only the last 30 days of the page's period (the default-period failure). Tests: with an older known excuse in the details cache, the cached read is rejected and the page is loaded in the same run; an older `unconfirmed` submit is **not** released by the rejected read; with no older known excuse the cached read is accepted; the label parse gives `period_start`/`period_end`; a manual refresh never uses the cache.

---

## 5. Step 2 & Step 5: Quick Tier, `/Marks/Widget`, & Per-Part Freshness

### 5.1 `/Marks/Widget` parser (`extractors.dart`) & fetcher (`data.dart`)
- `List<Map<String, Object?>>? extractMarksWidget(Object? htmlString)`:
  - Tri-state return:
    - `null`: HTML does not contain `class="[^"]*\bbk-widget-marks\b` (wrong page, 404/error, or changed Bakaláři markup) → parse failure.
    - `[]`: valid `bk-widget-marks` container with zero `.mark-line` items (student has no marks yet).
    - `List<Map<String, Object?>>`: ordered entries `{ 'grade': ..., 'subject': ..., 'note': ..., 'date': ..., 'is_new': bool }`, extracted from `.mark-line` spans (`mark-displayGrade`, `mark-subjectName`, `mark-note`, `mark-date`), HTML-unescaped and whitespace-normalized. `is_new` is `true` iff `mark-displayGrade`'s class list contains `isnew` (case-insensitive).
- `DataMixin.fetchMarksWidget()` calls `GET /Marks/Widget`, parses via `extractMarksWidget`, and returns the tri-state result (catching non-cancel errors, logging loudly, and returning `null`).
- **Order** *(R8a S3)*: in every run that reads both, the widget is read **before** `prubzna.aspx`. A mark given between the two requests then makes the stored widget older than the stored grades, which only causes one harmless extra marks-page load on the next tick (the reverse order would hide that mark until the next full run).
- Cache keys in `data_cache.json`: `const String marksWidgetKey = 'marks_widget_v1';` (the last parsed list, stored only together with grades from the same run), `const String marksWidgetFailedKey = 'marks_widget_failed_at';` (ISO timestamp while the widget is broken, cleared on the next valid parse) and `const String gradesFailedKey = 'grades_failed_at';` (ISO timestamp while `prubzna.aspx` fails, cleared on the next good read, *R8a S3*).

### 5.2 Per-week substitution feed hashes & absence growth (`extractors.dart`)
- `Map<String, String> substitutionsByWeekHashes(List<Map<String, Object?>> feed, List<DateTime> weekMondays)`:
  - Buckets feed entries by Monday (`YYYY-MM-DD`, using `parseCzDate(entry['day'])`), sorts entries canonically within each week, and computes SHA-256 hex digest per Monday in `weekMondays` (empty week = SHA-256 of `'[]'`).
  - Cache key in `data_cache.json`: `const String substitutionsWeekHashesKey = 'substitutions_week_hashes_v1';`.
  - **Written by full runs too** *(R8a S4)*: a full run stores the hashes of every week it loaded, computed from the feed read **before** those weeks in the same run (§4.3 fetch order). A quick tick stores a week's hash only when that week is unchanged or was loaded successfully after the feed.
- `bool absenceCountsIncreased(Map<String, Object?>? previousDetails, Map<String, Object?> freshDetails)`:
  - Returns `true` iff any subject in `freshDetails` has `missed_hours` (`int`, from Bakaláři `Count`) strictly greater than `previousDetails[subject]['missed_hours']` (default `0`), ignoring `LessonCount` (`total_hours`). The same comparison against `absence_counts_at_past_fetch` decides the past weeks (§4.3).

### 5.3 The single `runRefresh` pipeline (`refresh.dart`)
- `const List<String> refreshScopes = ['all', 'bakalari', 'strava', 'quick'];`
- New optional parameters of `runRefresh(...)`, defaults keep every existing caller and test exactly as today: `bool scheduled = false` (§4.3, §4.4) and `bool quickOutbox = false` (§5.3 step 1(e), only meaningful with `scope: 'quick'`).
- The quick tier needs new members on `RefreshApp` (e.g. `fetchQuick(...)`, `fetchMarksWidget()`), implemented by `Strakalari` through `BakalariClient`; test fakes that implement `RefreshApp` get these members without any change to existing assertions.
- When `scope == 'quick'`:
  1. **Bakaláři quick check** (if `hasBak`):
     - Reads existing cache (`previousCache = loadDataCache(dataDir: effectiveDataDir)`).
     - Logs in (reusing the lent pooled or stored session when valid — **0 login requests** during 5–10 min ticks, §6).
     - **(a) Marks signal:** calls `fetchMarksWidget()`.
       - If valid (`widget != null`): clears `marks_widget_failed_at`. Compares `widget` with `previousCache[marksWidgetKey]` via `jsonEquals`.
         - If different (or `previousCache[marksWidgetKey]` missing): calls `getGrades()` — unless `grades_failed_at` is set and less than 60 min old *(R8a S3)*. If `gradesError == ''`: puts `grades`, `quarterly_marks`, `marksWidgetKey: widget`, clears `grades_failed_at`, stamps `part_updated['marks'] = nowIso`. If `getGrades()` failed: does **not** update `marksWidgetKey` or `part_updated['marks']`, sets `grades_failed_at` (first failure of a streak logged loudly, later ones not), so the marks page is retried at most hourly while it is broken (not 187 KB every 5 min).
         - If identical: skips `prubzna.aspx`, stamps `part_updated['marks'] = nowIso` (confirmed unchanged by widget).
       - If parse/HTTP failed (`widget == null`): logs loudly (once per failure streak). If `previousCache[marksWidgetFailedKey]` is absent (first failure) OR `part_updated['marks']` is missing / ≥ 60 min old → falls back to `getGrades()` on **this tick** (so a broken widget never hides marks for long, while a permanently unsupported school throttles the fallback to hourly). Stamps `marksWidgetFailedKey: nowIso`.
     - **(b) Substitution feed:** calls `fetchSubstitutions()`.
       - Computes `freshHashes` for `[thisMonday, … thisMonday + goForwardWeeks]`.
       - Any week whose hash differs from `previousCache[substitutionsWeekHashesKey]` (or is missing) is queued in `weeksToFetch`.
       - Also if currently in daytime school hours (`activeDayWindow(previousCache, cfg, started) != null`) and `part_updated['timetable']` is missing or ≥ 60 min old → queues `thisMonday` (hourly safety net for short-notice whole free days).
     - **(c) Absence numbers:** calls `obtainAbsenceInfo()` (direct 1.2–3 KB JSON; page fallback as in §4.2, throttled hourly in quick ticks).
       - If `absenceError == ''`: puts `absence`, `absence_details`, stamps `part_updated['absence'] = nowIso`.
       - If `absenceCountsIncreased(previousCache['absence_details'], absenceDetails)` → queues `thisMonday` in `weeksToFetch`. (It does not touch `absence_counts_at_past_fetch`, §4.3.)
     - **(d) Conditional week fetch:** if `weeksToFetch` is non-empty:
       - Uses the cached `stable_baseline` (`stable_baseline_source == 'scraped'`) as in §4.3 *(R8a S5)*.
       - Fetches ONLY `weeksToFetch` via `timetableView('cal', monday)`.
       - Runs `updateStableBaseline()` (applying fresh `substitutions` feed + `backfillStableFacts` + `iterChanges` against the cached baseline).
       - If absence count grew and `newAbsences(previousCache, {'timetable': timetableData})` is empty and `lastMonday` wasn't fetched yet (e.g. teacher entered a Friday absence on Monday): fetches `lastMonday` (`addDays(thisMonday, -7)`) once and re-runs `updateStableBaseline()`.
       - Puts `timetable` into `fresh` (merged day-granularly by `_persist`), updates `substitutionsWeekHashesKey` **only** for unchanged or successfully loaded weeks, and stamps `part_updated['timetable'] = nowIso`.
       - If no weeks needed fetching and feed succeeded: updates `substitutionsWeekHashesKey` (unchanged) and puts `substitutions` into `fresh`.
     - **(e) Outbox read while excuses are pending** *(R8a M2)*: only when `quickOutbox == true` (decided by `chooseScheduledScope`, §7.5): calls `app.syncWebExcusesToHistory()` through the guarded path of §4.4 (cached fields + completeness check, full-page fallback), then writes `sent_excuses_from` and the details cache exactly as `_fetchPhases` does for full runs (`refresh.dart:567–578`) and stamps `part_updated['outbox'] = nowIso` only after a successful read. Without `quickOutbox` the quick tick does not read the outbox.
     - **Never writes `timetable_history` or `absence_counts_at_past_fetch`** *(R8a S1)*, never stores `stable_baseline`.
     - Stamps `part_updated['quick'] = nowIso` if marks signal, feed, and absence all succeeded without error.
  2. **Strava conditional check** (if `app.stravaEnable && hasStrava`):
     - Fetches Strava **only** when `stravaQuickFetchDue(previousCache, cfg, started)` is `true`:
       - `part_updated['strava']` is missing; OR
       - During daytime active window: `part_updated['strava']` is ≥ 30 min old; OR
       - Outside daytime window: `part_updated['strava']` is ≥ 60 min old; OR
       - Within 60 min before today's `resolveLunchCutoff(cfg)` and `part_updated['strava']` is ≥ 15 min old.
     - On success: updates `strava_meals`, `strava_ordered`, `strava_status: 'ok'`, stamps `part_updated['strava'] = nowIso`. On failure: records error in `result.errors` without advancing `part_updated['strava']`.
  3. **Auto phases (`_autoPhases`):**
     - **Scope lock on auto-excuse:** `wantsExcuse = effectiveScope != 'quick' && result.bakalariFetched && app.excuseMode == 'auto'`. Quick ticks NEVER run auto-excuse and NEVER emit `auto_excuse_outbox_unknown`, **also when the quick tick read the outbox in step 1(e)**.
     - Auto-lunch order & F3 auto-cancel run **only** when `result.stravaFetched` (i.e. Strava actually fetched in this tick) and `!automationPaused(cfg)`.
  4. **News & Persist:**
     - `findNews(previousCache, fresh, today)` compares only keys present in `fresh` (`grades`, `quarterly_marks`, fetched `timetable` days) against `previousCache` — firing immediate notifications for new marks, new absences, and timetable changes without false positives (`news.dart:33–64`, `:102–106`, `:189–196`).
     - `fresh['last_updated']` is **NOT** touched by `quick` (it stays the timestamp of the last complete `'all'` run); `fresh['part_updated']` merges updated part timestamps over `previousCache['part_updated']` (`saveDataCache` replaces top-level keys, so the merged map is written whole).
- **Quieter logs for quick ticks** *(R8a S13)*: with `scope == 'quick'`, `runRefresh` emits one summary line (`quick_check_log`, §8.3) instead of the per-phase progress lines, plus one line per thing that happened (news, a week loaded, a fallback, an error). The per-subject absence "Recommendation: …" lines (`data.dart:133–146`) are logged only in full runs.

### 5.4 Honest per-part freshness (`cache.dart` & UI)
- New constants & helpers in `packages/strakalari_core/lib/src/storage/cache.dart`:
  - `const String partUpdatedKey = 'part_updated';`
  - `DateTime? partUpdatedTime(Map<String, Object?>? cache, String part)` (reads `cache['part_updated'][part]`, falling back to `lastUpdatedTime(cache)` for pre-F6 caches).
  - `DateTime? lastCheckedTime([Map<String, Object?>? cache])` (newest of `part_updated['quick']`, `part_updated['full']`, and `last_updated`).
  - `String describeCacheForPart(Map<String, Object?>? cache, String part, [num ttlHours = 24])` (formats the part's own timestamp + age + stale badge; falls back to `describeCache` if `part_updated` is absent).
- **When stamps move** *(R8a S2)*: `part_updated['full']` exactly when `last_updated` moves (a complete `'all'` run, `refresh.dart:309–319`); `part_updated['outbox']` after an outbox read that passed §4.4 (full run or quick tick 1(e)); every other part as listed in §5.3; a failed part never moves its stamp. Every stamp of one run uses that run's `started` time (ISO), so "outbox older than full" (§7.5 rule 5) compares like with like.
- UI mapping (`app_state.dart` helper `updatedLabelFor(String part)`):
  - **Today (`today_live.dart`):** `updatedLabelFor('quick')`
  - **Timetable (`timetable_live.dart`):** `updatedLabelFor('timetable')`
  - **Marks (`marks_live.dart`):** `updatedLabelFor('marks')`
  - **Absences (`absences_live.dart`):** `updatedLabelFor('absence')`
  - **Lunches (`lunches_live.dart`):** `updatedLabelFor('strava')`
  - **Activity (`activity_live.dart`) & Settings → Diagnostika (`settings_live.dart:32`, `cache_info`):** shows `last_updated` (full refresh); when `part_updated['quick']` is newer than `part_updated['full']`, formats `refresh_checked_full` (`Kontrola: HH:MM · Úplná: DD.MM. HH:MM` / `Checked: HH:MM · Full: DD.MM. HH:MM`).
  - **Phone status notification & widget inputs** (`backgroundStatusInputs`, `app_state.dart:262–280`) *(R8a S11)*: `updated` = `lastCheckedTime(cache)`, shown with the core string `status_checked` (`Zkontrolováno HH:MM` / `Checked HH:MM`) instead of `status_updated`.
  - **Desktop status tooltip** (`scaffold.dart:480`) *(R8a S11)*: shows `lastCheckedTime` the same way, followed by the next check from §7.4.
  - `startupSeed(cache)` uses `lastCheckedTime(cache)` so quick ticks satisfy the scheduler timer on restarts/reboots without falsely moving `last_updated`.

### 5.5 Aktivita with a run every 5 minutes *(R8a S13)*
- The run list keeps 20 entries and the log 300 lines (`activity.dart:55–60`, `:1002–1030`, `:1174–1200`). So that the last full run (with its excuses and orders) stays visible:
  - A quick tick that succeeded, brought no news and changed nothing adds **no row**: it updates the account's `quickChecksToday` counter and `lastQuickCheck` time (in memory, like `runs`), shown as one line at the top of the run history card: `activity_quick_checks` (`Rychlé kontroly: {n}× dnes, poslední {time}`).
  - A quick tick that failed, was skipped (session busy), or brought news / loaded a week / read the outbox adds a row as today, labelled `scope_quick` (`_scopeLabel` maps `'quick'` to it; `'quick'` is **not** added to `_scopes`, which drives the manual refresh chips, `activity_view.dart:241–245`, `:575`).
  - Full runs add a row as today. The app's own `refresh_started_log` / `refresh_finished_log` lines are skipped for silent quick ticks.
- The audit (`automation_history.jsonl`) is unchanged: quick ticks send nothing; any auto order/cancel they run is audited as today.

---

## 6. Step 3: Session Reuse (3a In-Memory + 3b Encrypted Cookie Store)

### 6.1 Step 3a — In-memory session & TCP/TLS keep-alive pool *(R8a S9)*
- `DartIoHttpTransport` (`http_session.dart`): add optional `Duration idleTimeout = const Duration(seconds: 15)` constructor argument setting `_client.idleTimeout = idleTimeout` (15 s is `dart:io`'s default, so nothing changes for other callers).
- New file `packages/strakalari_core/lib/src/bakalari/session_store.dart`:
  - `BakalariSessionPool` (process-wide singleton with `resetForTesting()`):
    - Key: `(normalizedDataDir ?? '', appRoot(url), username)`.
    - Stores `BakalariSession` created with `DartIoHttpTransport(idleTimeout: const Duration(minutes: 6))` (`research-F6-bakalari-web.md` §8: the school's server keeps idle sockets ≥ 10 min; 6 min spans 5-min ticks to skip the ~7 KB TLS handshake on desktop & live Android UI).
    - Also remembers `passwordDigest` = SHA-256 (hex) of the **decrypted** password (kept only in memory and inside the encrypted file of §6.2), so a re-encrypted but equal password keeps the session, and a changed one evicts it.
    - **Exclusive lending:** `checkout(key, passwordDigest)` lends the pooled session to exactly one `BakalariClient` until it is returned (`Strakalari.close()`); a second checkout while it is lent gets a fresh session **outside** the pool (closed after use). No two callers ever share one `BakalariSession`.
    - On checkout: if `passwordDigest` changed → close & evict old session + delete on-disk `bakalari_session.enc`.
    - Explicit `evict(dataDir)` / `closeAll()` called on credential save in Settings and the wizard, account deletion, `--forget-secrets`, and desktop `onQuit`.
    - Callers passing an explicit `transport` (tests with `FakeBakalari`) always bypass the pool.
    - **Connection tests and the wizard's login checks** (`_testWork`, `activity.dart:1222–1272`, which runs without the session lock and with the typed values as `configData` overrides; `checkBakalariLogin`) **never use the pool or `bakalari_session.enc`**: they always build a fresh session and post the login form with the typed values (`BakalariClient.login()` would otherwise return at once for a logged-in session, `client.dart:258–262`).
  - `Strakalari.close()`: closes `stravaClient`; returns a pooled `BakalariSession` to the pool (keeping its sockets alive between ticks) and closes a non-pooled one.
- Tests (`session_store_test.dart`): reuse across two runs; a second checkout while lent gets a different session object; a connection test with a wrong typed password fails even while a pooled session is logged in; an equal re-encrypted password keeps the session; a changed password evicts it.

### 6.2 Step 3b — Encrypted on-disk cookie store (`<accountDir>/bakalari_session.enc`)
- Approved by owner in D6 A5 (`"Yes, store it encrypted like passwords"`).
- **Path:** `p.join(effectiveDataDir, 'bakalari_session.enc')` (per-account folder, so F4 account deletion and the uninstaller's `DelTree(AppDir + '\accounts')` remove it; in degraded mode it lies in the root folder, so `installer.iss` also gets `DeleteFile(AppDir + '\bakalari_session.enc')`).
- **Encryption:** Fernet-encrypted with the account's existing key (`encrypt(json, dataDir: dataDir)`, using Android Keystore / iOS Keychain / DesktopKeyStore — never plaintext). If encryption throws (`KeyStoreUnavailable`), log a warning and skip disk persistence (never write plaintext cookies). File written atomically with `0600` permissions on POSIX.
- **Payload (inside Fernet ciphertext):**
  ```json
  {
    "v": 1,
    "root": "https://bakaweb.gekom.cz",
    "username": "student",
    "password_sha256": "<hex of the decrypted password>",
    "cookies": {"BakaAuth": "...", "ASP.NET_SessionId": "..."},
    "renewed_at": "2026-11-22T09:10:00Z"
  }
  ```
- **Load & expiry rules:**
  - Decrypt with `decryptStrict(..., dataDir: dataDir, fallbackKeyDir: fallbackKeyDir)`. Corrupt/unreadable → delete file, log debug line, log in fresh.
  - Mismatch on `root`, `username`, or `password_sha256` → **delete `bakalari_session.enc` immediately** and log in fresh.
  - Age check from the **last renewal**, not the last request *(R8a N3)*: `renewed_at` is the time of the login or of the last response that carried a `Set-Cookie` for a cookie already held (the server's 15 minutes run from the last renewal, `research-F6-bakalari-web.md` §5). If `now − renewed_at >= 14 minutes` (1 min margin) or `< −2 minutes` (clock skew) → treat as expired and log in fresh directly without wasting a round-trip. *(If real Bakaláři renews without a new `Set-Cookie`, which is unverified, this only costs an early re-login every ~15 min; the owner's measurement, Q3, shows which.)*
  - Otherwise seed the lent `BakalariSession`'s cookies (`loggedIn = true`).
- **Update & invalidation:**
  - `BakalariSession` exposes `void Function(Map<String, String> cookies, DateTime renewedAt)? onCookiesChanged`: called after the login and after every response carrying `Set-Cookie`, persisting `bakalari_session.enc` immediately (always under the session lock, since every Bakaláři run and send holds it; connection tests never persist, §6.1).
  - On `bak_login_rejected` (invalid password) or credential edit/clear → **delete `bakalari_session.enc` immediately**.
  - `AccountManager.forgetAllKeys` (`--forget-secrets`) also deletes `bakalari_session.enc` in the root and in every folder under `accounts/`.
- **Redaction (`error_report.dart`):**
  - Never log cookie values or `bakalari_session.enc` contents.
  - Add cookie redaction to `error_report.dart`:
    1. `allAccountSensitiveValues` also reads any active pooled session cookies and (best-effort) decrypts `<accountDir>/bakalari_session.enc` cookie values (length ≥ 6) so every live/stored cookie value is replaced with `***`.
    2. `redactText` additionally scrubs raw `Cookie: …` and `Set-Cookie: …` header values via regex as defense in depth.
- Tests (`session_store_test.dart`, `error_report_test.dart`): encrypted disk round-trip; sliding `Set-Cookie` update moves `renewed_at`; 14-min expiry; credential-change and login-rejection deletion; corrupt-file recovery; no plaintext fallback on `KeyStoreUnavailable`; `forgetAllKeys` deletes the files; cookie value + `Cookie:`/`Set-Cookie:` redaction.

### 6.3 Test servers that end sessions *(R8a S10)*
Today `tools/bakalari_demo_server.py` (`login`, `logged_in`, l.528–641) and `FakeBakalari` keep every session forever, which would make the 3b checks prove nothing about expiry. Both get an **opt-in** session lifetime (off by default, so every existing test and use is unchanged):
- demo server: `--session-minutes 15`; `FakeBakalari(sessionMinutes: 15)` using `package:clock` (tests drive it with `withClock`);
- behaviour: a session lasts 15 minutes after its last renewal; a request in the second half renews it and answers with a fresh `Set-Cookie`; a request to an expired session answers `302 → /login?ReturnUrl=<path>`.
- Tests: 5- and 10-minute quick ticks never log in again; an hourly tick logs in exactly once with no wasted data request; after a renewal, the next headless run loads the renewed cookie. The Pixel run (§9) uses `--session-minutes 15`.

---

## 7. Dynamic Scheduling, Multi-Account, & Data-Usage Estimator

New pure-Dart module: `packages/strakalari_core/lib/src/automation/refresh_schedule.dart` (exported from `strakalari_core.dart`).

### 7.1 Network classification
- `enum NetworkKind { unmetered, metered, unknown }`
- Desktop (Windows, macOS, Linux) and iOS: always `NetworkKind.unmetered` (iOS checks only while the app is open, `startup.dart:246–251`; see §8.1 for what iOS shows).
- Android:
  - Add `<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />` to `app/android/app/src/main/AndroidManifest.xml` (normal install-time permission, no runtime prompt; not present today).
  - Add `networkKind` method to `StrakalariChannel.java` + `AndroidChannel.networkKind()` (available in the UI and the headless engine, like the other channel methods):
    - Uses `ConnectivityManager.getActiveNetwork()` + `getNetworkCapabilities(net)`.
    - `NET_CAPABILITY_INTERNET` + `NET_CAPABILITY_NOT_METERED` → `'unmetered'` (Wi-Fi / unmetered Ethernet).
    - `NET_CAPABILITY_INTERNET` without `NET_CAPABILITY_NOT_METERED` → `'metered'` (mobile data / metered hotspot).
    - Otherwise → `'unknown'`.
  - **Cached, not awaited in providers** *(R8a M3)*: `AppState.networkKind` is refreshed (`await channel.networkKind()`) at the start of every scheduled job run, when the app resumes, and in the headless entry before `registerJobs`; the synchronous providers of §7.4 read this field. Before the first read it is `unknown`.
  - **Important safety rule:** `networkKind` is used **only** to choose the polling cadence (`unknown` conservatively treated as `metered` on Android). It **never blocks** a refresh (so loopback `adb reverse` testing and VPNs always work).

### 7.2 Active school-day window (`activeDayWindow`)
- Uses `effectiveCalendar(config, clip: false).dates` and `wakeup.dart` (`indexDays`, `periodSlots`, `lessonsFor`, `firstLesson` with `planned: const []` so a planned skip doesn't hide school hours, `clockOf`, `isCancelledLesson`).
- For a given calendar `day`:
  - If `day` is in `freeDays` or (weekend with no non-cancelled lessons) or has 0 non-cancelled lessons (when timetable/baseline exists) → returns `null` (**day off**).
  - If timetable & baseline are both empty (cold install): Mon–Fri defaults to `07:00–17:00`, Sat–Sun returns `null`.
  - Otherwise:
    - `start` = `max(05:00, firstLessonStart - 60 min)` (1 hour before first lesson, D6 A2).
    - `end` = `max(17:00, lastLessonEnd)` (17:00, or end of last lesson if later, D6 A2).
- **Multi-account** *(R8a N11)*: the device rhythm (§7.4) uses `combinedActiveDayWindow(accountCachesAndConfigs, day)`, the union across all `background_refresh: true` configured accounts (earliest `start` to latest `end`); each account's own due check (§7.6) uses that account's own window.

### 7.3 Effective interval & next wake time
- `double effectiveCheckIntervalMinutes(Map<String, Object?> cfg, ({DateTime start, DateTime end})? window, NetworkKind network, DateTime now)`:
  - `wifiFast = max(1.0, check_interval_minutes)` (default `5.0`)
  - `mobileDay = max(wifiFast, max(1.0, check_interval_mobile_minutes))` (default `5.0`)
  - `offHours = check_interval_off_hours_minutes` (`0.0` = paused, else `max(1.0, v)`, default `60.0`)
  - `wifiAlwaysFast = cfg['refresh_wifi_always_fast'] != false` (default `true`)
  - `inWindow` = `window != null && !now.isBefore(window.start) && now.isBefore(window.end)`.
  - On `NetworkKind.unmetered`: returns `wifiFast` if `wifiAlwaysFast`, else (`inWindow ? wifiFast : offHours`).
  - On `NetworkKind.metered` / `unknown`: returns `inWindow ? mobileDay : offHours`.
- `DateTime nextScheduledWake(DateTime? lastRun, Map<String, Object?> cfg, ({DateTime start, DateTime end})? Function(DateTime day) windowFor, NetworkKind network, DateTime now, {DateTime? nextAlarm})` — **the only function that answers "when is the next scheduled check"**. `windowFor` is `activeDayWindow` for one account or `combinedActiveDayWindow` for the device rhythm (§7.2); `nextAlarm` is the primary account's next Wake-up alarm (`nextWakeupAlarm(...)?.alarmDt`) when `wakeup_enabled`:
  - `lastRun == null` → `now`.
  - When `effectiveInterval > 0`: `candidate = lastRun + effectiveInterval`. If currently outside the active window and today's window starts **before** `candidate` (and after `now`), clamps `candidate` to today's window start so fast checks begin right at `firstLesson - 60 min`.
  - When `effectiveInterval == 0` (user opted into off-hours pause): the earliest of:
    1. Next `activeDayWindow` start (today or up to 14 days ahead), and
    2. If `nextAlarm != null`: `nextAlarm - 30 min` (pre-alarm quick tick so a cancelled first lesson updates the alarm before it rings).
    - Fallback if neither exists within 14 days: `now + 6 hours`.
  - Never returns a time in the past by more than the runner's 5 s tick: `0` can never reach `nextDue` or `PeriodicRunner.intervalMinutes`, which both clamp to at least 1 minute (`scheduler.dart:23–26`, `:218–224`) and would turn a pause into a check every minute.

### 7.4 Wiring the schedule into every timer *(R8a M3)*
- **Core `PeriodicRunner`** (`scheduler.dart`) gets an optional `DateTime Function(DateTime? lastRun, DateTime now)? nextDueProvider` and a public `DateTime nextDueAt(DateTime now)`:
  - `nextDueAt` = `_retryAt` if a failed run set it and it is earlier, else `nextDueProvider(lastRun, now)` when set, else today's `nextDue(lastRun, intervalMinutes, now)` (unchanged for runners without a provider).
  - With a provider, a failed run sets `_retryAt = now + 5 min` and leaves `lastRun` alone (today the runner rewrites `lastRun` so that `nextDue` lands 5 minutes ahead, `scheduler.dart:178–186`; with a provider that trick no longer works). A successful run clears `_retryAt` and sets `lastRun = now` as today. **Without** a provider, the runner keeps today's `lastRun` rewrite unchanged.
  - `tick()` runs the jobs when `!now.isBefore(nextDueAt(now))`.
  - Tests in `scheduler_test.dart`: provider used; retry in 5 minutes with a provider; a runner without a provider behaves exactly as today (existing tests unchanged).
- **Every call site uses `runner.nextDueAt` / `nextScheduledWake`**, with the device rhythm's window (§7.2) and `AppState.networkKind` (§7.1):
  - `app/lib/platform/scheduler_jobs.dart:94–118` (`registerJobs`: passes the provider; `intervalProvider` keeps returning the effective interval only for labels);
  - `app/lib/platform/startup.dart:194–196` (UI/desktop runner), `:231–239` (hand-off: arm the wake for `loop.nextDueAt(now)`), `:345–355` (`_intervalMinutes` → effective interval for `bg_notif_text`), `:378–392` (`scheduleWake` → `loop.nextDueAt(now)`); `PhoneBackground.sync()` re-arms when any of the 4 schedule keys or the network kind changed;
  - `app/lib/platform/android/background.dart:344–372` (headless due check `runner.nextDueAt(now)`; the fallback wake before the job = `nextScheduledWake(now, …)`), `:376–399` (notification text), `:402–405` (`_scheduleWake` → `runner.nextDueAt`);
  - `app/lib/controllers/activity.dart:224–239` (`nextRunLabel` → the runner's `nextDueAt`), `:356`, `:484–489` (`_intervalFromConfig` → each account's effective interval for its due check, §7.6);
  - `app/lib/features/settings/settings_view.dart:614` (status preview text).
- **Scope per scheduled run:** `scheduledRefreshJob` (`activity.dart:323–449`) calls `chooseScheduledScope` (§7.5) **per account** and passes its scope, `scheduled: true` and `quickOutbox` through `startRefresh` (active account, `:408`) and `_refreshBackgroundAccount` (others, `:566`) to `runRefresh`. `startRefresh` (`:600–624`) accepts `'quick'` (today it turns every other scope into `'all'`, `:606–608`). Manual refresh, the tray's *Obnovit data* (`trayRefreshAll`), the wizard and the F1c early refresh keep `'all'` with `scheduled: false`.
- Tests (`app_state_accounts_test.dart`, `android_phone_background_test.dart`, `scheduler_test.dart`): off-hours `0` → no run between the window end and the pre-alarm tick, on the desktop runner **and** the headless wake (no 1-minute loop); last run 06:20, window starts 06:45 → next run 06:45; a scheduled tick shortly after a full run sends exactly the quick request list; manual and tray refresh stay `'all'`; the network kind switching from Wi-Fi to mobile data changes the next wake.

### 7.5 Tier selector per account (`chooseScheduledScope`)
- `({String scope, bool quickOutbox}) chooseScheduledScope(Map<String, Object?> cfg, Map<String, Object?> cache, DateTime now, {required bool hasPendingExcuses, required bool hasUnconfirmed})`; the app computes `hasPendingExcuses` with `pendingExcuseTasksFor(accCfg, accCache).isNotEmpty` (`app_state.dart:171`, the same list the screens show) and `hasUnconfirmed` from the account's `already_excused_lessons.unconfirmed.json`.
- Returns scope `'all'` when ANY of:
  1. `lastUpdatedTime(cache) == null` and `partUpdatedTime(cache, 'full') == null` (cold cache).
  2. Last full run (`part_updated['full'] ?? last_updated`) was on an earlier calendar day (first run of the day).
  3. Last full run is `>= 6 hours` old (~4 full runs per day).
  4. `hasUnconfirmed` AND `part_updated['outbox']` is missing or `>= 30 min` old.
  5. *(R8a S2)* The last full run did not finish its job: for an account with Bakaláři credentials, its outbox read failed (`part_updated['outbox']` missing or older than `part_updated['full']`; a Strava-only account has no outbox and skips this check), or the account's `scheduled_refresh_failed` stamp is set with `scheduled_refresh_failed_scope == 'all'` (new cache key written next to the stamp by `_markScheduledRefreshFailed`, `activity.dart:979–993`, and cleared with it; set for a failed fetch and for an automation error such as a failed auto-excuse). The retry then comes ~5 minutes later as a full run, as today.
- Otherwise returns scope `'quick'`, with `quickOutbox = hasPendingExcuses && (part_updated['outbox'] missing || ≥ 60 min old)` *(R8a M2)*.
- Tests: each of rules 1–5; `quickOutbox` true only with pending tasks and an outbox ≥ 60 min old; an excuse added to the fake outbox reaches the local history within 60 minutes of quick ticks while a task is pending; a quick tick with `quickOutbox` never calls `excusePending`, also in `auto` mode; no outbox read in quick ticks when nothing is pending.

### 7.6 Fixing `isAccountDueForRefresh` for 5/10-min intervals (`app/lib/controllers/activity.dart`)
- Today `isAccountDueForRefresh` uses `thresholdMin = intervalMinutes > 5.0 ? intervalMinutes - 5.0 : 0.0` (`activity.dart:17–29`), which makes a 5-minute account due on every runner fire.
- F6 updates it to:
  - Uses `lastCheckedTime(cache)` (instead of only `last_updated`).
  - Uses the account's own effective interval (its window, §7.2; the device's network kind).
  - `tolerance = intervalMinutes >= 30.0 ? 5.0 : (intervalMinutes * 0.1).clamp(0.25, 2.0)` (so 60 min keeps 55 min, 10 min uses 9 min, 5 min uses 4.5 min).
  - Returns `false` when the account's effective interval is `0` (paused off-hours) unless `now` reached its pre-alarm tick or `scheduled_refresh_failed` is set.

### 7.7 Pure Data-Usage Estimator (`estimateDataUsage`)
- `DataUsageEstimate estimateDataUsage(Map<String, Object?> cfg, {int accountCount = 1, bool persistentTls = false, double schoolDayHours = 10.0, bool useStrava = true})`:
  - Returns `{ mobileSchoolDayMb, wifiSchoolDayMb, typicalMonthlyMobileMb, allMobileMonthlyMb, requestsPerSchoolDay, effectiveWifiMin, effectiveMobileDayMin, effectiveOffHoursMin }`.
  - Uses the §2 per-tick sizes, the ~3.3 MB baseline (4 full runs) and the `quickOutbox` cost.
  - Deterministic, pure Dart, zero I/O, unit-tested against every row of the §2 table.

---

## 8. UI, Strings, & Tutorials

### 8.1 Settings → Rules (`app/lib/features/settings/settings_view.dart`)
Replace the single bare `check_interval_minutes` text field in `_rules` with a short **Kontroly a data / Checks and data** subsection (inside the Rules card, with `_sharedScopeCaption()` when multi-account). As little text as possible (owner D1):
1. **Fast check interval (`check_interval_minutes`, `Key('rule:interval')`):** keeps the existing `AutosaveField` (preserving existing tests) plus compact quick-pick chips (`5 min`, `10 min`, `15 min`, `60 min`). Label: `check_interval` on desktop and iOS (unchanged), `check_interval_wifi` on Android.
2. **Mobile-data daytime interval (`check_interval_mobile_minutes`, `Key('rule:interval_mobile')`, Android only):** `AutosaveField` (minutes) + the same chips, hint `rule_interval_mobile_hint`.
3. **Also at night and at weekends (`refresh_wifi_always_fast`, `Key('rule:wifi_always_fast')`):** `SwitchListTile`, `rule_wifi_always_fast` on Android, `rule_wifi_always_fast_desktop` on desktop; not on iOS.
4. **Off-hours interval (`check_interval_off_hours_minutes`, `Key('rule:interval_off_hours')`):** dropdown (`60`, `30`, `120` minutes via `rule_off_hours_every`, and `0` via `rule_off_hours_pause`). Always shown on Android (mobile data uses it off-hours); on desktop shown only while switch 3 is off; not on iOS.
5. **Live Estimated Data Usage panel (`Key('rule:data_estimate')`, Android and desktop):**
   - Android: `data_estimate_mobile`; desktop: `data_estimate_desktop`; plus `data_estimate_accounts` when > 1 `background_refresh` account.
   - `data_estimate_freshness` (marks, absences and timetable changes within ~N min; automatic excuses about 4× a day).
   - Android only: `data_estimate_doze`.
- **Platform checks** *(R8a N2)*: "Android only" means the Android platform check the app already uses for the phone background (`_isAndroid` in `startup.dart`), **not** `Strings.isMobile`, which is also true on iOS. iOS keeps only control 1 (it checks only while the app is open), with no estimate panel.

### 8.2 Ongoing Android notification, TopBar & Aktivita
- `PhoneBackground.sync()` (`startup.dart`) tracks all 4 schedule keys and the network kind, so changing any of them immediately re-arms the wake (§7.4) and updates the fallback text (`bg_notif_text` shows the school-hours interval for the current network: `check_interval_minutes` on Wi-Fi, the mobile interval on mobile data; never the `0` of a pause).
- `nextRunLabel` (`activity.dart`) shows the runner's `nextDueAt` (§7.4), including off-hours and pre-alarm transitions.
- Freshness labels as in §5.4; the Aktivita quick-check line as in §5.5.

### 8.3 Strings & Tutorials (PLAN Rules 5 & 7) *(R8a N7)*
Every new UI string goes into `app/lib/l10n/app_cs.arb`, `app/lib/l10n/app_en.arb` and `app/lib/l10n/strings.dart`; core strings into `packages/strakalari_core/lib/src/i18n.dart`. None of these keys exist today (checked at R8a). The texts below are the starting point; the agent may only shorten them.

| Key | Czech | English |
|---|---|---|
| `rule_refresh_title` | Kontroly a data | Checks and data |
| `check_interval_wifi` | Na Wi-Fi kontrolovat každých (min) | On Wi-Fi, check every (min) |
| `rule_interval_mobile` | Na mobilních datech kontrolovat každých (min) | On mobile data, check every (min) |
| `rule_interval_mobile_hint` | Ve školní dny od hodiny před první hodinou do 17:00. | On school days from an hour before the first lesson to 17:00. |
| `rule_interval_chip` | {n} min | {n} min |
| `rule_wifi_always_fast` | Na Wi-Fi kontrolovat i v noci a o víkendu | On Wi-Fi, also check at night and at weekends |
| `rule_wifi_always_fast_desktop` | Kontrolovat i v noci a o víkendu | Also check at night and at weekends |
| `rule_interval_off_hours` | Mimo školu kontrolovat | Outside school hours, check |
| `rule_off_hours_every` | každých {n} min | every {n} min |
| `rule_off_hours_pause` | nekontrolovat (jen před budíkem) | don't check (only before the alarm) |
| `data_estimate_mobile` | Odhad dat: asi {day} MB za školní den na mobilních datech (asi {month} MB za měsíc), {wifi} MB na Wi-Fi. | Estimated data: about {day} MB per school day on mobile data (about {month} MB a month), {wifi} MB on Wi-Fi. |
| `data_estimate_desktop` | Odhad dat: asi {day} MB za den (asi {month} MB za měsíc). | Estimated data: about {day} MB a day (about {month} MB a month). |
| `data_estimate_accounts` | (počet účtů: {n}) | (for {n} accounts) |
| `data_estimate_freshness` | Známky, absence a změny rozvrhu do {n} min. Automatické omluvenky asi 4× denně. | Marks, absences and timetable changes within {n} min. Automatic excuses about 4 times a day. |
| `data_estimate_doze` | Se zhasnutým displejem může Android kontroly trochu oddálit. | With the screen off, Android may delay checks a little. |
| `scope_quick` | Rychlá kontrola | Quick check |
| `activity_quick_checks` | Rychlé kontroly: {n}× dnes, poslední {time} | Quick checks: {n} today, last at {time} |
| `refresh_checked_full` | Kontrola: {checked} · Úplná: {full} | Checked: {checked} · Full: {full} |
| `quick_check_log` | Rychlá kontrola: beze změn. | Quick check: no changes. |
| core `status_checked` | Zkontrolováno {time} | Checked {time} |

- **Tutorials (`app/lib/tutorial/tours.dart`):** update `tut_settings_intro_body` / `tut_settings_intro_body_narrow` (cs & en) to mention how often the app checks and the data estimate under Rules, and `tut_activity_intro_body` (cs & en) to mention the quick-check line. Tests in `tutorial_test.dart`.

---

## 9. Step 4: Android Rhythm & Battery Measurement (Pixel 7 Pro `.test`)

Before handover for R8 code review:
1. Build `phonetest` APK (`io.github.dendlerx.strakalari.test`, Play app untouched) and install with `adb -s 2C221FDH3002NZ install -r`.
2. Run `tools/bakalari_demo_server.py --session-minutes 15` (extended with `/Marks/Widget`, the 3-field Komens callback, and the session lifetime of §6.3) on port `18080` with `adb reverse tcp:18080 tcp:18080`.
3. Configure `.test` to 5-min fast interval, verify initial full sync + subsequent quick ticks reuse the encrypted cookie without re-logging in (`bakalari_session.enc` present, demo server logs 0 extra `/Login` calls, 0 `/dashboard` calls, 0 `/Absence/Continuous` calls, 0 `GET /next/komens.aspx` calls on quick ticks), and that an hourly tick logs in exactly once.
4. Leave the Pixel screen off for ~60 minutes (resetting `dumpsys batterystats --reset` before), then capture into `build/qa-evidence/F6/`:
   - Actual tick count & gaps from Aktivita (quick-check line and rows) + demo server request log,
   - `dumpsys alarm` for `.test`,
   - `dumpsys batterystats io.github.dendlerx.strakalari.test`,
   - 390 px / 1280 px cs/en dark/light screenshots of Settings → Rules (with live data estimator), Activity (showing quick + full freshness), Marks, and Lunches.
5. Adjust the Android Doze wording in Settings if observed screen-off gaps differ a lot from 5–15 min.
6. **Battery** *(R8a N8)*: report the `.test` share of battery per screen-off hour in STATUS. If it is above 1 % per hour, stop and ask the owner whether night checks on Wi-Fi should be off by default (`refresh_wifi_always_fast: false`); don't change the default without the owner's answer.

---

## 10. Commit Plan & Test Matrix

Each commit lands with its own unit/widget tests (failing before the change, passing after) and keeps `dart analyze`, `dart test`, `flutter analyze`, and `flutter test` 100% green. Every existing send-path, excuse-history, lock and audit test stays unchanged and green; the only existing assertions that change are the two listed under commit 2.

1. **`F6: add low-data refresh config keys, schedule math, runner next-due provider, and data-usage estimator`**
   - Config keys (`check_interval_minutes: 5`, `check_interval_mobile_minutes: 5`, `check_interval_off_hours_minutes: 60`, `refresh_wifi_always_fast: true`), validation, `globalConfigKeys`, `config.example.json`, `parity/helpers.json` `roundTripFiles`, `refresh_schedule.dart` (window, effective interval, `nextScheduledWake`, `chooseScheduledScope`, estimator, `applyF6ScheduleDefaultsOnce`), `scheduler.dart` (`nextDueProvider`, `nextDueAt`, `_retryAt`).
   - Tests: `config_test.dart`, `accounts_test.dart`, `scheduler_test.dart` (§7.4), `refresh_schedule_test.dart` (school-day window 1 h before first lesson → 17:00, free days, Wi-Fi 24/7 vs off-hours, mobile clamping `max(wifi, mobile)`, off-hours pause `0` + pre-alarm tick, window-start clamp, multi-account window union, every `chooseScheduledScope` rule of §7.5, `applyF6ScheduleDefaultsOnce` cases of §3.3, estimator against every §2 row).
2. **`F6: implement Step 1 HTTP & Bakaláři free wins and Marks widget extractor`**
   - `http_session.dart` (§4.1, `idleTimeout`), `extractors.dart` (`extractMarksWidget`, `substitutionsByWeekHashes`, `absenceCountsIncreased`), `data.dart` (fetch order, direct `GetAbsenceBySubjects` + fallbacks, 3-field Komens callback with completeness check + page fallback, `fetchMarksWidget`, cached baseline), `timetable.dart` (`weekOffsetsOverride`), `FakeBakalari` + demo server (`/Marks/Widget`, 3-field callback, the default-period failure mode of §4.4).
   - Tests: `http_session_test.dart` (§4.1), `extractors_test.dart`, `bakalari_data_test.dart` (§4.2, §4.4, fetch order, cached baseline: days equal to a full run's).
   - **Explicit existing-test adaptations (2 assertions, documented upfront, both accepted at R8a):**
     - `packages/strakalari_core/test/http_session_test.dart:202` (`droppedConnectionIsRetriedOnceForReads`): `_FlakyTransport(server, 4)` → `3` and `expect(flaky.calls, 5)` → `4` because `login()` no longer makes the 3rd `GET /dashboard` call (the test still checks that a dropped read is retried once).
     - `packages/strakalari_core/test/bakalari_data_test.dart:791` (`parsesTheSubjectRows`): updates the `dateFrom` expectation from the HTML page's `'2026-09-01T00:00:00+02:00'` to the computed `'2026-09-01'` (under a fixed clock) and asserts zero `GET /Absence/Continuous` calls (plus new tests for the fallbacks).
3. **`F6: add Bakaláři session pool (3a) and encrypted cookie store (3b)`**
   - `session_store.dart`, `client.dart`, `automation.dart`, `error_report.dart`, `accounts.dart` (`forgetAllKeys`), `installer.iss`, the app's connection test and credential saves (`activity.dart`, `settings_controller.dart`, wizard), the session lifetime option of §6.3 in `FakeBakalari` and `tools/bakalari_demo_server.py`.
   - Tests: §6.1, §6.2 and §6.3 lists.
4. **`F6: add quick tier and per-part freshness to runRefresh`**
   - `cache.dart`, `refresh.dart`, `automation.dart`, `fake_bakalari.dart` (request counter).
   - Tests (`refresh_test.dart`, `cache_test.dart`, `automation_test.dart`):
     - Every tier makes **exactly** the expected requests (the request lists are what count; byte budgets on the fake's made-up sizes are informative only).
     - Quick tick **never** runs auto-excuse, even in `auto` mode and even with `quickOutbox`; without `quickOutbox` it never reads Komens.
     - Auto-excuse still runs only after a successful, complete outbox read in the same full run.
     - `automation_paused` stops auto-lunch on quick ticks and all auto phases on full runs.
     - New mark detected and notified in **one quick tick** via `/Marks/Widget` → `prubzna.aspx`; full runs read the widget before the marks page; a broken widget falls back loudly on the first failure and hourly after; a broken marks page is retried at most hourly.
     - Feed change for next week fetches **next week only**; after a full run, an unchanged feed fetches no week.
     - Absence `Count` growth fetches this week (and last week if back-dated) and notifies `new_absence`; an absence two weeks back is in the next scheduled full run's `timetableData`; `LessonCount` growth alone fetches no week.
     - Quick ticks leave `timetable_history` and `absence_counts_at_past_fetch` unchanged and never store `stable_baseline`.
     - Failed tier keeps cached data and leaves its `part_updated` stamp untouched; `last_updated` does not move on quick ticks; `part_updated['full']` moves exactly with it.
     - Scheduled full runs skip `perm`, subject dir, and past weeks once already fetched today unless a `Count` is above the snapshot.
     - A silent quick tick emits one log line (§5.3).
5. **`F6: wire Android metered-network detection, dynamic scheduling, and per-part freshness UI`**
   - `AndroidManifest.xml`, `StrakalariChannel.java`, `android_channel.dart`, `scheduler_jobs.dart`, `startup.dart`, `background.dart`, `activity.dart` (scope per account, `startRefresh`, due check, `_markScheduledRefreshFailed` scope, Aktivita quick-check line), `app_state.dart` (`networkKind`, `updatedLabelFor`, status inputs), `scaffold.dart`, feature `*_live.dart` freshness labels, `settings_live.dart`.
   - Tests: `android_background_test.dart`, `android_phone_background_test.dart`, `app_state_accounts_test.dart`, `activity_view_test.dart` (every call site of §7.4, 5-min `isAccountDueForRefresh` tolerance, dynamic `networkKind` switching, `chooseScheduledScope` quick vs full, per-part freshness display incl. the status notification and tooltip, the Aktivita rules of §5.5).
6. **`F6: add configurable refresh schedule, live data-usage estimator, and tutorial updates`**
   - `settings_view.dart`, `settings_controller.dart`, ARBs + `strings.dart` + core `i18n.dart`, `tours.dart`.
   - Tests: `settings_sections_test.dart` (controls per platform as §8.1), `strings_table_parity_test.dart`, `tutorial_test.dart`, plus 390/1280 px cs/en dark/light screenshots and Pixel 7 Pro `.test` evidence in `build/qa-evidence/F6/`.

---

## 11. Risks & Safety Checks

| Risk | Mitigation |
|---|---|
| Auto-excuse firing without a fresh outbox read | Scope lock: `effectiveScope != 'quick'` in `_autoPhases`, plus the existing `app.lastOutboxSyncOk == true` check; every existing send/history test stays unchanged and green. |
| A short Komens read (3 cached fields) silently covering less than the school year | Completeness check against every known excuse in the period, full-page fallback in the same run, weekly full-page reload, page on every manual refresh and first read; only a complete read sets `lastOutboxSyncOk` or settles unconfirmed submits (§4.4). |
| A manual excuse sent twice because an excuse sent elsewhere isn't known yet | While excuses are pending, quick ticks keep the outbox ≤ 60 min old (§5.3 1(e), §7.5); the send path itself is unchanged. |
| The schedule ignoring the pause or the window start, or every tick becoming a full run | One `nextScheduledWake` / `runner.nextDueAt` for every timer; `0` never reaches `nextDue`; `startRefresh` accepts `'quick'`; tests on the desktop runner and the headless wake (§7.4). |
| A failed full run or auto-excuse waiting 6 hours | Rule 5 of §7.5: the retry after a failed full run is a full run. |
| Upgraded install re-overwriting a later manual change to `60` min | `applyF6ScheduleDefaultsOnce` runs **only** when none of the 3 new F6 keys exist yet in `global.json` / `config.json`, re-checked under the lock; once written, it is a permanent no-op; runtime also clamps `mobileDay = max(check_interval_minutes, check_interval_mobile_minutes)`. |
| School Bakaláři lacking `/Marks/Widget` or changing its HTML | First broken tick logs loudly and falls back to `prubzna.aspx`; consecutive broken ticks throttle fallback to hourly so marks are never hidden for long and bandwidth never explodes. |
| A shared session used by two callers at once | Exclusive lending; connection tests never use the pool or the stored cookie (§6.1). |
| Leaking stored session cookies in logs or error reports | Never written to logs; encrypted with account Fernet key (`0600`, no plaintext fallback); deleted on password/URL/user change, login rejection, account delete, uninstall and `--forget-secrets`; scrubbed in `error_report.dart`. |
| `ConnectivityManager` reporting offline during loopback/VPN | `networkKind` only selects schedule cadence, never blocks or skips a refresh. |
| Android Doze stretching 5-min wakes with screen off, battery | Keep `setAndAllowWhileIdle` (never abuse `SCHEDULE_EXACT_ALARM` for polling), measure real 1-hour screen-off rhythm & battery on Pixel `.test`, state actual behavior in Settings, ask the owner above 1 %/h (§9). |
| Stale data looking fresh after a quick tick or failed tier | `last_updated` moves only on complete full runs; every screen, the status notification and the tooltip read their own stamp; failed phases never advance their stamp. |
| More (small) requests to the school's server on Wi-Fi day and night | ~920 a day vs ~670 today, far fewer bytes; owner accepted (Q2). |
| macOS / iOS native builds | Cannot be built on Windows 11; Dart code uses `mobilePlatform()` guards and stays marked *unverified* natively. |

---

## 12. Owner Decisions on Q1–Q3 (Answered 2026-11-22)

- **Q1 (Upgraded installs & 5-min default — answered):** *"It should get overwritten to the new default settings. And wifi should be 5 minutes 24/7. And we should make the 5 minutes default anyway."* → Defaults are `check_interval_minutes: 5`, `check_interval_mobile_minutes: 5`, `check_interval_off_hours_minutes: 60`, `refresh_wifi_always_fast: true`, applied once to pre-F6 installs via `applyF6ScheduleDefaultsOnce` (§3.3; recorded as an explicit owner-approved deviation from CONTRIBUTING §6's no-migration rule).
- **Q2 (24/7 5-min Wi-Fi — answered):** Confirmed `refresh_wifi_always_fast: true` default (5 min 24/7 on Wi-Fi, toggleable in Settings).
- **Q3 (Real-server measurement afterwards — answered):** *"We can do real account measurement afterwards as well, sure."* → Automated tests and Pixel `.test` verification use fakes and `bakalari_demo_server.py`; a standalone real-account measurement check follows after F6 code review passes. Its list: the MB per quick tick, full run and day (§2); that the 3-field Komens callback lists the whole school year (§4.4); whether a session renewal sends a new `Set-Cookie` (§6.2); that a new mark shows in the widget within one tick.
- The R8a fixes (2026-11-22) need no new owner decision: they keep the send path, the defaults and every D6 answer as they were.
