# Checkpoint D review: release (phase 9)

Reviewed at `c7caf4b` on 2026-11-14: the 4 commits since the last review (`53fb41f..c7caf4b`:
`72ae351`, `4b0a5ae`, `7fa913c`, `c7caf4b`), plus everything a release depends on that the
earlier checkpoints left unverified (`.github/workflows/dart.yml`, the docs, the soak, the
Windows Sandbox test). Phase 10 has not started, so the final merge is not part of this
review. The reviewer changed no code.

## Verdict: **FAIL**

The app itself holds up: every suite is green, Python and Dart behave the same on every day I
ran, and the Windows install-over test passed when I repeated it. What fails is the **release
path and the docs**: the release workflow cannot produce a release as written (1 blocker), and
8 must-fix items remain in the workflow, the macOS and Linux packaging and CONTRIBUTING.md.
**No-go for a beta tag and for phase 10** until these are fixed and re-reviewed.

---

## Blocker

### D-B1 The Windows release job always fails, so no release can be published

`.github/workflows/dart.yml:171-178` (step "Stamp installer version"):

```powershell
$iss2, $n = $iss -replace '#define MyAppVersion "[^"]+"', (...)
if ($n -ne 1) { throw "version stamp not found in installer.iss" }
```

PowerShell's `-replace` returns one string, not a (text, count) pair. `$n` is therefore always
`$null`, `$null -ne 1` is true, and the step throws on every run. Reproduced by the reviewer
with the same three lines against the real `installer.iss` (no file written): it throws.
`release-flutter` needs `build-flutter-windows` (`dart.yml:479`), so nothing is ever published,
and the MSIX job never runs.

Should match: `.github/workflows/build.yml:79-102`, which counts with `re.subn` and fails only
when the count is not 1.

Correct: count the matches first, then replace, for example
`$n = ([regex]::Matches($iss, '#define MyAppVersion "[^"]+"')).Count`, throw when `$n -ne 1`,
then `$iss2 = $iss -replace ...`. (The stamp is also passed as `/DMyAppVersion` at
`dart.yml:196`, and `installer.iss:7-9` only uses the hardcoded value when that is absent, so
keeping one of the two is enough; keep both only if both work.)

---

## Must-fix

### D-M1 A release tag starts the old Python release workflow as well

`.github/workflows/build.yml:3-6` and `.github/workflows/dart.yml:10-11` both run on `v*` tags.
A beta tag on this branch therefore starts five Python build jobs (macOS included, the
expensive one) next to the Flutter ones, and both workflows publish files with the **same
names** to the **same release** (`build.yml:514-560`, `dart.yml:477-520`).

Today the Python side only stays out of the release by accident: `installer.iss:63-64` now
packages the Flutter bundle, so `build.yml`'s `build-windows` fails at the Inno step and its
`release` job is skipped. A release must not depend on that.

Correct: on this branch, remove the `push: tags` trigger from `build.yml` and leave its
`workflow_dispatch`. This is the one change to the Python CI the reviewer approves before
phase 10 (PLAN phase 0 says not to change it; phase 10 deletes the file anyway). Change
nothing else in `build.yml`.

### D-M2 The release job has no permission to create a release

`.github/workflows/dart.yml` has no `permissions:` block; `release-flutter`
(`dart.yml:501-520`) creates a GitHub release with `GITHUB_TOKEN`. `build.yml:14-15` sets
`permissions: contents: write` for exactly this. Without it the publish step is refused where
the repository default is read-only.

Correct: add `permissions: contents: write` to the `release-flutter` job only (the other jobs
need no write access).

### D-M3 There is no build-only run, so macOS and Linux cannot be tried before they are published

`dart.yml:111` runs `meta` only for a tag or a non-empty `release_tag`, and every build job
has `if: needs.meta.outputs.release == 'true'` (`dart.yml:157, 219, 279, 359, 420`). The input
text at `dart.yml:18` promises "Leave empty for a build-only run", but an empty run builds
nothing. A beta is published at once, not as a draft (`dart.yml:507-510`). So the first time the
`.dmg` and the AppImage are ever built, they go straight to the beta users.

Should match: `build.yml:20-22` and its build jobs, which have no such `if`: no tag means
build-only, artifacts and no release.

Correct: `meta` also runs on a manual run without a tag (version from `app/pubspec.yaml`,
`release=false`); the Windows, Linux and macOS build jobs run whenever `meta` ran; only
`build-flutter-msix` and `release-flutter` keep the `release == 'true'` condition. The Android
job may stay release-only (a prod build needs the signing secrets).

### D-M4 A release is published without running the tests

`release-flutter` needs only the build jobs (`dart.yml:479`). The `dart` job (analyze + tests,
`dart.yml:23-57`) and `dart-macos-locks` (`dart.yml:63-94`) run beside it but do not gate it.
In `build.yml` every build job runs the suite first (`build.yml:119, 249, 365`).

Correct: add `dart` and `dart-macos-locks` to `needs:` of `release-flutter`.

### D-M5 The Linux build job fails, and its AppImage starts hidden

1. `dart.yml:294-297` installs no AppIndicator package. `tray_manager` 0.5.3 stops the build
   with `FATAL_ERROR` when neither `ayatana-appindicator3-0.1` nor `appindicator3-0.1` is found
   (its `linux/CMakeLists.txt:23-36`, read in the pub cache). Correct: add
   `libayatana-appindicator3-dev` to the `apt-get install` line, and copy
   `libayatana-appindicator3.so.1` (and the `libayatana-indicator3` / `libdbusmenu` libraries it
   loads) into `$APPDIR/usr/bin/lib/`, so the AppImage also starts on a system without them.
2. `dart.yml:328` writes `Exec=strakalari --minimized` into the AppImage's own desktop entry.
   `build.yml:277` has `Exec=strakalari`. With `--minimized` a user who starts the app from the
   menu gets no window. Correct: `Exec=strakalari`. (`--minimized` belongs only in the autostart
   entry, which `app/lib/platform/desktop/autostart.dart` writes.)

Not runnable here; verify with the build-only run of D-M3.

### D-M6 The macOS release build is sandboxed and has no network permission

`app/macos/Runner/Release.entitlements:5-6` (the `flutter create` default) switches on
`com.apple.security.app-sandbox`, and no `com.apple.security.network.client` is granted. A
sandboxed build cannot reach Bakaláři or Strava, keeps its data in
`~/Library/Containers/cz.strakalari.app/...` instead of
`~/Library/Application Support/Strakalari`, and cannot run the `security` command that
`app/lib/platform/desktop/keystore_desktop.dart:144-191` uses. The Python app is not sandboxed
(`strakalari.spec:273-283` sets no entitlements). The CI's `codesign --force --deep --sign -`
(`dart.yml:453`) happens to drop the entitlements again, so the shipped `.dmg` probably works,
but only by that side effect; a local `flutter build macos` does not.

Correct: set `com.apple.security.app-sandbox` to `<false/>` in `Release.entitlements` and
`DebugProfile.entitlements`. Not runnable here; verify with the build-only run of D-M3.

### D-M7 On Linux, saved passwords are lost on update unless `secret-tool` happens to be installed

`app/lib/platform/desktop/keystore_desktop.dart:212-214` reaches the Secret Service only through
the `secret-tool` command. When it is missing the store counts as absent
(`KeyStoreMissing`), `packages/strakalari_core/lib/src/storage/secret_store.dart:263-267` returns
no key, and a **new** key is created in a plain `secret.key`. The key Python's `keyring` stored
in the Secret Service (through D-Bus, no command needed) is never read: the old passwords
cannot be decrypted, the wizard asks again, and from then on the key lies in a file next to the
passwords. Debian and Ubuntu do not install `secret-tool` (`libsecret-tools`) by default.
`docs/flutter-migration/phase-7-desktop.md:99-101` lists this as an open decision; it was never
made, while `README.md:39` / `README.en.md:39` promise that passwords carry over on their own.

Correct: ship `secret-tool` inside the AppImage (CI: `apt-get install libsecret-tools`, copy
`/usr/bin/secret-tool` into `$APPDIR/usr/bin/`) and let `_which('secret-tool')` look in the
executable's own folder before `PATH`. Add a test for that lookup. Verify on Linux before the
README promise is kept for Linux; until then this stays on the unverified list.

### D-M8 CONTRIBUTING.md still describes the Python app

`CONTRIBUTING.md:7-30` is a banner about the migration; everything below it is unchanged:
prerequisites and setup are Python (`:34-68`), running is `python main.py` (`:70-76`), tests are
pytest and ruff (`:94-103`), the layout lists `strakalari/core` and `flet_ui` (`:105-137`), the
safety rules name Python functions and the two-process design (`:141-146`), the guidelines talk
about `requirements.txt` and Flet pins (`:150-156`), building is PyInstaller, `flet build` and
`make_mobile.py` (`:159-188`), and releases point at `build.yml` and `strakalari/__init__.py`
(`:190-197`). PLAN phase 9 asks for the docs to be updated; the only phase 9 change to this file
is one command (`7fa913c`).

Correct: rewrite sections 1–8 for the Flutter app, same structure and tone:
- prerequisites and setup: Flutter 3.44.8, `dart pub get --enforce-lockfile`;
- running: `flutter run -d windows` with `STRAKALARI_DATA_DIR`, the demo data and demo server;
- tests: the four commands of the banner;
- layout: PLAN §3.1;
- the safety rules with the Dart names (`runRefresh`, the session lock, the one send path, the
  audit log, `automation_paused`, fail loudly) and the one-process design;
- guidelines: config keys validated in `storage/config.dart`, strings in
  `app/lib/l10n/strings.dart`, `pubspec.lock`;
- building: `flutter build windows` + `installer.iss`, `tool/build_android.dart` (neutral
  folder, `~/.strakalari-signing/`, flavors `prod` / `phonetest`), run `flutter clean` before a
  local release build (see D-N3);
- releases: `dart.yml`, the version in `app/pubspec.yaml`, `update.dart` (`stampedAppVersion`)
  and `installer.iss`.

Keep one short paragraph saying the Python sources stay as the reference until phase 10.

---

## Should-fix

- **D-S1 The soak has fewer real days than its own exit rule asks for.**
  `docs/flutter-migration/SOAK.md:111-112` requires "several consecutive days (minimum three)".
  Logged: one real day (2026-11-13) and four simulated days run in one sitting
  (`SOAK.md:106`). The reviewer added a second real day (2026-11-14) and five more simulated
  days; all identical (see the table below). The simulation is useful but not complete:
  `tools/parity/fake_clock.py:68-74` only replaces module-level `datetime` / `date` names, so
  the function-local imports at `strakalari/core/automation.py:700`,
  `strakalari/core/refresh.py:155` and `strakalari/core/excuse_history.py:237, 245, 280` keep
  the real clock (none of them is reached in a dry run without Strava). Correct: add the
  reviewer's run to the SOAK.md log (`2026-11-14 · py@0ffdcff dart@c7caf4b · ... reviewer,
  reviews/checkpoint-D.md`), say in `fake_clock.py`'s docstring what it does not cover, and run
  one more real day before the re-review. STATUS.md says the owner allowed the simulated days;
  the owner should confirm that to the reviewer.
- **D-S2 The Sandbox test in STATUS.md ran on an older build and not on dry run.** The Flutter
  installer used on 2026-11-13 was built at 18:43, before the version commit `4b0a5ae` (19:02);
  its seed had `excuse_mode: confirm`, while PLAN phase 7 says "demo data and dry run"; and the
  seeded history entry was not a real one (`{"date": ..., "lesson": 1}`), so it proved nothing
  about history. The reviewer repeated the classic test with a fresh build, dry run and a real
  history entry: passed (below). The MSIX half was **not** repeated. Correct: say so in the
  Checkpoint D notes, and rerun the MSIX test with an MSIX packed from the current build, seed
  on dry run, a real-shaped history entry.
- **D-S3 STATUS.md is not closed.** Checkpoint D requires every question answered.
  - `STATUS.md:40-43` still says "Days 2–3 soak and the Windows Sandbox re-test remain".
  - Stale items not marked resolved: `:716` (toast console window "Unverified"), `:722` (MSIX
    VC++ runtime "Untested"), `:723` (Credential Manager "still untested").
  - Never answered: `:731-741` items 2–5 (flavor names, `backgroundMain` placement,
    `LSUIElement` and `launch_at_startup`, screenshots) and `:720` (tray icon always shown).
    The reviewer's answers: flavors `prod` / `phonetest` accepted (Checkpoint C); the
    trampoline accepted (Checkpoint C); no `LSUIElement`, a one-process app needs its Dock
    icon; `launch_at_startup`: see D-S5; screenshots were done at Checkpoint B; the tray
    deviation was accepted at Checkpoint C. Mark them so.
  - Open for the owner: `:710` (after an update Android takes the exact-alarm permission away
    until the user allows it again).
  - `SOAK.md:43, 84` still expect 720 core tests (now 802).
- **D-S4 User docs.**
  - `README.md:39`, `README.en.md:39`: "(Flutter) sestavení / build" and "identita aplikace /
    application identity" are developer words; `CONTRIBUTING.md:156` says the README stays
    non-technical. Say it plainly, for example "The new version installs over the old one like
    any update; settings, passwords and history stay."
  - `PRIVACY.md:3`: "Last updated: October 20, 2026" although the text changed in November.
  - `PRIVACY.md:24`: "how credentials are protected do not change" contradicts `:25` (the
    Android key is now wrapped by the Android Keystore), and the paragraph lists `applicationId`,
    `AppId`, MSIX identity, which a user does not need.
  - `PRIVACY.md:25` says where the key is kept on Windows and Android only, while `:5` now names
    macOS and Linux: add the macOS Keychain and the Linux Secret Service (with the file fallback
    of D-M7, whatever its fix turns out to be).
- **D-S5 Dead stub with a second autostart.** `app/lib/platform/desktop.dart` (145 lines:
  `DesktopWindow`, `DesktopTray`, `DesktopAutostart`, `SingleInstanceGuard`) is imported
  nowhere; it is the phase 5 stub, and the only user of the `launch_at_startup` dependency
  (`app/pubspec.yaml:53`). The live code is `app/lib/platform/desktop/`. Correct: delete the
  file and the dependency (answers question 4, `STATUS.md:737-739`).
- **D-S6 Actions are not pinned in `dart.yml`.** `build.yml` pins every action to a commit
  (for example `actions/checkout@fbc6f399...`); `dart.yml` uses moving tags (`actions/checkout@v4`,
  `subosito/flutter-action@v2`, `softprops/action-gh-release@v2`, `actions/upload-artifact@v4`,
  `actions/download-artifact@v4`, `actions/setup-java@v4`). The Android job handles the release
  signing key. Correct: pin each to a commit SHA with the version in a comment, like `build.yml`.
- **D-S7 Windows file properties say "app".** `app/windows/runner/Runner.rc:92-98`:
  `CompanyName` `io.github.dendlerx`, `FileDescription` and `ProductName` `app`. Task Manager
  and the file's properties show these. Correct: `FileDescription` and `ProductName`
  `Strakalari`, `CompanyName` `Strakalari` (the installer's publisher, `installer.iss:10`).

---

## Notes

- **D-N1 For phase 10 (not now).** `build.yml` also holds `publish-store`
  (`build.yml:480-508`, the Microsoft Store submission) and the Flutter MSIX job still calls
  the Python tools `tools/make_msix.py` and (through `publish-store`) `tools/store_submit.py`.
  Phase 10 must move `publish-store` into `dart.yml` and keep those two tools (with their tests)
  or port them; `dart-macos-locks` installs the Python `cryptography` package for a cross test
  that ends with the Python app. Until then a stable tag from this branch would not reach the
  Store.
- **D-N2** `4b0a5ae` is a real fix, not only wiring: before it nothing set
  `currentAppVersion`, so every installed Flutter build believed it was `0.0.0`. Now
  `packages/strakalari_core/lib/src/update.dart:36-43` takes the build's version, and
  `error_report.dart:286-305` reports it like `strakalari/core/error_report.py:241-263`
  (the `catch (_)` there mirrors Python's `except Exception`). Checked in real builds: the
  Windows exe reports `0.2.0-beta.1+7`, the APK `versionName 0.2.0-beta.1`.
  A release build on Android now reports `build: installer`; Python reported `source` there
  (`sys.frozen` is unset in the Flet phone build). Covered by the listed "`dart.vm.product`
  instead of `sys.frozen`" deviation; accepted.
- **D-N3** A local Windows release build ships whatever is left in
  `app/build/windows/x64/runner/Release/`: the reviewer's installer contained
  `flutter_local_notifications_windows.dll` and `dartjni.dll` from a plugin removed on
  2026-11-12. Harmless, and CI builds are clean, but run `flutter clean` before a local release
  build (put it in CONTRIBUTING, D-M8).
- **D-N4** The dropped sentence in `run_in_background_hint` (`7fa913c`; `app_cs.arb`,
  `app_en.arb`, `strings.dart`) is the one intended text difference from
  `strakalari/flet_ui/strings.py`. It follows PLAN §3.4 (the "open it once" line goes away);
  STATUS.md records the owner's go-ahead of 2026-11-13. Accepted.
- **D-N5** `bin/refresh_dryrun.dart` (`c7caf4b`): the body moved into `runBody()` unchanged,
  `DateTime.now()` became `clock.now()` twice, `--today` wraps it in `withClock`. Read line by
  line against the old version; the real-submit proof still gives the same result (below).
- **D-N6** Still true from Checkpoint C: nothing was run on the phone by a reviewer; the phone
  results are the migrating agent's.

---

## Unverified, for the owner's CI run (not passed)

Nothing below was run by anyone. A release depends on all of it.

- Every job in `dart.yml`: none has ever run (the branch was never pushed). D-B1 and D-M5 show
  two of them cannot pass as written.
- macOS: the build, the `.dmg`, key reading through `security`, the LaunchAgent, the tray, the
  single instance, `flock` (`dart-macos-locks`), and whether `--build-name` with a `-beta.1`
  suffix is accepted.
- Linux: the build, the AppImage, key reading through `secret-tool` (D-M7), the autostart
  `.desktop` file, the tray, notifications.
- Windows MSIX packed by CI (the VC++ DLL step, `dart.yml:239-248`) and the Store submission.
- The MSIX install-over test on the current build (D-S2).

Order that keeps the risk low once the findings are fixed: a build-only run (D-M3), try the
macOS and Linux files by hand, and only then a beta tag.

---

## What I verified, and how

Flutter 3.44.8 / Dart 3.12.2, Windows 11, 14 Nov 2026. Nothing was contacted except localhost.
The main checkout's data files were not opened. The working tree was clean before and after
(`git status --short` empty; all build output went to ignored folders or the reviewer's
scratch folder).

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / 802 passed, 2 skipped (POSIX permission bits; the flock probe is Linux and macOS only) |
| `flutter analyze` / `flutter test` (app) | clean / 640 passed, 1 skipped (APK scan; run separately, below) |
| Python suite | 1643 passed |
| `tools/parity/dump.py` + `git diff --exit-code` on `test/parity/` | clean |
| Test integrity since `53fb41f` | 6 lines added to two test files (`version_sync_test.dart`, `error_report_test.dart`), none removed or loosened; no new `skip:`; the six existing `skip:` are platform conditions |
| Pitfalls in the changed Dart | no new `RegExp`, no `~/` / `%` / `.round()` / `weekday`, no `jsonEncode` on a shared file; `DateTime.now()` removed from `bin/refresh_dryrun.dart`; one new `catch (_)` (D-N2) |
| Scope | no change under `strakalari/`, `tests/`, `mobile/` on the branch; `tools/` changes are `tools/parity/*` and the listed `make_msix.py` adaptation; `git log flutter-migration..main` is empty, `0ffdcff` is the last ported commit |
| Architecture | no `package:flutter` in core sources; no build_runner or codegen; `pubspec.lock` committed; Flutter 3.44.8 pinned in `dart.yml` |
| Hygiene | no upstream; 240 commits on the branch, all by DeNdlerX; no `Co-Authored-By` / `Claude-Session`; no personal file added (`test/parity/config.json` is the known fixture; the two `.properties` files are Gradle's) |
| Soak, real day (14 Nov), own demo server on localhost, throwaway folders | fresh: `IDENTICAL (modulo ts)`, fetch byte-identical (31195 B); same folders again: `IDENTICAL (modulo ts)` |
| Soak, simulated 16, 18, 20, 23 Nov and 1 Dec (`demo_server_at.py --today`, `--today` on both sides) | each day fresh and on accumulating folders: `IDENTICAL (modulo ts)`; fetch byte-identical each day (31370, 31373, 31375, 30893, 30411 B) |
| Real-submit proof (`--send-day 09.11.2026`, a fresh demo server per side) | `IDENTICAL (modulo ts)`; 5 outbox and 5 history entries on each side, empty unconfirmed file; both scripts refuse `http://example.com` |
| Windows release build as a beta | `flutter build windows --release --build-name=0.2.0-beta.1 --build-number=7 --dart-define=STRAKALARI_VERSION=0.2.0-beta.1` builds; exe version `0.2.0-beta.1+7`; `ISCC /DMyAppVersion=0.2.0-beta.1 installer.iss` compiles |
| Windows Sandbox, classic install-over (network off, `outside network reachable = False`) | Python 0.1.0 installer + demo seed on **dry run** (demo server on 127.0.0.1 inside the Sandbox), one Python run, then the reviewer's fresh Flutter `0.2.0-beta.1` installer over it. After Python: `secret.key` gone, Credential Manager entry `Strakalari` / `fernet-key:840cfbb6e2f38640`. After the Flutter installer: one uninstall entry (`{D94B0B7F-65C1-4D52-9A47-E30D6E26F22B}_is1`), same Run value, `config.json` and `already_excused_lessons.json` byte-identical. Flutter app: logged in (second `POST /Login` 302 on the demo server, so the password was decrypted with the key Python stored), refreshed the cache, history and config byte-identical afterwards, `secret.key` did not come back. Toast: `powershell.exe` started by the app, no console window with a visible handle. A second start exits and leaves one process ("already running; showing the open window" in `console.log`). No post to the excuse form. |
| Windows Sandbox, MSIX | **not repeated.** The migrating agent's logs of 2026-11-13 were read (`msix_result.txt`: update 0.1.0.0 → 0.1.1.0, data in `LocalCache\Local\Strakalari`, Flutter logged in and synced). They match STATUS.md, but see D-S2 |
| Android release build through `tool/build_android.dart apk --version 0.2.0-beta.1` | builds from the neutral folder; `io.github.dendlerx.strakalari`, versionCode 22031 (20031 + 2000), versionName `0.2.0-beta.1`; signed by the release key (`CN=Strakalari, O=DeNdler`, same certificate as the 0.1.0 APK); the tool's own package check passes; `packaging_privacy_test.dart` with `STRAKALARI_APK`: 5 passed. Not installed on the phone |
| `dart.yml` | read completely against `build.yml`; D-B1 reproduced locally; `tray_manager`'s Linux build file read in the pub cache; nothing run on CI |
| Docs | README.md, README.en.md, PRIVACY.md and CONTRIBUTING.md read completely, with their diff against `main` |

---

# Re-review (2026-11-14)

Reviewed at `952b065`: the 15 commits since the review (`be9f81e..952b065`, `e264719` …
`952b065`, one per finding; D-S2 and D-S3 share the last one). The reviewer changed no code.

## Verdict: **PASS**

Every finding of the review is fixed in the code, not only marked fixed; nothing else broke;
no new blocker, must-fix or should-fix. Phase 10 may start **on the branch**.

This is not yet a go for a release or for the merge into `main`. Three things stay with the
owner, and the final review (after phase 10) will check them again:

1. **Nothing in `dart.yml` has ever run** (the branch was never pushed), and macOS and Linux
   were never built or started by anyone. See "Still unverified" below. Before any beta tag:
   one build-only run (Actions → Dart → Run workflow, tag field empty), then try the `.dmg`
   and the AppImage by hand.
2. **Soak days.** `SOAK.md:113-114` asks for three consecutive real days; there are two
   (13 and 14 Nov), plus nine simulated days (4 by the migrating agent, 5 by the first
   reviewer), all identical. STATUS.md says the owner allowed simulated days. The reviewer
   accepts this in substance (the demo server's data depends only on the date, and the
   simulated days cross a weekend and a month end), but the owner should say so, or one more
   real day is run before the beta.
3. **Open owner question** (`STATUS.md:713`): after an update Android takes the exact-alarm
   permission away until the user allows it again; the app warns on the Budík card like
   Python. Change nothing, or add a hint elsewhere? (No change is the parity answer.)

## The findings, one by one

| Finding | Commit | Checked how | Result |
|---|---|---|---|
| D-B1 version stamp | `e264719` | `dart.yml:176-182` read; the same lines run by the reviewer against the real `installer.iss` (nothing written): the count is 1 and the replaced text carries the new version | fixed |
| D-M1 Python workflow on tags | `15b09ac` | the `build.yml` diff is exactly the three `push: tags` lines; `workflow_dispatch` kept | fixed |
| D-M2 release permission | `f882df4` | `dart.yml:496-497`, on `release-flutter` only | fixed |
| D-M3 build-only run | `96e439e` | `dart.yml:111` (`meta` on any manual run or tag), `:142-147` (version from `app/pubspec.yaml`, now `0.1.0`, `release=false`); the Windows, Linux and macOS jobs have no `if`; MSIX, Android and `release-flutter` keep `release == 'true'`. A plain branch push or a pull request skips `meta`, so the build jobs are skipped with it | fixed |
| D-M4 tests gate the release | `8f5d5c4` | `dart.yml:493`; `dart` runs on tags and manual runs, `dart-macos-locks` too (`:65`) | fixed |
| D-M5 Linux tray library, `Exec` | `c9870c5` | `dart.yml:300` installs `libayatana-appindicator3-dev`; `:324-332` copies the tray libraries into `usr/bin/lib`; `:342` `Exec=strakalari`; `:352` `LD_LIBRARY_PATH` in `AppRun` | fixed as written, **not runnable here** |
| D-M6 macOS sandbox | `cfb8f3c` | both entitlements files: `app-sandbox` is `<false/>` | fixed as written, **not runnable here** |
| D-M7 `secret-tool` | `361a18f` | `dart.yml:300, 322-323` ship it in the AppImage next to the executable; `keystore_desktop.dart:308-340` `locateCliTool` looks in the executable's folder before `PATH`; `:255-260` the store pipe now calls the located path; 4 new tests in `keystore_windows_test.dart:199-262` (prefer bundled, empty PATH, fall back, missing) call the real function and check exact paths | fixed as written, **Linux run still owed** |
| D-M8 CONTRIBUTING.md | `35c940b` | read completely; every file and name it cites was looked up in the tree (one slip, D2-N1) | fixed |
| D-S1 soak log, `fake_clock.py` | `e53d32c` | `SOAK.md:108-109`, `fake_clock.py:6-11`; one more run logged, but on the same day (see 2 above) | fixed, the owner's word is open |
| D-S2 MSIX Sandbox on the current build, dry run | `952b065` | repeated by the reviewer, below | fixed |
| D-S3 STATUS.md closed | `952b065` | `STATUS.md:40-46, 705-742` read: the stale items are marked resolved with their commits; one owner question left (3 above) | fixed |
| D-S4 user docs | `590ed4b` | README.md:39 and README.en.md:39 in plain words; PRIVACY.md date and `:24-25` | fixed |
| D-S5 dead stub | `984ed3f` | `app/lib/platform/desktop.dart` gone; `launch_at_startup` gone from `app/pubspec.yaml` and `pubspec.lock` (with `win32_registry`, which only it used); no import left (analyzers clean) | fixed |
| D-S6 pinned actions | `ca7a4c8` | all 25 `uses:` carry a commit id; each of the 7 ids was looked up with `git ls-remote --tags` in the action's public repository and belongs to the version in the comment; 5 of them are the ones `build.yml` already uses | fixed |
| D-S7 file properties | `f4e7bdb` | `Runner.rc:92-98`; seen on the built exe inside the Sandbox: `ProductName=Strakalari FileDescription=Strakalari CompanyName=Strakalari` | fixed |

## Notes

- **D2-N1** `CONTRIBUTING.md:125` says a scraper's deliberate fallback "logs one line via
  `_debug`". The Dart method is `debug(what, exc)`
  (`packages/strakalari_core/lib/src/bakalari/client.dart:154`); `_debug` is the Python name
  (`self._debug`). Correct it when phase 10 touches the file.
- **D2-N2** `PRIVACY.md:24` now says the key is "stored in ... Android Keystore on Android".
  More exact: the key file stays in the app's private storage and is *wrapped* by the Android
  Keystore (the wording before `590ed4b`). Not wrong enough to block; tidy it in phase 10.
- **D2-N3** `locateCliTool` also serves the macOS `security` lookup
  (`keystore_desktop.dart:142, 166, 196`), so the app's own folder is searched first there
  too. Harmless: that folder is as trusted as the executable itself.
- **D2-N4** The MSIX Sandbox test cannot use the real Store identity (that needs the Store's
  signature); it uses `StrakalariSandbox.Strakalari` with a throwaway certificate on both
  packages. The real identity values in `dart.yml:230-232` equal `build.yml:156-158`. The
  real Store update is only proven by the first Store submission.
- **D2-N5 For phase 10** (D-N1 still stands): move `publish-store` from `build.yml` into
  `dart.yml` and keep `tools/make_msix.py` and `tools/store_submit.py` with their tests (the
  MSIX job needs no `pip install`: `make_msix.py` uses the standard library only). The
  `dart-macos-locks` job and `helpers_test.dart` use the Python app for a cross test, which
  ends with it. `tools/parity/`, the demo server and `demo_data.py` are Python tools the
  Dart docs still point to (`CONTRIBUTING.md:23, 39-44, 75-76`): decide per tool, keep it or
  drop it together with the lines that cite it, and list the decision in STATUS.md.
- **D-N6 still true:** nothing was run on the phone by a reviewer.

## Still unverified, for the owner's CI run (not passed)

Unchanged from the review, minus the MSIX install-over test:

- every job in `dart.yml` (never run);
- macOS: build, `.dmg`, key reading through `security`, LaunchAgent, tray, single instance,
  `flock`, a `-beta.1` build name;
- Linux: build, AppImage with the bundled libraries, key reading through the bundled
  `secret-tool` (D-M7: until this is seen working, the README promise that passwords carry
  over is unproven on Linux), autostart, tray, notifications;
- the MSIX packed by CI and the Store submission.

## What I verified, and how

Flutter 3.44.8 / Dart 3.12.2, Windows 11, 14 Nov 2026. Only localhost was contacted, plus
read-only `git ls-remote` on seven public action repositories. The main checkout's data
files were not opened. The working tree was clean before and after.

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / 802 passed, 2 skipped (the same two platform skips) |
| `flutter analyze` / `flutter test` (app) | clean / 644 passed, 1 skipped (APK scan) |
| Python suite | 1643 passed |
| `tools/parity/dump.py` + `git diff --exit-code` on `test/parity/` | clean |
| Test integrity since `be9f81e` | one test file changed (`keystore_windows_test.dart`, +66 lines, 4 new tests); no line removed from any test; no new `skip:` |
| Scope and pitfalls | the only Dart logic changed is `locateCliTool` and the `secret-tool` call; no `RegExp`, date, rounding or JSON code touched; no config key touched; nothing changed under `strakalari/`, `tests/`, `mobile/`; the one `tools/` change is the `fake_clock.py` docstring; `git log flutter-migration..main` is empty (`0ffdcff` is still the last ported commit) |
| Architecture | no `package:flutter` in core; the lockfile is committed and consistent |
| Hygiene | no upstream; the 15 commits are by DeNdlerX, without `Co-Authored-By` / `Claude-Session`; no personal file added |
| Soak, real day 14 Nov, own demo server on localhost, throwaway folders | fresh: `IDENTICAL (modulo ts)`; the same folders again: `IDENTICAL (modulo ts)`; fetch byte-identical (31195 B) |
| Clean Windows release build at `952b065` (`flutter clean`, then `--build-name=0.1.0 --build-number=10099 --dart-define=STRAKALARI_VERSION=0.1.0`) | builds. Compared with the files inside the migrating agent's `Strakalari-fl-0.1.1.msix`: the same 20 files; the compiled Dart code (`data/app.so`), `flutter_windows.dll` and all assets are byte-identical; only the exe and the five C++ plugin DLLs differ (build timestamps). So the tested package holds the current code |
| Windows Sandbox, MSIX install-over, repeated by the reviewer (network off: `outside network reachable = False`; the agent's `run_msix.ps1` was read first and run unchanged from a copy in the reviewer's scratch folder) | Seed: demo server on 127.0.0.1, user `demo`, `excuse_mode` and `strava_order_mode` `dry_run`, Strava off, one real-shaped history entry (05.11.2026, lessons 1–2). Python MSIX 0.1.0.0 installed and started: data copied to `LocalCache\Local\Strakalari`, no `secret.key` there, Credential Manager entry `Strakalari` / `fernet-key:285cb7ed71a7fe87`, no login yet. Flutter MSIX 0.1.1.0 installed over it (same package family): one `POST /Login` 302 (the password was decrypted with the key Python stored), full refresh, cache written, `secret.key` did not come back, the seeded history entry kept first and unchanged with 4 entries synced from the web after it, config still on dry run. Requests seen by the demo server: login, timetable, absences, marks, subjects, the Komens outbox list and two message reads. **No post to the excuse form**, no outbox file |

**Added 2026-11-15:** the owner told the reviewer that the simulated soak days are accepted in place of a third real day (item 2 above is closed).
