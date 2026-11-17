# F6 step 0: research on the real Bakaláři web

Written 2026-11-17 by the step 0 research agent (`PROMPT-F6-research.md`),
in the built-in browser with the owner logged in at GEKOM
(Bakaláři web 2.2.1104.6, IIS 10, ASP.NET MVC 5.2). Read-only: page
navigation, the pages' own requests, and a few `fetch()` replays of
read-only requests. Nothing was sent, saved, submitted or marked read. No
mobile API. The only writes were the pages' own background saves, as on
any visit (the dashboard `POST`s `/UIState`, its layout). They weren't
replayed.

**The day matters:** 17 Nov is a public holiday, so there were no lessons
today. Everything that only shows during lessons (a mark or an absence
appearing live) is marked *unverified*.

Sizes are the HTTP body as measured by the browser (`encodedBodySize` on
the wire, `decodedBodySize` after decompression). Headers come on top
(about 0.3 KB per reply, see §8). All example values are made up.

---

## 1. In short

- **New marks: `GET /Marks/Widget`, 2.0 KB.** The dashboard's "recent
  marks" box: the 5 most recently given marks as a small HTML fragment.
  The bytes are identical while nothing changes, so the app can compare it
  with the last copy. Only when it changes does it load the marks page
  (187 KB). A second, even smaller signal exists: `GET
  /Dashboard/NoticesWidget` (0.4 KB), "Nové známky: N".
- **Timetable changes:** the feed the app already reads,
  `POST /Timetable/substitutions/dates` (3 KB here). It listed every
  changed lesson the week view showed, for this week and the next two.
  It doesn't list whole free days. `GetContentData` can't return less
  than a week (50–85 KB).
- **New absences:** `GET /Absence/Continuous/GetAbsenceBySubjects`
  (1.2 KB) *is* the absence data. Its date range is simply 1 September →
  today, and plain dates work, so the 58 KB absence page isn't needed.
- **Session:** 15 minutes, sliding. A normal request in the **second
  half** of the 15 minutes renews it to the full 15 minutes; a request in
  the first half doesn't. So ticks every 5 minutes keep it alive with no
  extra request. Ticks 15+ minutes apart need a new login (measured: dead
  15 minutes after the last renewal). The login's `returnUrl` field picks
  the page after login, so a login needn't cost the 49 KB dashboard.
- **Komens → Odeslané:** its list loads **without** the 207 KB page. It
  only needs three hidden fields (1.4 KB) kept from an earlier load (they
  even survived a new login), and the reply is gzip'ed (55 → 2.9 KB).
- **Compression:** only the DevExpress callbacks (Komens lists) come
  gzip'ed. All pages, JSON and widgets come uncompressed, even when the
  browser offers `br`. `br` would change nothing.
- **Quick tick** (marks widget + change feed + absence JSON): about
  **6 KB of data, ~16–20 KB with headers and a new TLS connection**. A
  school day at a 5-minute rhythm comes to **about 4–5 MB** (§9).

---

## 2. New marks (the priority)

| Request | Size (wire = decoded) | Change signal | Side effects | Verdict |
|---|---|---|---|---|
| `GET /Marks/Widget` | **2.0 KB** (5 marks) | bytes identical on repeat; changes when a mark is given, edited or removed among the 5 newest | none seen | **Use: the 5-minute marks signal** |
| `GET /Dashboard/NoticesWidget` | **0.4 KB** | "Nové známky: N" (count of marks flagged new) | none seen | Optional second signal |
| `GET /next/prubzna.aspx` | 187 KB (31 marks) | — | none seen: `IsNew` stayed true after 6 loads | Load only when the widget changed, plus in full runs |
| `GET /next/prubzna.aspx?dfrom=…&dto=…&subt=posl_tyden` | 96 KB (1 mark) | — | none | No: the page frame alone is ~95 KB |
| `GET /next/prubzna.aspx?s=chrono` | 91 KB | — | none | No: other markup, no `data-clasif` |
| `GET /Marks/Semester` | 158 KB | — | none | No (end-of-term marks only) |
| Komens inbox, `onlyRating` | 0.9 KB gzip (empty list) | — | listing is safe; opening a message marks it read | No: no mark messages in Komens at this school |

All of these: `Cache-Control: private, s-maxage=0`, no `ETag`, no
`Last-Modified`, never `304` (a conditional request got a plain `200`).
Not compressed.

### `GET /Marks/Widget`

What the dashboard loads with `$.get` (no parameters; the page adds a
`_=<timestamp>` cache-buster, which isn't needed). Reply: `text/html`,
one fragment:

```html
<div class="bk-widget-marks">
  <div class="mark-line" onclick="window.location.href = appRoot + 'next/prubzna.aspx'">
    <span class="mark-displayGrade isNew">1</span>   <!-- MarkText; "isNew" only on new marks -->
    <span class="mark-subjectName">Matematika</span> <!-- nazev -->
    <span class="mark-note">Písemka: zlomky</span>   <!-- poznamkakzobrazeni, as text -->
    <span class="mark-date">5.11.</span>             <!-- strdatum, day.month. -->
  </div>
  … 5 lines in total …
</div>
```

- **Which 5:** the 5 newest by `udel_datum` (the date the mark was given).
  The widget showed exactly the 5 marks with the latest `udel_datum` on the
  marks page. A mark given today for a test two weeks ago (`strdatum`
  older) therefore still comes first.
- **Change signal:** keep the parsed 5 lines (grade, subject, note, date,
  isNew). A different list means "load `prubzna.aspx`". The bytes contain
  no timestamp or token: two replies 1.5 s apart were identical.
- **Covers:** any new mark (it becomes the newest), and edits or
  deletions among the 5 newest.
- **Misses:** an edit or deletion of an older mark. The full runs (a few
  times a day) still read the whole page.
- *Unverified:* the order of marks given **on the same day**. If more
  than 5 marks arrive in one day, a later one might not displace an
  earlier one. The list would still change on the first of them, and
  `NoticesWidget` would count every one of them.
- *Unverified:* a mark appearing live (no lessons on the research day).

### `GET /Dashboard/NoticesWidget`

```html
<div class="bk-widget-notices">
  <div class="notice-line" onclick="window.location.href='next/prubzna.aspx'"
       data-testid="widget-notice-line-Klasifikace">
    <div class="notice-icon red"><i class="ico32-modul-klasifikace"></i></div>
    <div class="notice-text">Nové známky: 3</div>
  </div>
</div>
```

- `N` matched the number of marks with `IsNew: true` on the marks page.
- The one new mark was given 7 days ago and the next one 8 days ago, so
  "new" probably means "given in the last 7 days" (*unverified*). Loading
  the marks page didn't clear it. The count therefore also drops when a
  mark ages out (at a day boundary, outside school hours).
- Other notice types (Komens, homework, …) probably appear as more
  `notice-line`s with another `data-testid` (*unverified*: only the
  marks line was present).

### The marks page, for reference

`GET /next/prubzna.aspx`, 187 KB for 31 marks, all in the HTML as
`data-clasif` JSON (keys: `id, nazev, MarkText, vaha, udel_datum,
strdatum, caption, poznamkakzobrazeni, IsNew, typ, MarkTooltip, …`;
`datum` is always `0001-01-01`, unused). The date filter
(`dfrom`/`dto` as `yyMMddHHmm`, only together with `subt=posl_tyden`,
`posl_mesic`, `1pololeti` or `2pololeti`) still costs ~95 KB for the page
frame. No callback or JSON behind it.

---

## 3. Timetable changes

| Request | Size | Change signal | Side effects | Verdict |
|---|---|---|---|---|
| `POST /Timetable/substitutions/dates` (this week → week of today + 14 days) | **3.0 KB** (8 changes in 2 weeks); 5 KB in the owner's run | compare the entries per week | none | **Use every tick** (already used) |
| `POST /Timetable/GetContentData` `cal` | 50 KB (holiday week, 15 lessons), 82 KB (full week, 30 lessons) | — | none | Only for a week whose feed entries changed, plus a safety net |
| `GetContentData` `perm` | 85 KB | — | none | Once a day (step 1) |
| `GetContentData` with an unknown `term` (e.g. `day`) | 49 KB | — | none | Ignored: returns the week. No smaller variant |
| `GET /Timetable/Widget?date=<ISO>` | 14 KB (one day) | lines with `hasChange` / `absent` classes | none | No: the feed is smaller |
| `GET /Timetable/SubstitutionWidget?date=<ISO>` | 5.4 KB (one week) | — | none | No: the feed covers 3 weeks in less |
| `GET /Timetable` | 141 KB (renders the week itself) | — | none | No |

None compressed, no `ETag`, never `304`.

**Is the feed complete?** Compared with the full weeks (`GetContentData`
for this week and the next two):

- Every lesson the week marked as changed (badges `S`, `S`, `N`, `N`, `M`)
  had its entry in the feed.
- A lesson swapped for another subject shows in the feed as a pair:
  `Removed` (`OriginalTeacher`) and `Added` (`SubstituteTeacher`) for the
  same hour. The week shows only the new lesson (`N`).
- `RoomChanged` and `Substitution` were both present. No `Canceled` lesson
  existed to check (*unverified*, but `Canceled` is a known `ChangeType`).
- One `Absence` entry (the class is away for a lesson) had no change badge
  in the week. The day widget showed that lesson as `absent`.
- **Not in the feed:** whole free days (`Days[].DayOff`, e.g. today's
  holiday). A free day added at short notice would therefore only show in
  the week safety net, or in the events calendar (§8.1). The student's own
  absence and lesson topics aren't in it either (not needed quickly).

**Verdict:** the feed is enough for the 5-minute tick. Fetch a week again
only when its feed entries change, plus a safety net for free days (this
week hourly in school hours is plenty; next week in the full runs).

---

## 4. New absences

| Request | Size | Change signal | Side effects | Verdict |
|---|---|---|---|---|
| `GET /Absence/Continuous/GetAbsenceBySubjects?dateFrom=2026-09-01&dateTo=2026-11-17&lateChecked=false&schoolChecked=false&soonChecked=false` | **1.2 KB** (14 subjects); 3 KB in the owner's run | per-subject `Count` (`LessonCount` grows with every lesson held, so ignore it) | none | **Use every tick**: it is the data itself |
| `POST /Absence/Continuous/GetDates` `selectedPeriod=0` | 0.4 KB | — | none | Not needed: the range can be computed |
| `GET /Absence/Continuous` | 58 KB | — | none | Drop from routine runs |
| `GET /Absence/Continuous/GetAbsenceOverview?dateFrom=…&dateTo=…` | 40 KB (672 cells `{Day, Month, Type, Count}`) | — | none | No (calendar heat map) |

- **The date range without the page:** the page's default is the school
  year start → today 00:00 (`DefaultDateFrom` = `MinValue` =
  `2026-09-01T00:00:00+02:00`, `MaxValue` = `2027-07-01T23:59:59`). The
  reply was identical for `…T00:00:00+01:00`, `…T23:59:59+01:00` and plain
  `YYYY-MM-DD`. So: `dateFrom` = 1 September of the school year (the
  previous year before September), `dateTo` = today. Keep the page as a
  once-a-day fallback when the JSON fails (step 1 already says so).
- *Unverified:* whether `dateTo` = today includes today's lessons (no
  lessons today). The app should send today's date: the page does the
  same.
- *Unverified:* how quickly a teacher's absence entry shows here. The
  reply is computed per request (no cache headers), so probably at once.
- When `Count` grows, fetch this week's `GetContentData` too: the app
  needs the per-lesson `absenceType` for excuses.

---

## 5. Login and session

| Request | Size | Notes |
|---|---|---|
| `GET /sessioninfo` | **87 B** JSON | `{"success":true,"error":"","data":{"remainingTime":812.5,"sessionDuration":15.0}}`. Seconds left and the length in minutes. Calling it does **not** renew the session |
| `GET /sessionextend` | 0 B | What the page's session popup calls after mouse or keyboard activity. Called in the first half, it didn't change `remainingTime` |
| `GET /login` | ~6 KB (owner's run: 55 KB with the dashboard) | login form |
| `POST /Login` → `302` → `GET /dashboard` | dashboard **48.7 KB**, uncompressed | the redirect target is never used by the app |

**How long a session lives** (measured with `sessioninfo`, from a tab
with no scripts, so the page's own activity timer didn't interfere):

- `sessionDuration` is **15 minutes**. The dashboard's session popup
  warns 3 minutes before the end ("Jste tu ještě?").
- **Sliding, with renewal only in the second half** (the ASP.NET
  forms-authentication rule). During the first 7.5 minutes after a
  renewal, requests didn't change the countdown: `/Marks/Widget`,
  `substitutions/dates`, `prubzna.aspx` and `sessionextend` were all
  tried. After 7.5 minutes, one `/Marks/Widget` request reset it from
  420 s to **900 s**. `sessioninfo` itself never resets it.
- Idle test: §5.1.
- **What this means for a 5-minute tick:** every second tick lands in the
  second half and renews the session, so the ticks alone keep it alive.
  No keep-alive request is needed. With ticks 15 or more minutes apart
  (the hourly evening ticks), the session is gone, and the tick logs in
  again.

### 5.1 Idle test

From a tab with no scripts (`/sessioninfo` opened as a page). The last
renewal was at 19:26:28 and the last data request at 19:26:59.

| Idle for | Check | Result |
|---|---|---|
| ~4 min | `sessioninfo` (doesn't renew) | alive: 622 s left, counting down as expected |
| ~10 min (so ~5 min is alive too) | `sessioninfo`, then `/Marks/Widget`, then `sessioninfo` | alive: 261 s left. The widget answered normally and **renewed the session to 900 s** |
| 15 min 38 s after the renewal at 19:37:06 | `sessioninfo` | **expired**: `{"success":true,"error":"","data":{"remainingTime":0.0,"sessionDuration":0.0}}` (78 B, `200`, no redirect) |
| ~20 min | `/Marks/Widget` | **expired**: `302` → `/login?ReturnUrl=%2FMarks%2FWidget`, the login page (5.3 KB). Its form's hidden `returnUrl` holds `/Marks/Widget` |
| ~30 min | — | not run: once expired, a session stays expired. Hourly ticks always find it expired |

So a session dies exactly 15 minutes after its last renewal, and an idle
gap of 10 minutes is safe. Two cheap facts for the client:

- `sessioninfo` reports an expired session as `remainingTime: 0.0`
  without a redirect: 78 B to know whether a stored cookie is still good.
- A dead session answers a data request with the login page itself, so
  the client already holds the login form. It could log in from that page
  instead of loading `/login` again (−5 KB). Or, simpler, it can log in
  straight away when its last request was 15 or more minutes ago.

**Cookies:** all HttpOnly (`document.cookie` is empty), so their names
can't be read from the page. *Unverified* which one matters. The app
already stores every `Set-Cookie` at every hop (`_storeCookies`). A
renewal in the second half most likely sends a fresh cookie, so a stored
session cookie (step 3b) must be updated after every request, not only
at login.

**Skipping the dashboard after login:** the login `POST` answers `302` →
`/dashboard` (the browser's navigation shows one redirect). The session
cookie is already set on that `302`, so the client can stop there: treat
"`302` to somewhere other than `/login`" as success. That saves 49 KB per
login. Keep the "still on the login page" failure check.

**Verified: `returnUrl` picks the page after login.** The login form's
hidden `returnUrl` field is where the `302` after the login `POST` goes.
For the owner's second login, the browser opened `/Marks/Widget` while
logged out. It was sent to `/login?ReturnUrl=%2FMarks%2FWidget`, the form
carried `returnUrl=/Marks/Widget`, and after the login the browser landed
on the 2 KB widget (one redirect) instead of the 49 KB dashboard. So a
login can also bring the tick's first answer. For example, with
`returnUrl=/Marks/Widget`, the marks signal arrives with the login.
Either way, following the `302` costs the target page, not the dashboard.

**"Who am I" / keep-alive:** `sessioninfo` is the cheapest logged-in
check (87 B) and doesn't renew. It answers `remainingTime: 0.0` for an
expired session (§5.1). `sessionextend` exists but isn't needed: any data
request in the second half renews.

---

## 6. Komens → Odeslané (sent excuses)

| Request | Size | Notes |
|---|---|---|
| `GET /next/komens.aspx?l=o` | 207 KB, uncompressed | the page |
| list callback with the **whole form** (56 fields, 8.9 KB request) | 55 KB decoded, **2.9 KB gzip** | what the app does today |
| list callback with **only** `__VIEWSTATE` (556 chars), `__VIEWSTATEGENERATOR` (8), `__EVENTVALIDATION` (792), 1.8 KB request | 55 KB decoded, **2.9 KB gzip**, same 10 messages | **works** |
| list callback with no fields | 38 B: `0|/*DX*/({'redirect':'/dashboard?e='})` | fails safely |
| list callback, `pageSize: 1` | 6.7 KB decoded, 1.9 KB gzip | newest message first |
| `POST /Komens/GetMessageDataAsync` (sent message) | 1.6 KB, uncompressed | detail |

- **Without the page:** the callback runs with just those three hidden
  fields. They change on every page load (`__VIEWSTATEGENERATOR` stays the
  same), but a set loaded **10 minutes** earlier in the same session still
  worked (the full list of 10 messages). Across a new login: see §6.1.
- The list holds the default period (one month): 10 messages here, all
  `OMLUVENKA`. Each message appears twice in the HTML (`data-idmsg`).
- The first `data-idmsg` is the highest id, i.e. the newest message.
  There's no count or "newest id" endpoint, but `pageSize: 1` gives the
  newest message for 1.9 KB on the wire. The full list costs only 1 KB
  more (2.9 KB), so a separate "newest id" check isn't worth it.
- Details: only for ids not seen before (step 1 already plans this).
  1.6 KB each.

### 6.1 Cached fields after a new login

The three fields were kept from a page load at 19:26. That session expired
at 19:52, and the owner logged in again at about 20:00. In the new session,
the callback with the **old** fields returned the full list (10 messages,
55 KB decoded). So the fields aren't tied to the session. The app can keep
them in its cache across runs and logins. It should load the page again
only when the reply isn't a message list. That will probably happen after
a Bakaláři update or a server restart (*unverified* how often). The
fields aren't secrets: they're useless without the session cookie.

---

## 7. Compression

Server: IIS 10, ASP.NET 4.0, HTTP/2 to the browser (ALPN `h2`). The
browser offered `gzip, deflate, br, zstd`.

| Reply | Compressed? |
|---|---|
| DevExpress callbacks (`__CALLBACKID` posts: Komens lists) | **gzip** (even with `br` offered) |
| WebForms pages (`.aspx`) | no |
| MVC pages (`/dashboard`, `/Timetable`, `/Absence/Continuous`, …) | no |
| MVC JSON (`GetContentData`, `GetAbsenceBySubjects`, `substitutions/dates`, `GetMessageDataAsync`, `sessioninfo`, events API) | no |
| Dashboard widgets (`/Marks/Widget`, …) | no |
| The school's own CSS (`/App_Themes/…`) | no |

So it is **per handler**, not per content type: DevExpress compresses its
own callback replies, and IIS compresses nothing. `dart:io` asks for
gzip and decompresses it (`autoUncompress`), which already covers the
only compressed replies. **`br` would change nothing.** The savings must
come from fewer and smaller requests.

---

## 8. Overhead per request and per connection

| What | Size | Source |
|---|---|---|
| Reply headers | ~0.3 KB | browser's `transferSize − encodedBodySize` |
| Request headers from the app (User-Agent, cookies, Accept-Language, …) | ~0.5–0.8 KB | estimate (*unverified*: cookie length unknown) |
| Full TLS handshake | **~5.5 KB down + 0.4 KB (TLS 1.2) or 1.6 KB (TLS 1.3) up** | `openssl s_client`, 3-certificate chain |
| TCP setup and teardown | ~0.5 KB | estimate |
| Server keeps an idle connection | **at least 10 min** after a request (and at least 400 s with no request); both tests ended on my side, not the server's | `openssl s_client`: one anonymous `GET` of the Bakaláři logo over HTTP/1.1, then idle |

`dart:io` speaks HTTP/1.1 and keeps a connection open for 15 s by default
(`HttpClient.idleTimeout`). Between 5-minute ticks the connection is
therefore new every time, and the TLS handshake (~6–7 KB) costs more than
the tick's data (~6 KB).

The server would keep the connection much longer. So where the process
lives on between ticks (desktop, Android with the UI isolate alive), an
`idleTimeout` of ~6 minutes would let the next tick reuse the connection
and skip the handshake. Mobile networks may still drop an idle connection
sooner (*unverified*). The client already retries a read once when a
kept-alive connection was dropped (`isDroppedReadError`). *Unverified*
whether `dart:io` resumes TLS sessions, which would cut a new handshake to
~1 KB.

---

## 9. Recommended quick tick

Every 5 minutes in school hours, hourly otherwise until 22:00:

| # | Request | Data | If it changed |
|---|---|---|---|
| 1 | `GET /Marks/Widget` | 2.0 KB | `GET /next/prubzna.aspx` (187 KB) in the same tick; notify new marks |
| 2 | `POST /Timetable/substitutions/dates` | 3–5 KB | `GetContentData` for the week(s) whose entries changed (50–85 KB each) |
| 3 | `GET /Absence/Continuous/GetAbsenceBySubjects` (range: 1 Sep → today) | 1.2–3 KB | new numbers shown at once; if a `Count` grew, this week's `GetContentData` |
| (4) | `GET /Dashboard/NoticesWidget` (optional) | 0.4 KB | as #1 |

Per tick, with the session still alive: **~6–10 KB of data + ~3 KB of
headers + ~7 KB for a new TLS connection ≈ 16–20 KB**. With a login (the
session expired: hourly ticks): + `GET /login` (~6 KB) + `POST /Login` and
its `302` (~1.5 KB, not following it to the dashboard) ≈ **24–28 KB**.

A quick tick never reads Komens and never sends an excuse (proposal §3).

### Per school day

Every 5 minutes from 7:30 to 15:30 (96 ticks), hourly from 6:00 to 7:30
and from 15:30 to 22:00 (8 ticks), nothing at night.

| Part | Count | Each | Per day |
|---|---|---|---|
| Quick ticks, school hours (session reused) | 96 | ~17 KB | ~1.6 MB |
| Quick ticks, rest of the day (new login each) | 8 | ~26 KB | ~0.2 MB |
| Marks page after the widget changed | ~3 | 187 KB | ~0.6 MB |
| A week after its feed changed | ~3 | ~70 KB | ~0.2 MB |
| Safety net: this week hourly in school hours | 8 | ~65 KB | ~0.5 MB |
| Strava | ~30 | ~6 KB | ~0.2 MB |
| Full runs (first of the day ~640 KB, then ~340 KB) | 3 | — | ~1.3 MB |
| **Total** | | | **~4.6 MB** |

The full runs with this research applied: this and next week (~130 KB),
the marks page (187 KB), absence JSON, feed, Komens list via the cached
fields (3 KB) plus new details only, login without the dashboard: about
340 KB. The first run of the day adds the past weeks (~210 KB), the
permanent timetable (85 KB) and the subject list (4 KB): about 640 KB.

A day off (weekend, holiday): 16 hourly ticks (~0.4 MB) + the full runs
(~1.3 MB) ≈ **1.7 MB**.

Requests to the school server: ~96 × 3 + 8 × 5 + 3 × ~20 + ~10 triggered
≈ **400 a day**, against ~670 today (28 per hourly refresh). Most are
small.

---

## 10. New things worth using (ideas only)

All read-only, web only. Never call the write endpoints these pages
also carry (listed per row).

| Idea | Where | Size | How it helps a student | Fits? |
|---|---|---|---|---|
| **School calendar: events, tests, trips, free days** | `GET /core/Events/Api/Agenda/Load?filterParameters={"CurrentView":"agenda","DateFrom":…,"DateTo":…,"ClassIds":[],"TeacherIds":[],"RoomIds":[],"EventTypeIds":[],"ShowOnlyMyEvents":true}` → list of `{Id, Name, DateFrom, DateTo, IsAllDay, Type, PublishedDate, Detail{…}}`; `Type` 2 = event, 3 = national holiday, 4 = school holiday | **4 KB** for 4 weeks with `ShowOnlyMyEvents: true` (46 KB for the whole school) | upcoming trips and events, and the school's own free days, so the app needn't guess them (it would also feed F6 "school hours" and the before-alarm tick) | yes (GET). Never `…/Insert`, `…/Update`, `…/Delete`, `…/SendEmails` |
| **New Komens messages + unread count** | inbox list callback (`/next/komens.aspx`, `hfListType` = `prijate`) with `onlyUnread: true`, using cached fields as in §6 | ~0.9 KB gzip when empty; ~2–3 KB gzip for a month of messages (measured on Odeslané: 1 message 1.9 KB, 10 messages 2.9 KB) | "new message from the class teacher" notification without opening Bakaláři | yes, **list only**: never call `GetMessageDataAsync` for a received message, since opening marks it read (*unverified* whether the detail call alone does; assume it does) |
| **Homework** | `POST /HomeWorks/Student/LoadHomeworks` `{"homeworkState":3,"onlyUnfinishedHomeworks":false}` (3 = current, 4 = after deadline, 2 = closed); `GET /HomeWorks/Widget` | 37 B (no homework at GEKOM for this student); widget 149 B | a list of what's due, with deadlines | yes. Never `/HomeWorks/MarkAsFinished` (a write). Reply shape *unverified* (empty) |
| "Nové známky" badge | `GET /Dashboard/NoticesWidget` | 0.4 KB | the same count the web shows | yes |
| Behaviour notes (*Výchovná opatření*) | `GET /next/vychovna.aspx`, server-rendered | 46 KB | notify a new praise or reprimand | yes, daily read; HTML parsing |
| Class notice board (*Nástěnka*) | `GET /next/nastenky.aspx` | 61 KB | school notices | yes, daily read |
| Absence per lesson | already in `GetContentData` (`absenceType`); `GET /Timetable/Widget?date=` (14 KB, `absent` class) | — | the app has it already | — |
| Absence calendar | `GET /Absence/Continuous/GetAbsenceOverview` | 40 KB | a month-by-month heat map | yes, low value |
| Failed logins warning | `GET /Dashboard/GetBadLogins` | 81 B | "someone tried your password" | yes, low value |

Seen but not used: `/next/vyuka.aspx` (lesson topics, 225 KB),
`/PortalMessages` (42 KB), `/next/opravne.aspx` (45 KB),
`/Questionnaire/Filling?mode=Ankety`, `/core/Reports/Confirmations`. The
dashboard also `POST`s `/UIState` (it saves the dashboard layout): a
write the app must never make.

---

## 11. What couldn't be verified

- A mark, an absence or a timetable change appearing **live** (holiday,
  no lessons). The owner's measuring build should check: a new mark is
  noticed by the widget within one tick.
- The order of several marks given on the same day in the widget.
- What makes a mark "new" (looks like 7 days).
- Which cookie carries the session (HttpOnly).
- Whether the app's own login `POST` with `returnUrl` behaves like the
  browser's (it should: same form, same field).
- How long cached Komens fields stay valid (they survived a new login).
- `Canceled` lessons and short-notice free days in the feed.
- TLS session resumption in `dart:io`.
- Homework reply shape (no homework).
