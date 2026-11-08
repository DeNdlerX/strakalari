# Phase 7 — desktop platform (Dart implementation notes)

Branch: `flutter-migration`. Implements PLAN §3.2 (desktop row) + §3.4
(desktop half) in `app/lib/platform/desktop/`. The other agent owns
`app/lib/platform/` stubs (`desktop.dart`, `keystore.dart`,
`notifications.dart`, `android/`); the files below are self-contained
(imports are core + Flutter + declared deps only) and `flutter analyze`
clean on their own.

## Files created (`app/lib/platform/desktop/`)

| File | Python source(s) | What it does |
|---|---|---|
| `single_instance.dart` | `flet_ui/single_instance.py` | Loopback-TCP guard: per-user port pair (`42000 + 20·slot [+10 dev]`), `instance.token` handshake, `show`/`ping`/`quit` magics (`-v2`), `ensureSinglePrimary` (`primary`/`secondary`/`solo`), `terminateProcessTree`. Byte-identical protocol: a Python tray and a Flutter app on one PC mutually exclude each other. |
| `tray.dart` | `flet_ui/tray.py`, `flet_ui/macos.py` | One process (PLAN §3.2): `DesktopTrayController` hides the window to the tray (`setPreventClose` + `onWindowClose` → `hide`), tray menu (Open / Refresh now / Pause–Resume / Quit, cs+en defaults), left-click restores, `--minimized` starts hidden. `DesktopBackgroundLoop` mirrors the tray's `PeriodicRunner` wiring (seed from cache, interval re-read, refresh + update jobs, re-entrancy guard, one toast per failed job); the refresh itself is injected by the app. |
| `autostart.dart` | `core/autostart.py` | Same mechanism, same locations: HKCU `Run` value `Strakalari` = `"<exe>" --minimized` (+ legacy `.lnk` adoption), macOS `~/Library/LaunchAgents/cz.strakalari.app.plist`, Linux `~/.config/autostart/strakalari.desktop`, Store-MSIX refusal. Windows via `package:win32` registry calls (no new dep). |
| `notifications.dart` | `core/notify.py` (app side) | `flutter_local_notifications` backend (`DesktopNotifierBackend` implements core's `NotifierBackend`), stable per-event ids (`100 + eventTypes index`), `notifyEvent` parity helper (pref check → toast → stdout fallback), tap → show window. Windows identity: `appUserModelId 'Strakalari'`, guid = Inno `AppId`. |
| `keystore_desktop.dart` | `core/secret_store.py` keyring half | `DesktopKeyStore implements KeyStore`: Windows `CredRead/Write/Delete` via `package:win32` (service-first, compound fallback, UTF-16→UTF-8 decode — exactly keyring's `Windows.py`); macOS Keychain item via `security` CLI (same service/account); Linux Secret Service via `secret-tool` (same attributes + `Python keyring library` application, same label). Absent backend → `KeyStoreMissing` (file fallback); refused store → `KeyStoreUnavailable` (wizard re-prompts, never data loss). |

Supporting changes (all required for identity continuity, PLAN rule 2):

* `app/pubspec.yaml`: added `flutter_local_notifications ^19.4.1`,
  `crypto ^3.0.8`, `ffi ^2.1.4` (+ lockfile via `flutter pub get`).
* Runners: Windows `BINARY_NAME app → Strakalari`, macOS
  `PRODUCT_NAME app → Strakalari` + bundle `io.github.dendlerx.app →
  cz.strakalari.app` (matches the shipped Python `.app` and the
  LaunchAgent label), Linux `BINARY_NAME app → strakalari` +
  `APPLICATION_ID → cz.strakalari.app`.
* `installer.iss`: `[Files]` now ships the Flutter Release bundle
  (`app\build\windows\x64\runner\Release\*`) instead of
  `dist\Strakalari.exe`. AppId, exe name, HKCU Run value, taskkill,
  uninstall data-file list unchanged → installs as an update.
* `tools/make_msix.py`: new `--app-dir` (stages the whole Release
  bundle; `--exe` onefile mode kept). Manifest untouched
  (`Executable="Strakalari.exe"`, same identity tokens, same
  `StartupTask --minimized`).
* `.github/workflows/dart.yml`: `meta` + `build-flutter-windows`
  (Inno) + `build-flutter-msix` (stable only) + `build-flutter-linux`
  (AppImage) + `build-flutter-macos` (.dmg) + `release-flutter`
  (stable draft / beta immediate, MSIX excluded — same contract as
  `build.yml`). `build.yml` untouched (phase 10 switches).

## Deviations from Python (need reviewer sign-off)

1. **One process, not two.** Python runs tray parent + Flet child;
   Flutter hides the window in the same process. Closing the window
   never kills automation (the loop lives in the isolate). `flet.exe`
   orphan reaping is dropped (no Flet subprocesses exist).
2. **Async background loop** instead of core `PeriodicRunner` (its
   jobs are sync, `runRefresh` is async). Schedule math (seed,
   interval, 5 s tick, failure back-off) is the same.
3. **Windows exe name is now build-time** (`BINARY_NAME=Strakalari`)
   rather than PyInstaller's output name. Debug builds produce
   `build\windows\x64\runner\Debug\Strakalari.exe`.
4. **macOS/Linux key stores via CLI** (`security`, `secret-tool`)
   instead of native APIs — same stores, same entries, no Swift/D-Bus
   code. Linux `set` pipes the secret through a same-user-only
   environment variable (the `KeyStore` interface is synchronous and
   `secret-tool store` reads stdin).
5. **Frozen/dev port offset** uses `bool.fromEnvironment
   ('dart.vm.product')` (release = installed pair, debug/profile =
   dev pair) instead of `sys.frozen`.
6. **UTF-16 blob edge**: keyring decodes the blob as UTF-16 with
   `errors` falling back to UTF-8; this port detects lone surrogates
   to choose. ASCII Fernet keys are unaffected either way.
7. **Tray icon path** defaults to `assets/tray-icon.ico` (repo icon);
   the shell must declare it under `flutter/assets` in `app/pubspec.yaml`
   (currently no `assets:` section is declared).

## UNVERIFIED (no Mac/Linux/packaging run here)

* macOS + Linux code paths in all five files (written from the
  Python sources, never executed).
* `flutter build windows/macos/linux --release` (release builds were
  not run — only `flutter analyze`).
* Inno installer compile, MSIX pack (`--app-dir` path is new code),
  AppImage/dmg assembly, all `dart.yml` release jobs.
* Over-install upgrade (Python → Flutter keeping settings/passwords/
  history) — must be tested in Windows Sandbox per PLAN phase 7, with
  a Python build on demo data + dry run. Never over the owner's real
  installation.

## Open questions (for the owner / other agent)

1. **Shell wiring (other agent):** call in `main.dart` order —
   `ensureSinglePrimary` → `DesktopKeyStore` registered as
   `keyStoreBackend` → `installDesktopNotifier` → `DesktopTrayController.
   initialize(minimized: args.contains('--minimized'))` →
   `DesktopBackgroundLoop.start(seedLastRun: seedFromDisk())`.
   Also implement `--forget-secrets` (uninstaller calls it) and
   `--minimized` CLI flags, and set `currentAppVersion` (core
   `update.dart`) from the build + wire `onShow` to
   `SingleInstance.setOnShow`.
2. **`LSUIElement`**: to fully match the macOS accessory policy
   (no Dock icon for the tray process), set `LSUIElement=true` in the
   macOS runner `Info.plist`. Runner or shell owner to decide.
3. **Toast GUID**: reused the Inno `AppId`; change
   `windowsToastGuid` if a dedicated toast identity is preferred.
4. **Linux `secret-tool`**: not preinstalled everywhere — without it
   the key falls back to `secret.key` (by design). Decide whether to
   document/depend on `libsecret-tools`.
5. **LaunchAgent label** `cz.strakalari.app` vs bundle
   `cz.strakalari.app` kept identical on purpose (old + new installs
   share one plist). Confirm no rename is wanted.
6. **`launch_at_startup` plugin** (phase-5 stub dep) is now unused
   by `autostart.dart` (direct registry/plist/desktop-file parity
   instead). Keep or drop the dependency in a later cleanup.
