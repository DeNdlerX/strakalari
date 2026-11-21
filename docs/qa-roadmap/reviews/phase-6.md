# R6 review: F4 (multiple accounts), code

Reviewed 2026-11-21 at `qa-roadmap` @ `96123ed` (base `main` @ `527699b`;
`main` has no commits the branch lacks, so no merge was needed at the
phase start). Commits since the R6a design re-review (`0be557f`):

- `3ee48eb` F4 commit 1: `background_refresh` key and the account storage core;
- `458fa1e` F4 commit 2: Android Keystore, startup and `AppState`;
- `99cafd4` F4 commit 3: switcher, Settings → Účty, add-account wizard, tour;
- `0ef079e`, `96123ed` STATUS (handover, Pixel 7 Pro check).

Checked against PLAN §6 (phase 6), §9, the binding
[`design-F4.md`](../design-F4.md), the owner's D4 and Q1–Q3 answers in
STATUS (word for word), CONTRIBUTING §5–6 and every earlier review. As
R6a asked, the parts the reviewer itself wrote into the note (§2.1
rebuild, §3.4 accounts mode, §4.2 move, §7.2 steps 3–4, §10.1 switch,
§10.3 `adding`) were checked hardest.

## Verdict: FAIL

The heart of F4 is done well. The one-time move does what the note says,
and the reviewer ran it on copies of demo data folders: today's Flutter
layout (with and without the OS key store) and a Play-app style folder
(Android wrapped key). Each time every original file kept its bytes and
its timestamp, the copies in `accounts/default/` were identical, the
passwords opened with the account's own key, and a second start changed
nothing at all. The reviewer also killed the move at ten moments with a
600 MB log in the folder: every next start finished it cleanly, with the
originals untouched and no staging folder left. Once account folders
exist the move never runs again, and any per-account file read or write
without an account folder fails loudly instead of using the old files.
Background refreshes run one account at a time, each inside
`withSessionLockAsync` and through `runRefresh`, with one shared result
handler; excuses still go only through `Strakalari.sendExcuse` with
`HistoryLock`, orders through the one order path, both audited into the
account's own folder. Deleting an account asks first and removes only
`accounts/<id>/`. All suites are green, no test was removed, skipped or
weakened, the new key is added everywhere it must be, the parity fixtures
changed only by that key, and all 33 new strings exist in cs and en.

Two findings block the pass:

- **M1:** after the update, *Aktivita* can't show the automation history
  any more (sent excuses, orders, cancels): the card shows an internal
  error instead of the list, and *Odesláno za 7 dní* always says 0. This
  hits every user, also with a single account.
- **M2:** nothing tests that *Zrušit* in the add-account wizard can only
  delete an account that is being added. The guard is in the code (twice),
  but the reviewer removed both copies and every test stayed green. That
  guard is what keeps a child's real account from being deleted (R6a M5).

Five should-fix (S1–S5) and seven notes. No owner decision is needed.

---

## Must-fix

### M1 (F4, `3ee48eb` + `458fa1e`): *Aktivita* lost the automation history

- **Where:** `app/lib/features/activity/activity_live.dart:57`
  (`loadAuditItems`) calls `core.recent(limit: limit)` without `dataDir`.
  In accounts mode (every install after F4, fresh ones too) `recent` →
  `historyPath` → `requirePerAccountDir(null)` throws
  `StateError('per-account file used without an account folder')`
  (`packages/strakalari_core/lib/src/storage/accounts.dart:139–145`, as
  §3.4 of the note wants). `loadAuditItems` catches it and returns an empty
  list plus the error text, so `ActivityView` shows
  *Historie automatizace: Bad state: per-account file used without an
  account folder* (`activity_view.dart:1032–1033`) and no rows, and the
  *Odesláno za 7 dní* KPI, which counts that list
  (`activity_view.dart:661`), is always 0.
- **Reviewer's check** (throwaway test, not committed): a pre-F4 folder
  with one audit record, then `ensureMultiAccountLayout`, then
  `loadAuditItems()` → `0 items, error="Bad state: per-account file used
  without an account folder"`. The record is in
  `accounts/default/automation_history.jsonl`; only the screen can't read
  it.
- **Why the tests missed it:** no test builds `LiveActivityView` or calls
  `loadAuditItems` in accounts mode, and the §3.4 call-site table in the
  note (written at R6a by the reviewer) didn't list this call either.
- **Correct:** `loadAuditItems` reads the **active account's** history:
  give it the folder (`loadAuditItems([int limit = 80, String? dataDir])`
  → `core.recent(limit: limit, dataDir: dataDir)`, called with
  `s.activeAccountDir` at l.74; `null` in degraded/legacy mode keeps
  today's root file). Then grep `app/lib` once more for every other
  `core.` call that ends in `loadDataCache`, `saveDataCache`, `recent`,
  `hasDryRun`, `historyPath`, `record`, `encrypt`/`decrypt`/`decryptStrict`
  or a `Strakalari(` without `dataDir` and list the result in the commit
  message (the reviewer found no other one, but the agent owns the
  check).
- **Test:** an app test in accounts mode with two accounts, each with its
  own audit record: `loadAuditItems` (or `LiveActivityView`) lists only
  the active account's record, no error; after `switchAccount` it lists
  the other one. It must fail at `96123ed`.

### M2 (F4 tests, `3ee48eb` + `99cafd4`): no test catches *Zrušit* deleting a real account

- **Where:** the guard is right in both layers:
  `AccountManager.cancelAddingAccount` refuses an account without
  `adding: true` (`accounts.dart:1467`, `:1492`), and
  `AppState.cancelAddAccount` returns early (`app_state.dart:645`). The
  note's §10.3 item 4 asks for a test that *Zrušit* "deletes only an
  `adding` account's folder".
- **What the tests do:** `accounts_test.dart:896–900` calls
  `cancelAddingAccount(tmp.path, 'default')` with **one** account, so it
  throws for "last remaining account", never because of the missing flag.
  `accounts_ui_test.dart:551` (`existing account with cleared credentials
  ... is never deleted`) only checks that no *Zrušit* button is shown.
- **Reviewer's check:** with both guards removed (core and `AppState`),
  `accounts_test.dart`, `app_state_accounts_test.dart` and
  `accounts_ui_test.dart` all stay green.
- **Correct:** add tests with **two** finished accounts (no `adding`):
  `AccountManager.cancelAddingAccount(root, <the other id>)` throws
  `StateError` and leaves `accounts.json` and that folder untouched; and
  `AppState.cancelAddAccount()` with a non-adding active account whose
  credentials were cleared (`setupPending == true`) returns `false` and
  leaves its folder and registry entry. Each must fail when its guard is
  removed.

---

## Should-fix

### S1 (F4 tests): a child's *Pozadí vypnuto* isn't tested in the scheduler

`scheduledRefreshJob` skips an account with `background_refresh: false`
(`app/lib/controllers/activity.dart:372`, tray at `:466`); that is the
owner's D4 #3. With the skip removed, all F4 tests stay green (reviewer's
check). Add a test: two accounts, the second with `background_refresh:
false`, both due → a scheduled pass refreshes only the first; turned on
again → both.

### S2 (F4 tests): the move's "passwords open with the carried key alone" check is untested

`_verifyMigration` steps 4–5 (`accounts.dart:1297–1314`, note §4.2 step 6)
make sure the carried key really opens the saved passwords before
anything is committed. With that check disabled, `accounts_test.dart`
stays green (reviewer's check): every test carries the right key, so the
store/file equality checks alone pass them. Add a test where the root
`config.json` holds a password encrypted with a key that is **not** the
one carried (for example a store entry and a `secret.key` that differ, or
a token from another key): the move must end degraded, write no
`accounts.json` and no `accounts/default/`, and leave every root file
byte-identical.

### S3 (F4, `3ee48eb`): an Android install with two different keys never moves

When `secret.key.wrapped` and a plain `secret.key` both exist and differ,
today's code uses the **plain file** (`secret_store.dart:112–118`,
"using the file"; covered by
`differingPlainKeyIsKeptAlongsideWrappedKeyAcrossStarts`). The move's
Android branch takes the **wrapped** key as `K`
(`accounts.dart:1070–1116`), so verification fails, and it fails again on
every start: the install stays in degraded mode for good and shows the
*Přechod na více účtů se nepodařilo dokončit* hint each time. Nothing is
lost (reviewer's probe on a demo copy: `status=degraded`, originals
identical), but such a user never gets accounts. **Correct:** carry the
key `getKey` would use: when both files exist and differ, take the file
key (file mode; both files are copied anyway); when they match, keep
today's path. Test: that layout moves, and the password opens with
`accounts/default`'s key alone.

### S4 (F4, `3ee48eb`): an interrupted Store/macOS copy can drop accounts

The classic → Store and bundle → Application Support copy with accounts
(`helpers.dart:294–343`, `_migrateBundleData`) writes account after account, each one's
`config.json` at its end, and `accounts.json` last. `_needsBundleMigration`
(`helpers.dart:218–226`) says "no copy needed" as soon as the target has
**any** account folder with a `config.json`. A crash after the first
account's `config.json` but before the last one's leaves a target that
is never completed: the next start rebuilds the registry from the folders
that made it, and the other children's accounts are silently missing
(their data stays in the old folder). The note's own rule (§4.1, written
by the reviewer at R6a) has this hole; the test interrupts only at a key
carry, before any `config.json`. **Correct:** copy every account's other
files first, then all the `config.json` files, then `accounts.json`; and
when the old folder has an `accounts.json`, decide "copy needed" from the
target's `accounts.json` alone (`_copyMissing` never overwrites, and the
bundle copy runs inside `getUserDataDir()`, before
`ensureMultiAccountLayout` could rebuild anything). Test: an interruption
after the first account's `config.json`; the next launch has both
accounts and `accounts.json`.

### S5 (F4, `99cafd4`): *Spravovat účty* doesn't open Settings → Účty

The note (§10.1) says the switcher's *Spravovat účty* goes to
Settings → Účty. It calls `context.go(routeLocation('settings'))`
(`app/lib/shell/scaffold.dart:680`, `router.dart:158`) without setting the
section, so on a phone the user lands on the Settings list (or on
whatever section was open last). Set `settingsSection = 'accounts'` and
`settingsOpen = true` first, as `more.dart:152–153` does for Budík, and
extend the switcher test to check the Účty card is on screen.

---

## Notes (no action needed unless stated)

- **N1 (lock order):** `createProvisionalAccount`, `finishAddingAccount`,
  `setActiveAccount`, `setPrimaryAccount`, `renameAccount` and the delete
  hold `accounts.json.lock` and then call `AccountRegistry.load`, which,
  if `accounts.json` is unreadable at that moment, rebuilds it under
  `migrate.lock` + `accounts.json.lock` (`accounts.dart:586–600`): the
  opposite order to note §6, and the same lock taken twice. With the
  timeouts it ends in a `StateError` after about 10 s, not a hang, and
  only with a damaged registry. Fine to leave; if touched, read the
  registry before taking the lock.
- **N2:** `activity.dart:975`, `assert(... || true)` is a no-op written to
  silence the analyzer. Remove it with the next change there.
- **N3:** `findDuplicateStravaLogin` also reads `strava_id` and
  `strava_user` (`accounts.dart:362`, `:365`), which aren't config keys
  (CONTRIBUTING §6: no aliases). Read-only and harmless; drop them with
  the next change there.
- **N4 (screens):** the delete dialog has 4 of the 8 combinations
  (cs dark 390, cs light 1280, en dark 390, en light 1280), the More card
  only 390 px (it exists only on phones). The rest of the 68 PNGs cover
  cs/en, dark/light, 390/1280, and are newer than the last UI commit.
  Enough.
- **N5 (interrupted move):** all ten kills landed in the staging copy,
  which dominates with a 600 MB log. Interruptions at the later steps
  (key carry, verify, `global.json`, rename) are covered by
  `accounts_test.dart` Item 4 (injected crash after each step, then a
  clean retry), which the reviewer read and which passes; the "folders
  exist, registry missing" case is Item 5.
- **N6 (hosts):** the new tests use example addresses
  (`https://school1.cz`, `https://a.school.cz`, `bakaweb.gekom.cz` as the
  preset's address) only as config values for the duplicate check; no
  test opens a connection.
- **N7 (STATUS):** the header still says "Base: main @ be701d9"; `main`
  is `527699b`, which only adds the R5 merge note to STATUS. Nothing to
  merge.

---

## Done when (PLAN §6 phase 6, through the note)

- **Folder layout, shared/per-account split (§2–3):** 19 shared + 55
  per-account keys (`configKeyClassificationMatchesDesignSpec`); shared
  keys are read only from `global.json`, a save writes each part to its
  own file (`config.dart` `_loadMultiAccount` / `_saveMultiAccount`). ✔
- **One-time move, copy + verify, never delete originals (§4.2):** ✔,
  run by the reviewer (above); verify step untested (S2); Android
  two-keys case (S3).
- **Installing over today's Flutter and Play data (§4.1):** ✔ on demo
  copies (keyring, no keyring, wrapped key); real `adb install -r` over
  the pre-F4 `.test` app on the Pixel 7 Pro (STATUS, `phone/01–04`;
  headless start after the update logged no warning, the app opened on the
  same account without a password prompt). The real Play upgrade is
  unverified, as the note allows.
- **Credential names, fallback to today's names (§5):** account keys
  under `entryName(accountDir)`, root entry untouched, `decrypt` /
  `decryptStrict` fall back to the root key (`decryptStrictFallsBackToRootKey`). ✔
- **`session.lock` (§6):** one global lock for refresh, send, order, move,
  delete and add-cancel. ✔ (Item 9; breaking the background lock fails it.)
- **Background refresh one at a time through `runRefresh` (§7):** ✔;
  the per-account switch is untested (S1).
- **Notification, widget, alarm show the primary account (§8):** ✔
  (Item 13, phone `15`–`21b`).
- **What deleting deletes, with confirmation (§9):** ✔ dialog, backup
  line, `accounts/<id>/` only; cancel guard untested (M2).
- **Tutorial (rule 7):** `'accounts'` tour, `tut_settings_intro_body`
  updated, `TOURS_DONE`. ✔
- **Everything else in the app works after the move:** ✘ *Aktivita*
  history (M1).

## Each part caught by a test (reviewer undid it, one at a time)

| Undone | Caught? |
|---|---|
| move runs again when account folders exist but `accounts.json` doesn't | yes (Item 5) |
| per-account file without folder silently uses the root (`requirePerAccountDir`) | yes (Item 7) |
| shared keys also read from the account file | yes (Item 7) |
| background account refresh without `withSessionLockAsync` | yes (Item 9) |
| add mode guessed from "setup not finished" | yes (`accounts_ui_test`) |
| *Zrušit* allowed on a non-adding account (core + `AppState`) | **no** (M2) |
| move verify: passwords with the carried key alone | **no** (S2) |
| scheduler ignores `background_refresh: false` | **no** (S1) |

The only F4 test that compiles at the parent is
`f4BackgroundRefreshConfig`: it fails there with an assertion
(`Expected: true, Actual: <null>`). The other F4 tests call code F4 added,
so they were judged by reading and by the table above.

## What the reviewer verified, and how

1. **Suites**, at `96123ed` after `dart pub get --enforce-lockfile`:
   core `dart analyze` no issues, `dart test` **875 passed, 2 skipped**;
   app `flutter analyze` no issues, `flutter test` **807 passed,
   1 skipped**. Both match STATUS, and both grew since R5 (855 / 789).
   Flutter rewrote the line endings of the seven generated plugin
   registrant files in the review worktree; the reviewer restored them to
   `HEAD` (no content change).
2. **Test integrity:** `git diff 0be557f..HEAD` on the existing test files:
   only the new optional `route` parameter in five fake notifier backends;
   nothing removed, skipped or loosened. The only new `skip:` is
   platform-conditional (`msix*` tests skip off Windows; they ran here).
   `parity/helpers.json` changed only by `"background_refresh": true` in
   the two full configs of `roundTripFiles` (PLAN rule 4).
3. **Config key:** `background_refresh` is in `config.example.json`,
   `canonicalDefaults`, `validateConfig` and `config_test.dart`, all in
   `3ee48eb`; a script compared `config.example.json` with
   `canonicalDefaults`: 74 keys each, the same set.
4. **Strings:** a script diffed both ARB files against `0be557f`: 33 new
   keys, the same in cs and en, all in `strings.dart`, real Czech and
   English; two changed (`tut_settings_intro_body` and `_narrow`); none
   removed.
5. **Safety rules (CONTRIBUTING §5):** read every F4 change in
   `automation/`, `storage/`, `lunches/`, `strava/`, `bakalari/` and
   `controllers/`: refreshes only through `runRefresh` under
   `withSessionLockAsync` (active and background accounts, tray, headless);
   excuses only through `Strakalari.sendExcuse` (`HistoryLock` from the
   account's `already_excused_file`); `audit.record` called with the
   account folder for every send/order/cancel, dry run included;
   `automationPaused` read from each account's own config; no new silent
   `catch` in send, order or save code (the new `catch (_)` are in
   probes, label lookups and the best-effort failure stamp); confirmation
   defaults unchanged (`confirmAutoMode` now passes the account folder for
   its dry-run check).
6. **The move on demo data** (throwaway test and a compiled probe, not
   committed): `tools/demo_data.py generate` folders plus encrypted
   logins, history, unconfirmed file, blacklist, audit and log (with
   `.old`), `config.json.bak`, `update_cache.json` and a user preset;
   moved with a fake OS key store, with `STRAKALARI_NO_KEYRING=1`, and as
   Android with a fake Keystore (`secret.key.wrapped`). Whole-tree SHA-256
   and timestamps before/after, and before/after a second start. Then ten
   real process kills (`taskkill /F`) during the move of a folder with a
   600 MB log, each followed by a normal start.
7. **M1** reproduced with a throwaway app test; **S3** with a throwaway
   core test (two differing Android keys → `degraded`).
8. **Hygiene:** no upstream for `qa-roadmap`; `git log qa-roadmap..main`
   is empty; no `Co-Authored-By` / `Claude-Session` / "Generated with" in
   the F4 commits; `git log --stat` shows no `config.json`, data cache,
   log, `htmls/`, key or phone screenshot.
9. **Phone evidence** (`build/qa-evidence/F4/phone/`, 28 PNGs + 8 text
   files): read the upgrade logcat and services dumps and opened the
   Activity screenshot (`21b`); the Play app wasn't touched by the
   reviewer.
10. **Throwaway worktree** in the reviewer's scratch folder: plugin links
    removed one by one first, then the folder; every package in the pub
    cache still has its `pubspec.yaml`.
