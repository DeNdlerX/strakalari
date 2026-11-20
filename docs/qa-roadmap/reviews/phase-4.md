# R4 review: F2 (complete excuse history)

Reviewed 2026-11-20 at `qa-roadmap` @ `c1d886e` (base `main` @ `bfe4860`;
`main` has no commits the branch lacks, and the phase started with the
merge `2f100bc`). Commits since the R3c re-review and the merge into
`main`:

- `8a88414` the reviewer's read-only research note
  `research-F2-komens-outbox.md` (stands in for the saved multi-page
  Komens sample, at the owner's word);
- `2f100bc` merge of `main` @ `bfe4860`;
- `f478081` F2, one commit for the item;
- `c1d886e` STATUS.

Checked against PLAN §6 (phase 4), §9, the owner's D2 answers in STATUS,
the research note, report §3.4 (background), CONTRIBUTING §5–6 and every
earlier review.

## Verdict: FAIL

F2 does what D2 asks, and most of it is done carefully. The app now reads
Komens → Odeslané for the whole school year (`?s=rok&l=o`), walks every page
of the list the way the real page does (page 1 fresh, then cumulative
pages), and fails the whole read when any page, any message detail or the
limit goes wrong, so automatic excusing then stops. The excuse window
reaches back to the start of the running semester (1 September or
1 February, with the 30-day window kept across the change) and never past
the first day the outbox read covered. Older school-year weeks of the
timetable are re-read once a day so the wider window never acts on week
data frozen months ago. The demo server pages exactly like the real
server: the reviewer's own probe reproduces every number of the research
table. All suites are green, no test was removed or changed, the parity
fixtures are untouched, and the send path itself (`sendExcuse`,
`excuse_history.dart`'s coverage check, `HistoryLock`, the audit,
`automation_paused`) is unchanged.

The reviewer undid 22 parts of the fix one at a time in a throwaway copy:
18 are caught by the new tests (table below). Of the 4 misses, 2 are
redundant second layers that are fine, and 2 are real gaps (S1, S3).

One finding blocks the pass:

- **M1:** the new cache of read excuse messages also stores a message
  whose details came back empty or unreadable. That message then counts as
  "excuses nothing" for good: the app never reads it again, and in
  automatic mode it can send a second excuse for lessons that message
  already excused (when it was sent from the website or another device).
  Before F2 such a bad read was corrected on the next refresh.

Four should-fix:

- **S1:** two server answers that would mean an incomplete list (page 2
  repeating page 1, or pages that aren't cumulative) are taken as a
  complete read. Needs more than 100 excuse messages in a school year to
  matter; the three paging guards have no tests.
- **S2:** when one timetable week doesn't load, every following refresh
  re-reads the whole semester (8 weeks today, up to 18 in January) instead
  of only that week.
- **S3:** the test that should prove "page 2 fails, so nothing is sent"
  passes for another reason (its fake server has no message details), so
  it doesn't catch a page-2 error being ignored.
- **S4:** the message cache has no version, so a later fix to how excuse
  messages are read would never reach messages already cached.

Two owner decisions are needed (Q1, Q2 below): what happens for older
installs that keep the hidden limit of 100, and a confirmation that older
absences back to the start of the semester may now be excused
automatically.

---

## Must-fix

### M1 (F2, `f478081`): an empty or unreadable message detail is cached for good

- **Where:** `packages/strakalari_core/lib/src/bakalari/data.dart:213–225`
  (`fetchSentExcuses`): every message id gets
  `nextCache[key] = entries`, also when `entries` is empty. `:213` then
  reuses the cached value on every later sync, so the message is never
  read again. `sentExcuseEntries` (`extractors.dart:558`) returns `[]`
  when the detail isn't a map (`{"success": true, "data": null}`), when a
  date doesn't parse (`ArgumentError`, e.g. after a format change on the
  school's server) and, by design, for a time-based excuse.
- **What is wrong:** a one-off bad answer for one message becomes
  permanent. The cache is saved to `data_cache.json` (`komens_outbox_details`)
  and seeded into every new client (`automation.dart:1095–1098`), so it
  survives restarts too. From then on the history never learns which
  lessons that message excused. If it was sent outside this install (on
  the website, on another phone, before a reinstall), `generateExcuses`
  sees those lessons as still unexcused and automatic mode sends a second
  excuse, which can't be taken back. Before F2 every sync re-read every
  message, so the same bad answer cost one refresh at most.
- **Reviewer's check** (throwaway test, not committed): first sync with the
  detail answering `{"success": true, "error": null, "data": null}`, then
  a correct detail. Result at `f478081`: the second sync still returns `[]`
  and makes no detail request (`Expected: [{type: pure days, starting_day:
  03.09.2026, …}]`, `Actual: []`).
- **What correct looks like:** one commit,
  `F2: don't cache an excuse message that gave no entries (R4 M1)`.
  - In `fetchSentExcuses`, store `nextCache[key]` only when `entries` is
    not empty. A message with no entries is read again on every sync (a
    time-based excuse costs one small request per refresh; that's fine).
  - Test in `packages/strakalari_core/test/bakalari_data_test.dart`
    (group `sentExcuses`); it must fail at `f478081`:
    ```dart
    test('aDetailThatGaveNoEntriesIsReadAgainNextSync (R4 M1)', () async {
      var good = false;
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': outboxListing(['501'], const []),
        'POST /Komens/GetMessageDataAsync': (FakeRequest _) => {
              'success': true,
              'error': null,
              'data': good ? excuseDetail('3.9.2026') : null,
            },
      });
      final bak = BakalariClient(Map.of(fakeConfig), transport: server);
      expect(await bak.fetchSentExcuses(), isEmpty);
      expect(bak.knownOutboxDetails.containsKey('501'), isFalse);
      good = true;
      expect(await bak.fetchSentExcuses(), [
        {'type': 'pure days', 'starting_day': '03.09.2026', 'ending_day': '03.09.2026'}
      ]);
      expect(server.calls('POST', '/Komens/GetMessageDataAsync'), hasLength(2));
    });
    ```

---

## Should-fix

### S1 (F2, `f478081`): a repeated or non-cumulative page is taken as the end of the list; the paging guards are untested

- **Where:** `packages/strakalari_core/lib/src/bakalari/data.dart:298–367`
  (`fetchAllOutboxIds`). The end test `:354`
  (`allIds.length < pageNumber * size`) runs before the no-progress check
  `:357`, so that check can never fire: a page with no new id is always
  shorter than `pageNumber * size`. The shrink check `:340` only catches a
  reply that got shorter.
- **What is wrong:** the research note warns about exactly this: a page
  that only repeats page 1 "would look like a complete read while missing
  everything after page 1". Today's real server answers cumulatively, so
  this needs a server change (or a proxy/cache in between) and more than
  100 excuse messages in the school year. But the result would be a silent
  partial read, which PLAN §6 rules out, and `_settleUnconfirmed` and the
  window trust that read.
- **Reviewer's check** (throwaway tests, not committed), page size 4:
  - page 2 answers page 1 again (8 ids in all): read accepted with 4
    excuses (`Expected: null`, `Actual: [...]`);
  - pages answer only their own 4 ids (12 in all): read accepted after 8
    of 12 details.
  - Undoing the shrink guard (`:340`) or the no-progress guard (`:357`)
    breaks no test, and no test reaches the 50-page guard (`:361`).
- **What correct looks like:** one commit,
  `F2: fail the outbox read when a page is not cumulative or adds nothing (R4 S1)`.
  For page N > 1, in this order:
  1. the reply must contain every id of the previous reply (it is the
     whole list so far), else throw (this replaces the shrink check);
  2. if it adds no new id, it is the end only when the reply says so:
     `hfAllMessagesLoaded` = `all` or `hfLoadedMessagesCount` = `0` (the
     real server and the demo server both answer that way to the empty
     overflow read, research §2 table); otherwise throw ("no progress");
  3. otherwise the end is a reply with fewer than N × size rows, as now.
  Keep the 50-page guard. Tests in `bakalari_data_test.dart`, each must
  fail at `f478081` except the last two, which pin the guards:
  - page 2 repeats page 1 → `fetchSentExcuses()` returns null;
  - pages that aren't cumulative (page 2 = ids 5–8 only) → null;
  - an exact multiple (12 ids, size 6) whose third reply carries the
    markers → all 12 read, 3 callbacks;
  - page 2 lacks an id of page 1 → null;
  - `fetchAllOutboxIds(session, maxPages: 3)` with a list that is always
    full → throws.
  The `(12, 6, [6, 12, 12])` case of
  `fetchesWholeSchoolYearPeriodAndPagesCumulatively` (`:181`) will then
  need its fake to send the two hidden fields the way the real server does
  (`hfLoadedMessagesCount` = new rows in this reply, `hfAllMessagesLoaded`
  = `all` when that is 0). That makes the fake match the server; it is not
  a weaker test, and the reviewer accepts it.

### S2 (F2, `f478081`): one week that doesn't load makes every refresh re-read the whole semester

- **Where:** `packages/strakalari_core/lib/src/automation/refresh.dart:408–418`
  (`_recordHistoryWeeks`): `semester_reconciled` is written only when
  every semester week loaded (`allSemesterLoaded`). Until then
  `:504–507` drops every semester week from `done`, so the next run
  requests all of them again.
- **What is wrong:** a week that comes back as another week is skipped on
  purpose (`timetable.dart`, "did not load … skipping it this run"). If
  that keeps happening for one week, every refresh re-reads 8 weeks
  today and up to 18 in late January (about 70 KB each), instead of the one
  week. The owner cares about data use (F6).
- **Reviewer's check** (throwaway test in `refresh_test.dart`, not
  committed): run 1 on 2026-11-20 with the week of 14 September not
  loading, run 2 the same day: run 2 asks for every week from 31 August
  (`Expected: [2026-09-14]`, `Actual: [2026-08-31, …]`).
- **What correct looks like:** one commit,
  `F2: retry only the week that did not load (R4 S2)`.
  - In `_recordHistoryWeeks`, set `semester_reconciled` to today whenever
    it runs (it runs only after the Bakaláři fetch finished, so every
    semester week was requested in this run) and drop `allSemesterLoaded`.
    A week that never loaded stays out of `weeks`, so `_missingHistoryWeeks`
    retries just that week on the next run, as before F2.
  - New test in the `f2SemesterReconciliationAndOutboxCache` group: run 1
    with `skipHistoryWeeks: {2026-09-14}`, run 2 the same day (also
    skipping it) → `app2.recordedHistoryRequests.single` equals
    `[DateTime(2026, 9, 14)]`. Must fail at `f478081`.
  - `incompleteSemesterBackfillDoesNotMarkReconciled`
    (`refresh_test.dart:957`): the assertion at `:970` changes, by this
    decision, to `hist['semester_reconciled'] == '2026-11-20'` plus
    `hist['weeks']` not containing `'2026-09-14'`; rename the test to say
    the week is retried alone. Its second half (`contains(skipped)`, then
    reconciled) stays.

### S3 (F2 test, `f478081`): the page-2 auto-mode test passes without the page-2 check

- **Where:** `packages/strakalari_core/test/automation_test.dart:1253`
  (`pageTwoFailureBlocksAutoExcuseAndLeavesHistoryAndUnconfirmedUntouched`).
  Its fake server has no `POST /Komens/GetMessageDataAsync` route.
- **What is wrong:** with page-2 errors ignored in `fetchAllOutboxIds`
  (the reviewer's mutation), the read still fails because the message
  details 404, so the test stays green. PLAN §6 asks for exactly this
  test ("a failure on any page … auto mode doesn't send"), so it must fail
  when the page-2 failure is ignored. (The client-level test
  `pageTwoFailureOrDetailFailureFailsWholeRead` does catch it.)
- **Reviewer's check:** the same test with a detail route added catches
  the mutation (`lastOutboxSyncOk`: `Expected: false`, `Actual: <true>`)
  and passes on `f478081`.
- **What correct looks like:** one commit (test only),
  `F2: make the page-2 auto-mode test depend on page 2 (R4 S3)`: add
  `'POST /Komens/GetMessageDataAsync'` returning a valid excuse detail
  (e.g. `03.09.2026`, a day without the test's absences) and
  `expect(server.calls('GET', '/next/komens_zprava.aspx'), isEmpty)`. No
  other assertion changes.

### S4 (F2, `f478081`): the message cache has no version

- **Where:** `packages/strakalari_core/lib/src/storage/cache.dart:25`
  (`outboxDetailsKey`), `data.dart:223`, `automation.dart:503`.
- **What is wrong:** the cache stores what `sentExcuseEntries` made of each
  message, not the message. If a later version fixes how a detail is read
  (a new date format, hour captions), every message already cached keeps
  the old result for good, and nothing says so. Wrong entries there decide
  whether an excuse is sent.
- **What correct looks like:** one commit,
  `F2: version the outbox message cache (R4 S4)`: put a version in the key
  name (`komens_outbox_details_v1`) or store `{"v": 1, "items": {…}}` and
  ignore any other version when seeding; say in the doc comments of
  `outboxDetailsKey` and `sentExcuseEntries` that a change to what
  `sentExcuseEntries` returns must bump it. Test: a cache under another
  version is not used (the details are read again).

---

## Owner decisions needed

### Q1: older installs keep the hidden limit of 100 sent excuses

Every existing `config.json` holds `"sent_excuses_limit": 100` (the old
default; only new installs get `0`). There is no setting for it in the app.
Since F2, when a student has sent **more than 100 excuses in the school
year**, the outbox read fails on purpose and **automatic excusing stops for
good**, with the general message that Komens couldn't be read. Nothing wrong
is sent; the student just has to excuse by hand. This answers the agent's
open question in STATUS: the setting must not be changed silently
(CONTRIBUTING §6).

Options for the owner:

- **(a) recommended:** the app keeps working for them. It reads the newest
  100 excuse messages and automatically excuses only absences after the
  oldest of those 100 (older ones have to be excused by hand). That is how
  the app worked before F2 with its one-month list, and 100 messages
  usually cover the whole semester anyway. For the agent: when the limit
  is exceeded, read the details of the newest `limit` excuse ids only, set
  `sentExcusesFrom` to the sent date of the oldest of them (its
  `data-sortdate`; no date → fail the read as now), and log one line.
  `semesterExcuseWindowStart` and `_settleUnconfirmed` then stay inside
  what was read. Tests: 6 excuses with limit 5 → 5 details read,
  `sentExcusesFrom` = the 5th newest's day, an absence before it is not
  pending, one after it is.
- **(b)** leave it as it is now (safe; automatic excusing stops for those
  students).

If the owner answers, write it word for word into STATUS; the agent then
does (a) as one commit `F2: limit narrows the window instead of stopping
(R4 Q1)` in the same round. Without an answer, nothing changes.

### Q2: older absences can now be excused automatically

This is what "the whole semester" (D2) means in practice, so only a
confirmation: for students with automatic excusing on, the app now also
excuses absences back to 1 September (from February: 1 February) that are
still unexcused in Bakaláři and not in the history, including ones a
teacher already marked *neomluvená*. Before, it stopped at 30 days. The
first refresh after the update may therefore send several older excuses
at once. Students in the default *confirm* mode just see them in the list.
If that is not what the owner wants, say so before the merge.

---

## Notes (no action needed)

- **N1 (deviations accepted):** the message cache (research §2.5 and report
  §3.4 ask for it; it saves about 1.6 KB per message per refresh), the
  daily re-read of the semester's older weeks (report §3.4 point 4; without
  it the semester window would act on week data frozen up to months ago),
  and `sent_excuses_limit` 100 → 0 (research §2.5: the limit must not cut
  a semester short; D2 needs it, the key keeps its name, `config.example.json`,
  validation and a test changed in the same commit).
- **N2:** a message detail that fails now fails the whole read (before,
  that one message was skipped). Safer, as PLAN §6 wants. A message that
  fails for good would stop automatic excusing; the log line then doesn't
  name the message id. If it ever happens, adding the id to the error is
  enough.
- **N3:** `_readCachedOutboxDetails` (`automation.dart:503–527`) swallows
  any error and returns `{}`. That's a cache read whose fallback is reading
  every detail again, so it is the allowed optional-read case
  (CONTRIBUTING §5); the rest of the new code logs or fails.
- **N4:** the window's semester starts on 1 September / 1 February, as in
  Plánovač (`schoolYearTerms`), not on the school's own Bakaláři dates
  (20.8. / 20.1.). The 30-day overlap covers the change of semester.
- **N5 (research §3 promise):** no lesson that automatic mode may excuse
  falls outside the period read: the window never starts before the
  outbox period's first day (`?s=rok` → 20.8.), and the period ends on
  31.8., after every send. The one gap is an excuse sent before 20 August
  for a lesson after it (holidays), the same approximation the app always
  made.
- **N6:** two parts of the fix are second layers that no test catches on
  its own, and that's fine: clearing `sentExcusesFrom` in the `catch` of
  `fetchSentExcuses` (it is already null from the start of the call), and
  the `lastOutboxSyncOk` gate before writing `sent_excuses_from` in
  `refresh.dart` (the client already gives null on failure).
- **N7 (data use):** the first refresh of each day reads the semester's
  older weeks once more (8 weeks now, about 0.6 MB; up to about 1.3 MB in
  late January); message details are read once and then cached. Small next
  to about 25 MB a day at hourly refreshes.
- **N8:** running `flutter test` rewrites the generated plugin files under
  `app/linux`, `app/macos` and `app/windows` with other line endings (no
  content change); the reviewer restored them. Nothing for the agent.

---

## Done when (PLAN §6, phase 4)

| PLAN line | Result |
|---|---|
| The four limits are lifted: 30-day window, page 1 only, `sent_excuses_limit`, `go_back_weeks` freeze | Done: semester window (`excuse_history.dart:101–126`), `?s=rok` + all pages (`data.dart:298`), limit 0 = none, daily semester re-read (`refresh.dart:382–429`, `:500–507`). M1, S1, S2 to fix |
| Every existing send-path and history test unchanged and green | Yes: no line removed or changed in any test file; 1532 → 1549 test calls, no file lost one; `excuse_history`, `history`, `parity` fixtures untouched |
| A failure on any page is a failed outbox read, auto mode doesn't send | Yes at client level (`pageTwoFailureOrDetailFailureFailsWholeRead`); automation test needs S3; S1 closes two silent partial reads |
| Paging from a real multi-page sample; demo server pages the same way | Research note (owner-approved stand-in) + `bakalari_demo_server.py`: the reviewer's probe matches every number of the research table |
| Defaults, `excuse_history_scope`, Absence list only as D2 says | `go_back_weeks` stays 4; no new key; no list (D2: "no need to list sent excuses"); limit default see N1 |

## Each fix's test catches it

Each part undone alone in a throwaway copy of `f478081`, then the named
tests run.

| Part undone | Caught by |
|---|---|
| core window back to `excuseWindowStart` | `completeExcuseHistoryF2 pendingExcusesFollowsSemesterWindowAndOutboxBounds` |
| app window back to `excuseWindowStart` | `F2 semester excuse window …` (also fails on the parent `2f100bc`) |
| no clamp to the outbox's first day | `semesterExcuseWindowStart coversFullCurrentSemester…`, `pendingExcusesFollows…` |
| month period `?l=o` instead of `?s=rok` | `fetchesWholeSchoolYearPeriodAndPagesCumulatively` |
| `reloadMessages: true` on every page | `fetchesWholeSchoolYear…`, `mixedMessageTypes…`, `syncReadsOver100…` |
| page 1 only | `fetchesWholeSchoolYear…`, `syncReadsOver100…`, `pageTwoFailureBlocks…` |
| count excuse rows only | `mixedMessageTypesStillTriggerNextPage` |
| skip a failed detail | `pageTwoFailureOrDetailFailureFailsWholeRead`, `unparseableOutboxIsUnknownNotEmpty` |
| limit truncates instead of failing | `explicitPositiveLimitFailsClosedWhenExceeded` |
| no detail cache | `detailCacheSkipsKnownMessages…`, `syncReadsOver100…` |
| cache not seeded from `data_cache.json` | `syncReadsOver100…ReusesDetailCacheAcrossInstances` |
| `sentExcusesFrom` set before the details | `explicitPositiveLimitFailsClosedWhenExceeded` |
| no daily re-read | both `f2SemesterReconciliation…` tests |
| re-read marked done although a week failed | `incompleteSemesterBackfillDoesNotMarkReconciled` (S2 changes this rule) |
| floor at 30 days only | both `f2SemesterReconciliation…` tests |
| validation `>= 0` off | `sentExcusesLimitDefaultsToZeroAndValidates` |
| default back to 100 | `sentExcusesLimit…`, `syncReadsOver100…` |
| `sentExcusesFrom` kept in `catch` | **not caught**, fine (N6) |
| `refresh.dart` writes on a failed sync | **not caught**, fine (N6) |
| shrink guard off | **not caught** (S1) |
| no-progress guard off | **not caught** (S1; the guard is unreachable) |
| page-2 error ignored | **not caught** by the automation test (S3); caught by `pageTwoFailureOrDetailFailureFailsWholeRead` |

## What the reviewer verified, and how

1. **Suites** at `c1d886e` (Flutter 3.44.8 / Dart 3.12.2):
   `dart pub get --enforce-lockfile` OK; core `dart analyze` no issues,
   `dart test` **825 passed, 2 skipped** (809 at R3c, +16); app
   `flutter analyze` no issues, `flutter test` **777 passed, 1 skipped**
   (776, +1). Baseline for the re-review: these counts.
2. **Tests on the parent:** the 7 changed test files copied onto `2f100bc`.
   `config_test` (`Expected: <0>`, `Actual: <100>`) and the app test
   (`Expected: ['2026-09-15']`, `Actual: []`) fail by assertion; the other
   five don't compile there (they use `semesterExcuseWindowStart`,
   `outboxPageSize`, `knownOutboxDetails`, `outboxDetailsKey`, …), so each
   was read and then checked by undoing its part of the fix on `f478081`
   (table above).
3. **The code**, every changed file: `excuse_history.dart`,
   `automation.dart` (`syncWebExcusesToHistory`, `pendingExcuses`,
   `_readCachedOutboxDetails`, `outboxDetailsCache`), `data.dart`
   (`fetchSentExcuses`, `fetchAllOutboxIds`, `fetchOutboxIds` kept for
   `excuse.dart`'s send check), `extractors.dart`, `client.dart`,
   `cache.dart`, `config.dart`, `refresh.dart` (`_fetchPhases`,
   `_historyState`, `_recordHistoryWeeks`, `_semesterFloorMonday`),
   `app/lib/controllers/excuses.dart`, `bin/refresh_dryrun.dart`,
   `docs/BAKALARI_API.md` (matches the research), and
   `tools/bakalari_demo_server.py`. Also read, unchanged: `generateExcuses`
   and `absenceKind` (what the wider window lets through, Q2),
   `_autoPhases` (outbox unknown → no send), `fetchTimetableWeeks`
   (history weeks only in this run's data), `schoolYearTerms` (N4),
   `session.json` (what a detail can return, M1).
4. **Reviewer tests** (throwaway, not committed): M1, S1 (two cases), S2,
   and S3 with the detail route; each result is quoted in its finding.
5. **Demo server:** loaded `tools/bakalari_demo_server.py` in a local
   probe (localhost, in-memory outbox, no files): periods `?l=o`,
   `mesic`, `1polo`, `2polo`, `rok`, `starsi`, `custom` give the research
   labels; 17 messages by 6 → 6, 12, 17, 17 with `hfLoadedMessagesCount`
   6, 6, 5, 0 and `all` only on the last; page 2 and 3 with
   `reloadMessages: true` → 6 each; size 101 → 17; the period stays with
   the loaded page after another period was loaded; 49 by 21 → 21, 42,
   49, 49; size 1000 → 49. The agent's `build/qa-evidence/F2/demo_server_verification.txt`
   shows the same plus a Dart run against the server (second run 0 detail
   reads).
6. **Test integrity:** every `test(` / `testWidgets(` call counted per file
   at `bfe4860` and `c1d886e`: 1532 → 1549, no file lost a test, no name
   disappeared. `git show f478081` removes or changes no line in any test
   file. No `skip:`, no `try`/`catch` around assertions; the one
   `isNotNull` is followed by exact checks. Hosts: only
   `https://bakalari.test` and `fakeRoot`.
7. **Scope:** one commit for the item, message starts with `F2`. Every
   change maps to PLAN §6 phase 4 or report §3.4; deviations accepted in
   N1. No UI, strings, tutorials or screens changed, so no screenshots or
   phone evidence are needed for F2.
8. **Config keys:** no key added, removed or renamed; `sent_excuses_limit`
   default, validation and test changed in `f478081` together with
   `config.example.json`. A script compared the keys of `canonicalDefaults`
   and `config.example.json`: identical (apart from the template fields
   `name`/`text`). `test/parity/` unchanged since `bfe4860`; the parity
   files hold `sent_excuses_limit: 100` only as input data.
9. **Safety rules:** refreshes still go through `runRefresh` under the
   session lock (only `_fetchPhases` changed inside it); excuses are still
   sent only by `Strakalari.sendExcuse` with the history check and
   `HistoryLock` (untouched), and the web sync still merges under
   `HistoryLock`; audit and `automation_paused` code untouched; outbox
   unknown still blocks automatic excusing (`refresh.dart:641`).
   `excuse_mode` still defaults to `confirm`. One new silent `catch`, N3.
10. **Hygiene:** no personal data in `git log --stat bfe4860..HEAD`; no
    `Co-Authored-By`, `Claude-Session` or "Generated with" lines; the
    branch has no upstream; `main` has nothing the branch lacks. The
    research note holds no names, texts or message ids.

---

## Re-review 2026-11-20

Reviewed at `qa-roadmap` @ `9e2fd3d` (base `main` @ `bfe4860`; `main` has
no commits the branch lacks). Commits since the review (`c6cb383`):

- `a7f5e1a`, `f3eace3` STATUS: the owner's Q1 answer (a) and Q2
  confirmation, word for word;
- `cdd14d7` M1, `b8ec2db` S1, `5c43568` S2, `805fde6` S3 (test only),
  `31c9a1b` S4, `c886ac8` Q1 (a), one commit each;
- `9e2fd3d` STATUS.

### Verdict: PASS WITH FIXES

All five findings and the owner's Q1 (a) are done, in the code and not
just marked done. A message whose details came back empty or unreadable is
now read again on the next refresh instead of being remembered as
"excuses nothing" (M1). A page that repeats or drops earlier messages fails
the read, and after an exact multiple of the page size the list only ends
when the server says so (S1). A week that doesn't load is retried alone
instead of the whole semester (S2). The page-2 test now fails when a page-2
error is ignored (S3). The message cache has a version (S4). Older installs
with the hidden limit of 100 keep automatic excusing: they read the newest
100 messages and excuse only after them (Q1 (a)). Every new test fails on
the code before its fix with an assertion, every part of the fixes undone
alone breaks a test, both suites are green, and only the two test edits
R4 allowed were made.

One should-fix is left, and it comes from the reviewer's own R4
instruction for Q1, not from the agent: **S5**. The cut at 100 messages can
fall inside a day. The app then counts that whole day as read, although the
earlier messages of that same day were not read. The reviewer's test shows
what follows: an excuse the app really sent that day, but whose
confirmation it missed, is declared "NOT sent and may be sent again", and
that day's absence is offered for automatic sending once more. It needs more
than 100 excuse messages in the school year and an unlucky day, so it is
unlikely, but a second excuse can't be taken back and the fix is a few
lines.

### Should-fix

#### S5 (F2 / Q1, `c886ac8`): a cut at the limit inside a day counts that day as read

- **Where:** `packages/strakalari_core/lib/src/bakalari/data.dart:199–219`
  (`fetchSentExcuses`, the limit branch). `sentExcusesFrom` becomes the
  sent day of the oldest message read (`idsToRead.last`, `:201`, `:218`,
  `:259`). The list is newest first, so message `limit + 1` and older ones
  are not read. When message `limit + 1` was sent on the same day as
  message `limit`, that day counts as read although part of it wasn't.
- **What is wrong:** `sentExcusesFrom` means "every excuse sent from this
  day on was read". Two places trust it:
  - `resolveUnconfirmed` (`excuse_history.dart:380–387`): an unconfirmed
    submit from that day or later that the read didn't find is settled as
    "it was NOT sent and may be sent again" (`automation.dart:1182`), and
    nothing blocks its re-send any more;
  - `pendingExcuses` → `semesterExcuseWindowStart`: the window starts on
    that day, so an absence that day excused by the unread message (sent on
    the website or another phone) is pending again.

  Either way automatic mode can send a second excuse. It needs more than
  `sent_excuses_limit` excuse messages in the school year (100 on every
  older install) and the cut on such a day; the unconfirmed path also needs
  the submit to stay unsettled until that many newer messages exist. The
  cause is the R4 text of Q1 (a) ("set `sentExcusesFrom` to the sent date of
  the oldest of them"); the agent did exactly what it said.
- **Reviewer's check** (throwaway test in `automation_test.dart`, not
  committed): limit 2; the outbox, newest first: `603` sent 10.11. 10:00
  (excuses 10.11.), `602` sent 5.11. 12:00 (excuses 4.11.), `601` sent
  5.11. 09:00 (excuses 5.11.); the sidecar holds the app's own unconfirmed
  whole-day submit for 5.11., made 5.11. 09:00 (that is `601`); an absent
  lesson on 5.11.; clock 20.11. 10:00. Result at `9e2fd3d`:
  `sentExcusesFrom` = 5.11., the sidecar is emptied (`Expected: an object
  with length of <1>`, `Actual: []`), and `pendingExcuses()` returns
  `[05.11.2026]`.
- **What correct looks like:** one commit,
  `F2: a limit cut inside a day doesn't count that day as read (R4 S5)`.
  - In the limit branch, also read the sent day of the first message not
    read, `ids[capped]` (its key in `cacheKeys`, then `parseOutboxSortDate`,
    as for the oldest read one). The window then starts on the later of
    the oldest read message's day (as now) and **the day after** the first
    unread message's day; then the later of that and the period start (as
    now). Build the day after as `DateTime(y, m, d + 1)`, not with a
    `Duration`.
  - Fail the read as today (null, the same log line and
    `sentExcusesError`) when the first unread message has no
    `data-sortdate`, and when that start would be after today. The second
    case only happens when the cut falls on today; it matters because
    `semesterExcuseWindowStart` (`excuse_history.dart:121`) falls back to
    the 30-day window for a start in the future, which would be wider than
    what was read.
  - Tests, each must fail at `9e2fd3d`:
    1. `bakalari_data_test.dart`, group `sentExcuses`: the three messages
       above with limit 2 → `sentExcusesFrom == DateTime(2026, 11, 6)`,
       two detail reads.
    2. `automation_test.dart`, group `completeExcuseHistoryF2`: the
       reviewer's scenario above → the sidecar still holds the 5.11. entry
       and `pendingExcuses()` doesn't contain `05.11.2026`.
    3. `bakalari_data_test.dart`: limit 1, two messages both sent today
       (`withClock` on 20.11.) → `fetchSentExcuses(limit: 1)` returns null.
  - The existing tests stay as they are: in both R4 Q1 tests the first
    unread message (`601`) was sent on 10.9., so their start stays 15.10.
    The reviewer ran this change in a throwaway copy: all 836 existing core
    tests pass unchanged, and so do tests 2 and 3.
  - When updating STATUS, also fix the wording of the *F2 legacy
    `sent_excuses_limit`* question: since Q1 (a) the read no longer fails
    when the limit is exceeded.

### R4 findings, checked

- **M1 fixed** (`cdd14d7`). `fetchSentExcuses` reuses a cached message only
  when its entries aren't empty (`data.dart:239`) and stores only non-empty
  results (`:247`); seeding from `data_cache.json` skips empty lists too
  (`automation.dart:521`, a second layer). The test is the reviewer's,
  word for word (`bakalari_data_test.dart:491`); on `f3eace3` it fails with
  `Expected: false`, `Actual: <true>`.
- **S1 fixed** (`b8ec2db`). For page N > 1, `fetchAllOutboxIds` throws when
  the reply lacks an id of an earlier reply (`data.dart:367`, replacing the
  shrink check); a reply with no new id ends the list only when
  `hfAllMessagesLoaded` is `all` or `hfLoadedMessagesCount` is `0`, else it
  throws "no progress" (`:376`, `_outboxReplyMarksEnd` `:711`); otherwise a
  reply shorter than N × size ends it; the 50-page guard stays (`:390`).
  The fake of `fetchesWholeSchoolYearPeriodAndPagesCumulatively` now sends
  the two hidden fields the way the real and the demo server do (allowed in
  R4). Five tests (`:516`, `:538`, `:562`, `:621`, `:645`): on `cdd14d7`
  the first four fail with `Expected: null`, `Actual: [...]` (the exact
  multiple test through its no-marker case), and the 50-page guard test
  passes there, as R4 said it would.
- **S2 fixed** (`5c43568`). `_recordHistoryWeeks` writes
  `semester_reconciled` = today after every Bakaláři fetch
  (`refresh.dart:410`) and gets `effectiveDone` (`:512`), so a semester
  week that didn't load stays out of `weeks` and alone is asked for next
  time. Its stored days are not lost: `_persist` merges the timetable day
  by day and keeps the school year's earlier days (`refresh.dart:301–321`).
  The old test was renamed and changed exactly as R4 allowed, and its
  second half is now stricter (`[skipped]` instead of
  `contains(skipped)`). On `b8ec2db`:
  `persistentlyFailingWeekIsRetriedAloneNotWholeSemester` fails
  (`Expected: [2026-09-14]`, `Actual` starts at 2026-08-31) and
  `incompleteSemesterBackfillRetriesMissingWeekAlone` fails
  (`Expected: '2026-11-20'`, `Actual: <null>`).
- **S3 fixed** (`805fde6`, test only, 12 lines added, nothing changed). With
  page-2 errors ignored in `fetchAllOutboxIds` (the reviewer's mutation at
  `9e2fd3d`), the new version fails (`lastOutboxSyncOk`: `Expected: false`,
  `Actual: <true>`); the version before `805fde6` still passes with the
  same mutation.
- **S4 fixed** (`31c9a1b`). `outboxDetailsKey` is
  `komens_outbox_details_v1` (`cache.dart:28`), and both doc comments say a
  change to what `sentExcuseEntries` returns must bump it (`cache.dart:26`,
  `extractors.dart:575`). The test (`automation_test.dart:1346`) seeds a
  wrong cache under the old and another name; on `805fde6` it fails with 0
  detail reads (`Expected: an object with length of <1>`). The old key
  never reached `main`, so no install keeps a dead copy.
- **Q1 (a) done** (`c886ac8`), apart from S5. With the limit exceeded, only
  the newest `limit` messages are read, the window starts on the oldest
  read one's sent day (never before the period start), a row without
  `data-sortdate` still fails the read
  (`explicitPositiveLimitFailsClosedWhenExceeded` unchanged and green), and
  one log line names the start. On `31c9a1b`
  `positiveLimitReadsNewestAndNarrowsSentExcusesFrom` fails
  (`Expected: not null`) and
  `positiveLimitNarrowsPendingWindowInsteadOfStopping` fails
  (`Expected: true`, `Actual: <false>`); the `parseOutboxSortDate` test
  can't compile there and was read (valid day, 30 February, empty, null,
  garbage).

### Each part of the fixes undone alone (at `9e2fd3d`)

| Part undone | Caught by |
|---|---|
| containment check off (`data.dart:367`) | `nonCumulativePagesFailOutboxRead`, `pageTwoMissingAnIdFromPageOneFailsOutboxRead` |
| end markers always "end" | `pageTwoRepeatingPageOneFailsOutboxRead`, `exactMultipleEnds…` |
| end markers never "end" | `exactMultipleEnds…`, `fetchesWholeSchoolYearPeriodAndPagesCumulatively` |
| no-progress check off (`:376`) | `pageTwoRepeatingPageOneFailsOutboxRead`, `exactMultipleEnds…` |
| page-2 error ignored | `pageTwoFailureBlocksAutoExcuse…` (S3), `pageTwoFailureOrDetailFailureFailsWholeRead` |
| Q1: window not narrowed | `positiveLimitReadsNewest…`, `positiveLimitNarrowsPendingWindow…` |
| Q1: all messages read | both Q1 tests |
| Q1: no clamp to the period start | `positiveLimitReadsNewest…` (second half) |
| M1, S2, S4 | their tests, on the parent commit (above) |
| M1 seeding filter (`automation.dart:521`) | not caught on its own; a second layer behind `data.dart:239`, fine (like N6) |

### Notes (no action needed)

- **N9 (S1, real markup):** the end markers are read from
  `<input … id="…hfAllMessagesLoaded" value="…">` (an id ending in the
  name also counts). The demo server writes them that way, and the
  reviewer's run against it ends correctly. The research note recorded the
  values of the two fields on the real server, not their markup. If the
  real markup differed, a school year whose message count (all types) is
  an exact multiple of 100 would fail the read with "no progress" until the
  next message arrives: automatic excusing pauses, nothing wrong is sent.
  Worth a glance at the next read-only look at the real page.
- **N10 (S2):** dropping a week that didn't load from `weeks` only makes
  the next run ask for it again; its stored lessons stay in the cache.
- **N11 (evidence):** `build/qa-evidence/F2/demo_server_verification.txt`
  is from before the fixes (16:20). No *Done when* line needs it again; the
  reviewer ran the fixed code against the demo server itself (below).
- **N12:** running `flutter test` again rewrote the generated plugin files
  with other line endings (N8); the reviewer restored them.

### What the reviewer verified, and how

1. **Suites** at `9e2fd3d` (Flutter 3.44.8 / Dart 3.12.2):
   `dart pub get --enforce-lockfile` OK; core `dart analyze` no issues,
   `dart test` **836 passed, 2 skipped** (825 at R4, +11); app
   `flutter analyze` no issues, `flutter test` **777 passed, 1 skipped**
   (unchanged). These match STATUS.
2. **Tests on the parent:** a throwaway worktree in the reviewer's scratch
   space (removed afterwards). For each fix commit, its parent with only
   that commit's test files copied in; results as listed above. Then each
   part of the fixes undone alone at `9e2fd3d` (table above).
3. **S5:** the reviewer's two tests (the boundary day, the cut on today)
   at `9e2fd3d`, then the change described in S5 applied in the throwaway
   copy: `dart analyze` clean, the full core suite 838 passed (836 + the 2
   reviewer tests), 2 skipped.
4. **Demo server:** `tools/bakalari_demo_server.py` on `127.0.0.1` only,
   with a throwaway Dart probe on the code at `9e2fd3d` (its 3 seeded
   excuses): page size 3 (exact multiple) → 2 list callbacks, all 3 read,
   ended by the markers; size 1 → 4 callbacks; size 2 → 2; size 100 → 1;
   limit 2 → the newest 2 read, the window from the second one's sent day
   (31.10.), one log line. Stopped afterwards.
5. **Code:** `git diff c6cb383..HEAD` read in full: `data.dart`,
   `automation.dart` (one line), `refresh.dart`, `extractors.dart`,
   `cache.dart`, four test files, STATUS. Also read, unchanged:
   `resolveUnconfirmed`, `_settleUnconfirmed`, `sendExcuse`'s unconfirmed
   path, `semesterExcuseWindowStart`, `fetchTimetableWeeks`, `_persist`.
6. **Test integrity:** `test(` / `testWidgets(` calls 1549 → 1560; per
   file 84 → 86, 21 → 28, 24 → 25, 28 → 29. The only removed or changed
   test lines are the two R4 allowed (the S1 fake's return line; the S2
   test's rename and its first-run assertion). No `skip:`, no
   `try`/`catch` around assertions, no `anything`; the one `isNotNull` is
   followed by `hasLength(5)`. Only `https://bakalari.test` as a host.
7. **Scope, keys, strings:** every commit touches only its finding's
   files; no change to `config.example.json`, `config.dart`,
   `test/parity/`, the ARB files, `strings.dart`, tutorials or UI. No new
   silent `catch`.
8. **Safety rules:** no change to `runRefresh`'s lock, `sendExcuse`,
   `HistoryLock`, the audit or `automation_paused`; the web sync still
   merges under `HistoryLock`; an unknown outbox still blocks automatic
   excusing. S5 is the one place where the read can claim more than it
   saw.
9. **Hygiene:** all commits by the configured user, no `Co-Authored-By`,
   `Claude-Session` or "Generated with" lines; no personal file or
   screenshot committed; `qa-roadmap` has no upstream; `main` has no
   commits the branch lacks.
10. **Not checked:** macOS and iOS (not possible here); the real server's
    markup of the end markers (N9).

---

## Re-review 2 (2026-11-20)

At the owner's word ("can you fix it? and then mark it as reviewed? I give
you approval to do that", in STATUS), the reviewer fixed S5 itself, as in
R2 and R3c. So this one fix was written and checked by the same person;
what makes up for that is listed below: tests that fail without it, each
part undone alone, and both suites. Reviewed at `qa-roadmap` @ `24c310b`;
`main` has no commits the branch lacks. Commits since the re-review
(`16d6d15`):

- `24c310b` S5, code and tests in one commit.

### Verdict: PASS

S5 is fixed as the re-review described it. When the limit cuts the list,
the app now also reads the sent day of the first message it leaves out,
and starts the excuse window only on the day after it (or on the oldest
read message's day, if that is later). A day where the cut falls is no
longer treated as read: an excuse really sent that day stays blocked
from a re-send, and that day's absences aren't offered for automatic
sending. If the cut falls on today, or the first message left out has no
date, the read fails as before and automatic excusing waits. Nothing
else changed. F2 is done, and with it phase 4.

### S5, checked

- **Code** (`packages/strakalari_core/lib/src/bakalari/data.dart`, the limit
  branch of `fetchSentExcuses`): `sentDay` reads a row's day from its
  cache key (as before, one helper for both rows); `unreadDay` is the day
  of `ids[capped]`, the newest message left out (`:212`); the start is the
  later of the day after it, built as `DateTime(y, m, d + 1)`, and the
  oldest read message's day (`:225`), then the later of that and the
  period start (`:238`, as before). The read fails, with the same
  `sentExcusesError`, when either row has no date or the start is after
  today (`:227`); the two log lines say which. The doc comment says the
  same. Only the limit branch changed; with `sent_excuses_limit` 0 (every
  new install) nothing runs differently.
- **Tests** (one commit with the fix):
  - `limitCutInsideADayStartsTheWindowTheDayAfter (R4 S5)`
    (`bakalari_data_test.dart:452`): the three messages from S5, limit 2 →
    the start is 6.11., and only `603` and `602` are read.
  - `limitCutFailsClosedWhenTheFirstUnreadDayIsTodayOrUnknown (R4 S5)`
    (`:487`): limit 1, both messages sent today → null; the first message
    left out without a date → null; no details read in either case.
  - `limitCutInsideADayKeepsThatDaysUnconfirmedSubmitBlocked (R4 S5)`
    (`automation_test.dart:1487`): the scenario from S5 through
    `syncWebExcusesToHistory` → the start is 6.11., the unconfirmed 5.11.
    submit is still in the sidecar, and of the absences on 5.11. and 9.11.
    only 9.11. is pending (it isn't covered by any message, so the window
    isn't simply empty).
  - On `16d6d15` (the code before the fix) all three fail with
    assertions: `Expected: DateTime:<2026-11-06 …>`, `Actual:
    DateTime:<2026-11-05 …>` (twice) and `Expected: null`, `Actual: [...]`.
  - Each part undone alone at `24c310b`: no "day after" → all three fail;
    no "after today" check → the fail-closed test fails; an unknown day
    accepted → the fail-closed test fails.
  - Unchanged and green: both R4 Q1 tests (their first message left out was
    sent 10.9., so their start stays 15.10.) and
    `explicitPositiveLimitFailsClosedWhenExceeded`.
- **STATUS:** the *F2 legacy `sent_excuses_limit`* question now says the
  read no longer fails when the limit is exceeded.

### What the reviewer verified, and how (re-review 2)

1. **Suites** with the fix (Flutter 3.44.8 / Dart 3.12.2): core
   `dart analyze` no issues, `dart test` **839 passed, 2 skipped** (836,
   +3); app `flutter analyze` no issues, `flutter test` **777 passed,
   1 skipped** (unchanged). The generated plugin files rewritten by
   `flutter test` were restored (line endings only, N8).
2. **Tests on the code before the fix:** a throwaway worktree at
   `16d6d15` in the reviewer's scratch space with only the two changed
   test files copied in, then each part of the fix undone alone (above);
   removed afterwards.
3. **Test integrity:** the two test files only gained lines (82 + 70);
   `test(` calls 1560 → 1563. No `skip:`, no `try`/`catch` around
   assertions, no `anything` or `isNotNull`; only `https://bakalari.test`
   as a host.
4. **Scope, keys, strings, safety:** one code file, the limit branch only;
   no config key, parity fixture, string, UI or tutorial change; no new
   `catch`. The send path, `HistoryLock`, the audit and
   `automation_paused` are untouched; an unknown outbox still blocks
   automatic excusing.
5. **Hygiene:** committed as the configured user, plain messages, no
   `Co-Authored-By`, `Claude-Session` or "Generated with" lines; no
   personal file; `qa-roadmap` has no upstream; not merged into `main`.
6. **Not checked:** macOS and iOS (not possible here); the real server's
   markup of the end markers (N9). Neither blocks the pass.
