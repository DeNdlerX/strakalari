# F4 design note: Multiple accounts

Status: **design note only, no F4 code written yet (⛔ R6a stop).**
Written 2026-11-20 against `qa-roadmap` / `main` @ `be701d9` (after R5 passed and merged).

Sources: [`PLAN.md`](PLAN.md) §6 (Phase 6 — F4), §8 (D4), owner's D4 answers recorded word for word in [`STATUS.md`](STATUS.md), `CONTRIBUTING.md` §5–6, and report §3.2 (background — note that report §3.2 assumes `flutter_secure_storage`, whereas the real codebase uses Fernet encryption backed by `secret_store.dart` + `DesktopKeyStore` / Android Keystore `strakalari-secret-key`; this note follows the real codebase).

---

## 1. Summary & Goals

Allow one installation of Strakaláři (Windows, macOS, Linux, Android; iOS-ready) to hold **multiple independent school accounts** (for example, a parent managing two children, or a student with two accounts) with:

- **Complete per-account data isolation:** credentials, encryption keys, school preset/calendar overrides, absence limits, planned skips, excuse templates, sent/unconfirmed excuse history, timetable/marks/lunches cache, lunch blacklist, automation rules, audit log, and per-account log file live in separate folders under `<rootDir>/accounts/<account_id>/`.
- **Clear shared vs. per-account split:** app-wide preferences (theme, language, layout density, timetable view, marks sort, tutorials, disclaimer, update channel, notification preferences, device background/tray switches, check interval, network timeouts, and shared Gemini API key) live once in `<rootDir>/global.json`; every student/school/automation setting lives in `<rootDir>/accounts/<id>/config.json`.
- **Per-account background refresh toggle (D4 #3):** a new canonical boolean key `background_refresh` (default `true`) lets the user turn automatic background refresh on or off individually per account, in **Settings → Accounts** and **Settings → Rules**.
- **Lossless one-time upgrade:** existing desktop Flutter installs (classic, MSIX, macOS, Linux), Android Flutter installs, and **Google Play Python (Flet) installs** migrate automatically on first launch (UI **or** Android headless wake) by copying files to `accounts/default/`, verifying every file byte-for-byte + JSON + decryption before committing `accounts.json`, and **never deleting any original root file**.
- **Safety rules preserved (`CONTRIBUTING.md` §5):** one pipeline (`runRefresh`), one global `<rootDir>/session.lock` (one refresh/send/order at a time across all accounts and processes), one send path (`Strakalari.sendExcuse` + per-account `excuse_history.dart` + `HistoryLock`), everything audited per account (`automation_history.jsonl`, dry run included), per-account `automation_paused`, fail loudly, and destructive account deletion gated by an explicit confirmation dialog.
- **Zero clutter for single-account users:** when only one account exists, the top bar, bottom bar, notifications, widget, and wake-up alarm look and behave identically to today.

---

## 2. Folder Layout

Let `<rootDir>` be the app's root user data folder returned by `getUserDataDir()` (`packages/strakalari_core/lib/src/storage/helpers.dart` — `STRAKALARI_DATA_DIR`, Android `getApplicationSupportDirectory()/data`, macOS `~/Library/Application Support/Strakalari`, MSIX `%LOCALAPPDATA%\Strakalari`, writable classic Windows install dir, or Linux `~/.config/strakalari`). `getUserDataDir()` itself does **not** change, keeping all existing core parity tests and platform resolution intact.

```text
<rootDir>/
  accounts.json                      # Account registry, active_id, primary_id (atomic JSON, commit marker)
  accounts.json.lock                 # InterProcessLock guarding accounts.json writes
  global.json                        # App-wide shared settings (19 keys; see §3)
  global.json.lock                   # InterProcessLock guarding global.json writes
  session.lock                       # ONE global cross-process session lock (shared with legacy/Python builds)
  migrate.lock                       # InterProcessLock guarding one-time migrations (existing + F4)
  instance.token                     # Desktop single-instance IPC token (existing, unchanged)
  console.log (+ .old)               # Windows windowed release stdio log (existing, unchanged)
  update_cache.json                  # GitHub release check cache (existing, app-wide, unchanged)
  school_presets/                    # User-supplied school calendar preset JSONs (existing, app-wide, unchanged)
  secret.key / secret.key.wrapped    # Root Fernet key (encrypts global.json gemini_api_key; fallback for migrated default)

  # Untouched pre-F4 backup files (present ONLY on upgraded installs; NEVER deleted automatically):
  config.json, data_cache.json, already_excused_lessons.json,
  already_excused_lessons.unconfirmed.json, strava_blacklist.json,
  automation_history.jsonl, log.txt

  accounts/
    <account_id>/                    # 'default' for first/migrated account; 'acc_<12 hex>' for added accounts
      config.json (+ .lock, .bak)    # Per-account canonical config (full schema; global keys overridden by global.json)
      data_cache.json                # Per-account timetable, absences, marks, lunches, outbox cache, cancel-handled list
      already_excused_lessons.json (+ .lock)     # Per-account sent & web-synced excuse history + HistoryLock
      already_excused_lessons.unconfirmed.json   # Per-account unconfirmed submits awaiting outbox settlement
      strava_blacklist.json          # Per-account forbidden lunch ingredients
      automation_history.jsonl (+ .old, .lock)   # Per-account audit log
      log.txt                        # Per-account core log
      secret.key / secret.key.wrapped            # Per-account Fernet key (Android wrapped or no-keyring fallback)
```

### 2.1 Account ID rules & `accounts.json` schema

- **Account IDs:**
  - Migrated single-account install and first fresh-install account: `'default'`.
  - Additional accounts created via `+ Přidat účet`: `'acc_<12 lowercase hex chars>'` generated via `Random.secure()`.
  - Validation regex: `^[a-z0-9][a-z0-9_-]{0,39}$`. Every path resolution also asserts `p.isWithin(p.join(rootDir, 'accounts'), accountDir)` so a tampered `accounts.json` can never escape `accounts/`.
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
        "created_at": "2026-11-20T21:30:00"
      }
    ]
  }
  ```
- **Invariants on load (`AccountRegistry.load`):**
  - `accounts` is deduplicated by `id`, invalid IDs are dropped, and at least one entry must remain (if `accounts.json` is corrupt JSON, quarantine it via `quarantineCorruptFile`, log loudly, and reconstruct from existing `accounts/<id>/config.json` directories or fall back to single-account mode rather than losing data).
  - If `active_id` is missing from `accounts`, fall back to `accounts.first.id`.
  - If `primary_id` is missing from `accounts`, fall back to `active_id`.
- **Default display `label`:**
  - On migration from legacy `config.json`: `your_signature` (trimmed, if non-empty and not placeholder) → else `bakalari_username` (if non-empty and not placeholder) → else `''` (rendered in the UI as localized `account_default_label`: `"Hlavní účet"` / `"Main account"`).
  - On finishing the add-account wizard: `your_signature` → else `bakalari_username` → else `"Účet N"` / `"Account N"`.
  - Always editable via Rename in **Settings → Účty** (trimmed, non-empty, max 60 characters).

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
| Notifications & updates (2) | `notifications`, `update_channel` | Event toggle preferences (including app-wide `update_available`) and release channel for the single installed binary. *(See §12 Q1 for confirmation.)* |
| Network & cache display (2) | `page_load_timeout_s`, `cache_ttl_hours` | Device/network timing & staleness display threshold. |
| Shared Gemini API credentials (3) | `gemini_api_key`, `gemini_api_key_encrypted`, `gemini_model` | One Google AI Studio key per household/device (encrypted with the root key `getKey(rootDir)`), while per-child lunch preferences stay separate below. |

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
| Wake-up alarm (3) | `wakeup_enabled`, `wakeup_minutes_before`, `wakeup_skip_dates` | Tied to the student's timetable; driven on Android by the `primary_id` account (§8). |
| Setup wizard state (1) | `wizard_step` | Tracks unfinished setup per account (`-1` when complete). |

### 3.3 New canonical config key: `background_refresh` (PLAN §2 rule 4)

- Key name: `background_refresh`
- Type & default: `bool`, default `true`
- Validation (`config.dart` `validateConfig`): rejects non-boolean non-null values (`"'background_refresh' must be a boolean."`), mirroring `strava_auto_cancel_lunches`.
- Updated in the **same commit** in:
  1. `config.example.json`
  2. `packages/strakalari_core/lib/src/storage/config.dart` (`canonicalDefaults` + `validateConfig`)
  3. `packages/strakalari_core/test/config_test.dart`
  4. The two full canonical config snapshots in `roundTripFiles` of `packages/strakalari_core/test/parity/helpers.json` (only allowed parity fixture edit per PLAN §2 rule 4).

### 3.4 Merged runtime config & backward compatibility

- **Legacy single-file `ConfigManager` calls** (all existing core unit/parity tests, `ConfigManager(path)` without `globalPath`): unchanged behavior — all 74 keys load from and save to `path`, zero parity regressions.
- **Multi-account `ConfigManager(accountConfigPath, globalPath: p.join(rootDir, 'global.json'), baseDir: accountDir, rootDir: rootDir)`:**
  - `load()`: loads `<accountDir>/config.json`, then overlays keys in `globalConfigKeys` from `<rootDir>/global.json` (if present; missing keys fall back to `canonicalDefaults`, preserving `defaultUpdateChannel()`).
  - `set(key, value)`: encrypts `bakalari_password` / `strava_password` with `encrypt(v, dataDir: accountDir)` and encrypts `gemini_api_key` with `encrypt(v, dataDir: rootDir)`.
  - `save()`: splits touched keys:
    - Keys in `globalConfigKeys` merge-save atomically into `<rootDir>/global.json` under `<rootDir>/global.json.lock`.
    - Remaining keys merge-save atomically into `<accountDir>/config.json` under `<accountDir>/config.json.lock`.
  - Every core consumer (`Strakalari`, `runRefresh`, `validateConfig`, `error_report`, `school_presets`, `wakeup`, `status_notification`) receives the flat merged `Map<String, Object?>` — zero schema breakage.
  - **No mutable global `activeAccountDir` for I/O:** core storage functions gain optional `String? dataDir` parameters defaulting to `null` (`getUserDataDir()`):
    - `loadDataCache({String? dataDir})`, `saveDataCache(data, {bool replace = false, String? dataDir})`
    - `audit.historyPath({String? dataDir})`, `audit.record(..., {..., String? dataDir})`, `audit.recent({int limit = 50, String? dataDir})`, `audit.hasDryRun(kind, {String? dataDir})`
    - `Strakalari({..., String? dataDir, String? rootDir})` (resolves `configFile`, `blacklist`, `alreadyExcusedFile`, `logFile` against `dataDir`, and passes `dataDir` into `loadDataCache`/`saveDataCache`/`audit`/password decrypt with `fallbackKeyDir: rootDir`)
    - `StravaClient(config, {String? dataDir})`
    - `runRefresh(app, config, ...)` reads `app.dataDir` for every cache read/write.
    - Because every call carries its explicit `dataDir`, an async background refresh of Account B can **never** interleave with and corrupt Account A's UI reads/writes across `await` boundaries.

---

## 4. One-Time Migration & Upgrading Existing Installs

### 4.1 Upgrade matrix (Flutter installs + Google Play Python app)

| Existing install | Root data dir (`getUserDataDir()`) | Pre-F4 migration before F4 | F4 migration behavior |
|---|---|---|---|
| **Windows classic** | `%LOCALAPPDATA%\Programs\Strakalari` (or `%LOCALAPPDATA%\Strakalari`) | None | Copies flat root files → `accounts/default/`, carries keyring key, writes `global.json`, commits `accounts.json`. |
| **Windows Store (MSIX)** | `%LOCALAPPDATA%\Strakalari` | Existing `_storeAppDataDir()` copies from classic install if needed | Runs **after** `getUserDataDir()`, so classic → MSIX → F4 chains cleanly into `accounts/default/`. |
| **macOS** | `~/Library/Application Support/Strakalari` | Existing `_macosAppDataDir()` copies out of `.app` bundle if needed | Runs **after** `getUserDataDir()`, chaining cleanly. *(Unverified natively on Windows 11.)* |
| **Linux** | `~/.config/strakalari` | None | Copies flat root files → `accounts/default/`, carries Secret Service key, commits `accounts.json`. |
| **Android Flutter (`.test` / GitHub APK)** | `getApplicationSupportDirectory()/data` | None | Copies flat root files + `secret.key.wrapped` (or `secret.key`) → `accounts/default/`, verifies Android Keystore unwrap, commits `accounts.json`. |
| **Android Google Play (Python / Flet)** | `getApplicationSupportDirectory()/data` (identical to Flet's `FLET_APP_STORAGE_DATA`) | None — identical file names, JSON schemas, and Android Keystore alias `strakalari-secret-key` | Identical to Android Flutter above! **Crucial:** `ensureMultiAccountLayout(rootDir)` runs in **both** `prepareStartup()` (UI launch) **and** `_runHeadless()` (`app/lib/platform/android/background.dart`), so an overnight Play Store update whose first execution is `BootReceiver` / `MY_PACKAGE_REPLACED` / `RefreshReceiver` migrates safely before the user ever opens the app. |
| **Fresh install** (no `accounts.json` and no root `config.json`) | `<rootDir>` | None | Creates `accounts/default/`, empty `global.json`, and `accounts.json` (`active_id: 'default'`, `primary_id: 'default'`). `needsSetup()` is `true` → normal first-run wizard launches. |

### 4.2 Exact one-time migration protocol (`ensureMultiAccountLayout(rootDir)`)

Runs only when `!<rootDir>/accounts.json` exists AND `<rootDir>/config.json` exists. Guarded by `InterProcessLock('<rootDir>/migrate.lock')` (timeout 30 s):

1. **Re-check commit marker:** if `<rootDir>/accounts.json` now exists (another process/isolate just completed migration), return `true`.
2. **Parse source config:** read `<rootDir>/config.json` as UTF-8 JSON `Map`. If unreadable or corrupt, log a loud `Warning:` and return `false` without modifying or deleting anything.
3. **Build per-account file list** (relative paths under `<rootDir>` that currently exist as files):
   - Standard files: `config.json`, `config.json.bak`, `data_cache.json`, `already_excused_lessons.json`, `already_excused_lessons.unconfirmed.json`, `strava_blacklist.json`, `automation_history.jsonl`, `automation_history.jsonl.old`, `log.txt`.
   - Custom relative paths from source `config.json` keys `strava_blacklist`, `already_excused_file`, `log_file` (normalized, skipping absolute paths or `..` escapes — same rule as `_bundleDataItems` in `helpers.dart:216`).
   - Root-shared items (`school_presets/`, `update_cache.json`, `instance.token`, `console.log`, `session.lock`, `migrate.lock`, `accounts/`) stay in `<rootDir>` and are **not** copied.
4. **Copy files atomically** into `<rootDir>/accounts/default/<rel>` (write to `.migrating-<pid>` temp file + rename; skip if destination already exists with matching SHA-256 so an interrupted earlier attempt resumes cleanly).
5. **Carry credential key** for `accounts/default/`:
   - **Android:** copy `<rootDir>/secret.key.wrapped` (if present) and `<rootDir>/secret.key` (if present) atomically into `<rootDir>/accounts/default/`.
   - **Desktop:** call `carryKey(rootDir, defaultAccountDir)` (copies the Fernet key into the OS credential store under `entryName(defaultAccountDir)`, or `<defaultAccountDir>/secret.key` when keyring is disabled/unavailable, while **leaving the root entry `entryName(rootDir)` untouched**). If `carryKey` returns `false`, abort migration (step 7 below).
6. **Verify EVERY copied artifact BEFORE committing:**
   - Every file in step 3 exists at `<rootDir>/accounts/default/<rel>` with **exact matching byte length and SHA-256 digest** against `<rootDir>/<rel>`.
   - `<rootDir>/accounts/default/config.json` decodes cleanly as a JSON `Map`.
   - If `bakalari_password_encrypted == true` (with non-empty `bakalari_password`), or `strava_password_encrypted == true` (with non-empty `strava_password`), `decryptStrict(..., dataDir: defaultAccountDir, fallbackKeyDir: rootDir)` returns non-null.
   - If `gemini_api_key_encrypted == true` (with non-empty `gemini_api_key`), `decryptStrict(..., dataDir: rootDir)` returns non-null.
   - On Android, if `accounts/default/secret.key.wrapped` was copied, `warmAndroidKeystore(defaultAccountDir)` unwraps it cleanly.
7. **On ANY verification failure:**
   - Print a loud `Warning:` naming the exact failed step/file.
   - Do **NOT** write `<rootDir>/accounts.json`.
   - Do **NOT** delete or alter any original file in `<rootDir>`.
   - Return `false`: `AppState` sees no `accounts.json` and degrades safely into single-account compatibility mode on `<rootDir>` for this launch; migration retries cleanly on the next launch.
8. **Write `global.json` (if missing) & commit `accounts.json`:**
   - Extract all keys in `globalConfigKeys` present in source `config.json` and write `<rootDir>/global.json` atomically; verify it parses back as a JSON `Map`.
   - Write `<rootDir>/accounts.json` atomically as the **final commit step** with `version: 1`, `active_id: 'default'`, `primary_id: 'default'`, and `accounts: [{id: 'default', label: <derived>, created_at: <nowIso>}]`.
9. **Never delete originals:** `<rootDir>/config.json`, `data_cache.json`, `already_excused_lessons.json`, `secret.key*`, and the root OS keyring entry remain completely untouched on disk as a permanent non-destructive backup. Once `<rootDir>/accounts.json` exists, F4 reads/writes only `global.json`, `accounts.json`, and `accounts/<id>/*`.

---

## 5. Credential Key Names & Fallback to Today's Names

### 5.1 Key naming & isolation

| Scope | Desktop OS Credential Store (`service = "Strakalari"`) | Desktop fallback (`STRAKALARI_NO_KEYRING=1`) | Android (`strakalari-secret-key` AES-256-GCM wrap) |
|---|---|---|---|
| **Root / shared (`global.json` — `gemini_api_key`)** | **Today's exact entry name:** `entryName(rootDir)` = `fernet-key:<sha256(normcase(abspath(rootDir)))[:16]>` | `<rootDir>/secret.key` | `<rootDir>/secret.key.wrapped` (plain `<rootDir>/secret.key` if Keystore unavailable) |
| **Per-account (`accounts/<id>/config.json` — `bakalari_password`, `strava_password`)** | `entryName(accountDir)` = `fernet-key:<sha256(normcase(abspath(accountDir)))[:16]>` | `<accountDir>/secret.key` | `<accountDir>/secret.key.wrapped` (plain `<accountDir>/secret.key` if Keystore unavailable) |

- Every newly added account gets its **own freshly generated 32-byte Fernet key** under its own `entryName(accountDir)` / `<accountDir>/secret.key.wrapped`.
- Migrated `'default'` receives a copy of the root key via `carryKey(rootDir, defaultAccountDir)` (desktop) or copied `secret.key.wrapped` (Android), keeping the root key intact.

### 5.2 Fallback to today's key name

`encrypt` / `decrypt` / `decryptStrict` in `packages/strakalari_core/lib/src/storage/helpers.dart` gain optional `{String? dataDir, String? fallbackKeyDir}` parameters (defaulting to `null` → `getUserDataDir()`, preserving 100% existing signatures and tests):

1. **Encryption (`encrypt`):**
   - Per-account passwords (`bakalari_password`, `strava_password`) always encrypt with `getKey(accountDir)`.
   - Shared `gemini_api_key` always encrypts with `getKey(rootDir)`.
2. **Decryption (`decrypt` / `decryptStrict`):**
   - First try Fernet with `getKey(dataDir ?? getUserDataDir())`.
   - **Fallback to today's name:** if that fails (`InvalidTokenException` / `FormatException` / missing key) and `fallbackKeyDir != null` (`!p.equals(dataDir, fallbackKeyDir)`), try Fernet with `getKey(fallbackKeyDir)` — i.e., today's root entry `entryName(rootDir)` / `<rootDir>/secret.key.wrapped`!
   - Finally, fall back to the legacy XOR cipher (unchanged).
   - Thus, even if an upgraded account's keyring entry was ever missing or a user manually copied an old `config.json` into `accounts/default/`, stored passwords still decrypt cleanly via today's root key name.

### 5.3 Android `WarmedAndroidKeystore` multi-key upgrade (`app/lib/platform/android/android_keystore.dart`)

- Currently `WarmedAndroidKeystore` stores **only a single** `(key, blob)` pair and throws `KeyStoreUnavailable` for any second key — which would break multi-account on Android!
- **Fix:** upgrade `WarmedAndroidKeystore` to hold a map/list of warmed `(Uint8List key, Uint8List? blob)` pairs (still refusing any un-warmed key/blob so fail-safe semantics are unchanged).
- Add `warmAndroidKeystoreAll(String rootDir, Iterable<String> accountIds)` called at **both** UI startup (`prepareStartup`) and headless wake (`_runHeadless`), warming `rootDir` plus every `<rootDir>/accounts/<id>/` directory.
- When adding a new account in the UI, `await warmAndroidKeystore(newAccountDir)` wraps and registers its newly generated key before the wizard saves its first password.
- When deleting an account, `forgetKey(accountDir)` zeroes and deletes `<accountDir>/secret.key.wrapped` / `<accountDir>/secret.key`, evicts it from `_cache`, and drops its pair from `WarmedAndroidKeystore`.
- Desktop `--forget-secrets` (`startup.dart:77`) calls `forgetAllKeys(rootDir)`, forgetting the root key **and** every `<rootDir>/accounts/<id>/` key so the uninstaller leaves no orphaned OS credential store entries.
- **Zero Java Keystore changes required:** `StrakalariChannel.java`'s `keystoreWrap` / `keystoreUnwrap` already wrap/unwrap arbitrary byte arrays under `strakalari-secret-key`.

---

## 6. `session.lock` & Concurrency Safety

- **One global lock:** `<rootDir>/session.lock` (`SessionLock.acquire` continues to resolve `./session.lock` against `getUserDataDir()` = `<rootDir>`).
  - Guarantees **at most one refresh, excuse submit, or lunch order across ALL accounts and ALL processes/isolates at any moment**.
  - Remains identical to the Python app and pre-F4 Flutter builds, so a legacy and F4 process still exclude each other.
- **Per-account & metadata locks:**
  - `<accountDir>/already_excused_lessons.json.lock` (`HistoryLock`, already derived from `alreadyExcusedFile`): isolates each account's excuse check-send-write sequence.
  - `<accountDir>/config.json.lock`: guards per-account config saves.
  - `<rootDir>/global.json.lock`: guards shared settings saves.
  - `<rootDir>/accounts.json.lock`: guards registry updates (add, switch, rename, set primary, delete).
  - `<rootDir>/migrate.lock`: guards one-time migrations.
- **Lock ordering (deadlock-free):** `session.lock` is always outermost; leaf locks (`HistoryLock`, `config.json.lock`, `global.json.lock`, `accounts.json.lock`) are never nested inside each other (except `HistoryLock` inside `session.lock`, as today).
- **UI switching safety:**
  - Switching or deleting an account is rejected with a clear snackbar (`account_switch_busy` / `account_delete_busy`) while `refreshRunning || sendingExcuses.isNotEmpty || orderRunning || testing.isNotEmpty` is active.
  - Background refreshes of non-active accounts **never mutate** the active account's UI state (`data`, `orders`, `pendingOrders`, `plannedSkips`, `status`); they write strictly to their own `<accountDir>` and record their summary in `runsByAccount[accId]` / `logLinesByAccount[accId]`.

---

## 7. Background Refresh Across Accounts

### 7.1 Per-account control + device master switch

- **Per-account switch (`background_refresh`, default `true`):** stored in `<accountDir>/config.json`. Toggleable per account in **Settings → Účty** (on every account row, without needing to switch accounts first) and in **Settings → Pravidla** (for the active account).
- **Android device master switch (`run_in_background`, default `true`):** stored in `<rootDir>/global.json`.
  - When `run_in_background` is `false` on Android: `KeepAliveService` stops, `RefreshReceiver` wake is cancelled, and headless wakes exit immediately (unchanged contract).
  - When `run_in_background` is `true` on Android (and on desktop whenever the app/tray runs): the scheduler ticks every `check_interval_minutes` (`global.json`).

### 7.2 Sequential execution through `runRefresh`

Both the live scheduler (`AppState.scheduledRefreshJob` in `app/lib/controllers/activity.dart`) and the Android headless wake (`runHeadlessTick` in `app/lib/platform/android/background.dart`, which calls the same `registerJobs` → `scheduledRefreshJob`) run the **exact same sequential loop**:

1. Load the current `AccountRegistry` from `<rootDir>/accounts.json`.
2. Build the ordered account list: `primary_id` first, then `active_id` (if different), then remaining accounts in registry order.
3. For each account `acc` **one at a time** (never in parallel):
   - If `stopped?.call() ?? false`, stop immediately.
   - Load `acc`'s merged config (`global.json` + `<accDir>/config.json`).
   - Skip `acc` if:
     - `acc`'s setup is pending (`wizard_step >= 0` or `!hasValidCredentials(accCfg).$1 && !hasValidCredentials(accCfg).$2`), OR
     - `accCfg['background_refresh'] == false`.
   - If `acc.id == activeAccountId` (UI alive): run the active account's standard `startRefresh('all')` (which acquires `<rootDir>/session.lock`, runs `runRefresh(app, runConfig, scope: 'all', ...)`, clears auto-ordered/auto-cancelled `pendingOrders`, calls `reloadCache()`, updates `runs`, and fires notifications).
   - If `acc.id != activeAccountId` (non-active account): run `_refreshBackgroundAccount(acc)` inside `withSessionLockAsync`:
     - Constructs `createApp(dataDir: accDir, rootDir: rootDir, configData: accCfg, onLog: ...)` and calls **`runRefresh(app, accCfg, scope: 'all', cancelledLunchDays: ..., keptLunchDays: const {}, ...)`** — **the exact same `runRefresh` pipeline!**
     - Passes `acc`'s own `cancelledLunchDays` (recomputed from `acc`'s `planned_skips` + `data_cache.json` `strava_ordered` & `auto_lunch_cancel_handled`, matching `AppState`'s constructor logic).
     - Stamps `gemini_last_run` into `<accDir>/config.json` if `result.usedGemini`.
     - Records the run into `runsByAccount[acc.id]` (capped at 20) and `logLinesByAccount[acc.id]` (capped at 300), so switching to `acc` later shows its recent Activity runs immediately!
     - On error: builds error diagnostics redacted with **`accCfg`** (never the active account's config!), logs it, notifies `refresh_failed` / `automation_failed`, marks `anyFailed = true`, and **continues to the next account** so one broken account never starves another child's refresh or automation.
4. **Notification tagging & O8 tap routing:**
   - Add `notifyForAccount(String event, String message, {Map<String, Object?>? prefs, String? accountId, String? accountLabel})` in `packages/strakalari_core/lib/src/platform/notifier.dart` (leaving existing `notify(event, message, [prefs])` signature and all parity tests untouched).
   - When `accounts.length > 1` and `accountLabel` is non-empty: prefix the notification body with `"[<accountLabel>] "` (e.g., `"[Klára] Nová známka: Matematika (1)"`). When `accounts.length == 1`: no prefix.
   - `AndroidNotifications` (`app/lib/platform/android/android_notifications.dart`) encodes `route` as `'$baseRoute?account=$accountId'` when `accountId` is present. `Notifications.java` (`requestCodeForRoute` default branch `1000 + (route.hashCode() & 0x7fff)`) and `StrakalariChannel.java` (`handleIntent` forwarding `EXTRA_ROUTE`) already support arbitrary route strings with **zero Java changes**!
   - `AppState.applyLaunchRoute(rawRoute)` parses optional `?account=<id>`: if `<id>` exists in `accounts.json` and differs from `activeAccountId` (and `!setupPending` and not busy), switches to `<id>` first and then opens the target screen. If `<id>` no longer exists (deleted account), stays safely on the current account.
5. **Retry & startup seed:**
   - If any enabled account failed (non-cancelled), `scheduledRefreshJob` throws `JobFailed` so `PeriodicRunner` retries in 5 minutes (same as today).
   - `schedulerStartupSeed` anchors to the **oldest** `last_updated` among configured accounts with `background_refresh == true` (falling back to the active account if none), so a stale or newly added account does not wait an extra interval.
6. **Manual refresh:**
   - TopBar / Activity **Obnovit data** refreshes the **active account** only.
   - Desktop tray **Obnovit data** refreshes all configured `background_refresh`-enabled accounts sequentially (or the active account if none are enabled). Desktop tray **Pause / Resume** toggles `automation_paused` on the active account (and appends the active account's label to the tray menu item when `accounts.length > 1` so it is explicit and never silently unpauses another child's account).

---

## 8. Which Account the Notification, Widget, and Wake-Up Alarm Show

Android has **one** ongoing status notification (`KeepAliveService` / `StatusNotifier`), **one** home-screen timetable widget (`TimetableWidgetProvider`), and **one** wake-up alarm queue (`AlarmReceiver`).

- **Owner:** the designated **primary account** (`primary_id` in `accounts.json`).
  - Defaults to `'default'` (the existing/first account).
  - Never changes automatically when adding a second account or switching tabs to inspect another child — so looking at Child B's grades never clobbers Child A's home-screen widget or tomorrow's 6:45 wake-up alarm.
  - Changeable with one tap in **Settings → Účty** (*Nastavit jako hlavní* / *Set as primary*) whenever `accounts.length > 1`. Changing `primary_id` immediately re-runs `syncAndroidState()` and `phone.notifier.poke()` without restart.
- **Data source (`AppState.backgroundStatusInputs()` & `AppState.syncAndroidState()` + headless `_postStatus`):**
  - When `primary_id == activeAccountId`: reads directly from `AppState`'s in-memory config/cache (identical to today).
  - When `primary_id != activeAccountId`: loads `primary_id`'s merged config and `<primaryDir>/data_cache.json` + excuse tasks cleanly from disk so the status notification, widget, and wake-up alarm queue always reflect `primary_id`!
- **Status notification label when `accounts.length > 1`:**
  - `StatusContent.sub` (currently e.g. `"Aktualizováno 18:56"`) prepends the primary account label: `"Klára · Aktualizováno 18:56"` (or `"Klára"` if `sub` was empty), so the user always sees which child is summarized in the shade. When `accounts.length == 1`, `sub` is unchanged.
- **Tapping the status notification (`today`), home-screen widget (`timetable`), or alarm (`alarm`):**
  - These carry no `?account=` query parameter. In `applyLaunchRoute`, when `accounts.length > 1` and `activeAccountId != primary_id` (and `!setupPending` and not busy), a tap without `?account=` switches to `primary_id` before navigating so the opened screen always matches what the user tapped!
- **Settings → Budík on a non-primary account (`accounts.length > 1 && activeAccountId != primary_id`):**
  - Shows a concise info banner above `WakeupCard` (`alarm_primary_account_note`): *"Budík telefonu, widget a stavové oznámení používají hlavní účet ({name}). Hlavní účet změníte v Nastavení → Účty."* / *"The phone alarm, widget and status notification use the primary account ({name}). Change the primary account in Settings → Accounts."*

---

## 9. Account Deletion (Scope & Confirmation)

- **Guard:** the last remaining account (`accounts.length <= 1`) **cannot** be deleted (delete button hidden; users can edit credentials or clear cache instead). Deletion is also blocked with snackbar `account_delete_busy` while a refresh, send, order, or connection test is running.
- **Confirmation dialog (`AlertDialog`, `Key('acc:delete_dialog')`):**
  - Title: `Strings.format('account_delete_title', {'name': label})` (*Odstranit účet „{name}“?* / *Delete account "{name}"?*).
  - Explicit plain-language body (`account_delete_body`) stating:
    - **Deleted locally:** saved Bakaláři and Strava logins and this account's encryption key; its settings, school calendar overrides, limits, planned days, excuse templates, and lunch blacklist; its cached timetable, marks, absences, lunches, excuse history, and activity log.
    - **Kept untouched:** nothing changes on Bakaláři or Strava.cz websites; other accounts, shared app settings (theme, language, Gemini API key), and user-added school presets stay intact.
  - Actions: **Zrušit / Cancel** (default) and destructive **Odstranit účet / Delete account** (`Key('acc:delete_confirm')`).
- **Crash-safe deletion sequence (`AccountManager.deleteAccount(targetId)`):**
  1. Acquire `<rootDir>/session.lock` (non-blocking; abort with `account_delete_busy` if held by another process/isolate).
  2. Under `<rootDir>/accounts.json.lock`:
     - Verify `accounts.length > 1` and `targetId` exists.
     - Compute `nextActiveId` (first remaining account if `targetId == active_id`, else unchanged) and `nextPrimaryId` (equals `nextActiveId` if `targetId == primary_id`, else unchanged).
     - Write updated `accounts.json` atomically **first** (so a mid-delete crash never leaves a dangling half-deleted entry).
  3. Call `forgetKey(targetDir)` (deletes `entryName(targetDir)` from OS credential store, zeroes & deletes `<targetDir>/secret.key` and `<targetDir>/secret.key.wrapped`, clears in-memory key cache and `WarmedAndroidKeystore` entry).
  4. Assert `p.isWithin(accountsRoot, targetDir)` and recursively delete `<rootDir>/accounts/<targetId>/` **only**. Never touch any file outside `targetDir` (e.g., an absolute `log_file` path), never touch `global.json`, `school_presets/`, `update_cache.json`, or untouched pre-F4 root backup files.
  5. Release `<rootDir>/session.lock`.
  6. Drop `runsByAccount[targetId]` / `logLinesByAccount[targetId]`. If `targetId` was active, switch `AppState` to `nextActiveId`. If `targetId` was primary, immediately call `syncAndroidState()` and notify `PhoneBackground` so the widget, status notification, and wake-up alarms switch to `nextPrimaryId` immediately. Show `account_deleted` snackbar.

---

## 10. UI, Add-Account Wizard Flow, Tutorials & Strings

### 10.1 Account Switcher (`scaffold.dart`, `more.dart`)

- **Single-account (`accounts.length <= 1`):** no switcher pill in TopBar or `MorePage` (zero layout change for existing single-account users).
- **Multi-account (`accounts.length > 1`):**
  - Compact pill in TopBar (`Key('account_switcher')`, wrapped in `TutorialAnchor(anchorKey: 'account_switcher')`) on **both** narrow (390 px, `ConstrainedBox(maxWidth: 120)`, ellipsis) and wide (1280 px, `maxWidth: 200`): person icon + active account label + dropdown arrow. Always visible on every screen so a parent never excuses or orders for the wrong child!
  - Full-width active-account card at top of `MorePage` on narrow phones (`Key('more:account_card')`) opening the same switcher sheet.
- **Switcher sheet/dialog (`AccountSwitcherSheet`, `Key('account_switcher_sheet')`):**
  - Bottom sheet on narrow, dialog on wide.
  - Lists every account (initial badge, label, username + school preset subtitle, `"Hlavní"` / `"Primary"` chip on `primary_id`, `"Pozadí vypnuto"` / `"Background off"` muted tag if `background_refresh == false`, checkmark on active).
  - Tapping a non-active account switches immediately (`AppState.switchAccount(id)`): loads its `ConfigManager` + `data_cache.json`, rebuilds `orders`/`webOrders`/`plannedSkips`/`cancelledLunches`/`ignoredExcuseKeys`, clears ephemeral UI state (`pendingOrders`, `drafts`, `expandedDays`, `marksSelected`, `marksEditing`, `marksPredictions`, `yearPlanCache`, `monthSlotsCache`, `baselineCache`, `lastError`, `lastTest`, `plannerTerm`), swaps `runs`/`logLines` to `runsByAccount[id]`/`logLinesByAccount[id]`, updates `accounts.json` `active_id`, and emits.
  - Footer actions: **`+ Přidat účet`** (`Key('switcher:add_account')`) and **`Spravovat účty`** (navigates to Settings → Účty).

### 10.2 Settings → Účty & scope captions (`settings_view.dart`, `settings_controller.dart`)

- Top card of **Settings → Účty**: **"Účty v aplikaci" / "App accounts"** (`Key('settings:accounts_card')`):
  - Shows all accounts (`Key('acc:item:<id>')`) with active indicator, primary badge (when >1), Bakaláři username + school subtitle, per-account **Rename** (`Key('acc:rename:<id>')`), **Set as primary** (`Key('acc:set_primary:<id>')`, when >1 and not primary), per-account **Background refresh** toggle (`Key('acc:bg_refresh:<id>')`), and **Delete** (`Key('acc:delete:<id>')`, when >1, opening the confirmation dialog in §9).
  - **`+ Přidat účet` / `+ Add account`** button (`Key('acc:add_btn')`).
- Below it: active account's Bakaláři & Strava credential cards (headed by `"Přihlašovací údaje — <label>"` when >1 account).
- **Settings → Pravidla:** adds `SwitchListTile(key: Key('rule:background_refresh'))` for the active account's `background_refresh` (with hint explaining it controls scheduled background refreshes for this account).
- **Scope captions (only when `accounts.length > 1`):**
  - Per-account sections (`accounts`, `limits`, `calendar`, `alarm`, `templates`, `rules`, `ai` per-account card): subtle muted caption `"Nastavení účtu: {name}"` / `"Account settings: {name}"`.
  - Shared sections (`appearance`, `notifications`, `browser`, `diagnostics`, `ai` API key card): subtle muted caption `"Společné pro všechny účty"` / `"Shared across all accounts"`.
  - Settings → Diagnostika → *Vymazat mezipaměť* clears only the active account's `<activeAccountDir>/data_cache.json`.

### 10.3 Add-Account Wizard Flow (`wizard_controller.dart`, `wizard_live.dart`, `wizard_view.dart`)

Reuses the existing F1/F1c wizard without duplicating any login/preset/template UI:
1. `AppState.beginAddAccount()` creates a provisional `<rootDir>/accounts/<newId>/` directory, warms its Android Keystore key on Android, inserts it into `accounts.json` with `wizard_step = disclaimerAccepted ? stepSchool : stepWelcome`, stores `addingAccountReturnId = previousActiveId`, switches active account to `<newId>`, and navigates to `/wizard`.
2. In add-account mode (`addingAccount == true`, i.e., `accounts.length > 1 && setupPending`):
   - `shownSteps()` shows only the applicable per-account steps: **Škola (`stepSchool`) → Bakaláři (`stepBakalari`) → Strava (`stepStrava`) → Omluvenky (`stepExcuses`) → Hotovo (`stepDone`)** — skipping `stepWelcome` (when `disclaimer_accepted` is already `true` in `global.json`) **and** skipping `stepPhone` on Android (notification permission was already handled on first setup, and the phone's wake-up alarm belongs to `primary_id`, not a newly added secondary account).
   - Provides a **Zrušit / Cancel** action (`Key('wiz:cancel_add')`) on the first shown step (and in header if resumed after app restart) that calls `cancelAddAccount()`: deletes the provisional account dir + key, removes `<newId>` from `accounts.json`, and switches back to `addingAccountReturnId` (or first remaining account).
   - Never overwrites `global.json` (`theme`, `language`, `tutorials_done`, `disclaimer_accepted`, `run_in_background`, `gemini_api_key`).
   - On Finish: derives the new account's `label` from `your_signature` → `bakalari_username` → `"Účet N"`, leaves `primary_id` unchanged, offers the `'accounts'` tutorial tour, and starts the new account's first refresh (`finishWizardRefresh()`).

### 10.4 Interactive Tutorials (PLAN §2 rule 7 / CONTRIBUTING §5)

- **New tour `'accounts'`** in `app/lib/tutorial/tours.dart` (`route: null`, offered automatically by `AppScaffold` / `wizardFinished` once `accounts.length > 1` and `'accounts'` is not in `tutorials_done`):
  - Step 1 (`acc_switch`, `anchor: 'account_switcher'`, `place: TourPlace.topLeft`, `icon: Icons.switch_account_outlined`): explains switching accounts from the top bar, that each account keeps its own data and automation rules, and that primary account + per-account background refresh are configured in Settings → Accounts.
- **Updated `'settings'` tour:** append one short sentence to `tut_settings_intro_body` (cs & en) mentioning that you can add and manage multiple accounts under *Účty* / *Accounts*.
- Update `tools/demo_data.py` `TOURS_DONE` to include `"accounts"` alongside the other non-default tours.

### 10.5 Localization (`app_cs.arb`, `app_en.arb`, `strings.dart` — cs & en)

All new UI strings (~28 keys: `accounts_manage_title`, `account_add`, `account_default_label`, `account_numbered_label`, `account_active_badge`, `account_primary_badge`, `account_set_primary`, `account_rename`, `account_rename_hint`, `account_delete`, `account_delete_title`, `account_delete_body`, `account_delete_confirm`, `account_deleted`, `account_switch_busy`, `account_delete_busy`, `account_bg_refresh`, `account_bg_refresh_hint`, `account_bg_off_tag`, `account_manage_btn`, `account_credentials_for`, `settings_scope_account`, `settings_scope_shared`, `settings_interval_shared_hint`, `alarm_primary_account_note`, `wiz_cancel_add`, `tut_acc_switch_title`, `tut_acc_switch_body`) added to `app_cs.arb`, `app_en.arb`, and `strings.dart`, verified by `strings_table_parity_test.dart`.

---

## 11. Implementation & Verification Plan

### 11.1 Planned commits (one focused unit per commit, every commit green)

1. **`F4: add background_refresh config key and multi-account storage core`**
   - `background_refresh` in `config.example.json`, `config.dart`, `config_test.dart`, and `parity/helpers.json` `roundTripFiles` (PLAN rule 4).
   - `packages/strakalari_core/lib/src/storage/accounts.dart`: `globalConfigKeys`, `AccountInfo`, `AccountRegistry`, `AccountManager`, `ensureMultiAccountLayout` (copy, SHA-256 + JSON + `decryptStrict` verify, never delete originals, degrade safely on failure), `createAccount`, `renameAccount`, `setActiveAccount`, `setPrimaryAccount`, `deleteAccount` (commit registry first, `forgetKey`, contained delete), `forgetAllKeys`.
   - Scoped `dataDir` / `fallbackKeyDir` support in `helpers.dart`, `config.dart`, `cache.dart`, `audit.dart`, `automation.dart`, `refresh.dart`, `strava/client.dart`, and `notifyForAccount` in `notifier.dart`.
   - Comprehensive core unit tests (`accounts_test.dart`, extended `config_test.dart`, `secret_store_test.dart`, `notifier_test.dart`).
2. **`F4: upgrade Android Keystore, startup, and AppState for multiple accounts`**
   - Multi-key `WarmedAndroidKeystore` + `warmAndroidKeystoreAll` (`android_keystore.dart`).
   - Startup migration & `--forget-secrets` (`startup.dart`), headless migration + multi-key warm + sequential multi-account refresh + primary-account status/widget/alarm sync (`background.dart`, `scheduler_jobs.dart`, `android_notifications.dart`).
   - `AppState` multi-account lifecycle (`app_state.dart`, `activity.dart`, `excuses.dart`, `lunches.dart`, `planner.dart`): `AccountManager` integration, `switchAccount`, `beginAddAccount`, `cancelAddAccount`, `renameAccount`, `setPrimaryAccount`, `deleteAccount`, `setAccountBackgroundRefresh`, per-account `runsByAccount`/`logLinesByAccount`, sequential multi-account `scheduledRefreshJob`, primary-account `backgroundStatusInputs`/`syncAndroidState`, `?account=` routing in `applyLaunchRoute`.
   - App unit tests (`app_state_accounts_test.dart`, extended `android_background_test.dart`, `android_keystore_test.dart`, `android_phone_background_test.dart`).
3. **`F4: add account switcher, Settings accounts manager, add-account wizard, and tutorial`**
   - Account Switcher pill + sheet/dialog (`scaffold.dart`, `more.dart`, new `widgets/account_switcher.dart`).
   - Settings → Účty manager card, per-account `background_refresh` switch in Účty & Pravidla, scope captions, primary-account alarm banner, delete confirmation dialog (`settings_controller.dart`, `settings_live.dart`, `settings_view.dart`).
   - Add-account wizard mode + Cancel cleanup (`wizard_controller.dart`, `wizard_live.dart`, `wizard_view.dart`).
   - `'accounts'` tutorial tour + `tut_settings_intro_body` update + `demo_data.py` `TOURS_DONE` (`tours.dart`, ARBs, `strings.dart`).
   - Widget & live tests (`accounts_ui_test.dart`, extended `settings_sections_test.dart`, `wizard_live_test.dart`, `tutorial_test.dart`, `mobile_narrow_shell_test.dart`).

### 11.2 Verification checklist (before ⛔ R6 handover)

- `dart pub get --enforce-lockfile`; `dart analyze && dart test` in `packages/strakalari_core`; `flutter analyze && flutter test` in `app` — zero warnings, zero regressions, zero weakened/skipped tests.
- Visual evidence in `build/qa-evidence/F4/` at **390 px and 1280 px**, **cs and en**, **light and dark** (demo data only): TopBar switcher pill, Switcher sheet/dialog, Settings → Účty (2 accounts), Delete confirmation dialog, Settings → Pravidla (`background_refresh`), Více page (390 px), Settings → Budík non-primary banner, Add-account wizard step with Cancel.
- Pixel 7 Pro (`2C221FDH3002NZ`, `io.github.dendlerx.strakalari.test` ONLY — never the Play app) against local `bakalari_demo_server.py`:
  1. Upgrade migration test from a pre-F4 flat layout in `.test` (verify legacy root files untouched, `accounts/default/` verified, Keystore unwrap succeeds without re-entering password).
  2. Add 2nd account via wizard, verify switching, rename, set primary, toggle per-account `background_refresh`, and delete with confirmation.
  3. Verify `KeepAliveService` status notification shows primary account label + data, and event notification tap for non-active account switches to that account and opens the matching tab (O8).
- macOS and iOS native builds remain marked *unverified* on Windows 11.

---

## 12. Resolved Owner Choices (2026-11-20)

1. **Q1 (`notifications` scope) — confirmed:** Keep the 13 event notification toggles (`notifications`) shared in `global.json`, while per-account background refresh is toggled individually via `background_refresh`.
2. **Q2 (shared `gemini_api_key`) — confirmed:** Keep `gemini_api_key` + `gemini_model` shared in `global.json`, while `gemini_prompt`, `gemini_auto_enabled`, and `gemini_interval_days` stay per-account.
3. **Q3 (desktop tray *Obnovit data* & *Pozastavit*) — decided:** Tray *Obnovit data* refreshes all `background_refresh`-enabled accounts sequentially; tray *Pozastavit automatizaci* toggles `automation_paused` on the active account and includes the active account's label when `accounts.length > 1` (never silently unpausing another child's account).
