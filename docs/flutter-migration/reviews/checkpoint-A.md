# Checkpoint A review: core (phases 1–4)

Date: 2026-11-08 · Reviewed at: `a594f19` (branch tip) · Checkpoint A state: `a0c8a89`
Scope: `packages/strakalari_core/**` and `tools/parity/**` against `strakalari/core/**`.

## Verdict: **FAIL**

Five blockers, eight must-fix items. Three of the blockers break the safety rules the
port exists to keep: one can send the **same excuse twice**, one records **lunches as
ordered that were never saved**, and one lets **two refreshes run at once**.

### Process problem first

The migrating agent did not stop at Checkpoint A (PLAN §4, PROMPT "Stop and hand
over"). Phases 5–9 were built on top of an unreviewed core by parallel sub-agents,
committed in one burst (`b2ff720`…`a594f19`, all within 30 seconds), and STATUS.md
calls them "done". They are not reviewed here. The app UI isn't connected to the
core yet: the router passes empty default controllers, and nothing in `app/lib` calls
`runRefresh`, `sendExcuse` or `stravaOrderSelected` except the Android background
entry. **No work on phases 5–10 until Checkpoint A passes.** Fixes may touch
`app/lib/platform/android/background.dart` only where finding A-B5 requires it.

---

## Findings

Severity: **blocker** (unsafe or broken, stop) · **must-fix** (wrong vs Python, fix before
re-review) · **should-fix** · **note**.

### A-B1 · blocker · Day arithmetic breaks across daylight-saving changes

`Duration(days: n)` on local `DateTime`s is 23 or 25 hours across the Prague DST
switches (29.3.2026, 25.10.2026). Python `date ± timedelta` has no DST. Results were
proven by running the real Dart code next to Python on this PC (Europe/Prague):

| Dart | Python | Proof (Dart vs Python) |
|---|---|---|
| `automation/excuse_history.dart:86` `excuseWindowStart` | `excuse_history.py:72` | `excuseWindowStart(15.4.2026)` = **15.3** vs **16.3**: in the month after the spring switch, the auto-excuse window is one day wider than what Komens → Odeslané can show, so a duplicate can't be ruled out for that day. |
| `automation/excuse_history.dart:208` `_excusePoints` cursor | `excuse_history.py:156` | `unconfirmedBlocks(pure days 24.–26.10.2026, unconfirmed 26.10)` = **false** vs **True**: a maybe-sent excuse does **not** block an overlapping re-send (duplicate risk). The cursor becomes 25.10 23:00 and Monday 26.10 is never checked. |
| `automation/automation.dart:1555` cutoff, `:1676` `day.difference(prevDate).inDays` | `automation.py:964`, `:1057` | `generateExcuses(absence Sat 28.3, today Mon 30.3, delay 2)` = **[]** vs **one excuse**. |
| `bakalari/timetable.dart:76-100` week stepping and `targetDays`; `:82` `inDays ~/ 7` (truncates, Python `//` floors) | `bakalari_timetable.py:57-71` | **Live demo-server run today:** Dart logged "week of 19.10.2026 did not load (got 19.10.–23.10.)" for all 8 school-year weeks before 25.10 and cached **15** timetable days vs Python's **55**. Mondays become 23:00/01:00, so `targetDays` never equals the midnight days shown. For ~4 weeks after each switch the regular past weeks are also skipped or the wrong week is fetched (today 30.3.2026, off −1 → Monday **16.3** vs **23.3**). |
| `automation/refresh.dart:332, 374, 386, 389, 396, 406-408` | `refresh.py:269-297, 388` | `_missingHistoryWeeks` steps `+7 days`; after a switch every Monday misses `done`/`regular`, so the whole history is re-fetched **on every refresh** and thrown away (see the row above). |
| `bakalari/data.dart:361-365` substitution range | `bakalari_data.py:280-283` | Today 19.10 + 14 days → Sun 1.11 23:00, so the range ends a week early. |

Also audit and fix the same pattern in `bakalari/excuse.dart:243`,
`lunches/lunch_cutoff.dart:77,112,115`, `planning/grades.dart:681`,
`planning/schedule.dart:1002-1032`, `planning/planned_skips.dart:141-143`,
`status_notification.dart:289-546`, `wakeup.dart:245-755`.

**Correct:** one pair of helpers in `storage/helpers.dart`, used everywhere a calendar day moves:
`DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);` and
`int daysBetween(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;`.
Week offsets use floor division (`(days / 7).floor()`, Python `//`). Compare days as
date-only values. Add Dart tests and `dump.py` parity cases at 27.3–1.4.2026 and
23.10–28.10.2026 for every row above, and run `dart test` with `TZ=Europe/Prague` in
`dart.yml` (otherwise the CI runner's UTC hides this bug).

### A-B2 · blocker · "Surely not sent" is decided by error code, not by when the error happened

`bakalari/http_session.dart:860-885` (`isNeverSentCause`, `_isRefused`) treats
SocketExceptions with codes such as 110/10060 (ETIMEDOUT), 113/65 (EHOSTUNREACH),
101/51 (ENETUNREACH), "network is down" or "timed out" as "the post never left".
Python (`bakalari_excuse.py:381`) decides by **phase**: only `httpx.ConnectError` and
`ConnectTimeout`, which are raised before any request byte is sent. All of these codes
also occur on an **established** connection after the excuse POST was written, for
example a phone switching networks while it waits for the reply. Dart then sets
`lastSubmitUncertain = false`, the outcome is `failed`, and the next auto refresh
**sends the excuse again**. The ported test (`bakalari_excuse_test.dart:293-297`)
only checks messages, not phases, so it can't catch this.

**Correct:** in `DartIoHttpTransport.send` (`http_session.dart:483`) wrap only
`await _client.openUrl(...)` (DNS + connect), and rethrow its failures as a new
`ConnectFailure(cause)`. Set `_client.connectionTimeout = timeout` so a connect timeout
also comes out as `ConnectFailure`. Anything thrown after `openUrl` returned means
"maybe sent". `isNeverSentCause` returns true **only** for `ConnectFailure`. The fake
transport throws `ConnectFailure` for its "refused" case. New tests:
`SocketException('Connection timed out', OSError('', 110))` thrown after the request
→ `lastSubmitUncertain == true`; `ConnectFailure(...)` → `false`. Apply the same rule
to the Strava retry (`strava/client.dart:278`).

### A-B3 · blocker · A failed lunch-order run records unsaved lunches as ordered

`automation/automation.dart:1008` `immediate = client.findSaveButton();` with
`strava/ordering.dart:304` `bool findSaveButton(...) => true;` is the **inverse** of
Python `automation.py:585` `immediate = client._find_save_button(timeout_ms=500) is None`
with `strava_ordering.py:237` returning `True` (truthy = staged, needs the save).
Whenever an order run fails after clicks, every other clicked day goes into
`lastOrderedDays`, `orderedDict`, the cached `strava_ordered`, the audit as `sent`,
and the auto-mode "handled" list (so auto never retries it). **Nothing was saved on
Strava**, so the student has no lunch while the app says ordered. The Dart tests
`automation_test.dart:1072-1090` flipped the fake's `saveButton` flag to match the
inverted code (Python `test_strava_ordering.py:68-90` sets `None` for "immediate" and
an object for "save button").

**Correct:** keep Python's meaning (true = a save button exists, changes are staged)
and write `immediate = !client.findSaveButton();`. In the two tests, use
`saveButton = false` for `failedRunReportsDaysSavedByImmediateFrontend` and
`saveButton = true` for `failedRunOnSaveButtonFrontendReportsNothingClicked`. Add a test
with the **default** client (no override) that asserts `lastOrderedDays` is empty
after a failed run with clicks.

### A-B4 · blocker · Automatic lunch ordering is not connected

`automation/refresh.dart:75-93`: `planAutoOrdersHook` defaults to
`throw UnimplementedError('phase 3: lunch_auto')`. Its contract is synchronous and
gets `ordered` as a list of days (`refresh.dart:694`). The real
`lunches/lunch_auto.dart:435 planAutoOrders` is async and takes
`Map<String, String> ordered`. Python `refresh.py:527-533` passes the day → meal
dict. Every refresh with `strava_order_mode: auto` records an `auto_lunch` error and
orders nothing.

**Correct:** make the hook `Future<(Map<String, String>, bool)> Function(...)` with
`ordered: Map<String, String>`, default it to `planAutoOrders`, `await` it in
`_autoLunch`, and pass `ordered: orderedBefore`. Add a refresh test that runs with the
**default** hook (a fake Strava app and menu, no Gemini) and orders a gap day.

### A-B5 · blocker · The session lock doesn't hold

a) `storage/helpers.dart:354` `lockSync(FileLock.exclusive, 0, 1)`. dart:io uses POSIX
`fcntl` record locks on Linux, macOS and Android. They belong to the process (dart:io
docs: "several isolates in the same process can obtain an exclusive lock"), and closing
any handle to the file drops them. Python uses `flock` (`helpers.py:364`). I proved on
Linux (WSL, Python `fcntl.lockf` = the same fcntl lock): with `flock` held by one
process, another process **acquired** the fcntl lock on byte 0, and a second fcntl
lock in the same process was **also acquired**. So on Linux a Python and a Dart app
don't exclude each other, and on every POSIX platform two refreshes in one Dart
process both get the lock. `session_lock_test.dart:58` and `helpers_test.dart:168` will
fail on the ubuntu CI job. Windows is fine: I ran Python-holds/Dart-tries and the
reverse, and both were refused correctly.
**Correct:** on POSIX call `flock(fd, LOCK_EX | LOCK_NB)` through `dart:ffi` (libc),
which matches Python on Linux and macOS. Add an in-process registry (a static set of
held lock paths) so a second acquire in the same process fails like Python's second
handle. Keep `LockFileEx` on Windows. Add a Linux cross test (Python holds, Dart
tries, and the reverse).

b) `automation/session_lock.dart:48` `withSessionLock<T>(T Function(bool held) body)`
releases in `finally` as soon as an **async** body returns its Future, so the lock is
gone before the work runs. `app/lib/platform/android/background.dart:184` does exactly
that, so the Android background refresh runs unlocked.
**Correct:** add `Future<T> withSessionLockAsync<T>(Future<T> Function(bool held) body)`,
which awaits the body inside `try/finally`, and use it in `background.dart`. Make the
sync variant reject a Future-returning body (an assert, plus a test).

### A-M1 · must-fix · History lock: concurrent tasks walk in, and the UI can freeze

`automation/excuse_history.dart:369-414`. Python `excuse_history.py:306-339` holds a
process `RLock` across the whole block, so other threads **wait**. The Dart static
depth counter lets any concurrent async task in the isolate in as "re-entrant" while a
send is awaiting login or submit. `_sendTail` (`automation.dart:1264`) only serializes
sends with each other. `syncWebExcusesToHistory` (`automation.dart:1121`) can run in
the middle of a send: it rewrites the history and settles the sidecar, then the send
writes its stale copy (`automation.dart:1384`), so web-imported entries are lost until
the next sync, and `_recordUnconfirmed` rewrites a stale sidecar. Also, `acquire`
busy-waits with `sleep()` (`:392`) for up to 600 s, which freezes the whole isolate
(the UI) while the tray or another process holds the file.
**Correct:** `Future<bool> acquire()` with one async mutex per path. Re-entrancy only
for the same logical task (a `Zone` value set by the outer holder). Poll the file lock
with `await Future.delayed(500 ms)` and a `Stopwatch` deadline. Remove `_sendTail`. Test:
a send blocked mid-submit (a `Completer` in the fake) plus a concurrent sync. The sync
must wait, and the history must contain both afterwards.

### A-M2 · must-fix · A corrupt unconfirmed sidecar breaks the send instead of being quarantined

`automation/excuse_history.dart:252-262` vs `excuse_history.py:198-218`. Python
quarantines corrupt JSON or bad UTF-8 and reads `[]`. In Dart, `jsonDecode` throws a
`FormatException` that escapes `_sendExcuseInner` (`automation.dart:1344` catches only
`FileSystemException`). The send then leaves **no audit record** and `excusePending`
aborts. Invalid UTF-8 surfaces as a `FileSystemException`, so it becomes "failed"
instead of being quarantined.
**Correct:** treat a `FormatException` or a UTF-8 decode failure as corrupt:
`quarantineCorruptFile(path)` and return `[]`. Other I/O errors rethrow (they become
"failed" like Python's `OSError`). Test: a corrupt sidecar is quarantined, the send
goes on, and the audit has the record.

### A-M3 · must-fix · `fetchBakalariData` skips Python's reset and prelude

`automation/automation.dart:651-677` rebuilds `bakalari_data.fetch_data` but leaves out
its reset (`bakalari_data.py:378-401`: `timetable_sources`, `timetableData`, absence,
grades, stable, `substitutions = None`, …) and its `_raise_if_cancelled()` + `login()`
prelude. A reused `Strakalari` gets old and new timetable sources merged together, and
stale absences reach `generateExcuses`.
**Correct:** port `fetch_data` into `DataMixin.fetchData()` line by line and have
`Strakalari.fetchBakalariData` forward the cancel flags and call it. Test: two refreshes
on one object, where the second sees only fresh data.

### A-M4 · must-fix · Files are not byte-identical on Windows

Python writes text mode, so files get CRLF on Windows (`helpers.py:452`, `audit.py:62`,
`automation.py:332`). Dart writes LF (`storage/helpers.dart:445`,
`automation/audit.dart:77`, `automation/automation.dart:636`). Proven: when Dart
rewrites a Python-written `data_cache.json` or `already_excused_lessons.json`, bytes
change from `{\r\n` to `{\n`. The audit line separators differ too: Python
`json.dumps` default `", "` / `": "` vs compact `jsonEncode` (`audit.dart:74`).
**Correct:** on Windows, emit `\r\n` in `atomicWriteJson`, audit and log lines. Make
audit lines use Python's separators. Add a committed cross test: Python writes, Dart
rewrites, bytes match, for config, cache, history, sidecar, planned skips and presets.

### A-M5 · must-fix · Key entry name isn't normalized like Python

`storage/secret_store.dart:39-44` vs `secret_store.py:49`
`normcase(abspath(data_dir))`. Dart doesn't turn `/` into `\`, drop trailing
separators or collapse `..`. With `STRAKALARI_DATA_DIR=C:/x/data` or `…\data\`, Dart
asks for a different `fernet-key:` entry than Python, creates a new key, and the stored
passwords are lost.
**Correct:** `p.normalize(p.absolute(dataDir))`, then lowercase on Windows. Add parity
cases for forward slashes, a trailing separator, `..` and mixed case (pure string
function, no key store).

### A-M6 · must-fix · Without a registered key store, Dart silently creates `secret.key`

`storage/secret_store.dart:126` (and `:282, :309, :335`): `keyStoreBackend == null`
falls back to the file. Python's default is the real OS keyring
(`secret_store.py:257`). Proven: the Dart dry-run CLI created `secret.key` in a fresh
data folder, where Python used Windows Credential Manager. Any desktop entry point that
forgets to register the backend creates a new key. On the next start with the backend,
the store and the file differ, the rule "use the file" wins, and Python's passwords are
unreadable for **both** apps.
**Correct:** on desktop, a missing backend throws `KeyStoreUnavailable` unless
`STRAKALARI_NO_KEYRING` is set or a test opts in explicitly. Tools and CLIs set
`STRAKALARI_NO_KEYRING` themselves.

### A-M7 · must-fix · The parity oracle isn't reproducible

Regenerating `tools/parity/dump.py` changes `test/parity/schedule.json` case 16
(`stableWeeklyHours`, key order `NJ, AJ` → `AJ, NJ`, values equal). Python
`schedule.py:253` iterates a `set`, so the order follows `PYTHONHASHSEED`. Not a hand
edit, but the `git diff --exit-code` gate fails.
**Correct:** `dump.py` re-runs itself with `PYTHONHASHSEED=0` when that isn't already
set. Regenerate, commit, and note it in the module docstring.

### A-M8 · must-fix · STATUS.md is not accurate

- It says phases 5–9 are "done". The UI isn't wired to the core, the soak was never run
  for days, and the on-device and Sandbox tests are pending.
- "Dry-run parity identical" compared cache **keys** only. My full comparison found the
  40-day timetable gap (A-B1). The demo data also produced **0** pending excuses, so the
  auto-excuse path was never compared.
- Several module rows claim tests that exist in neither suite: `test_lunch_same_pick.py`
  (5), 3 of `test_lunch_auto_user_choice.py`, 5 window/tray cases of
  `test_scheduler_retry.py`, and `test_order_latch.py`'s AppState latch (4).

**Correct:** mark phases 5–9 "in progress, unreviewed". For every Python test file,
list each Python test → Dart test, or **Deferred (phase N)** / **Dropped (reason)**.
Many Dart tests also don't follow the "same names in camelCase" rule (`lunch_auto_test`
uses sentences), which makes this mapping necessary.

### Should-fix

- **A-S1** `automation.dart:830-835`: `List.sort` isn't stable for lists over 32
  entries, while Python `sorted` is (`automation.py:464`). Build the list as
  cancellations then orders (two filtered passes).
- **A-S2** Python-compatible float formatting in the JSON writers. Python repr gives
  `1e-07` and `1e+16`, Dart gives `1e-7` and `10000000000000000.0` (proven).
- **A-S3** Timeouts use `DateTime.now()` (`excuse_history.dart:385,391`,
  `helpers.dart:302,369,376`). Use a `Stopwatch` for deadlines and `clock.now()` for the
  stale-file age.
- **A-S4** `tools/parity/soak_refresh.py` and `fetch.py` use the real keyring, so every
  soak run stores a key for a throwaway folder in the owner's Windows Credential Manager.
  Set `os.environ["STRAKALARI_NO_KEYRING"] = "1"` before the imports.
- **A-S5** `bin/refresh_dryrun.dart --send-day` sends a **real** excuse with no host
  check. Refuse unless the host is `127.0.0.1`, `localhost` or `[::1]`.
- **A-S6** The dry-run parity scripts should also run `excusePending()` in dry run and
  compare the whole cache, history, sidecar and audit (see "What I verified").
- **A-S7** `automation/scheduler.dart:82` `typedef Job = Object? Function()` can't await
  the async `runRefresh`. An async job counts as "ok" at once and its errors never cause
  the 5-minute retry. Make it `FutureOr<Object?> Function()` and await it.
- **A-S8** `http_session.dart:628-641` and `strava/client.dart:277-282` retry on any
  `IOException`. Python retries only `RemoteProtocolError` / `ReadError` (connection
  closed before a reply). Narrow the retry to those cases.
- **A-S9** `DartIoHttpTransport` has no connect timeout (`openUrl` is unbounded). Set
  `connectionTimeout` (also needed for A-B2).
- **A-S10** `automation.dart:553-607` keeps its own copy of the log redaction "in sync"
  with `error_report`. Call the `error_report` functions now that they're ported.

### Notes

- **A-N1** `refresh.dart:245-255` swallows a throwing cancel predicate (Python
  propagates it). `refresh.dart:358-367` falls back to today when the school-year start
  fails (Python raises). `writeLog` creates the parent folder (Python doesn't). Align
  these or list them as deviations.
- **A-N2** Request bodies differ only in JSON spacing (Strava `_post` body, the Komens
  list param). They are equivalent JSON, accepted.
- **A-N3** For Checkpoint C: `wakeup.dart:847,873` doesn't sort keys like Python
  `sort_keys=True`. Harmless for the Java parser.
- **A-N4** `automation_paused` gating, the outbox gate (`last_outbox_sync_ok`), the
  history coverage check, `historyEntries`, `mergeSentExcuses`, `resolveUnconfirmed`,
  `executeExcuse` (outbox before/after, `sendOnce` without retry or redirects, expired
  session) and the Strava `saveConfirm` (one save, verified on a fresh menu) match
  Python line by line.

### Deviations (STATUS list): sign-off

Accepted: private→public names, `t(args:)`, the `fernetFactory` seam, hermetic test
data folders, the `ConfigManager` factory and `StateError`, the real-lock save test,
typed `normalizeHistoryItem`, deep `jsonEquals`, `html_unescape`, half-even `_round2`,
the hand-written `HttpTransport` (manual redirects; but see A-B2, A-S8, A-S9),
`BakalariClientBase` mixins, nullable `sentExcuses`, `session.json` extras,
`UserError.cause`, the public outbox helpers, the UTC `dateState`, the `selectedDates`
list, `apiRoot` netloc, `List<String>` blacklist, dropping `tls.py`, the
canonical-name unification, ban matching via `matching.dart`, `bandsValid` accepting
bools, `LessonSource`, `_pyRepr`, `mealText`, the `buildPrompt` wording,
`updateStableBaseline` in `DataMixin`, `RefreshApp`, async methods, named optional
params, and the `getUserDataDir` writability probe (fine for the per-user Inno install
in `{localappdata}\Programs`).
Rejected or conditional: the static async send mutex (replace, A-M1); the Strava retry
reusing `isNeverSentCause` (A-B2, A-S8); "DST-safe stepping only in
forecast/planned_skips/planner" (extend everywhere, A-B1); hook defaults (accepted
except `planAutoOrdersHook`, A-B4); the local redaction mirror (A-S10).
Dropped list: also list `test_tls_bundle.py` and `test_frozen_ssl.py` under *Dropped*
with the reason (currently only the module is listed). Accepted.

### Answers to the Checkpoint A questions in STATUS.md

1. `planAutoOrdersHook`: make it async now (A-B4).
2. `bin/refresh_dryrun.dart --send-day`: may stay only with the localhost guard (A-S5).
3. No `today` parameter for `planAutoOrders`. It reads `clock.now()`, so tests use `withClock`.
4. Hook names and signatures are accepted as test seams. Every hook must default to the
   real function (no throwing defaults).
5. DST drift: fix it everywhere now (A-B1).

---

## What I verified, and how

All commands ran in the worktree with Flutter 3.44.8 / Dart 3.12.2. Scripts and outputs
are in the reviewer's scratchpad (not committed).

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / **720 passed** |
| `flutter analyze` / `flutter test` (app) | clean / **123 passed, 1 skipped** (`packaging_privacy` APK test, needs `STRAKALARI_APK`) |
| Python suite (`pytest tests/`) | **1643 passed** |
| `dump.py` regeneration + `git diff --exit-code` | **1 difference**, key order only (A-M7); restored afterwards |
| Session lock, Windows: Python holds → Dart tries, and Dart holds → Python tries | both refused correctly; second handle in the same Dart process refused |
| Lock semantics on Linux (WSL, Python flock vs fcntl) | fcntl lock taken while flock held; second fcntl lock in the same process taken (A-B5) |
| Fernet Python ↔ Dart with a throwaway key (Czech text and emoji) | both directions decrypt |
| JSON writer byte check (Python writes → Dart rewrites → Python rewrites) | differs: CRLF vs LF, float repr (A-M4, A-S2) |
| DST probe: the real Dart functions vs Python at 15.4 / 30.3 / 24.–27.10.2026 | 4 wrong results (A-B1) |
| Dry-run parity: demo server, two throwaway folders, `runRefresh` + `excusePending()` in dry run, full JSON compare | audit, history, sidecar, result: **identical**; cache: Dart is missing 40 timetable days and 8 history weeks (A-B1) |
| Test counts per file (Dart JSON reporter) vs `pytest --collect-only` | Dart 844 (720 core + 124 app) vs Python 1643. Safety files compared case by case: `test_bakalari_excuse` 14 → 14, `test_session_lock` 6 → 6 (2 tray/window cases rewritten as lock-contract tests), automation/refresh/history/audit 168 → 139 (the rest are AppState cases, see A-M8) |
| Test integrity (`git log -p` on Dart tests; grep for `skip:`, `anything`, `try`/`catch` around `expect`) | no loosened assertions, no catch around expects; the one `skip:` is the APK check. Flipped ordering fakes: A-B3 |
| `package:flutter` in core, build_runner / `*.g.dart`, root `pubspec.lock` committed, Flutter 3.44.8 + `--enforce-lockfile` in `dart.yml` | OK |
| Committed personal data, real hosts contacted in tests, upstream, `Co-Authored-By` / `Claude-Session` | none |
| `main` merged and ported | `main` = `0ffdcff`, an ancestor of the branch; STATUS says 0ffdcff. OK |

**Not verified at this checkpoint:** macOS behavior of flock vs fcntl; Android;
planned-skips and preset file round trips; config writes with encrypted values (they
would touch the owner's key store). Re-check these after the fixes, with
`STRAKALARI_NO_KEYRING=1`.

Side effect to clean up: my Python dry run stored one throwaway key in Windows
Credential Manager, `Strakalari / fernet-key:d242a8e8433a6c40` (my scratch folder, no
real data). The owner may delete it.

---

# Re-review (2026-11-08)

Reviewed at `21958bc` (branch tip). Commits since the review: `09157ff..21958bc`
(23 fix commits `ee364bd..b953c09` plus STATUS commits). Same scope as above.

## Verdict: **FAIL** (no blockers left, 3 must-fix)

Every finding of the first review is fixed in the code, and I proved the important
ones by running them (table below). The send path, the order path, the locks and
the file formats now match Python. Three new must-fix items keep this from passing:
the new POSIX lock calls `open()` wrongly for Apple-silicon Macs (R-M1), the rework
list in STATUS.md describes fixes that don't exist (R-M2), and one refresh-pipeline
test was never ported (R-M3). All three are small. The should-fix items below can go
in the same rework.

## Status of the first review's findings

| ID | Commit | How I checked | Result |
|---|---|---|---|
| A-B1 DST | `ee364bd` | Read every changed site against Python; no `Duration(days:` day steps or `.inDays` on local dates left in `lib/` (grep); full core suite on **Linux with `TZ=Europe/Prague`**; live demo-server dry run: Dart now caches **55** timetable days like Python (was 15) | fixed (tests: see R-S4) |
| A-B2 never-sent by phase | `7a045dd` | Code: only `openUrl` (DNS + connect, incl. TLS) is wrapped in `ConnectFailure`; `isNeverSentCause` is `is ConnectFailure`. **Probe with the real `DartIoHttpTransport`** and a local socket: reset after the server read the POST → `HttpException`, "maybe sent"; no reply → `TimeoutException`, "maybe sent"; closed port → `ConnectFailure`, "never sent" | fixed |
| A-B3 save button | `e0d0ebf` | `immediate = !client.findSaveButton()` matches `automation.py:585`; both tests flipped back; new default-client test | fixed |
| A-B4 auto lunch | `441a05e` | Hook is async, defaults to `planAutoOrders`, gets `ordered` as the day → meal map; `defaultHookOrdersGapDay` runs the real planner. No `today` parameter was added (correct, see answer 3) | fixed |
| A-B5 session lock | `2eff0b5` | POSIX `flock` via FFI + in-process registry; `withSessionLockAsync` used in `background.dart:184`. **Linux (WSL, Dart 3.12.2):** `session_lock_test.dart` 11/11 incl. `matchesPythonFlock` (Python holds → Dart refused, Dart holds → Python refused). **Two isolates in one process** exclude each other on Linux and Windows (probe). **Windows:** Python holds → Dart refused, Dart holds → Python refused, both released → acquired | fixed (macOS: R-M1) |
| A-M1 history lock | `56c34aa` | Per-path FIFO mutex + `Zone` re-entrancy + async file-lock poll, like `excuse_history.py:306-339`; `_sendTail` gone; `concurrentSyncWaitsForSendAndKeepsBoth` gates the submit with a `Completer` | fixed |
| A-M2 corrupt sidecar | `5857842` | `loadUnconfirmed` quarantines bad JSON / bad UTF-8 and returns `[]`, I/O errors rethrow, like `excuse_history.py:198-218` | fixed |
| A-M3 fetch_data | `73cd892` | `DataMixin.fetchData` resets the same fields in the same order as `bakalari_data.py:377-427`, then cancel check + login | fixed |
| A-M4 bytes on Windows | `e734e04`, `763ec48` | Dry run on both sides: `already_excused_lessons.json`, `automation_history.jsonl` and `data_cache.json` byte-identical apart from timestamps. Config **with encrypted passwords** (probe, `STRAKALARI_NO_KEYRING=1`): Python writes → Dart decrypts and rewrites → same bytes; Dart writes a new password → Python decrypts it (Czech letters + emoji). The committed test spawns Python for six file types | fixed |
| A-M5 entry name | `f5f7f16` | Probe: Dart `entryName` = Python `_entry_name` for `C:/x/data`, `C:\x\data\`, `c:\X\Data`, `C:\x\sub\..\data`, relative paths, a trailing `.`, Czech letters, UNC | fixed |
| A-M6 missing key store | `57a54f4` | Desktop with no backend throws `KeyStoreUnavailable` unless `STRAKALARI_NO_KEYRING`; tests opt in explicitly | fixed |
| A-M7 oracle | `0d37753` | `dump.py` regenerated → `git diff --exit-code` clean | fixed |
| A-M8 STATUS | `a3811a3` | Phases 5–9 now "in progress, unreviewed"; all 94 Python files mapped. But see R-M2 | partly |
| A-S1 … A-S10, A-N1 | `92181d8..b953c09` | Read each diff: two-pass staging, Python float repr, `Stopwatch` deadlines, `NO_KEYRING` in all parity scripts, `--send-day` loopback guard (+ test), full-cache dry-run compare, `FutureOr` jobs awaited, read retry narrowed, connect timeout `min(timeout, 20 s)` like `bakalari_http.py:281`, redaction delegated, N1 aligned (cancel predicate and school-year start now propagate) | fixed |

## New findings

### R-M1 · must-fix · On Apple-silicon Macs the lock files get random permissions

`packages/strakalari_core/lib/src/storage/helpers.dart:468-470` declares libc `open`
as a fixed three-argument function and calls it at `:548` with
`O_RDWR | O_CREAT, 438`. `open` is variadic (`int open(const char *, int, ...)`).
On Apple arm64, variadic arguments are passed on the stack, not in registers, so
`open` reads the mode from a random stack slot. Every lock file the Dart app creates
first (`session.lock`, `config.json.lock`, `secret.key.lock`, …) gets random
permission bits. If the owner-read/write bits are missing, every later `open` fails
with `EACCES`, `_flockExclusive` returns null, and the lock looks busy **forever**:
no refresh runs, config saves fail, and the Python app can't open those files either
(`helpers.py:354` raises `PermissionError`). Linux, Android and Intel Macs are not
affected (they pass these arguments in registers).
Python reference: `helpers.py:354` `open(self.path, "a+b")` (mode `0o666 & ~umask`).
**Correct:** declare it variadic:
`typedef _OpenC = ffi.Int32 Function(ffi.Pointer<ffi.Int8>, ffi.Int32, ffi.VarArgs<(ffi.Int32,)>);`
(keep the Dart signature `int Function(Pointer<Int8>, int, int)`). Add a POSIX-only
test: acquire a lock on a fresh path, release it, then check
`FileStat.statSync(path).mode & 0x180 == 0x180` (owner read + write) and that a second
acquire succeeds. Mark the macOS run as *unverified* in STATUS until the owner's
macOS CI job runs it.

### R-M2 · must-fix · STATUS.md describes fixes that aren't in the code

The rework list under *Checkpoint notes* (`STATUS.md:705-718`) does not match the
commits it names. Several entries describe functions that don't exist anywhere in the
repository (`loadExcuses`, `decryptEntry`, `saveExcuses`, `tryEncrypt`):

| Line | Says | The commit actually does |
|---|---|---|
| 707 A-B3 `e0d0ebf` | "`loadExcuses(decrypt: true)` … `reason_encrypted`" | flips `findSaveButton` |
| 708 A-B4 `441a05e` | "added optional `today` parameter" | no `today` parameter (correctly, per answer 3) |
| 709 A-B5 `2eff0b5` | "aligned `parseInt` …" | POSIX `flock` + `withSessionLockAsync` |
| 711 A-M2 `5857842` | "`hasValidCredentials` … truthiness" | quarantines a corrupt sidecar |
| 712 A-M3 `73cd892` | "moved `tryEncrypt` before `with HistoryLock` in `saveExcuses`" | ports `fetch_data` |
| 713 A-M4 `e734e04`/`763ec48` | "`json.loads` NaN/Infinity, `float()`" | CRLF, audit separators, byte test |
| 714 A-M5 `f5f7f16` | "input order when sorting ties in `grades.summarize`/`news.findNews`" | normalizes `entryName` |

Also: the deviation at `STATUS.md:502-506` says `HistoryLock` uses "the OS
`InterProcessLock`"; it uses `tryFileLock` (the create-exclusive lock file), which is
what Python's `history_lock` uses (`excuse_history.py:327`), so the code is right and
the text is wrong. `STATUS.md:726` still says "Dart suite 720/720" (now 757 core, 124
app). `STATUS.md:665` still says "Checkpoints B + C reached", while the header says
phases 5–8 are unreviewed. Several per-file counts in the test map are function
counts, not pytest cases (`test_bakalari_excuse.py` 12 vs 14 collected,
`test_order_latch.py` 4 vs 7, `test_excuse_generation.py` 25 vs 41,
`test_mobile.py` 48 vs 70, and 9 more).
**Correct:** rewrite the rework list from `git show --stat` of each commit, one line
each, describing only what the diff changes. Fix the three stale lines. Give every
test-map count as `pytest --collect-only` reports it, with the function count in
brackets where they differ.

### R-M3 · must-fix · A refresh-pipeline test was never ported

`tests/test_refresh_pipeline.py:159` `test_gemini_fallback_is_not_a_gemini_run` (Gemini
offline → the blacklist-filter pick is used and `used_gemini` is False) has no Dart
counterpart. STATUS.md (test map, item 58) points it at `lunch_auto_test.dart`
`gemini answer is used when due`, which tests the opposite case, and at
`gemini_test.dart`, which tests the local fallback inside `recommendLunches`, not
`planAutoOrders`. PLAN §4 phase 4 says the `test_refresh_*` files are ported first and
literally. I ran the case by hand (a probe with a failing `geminiTransport`): Dart
returns `used=false`, `{06.10.2099: t2&1&0}`, the same as Python. So the code is right
and only the test is missing.
**Correct:** add `geminiFallbackIsNotAGeminiRun` to `refresh_test.dart` (or
`lunch_auto_test.dart`): `planAutoOrders({'06.10.2099': {'t2&1&0': 'Guláš'}}, cfg)` with
`gemini_auto_enabled: true`, `gemini_api_key: 'k'`, `gemini_api_key_encrypted: false`,
a `geminiTransport` that throws `SocketException('offline')` and a no-op
`geminiSleep`. Expect `usedGemini == false` and `orders == {'06.10.2099': 't2&1&0'}`.
Fix item 58 of the test map.

### Should-fix

- **R-S1** Dead `on OSError` catches: Dart file APIs throw `FileSystemException`, never
  `OSError`. (a) `automation/automation.dart:586`: when rotating `log.txt` fails (for
  example another program has it open on Windows), the exception escapes to the outer
  catch and **the log line is lost**; Python (`automation.py:325`) ignores the
  rotation error and still appends. (b) `storage/secret_store.dart:323`: `carryKey`
  promises "never raises" but a write error escapes; Python (`secret_store.py:317`)
  catches `OSError`, which includes `KeyStoreUnavailable`. (c)
  `storage/helpers.dart:825` `decrypt`: Python (`helpers.py:484`) also falls back on
  `OSError`. Use `on FileSystemException` (plus `KeyStoreUnavailable` in (c), as
  Python's `KeyStoreUnavailable` is an `OSError`). Test: a log rotation that fails
  still appends the line.
- **R-S2** `storage/helpers.dart:793-801` `_replaceFile` and
  `storage/secret_store.dart:213-222` `_writeFile` delete the target when the rename
  fails, then rename again. Python uses `os.replace` and never deletes
  (`helpers.py:453`, `secret_store.py:93`). I checked: Dart `renameSync` already
  replaces an existing file on Windows, so the fallback only runs on a real error,
  and then it can leave **no** `config.json` / history / `secret.key` at all.
  Remove the fallback and let the error propagate.
- **R-S3** `bakalari/excuse.dart:192` `now ?? DateTime.now()` must be `clock.now()`
  (PLAN §3.5; Python `bakalari_excuse.py:113` `datetime.now()`).
- **R-S4** Three DST tests re-implement the arithmetic instead of calling the code:
  `test/dst_test.dart:59` (`mondayAndTargetDaysStayMidnight`), `:77`
  (`historyWeekSteppingStaysMidnight`), `:89` (`substitutionRange`). Drive the real
  code under `withClock` at 30.3.2026 and 26.10.2026: `fetchTimetableWeeks`
  (`bakalari/timetable.dart:68`) with a fake that records the Mondays it was asked
  for, `_missingHistoryWeeks` through `runRefresh` (`automation/refresh.dart:347`),
  and the substitution request range in `bakalari/data.dart` (`fetchSubstitutions`).
  Assert the same Mondays and dates Python produces (add those rows to `dump.py`,
  as the first review asked "for every row above"). Note that `TZ` may not take
  effect on the `windows-latest` runner; the ubuntu job is the one that proves it.
- **R-S5** User messages after a connect failure differ from Python. A connect
  timeout becomes `bak_unreachable` / `strava_unreachable` in Dart
  (`bakalari/http_session.dart:510`, `:678`; `strava/client.dart:288`); Python shows
  `timeout_user_message()` because `ConnectTimeout` is a `TimeoutException`
  (`bakalari_http.py:308`, `strava_client.py:230`). And a Strava `SocketException`
  after connecting becomes `strava_unreachable` in Dart, while Python says
  `strava_connection_lost` (`strava_client.py:235`: only `ConnectError` is
  "unreachable"). Keep `ConnectFailure` (the never-sent rule is right), but choose the
  message from its `cause`: a `TimeoutException` cause gives the timeout message, and
  only `ConnectFailure` gives "unreachable".
- **R-S6** Log lines print maps in Dart's style: `{type: days and hours, …}` vs Python
  `{'type': 'days and hours', …}` (seen in the dry-run `log.txt`;
  `automation/automation.dart:1239` and every log line that interpolates `$excuse`;
  Python `automation.py:787`). Format them with the existing `_pyRepr` so `log.txt`
  reads the same.
- **R-S7** `storage/helpers.dart:394-403, 489-523`: when libc can't be loaded, the lock
  silently falls back to `lockSync`, the per-process lock A-B5 was about. Print one
  `Warning:` line the first time this happens (CONTRIBUTING §5, fail loudly).

### Notes (for later checkpoints, nothing to do now)

- **R-N1** `wakeup.dart:509` compares absolute time (`difference`), Python compares wall
  time (`wakeup.py:371`); they differ by one hour only across a DST switch, and both
  results ring at the right moment. Look again at Checkpoint C.
- **R-N2** `app/lib/platform/desktop/notifications.dart:36` (`windowsToastGuid`) and
  the comment at `.github/workflows/dart.yml:68` say `{D94B0F7F-…}`; the Inno AppId
  in `installer.iss:14` and PLAN is `{D94B0B7F-…}`. `installer.iss` is right. Check
  at Checkpoint C which GUID the toasts need.
- **R-N3** `ConfigManager.save` (`storage/config.dart:607`) and `getKey`
  (`storage/secret_store.dart:79`) wait for their file lock with a blocking `sleep()`
  (up to 10 s). Python blocks only a worker thread; in Flutter this would freeze the
  UI isolate while another process saves. Checkpoint B: call them off the UI isolate
  or make the wait async.
- **R-N4** `automation/refresh.dart:726` passes `app.orderedDict` to
  `updateHandledDays`; Python passes `client.orderedDict or ordered_before`
  (`refresh.py:578`). The two differ only when the order dict comes back empty.
  Align it.
- **R-N5** `automation/automation.dart:1043-1047`: `sent_excuses_limit: 5.7` gives 100
  in Dart, 5 in Python (`int(5.7)`). Only a hand-edited config can hold that.
- **R-N6** `app/lib/platform/android/background.dart` passes
  `pendingExcuses: result.excusesFailed` to the phone sync. Check against Python at
  Checkpoint C.

## What I verified in the re-review, and how

Flutter 3.44.8 / Dart 3.12.2 on this PC (Windows 11, Europe/Prague). Probes and outputs
are in the reviewer's scratchpad, not committed. Nothing touched the owner's data,
key store or real servers.

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core, Windows) | clean / **757**: 756 passed, 1 skipped (the Linux-only flock probe) |
| Core suite on **Linux** (WSL Ubuntu, official Dart 3.12.2 SDK, `TZ=Europe/Prague`, every test file run directly with `--enable-asserts`) | **757 passed** (the flock probe runs there). The SDK was downloaded with the owner's OK and deleted afterwards |
| `flutter analyze` / `flutter test` (app) | clean / **124**: 123 passed, 1 skipped (APK scan, needs `STRAKALARI_APK`) |
| Python suite | **1643 passed** |
| `dump.py` regeneration + `git diff --exit-code` on `test/parity/` | **clean** |
| Dry-run parity (`tools/parity/soak_refresh.py` vs `bin/refresh_dryrun.dart`, one demo server, two throwaway folders) | `soak_compare.py`: **IDENTICAL**. Both: 55 timetable days, 2 audit records (manual + auto `dry_run`), 4 outbox items, 4 history items, empty sidecar. Written files byte-identical apart from timestamps; `log.txt` differs only in map formatting (R-S6) |
| Phase-2 fetch parity (`tools/parity/fetch.py` vs `bin/parity_fetch.dart`) | **byte-identical** (31,142 bytes) |
| Session lock, Windows, both directions | refused correctly both ways; acquired after release |
| Session lock, Linux, both directions + same process | refused correctly; second handle and second isolate refused |
| Real transport phases (local socket probe) | reset / no reply after the request → "maybe sent"; closed port → "never sent" |
| Config with encrypted passwords, both directions; entry names for 9 path shapes | match (see A-M4, A-M5 rows) |
| Test parity (pytest `--collect-only` vs Dart JSON reporter, per file) | Safety files case by case: `test_bakalari_excuse` 14 → 16 (3 network cases → 5), `test_session_lock` 6 → 6 + 5 new lock tests, `test_unconfirmed_excuses` 16 → 16 + corrupt-sidecar test, `test_automation_safety` 12 ported + 4 UI deferred, `test_refresh_pipeline` 9 → 8 (+ the new default-hook test; the 9th is missing, R-M3), `test_data_safety` 8 → 8 (spread over three Dart files) |
| Test integrity (`git diff 09157ff..` on all Dart tests) | no assertion loosened or removed (the scheduler tests became `async`, same expectations); no new `skip:` except the Linux-only probe; no `try`/`catch` around `expect`. Three DST tests don't call the code under test (R-S4) |
| Fail loudly (send, order and save code) | every swallowed exception has a Python counterpart that swallows too, except the dead `on OSError` catches (R-S1) |
| §3.5 pitfalls in the changed code (`RegExp`, `~/`, `%`, `round`, `weekday`, `DateTime.now`, `DateTime.parse`, `jsonEncode`) | OK, except `excuse.dart:192` (R-S3) |
| `package:flutter` in core, codegen, lockfiles, Flutter pin | none / none / committed / 3.44.8 + `--enforce-lockfile` |
| Personal data in history, real hosts in tests, upstream, `Co-Authored-By` / `Claude-Session` | none (`test/parity/config.json` is oracle data); tests use fakes or loopback only; no upstream; none |
| `main` merged and ported | `main` = `0ffdcff`, an ancestor of the branch; STATUS says `0ffdcff` |

**Still not verified:** macOS (R-M1 must go through the owner's CI), Android
(Checkpoint C), and phases 5–9, which stay unreviewed.

---

# Re-review 2 (2026-11-09)

Reviewed at `4045a11` (branch tip). Commits since the last re-review: `2ae814b..4045a11`
(10 commits: R-M1, R-M3, R-S1 … R-S7 with R-N4/R-N5, and R-M2). Same scope as above.

## Verdict: **PASS WITH FIXES**

Every finding of the last re-review is fixed in the code, not just marked fixed, and
nothing else broke: all suites are green on Windows and on Linux, the parity oracle
regenerates without a single difference, and a dry run against the demo server gives
the same audit, history, outbox and files as Python. The send path, the order path
and the locks changed only where the findings asked. Three should-fix items are left
(two missing tests and one log line), plus notes for later checkpoints. None of them
can send, order, or lose anything.

## Status of the last re-review's findings

| ID | Commit | How I checked | Result |
|---|---|---|---|
| R-M1 variadic `open` | `2ae814b` | `_OpenC` declares the mode as `ffi.VarArgs<(ffi.Int32,)>`, the Dart signature is unchanged, `dart analyze` accepts the binding. **Linux** (WSL, Dart 3.12.2, `TZ=Europe/Prague`): the libc binding loads, `freshLockFileIsOwnerReadWritable` passes and `matchesPythonFlock` passes (Python holds → Dart refused, Dart holds → Python refused, released → acquired), so the lock still holds after the change | fixed in code; Apple silicon unverified (R2-S3) |
| R-M2 STATUS | `4045a11` | Rework list compared with `git show --stat` of all 24 A-* and 9 R-* commits: every line now describes what its diff does. `HistoryLock` deviation corrected. Suite counts equal my runs (core 764 + 2 skipped, app 123 + 1 skipped). All 94 test-map counts equal `pytest --collect-only`, cases and (where different) functions, checked by script | fixed |
| R-M3 Gemini fallback test | `6e6c723` | `geminiFallbackIsNotAGeminiRun` is a literal port of `test_refresh_pipeline.py:159` (the same config as `CONFIG`, the same day, a failing transport, a no-op sleep, the same two asserts). `test_refresh_pipeline.py` 9 → 9 | fixed |
| R-S1 dead `OSError` catches | `8f70936` | The three sites catch `FileSystemException` (plus `KeyStoreUnavailable` in `decrypt`), like Python's `OSError`. `failedLogRotationStillAppendsTheLine` makes the real rename fail, and the line is still written | fixed |
| R-S2 delete-then-rename | `2cd35ae` | Both fallbacks removed; `replacesAnExistingFile` proves `renameSync` replaces on Windows; `failedReplaceNeverDeletesTheTarget` | fixed |
| R-S3 `DateTime.now()` | `4aafeb3` | `clock.now()`; grep finds no `DateTime.now()` left in core `lib/` | fixed |
| R-S4 DST tests | `a487824` | Rows come from the real Python functions (`dst_cases`); the Dart tests drive `fetchTimetableWeeks`, `fetchSubstitutions` and `runRefresh` under `withClock`. One gap: R2-S1 | fixed, one gap |
| R-S5 connect messages | `d5366ea` | `ConnectFailure.isTimeout` gives the timeout message in both clients; Strava says "unreachable" only for `ConnectFailure`, otherwise "connection lost", like `bakalari_http.py:307-313` and `strava_client.py:229-235`. The excuse's never-sent rule still sees the `ConnectFailure` as the cause | fixed |
| R-S6 log `repr` | `998906d` | `pyRepr` with 6 Python-generated parity cases; every excuse and order log line that printed a map uses it; the demo dry-run `log.txt` is now identical to Python's apart from timestamps | fixed |
| R-S7 libc warning | `c035cb1` | One `Warning:` line, on the first failure only (`_libcFailed`) | fixed |
| R-N4 | `c035cb1` | `orderedDict.isNotEmpty ? orderedDict : orderedBefore` is Python's `or` (`refresh.py:579`) | fixed |
| R-N5 | `c035cb1` | A float truncates, a bool gives 1/0, a string parses or falls back to 100, like `int()` (`automation.py:651`) | fixed |

## New findings

No blockers, no must-fix items.

### R2-S1 · should-fix · The substitution-range DST rows never cross a clock change

`tools/parity/dump.py:2397` runs `dst_cases` only for "today" = 30.3.2026 and
26.10.2026, the Monday after each switch. That is right for the timetable and history
weeks, which step **backwards** across the switch. But the substitution range steps 14
days **forward** (`bakalari_data.py:280-283`), so from those two days it never crosses a
switch, and `substitutionRangeIsPythonsCalendarRange`
(`packages/strakalari_core/test/parity_dst_test.dart:62`) cannot catch the original
A-B1 bug (19.10 + 14 days ending a week early). The old test for 19.10 was deleted in
R-S4. The same holds for the forward timetable week (`go_forward_weeks`): from 30.3 or
26.10 the next Monday doesn't cross a switch either.

I checked the code by hand: for today = 23.3, 27.3, 19.10 and 23.10.2026 with
`go_back_weeks: 4`, `go_forward_weeks: 2`, the real Dart code asks for the same Mondays
and sends the same `dateFrom` / `dateTo` strings as Python (identical JSON). So the code
is right; only the test is missing.

**Correct:** in `dst_cases`, also loop over `date(2026, 3, 23)` and `date(2026, 10, 19)`
(the Monday one week before each switch), for all three row kinds. Regenerate
`test/parity/dst.json`. The existing Dart tests read the new rows unchanged; run them
with `TZ=Europe/Prague`.

### R2-S2 · should-fix · Log lines for tolerated errors lose the message when it has several lines

`packages/strakalari_core/lib/src/storage/helpers.dart:589-603` `describeSwallowed`
vs `strakalari/core/helpers.py:414-428` `describe_swallowed`. Dart cuts the first line
with `substring(0, … ? 160 : text.length)`. When the error text has more than one line
and the first line is shorter than 160 characters, `text.length` is past the end of the
first line, `substring` throws `RangeError`, the `catch (_)` swallows it, and the log
line keeps only the type. Proven with a verbatim copy of the function: error text
`'timeout\ncall log: …'` gives Dart `Debug: waiting for the grid — StateError` and
Python `Debug: waiting for the grid — StateError: timeout`. It is used by
`bakalari/client.dart:155` and `strava/client.dart:242`, so `log.txt` and bug reports
lose the reason for exactly the multi-line errors Python's docstring mentions.
Diagnostics only: nothing is sent or saved differently.

**Correct:** split once and cut that line, like Python `text.splitlines()[0][:160]`:
`final line = text.split(RegExp(r'\r\n|\r|\n')).first;` then
`first = line.length > 160 ? line.substring(0, 160) : line;`. Add `describeSwallowed`
cases to `dump.py` (multi-line text, `\r\n`, a 200-character first line, empty text;
use a small Python exception class so `type(exc).__name__` is stable) and a parity test
that compares the part after the type name.

### R2-S3 · should-fix · No CI job can verify the macOS lock fix

`STATUS.md:609-610`, `:716` and `:748-750` say the Apple-silicon run of R-M1 stays
unverified "until the owner's macOS CI runs". But `.github/workflows/dart.yml:23-29`
runs the tests only on `ubuntu-latest` and `windows-latest`; the only macOS job
(`build-flutter-macos`, `:308`) builds the release and runs no tests. So that CI run can
never happen as described. The bug R-M1 fixed exists **only** on Apple silicon: on
Linux x64 (and Intel Macs) the variadic mode travels in a register, so
`freshLockFileIsOwnerReadWritable` passes on Linux even with the old declaration.

**Correct:** add a core test job on `macos-latest` (Apple silicon) that runs at least
`dart test test/session_lock_test.dart test/helpers_test.dart` in
`packages/strakalari_core` with `TZ: Europe/Prague`. To save CI minutes it may run only
on `workflow_dispatch` and on tags. Name that job in the three STATUS lines. Until the
owner runs it, macOS stays on the "not verified" list below.

### Notes (nothing to do now)

- **R2-N1** (Checkpoint C) `storage/helpers.dart:836` names the temp file
  `$path.$pid.tmp`. Python uses `tempfile.mkstemp` (`helpers.py:449`), unique per call.
  Two isolates of one process (the Android background isolate and the UI isolate) share
  the pid, so two concurrent writes of the same file would share one temp file. Config,
  history and the session-guarded writes are locked, so only unlocked writers could be
  hit. Look at it with the isolate hand-off at Checkpoint C; a unique name per call (for
  example a random suffix) would match Python.
- **R2-N2** `ConnectFailure.isTimeout` (`bakalari/http_session.dart:489-494`) recognizes
  dart:io's connect timeout by its message text ("HTTP connection timed out"). Fine on
  the pinned Flutter 3.44.8, but the test builds that text itself, so an SDK change
  wouldn't be caught. Re-check whenever Flutter is upgraded.
- **R2-N3** `pyRepr` escapes the common invisible characters, not every one Python's
  `repr` escapes (for example U+2000–U+200A and U+3000). Log text only. Accepted.
- **R2-N4** `STATUS.md:26` and `:766` still say "106" app tests (now 123). Fix with the
  Checkpoint B notes.

### Deviations of this round: sign-off

Accepted: `pyRepr` (Python `repr` for log lines, now shared with `school_presets`), the
variadic `open` binding, the one-time libc warning, `ConnectFailure.isTimeout` (see
R2-N2), and removing the delete-then-rename fallbacks. The Dropped list (`tls.py`,
`test_tls_bundle.py`, `test_frozen_ssl.py`, `test_imports_resolve.py`) is unchanged and
its reasons stay valid. `test_order_latch.py` (7) stays deferred to phase 5 because its
subject is `AppState.submit_orders`; Checkpoint B must find it ported literally before
the UI can send orders.

## What I verified in re-review 2, and how

Flutter 3.44.8 / Dart 3.12.2 on this PC (Windows 11, Europe/Prague). Probes and outputs
are in the reviewer's scratchpad, not committed; temporary probe tests were deleted and
the tree was clean afterwards. Nothing touched the owner's data, key store or real
servers (`STRAKALARI_NO_KEYRING=1` everywhere; both throwaway folders got a file key).

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core, Windows) | clean / **766**: 764 passed, 2 skipped (the two POSIX-only lock tests) |
| Core suite on **Linux** (WSL Ubuntu, official Dart 3.12.2 SDK with verified checksum, `TZ=Europe/Prague`, a copy of the branch tip, packages at the locked versions from the local pub cache) | `dart analyze` clean / **766 passed**, none skipped (both POSIX-only lock tests run there) |
| `flutter analyze` / `flutter test` (app) | clean / **124**: 123 passed, 1 skipped (APK scan, needs `STRAKALARI_APK`) |
| Python suite | **1643 passed** |
| `dump.py` regeneration + `git diff --exit-code` on `test/parity/` | **clean** (27 files, including the new `dst.json` and `pyRepr` rows) |
| Dry-run parity (`soak_refresh.py` vs `bin/refresh_dryrun.dart`, demo server on :18080, two throwaway folders) | `soak_compare.py`: **IDENTICAL**. Both: 2 audit records (auto and manual `dry_run`), the same outbox, history and sidecar. Files: `already_excused_lessons.json` byte-identical; `automation_history.jsonl` and `log.txt` identical apart from timestamps (both CRLF); `data_cache.json` differs only in `last_updated` |
| Session lock on Windows: Python's real `refresh.session_lock` vs Dart `withSessionLock` / `SessionLock` | Python holds → Dart refused; Python exits → Dart gets it; Dart holds → Python refused; Dart releases → Python gets it; a second handle in the same Dart process is refused |
| DST forward probe (real code, today 23.3 / 27.3 / 19.10 / 23.10.2026) | Dart = Python (see R2-S1) |
| Test parity | Test map: 94/94 files, every count equals `pytest --collect-only` (script). Safety files: `test_refresh_pipeline` 9 → 9 (+2 extra), `test_bakalari_excuse` 14 → 17, `test_session_lock` 6 → 6 (+6 lock tests), `test_unconfirmed_excuses` 16 → 16, `test_automation_safety` 12 ported + 4 UI deferred, `test_data_safety` 8 → 8, `test_excuse_history` unchanged since the last review |
| Test integrity (`git diff bd00f33..` on all Dart tests) | Only removals: the three re-implemented DST tests (replaced by real-code tests, as R-S4 asked) and the `OSError` fake in `decryptSurvivesKeyFileOSError` (now `FileSystemException`, same assertion). No new `skip:` except the POSIX-only permission test; no `try`/`catch` around `expect`; no `anything` / `isNotNull` |
| §3.5 pitfalls in the changed code | none (no new `RegExp`, `~/`, `%`, `round`, `weekday`, `DateTime.parse`, `jsonEncode`); no `DateTime.now()` left in core `lib/` |
| Fail loudly (send, order and save code) | No new swallowing catch; the file replace now propagates its error like `os.replace` |
| `package:flutter` in core, codegen, lockfiles, Flutter pin | none / none / committed / 3.44.8 + `--enforce-lockfile` |
| Personal data, real hosts, upstream, `Co-Authored-By` / `Claude-Session` | none (`test/parity/config.json` holds only the test values of `tests/test_config.py`); the new tests use fakes and loopback only; no upstream; all 81 branch commits by DeNdlerX, no such lines |
| `main` merged and ported | `main` = `0ffdcff`, an ancestor of the branch; STATUS says `0ffdcff` |

**Still not verified:** Apple-silicon macOS (R-M1, needs the job from R2-S3), Android
and the install-over tests (Checkpoint C), and phases 5–9, which stay unreviewed.

Left on this PC at the owner's request: the Dart 3.12.2 Linux SDK in WSL at
`~/dart-3.12.2`.
