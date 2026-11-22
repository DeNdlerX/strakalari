# F6 design note: Low-data tiered refresh (towards every 5 minutes)

Status: **design note only, no F6 code written yet.** Written 2026-11-22 against `qa-roadmap` / `main` @ `617eb92` (after R7 passed and merged). Stops for review (`⛔ R8a`) before any code is written.

Sources: [`proposal-F6-low-data.md`](proposal-F6-low-data.md), [`research-F6-bakalari-web.md`](research-F6-bakalari-web.md) (Step 0 real-GEKOM web measurements), owner's D6 answers recorded word for word in [`STATUS.md`](STATUS.md) (2026-11-22), [`PLAN.md`](PLAN.md) §2 (Ground rules), and [`CONTRIBUTING.md`](../../CONTRIBUTING.md) §5–6.

---

## 1. Summary & Goals

Cut routine Bakaláři bandwidth by ~75–85% so Strakaláři can check for **new marks, new absences, and timetable changes every 5–10 minutes** while using **less data per day than today's hourly ~1 MB full refresh (~25 MB/day)**:

- **Step 1 — Free wins (zero freshness loss):** stop following the login `302` to the 49 KB `/dashboard`, compute the absence date range locally (`1 Sep → today`) instead of loading the 58 KB `/Absence/Continuous` page (with page fallback), fetch the permanent timetable (`perm`, 85 KB) and subject directory (4 KB) once per day, fetch past weeks (`-1 … -go_back_weeks`) once per day plus on-demand when an absence count grows, and post the Komens outbox callback with 3 cached hidden fields instead of loading the 207 KB `/next/komens.aspx?s=rok&l=o` page every run (with automatic full-page fallback). *(Komens detail caching is already done in F2 via `komens_outbox_details_v1`.)*
- **Step 2 & Step 5 — Tiered `runRefresh` pipeline:** add `scope: 'quick'` inside the single `runRefresh` pipeline. Quick ticks make only 3 tiny requests (~6–10 KB payload, ~18 KB total wire with headers + new TLS, or ~11 KB on a kept-alive connection):
  1. `GET /Marks/Widget` (2 KB) → loads `GET /next/prubzna.aspx` (187 KB) in the same tick **only** when the 5 newest marks changed (or on parse failure, logged loudly).
  2. `POST /Timetable/substitutions/dates` (3–5 KB) → loads `POST /Timetable/GetContentData` (50–85 KB) **only** for week(s) whose feed entries changed, plus an hourly daytime safety net for this week (to catch short-notice whole free days).
  3. `GET /Absence/Continuous/GetAbsenceBySubjects` (1.2–3 KB) → updates absence numbers immediately (**within 5 minutes**, D6 A3) and fetches this week's `GetContentData` if any subject's missed-lesson `Count` grew.
  - Full runs (`scope: 'all'`) run on cold start, first run of the day, every 6 hours (~3×/day), when an unconfirmed excuse needs settlement, and on every manual *Obnovit data*. **Auto-excuse runs ONLY in full runs after a fresh Komens outbox read in the same run** — never in a quick tick.
- **Step 3 — Session reuse (3a in-memory + 3b encrypted cookie file, D6 A5):** keep live `BakalariSession` + `HttpClient` (`idleTimeout: 6 min`) in a per-account in-memory pool (desktop & live Android UI isolate), and persist encrypted session cookies to `<accountDir>/bakalari_session.enc` using the account's existing Fernet key so Android headless wakes reuse the 15-minute sliding session without re-logging in on every 5–10 min tick.
- **Dynamic network-aware schedule & Settings data predictor (D6 A2, A4, A6):**
  - **On Wi-Fi / unmetered** (and desktop): **5 min 24/7** by default (`refresh_wifi_always_fast: true`), configurable.
  - **On mobile data (Android metered):** **10 min** (configurable to 5, 10, 15, …) during active school hours (**1 hour before first lesson → 17:00**, or end of last lesson if later), and **60 min** hourly overnight & on days off by default (`check_interval_off_hours_minutes: 60`; `0` = pause off-hours with one quick tick 30 min before the Wake-up alarm).
  - **Settings → Rules** gets clean, plain-language refresh schedule controls with a **live estimated data usage readout** (MB/school day on mobile & Wi-Fi, typical MB/month, honest Android Doze note).
- **Honest per-part freshness:** `data_cache.json` records `part_updated` timestamps per subsystem (`quick`, `full`, `timetable`, `stable_timetable`, `subject_directory`, `marks`, `absence`, `outbox`, `strava`) so every screen displays the true freshness of its own data and a failed tier never makes stale data look fresh.
- **Safety rules preserved (`CONTRIBUTING.md` §5):** one pipeline (`runRefresh`), one session lock (`<rootDir>/session.lock`), one send path (`Strakalari.sendExcuse` + `excuse_history.dart` + `HistoryLock`), everything audited (`audit.dart`, dry run included), `automation_paused` stops every tier's auto phase, Bakaláři web only (never `/api/3`), fail loudly.

---

## 2. Bandwidth & Request-Count Estimates (Answering D6 A2 & A6)

All sizes are taken directly from the real GEKOM measurements in [`research-F6-bakalari-web.md`](research-F6-bakalari-web.md) §2–9:
- Quick tick (session reused, new TLS handshake — Android headless): **~18 KB** (`Marks/Widget` 2 KB + `substitutions/dates` 4 KB + `GetAbsenceBySubjects` 2 KB + ~3 KB HTTP headers + ~7 KB TLS).
- Quick tick (session reused, kept-alive TLS — desktop / live Android UI): **~11 KB**.
- Quick tick (session expired, gap ≥ 15 min — new login without `/dashboard`): **~26 KB** (+6 KB `GET /login` + 1.5 KB `POST /Login` `302`).
- Note on Bakaláři's 15-minute sliding session (`research-F6-bakalari-web.md` §5.1): requests in the second half (> 7.5 min, < 15 min) renew it to 15 min. Both **5-min** ticks (every 2nd tick at 10 min renews) and **10-min** ticks (every tick at 10 min renews) keep the session alive without extra logins.
- School-day baseline (non-quick-tick traffic, 10h school window 07:00–17:00):
  - Triggered `prubzna.aspx` on new marks (~3× 187 KB): **0.56 MB**
  - Triggered changed timetable weeks (~3× 70 KB): **0.21 MB**
  - Hourly daytime safety net for this week (10× 65 KB): **0.65 MB**
  - Strava every 30 min daytime + pre-cutoff (~24× 6 KB): **0.14 MB**
  - Full runs: first of day (~640 KB with `perm`, subject dir, past weeks) + 2 routine full runs (~340 KB each with cached Komens 3 fields & details): **1.32 MB**
  - **Baseline subtotal:** **~2.9 MB / school day** (days off: **~1.3 MB / day**).

| Scenario (1 account, 10h school day: 1h before 8:00 = 07:00 → 17:00) | Quick ticks / day | Total / school day | Typical mobile / month* | 100% mobile / month | School requests / day |
|---|---|---|---|---|---|
| **Today (hourly full refresh)** | 24 full | **~25 MB** | ~250 MB | ~750 MB | ~672 (heavy) |
| **Mobile 5 min daytime + 60 min off-hours** | 120 + 14 | **~5.4 MB** | **~75 MB** | ~130 MB | ~460 (tiny) |
| **Mobile 10 min daytime + 60 min off-hours** *(default mobile)* | 60 + 14 | **~4.4 MB** | **~55 MB** | ~105 MB | ~280 (tiny) |
| **Wi-Fi 5 min 24/7** *(default Wi-Fi)* | 288 | **~8.1 MB** (~6.1 MB kept-alive) | **0 MB** | — | ~920 (tiny) |
| **Wi-Fi 5 min daytime + 60 min off-hours** (`refresh_wifi_always_fast: false`) | 120 + 14 | **~5.4 MB** (~4.5 MB kept-alive) | **0 MB** | — | ~460 (tiny) |

*\*Typical mobile/month assumes mobile data during the 10 daytime hours on ~21 school days/month and Wi-Fi at home/weekends. Multi-account installs multiply linearly by the number of `background_refresh: true` accounts.*

All mobile configurations stay well below `proposal-F6-low-data.md` §6's ≤ 8 MB/day target (4.4 MB/day at 10 min, 5.4 MB/day at 5 min).

---

## 3. Configuration Keys (PLAN Rule 4 & F4 Shared Split)

All schedule keys live in `<rootDir>/global.json` (`globalConfigKeys` in `packages/strakalari_core/lib/src/storage/accounts.dart`) because one device / scheduler wakes on one rhythm.

### 3.1 Existing & new canonical keys (3 new keys; total canonical keys 74 → 77, `globalConfigKeys` 19 → 22)

| Key | Type | Default | Validation (`config.dart`) | Meaning |
|---|---|---|---|---|
| `check_interval_minutes` *(existing)* | `num` | **`5`** *(was `60`)* | `>= 1` | Fast check interval in minutes (Wi-Fi / desktop; also the lower bound for mobile). Existing installs with `60` saved on disk keep `60` untouched (see §12 Q1). |
| `check_interval_mobile_minutes` *(new)* | `num` | **`10`** | `>= 1` | Daytime check interval in minutes on mobile data (Android metered). Runtime uses `max(check_interval_minutes, check_interval_mobile_minutes)` so mobile never polls faster than Wi-Fi (protects upgraded installs with `check_interval_minutes: 60`). |
| `check_interval_off_hours_minutes` *(new)* | `num` | **`60`** | `== 0 || >= 1` (i.e. `>= 0` and not in `(0, 1)`) | Off-hours / overnight & day-off check interval in minutes. `0` = pause off-hours (with one quick tick 30 min before the Wake-up alarm if enabled); `>= 1` = check every N minutes (default `60` per D6 A4). |
| `refresh_wifi_always_fast` *(new)* | `bool` | **`true`** | `is bool` | When `true`, Wi-Fi / unmetered connections keep using `check_interval_minutes` 24/7 including nights and weekends (D6 A6). When `false`, Wi-Fi also slows to `check_interval_off_hours_minutes` outside school daytime hours and on days off. |

### 3.2 Files updated in the same commit (PLAN Rule 4)
1. `config.example.json` (add the 3 new keys; update `check_interval_minutes` to `5`).
2. `packages/strakalari_core/lib/src/storage/config.dart` (`canonicalDefaults` + `validateConfig`).
3. `packages/strakalari_core/lib/src/storage/accounts.dart` (add the 3 new keys to `globalConfigKeys`).
4. `packages/strakalari_core/test/parity/helpers.json` (`roundTripFiles` — add the 3 new keys to the two full canonical config snapshots only; keep `check_interval_minutes: 60` unchanged inside those two snapshots since they are saved-config round-trips).
5. `packages/strakalari_core/test/config_test.dart` and `packages/strakalari_core/test/accounts_test.dart`.

---

## 4. Step 1: Free Wins in Bakaláři HTTP & Client

### 4.1 Login without downloading `/dashboard` (`http_session.dart`)
- In `BakalariSession.login()`:
  - `GET /login` uses `followRedirects: false` (following at most 5 redirects ONLY if the redirect `Location` still points to `/login`, e.g. `http → https` or `/login?ReturnUrl=…`). If `GET /login` redirects to a non-login path (e.g. `/dashboard`), the session cookie is already valid → set `loggedIn = true`, record `_lastActivityAt = clock.now()`, and return without fetching `/dashboard`.
  - `POST /Login` uses `followRedirects: false`. `_storeCookies(resp)` already captures every `Set-Cookie` on the `302`.
    - If `301/302/303/307/308`: resolve `Location` against the POST URL.
      - If the resolved path ends with `/login` (case-insensitive, trailing `/` stripped): follow it with one `GET` so `loginErrorText(resp)` extracts any error message, set `loggedIn = false`, clear stored session cookie, and throw `UserError(bak_login_rejected)`.
      - Otherwise (redirected away from `/login`): login succeeded! Set `loggedIn = true`, record `_lastActivityAt = clock.now()`, invoke cookie-persisted hook, and return immediately without loading `/dashboard`.
    - If `200`: keep the exact `isLoginPage(resp)` rejection check (wrong password returns `200` with error markup on both real Bakaláři and `FakeBakalari`).
  - `sendOnce()` (excuse post) is **completely untouched**.

### 4.2 Absence without loading `/Absence/Continuous` (`data.dart`)
- In `DataMixin.obtainAbsenceInfo()`:
  - Compute the school year range locally using `schoolYearTerms(today)[0].$2` (`YYYY-09-01`, previous year if `today.month < 9`) through `today` (`YYYY-MM-DD`).
  - Call `GET /Absence/Continuous/GetAbsenceBySubjects?dateFrom=<iso>&dateTo=<iso>&lateChecked=false&schoolChecked=false&soonChecked=false` directly.
  - **Fail-loud fallback:** if that request throws (other than `CancelledError`) OR `storeRows(rows) == null`, log `Warning: direct GetAbsenceBySubjects failed ($e); falling back to /Absence/Continuous` and run the legacy path (`GET /Absence/Continuous` → `absenceDateRange(page)` → `GetAbsenceBySubjects`) once.
  - Only if both fail: clear `absencePercentages = {}`, `absenceDetails = {}`, and set `absenceError`.

### 4.3 Permanent timetable (`perm`) & subject directory once per day (`data.dart`, `timetable.dart`, `refresh.dart`)
- `DataMixin.fetchData()` gains optional parameters with backward-compatible defaults (so direct callers and all existing tests behave identically):
  - `List<int>? weekOffsetsOverride` (null = standard `weekOffsets(goBackWeeks, goForwardWeeks)` + `historyWeeks`).
  - `bool fetchStable = true` (when `false`, seeds `stableBaseline` from optional `cachedStableBaseline` + `cachedStableComplete` so `updateStableBaseline()` still diffs loaded weeks against the real scraped baseline).
  - `bool fetchSubjects = true`.
  - `bool fetchMarks = true`.
  - `bool fetchMarksWidget = false` (set `true` by `runRefresh` on full runs so the 2 KB widget baseline is primed right after `getGrades()`).
- In `runRefresh` for **scheduled full runs** (`scheduled: true`):
  - Skip `perm` when `part_updated['stable_timetable']` is from today AND cached `stable_baseline` is non-empty with `stable_baseline_source == 'scraped'`.
  - Skip `/Teaching/Subjects` when `part_updated['subject_directory']` is from today AND cached `subject_directory` is non-empty.
  - Skip past regular weeks (`-1 … -goBackWeeks`) when `timetable_history.past_weeks_fetched == todayIso` AND all past regular Mondays are already in `timetable_history.weeks` AND no subject's absence `Count` increased since cached `absence_details`. (Note: in a scheduled full run, `obtainAbsenceInfo()` runs **before** `fetchTimetableWeeks()` so a newly increased absence `Count` can immediately pull `-1 … -goBackWeeks` in the same run!)
- On **manual full runs** (`scheduled: false`) or first run of the day: fetch everything fresh (no daily skipping).

### 4.4 Komens list callback with 3 cached hidden fields (`data.dart`, `cache.dart`)
- Cache key in `data_cache.json`: `const String outboxFormKey = 'komens_outbox_form_v1';`
  ```json
  {
    "path": "/next/komens.aspx?s=rok&l=o",
    "viewstate": "...",
    "viewstate_generator": "...",
    "event_validation": "...",
    "period_start": "2026-09-01",
    "fetched_at": "2026-11-22T07:05:00"
  }
  ```
- Not a secret (`research-F6-bakalari-web.md` §6.1: useless without the session cookie, and survives across new logins).
- `DataMixin.fetchAllOutboxIds` checks cached `knownOutboxForm` when:
  - `knownOutboxForm` is valid (`path == _outboxYearPath`, all 3 fields non-empty, `period_start` is a valid ISO date `>= schoolYearStart(today)`), AND
  - `fetched_at` is `< 7 days` old, AND
  - `forceReloadOutboxPage` is `false` (manual refresh sets `forceReloadOutboxPage: false` too — wait: or `true` only if older than 7 days so even manual refresh saves 204 KB unless stale/failed, while invalidating immediately on any callback rejection!).
- **Cached callback path:** sends `POST /next/komens.aspx?s=rok&l=o` with `[('__VIEWSTATE', ...), ('__VIEWSTATEGENERATOR', ...), ('__EVENTVALIDATION', ...), ('__CALLBACKID', _outboxCallbackId), ('__CALLBACKPARAM', 'c0:$param')]`.
- **Fail-safe self-healing fallback:**
  - If page 1's cached callback throws (`ArgumentError` on `0|/*DX*/({'redirect':'/dashboard?e='})`, `StateError` on callback error or missing `komens-messages-wrapper`, or HTTP error — never `CancelledError`), log loudly (`Komens cached form fields rejected ($e); reloading outbox page`), clear `knownOutboxForm`, and **retry once from scratch with full `GET /next/komens.aspx?s=rok&l=o`** (`hfListType == 'odeslane'` verified + `cphmain_obdobiLabel` parsed + full form fields).
  - If the full-page path succeeds, extract `__VIEWSTATE`, `__VIEWSTATEGENERATOR`, `__EVENTVALIDATION`, and `period_start` from the page HTML and store them in `knownOutboxForm` (persisted to `data_cache.json` only when `lastOutboxSyncOk == true`).
  - If page 2+ fails OR the full-page fallback fails: abort the entire outbox read (`sentExcuses = null`, `lastOutboxSyncOk = false`, `knownOutboxForm` not updated) — **zero partial success, auto-excuse blocked**.

---

## 5. Step 2 & Step 5: Quick Tier, `/Marks/Widget`, & Per-Part Freshness

### 5.1 `/Marks/Widget` parser (`extractors.dart`) & fetcher (`data.dart`)
- `List<Map<String, Object?>>? extractMarksWidget(Object? htmlString)`:
  - Tri-state return:
    - `null`: HTML does not contain `class="[^"]*\bbk-widget-marks\b` (wrong page, 404/error, or changed Bakaláři markup) → parse failure.
    - `[]`: valid `bk-widget-marks` container with zero `.mark-line` items (student has no marks yet).
    - `List<Map<String, Object?>>`: ordered entries `{ 'grade': ..., 'subject': ..., 'note': ..., 'date': ..., 'is_new': bool }`, extracted from `.mark-line` spans (`mark-displayGrade`, `mark-subjectName`, `mark-note`, `mark-date`), HTML-unescaped and whitespace-normalized. `is_new` is `true` iff `mark-displayGrade`'s class list contains `isnew` (case-insensitive).
- `DataMixin.fetchMarksWidget()` calls `GET /Marks/Widget`, parses via `extractMarksWidget`, and returns the tri-state result (catching non-cancel errors, logging loudly, and returning `null`).
- Cache key in `data_cache.json`: `const String marksWidgetKey = 'marks_widget_v1';` (the last parsed list) and `const String marksWidgetFailedKey = 'marks_widget_failed_at';` (ISO timestamp if widget is currently broken, cleared on next valid parse).

### 5.2 Per-week substitution feed hashes & absence growth (`extractors.dart`)
- `Map<String, String> substitutionsByWeekHashes(List<Map<String, Object?>> feed, List<DateTime> weekMondays)`:
  - Buckets feed entries by Monday (`YYYY-MM-DD`, using `parseCzDate(entry['day'])`), sorts entries canonically within each week, and computes SHA-256 hex digest per Monday in `weekMondays` (empty week = SHA-256 of `'[]'`).
  - Cache key in `data_cache.json`: `const String substitutionsWeekHashesKey = 'substitutions_week_hashes_v1';`.
- `bool absenceCountsIncreased(Map<String, Object?>? previousDetails, Map<String, Object?> freshDetails)`:
  - Returns `true` iff any subject in `freshDetails` has `missed_hours` (`int`, from Bakaláři `Count`) strictly greater than `previousDetails[subject]['missed_hours']` (default `0`), ignoring `LessonCount` (`total_hours`).

### 5.3 The single `runRefresh` pipeline (`refresh.dart`)
- `const List<String> refreshScopes = ['all', 'bakalari', 'strava', 'quick'];`
- Add optional `bool scheduled = false` parameter to `runRefresh(...)` (default `false` so all existing callers and tests keep exact manual behavior!).
- When `scope == 'quick'`:
  1. **Bakaláři quick check** (if `hasBak`):
     - Reads existing cache (`previousCache = loadDataCache(dataDir: effectiveDataDir)`).
     - Logs in (reusing live/stored session when valid — **0 login requests** during 5–10 min ticks).
     - **(a) Marks signal:** calls `fetchMarksWidget()`.
       - If valid (`widget != null`): clears `marks_widget_failed_at`. Compares `widget` with `previousCache[marksWidgetKey]` via `jsonEquals`.
         - If different (or `previousCache[marksWidgetKey]` missing): calls `getGrades()`. If `gradesError == ''`, puts `grades`, `quarterly_marks`, `marksWidgetKey: widget`, and stamps `part_updated['marks'] = nowIso`! If `getGrades()` failed, does **not** update `marksWidgetKey` or `part_updated['marks']` (retries next tick).
         - If identical: skips `prubzna.aspx`, stamps `part_updated['marks'] = nowIso` (confirmed unchanged by widget).
       - If parse/HTTP failed (`widget == null`): logs loudly. If `previousCache[marksWidgetFailedKey]` is absent (first failure) OR `part_updated['marks']` is missing / ≥ 60 min old → falls back to `getGrades()` on **this tick** (so a broken widget never hides marks, while a permanently unsupported school throttles fallback to hourly instead of burning 54 MB/day). Stamps `marksWidgetFailedKey: nowIso`.
     - **(b) Substitution feed:** calls `fetchSubstitutions()`.
       - Computes `freshHashes` for `[thisMonday, … thisMonday + goForwardWeeks]`.
       - Any week whose hash differs from `previousCache[substitutionsWeekHashesKey]` (or is missing) is queued in `weeksToFetch`.
       - Also if currently in daytime school hours (`activeDayWindow(previousCache, cfg, started) != null`) and `part_updated['timetable']` is missing or ≥ 60 min old → queues `thisMonday` (hourly safety net for short-notice whole free days).
     - **(c) Absence numbers:** calls `obtainAbsenceInfo()` (direct 1.2–3 KB JSON; page fallback only on failure).
       - If `absenceError == ''`: puts `absence`, `absence_details`, stamps `part_updated['absence'] = nowIso`.
       - If `absenceCountsIncreased(previousCache['absence_details'], absenceDetails)` → queues `thisMonday` in `weeksToFetch`!
     - **(d) Conditional week fetch:** if `weeksToFetch` is non-empty:
       - Loads cached `stable_baseline` (`stable_baseline_source == 'scraped'`) into client.
       - Fetches ONLY `weeksToFetch` via `timetableView('cal', monday)`.
       - Runs `updateStableBaseline()` (applying fresh `substitutions` feed + `backfillStableFacts` + `iterChanges`).
       - If absence count grew and `newAbsences(previousCache, {'timetable': timetableData})` is empty and `lastMonday` wasn't fetched yet (e.g. teacher entered a Friday absence on Monday): fetches `lastMonday` (`addDays(thisMonday, -7)`) once and re-runs `updateStableBaseline()`.
       - Puts `timetable` into `fresh` (merged day-granularly by `_persist`), updates `substitutionsWeekHashesKey` **only** for unchanged or successfully loaded weeks, and stamps `part_updated['timetable'] = nowIso`.
       - If no weeks needed fetching and feed succeeded: updates `substitutionsWeekHashesKey` (unchanged) and puts `substitutions` into `fresh`.
     - **NEVER reads Komens outbox.** `lastOutboxSyncOk` remains `false`.
     - Stamps `part_updated['quick'] = nowIso` if marks signal, feed, and absence all succeeded without error.
  2. **Strava conditional check** (if `app.stravaEnable && hasStrava`):
     - Fetches Strava **only** when `stravaQuickFetchDue(previousCache, cfg, started)` is `true`:
       - `part_updated['strava']` is missing; OR
       - During daytime active window: `part_updated['strava']` is ≥ 30 min old; OR
       - Outside daytime window: `part_updated['strava']` is ≥ 60 min old; OR
       - Within 60 min before today's `resolveLunchCutoff(cfg)` and `part_updated['strava']` is ≥ 15 min old.
     - On success: updates `strava_meals`, `strava_ordered`, `strava_status: 'ok'`, stamps `part_updated['strava'] = nowIso`. On failure: records error in `result.errors` without advancing `part_updated['strava']`.
  3. **Auto phases (`_autoPhases`):**
     - **Double lock on auto-excuse:** `wantsExcuse = effectiveScope != 'quick' && result.bakalariFetched && app.excuseMode == 'auto'`. Quick ticks NEVER run auto-excuse and NEVER emit `auto_excuse_outbox_unknown`.
     - Auto-lunch order & F3 auto-cancel run **only** when `result.stravaFetched` (i.e. Strava actually fetched in this tick) and `!automationPaused(cfg)`.
  4. **News & Persist:**
     - `findNews(previousCache, fresh, today)` compares only keys present in `fresh` (`grades`, `quarterly_marks`, fetched `timetable` days) against `previousCache` — firing immediate notifications for new marks, new absences, and timetable changes without false positives!
     - `fresh['last_updated']` is **NOT** touched by `quick` (it stays the timestamp of the last complete `'all'` run); `fresh['part_updated']` merges updated part timestamps over `previousCache['part_updated']`.

### 5.4 Honest per-part freshness (`cache.dart` & UI)
- New constants & helpers in `packages/strakalari_core/lib/src/storage/cache.dart`:
  - `const String partUpdatedKey = 'part_updated';`
  - `DateTime? partUpdatedTime(Map<String, Object?>? cache, String part)` (reads `cache['part_updated'][part]`, falling back to `lastUpdatedTime(cache)` for pre-F6 caches).
  - `DateTime? lastCheckedTime([Map<String, Object?>? cache])` (newest of `part_updated['quick']`, `part_updated['full']`, and `last_updated`).
  - `String describeCacheForPart(Map<String, Object?>? cache, String part, [num ttlHours = 24])` (formats the part's own timestamp + age + stale badge; falls back to `describeCache` if `part_updated` is absent).
- UI mapping (`app_state.dart` helper `updatedLabelFor(String part)`):
  - **Today (`today_live.dart`):** `updatedLabelFor('quick')`
  - **Timetable (`timetable_live.dart`):** `updatedLabelFor('timetable')`
  - **Marks (`marks_live.dart`):** `updatedLabelFor('marks')`
  - **Absences (`absences_live.dart`):** `updatedLabelFor('absence')`
  - **Lunches (`lunches_live.dart`):** `updatedLabelFor('strava')`
  - **Activity (`activity_live.dart`) & Diagnostics (`settings_live.dart`):** shows `last_updated` (full refresh); when `part_updated['quick']` is newer than `part_updated['full']`, formats `Kontrola: HH:MM · Úplná: DD.MM. HH:MM` / `Checked: HH:MM · Full: DD.MM. HH:MM`.
  - `startupSeed(cache)` uses `lastCheckedTime(cache)` so quick ticks satisfy the scheduler timer on restarts/reboots without falsely moving `last_updated`.

---

## 6. Step 3: Session Reuse (3a In-Memory + 3b Encrypted Cookie Store)

### 6.1 Step 3a — In-memory session & TCP/TLS keep-alive pool
- `DartIoHttpTransport` (`http_session.dart`): add optional `Duration idleTimeout = const Duration(seconds: 15)` constructor argument setting `_client.idleTimeout = idleTimeout`.
- New file `packages/strakalari_core/lib/src/bakalari/session_store.dart`:
  - `BakalariSessionPool` (process-wide singleton with `resetForTesting()`):
    - Key: `(normalizedDataDir ?? '', appRoot(url), username)`.
    - Stores `BakalariSession` created with `DartIoHttpTransport(idleTimeout: const Duration(minutes: 6))` (matching `research-F6-bakalari-web.md` §8: school IIS keeps idle sockets ≥ 10 min; 6 min spans 5-min ticks to skip the ~7 KB TLS handshake on desktop & live Android UI).
    - Also remembers `passwordDigest` (`sha256` of ciphertext/plaintext password) and `lastActivityAt`.
    - On checkout: if `passwordDigest` changed → close & evict old session + delete on-disk `bakalari_session.enc`.
    - Explicit `evict(dataDir)` / `closeAll()` called on credential save in Settings, account deletion, `--forget-secrets`, and desktop `onQuit`.
    - Callers passing an explicit `transport` (tests with `FakeBakalari`) always bypass the pool.
  - `Strakalari.close()`: closes `stravaClient`, and closes `bakalariClient` **only** when `bakalariClient` owns its session (not checked out from the pool), leaving pooled `HttpClient` sockets alive between ticks.

### 6.2 Step 3b — Encrypted on-disk cookie store (`<accountDir>/bakalari_session.enc`)
- Approved by owner in D6 A5 (`"Yes, store it encrypted like passwords"`).
- **Path:** `p.join(effectiveDataDir, 'bakalari_session.enc')` (per-account folder, so F4 account deletion automatically wipes it; also cleaned by `AccountManager.forgetAllKeys` and `installer.iss` uninstall).
- **Encryption:** Fernet-encrypted with the account's existing key (`encrypt(json, dataDir: dataDir)` from `secret_store.dart`, using Android Keystore / iOS Keychain / DesktopKeyStore — never plaintext). If encryption throws (`KeyStoreUnavailable`), log a warning and skip disk persistence (never write plaintext cookies). File written atomically with `0600` permissions on POSIX.
- **Payload (inside Fernet ciphertext):**
  ```json
  {
    "v": 1,
    "root": "https://bakaweb.gekom.cz",
    "username": "student",
    "password_sha256": "<hex>",
    "cookies": {"BakaAuth": "...", "ASP.NET_SessionId": "..."},
    "last_activity_at": "2026-11-22T09:10:00Z"
  }
  ```
- **Load & expiry rules:**
  - Decrypt with `decryptStrict(..., dataDir: dataDir, fallbackKeyDir: fallbackKeyDir)`. Corrupt/unreadable → delete file, log debug line, log in fresh.
  - Mismatch on `root`, `username`, or `password_sha256` → **delete `bakalari_session.enc` immediately** and log in fresh.
  - Age check (`clock.now().toUtc().difference(lastActivityAt)`): if `>= 15 minutes` or `<-2 minutes` (clock skew) → treat as expired (Bakaláři sessions die at 15 min, `research-F6-bakalari-web.md` §5.1) and log in fresh directly without wasting a round-trip.
  - Otherwise seed `BakalariSession` cookies (`loggedIn = true`).
- **Update & invalidation:**
  - `BakalariSession` exposes `void Function(Map<String, String> cookies, DateTime at)? onCookiesChanged`: called after every response carrying `Set-Cookie` (captures sliding-window cookie renewals in the second half of the 15-min window!) and after successful login/requests, persisting `bakalari_session.enc` immediately.
  - On `bak_login_rejected` (invalid password) or credential edit/clear → **delete `bakalari_session.enc` immediately**.
- **Redaction (`error_report.dart`):**
  - Never log cookie values or `bakalari_session.enc` contents.
  - Add cookie redaction to `error_report.dart`:
    1. `allAccountSensitiveValues` also reads any active pooled session cookies and (best-effort) decrypts `<accountDir>/bakalari_session.enc` cookie values (length ≥ 6) so every live/stored cookie value is replaced with `***`.
    2. `redactText` additionally scrubs raw `Cookie: …` and `Set-Cookie: …` header values via regex as defense in depth.

---

## 7. Dynamic Scheduling, Multi-Account, & Data-Usage Estimator

New pure-Dart module: `packages/strakalari_core/lib/src/automation/refresh_schedule.dart` (exported from `strakalari_core.dart`).

### 7.1 Network classification
- `enum NetworkKind { unmetered, metered, unknown }`
- Desktop (Windows, macOS, Linux) and iOS: always `NetworkKind.unmetered`.
- Android:
  - Add `<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />` to `app/android/app/src/main/AndroidManifest.xml` (normal install-time permission, no runtime prompt).
  - Add `networkKind` method to `StrakalariChannel.java` + `AndroidChannel.networkKind()`:
    - Uses `ConnectivityManager.getActiveNetwork()` + `getNetworkCapabilities(net)`.
    - `NET_CAPABILITY_INTERNET` + `NET_CAPABILITY_NOT_METERED` → `'unmetered'` (Wi-Fi / unmetered Ethernet).
    - `NET_CAPABILITY_INTERNET` without `NET_CAPABILITY_NOT_METERED` → `'metered'` (mobile data / metered hotspot).
    - Otherwise → `'unknown'`.
  - **Important safety rule:** `networkKind` is used **only** to choose the polling cadence (`unmetered` vs `metered`, with `unknown` conservatively treated as `metered` on Android). It **never blocks** a refresh (so loopback `adb reverse` testing and VPNs always work).

### 7.2 Active school-day window (`activeDayWindow`)
- Uses `effectiveCalendar(config, clip: false).dates` and `wakeup.dart` (`indexDays`, `periodSlots`, `lessonsFor`, `firstLesson` with `planned: const []` so a planned skip doesn't hide school hours, `clockOf`, `isCancelledLesson`).
- For a given calendar `day`:
  - If `day` is in `freeDays` or (weekend with no non-cancelled lessons) or has 0 non-cancelled lessons (when timetable/baseline exists) → returns `null` (**day off**).
  - If timetable & baseline are both empty (cold install): Mon–Fri defaults to `07:00–17:00`, Sat–Sun returns `null`.
  - Otherwise:
    - `start` = `max(05:00, firstLessonStart - 60 min)` (1 hour before first lesson, D6 A2).
    - `end` = `max(17:00, lastLessonEnd)` (17:00, or end of last lesson if later, D6 A2).
- **Multi-account:** `combinedActiveDayWindow(accountCachesAndConfigs, day)` takes the union across all `background_refresh: true` configured accounts (earliest `start` to latest `end`).

### 7.3 Effective interval & next wake time
- `double effectiveCheckIntervalMinutes(Map<String, Object?> cfg, Map<String, Object?> cache, NetworkKind network, DateTime now)`:
  - `wifiFast = max(1.0, check_interval_minutes)` (default `5.0`)
  - `mobileDay = max(wifiFast, max(1.0, check_interval_mobile_minutes))` (default `10.0`)
  - `offHours = check_interval_off_hours_minutes` (`0.0` = paused, else `max(1.0, v)`, default `60.0`)
  - `wifiAlwaysFast = cfg['refresh_wifi_always_fast'] != false` (default `true`)
  - On `NetworkKind.unmetered`: returns `wifiFast` if `wifiAlwaysFast`, else (`inWindow ? wifiFast : offHours`).
  - On `NetworkKind.metered` / `unknown`: returns `inWindow ? mobileDay : offHours`.
- `DateTime nextScheduledWake(DateTime? lastChecked, Map<String, Object?> cfg, Map<String, Object?> cache, NetworkKind network, DateTime now)`:
  - When `effectiveInterval > 0`: computes `candidate = nextDue(lastChecked, effectiveInterval, now)`. If currently outside the active window and today's window starts **before** `candidate`, clamps `candidate` to today's window start so fast checks begin right at `firstLesson - 60 min` instead of overshooting!
  - When `effectiveInterval == 0` (user opted into off-hours pause): finds the earliest of:
    1. Next `activeDayWindow` start (today or up to 14 days ahead), and
    2. If `wakeup_enabled`: `nextWakeupAlarm(timetable, config: cfg, now: now).alarmDt - 30 min` (pre-alarm quick tick so a cancelled first lesson updates the alarm before it rings!).
    - Fallback if neither exists within 14 days: `now + 6 hours`.

### 7.4 Tier selector per account (`chooseScheduledScope`)
- Returns `'all'` when ANY of:
  1. `lastUpdatedTime(cache) == null` and `partUpdatedTime(cache, 'full') == null` (cold cache).
  2. Last full run (`part_updated['full'] ?? last_updated`) was on an earlier calendar day (first run of the day).
  3. Last full run is `>= 6 hours` old (~3 full runs per day).
  4. Account has unconfirmed excuses on disk (`already_excused_lessons.unconfirmed.json` non-empty) AND `part_updated['outbox']` is missing or `>= 30 min` old.
- Otherwise returns `'quick'`.

### 7.5 Fixing `isAccountDueForRefresh` for 5/10-min intervals (`app/lib/controllers/activity.dart`)
- Today `isAccountDueForRefresh` uses `thresholdMin = intervalMinutes > 5.0 ? intervalMinutes - 5.0 : 0.0`, which would make a 5-minute account permanently due (0-minute threshold!).
- F6 updates it to:
  - Uses `lastCheckedTime(cache)` (instead of only `last_updated`).
  - `tolerance = intervalMinutes >= 30.0 ? 5.0 : (intervalMinutes * 0.1).clamp(0.25, 2.0)` (so 60 min keeps 55 min, 10 min uses 9 min, 5 min uses 4.5 min).
  - Returns `false` when `effectiveInterval == 0` (paused off-hours) unless `now` reached the pre-alarm tick or `scheduled_refresh_failed` is set.

### 7.6 Pure Data-Usage Estimator (`estimateDataUsage`)
- `DataUsageEstimate estimateDataUsage(Map<String, Object?> cfg, {int accountCount = 1, bool persistentTls = false, double schoolDayHours = 10.0, bool useStrava = true})`:
  - Returns `{ mobileSchoolDayMb, wifiSchoolDayMb, typicalMonthlyMobileMb, allMobileMonthlyMb, requestsPerSchoolDay, effectiveWifiMin, effectiveMobileDayMin, effectiveOffHoursMin }`.
  - Deterministic, pure Dart, zero I/O, unit-tested against the §2 table.

---

## 8. UI, Strings, & Tutorials

### 8.1 Settings → Rules (`app/lib/features/settings/settings_view.dart`)
Replace the single bare `check_interval_minutes` text field in `_rules` with a clear **Refresh & Data** subsection (inside the Rules card, with `_sharedScopeCaption()` when multi-account):
1. **Fast check interval (`check_interval_minutes`, `Key('rule:interval')`):** keeps the existing `AutosaveField` (preserving existing tests!) plus compact quick-pick chips (`5 min`, `10 min`, `15 min`, `60 min`).
2. **Mobile-data daytime interval (`check_interval_mobile_minutes`, `Key('rule:interval_mobile')`, Android only):** `AutosaveField` (minutes) + quick chips (`5`, `10`, `15`, `60`) with plain hint: *"On mobile data during school hours (1h before first lesson to 17:00)."*
3. **Keep fast checks 24/7 on Wi-Fi (`refresh_wifi_always_fast`, `Key('rule:wifi_always_fast')`):** `SwitchListTile` (Android wording: *"Fast checks 24/7 on Wi-Fi (nights & weekends too)"*; desktop wording: *"Fast checks all day and night (weekends too)"*).
4. **Off-hours / overnight interval (`check_interval_off_hours_minutes`, `Key('rule:interval_off_hours')`):** dropdown / chips (`60 min — hourly`, `30 min`, `120 min`, `Pause overnight (0)`), disabled/muted with a short note when on desktop with `refresh_wifi_always_fast: true` (still editable on Android because mobile data always uses it off-hours!).
5. **Live Estimated Data Usage panel (`Key('rule:data_estimate')`):**
   - Plain-language summary updated live as any control above changes:
     - On Android: *"Estimated data: ~X.X MB/school day on mobile (~YY MB/month typical), ~Z.Z MB/day on Wi-Fi."*
     - On desktop: *"Estimated data: ~Z.Z MB/school day (~WW MB/month)."*
     - Multi-account note when >1 `background_refresh` accounts: *"(for N accounts)"*.
   - Honest freshness & Android Doze line:
     - *"New marks, absences, and timetable changes arrive within ~N min; automatic excuses run on full checks (~3×/day)."*
     - On Android (`Strings.isMobile`): *"With the screen off, Android may stretch check gaps to ~5–15 min to save battery."*

### 8.2 Ongoing Android notification & TopBar
- `PhoneBackground.sync()` (`startup.dart`) tracks all 4 schedule keys so changing any of them immediately re-arms `scheduleWake()` and updates the ongoing notification fallback text (`bg_notif_text` shows the current effective interval).
- `nextRunLabel` (`activity.dart`) uses `nextScheduledWake` instead of raw `nextDue(lastRun, check_interval_minutes, now)`, so the status tooltip and Activity hero show the real next wake time (including off-hours / pre-alarm transitions!).

### 8.3 Strings & Tutorials (PLAN Rules 5 & 7)
- Every new UI label/hint/estimate string added in **both** `cs` and `en` in `app/lib/l10n/app_cs.arb`, `app/lib/l10n/app_en.arb`, and `app/lib/l10n/strings.dart` (with mobile-specific wording in `Strings.isMobile` overrides).
- Core log/progress strings added in both `cs` and `en` in `packages/strakalari_core/lib/src/i18n.dart`.
- **Tutorials (`app/lib/tutorial/tours.dart`):** update `tut_settings_intro_body` / `tut_settings_intro_body_narrow` (cs & en) to mention refresh frequency & data settings under Rules, and `tut_activity_intro_body` (cs & en) to note quick vs. full checks.

---

## 9. Step 4: Android Rhythm & Battery Measurement (Pixel 7 Pro `.test`)

Before handover for R8 code review:
1. Build `phonetest` APK (`io.github.dendlerx.strakalari.test`, Play app untouched) and install with `adb -s 2C221FDH3002NZ install -r`.
2. Run `tools/bakalari_demo_server.py` (extended with `/Marks/Widget`, `/sessioninfo`, and 3-field Komens callback) on port `18080` with `adb reverse tcp:18080 tcp:18080`.
3. Configure `.test` to 5-min fast interval, verify initial full sync + subsequent quick ticks reuse the encrypted cookie without re-logging in (`bakalari_session.enc` present, demo server logs 0 extra `/Login` calls, 0 `/dashboard` calls, 0 `/Absence/Continuous` calls, 0 `GET /next/komens.aspx` calls on quick ticks).
4. Leave the Pixel screen off for ~60 minutes (resetting `dumpsys batterystats --reset` before), then capture into `build/qa-evidence/F6/`:
   - Actual tick count & gaps from Aktivita + demo server request log,
   - `dumpsys alarm` for `.test`,
   - `dumpsys batterystats io.github.dendlerx.strakalari.test`,
   - 390 px / 1280 px cs/en dark/light screenshots of Settings → Rules (with live data estimator), Activity (showing quick + full freshness), Marks, and Lunches.
5. Adjust the Android Doze wording in Settings if observed screen-off gaps differ from 5–15 min.

---

## 10. Commit Plan & Test Matrix

Each commit lands with its own unit/widget tests (failing before the fix, passing after) and keeps `dart analyze`, `dart test`, `flutter analyze`, and `flutter test` 100% green:

1. **`F6: add low-data refresh config keys, schedule math, and data-usage estimator`**
   - Config keys, validation, `globalConfigKeys`, `config.example.json`, `parity/helpers.json` `roundTripFiles`, `refresh_schedule.dart`.
   - Tests: `config_test.dart`, `accounts_test.dart`, `refresh_schedule_test.dart` (school-day window 1h before first lesson → 17:00, free days, Wi-Fi 24/7 vs off-hours, mobile clamping `max(wifi, mobile)`, off-hours pause `0` + pre-alarm tick, multi-account window union, tier selector including unconfirmed-excuse promotion, data-usage estimator values).
2. **`F6: implement Step 1 HTTP & Bakaláři free wins and Marks widget extractor`**
   - `http_session.dart` (no `/dashboard` redirect, `idleTimeout`), `extractors.dart` (`extractMarksWidget`, `substitutionsByWeekHashes`, `absenceCountsIncreased`), `data.dart` (direct `GetAbsenceBySubjects` + fallback, 3-field Komens callback + page fallback, `fetchMarksWidget`), `timetable.dart` (`weekOffsetsOverride`).
   - Tests: `http_session_test.dart`, `extractors_test.dart`, `bakalari_data_test.dart`.
   - **Explicit existing-test adaptations (2 assertions, documented upfront):**
     - `packages/strakalari_core/test/http_session_test.dart:202` (`droppedConnectionIsRetriedOnceForReads`): `_FlakyTransport(server, 4)` → `3` and `expect(flaky.calls, 5)` → `4` because `login()` no longer makes the 3rd `GET /dashboard` call.
     - `packages/strakalari_core/test/bakalari_data_test.dart:791` (`parsesTheSubjectRows`): updates `dateFrom` expectation from the HTML page's `'2026-09-01T00:00:00+02:00'` to computed `'2026-09-01'` and asserts zero `GET /Absence/Continuous` calls (plus a new test verifying the `/Absence/Continuous` fallback when the direct JSON fails!).
3. **`F6: add Bakaláři session pool (3a) and encrypted cookie store (3b)`**
   - `session_store.dart`, `client.dart`, `automation.dart`, `error_report.dart`, `accounts.dart`, `installer.iss`.
   - Tests: `session_store_test.dart` (in-memory reuse, encrypted disk round-trip, sliding `Set-Cookie` update, 15-min expiry, credential-change deletion, login-rejection deletion, corrupt-file recovery, no plaintext fallback on `KeyStoreUnavailable`), `error_report_test.dart` (cookie value + `Cookie:`/`Set-Cookie:` redaction).
4. **`F6: add quick tier and per-part freshness to runRefresh`**
   - `cache.dart`, `refresh.dart`, `automation.dart`, `fake_bakalari.dart` (request + wire-byte counter), `tools/bakalari_demo_server.py`.
   - Tests (`refresh_test.dart`, `cache_test.dart`, `automation_test.dart`):
     - Every tier makes **exact** expected requests and stays within byte budgets (quick tick ≤ 20 KB simulated wire, routine full ≤ 600 KB).
     - Quick tick **never** reads Komens and **never** runs auto-excuse, even in `auto` mode.
     - Auto-excuse still runs only after a successful outbox read in the same full run; all existing send-path, excuse-history, lock, and audit tests stay unchanged and green.
     - `automation_paused` stops auto-lunch on quick ticks and all auto phases on full runs.
     - New mark detected and notified in **one quick tick** via `/Marks/Widget` → `prubzna.aspx`; broken `/Marks/Widget` falls back loudly to `prubzna.aspx` on first failure and throttles to hourly if persistently broken.
     - Feed change for next week fetches **next week only** (never this week or past weeks).
     - Absence `Count` growth fetches this week (and last week if back-dated) and notifies `new_absence`; `LessonCount` growth alone fetches no week.
     - Failed tier keeps cached data and leaves its `part_updated` stamp untouched; `last_updated` does not move on quick ticks.
     - Scheduled full runs skip `perm`, subject dir, and past weeks once already fetched today unless absence count grew.
5. **`F6: wire Android metered-network detection, dynamic scheduling, and per-part freshness UI`**
   - `AndroidManifest.xml`, `StrakalariChannel.java`, `android_channel.dart`, `scheduler_jobs.dart`, `startup.dart`, `background.dart`, `activity.dart`, `app_state.dart`, feature `*_live.dart` freshness labels.
   - Tests: `android_background_test.dart`, `android_phone_background_test.dart`, `app_state_accounts_test.dart` (including 5-min `isAccountDueForRefresh` tolerance, dynamic `networkKind` switching, `chooseScheduledScope` quick vs full, per-part freshness display).
6. **`F6: add configurable refresh schedule, live data-usage estimator, and tutorial updates`**
   - `settings_view.dart`, `settings_controller.dart`, ARBs + `strings.dart`, `tours.dart`.
   - Tests: `settings_sections_test.dart`, `strings_table_parity_test.dart`, `tutorial_test.dart`, plus 390/1280 px cs/en dark/light screenshots and Pixel 7 Pro `.test` evidence in `build/qa-evidence/F6/`.

---

## 11. Risks & Safety Checks

| Risk | Mitigation |
|---|---|
| Auto-excuse firing without a fresh outbox read | Double lock: `effectiveScope != 'quick'` AND `app.lastOutboxSyncOk == true` in `_autoPhases`; every existing send/history test stays unchanged and green. |
| Upgraded install (`check_interval_minutes: 60`) unexpectedly polling mobile every 10 min | Runtime clamps `mobileDay = max(check_interval_minutes, check_interval_mobile_minutes)`. |
| School Bakaláři lacking `/Marks/Widget` or changing its HTML | First broken tick logs loudly and falls back to `prubzna.aspx`; consecutive broken ticks throttle fallback to hourly so marks are never hidden and bandwidth never explodes. |
| Leaking stored session cookies in logs or error reports | Never written to logs; encrypted with account Fernet key (`0600`, no plaintext fallback); deleted on password/URL/user change, login rejection, account delete, and `--forget-secrets`; scrubbed in `error_report.dart`. |
| `ConnectivityManager` reporting offline during loopback/VPN | `networkKind` only selects schedule cadence, never blocks or skips a refresh. |
| Android Doze stretching 5-min wakes with screen off | Keep `setAndAllowWhileIdle` (never abuse `SCHEDULE_EXACT_ALARM` for polling), measure real 1-hour screen-off rhythm & battery on Pixel `.test`, and state actual behavior honestly in Settings. |
| Stale data looking fresh after a quick tick or failed tier | `last_updated` moves only on complete full runs; every screen reads its own `part_updated` key; failed phases never advance their stamp. |
| macOS / iOS native builds | Cannot be built on Windows 11; Dart code uses `mobilePlatform()` guards and stays marked *unverified* natively. |

---

## 12. Open Questions for Owner / Reviewer

- **Q1 (Upgraded installs' saved `check_interval_minutes: 60`):** New installs default to `5` min Wi-Fi / `10` min daytime mobile / `60` min off-hours. Per `CONTRIBUTING.md` §6 ("no silent migration"), upgraded installs keep their saved `check_interval_minutes: 60` on disk (they still get all Step 1–3 bandwidth savings immediately and can switch to 5/10 min in Settings → Rules with one tap on the preset chips). Confirm keeping saved `60` untouched is what you want? *(Recommended: yes, keep saved value untouched.)*
- **Q2 (24/7 5-min Wi-Fi request count):** At 5 min 24/7 on Wi-Fi (`refresh_wifi_always_fast: true`), the app sends ~920 small requests/day (~8 MB/day on Wi-Fi, 0 mobile data) vs. ~460 small requests/day if Wi-Fi also slows to hourly overnight (`refresh_wifi_always_fast: false`). Confirm keeping `refresh_wifi_always_fast: true` as the default (toggleable in Settings) as requested in D6? *(Recommended: yes.)*
- **Q3 (Real-server measurement after implementation):** Automated tests and Pixel `.test` verification use fakes and `bakalari_demo_server.py` (never real credentials/servers). After F6 passes code review, do you want to run a standalone measuring check against your real GEKOM account (like on 2026-11-17) to confirm the real MB/day numbers?
