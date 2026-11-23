# Contributing to Strakaláři

Thanks for wanting to help! This guide covers local development, testing, building installers, and the rules that keep the project healthy.

End-user documentation lives in [README.md](README.md) / [README.en.md](README.en.md) — this file is for developers only.

---

## 1. Prerequisites

- **Flutter 3.44.8** (Dart **3.12.2** — pinned; do not run `flutter upgrade`).
- **Git**.
- **Desktop / Android toolchains** for the targets you build locally:
  - Windows: Visual Studio with the Desktop development with C++ workload (and Inno Setup 6 for `installer.iss`).
  - Android: JDK 17 and the Android SDK.
  - Linux / macOS: standard Flutter Linux (`clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libayatana-appindicator3-dev`, `libsecret-tools`) or Xcode.
- **Python 3** (stdlib only — optional) to run the local demo tools (`tools/demo_data.py`, `tools/bakalari_demo_server.py`) and Windows MSIX packaging (`tools/make_msix.py`, `tools/store_submit.py`). Only `tools/render_icon.py` (regenerating the icon files) needs extra packages: `pip install playwright pillow`.

## 2. Local setup

```bash
git clone https://github.com/DeNdlerX/strakalari.git
cd strakalari
dart pub get --enforce-lockfile
```

The repository uses a Dart pub workspace (`pubspec.yaml` at the repo root linking `packages/strakalari_core` and `app`). Always resolve dependencies with `--enforce-lockfile` so builds match the committed `pubspec.lock`.

Never commit a real `config.json` or data folder — `config.json` holds credentials. Use `tools/demo_data.py` in a throwaway directory outside the repository for local testing.

## 3. Running from source

Generate synthetic demo data in a throwaway directory and start the local demo Bakaláři server (never use real school servers or accounts during development):

```bash
python tools/demo_data.py generate <THROW_AWAY_DIR>
python tools/bakalari_demo_server.py --port 8080 --user demo --password demo
```

Then run the Flutter app pointed at that directory:

```bash
cd app
STRAKALARI_DATA_DIR=<THROW_AWAY_DIR> flutter run -d windows
STRAKALARI_DATA_DIR=<THROW_AWAY_DIR> flutter run -d windows -- --minimized   # start hidden in the tray
```

Without credentials the setup wizard can be skipped ("Skip for now"); screens stay empty until real data is cached.

### Configuration and data files

Users configure everything on the **Settings** screen; the files below are for development and debugging.

- `config.json` — settings. `config.example.json` is the canonical key reference. `strava_blacklist.json` holds forbidden lunch ingredients.
- `data_cache.json` — the downloaded timetable, absences, marks, and menu.
- `already_excused_lessons.json`, `already_excused_lessons.unconfirmed.json`, `automation_history.jsonl` — sent excuses, unconfirmed submits awaiting outbox settlement, and the Activity audit log.
- `log.txt`, `console.log` — the app log and captured stdout/stderr/warnings of windowed builds (`app/lib/platform/desktop/console_log.dart`).
- `school_presets/*.json` — user-added school calendars (see [docs/SCHOOL_PRESETS.md](docs/SCHOOL_PRESETS.md)).

Where they live (`getUserDataDir` in `packages/strakalari_core/lib/src/storage/helpers.dart`): next to the executable when that folder is writable (the classic Windows installer puts it in `%LOCALAPPDATA%\Programs\Strakalari`), otherwise `%LOCALAPPDATA%\Strakalari` (including the Microsoft Store package's virtualized `LocalCache\Local\Strakalari`), `~/Library/Application Support/Strakalari` (macOS, always), `~/.config/strakalari` (Linux), or `getApplicationSupportDirectory()/data` (Android). `STRAKALARI_DATA_DIR` overrides all of them.

Passwords and the Gemini API key are encrypted with Fernet; the key lives in the OS credential store (`DesktopKeyStore` in `app/lib/platform/desktop/keystore_desktop.dart` for Windows Credential Manager, macOS Keychain, and Linux Secret Service, or wrapped with the Android Keystore alias `strakalari-secret-key` via `AndroidChannel`), falling back to `secret.key` when no store is available (`secret_store.dart`). The in-app "Copy log" action scrubs passwords, usernames, API keys, and the signature (`redactText` in `packages/strakalari_core/lib/src/error_report.dart`); raw files on disk are not scrubbed.

## 4. Tests

```bash
cd packages/strakalari_core && dart analyze && dart test   # pure-Dart core (includes parity vector tests)
cd app && flutter analyze && flutter test                # Flutter app & platform tests
```

- CI runs analysis, core/app tests, and release builds in `.github/workflows/dart.yml` (plus `dart-macos-locks` for Apple Silicon `flock` verification on manual dispatch and release tags).
- CI minutes are limited — **always run the checks locally and make them pass before pushing**. Don't use CI as your test runner.
- Committed parity test vectors live in `packages/strakalari_core/test/parity/*.json` and are verified automatically by `parity_*_test.dart`.
- Add tests alongside every bug fix or behavior change (`packages/strakalari_core/test/*_test.dart`, `app/test/*_test.dart`).

## 5. Project layout

```
pubspec.yaml                         # Dart workspace root (packages/strakalari_core, app)
analysis_options.yaml                # shared lints (package:lints + strict casts/inference/raw-types)
packages/strakalari_core/            # pure Dart core (must never import Flutter)
  lib/src/
    bakalari/                        #   http_session, client, timetable, data, excuse, common, extractors
    strava/                          #   client, ordering, extractors
    automation/                      #   automation, refresh, scheduler, excuse_history, audit, session_lock, cancel
    planning/                        #   schedule, forecast, planner, planned_skips, grades, matching, school_presets
    lunches/                         #   lunch_auto, lunch_cutoff, gemini
    storage/                         #   config, cache, helpers, fernet, secret_store
    platform/                        #   abstract interfaces (AndroidBridge, KeyStore, Notifier, packaging, build_number)
    models.dart, i18n.dart, error_report.dart, news.dart, update.dart, wakeup.dart, status_notification.dart
  test/                              # unit + parity tests (+ test/parity/*.json fixtures)
app/                                 # Flutter UI & platform implementations (package:app)
  lib/
    main.dart                        #   UI entry + @pragma('vm:entry-point') backgroundMain()
    shell/                           #   router (go_router), adaptive scaffold (720/520 breakpoints), theme tokens
    controllers/                     #   Riverpod AppState + feature facades (excuses, lunches, marks, planner, …)
    features/<screen>/               #   today, timetable, absences, marks, planner, lunches, activity, settings, wizard, more
    widgets/, tutorial/              #   shared widgets, overlays, error dialogs, interactive tutorial tours
    platform/                        #   desktop (tray, autostart, single_instance, console_log, keystore, store_package),
                                     #   android (MethodChannel, keystore, backgroundMain, notifications), startup
    l10n/                            #   app_cs.arb, app_en.arb, strings.dart
  android/ windows/ macos/ linux/    # platform runners (+ Android Java classes under io/github/dendlerx/strakalari/android/)
  test/                              # widget & platform unit tests
tools/                               # demo_data.py, bakalari_demo_server.py, make_msix.py, store_submit.py, render_icon.py, parity/capture_screens.dart
docs/                                # BAKALARI_API.md, STRAVA_API.md, SCHOOL_PRESETS.md, STORE.md, flutter-migration/
config.example.json                  # canonical config-key reference (keep in sync with config.dart!)
installer.iss                        # Inno Setup script (Windows installer)
```

These rules keep the automation safe:

- **One pipeline.** Anything that refreshes data or runs auto modes goes through `runRefresh` (`packages/strakalari_core/lib/src/automation/refresh.dart`) — never a second copy in the UI, tray, or background entry.
- **One session at a time.** Desktop runs as one process: closing the window hides it to the tray (when `minimize_to_tray` is enabled; `--minimized` starts hidden), and a second launch wakes the existing window over `SingleInstance` loopback TCP (`app/lib/platform/desktop/single_instance.dart`). Whole refreshes and order submits run under `withSessionLock` / `withSessionLockAsync` (`session.lock`, OS file lock); a caller that cannot acquire it skips with a visible message instead of running in parallel. On Android, `backgroundMain` checks `IsolateNameServer` and hands off to the live UI isolate if one is active before falling back to running headless.
- **One send path.** Excuses are sent only via `Strakalari.sendExcuse` (`packages/strakalari_core/lib/src/automation/automation.dart`), which checks `excuse_history.dart` for coverage and holds `HistoryLock` across check, submit, and write. Navigation-triggering clicks use `once: true` and are never retried. A submit the site never confirmed is `unconfirmed`, not `failed`: it goes to `already_excused_lessons.unconfirmed.json` and blocks every re-send until a successful Komens outbox read settles it — and auto mode never sends when the outbox could not be read.
- **Everything is recorded.** Every send/order attempt (manual or auto, success or failure) goes to `audit.dart` (`automation_history.jsonl`); `automation_paused` must stop every auto phase.
- **New feature, new tutorial.** Interactive tutorials live in `app/lib/tutorial/tours.dart`: add a `Tour` to `tours`, add its `tut_*` strings (cs + en) in `app/lib/l10n/`, call `tutorialOffer` in the view once the feature's content is on screen, wrap the controls it explains in `TutorialAnchor`, and fire `tutorialEvent` where the action succeeds if a step waits for it.
- **Fail loudly.** In send, order, and save code an exception is never swallowed silently: log it (`writeLog` / `app.log`), or `print('Warning: …')` where no logger exists (windowed Windows builds write stdout/stderr to `console.log` via `console_log.dart`). An auto phase that did not do its job is an `AutomationError` in `RefreshResult.errors`, which the UI and notifications surface. Silent `catch (_)` is fine only for optional probes (cosmetic UI state or non-critical reads); a wait or fallback a scraper deliberately carries on after logs one line via `debug(what, exc)` (`packages/strakalari_core/lib/src/bakalari/client.dart`). `writeLog` scrubs stored passwords and API keys before anything reaches `log.txt`.

## 6. Contribution guidelines

- **Match existing style and conventions.** Touch only what the task needs — no drive-by refactors, renames, or reformatting.
- **Config keys are canonical.** The keys in `config.example.json` are the only valid names — no aliases, no silent migration. If you add/remove/rename a key, update `config.example.json`, the validation in `packages/strakalari_core/lib/src/storage/config.dart`, and its tests in the same PR.
- **Dependencies are pinned via `pubspec.lock`.** Commit lockfile updates deliberately and always run `dart pub get --enforce-lockfile` plus the full test suites.
- **Keep it locale-safe.** Releases are QA-tested on an English-locale Windows machine — never assume a Czech locale: no locale-dependent date/number parsing, no hardcoded Czech strings in logic (UI text lives in `app/lib/l10n/app_cs.arb`, `app_en.arb`, and `strings.dart`; core background strings live in `packages/strakalari_core/lib/src/i18n.dart` with both `cs` and `en`), no console codepage assumptions.
- **Keep it end-user safe.** The installer is used by non-technical classmates: no scary dialogs, no unexplained failures, no data loss. Destructive/network actions default to confirmation (`confirm` modes).
- **Screenshots use synthetic data only.** README images live in `docs/images/` (`<screen>-cs.png` / `<screen>-en.png`, dark theme) and are captured from synthetic demo data (`tools/parity/capture_screens.dart` / `tools/demo_data.py`), never from a real account.
- **User docs stay non-technical.** README.md / README.en.md are for classmates who just download the installer; anything about source, config files, or internals belongs here.
- **GPLv3.** All contributions are under the project's GNU GPLv3 license.

## 7. Building installers locally

Verify packaging work locally rather than burning CI release runs. **Always run `flutter clean` inside `app/` before a local Windows release build** so stale plugin DLLs from earlier builds are not left behind in `app/build/windows/x64/runner/Release/` and swept into the installer.

- **Windows installer**:

  ```bash
  cd app
  flutter clean
  flutter build windows --release --build-name=<version> --build-number=<num> --dart-define=STRAKALARI_VERSION=<version>
  ```

  Then compile `installer.iss` with Inno Setup (`ISCC.exe /DMyAppVersion=<version> installer.iss`; local runs without `/DMyAppVersion` fall back to the version hardcoded in `installer.iss`).
- **Windows Microsoft Store (MSIX)**: pack the release bundle directory (plus app-local VC++ runtime DLLs) with `python tools/make_msix.py --app-dir <dir> --out Strakalari-<version>.msix --version <version> ...` (see `build-flutter-msix` in `.github/workflows/dart.yml` and [docs/STORE.md](docs/STORE.md)).
- **Linux**: AppImage packaging (including bundled `libayatana-appindicator3` and `secret-tool`) — see `build-flutter-linux` in `.github/workflows/dart.yml`.
- **macOS**: `.dmg` drag-and-drop bundle — see `build-flutter-macos` in `.github/workflows/dart.yml`.

After building, smoke-test the actual artifact (launch, wizard, one refresh against `tools/bakalari_demo_server.py`) before pushing.

### Phone app (Android; iOS later)

`packages/strakalari_core/tool/build_android.dart` stages only the required source files into a neutral staging folder outside your home directory and repo (so no personal file or machine path ends up in the APK/AAB), runs `flutter build` with `--split-per-abi` (for APKs) and `buildNumber(version)` as the `versionCode`, and runs `checkPackage` against the output:

```bash
cd packages/strakalari_core
dart run tool/build_android.dart apk --flavor prod --stage C:/strakalari-build
```

Use `--flavor phonetest` (`io.github.dendlerx.strakalari.test`) when testing on a real phone alongside an existing Play Store install (`prod` = `io.github.dendlerx.strakalari`).

- **Signing**: every release APK must carry the same release key, or Android refuses to update installed copies. `app/android/app/build.gradle.kts` reads `~/.strakalari-signing/android-release.properties` (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`) or the `STRAKALARI_SIGNING_*` environment variables and refuses a `prod` release build without them. CI signs using `ANDROID_KEYSTORE_B64` and `ANDROID_KEYSTORE_PASSWORD`. Keep a backup of the signing key folder outside this machine.
- **Distribution**: `apk` builds are for GitHub Releases and keep the in-app update check; `aab` (`appbundle`) builds are for Google Play, which owns updates (`mobileStore()` disables the GitHub check).
- **Layout** follows the page width, not the platform: below 720 px (`narrowMaxWidth` in `app/lib/shell/scaffold.dart`) the app switches to the phone layout (bottom bar + *More*, stacked panels).
- **Platform differences** go through `isMobile()` / `mobilePlatform()` in `packages/strakalari_core/lib/src/platform/packaging.dart`: data in the app's private storage, no tray/autostart/single-instance, Android Back walks up the screens (`ShellBackScope`). Phone-specific wording lives in `Strings.isMobile` overrides (`app/lib/l10n/strings.dart`).
- **Android system features** (notifications, foreground service, wake-up alarms, boot/update receivers, home-screen widget, Android Keystore key wrapping) live in Java under `app/android/app/src/main/java/io/github/dendlerx/strakalari/android/` and are wired to Dart over the `strakalari/android` MethodChannel (`StrakalariChannel` / `android_channel.dart`). Scheduled background refreshes run headlessly via `@pragma('vm:entry-point') backgroundMain()` (`app/lib/main.dart` → `app/lib/platform/android/background.dart`) and automatically re-arm after a reboot or app update without opening the UI. With *Run in the background* off, scheduled wakes are cancelled and refreshes pause while the app is hidden.

## 8. Releases

Releases are cut by tagging: `git tag vX.Y.Z && git push origin vX.Y.Z` — or by triggering the **Dart** workflow (`.github/workflows/dart.yml`) via `workflow_dispatch` with `release_tag` (leave `release_tag` empty for a build-only run producing Windows, Linux, and macOS artifacts without publishing).

Keep the version synchronized across `app/pubspec.yaml` (`version: <ver>+<buildNumber>`), `packages/strakalari_core/lib/src/update.dart` (`stampedAppVersion` default, overridden on release builds by `--dart-define=STRAKALARI_VERSION=...`), and `installer.iss` (`#define MyAppVersion`); `app/test/version_sync_test.dart` checks that they agree.

- **Stable** (`v0.2.0`): published as a **draft** — review it and press *Publish*.
- **Beta** (`v0.2.0-beta.1`, anything with a `-suffix`): published immediately and marked **Pre-release**. Only users on the *Beta* update channel (Settings → Diagnostics; the default for anyone whose first install was a beta) are notified; *Stable* users never see pre-releases. Beta users are also notified about stable releases, and `0.2.0` counts as newer than `0.2.0-beta.N`.

The in-app update check reads the public GitHub API without a token, so it only works while the repository is public (a private repo answers 404 and the check stays silent).

## 9. Reporting bugs

Include: app version, OS (+ locale if non-English), what you did, what happened vs. what you expected, and the relevant part of `log.txt` / `console.log` (redact credentials). The in-app "Copy log" button already scrubs passwords, usernames and the signature. Check open [issues](https://github.com/DeNdlerX/strakalari/issues) first to avoid duplicates.
