# F2 research: Komens → Odeslané, periods and paging on the real Bakaláři

Looked up on 2026-11-20 by the reviewer in the owner's logged-in browser
(GEKOM, `bakaweb.gekom.cz`), at the owner's word (STATUS, *D2 / F2*).
Read-only: only page loads and the page's own list callback. Nothing was
sent, deleted, suppressed or marked. No `/api/3`. This note holds no
personal data: no names, texts or message ids, only counts, period dates
and how the server answers. It stands in for the "saved Komens page with
more than one page" that PLAN §6 (F2) asks for.

## 1. The period is chosen by the page address

The period buttons on Odeslané (*Den, Týden, Měsíc, 1. pololetí,
2. pololetí, Školní rok, Starší*, and *Filtrovat* with two dates) all call
`IntervalClick(interval, from, to)`, which only loads the page again:

```
/next/komens.aspx?s=<interval>&l=o[&from=ddmmyyyy&to=ddmmyyyy]&filter=<json>
```

`filter` holds the recipient checkboxes and the search text; without it the
server uses its defaults (all recipients), which is what the app wants.
Labels (`#cphmain_obdobiLabel`) seen on 2026-11-20:

| Address | Label | Sent messages in it |
|---|---|---|
| `?l=o` (what the app loads today) and `?s=mesic&l=o` | 21.10.2026 - 20.11.2026 | 10 |
| `?s=1polo&l=o` | 20.8.2026 - 31.1.2027 | 17 |
| `?s=2polo&l=o` | 20.1.2027 - 31.8.2027 | (future) |
| `?s=rok&l=o` | 20.8.2026 - 31.8.2027 | 17 |
| `?s=starsi&l=o` | 1.1.2000 - 20.8.2026 | 49 |
| `?s=custom&l=o&from=01092026&to=20112026` | 1.9.2026 - 20.11.2026 | 17 |

- Every one of them is `hfListType` = `odeslane`, about 205 KB, like today.
- The label's first date is what `_outboxPeriodStart` already reads.
- *2. pololetí* starts on 20.1., before *1. pololetí* ends (31.1.). That
  is the school's own setting.
- All messages seen here were excuses (`badgeExcuse` on every row).

**The period belongs to the loaded page, not to the session.** After that
page was loaded, loading other periods in the same session (`?s=starsi`,
`?l=o`) did not change what the first page's list callback returned (still
its own 17). So the app's pair "GET the page, then the list callback with
that page's fields" always lists the period of the page it loaded.
Consequence for F6 (cached form fields): cached fields keep their period.
Fields from a `custom` page with `to` = today would keep ending on that
day and miss newer messages; `?s=rok` ends on 31.8. and has no such
problem.

## 2. The list callback and paging

The page's own call (`PerformCallbackOnMessagesList`):

```
{"showRepressed":false,"pageNumber":N,"pageSize":21,"reloadMessages":B,
 "sortOrder":0,"onlyRating":true,"onlyExcuses":true,
 "onlySystemMessages":true,"onlyGeneralMessages":true,"onlyUnread":false}
```

The page uses `pageSize = 20` and sends `pageSize + 1` to learn whether
more exist. On first load it sends `pageNumber: 1, reloadMessages: true`.
When the list is scrolled to the bottom and the last reply held more than
20 messages, it sends `pageNumber + 1` with `reloadMessages: false`. The
app today sends the same shape with `pageNumber: 1`,
`pageSize: sent_excuses_limit + 1`, `reloadMessages: true`.

What the server answered (message counts in the raw reply, newest first,
ids descending):

| Period | Request | Messages in the reply | `hfLoadedMessagesCount` | `hfAllMessagesLoaded` |
|---|---|---|---|---|
| 1. pololetí (17) | page 1, size 6, reload `true` | 6 (1–6) | 6 | "" |
| | page 2, size 6, reload `false` | **12 (1–12)** | 6 | "" |
| | page 3, size 6, reload `false` | 17 (1–17) | 5 | "" |
| | page 4, size 6, reload `false` | 17 (1–17) | 0 | "all" |
| | **page 2, size 6, reload `true`** | **6 (1–6)** | 6 | — |
| | **page 3, size 6, reload `true`** | **6 (1–6)** | 6 | — |
| | page 1, size 101, reload `true` | 17 (1–17) | 17 | — |
| Starší (49) | page 1, size 21, reload `true` (the page's own load) | 21 | 21 | "" |
| | page 2, size 21, reload `false` | 42 (1–42) | 21 | "" |
| | page 3, size 21, reload `false` | 49 (1–49) | 7 | "" |
| | page 4, size 21, reload `false` | 49 | 0 | "all" |
| | page 1, size 1000, reload `true` | **49, same order** | 49 | "all" |

What this means for F2:

1. **A reply with `reloadMessages: false` holds every message up to that
   page,** not only the new page. Page N's reply is the whole list so far;
   `hfLoadedMessagesCount` counts only the new page.
2. **`reloadMessages: true` ignores `pageNumber`** and always returns the
   first page. A loop that sends page 2, 3, … with `reloadMessages: true`
   (the app's current shape) reads page 1 again and again, and would look
   like a complete read while missing everything after page 1.
3. **One request with a large `pageSize` returns the whole period.** Size
   1000 returned all 49 in the same order as the paging, in about 0.3 s. No
   server cap was seen up to 49 messages.
4. **The end of the list:** a reply with fewer messages than the requested
   `pageSize` is complete. A reply with exactly `pageSize` messages may
   have more behind it: read further (page N+1 with `reloadMessages:
   false`) or count the read as failed (PLAN: a failure on any page is a
   failed outbox read, so auto mode doesn't send). Don't rely on
   `hfAllMessagesLoaded`: it was "" after a short last page (5 of 6, 7 of
   21) and "all" only after an empty page or a single short reload read.
5. **Size:** the decoded reply is about 5.4 KB a message (17 messages:
   92 KB decoded). The callback is gzip on the wire (F6 research §6: 55 KB
   decoded = 2.9 KB gzip for 10 messages), so a school year of excuses is a
   few tens of KB. The cost is in the details: `GetMessageDataAsync` is
   about 1.6 KB per message, uncompressed, so details should be read only
   for ids not already known (as F6 step 1 plans), and `sent_excuses_limit`
   (default 100) must not cut a semester short.

## 3. Which period covers "the whole semester"

The owner wants the excuse history to cover the whole semester (D2). An
excuse can be sent before its lesson (planned in advance) or after it,
and auto mode looks back `go_back_weeks` (default 4). Near the semester
change, early February lessons can have excuses sent in January, and
February runs still look back into January. `?s=2polo` alone starts on
20.1. and would not show an excuse sent earlier.

`?s=rok&l=o` (20.8. – 31.8.) covers both semesters, every advance excuse
within the school year, and the look-back at the semester change, for
little more data. A `custom` range from the earlier of the semester start
and the oldest lesson auto mode looks at also works, but its fixed `to`
date must not be cached (§1). This is the agent's call within D2; the
reviewer will check that no lesson auto mode may excuse can fall outside
the period read.

## 4. What the demo server needs (`tools/bakalari_demo_server.py`)

Today `outbox_page()` always labels the last 30 days, and the list callback
returns every message, ignoring the period and all callback parameters. To
page "the same way":

- `GET /next/komens.aspx` honours `s` (`mesic` default, `1polo`, `2polo`,
  `rok`, `starsi`, `custom` with `from` / `to` as `ddmmyyyy`), writes the
  matching label, and carries the period in the page's own form state
  (for example in the `__VIEWSTATE` value), since the real server binds it
  to the page and not to the session.
- The callback reads `__CALLBACKPARAM` (`c0:` + JSON), keeps the messages
  sent inside the page's period, newest first, and answers:
  `reloadMessages: true` → the first `pageSize` messages, whatever
  `pageNumber` is; `reloadMessages: false` → the first
  `pageNumber × pageSize` messages (the whole list so far). It sets
  `hfLoadedMessagesCount` to the number of messages new in this page.
- Tests use the numbers above: 17 messages with size 6 → 6, 12, 17, 17;
  49 with size 21 → 21, 42, 49, 49; size 1000 → all at once.
