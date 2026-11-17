# F1 design note: wizard and school selection redesign

Status: **design only, no code yet.** Rewritten 2026-11-17 after the R3a
review (`reviews/phase-3-design.md`, FAIL) to the owner's simplicity
direction. Base: `qa-roadmap` @ `a44e9c2`.

Sources: PLAN §6 Phase 3, report §3.1, and the owner's D1 answers in
STATUS.md, above all *D1 / F1 simplicity* (2026-11-17): as few start screens
and as little text as possible, no Gemini in the wizard, a shorter
disclaimer. Where this conflicts with PLAN §6 Phase 3 (the wizard no longer
shows the B1/B2 template editor), the owner's words win.

---

## 1. What changes, in one paragraph

Setup gets shorter: **6 screens on a PC, 7 on Android** (the first draft had 9 and 11).
The first screen holds the language and a three-sentence disclaimer. Next the
user picks the **school**; GEKOM fills in the Bakaláři address, the Strava
canteen, the calendar, the grade conversion and the marking scale, so the
user types only their logins. AI and excuse templates leave the wizard; they
stay in Settings. On Android one *Telefon* screen holds the background and
alarm switches and asks for the notification permission there, on purpose.
On phones the wizard fills the screen with a pinned header and button bar.
While a school preset is active, Známky shows no grade conversion card and no
grade/percent switches (D1); the grade conversion is edited in
**Nastavení → Škola**.

---

## 2. Step order

| # | Step | Shown on | Replaces (old #) | Saves on *Pokračovat* |
|---|---|---|---|---|
| 0 | **Vítejte** (language + disclaimer) | all | 0, 1 | `language` (on tap, as now), `disclaimer_accepted` |
| 1 | **Škola** | all | 6 | `school_preset_id` |
| 2 | **Bakaláři** (+ signature) | all | 2, part of 8 | `bakalari_url`, `bakalari_username`, `bakalari_password`, `your_signature` |
| 3 | **Strava** | all | 4 | `use_strava`, `strava_username`, `strava_password`, `strava_canteen_id` |
| 4 | **Limity absence** | all | 3 | `subject_limits`, `absence_critical_pct` |
| 5 | **Telefon** | Android | 7 | `run_in_background`, `wakeup_enabled` |
| 6 | **Hotovo** | all | 9 | nothing; *Dokončit* starts the first refresh |

Removed from the wizard: **AI doporučení** (old 5) and **Omluvenky** (old
8). Gemini stays in Settings unchanged; templates keep their defaults
(`config.dart` l.57–103) and stay editable in Settings → Šablony. The
wizard writes no `gemini_*` key and no template key.

Why this order: the school supplies the defaults the login steps show; the
two logins follow each other; Limity needs the Bakaláři login (its subject
list comes from the Bakaláři-only refresh, `onLimitsRefresh`, unchanged).

Unchanged: Bakaláři and Strava run their live test on *Otestovat a
pokračovat* and move on only after it passes; *Přeskočit* moves one step and
saves nothing; Vítejte can't be skipped.

---

## 3. What each step shows

**0 Vítejte.** Heading, one line (`wiz_welcome_p`, shortened, no mention of
AI), the Čeština / English buttons, the disclaimer (§3a) and one checkbox
*Rozumím* (`wiz_disclaimer_ack`). *Pokračovat* is enabled only when it is
ticked. 16 px between text and buttons.

**§3a Disclaimer text** (replaces `wiz_disclaimer_p` + `wiz_disclaimer_rules`,
~110 words → ~35):
- cs: *Neoficiální studentská aplikace. Jedná vaším jménem — odeslanou
  omluvenku nelze vzít zpět, a proto se bez vašeho potvrzení nic neodešle.
  Hesla zůstávají šifrovaně v tomto zařízení. Bez záruky (GPLv3).*
- en: *An unofficial student app. It acts in your name — a sent excuse can't
  be taken back, so nothing is sent without your confirmation. Your passwords
  stay encrypted on this device. No warranty (GPLv3).*

"zařízení / device" fits PC and phone, so the P1 `isMobile` override for
these keys goes. `wiz_disclaimer_rules` is removed from both ARBs and
`strings.dart`; `wiz_disclaimer_h` and `wiz_disclaimer_need` stay unused
only if the string-table tests allow; otherwise they are removed too.
`automation_disclaimer` (Settings) is not touched.

**1 Škola.**
- One card per school, then **Jiná škola** (`custom`). Presets are grouped
  by their `school` field (§4); a preset without one is its own card, titled
  with `presetTitle`. Today: GEKOM and Jiná škola.
- A school with **several** presets shows them as a radio list inside its
  card once picked. With **one** preset (GEKOM today) no category line is
  shown at all.
- Picked preset: one line, *Adresa Bakalářů, jídelna, prázdniny a převod
  známek se vyplní samy. Změnit je můžete v Nastavení.* (en: *The Bakaláři
  address, canteen, holidays and grade conversion are filled in for you. You
  can change them in Settings.*)
- Jiná škola: one line, *Prázdniny, uzávěrky a převod známek doplníte
  v Nastavení → Škola.*
- *Pokračovat* is enabled once a card (and, if needed, a preset) is picked.
  It writes **only** `school_preset_id`.

**2 Bakaláři.**
- If the preset has `bakalari_url` and the config has none, the address
  field is replaced by one line *Škola: bakaweb.gekom.cz* with a *Změnit*
  button that shows the normal field, prefilled. The address used for the
  test and the save is draft, then config, then preset. A `bakalari_url`
  already in the config always wins.
- Username and password (P2 eye toggle) as now.
- New, below them: optional field *Podpis pod omluvenky* (`your_signature`,
  existing key, existing string `wiz_signature` or the Settings label).
  Saved together with the login when the test passes.

**3 Strava.** *Používat Stravu* switch as now. Canteen number like the
Bakaláři address: *Jídelna: 1950* with *Změnit* when the preset has
`strava_canteen_id` and the config has none. Username and password as now.

**4 Limity.** As now (skippable, P3 pinned buttons).

**5 Telefon** (Android only).
- One line: *Strakaláři mohou kontrolovat Bakaláře a Stravu na pozadí a
  budit vás před první hodinou.*
- Switch *Běžet na pozadí* (`run_in_background`, default on).
- Switch *Budík* (`wakeup_enabled`, default off). Minutes before and other
  options stay in Settings → Budík; the wizard doesn't write
  `wakeup_minutes_before`.
- *Pokračovat* saves both. If either switch is on, it then asks for the
  notification permission (`requestNotificationPermission`, which waits for
  the answer since B9) and moves on after the answer, either way. The ask is
  recorded in `AppState` for this run, so `PhoneBackground.sync` doesn't ask
  again after the intro tour.
- *Přeskočit* saves and asks nothing; B9's after-tour ask still holds. The
  service starts when `PhoneBackground.sync` runs after setup (B9 (b)).

**6 Hotovo.** Heading and one sentence (`wiz_done_p`, merged with
`wiz_done_next` into one shorter line). No summary.

---

## 4. Preset data format

Today's shape (`gekom20262027`, `docs/SCHOOL_PRESETS.md`) stays. These
**optional** fields are added; a user preset without them loads as before,
and unknown fields are still ignored (`validatePreset` only checks known
keys).

| Field | Type | Meaning | Validation |
|---|---|---|---|
| `school` | string | Groups presets into one school card. Already in GEKOM; now read. | none |
| `category_cs`, `category_en` | string | Label of a preset inside a school with several presets. Fallback `year`, then title. | none |
| `bakalari_url` | string | Wizard prefill. | starts with `http://` or `https://`, contains a `.` |
| `strava_canteen_id` | string | Wizard prefill. | digits only |
| `marks_scale` | `grade` / `percent` | School's scale. While the preset is active it beats the config's `marks_scale` (including `auto`) and `marks_subject_scales`. | one of the two |

GEKOM gets only D1's values (no category, since it is the only GEKOM
preset):

```dart
'bakalari_url': 'https://bakaweb.gekom.cz',
'strava_canteen_id': '1950',
'marks_scale': 'percent',
```

- The preset id stays `gekom_2026_2027`.
- No `strava_url` field: D1's "strava.cz" is already the default
  (`config.dart:35`).
- No school-system or lunch-system picker: each has one choice.

New core helpers in `school_presets.dart`: `presetMarksScale(id)`,
`presetBakalariUrl(id)`, `presetCanteenId(id)`, `presetCategory(preset,
lang)`, `schoolGroups(lang)`. `docs/SCHOOL_PRESETS.md` documents the fields.

---

## 5. Config keys

**No config key is added, removed or renamed.** The wizard writes only
existing keys (§2). Preset values are prefills that reach the config only
through the normal `saveBakalari` / `saveStrava` when the step is continued.

- **Scale:** preset `marks_scale` wins while active; otherwise the user's
  `marks_scale` / `marks_subject_scales` apply. Nothing is rewritten, so
  switching to Jiná škola restores the user's choice.
- **Bands:** unchanged (`resolveMarksBands`: user, preset, default). A user's
  own bands are kept; *Podle školy* in Settings → Škola clears them.

**Saved `wizard_step` (resume).** The indexes change and old and new values
can't be told apart without a new key. Rule: a resumed wizard starts at
`min(saved wizard_step, 1)` (Škola), and at 0 when `disclaimer_accepted` is
false. Every step saves only on *Pokračovat* and shows what's already saved,
so walking Škola–Bakaláři again loses nothing. `needsSetup` gating
(`app_state.dart:830`) is unchanged.

---

## 6. Other screens

**Známky.** The *Převod procent na známky* card is hidden when the active
preset has `marks_percent_bands`; the grade/percent switches (header, phone
list, subject detail) are hidden when it has `marks_scale`. Jiná škola: both
shown as today. The `marks` tour step on the scale switch is skipped when its
anchor isn't built.

**Nastavení → Škola** (today *Školní kalendář*, section id `calendar`
unchanged; only the `sec_calendar` text changes to *Škola / School*).
Preset dropdown, closures and free days as B5 left them. New card
**Převod procent na známky**: the existing `_BandsCard` moved into a shared
widget used here and in Známky. With GEKOM it shows the preset values; edits
save `marks_percent_bands`; *Podle školy* clears them. Changing the preset
writes only `school_preset_id`. No address controls here (they are in
Nastavení → Účty).

**Tutorials (rule 7).** `tut_settings_intro` gets one sentence that the grade
conversion is under Škola; the `marks_scale` step is skipped as above. The
wizard has no tour.

---

## 7. Layout

- **Phone (narrow):** no card border; full-height `Column` in a `SafeArea`:
  pinned header (*Krok i z n*, `LinearProgressIndicator`, step heading),
  scrolling body, pinned button bar (*Zpět* left, *Přeskočit* only on
  skippable steps, *Pokračovat* as `FilledButton` taking the rest), kept
  above the keyboard. The bar must not wrap at 390 px in cs.
- **Desktop (wide):** the centred card stays, with P3's pinned header and
  buttons.
- **Step change:** 250 ms slide + fade (`AnimatedSwitcher`, keyed by step),
  off when `MediaQuery.disableAnimations`.
- **Spacing:** 16 px between step text and the first field, 12 px between
  fields.

---

## 8. Differences from the report, and why

| Report §3.1 | This note | Why |
|---|---|---|
| Nested `SchoolDefinition` classes | Flat presets with optional fields, grouped by `school` | PLAN: ids and user preset format keep loading. |
| Welcome and Disclaimer merged | Merged (as the report) | Owner: fewer screens; the disclaimer is now three sentences. |
| `PageView` | `AnimatedSwitcher` | `PageView` keeps neighbouring steps alive with their own controllers (B8 risk). |
| Read-only preset badge in Známky | Card and switches hidden | D1: "dont display it at all". |
| Notification category switches | Only *Běžet na pozadí* (+ *Budík*) | Owner: less clutter; Settings → Oznámení has them. |
| AI step kept | Removed from the wizard | Owner: Gemini only in Settings. |
| Summary / signature preview | None | Owner: less text. |
| School/lunch system pickers | None | One choice each. |
| Settings → Škola overrides for URLs, cutoff, free days | Only the grade conversion added | PLAN: only as far as D1 approves. |

---

## 9. Tests and evidence

**Core** (`school_presets_test.dart`): new fields accepted, bad values
rejected one by one; GEKOM valid with D1 values; a user preset without the
new fields loads; helpers return values, or empty/null for `custom`.

**App:**
- Exact step list on desktop (6) and Android (7).
- Vítejte: *Pokračovat* disabled until the checkbox is ticked; disclaimer
  strings in cs and en.
- Škola writes only `school_preset_id`; nothing on *Přeskočit*.
- Prefills: preset value when the config is empty, config value otherwise,
  nothing for Jiná škola; saved config holds the prefills after a passing
  fake `testConnection` (no network). Signature saved with the Bakaláři step.
- Telefon: *Pokračovat* with a switch on asks once; `PhoneBackground` doesn't
  ask again; *Přeskočit* keeps B9's after-tour ask (B9 tests unchanged).
- Resume: saved `wizard_step` 6 → Škola; 0, or disclaimer not accepted →
  Vítejte; `needsSetup` gating unchanged.
- The whole wizard leaves the four template keys and every `gemini_*` key
  byte-identical (the B1 round-trip test, adapted to the new steps).
- Známky with GEKOM: no bands card, no scale switches; with `custom`: both.
  Settings → Škola: bands editor saves `marks_percent_bands`.

**Adapted, not deleted** (listed in each commit message and under
*Deviations* in STATUS.md): wizard tests that drive the removed AI and
Omluvenky steps (B1 wizard template tests, P1 disclaimer wording, P4
switches on the AI step). Each keeps checking its behaviour where it still
exists (Settings `TemplateEditor` tests stay unchanged) and the round-trip
guarantee above.

**Evidence** in `build/qa-evidence/F1/`: every step at 390 and 1280 px, cs
and en, dark and light for Vítejte and Škola; Známky and Settings → Škola
with GEKOM and `custom`; on the phone (`.test` app, demo server) the
permission dialog on Telefon and `dumpsys activity services` showing
`KeepAliveService` after *Dokončit*.

**Commits** (each `F1:`, each green, each with its tests):
1. preset fields and helpers (core, docs)
2. new step list, merged Vítejte, short disclaimer, resume rule
3. Škola step
4. prefills and signature on Bakaláři
5. Telefon step
6. phone layout
7. Známky / Settings → Škola
8. tutorials

---

## 10. Open question for the owner

- **Q1.** Is the Bakaláři address exactly `https://bakaweb.gekom.cz` (no
  path after it)? The preset uses it as given in D1; *Změnit* makes a wrong
  path easy to fix.
