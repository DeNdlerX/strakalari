# Prompt for the F6 research agent (real Bakaláři, read-only)

The owner pastes everything below the line into a **new session in the
Claude desktop app (Code tab)**, opened on this repository, so the
built-in browser is available. Run it only while the implementing agent is
stopped, because both write to `docs/qa-roadmap/`.

---

You research how **Strakaláři** can refresh with as little data as possible,
so that **new marks, timetable changes and new absences show up within 5
minutes**. Strakaláři is a Flutter + Dart app for students. It reads
Bakaláři (the school system) through its **web** interface, and orders
lunches on Strava.cz. The owner isn't technical: you make the technical
calls, and you report in plain language.

You do research only. You write no app code and change no setting
anywhere.

## Read first

- `docs/qa-roadmap/proposal-F6-low-data.md`: the plan your results feed
  (step 0 is you). Its §2 has the owner's measurement of one refresh,
  request by request.
- `docs/qa-roadmap/STATUS.md`: the F6 row and the owner's answers. Above
  all: "I want new marks to be visible in the 5 minutes, thats kinda the
  point."
- `docs/BAKALARI_API.md`: every Bakaláři web request the app already
  uses, with sizes and shapes. Don't rediscover these. Measure them and
  look for smaller ones.
- The code that fetches today:
  - `packages/strakalari_core/lib/src/bakalari/http_session.dart`
    (login, session, cookies);
  - `client.dart`, `timetable.dart`, `data.dart`;
  - `packages/strakalari_core/lib/src/automation/refresh.dart`.
- `CONTRIBUTING.md` §5 (the safety rules the later design must keep).

## Where you work

- Worktree: `C:\Users\matou\Documents\Programy\Python\strakalari\.claude\worktrees\qa-roadmap`,
  branch `qa-roadmap`. Never touch the main checkout or its personal files
  (`config.json`, `data_cache.json`, `log.txt`, `htmls/`, `secret.key*`).
- You may create or change only three files:
  - `docs/qa-roadmap/research-F6-bakalari-web.md` (new, your report);
  - `docs/qa-roadmap/proposal-F6-low-data.md` (update §2, §4, §5, §8);
  - `docs/qa-roadmap/STATUS.md` (one line in the F6 row's notes).
- Commit only those files, by path (`git commit -- <paths>`), as the
  configured git user. Plain message, no `Co-Authored-By`,
  `Claude-Session` or "Generated with" lines. Never push.

## The real Bakaláři

- Load the built-in browser's skill (`anthropic-skills:built-in-browser`)
  first. Then open `https://bakaweb.gekom.cz` in the built-in browser and
  ask the owner to sign in there. You never type, see or store the
  password, and you never sign out.
- This is a real student's account at a real school. Everything is
  **read-only**:
  - Never send, save, submit, delete or change anything: no excuses
    (*Omluvenky*), no Komens messages, no settings, no profile, no form
    submit. Don't press anything like *Odeslat*, *Uložit*, *Potvrdit*,
    *Smazat* or *Omluvit*. If you aren't sure a click is harmless, don't
    click it; ask the owner.
  - Don't open unread Komens messages in the inbox: opening one marks it
    read. Sent messages (*Odeslané*) are fine to open.
  - **Web only:** the pages, their own XHR/JSON endpoints and postbacks.
    Never the mobile API (`/api/login`, `/api/3/…`), not even to compare.
  - **Look first, replay little.** Read the network log of normal
    navigation (`read_network_requests`) for URLs, methods, bodies and
    sizes. You may replay a **read-only** request the page itself made
    (same method and URL, maybe a smaller parameter) with `fetch()` in
    the page, to measure it or test a smaller variant. Examples: a GET,
    or a data-read POST such as `GetContentData`, `GetAbsenceBySubjects`,
    `substitutions/dates` or a list callback. Never replay anything that
    sends, saves or marks something read.
  - Be gentle with the school's server: at most ~150 requests in total,
    spaced out.
- **Personal data:** you'll see real marks, names, teachers and messages.
  - None of it goes into the repository, the report or your messages.
  - Record only: paths, methods, parameter names, the response shape
    (keys, types), sizes, compression and cache headers. Use made-up
    example values.
  - No screenshots in the repository. If you need one to think, keep it
    in your scratch space and delete it at the end.
- If the browser pane isn't available, or the owner can't sign in, stop
  and say so.

## What to find

For each request: method and path, parameters, size on the wire and
decoded, whether it's compressed, cache headers (`Cache-Control`, `ETag`,
`Last-Modified`, and whether a `304` is ever returned), what makes it
change, any side effect, and how a client could tell "changed" from "same"
as cheaply as possible.

1. **New marks (the priority).** Find the smallest web request that shows
   a new mark, so a check every 5 minutes is cheap. Things to try:
   - Does `/next/prubzna.aspx` load its marks through its own callback or
     JSON? Can that request be filtered (one subject, one period, only
     new marks)?
   - Does the dashboard show recent or new marks, and does it load them
     through its own small XHR? Any badge or count endpoint (bell icon,
     unread counts, "nové známky")?
   - Komens messages of the marks type: the Komens list callback has an
     `onlyRating` flag.
   - Anything that answers `304`, or carries a version or timestamp you
     could compare.
   If nothing small exists, say so, and give the cheapest full read
   (sizes per variant).
2. **Timetable changes.** Is `/Timetable/substitutions/dates` (~5 KB)
   complete? Does it list cancelled, added and moved lessons and room
   changes, for this week and next? Compare it with the full current week
   from `GetContentData`. Can `GetContentData` return less (one day, a
   smaller term)?
3. **New absences.** The smallest request that shows a new absence (a
   narrower `GetAbsenceBySubjects` range, a dashboard tile, …). Can the
   date range be worked out without loading `/Absence/Continuous`
   (58 KB)?
4. **Login and session.** How long an idle session stays alive: try the
   cheapest request after about 5, 10, 20 and 30 minutes without
   activity. Which cookies matter? Can the redirect to `/dashboard`
   (49 KB) after login be skipped? Is there a keep-alive or "who am I"
   endpoint?
5. **Komens → Odeslané (sent excuses).** Can its list callback run
   without first loading the 200 KB page (for example with values cached
   from an earlier load)? Is there a cheaper count or "newest id"? Read
   only *Odeslané*, never send.
6. **Compression.** Which replies come gzip'ed, and is it per endpoint or
   per content type? The app's `dart:io` client asks for gzip only.
   Would `Accept-Encoding: br` change anything?
7. **New things worth using** (ideas only, nothing built). Data the web
   offers that the app doesn't use yet, for example:
   - homework;
   - tests and events (*Plán akcí*);
   - class notices;
   - the Komens inbox unread count;
   - absence per lesson;
   - behaviour notes.
   For each: where it lives, its size, how it would help a student, and
   whether it fits "web only, read-only".

## What you deliver

1. `docs/qa-roadmap/research-F6-bakalari-web.md`:
   - a table per item above (request, size, change signal, side effects,
     verdict);
   - a recommended **quick tick** that covers marks, timetable and
     absence every 5 minutes, with bytes per tick and per day. Assume
     every 5 minutes from 7:30 to 15:30 on school days, hourly otherwise
     until 22:00, and nothing at night. Add login and TLS overhead.
   - the session findings;
   - the new-features list.
   Mark anything you couldn't verify as *unverified*.
2. `proposal-F6-low-data.md`: update §2 (findings), §4 (the quick tier
   with the marks signal, step 5), §5 (the estimate) and §8 (answered
   questions). Keep every safety point in §3.
3. `STATUS.md`: one line in the F6 row's notes pointing to the research
   file. Don't change *Next step*.
4. Tell the owner in 3–6 plain sentences:
   - the smallest way you found to spot new marks;
   - the expected data per day at a 5-minute check;
   - any risk;
   - the two or three best new-feature ideas.

Then stop. F6 still needs the owner's "go", a design note and a review
before any code.
