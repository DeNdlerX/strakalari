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
  the school's own list of timetable changes (~5 KB) and a small signal
  for new marks (to be found, step 0). The big pages come only when
  something changed, or on a slower clock (past weeks daily). Nothing at
  night.
- **Estimate:** every 5 minutes during school hours for about **4–6 MB a
  day**. That is less than today's hourly refresh. Once the login is
  reused (step 3), it also means fewer requests to the school server than
  today (~300 a day instead of ~670).
- **Owner's answer (D6, 2026-11-17):** new marks must show up within 5
  minutes, "thats kinda the point". So the quick check must also spot a
  new mark, and do it cheaply: the marks page is 185 KB, and loading it
  every 5 minutes alone would be ~18 MB a day. Finding the smallest way is
  now **step 0**, research on the real Bakaláři with the owner logged in
  (`PROMPT-F6-research.md`). It comes before the design note.

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
- `dart:io` already asks for gzip. The school server compresses only the
  DevExpress callbacks (the Komens list: 55 → 3–7 KB), not the pages, the
  JSON or the widgets, and `br` changes nothing (step 0, research §7). The
  app can't change that, so the savings must come from downloading less.
- The cold run (1.68 MB) also backfills 8 old weeks once per school year
  (`historyWeeks`). That is a one-time cost and is fine.
- Android wakes the app with `setAndAllowWhileIdle` alarms
  (`RefreshReceiver.java`). Android limits how often those fire in deep
  sleep (Doze), so a true 5-minute rhythm with the screen off must be
  **measured** on the Pixel, not assumed.
- `check_interval_minutes` already accepts 1 minute (`config.dart:466`,
  `settings_controller.dart:297`). No new key is needed for the interval
  itself.

### Step 0 findings (real GEKOM web, 2026-11-17)

Full report: `research-F6-bakalari-web.md`. The research day was a
public holiday (no lessons), so nothing was seen appearing live.

| Need | Smallest web request | Size | Change signal |
|---|---|---|---|
| **New marks** | `GET /Marks/Widget` (the dashboard's recent-marks box) | **2.0 KB** | the 5 most recently given marks; identical bytes while nothing changes. Extra, optional: `GET /Dashboard/NoticesWidget`, 0.4 KB, "Nové známky: N" |
| Marks themselves | `GET /next/prubzna.aspx` | 187 KB | no smaller variant: with a date filter the page frame alone is ~95 KB |
| Timetable changes | `POST /Timetable/substitutions/dates` (already used) | 3–5 KB | listed every changed lesson the weeks showed; whole free days aren't in it |
| A week | `POST /Timetable/GetContentData` | 50–85 KB | no smaller variant (no day view) |
| Absence | `GET /Absence/Continuous/GetAbsenceBySubjects`, range 1 Sep → today computed by the app | 1.2–3 KB | per-subject `Count`; the 58 KB page isn't needed for the range |
| Komens → Odeslané | its list callback with only 3 hidden fields kept from an earlier load (even across a new login) | 2.9 KB gzip | no 207 KB page per run |

- **Session:** 15 minutes, sliding. A request in the second half of the
  15 minutes renews it; one in the first half doesn't. Ticks every 5
  minutes keep it alive on their own. Measured: still alive after 10 idle
  minutes, dead 15 minutes after the last renewal.
- **No `ETag`, no `Last-Modified`, never `304`** on any Bakaláři reply.
  Change detection is the client's job (compare the small replies).
- **TLS:** a new connection costs ~6–7 KB (handshake), more than a quick
  tick's data. `dart:io` drops idle connections after 15 s.

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

### Step 0: research on the real Bakaláři (before the design note)

- A research agent goes through the real GEKOM Bakaláři web, read-only,
  in the built-in browser where the owner has logged in. The prompt is
  `PROMPT-F6-research.md`.
- It finds the smallest web requests that show a new mark, a timetable
  change and a new absence, and how long a session stays alive. It also
  lists new things the web offers that the app could use.
- It writes `research-F6-bakalari-web.md` and updates §2, §4, §5 and §8
  here.
- Steps 2 and 5 below depend on its result.
- **Done 2026-11-17:** `research-F6-bakalari-web.md`; summary in §2
  ("Step 0 findings"). The steps below are updated with its results.

### Step 1: free wins (same data, same freshness, ~45 % less)

Nothing the user sees changes. Every refresh still brings everything that
can change.

| Change | Saves per refresh | Notes |
|---|---|---|
| After the login `POST`, don't follow the redirect to `/dashboard`; treat a redirect away from `/login` as success | −49 KB per login | Keep the "still on the login page" failure check. The excuse post (`sendOnce`) doesn't change. Step 0: the form's `returnUrl` field picks the redirect target (verified in the browser), so `returnUrl=/Marks/Widget` would even make the login bring the marks signal (research §5). |
| Don't load `/Absence/Continuous` for its date range: send 1 September of the school year → today (step 0: plain dates work, same reply). Load the page only when `GetAbsenceBySubjects` fails | −58 KB | The JSON call stays every run. |
| Permanent timetable (`perm`) and the subject list once a day | −76 KB | The permanent timetable changes a few times a year. |
| Past weeks (−1 … −3) once a day, plus at once when the absence data shows a new absence in them | −216 KB | They are only needed to match absences to lessons for excuses. |
| Komens details: read `GetMessageDataAsync` only for message ids not seen before (cache by id) | −30 KB | Overlaps F2. Do it inside F2 if F2 comes first. |
| Komens list without the page: keep `__VIEWSTATE`, `__VIEWSTATEGENERATOR` and `__EVENTVALIDATION` from the last page load and post only those with the list callback; load the page again when the reply is the `redirect` one or isn't a message list | −204 KB | Step 0: works with fields 10 minutes old, and with fields from a session that had expired, after a new login (research §6, §6.1). So they can live in the cache. The `hfListType` check moves to the last page load. Overlaps F2 like the row above. |

Result: ~**350 KB** per full refresh, with the same freshness for this week
and next week, marks, absence and the outbox.

### Step 2: tiers (the big win)

| Tier | When | What | Size |
|---|---|---|---|
| **Quick** | every `check_interval_minutes` (e.g. 5) during school hours | three small reads: the marks signal `GET /Marks/Widget`, the substitution feed `POST /Timetable/substitutions/dates`, and the absence numbers `GET /Absence/Continuous/GetAbsenceBySubjects` (computed date range, step 1) | ~6–10 KB of data; ~16–20 KB with headers and TLS |
| **Week** | when the feed's entries for a week changed (hash per week), when an absence `Count` grew (this week), and hourly in school hours as a safety net for free days, which the feed doesn't list | that week's `GetContentData` (this week, next week) | 50–85 KB per week |
| **Marks** | in the same quick tick, when the widget's 5 lines differ from the cached copy (D6: within 5 minutes) | `prubzna.aspx` | ~187 KB |
| **Strava** | every 30 min in the day, and before each order cutoff | as today | ~4 KB |
| **Full** | first run of the day, and twice a day | everything, including the Komens outbox; **only here do auto excuses run** | ~350 KB after step 1 (~640 KB for the first run of the day, with the daily parts) |
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
- **Step 0 measured it:** 15 minutes, sliding. A request in the second
  half of the 15 minutes renews it; one in the first half doesn't. Ticks
  every 5 minutes therefore keep it alive with no extra keep-alive
  request. Ticks 15 or more minutes apart (the hourly ticks) log in again.
  `GET /sessioninfo` (87 B) tells the seconds left and doesn't renew, if a
  check is ever needed. Since a renewal probably sends a fresh cookie, the
  session must keep every `Set-Cookie` it gets (it already does), and 3b
  must store the cookie again after each run, not only at login.
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

### Step 5: the marks signal in code

- Build the cheap marks signal that step 0 found into the quick tier, with
  a fake-server test that a new mark is noticed after one quick tick.
- **The signal (step 0): `GET /Marks/Widget`, 2.0 KB.** It holds the 5
  most recently given marks (`.mark-line` → grade, subject, note, date,
  `isNew`), and its bytes don't change while the marks don't. Each quick
  tick parses it and compares the 5 lines with the copy in the cache.
  - Different → load `prubzna.aspx` in the same tick, and notify the new
    marks as today.
  - Same → nothing more.
  - Can't parse it (the format changed) → load `prubzna.aspx` this tick
    and log it loudly, so a broken signal never hides marks.
- The full runs keep reading `prubzna.aspx`. They catch what the widget
  can't see: an edit or a deletion of an older mark.
- Optional second signal: `GET /Dashboard/NoticesWidget` (0.4 KB,
  "Nové známky: N"). Not needed for the first version.
- The fake server (`fake_bakalari.dart`) and the demo server get a
  `/Marks/Widget` that follows the marks they serve.

---

## 5. Expected result

GEKOM school day, quick tick every 5 minutes from 7:30 to 15:30 (96
ticks), hourly from 6:00 to 7:30 and from 15:30 to 22:00 (8 ticks),
nothing at night. Sizes from step 0 (research §9).

| Part | Per day |
|---|---|
| Quick ticks, school hours (96 × ~17 KB: marks widget 2 KB + feed 3–5 KB + absence 1–3 KB, ~3 KB of headers, ~7 KB for a new TLS connection; the session stays alive) | ~1.6 MB |
| Quick ticks, rest of the day (8 × ~26 KB, a new login each) | ~0.2 MB |
| Marks page when the widget changed (~3 × 187 KB) | ~0.6 MB |
| Week refetches after a feed change (~3 × ~70 KB) | ~0.2 MB |
| Week safety net, this week hourly in school hours (8 × ~65 KB) | ~0.5 MB |
| Strava (~30 × ~6 KB) | ~0.2 MB |
| Full runs (first of the day ~640 KB, then 2 × ~350 KB) | ~1.3 MB |
| **Total** | **~4.6 MB a day** |

- A day off (weekend, holiday): 16 hourly ticks and the full runs, about
  **1.7 MB**.
- The TLS handshake is the biggest part of a quick tick. Keeping one
  connection open between ticks (desktop, Android with the UI alive) would
  bring a tick down to ~10 KB, about −0.7 MB a day. The school's server
  keeps an idle connection for at least 10 minutes. The client would need
  an `idleTimeout` of ~6 minutes instead of `dart:io`'s 15 s (research §8).
- Requests to the school server: about 400 a day, against ~670 today.

These are estimates from one measured run and one holiday's research. The
measuring build checks them after each step.

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
  - a new mark is noticed and notified after one quick tick (D6);
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
| How quickly must new **marks** and **absences** show up? | **Answered 2026-11-17 for marks:** "I want new marks to be visible in the 5 minutes, thats kinda the point." **Step 0:** a cheap marks signal exists (`/Marks/Widget`, 2 KB), so 5 minutes it is. Absence: the absence numbers themselves are only 1–3 KB, so the suggestion is now **5 minutes too** (every quick tick). Your call. |
| Night pause 22:00–6:00? | Yes, with one tick before the Budík alarm |
| May the session cookie be stored encrypted for background runs (step 3b)? | Only if 3a isn't enough. **Step 0:** a session lasts 15 minutes and 5-minute ticks keep it alive. Without 3b, every headless Android tick logs in again: ~+7.5 KB a tick (~+0.7 MB a day) and ~96 more logins a day on the school's server |
| 5 minutes on mobile data too, or only on Wi-Fi (15 min on mobile)? | Your call: **~4.6 MB a school day** (step 0 estimate) is small for most plans |
| Can you save a few real pages (marks page, dashboard), personal data removed, for step 5? | **Answered 2026-11-17:** the owner logs in to the built-in browser for the step 0 research agent instead. **Done:** `research-F6-bakalari-web.md`. |
