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
