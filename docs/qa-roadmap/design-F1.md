# F1 design note: wizard and school selection redesign

Status: **design only, no code yet.** Waits for review ⛔ R3a
(`reviews/phase-3-design.md`). Written 2026-11-17 against `qa-roadmap` @
`7e92c7d` (= `main` @ `f8d5582` merged in, same tree).

Sources: PLAN §6 Phase 3, report §3.1, and the owner's D1 answers in
STATUS.md (2026-11-17, word for word there). Where the report and this note
differ, the reason is given in §8.

---

## 1. What changes, in one paragraph

The wizard asks for the **school first**. Picking GEKOM fills in the
Bakaláři address, the Strava canteen number, the calendar, the grade
conversion and the marking scale, so the user only types their logins. A
new Android step asks for the notification permission **on purpose**. The
last step shows a short summary. On phones the wizard fills the screen with
a pinned header and a pinned button bar. While a school preset is active,
Známky no longer shows the grade conversion card or the
grade/percent switches (D1: "dont display it at all"); the grade conversion
moves to **Nastavení → Škola** (the renamed *Školní kalendář* section),
where it stays editable.

---

## 2. Step order

| # | Step (new) | Shown on | Was | Saves on *Pokračovat* |
|---|---|---|---|---|
| 0 | Vítejte (language) | all | 0 | `language` (on tap, as now) |
| 1 | Upozornění (disclaimer) | all | 1 | `disclaimer_accepted` |
| 2 | **Škola** (new, replaces *Školní kalendář*) | all | 6 | `school_preset_id` |
| 3 | Bakaláři | all | 2 | `bakalari_url`, `bakalari_username`, `bakalari_password` |
| 4 | Strava | all | 4 | `use_strava`, `strava_username`, `strava_password`, `strava_canteen_id` |
| 5 | Limity absence | all | 3 | `subject_limits`, `absence_critical_pct` |
| 6 | AI doporučení | all | 5 | `gemini_api_key`, `gemini_model` |
| 7 | **Na pozadí a oznámení** (new) | Android | — | `run_in_background` |
| 8 | Budík | Android | 7 | `wakeup_enabled`, `wakeup_minutes_before` |
| 9 | Omluvenky (signature + templates) | all | 8 | `your_signature` (templates save themselves, B1/B2) |
| 10 | **Hotovo** (with summary) | all | 9 | nothing; *Dokončit* starts the first refresh |

Desktop shows 9 steps, Android 11.

Why this order:
- **School before logins** (report §3.1): the school supplies the defaults
  the login steps show.
- **Strava right after Bakaláři**: both logins in a row. Limity moves after
  them; it still needs the Bakaláři login, because its subject list comes
  from the one-time Bakaláři-only refresh (`onLimitsRefresh`, unchanged).
- **Notifications before Budík**, both Android only, next to each other.

Unchanged: each tested step (Bakaláři, Strava, AI) runs its live test on
*Otestovat a pokračovat* and moves on only after it passes;
*Přeskočit* moves one step and saves nothing; Welcome and Disclaimer can't
be skipped.

---

## 3. What each step shows

**0 Vítejte.** As now (heading, one line, Čeština / English). Only the
spacing changes: 16 px between the text and the language buttons, so the
buttons no longer sit on the divider (screenshot `01_wiz_welcome.png`).

**1 Upozornění.** As now, including P1's phone wording.

**2 Škola** (new).
- One card per **school**, then a card **Jiná škola** (`custom`).
  Presets are grouped by their `school` field (§4); a preset without one
  is its own card, titled with `presetTitle`. Today that is GEKOM (one
  card) and Jiná škola.
- A school with **several** presets shows them as a radio list
  (*Kategorie*) inside its card once it is picked. With **one** preset (GEKOM
  today) that preset is picked with the school, and its category label is
  shown as a line, not as a list.
- The picked preset shows a read-only summary, only for what the preset
  holds:
  - *Bakaláři:* `bakaweb.gekom.cz`
  - *Strava:* `jídelna 1950`
  - *Uzávěrky:* `25.01.2027 / 26.04.2027`, and the free-day count and
    groups, as the calendar card shows today
  - *Převod známek:* `1: 100–87 % · 2: 87–72 % · …` (`bandsRanges`)
  - *Známkování:* `procenta`
  - *Uzávěrka obědů:* `12:00`
  - and one line: *Všechno lze později změnit v Nastavení.*
- **Jiná škola** shows: *Prázdniny, uzávěrky a převod známek doplníte
  v Nastavení → Škola.* There are no extra forms in the wizard.
- *Pokračovat* is enabled once a card (and, if needed, a category) is
  picked, as the calendar step is today. It writes **only**
  `school_preset_id`.

**3 Bakaláři.**
- When the picked preset has a `bakalari_url` **and** the config has no
  `bakalari_url` yet, the address field is replaced by one line,
  *Adresa školy: bakaweb.gekom.cz*, with a *Změnit* button that shows the
  normal field, prefilled. The address the test and the save use is
  draft, then config, then preset.
- Username and password (with P2's eye toggle) as now.
- A `bakalari_url` already in the config always wins, so running the wizard
  again never replaces an address the user typed.

**4 Strava.** The *Používat Stravu* switch as now (`use_strava`, default on).
The canteen number is handled like the Bakaláři address:
*Jídelna: 1950* with *Změnit*, when the preset has `strava_canteen_id` and
the config has none. Username and password as now.

**5 Limity**, **6 AI.** As now (P3 already pins the buttons).

**7 Na pozadí a oznámení** (new, Android only).
- Heading and two short lines: the app checks Bakaláři and Strava in the
  background and keeps a quiet notification with an overview, and it can
  notify about new excuses, marks and failed runs.
- The *Běžet na pozadí* switch (`run_in_background`, default on).
- Hint: *Které události oznamovat, vyberete v Nastavení → Oznámení.*
- *Pokračovat* saves `run_in_background`. If the switch is on, it then asks
  for Android's notification permission (`requestNotificationPermission`,
  which since B9 waits for the answer) and moves on after the answer, either
  way. The ask is recorded in `AppState` for this run, so
  `PhoneBackground.sync` doesn't ask a second time after the intro tour.
- *Přeskočit* saves nothing and asks nothing. Then B9's path still holds:
  after *Dokončit* the permission is asked once the intro tour is closed,
  never over it.
- Answered or not, the service starts when `PhoneBackground.sync` runs after
  setup (B9 (b)).

**8 Budík**, **9 Omluvenky.** As now: the signature field and the B1/B2
`TemplateEditor` with human labels.

**10 Hotovo.** The current heading and text, plus a short summary with one
line per item, each read from the saved config:
- Škola: preset title, or *Jiná škola*
- Bakaláři: `username · host`, or *nenastaveno*
- Strava: `jídelna N`, or *vypnuto*
- AI: *zapnuto* / *vypnuto*
- Android only: Na pozadí *zapnuto/vypnuto* and Oznámení
  *povolena/nepovolena*, and Budík *zapnut/vypnut*

---

## 4. Preset data format

Today's shape (`gekom20262027` in `school_presets.dart`,
`docs/SCHOOL_PRESETS.md`) stays exactly as it is. These **optional** fields
are added. A user preset without them loads as before, and unknown fields
are still ignored.

| Field | Type | Meaning | Validation (`validatePreset`) |
|---|---|---|---|
| `school` | string | Groups presets into one school card. It already exists in GEKOM; it is now read. | none (free text) |
| `category_cs`, `category_en` | string | The preset's label inside its school, e.g. *Maturitní ročník 2026/2027*. Fallback: `year`, then the title. | none |
| `bakalari_url` | string | Wizard prefill for `bakalari_url`. | must start with `http://` or `https://` and contain a `.` |
| `strava_canteen_id` | string | Wizard prefill for `strava_canteen_id`. | digits only |
| `marks_scale` | `grade` / `percent` | The school's marking scale. While the preset is active it replaces `marks_scale` / `marks_subject_scales`, and Známky hides the switches. | one of the two |

GEKOM gets (the values from D1, nothing guessed):

```dart
'bakalari_url': 'https://bakaweb.gekom.cz',
'strava_canteen_id': '1950',
'marks_scale': 'percent',
'category_cs': 'Maturitní ročník 2026/2027',
'category_en': 'Final year 2026/2027',
```

- The preset id stays `gekom_2026_2027`.
- The category label comes from the preset's own comment ("final year ends
  sooner"); question Q2 asks the owner to confirm it.
- No `strava_url` field: the owner's "strava.cz" is already the default
  (`'strava_url': 'https://strava.cz'` in `config.dart`), so there is
  nothing to fill in.
- No "school system" or "lunch system" picker (report §3.1, branch B):
  Bakaláři is the only school system, and Strava already has its own on/off
  switch, so a picker with one choice would only add clutter.

New core helpers in `school_presets.dart`, next to the existing
`presetMarksBands` / `presetLunchCutoff`: `presetMarksScale(id)`,
`presetBakalariUrl(id)`, `presetCanteenId(id)`, `presetCategory(preset,
lang)` and `schoolGroups(lang)`. `docs/SCHOOL_PRESETS.md` documents the
new fields.

---

## 5. Config keys

**No config key is added, removed or renamed.** The wizard writes only keys
that exist today (table in §2). Preset values are **prefills**: they reach
the config only when the user continues the Bakaláři or Strava step, through
the same `saveBakalari` / `saveStrava` as typed values.

`school_preset_id`, `marks_scale`, `marks_subject_scales` and
`marks_percent_bands` keep their meaning and values. The marking scale and
grade bands are resolved when they are read, the way bands and the lunch
cutoff already are:

- **Scale:** if the preset has `marks_scale`, that wins and the subject
  overrides are ignored. Otherwise the user's `marks_scale` /
  `marks_subject_scales` apply, as today. Nothing in the file is rewritten,
  so switching to *Jiná škola* brings the user's old choice back.
- **Bands:** unchanged (`resolveMarksBands`: user, then preset, then default).

**Saved `wizard_step`:** it stores a step **index**, and the indexes move
(§2). Someone who quit setup half-way on the old version and updates
resumes at a neighbouring step. That is harmless: every step saves only on
*Pokračovat*, *Zpět* works, and `needsSetup` gating is unchanged. I won't
add a migration key (it would be a new config key just for this one-off).

---

## 6. Other screens

**Známky** (`marks_view.dart`).
- The *Převod procent na známky* card is hidden when
  `school_preset_id` is a preset that has `marks_percent_bands`. The card
  stays for *Jiná škola* or a preset without bands.
- The grade/percent switch (header, phone list) and the per-subject switch
  in the detail are hidden when the preset has `marks_scale`.
- The `marks` tour's last step points at the hidden `marks_scale`
  switch. That step is skipped when its anchor isn't built (rule 7: a tour
  must not explain a control that isn't there).

**Nastavení → Škola** (today *Školní kalendář*, section id `calendar`
unchanged).
- The section's label becomes **Škola / School** (`sec_calendar` text
  only, the key stays).
- Its preset dropdown, the semester closures and the free days stay as B5
  left them.
- New card: **Převod procent na známky**, always shown. It is the existing
  `_BandsCard` moved out of `marks_view.dart` into a shared widget, so Známky
  (for Jiná škola) and Settings use one editor. With GEKOM it shows the
  preset's values (*Převzato z předvolby GEKOM*) and edits save
  `marks_percent_bands` as today. *Podle školy* clears them again.
- No Bakaláři or Strava address controls here: they already live in
  Nastavení → Účty. No summary card: D1 approves only "change stuff related
  to the preset", and the owner asked for less clutter.
- Changing the preset in Settings writes only `school_preset_id`, as now. It
  never touches the login fields.

**Tutorials (rule 7).**
- `tut_settings_intro` gets one sentence: the grade conversion is under
  Škola.
- The `marks_scale` step is skipped as described above.
- The wizard has no tour.

---

## 7. Layout

- **Phone (narrow).** No card border. A full-height `Column` in a
  `SafeArea`:
  - a pinned header: *Krok i z n*, a `LinearProgressIndicator` instead of
    the dots, and the step heading;
  - the scrolling step body;
  - a pinned button bar: *Zpět* (left), *Přeskočit* (when allowed) and
    *Pokračovat* (`FilledButton`, takes the rest of the row), padded above
    the keyboard (`resizeToAvoidBottomInset`).

  Short steps no longer leave 60 % of the screen empty
  (`01_wiz_welcome.png`, `10_wiz_done.png`): the button bar stays at the
  bottom.
- **Desktop (wide).** The centred card stays, with P3's pinned header and
  buttons.
- **Step change:** a 250 ms slide + fade (`AnimatedSwitcher`, keyed by
  step). It is off when the system asks for reduced motion
  (`MediaQuery.disableAnimations`).
- **Spacing:** 16 px between the step text and the first field, 12 px
  between fields.

---

## 8. Differences from the report, and why

| Report §3.1 | This note | Why |
|---|---|---|
| New nested `SchoolDefinition` / `SchoolCategoryPreset` classes | Flat presets with optional fields, grouped by `school` | PLAN: preset ids and the user preset format keep loading; new fields optional. |
| Welcome and Disclaimer merged | Kept as two steps | The disclaimer needs its own confirmation. Merging would make a long first screen on phones. |
| `PageView` with slide | `AnimatedSwitcher` slide | The view is rebuilt from `AppState` on every change. A `PageView` keeps neighbouring steps alive, with their own text controllers (B8 risk). |
| Read-only preset badge in Známky, *Upravit v Nastavení* | Card and switches hidden | D1 clarification: "dont display it at all". |
| Notification category switches in the wizard | Only *Běžet na pozadí*, plus a pointer to Settings | 13 switches on one step is the clutter the owner objects to. Settings → Oznámení already has them (B6). |
| School-system / lunch-system pickers for a custom school | None | Only one choice exists for each (see §4). |
| Settings → Škola with overrides for URLs, cutoff, free days | Grade conversion added; the rest stays where it is | PLAN: "Settings → Škola changes only as far as D1 approves". |
| Signature preview snippet | Not added | Not needed for the D1 goals; can be added later if wanted. |

---

## 9. Tests and evidence (what *done* will be checked against)

**Core** (`packages/strakalari_core/test/school_presets_test.dart`):
- `validatePreset` accepts the new fields and rejects bad values for each.
- GEKOM passes, with the D1 values.
- A user preset without the new fields still loads.
- The new helpers return the values, or empty / null for `custom`.

**App:**
- Step order on desktop and on Android.
- The school step writes only `school_preset_id`, and nothing on *Přeskočit*.
- Bakaláři and Strava use the preset prefill when the config is empty, and
  the config value when there is one. *Jiná škola* prefills nothing. The
  saved config holds the prefilled values after the test passes (fake
  `testConnection`, no network).
- Notifications step: *Pokračovat* with the switch on asks for the
  permission once. `PhoneBackground` doesn't ask again. *Přeskočit* leaves
  B9's after-tour ask in place (the B9 tests stay unchanged and green).
- Going through the whole wizard without touching the templates still leaves
  them unchanged (B1 test, unchanged).
- `needsSetup` / saved `wizard_step` gating as before.
- Známky with GEKOM: no bands card and no scale switches; with `custom`:
  both shown. Settings → Škola shows the bands editor, and an edit saves
  `marks_percent_bands`.
- The summary on the Hotovo step.

**Evidence** in `build/qa-evidence/F1/`:
- every step at 390 px and 1280 px, cs and en, plus dark and light for at
  least Škola and Hotovo;
- Známky and Settings → Škola with GEKOM and with `custom`;
- the phone: the permission dialog on the notifications step, and
  `dumpsys activity services` showing `KeepAliveService` running after
  *Dokončit*.

**Planned commits:** F1 is one plan item, but too big for one readable
commit. I propose a few commits, each starting with `F1:`, each green, each
with its tests:
1. preset fields and helpers (core and docs)
2. Škola step and new order
3. prefills
4. notifications step
5. summary
6. phone layout
7. Známky / Settings → Škola
8. tutorials

(See question Q6.)

---

## 10. Questions for the owner / reviewer

- **Q1.** Is the Bakaláři address exactly `https://bakaweb.gekom.cz` (no
  path after it)? That is what the preset will hold.
- **Q2.** The GEKOM preset's dates are for the **final year**. Is the label
  *Maturitní ročník 2026/2027* right? Other years can be added later as more
  categories under GEKOM.
- **Q3.** With GEKOM, Známky always uses percent and the switch is gone
  everywhere. Should Settings → Škola offer a way to change the scale anyway,
  or is "switch the school to Jiná škola" enough? This note assumes the
  latter.
- **Q4.** Someone who already typed their own grade conversion while on
  GEKOM keeps it. It then shows and can be changed only in Settings → Škola
  (*Podle školy* resets it). OK?
- **Q5.** The notifications step has only the *Běžet na pozadí* switch, not
  the 13 event switches. OK?
- **Q6 (reviewer).** Several `F1:` commits instead of one (§9). OK?
