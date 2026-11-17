# Strakaláři: phone QA fixes and roadmap — plan

Status: **plan only, nothing built yet.** Written 2026-11-15 against `main` @
`a528acd`, after the Flutter migration was merged.

**Source.** A phone QA run on the Pixel 7 Pro produced a report, written by
another AI:
`C:\Users\matou\.gemini\antigravity\brain\decaa44b-a33f-4ebc-b215-43ac09eda9da\qa_and_vision_report.md`.
Its screenshots sit next to it (`01_wiz_welcome.png` … `21c_notifications_home.png`).
The report is **background**, not the task. Each of its claims was checked
against the code. This plan keeps what holds up and corrects what doesn't.
**Where the report and this plan differ, this plan wins.**

---

## 1. How to read this plan

Every item has an **ID** (B = bug, P = polish, N = notification, F = feature),
a **label**, where the problem is, and a **Done when** list. The reviewer
checks every item against its *Done when* list.

| Label | Meaning | What the agent does first |
|---|---|---|
| **confirmed in code** | The fault is visible in the code at the given place. | Write a test that fails because of it, then fix. |
| **seen on phone, cause not confirmed** | The report saw it on the phone; nobody has found the code cause yet. | Reproduce it (test, 390 px screenshot or phone). If it doesn't reproduce, write that under *Questions* in STATUS.md and move on. Don't guess-fix. |
| **report is wrong** | The report's explanation doesn't match the code. | Ignore the report's explanation and use the one here. |

Phases 1 and 2 need no owner decision. Phases 3–7 are the roadmap proposals
from the report. They are not agreed scope yet: **each one starts only after
the owner says "go"** and answers its questions in §8.

---

## 2. Ground rules (binding)

1. **Only plan items.** No other fixes, features, renames or refactors. If
   something else looks wrong, add one line under *Questions* in STATUS.md.
2. **One commit per item**, message starting with its ID (`B4: store the run
   time, not just the date`). A test that fails before the fix and passes after
   it goes in the same commit. If an item really can't have a test (pure
   layout, Android XML), the commit message says why, and the evidence
   (screenshots, `dumpsys` output) goes in `build/qa-evidence/<ID>/` (ignored
   by git).
3. **Safety rules stay true** (`CONTRIBUTING.md` §5, "These rules keep the
   automation safe"): one pipeline (`runRefresh`), one session at a time
   (`withSessionLock`), one send path (`Strakalari.sendExcuse` +
   `excuse_history.dart` + `HistoryLock`), everything recorded (`audit.dart`,
   dry run included), `automation_paused` stops every auto phase, fail loudly.
   Destructive or network actions default to confirmation (§6).
4. **Config keys** (`CONTRIBUTING.md` §6): a new, removed or renamed key changes
   `config.example.json`, the validation in
   `packages/strakalari_core/lib/src/storage/config.dart` and their tests **in
   the same commit**. `ConfigManager.save` writes every known key, so a new key
   also goes into the two full config files of the `roundTripFiles` case in
   `packages/strakalari_core/test/parity/helpers.json`, where save writes it
   (see commit `a528acd`). That's the only allowed edit to the frozen parity
   fixtures: they can't be regenerated now that the Python app is gone.
5. **Strings:** every UI string goes into `app/lib/l10n/app_cs.arb`,
   `app_en.arb` and `strings.dart`, in both languages. Phone-only wording goes
   through `Strings.isMobile` overrides.
6. **Screens:** every changed screen still works at 390 px and 1280 px, in cs
   and en, light and dark.
7. **New feature, new tutorial** (`CONTRIBUTING.md` §5): features that add or
   move controls update `app/lib/tutorial/tours.dart` and its `tut_*` strings.
8. **Tests are never weakened, skipped or deleted** to get green.

---

## 3. Phase 0: setup

The agent creates the worktree and `docs/qa-roadmap/STATUS.md` from the
template in §10, and commits. See `PROMPT.md`.

---

## 4. Phase 1: confirmed bugs ⛔ review after

Order: **B2 first**, then B1 (B1 reuses B2's fixed editor), then B3–B9.

### B1 Wizard excuse templates lose names and split multi-line texts (critical, data loss)

**Label: confirmed in code.**

- `app/lib/features/wizard/wizard_live.dart`, `wizardControllerFor` (the
  `tplKeys` loop, ~l.108–126) turns each `{name, text}` template into its text
  only and joins them with `\n`.
- `app/lib/features/wizard/wizard_controller.dart:409–431`
  (`setExcuseTemplatesInitial`, `saveExcuseTemplates`) splits on `\n` again
  and saves a `List<String>`. A template text with a line break becomes
  several templates, and names are lost.
- `wizard_view.dart:603–621` (`_templateEditors`) shows the raw config key
  (`late_income_excuses` …) as the field label.
- `LiveWizardView.build` creates a new controller on every `AppState` change,
  and the template edits live only in that controller. Any rebuild (a refresh
  tick) wipes them.

**Done when:**
- Going through the whole wizard without touching the templates leaves the
  four template keys in `config.json` exactly as they were (test).
- A template with a name and a multi-line text keeps both after it is edited
  and saved in the wizard (test).
- Template edits survive an `AppState` rebuild during the step (widget test).
- The labels are the same human labels Settings → Šablony uses, in cs and en.
- A config that already holds plain strings (written by this bug) still loads
  in Settings and in the send path without a crash (test). Don't repair those
  configs automatically; note them under *Questions*.

Hint: reuse the Settings `TemplateEditor` once B2 has fixed it. That is not a
redesign; F1 may restyle it later.

### B2 Settings → Šablony omluvenek doesn't save typed text

**Label: confirmed in code.** The report is partly wrong: typed text *does*
reach the in-memory list (`onChanged` sets `values[i]['name']` / `['text']`).
It is only **saved** when *+ Přidat* or *Delete* is pressed (`_commit`). The
`TextEditingController`s are created inside `build`, so the cursor can jump.

- `app/lib/features/settings/settings_view.dart:172–275` (`TemplateEditor`;
  controllers ~l.240/248; `_commit` only ~l.261/270).

**Done when:**
- Typing a name or text and then leaving the field or the screen saves it
  (test reads the saved config).
- The controllers live in the `State`, are disposed, and keep the cursor where
  it was during typing.
- On the phone, the name and text fields don't overlap, and the text field
  shows several lines and grows with the text (390 px screenshot).

### B3 Light theme (Vzhled → Světlý) stays dark on the phone

**Label: seen on phone, cause not confirmed. The report's cause is wrong.** The
dropdown (`settings_view.dart:1379`) calls the normal `save`, not the quiet
one: `SettingsController.save` (`settings_controller.dart:101`) →
`AppState.save` (`app_state.dart:349`), which calls `refreshTokens()` and
notifies; `AppStateController.updateShouldNotify` always returns true. So
something else is wrong.

**Do:** reproduce first, with a widget test that pumps the real app (`MyApp` /
the shell), opens Settings → Vzhled, picks Světlý and checks the scaffold
background, and on the phone (`.test` build from current `main`). Find the real
cause. If it doesn't reproduce anywhere, write that under *Questions* and move
on.

**Done when:** picking Světlý turns the whole app light at once (background,
cards, app bar, bottom bar, text), and Tmavý turns it back, without a restart.
There are phone screenshots of both.

### B4 Aktivita shows 00:00 instead of the run time

**Label: confirmed in code.** The report blames the reader; the cause is the
**writer**. `app/lib/controllers/activity.dart:559` stores
`'at': fmtIso(finished)`, and `fmtIso` (`app_state.dart:49`) is date only. So
`runTime()` (`activity_view.dart:50`) parses midnight.

**Done when:**
- New runs store date **and** time in `at`.
- The status card, the KPI card and the run history show the real time.
- Runs already saved with a date-only `at` show their `finished` label, not
  `00:00` (test for both).
- Every other reader of a run's `at` still works (grep for them).

### B5 Settings → Školní kalendář shows "Vlastní" and can silently reset the preset

**Label: confirmed in code, worse than the report says.**
`settings_view.dart:876–886` has a single dropdown item (`custom`) and
`initialValue: 'custom'`. Picking it writes `school_preset_id: custom`. That
silently drops the preset's grade conversion, lunch cutoff and free days,
because they all read `school_preset_id` (`school_presets.dart:331–434`).
The report's names are wrong: the key is **`school_preset_id`**, and the GEKOM
preset id is **`gekom_2026_2027`**.

**Done when:**
- The dropdown lists the same options as the wizard's calendar step (shipped
  presets, user presets, custom; `presetOptions` / `buildCalendarPresets`) and
  shows the saved `school_preset_id`.
- Opening and closing the dropdown without a change writes nothing (test).
- When the config has no own semester dates, the semester fields show the
  preset's dates the way the wizard does (test).
- The duplicated hint text in this card (screenshot `19b_settings_school.png`)
  is gone.

### B6 Settings → Oznámení shows raw event keys

**Label: confirmed in code.** `settings_view.dart:13–27`
(`kNotificationEvents`) and ~l.1632 (`Text(event)`). Labels already exist as
`notif_<event>` in both ARBs (`app_cs.arb:427` …) and `strings.dart`.

**Done when:** each of the 13 events shows its `notif_<event>` label in cs and
en, and a test fails if any event lacks a label in either language. Missing
labels are added to both ARBs and `strings.dart`.

### B7 Wizard limits step: "Zkusit znovu" says "already running" when nothing was

**Label: confirmed in code.** `wizard_view.dart:424–434` reads
`c.refreshRunning`, a value copied *before* the refresh was started, and
shows `already_running` exactly when nothing was running.

**Done when:** the snackbar appears only when a refresh really was already
running (test for both cases).

### B8 Text fields that can show stale text

**Label: confirmed in code, effect not reproduced.**
- `_DraftField` / `_DraftArea` (`wizard_view.dart` ~l.689 and ~l.743) create
  their controller once in `initState`, with no `didUpdateWidget` and no key.
- `marks_view.dart:768–773` (`_bandsCard`) creates four controllers inside
  `build`.

**Do:** write tests that show stale text or a lost edit, for example two wizard
steps whose fields share a position, or typing in a grade band and then a
rebuild. Fix only what a test shows. If nothing reproduces, note it and move
on.

### B9 Android: notification permission over the tutorial; background service doesn't start after allowing

**Label: seen on phone, cause not confirmed.**
- (a) Right after *Dokončit*, Android's notification permission dialog opens on
  top of the *Vítejte ve Strakalářích* tutorial.
- (b) After *Allow*, with *Běžet na pozadí* on, `KeepAliveService` didn't
  start. Toggling the switch, a manual refresh and going Home didn't start it
  either (`dumpsys activity services io.github.dendlerx.strakalari.test` printed
  `(nothing)`).

**Do:** reproduce on the `.test` app against the demo server. Look at where the
permission is requested and where the service is started (`app/lib/platform/android/`,
`StrakalariChannel`, `KeepAliveService.java`).

**Done when:**
- (a) The permission dialog never covers the tutorial.
- (b) Granting the permission starts the service and its status notification
  at once, without restarting the app. The `dumpsys` output from before and
  after is in the evidence folder.
- The fix also holds for a user who later skips a wizard notifications step
  (F1).

---

## 5. Phase 2: phone polish and the collapsed notification ⛔ review after

**Label for every item: seen on phone, cause not confirmed.** The report's
screenshot name is given for each. Reproduce at 390 px (or on the phone), fix,
and put before/after screenshots in the evidence folder.

| ID | Screen | Problem | Done when |
|---|---|---|---|
| P1 | Wizard (`02_wiz_disclaimer.png`) | Says "na tomto počítači" on a phone. | Phones get device wording through `Strings.isMobile`, cs and en. |
| P2 | Wizard (`03b`) | Password fields have no show/hide. | Bakaláři and Strava password fields have an eye toggle. |
| P3 | Wizard (`04_wiz_limits.png`) | The long subject list pushes *Pokračovat* off the bottom. | *Zpět*/*Pokračovat* are always reachable without scrolling the list away. |
| P4 | Wizard (`05_wiz_strava.png`) | A switch that is on shows a solid pill with no visible thumb. | The switch thumb is visible in both themes (theme `switchTheme`). |
| P5 | Dnes (`11_today.png`) | (a) An empty *Čekající omluvenky* says "Žádné změny". (b) The room change shows `I (I)`, the same old and new room. | (a) It uses the right empty text. (b) No room change is shown when old = new. First check whether the demo data causes it. |
| P6 | Rozvrh (`12`, `13`) | (a) The table legend hides behind the bottom bar. (b) List rows read `1.8:00 - 8:45`. (c) *Tento týden* looks the same as *Stálý* when selected. | (a) The legend is fully visible. (b) `1. 8:00 – 8:45`. (c) The selected button is clearly marked. |
| P7 | Známky (`14_marks.png`) | *Vývoj průměru* draws solid green blocks with no axes or labels. | The chart shows a readable line or bars with axis labels. |
| P8 | Obědy (`15_lunches.png`) | *Odeslat objednávky do Stravy* is enabled when Strava isn't set up. | Disabled, with a short reason, when Strava isn't configured. |
| P9 | Absence, Plánovač (`16`, `17`) | (a) KPI cards in one row have different heights. (b) On Plánovač, the stacked buttons push the calendar off the screen. (c) Subpages opened from *Více* have no back arrow. | (a) Same height per row. (b) The calendar starts within the first screen at 390 px. (c) Back arrow on *Více* subpages on phones (the Android Back key already works). |
| P10 | Aktivita (`18_activity.png`) | The filter chips and *Obnovit data* are squeezed next to the check icon. | They span the card width. |
| N1 | Android shade (`21c_notifications_home.png`) | The collapsed background notification clips its second row. | See below. |

**N1 details.** Partly confirmed in code:
`app/android/app/src/main/res/layout/strakalari_status_collapsed.xml` has a
`match_parent` root, and its first row uses
`TextAppearance.Material.Notification.Title`. **The report is wrong** that the
second row is vertical: `strakalari_status_rest` is already horizontal. Compare
with the Play app on the same phone (`dumpsys notification --noredact`, shade
screenshots). **Done when:** the collapsed notification shows both rows without
clipping on the Pixel, the expanded one still shows everything, and there are
screenshots of both. `StatusViews.java` changes only as far as needed.

**Left out (owner can ask for them):** the duplicate timestamp on Dnes, the
grade pill padding, a notification importance option, read-only grade bands
for presets (that's in F1).

---

## 6. Phases 3–7: roadmap features (each needs the owner's "go")

Each feature phase starts only when its §8 questions are answered and the
owner said "go". The agent records the answers word for word in STATUS.md. For
the details of the idea, read the matching section of the report. This section
lists what must stay true and what *done* means.

### Phase 3 — F1 Wizard and school selection redesign (report §3.1) ⛔ design note, ⛔ review after

- **First** write `docs/qa-roadmap/design-F1.md`: the step order, what each
  step shows, which config keys it writes, and the preset data format. Stop
  for review before writing code.
- Preset ids stay as they are (`gekom_2026_2027`). User presets and the format
  in `docs/SCHOOL_PRESETS.md` keep loading; new preset fields are optional.
- **No guessed school data.** The report's `bakaweb.gekom.cz` and canteen
  `1950` aren't in the preset and weren't checked. Only values the owner gives
  (D1) go in.
- The wizard keeps its gating (`needsSetup`, and the saved `wizard_step` if
  the owner's work in progress was committed).
- Uses the B1/B2 template editor and the B9 permission fix. The notifications
  step asks for the permission on purpose, on that step.
- Settings → Škola changes only as far as D1 approves.
- Tutorials updated (rule 7). Screenshots of every step at 390 and 1280 px.

### Phase 4 — F2 Complete excuse history (report §3.4) ⛔ review after

The report's four limits are real: `excuseWindowDays = 30`
(`excuse_history.dart:39`, used at l.90), Komens outbox page 1 only
(`data.dart:256–283`, `'pageNumber': 1`), `sent_excuses_limit` (default 100,
`config.dart:108`) and `go_back_weeks` (a config key with default 4,
`config.dart:105`, not hardcoded as the report says).

- **This touches the send path.** `excuse_history.dart` is what the send path
  uses to decide whether a lesson is already excused. Every existing send-path
  and history test stays unchanged and green.
- A history read that fails on **any** page counts as a failed outbox read, so
  auto mode doesn't send (no partial success).
- Paging is built from a **real saved Komens "Odeslané" page with more than one
  page**, with personal data removed, which the owner provides (D2). The demo
  server (`tools/bakalari_demo_server.py`, `MAX_OUTBOX = 200`, no paging) is
  extended to page the same way. Without that sample: do only the date range,
  no paging, and note it.
- Defaults of `sent_excuses_limit` / `go_back_weeks`, a new
  `excuse_history_scope` key and an excuse history view in Absence: only as D2
  says (rule 4 for keys).

### Phase 5 — F3 Strava: cancel lunches automatically (report §3.5) ⛔ review after

Today `_plannedDeorders` (`lunch_auto.dart:379`, used at l.463) cancels lunches
only for days planned in Plánovač, and only with `strava_order_mode = auto`
(the default is `confirm`, `config.dart:124`).

- **Owner decides (D3)** which new triggers come in (full-day Bakaláři absence,
  a sent excuse, a whole day cancelled, preset free days) and what happens in
  `confirm` mode. The report wants it on by default even in `confirm` mode.
  That conflicts with "network actions default to confirmation", so without
  D3 saying otherwise, cancels in `confirm` mode are **proposed**, not done.
- Every cancel goes through the one order path (`strava/ordering.dart`, one
  verified save), under the session lock, respects the cutoff time and
  `automation_paused`, and is recorded in the audit, dry run included.
- A day with only a **partial** absence never cancels a lunch (test).
- Activity entry and notification text in cs and en.

### Phase 6 — F4 Multiple accounts (report §3.2) ⛔ design note, ⛔ review after

- **First** write `docs/qa-roadmap/design-F4.md` and stop for review **before
  any code**. It must cover:
  - the folder layout;
  - the one-time move of today's data: copy, verify, never delete the
    originals automatically;
  - installing over today's Flutter installs and over the Play app's data;
  - credential key names, with a fallback to today's names;
  - `session.lock`;
  - background refresh across accounts, one at a time and always through
    `runRefresh`;
  - which account the notification and widget show;
  - what deleting an account deletes, with confirmation.
- The implementation follows the approved note only.

### Phase 7 — F5 iOS preparation (report §3.3) ⛔ review after

- Run `flutter create --platforms=ios .` inside `app/`. Afterwards
  `git status` may show only a new `app/ios/` (plus `.metadata` if it changes).
  Revert anything else.
- Bundle id and CI trigger as D5 says. Info.plist gets only what is used.
- No Android-only call runs on iOS (`mobilePlatform()` guards). Keychain
  accessibility allows background reads.
- An `ios` job in `.github/workflows/dart.yml` builds an unsigned `.ipa`. Pin
  every action to a commit SHA like the other jobs.
- Write `docs/IOS_SIDELOADING.md` in plain words.
- Nothing can be built here (no Mac). Everything stays marked *unverified*
  until the owner's CI run.

---

## 7. Checkpoints (⛔ = stop and hand over)

| Stop | After | Review file |
|---|---|---|
| ⛔ R1 | Phase 1 (B1–B9) | `reviews/phase-1.md` |
| ⛔ R2 | Phase 2 (P1–P10, N1) | `reviews/phase-2.md` |
| ⛔ R3a | F1 design note | `reviews/phase-3-design.md` |
| ⛔ R3 | F1 done | `reviews/phase-3.md` |
| ⛔ R4 | F2 | `reviews/phase-4.md` |
| ⛔ R5 | F3 | `reviews/phase-5.md` |
| ⛔ R6a | F4 design note | `reviews/phase-6-design.md` |
| ⛔ R6 | F4 done | `reviews/phase-6.md` |
| ⛔ R7 | F5 | `reviews/phase-7.md` |

The branch is merged into `main` only after a passing review, when the owner
says so. The owner may ask for a merge after any passing review (for example
after R2, to get the bug fixes out).

---

## 8. Owner decisions (needed before the feature phases)

| ID | Phase | Question |
|---|---|---|
| D1 | F1 | Go for the wizard redesign as in report §3.1? The real GEKOM Bakaláři address and Strava canteen number, if they should be filled in for you. While a school preset is active, should the grade conversion stay editable in Známky (as now) or be shown read-only? |
| D2 | F2 | How far back should excuse history go: 30 days (now), the semester, or the whole school year? Can you save one Komens "Odeslané" page with more than one page (personal data removed) as a test sample? Do you want an excuse history list in Absence? |
| D3 | F3 | Which cases should cancel a lunch: a planned free day, a full-day absence in Bakaláři, a sent excuse, a whole day cancelled, preset free days? In *confirm* mode: ask first, or cancel without asking? On or off for new users? |
| D4 | F4 | Go for multiple accounts? Who is it for (e.g. one parent, two children)? Should the background refresh run for all accounts or only the active one? |
| D5 | F5 | Go for iOS? Same bundle id `io.github.dendlerx.strakalari`? Should the iOS CI job run on every push or only when started by hand? |

---

## 9. Risks

- **Data loss in config files** (B1, B5, F4): every item that writes config
  has a round-trip test, and F4 never deletes originals.
- **Sending or cancelling more than intended** (F2, F3): send/order tests stay
  unchanged, a partial read counts as failed, and confirmation stays the
  default.
- **Fixes based on the report's wrong causes** (B3, N1): the labels make the
  agent reproduce first.
- **The owner's real data on the phone:** only the `.test` app is touched,
  never the Play app.

---

## 10. `STATUS.md` template (created in phase 0, at `docs/qa-roadmap/STATUS.md`)

```markdown
# QA & roadmap status

Branch: qa-roadmap · Base: main @ <sha> · Current phase: <n>
Next step: <one line the agent follows at its next start>

## Items
| ID | Status (todo / doing / done / can't reproduce / blocked) | Commit | Test | Evidence | Notes |
|---|---|---|---|---|---|

## Owner decisions (answers word for word, with date)
## Questions for the owner / reviewer
## Deviations from the plan (each needs reviewer sign-off)
## Phase notes (written at every ⛔: what was done, what's unsure, how to verify)
```
