# F6 proposal: low-data refresh (towards every 5 minutes)

Status: **proposal, not in PLAN yet.** Written 2026-11-17 by the reviewer
at the owner's request, from the owner's own measurement (below) and the
code at `qa-roadmap` @ `c61e479`. It starts only after the owner's "go"
and answers to D6 (§8). Like F1 and F4, it then gets a design note and a
review before any code, because it changes the refresh pipeline.

---

## 1. In short

- **Today:** a routine refresh downloads about **1 MB**. Hourly that is
  ~25 MB a day; every 5 minutes it would be ~300 MB a day.
- **Why:** every refresh downloads everything again: five timetable weeks
  plus the permanent timetable, all sent excuses, all marks and the absence
  page. Almost none of it changes between two refreshes.
- **Idea:** every 5 minutes, only a **quick check** of one small list,
  the school's own list of timetable changes (~5 KB). The big pages come
  only when something changed, or on a slower clock (marks hourly, past
  weeks daily). Nothing at night.
- **Estimate:** every 5 minutes during school hours for about **4–6 MB a
  day**. That is less than today's hourly refresh. Once the login is
  reused (step 3), it also means fewer requests to the school server than
  today (~300 a day instead of ~670).
- **Trade-off:** timetable changes arrive within 5 minutes. New marks and
  absences arrive within your chosen slower interval (for example 30–60
  minutes), unless a cheap way to spot them is found (step 5).

---

## 2. The measurement (owner, 2026-11-17)

Routine refresh, real GEKOM and Strava account, `automation_paused: true`:
**1.04 MB** on the phone (`TrafficStats`), 992 KB of HTTP in 28 requests.

| Requests | What | Wire | Why it runs every time today |
|---|---|---|---|
| `POST /Timetable/GetContentData` ×6 | 5 weeks (`go_forward_weeks` 1 … `go_back_weeks` 4, i.e. +1, 0, −1, −2, −3) and the permanent timetable | 432 KB | `fetchTimetableWeeks`, `extractStableTimetable` (`timetable.dart`) |
| `GET /next/komens.aspx` + its list callback + `GetMessageDataAsync` ×10 | Komens → Odeslané: the sent-excuse history | 245 KB | `syncWebExcusesToHistory` → `fetchSentExcuses` (`data.dart:171`); every message's details are read again |
| `GET /next/prubzna.aspx` | all marks | 185 KB | `getGrades` |
| `GET /Absence/Continuous` + `GetAbsenceBySubjects` | the page is fetched only for its date range; the numbers come from the 3 KB JSON | 61 KB | `obtainAbsenceInfo` |
| `GET /login` + `GET /dashboard` | new login every run; the dashboard is only the redirect target after login and is never used | 55 KB | `BakalariSession.login` follows the redirect |
| `POST /Timetable/substitutions/dates` | the school's own list of changes for this week to 14 days ahead | 5 KB | `fetchSubstitutions` |
| `POST /Teaching/Subjects` | subject list | 4 KB | `fetchSubjectDirectory` |
| Strava (2 requests) | menu and orders | 4 KB | already small and compressed |

Other facts from the code:
- `dart:io` already asks for gzip. The school server compresses only some
  replies (the Komens list: 54 → 7 KB), not the big pages or the timetable
  JSON. The app can't change that, so the savings must come from
  downloading less.
- The cold run (1.68 MB) also backfills 8 old weeks once per school year
  (`historyWeeks`). That is a one-time cost and is fine.
- Android wakes the app with `setAndAllowWhileIdle` alarms
  (`RefreshReceiver.java`). Android limits how often those fire in deep
  sleep (Doze), so a true 5-minute rhythm with the screen off must be
  **measured** on the Pixel, not assumed.
- `check_interval_minutes` already accepts 1 minute (`config.dart:466`,
  `settings_controller.dart:297`). No new key is needed for the interval
  itself.

---

## 3. What must stay true (CONTRIBUTING §5, PLAN rule 3)

- **One pipeline.** Every tier below is a `scope` of `runRefresh`
  (`refreshScopes` already exists), never a second fetch path in the UI,
  the tray or `backgroundMain`.
- **One session at a time.** Every tick runs under `withSessionLock`. A
  tick that can't get the lock skips with a visible message, as today.
- **One send path, and no send without a fresh outbox.** Auto excuses run
  only in a run that read Komens → Odeslané successfully **in the same
  run** (`lastOutboxSyncOk`, `refresh.dart:601`). A quick tick never sends
  an excuse. The send itself stays `Strakalari.sendExcuse` with
  `excuse_history.dart` and `HistoryLock`.
- **Everything recorded, `automation_paused` stops every auto phase**, and
  failures are loud. A tier that fails keeps the cached data and says so.
- **Honest freshness.** Today the global `last_updated` stamp moves only
  on a complete full refresh (`refresh.dart:266`). With tiers, each part
  gets its own "fetched at" stamp (timetable, marks, absence, outbox,
  Strava). The UI shows the right one, and no part ever looks fresher than
  it is.
- **Bakaláři web only**, never the `/api/3` mobile API.
- **No real servers in tests.** Tests use fakes and
  `tools/bakalari_demo_server.py`. Real numbers come only from the
  owner's own measuring run.

---

## 4. The plan, in steps

Each step is its own commit(s) with tests, and is measured again with the
owner's measuring build before the next one.

### Step 1: free wins (same data, same freshness, ~45 % less)

Nothing the user sees changes. Every refresh still brings everything that
can change.

| Change | Saves per refresh | Notes |
|---|---|---|
| After the login `POST`, don't follow the redirect to `/dashboard`; treat a redirect away from `/login` as success | −49 KB per login | Keep the "still on the login page" failure check. The excuse post (`sendOnce`) doesn't change. |
| Keep the absence date range from `/Absence/Continuous` in the cache; fetch the page again once a day, or when `GetAbsenceBySubjects` fails or the date falls outside the range | −58 KB | The JSON call stays every run. |
| Permanent timetable (`perm`) and the subject list once a day | −76 KB | The permanent timetable changes a few times a year. |
| Past weeks (−1 … −3) once a day, plus at once when the absence data shows a new absence in them | −216 KB | They are only needed to match absences to lessons for excuses. |
| Komens details: read `GetMessageDataAsync` only for message ids not seen before (cache by id) | −30 KB | Overlaps F2. Do it inside F2 if F2 comes first. |

Result: ~**550 KB** per full refresh, with the same freshness for this week
and next week, marks, absence and the outbox.

### Step 2: tiers (the big win)

| Tier | When | What | Size |
|---|---|---|---|
| **Quick** | every `check_interval_minutes` (e.g. 5) during school hours | substitution feed only (`/Timetable/substitutions/dates`) | ~5 KB + login/TLS |
| **Week** | when the feed's entries for a week changed (hash per week), and every 30 min in school hours as a safety net | that week's `GetContentData` (this week, next week) | ~72 KB per week |
| **Absence** | every 15–30 min in school hours | `GetAbsenceBySubjects` (cached date range, step 1) | ~3 KB |
| **Marks** | every 60 min in school hours, plus once in the evening (D6) | `prubzna.aspx` | ~185 KB |
| **Strava** | every 30 min in the day, and before each order cutoff | as today | ~4 KB |
| **Full** | first run of the day, and twice a day | everything, including the Komens outbox; **only here do auto excuses run** | ~550 KB after step 1 |
| **Night** | 22:00–6:00 (D6) | nothing, except one quick tick 30 min before the Budík alarm | — |

- "School hours" come from today's timetable: 30 minutes before the first
  lesson to the end of the last one. On days off (weekends, preset free
  days, holidays) the quick tick runs hourly.
- A manual *Obnovit data* always runs the full tier.
- Auto lunch keeps running in runs that fetched Strava. Auto excuse keeps
  running only in full runs (an outbox read in the same run). With
  `excuse_delay_days` 2, a few full runs a day are early enough.
- One setting for the user stays: *Jak často kontrolovat změny*
  (`check_interval_minutes`). The slower clocks are fixed in code, so no
  new config keys are needed. If D6 asks for a switch (e.g. Wi-Fi only),
  that key follows PLAN rule 4.

### Step 3: login once, not every tick

- With a 5-minute rhythm the Bakaláři session stays alive between ticks.
  Reusing it saves the login (~10 KB) and avoids ~100 logins a day on the
  school's server.
- **3a (no new risk):** keep the `BakalariSession` in memory between runs
  where the process lives on: desktop, and Android while the UI isolate
  is alive.
- **3b (only with the owner's OK, D6):** for headless Android runs, store
  the session cookie encrypted with the existing Fernet key, next to the
  passwords. It is a password-like secret: delete it on logout or when
  the login changes, never log it, and add it to `redactText`.

### Step 4: Android rhythm and battery

- On the Pixel, with the `.test` app against the demo server and the
  screen off for an hour: count the runs in Aktivita and check
  `dumpsys alarm`. If Doze stretches the gaps, say so plainly in Settings
  ("about every 5–10 minutes") rather than promising 5.
- Check battery use with `dumpsys batterystats` for `.test`, before and
  after.
- Optional (D6): the 5-minute rhythm only on Wi-Fi, and 15 minutes on
  mobile data.

### Step 5 (research): a cheaper way to spot new marks

- Marks are the biggest item left (185 KB per check).
- Look for the smallest **web** request that changes when a mark is added:
  the dashboard's "new marks" part, a callback of the marks page, or a
  Komens notification.
- This needs a few real saved pages, with personal data removed (D6).
  Without them, marks stay on the hourly clock.

---

## 5. Expected result

GEKOM school day, quick tick every 5 minutes from 7:30 to 15:30 (~96
ticks), and hourly on the rest of the day until 22:00.

| Part | Per day |
|---|---|
| Quick ticks, school hours (96 × ~10–15 KB incl. TLS) | ~1.2 MB |
| Quick ticks, rest of the day (~6 × ~15 KB) | ~0.1 MB |
| Week refetches (≈ 16 safety-net + a few real changes × 72 KB) | ~1.4 MB |
| Absence (32 × ~5 KB) | ~0.2 MB |
| Marks (9 × 185 KB) | ~1.7 MB |
| Strava (~30 × ~6 KB) | ~0.2 MB |
| Full runs (3 × ~550 KB) | ~1.6 MB |
| **Total** | **~6 MB a day**; ~4 MB with both a cheap marks check (step 5) and the week safety net every 60 min |

These are estimates from one measured run. The measuring build checks
them after each step.

---

## 6. Done when

- The owner's measuring build reports: a quick tick of **≤ 20 KB**, a full
  refresh of **≤ 600 KB**, and a day at the 5-minute rhythm of **≤ 8 MB**
  (per-tier sizes × the schedule).
- Every existing send-path, excuse-history, lock and audit test is
  unchanged and green.
- New tests (fake server that counts requests and bytes):
  - each tier makes exactly the requests listed;
  - a quick tick never runs auto excuse, even in `auto` mode;
  - auto excuse runs only after a successful outbox read in the same run;
  - `automation_paused` stops every tier's auto phase;
  - a failed tier keeps its cached data and shows its own stamp;
  - a feed change for next week fetches next week only;
  - the night pause and the before-alarm tick.
- Pixel (`.test` only): the rhythm with the screen off and battery
  measured as in step 4, with evidence in `build/qa-evidence/F6/`.
- Settings wording (cs/en) says honestly how often it checks, and how fast
  marks and absences arrive. Tutorials updated if a control is added
  (rule 7).

---

## 7. Risks

- **Missed changes.** The feed covers changes the school marks as
  substitutions. A change it doesn't list (if any) waits for the
  30-minute week safety net. Step 2 checks the feed against the full week
  on the demo server, and the owner's measuring build checks it on real
  data.
- **The school's server.** Polling every 5 minutes is fine only because
  each quick tick is one small request. That is fewer requests than
  today's hourly full refresh. Never make the quick tick bigger without
  measuring.
- **Android limits** (Doze, battery optimisation): see step 4.
- **Complexity in safety-critical code.** The tiers live inside
  `runRefresh` and its tests, behind the same lock and audit. Nothing new
  sends or orders.

---

## 8. Owner decisions (D6)

| Question | Reviewer's suggestion |
|---|---|
| Go for F6? Before or after F2 (excuse history)? | After F2, because both change the Komens read. Step 1 (except the Komens part) can come any time. |
| School hours: from the timetable, or fixed (e.g. 7:00–16:00)? | From the timetable |
| How quickly must new **marks** and **absences** show up? | Absence 15–30 min, marks 60 min |
| Night pause 22:00–6:00? | Yes, with one tick before the Budík alarm |
| May the session cookie be stored encrypted for background runs (step 3b)? | Only if 3a isn't enough |
| 5 minutes on mobile data too, or only on Wi-Fi (15 min on mobile)? | Your call: ~6 MB a day is small for most plans |
| Can you save a few real pages (marks page, dashboard), personal data removed, for step 5? | Optional |
