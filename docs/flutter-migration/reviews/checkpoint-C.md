# Checkpoint C review: platforms (phases 7–8)

Reviewed at `d45fa07` (2026-11-12), commits `9b5fca3..d45fa07` since the Checkpoint B
re-review 5 commit `1e94e67`, plus all phase 7–8 code on the branch (it was never reviewed).
Fresh session; the reviewer changed no code.

## Verdict: **FAIL**

4 blockers, 8 must-fix, 7 should-fix. STATUS.md itself says phases 7–8 are still in progress
(no Checkpoint C notes, Windows re-test pending, phone checks open), so this is an early
review of unfinished work. The code that exists has two ways to lose every stored password
and one way to run automation after the user switched background running off.

Paths: `app/…` and `packages/…` are Dart, `strakalari/…` is the Python reference.

---

## Blockers

### C-B1 Android: every app start throws away the password key
`app/lib/platform/android/android_keystore.dart:173, 183, 227-228` register
`WarmedAndroidKeystore(key, wrapped)` where `wrapped` is the **base64 text** read from
`secret.key.wrapped`. Core then calls
`android.unwrap(base64.decode(ascii.decode(wrapped)))`
(`packages/strakalari_core/lib/src/storage/secret_store.dart:105`), i.e. with the **decoded**
bytes. `WarmedAndroidKeystore.unwrap` (`android_keystore.dart:72-75`) compares the two, they
never match, it throws, and core does what it does for a lost key
(`secret_store.dart:106-110, 123-134`): quarantines `secret.key.wrapped`, makes a new random
key and writes it as plain `secret.key`. The next start wraps that new key, and the same
thing happens again.

Proven with a throwaway test (not committed) that builds the bridge exactly like line 183 and
calls `getKey`:

```
Warning: could not unlock secret.key.wrapped (FormatException: … does not read back); stored passwords must be entered again.
Warning: Android Keystore unavailable (KeyStoreUnavailable: … Key changed after the Keystore warm-up.); keeping secret.key.
same key as warmed: false
files after: [secret.key, secret.key.lock, secret.key.wrapped.corrupt-20261112-165829]
```

Python (`strakalari/core/secret_store.py:194-240`) returns the unwrapped key. Effect for a
user: after the update no saved Bakaláři / Strava password decrypts, on every start.

Correct: the bridge must answer core with what the Keystore answered. Store the decoded blob
(`base64.decode(ascii.decode(wrapped))`) in `WarmedAndroidKeystore.blob`, in all three places,
and make `wrap` return the raw blob too (core base64-encodes it itself, line 129). Add app
tests that run warm-up and then core `getKey` against a fake channel for: existing wrapped
key, plain `secret.key` to migrate, fresh install, lost Keystore key, and the two-isolate
race. Each must end with the same key and the same files as
`_android_load_or_create`.

### C-B2 Windows: saving or forgetting a key destroys another data folder's key
`app/lib/platform/desktop/keystore_desktop.dart:198-233` (`_setWindows`) writes target
`Strakalari` directly. keyring's `set_password` (`keyring/backends/Windows.py`,
`WinVaultKeyring.set_password`) first reads the existing `Strakalari` credential and, if there
is one, re-saves it under `<its user name>@Strakalari`, and only then writes the new one. The
Dart code skips that step, so the key of whichever data folder currently owns the `Strakalari`
target is overwritten and gone.

`_deleteWindows` (`keystore_desktop.dart:235-252`) deletes both targets unconditionally.
keyring's `delete_password` deletes a target only when its `UserName` equals the entry name.
So `Strakalari.exe --forget-secrets` (the uninstaller, `installer.iss:190`,
`app/lib/platform/startup.dart:74-76`) of one install deletes another install's key.

This is not theoretical: more than one data folder per Windows user is normal (GitHub
installer + Store package, a portable copy, a source run). This PC's Credential Manager holds
five `…@Strakalari` / `Strakalari` entries for five folders (names only were read, no secret).
Any Flutter run on a new data folder would have erased the key under `Strakalari`.

Correct: port `set_password`, `_resolve_credential` and `delete_password` line by line
(compound re-save before the write, `Comment = "Stored using python-keyring"`, delete only
where `UserName == account`, `PasswordDeleteError` semantics for `forgetKey` =
`secret_store.py:325-347`). Put the Win32 calls behind a small interface so a fake credential
table can test: collision on write, read through the compound name, delete leaves the other
entry alone. See also C-S4.

### C-B3 Android: after a reboot or an update the app runs automation although background running is off
`RefreshReceiver` (`app/android/app/src/main/AndroidManifest.xml`, `RefreshReceiver.java:99-108`)
starts the headless entry on `BOOT_COMPLETED` and `MY_PACKAGE_REPLACED`.
`_runHeadless` / `_runInline` (`app/lib/platform/android/background.dart:114-118, 175-229`)
then run `runRefresh` at once and `_rearm` (`:299-321`) always arms the next wake. Nothing
checks:

- `run_in_background` (Python: `_phone_background_on`, `strakalari/flet_ui/app.py:1012-1018`;
  when off, `stop_background` + `cancel_wake`, `app.py:1078-1081`). With the switch off the
  Flutter app still sends excuses and orders lunches in the background after every reboot,
  and keeps waking itself from then on.
- the gates of the scheduled job (`app.py:952-957`): setup not finished, demo mode without
  credentials.
- whether a run is due at all. Python anchors the first run to the last successful refresh
  (`_startup_seed`, `app.py:913-923, 993`). Here every boot and every app update is an extra
  run outside the schedule.

The inline run also reports less than the Python worker
(`strakalari/flet_ui/state_activity.py:375-403`): only `result.news` is notified; a failed
auto-excuse or auto-order (`automation_failed`), a low balance and a failed refresh
(`refresh_failed`) are silent, no run is recorded for the Activity screen, and the core
language is never set (`setLanguage`), so an English user gets Czech notifications. The status
fallback is `('Strakaláři', '')` instead of `bg_notif_title` / `bg_notif_text`
(`app.py:1052-1053`).

Correct: before anything else the headless entry reads the config and returns (cancelling the
wake, without re-arming) when `run_in_background` is false; it applies the three job gates;
on `boot` it only runs when `nextDue(startupSeed(cache), interval, now)` is reached, otherwise
it just arms that time; after a run it does what `_refresh_work` does (notifications, run
record, language). Best is one shared function used by `AppState`'s worker and the headless
run, with tests for each gate.

### C-B4 Android release build has no network permission
`app/android/app/src/main/AndroidManifest.xml` has no
`<uses-permission android:name="android.permission.INTERNET" />`; only the debug and profile
manifests do. The old app had it in the main manifest (Flet build template). The debug APK on
the test phone works, a release APK / AAB cannot reach Bakaláři or Strava at all. Add the
permission to the main manifest and add it to the manifest test in
`app/test/packaging_privacy_test.dart`.

---

## Must-fix

### C-M1 Android: background refreshes stop once the app is swiped away
`_handOffToUi` (`background.dart:121-141`) looks up the UI isolate's port in
`IsolateNameServer`. When the screen is closed, Flutter destroys the engine and the UI isolate
dies, but the process lives on (foreground service) and the name mapping stays. Sending to a
dead port neither throws nor answers, so the code waits 30 s, takes the timeout branch ("UI
isolate alive but did not answer", returns `true`) and ends **without a refresh and without
re-arming the wake**. From then on nothing runs until the app is opened. (Read from the code
and the engine's behaviour; not run on the phone, see "Not verified".)

Correct: the UI answers at once with an acknowledgement (`'taken'`) and then runs; the
headless side waits a few seconds for it. No acknowledgement: remove the stale mapping and run
inline (the session lock uses `flock`, which also separates two isolates, so this is safe).
The UI removes its mapping when it is torn down (`AppLifecycleState.detached`). Every headless
path ends by arming the next wake. Add a test with a closed `ReceivePort`.

### C-M2 Android: the notification permission is never asked
`MainActivity.kt:11-15` attaches the channel with `attach(applicationContext, messenger)`. The
`ActivityAware` callbacks of `StrakalariChannel` are only called for plugins added to the
engine's plugin registry, so `activity` stays `null` and `requestNotificationPermission`
(`StrakalariChannel.java:315-323`) always returns early. On Android 13+ a new install then
never shows any notification. Python asks through the Activity (`android.py:280-297`). Pass the
activity from `MainActivity` (or register the channel with `flutterEngine.plugins.add`).

### C-M3 Android: nothing keeps the CPU awake during a refresh in the UI isolate
Python wraps the scheduled refresh in `KeepAwake` (`app.py:958-963`, `android.py:565-598`).
There is no counterpart (`grep -ri keepawake app/lib packages` is empty). With the hand-off
the headless isolate replies and calls `backgroundDone`, which releases the only wakelock
(`RefreshReceiver.release`) while the UI isolate is still fetching. Add a `keepAwake` /
`releaseAwake` pair to the channel (partial wakelock `strakalari:refresh`, 30 min safety
timeout) and hold it around `scheduledRefreshJob` (`app/lib/platform/startup.dart:113`).

### C-M4 App identity details differ from the old build
Old values from the Flet build's manifest (`build/mobile/build/flutter/android/…` of the last
Python phone build):

| What | Old | New | Where |
|---|---|---|---|
| App name | `Strakaláři` | `app` (`aapt2 dump badging` of the built APK) | `AndroidManifest.xml` `android:label` |
| Launcher icon | Strakaláři icon | different file (Flutter default) | `res/mipmap-*/ic_launcher.png` |
| `android:allowBackup` | `false` | missing (= true: Android would copy `config.json` and the key file to the user's Google backup) | `<application>` |
| `android:enableOnBackInvokedCallback` | `true` | missing | `<application>` |
| `versionCode` | `build_number(version)` (`tools/make_mobile.py:211-221`) | `1` | `app/pubspec.yaml` `1.0.0+1`; nothing stamps it |
| Windows exe icon | `assets/icon.ico` | another file | `app/windows/runner/resources/app_icon.ico` |

A `versionCode` below the installed one cannot be installed as an update. Port
`build_number` into the build step and port `tests/test_icons.py` (13) and
`tests/test_version_sync.py` (3).

### C-M5 A release build without the key is silently signed with the debug key
`app/android/app/build.gradle.kts:93-103`: `signingConfig = releaseSigning ?: debug`. A
debug-signed release can never update the real app and the build gives no hint. Fail the
`prod` release build with a clear message when `~/.strakalari-signing/` (or the env variables)
is missing; allow the debug key only for the `phonetest` flavor.

### C-M6 The phase 7–8 tests are not ported; no platform file has a test
No test imports `startup.dart`, `background.dart`, `android_keystore.dart`,
`android_channel.dart`, `keystore_desktop.dart`, `single_instance.dart`, `autostart.dart` or
`tray.dart`. Still "Deferred" in the STATUS test map, with the Python case counts:
`test_single_instance` 22, `test_shutdown` 23, `test_store_package` 18, `test_macos_tray_host`
15, `test_icons` 13, `test_macos_data_dir` 9, `test_minimize_to_tray` 8, `test_autostart` 3 +
`test_autostart_platforms` 5, `test_entry_routing` 5, `test_tray_ui_command` 4,
`test_version_sync` 3, `test_wake_ui` 2, `test_tray_language` 1; from `test_scheduler.py` the
three registration cases and `test_scheduler_skips_refresh_while_setup_pending`
(`test_wizard_setup.py:260`); from `test_status_notification.py` the 12 Android / wiring
cases; from `test_mobile.py` `TestDataDir`, `TestKeystoreKey`, `TestPhoneBackground`,
`test_open_system_alarm_*`; from `test_wakeup_and_widget.py` the remaining Android cases.
PLAN rule 4: port each, or list it under *Dropped* with a reason that holds (for example the
Flet-view orphan sweep). C-B1 and C-B2 would both have been caught by these.

### C-M7 The checkpoint's own conditions are not met
PLAN §4 rows 7 and 8, STATUS "Next step" and "Questions":

- Phone: the Flutter `.test` build was **not** installed over the Flet `.test` build; the old
  app was wiped first. So "keeps data and passwords" is untested, and C-B1 shows it fails.
  Redo it: build the Flet `.test` app, set it up on demo data and dry run, install the Flutter
  build over it, check that the saved login still decrypts.
- Phone: notifications, wake-up alarm, widget and "a background refresh still runs after a
  reboot without opening the app" are unchecked.
- Windows Sandbox: the over-install test ran before the start-up wiring (`d6fb973`) existed.
  Repeat it on the current build, and seed the key through Python `keyring` (Credential
  Manager), not only as `secret.key`. MSIX over-install is untested.
- STATUS.md has no Checkpoint C notes (deviations, how to verify).

### C-M8 The app runs its own copy of the scheduler instead of core's `PeriodicRunner`
`DesktopBackgroundLoop` (`app/lib/platform/desktop/tray.dart:266-415`) re-implements
`PeriodicRunner`. The stated reason ("core jobs are sync") no longer holds since A-S7: core's
`Job` is `FutureOr` and is awaited (`packages/strakalari_core/lib/src/automation/scheduler.dart`,
13 ported tests). Differences from `strakalari/core/scheduler.py`:

- `runNow` (`tray.dart:329, 359-381`) moves `_lastRun`; Python's `run_now` never touches the
  timer (`scheduler.py:136-142`, test `runNowLeavesTimerAlone`).
- No `Error: scheduled job … failed at …` line with the redacted traceback
  (`scheduler.py:108-116`).
- `on_result` per job (heartbeat `scheduler_last_run` after every result, `app.py:934-936`)
  is reduced to a failure hook.

Use core `PeriodicRunner` (jobs `refresh` and `update`, `paused`, `lastRun` seed, `onResult`
chained like `_setup_phone_background`, `app.py:1104-1112`) and delete the copy.

---

## Should-fix

- **C-S1** `single_instance.dart:69-77`: the identity lower-cases the user name and prefers
  `HOME` over `USERPROFILE`. Python is `f"{getuser()}|{normcase(expanduser('~'))}"`
  (`single_instance.py:34-41`): the user name keeps its case and `~` on Windows is
  `USERPROFILE`. A Windows user called `Matou` gets a different port in Dart, so the header's
  "byte-identical" claim is false. `_randomToken` (`:161-168`) still derives the token from
  the clock and pid (BR3-N2, carried twice) and uses `DateTime.now()`; use `Random.secure()`.
  `_validToken` accepts upper-case hex, Python only lower-case.
- **C-S2** `packages/strakalari_core/lib/src/storage/helpers.dart:841`: temp file
  `$path.$pid.tmp` is shared by the two isolates of one process (R2-N1). Add a random suffix
  like `tempfile.mkstemp`.
- **C-S3** `android_channel.dart`: every `PlatformException` is swallowed without a word.
  Python prints `Warning: could not …` for each (`android.py:266, 344, 384, 412, 459, 561`).
  Print the same lines.
- **C-S4** `keystore_desktop.dart:165-187`: a failed first `CredRead` is treated as "not
  found" without looking at the error; `GetLastError()` is read after other calls and is not
  reliable through FFI; an empty stored user name is accepted (keyring goes to the compound
  name). A store that refuses must give `KeyStoreUnavailable`, never a new key.
- **C-S5** `.github/workflows/dart.yml` has no Android job; the Python CI builds and signs the
  APK (`.github/workflows/build.yml:412`). Needed before phase 10 removes `build.yml`.
- **C-S6** R3-N1 is still open: `session_lock_test.dart` `matchesPythonFlock` runs on Linux
  only. Let it run on macOS too.
- **C-S7** `background.dart:309-310` reads the interval as `raw is num ? … : 60.0`; Python is
  `float(get(…, 60) or 60)` with a minimum of 1 (`app.py:1049-1050`): a string or `0` differs.

## Notes

- **C-N1** Accepted: the six Java classes differ from `mobile/strakalari_android` only by the
  added `import …R;` line (`diff -r`); resources identical; permissions, services and
  receivers of the old manifest are all present; `RefreshReceiver`, `StrakalariChannel` and
  `MainActivity` are new. Keystore code is identical in effect (alias
  `strakalari-secret-key`, `AES/GCM/NoPadding`, 12-byte IV prefix, 128-bit tag, 256-bit key).
- **C-N2** Accepted: every `android.py` function has one channel method; `scheduleWake` now
  targets `RefreshReceiver` (request code 7305) instead of `WakeReceiver`. One old alarm may
  still fire `WakeReceiver` once after the update; harmless.
- **C-N3** Question for the owner: `BootReceiver` (unchanged Java) still shows "open the app
  once" after a reboot, although the refresh now restarts by itself. Changing it means
  touching the Java the plan says to keep unchanged.
- **C-N4** Accepted deviations: tray icon always shown; tray menu has Pause; the interval is
  re-read live. `applicationId` unchanged, `.test` only in the `phonetest` flavor; Inno
  `AppId {D94B0B7F-65C1-4D52-9A47-E30D6E26F22B}` unchanged; phone data folder
  `getApplicationSupportDirectory()/data` equals the Flet build's (`main.dart:363-364` there).
- **C-N5** Not looked at closely, carry to the re-review: `autostart.dart` line by line,
  `desktop_notify.dart` (13 tests exist), `tools/make_msix.py --app-dir`, R-N1, R-N2, R-N6,
  A-N3, the PowerShell toast's console window, the MSIX and the VC++ runtime.

## Unverified, for the owner's CI run (not passed)

All macOS and Linux code: key stores through `security` / `secret-tool`, autostart plist and
`.desktop`, tray, single instance, `flock` (job `dart-macos-locks`), `.dmg`, AppImage, and
every release job in `dart.yml`.

## What I verified, and how

Flutter 3.44.8 / Dart 3.12.2, Windows 11, 12 Nov 2026. Nothing contacted except localhost.
The main checkout's data files were not opened.

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / 777 passed, 2 skipped |
| `flutter analyze` / `flutter test` (app) | clean / 506 passed, 1 skipped |
| Python suite | 1643 passed |
| `tools/parity/dump.py` + `git diff --exit-code` on `test/parity/` | clean |
| `packaging_privacy_test.dart` with `STRAKALARI_APK` = the built `phonetest` debug APK | 5 passed |
| Java / resources / manifest | `diff -r` against `mobile/strakalari_android`; old Flet manifest read from the last Python phone build |
| C-B1 | throwaway test, output above; removed again |
| C-B2 | read against `keyring/backends/Windows.py`; `cmdkey /list` names only |
| Hygiene | no upstream; author DeNdlerX; no `Co-Authored-By` / `Claude-Session`; no personal file ever added; no Python change since `1e94e67`; `main` (`0ffdcff`) is an ancestor |
| Architecture | no `package:flutter` in core sources; no build_runner; workspace `pubspec.lock` committed; Flutter 3.44.8 pinned in `dart.yml` |
| Tests since `1e94e67` | two new files (`scheduler_retry_test.dart` 4, `desktop_notify_test.dart` 13), no `skip:`, no loosened assertion, no existing test changed |

**Not verified:** nothing was run on the phone or in Windows Sandbox in this review (the
blockers above come first; the owner was not asked to confirm the phone's state). C-M1 is from
reading the code. `session.lock` Python↔Dart was not re-run by hand (covered at Checkpoint A
and by `session_lock_test.dart`).

---

## Re-review (2026-11-13)

Reviewed at `f237bef`: the 37 commits `259cfbf..f237bef`. Fresh session; the reviewer changed
no code (one throwaway probe test was run and deleted again).

### Verdict: **FAIL** (narrow)

All 4 blockers and the must-fix items C-M1 … C-M6 and C-M8 are fixed in the code, and every
should-fix C-S1 … C-S7 is done. What is left: **2 new must-fix** (CR-M1, CR-M2), **2
should-fix**, and the desktop half of **C-M7**, which the owner put off on purpose. No
blocker is open.

### Earlier findings

| Finding | State | How checked |
|---|---|---|
| C-B1 key thrown away on every start | fixed | `android_keystore.dart:61-88, 111-114, 170, 197, 242` keep the raw blob; `android_keystore_test.dart` (6) runs warm-up then core `getKey`; read against `secret_store.py:194-240`. But see CR-M1. |
| C-B2 Credential Manager overwrite / delete | fixed | `win_credentials.dart:119-179` read line by line against `keyring/backends/Windows.py` (`_resolve_credential`, `set_password`, `delete_password`, `_read_credential`, `_delete_password`): same order, same conditions, same comment, UTF-16LE blob. `keystore_windows_test.dart` (13). |
| C-B3 automation with background off | fixed | `background.dart:126-149` reads `run_in_background` before anything else and cancels the wake; `runHeadlessTick` (`:284-316`) uses `registerJobs` (the gates of `app.py:952-957`), runs only when due, arms the due time otherwise. `android_background_test.dart` (8). |
| C-B4 no INTERNET in release | fixed | `AndroidManifest.xml:5`, checked by `packaging_privacy_test.dart:115`. |
| C-M1 dead UI port | fixed | `background.dart:78-89, 186-206`: acknowledgement first, 5 s, stale name removed, `detached` unregisters (`startup.dart:127`). The session lock is `flock` through FFI (`helpers.dart:391-432`), so two isolates do exclude each other. `android_handoff_test.dart` (4). |
| C-M2 notification permission | fixed | `MainActivity.kt:16`, `StrakalariChannel.java:124`. Seen on the phone by the migrating agent. |
| C-M3 CPU awake | fixed | `StrakalariChannel.java:413-449`, `background.dart:210-218`, held around the refresh job (`scheduler_jobs.dart:72-76`). |
| C-M4 app identity | fixed | manifest label / `allowBackup` / back callback, icons, `pubspec.yaml` `0.1.0+10099`; `build_number.dart` equals `make_mobile.py:211-223`; `icons_test`, `version_sync_test`, `build_number_test`. |
| C-M5 debug-signed release | fixed | `build.gradle.kts:103-115` stops `preProdReleaseBuild` without the key. |
| C-M6 tests not ported | fixed | Python case counts taken with `pytest --collect-only` and compared with the Dart files; every *Dropped* reason is a Flet-child / tray-parent / Python-import subject that does not exist in the one-process app. Accepted. |
| C-M7 checkpoint conditions | **phone half done, desktop half open** | see "Not verified" below. |
| C-M8 own scheduler copy | fixed | `tray.dart` copy deleted; `scheduler_jobs.dart` on core `PeriodicRunner`; `register_jobs_test.dart` (4). |
| C-S1 … C-S7 | fixed | read each diff: identity (`single_instance.dart:71-107`), `mkstemp` (`helpers.dart:882-905`), warning lines, `WinCredError` handling, CI Android job, flock test on macOS, `checkIntervalMinutes`. |
| C-N3 reboot notice | accepted | owner's decision; `BootReceiver.java` now differs from `mobile/strakalari_android` by 29 lines (the notice removed), the other moved classes still only by the `R` import. |

### New findings

#### Must-fix

**CR-M1 Android: a plain `secret.key` that differs from the wrapped key is deleted, and the
passwords are lost on the next start.**
`app/lib/platform/android/android_keystore.dart:182-189`: when `secret.key` and
`secret.key.wrapped` hold different keys, the warm-up correctly returns the file's key, but
registers `WarmedAndroidKeystore(fileKey, blob)`. Core then runs its own pass
(`packages/strakalari_core/lib/src/storage/secret_store.dart:105-120`): `unwrap(blob)` now
answers `fileKey`, the two keys look equal, and line 119 deletes `secret.key` as a "leftover
of a migration". On the next start only the wrapped key exists, which is the *other* key, so
nothing saved under the file's key decrypts any more. Python
(`strakalari/core/secret_store.py:216-220`) returns the file's key and **keeps the file**.

Proven with a throwaway test (same fake channel as `android_keystore_test.dart`; fresh start,
then a second valid key written to `secret.key`, then two starts):

```
Warning: secret.key differs from secret.key.wrapped; using the file.
PROBE warmed==k1: true
PROBE core==k1: true
PROBE secret.key exists after start: false
PROBE next start key==k1: false  ==k2: true
```

Correct: in this branch the bridge must answer core with what the Keystore really said, so
core reaches the same "differs, using the file" branch and keeps the file: register a bridge
whose `unwrap(blob)` returns the **Keystore's** key (`key`, not `fileKey`). Add the case to
`android_keystore_test.dart`: after the start `secret.key` still exists, a second start
returns the same key, and both files are unchanged (as in Python).

**CR-M2 Android: a headless run that takes longer than ten minutes is killed, and no further
refresh is ever scheduled.**
`app/android/app/src/main/java/io/github/dendlerx/strakalari/android/RefreshReceiver.java:48, 169-177`:
after `HOLD_MS` (10 min) `giveUp()` destroys the engine. Its comment says "the armed wake
retries", but during an inline run no wake is armed: the alarm that started the run is used
up, and the next one is only set at the end of `runHeadlessTick`
(`app/lib/platform/android/background.dart:314`). So a slow run (the job itself may wait up
to 30 minutes, `app/lib/controllers/activity.dart:256-258` = `_REFRESH_JOB_WAIT_S`,
`strakalari/flet_ui/app.py:930`; `KeepAwake` is also 30 minutes) is cut off in the middle and
background refreshes stop until the user opens the app, without a word. The same happens when
the Dart side dies before it reports `backgroundDone`. This is exactly what the headless
entry was built to end.

Correct: (1) `HOLD_MS` must cover the longest allowed run (the 30-minute job wait plus the
60 s update wait); (2) `giveUp()` must arm a retry wake itself (`AlarmManager` with
`wakeIntent`, about 5 minutes ahead, the scheduler's retry time), and log a warning line;
(3) `runHeadlessTick` should arm a fallback wake before `runAllOnce()` as well, so a killed
process also comes back. Add a Dart test that a wake is armed before the job starts.

#### Should-fix

- **CR-S1** `app/test/packaging_privacy_test.dart:118-131` scans the raw APK bytes, so it
  fails on a real release APK (it finds the file *names* `secret.key` and
  `already_excused_lessons.json` inside the compiled code; reported by the migrating agent
  under Questions). Answer to that question: yes, use the ported `check_package`
  (`packages/strakalari_core/tool/android_build.dart`, what `tools/make_mobile.py` does:
  the archive's file list plus machine paths), so the one privacy check that exists is the
  one that passes on the release build.
- **CR-S2** `app/lib/platform/startup.dart:272-275` (`PhoneBackground.scheduleWake`) uses
  the interval cut to a whole number, Python uses the runner's own value
  (`_schedule_phone_wake`, `app.py:1026`: `runner.interval_minutes`). With an interval like
  2.5 the alarm fires before the runner is due and is re-armed in the past until it is. Use
  `loop.intervalMinutes` like `background.dart:347`.

#### Notes

- **CR-N1** `app/test/android_background_test.dart` `theHeadlessRunActuallyRunsItsJobs`
  checks the source text of `background.dart`, not behaviour. Accepted (the phone run is the
  real proof), but do not add more tests of this kind.
- **CR-N2** A crash between `createSync(exclusive: true)` and the write
  (`android_keystore.dart:215-221`) leaves an empty `secret.key.wrapped`; every later start
  then waits 3 s and keeps the plain file. Safe, only slow. No change required.
- **CR-N3** For the owner (open questions in STATUS.md): the Settings → Background hint
  still says "open it once after a reboot or update" although that is no longer needed;
  changing it is a text change in both languages and is the owner's call. The exact-alarm
  permission being withdrawn by Android after an update is Android's behaviour and the app
  already warns about it; nothing to change.
- **CR-N4** For Checkpoint D: `TestMsixVersion` and `test_store_submit_loads` live only in
  the Python suite; phase 10 must keep or port them, since `tools/make_msix.py` stays.
  `bg_boot_title` / `bg_boot_text` are still sent to the service but no longer shown.
- **CR-N5** Still not looked at closely (carried from C-N5): `desktop_notify.dart` and the
  PowerShell toast's console window, the MSIX and the VC++ runtime, R-N1, R-N2, R-N6, A-N3.

### Not verified (not passed on trust)

- **Windows Sandbox (C-M7, desktop half):** installing the Flutter installer and the Flutter
  MSIX over the Python ones, with the key held in Credential Manager. Put off by the owner
  until the migration is complete; the migrating agent also reports that today's Sandbox
  refuses unsigned programs. This stays a release condition: it must pass before
  Checkpoint D can pass. The 2026-11-12 Sandbox run predates the start-up wiring and does
  not count.
- **Phone:** the over-install over the Flet `.test` build, notifications, reboot, wake-up
  alarm and widget are the migrating agent's results (STATUS.md, 2026-11-13). The reviewer
  did not repeat them on the phone in this session. The wake-up alarm was armed but never
  rang. Nothing in STATUS.md or the commits shows a test against the Play app or the
  owner's real installation; the one mis-placed Play-app widget was removed at once.
- **macOS and Linux:** all of it, as listed in the first review, plus the new `chmod 600`
  on the instance token and the macOS flock test. For the owner's CI run.

### What I verified, and how

Flutter 3.44.8 / Dart 3.12.2, Windows 11, 13 Nov 2026. Nothing contacted except localhost.
The main checkout's data files were not opened.

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / 801 passed, 2 skipped (one is the flock probe: Linux and macOS only) |
| `flutter analyze` / `flutter test` (app) | clean / 637 passed, 1 skipped (APK scan needs `STRAKALARI_APK`) |
| Python suite | 1643 passed |
| `tools/parity/dump.py` + `git diff --exit-code` on `test/parity/` | clean, working tree unchanged |
| Test integrity | diff of every existing test file since `259cfbf`: only additions, the Linux-only skip widened to macOS, the `no_wall_clock` exception removed. New `skip:` only for OS-bound cases. No loosened assertion. |
| Pitfalls | every new `RegExp` and `catch (_)` in the changed Dart read; none in send, order or save code; no `DateTime.now()` (the test's last exception is gone) |
| Scope | no change under `strakalari/`, `tests/`, `tools/`, `mobile/`, `installer.iss` since `259cfbf`; `main` (`0ffdcff`) is an ancestor and is the last ported commit |
| Architecture | no `package:flutter` in core `lib`, `bin`, `tool`; no build_runner; workspace `pubspec.lock` committed; Flutter 3.44.8 and `--enforce-lockfile` in every `dart.yml` job |
| Java | `diff` against `mobile/strakalari_android`: six files differ by the `R` import only, `BootReceiver.java` by the removed notice, four are identical |
| Hygiene | no upstream; 37 commits by DeNdlerX; no `Co-Authored-By` / `Claude-Session`; no personal file ever added; APK asset name equals `build.yml`'s |
| CR-M1 | throwaway probe test, output above; deleted again |
| CR-M2 | read from `RefreshReceiver.java` and `background.dart`; not run |

---

## Re-review 2 (2026-11-13)

Reviewed at `263f3d8`: the 9 commits `8fd21c5..263f3d8` (the four fixes `4ad019b`, `02646b5`,
`c474019`, `45c5d6c`, the STATUS commit `ef66763`, and four Phase 9 commits made before this
re-review: `9d868c5`, `2f2b0f6`, `c4e7be2`, `263f3d8`). Fresh session; the reviewer changed no
code.

### Verdict: **PASS WITH FIXES**

CR-M1, CR-M2, CR-S1 and CR-S2 are fixed in the code and tested. No blocker and no must-fix is
open. Left: **3 should-fix** below, and the desktop half of **C-M7** (Windows Sandbox
over-install with the key in Credential Manager, and the MSIX), which the owner put off on
purpose. C-M7 is not passed: it stays a release condition and must pass before Checkpoint D
can pass.

### Findings of the last re-review

| Finding | State | How checked |
|---|---|---|
| CR-M1 differing `secret.key` deleted | fixed | `app/lib/platform/android/android_keystore.dart:187` registers the bridge with the Keystore's key, so core (`packages/strakalari_core/lib/src/storage/secret_store.dart:112-117`) reaches the same "differs, using the file" branch as `strakalari/core/secret_store.py:216-220` and keeps the file. `android_keystore_test.dart` `differingPlainKeyIsKeptAlongsideWrappedKeyAcrossStarts`: two starts, same key, both files byte-identical. |
| CR-M2 headless run killed, no retry | fixed | `RefreshReceiver.java:52-53` (32 min hold, 5 min retry), `:158-178` `giveUp()` logs a warning and arms the wake through the same `wakeIntent` and the same `setAndAllowWhileIdle` call as `StrakalariChannel.scheduleWake` (`:392-402`). `app/lib/platform/android/background.dart:301-320`: a fallback wake one interval ahead before `runAllOnce()`, the real wake in `finally`. `android_background_test.dart` `fallbackWakeIsArmedBeforeTheJobStarts` checks the order against the fake channel. Both Java flavors compile (`:app:compilePhonetestDebugJavaWithJavac`, `:app:compileProdReleaseJavaWithJavac`, run by the reviewer). Not run on the phone. |
| CR-S1 privacy test on a release APK | fixed | `app/test/packaging_privacy_test.dart:128-143` uses `checkPackage` / `buildPathMarkers` (`packages/strakalari_core/tool/android_build.dart:47-101`), read against `tools/make_mobile.py:379-436`: same markers, same nested-zip walk, same two checks. Run by the reviewer with `STRAKALARI_APK=dist/flutter-android/Strakalari-0.1.0-android.apk`: 5 passed. |
| CR-S2 whole-number interval | fixed | `app/lib/platform/startup.dart:274` uses `loop.intervalMinutes` (`app.py:1026`); `android_phone_background_test.dart` `scheduleWakeUsesRunnersFractionalInterval` (2.5 min gives +2:40). |

### New findings

#### Should-fix

- **CR2-S1 Android: a headless start that fails leaves no wake armed.**
  `app/android/app/src/main/java/io/github/dendlerx/strakalari/android/RefreshReceiver.java:128-150`.
  (a) `FlutterCallbackInformation.lookupCallbackInformation(handle)` returns `null` when the
  stored handle is not known to this build (possible after an app update); the code passes
  that `null` on, the start throws, and the `catch` only calls `release(appCtx)`.
  (b) Any other exception at start ends the same way. In both cases the alarm that started
  the run is used up and Dart never ran, so nothing armed the next one: background refreshes
  stop without a word until the app is opened, the case CR-M2 was about.
  Correct: when `info == null`, fall back to the named entry point `backgroundMain` (the
  `else` branch already there); in the `catch`, write a `Log.w("strakalari", "Warning: …")`
  line and arm the same 5-minute retry wake that `giveUp()` arms (share one helper). No Dart
  change needed.
- **CR2-S2 The "real-submit proof" in STATUS.md cannot be repeated from the repository.**
  `STATUS.md` (Checkpoint D notes) and `docs/flutter-migration/SOAK.md` (log line of
  2026-11-13) say a real submit with `--send-day 09.11.2026` was "IDENTICAL" on both sides.
  Only the Dart side has that option (`packages/strakalari_core/bin/refresh_dryrun.dart:75`);
  `tools/parity/soak_refresh.py` has no `--send-day`, and SOAK.md itself calls it
  "dry-run-only tooling". How the Python side was run is not recorded and no script for it
  is committed. Correct: add the option to `tools/parity/soak_refresh.py` (allowed: it is
  under `tools/parity/`), doing what the Dart side does (`excuse_mode: confirm`, one
  whole-day submit through `send_excuse`, refused unless the host is `127.0.0.1`,
  `localhost` or `[::1]`), fix the SOAK.md sentence, and re-run the proof with a fresh demo
  server per side. Or remove the claim. Checkpoint D will not accept it as it stands.
- **CR2-S3 STATUS.md contradicts itself at the top.** Lines 29–39 still say phases 7 and 8
  are "in progress, unreviewed … On-phone verification pending" and "Checkpoint C: platform
  review (unreviewed)"; the Modules table still marks most UI rows "in progress,
  unreviewed" although Checkpoint B passed. Bring the header and the State column in line
  with the Checkpoint notes (Checkpoint D checks that nothing in STATUS.md is left open or
  wrong).

#### Notes

- **CR2-N1 Process.** Next step after the last re-review said "then stop for re-review".
  The four Phase 9 commits were made anyway. They are reviewed here and nothing wrong was
  found in them, but the rule stands: at "stop for re-review", stop.
- **CR2-N2** `packages/strakalari_core/lib/src/platform/desktop_notify.dart:55-60, 170-278`
  (`CreateProcessW`, `CREATE_NO_WINDOW`, `STARTF_USESHOWWINDOW` + `SW_HIDE`, like
  `strakalari/core/notify.py:131-142`): struct layout, quoting (`CommandLineToArgvW` rules,
  as Python's `list2cmdline`), handle and heap clean-up and the timeout kill read line by
  line; accepted. The test `returnsExitCodeAndEnforcesTimeoutWithoutConsoleWindow` checks
  exit code and timeout only; that no console window flashes can only be seen by eye in a
  release build. Add it to the Sandbox checklist (C-M7).
- **CR2-N3** `RefreshReceiver.java:110, 153`: the wakelock and the give-up timer both run
  out after exactly `HOLD_MS`. Harmless in practice (both fire on the main thread, the lock
  first), no change required; a lock a few seconds longer would remove the doubt.
- **CR2-N4** `.github/workflows/dart.yml:239-248` copies the three VC++ runtime DLLs from
  the runner's `System32` into the MSIX bundle, like `installer.iss:68-70`. Not run by the
  reviewer (no CI, no MSIX install); belongs to the Sandbox test and the owner's CI run.
- **CR2-N5** For Checkpoint D: the README / PRIVACY / CONTRIBUTING wording was changed in
  `2b17249` (2026-11-08), before most of phases 5–8 existed. It has not been reviewed yet
  and must be re-read against the finished app at Checkpoint D. The soak has one day logged
  of the three SOAK.md requires.

### Not verified (not passed on trust)

- **Windows Sandbox (C-M7, desktop half):** unchanged, put off by the owner. Release
  condition for Checkpoint D. Add the toast check of CR2-N2.
- **Phone:** nothing was run on the phone in this session; CR-M2's Java was compiled, not
  exercised. The earlier phone results are the migrating agent's.
- **macOS and Linux:** all of it, as listed in the first review. For the owner's CI run.

### What I verified, and how

Flutter 3.44.8 / Dart 3.12.2, Windows 11, 13 Nov 2026. Nothing contacted except localhost.
The main checkout's data files were not opened.

| Check | Result |
|---|---|
| `dart analyze` / `dart test` (core) | clean / 802 passed, 2 skipped (POSIX permission bits; the flock probe is Linux and macOS only) |
| `flutter analyze` / `flutter test` (app) | clean / 640 passed, 1 skipped (APK scan; run separately with `STRAKALARI_APK`: 5 passed) |
| Python suite | 1643 passed |
| `tools/parity/dump.py` + `git diff --exit-code` on `test/parity/` | clean, working tree unchanged |
| Android Java | both compile tasks `BUILD SUCCESSFUL` (after `flutter build apk --config-only`, which only rewrote the untracked `local.properties`) |
| Dry-run parity (Phase 9 claim) | own demo server on localhost, fresh throwaway folders: `soak_refresh.py` vs `bin/refresh_dryrun.dart` gives `IDENTICAL (modulo ts)`; a second run on the same folders gives `IDENTICAL (modulo ts)`; `fetch.py` vs `parity_fetch.dart` byte-identical (31116 bytes); 4 audit lines on each side |
| Test integrity | diff of all test files since `8fd21c5`: 102 lines added, 1 removed (the raw-byte scan replaced by `checkPackage`, as CR-S1 asked). No `skip:` added, no loosened assertion; the one new `isNotNull` is followed by value checks |
| Pitfalls | one new `RegExp` (`[\s"]`, command-line quoting, no Python pattern to match); no new `catch (_)`, no `DateTime.now()`, no `jsonEncode`, no date maths in the changed Dart |
| Scope | no change under `strakalari/`, `tests/`, `tools/`, `mobile/`, `installer.iss` since `8fd21c5`; `git log flutter-migration..main` is empty, `0ffdcff` is the last ported commit |
| Architecture | no `package:flutter` in core; no build_runner; `pubspec.lock` committed; Flutter 3.44.8 pinned in `dart.yml` |
| Hygiene | no upstream; 9 commits by DeNdlerX; no `Co-Authored-By` / `Claude-Session`; no personal file added (`test/parity/config.json` is the known fixture) |

---

## Re-review 3 (2026-11-13)

### Verdict: **PASS**

The owner asked the reviewer to fix the three should-fix items of re-review 2 itself and to
accept the result. So these fixes were written and checked by the same reviewer; they are
not independently reviewed. Checkpoint D should read them once more.

| Finding | Fix | How checked |
|---|---|---|
| CR2-S1 failed headless start leaves no wake | `RefreshReceiver.java`: an unknown callback handle (`lookupCallbackInformation` gives `null`) falls back to the named entry point `backgroundMain`; a start that throws writes a warning line and arms the 5-minute retry through `armRetry`, which `giveUp()` now shares. | Both Java flavors compile (`:app:compilePhonetestDebugJavaWithJavac`, `:app:compileProdReleaseJavaWithJavac`). Not run on the phone. |
| CR2-S2 real-submit proof not repeatable | `tools/parity/soak_refresh.py --send-day DD.MM.YYYY`: `confirm` mode, one whole-day `excuse_single`, the seeded dry-run step skipped, refused unless the host is `localhost` / `127.0.0.1` / `[::1]`, as `bin/refresh_dryrun.dart` does. SOAK.md corrected and the run logged. | Guard refused `http://example.com` (exit 1). Proof run with a fresh demo server per side, `--send-day 09.11.2026`: `IDENTICAL (modulo ts)`; 5 outbox and 5 history entries on each side, empty unconfirmed file. Python suite 1643 passed. |
| CR2-S3 STATUS.md contradicted itself | Header, Modules State column and test mapping no longer say "in progress, unreviewed"; Checkpoint C marked passed with the open Sandbox half. | Read. |

No Dart file changed, so the Dart suites of re-review 2 (core 802 passed / 2 skipped, app 640
passed / 1 skipped, analyzers clean, parity JSON clean) still stand.

**Still open, not passed:** the Windows Sandbox over-install test (C-M7, desktop half,
including the toast check of CR2-N2), deferred by the owner; it must pass before Checkpoint D
can pass. Nothing was run on the phone in this review (CR-M2 and CR2-S1 are compiled, not
exercised there). macOS and Linux remain unverified, for the owner's CI run.
