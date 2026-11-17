# R3a review: F1 design note (`design-F1.md`)

Reviewed 2026-11-17 against `qa-roadmap` @ `f36d37a` (`main` @ `f8d5582`
merged in `7e92c7d`).

## Verdict: FAIL

The note is careful and mostly correct about the code, but the owner gave a
new direction at this review (recorded word for word in STATUS.md, *D1 /
F1 simplicity*): as few start screens and as little text as possible, no AI
(Gemini) step in the wizard, a shorter disclaimer. The note's 9/11-step
wizard with a summary page and long preset read-outs goes the other way. It
must be rewritten to the target below and reviewed again before any F1 code.

## Owner direction (2026-11-17, word for word in STATUS.md)

> I want the app to be as simple as possible, the smaller the amount of
> startup screens and text, the better. I might be against displaying the
> gemini stuff, because we might create a subscription for this later, so
> leave it only in settings for power users, but not display it in the
> wizard. And the disclaimer can be shortened as well. Just really rework it
> to make it AAA.

This overrides PLAN §6 Phase 3 where they conflict (the wizard no longer
"uses the B1/B2 template editor"; see M3).

## Findings

### Must-fix

**M1 — Step list: too many screens.** `design-F1.md` §2 (table, l.30–44).
Rewrite §2 to this flow (desktop 6 steps, Android 7):

| # | Step | Saves on *Pokračovat* |
|---|---|---|
| 0 | **Vítejte** — language buttons + the short disclaimer (M2) + one *Rozumím* checkbox | `language` (on tap), `disclaimer_accepted` |
| 1 | **Škola** | `school_preset_id` |
| 2 | **Bakaláři** — address (or the preset's one-line address with *Změnit*), username, password, and an optional *Podpis pod omluvenky* field | `bakalari_url`, `bakalari_username`, `bakalari_password`, `your_signature` |
| 3 | **Strava** — as the note's §3 step 4 | as now |
| 4 | **Limity absence** (skippable, as now) | `subject_limits`, `absence_critical_pct` |
| 5 | **Telefon** (Android only) — *Běžet na pozadí* and *Budík* switches on one screen | `run_in_background`, `wakeup_enabled` (+ `wakeup_minutes_before` only if the user opens it) |
| 6 | **Hotovo** — heading + one sentence, no summary | nothing; *Dokončit* starts the first refresh |

- Welcome and disclaimer become one screen. The note's reason for keeping
  them apart (§8, "long first screen on phones") no longer holds once the
  disclaimer is three lines (M2). The disclaimer still needs its own explicit
  confirmation (the checkbox gates *Pokračovat*).
- The summary on *Hotovo* (§3 step 10) is dropped: it is extra text, and the
  same facts are in Settings.
- The *Telefon* step asks for the notification permission on *Pokračovat*
  when either switch is on, exactly as the note's step 7 describes (wait for
  the answer, move on either way, record the ask so `PhoneBackground.sync`
  doesn't ask again; *Přeskočit* keeps B9's after-tour ask). Budík's other
  fields stay in Settings → Budík.
- Done when: a test asserts the exact step list on desktop and on Android.

**M2 — Shorter disclaimer, in cs and en.** `app_cs.arb` / `app_en.arb`
`wiz_disclaimer_p` and `wiz_disclaimer_rules` (l.782–783), today ~110 words.
Keep exactly these points, nothing else: unofficial project; acts in your
name; a sent excuse can't be taken back; nothing is sent without your
confirmation by default; logins stay encrypted on this device; no warranty
(GPLv3). Suggested text (the agent may polish, not lengthen):

- cs: *Neoficiální studentská aplikace. Jedná vaším jménem — odeslanou
  omluvenku nelze vzít zpět, a proto se bez vašeho potvrzení nic neodešle.
  Hesla zůstávají šifrovaně v tomto zařízení. Bez záruky (GPLv3).*
- en: *An unofficial student app. It acts in your name — a sent excuse can't
  be taken back, so nothing is sent without your confirmation. Your passwords
  stay encrypted on this device. No warranty (GPLv3).*

"zařízení / device" works on desktop and phone, so P1's `isMobile` override
for these keys can go; P1's test must then check the new wording instead
(change what it asserts, don't delete it). Shorten `wiz_welcome_p` too: it
names "AI doporučení", which the wizard no longer has.

**M3 — No AI step and no template editor in the wizard.** Note §2 steps 6
and 9.
- The AI step goes. Gemini stays only in Settings, unchanged. The wizard
  writes no `gemini_*` key.
- The *Omluvenky* step goes. Templates have defaults in `config.dart`
  (l.57–103) and stay editable in Settings → Šablony; the signature moves to
  the Bakaláři step (M1).
- Tests: the wizard-only parts of the B1/B2 and AI tests that drive a step
  that no longer exists are **adapted**, not dropped. Above all the B1 check
  stays: going through the whole wizard leaves the four template keys
  byte-identical, and `TemplateEditor` keeps its Settings tests unchanged.
  List each adapted test in the commit message and under *Deviations*.

**M4 — Saved `wizard_step` resume after the step indexes change.** Note §5
(l.203–207) calls the shift harmless. It isn't: someone who quit on the old
calendar step (index 6) would resume on a later step and never see the new
*Škola* step, so no preset and no prefills. Old and new indexes can't be
told apart without a new key, so use the simple rule: a resumed wizard
starts at `min(saved wizard_step, Škola)`, and step 0 when the disclaimer
isn't accepted. Each step saves only on *Pokračovat* and the later steps
show what's already saved, so going through Škola–Bakaláři again loses
nothing and takes seconds. Test: a saved `wizard_step` of 6 resumes on
Škola; one of 0 resumes on Vítejte; `needsSetup` gating unchanged.

**M5 — Less text on the Škola step.** Note §3 step 2 (l.78–87) lists six
read-only lines per preset. Replace with one line: *Adresa Bakalářů, jídelna,
prázdniny a převod známek se vyplní samy. Změnit je můžete v Nastavení.*
(en to match). With one preset per school (GEKOM today), show no category
line at all. Jiná škola keeps its one line.

### Should-fix

**S1 — Owner questions that the new direction answers.** Rewrite §10:
- Q2 (category label) is moot for the wizard (M5). Keep `category_cs/en`
  optional in the format, but GEKOM needs none now; drop it from the GEKOM
  values in §4 unless the owner confirms the label.
- Q3: "switch to *Jiná škola*" is enough (no extra scale control).
- Q4: yes, a user's own bands are kept — never discard user data; *Podle
  školy* resets them.
- Q5: answered by M1 (only the two switches).
- Q6: several green `F1:` commits are fine, each with its tests, the step
  order list from M1 in the first wizard commit.
- Q1 stays for the owner, but the *Změnit* button makes a wrong path cheap
  to fix; the agent may use `https://bakaweb.gekom.cz` as given in D1.

**S2 — Phone layout spacing.** §7 is fine; add that the pinned button bar
shows only *Zpět* and *Pokračovat* on steps that can't be skipped, so the bar
never wraps at 390 px in cs (the longest labels).

### Notes

- **N1.** Checked and correct: `wizard_step` gating (`app_state.dart:820–838`,
  `config.dart:129/402`), `run_in_background` and `use_strava` default on
  (`config.dart:112/40`), `strava_url` default `https://strava.cz`
  (`config.dart:35`), `validatePreset` ignores unknown fields
  (`school_presets.dart:93`), GEKOM already has `school`
  (`school_presets.dart:33`), `requestNotificationPermission` awaits since B9
  (`android_channel.dart:91`, `startup.dart:308`).
- **N2.** `marks_scale` in config also has `auto` (`config.dart:155/356`).
  The preset field only allows `grade`/`percent`, which is right; say in §4
  that the preset value beats `auto` too.
- **N3.** The rest of the note stands unchanged: flat optional preset fields
  and validation (§4), no config key added/removed/renamed (§5), Známky
  hiding the bands card and scale switches under a preset and moving the
  bands editor to Settings → Škola (§6, matches the owner's D1 words), the
  `AnimatedSwitcher` choice over `PageView` (B8 risk), tutorial handling.
  The *Telefon* step still asks for the permission on purpose on that step
  (PLAN Phase 3).

## What I verified and how

- `git log f8d5582..HEAD`: only `docs/qa-roadmap/STATUS.md` and
  `design-F1.md` changed — no F1 code before this review. `main` has no
  commits the branch lacks. Branch has no upstream. No personal data or
  attribution lines in the new commits.
- Ran `dart pub get --enforce-lockfile`, `dart analyze` / `dart test`
  (core) and `flutter analyze` / `flutter test` (app); results under
  *Test run* below.
- Read the note against PLAN §6 Phase 3, CONTRIBUTING §5–6 and the owner's
  D1 answers, and checked each code reference listed in N1 by grep/reading.
- No item commits to test on a parent (design phase only).

### Test run

- `dart pub get --enforce-lockfile`: OK.
- Core: `dart analyze` no issues; `dart test` 804 passed, 2 skipped.
- App: `flutter analyze` no issues; `flutter test` 703 passed, 1 skipped.
- Same counts as the R2 re-review baseline: nothing deleted or skipped.

## Re-review 2026-11-17

At the owner's request ("Can you rewrite it?") the reviewer rewrote
`design-F1.md` itself, as in the R2 re-review. The review is therefore not
independent for this note; the code review at R3 will be.

- **M1** fixed: §2 has 6 steps on desktop, 7 on Android, as listed here.
- **M2** fixed: §3a holds the three-sentence cs/en disclaimer; P1 override
  and `wiz_disclaimer_rules` go; `wiz_welcome_p` drops AI.
- **M3** fixed: AI and Omluvenky steps removed; signature on Bakaláři;
  §9 lists the tests to adapt (not delete) and keeps the B1 round trip,
  extended to `gemini_*` keys.
- **M4** fixed: §5 resume rule `min(saved, 1)`, 0 without the disclaimer.
- **M5** fixed: one line on Škola; no category line for a single preset.
- **S1** fixed: Q2–Q6 answered in the note; only Q1 left for the owner.
- **S2** fixed: §7, *Přeskočit* only on skippable steps, no wrap at 390 px.
- **N2** taken in §4 (`marks_scale` beats `auto`).

No code changed since the review, so the test run above still holds.

- Owner follow-up (same day): limits leave the wizard and are edited in the
  Absence tab (note §2, §6, §9). Joining Absence and Plánovač is out of F1,
  tracked as F1b with its own design note.

### Verdict: PASS

The agent may write F1's code as the note says.
