# R6a review: F4 design note (`design-F4.md`)

Reviewed 2026-11-20 at `qa-roadmap` @ `9365138` (base `main` @ `527699b`;
`main` has no commits the branch lacks). The note came in `755db60` and was
refined in `9365138` with the owner's Q1–Q3 answers. Both commits touch
only `design-F4.md` and `STATUS.md`: no F4 code was written.

## Verdict: FAIL

The note has the right shape and most of it matches the code. It covers
every point PLAN §6 lists for phase 6, it classifies all 73 config keys
(checked: 19 shared + 54 per account, none missing, none twice) plus the
one new key `background_refresh`, it never deletes the originals, it keeps
one global `session.lock`, and it sends every background refresh through
`runRefresh`, one account at a time. The credential fallback to today's
key is right, and so is most of what it says about the Android Keystore,
notification routing and the wizard steps.

Seven points must change before any code is written. In plain words:

- **M1:** if the account list file (`accounts.json`) is ever lost or
  damaged, the one-time move can run a second time and copy the old
  pre-update files over the newer data, or the app falls back to the old
  files. That loses settings and excuse history.
- **M2:** while the move runs, nothing stops a refresh or an automatic
  send from writing the old files at the same time, and a phone whose move
  failed once keeps working on the old files even after the other half of
  the app finished the move. "Degraded mode" isn't defined.
- **M3:** every file function falls back to the old top-level files when a
  call forgets the account folder. Several places in the app already
  resolve files that way. One concrete result: the lunch blacklist edited
  on Obědy would be saved where automatic ordering doesn't read it.
- **M4:** two existing moves (classic Windows install → Store app, macOS
  app bundle → Application Support) copy a fixed list of top-level files.
  After F4 they would leave every account behind.
- **M5:** the note decides that an account is "being added" from
  "setup not finished". A real account whose login was cleared would show
  the add-account wizard, and its *Zrušit* would delete that account.
- **M6:** a background refresh of another child's account handles the
  result with a second, smaller copy of the active account's code. It
  would send no "new mark" or "lunch cancelled" notifications for that
  child, and an empty Strava balance would retry every 5 minutes.
- **M7:** the delete dialog promises that the account's saved logins and
  data are deleted. For the account that came from the update, a full copy
  stays in the old top-level files.

Thirteen should-fix points (S1–S13) and ten notes follow. No owner
decision is needed for these; the owner's D4 and Q1–Q3 answers are enough.

---

## Must-fix

### M1 (§2.1, §4.2): the move can run again over newer data

- **Where:** `design-F4.md` l.80 (corrupt `accounts.json`: quarantine,
  "reconstruct … **or fall back to single-account mode**"), l.169 (the
  move runs when there is no `accounts.json` and a root `config.json`),
  l.177 (copy: "skip if destination already exists with matching
  SHA-256"), l.192 ("Write `global.json` (if missing)").
- **What is wrong:**
  - After the move, the root `config.json` stays on disk forever (rule:
    never delete originals). So "no `accounts.json` + root `config.json`"
    is true again whenever `accounts.json` disappears. The note itself
    makes it disappear: `quarantineCorruptFile` renames the file away
    (`helpers.dart:316–333`). The next start, or the other isolate on
    Android, then runs the move again and copies the month-old pre-update
    files into `accounts/default/`, over the newer settings, cache and
    excuse history (including the `unconfirmed` list that blocks re-sends).
  - "Fall back to single-account mode" runs the app on the root files,
    which after the move are an old copy.
  - Step 4 says what happens when the destination file matches, not when
    it differs (overwrite? keep?), and nothing removes a file left in
    `accounts/default/` by an earlier attempt that the root no longer has.
  - Step 8 writes `global.json` only "if missing", so a `global.json` left
    by an interrupted attempt keeps old shared settings although the root
    `config.json` changed since (for example in degraded mode, M2).
- **What correct looks like** (write it into §2.1 and §4.2):
  - The move runs only when there is no `accounts.json` **and no account
    folder with a `config.json`** under `accounts/`. When `accounts.json`
    is missing or unreadable but account folders exist, the app rebuilds
    the registry from the folders (under `accounts.json.lock`, loudly, ids
    from the folder names, `active_id`/`primary_id` = `default` if present,
    else the first) and **never** reads the root files again.
  - The app never falls back to the root files once an account folder
    exists. If even the rebuild fails, it stops with a clear message
    instead of running.
  - Copy into a staging folder whose name can't be an account id (for
    example `accounts/.migrating/`, excluded by the l.63 regex), delete any
    leftover staging folder first, copy everything from scratch, verify
    there, write `global.json` from the current root `config.json` every
    time (not "if missing"), then rename the staging folder to
    `accounts/default/` and write `accounts.json` last. A crash before the
    rename leaves only the staging folder, which the next attempt deletes.
    A crash after the rename is the "registry missing, folders exist" case
    above. On desktop, `carryKey` targets the final path
    `accounts/default` (the keyring entry is bound to the path), so it
    stays right after the rename.
  - Tests: (1) a second run after a finished move changes nothing (all
    files and their modification times the same); (2) `accounts.json`
    deleted, and separately made unreadable, after the move and after
    changes in `accounts/default/`: the app rebuilds the registry and the
    changes survive, root files untouched; (3) a crash injected after each
    step (copy, key, verify, `global.json`, rename) and a new run: the end
    state equals a clean run.

### M2 (§4.2 step 7, §6): the move isn't protected from refreshes, and "degraded mode" isn't defined

- **Where:** l.169 (only `migrate.lock`), l.191 ("degrades safely into
  single-account compatibility mode on `<rootDir>` for this launch"),
  l.246–247 (`migrate.lock` is a leaf lock, not under `session.lock`).
- **What is wrong:**
  - The UI and a headless wake are two isolates in one Android process
    (`background.dart:177–206`). If the headless run's move fails once
    (for example a Keystore hiccup in step 6), it carries on in degraded
    mode on the root files and may run a refresh with automatic sends.
    Meanwhile the UI starts, its move succeeds and copies the root files
    while the headless run is still writing them, and commits. Whatever
    the headless run writes after the copy (an excuse in
    `already_excused_lessons.json`, an `unconfirmed` entry, `strava_ordered`)
    is lost to F4. An `unconfirmed` entry is exactly what must not get
    lost (CONTRIBUTING §5, "One send path").
  - Degraded mode has no rules: nothing says the account switcher and
    *+ Přidat účet* are hidden. Adding an account there would create an
    `accounts.json` without the existing account, and the next start would
    never move the root data (it would look like a fresh multi-account
    install with the old account missing).
  - A move that keeps failing (for example `carryKey` returns `false`
    every time because the keyring doesn't answer) is only a `Warning:` in
    the log. A non-technical user never learns why accounts can't be added.
  - The note doesn't say where in startup the move runs. On desktop it
    must run after the single-instance guard (`startup.dart:80–92`):
    before it, a second launch could start moving data while the running
    instance still writes it. On Android it must run before
    `warmAndroidKeystore`, before the first `ConfigManager()` /
    `AppState()` and, in the headless entry, before the
    `run_in_background` read (`background.dart:133–146`, see M3).
- **What correct looks like:**
  - The move takes `session.lock` first (waiting a bounded time, say up to
    2 minutes), then `migrate.lock`, for the whole copy → verify → commit.
    Update the lock order in §6 to `session.lock` → `migrate.lock`. If it
    can't get `session.lock`, it doesn't move this time.
  - Degraded mode, written as rules: no account UI and no
    *+ Přidat účet*; it never writes `accounts.json` or `global.json`;
    right before each refresh, send and order (under `session.lock`) it
    checks whether `accounts.json` now exists, and if it does, it does not
    run (skips with the "session busy" style message; the next start uses
    the accounts).
  - A visible hint when the move failed (Settings → Účty, or a one-time
    snackbar), in cs and en, saying the update could not be finished and
    the app keeps working as before.
  - The startup order above, written into §4.1 for desktop, the Android UI
    and the Android headless entry.
  - Tests: the move waits for a held `session.lock`; a degraded process
    refuses to refresh once another process committed; no account UI in
    degraded mode.

### M3 (§3.4, §5.2): a forgotten account folder silently means the old top-level files

- **Where:** l.143–149 ("core storage functions gain optional
  `String? dataDir` parameters **defaulting to `null`
  (`getUserDataDir()`)**"), l.213.
- **What is wrong:** after the move, `getUserDataDir()` is the root, where
  the untouched pre-update copies lie. Any call that doesn't pass the
  account folder reads or writes those copies without a warning. The note
  lists core functions only. Places in today's code that resolve
  per-account files against the root and aren't in the note:
  - `app/lib/controllers/lunches.dart:531–540` (`_blacklistPath`, used by
    the blacklist editor and `blacklistWords`). The blacklist edited on
    Obědy would go to the root `strava_blacklist.json`, while automatic
    ordering reads `accounts/<id>/strava_blacklist.json`
    (`automation.dart:423`, `strava/client.dart:154`). A banned meal (an
    allergy, say) could be ordered automatically.
  - `config.dart:747` (`getBlacklistPath`) and `config.dart:834`
    (`getAlreadyExcusedPath`).
  - `app/lib/features/settings/settings_live.dart:52–58` (*Vymazat
    mezipaměť* deletes `core.resolvePath(core.cacheFile)`, the root cache).
  - `app_state.dart:89`, `:384`, `:391`, `:794` and `lunches.dart:352`,
    `:372` (`loadDataCache()` / `saveDataCache()` without a folder).
  - `app_state.dart:166` (`final ConfigManager config = ConfigManager()`,
    the root `config.json`).
  - `error_report.dart:231` (`redactWithSavedConfig` reads the root
    `config.json`; see also S10).
  - `background.dart:135`: the headless entry reads `run_in_background`
    from the root `config.json`. After the move that switch lives in
    `global.json`. A user who had background running off before the update
    and turns it on afterwards gets every wake cancelled at l.141–145, so
    background refreshes (and F3's cancels before the cutoff) never run
    while the screen is closed.
  - `audit.dart:44` (`historyPath()`), `automation.dart:436–438`.
- **What correct looks like:**
  - A missing account folder fails loudly instead of meaning "root". Two
    acceptable ways; pick one and write it in §3.4:
    (a) make the folder a required parameter of every per-account file
    function (cache, audit, `Strakalari`, `StravaClient`, the per-account
    `ConfigManager` paths, the app's blacklist and cache helpers), so the
    compiler finds every caller; or (b) keep the optional parameter, but
    once the process runs with accounts (set once, after the move or
    registry load, never changed back), a per-account file function
    called without a folder, and `ConfigManager()` on the root
    `config.json`, throw `StateError` (only the move itself may read the
    root files). Shared files (`session.lock`, `update_cache.json`,
    `school_presets/`, `instance.token`) keep using the root.
  - List every call site above in §3.4 with what it gets instead, and say
    that the headless entry reads `run_in_background` from `global.json`
    once accounts exist.
  - Test: on a moved layout, run a full cycle for two accounts (refresh,
    manual and automatic send, order and cancel in dry run, blacklist
    edit, clear cache, settings save, error report) and check that every
    root file is byte-identical afterwards. This one test also proves
    "originals are never changed".

### M4 (§4.1): the classic → Store and bundle → Application Support moves would leave the accounts behind

- **Where:** l.160–161 ("classic → MSIX → F4 chains cleanly",
  "chaining cleanly").
- **What is wrong:** both existing moves copy a fixed list of top-level
  files (`_bundleDataItemNames`, `helpers.dart:180–190`) and decide from
  `config.json` alone (`_needsBundleMigration`, `helpers.dart:210–214`;
  `legacyDesktopDataDir`, `packaging.dart:81–87`, returns null when there
  is no root `config.json`). The note only covers moves that happen
  before F4. After F4:
  - A classic install upgraded to F4 still has the old root `config.json`.
    Installing the Store version copies that old file and the other old
    top-level files, but not `accounts.json`, `global.json` or `accounts/`.
    The Store app then runs the F4 move on the old copy: every change
    since the update and every added account is gone.
  - A classic install that started with F4 has no root `config.json`, so
    the Store app copies nothing and starts empty.
  - macOS: `_macosAppDataDir` uses the bundle as the data folder when its
    move fails (`helpers.dart:200–205`), so F4 can write accounts into the
    bundle, and the next successful bundle move leaves them behind.
  - The desktop keys are bound to the folder path (`entryName`,
    `secret_store.dart:63–70`). Each account's key has to be carried to
    the new path, like `carryKey` does for the root key today
    (`helpers.dart:290`).
- **What correct looks like:** add the two moves to §4.1 and the plan:
  when the old folder has an `accounts.json` (or account folders), the
  move copies `accounts.json`, `global.json` and the whole `accounts/`
  tree, carries the root key and the key of every `accounts/<id>/`
  (`carryKey(old/accounts/<id>, new/accounts/<id>)`), and uses
  `accounts.json` as its "move finished" marker (written last, like
  `config.json` today); `legacyDesktopDataDir` also accepts an
  `accounts.json` without a root `config.json`. Tests for both moves with
  two accounts, keyring and `STRAKALARI_NO_KEYRING`, including a move that
  is interrupted.

### M5 (§10.3): "adding an account" is guessed from "setup not finished", so *Zrušit* can delete a real account

- **Where:** l.368 (`addingAccount == true, i.e., accounts.length > 1 &&
  setupPending`), l.370 (`cancelAddAccount()` "deletes the provisional
  account dir + key").
- **What is wrong:** `setupPending` is true also for an account that is
  finished but has no login left: `needsSetup()` is
  `_savedWizardStep >= 0 || !_hasAnyCredentials()`
  (`app_state.dart:873`, `:890–898`), and the shell opens the wizard at
  once whenever `setupPending` is true (`scaffold.dart:239–247`). So a
  parent who clears the Bakaláři login of child B (to type it again, say)
  gets the add-account wizard for B, and *Zrušit* deletes B's folder:
  settings, excuse history, cache, audit, with no confirmation.
- **What correct looks like:**
  - An explicit, saved marker for an account that is still being added,
    for example `"adding": true` on its entry in `accounts.json`, set by
    `beginAddAccount()` and removed only by Finish (in one registry write
    with the label). `addingAccount` reads only that marker.
  - *Zrušit* deletes an account only when it has the marker. It takes
    `session.lock` first, like delete (the F1c early refresh may be
    running for it, `activity.dart:336–342`).
  - In add mode the only ways out are Finish and *Zrušit* (no dismiss
    that leaves an empty account behind).
  - An account without the marker whose setup is pending gets the normal
    wizard (all its steps, no *Zrušit*), like a single-account install
    today.
  - Test: an existing account with cleared credentials opens the normal
    wizard without *Zrušit*, and its folder is never deleted; *Zrušit* on a
    marked account deletes only that folder.
  - Also fix the wording slip at l.367: `wizard_step` is a per-account
    config key (§3.2), so it goes into the new account's `config.json`,
    not into `accounts.json`.

### M6 (§7.2 step 3): another child's background refresh gets a second, smaller copy of the result handling

- **Where:** l.276–281 (`_refreshBackgroundAccount`: run record, log
  lines, `gemini_last_run`, "on error … notifies `refresh_failed` /
  `automation_failed`, marks `anyFailed = true`").
- **What is wrong:** `runRefresh` is shared, but what happens with its
  result lives in `_refreshLocked` (`activity.dart:403–538`), and the
  note's copy drops most of it:
  - `result.news` → `new_mark`, `new_quarterly_mark`, `new_absence`,
    `timetable_change` notifications (l.461–463). A parent would hear
    about new marks only for the child on screen, which is the main reason
    to add a second child.
  - The F3 `lunch_skipped` notice for automatic cancels (l.464–469).
  - The low-balance case (l.502–509): an empty Strava account is a
    warning and the run counts as done, "so the scheduler does not retry
    every 5 minutes". In the note's copy it is an automation error, so
    `anyFailed` → `JobFailed` → a retry of every account every 5 minutes,
    with an `automation_failed` notification each time.
  - The combined fetch-and-automation error case (l.490–501) and
    `refresh_done` (l.522).
- **What correct looks like:** one result handler for every account.
  Move the part of `_refreshLocked` after `runRefresh` into a function
  that takes the account context (its config and folder, its notify with
  the account label and `?account=`, its run list and log), and call it
  from both the active and the background path; only the active path
  additionally touches the screen state (`pendingOrders`, `reloadCache`).
  Say in §7.2 that the background path is that function, not a list of
  steps. Tests: a background account's new mark notifies with its label;
  its F3 cancel sends `lunch_skipped`; its empty Strava balance doesn't
  make the job fail or retry.

### M7 (§9): the delete dialog promises more than is deleted

- **Where:** l.322 ("**Deleted locally:** saved Bakaláři and Strava
  logins and this account's encryption key; … excuse history, and
  activity log"), l.332 (files outside the folder are kept), l.195 (the
  root copies stay forever).
- **What is wrong:** the account that came from the update (`default`)
  has a full pre-update copy in the root: `config.json` with the stored
  passwords, the root key that decrypts them (it stays, because it also
  encrypts the shared Gemini key, l.205), `data_cache.json`,
  `already_excused_lessons*.json`, `automation_history.jsonl`, `log.txt`.
  An absolute `log_file` or `already_excused_file` path is kept too
  (l.332). Deleting `default` removes none of that, but the dialog says
  the logins and history are gone.
- **What correct looks like:** the dialog tells the truth for this case.
  Simplest, and enough: when the account being deleted is the one that
  came from the update (mark it in `accounts.json`, for example
  `"migrated": true`) or has a file outside its folder, add one line in cs
  and en, such as *"Kopie dat z doby před aktualizací zůstává ve složce
  aplikace, dokud aplikaci neodinstalujete."* /
  *"A copy of the data from before the update stays in the app folder
  until you uninstall the app."* Don't delete the root files (PLAN: never
  delete the originals). Write the exact strings into §9 and §10.5, and
  test that the line shows only for that account.

---

## Should-fix

### S1 (§4.2 step 6): the key check passes even when the key wasn't carried

- **Where:** l.184–186.
- **What is wrong:** step 6 checks the passwords with `decryptStrict(…,
  dataDir: defaultAccountDir, fallbackKeyDir: rootDir)`. With the fallback
  it succeeds through the root key even if the account's own key is
  missing or wrong (on desktop, `getKey` would silently make a new one,
  `secret_store.dart:182–188`). On Android, `warmAndroidKeystore`
  quarantines a blob it can't unwrap and makes a new key
  (`android_keystore.dart:170–180`), so "unwraps it cleanly" can't be read
  from its result, and it has to run before any `decryptStrict` on that
  folder (an un-warmed folder makes core quarantine it,
  `secret_store.dart:102–111`).
- **What correct looks like:** check the carried key directly, without
  the fallback: on desktop `getKey(defaultAccountDir)` equals
  `getKey(rootDir)` byte for byte after `carryKey`; on Android warm the
  account folder first and compare its key with the root key; then
  decrypt each stored password with the account key alone. Also add
  `log.txt.old` to the step 3 list (`writeLog` rotates to it,
  `automation.dart:619–626`; the uninstaller knows it,
  `installer.iss:222`).

### S2 (§5.3): warm an account's Android key right before it is used, not only at isolate start

- **Where:** l.228–229.
- **What is wrong:** the warmed bridge answers only for warmed keys, and
  for any other blob core quarantines `secret.key.wrapped` and makes a new
  key (`secret_store.dart:102–111`, `android_keystore.dart:83–87`): the
  account's saved passwords are lost. Warming once at isolate start misses
  an account added in the other isolate after that (the registry is read
  later, in the refresh loop, l.267).
- **What correct looks like:** an idempotent `ensureWarmed(accountDir)`
  awaited right before every `createApp` / `getKey` / `ConfigManager`
  for an account, in both isolates (refresh loop, switch, add, status
  inputs for `primary_id`). Test: an account added after the headless
  isolate started is refreshed there without its key being quarantined.

### S3 (§7.2 step 5): a failing account makes every account refresh every 5 minutes, and a long pass can outrun Android's limit

- **Where:** l.287–289 (`JobFailed` → `PeriodicRunner` retries in 5
  minutes), l.269 (one loop, no time limit).
- **What is wrong:**
  - The retry reruns the whole loop. With child B's wrong password, child
    A is also refreshed (and its auto phases run) every 5 minutes, 12
    times the data. The owner's own measurement is about 1 MB per refresh
    (STATUS, *Real refresh data measurement*).
  - A headless wake lives at most 32 minutes (`RefreshReceiver.java:52`,
    `HOLD_MS`), the wake lock 30 (`background.dart:211`), and each refresh
    may wait up to 30 (`activity.dart:257`). With two or three accounts
    and one slow server, a later account's refresh can be killed in the
    middle, possibly mid-send.
- **What correct looks like:** each account has its own "last finished"
  time; an account runs when it is due (its last finished run plus the
  interval, or 5 minutes after its own failure). The 5-minute retry
  touches only the accounts that failed. The pass has a time budget
  (for example: start no new account after 20 minutes into the pass;
  each account's wait is bounded so the pass stays under 30 minutes);
  what is left runs on the next wake. Replace the "oldest `last_updated`"
  seed at l.289 with this rule. Tests for both.

### S4 (§6, §10.1): switching accounts needs a safer rule than a list of busy flags and fields to clear

- **Where:** l.249 (busy: `refreshRunning || sendingExcuses.isNotEmpty
  || orderRunning || testing.isNotEmpty`), l.349 (the fields cleared on
  switch).
- **What is wrong:**
  - `aiRunning` (`app_state.dart:179`), the F1c early setup refresh and a
    background refresh of another account in the same isolate are not in
    the busy list. An AI lunch pick for child A that finishes after the
    switch is staged for child B (`stagePick`), and B's *Odeslat* would
    order A's choices.
  - Switching to B while B's own background refresh runs shows B's old
    cache, and nothing reloads it when that refresh ends.
  - A list of fields to clear is easy to get wrong as `AppState` grows
    (it is a field-for-field port with dozens of fields); a forgotten one
    carries child A's state into child B's screens.
- **What correct looks like:** every account-bound async operation takes
  the active account id when it starts and drops its result (with a log
  line) if the active account changed; the busy check also covers
  `aiRunning`, the early refresh and any background refresh in this
  isolate; when a background refresh of the account now on screen
  finishes, `reloadCache()` runs. Write an allow-list of what survives a
  switch (`runsByAccount`, `logLinesByAccount`, the update info, tutorial
  state, navigation) and reset everything else to what a cold start for
  that account would build; a test compares a switched `AppState` with a
  freshly built one for the same account.

### S5 (§7.2 step 4, §8): notification taps for the account on screen, and taps while busy

- **Where:** l.285 (`?account=` only "when `accountId` is present"),
  l.286 (busy: "stays safely on the current account"), l.310 (a tap
  without `?account=` switches to `primary_id`).
- **What is wrong:** if the active account's own events are posted
  without `?account=`, l.310 treats them like the status notification and
  switches to `primary_id`: a tap on child B's "new mark" (B on screen,
  A primary) opens A. And when switching isn't possible (busy), l.286
  opens the target screen on the wrong child.
- **What correct looks like:** every per-account event carries
  `?account=<id>`, the active account's too (`update_available` stays
  without it). When the switch is refused because something runs, the
  app doesn't open the target screen for the other child: it shows a short
  snackbar naming the account and switches when the run ends (or the user
  taps again). Tests for both.

### S6 (§7.2 step 3, §8): the primary account's notification, widget and alarm must come from the same code as the screen

- **Where:** l.278 (`cancelledLunchDays` "recomputed … matching
  AppState's constructor logic"), l.306 (status inputs "loaded cleanly
  from disk").
- **What is wrong:** `backgroundStatusInputs()` (`app_state.dart:741–788`)
  and `syncAndroidState()` (`:722–737`) are built from many `AppState`
  helpers (`excuseTasks`, `phoneTimetable`, `food`, `stableBaseline`,
  `lunchFreeDays`), and `cancelledLunches` from the constructor
  (`:108–127`). Doing it again "from disk" for another account is a second
  copy that will drift (a wrong pending-excuse count, a wrong alarm day).
- **What correct looks like:** extract those derivations into functions
  that take an account's config and cache, and use them both in
  `AppState` and for `primary_id` / background accounts (or build a
  read-only `AppState` for that account). Say which in §7.2 and §8. Test:
  status inputs for a non-active primary equal those of an `AppState`
  built for it.

### S7 (§3.4): say which file wins for a shared key, and what a save writes where

- **Where:** l.136–141.
- **What is wrong:** `ConfigManager.save` writes `defaultConfig()` plus
  the file plus the edits (`config.dart:668–696`, l.681), so every
  account `config.json` will also hold all 19 shared keys (the moved
  `default` holds them already, l.177), with stale values. The note
  doesn't say that shared keys are read only from `global.json`. A save
  that touches both files (the wizard's Finish) can also half fail: the
  note doesn't say what happens to the edits of the file that failed.
- **What correct looks like:** shared keys come only from `global.json`
  (then defaults), never from an account file; an account write leaves
  out the shared keys and a `global.json` write leaves out the account
  keys; if one of the two writes fails, its edits stay pending and the
  error is raised (fail loudly), the other write stands. Tests for the
  precedence and the half-failed save.

### S8 (§9): switch away first, then delete; a deleted account can't come back from a late save

- **Where:** l.326–334 (the switch to `nextActiveId` is the last step).
- **What is wrong:** deleting the account on screen while its Settings
  fields are open: the B2 fields save on blur and dispose. A late save
  through the deleted account's `ConfigManager` finds no file and writes
  the whole in-memory config (`config.dart:669`), so the folder comes back
  with the username and the encrypted passwords.
- **What correct looks like:** if the target is active, switch to
  `nextActiveId` first and let pending saves finish, then delete; the
  `ConfigManager` (and cache writes) of a deleted account refuse to
  create a missing account folder. Test: delete the active account with a
  focused field, the folder stays gone.

### S9 (§5.3, missing from the note): the uninstaller and `--forget-secrets`

- **Where:** l.231; `installer.iss:200–239` isn't mentioned.
- **What is wrong:** *Remove all user data* in the Windows uninstaller
  deletes a list of known top-level files and then the install folder if
  empty (`installer.iss:209–238`). After F4 it would leave `accounts/`
  (every child's history, cache, logs), `accounts.json` (names) and
  `global.json`. `forgetAllKeys` as written relies on the registry, which
  may be the lost file of M1.
- **What correct looks like:** add `installer.iss` to the plan: delete
  `accounts.json`, `global.json` and `DelTree(AppDir + '\accounts')`
  (owned by the app); `--forget-secrets` forgets the root key and the key
  of every folder under `accounts/` it finds on disk, registry or not.

### S10 (§7.2 step 3): redact every account's secrets from tracebacks

- **Where:** l.281; `error_report.dart:228–240` (`redactWithSavedConfig`,
  used by `scheduler.dart:166`).
- **What is wrong:** the scheduler redacts tracebacks with the root
  `config.json` only. Child B's password, if an exception text echoes it,
  would reach the log and a shared error report.
- **What correct looks like:** `redactWithSavedConfig` (and `writeLog`'s
  scrub) use the secrets of every account plus `global.json`. Test with a
  second account's password in a traceback.

### S11 (§8): the alarm settings of a non-primary account do nothing, but stay editable

- **Where:** l.311–312 (a banner above an otherwise normal
  `WakeupCard`).
- **What is wrong:** only `primary_id`'s `wakeup_*` keys drive the
  phone's alarm. Turning on the alarm for child B (not primary) saves it,
  shows it, and it never rings.
- **What correct looks like:** on a non-primary account (Android, more
  than one account), Budík shows the banner and a *Nastavit jako hlavní*
  button instead of the editable card (or the card read-only). Strings in
  cs and en; test.

### S12 (§10.3): don't allow the same login twice

- **What is wrong:** nothing stops a parent from adding the same child
  again (easy to do if the first attempt looked like it failed). Two
  accounts on one Bakaláři login have two separate excuse histories and
  planners, double the data and the notifications; on one Strava login, an
  account in `auto` order mode can re-order a lunch the other account
  cancelled for a planned day off, and the other then treats it as the
  user's own choice (`auto_lunch_cancel_handled`), so the lunch is paid
  for. F2's outbox read before each automatic send should keep excuses
  from being sent twice, but nothing else does.
- **What correct looks like:** the Bakaláři step of the add-account
  wizard (and Settings → Účty when the login is changed) refuses a
  Bakaláři address + username (compared case-insensitively, address
  without a trailing slash) that another account already uses, naming
  that account; the same for a Strava canteen + username. Strings in cs
  and en; tests.

### S13 (§11): the test and phone plan must name the cases the reviewer will run

- **Where:** l.395, l.400, l.406 (test file names only), l.413 (phone).
- **What is wrong:** §11 lists test files, not cases. R6 will run the
  move itself on throwaway copies of today's Flutter layout and of
  Play-app style data, a second run and an interrupted run, and check the
  originals after each, and that two accounts never refresh at the same
  time. And the phone plan can't create Play-app data in the `.test` app
  (`run-as` doesn't work on `.test`, STATUS B9; the Play app is never
  touched).
- **What correct looks like:** list the cases in §11: the move of a
  desktop layout (keyring and `STRAKALARI_NO_KEYRING`), an Android/Flet
  layout (wrapped key and plain `secret.key`), a second run, a crash after
  each step, a lost and a corrupt `accounts.json` (M1), degraded mode
  (M2), the root-files-unchanged cycle (M3), both data moves (M4), the
  adding marker (M5), the shared result handler (M6), two accounts never
  in `runRefresh` at once (UI scheduler, tray *Obnovit data* and a
  headless wake together), delete and *Zrušit*. For the phone: the real
  upgrade test is today's `.test` build set up against the demo server,
  then the F4 build installed over it with `adb install -r`; a second
  account uses a second demo server on another port (`--port 18081`,
  another address, so S12 allows it); the real Play upgrade can't be run
  here, so it is covered by the Flet-layout unit test and marked
  *unverified* in STATUS.

---

## Notes (no action needed unless stated)

- **N1 (downgrade):** an older version installed over F4 would run on the
  pre-update copy, and its changes would be ignored after the next
  upgrade. That's acceptable; say in §4 that downgrading isn't supported.
- **N2 (scope captions, §10.2 l.359–361):** a caption on every Settings
  section adds text, and the owner wants as little as possible (D1
  simplicity). One short muted line, only when there is more than one
  account, as the note says, is fine; don't add more.
- **N3 (Q3, tray pause):** the owner left Q3 to the agent. Pausing only
  the account on screen, with its name in the menu item, is accepted. The
  reviewer would find "pause everything" a safer brake for the tray; the
  owner can ask for it.
- **N4 (labels):** two accounts can get the same label (two empty
  signatures with the same username at different schools), which makes
  the `[label]` prefix ambiguous. Adding " 2" on a clash would be enough.
- **N5 (primary change):** *Nastavit jako hlavní* and deleting the primary
  move the phone's alarm to the other child's alarm settings at once. The
  button could say so in its hint.
- **N6 (two-account demo data):** say in §11.2 how the two-account
  screenshots are made (add-account wizard against two demo servers, or a
  `tools/demo_data.py` option).
- **N7 (checked, correct):** `_bundleDataItems` (`helpers.dart:216`),
  `carryKey` / `forgetKey` / `entryName` (`secret_store.dart`), the
  single-pair `WarmedAndroidKeystore` (`android_keystore.dart:61–91`), the
  Keystore channel that wraps any bytes (`StrakalariChannel.java`), the
  route request codes (`Notifications.java:110–135`, any other route gets
  `1000 + hash`), rotating event ids (`StrakalariChannel.java:360–369`, so
  two accounts' notifications don't replace each other),
  `routeForLocation` already dropping `?…` (`router.dart:68–77`),
  `session.lock` resolved against the root (`session_lock.dart:29`), the
  history and `unconfirmed` files derived from `alreadyExcusedFile`
  (`automation.dart:436`, `excuse_history.dart:274`), the wizard step
  constants (`wizard_controller.dart:84–91`), `TourPlace.topLeft`, and no
  clash of the 28 new string keys with existing ones.
- **N8 (STATUS):** the header still says "Base: main @ be701d9"; `main`
  is now `527699b`, which only adds the STATUS merge note. Nothing to
  merge.
- **N9:** the parity fixtures may change only by `background_refresh` in
  the two full configs of `roundTripFiles` (§3.3), as PLAN rule 4 allows.
  Keep it that way.
- **N10:** the owner's D4 and Q1–Q3 answers are recorded word for word in
  STATUS and match §3 and §12.

---

## What the reviewer verified, and how

1. `git log` / `git diff --stat 527699b..HEAD`: the two F4 commits change
   only `design-F4.md` and `STATUS.md`; no code, tests, fixtures, strings
   or config keys. `git log qa-roadmap..main` is empty; the branch has no
   upstream; both commit messages are plain (no `Co-Authored-By`,
   `Claude-Session` or "Generated with"); no personal data committed.
2. Suites, run by the reviewer at `9365138` after
   `dart pub get --enforce-lockfile`: core `dart analyze` no issues,
   `dart test` **855 passed, 2 skipped**; app `flutter analyze` no issues,
   `flutter test` **789 passed, 1 skipped**. Same counts as at R5.
3. Config keys: a script compared `config.example.json` with
   `canonicalDefaults` in `config.dart` (73 each, the same set) and with
   the note's §3.1/§3.2 tables (19 + 54 + `background_refresh`, every key
   once).
4. Every code claim of the note read against the code: data-dir
   resolution and the two existing moves (`helpers.dart:79–301`,
   `packaging.dart:81–87`), the key store (`secret_store.dart`), the
   Android Keystore warm-up (`android_keystore.dart`), the headless entry
   and tick (`background.dart:101–369`, `RefreshReceiver.java:52`), the
   scheduler (`scheduler_jobs.dart`, `activity.dart:256–538`), `AppState`
   construction, setup gating, status inputs and launch routes
   (`app_state.dart:75–166`, `:700–800`, `:873–1001`, `scaffold.dart:239–247`),
   config load and save (`config.dart:525–724`), the cache
   (`cache.dart:95–160`), every `resolvePath(` / `getUserDataDir()` /
   `loadDataCache(` / `saveDataCache(` / `ConfigManager(` call in core and
   app (grep), notifications (`android_notifications.dart`,
   `Notifications.java`, `StrakalariChannel.java`), the tray
   (`startup.dart:183–197`), the wizard steps, tours, `demo_data.py`
   `TOURS_DONE`, and the uninstaller (`installer.iss:180–239`).
5. No throwaway worktree was needed (no code to test against a parent),
   so the shared pub cache wasn't touched.

---

## Re-review 2026-11-20

At the owner's word ("Can you fix the plan?", recorded in STATUS
*Owner decisions*), the reviewer fixed the note itself, like the F1c note
at R3c: `f8e8a8a` (M1–M7, S1–S13, N1–N4, N6) and `67bb97e` (three
corrections the reviewer found in its own fixes on re-reading, below).
Both commits change only `design-F4.md` (and `f8e8a8a` the STATUS owner
line). No code.

### Verdict: PASS

Every finding is fixed in the note, checked below. Because the same
reviewer wrote the fixes and checked them, this check is less independent
than usual: at R6 the code review must look hardest at the parts written
here (§2.1 rebuild, §3.4 accounts mode, §4.2, §7.2 steps 3–4, §10.1
switch, §10.3 `adding`).

### Findings, checked

- **M1:** §4.2 runs the move only with no `accounts.json` **and** no
  account folder with a `config.json`; §2.1 rebuilds a lost or unreadable
  registry from the folders under `migrate.lock` + `accounts.json.lock`,
  never reads the root files again and never falls back to them (error
  screen if even the rebuild fails). The copy goes into
  `accounts/.migrating/` (not a valid id), from scratch every attempt,
  `global.json` is rewritten every attempt, then rename, then
  `accounts.json` last. Tests §11.2 items 3–5.
- **M2:** the move holds `session.lock` (up to 2 minutes) then
  `migrate.lock` from re-check to commit; §6 lock order updated. Degraded
  mode has rules (no account UI, never writes `accounts.json` /
  `global.json` / `accounts/`, checks for a finished move under
  `session.lock` before each refresh/send/order, user hint
  `account_migration_failed`). §4.1 gives the startup order on desktop
  (after the single-instance guard), the Android UI and the headless
  entry. Test item 6.
- **M3:** §3.4 picks option (b): a one-way accounts mode in which every
  per-account file function without a folder, `ConfigManager()` on the
  root `config.json`, and (`67bb97e`) `encrypt` / `decrypt` without a
  folder throw. A table lists every call site M3 named with what
  each gets; the headless `run_in_background` gate reads `global.json`.
  Test item 7 is the root-files-unchanged cycle.
- **M4:** §4.1 extends `legacyDesktopDataDir`, `_needsBundleMigration`
  and the copy list (`global.json`, `accounts/`, every account key via
  `carryKey`, `accounts.json` last). Test item 8.
- **M5:** `adding: true` in `accounts.json` is the only marker (§2.1,
  §10.3); an account with a cleared login gets the normal wizard without
  *Zrušit*; *Zrušit* only for `adding`, under `session.lock`; only Finish
  and *Zrušit* leave add mode; `wizard_step` goes into the new account's
  `config.json`. Test §10.3 item 4.
- **M6:** §7.2 step 4: one `handleRefreshResult` for every account, with
  the full list of what it does (news, `lunch_skipped`, low balance,
  combined failure, `refresh_done`, run record). Test item 11.
- **M7:** §9 adds `account_delete_backup_note` (exact cs/en text) for an
  account with `migrated: true` or a file outside its folder; the root
  files are never deleted. Test item 14.
- **S1:** §4.2 steps 5–6 verify the carried key directly (store entry or
  staged file equals the root key; on Android the same blob), decrypt
  with that key alone, never call `getKey` on the not-yet-existing folder;
  `log.txt.old` added.
- **S2:** `ensureWarmed(accountDir)` before every use of an account's key
  in both isolates (§5.3). Test item 12.
- **S3:** due accounts (§7.2 step 3) and a pass budget under the 30/32
  minute limits (step 4). `67bb97e`: a failed account stays due through
  `scheduled_refresh_failed` in its cache, because `last_updated` is
  saved before the auto phases run (`refresh.dart:314`, `:365`), so a
  failing account (also a single one) is still retried in ~5 minutes as
  today. Test item 10.
- **S4:** §6 busy list extended (`aiRunning`, early refresh, background
  refresh), account token for async results, reload after a background
  refresh of the account on screen; §10.1 switch by allow-list
  (`67bb97e` adds the wiring and `schedulerLastRun` to it) through one
  `_loadAccount()` shared with the constructor. Test item 13.
- **S5:** every per-account event carries `?account=`; a busy tap shows
  `account_tap_busy` and switches later (§7.2 step 5, §8). Test item 13.
- **S6:** `cancelledLunchDaysFor` and the status/widget/alarm derivations
  are extracted and shared (§7.2, §8). Test item 13.
- **S7:** §3.4 precedence (shared keys only from `global.json`), split
  writes, half-failed save keeps its edits and raises. Test item 7.
- **S8:** §9 switches away first, a deleted account's `ConfigManager` and
  cache writes refuse to recreate the folder. Test in §9 and item 14.
- **S9:** §5.3 `installer.iss` removes `accounts.json`, `global.json`,
  `accounts\`; `forgetAllKeys` uses the folders on disk. Test item 12.
- **S10:** §7.2 step 7 redacts every account's secrets. Test item 12.
- **S11:** §8 Budík on a non-primary account: banner and *Nastavit jako
  hlavní*, no editable card. Test item 15.
- **S12:** §10.3 refuses a duplicate Bakaláři or Strava login (also in
  Settings → Účty). Test §10.3 item 4.
- **S13:** §11.2 lists 15 test cases; §11.3 the real `.test` upgrade
  (`adb install -r` over today's build), a second demo server on port
  18081 for the second account, and the Play upgrade marked unverified.
- **N1** (downgrade, §4.1), **N2** (captions, §10.2), **N3** (§12),
  **N4** (unique labels, §2.1), **N6** (two-account demo data, §11.3) are
  in the note. N5 stays a note.

### Corrections the reviewer made to its own fixes (`67bb97e`)

- The first version of the "due" rule used `last_updated` alone, which
  would have stopped the 5-minute retry after an auto-phase failure, also
  for a single account. Fixed as described under S3.
- The first switch allow-list forgot the wiring (`onChanged`,
  `configListeners`, `spawn`): after a switch the screen and the tray
  would have stopped updating. Fixed.
- `encrypt` / `decrypt` without a folder now also fail loudly in accounts
  mode.

### What the reviewer verified, and how (re-review)

1. `git diff 0e86932..67bb97e --stat`: only `design-F4.md` and one STATUS
   line.
2. The key script again: 73 keys in `config.example.json` and
   `canonicalDefaults`, the note's tables 19 + 55 (with
   `background_refresh`), none missing or twice.
3. A script over §10.5: 33 new string keys, all unique, none already in
   `app_cs.arb` / `app_en.arb`, and every `account_*` key the note uses is
   in the list.
4. A search of the note for the wording the findings replaced ("fall back
   to single-account mode", "skip if destination", "(if missing)",
   `&& setupPending)`, "defaulting to `null` (`getUserDataDir()`)"): none
   left.
5. The code facts the fixes rely on, read again: `JobFailed` is reported
   and retried in ~5 minutes without a second notification
   (`scheduler.dart:30–40`, `:154–156`, `:179–184`, `activity.dart:293`);
   `startupSeed` reads `last_updated` (`cache.dart:215`); the refresh
   saves `last_updated` before the auto phases (`refresh.dart:314`,
   `:365`); `carryKey` writes a file into the new folder when the store
   refuses (`secret_store.dart:308–314`), which is why §4.2 step 5 doesn't
   call it on the not-yet-existing folder.
6. Suites not re-run: no code changed since the R6a run (core 855 passed /
   2 skipped, app 789 passed / 1 skipped).
