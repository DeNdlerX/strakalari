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
