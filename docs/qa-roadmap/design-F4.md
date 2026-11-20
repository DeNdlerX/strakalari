# F4 design note: Multiple accounts

Status: **design note only, no F4 code written yet.** Written 2026-11-20 against `qa-roadmap` / `main` @ `be701d9` (after R5 passed and merged). R6a review FAIL the same day; the reviewer fixed M1–M7 and S1–S13 in this note at the owner's word ("Can you fix the plan?", 2026-11-20), see [`reviews/phase-6-design.md`](reviews/phase-6-design.md).

Sources: [`PLAN.md`](PLAN.md) §6 (Phase 6 — F4), §8 (D4), owner's D4 answers recorded word for word in [`STATUS.md`](STATUS.md), `CONTRIBUTING.md` §5–6, and report §3.2 (background — note that report §3.2 assumes `flutter_secure_storage`, whereas the real codebase uses Fernet encryption backed by `secret_store.dart` + `DesktopKeyStore` / Android Keystore `strakalari-secret-key`; this note follows the real codebase).

---

## 1. Summary & Goals

Allow one installation of Strakaláři (Windows, macOS, Linux, Android; iOS-ready) to hold **multiple independent school accounts** (for example, a parent managing two children, or a student with two accounts) with:

- **Complete per-account data isolation:** credentials, encryption keys, school preset/calendar overrides, absence limits, planned skips, excuse templates, sent/unconfirmed excuse history, timetable/marks/lunches cache, lunch blacklist, automation rules, audit log, and per-account log file live in separate folders under `<rootDir>/accounts/<account_id>/`.
- **Clear shared vs. per-account split:** app-wide preferences (theme, language, layout density, timetable view, marks sort, tutorials, disclaimer, update channel, notification preferences, device background/tray switches, check interval, network timeouts, and shared Gemini API key) live once in `<rootDir>/global.json`; every student/school/automation setting lives in `<rootDir>/accounts/<id>/config.json`.
- **Per-account background refresh toggle (D4 #3):** a new canonical boolean key `background_refresh` (default `true`) lets the user turn automatic background refresh on or off individually per account, in **Settings → Accounts** and **Settings → Rules**.
- **Lossless one-time upgrade:** existing desktop Flutter installs (classic, MSIX, macOS, Linux), Android Flutter installs, and **Google Play Python (Flet) installs** move automatically on first launch (UI **or** Android headless wake): under `session.lock` + `migrate.lock`, files are copied into a staging folder, verified byte-for-byte + JSON + key, renamed to `accounts/default/`, and `accounts.json` is written last. **No original root file is ever deleted or changed**, and once account data exists the move never runs again (§4.2).
- **No silent fallback to the old files:** once the app runs with accounts, a per-account file read or write without an account folder fails loudly instead of using the pre-update copies in the root (§3.4).
- **Safety rules preserved (`CONTRIBUTING.md` §5):** one pipeline (`runRefresh`, with one shared result handler for every account), one global `<rootDir>/session.lock` (one refresh/send/order at a time across all accounts and processes), one send path (`Strakalari.sendExcuse` + per-account `excuse_history.dart` + `HistoryLock`), everything audited per account (`automation_history.jsonl`, dry run included), per-account `automation_paused`, fail loudly, and destructive account deletion gated by an explicit confirmation dialog.
- **Zero clutter for single-account users:** when only one account exists, the top bar, bottom bar, notifications, widget, and wake-up alarm look and behave identically to today.

---

## 2. Folder Layout

Let `<rootDir>` be the app's root user data folder returned by `getUserDataDir()` (`packages/strakalari_core/lib/src/storage/helpers.dart` — `STRAKALARI_DATA_DIR`, Android `getApplicationSupportDirectory()/data`, macOS `~/Library/Application Support/Strakalari`, MSIX `%LOCALAPPDATA%\Strakalari`, writable classic Windows install dir, or Linux `~/.config/strakalari`). `getUserDataDir()` itself does **not** change, keeping all existing core parity tests and platform resolution intact.

```text
<rootDir>/
  accounts.json                      # Account registry, active_id, primary_id (atomic JSON, commit marker of the move)
  accounts.json.lock                 # InterProcessLock guarding accounts.json writes
  global.json                        # App-wide shared settings (19 keys; see §3)
  global.json.lock                   # InterProcessLock guarding global.json writes
  session.lock                       # ONE global cross-process session lock (shared with legacy/Python builds)
  migrate.lock                       # InterProcessLock guarding one-time moves (existing bundle/Store moves + F4)
  instance.token                     # Desktop single-instance IPC token (existing, unchanged)
  console.log (+ .old)               # Windows windowed release stdio log (existing, unchanged)
  update_cache.json                  # GitHub release check cache (existing, app-wide, unchanged)
  school_presets/                    # User-supplied school calendar preset JSONs (existing, app-wide, unchanged)
  secret.key / secret.key.wrapped    # Root Fernet key (encrypts global.json gemini_api_key; fallback for migrated default)

  # Untouched pre-F4 backup files (present ONLY on upgraded installs; NEVER deleted or changed by the app):
  config.json, config.json.bak, data_cache.json, already_excused_lessons.json,
  already_excused_lessons.unconfirmed.json, strava_blacklist.json,
  automation_history.jsonl (+ .old), log.txt (+ .old)

  accounts/
    .migrating/                      # Staging folder of an unfinished move only (never a valid id; deleted by the next attempt)
    <account_id>/                    # 'default' for first/migrated account; 'acc_<12 hex>' for added accounts
      config.json (+ .lock, .bak)    # Per-account canonical config (per-account keys only; see §3.4)
      data_cache.json                # Per-account timetable, absences, marks, lunches, outbox cache, cancel-handled list
      already_excused_lessons.json (+ .lock)     # Per-account sent & web-synced excuse history + HistoryLock
      already_excused_lessons.unconfirmed.json   # Per-account unconfirmed submits awaiting outbox settlement
      strava_blacklist.json          # Per-account forbidden lunch ingredients
      automation_history.jsonl (+ .old, .lock)   # Per-account audit log
      log.txt (+ .old)               # Per-account core log
      secret.key / secret.key.wrapped            # Per-account Fernet key (Android wrapped or no-keyring fallback)
```

### 2.1 Account ID rules & `accounts.json` schema

- **Account IDs:**
  - Migrated single-account install and first fresh-install account: `'default'`.
  - Additional accounts created via `+ Přidat účet`: `'acc_<12 lowercase hex chars>'` generated via `Random.secure()`.
  - Validation regex: `^[a-z0-9][a-z0-9_-]{0,39}$` (so `.migrating` is never an id). Every path resolution also asserts `p.isWithin(p.join(rootDir, 'accounts'), accountDir)` so a tampered `accounts.json` can never escape `accounts/`.
- **`accounts.json` format:**
  ```json
  {
    "version": 1,
    "active_id": "default",
    "primary_id": "default",
    "accounts": [
      {
        "id": "default",
        "label": "Jan Novák",
        "created_at": "2026-11-20T21:30:00",
        "migrated": true
      },
      {
        "id": "acc_3f9c0a1b2d4e",
        "label": "",
        "created_at": "2026-11-21T18:02:00",
        "adding": true
      }
    ]
  }
  ```
  - `migrated` (optional, default `false`): set only on the account that came from the one-time move (§4.2); the delete dialog uses it (§9).
  - `adding` (optional, default `false`): set by `beginAddAccount()` on an account still in the add-account wizard and removed only by its Finish (§10.3). It is the **only** thing that makes an account "being added".
- **Invariants on load (`AccountRegistry.load`; a plain read, while a rebuild runs under `migrate.lock` + `accounts.json.lock`):**
  - `accounts` is deduplicated by `id`, invalid IDs are dropped, and entries whose folder `accounts/<id>/` doesn't exist are dropped with a loud log line; at least one entry must remain.
  - If `active_id` is missing from `accounts`, fall back to `accounts.first.id`.
  - If `primary_id` is missing from `accounts`, fall back to `active_id`.
  - **Registry missing or unreadable while account folders exist** (any `accounts/<valid id>/config.json`): quarantine an unreadable file via `quarantineCorruptFile`, log loudly, and **rebuild** `accounts.json` from the folders: ids from the folder names, `active_id` and `primary_id` = `default` if present, else the first id in sorted order, labels derived as below, `migrated: true` on `default` if the root holds a pre-F4 `config.json`, no `adding` flag (a half-added account then shows the normal wizard, never a *Zrušit* that deletes, §10.3). The rebuild never reads the root files and never runs the move (§4.2).
  - If even the rebuild fails (no writable registry), the app shows a clear error screen with the reason and doesn't run any refresh, send or order. It **never** falls back to the root files once an account folder exists.
- **Default display `label`:**
  - On migration from legacy `config.json`: `your_signature` (trimmed, if non-empty and not placeholder) → else `bakalari_username` (if non-empty and not placeholder) → else `''` (rendered in the UI as localized `account_default_label`: `"Hlavní účet"` / `"Main account"`).
  - On finishing the add-account wizard: `your_signature` → else `bakalari_username` → else `"Účet N"` / `"Account N"`.
  - Always editable via Rename in **Settings → Účty** (trimmed, non-empty, max 60 characters).
  - Labels are kept unique: when a derived or typed label equals another account's label (case-insensitive), ` 2`, ` 3`, … is appended, so the `[label]` notification prefix (§7.2) always names one account.

---

## 3. Shared (`global.json`) vs. Per-Account (`accounts/<id>/config.json`) Settings

Every single one of the **73 existing keys** in `config.example.json` / `canonicalDefaults` plus **1 new per-account key (`background_refresh`)** = **74 canonical keys** is classified below.

### 3.1 Shared settings — `<rootDir>/global.json` (19 keys)

Defined as `const Set<String> globalConfigKeys` in `packages/strakalari_core/lib/src/storage/accounts.dart`:

| Group | Keys | Why shared |
|---|---|---|
| Appearance & UI layout (5) | `theme`, `language`, `compact_density`, `timetable_view`, `marks_sort` | App shell appearance & view preferences; switching accounts must not flash themes or flip languages. |
| Onboarding & legal (3) | `disclaimer_accepted`, `tutorials_enabled`, `tutorials_done` | Accepted/completed once per installation; adding a second child should not replay the intro tour or disclaimer. |
| Device & background shell (4) | `minimize_to_tray`, `run_in_background`, `background_notification_items`, `check_interval_minutes` | One desktop tray process, one Android `KeepAliveService` + ongoing notification layout, and one wake schedule interval. |
| Notifications & updates (2) | `notifications`, `update_channel` | Event toggle preferences (including app-wide `update_available`) and release channel for the single installed binary (owner Q1, §12). |
| Network & cache display (2) | `page_load_timeout_s`, `cache_ttl_hours` | Device/network timing & staleness display threshold. |
| Shared Gemini API credentials (3) | `gemini_api_key`, `gemini_api_key_encrypted`, `gemini_model` | One Google AI Studio key per household/device (encrypted with the root key `getKey(rootDir)`), while per-child lunch preferences stay separate below (owner Q2, §12). |

### 3.2 Per-account settings — `<rootDir>/accounts/<id>/config.json` (55 keys)

| Group | Keys | Why separated |
|---|---|---|
| School portals & logins (10) | `bakalari_url`, `bakalari_username`, `bakalari_password`, `bakalari_password_encrypted`, `strava_url`, `strava_canteen_id`, `strava_username`, `strava_password`, `strava_password_encrypted`, `use_strava` | Distinct credentials and portals per student. |
| Per-account file paths (3) | `log_file`, `strava_blacklist`, `already_excused_file` | Resolved relative to `<accountDir>` (absolute paths outside `<accountDir>` stay absolute and are untouched on delete). |
| School preset & calendar (7) | `school_preset_id`, `sem1_close`, `sem2_close`, `user_free_days`, `forced_school_days`, `holidays`, `school_year_end` | Two children may attend different schools or grades with different closures and free days. |
| Absence limits & planner (6) | `absence_warn_pct`, `absence_critical_pct`, `absence_plan_reserve_pct`, `subject_limits`, `planned_skips`, `planner_target_days` | Different subjects, limits, and planned days off per student. |
| Marks scale & conversion (3) | `marks_scale`, `marks_subject_scales`, `marks_percent_bands` | Tied to the student's school preset and subjects. |
| Excuse templates & signature (5) | `your_signature`, `late_income_excuses`, `left_soon_excuses`, `short_absence_excuses`, `long_absence_excuses` | Different student name/signature and wording per account. |
| Automation rules & per-account refresh (13) | `excuse_mode`, `default_excuse_selection`, `excuse_delay_days`, `excuse_day_per_lesson`, `ignored_excuses`, `strava_order_mode`, `strava_auto_cancel_lunches`, `lunch_order_cutoff_time`, `automation_paused`, `go_back_weeks`, `go_forward_weeks`, `sent_excuses_limit`, **`background_refresh` (NEW, `bool`, default `true`)** | Independent safety modes, pause state, deadlines, and individual background refresh opt-in/out (D4 #3). |
| Per-account AI lunch rules (4) | `gemini_auto_enabled`, `gemini_prompt`, `gemini_interval_days`, `gemini_last_run` | Each child has their own food tastes and AI schedule. |
| Wake-up alarm (3) | `wakeup_enabled`, `wakeup_minutes_before`, `wakeup_skip_dates` | Tied to the student's timetable; on Android only the `primary_id` account's values drive the phone (§8). |
| Setup wizard state (1) | `wizard_step` | Tracks unfinished setup per account (`-1` when complete). |

### 3.3 New canonical config key: `background_refresh` (PLAN §2 rule 4)

- Key name: `background_refresh`
- Type & default: `bool`, default `true`
- Validation (`config.dart` `validateConfig`): rejects non-boolean non-null values (`"'background_refresh' must be a boolean."`), mirroring `strava_auto_cancel_lunches`.
- Updated in the **same commit** in:
  1. `config.example.json`
  2. `packages/strakalari_core/lib/src/storage/config.dart` (`canonicalDefaults` + `validateConfig`)
  3. `packages/strakalari_core/test/config_test.dart`
  4. The two full canonical config snapshots in `roundTripFiles` of `packages/strakalari_core/test/parity/helpers.json` (only allowed parity fixture edit per PLAN §2 rule 4). No other parity fixture changes.

### 3.4 Merged runtime config, file resolution & backward compatibility

- **Legacy single-file `ConfigManager` calls** (all existing core unit/parity tests, `ConfigManager(path)` without `globalPath`, a process that never entered accounts mode): unchanged behavior — all 74 keys load from and save to `path`, zero parity regressions.
- **Multi-account `ConfigManager(accountConfigPath, globalPath: p.join(rootDir, 'global.json'), baseDir: accountDir, rootDir: rootDir)`:**
  - **Precedence (`load()`):** canonical defaults, then the per-account keys from `<accountDir>/config.json`, then the shared keys from `<rootDir>/global.json`. A shared key is **only** ever read from `global.json` (or its default), never from an account file, even if the account file holds a stale copy (the moved `default` holds all 19 at first, because it is a byte copy). Missing keys fall back to `canonicalDefaults`, preserving `defaultUpdateChannel()`.
  - `set(key, value)`: encrypts `bakalari_password` / `strava_password` with the account key (`dataDir: accountDir`) and `gemini_api_key` with the root key (`dataDir: rootDir`).
  - **`save()`** splits the edits:
    - Edits of keys in `globalConfigKeys` merge-save atomically into `<rootDir>/global.json` under `<rootDir>/global.json.lock`; the written file contains shared keys only.
    - Remaining edits merge-save atomically into `<accountDir>/config.json` under `<accountDir>/config.json.lock`; the written file contains per-account keys only (today's `_mergeOntoDisk` starts from `defaultConfig()`, `config.dart:681`: the account write filters the shared keys out of that map, the global write filters the per-account keys out).
    - The two writes run one after the other (`global.json` first), never nested. If one of them fails, that file's edits stay pending (still touched, baseline not reset) and the error is raised (fail loudly); the other write stands.
    - The `ConfigManager` of an account whose folder no longer exists (deleted, §9) refuses to save (`StateError`), so a late save can never recreate a deleted account.
  - Every core consumer (`Strakalari`, `runRefresh`, `validateConfig`, `error_report`, `school_presets`, `wakeup`, `status_notification`) receives the flat merged `Map<String, Object?>` — zero schema breakage.
- **Explicit account folder, never a silent root fallback:**
  - Core storage functions gain optional `String? dataDir` parameters (keeping today's signatures for single-account tests): `loadDataCache({String? dataDir})`, `saveDataCache(data, {bool replace = false, String? dataDir})`, `audit.historyPath({String? dataDir})`, `audit.record(..., {..., String? dataDir})`, `audit.recent({int limit = 50, String? dataDir})`, `audit.hasDryRun(kind, {String? dataDir})`, `Strakalari({..., String? dataDir, String? rootDir})` (resolves `configFile`, `blacklist`, `alreadyExcusedFile`, `logFile` against `dataDir`, and passes `dataDir` into cache/audit/decrypt with `fallbackKeyDir: rootDir`), `StravaClient(config, {String? dataDir})`; `runRefresh(app, config, ...)` reads `app.dataDir` for every cache read/write.
  - **Accounts mode** is a process-wide, one-way flag (`enterAccountsMode(rootDir)` in `accounts.dart`), set right after the registry is loaded or the move committed, in every isolate; it is never switched off (tests reset it through a `@visibleForTesting` hook). While it is on:
    - every per-account file function called with `dataDir == null` throws `StateError('per-account file used without an account folder')` instead of resolving against `getUserDataDir()`;
    - `ConfigManager()` / `ConfigManager(path)` whose resolved path is `<rootDir>/config.json` throws the same way (only the move in §4.2 reads the root `config.json`, with its own file read);
    - shared files keep using the root: `session.lock`, `update_cache.json`, `school_presets/`, `instance.token`, `console.log`.
  - **Every call site that resolves a per-account file today**, and what it gets:

    | Call site | Today | With accounts |
    |---|---|---|
    | `app/lib/controllers/app_state.dart:166` (`final ConfigManager config = ConfigManager()`) | root `config.json` | the active account's multi-account `ConfigManager` (field becomes replaceable on switch, §10.1) |
    | `app_state.dart:89`, `:384`, `:391`, `:794`; `app/lib/controllers/lunches.dart:352`, `:372` | `loadDataCache()` / `saveDataCache()` | `dataDir: activeAccountDir` |
    | `lunches.dart:531–540` (`_blacklistPath`, blacklist editor + `blacklistWords`) | `resolvePath` against root | `resolvePath(path, activeAccountDir)` |
    | `app/lib/features/settings/settings_live.dart:52–58` (*Vymazat mezipaměť*) | root `data_cache.json` | `<activeAccountDir>/data_cache.json` |
    | `packages/strakalari_core/lib/src/storage/config.dart:747` (`getBlacklistPath`), `:834` (`getAlreadyExcusedPath`) | root | the manager's `baseDir` |
    | `automation.dart:423`, `:436–438`; `strava/client.dart:154` | root | `dataDir` |
    | `audit.dart:44` (`historyPath()`) | root | `dataDir` |
    | `error_report.dart:228–240` (`redactWithSavedConfig`, used by `scheduler.dart:166`) | root `config.json` | secrets of **every** account + `global.json` (§7.2 step 3) |
    | `app/lib/platform/android/background.dart:133–146` (headless `run_in_background` gate) | root `config.json` | `global.json` once accounts exist (§4.1) |

  - Because every call carries its explicit `dataDir`, an async background refresh of Account B can **never** interleave with and corrupt Account A's UI reads/writes across `await` boundaries.
  - Test (also the proof that originals are never changed): on a moved layout, a full cycle for two accounts — refresh, manual and automatic send, order and cancel in dry run, blacklist edit, clear cache, settings save, error report — leaves every root file byte-identical (SHA-256 before/after), and calling a per-account function without a folder in accounts mode throws.

---

## 4. One-Time Move & Upgrading Existing Installs

### 4.1 Upgrade matrix (Flutter installs + Google Play Python app)

| Existing install | Root data dir (`getUserDataDir()`) | Existing data move | F4 behavior |
|---|---|---|---|
| **Windows classic** | `%LOCALAPPDATA%\Programs\Strakalari` (or `%LOCALAPPDATA%\Strakalari`) | None | F4 move (§4.2): flat root files → `accounts/default/`, carries keyring key, writes `global.json`, commits `accounts.json`. |
| **Windows Store (MSIX)** | `%LOCALAPPDATA%\Strakalari` | `_storeAppDataDir()` copies from the classic install | Runs **after** `getUserDataDir()`. Pre-F4 classic → MSIX → F4 move chains cleanly. **F4 classic → MSIX** is handled by the extended copy below. |
| **macOS** | `~/Library/Application Support/Strakalari` | `_macosAppDataDir()` copies out of `.app` bundle | Same as MSIX, with the extended copy below. *(Unverified natively on Windows 11.)* |
| **Linux** | `~/.config/strakalari` | None | F4 move: flat root files → `accounts/default/`, carries Secret Service key, commits `accounts.json`. |
| **Android Flutter (`.test` / GitHub APK)** | `getApplicationSupportDirectory()/data` | None | F4 move: flat root files + `secret.key.wrapped` (or `secret.key`) → `accounts/default/`, verifies the key, commits `accounts.json`. |
| **Android Google Play (Python / Flet)** | `getApplicationSupportDirectory()/data` (identical to Flet's `FLET_APP_STORAGE_DATA`) | None — identical file names, JSON schemas, and Android Keystore alias `strakalari-secret-key` | Identical to Android Flutter above. `ensureMultiAccountLayout(rootDir)` runs in **both** `prepareStartup()` (UI launch) **and** `_runHeadless()` (`app/lib/platform/android/background.dart`), so an overnight Play Store update whose first execution is `BootReceiver` / `MY_PACKAGE_REPLACED` / `RefreshReceiver` moves safely before the user ever opens the app. |
| **Fresh install** (no `accounts.json`, no account folder, no root `config.json`) | `<rootDir>` | None | Creates `accounts/default/`, empty `global.json`, and `accounts.json` (`active_id: 'default'`, `primary_id: 'default'`, no `migrated`). `needsSetup()` is `true` → normal first-run wizard launches. |

**Where the move runs (startup order):**

- **Desktop (`startup.dart` `prepareStartup`):** after `keyStoreBackend` is set and **after the single-instance guard** (`ensureSinglePrimary`, `startup.dart:80–92`), so a second launch exits before it could move data a running instance still writes; before the first `ConfigManager()` / `AppState()`. `--forget-secrets` runs before the move (it only forgets keys, §5.3).
- **Android UI (`prepareStartup`):** after `setMobileDataDir`, in place of today's single `warmAndroidKeystore(dataDir)` (`startup.dart:61`): the move warms the root key itself (§4.2 step 5), then `warmAndroidKeystoreAll` runs, all before the first `ConfigManager()` / `AppState()`.
- **Android headless (`_runHeadless`):** right after `_phoneDataDir()`, **before** the `run_in_background` gate; the gate then reads `run_in_background` from `global.json` (or from the root `config.json` only in degraded mode), never from the root backup once accounts exist (`background.dart:133–146` today reads the root `config.json`).

**Data moves after F4 (`_storeAppDataDir`, `_macosAppDataDir`, `helpers.dart:158–301`):** today they copy a fixed list of root files (`_bundleDataItemNames`, `helpers.dart:180–190`) and decide from `config.json` alone (`_needsBundleMigration`, `helpers.dart:210–214`; `legacyDesktopDataDir`, `packaging.dart:81–87`). Extended:

- `legacyDesktopDataDir()` returns the classic folder when it has a `config.json` **or** an `accounts.json`.
- `_needsBundleMigration(old, target)`: when `old` has an `accounts.json`, the move is needed while `target` has no `accounts.json` and no account folder; otherwise today's rule (`config.json`).
- When `old` has an `accounts.json`, the copy adds `global.json` and the whole `accounts/` tree (except `accounts/.migrating/`) to today's list, carries the root key **and** the key of every folder `old/accounts/<id>/` found on disk (`carryKey(old/accounts/<id>, target/accounts/<id>)`; desktop keys are bound to the folder path, `secret_store.dart:63–70`), and copies `accounts.json` **last** as its "move finished" marker (like `config.json` today). If any carry fails, it stops before `accounts.json` (retried next launch, like today).
- Tests: classic → Store and bundle → Application Support with two accounts, keyring and `STRAKALARI_NO_KEYRING`, plus a copy interrupted before `accounts.json`.

**Downgrade is not supported:** an older version installed over F4 runs on the pre-update root copy, and its changes are ignored after the next upgrade (the root files are only a backup once accounts exist). Release notes say so.

### 4.2 Exact one-time move protocol (`ensureMultiAccountLayout(rootDir)`)

**When it runs:** only when **all** hold: no `<rootDir>/accounts.json`; **no account folder** `<rootDir>/accounts/<valid id>/` with a `config.json`; and `<rootDir>/config.json` exists. If `accounts.json` is missing but account folders exist, the registry is rebuilt from the folders (§2.1) and the move never runs. Fresh installs take the fresh path (§4.1).

**Locks:** the move takes `<rootDir>/session.lock` first (waiting up to 2 minutes; a refresh, send or order in another isolate/process finishes first), then `InterProcessLock('<rootDir>/migrate.lock')` (timeout 30 s), and holds both from step 1 to step 9. If it can't get either lock, it doesn't move this launch (degraded mode, below).

1. **Re-check:** if `accounts.json` now exists or an account folder with a `config.json` appeared (another process/isolate just finished), release and return `true` (then load the registry).
2. **Parse source config:** read `<rootDir>/config.json` as UTF-8 JSON `Map`. If unreadable or corrupt, log a loud `Warning:` and return `false` without modifying or deleting anything.
3. **Build the file list** (relative paths under `<rootDir>` that currently exist as files):
   - Standard files: `config.json`, `config.json.bak`, `data_cache.json`, `already_excused_lessons.json`, `already_excused_lessons.unconfirmed.json`, `strava_blacklist.json`, `automation_history.jsonl`, `automation_history.jsonl.old`, `log.txt`, `log.txt.old`.
   - Custom relative paths from source `config.json` keys `strava_blacklist`, `already_excused_file`, `log_file` (normalized, skipping absolute paths or `..` escapes — same rule as `_bundleDataItems` in `helpers.dart:216`).
   - Root-shared items (`school_presets/`, `update_cache.json`, `instance.token`, `console.log`, `session.lock`, `migrate.lock`, `accounts/`) stay in `<rootDir>` and are **not** copied.
4. **Fresh staging copy:** delete a leftover `<rootDir>/accounts/.migrating/` (only ever an unfinished earlier attempt; it is never an account), create it empty, and copy every file of step 3 into `accounts/.migrating/<rel>` (temp file + rename per file). Nothing is skipped or reused from an earlier attempt.
5. **Carry the credential key** (the root key `K` = `getKey(rootDir)`, read once; on Android after `ensureWarmed(rootDir)`):
   - **Android:** copy `<rootDir>/secret.key.wrapped` (if present) and `<rootDir>/secret.key` (if present) into `accounts/.migrating/` with the other files. The same blob under the same Keystore alias unwraps to the same key, so no Keystore call is made on the staging folder.
   - **Desktop, key in a file** (`STRAKALARI_NO_KEYRING`, or the root key lives in `<rootDir>/secret.key`): copy that file into `accounts/.migrating/` (`_writeFile`, chmod 600).
   - **Desktop, key in the OS credential store:** store `K` under `entryName(<rootDir>/accounts/default)` — the **final** path, because the entry is bound to it — with the same store calls `carryKey` uses (`secret_store.dart:299–325`), but never writing a file into the not-yet-existing final folder. The root entry `entryName(rootDir)` stays untouched. If the store refuses, abort (step 7).
6. **Verify everything before committing** (no decrypt fallback in this step; never `getKey` on the not-yet-existing final folder, which could create a key):
   - Every file of step 3 exists in `accounts/.migrating/` with **exactly the same byte length and SHA-256 digest** as `<rootDir>/<rel>` (this covers the copied `secret.key.wrapped` / `secret.key`).
   - `accounts/.migrating/config.json` decodes cleanly as a JSON `Map`.
   - **The carried key is `K`:** desktop store — the entry `entryName(<rootDir>/accounts/default)` read back directly equals `K` byte for byte; desktop file — the staged `secret.key` equals `K`; Android — the staged blob equals the root blob (step above) and `K` came from a clean unwrap (if the root warm-up had to quarantine or create a key, that counts as a failure).
   - With `K` **alone** (a Fernet built from `K`, `fallbackKeyDir` unused): if `bakalari_password_encrypted == true` (non-empty `bakalari_password`) or `strava_password_encrypted == true` (non-empty `strava_password`), the password decrypts.
   - If `gemini_api_key_encrypted == true` (non-empty `gemini_api_key`), `decryptStrict(..., dataDir: rootDir)` returns non-null.
7. **On ANY failure:**
   - Print a loud `Warning:` naming the exact failed step/file, and set `migrationFailed` for the UI hint below.
   - Do **NOT** write `accounts.json` and do **NOT** rename the staging folder (the next attempt deletes it).
   - Do **NOT** delete or alter any original file in `<rootDir>`.
   - Return `false`: the process runs in **degraded mode** (below); the move retries on the next launch.
8. **Write `global.json`:** extract every key of `globalConfigKeys` present in the source `config.json` and write `<rootDir>/global.json` atomically **every attempt** (overwriting one left by an earlier attempt, because the root `config.json` may have changed since); verify it parses back as a JSON `Map`.
9. **Commit:**
   - Rename `accounts/.migrating/` to `accounts/default/` (if a stray empty `accounts/default/` without `config.json` exists from a fresh-path crash, remove it first).
   - Write `<rootDir>/accounts.json` atomically as the **final step**: `version: 1`, `active_id: 'default'`, `primary_id: 'default'`, `accounts: [{id: 'default', label: <derived>, created_at: <nowIso>, migrated: true}]`.
   - Call `enterAccountsMode(rootDir)` and release `migrate.lock`, then `session.lock`.
   - A crash after the rename but before `accounts.json` is the "folders exist, registry missing" case of §2.1 (rebuilt, data already verified).
10. **Never delete originals:** `<rootDir>/config.json`, `data_cache.json`, `already_excused_lessons.json`, `secret.key*`, and the root OS keyring entry remain untouched on disk as a permanent non-destructive backup. Once accounts exist, F4 reads/writes only `global.json`, `accounts.json`, and `accounts/<id>/*` (enforced by accounts mode, §3.4).

**Degraded mode** (the move returned `false` in this process):

- The process works exactly like today on the root files, single account.
- No account UI: no switcher, no Settings → Účty account card, no `+ Přidat účet`, no `'accounts'` tour. It never writes `accounts.json`, `global.json` or anything under `accounts/`.
- Right before every refresh, send and order, **under `session.lock`**, it checks whether `accounts.json` (or an account folder) now exists. If it does (another isolate/process finished the move), it does **not** run: it logs and shows `account_migrated_elsewhere` (restart the app), and the next start uses the accounts.
- The UI shows a one-time snackbar and a muted line in Settings → Diagnostika (`account_migration_failed`): *"Přechod na více účtů se nepodařilo dokončit. Aplikace funguje dál jako dřív a zkusí to znovu při příštím spuštění."* / *"The switch to multiple accounts could not be finished. The app keeps working as before and tries again on the next start."*

---

## 5. Credential Key Names & Fallback to Today's Names

### 5.1 Key naming & isolation

| Scope | Desktop OS Credential Store (`service = "Strakalari"`) | Desktop fallback (`STRAKALARI_NO_KEYRING=1`) | Android (`strakalari-secret-key` AES-256-GCM wrap) |
|---|---|---|---|
| **Root / shared (`global.json` — `gemini_api_key`)** | **Today's exact entry name:** `entryName(rootDir)` = `fernet-key:<sha256(normcase(abspath(rootDir)))[:16]>` | `<rootDir>/secret.key` | `<rootDir>/secret.key.wrapped` (plain `<rootDir>/secret.key` if Keystore unavailable) |
| **Per-account (`accounts/<id>/config.json` — `bakalari_password`, `strava_password`)** | `entryName(accountDir)` = `fernet-key:<sha256(normcase(abspath(accountDir)))[:16]>` | `<accountDir>/secret.key` | `<accountDir>/secret.key.wrapped` (plain `<accountDir>/secret.key` if Keystore unavailable) |

- Every newly added account gets its **own freshly generated 32-byte Fernet key** under its own `entryName(accountDir)` / `<accountDir>/secret.key.wrapped`.
- Migrated `'default'` receives a copy of the root key via `carryKey(rootDir, defaultAccountDir)` (desktop) or the copied `secret.key.wrapped` (Android), keeping the root key intact.

### 5.2 Fallback to today's key name

`encrypt` / `decrypt` / `decryptStrict` in `packages/strakalari_core/lib/src/storage/helpers.dart` gain optional `{String? dataDir, String? fallbackKeyDir}` parameters (defaulting to `null` → `getUserDataDir()` in single-account processes, preserving existing signatures and tests):

1. **Encryption (`encrypt`):**
   - Per-account passwords (`bakalari_password`, `strava_password`) always encrypt with `getKey(accountDir)`.
   - Shared `gemini_api_key` always encrypts with `getKey(rootDir)`.
2. **Decryption (`decrypt` / `decryptStrict`):**
   - First try Fernet with `getKey(dataDir ?? getUserDataDir())`.
   - **Fallback to today's name:** if that fails (`InvalidTokenException` / `FormatException`) and `fallbackKeyDir != null` (`!p.equals(dataDir, fallbackKeyDir)`), try Fernet with `getKey(fallbackKeyDir)` — i.e., today's root entry `entryName(rootDir)` / `<rootDir>/secret.key.wrapped`.
   - Finally, fall back to the legacy XOR cipher (unchanged).
   - Thus, even if an upgraded account's keyring entry was ever missing or a user manually copied an old `config.json` into `accounts/default/`, stored passwords still decrypt via today's root key name. The move's verification (§4.2 step 6) deliberately runs **without** this fallback, so a key that wasn't carried is caught there.

### 5.3 Android `WarmedAndroidKeystore` multi-key upgrade (`app/lib/platform/android/android_keystore.dart`)

- Currently `WarmedAndroidKeystore` stores **only a single** `(key, blob)` pair: `wrap` throws `KeyStoreUnavailable` and `unwrap` throws `FormatException` for anything else (`android_keystore.dart:61–91`), and core then quarantines that folder's `secret.key.wrapped` and makes a new key (`secret_store.dart:102–111`) — the account's saved passwords would be lost.
- **Fix:** upgrade `WarmedAndroidKeystore` to hold a map of warmed `(Uint8List key, Uint8List? blob)` pairs (still refusing any un-warmed key/blob so fail-safe semantics are unchanged).
- Add `warmAndroidKeystoreAll(String rootDir, Iterable<String> accountIds)` called at **both** UI startup (`prepareStartup`) and headless wake (`_runHeadless`), warming `rootDir` plus every `<rootDir>/accounts/<id>/` directory.
- Add an idempotent `ensureWarmed(String accountDir)` (a no-op once the folder's pair is in the map) and **await it right before every** `createApp`, `getKey`, `decrypt` or `ConfigManager` for an account, in both isolates: the refresh loop (§7.2, per account), `switchAccount`, `beginAddAccount` (before the wizard saves its first password), and the status inputs for `primary_id` (§8). So an account added in the other isolate after this isolate started is warmed before its first use.
- When deleting an account, `forgetKey(accountDir)` zeroes and deletes `<accountDir>/secret.key.wrapped` / `<accountDir>/secret.key`, evicts it from `_cache`, and drops its pair from `WarmedAndroidKeystore`.
- Desktop `--forget-secrets` (`startup.dart:77–78`) calls `forgetAllKeys(rootDir)`, forgetting the root key **and** the key of every folder it finds on disk under `<rootDir>/accounts/` (registry or not, so a lost `accounts.json` leaves no orphaned credential store entries).
- **Uninstaller (`installer.iss:200–239`):** *Remove all user data* also deletes `accounts.json` and `global.json` and runs `DelTree(AppDir + '\accounts', True, True, True)` (the folder is owned by the app); `*.lock` already covers the new lock files. The fallback data dir (`{localappdata}\Strakalari`) is already deleted as a whole.
- **Zero Java Keystore changes required:** `StrakalariChannel.java`'s `keystoreWrap` / `keystoreUnwrap` already wrap/unwrap arbitrary byte arrays under `strakalari-secret-key`.

---

## 6. `session.lock` & Concurrency Safety

- **One global lock:** `<rootDir>/session.lock` (`SessionLock.acquire` continues to resolve `./session.lock` against `getUserDataDir()` = `<rootDir>`).
  - Guarantees **at most one refresh, excuse submit, lunch order, account deletion, add-account cancel or data move across ALL accounts and ALL processes/isolates at any moment**.
  - Remains identical to the Python app and pre-F4 Flutter builds, so a legacy and F4 process still exclude each other.
- **Per-account & metadata locks:**
  - `<accountDir>/already_excused_lessons.json.lock` (`HistoryLock`, already derived from `alreadyExcusedFile`): isolates each account's excuse check-send-write sequence.
  - `<accountDir>/config.json.lock`: guards per-account config saves.
  - `<rootDir>/global.json.lock`: guards shared settings saves.
  - `<rootDir>/accounts.json.lock`: guards registry updates (add, switch, rename, set primary, delete).
  - `<rootDir>/migrate.lock`: guards the data moves and the registry load/rebuild.
- **Lock ordering (deadlock-free):** `session.lock` is always outermost. Allowed nestings: `HistoryLock` inside `session.lock` (as today), `migrate.lock` inside `session.lock` (the F4 move, §4.2), `accounts.json.lock` inside `session.lock` (delete, cancel), `accounts.json.lock` inside `migrate.lock` (registry rebuild, §2.1). Leaf locks (`HistoryLock`, `config.json.lock`, `global.json.lock`, `accounts.json.lock`) are never nested inside each other. The existing bundle/Store move takes `migrate.lock` alone, without `session.lock`, so no cycle arises.
- **UI switching safety:**
  - **Busy:** switching, adding or deleting an account is rejected with a clear snackbar (`account_switch_busy` / `account_delete_busy`) while any of these runs: `refreshRunning`, `sendingExcuses.isNotEmpty`, `orderRunning`, `testing.isNotEmpty`, `aiRunning`, `earlyRefreshInFlight` (F1c), or a background refresh of any account in this isolate (`backgroundAccountRunning`).
  - **Account token:** every account-bound async operation (refresh, send, order, connection test, AI recommendation, marks prediction, any future one) captures `activeAccountId` when it starts; when it finishes and the active account has changed, it drops its UI result (staging, drafts, snackbars) with one log line instead of applying it to the other child. Its disk writes went to its own account folder anyway.
  - **Reload after background work:** when a background refresh of the account that is now on screen finishes, `reloadCache()` runs for it.
  - Background refreshes of non-active accounts **never mutate** the active account's UI state (`data`, `orders`, `pendingOrders`, `plannedSkips`, `status`); they write strictly to their own `<accountDir>` and record their summary in `runsByAccount[accId]` / `logLinesByAccount[accId]`.

---

## 7. Background Refresh Across Accounts

### 7.1 Per-account control + device master switch

- **Per-account switch (`background_refresh`, default `true`):** stored in `<accountDir>/config.json`. Toggleable per account in **Settings → Účty** (on every account row, without needing to switch accounts first) and in **Settings → Pravidla** (for the active account).
- **Android device master switch (`run_in_background`, default `true`):** stored in `<rootDir>/global.json`.
  - When `run_in_background` is `false` on Android: `KeepAliveService` stops, `RefreshReceiver` wake is cancelled, and headless wakes exit immediately (unchanged contract; the headless gate reads `global.json`, §4.1).
  - When `run_in_background` is `true` on Android (and on desktop whenever the app/tray runs): the scheduler ticks every `check_interval_minutes` (`global.json`).

### 7.2 Sequential execution through `runRefresh`

Both the live scheduler (`AppState.scheduledRefreshJob` in `app/lib/controllers/activity.dart`) and the Android headless wake (`runHeadlessTick` in `app/lib/platform/android/background.dart`, which calls the same `registerJobs` → `scheduledRefreshJob`) run the **exact same sequential loop**:

1. Load the current `AccountRegistry` from `<rootDir>/accounts.json`.
2. Build the ordered account list: `primary_id` first, then `active_id` (if different), then remaining accounts in registry order.
3. **Due accounts only:** an account is due when its last successful refresh (`last_updated` in its own `data_cache.json`, as `startupSeed` reads it, `cache.dart:215`) is unknown or at least `check_interval_minutes − 5` minutes old. So after a pass where A succeeded and B failed, the runner's 5-minute retry (`scheduler.dart:179–184`) refreshes only B; A waits for its interval.
4. For each due account `acc` **one at a time** (never in parallel), within the **pass budget**:
   - If `stopped?.call() ?? false`, stop immediately.
   - **Budget:** start no new account later than 20 minutes after the pass started, and cap each account's wait (`maxWait`, today 30 minutes for one refresh, `activity.dart:257`) at the time left until 28 minutes after the pass started, so the whole pass stays inside the wake lock (30 minutes, `background.dart:211`) and the headless engine's hold (32 minutes, `RefreshReceiver.java:52`). Accounts left out stay due; the job then ends with `JobFailed('accounts left for the next run')`, which the runner retries in ~5 minutes without a notification (`JobResult.reported`).
   - `await ensureWarmed(accDir)` (Android, §5.3), then load `acc`'s merged config (`global.json` + `<accDir>/config.json`).
   - Skip `acc` if:
     - `acc` has the `adding` flag, or its setup is pending (`wizard_step >= 0` or `!hasValidCredentials(accCfg).$1 && !hasValidCredentials(accCfg).$2`), OR
     - `accCfg['background_refresh'] == false`.
   - If `acc.id == activeAccountId`: run the active account's standard `startRefresh('all')` (which acquires `<rootDir>/session.lock`, runs `runRefresh(app, runConfig, scope: 'all', ...)`, and hands the result to the shared handler below with the screen updates on).
   - If `acc.id != activeAccountId`: run `_refreshBackgroundAccount(acc)` inside `withSessionLockAsync`, with `backgroundAccountRunning` set (§6):
     - Constructs `createApp(dataDir: accDir, rootDir: rootDir, configData: accCfg, onLog: ...)` and calls **`runRefresh(app, accCfg, scope: 'all', cancelledLunchDays: ..., keptLunchDays: const {}, ...)`** — **the exact same `runRefresh` pipeline**.
     - `cancelledLunchDays` comes from the same function the `AppState` constructor uses (`app_state.dart:108–127`, extracted as `cancelledLunchDaysFor(config, cache)` and called by both), never from a second copy.
     - Hands the result to the shared handler below with the screen updates off.
   - **One result handler for every account (`handleRefreshResult`):** the part of today's `_refreshLocked` after `runRefresh` (`activity.dart:442–537`) moves into one function that takes an account context — its id, label, merged config and `ConfigManager`, its folder, its run list and log lines (`runs` / `logLines` for the active account, `runsByAccount[id]` / `logLinesByAccount[id]` for the others), and a flag for the screen updates. It does, for every account: stamp `gemini_last_run` (in that account's config) if `result.usedGemini`; send `result.news` as notifications (`new_mark`, `new_quarterly_mark`, `new_absence`, `timetable_change`); send the F3 `lunch_skipped` notice; build the run summary; the combined fetch + automation failure notification; the low-balance case (`warnLowBalance`, once a day through that account's `strava_low_balance_notified`, and the run counts as done, so no 5-minute retry); `automation_failed` with `reportError`; `refresh_done`; `refresh_failed`; and the run record (`finishRun`, capped at 20 runs / 300 log lines per account). Only with the screen updates on does it also touch `pendingOrders` and call `reloadCache()`.
   - On an error that the handler reports as failed (not cancelled, not low balance), mark `anyFailed = true` and **continue to the next account** so one broken account never starves another child's refresh or automation.
5. **Notification tagging & O8 tap routing:**
   - Add `notifyForAccount(String event, String message, {Map<String, Object?>? prefs, String? accountId, String? accountLabel})` in `packages/strakalari_core/lib/src/platform/notifier.dart` (leaving existing `notify(event, message, [prefs])` signature and all parity tests untouched); `NotifierBackend.sendNotification` gains an optional `route`.
   - When `accounts.length > 1` and `accountLabel` is non-empty: prefix the notification body with `"[<accountLabel>] "` (e.g., `"[Klára] Nová známka: Matematika (1)"`). When `accounts.length == 1`: no prefix.
   - **Every per-account event carries its account**, the active account's own events included: `AndroidNotifications` (`app/lib/platform/android/android_notifications.dart`) encodes the route as `'$baseRoute?account=$accountId'` whenever accounts exist. Only the app-wide `update_available` has no `?account=`. `Notifications.java` (`requestCodeForRoute` default branch `1000 + (route.hashCode() & 0x7fff)`) and `StrakalariChannel.java` (`handleIntent` forwarding `EXTRA_ROUTE`; event ids rotate, so two accounts' notifications never replace each other) already support arbitrary route strings with **zero Java changes**.
   - `AppState.applyLaunchRoute(rawRoute)` parses optional `?account=<id>` (`routeForLocation` already drops the query, `router.dart:68–77`; the `alarm` check compares the part before `?`):
     - `<id>` exists, differs from `activeAccountId`, `!setupPending`, not busy (§6): switch to `<id>`, then open the target screen.
     - `<id>` exists and differs, but busy: **don't** open the target screen on the current account. Show `account_tap_busy` (*"Toto oznámení patří účtu {name}. Přepnu na něj, až doběhne obnova."* / *"This notification belongs to {name}. I'll switch to it when the refresh is done."*), remember `(id, route)`, and apply it as soon as nothing runs (a later tap replaces it).
     - `<id>` no longer exists (deleted account): stay on the current account and open nothing.
6. **Retry & startup seed:**
   - If any due, enabled account failed (non-cancelled, not low balance), `scheduledRefreshJob` throws `JobFailed` so `PeriodicRunner` retries in ~5 minutes; thanks to step 3 the retry refreshes only the accounts that are still due.
   - `schedulerStartupSeed` anchors to the **oldest** `last_updated` among configured accounts with `background_refresh == true` (falling back to the active account if none), so a stale or newly added account does not wait an extra interval; step 3 skips the ones that aren't due.
7. **Redaction:** `redactWithSavedConfig` (`error_report.dart:228–240`, used before scheduler tracebacks reach the log, `scheduler.dart:166`) and `writeLog`'s scrub use the secrets of **every** account (each account config, decrypted with its own key) plus `global.json`, so another child's password echoed by an exception never reaches a log or an error report. Diagnostics for a background account are built from that account's config.
8. **Manual refresh:**
   - TopBar / Activity **Obnovit data** refreshes the **active account** only.
   - Desktop tray **Obnovit data** refreshes all configured `background_refresh`-enabled accounts sequentially, due or not (or the active account if none are enabled). Desktop tray **Pause / Resume** toggles `automation_paused` on the active account (and appends the active account's label to the tray menu item when `accounts.length > 1` so it is explicit and never silently unpauses another child's account).

---

## 8. Which Account the Notification, Widget, and Wake-Up Alarm Show

Android has **one** ongoing status notification (`KeepAliveService` / `StatusNotifier`), **one** home-screen timetable widget (`TimetableWidgetProvider`), and **one** wake-up alarm queue (`AlarmReceiver`).

- **Owner:** the designated **primary account** (`primary_id` in `accounts.json`).
  - Defaults to `'default'` (the existing/first account).
  - Never changes automatically when adding a second account or switching tabs to inspect another child — so looking at Child B's grades never clobbers Child A's home-screen widget or tomorrow's 6:45 wake-up alarm.
  - Changeable with one tap in **Settings → Účty** (*Nastavit jako hlavní* / *Set as primary*) whenever `accounts.length > 1`. Changing `primary_id` immediately re-runs `syncAndroidState()` and `phone.notifier.poke()` without restart.
- **Data source (`AppState.backgroundStatusInputs()` & `AppState.syncAndroidState()` + headless `_postStatus`):**
  - The derivations behind them (`excuseTasks`, `phoneTimetable`, `food`, `stableBaseline`, `stableComplete`, `lunchFreeDays`, `webOrders`, `last_updated`; `app_state.dart:700–788`) are extracted into functions that take an account's merged config and cache, and **both** `AppState` and the primary-account path call them — one implementation, no second copy.
  - When `primary_id == activeAccountId`: called with `AppState`'s in-memory config/cache (identical to today).
  - When `primary_id != activeAccountId`: `await ensureWarmed(primaryDir)`, then called with `primary_id`'s merged config and `<primaryDir>/data_cache.json`, so the status notification, widget, and wake-up alarm queue always reflect `primary_id`.
  - Test: the status inputs for a non-active primary equal those of an `AppState` built for that account.
- **Status notification label when `accounts.length > 1`:**
  - `StatusContent.sub` (currently e.g. `"Aktualizováno 18:56"`) prepends the primary account label: `"Klára · Aktualizováno 18:56"` (or `"Klára"` if `sub` was empty), so the user always sees which child is summarized in the shade. When `accounts.length == 1`, `sub` is unchanged.
- **Tapping the status notification (`today`), home-screen widget (`timetable`), or alarm (`alarm`):**
  - These carry no `?account=` query parameter (event notifications always do, §7.2 step 5). In `applyLaunchRoute`, when `accounts.length > 1` and `activeAccountId != primary_id` (and `!setupPending`), a tap without `?account=` switches to `primary_id` before navigating, so the opened screen matches what the user tapped; when busy, it behaves like a busy `?account=` tap (§7.2 step 5).
- **Settings → Budík on a non-primary account (Android, `accounts.length > 1 && activeAccountId != primary_id`):**
  - The editable `WakeupCard` is **not** shown (its values would never ring). Instead: the info banner `alarm_primary_account_note` — *"Budík telefonu, widget a stavové oznámení používají hlavní účet ({name}). Hlavní účet změníte v Nastavení → Účty."* / *"The phone alarm, widget and status notification use the primary account ({name}). Change the primary account in Settings → Accounts."* — and a *Nastavit jako hlavní* / *Set as primary* button (`account_set_primary`, `Key('alarm:set_primary')`) that makes this account primary and then shows its card.
  - Desktop has no phone alarm queue; Budík is unchanged there.

---

## 9. Account Deletion (Scope & Confirmation)

- **Guard:** the last remaining account (`accounts.length <= 1`) **cannot** be deleted (delete button hidden; users can edit credentials or clear cache instead). Deletion is also blocked with snackbar `account_delete_busy` while anything in the §6 busy list runs.
- **Confirmation dialog (`AlertDialog`, `Key('acc:delete_dialog')`):**
  - Title: `Strings.format('account_delete_title', {'name': label})` (*Odstranit účet „{name}“?* / *Delete account "{name}"?*).
  - Explicit plain-language body (`account_delete_body`) stating:
    - **Deleted on this device:** saved Bakaláři and Strava logins and this account's encryption key; its settings, school calendar overrides, limits, planned days, excuse templates, and lunch blacklist; its cached timetable, marks, absences, lunches, excuse history, and activity log.
    - **Kept untouched:** nothing changes on Bakaláři or Strava.cz websites; other accounts, shared app settings (theme, language, Gemini API key), and user-added school presets stay intact.
  - **Extra line when something stays behind** (`account_delete_backup_note`), shown when the account has `migrated: true`, or its `log_file` / `already_excused_file` / `strava_blacklist` is an absolute path outside its folder: *"Kopie dat z doby před aktualizací zůstává ve složce aplikace, dokud aplikaci neodinstalujete."* / *"A copy of the data from before the update stays in the app folder until you uninstall the app."* The root backup files are never deleted by the app (PLAN: never delete the originals), and the root key stays because it also encrypts the shared Gemini key.
  - Actions: **Zrušit / Cancel** (default) and destructive **Odstranit účet / Delete account** (`Key('acc:delete_confirm')`).
- **Crash-safe deletion sequence (`AccountManager.deleteAccount(targetId)`):**
  1. **Switch away first:** if `targetId` is the active account, switch to `nextActiveId` (first remaining account) with the normal `switchAccount` (§10.1), which unfocuses fields and lets pending saves (B2 fields save on blur/dispose) finish against the target's own folder. Only then continue.
  2. Acquire `<rootDir>/session.lock` (non-blocking; abort with `account_delete_busy` if held by another process/isolate).
  3. Under `<rootDir>/accounts.json.lock`:
     - Verify `accounts.length > 1` and `targetId` exists.
     - Compute `nextPrimaryId` (equals the active account if `targetId == primary_id`, else unchanged).
     - Write updated `accounts.json` atomically **first** (so a mid-delete crash never leaves a dangling half-deleted entry; a leftover folder without a registry entry is ignored and removed by the next delete or cancel of that id).
  4. Call `forgetKey(targetDir)` (deletes `entryName(targetDir)` from OS credential store, zeroes & deletes `<targetDir>/secret.key` and `<targetDir>/secret.key.wrapped`, clears in-memory key cache and `WarmedAndroidKeystore` entry).
  5. Mark the target's `ConfigManager` (if any instance is still alive) and cache writes as deleted, so they refuse to create a missing account folder (§3.4).
  6. Assert `p.isWithin(accountsRoot, targetDir)` and recursively delete `<rootDir>/accounts/<targetId>/` **only**. Never touch any file outside `targetDir` (e.g., an absolute `log_file` path), never touch `global.json`, `school_presets/`, `update_cache.json`, or untouched pre-F4 root backup files.
  7. Release `<rootDir>/session.lock`.
  8. Drop `runsByAccount[targetId]` / `logLinesByAccount[targetId]`. If `targetId` was primary, immediately call `syncAndroidState()` and notify `PhoneBackground` so the widget, status notification, and wake-up alarms switch to `nextPrimaryId`. Show `account_deleted` snackbar.
- Test: deleting the active account while one of its Settings fields is focused leaves its folder gone (no late save recreates it).

---

## 10. UI, Add-Account Wizard Flow, Tutorials & Strings

### 10.1 Account Switcher (`scaffold.dart`, `more.dart`)

- **Single-account (`accounts.length <= 1`) and degraded mode:** no switcher pill in TopBar or `MorePage` (zero layout change for existing single-account users).
- **Multi-account (`accounts.length > 1`):**
  - Compact pill in TopBar (`Key('account_switcher')`, wrapped in `TutorialAnchor(anchorKey: 'account_switcher')`) on **both** narrow (390 px, `ConstrainedBox(maxWidth: 120)`, ellipsis) and wide (1280 px, `maxWidth: 200`): person icon + active account label + dropdown arrow. Always visible on every screen so a parent never excuses or orders for the wrong child.
  - Full-width active-account card at top of `MorePage` on narrow phones (`Key('more:account_card')`) opening the same switcher sheet.
- **Switcher sheet/dialog (`AccountSwitcherSheet`, `Key('account_switcher_sheet')`):**
  - Bottom sheet on narrow, dialog on wide.
  - Lists every account (initial badge, label, username + school preset subtitle, `"Hlavní"` / `"Primary"` chip on `primary_id`, `"Pozadí vypnuto"` / `"Background off"` muted tag if `background_refresh == false`, checkmark on active).
  - Tapping a non-active account switches immediately (`AppState.switchAccount(id)`, refused while busy, §6).
  - Footer actions: **`+ Přidat účet`** (`Key('switcher:add_account')`) and **`Spravovat účty`** (navigates to Settings → Účty).
- **What a switch does (`AppState.switchAccount(id)`):** `await ensureWarmed(accDir)`, update `accounts.json` `active_id`, then rebuild the account state **from an allow-list**: the fields that survive a switch are `runsByAccount`, `logLinesByAccount` (whose entry for `id` becomes `runs` / `logLines`), the update info (`updateInfo`, `updateCheckRunning`), tutorial state, theme/language tokens, `narrow` / `navSide` and navigation. **Every other field** is reset to exactly what a cold start for that account builds: the constructor's logic (`app_state.dart:75–164`, factored into one `_loadAccount()` used by the constructor and the switch) loads its `ConfigManager` + `data_cache.json`, rebuilds `orders`/`webOrders`/`plannedSkips`/`cancelledLunches`/`ignoredExcuseKeys`, and clears drafts, selections, caches and errors. Then emit. Test: a switched `AppState` equals a freshly built `AppState` for the same account, field by field (except the allow-list).

### 10.2 Settings → Účty & scope captions (`settings_view.dart`, `settings_controller.dart`)

- Top card of **Settings → Účty**: **"Účty v aplikaci" / "App accounts"** (`Key('settings:accounts_card')`), hidden in degraded mode:
  - Shows all accounts (`Key('acc:item:<id>')`) with active indicator, primary badge (when >1), Bakaláři username + school subtitle, per-account **Rename** (`Key('acc:rename:<id>')`), **Set as primary** (`Key('acc:set_primary:<id>')`, when >1 and not primary), per-account **Background refresh** toggle (`Key('acc:bg_refresh:<id>')`), and **Delete** (`Key('acc:delete:<id>')`, when >1, opening the confirmation dialog in §9).
  - **`+ Přidat účet` / `+ Add account`** button (`Key('acc:add_btn')`).
- Below it: active account's Bakaláři & Strava credential cards (headed by `"Přihlašovací údaje — <label>"` when >1 account). Changing the login there runs the same duplicate check as the wizard (§10.3).
- **Settings → Pravidla:** adds `SwitchListTile(key: Key('rule:background_refresh'))` for the active account's `background_refresh` (with hint explaining it controls scheduled background refreshes for this account).
- **Scope captions (only when `accounts.length > 1`, one short muted line each, nothing more — owner's D1 simplicity rule):**
  - Per-account sections (`accounts`, `limits`, `calendar`, `alarm`, `templates`, `rules`, `ai` per-account card): `"Nastavení účtu: {name}"` / `"Account settings: {name}"`.
  - Shared sections (`appearance`, `notifications`, `browser`, `diagnostics`, `ai` API key card): `"Společné pro všechny účty"` / `"Shared across all accounts"`.
  - Settings → Diagnostika → *Vymazat mezipaměť* clears only the active account's `<activeAccountDir>/data_cache.json` (§3.4 table).

### 10.3 Add-Account Wizard Flow (`wizard_controller.dart`, `wizard_live.dart`, `wizard_view.dart`)

Reuses the existing F1/F1c wizard without duplicating any login/preset/template UI. Creating a new account **does** open the wizard again, with only the steps that apply (owner's question, STATUS 2026-11-20):

1. `AppState.beginAddAccount()` (refused while busy, §6) creates a provisional `<rootDir>/accounts/<newId>/` directory with a `config.json` holding `wizard_step = stepSchool` (or `stepWelcome` when `disclaimer_accepted` is `false` in `global.json`), runs `await ensureWarmed(newAccountDir)` on Android, inserts `{id: <newId>, label: '', created_at: <now>, adding: true}` into `accounts.json`, stores `addingAccountReturnId = previousActiveId` (in memory), switches active account to `<newId>`, and navigates to `/wizard`.
2. **Add-account mode is exactly "the active account has `adding: true`"** (`addingAccount` reads only that flag, never `setupPending`). An existing account whose setup is pending for another reason (for example its login was cleared in Settings, which makes `needsSetup()` true, `app_state.dart:890–893`) gets the **normal** wizard with all its steps and **no** *Zrušit*; its folder is never deleted by the wizard.
3. In add-account mode:
   - `shownSteps()` shows only the applicable per-account steps: **Škola (`stepSchool`) → Bakaláři (`stepBakalari`) → Strava (`stepStrava`) → Omluvenky (`stepExcuses`) → Hotovo (`stepDone`)** — skipping `stepWelcome` (when `disclaimer_accepted` is already `true` in `global.json`) **and** skipping `stepPhone` on Android (notification permission was already handled on first setup, and the phone's wake-up alarm belongs to `primary_id`, not a newly added secondary account).
   - The only ways out are **Finish** and **Zrušit / Cancel** (`Key('wiz:cancel_add')`, on the first shown step and in the header, also when resumed after an app restart). There is no dismiss/skip that would leave an empty account behind.
   - `cancelAddAccount()` acts only on an account with `adding: true`: it takes `<rootDir>/session.lock` (waiting for the F1c early refresh of that account to finish, `activity.dart:336–342`), then, under `accounts.json.lock`, removes `<newId>` from `accounts.json`, `forgetKey(newAccountDir)`, deletes the provisional folder (contained-path assert as in §9), and switches back to `addingAccountReturnId` (or the first remaining account).
   - **Duplicate logins are refused:** on *Pokračovat* of the Bakaláři step, if another account already uses the same Bakaláři address + username (username compared case-insensitively, address without scheme case, trailing slash and whitespace), the step shows `account_duplicate_login` (*"Tento účet už v aplikaci je: {name}."* / *"This login is already in the app: {name}."*) and doesn't continue; the same check runs on the Strava step for canteen + username, and in Settings → Účty when a login is changed (§10.2). F2's outbox read keeps excuses from being sent twice anyway, but two accounts on one Strava login could re-order a lunch the other one cancelled.
   - Never overwrites `global.json` (`theme`, `language`, `tutorials_done`, `disclaimer_accepted`, `run_in_background`, `gemini_api_key`).
   - On Finish: derives the new account's `label` from `your_signature` → `bakalari_username` → `"Účet N"` (made unique, §2.1), removes `adding` in the **same** registry write as the label, leaves `primary_id` unchanged, offers the `'accounts'` tutorial tour, and starts the new account's first refresh (`finishWizardRefresh()`).
4. Tests: an existing account with cleared credentials opens the normal wizard without *Zrušit* and is never deleted; *Zrušit* deletes only an `adding` account's folder, with `session.lock` held; a duplicate Bakaláři and a duplicate Strava login are refused; Finish clears `adding`.

### 10.4 Interactive Tutorials (PLAN §2 rule 7 / CONTRIBUTING §5)

- **New tour `'accounts'`** in `app/lib/tutorial/tours.dart` (`route: null`, offered automatically by `AppScaffold` / `wizardFinished` once `accounts.length > 1` and `'accounts'` is not in `tutorials_done`):
  - Step 1 (`acc_switch`, `anchor: 'account_switcher'`, `place: TourPlace.topLeft`, `icon: Icons.switch_account_outlined`): explains switching accounts from the top bar, that each account keeps its own data and automation rules, and that primary account + per-account background refresh are configured in Settings → Accounts.
- **Updated `'settings'` tour:** append one short sentence to `tut_settings_intro_body` (cs & en) mentioning that you can add and manage multiple accounts under *Účty* / *Accounts*.
- Update `tools/demo_data.py` `TOURS_DONE` to include `"accounts"` alongside the other non-default tours.

### 10.5 Localization (`app_cs.arb`, `app_en.arb`, `strings.dart` — cs & en)

All new UI strings (33 keys: `accounts_manage_title`, `account_add`, `account_default_label`, `account_numbered_label`, `account_active_badge`, `account_primary_badge`, `account_set_primary`, `account_rename`, `account_rename_hint`, `account_delete`, `account_delete_title`, `account_delete_body`, `account_delete_backup_note`, `account_delete_confirm`, `account_deleted`, `account_switch_busy`, `account_delete_busy`, `account_tap_busy`, `account_duplicate_login`, `account_migration_failed`, `account_migrated_elsewhere`, `account_bg_refresh`, `account_bg_refresh_hint`, `account_bg_off_tag`, `account_manage_btn`, `account_credentials_for`, `settings_scope_account`, `settings_scope_shared`, `settings_interval_shared_hint`, `alarm_primary_account_note`, `wiz_cancel_add`, `tut_acc_switch_title`, `tut_acc_switch_body`) added to `app_cs.arb`, `app_en.arb`, and `strings.dart`, verified by `strings_table_parity_test.dart`. None of them exists today. The exact cs/en text for `account_delete_backup_note`, `account_tap_busy`, `account_duplicate_login`, `account_migration_failed` and `alarm_primary_account_note` is given in §4.2, §7.2, §8, §9 and §10.3; `account_migrated_elsewhere` is *"Data se právě přesunula do účtů; spusťte aplikaci znovu."* / *"The data was just moved into accounts; please restart the app."*

---

## 11. Implementation & Verification Plan

### 11.1 Planned commits (one focused unit per commit, every commit green)

1. **`F4: add background_refresh config key and multi-account storage core`**
   - `background_refresh` in `config.example.json`, `config.dart`, `config_test.dart`, and `parity/helpers.json` `roundTripFiles` (PLAN rule 4).
   - `packages/strakalari_core/lib/src/storage/accounts.dart`: `globalConfigKeys`, `AccountInfo` (`migrated`, `adding`), `AccountRegistry` (load, rebuild from folders, unique labels), `AccountManager`, `ensureMultiAccountLayout` (§4.2: conditions, `session.lock` + `migrate.lock`, staging, verify without fallback, `global.json` every attempt, rename, commit, never touch originals), `enterAccountsMode`, `createAccount`, `renameAccount`, `setActiveAccount`, `setPrimaryAccount`, `deleteAccount`, `forgetAllKeys` (folders on disk).
   - Extended Store/macOS data moves (`helpers.dart`, `packaging.dart`, §4.1).
   - Scoped `dataDir` / `fallbackKeyDir` support and the accounts-mode guard in `helpers.dart`, `config.dart` (precedence, split save, refuse save for a deleted account), `cache.dart`, `audit.dart`, `automation.dart`, `refresh.dart`, `strava/client.dart`, `error_report.dart` (all-account redaction), and `notifyForAccount` in `notifier.dart`.
   - Core unit tests (§11.2 items 1–6, 12): `accounts_test.dart`, extended `config_test.dart`, `secret_store_test.dart`, `notifier_test.dart`, `error_report_test.dart`, `helpers_test.dart`.
2. **`F4: upgrade Android Keystore, startup, and AppState for multiple accounts`**
   - Multi-key `WarmedAndroidKeystore` + `warmAndroidKeystoreAll` + `ensureWarmed` (`android_keystore.dart`).
   - Startup move order & `--forget-secrets` (`startup.dart`), headless move + `global.json` gate + multi-key warm + sequential multi-account refresh + primary-account status/widget/alarm sync (`background.dart`, `scheduler_jobs.dart`, `android_notifications.dart`).
   - `AppState` multi-account lifecycle (`app_state.dart`, `activity.dart`, `excuses.dart`, `lunches.dart`, `planner.dart`): `_loadAccount()`, `switchAccount` (allow-list), account token for async results, extended busy list, `beginAddAccount`, `cancelAddAccount`, `renameAccount`, `setPrimaryAccount`, `deleteAccount`, `setAccountBackgroundRefresh`, `runsByAccount`/`logLinesByAccount`, `handleRefreshResult` (shared by active and background accounts), due accounts + pass budget in `scheduledRefreshJob`, extracted status/cancelled-lunch derivations, `?account=` routing and busy taps in `applyLaunchRoute`, every call site of the §3.4 table.
   - `installer.iss` *Remove all user data* (§5.3).
   - App unit tests (§11.2 items 7–11, 13): `app_state_accounts_test.dart`, extended `android_background_test.dart`, `android_keystore_test.dart`, `android_phone_background_test.dart`, `settings_live_test.dart`.
3. **`F4: add account switcher, Settings accounts manager, add-account wizard, and tutorial`**
   - Account Switcher pill + sheet/dialog (`scaffold.dart`, `more.dart`, new `widgets/account_switcher.dart`).
   - Settings → Účty manager card, per-account `background_refresh` switch in Účty & Pravidla, scope captions, Budík on a non-primary account (banner + *Nastavit jako hlavní*, no card), delete confirmation dialog with the backup line, degraded-mode hint (`settings_controller.dart`, `settings_live.dart`, `settings_view.dart`).
   - Add-account wizard mode (`adding` flag, Finish/Cancel only, duplicate-login check) (`wizard_controller.dart`, `wizard_live.dart`, `wizard_view.dart`).
   - `'accounts'` tutorial tour + `tut_settings_intro_body` update + `demo_data.py` `TOURS_DONE` (`tours.dart`, ARBs, `strings.dart`).
   - Widget & live tests (§11.2 items 14–15): `accounts_ui_test.dart`, extended `settings_sections_test.dart`, `wizard_live_test.dart`, `tutorial_test.dart`, `mobile_narrow_shell_test.dart`.

### 11.2 Test cases (the R6 reviewer runs these and the move itself on throwaway copies)

Every move test checks afterwards that every original root file is byte-identical (SHA-256) and still present.

1. **Desktop layout move:** a pre-F4 flat layout with stored passwords, keyring backend (fake `KeyStore`) and `STRAKALARI_NO_KEYRING=1`: `accounts/default/` byte-identical copies, key equals the root key, passwords decrypt with the account key alone, `global.json` has exactly the shared keys present, `accounts.json` has `migrated: true`.
2. **Android / Play (Flet) layout move:** the same with `secret.key.wrapped` (fake Keystore bridge) and with a plain `secret.key`; custom relative `already_excused_file` / `log_file` paths; `log.txt.old`.
3. **Second run:** after a finished move, a new start changes nothing (every file and modification time the same).
4. **Interrupted run:** a crash injected after each step (staging copy, key carry, verify, `global.json`, rename) and a new run: the end state equals a clean run; an earlier `global.json` is overwritten from the current root config.
5. **Lost / corrupt registry:** `accounts.json` deleted, and separately made unreadable, after the move and after changes in `accounts/default/` and a second account: the registry is rebuilt from the folders, the changes survive, the move does not run, root files untouched.
6. **Degraded mode & locks:** the move waits for a held `session.lock`; a failing carry leaves no `accounts.json` and shows the hint; a degraded process refuses to refresh/send/order once another process committed; no account UI in degraded mode.
7. **Root files never used in accounts mode:** the full two-account cycle of §3.4 leaves every root file byte-identical; a per-account function without a folder throws. **Config precedence:** a shared key comes from `global.json` even when the account file holds another value; a save writes shared keys only to `global.json` and per-account keys only to the account file; when the account write fails, its edits stay pending, the error is raised, and the `global.json` write stands; a deleted account's `ConfigManager` refuses to save.
8. **Store / macOS moves after F4:** classic → MSIX and bundle → Application Support with two accounts (keyring and no keyring), and one interrupted before `accounts.json`.
9. **One at a time:** two accounts never inside `runRefresh` at once while the UI scheduler, the tray *Obnovit data* and a headless wake fire together (a fake that records overlapping calls).
10. **Due accounts & budget:** A succeeds and B fails → the 5-minute retry refreshes only B; a pass that hits the 20-minute mark leaves the rest due and ends with an unreported `JobFailed`.
11. **Shared result handler:** a background account's new mark notifies with its `[label]` and `?account=`; its F3 cancel sends `lunch_skipped`; its empty Strava balance neither fails the job nor retries; its failure doesn't stop the next account.
12. **Keys:** an account added after the headless isolate started is refreshed there without its key being quarantined (`ensureWarmed`); `forgetAllKeys` forgets the keys of folders missing from the registry; another account's password in a traceback is redacted.
13. **Switching & routing:** switched state equals a fresh `AppState` (except the allow-list); an AI pick finishing after a switch is dropped; an event tap for the active account doesn't switch to the primary; a busy tap shows `account_tap_busy` and switches later; status inputs for a non-active primary equal an `AppState` built for it.
14. **Add & delete:** the wizard cases of §10.3 item 4; deleting the active account with a focused field leaves the folder gone; the backup line shows only for `migrated` / outside-folder accounts.
15. **Budík:** a non-primary account shows the banner and *Nastavit jako hlavní*, no editable card; the button makes it primary and shows the card.

### 11.3 Visual and phone evidence (before ⛔ R6 handover)

- `dart pub get --enforce-lockfile`; `dart analyze && dart test` in `packages/strakalari_core`; `flutter analyze && flutter test` in `app` — zero warnings, zero regressions, zero weakened/skipped tests.
- Visual evidence in `build/qa-evidence/F4/` at **390 px and 1280 px**, **cs and en**, **light and dark** (demo data only): TopBar switcher pill, Switcher sheet/dialog, Settings → Účty (2 accounts), Delete confirmation dialog (with and without the backup line), Settings → Pravidla (`background_refresh`), Více page (390 px), Settings → Budík non-primary banner, Add-account wizard step with Cancel, duplicate-login message. Two-account demo data: run two demo servers (`tools/bakalari_demo_server.py --port 18080` and `--port 18081`, different addresses, so the duplicate check allows them) and add the second account through the wizard, or add an option to `tools/demo_data.py` that writes a two-account layout.
- Pixel 7 Pro (`2C221FDH3002NZ`, `io.github.dendlerx.strakalari.test` ONLY — never the Play app) against local `bakalari_demo_server.py`:
  1. **Real upgrade:** today's `.test` build (pre-F4) set up against the demo server, then the F4 build installed over it with `adb install -r` (keeps its data); the app opens on the same account without re-entering the password, and the headless wake after the install moves the data if the app isn't opened first. (`run-as` doesn't work on `.test`, STATUS B9, so the folder itself can't be inspected on the phone; the byte-level checks are items 1–2 above.)
  2. Add a 2nd account via the wizard (second demo server on port 18081 with `adb reverse tcp:18081 tcp:18081`), verify switching, rename, set primary, toggle per-account `background_refresh`, and delete with confirmation.
  3. Verify the `KeepAliveService` status notification shows the primary account label + data, and an event notification tap for a non-active account switches to that account and opens the matching tab (O8).
- **Unverified (marked in STATUS):** the real Google Play (Flet) upgrade can't be run here (the Play app is never touched); it is covered by test item 2 with the Flet layout. macOS and iOS native builds remain *unverified* on Windows 11.

---

## 12. Resolved Owner Choices (2026-11-20)

1. **Q1 (`notifications` scope) — confirmed:** Keep the 13 event notification toggles (`notifications`) shared in `global.json`, while per-account background refresh is toggled individually via `background_refresh`.
2. **Q2 (shared `gemini_api_key`) — confirmed:** Keep `gemini_api_key` + `gemini_model` shared in `global.json`, while `gemini_prompt`, `gemini_auto_enabled`, and `gemini_interval_days` stay per-account.
3. **Q3 (desktop tray *Obnovit data* & *Pozastavit*) — decided:** Tray *Obnovit data* refreshes all `background_refresh`-enabled accounts sequentially; tray *Pozastavit automatizaci* toggles `automation_paused` on the active account and includes the active account's label when `accounts.length > 1` (never silently unpausing another child's account). The owner can ask for "pause everything" instead.
4. **Add-account wizard (owner's question):** yes, creating an account opens the wizard again with only the applicable steps (§10.3).
