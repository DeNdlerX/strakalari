# Review R3: Phase 3 (F1 wizard and school selection)

Reviewed 2026-11-17 at `qa-roadmap` @ `ae037f5` (base `main` @ `f8d5582`;
`main` has no commits the branch lacks). Commits reviewed: `1afb030`
(presets), `bf98783` (step list, Vítejte, disclaimer, resume), `ff297de`
(Škola), `2696b70` (prefills, Omluvenky, template groups), `b0c7582`
(Telefon), `4ff0a40` (phone layout), `efd75c4` (Známky, Settings → Škola,
limits in Absence), `7c590ce` (tutorials), `ae037f5` (STATUS). Checked
against `design-F1.md` (passed at R3a), PLAN §6 Phase 3, CONTRIBUTING §5–6
and the owner's D1 answers.

## Verdict: **FAIL**

The wizard itself is good. It has 6 steps on a PC and 7 on Android, the
three-sentence disclaimer, no AI step, GEKOM fills in the address and the
canteen, the Telefon step asks for notifications on purpose, and the phone
layout is pinned and doesn't wrap. All four suites are green. Every commit
was green on its own. The reviewer walked the whole wizard with named
multi-line templates and AI settings, and they came out byte-identical.
Nothing in the send, order, lock or audit code was touched, and no screen
has a render error (144 reviewer captures).

Three findings block the pass:

- a frozen parity fixture was edited (X1, blocker by rule);
- two still-valid tests were deleted (M1);
- a resumed wizard forgets the saved school (M2).

---

## Blocker

### X1 (F1, `1afb030`): the frozen parity fixture was edited

- **Where:** `packages/strakalari_core/test/parity/school_presets.json:186–188`
  (three lines added to the expected `getPreset('gekom_2026_2027')`
  output). STATUS lists this under *Deviations*.
- **What is wrong:** PLAN rule 4 allows exactly one kind of edit in
  `test/parity/`: a new config key added to the two full config files in
  `helpers.json` (`roundTripFiles`). Any other edit is a blocker. The
  fixtures record what the Python app did and can't be regenerated. After
  this edit, the file no longer says what Python returned. A compliant way
  existed, shown below.
- **What correct looks like:** one commit, `F1: keep the parity fixture
  frozen (R3 X1)`:
  1. Restore the fixture byte-for-byte:
     `git checkout f8d5582 -- packages/strakalari_core/test/parity/school_presets.json`.
  2. In `packages/strakalari_core/test/parity_school_presets_test.dart`,
     put F1's three D1 fields in a constant with a comment, and add them
     to the expected value of that single case:
     ```dart
     // F1 (owner's D1, 2026-11-17): fields the Python app never had. The
     // frozen fixture stays as Python wrote it; they are added here.
     const f1GekomFields = {
       'bakalari_url': 'https://bakaweb.gekom.cz',
       'strava_canteen_id': '1950',
       'marks_scale': 'percent',
     };
     ...
     var expected = decodeParityValue(c['expected']);
     if (fn == 'getPreset' && args[0] == 'gekom_2026_2027') {
       expected = {...(expected as Map), ...f1GekomFields};
     }
     ```
     The comparison stays exact. Any other new or changed key still fails
     it.
  3. Rewrite the *Deviations* line in STATUS: the fixture is untouched, and
     the test adds the three D1 fields in code.
  4. Check: `git diff f8d5582 -- packages/strakalari_core/test/parity/` is
     empty, and the parity test fails if you change `'1950'` in the
     constant.

---

## Must-fix

### M1 (F1, `bf98783`): two tests that still apply were deleted

- **Where:** `app/test/wizard_setup_full_test.dart`. At `f8d5582`,
  l.116–130 (`testWizardGotoClampsAndFinishClears`) and l.132–146
  (`testSkipMovesOneStepOnly`).
- **What is wrong:** both tests check behaviour F1 kept: `goTo` clamps,
  `finishWizard` clears the drafts, and *Přeskočit* moves exactly one step
  without saving or finishing. The reviewer ran both, copied unchanged,
  against `ae037f5`, and both pass. They were deleted, not adapted, and
  the commit message says "adapted … skip/ready". PLAN rule 8 forbids
  deleting tests.
  Four other tests were removed together with the code they tested, and
  that is acceptable: `testAiOptional`, `testLimitsStepUpdates`,
  `testLimitsStepLoadsSubjectsOnce` and `retryLimitsRefresh honors both
  refreshRunning and callback bool return`. But they aren't listed
  anywhere.
- **What correct looks like:** one commit, `F1: restore the goto/finish and
  skip tests (R3 M1)`:
  - Put both tests back unchanged from `f8d5582`, in the first group,
    before `testNoSkipWhereNothingMayBeSkipped` (HEAD l.103).
  - Under *Deviations* in STATUS, list the four tests removed with their
    code, one line each, with the reason. For the limits tests, add that
    the limits editor is the Settings one moved unchanged
    (`LimitsEditorContent`) and is tested in `absences_view_test.dart`.

### M2 (F1, resume): a resumed wizard shows no school, though one is saved

- **Where:** `app/lib/features/wizard/wizard_controller.dart:300–305`
  (`calPreset()` reads only the `wiz:cal_preset` draft). The resume rule
  is in `app/lib/controllers/app_state.dart:132–137`.
- **What is wrong:**
  - `design-F1.md` §5 says a resumed wizard starts on Škola, and "every
    step … shows what's already saved, so walking Škola–Bakaláři again
    loses nothing".
  - After a restart, the drafts are gone. Škola shows no card picked and
    *Pokračovat* is disabled, even when `school_preset_id` is saved. The
    agent's own phone screenshot shows exactly this
    (`build/qa-evidence/F1/phone_resume.png`: interrupted on Bakaláři after
    picking GEKOM, resumed on Škola with nothing selected and a grey
    *Pokračovat*).
  - The reviewer's test (below) fails at `ae037f5`: `calPreset()` is `''`.
  - The user has to pick their school again for no visible reason, which
    is the kind of friction F1 was meant to remove.
- **What correct looks like:**
  - When the wizard resumes, the saved `school_preset_id` is shown as
    picked (its card, and its radio button if the school has several
    presets). Do this when the saved step was past Škola
    (`wizard_step` > 1), or when the saved id is a real preset (not
    `custom`). For example, seed `wiz:cal_preset` and `wiz:school_group`
    from the config in the resume branch of `AppState`.
  - A fresh install still needs an explicit pick: `school_preset_id`
    defaults to `custom` (`config.dart:133`), and
    `testCalendarStepRequiresExplicitPick` stays unchanged.
  - *Pokračovat* on a seeded Škola writes nothing new.
  - Test (add it to `wizard_live_test.dart`; it must fail on `ae037f5`):
    ```dart
    final first = AppState()..wizardOpened();
    first.save({'disclaimer_accepted': true,
                'school_preset_id': 'gekom_2026_2027'});
    first.wizardGoto(WizardController.stepBakalari, WizardController.stepDone);
    final restarted = AppState();
    expect(restarted.wizardStep, WizardController.stepSchool);
    final c = wizardControllerFor(restarted);
    expect(c.calPreset(), 'gekom_2026_2027');
    expect(c.nextEnabled, isTrue);
    ```
    Add a second case: a fresh `AppState()` with no saved step still has
    `calPreset() == ''`.
  - Replace `phone_resume.png` with a new one that shows GEKOM picked.

---

## Should-fix

### S1 (F1, prefills): the Bakaláři and Strava text asks for what is already filled in

- **Where:** `wizard_view.dart:593` (`wiz_bakalari_p`: *Zadejte adresu
  školy, uživatelské jméno a heslo …*) and `:624` (`wiz_strava_p`: *…
  vyplňte přihlášení a číslo jídelny*).
- **What is wrong:** with GEKOM, the address and the canteen are shown as
  the one-line prefill (*Škola: bakaweb.gekom.cz*, *Jídelna: 1950*), but
  the line above still asks the user to type them in
  (`phone_2_bakalari_prefill.png`, reviewer captures `wiz2`/`wiz3`). The
  owner asked for as little text as possible, and this text is also wrong
  for the screen it is on.
- **What correct looks like:**
  - Two new strings, used only while the prefill row is shown
    (`!c.showBakalariUrlField`, `!c.showStravaCanteenField`). Add each to
    both ARB files and `strings.dart`:
    - `wiz_bakalari_p_preset`: cs *Zadejte uživatelské jméno a heslo —
      stejně jako v prohlížeči.*, en *Enter your username and password —
      same as in the browser.*
    - `wiz_strava_p_preset`: cs *Pokud obědy neřešíte, integraci
      vypněte. Jinak vyplňte přihlášení.*, en *If you don't use school
      lunches, turn the integration off. Otherwise fill in the login.*
  - Extend `F1 login prefills and Změnit`: GEKOM shows the short lines,
    and `custom`, or after *Změnit*, shows the old ones.

### S2 (F1, Absence): "no limits set" next to rows that each show a limit

- **Where:** `app/lib/features/absences/absences_view.dart:66–96`
  (`_noLimitsBanner`), string `abs_no_limits`.
- **What is wrong:** the line appears whenever `subject_limits` is empty.
  But `absence_critical_pct` (25 % by default) applies to every subject,
  and every row right under it says *Limit: 25 %*. The reviewer's
  captures `absences-nolimits-*` show the contradiction in cs and en.
  The design note said "while no limit is set". That was the note's
  mistake: a default limit always exists.
- **What correct looks like:** make the line true. Change `abs_no_limits`
  to cs *Všechny předměty mají výchozí limit {pct:g} %.* and en *All
  subjects use the default limit of {pct:g} %.*, and pass
  `absence_critical_pct` in. Keep the *Limity* button. If the owner prefers
  even less text, drop the line and keep only the header button. Either
  way, adjust the F1 Absence test.

### S3 (F1): user docs still use the old names

- **Where:**
  - `README.md:88` and `README.en.md:88`: *Vlastní dny* / *Custom days*
    and *Nastavení → Školní kalendář* / *Settings → School calendar*.
  - `docs/SCHOOL_PRESETS.md:79`: "a user can still override it on the
    Marks tab". While a preset sets bands, that is now done in Settings →
    School.
  - `docs/SCHOOL_PRESETS.md:82`: *Settings → School calendar*.
- **What correct looks like:** the new names *Jiná škola* / *Another
  school* and *Nastavení → Škola* / *Settings → School*, and l.79 points
  to Settings → School. One commit, docs only.

### S4 (F1, P3 test): the adapted P3 test taps Back instead of Continue

- **Where:** `app/test/wizard_live_test.dart`, `P3 adapted wizard
  navigation reachability` (`await tester.tap(backBtn)`).
- **What is wrong:** the original test tapped *Pokračovat* and checked
  that the wizard moved on, which proved the pinned button works. The
  adapted test taps *Zpět* instead, because *Pokračovat* on Omluvenky needs
  a name. Both buttons are still checked to be on screen, but the one P3
  is about is no longer pressed.
- **What correct looks like:** after opening *Pokročilé* and a group,
  enter a name in `draft:wiz:signature`, tap *Pokračovat* and assert the
  next step (`stepDone` on desktop). Keep the Back check if you like.
  Write a line about the change under *Deviations*.

---

## Notes (no action needed unless you touch the code anyway)

- **N1 (evidence):**
  - Missing from `build/qa-evidence/F1/`: steps 3–4 at 1280 px, English
    and light at 1280 px, Settings → Škola with `custom`, and Známky
    `custom` at 390 px.
  - The reviewer captured all changed screens instead (144 images, see
    *What the reviewer verified*), so nothing more is needed for this
    review.
- **N2 (privacy, not committed):** the first frames of
  `build/qa-evidence/F1/phone_welcome.mp4` show a Google sign-in check
  screen with the owner's account address and device names. `build/` is
  git-ignored, so nothing reached the repo. Trim or delete the recording
  before sharing it anywhere. In future, start recording only after the
  `.test` app is in front.
- **N3 (Absence):** closing the limits dialog calls `s.save(const {})`
  (`absences_live.dart:24`). It rewrites `config.json` and runs every
  config listener, even when nothing was edited. Harmless, since it is
  the same save any setting uses, but a plain rebuild would do.
- **N4 (dead code):** these are only kept alive for older tests:
  `WizardController.calendarOptions`, `CalendarPreset` and
  `buildCalendarPresets` (the wizard now uses `schoolOptions`). These
  are unused: `alarmExactOff` and the `AppState.hasPresetBands`
  extension getter. Leave them unless the owner asks for a cleanup.
- **N5 (cosmetic, by reading the code):** `LiveWizardView` builds a new
  controller on every `AppState` change, and `WizardView.didUpdateWidget`
  then resets `_goingBack`. So *Zpět* probably slides the same way as
  *Pokračovat*. Not checked on the phone.
- **N6 (wording):** the wizard calls the no-preset choice *Jiná škola* /
  *Another school*. The Settings → Škola dropdown still says *Vlastní (bez
  presetu)* / *Custom (no preset)*. The owner may want one name. That's
  not in the plan, so it's not changed here.
- **N7 (tests):** new tests use `https://custom.school.cz` and
  `*.example.cz` as config values, never contacted. Prefer
  `http://127.0.0.1` (as R1 N4). `https://bakaweb.gekom.cz` appears only
  as the preset value under test, and no test contacts it.
- **N8 (deviations accepted):** these are accepted. They are the tests
  adapted to the new step list, as `design-F1.md` §9 asked: B1 round trip
  (now through the whole wizard and the `gemini_*` keys), B7 (now on
  *Dokončit*), P1 (neutral *zařízení/device* wording), P4 (Strava and
  Telefon switches), wizard look dots, resume, `marks_view_test`
  `presetBandsDriveConversionAndAreLabelled` (bands now hidden on Známky;
  the label and ranges are checked in Settings → Škola), and the
  `tut_abs_subject_body` update (rule 7). Not accepted: the parity fixture
  (X1) and the two deletions (M1).
- **N9 (owner):** the owner answered Q1 in this session: "And yes, the url
  is bakaweb.gekom.cz". It is recorded in STATUS. The preset value
  `https://bakaweb.gekom.cz` stands.

---

## Done when (PLAN §6 Phase 3, design-F1.md, review prompt)

| Check | Result |
|---|---|
| `design-F1.md` written and passed before code | ✔ R3a PASS (`7479366`); first code commit `1afb030` is after it |
| Preset id `gekom_2026_2027` stays; user presets in the `SCHOOL_PRESETS.md` format load; new fields optional | ✔ `schoolGroupsAndLegacyUserPreset`; reviewer loaded the doc's own example JSON as a user preset (validates, `presetBakalariUrl` works) |
| Only the owner's D1 school data | ✔ GEKOM gained exactly `bakalari_url` `https://bakaweb.gekom.cz`, `strava_canteen_id` `1950`, `marks_scale` `percent` (D1, Q1 confirmed now); no category, no `strava_url` (default is already `https://strava.cz`) |
| Wizard gating (`needsSetup`, `wizard_step`) | ✔ gating unchanged; resume rule `min(saved, 1)` / 0 without disclaimer tested; ✘ resumed Škola doesn't show the saved school (M2) |
| Uses the B1/B2 template editor; templates untouched round-trip | ✔ `TemplateEditor(embedded)` inside `TemplateGroupsList`; reviewer's round trip byte-identical (see below) |
| B9 permission fix; Telefon asks on purpose | ✔ asks on *Pokračovat*, waits, records the ask; `PhoneBackground` doesn't ask again; *Přeskočit* keeps the after-tour ask (B9 tests unchanged and green); phone: `phone_5_permission.png`, `phone_services_dumpsys.txt` (`KeepAliveService` foreground, `.test` only) |
| Settings → Škola only as far as D1 approves | ✔ section renamed, shared bands card added, preset change writes only `school_preset_id` (+ clears band drafts); no address controls |
| Známky hides bands and scale switches under a preset (D1) | ✔ tests and captures (`marks-gekom-*`); `custom` shows both |
| Limits out of the wizard, into Absence | ✔ `LimitsEditorContent` is the Settings editor moved verbatim; Settings → Limity links to Absence; ✘ wording of the empty-limits line (S2) |
| Tutorials updated (rule 7) | ✔ `marks_scale` step skipped under a preset (dots and *last* label adjusted), `tut_settings_intro`, `tut_abs_subject_body` |
| Screens at 390 / 1280, cs / en, light / dark | ✔ reviewer captures, no render errors; S1 and S2 are wording |
| Phone layout: full screen, pinned bar, no wrap at 390 px cs, above the keyboard; 250 ms transitions | ✔ test `F1 phone wizard layout` and phone screenshots |
| Disclaimer three sentences, cs/en; no AI in the wizard; no summary | ✔ |

## Each commit's test catches its change

One throwaway worktree in the reviewer's scratch space, removed afterwards.
For each commit: checked out its parent, copied in that commit's test files
(and the fixture for `1afb030`), ran them; then the same on the commit.

| Commit | On the parent | On the commit |
|---|---|---|
| `1afb030` | core test file doesn't compile (new helpers); parity test fails (fixture expects the new keys) | 20 + parity pass |
| `bf98783` | doesn't compile (`stepSchool`, `stepPhone`, `WelcomeLogo`) | 49 pass |
| `ff297de` | doesn't compile (`schoolOptions`) | 19 pass |
| `2696b70` | doesn't compile (prefill getters); the adapted B2 Settings tests fail with assertions (no template groups yet) | 34 pass |
| `b0c7582` | doesn't compile (`savePhone`, `notificationPermissionAsked`) | 70 pass |
| `4ff0a40` | 10 fail with assertions (no bottom bar, no `FilledButton`, no 250 ms switcher) | 24 pass |
| `efd75c4` | 2 marks tests fail with assertions; Absence and Settings tests don't compile (`LimitsEditorContent`) | 54 pass |
| `7c590ce` | doesn't compile (`tutorialVisibleStepIndices`) | pass |

Tests that can't compile on the parent prove nothing either way, so the
reviewer read each one. They check the behaviour the design asks for (exact
step lists, Škola writes only `school_preset_id`, prefill precedence,
Telefon asks once and waits, pinned bar on every step and with the
keyboard, preset scale precedence without rewriting config, tutorial step
skipping, limits saved from Absence). None of them only re-checks what the
code does by construction.

## What the reviewer verified, and how

1. **Suites** (worktree, Flutter 3.44.8 / Dart 3.12.2):
   - `dart pub get --enforce-lockfile`: OK.
   - Core: `dart analyze` no issues; `dart test` **808 passed, 2 skipped**.
     That is 804 at R3a plus 4 new preset tests; the skips are the old
     POSIX ones.
   - App: `flutter analyze` no issues; `flutter test` **710 passed, 1
     skipped**. That is 703 at R3a, net +7: about 13 new F1 tests, 4
     removed with their code, and 2 deleted (M1).
   - The worktree's uncommitted `generated_plugin*` files are Flutter
     line-ending churn, not part of any commit.
2. **Every commit green on its own:** `dart analyze`, `dart test`,
   `flutter analyze` and `flutter test` at each of the eight code commits.
   Results are in *Per-commit check* below.
3. **Tests catch the change:** table above.
4. **Reviewer's own tests**, run at `ae037f5` and not committed:
   - **B1 round trip:**
     - Seeded `config.json` with all four template keys: named multi-line
       texts, an empty line inside a text, a `{text, name}` map in reverse
       key order, a name with surrounding spaces, a plain multi-line
       string, and padded text. Also seeded four `gemini_*` keys,
       including a multi-line prompt.
     - Drove `LiveWizardView` from Vítejte: disclaimer, Škola (GEKOM),
       skip Bakaláři and Strava, Omluvenky. There it opened *Pokročilé*
       and a group, focused and blurred a template field, forced two
       `AppState` rebuilds, entered a name, then pressed *Dokončit*.
     - Every seeded key was identical (`jsonEncode`, key order included)
       after Škola, at Hotovo and after *Dokončit*, at 800 px and
       390 px. Passed.
     - At 1280 px the wide footer overflows by 14 px with the test's Ahem
       font only. With real fonts at 1280 px there is no overflow (step
       5).
   - **Resume (M2):** fails as described.
   - **The two deleted tests (M1):** copied unchanged from `f8d5582`.
     Both pass.
   - **`SCHOOL_PRESETS.md` example:** the doc's JSON validates and loads
     as a user preset. GEKOM still loads.
5. **Screens:**
   - Capture run derived from `tools/parity/capture_screens.dart`: the real
     router and `MyApp` setup, real Roboto fonts, demo data from
     `tools/demo_data.py`, fresh folders for the wizard.
   - Screens: wizard steps 0–6 plus Škola with *Jiná škola* and Omluvenky
     opened; Settings → Škola (GEKOM and `custom`), Šablony and Limity;
     Známky (GEKOM and `custom`); Absence (with limits, without, and the
     limits dialog).
   - 390 and 1280 px, cs and en, light and dark: **144 images, no render
     or overflow errors**. Everything looked right except S1 and S2.
   - The agent's phone screenshots were all opened: welcome, Škola,
     Bakaláři prefill and keyboard, Strava, Omluvenky, Telefon, the
     permission dialog, Hotovo, Today after finishing, and resume.
   - Frames of `phone_welcome.mp4` were tiled: the logo scales in, then
     the heading, text and buttons appear one after another. See N2.
6. **Plan corrections:** the preset id is `gekom_2026_2027`, and only the
   owner's D1 values were added. The report's nested school classes,
   `PageView`, AI step and summary weren't used (`design-F1.md` §8).
7. **Scope:** every change maps to `design-F1.md`, with two exceptions:
   - X1, the fixture;
   - the Settings preset dropdown now also clears the band drafts. That
     is needed so a preset change doesn't keep stale band text, and is
     accepted.
   No feature outside the note. F1b (joining Absence and Plánovač) wasn't
   started.
8. **Config keys and strings:**
   - No key added, removed or renamed. `config.example.json` and
     `config.dart` are unchanged on the branch.
   - Parity fixtures: only X1. `helpers.json` is unchanged.
   - The cs and en ARB files have the same keys, and `strings.dart` has
     every ARB key in both tables, checked by script. Removed keys are
     unused. New strings have real Czech and English text. The string
     table tests are green.
9. **Safety rules:**
   - Nothing in core `automation/`, `lunches/`, `strava/`, `bakalari/` or
     `storage/` changed.
   - In `app/lib/controllers/`, only these changed: the resume rule and
     the `notificationPermissionAsked` flag (`app_state.dart`), the preset
     scale getters (`marks.dart`), and tutorial step skipping
     (`tutorial.dart`).
   - `runRefresh`, the session lock, `sendExcuse` / `HistoryLock`, the
     audit and `automation_paused` are untouched. *Dokončit* still starts
     the first refresh through `startRefresh`.
   - The two new `catch (_)` are number-parse probes moved unchanged from
     the old Settings limits editor and the old `_BandsCard`.
   - Nothing new sends, orders or saves without the user's action.
10. **Test integrity:**
    - `git diff f8d5582..ae037f5` on the test files: no `skip:`, and no
      `try`/`catch` around assertions.
    - Removed tests: M1 (two) and the four removed with their code.
    - Changed assertions: the adapted ones in N8, and S4.
11. **Phone** (read-only, `adb -s 2C221FDH3002NZ`):
    - The Play app `io.github.dendlerx.strakalari` still has
      `lastUpdateTime=2026-11-13 04:07:35` from `com.android.vending`, so
      it wasn't reinstalled or touched.
    - The `.test` app was last installed 2026-11-17 14:45, built after
      the last code commit.
    - The reviewer didn't operate the phone.
12. **Hygiene:**
    - No `config.json`, `data_cache.json`, `log.txt`, `htmls/`, keys or
      screenshots in any commit.
    - All commits are by the configured user, with no `Co-Authored-By`,
      `Claude-Session` or "Generated with" lines.
    - `qa-roadmap` has no upstream, so nothing was pushed. `main` has no
      commits the branch lacks.
13. **Not checked:** macOS and iOS builds (not possible here). The
    resume path and the Telefon prompt on the phone after the M2 fix will
    be the agent's new evidence.

### Per-commit check

Full `dart analyze`, `dart test`, `flutter analyze` and `flutter test` at
each code commit (throwaway worktree):

| Commit | Core analyze / test | App analyze / test |
|---|---|---|
| `1afb030` | clean / 808 + 2 skipped | clean / 703 + 1 skipped |
| `bf98783` | clean / 808 + 2 | clean / **695** + 1 (the M1 deletions and the four removed with their code) |
| `ff297de` | clean / 808 + 2 | clean / 697 + 1 |
| `2696b70` | clean / 808 + 2 | clean / 698 + 1 |
| `b0c7582` | clean / 808 + 2 | clean / 701 + 1 |
| `4ff0a40` | clean / 808 + 2 | clean / 703 + 1 |
| `efd75c4` | clean / 808 + 2 | clean / 708 + 1 |
| `7c590ce` | clean / 808 + 2 | clean / 710 + 1 |

No commit left a broken tree.

---

## Re-review 2026-11-17

Re-reviewed at `qa-roadmap` @ `792ec4f` (base `main` @ `f8d5582`; `main`
still has no commits the branch lacks). Commits since the review
(`fa71cc7`): `1838525` (X1), `ca17f0c` (M1), `bedcf60` (M2), `1627602`
(S1), `d2f6033` (S2), `20fbc63` (S3), `ae8d768` (S4), `19858ae` (owner:
no *Změnit* on the preset Bakaláři address), and `cb16159` / `792ec4f`
(STATUS only).

### Verdict: **PASS WITH FIXES**

The blocker, both must-fix and all four should-fix findings are fixed in the
code, not just marked as fixed. Each code fix has a test that fails without
it. All four suites are green, with three more app tests than at the
review. One should-fix is left (S5): the M2 fix covers a wizard resumed
mid-way, but not a wizard that shows again after it was finished without
logins. The saved school is still lost in that case. Nothing else changed.

### Open finding

#### S5 (should-fix, F1 / M2): the wizard shown again after finishing without logins forgets the saved school

- **Where:** `app/lib/controllers/app_state.dart:132–144` (the resume
  block added in `bedcf60`). It seeds `wiz:cal_preset` only when
  `savedStep >= 0`.
- **What is wrong:**
  - A user can reach *Dokončit* with *Přeskočit* on Bakaláři and Strava.
    `wizardFinished()` saves `wizard_step: -1`.
  - On the next start `needsSetup()` is true (no credentials), so the
    wizard shows again from Vítejte.
  - Škola then has nothing picked and *Pokračovat* is disabled, though
    `school_preset_id` is `gekom_2026_2027`.
  - The R3 M2 text asked for the seed "when the saved step was past Škola
    (`wizard_step` > 1), **or when the saved id is a real preset (not
    `custom`)**". The second half isn't met in this path.
  - Reviewer's test at `792ec4f`: save `disclaimer_accepted` and GEKOM,
    go to `stepDone`, `wizardFinished()`, new `AppState()`. Result:
    `needsSetup()` is true, `wizardStep` 0, `calPreset()` `''`.
- **What correct looks like:** one commit, `F1: keep the saved school when
  the wizard shows again (R3 S5)`.
  - Whenever the wizard is shown, a real saved preset (not `custom`) is
    picked on Škola. That includes `wizard_step` -1 with `needsSetup()`
    true. One way: also seed in `AppState.wizardOpened()` when
    `wiz:cal_preset` isn't in `drafts` yet and the saved
    `school_preset_id` is a real preset.
  - Keep what works today:
    - an explicit pick, including *Jiná škola*, is never overwritten;
    - a fresh install still needs an explicit pick
      (`testCalendarStepRequiresExplicitPick` and the fresh case of
      `resumed wizard keeps saved school picked …` stay unchanged);
    - starting the app writes nothing to `config.json`.
  - Add a test to `wizard_live_test.dart` that fails on `792ec4f`:
    ```dart
    final first = AppState()..wizardOpened();
    first.save({'disclaimer_accepted': true,
                'school_preset_id': 'gekom_2026_2027'});
    first.wizardGoto(WizardController.stepDone, WizardController.stepDone);
    first.wizardFinished();
    final again = AppState();
    expect(again.needsSetup(), isTrue);
    again.wizardOpened(); // as LiveWizardView does
    final c = wizardControllerFor(again);
    expect(c.calPreset(), 'gekom_2026_2027');
    ```

### Notes (no action needed)

- **N10 (M2, old step numbers):** someone who quit the **old** wizard on
  steps 2–5 resumes on Škola with *Jiná škola* already picked. Their
  `school_preset_id` was still the default `custom`, and the seed rule
  takes `wizard_step` > 1 as "past Škola". This is what the R3 M2 text
  allowed. It only affects someone halfway through setup during the update,
  and they can still pick their school. Accepted.
- **N11 (`19858ae`, owner):** the preset Bakaláři address has no
  *Změnit* any more, as the owner asked ("One thing, I wouldnt give them
  the option to change the link"). It is recorded under *Owner decisions*
  and *Deviations*. Accepted.
  - A wrong preset address can now only be fixed in Nastavení → Účty after
    setup. The address is the owner's confirmed one (Q1).
  - `design-F1.md` §3 still describes *Změnit* on Bakaláři. It is a
    historical design note, so leave it.
  - Whether Strava's *Změnit* stays is an open owner question in STATUS.
- **N12 (STATUS):** the Phase 3 *Unsure* list still says Q1 is open. It was
  answered at R3 ("And yes, the url is bakaweb.gekom.cz"). Mark it answered
  if you touch STATUS anyway.

### Each earlier finding

| Finding | Fixed? | How the reviewer checked |
|---|---|---|
| X1 | ✔ `1838525` | `git diff f8d5582 -- packages/strakalari_core/test/parity/` is empty. `parity_school_presets_test.dart` adds the three D1 fields in a commented constant for `getPreset('gekom_2026_2027')` only. With `'1951'` in the constant the parity test **fails**; as committed it passes. STATUS *Deviations* rewritten. |
| M1 | ✔ `ca17f0c` | Both tests are back, byte-identical to `f8d5582` (compared by diff), before `testNoSkipWhereNothingMayBeSkipped`. The four tests removed with their code are listed under *Deviations*, each with its reason. |
| M2 | ✔ `bedcf60`, with S5 left | `wiz:cal_preset` is seeded from `school_preset_id` on resume. `saveCalendar` skips the save when nothing changed. New test **fails on `ca17f0c`** (`calPreset()` `''`) and passes on `bedcf60`. Reviewer's own tests at `792ec4f`: resume on Škola keeps GEKOM; starting the app doesn't touch `config.json` (content and mtime); picking *Jiná škola* on a resumed Škola saves `custom`. Phone: `phone_resume.png` (17:08, `.test` installed 17:07:58) shows GEKOM picked and *Pokračovat* enabled. Gap: S5. |
| S1 | ✔ `1627602` | `wiz_bakalari_p_preset` / `wiz_strava_p_preset` in both ARB files and `strings.dart` (cs/en as asked), used only while the prefill row shows. Extended test **fails on `bedcf60`** and passes on `1627602`; it checks GEKOM, `custom` and Strava after *Změnit*. |
| S2 | ✔ `d2f6033` | `abs_no_limits` now says *Všechny předměty mají výchozí limit {pct:g} %.* / *All subjects use the default limit of {pct:g} %.*, fed from `absence_critical_pct`. The test checks 25 % and a change to 30 %. It **fails on `1627602`** and passes on `d2f6033`. |
| S3 | ✔ `20fbc63` | README cs/en and `SCHOOL_PRESETS.md` use *Jiná škola* / *Another school* and *Nastavení → Škola* / *Settings → School*, and l.79 points to Settings → School. No old names left (grep). Docs only. |
| S4 | ✔ `ae8d768` | The P3 test enters a name, taps *Pokračovat* and asserts `stepDone`, then checks *Zpět*. It is a test-only change, so it passes on its parent and on the commit, as expected. Listed under *Deviations*. |

### What the reviewer verified, and how

1. **Suites** (worktree, Flutter 3.44.8 / Dart 3.12.2):
   - `dart pub get --enforce-lockfile`: OK.
   - Core: `dart analyze` no issues; `dart test` **808 passed, 2
     skipped**. That is the same as R3; the skips are the old POSIX ones.
   - App: `flutter analyze` no issues; `flutter test` **713 passed, 1
     skipped**. That is 710 at R3 plus the two M1 tests and the M2 test.
   - Use these counts as the baseline for the next review.
2. **Each fix's test fails without it:**
   - One throwaway worktree in the reviewer's scratch space, removed
     afterwards.
   - For M2, S1, S2 and `19858ae`: checked out the parent, copied in the
     commit's test file, and ran that test. It fails with an assertion
     (table above; `19858ae`'s test finds *Změnit* on the parent). On the
     commit it passes.
   - X1: checked by changing the constant.
   - M1 and S3: compared by diff.
3. **Reviewer's own tests** at `792ec4f` (not committed): S5 (fails as
   described), N10, resume on Škola, no write at start-up, and changing
   the seeded school.
4. **Screens:**
   - Captured with a copy of `tools/parity/capture_screens.dart` (real
     router and `MyApp` setup, Roboto, demo data).
   - Screens: wizard Bakaláři and Strava with GEKOM and with `custom`, and
     Absence without subject limits.
   - 390 and 1280 px, cs and en, light and dark: **40 images, no render
     or overflow errors**. The short texts show only with the prefill,
     and the Absence line matches the *Limit: 25 %* rows.
   - The agent's phone screenshots `phone_resume.png`,
     `phone_2_bakalari_prefill.png` (no *Změnit*, short text) and
     `phone_3_strava.png` were opened.
5. **Scope:** the code commits touch only what each finding names, plus
   `19858ae`, which follows the owner's recorded words. No new feature.
   F1b and Phase 4 weren't started.
6. **Config keys and strings:**
   - No key added, removed or renamed. `config.example.json`, `config.dart`
     and `test/parity/` match `main`.
   - The cs and en ARB files have the same keys. The three new or changed
     strings match `strings.dart` in both tables (checked by script).
7. **Safety rules:**
   - Since the review, nothing in core `lib/` changed.
   - In `app/lib/controllers/`, only the resume seed in `app_state.dart`
     changed. It only fills an in-memory draft.
   - `runRefresh`, the session lock, `sendExcuse` / `HistoryLock`, the
     audit and `automation_paused` are untouched. No new `catch`.
8. **Test integrity:**
   - The removed test lines since the review are only the replaced
     assertions for S2 (new text), S4 (Back → Continue) and S1 (the
     `custom` case now renders too), and X1's `final expected`.
   - No `skip:`, no `try`/`catch` around assertions, and no assertion
     loosened.
   - The only host in new tests is the preset value under test.
9. **Phone** (read-only, `adb -s 2C221FDH3002NZ`):
   - The Play app `io.github.dendlerx.strakalari` still shows
     `lastUpdateTime=2026-11-13 04:07:35` from `com.android.vending`, so
     it wasn't reinstalled.
   - The `.test` app was installed at 17:07:58, after `19858ae`.
   - The reviewer didn't operate either app. At the owner's request
     (refresh interval, see STATUS *Questions*), the reviewer read the
     phone's own data counter for the Play app (`dumpsys netstats`,
     read-only). Nothing was logged in or changed.
10. **Hygiene:**
    - No personal files or screenshots in any branch commit.
    - All commits are by the configured user, with no `Co-Authored-By`,
      `Claude-Session` or "Generated with" lines.
    - `qa-roadmap` has no upstream, so nothing was pushed.
11. **Not checked:** macOS and iOS builds (not possible here).

---

## Re-review 2 (2026-11-17)

Re-reviewed at `qa-roadmap` @ `af17c27` (base `main` @ `f8d5582`; `main`
still has no commits the branch lacks). Commits since the re-review
(`9bc4301`): `0fd3017` (S5), and `daa1c67` / `af17c27` (STATUS only).

### Verdict: **FAIL**

S5 is fixed: a wizard shown again after finishing without logins now keeps
the saved school. But the fix also puts the saved school into the wizard
draft at **every** app start, even when no wizard is shown. That draft is
never refreshed, so it can go stale and later be written back over a newer
choice (M3). The fix is one line, and the reviewer tested it (below).

The owner also decided a small F1 change in this session (O2, below). It is
not a finding, but it belongs in the same round.

### Must-fix

#### M3 (F1, `0fd3017`): a stale school pick can overwrite the school chosen in Settings

- **Where:** `app/lib/controllers/app_state.dart:138`
  (`_seedSchoolPresetDraft(savedStep);` in the constructor, which since
  `0fd3017` runs outside the `savedStep >= 0` check).
- **What is wrong:**
  - A set-up app (logins saved, no wizard in progress) now puts the saved
    school into the draft `wiz:cal_preset` at start-up, though no wizard
    is shown.
  - Nothing refreshes that draft. If the user then changes the school in
    Settings → Škola, the draft still holds the old one.
  - If the logins are then cleared in the same session (Settings → Účty,
    Bakaláři username emptied, no Strava login), `needsSetup()` turns
    true and the wizard takes over the screen (`scaffold.dart:231`).
  - Škola shows the **old** school picked, and *Pokračovat* writes it back
    over the Settings choice. That silently brings back the old grade
    conversion, lunch cutoff and free days.
  - Reviewer's test at `af17c27`:
    - setup: GEKOM and a Bakaláři login saved, new `AppState`;
    - then: save `custom`, clear the username, `wizardOpened()`;
    - result: Škola shows `gekom_2026_2027`, and *Pokračovat* saves
      `school_preset_id: gekom_2026_2027`.
    - The same test at `9bc4301`: Škola shows nothing, and nothing is
      written.
- **What correct looks like:** one commit, `F1: seed the school only for a
  wizard on screen (R3 M3)`.
  - In the constructor, seed only for a wizard in progress, as `bedcf60`
    did: `if (savedStep >= 0) _seedSchoolPresetDraft(savedStep);`.
    Settings can't be reached while a wizard is in progress. Keep the
    seed in `wizardOpened()`. It reads the config at the moment the wizard
    appears, which covers S5.
  - The reviewer tried exactly this change:
    - the stale case below writes nothing;
    - the S5 test and all of `wizard_live_test.dart` pass;
    - a live-view test passes: `LiveWizardView` on the reopened state,
      then Škola shows GEKOM picked with *Pokračovat* enabled.
  - Add the stale case to `wizard_live_test.dart` (it must fail on
    `af17c27`):
    ```dart
    AppState().save({
      'disclaimer_accepted': true,
      'school_preset_id': 'gekom_2026_2027',
      'bakalari_url': 'http://127.0.0.1:18080',
      'bakalari_username': 'demo',
    });
    final s = AppState();
    expect(s.needsSetup(), isFalse);
    s.save({'school_preset_id': 'custom'});   // Settings → Škola
    s.save({'bakalari_username': ''});        // Settings → Účty
    expect(s.needsSetup(), isTrue);
    s.wizardOpened();
    final c = wizardControllerFor(s)..step = WizardController.stepSchool;
    expect(c.calPreset(), isNot('gekom_2026_2027'));
    c.pressNext();
    expect(s.config.get('school_preset_id', ''), 'custom');
    ```

### Owner change for this round: O2 (F1, not a finding)

The owner said, word for word: "You may also remove the canteen number text
as well as the url, its set from the preset." This also answers the open
question about Strava's *Změnit*.

- **What:** when the preset supplies the value, the wizard shows neither the
  address row (*Škola: bakaweb.gekom.cz*) on Bakaláři, nor the canteen
  row (*Jídelna: 1950*) and its *Změnit* on Strava. The values are still
  used for the connection test and saved as today (draft, then config,
  then preset).
- **Resumed wizard too:**
  - Today `showBakalariUrlField` and `showStravaCanteenField`
    (`wizard_controller.dart:230–239`) show the editable field as soon as
    the config holds a value. So on a resumed wizard, the GEKOM address
    saved earlier comes back as an editable field.
  - Hide the field also when the config value equals the preset value.
  - Show the normal field only when there is no preset value (*Jiná
    škola*), or when the config holds a different value of the user's
    own.
- **Clean-up:**
  - Remove `_prefillRow` and the `wiz:edit_strava_canteen` draft.
  - Remove the strings `wiz_prefill_school`, `wiz_prefill_canteen` and
    `wiz_prefill_change` from both ARB files and `strings.dart`, unless
    something else still uses them.
  - The S1 short texts stay: they don't mention the address or canteen.
- **Unchanged:** Settings → Účty keeps both fields as they are.
- **Tests:** adapt `GEKOM prefills Bakaláři URL and Strava canteen …`:
  - with GEKOM: no address row, no canteen row, no *Změnit*;
  - after a passing fake test, the saved config holds the preset values;
  - a resumed wizard whose config equals the preset shows no field;
  - a config with a different value of the user's own still shows the
    field;
  - *Jiná škola* shows both fields.
  - The *Změnit* tap goes with the button. List that under *Deviations*,
    with the owner's words.
- **Evidence:** Bakaláři and Strava with GEKOM at 390 px (capture or
  phone).
- **Commit:** one commit, `F1: hide the preset address and canteen in the
  wizard (owner)`.

### Notes (no action needed)

- **N13 (`af17c27`, measurement):**
  - STATUS says the owner ran a separate measuring build with the real
    logins, outside the repository. Nothing from it is in the branch:
    `af17c27` adds one STATUS line, with endpoint names and sizes only.
  - `C:\strakalari-measure` holds program files only. The reviewer
    looked for `config.json`, cache, log and key files by name and found
    none.
  - If the run used a copy of the real config anywhere else, delete it
    when you're done.
  - Its result (about 1 MB per routine refresh, ~25 MB a day hourly)
    agrees with the reviewer's reading of the phone's own counter (about
    30 MB a day).

### Each earlier finding

| Finding | Fixed? | How the reviewer checked |
|---|---|---|
| S5 | ✔ `0fd3017`, but it caused M3 | `_seedSchoolPresetDraft` runs at start-up and in `wizardOpened()`, never over an existing draft. The new test **fails on `9bc4301`** (`calPreset()` `''`) and passes on `0fd3017`. It also passes with the `wizardOpened()` seed removed, because it is carried by the start-up seed. After M3's change it is carried by the `wizardOpened()` seed (the reviewer checked). |

### What the reviewer verified, and how

1. **Suites** (worktree, Flutter 3.44.8 / Dart 3.12.2):
   - `dart pub get --enforce-lockfile`: OK.
   - Core: `dart analyze` no issues; `dart test` **808 passed, 2
     skipped**.
   - App: `flutter analyze` no issues; `flutter test` **714 passed, 1
     skipped**. That is 713 plus the S5 test.
2. **Test before and after:** in a throwaway worktree (removed afterwards),
   the S5 test from `0fd3017` was run on `9bc4301` (fails with an
   assertion) and on `0fd3017` (passes).
3. **Reviewer's own tests** (not committed):
   - the stale case at `af17c27` (M3) and at `9bc4301` (no write);
   - the suggested one-line change against the stale case, the S5 test,
     the whole `wizard_live_test.dart` and the live-view test (all pass).
4. **Scope:** `0fd3017` touches only `app_state.dart` and its test. There
   is no UI change, so no new screen captures.
5. **Safety rules:**
   - `runRefresh`, the session lock, `sendExcuse` / `HistoryLock`, the
     audit and `automation_paused` are untouched. No new `catch`.
   - M3 is a config write of a stale value through the normal wizard
     save, not a new write path.
6. **Test integrity:** no removed test lines, no `skip:`, no
   `try`/`catch` around assertions.
7. **Hygiene:**
   - No personal data in the commits.
   - No `Co-Authored-By`, `Claude-Session` or "Generated with" lines.
   - `qa-roadmap` has no upstream.
8. **Not checked:** macOS and iOS builds (not possible here).

---

## Re-review 3 (2026-11-17)

Re-reviewed at `qa-roadmap` @ `6718510` (base `main` @ `f8d5582`; `main`
still has no commits the branch lacks). Commits since re-review 2
(`c61e479`):

- `2c1a256` (M3) and `4484155` (O2, the owner's change);
- `970c5d5` (STATUS only);
- `51d9e42`, `84254bd`, `3c2ad05`, `a7f63af`, `6718510`: the F6 proposal,
  research prompt and research report, docs only (N14).

### Verdict: **FAIL**

M3 is fixed with the one line asked for, and its test fails without it. O2
is done as the owner asked: with GEKOM, the wizard shows neither the
address nor the canteen, and all suites are green.

But O2 opened a new hole (M4). If the user has typed an address under
*Jiná škola* and then switches to GEKOM, the wizard can hide the address
field while the address is empty. *Otestovat a pokračovat* then only says
"fill in Bakaláři", and there's nothing to fill in. A GEKOM student gets
stuck on step 3. The fix is four lines, and the reviewer tested it (below).

### Must-fix

#### M4 (F1 / O2, `4484155`): a hidden address or canteen field can leave the value empty, and the wizard gets stuck

- **Where:** `app/lib/features/wizard/wizard_controller.dart:212–219`
  (`effectiveBakalariUrl`) and `:221–228` (`effectiveCanteenId`), together
  with the new `showBakalariUrlField` / `showStravaCanteenField`
  (`:230–246`).
- **What is wrong:**
  - Since `4484155`, under a preset the field shows only when a draft
    holds a **non-empty** value that differs from the preset. But
    `effectiveBakalariUrl()` still returns the draft whenever one exists,
    **even an empty one**.
  - So with an empty `wiz:bakalari_url` draft and GEKOM picked, there is
    no address field and the address used is `''`. *Otestovat a
    pokračovat* shows `wiz_need_bakalari` (*Vyplňte…*) and runs no test.
    The short S1 text even says only username and password are needed.
  - Two ways to get there. Both were reproduced through `LiveWizardView`
    with real taps at `6718510`:
    1. Škola → *Jiná škola* → Bakaláři, type an address → *Zpět* →
       GEKOM → Bakaláři. The typed address is shown, because it differs
       from the preset. The user clears it to get the school's address.
       On the next rebuild (keyboard closing, any `AppState` change), the
       field disappears and the address stays empty.
    2. The same, but the address was typed and erased again under *Jiná
       škola*. With GEKOM there is no address field at all from the
       start, and the address is empty.
  - The only ways out are *Zpět* → *Jiná škola* and typing the address by
    hand, or restarting the app. A student won't know either.
  - The Strava canteen has the same hole: a canteen number typed under
    *Jiná škola*, then GEKOM, then cleared gives no field and
    `effectiveCanteenId()` `''`, so `readyStrava()` stays false (checked
    in the controller).
  - Before O2 (`2c1a256`), the same reviewer tests pass: the field stays
    visible while a draft exists. So `4484155` introduced this.
- **What correct looks like:** one commit, `F1: never hide an empty
  address or canteen (R3 M4)`.
  - Under a preset, a hidden field always means the preset value is used.
    An empty draft counts as no draft while the field is hidden. The
    reviewer tried exactly this:
    ```dart
    String effectiveBakalariUrl() {
      final d = drafts['wiz:bakalari_url']?.trim();
      if (d != null && (d.isNotEmpty || showBakalariUrlField)) return d;
      final cfg = '${config['bakalari_url'] ?? ''}'.trim();
      if (cfg.isNotEmpty) return cfg;
      return presetBakalariUrl();
    }
    ```
    `effectiveCanteenId()` gets the same change, with
    `wiz:strava_canteen_id` and `showStravaCanteenField`.
  - Result with this change:
    - both paths above run the connection test with
      `https://bakaweb.gekom.cz`;
    - the canteen case gives `1950`;
    - all 715 app tests pass, plus the reviewer's 6.
  - Keep what works today:
    - *Jiná škola* always shows both fields;
    - an own value in the config that differs from the preset shows the
      field;
    - clearing the field in those two cases still means "empty", and the
      user has to type a value.
  - Tests in `app/test/wizard_live_test.dart`, group `F1 login prefills`.
    Each must fail on `6718510`:
    - **Path 1, live:**
      - `LiveWizardView` on a bare `AppState` with
        `disclaimer_accepted`, `wizardStep` = Škola;
      - tap `school:custom`, `wiz:next_btn`, enter an address in
        `draft:wiz:bakalari_url`, tap `wiz:back_btn`, `school:GEKOM`,
        `wiz:next_btn`;
      - clear the address, fill username and password, call
        `s.onChanged()`, tap *Otestovat a pokračovat*;
      - expect no `wiz_need_bakalari` text and the test started with
        `https://bakaweb.gekom.cz`. A bare `AppState` claims `testing`
        and never touches the network, so `s.testing == 'bakalari'` plus
        `wizardControllerFor(s).effectiveBakalariUrl()` is enough.
    - **Path 2, live:** the same, but erase the address under *Jiná
      škola* before *Zpět*.
    - **Strava, controller:** canteen `1234` typed under *Jiná škola*,
      then GEKOM, then cleared: `effectiveCanteenId()` is `1950`.

### Notes (no action needed)

- **N14 (F6 docs, owner):**
  - Five commits add the F6 proposal, the step 0 research prompt and its
    report. They are docs only, in `docs/qa-roadmap/`, at the owner's
    request, and recorded in STATUS (*Owner decisions*, F6 row).
  - F6 isn't in PLAN and no F6 code exists. That is right until the
    owner's "go", D6 and a design note with its review.
  - The research used the owner's real GEKOM login, read-only, in a
    separate session the owner asked for. The implementing agent's "no
    real services" rule is unchanged.
  - The reviewer scanned the three files for e-mail addresses, tokens,
    long ids, names and hosts. Only the school's public address and
    made-up examples are there.
  - `a7f63af` adds one *Owner decisions* line beyond the prompt's "one
    line in the F6 row". It quotes the owner word for word, so it is
    fine.
- **N15 (evidence):**
  - The agent's O2 captures are 390 px only: cs/en dark and cs light.
    The reviewer captured the rest (below).
  - The phone screenshots `phone_2_bakalari_prefill.png` and
    `phone_3_strava.png` are from before O2 and still show the old rows.
    Retake them when the phone is next in use; no need now.
  - STATUS *How to verify* (Phase 3) still names `phone_welcome.mp4`,
    which was deleted for N2.
- **N16 (M3 live):** the S5 case still works through the real screen
  after M3. In the reviewer's test, a wizard shown again after finishing
  without logins puts nothing into the drafts at start-up and leaves
  `config.json` unchanged. After *Pokračovat* on Vítejte, Škola shows GEKOM
  ticked and *Pokračovat* enabled.

### Each earlier finding

| Finding | Fixed? | How the reviewer checked |
|---|---|---|
| M3 | ✔ `2c1a256` | Exactly the one line asked for: `if (savedStep >= 0) _seedSchoolPresetDraft(savedStep);`. The new test (the reviewer's stale case) **fails on `84254bd`** (`Expected: not 'gekom_2026_2027'`) and passes on `2c1a256`. The S5 test still passes on `2c1a256`, now through the `wizardOpened()` seed, and through the live screen (N16). |
| O2 | ✔ `4484155`, but see M4 | With GEKOM, neither row nor *Změnit* shows, also when the saved config equals the preset. An own config value and *Jiná škola* show the field. `_prefillRow`, `_displayHost`, `wiz:edit_strava_canteen` and the three `wiz_prefill_*` strings are gone, and nothing else used them (grep over the repo). Settings → Účty is unchanged. The adapted test **fails on `2c1a256`** (finds *Škola: bakaweb.gekom.cz*) and passes on `4484155`. The reviewer's resumed-config case also fails on `2c1a256` and passes on `4484155`. Every test point from re-review 2 is covered, including the saved preset values after a passing fake test. The *Změnit* tap removal is listed under *Deviations* with the owner's words. |

### What the reviewer verified, and how

1. **Suites** (worktree, Flutter 3.44.8 / Dart 3.12.2):
   - `dart pub get --enforce-lockfile`: OK.
   - Core: `dart analyze` no issues; `dart test` **808 passed, 2
     skipped**. The skips are the old POSIX ones.
   - App: `flutter analyze` no issues; `flutter test` **715 passed, 1
     skipped**. That is 714 plus the M3 test; O2 adapted an existing
     test.
   - Use these counts as the baseline for the next review.
2. **Each fix's test fails without it:**
   - One throwaway worktree in the reviewer's scratch space, removed
     afterwards.
   - The commit's test file was copied onto the parent and run, then run
     on the commit (table above).
3. **Reviewer's own tests** (not committed):
   - M4, paths 1 and 2 through `LiveWizardView`: both stuck at
     `6718510`, both fine at `2c1a256`.
   - M4, controller-level: Bakaláři with and without a rebuild, and the
     Strava canteen. Stuck at `6718510`, fine at `2c1a256`.
   - The suggested change: all M4 tests pass, and the whole app suite
     passes (721 = 715 + 6 reviewer tests).
   - O2 resumed config equal to the preset: fails on `2c1a256`, passes
     on `4484155`.
   - S5 through the live screen after M3 (N16).
   - No test touched the network. The live connection test runs only
     with the real app's `spawn`, and a bare `AppState` never runs it.
4. **Screens:**
   - Captured with a copy of `tools/parity/capture_screens.dart`: real
     router and `MyApp` setup, Roboto.
   - Bakaláři and Strava steps in three cases: GEKOM fresh, GEKOM with
     saved values equal to the preset (resumed), and *Jiná škola*.
   - 390 and 1280 px, cs and en, light and dark: **48 images, no render
     or overflow errors**.
   - The fields show only for *Jiná škola*, and the short S1 texts show
     with GEKOM.
   - The agent's 390 px captures (19:07, from the O2 tree) were opened.
5. **Scope:**
   - `2c1a256` is the one line and its test.
   - `4484155` touches only what O2 names: the two getters, the two rows
     in the view, three strings and the test.
   - The F6 commits are docs only (N14).
   - O1, F1b and phase 4 weren't started.
6. **Config keys and strings:**
   - No key added, removed or renamed. `config.example.json`,
     `config.dart` and `test/parity/` match `main`.
   - The cs and en ARB files have the same 800 keys, and both
     `strings.dart` tables match them exactly (checked by script).
7. **Safety rules:**
   - Since re-review 2, only one line changed in `app/lib/controllers/`
     (M3), and nothing in core `lib/`.
   - `runRefresh`, the session lock, `sendExcuse` / `HistoryLock`, the
     audit and `automation_paused` are untouched. No new `catch`.
   - M4 blocks setup; it sends and saves nothing wrong.
8. **Test integrity:**
   - The removed test lines are the old prefill-row and *Změnit*
     assertions, replaced by the O2 ones the review asked for.
   - No `skip:`, no `try`/`catch` around assertions, and the count went
     up by one.
   - The new hosts are `http://127.0.0.1:18080` and the preset value
     under test.
9. **Phone:**
   - Not checked this time. `adb devices` showed only a stale offline
     emulator; the Pixel wasn't connected.
   - This round has no phone item.
10. **Hygiene:**
    - No personal files or screenshots in the new commits.
    - The F6 docs are scanned (N14).
    - No `Co-Authored-By`, `Claude-Session` or "Generated with" lines.
    - `qa-roadmap` has no upstream.
    - The worktree's uncommitted `generated_plugin*` files are the known
      Flutter line-ending churn.
11. **Not checked:** macOS and iOS builds (not possible here), and the
    phone (not connected).

---

## Re-review 4 (2026-11-17)

Re-reviewed at `qa-roadmap` @ `606565d` (base `main` @ `f8d5582`; `main`
still has no commits the branch lacks). Commits since re-review 3
(`4375fee`):

- `bba4886` (M4);
- `606565d` (STATUS only).

### Verdict: **PASS**

M4 is fixed in the code, with exactly the change the review asked for. A
hidden address or canteen field now always means the school's own value
is used. A GEKOM student who first typed something under *Jiná škola* no
longer gets stuck on Bakaláři or Strava. The three new tests fail on the
old code with real assertion errors and pass on the fix. All four suites
are green, with three more app tests than at re-review 3. Nothing else
changed. No finding is left open, so phase 3 (F1) passes.

### Notes (no action needed)

- **N17 (M4, intended behaviour):** under GEKOM, a user who clears an
  address of their own now gets the school's address. The field goes away
  at the next rebuild. That is what O2 and M4 asked for ("a hidden field
  always means the preset value is used"). Under *Jiná škola*, or with an
  own address saved in the config, clearing still means "empty", and the
  user has to type one (checked, see below).
- **N18 (evidence, from N15):** `phone_2_bakalari_prefill.png` and
  `phone_3_strava.png` still show the rows from before O2. M4 changes no
  screen, and the reviewer's 390 / 1280 px captures from re-review 3
  cover O2. Retake both the next time the phone is in use.
- **N12 and N15 (STATUS):** both are done in `606565d`. The *Unsure* list
  marks Q1 answered, and *How to verify* no longer names
  `phone_welcome.mp4`.

### Each earlier finding

| Finding | Fixed? | How the reviewer checked |
|---|---|---|
| M4 | ✔ `bba4886` | `effectiveBakalariUrl()` and `effectiveCanteenId()` now use a draft only when it is non-empty or the field is shown, exactly as the review asked. Nothing else in `wizard_controller.dart` changed. Every reader of the two values (`saveBakalari`, `saveStrava`, `overridesFor`, so also `readyBakalari`, `readyStrava` and the test fingerprint) goes through these two functions (grep). The three new tests in `F1 login prefills` (path 1 live, path 2 live, Strava canteen plus the *Jiná škola* and own-config cases) **fail on `4375fee`**: paths 1 and 2 show *Vyplňte adresu, jméno i heslo Bakalářů.*, and the canteen is `''` instead of `1950`. All three pass on `bba4886`. |

### What the reviewer verified, and how

1. **Suites** (worktree, Flutter 3.44.8 / Dart 3.12.2):
   - `dart pub get --enforce-lockfile`: OK.
   - Core: `dart analyze` no issues; `dart test` **808 passed, 2
     skipped**. The skips are the old POSIX ones.
   - App: `flutter analyze` no issues; `flutter test` **718 passed, 1
     skipped**. That is 715 plus the three M4 tests.
   - Use these counts as the baseline for the next review.
2. **The tests catch the bug:**
   - One throwaway worktree in the reviewer's scratch space, removed
     afterwards.
   - `bba4886`'s `wizard_live_test.dart` was copied onto the parent
     `4375fee`. The three M4 tests fail there with assertions (above). On
     `bba4886` they pass.
3. **Reviewer's own tests** (not committed), run on `4375fee` and
   `bba4886`:
   - **Every combination**, for the address and the canteen: GEKOM or
     *Jiná škola* picked × config value none, empty, the preset's or an
     own one × draft none, empty, spaces, the preset's or an own one.
     Wherever the field is hidden, the value used is the preset's.
     Wherever it is shown, the typed draft is used as before. Fails on
     `4375fee` (GEKOM, empty draft, value `''`), passes on `bba4886`.
   - **Saved values:** GEKOM with an empty hidden draft is ready, and
     *Pokračovat* saves `bakalari_url` `https://bakaweb.gekom.cz` and
     `strava_canteen_id` `1950`. Fails on `4375fee`, passes on `bba4886`.
   - ***Jiná škola* with an empty address** is still not ready and saves
     nothing (passes on both, as it should).
4. **Scope:** `bba4886` touches only the two functions and their tests.
   `606565d` touches only STATUS. No UI change, so no new screen captures
   were needed. O1, F1b and phase 4 weren't started.
5. **Config keys and strings:** no key and no string added, removed or
   renamed. `config.example.json`, `config.dart` and `test/parity/` match
   `main`.
6. **Safety rules:**
   - Nothing changed in core `lib/` or `app/lib/controllers/`.
   - `runRefresh`, the session lock, `sendExcuse` / `HistoryLock`, the
     audit and `automation_paused` are untouched. No new `catch`.
   - The fix only changes which address or canteen number the wizard
     tests and saves. It is always the one shown, or the school's own.
7. **Test integrity:** no test line removed, no `skip:`, no `try`/`catch`
   around assertions. The only hosts in the new tests are
   `http://127.0.0.1:18080` and the preset value under test. No test
   touches the network.
8. **Phone:** not checked. `adb devices` showed only a stale offline
   emulator; the Pixel wasn't connected. This round has no phone item.
9. **Hygiene:**
   - No personal files or screenshots in the new commits.
   - Both commits are by the configured user, with no `Co-Authored-By`,
     `Claude-Session` or "Generated with" lines.
   - `qa-roadmap` has no upstream, so nothing was pushed.
   - The worktree's uncommitted `generated_plugin*` files are the known
     Flutter line-ending churn.
10. **Not checked:** macOS and iOS builds (not possible here), and the
    phone (not connected).
