# Moving Strakaláři to Flutter (Dart): decision and migration plan

Status: **plan only, nothing built yet.** Written 2026-11-07 against `main` @
`d3b303f` (Flet 0.86.5).

This replaces the "Flutter/Dart rewrite: rejected" row of
`strakalari_MOBILE_PLAN.md`. That rejection was about running **two** scrapers
(Python on the desktop, Dart on the phone). This plan moves **everything**, so
there is still exactly one scraper, one send path and one test suite.

---

## 1. Decision

**Winner: Flutter + Dart for every platform**: Windows, macOS, Linux and Android
now, with iOS and the web possible later. One codebase.

### Options compared

| | Stay on Flet (Python) | **Flutter (Dart)** | Kotlin Multiplatform + Compose | React Native (Expo) | Tauri v2 (Rust + web UI) |
|---|---|---|---|---|---|
| All 4 current targets from one UI | yes | **yes** | yes, but desktop runs on the JVM | no Linux, weak desktop | yes |
| Deep Android (background, alarms, widget) | poor: no headless start | **good**: headless Dart, plugins | best | good | weakest |
| iOS later | effectively no background | **yes** | yes | yes | young |
| Web later | server-side only | **yes** (with a relay, see below) | its least mature target | yes | yes |
| Common / AI knows it well | niche, API changed a lot | **very common** | growing | very common | niche |
| Performance, app size | CPython in every build | **native AOT** | JVM on desktop | JS runtime | small |
| Migration cost from today | none | **lowest of the rewrites**: Flet *is* Flutter | full UI rewrite | full rewrite | full rewrite |

### Why not stay on Flet

The repository already shows the cost of running Python inside Flutter. Each
item below exists only because of that:

- `core/android.py`: a wrong pyjnius call aborts the whole process with no
  Python error, and the app's own Java classes can't be loaded from Python threads.
- `KeepAliveService` is `START_NOT_STICKY` because nothing can start Python
  headless. So after a reboot, an update or a kill, the README has to say *"open
  it once"*, and the foreground service exists mainly to keep the whole process
  alive for a timer.
- `core/tls.py`: Android purges the extracted CA bundle while the process lives.
- `flet_ui/state.py` `ensure_page_executor`: works around Flet shutting down a
  shared thread pool on reconnect.
- `tools/make_mobile.py` (path scrubbing via `sitecustomize`),
  `rthook_frozen_builtins.py`, `strakalari.spec`, and the
  flet/flet-desktop/flet-web lockstep.
- `flet_ui/macos.py`: on macOS the tray has to be the window's parent process.
- Size: the arm64 APK is 62.5 MB, the AAB 107 MB and the MSIX 70 MB, mostly
  CPython plus the stdlib on top of Flutter.
- Flet is a small project whose API changed heavily between versions, so AI
  models write it less reliably than plain Flutter.

### Why Flutter wins

1. **Flet is Flutter.** `ft.Container`, `Row`, `Column`, `NavigationRail`,
   `NavigationBar`, `AlertDialog`… are the same Flutter widgets with nearly the
   same names and properties. Porting the UI is translation, not redesign. That
   makes it the cheapest, safest rewrite, and one a mid-tier model can do reliably.
2. **One toolchain for six targets**, production-grade on all four current ones.
3. **Dart**: static types, sound null safety and AOT-compiled native code. One
   language for core, UI and background work. Only the small Android system
   hooks stay in Java, and they are already written.
4. **Headless background on Android**: a receiver can start Dart without a
   screen. That means refreshes continue after a reboot or a kill, without
   keeping a process alive for a timer.
5. **Common**: Flutter is one of the two most-used cross-platform frameworks,
   with mature packages for everything this app needs (§3.3).
6. **Modular**: Dart pub workspaces. A pure-Dart core package (no Flutter
   import) runs in the app, in a background isolate, in tests, in a CLI and on a
   server later. The Flutter app on top only does UI and platform work.

**Runner-up: Kotlin Multiplatform.** It has the best Android story, but the
desktop app is a JVM app (bundled Java runtime, slower start, more memory),
Gradle is complex, there is no ready MSIX or AppImage path, web is its least
mature target, and the UI would be a full rewrite. It would only be
the right pick if Android were the only platform.

### What Flutter does *not* solve (true for every option)

- **Web:** a browser can't talk to Bakaláři or Strava directly (CORS, cookies).
  A web version needs a relay server, and a hosted one would see students'
  passwords, which conflicts with `PRIVACY.md`. That is a product decision for
  later. The plan keeps the door open: the core is pure Dart, so it can run on
  such a server unchanged.
- **The home-screen widget and the ongoing notification's layout** stay native
  Android (`RemoteViews`). The existing Java is reused.
- **iOS background work** stays limited by iOS itself.

---

## 2. Ground rules (binding for whoever does the migration)

1. **Parity, not redesign.** Port what the Python app does, quirks included.
   No new features, no UX changes, no "while I'm here" improvements. Write any
   doubt under *Questions* in `STATUS.md` instead of guessing.
2. **Same files, same places, same formats.** An update from the Python app must
   keep settings, passwords and history with **no migration step**:
   - The data folder is resolved exactly like `core.helpers.get_user_data_dir`,
     including `STRAKALARI_DATA_DIR`. On the phone it's
     `getApplicationSupportDirectory()/data` (what Flet sets as
     `FLET_APP_STORAGE_DATA`).
   - Every file name and format stays the same: `config.json` (canonical keys,
     `config.example.json`), `data_cache.json`, `already_excused_lessons.json`,
     `already_excused_lessons.unconfirmed.json`, `automation_history.jsonl`,
     planned skips, `strava_blacklist.json`, `school_presets/*.json`,
     `update_cache.json`, `log.txt` and `instance.token`.
   - The same Fernet key in the same place: OS credential store, service
     `Strakalari`, entry `fernet-key:<first 16 hex of sha256(normcase(abspath(data_dir)))>`;
     the `secret.key` fallback; on Android the Keystore alias
     `strakalari-secret-key` (AES/GCM/NoPadding, 12-byte IV prefix,
     `core/android.py`). Python's `keyring` package defines the store layout.
     Read its backends in `.venv/Lib/site-packages/keyring/backends/` and
     replicate them exactly.
   - The same app identity: Android `applicationId io.github.dendlerx.strakalari`
     and the same release key (`~/.strakalari-signing/`, **never regenerate**),
     Inno Setup `AppId {D94B0B7F-65C1-4D52-9A47-E30D6E26F22B}`, the MSIX identity
     (`docs/STORE.md`, `tools/make_msix.py`) and the macOS bundle id. The new app
     then installs as an update.
3. **The safety rules in `CONTRIBUTING.md` §5 carry over word for word:**
   - **One pipeline:** `runRefresh`.
   - **One session at a time:** the same `session.lock` file and locking
     method, so a Python and a Dart app on one PC still exclude each other.
   - **One send path:** a history coverage check, with the lock held across
     check, submit and write. Navigation clicks are `once` and never retried. An
     unconfirmed send blocks re-sends until the outbox settles it, and auto mode
     never sends when the outbox can't be read.
   - **Everything is recorded:** every attempt goes into the audit log.
   - `automation_paused` stops every auto phase.
   - **Fail loudly.**
4. **Tests come first.** Every Python test file gets a Dart counterpart with the
   same cases, ported before or together with the code it tests. A test may be
   dropped only when its subject doesn't exist in the Flutter app (PyInstaller,
   pyjnius quirks), and `STATUS.md` lists it with the reason.
5. **Never contact real Bakaláři or Strava, and never use real accounts.** Tests
   use fakes. Manual runs use `tools/bakalari_demo_server.py` and dry run. Never
   commit `htmls/`, `config.json` or any user data.
6. **Bakaláři web interface only.** Never the `/api/3` mobile API.
7. **Python stays on the branch as the reference** until phase 10. Don't edit it,
   except for the parity scripts in `tools/parity/` and merges from `main`.
8. **Locale-safe, cs + en.** No locale-dependent parsing, and no Czech text
   hardcoded in logic.
9. **Reproducible builds.** Pin the Flutter version, commit every `pubspec.lock`,
   and run CI with `--enforce-lockfile`.
10. **Small local commits** on `flutter-migration`, as the user's git identity,
    with no `Co-Authored-By` or `Claude-Session` lines. **Never push.**

---

## 3. Target architecture

### 3.1 Layout (final; Python files sit alongside until phase 10)

```
pubspec.yaml                  # Dart workspace root (workspace: [packages/strakalari_core, app])
analysis_options.yaml         # shared lints (package:lints recommended + strict-casts/inference/raw-types)
packages/strakalari_core/     # package:strakalari_core, PURE DART (must never import Flutter)
  lib/strakalari_core.dart    #   public API
  lib/src/
    bakalari/                 #   http_session, client, timetable, data, excuse, common, extractors
    strava/                   #   client, ordering
    automation/               #   automation, refresh, scheduler, excuse_history, audit, session lock
    planning/                 #   schedule, forecast, planner, planned_skips, grades, matching
    lunches/                  #   lunch_auto, lunch_cutoff, gemini
    storage/                  #   data_dir, config (+validation), cache, secret_store (+Fernet), atomic writes, file locks
    platform/                 #   abstract interfaces the app implements: Notifier, KeyStore, AndroidBridge, …
    status_notification.dart, wakeup.dart, news.dart, update.dart, error_report.dart, i18n.dart, models/
  bin/parity_fetch.dart       #   dev CLI: log in to the demo server and dump everything as JSON
  test/                       #   one *_test.dart per Python test file; test/parity/*.json from Python
app/                          # the Flutter app (package:strakalari)
  lib/
    main.dart                 #   UI entry; also `@pragma('vm:entry-point') backgroundMain()`
    shell/                    #   router (go_router), adaptive scaffold (rail ↔ bottom bar at 720 px), theme tokens
    features/<screen>/        #   today, timetable, absences, marks, planner, lunches, activity, settings, wizard
                              #   each: <screen>_view.dart + <screen>_controller.dart (Riverpod Notifier)
    widgets/                  #   shared components (port of flet_ui/components.py, overlays.py)
    tutorial/                 #   port of flet_ui/tutorial.py
    platform/                 #   desktop (tray, window, autostart, single instance), android (MethodChannel), notifications, key store
    l10n/app_cs.arb, app_en.arb
  android/ windows/ macos/ linux/   # runners; existing Java moves to android/app/src/main/java/io/github/dendlerx/strakalari/android/
  test/                       #   widget tests (port of test_ui_views.py etc.)
tools/                        # parity/ (Python oracle scripts), demo data, release helpers
```

### 3.2 Python → Dart map

| Python | Goes to |
|---|---|
| `strakalari/core/*` (everything except below) | `packages/strakalari_core/lib/src/…` (same names, snake_case files) |
| `core/android.py` (pyjnius) | Dart: `core/platform/android_bridge.dart` (interface) + `app/lib/platform/android/` (MethodChannel `strakalari/android`, the same operations as the functions in `android.py`). Java: the existing classes plus one `StrakalariChannel` handler |
| `core/notify.py`, `secret_store` OS parts, `autostart.py`, `packaging.py` | an interface in core + an implementation in `app/lib/platform/` |
| `core/tls.py` | dropped (Dart uses the OS trust store) and listed in STATUS.md |
| `flet_ui/state*.py` (AppState + mixins) | one Riverpod `Notifier` per mixin under `features/*/…_controller.dart`, plus an `appStateProvider` for the shared parts |
| `flet_ui/views/**`, `components.py`, `overlays.py`, `theme.py`, `tutorial.py` | `app/lib/features/**`, `widgets/`, `shell/theme.dart`, `tutorial/` |
| `flet_ui/strings.py` (cs + en, `MOBILE_STRINGS`) | ARB files + `gen-l10n`; convert with a one-off script, keeping the keys. Core-side texts (`core/i18n.py`) stay a Dart map in core, because background code has no `BuildContext` |
| `flet_ui/tray.py`, `macos.py`, `single_instance.py` | `app/lib/platform/desktop/`: **one process** (the window hides to the tray); single instance keeps the existing loopback-TCP design, ported |
| `strakalari.spec`, `rthook_frozen_builtins.py`, `tools/make_mobile.py`, `mobile/strakalari_android` | dropped at the switch (the Java moves, see above) |
| `installer.iss`, `tools/make_msix.py`, `.github/workflows/*.yml` | adapted to the Flutter build outputs |
| `tests/test_*.py` | `packages/strakalari_core/test/*_test.dart` or `app/test/*_test.dart` |

### 3.3 Libraries (well-known; pin exact versions via the lockfile)

- **Core:**
  - `http` for requests; its `MockClient` replaces the Python fakes in tests.
  - `cookie_jar` for cookies.
  - `html` for the places that use `html.parser`.
  - `crypto` (HMAC-SHA256) + `pointycastle` (AES-128-CBC) for Fernet, about
    60 lines. Verify it against tokens Python made.
  - `clock` for testable "now": write `clock.now()`, never `DateTime.now()`;
    tests wrap in `withClock`.
  - `path`, `test`.
  - **No code generation (no build_runner):** write `fromJson`, `toJson` and
    `copyWith` by hand.
- **App:**
  - `flutter_riverpod` (state, no codegen), `go_router`, `flutter_localizations`
    + `intl`.
  - `flutter_local_notifications` (all platforms).
  - Desktop: `window_manager`, `tray_manager`, `launch_at_startup`.
  - `url_launcher`, `share_plus` (Share log on the phone), `path_provider` (only
    where Python used the same OS directories).
  - `win32` (Credential Manager), and `msix` as a dev dependency.
- **Android:** the existing Java classes, one MethodChannel, and a headless
  Dart entry point (§3.4). No extra background plugin unless the native route
  fails.

### 3.4 Background work

- **Desktop:** one process. Closing the window hides it to the tray (where the
  user enabled that), and autostart launches with `--minimized`. The Python
  `PeriodicRunner` becomes a Dart `Timer`-based scheduler in core. The visible
  behavior per OS matches today (read `tray.py`, `macos.py`, `autostart.py`).
- **Android:**
  - `WakeReceiver` (an exact alarm when a refresh is due) starts a **headless
    FlutterEngine** running `backgroundMain()`. That runs one `runRefresh`,
    updates the status notification and widget through the channel, re-arms the
    next wake, and exits.
  - `BootReceiver` re-arms the wake instead of only reminding the user. This is
    the one intended behavior change: the README line *"open it once"* goes away.
  - `KeepAliveService` stays as long as the always-visible overview notification
    is wanted. It no longer has to keep Dart alive.
  - **Pitfall:** a file lock doesn't separate two isolates in **one** process
    (POSIX locks are per process). If the UI isolate is alive (registered in
    `IsolateNameServer`), the background entry hands the job to it; only when no
    UI isolate exists does it run the refresh itself.

### 3.5 Porting pitfalls (Python → Dart)

- **Regex:** `(?P<name>…)` becomes `(?<name>…)`. There are no inline flags like
  `(?i)` or `(?s)`: use `caseSensitive: false` and `dotAll: true`. `re.match`
  anchors at the start, `firstMatch` doesn't. `\Z` doesn't exist (use `$`
  without `multiLine`). `re.VERBOSE` doesn't exist.
- **Redirects:** `dart:io` follows redirects for GET/HEAD only. WebForms posts
  answer 302, so follow them by hand in the HTTP session the way httpx does
  (302/303 → GET), storing cookies at every hop.
- **Text and numbers:** Python `str` indexes code points, Dart `String` indexes
  UTF-16 units (watch slicing around emoji). Integer `//` and `%` on negatives
  differ: Python floors, while Dart `~/` truncates and `%` is Euclidean. Python
  `round()` rounds half to even, Dart's rounds half away from zero, so grade
  averages must match exactly (use the parity fixtures).
- **JSON:** `json.dumps` defaults (`ensure_ascii=True`, key order,
  `indent`/`separators`) matter for files that are compared or hashed. Match what
  each writer in Python does.
- **Dates:** keep naive local datetimes where Python does. The weekday is
  Monday=1 in Dart but `weekday()` gives Monday=0 in Python. Parse `D.M.YYYY`
  by hand, never with a locale.
- **Atomic writes and locks:** port `helpers` exactly (temp file + rename,
  `InterProcessLock`). On Windows, Python uses `msvcrt.locking`. Use a lock that
  conflicts with it (`RandomAccessFile.lock` uses `LockFileEx` on the same byte
  range), and prove it with a cross test: Python holds the lock, Dart must fail
  to take it.

---

## 4. Phases

Each phase ends with `dart analyze` / `flutter analyze` clean, every test
passing, and `STATUS.md` updated. At ⛔ checkpoints the migrating model
**stops** and a capable model reviews before work goes on.

| # | Phase | Done when |
|---|---|---|
| 0 | **Setup.** Create the worktree and branch, then the Dart workspace skeleton (`pubspec.yaml`, `analysis_options.yaml`, `packages/strakalari_core`, `app` via `flutter create --platforms=windows,macos,linux,android --org io.github.dendlerx`, with `applicationId` fixed to `io.github.dendlerx.strakalari`). Create `STATUS.md` (template in §6) with a row for every Python module and test file (`git ls-files strakalari tests`). Add a separate CI workflow `dart.yml` (analyze + test on ubuntu + windows). It first runs when the owner pushes, so run the same commands locally. Don't change the Python CI. Pin Flutter **3.44.8**, the SDK already on this PC. | Both packages build, one trivial test passes, and the STATUS rows exist |
| 1 | **Core foundation:** models, helpers (data dir, atomic write, locks, log with redaction), config (+ validation, same keys), cache, i18n, audit, excuse_history, Fernet + secret_store (the file fallback, plus a `KeyStore` interface for the OS stores). Add `tools/parity/dump.py` (Python): runs pure functions on input cases and writes the expected outputs to `packages/strakalari_core/test/parity/*.json`. | Ported tests pass. Dart reads a `config.json`, cache, history and `secret.key` written by Python, decrypts a Python Fernet token, and writes files Python reads back byte-identically |
| 2 | **Clients:** Bakaláři (http session with WebForms/DevExpress callbacks, extractors, timetable, data, excuse) and Strava (client, ordering). | Ported tests pass with `MockClient` + `tests/fixtures`. `bin/parity_fetch.dart` and an equivalent Python call against `tools/bakalari_demo_server.py` give identical JSON |
| 3 | **Domain logic:** schedule, forecast, planner, planned_skips, grades, matching, lunch_auto, lunch_cutoff, school_presets, news, gemini, update, status_notification, wakeup, notify (interface). | Ported tests pass, and the parity JSON matches for every pure function with cases in `dump.py` |
| 4 | **Automation:** automation, refresh pipeline, scheduler, session lock, error_report. Port `test_automation_safety`, `test_data_safety`, `test_excuse_history`, `test_session_lock`, `test_order_latch` and `test_refresh_*` **first and literally**. | A dry-run refresh against the demo server gives the same audit entries and outbox as Python. ⛔ **Checkpoint A: core review** |
| 5 | **App shell:** theme tokens, ARB strings (generated from `strings.py` by a script), go_router, the adaptive scaffold (720 px breakpoint, rail ↔ bottom bar + *More*, landscape phone → rail), controllers replacing AppState, shared widgets, error dialogs with *Copy log*. | The app starts on Windows on a demo data dir (`tools/demo_data.py generate DIR`, `STRAKALARI_DATA_DIR=DIR`) and navigates every screen (placeholders allowed) |
| 6 | **Screens**, one commit each: wizard, today, timetable (table + list, phone grid scrolling sideways), absences, marks, planner, lunches, activity (+ live log), settings (every section), overlays, tutorials (every `Tour`). | Ported widget tests pass. Screenshots of every screen (cs/en, light/dark, 1280 px and 390 px) from the Flet build (`tools/demo_data.py screenshots --out build/parity-screens/flet`; never the default `--out`, which overwrites the README images) and the Flutter build sit side by side under `build/parity-screens/` (not committed). ⛔ **Checkpoint B: UI review** |
| 7 | **Desktop platform:** tray + hide-to-tray, autostart (registry/login item/.desktop, MSIX StartupTask), single instance, notifications, update check (GitHub releases, the same channels), the OS key stores reading the Python keyring entries (Windows `CredRead` via `win32`, a small Swift channel for the macOS Keychain, libsecret for Linux; if reading fails, the wizard asks for passwords again, which is the documented fallback), then packaging: Inno Setup (same AppId), MSIX (same identity), macOS `.dmg`, Linux AppImage, and the CI release jobs. This PC can only build Windows (Linux maybe through WSL), so the macOS and Linux parts are written but stay *unverified* in STATUS.md until the owner runs CI. | On Windows, installing the Flutter build **over** an installed Python build keeps settings, passwords and history; the Store MSIX likewise (local sideload test) |
| 8 | **Android platform:** move the Java classes in unchanged, replace pyjnius with the MethodChannel, add the headless `backgroundMain` (§3.4), re-arm on boot, wire up the widget, alarms, status notification, permissions and Keystore unwrap, sign with the same key, and port the privacy check of `test_packaging_privacy.py` to the APK/AAB. | On the test phone, the `.test` package built with Flutter installs **over** the Flet `.test` build and keeps data and passwords, and a background refresh still runs after a reboot without opening the app. ⛔ **Checkpoint C: platform review** |
| 9 | **Parity soak:** run both builds side by side on demo data and dry run for several days. Fix differences, merge `main` and port its Python changes, update the docs (README, CONTRIBUTING, PRIVACY wording), and cut a beta release from the branch (only when the owner says so). | No open parity differences. ⛔ **Checkpoint D: release review** |
| 10 | **Switch:** remove the Python app, Flet, PyInstaller, `mobile/strakalari_android` and the Python CI, and make `dart.yml` the only CI. Merge into `main` (done by the owner/reviewer). | `main` builds and releases from Flutter only |

**After the switch, not part of this plan:** iOS (WidgetKit, background
limits), the web version (needs the relay/privacy decision), Java → Kotlin
(optional).

**Size, for planning:** about 15.6k lines of core, 18.5k of UI, 18k of tests
and 2k of Java (moved, not rewritten). Expect phases 1–4 and 5–6 to be the long
ones, each spanning many sessions.

**While the migration runs:** keep `main` to fixes only if possible. Every
feature added to the Python app in the meantime has to be ported too. Merge
`main` into the branch at the start of each phase and port the Python diff.
`STATUS.md` records the last `main` commit that was ported.

---

## 5. Risks and how the plan handles them

| Risk | Handling |
|---|---|
| A regression in the send path sends a wrong excuse (it can't be undone) | Safety tests are ported first and literally, the dry-run parity uses the demo server, no real accounts, and Checkpoint A reviews this code line by line |
| Users lose passwords on update | Same key, same store, same entry name (rule 2), cross tests, and real over-install tests in phases 7 and 8. The fallback is a wizard re-prompt, never data loss |
| Automation runs twice (old and new app at the same time) | The same `session.lock` and file formats, so the two apps exclude each other and both see the same history |
| Subtle math or parsing differences | Parity JSON from Python for every pure function, plus the §3.5 pitfalls |
| The cheaper model drifts or "improves" things | Rule 1, the per-file STATUS rows, small commits and four checkpoints |
| Python changes on `main` meanwhile | Merge and port at every phase start, with the last ported commit in STATUS.md |

---

## 6. `STATUS.md` template (created in phase 0, updated after every step)

```markdown
# Flutter migration status
Branch: flutter-migration · Flutter: <version> · Last main commit ported: <sha>
Current phase: <n> · Next step: <one line>

## Modules
| Python file | Dart file | Tests (py → dart) | State |
|---|---|---|---|
| strakalari/core/grades.py | packages/strakalari_core/lib/src/planning/grades.dart | test_grades.py N → grades_test.dart N | todo / tests / done |

## Dropped (with reason)
## Deviations from Python (each needs reviewer sign-off)
## Questions for the owner / reviewer
## Checkpoint notes
```
