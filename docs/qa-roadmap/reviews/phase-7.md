# R7 review: F5 (iOS preparation)

Reviewed 2026-11-21 at `qa-roadmap` @ `a47f915` (base `main` @ `9fc53a1`;
`main` has no commits the branch lacks, so no merge was needed at the
phase start; the branch has no upstream). Commits since the R6 merge note
(`9fc53a1`):

- `af118ec` STATUS: the owner's "go" and D5 answers;
- `52ba12b` F5 commit 1: `app/ios/` runner, bundle id, `Info.plist`,
  Keychain channel in `AppDelegate.swift`, icons;
- `55dca7c` F5 commit 2: iOS Keychain key store, Darwin `flock` fix,
  iOS startup and `mobilePlatform()` guards;
- `b37f8a5` F5 commit 3: `build-flutter-ios` CI job and
  `docs/IOS_SIDELOADING.md`;
- `a47f915` STATUS (handover).

Checked against PLAN §6 (phase 7), §9, the owner's D5 answers in STATUS
(word for word, with the reviewer's reading of the CI answer),
CONTRIBUTING §5–6 and every earlier review.

## Verdict: FAIL

Most of F5 is done well. `app/ios/` is exactly what `flutter create`
makes with Flutter 3.44.8 (the reviewer compared every file with the
template): the only changes are the D5 bundle id, the app's name and
languages in `Info.plist`, the Keychain channel in `AppDelegate.swift`
and the app's own icon. `Info.plist` asks for no permission, background
mode or network exception. No Android-only call runs on iOS: the
reviewer read every `AndroidChannel`, Android key store, wake-up, widget
and background call site, and the new tests check the startup, the
wizard, Settings and *Více* on iOS with zero Android calls. The Keychain
item is readable after the first unlock (`AfterFirstUnlockThisDeviceOnly`),
and a locked Keychain never makes the app create a new key. The `flock`
fix makes the session lock work on iOS at all (before it, iOS used Linux
flag values). The CI job builds an unsigned `.ipa` under the same
condition as Android, with every action pinned to the same commit SHAs as
the other jobs. All suites are green, nothing was removed, skipped or
weakened, and no config key, string, tutorial, parity fixture or
`pubspec.lock` entry changed.

One finding blocks the pass:

- **M1:** on an iPhone the key that protects the saved passwords is
  filed in the Keychain under a name made from the app folder's full
  path. iOS changes that path when the app is installed again or
  updated, which the 7-day renewal in the new doc does every week. After
  that the app can't find its key, makes a new one, and every saved
  password (Bakaláři, Strava, every account) can no longer be read. The
  reviewer reproduced it with a test.

Three should-fix (S1–S3) and ten notes. No owner decision is needed.

---

## Must-fix

### M1 (F5, `55dca7c`): an update on the iPhone makes the saved passwords unreadable

- **Where:** the Keychain item's name is `entryName(dataDir)`
  (`packages/strakalari_core/lib/src/storage/secret_store.dart:63`), a
  hash of the folder's **absolute** path. The iOS warm-up uses it
  (`app/lib/platform/ios/ios_keystore.dart:165`, also `hasEntry` `:63`
  and `removeEntry` `:84`), and core's `getKey` → `_loadOrCreate` reads
  the same name. On iOS that path is
  `…/Containers/Data/Application/<UUID>/Library/Application Support/data`
  (`app/lib/platform/startup.dart:106–109`), and the `<UUID>` part is not
  stable: iOS gives the app's container a new path when the app is
  installed over or updated (Apple's advice is never to keep absolute
  container paths; the files move along, Keychain items stay). Re-signing
  with a free Apple ID every 7 days is such a reinstall
  (`docs/IOS_SIDELOADING.md:81`), and so is every new version.
- **What happens then:** the warm-up deleted `secret.key` after moving
  the key into the Keychain (`ios_keystore.dart:191`, `:209`), so the next
  start finds neither a Keychain item under the new name nor a file, and
  creates a new key (`:199`) for the root and for every account. The old
  passwords stay encrypted with the old key: `decryptStrict` gives `null`,
  plain `decrypt` falls through to the legacy cipher, logins fail on
  every refresh until the user types every password again, in every
  account, after every update.
- **Reviewer's check** (throwaway app test, not committed): iOS
  `prepareStartup` with a fake Keychain in folder `UUID-A`, a password
  encrypted for `accounts/default`; the files copied to `UUID-B` and
  `UUID-A` removed, the Keychain items kept, the key caches cleared;
  `prepareStartup` again in `UUID-B` → the Keychain went from 2 to 4
  items (two new keys) and `decryptStrict(cipher, dataDir:
  UUID-B/data/accounts/default)` is `null`. Fails at `a47f915`.
- **Correct:** on iOS the Keychain name must not depend on the
  container's absolute path. Build it from the folder's path **relative
  to the app's data root** (the folder given to `setMobileDataDir`, so
  `data` and `data/accounts/<id>`), only when running on iOS; core's
  `getKey`, the iOS warm-up, `hasEntry`, `removeEntry` and `forgetKey`
  must all use that same name. Desktop and Android names stay exactly as
  they are (`entryName` is pinned by parity tests and by today's
  installs). Nothing has shipped on iOS yet, so no fallback to the old
  names is needed.
- **Test:** an app test like the reviewer's: start on iOS in container
  A, save a password, move the files to container B with the same fake
  Keychain, start again → the password opens with the account's own key,
  the Keychain holds no new item and no `secret.key` was written. It must
  fail at `a47f915`. Keep the existing `ios_platform_test.dart` cases
  green (they check the absolute-path name in the multi-account test at
  `:233–236`; change only what the new rule requires there and say so in
  the commit message).

---

## Should-fix

### S1 (F5 test, `55dca7c`): the `flock` test doesn't test the fix

The fix is that iOS now counts as Darwin when the `open(2)` flag and the
C library are chosen (`helpers.dart:560–570`, `Platform.isMacOS ||
Platform.isIOS`). `darwinAndLinuxPosixFlockConstants`
(`packages/strakalari_core/test/helpers_test.dart:248–256`) passes
`isDarwin:` itself, so it never runs that choice: with `|| Platform.isIOS`
removed again, it stays green (reviewer's check). Without the fix every
lock on iOS fails to open its file and every refresh reports "busy".
**Correct:** let the functions take the OS name (for example
`{String? os}` defaulting to `Platform.operatingSystem`) and decide
Darwin from it; test `ios` and `macos` → `0x200` and
`/usr/lib/libSystem.dylib`, `android` → `64` and `libc.so`, `linux` →
`64` and `libc.so.6`. It must fail when `ios` is dropped from the Darwin
check.

### S2 (F5 test, `55dca7c`): the iOS "wait while in the background" wiring is untested

On iOS, `startPlatformServices` now listens to the app's state so the
scheduler doesn't start a refresh while the app is in the background
(`app/lib/platform/startup.dart:246–251`, the same rule Android has:
"the OS freezes it there, mid-run"). Removing the listener keeps every
test green (reviewer's check). **Test:** on iOS, after
`startPlatformServices` (the `onLoopCreated` seam gives the loop), send
`AppLifecycleState.paused` through the binding → `loop.paused!()` is
`true`; send `resumed` → `false`. It must fail without the listener.

### S3 (F5 docs, `b37f8a5`): `docs/IOS_SIDELOADING.md` promises more than is known

- **`:5`** says the screens, the wizard, accounts and the Keychain "all
  work". Nothing has been built or opened on an iPhone yet (PLAN §6:
  everything stays unverified until the owner's CI run). Say they are
  expected to work and are not yet tested on an iPhone.
- **`:81`** says the saved keys "stay intact" across the 7-day
  reinstall. Today that is false (M1). After M1, say what is expected and
  that it is untested until the first renewal on a real iPhone.
- **`:50–53` (Option C)** `dart pub get` alone doesn't let Xcode build
  the app: the Mac needs Flutter 3.44.8 installed and `flutter pub get`
  (or `flutter build ios --config-only`) run in `app/`, which writes
  `ios/Flutter/Generated.xcconfig` that `Debug.xcconfig` /
  `Release.xcconfig` include. Add that step.
- **`:13–16` (Step 1)** the artifact is deleted 14 days after the run
  (`retention-days: 14`, `.github/workflows/dart.yml:539`). Say so, and
  that an older version needs a new run.
- **`:7`** "push notifications": the app has no notifications on iOS at
  all yet (they are only recorded inside the app, `AppNotifierBackend`).
  Say "notifications".

Keep it in plain words, as now.

---

## Notes (no action needed unless stated)

- **N1 (deviations, accepted):** (1) a small Swift Keychain channel
  instead of a new package keeps `pubspec.yaml` and `pubspec.lock`
  untouched and mirrors Android's warmed key store; (2) the job name
  `build-flutter-ios`, and the `.ipa` as a workflow artifact only, not on
  the public release: an untested internal build never blocks or joins a
  release (`release-flutter` doesn't wait for it); (3) the app's own
  icon instead of Flutter's placeholder (15 PNGs, each the size its name
  says, opaque RGB as Apple requires); (4) `.metadata` gained only the
  `ios` entry.
- **N2 (scope):** besides `app/ios/`, the CI job and the doc, F5 changed
  Dart code. Each change is what the plan's guards and Keychain need:
  the iOS startup branch (data folder, account layout, Keychain warm-up),
  the `mobilePlatform()` guards in Settings, the wizard, `AppState` and
  startup, the iOS key store, and the `flock` fix the session lock needs.
  One extra: `_restrictPermissions` skips `chmod` on iOS
  (`secret_store.dart:232`); the old `try`/`catch` already covered it,
  harmless, accepted.
- **N3:** on Android and desktop nothing changes: `_isAndroid` /
  `mobilePlatform() == 'android'` equal `Platform.isAndroid` in the app
  (`FLET_PLATFORM` is never set there), and `ensureWarmed` was already a
  no-op off Android. No screen changes on any platform, so no
  screenshots and no phone run were needed.
- **N4 (backup to a new iPhone):** the Keychain item is
  `ThisDeviceOnly`, so restoring an iPhone backup onto another phone
  brings the files but not the key, and the passwords must be typed
  again. Android's Keystore behaves the same. Fine for internal testing.
- **N5:** the Swift test (`ios_project_config_test.dart`) checks text, so
  it can't tell whether the update path still sets the accessibility
  (reviewer removed it there; the test stayed green). The code sets it on
  both paths; real proof needs a Mac.
- **N6 (iPad):** *Sdílet* in the error dialog calls the share sheet
  without an anchor (`error_dialog.dart:142`), which iPads may refuse;
  the error is caught and the copy button still works. Not in the plan.
- **N7:** `mobileStore()` reports `app_store` on iOS, so a sideloaded
  build shows no update notice. Fine while iOS is internal.
- **N8:** on iOS there are no OS notifications, no background refresh,
  no widget and no alarm; the wizard skips the *Telefon* step. That
  matches PLAN ("preparation") and the doc's Android-only list.
- **N9:** the three F5 commit messages have no body. Each commit has a
  test, so none was needed.
- **N10 (STATUS):** the F5 row's evidence is "—", which is right: there
  is nothing to capture until the CI run.

---

## Done when (PLAN §6 phase 7)

- **`flutter create --platforms=ios .`, only `app/ios/` (+ `.metadata`):**
  ✔ every file equals Flutter 3.44.8's template apart from the changes in
  N1 and the Keychain channel.
- **Bundle id and CI trigger as D5 says:** ✔ `io.github.dendlerx.strakalari`
  in Debug/Release/Profile (`.RunnerTests` for tests); the job runs under
  `build-flutter-android`'s condition (`needs: meta`, `release == 'true'`).
- **Info.plist only what is used:** ✔ display name, bundle name,
  `cs`/`en`; nothing else beyond the template.
- **No Android-only call runs on iOS:** ✔ (reviewer's grep of `app/lib`
  plus the five guard tests).
- **Keychain accessibility allows background reads:** ✔
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on add and update;
  ✘ the item's name changes with the container path (M1).
- **`ios` job builds an unsigned `.ipa`, actions pinned to SHAs:** ✔ the
  same four SHAs as the other jobs.
- **`docs/IOS_SIDELOADING.md` in plain words:** mostly ✔; S3.
- **Everything marked unverified:** ✔ in STATUS (F5 row and phase notes).

## Each part caught by a test (reviewer undid it, one at a time, at `a47f915`)

| Undone | Caught? |
|---|---|
| `AppState.ensureWarmedFn` iOS branch | yes |
| wizard permission request guarded on iOS | yes |
| iOS `setMobileDataDir` in `prepareStartup` | yes |
| `setPassword` refusing an unverified write | yes |
| marking a locked Keychain unavailable (no new key) | yes |
| iOS counted as Darwin for `flock` (`helpers.dart:560–570`) | **no** (S1) |
| iOS background-pause listener (`startup.dart:246–251`) | **no** (S2) |
| Swift accessibility on the update path | **no** (N5) |

Parent runs: `ios_project_config_test.dart` from `52ba12b` at `af118ec`
fails only because the files don't exist yet; from `b37f8a5` at
`55dca7c` its CI test fails with an assertion (`Missing
build-flutter-ios job`) and its doc test on the missing file.
`ios_platform_test.dart` and the new `helpers_test.dart` case call code
`55dca7c` added and can't compile at `52ba12b`; they were judged by
reading and by the table above.

## Unverified until the owner's CI run and an iPhone

1. `AppDelegate.swift` compiles. (The API it uses,
   `FlutterImplicitEngineBridge.applicationRegistrar` and its
   `messenger()`, exists in Flutter 3.44.8's engine headers; the reviewer
   checked.)
2. `flutter build ios --release --no-codesign` succeeds on
   `macos-latest`, with the plugins `path_provider_foundation`,
   `url_launcher_ios` and `share_plus` (Swift Package Manager or
   CocoaPods), and the `.ipa` is packed.
3. The `.ipa` installs with Sideloadly or AltStore and opens.
4. The Keychain on a real iPhone: the first start creates the key, a
   second start finds it, and (after M1) a reinstall over the app keeps
   the passwords.
5. The session lock (`flock` through `libSystem`) works: a refresh runs
   and never reports "busy" by itself.
6. The app in daily use: the wizard, a refresh against the school, the
   scheduler pausing in the background.

## What the reviewer verified, and how

1. **Suites**, at `a47f915` after `dart pub get --enforce-lockfile`: core
   `dart analyze` no issues, `dart test` **880 passed, 2 skipped**; app
   `flutter analyze` no issues, `flutter test` **827 passed, 1 skipped**.
   Both match STATUS and both grew since R6 (879 / 810). Flutter again
   rewrote the line endings of the seven generated plugin registrant
   files; restored to `HEAD`.
2. **Scaffold:** every committed file in `app/ios/` diffed against
   `flutter_tools/templates/app/ios.tmpl` of Flutter 3.44.8; differences
   only as in N1 and the bundle id; `git show 52ba12b -- app/.metadata`
   adds only `ios`.
3. **Icons:** sizes and PNG colour type read from each file header; the
   1024 px icon opened and looked at.
4. **CI job:** read against `build-flutter-android` and
   `build-flutter-macos`; the action SHAs counted across `dart.yml` (one
   SHA per action, used by every job); `dart run
   strakalari_core:build_number` run here (`0.3.0-beta.1` → 30031,
   `0.3.0` → 30099, so a beta numbers below its release) and the
   `-beta` strip for the build name checked.
5. **M1** reproduced with a throwaway app test (above).
6. **Parent runs and eight undo checks** in a throwaway worktree
   (results above).
7. **Android-only calls:** grep of `app/lib` and core for
   `AndroidChannel`, `Platform.isAndroid`/`isIOS`, `androidKeystoreBridge`,
   `wakeupPhoneBridge`, `syncAndroid`, `IsolateNameServer`,
   `androidKeepAwake`: each runs only on Android or is a no-op without
   the Android bridges (`syncAndroid` returns when `wakeupPhoneBridge` is
   `null`, `wakeupAvailable` is false on iOS).
8. **Safety rules:** the `storage/` changes only pick iOS's `flock` flags
   and skip `chmod` on iOS; `controllers/app_state.dart` only adds the
   iOS warm-up. No refresh, send, order, lock, audit or pause code
   changed. The new `catch` blocks are in the Keychain warm-up and
   startup: they print a warning, except the expected "no Keychain
   backend" case and the best-effort removal of a `secret.key` already
   moved into the Keychain (if that fails, the next start removes it);
   the Keychain delete logs its failure.
9. **Test integrity:** `git diff 9fc53a1..HEAD` on test files adds lines
   only; no `skip:`, `anything`, `try`/`catch`; two `isNotNull` are each
   followed by a real check (`isReady`, no Android calls).
10. **Keys, strings, fixtures, tutorials, lockfile:** `git diff --stat
    9fc53a1..HEAD` on `config.example.json`, `config.dart`,
    `test/parity/`, `app/lib/l10n/`, `app/lib/tutorial/`, `pubspec.lock`
    and both `pubspec.yaml` is empty.
11. **Hygiene:** no upstream; `git log qa-roadmap..main` empty; every
    commit by DeNdlerX with no `Co-Authored-By` / `Claude-Session` /
    "Generated with" line; no config, cache, log, `htmls/`, key,
    certificate, provisioning profile or phone screenshot committed; the
    new tests contain no address at all.
12. **Throwaway worktree:** plugin links removed one by one first, then
    `git worktree remove --force`, which unregistered it but couldn't
    delete the folder (Windows long paths); the leftover folder in the
    reviewer's scratch space has no links left. Every one of the 338
    packages in the pub cache still has its `pubspec.yaml`.
13. **Not checked:** anything that needs a Mac or an iPhone (list above);
    the phone (no Android change).

---

## Re-review 2026-11-21

Re-reviewed at `qa-roadmap` @ `e1f452d` (base `main` @ `9fc53a1`; `main`
still has no commits the branch lacks; the branch has no upstream).
Commits since the R7 review (`66aa276`):

- `99e544d` M1: iOS Keychain names from the path relative to the data root;
- `ed691ff` S1: `flock` constants chosen from the OS name, iOS tested;
- `7ad5efc` S2: test for the iOS background pause;
- `4acd2e7` S3: `docs/IOS_SIDELOADING.md` wording;
- `e1f452d` STATUS (handover).

### Verdict: PASS WITH FIXES

All four R7 findings are fixed in the code, and each new test fails on
the code before its fix (or when the reviewer undoes the fix). The
passwords now survive an iPhone update: the Keychain name no longer
contains the app folder's changing path, and every place that reads,
writes or deletes a key uses the same name. Desktop and Android names
are unchanged. Nothing else broke: all suites are green, and test counts
grew (core 880 → 881, app 827 → 829).

Two new should-fix items, both one sentence in
`docs/IOS_SIDELOADING.md`. The first is in the note S3 added, the second
was already there and was missed at R7:

- **S4:** the new 14-day note says to "start a new release run" to get an
  expired `.ipa` again. A release run always publishes a release, so
  following it with an old tag would change a release that's already out.
- **S5:** the privacy line says nothing is sent anywhere except Bakaláři
  and Strava. On iOS, Settings → AI is there too, and with a key it sends
  data to Google Gemini. The README says so; this doc doesn't.

No blocker, no must-fix, no owner decision.

### Should-fix

#### S4 (F5 docs, `4acd2e7`): the 14-day note's remedy would re-publish a release

- **Where:** `docs/IOS_SIDELOADING.md:18`: "If you need an older version
  whose artifact has expired, start a new release run of the **Dart**
  workflow".
- **What is wrong:** the iOS job runs only when `meta` says
  `release == 'true'` (D5, `build-flutter-ios`, `.github/workflows/dart.yml:478`),
  so every run that builds the `.ipa` is a release run. A release run also
  runs `release-flutter` (`dart.yml:545`, publishes a GitHub Release for
  that tag) and, for a version without `-beta`, `publish-store`
  (`dart.yml:598–601`, submits to the Microsoft Store). A manual run with
  the tag of a version that's already out builds the **commit picked in
  the dialog** (normally today's `main`), not that old version, and tries
  to put the result on the existing release. Re-running the old run runs those
  two jobs again too. So as written, the note can't give back "an older
  version". At worst it changes a public release or makes a second Store
  submission.
- **Correct:** say what is true in plain words, without a recipe that
  publishes. For example: "GitHub deletes the `.ipa` **14 days** after the
  run. A new one is built only together with a new release (a new `v…`
  version, for example a new beta), because every run that builds it also
  publishes that release. Never start a run with the tag of a version
  that's already out: it would change that release." Keep
  `ios_project_config_test.dart`'s `14 days` check and add one for the new
  warning.

#### S5 (F5 docs, `b37f8a5`): the privacy line leaves out Google Gemini

- **Where:** `docs/IOS_SIDELOADING.md:90`: "nothing is sent anywhere
  except your school's Bakaláři server and Strava.cz."
- **What is wrong:** on iOS, Settings keeps the AI section
  (`app/lib/features/settings/settings_controller.dart:278–286` removes
  only `browser` and `notifications` on iOS, and `alarm` off Android).
  With a Gemini key entered, the app sends lunch menus to
  `generativelanguage.googleapis.com`
  (`packages/strakalari_core/lib/src/lunches/gemini.dart:321`). The
  README's privacy text says so: "and to Google Gemini only if you turn
  on AI recommendations yourself" (`README.en.md:121`). A privacy
  statement must not promise more than the app keeps.
- **Correct:** add the same condition as the README, in the same plain
  words, for example "…except your school's Bakaláři server and
  Strava.cz, and Google Gemini only if you turn on AI suggestions in
  Settings yourself." Add a check to `ios_project_config_test.dart` that
  the doc mentions Gemini.

One commit per finding (`F5: … (R7 S4)`, `F5: … (R7 S5)`). They touch
only the doc and its test, so no screenshots and no phone run are needed.

### R7 findings, checked

- **M1 ✔ (`99e544d`).** `entryName` (`secret_store.dart:68`, new branch
  `:69–91`) now
  hashes `data` / `data/accounts/<id>` when it runs on iOS
  (`mobilePlatform() == 'ios'`, which on an iPhone comes from
  `Platform.isIOS`, `platform/packaging.dart:35–47`) and a data root is
  set (`mobileDataDirRoot()`, `helpers.dart:158`). Everything goes
  through that one function: core's `getKey` (`secret_store.dart:188`),
  `carryKey`, the store-only read and write, `forgetKey` (`:409`), and the
  iOS key store's `hasEntry`, `removeEntry` and warm-up
  (`ios_keystore.dart:63`, `:84`, `:165`). The root is set once, in
  `prepareStartup`, before the account layout and the warm-up run
  (`startup.dart:105–116`), and nothing else calls `setMobileDataDir`.
  There's no second isolate on iOS (the only `Isolate.run` is the
  Windows notifier). Desktop (`mobilePlatform()` is null), Android and
  the parity tests (they pass `windows:`) keep the absolute-path name
  byte for byte: that code is unchanged below the new branch. A path
  outside the root falls back to the old rule; there's none on iOS. The
  reviewer also checked that nothing else saves the container's path:
  `accounts.json` stores only ids, labels, dates and flags
  (`accounts.dart:429–435`, `:494–499`). Both new tests (core
  `iosEntryNameUsesPathRelativeToMobileDataRoot`,
  `secret_store_test.dart:206`; app `saved passwords stay readable when
  iOS container path changes on update`, `ios_platform_test.dart:239`)
  fail with an assertion at the parent `66aa276` (core: wrong name; app:
  the Keychain map changed, 2 → 4 items) and pass at `99e544d`. The
  older multi-account test (`ios_platform_test.dart:233–236`) needed no
  change: it computes the expected name with `entryName` under the same
  iOS setting.
- **S1 ✔ (`ed691ff`).** `posixOCreatFlag` / `posixLibcLibraryName`
  (`helpers.dart:563–574`) take `{String? os}` and decide Darwin
  themselves; the lock code calls them with no argument
  (`helpers.dart:576`, `:606`), so `Platform.operatingSystem` (`ios` on
  an iPhone) picks. The test (`helpers_test.dart:248`) checks
  `ios`/`macos`/`android`/`linux`. Reviewer's undo at `ed691ff`: with
  `ios` dropped from the `O_CREAT` choice it fails (`512` expected, `64`
  actual); with `ios` dropped from the library choice it fails
  (`/usr/lib/libSystem.dylib` expected, `libc.so.6` actual). At the
  parent it can't compile (the parameter is new), as expected for a
  signature change.
- **S2 ✔ (`7ad5efc`).** The test (`ios_platform_test.dart:336`) drives
  the binding through `inactive → hidden → paused` and back and checks
  `loop.paused!()`. With the iOS listener removed (`startup.dart:246–249`)
  it fails (`true` expected, `false` actual). Its tear-down puts the
  binding back to `resumed`. The pause is real on iOS:
  `_phoneBackgroundOn` is false off Android (`startup.dart:302–305`), so
  a backgrounded iOS app always waits.
- **S3 ✔ (`4acd2e7`).** All five points are in: "expected to work … not
  yet been built on a Mac or opened on a real iPhone" (`:5`),
  "notifications" (`:7`), the 14-day limit (`:18`, but see S4), Flutter
  3.44.8 with `flutter pub get` and `flutter build ios --config-only
  --no-codesign` writing `Generated.xcconfig` (`:50–59`), and the renewal
  "designed to stay intact … untested until the first renewal on a real
  iPhone" (`:87`). The extended doc test fails at the parent `7ad5efc`
  (`contains '14 days'`).

### Each fix undone alone

| Undone (one at a time) | Caught? |
|---|---|
| M1 relative name: core test from `99e544d` run at `66aa276` | yes |
| M1 relative name: app test from `99e544d` run at `66aa276` | yes |
| S1 `ios` in the `O_CREAT` choice (at `ed691ff`) | yes |
| S1 `ios` in the C library choice (at `ed691ff`) | yes |
| S2 iOS lifecycle listener (at `7ad5efc`) | yes |
| S3 doc test from `4acd2e7` run at `7ad5efc` | yes |

### Notes (no action needed)

- **N11:** none of the four fix commits has a message body. Each has a
  test (S3's is the doc test), so none was needed.
- **N12:** the Keychain keeps its items when the app is deleted. With
  M1, a later reinstall finds the old key under the same name and uses
  it for the new, empty data. That's harmless: the old passwords went
  with the app's files, and the doc's "Uninstalling wipes local data"
  stays true.
- **N13:** the M1 test copies the folders to a new path and keeps the
  fake Keychain, which is what an iOS update does as far as the app can
  tell (files at a new path, Keychain unchanged). Whether a real update
  behaves exactly so is item 4 of the unverified list.

### Unverified until the owner's CI run and an iPhone (updated)

Unchanged from R7, with item 4 now about the fixed code:

1. `AppDelegate.swift` compiles.
2. `flutter build ios --release --no-codesign` succeeds on
   `macos-latest` with `path_provider_foundation`, `url_launcher_ios` and
   `share_plus`, and the `.ipa` is packed.
3. The `.ipa` installs with Sideloadly or AltStore and opens.
4. The Keychain on a real iPhone: the first start creates the key, a
   second start finds it, and a reinstall over the app (the 7-day renewal
   or a new version) keeps every saved password readable.
5. The session lock (`flock` through `libSystem`) works: a refresh runs
   and never reports "busy" by itself.
6. Daily use: the wizard, a refresh against the school, the scheduler
   waiting while the app is in the background.

### What the reviewer verified, and how (re-review)

1. **Suites** at `e1f452d` after `dart pub get --enforce-lockfile`: core
   `dart analyze` no issues, `dart test` **881 passed, 2 skipped** (the
   same two platform skips as before: POSIX permission bits, the
   Linux/macOS `flock` probe); app `flutter analyze` no issues,
   `flutter test` **829 passed, 1 skipped**. Both match STATUS. Flutter
   again rewrote only the line endings of the seven generated plugin
   registrant files (`git diff --ignore-cr-at-eol` empty); restored to
   `HEAD`.
2. **Parent runs and undo checks** (table above) in one throwaway
   worktree in the reviewer's scratch space.
3. **M1 code paths:** every `entryName(` caller in core and the app,
   every `setMobileDataDir` caller, `mobilePlatform()`, any `Isolate`
   use, and what `accounts.json` stores (above).
4. **Test integrity:** `git diff 66aa276..HEAD` on test files removes
   only the five old `isDarwin:` assertions in
   `darwinAndLinuxPosixFlockConstants`, replaced by eight stricter ones
   as S1 asked; no `skip:`, `anything` or `try`/`catch` added; the one
   new `isNotNull` (`ios_platform_test.dart`, S2) is followed by real
   `paused!()` checks.
5. **Keys, strings, fixtures, tutorials, lockfile, CI, `app/ios/`:**
   `git diff --stat 66aa276..HEAD` on `config.example.json`,
   `config.dart`, `test/parity/`, `app/lib/l10n/`, `app/lib/tutorial/`,
   `pubspec.lock`, all three `pubspec.yaml`, `app/ios/` and `.github/` is
   empty.
6. **Safety rules:** the `storage/` changes only pick the Keychain name
   on iOS and the `flock` constants; no `catch` added; no refresh, send,
   order, lock, audit or pause code changed.
7. **Hygiene:** no upstream; `git log qa-roadmap..main` empty; the five
   commits are by DeNdlerX with no `Co-Authored-By` / `Claude-Session` /
   "Generated with" line; they touch only code, tests, the doc and
   STATUS (no config, cache, log, `htmls/`, key or screenshot); the new
   tests use no address.
8. **Docs:** `docs/IOS_SIDELOADING.md` read in full at `e1f452d` against
   `dart.yml` (`meta`, `build-flutter-ios`, `release-flutter`,
   `publish-store`) and the iOS Settings sections (S4, S5).
9. **Throwaway worktree:** each plugin link in
   `app/{windows,linux}/flutter/ephemeral/.plugin_symlinks` removed on
   its own first, then `git worktree remove --force`, which unregistered
   it but couldn't delete the folder (Windows long paths); the leftover
   folder in the reviewer's scratch space has no links left. All 338
   packages in the pub cache still have their `pubspec.yaml`.
10. **Not checked:** anything that needs a Mac or an iPhone (list
    above); the Android phone (no Android change since R6).

---

## Re-review 2 (2026-11-21)

The owner asked the reviewer, right after the re-review: "can you fix
the two doc lines yourself?" So the reviewer fixed S4 and S5 itself,
one commit each, as at R4 S5 and R5 S5. For these two commits the
review isn't independent; each is one sentence in
`docs/IOS_SIDELOADING.md` plus a doc-test check, and the owner can read
both diffs in a minute.

- `c8101a3` F5: say an expired .ipa needs a new release and never reuse
  a released tag (R7 S4);
- `9923cb0` F5: name Google Gemini in the iOS doc's privacy line, as the
  README does (R7 S5).

### Verdict: PASS

Every R7 finding is fixed. Everything that needs a Mac or an iPhone stays
unverified until the owner's CI run and a sideload (the six points in
*Unverified until the owner's CI run and an iPhone (updated)* above).

### S4 and S5, checked

- **S4 ✔ (`c8101a3`).** `docs/IOS_SIDELOADING.md:18` now says GitHub
  deletes the `.ipa` 14 days after the run, that a new one is built only
  together with a new release (a new `v…` version, for example a beta)
  because every run that builds it also publishes that release, and
  never to start a run with the tag of a version that's already out. It
  no longer suggests any run. `ios_project_config_test.dart` checks both
  sentences and that "start a new release run" is gone. With the old doc
  (`9923cb0^^`) the test fails (`contains 'built only together with a
  new release'`); with the new one it passes.
- **S5 ✔ (`9923cb0`).** The privacy line (`:90`) ends "…and Google
  Gemini only if you turn on **AI recommendations** in Settings
  yourself." That's the README's condition, and *AI recommendations* is
  the Settings section's English name (`sec_ai`, `app_en.arb:584`). The
  test checks the phrase; it fails with the old doc and passes with the
  new one.

### What the reviewer verified, and how (re-review 2)

1. Each doc-test check run against the doc before and after its commit
   (fails before, passes after).
2. App `flutter analyze` no issues, `flutter test` **829 passed, 1
   skipped** at `9923cb0` (same count: the checks went into the existing
   doc test). Core wasn't touched since the re-review (881 passed / 2
   skipped there). The generated plugin registrants' line endings were
   restored to `HEAD` again.
3. Both commits touch only `docs/IOS_SIDELOADING.md` and
   `app/test/ios_project_config_test.dart`; both are by DeNdlerX with no
   `Co-Authored-By` / `Claude-Session` / "Generated with" line; no
   upstream; `git log qa-roadmap..main` empty.
