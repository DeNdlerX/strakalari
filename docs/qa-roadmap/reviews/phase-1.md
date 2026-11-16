# Review R1: Phase 1 (B1–B9)

Reviewed 2026-11-16 at `qa-roadmap` @ `aeec9f4` (base `main` @ `a528acd`;
`main` has no newer commits). Commits reviewed: `99fe14d` (B2), `de10797`
(B1), `1f2d027` (B3), `f9e7eba` (B4), `3491a63` (B5), `ef5fdec` (B6),
`fef6411` (B7), `0bbe48b` (B8), `aeec9f4` (B9).

## Verdict: **FAIL**

Most of the phase is solid: all suites are green, every item's test fails on
the commit before its fix, nothing in the send, order, lock or audit code was
touched, and the B1 round trip keeps templates byte-identical. Three must-fix
findings block the pass. The worst is a new data-entry regression in the
template editor (M1) that B2 introduced and B1 carried into the wizard.

---

## Must-fix

### M1 (B2, affects B1): a new template row, or a name typed without text, disappears on the next app rebuild

- **Where:** `app/lib/features/settings/settings_view.dart:318–330`
  (`_TemplateEditorState.didUpdateWidget`).
- **What is wrong:** `didUpdateWidget` reloads from config whenever the editor
  is not dirty and not focused, and it compares the stored list with `values`.
  `values` also holds rows that were never saved: `commitTemplatesList`
  drops rows with empty text. So after **+ Přidat** (the new row is empty and
  not focused) the next `AppState` change (a refresh progress tick, the
  scheduler, any `onChanged`) reloads from config and the new row vanishes.
  The same happens to a row where the user typed a name, left the field and
  hasn't typed the text yet: the typed name is lost. On `main` (before B2) the
  row survived, because the editor never reloaded.
- **Reproduced by the reviewer** with a throwaway widget test, in Settings →
  Šablony and in the wizard's excuses step: tap **+ Přidat**, call
  `s.onChanged()`, pump → `tpl:late_income_excuses:1:text` is gone. On `main`
  the same Settings test keeps the row.
- **What correct looks like:** reload only when the **stored** value changed
  since the editor last read or wrote it. For example keep a snapshot of the
  stored list (`_lastStored`) taken in `initState`, after every
  `_saveValues()` and after every reload, and in `didUpdateWidget` reload only
  when `readTemplates()` / `controller.get(configKey)` differs from that
  snapshot (key change still forces a reload). Unsaved rows in `values` must
  never cause a reload on their own.
- **Tests to add (fail before, pass after):** in `settings_live_test.dart`
  (`B2 template editor`) and `wizard_live_test.dart`
  (`B1 wizard excuse templates`): (1) tap **+ Přidat**, `s.onChanged()`, pump →
  the new row is still there and can be filled and saved; (2) type a name in
  the new row, unfocus, `s.onChanged()`, pump → the typed name is still in the
  field. Keep a test that a real outside change to the config (e.g.
  `s.save({'late_income_excuses': [...]})` while the editor is unfocused and
  clean) still shows up.

### M2 (B5): no test for "opening and closing the dropdown without a change writes nothing"; re-picking the current preset still saves

- **Where:** `app/test/settings_sections_test.dart:317` (`B5 school calendar
  presets`) has no such test; `app/lib/features/settings/settings_view.dart:1066–1069`
  (`onChanged` of the preset dropdown).
- **What is wrong:** the plan's *Done when* asks for this test by name. The
  three B5 tests check the item list, the semester fallbacks and a real change.
  None opens and closes the dropdown and checks that nothing was written.
  The reviewer checked it: dismissing the menu (tap outside, Back) writes
  nothing, but tapping the already selected preset calls `c.save(...)` once
  (same content, but a full save with `refreshTokens`, a rebuild and all config
  listeners). Re-picking the current value is "opening and closing without a
  change".
- **What correct looks like:** in `onChanged`, return early when
  `v == null || v == presetId`. Add a widget test with a real `AppState` and a
  seeded `config.json` (`school_preset_id: gekom_2026_2027`) that (1) opens the
  dropdown and dismisses it, (2) opens it and taps the selected preset, and
  after each step asserts that no save happened (count `configListeners`
  calls, or compare `config.json` content **and** modification time) and
  `school_preset_id` is still `gekom_2026_2027`.

### M3 (B3): the phone evidence doesn't show the bug, but STATUS says it was reproduced and verified

- **Where:** `build/qa-evidence/B3/before_light_phone.png`, STATUS row B3.
- **What is wrong:** B3 is labelled *seen on phone, cause not confirmed*, so it
  had to be reproduced first. The "before" phone screenshot (22:21, the build
  before the fix) already shows Vzhled → **Světlý fully light**: background,
  cards, bottom bar, text. So the reported "stays dark" did not reproduce on
  the phone. The widget test reproduces something smaller: right after the
  pick, `Theme.of` is still dark for a frame because `MaterialApp` animates
  between two `ThemeData`s that are never equal (new `WidgetStateProperty`
  closures on every build), so every rebuild restarts that animation. That is
  a real defect and the fix (cached `ThemeData`, no theme animation, explicit
  `Scaffold.backgroundColor`) is low-risk and fine to keep. But STATUS must
  not claim the phone bug was reproduced and fixed.
- **What correct looks like:** no code change. In STATUS: rewrite the B3 Notes
  to say what was actually seen (phone: not reproduced, the before screenshot
  is already light; test: theme lags a frame and restarts its animation on
  every rebuild, which could keep it dark while the app rebuilds faster than
  the animation finishes). Add one line under *Questions* asking the owner
  whether they still see the dark-stays-dark problem on their phone after this
  build. Add the removal of the theme cross-fade
  (`app/lib/main.dart:77`, `themeAnimationStyle: AnimationStyle.noAnimation`)
  under *Deviations* with that reason; the reviewer accepts it.

---

## Should-fix

### S1 (B1): the old split-on-newline code is still there and still called

- **Where:** `app/lib/features/wizard/wizard_controller.dart:425–454`
  (`excuseTemplates`, `setExcuseTemplatesInitial`, `saveExcuseTemplates`,
  which splits on `\n` and saves plain strings) and `:715`
  (`if (excuseTemplates.isNotEmpty) saveExcuseTemplates();`).
- **What is wrong:** nothing fills `excuseTemplates` any more, so today it is
  dead. But it is exactly the B1 bug, still wired into **Pokračovat** on the
  excuses step; anything that fills the map again brings the data loss back.
- **What correct looks like:** remove the map, both methods and the call at
  `:715`, in a commit `B1: remove the old line-split template path`. All B1
  tests stay green.

### S2 (B5): the placeholder change reaches every Settings text field, not just the calendar card

- **Where:** `app/lib/features/settings/settings_view.dart:164`
  (`hintText: widget.hint.isEmpty ? null : widget.hint` in `AutosaveField`).
- **What is wrong:** the plan asks to remove the duplicated hint "in this
  card". The change removes the label-as-placeholder from every
  `AutosaveField` in Settings (Účty, Limity, AI, …). It isn't listed under
  *Deviations*.
- **What correct looks like:** the reviewer accepts the wider change (the
  label stays visible above each field, so nothing is lost, and the same
  duplication was on every card). Add it under *Deviations* with that reason.
  No code change needed.

### S3 (B9): four switches outside B9 were changed

- **Where:** `app/lib/features/settings/settings_view.dart:917`
  (`use_strava`), `:1497` and `:1538` (`minimize_to_tray`), `:1686`
  (`gemini_auto_enabled`).
- **What is wrong:** B9 needed the `run_in_background` switch (`:1460`) to
  redraw at once. The same `onChanged?.call()` was added to four other
  switches. Probably the same real bug, but not in the plan, not listed under
  *Deviations*, and only `run_in_background` has a test.
- **What correct looks like:** either revert those four and add one line under
  *Questions*, or keep them, list them under *Deviations* ("same missing
  redraw as B9's switch") and extend the `B9 background switch rebuilds` test
  in `settings_sections_test.dart` to toggle each of the four and check the
  switch value flips. The reviewer accepts the second option.

### S4 (B9): no phone evidence for the path the plan describes ("right after Dokončit")

- **Where:** `build/qa-evidence/B9/`.
- **What is wrong:** (a) was checked on the phone by replaying tutorials and
  cold-starting, not by finishing the wizard. The Dart tests cover
  `wizardFinished` / `dismissWizard`, but the plan's report is about the
  dialog appearing right after **Dokončit**.
- **What correct looks like:** on the `.test` app only, without clearing it:
  put the `.test` app's config back into the wizard (e.g. `adb -s
  2C221FDH3002NZ shell run-as io.github.dendlerx.strakalari.test` and set
  `wizard_step` to 8 and `tutorials_done` to `[]` in its `config.json`),
  revoke `POST_NOTIFICATIONS`, cold-start, press **Dokončit**, and save
  screenshots: the welcome tutorial without the system dialog, then the
  dialog after the tutorial closes, then `dumpsys activity services` after
  **Allow**. If `run-as` doesn't work, ask the owner before clearing the
  `.test` app.

### S5 (B9): the cold-launch test copies the startup code instead of calling it

- **Where:** `app/test/android_phone_background_test.dart:371–397`; the code it
  copies is `app/lib/platform/startup.dart:125–130`.
- **What is wrong:** the test repeats `if (!s.setupPending &&
  s.tutorialOffer(firstTourId)) s.onChanged(); phone.start();` itself. If
  `startPlatformServices` went back to calling `phone.start()` first, this test
  would still pass.
- **What correct looks like:** move those lines into one small function in
  `startup.dart` (e.g. `startPhoneBackground(AppState state, PhoneBackground
  phone)`) that `startPlatformServices` calls, and have the test call that
  function. Same behaviour, nothing else changes.

### S6 (B9): the cause of (b) isn't written down, and a failed start is never retried

- **Where:** STATUS row B9; `app/lib/platform/startup.dart:311–330`.
- **What is wrong:** B9 was *cause not confirmed*. STATUS lists what was
  changed, not what the cause was. Before the fix,
  `requestNotificationPermission` returned before the user answered, so
  `sync()` went on while the system dialog was on top. `KeepAliveService`
  doesn't need the permission to start, so the reviewer's guess (not
  verified) is that `startBackground` threw while the dialog covered the app
  (a foreground-service start from the background throws on Android 12+),
  and `_on`/`_interval` were already recorded, so no later `sync()` tried
  again.
  The new code still records `_on`/`_interval`/`_allowed` **before**
  `startBackground`, so a start that throws is still never retried until a
  setting changes.
- **What correct looks like:** write the cause you found (with the log line
  if you have it, e.g. `Warning: background running setup failed (…)`) in the
  B9 Notes. Add one line under *Questions* about the retry gap; don't change
  it without the owner's go, because it changes when the service is started.

---

## Notes (no action required unless you touch the code anyway)

- **N1 (B6):** `Strings.get` falls back to Czech, so the B6 test alone would
  pass if an English `notif_*` label were missing. All 13 labels exist in
  both ARBs and `strings.dart` today (checked by hand).
- **N2 (B9):** the test `Android bridge waits for onRequestPermissionsResult
  before returning` (`android_phone_background_test.dart:451`) only greps the
  Java/Kotlin source. It's fine as a tripwire; the real proof is the phone
  evidence.
- **N3 (STATUS):** row B9 says `self (B9 commit)`; write `aeec9f4`.
- **N4 (tests):** new tests use `https://skola.bakalari.cz` and
  `https://*.example.cz` as config values. They are never contacted (the
  existing tests do the same), but new tests should prefer `http://127.0.0.1`.
- **N5 (B9):** `StrakalariChannel.onReattachedToActivityForConfigChanges`
  doesn't re-add the permission listener. Harmless today, because
  `MainActivity` forwards `onRequestPermissionsResult` itself.

---

## Item by item

| ID | Test fails on parent / passes on commit | Done when | Result |
|---|---|---|---|
| B1 | 4 of 5 fail on parent (1 assertion, 3 missing widgets; the 5th is the "legacy configs still load" guard and passes on both, as it should) / all pass | Round trip byte-identical ✔ (reviewer's full-wizard run); multi-line + name kept ✔; edits survive a rebuild while focused ✔, but not an added row (M1) ✘; labels = Settings labels in cs/en ✔; plain-string configs load in Settings, `TodayController`, `templateTexts` ✔; no auto-repair, owner answered ✔ | M1, S1 |
| B2 | 5 of 5 fail (2 because nothing was saved, so `config.json` doesn't exist; 3 assertions) / pass | Saves on blur and on leaving ✔; controllers in `State`, disposed, cursor kept ✔; 390 px no overlap, multi-line growing ✔ (screenshot + test) | M1 |
| B3 | 2 of 2 fail (assertions) / pass | Whole app switches at once and back ✔ in test and phone screenshots; phone "before" shows no bug | M3 |
| B4 | 2 of 2 fail (assertions) / pass | Full timestamp stored ✔; status card, KPI, history show the time ✔; date-only `at` shows `finished` ✔; other readers (`runTime` on audit `ts`, which has `T`) still work ✔ | pass |
| B5 | 3 of 3 fail (assertions) / pass | Options = `presetOptions` + custom, shows saved id ✔; open/close writes nothing: dismiss ✔, re-pick saves ✘, no test ✘; semester fallbacks like the wizard ✔; duplicated hint gone ✔ | M2, S2 |
| B6 | 1 of 1 fails (assertion) / passes | 13 labels in cs and en ✔ | N1 |
| B7 | file doesn't compile on parent (unit test calls new `retryLimitsRefresh`); with that test removed, `tapping retry when idle…` fails on parent with an assertion / all pass | Snackbar only when a refresh really ran ✔ (both cases tested) | pass |
| B8 | wizard 2 of 2 fail (stale `baka_user` shown on the Strava step) and marks 1 of 1 fails (controller replaced on rebuild) / pass | Fixed only what the tests show ✔ | pass |
| B9 | 5 of 5 + 1 of 1 fail / pass | (a) dialog after tutorial ✔ (Dart tests; phone via cold start, S4); (b) service + notification start on grant ✔ (`before_dumpsys.txt` empty, `after_dumpsys.txt` shows `KeepAliveService` foreground, created 29 s before the dump, notification in `after_shade.png`); holds for a skipped F1 step ✔ (gating is on `tutorial == null` and setup, not on a step) | S3–S6, N2, N5 |

## What the reviewer verified, and how

1. **Builds and suites** (in the worktree, Flutter 3.44.8):
   `dart pub get --enforce-lockfile` OK; core `dart analyze` no issues,
   `dart test` **803 passed, 2 skipped** (both POSIX-only, pre-existing);
   app `flutter analyze` no issues, `flutter test` **680 passed, 1 skipped**
   (pre-existing). Use these counts as the baseline for the re-review.
2. **Tests catch the bugs:** one throwaway worktree in the reviewer's scratch
   space; for each item commit, checked out its parent, copied in only that
   commit's version of the item's test files, ran only the item's group
   (`--plain-name`), then did the same on the commit. Results in the table
   above. Worktree removed afterwards.
3. **B1 round trip (reviewer's own test):** seeded `config.json` with all four
   template keys: named multi-line texts, a `{text, name}` map with reversed
   key order, a plain multi-line string, names and texts with surrounding
   spaces, an empty line inside a text. Drove `LiveWizardView` from step 0 to
   **Dokončit** (skipping the three connection-test steps), focused and blurred
   a template field and forced an `AppState` rebuild on the excuses step. All
   four keys in the saved `config.json` were identical (`jsonEncode` with key
   order) to the seed. Passed.
4. **B5 (reviewer's own test):** real `AppState` and `LiveSettingsView` on a
   seeded config; dismiss and Back: no save, file and mtime unchanged;
   re-picking the selected preset: one save, same content (M2).
5. **M1 (reviewer's own test):** described under M1; fails at `aeec9f4` in
   Settings and the wizard, passes on `main`.
6. **Screens:** a capture run derived from `tools/parity/capture_screens.dart`
   (demo data from `tools/demo_data.py`) for Settings → Šablony, Školní
   kalendář, Oznámení, Vzhled, Běh na pozadí, Známky, Aktivita and wizard
   step 8, at 390 and 1280 px, cs and en, light and dark (64 images): no
   overflow or render errors, all looked right. The `→` in the wizard hint
   renders as a box only because the capture font lacks it (not a bug).
   The agent's own screenshots in `build/qa-evidence/` (B1, B2, B3, B5, B6,
   B9) were all opened.
7. **Plan corrections used:** B2 fixed the save (not "text never reaches the
   list"); B3 didn't follow the report's quiet-save theory; B4 fixed the
   writer (`activity.dart:559`); B5 uses `school_preset_id` and
   `gekom_2026_2027`. (The plan's N1 notification item is phase 2.)
8. **Scope:** findings S2, S3 and M3 (cross-fade) are the only changes outside
   their items. Everything else stays inside the item.
9. **Config keys and strings:** no key added, removed or renamed;
   `config.example.json`, `config.dart`, the parity fixtures and the ARB files
   are unchanged on the branch. No new UI strings.
10. **Safety rules:** no diff touches `automation/`, `lunches/`, `strava/`,
    `bakalari/` or `storage/`. In `controllers/`, only the run timestamp (B4)
    and two `tutorialOffer` calls (B9) changed; `runRefresh`, the session
    lock, `sendExcuse`/`HistoryLock`, the audit and `automation_paused` are
    untouched. The B7 retry still goes through `startRefresh`. The only new
    `catch (_)` is the marks band number parse, moved unchanged from the old
    code.
11. **Test integrity:** `git diff main..qa-roadmap` on the test files has no
    removed lines, no `skip:`, no loosened assertions, no `try`/`catch` around
    assertions. Weak spots: N2 and S5.
12. **Hygiene:** no `config.json`, `data_cache.json`, `log.txt`, `htmls/`,
    keys or screenshots in any commit; no `Co-Authored-By`, `Claude-Session`
    or "Generated with" lines; `qa-roadmap` has no upstream (never pushed);
    `main` has no commits the branch lacks.
13. **Not checked by the reviewer:** the phone itself (the agent's `dumpsys`
    and screenshots were read instead); macOS/iOS builds (not possible here).
