# Review R2: Phase 2 (P1–P10, N1)

Reviewed 2026-11-17 at `qa-roadmap` @ `55caabe` (base `main` @ `a528acd`;
`main` has no commits the branch lacks). Commits reviewed: `0a397bf` (P1),
`401dc6b` (P2), `4021a1d` (P3), `b439ce7` (P4), `ed137c9` (P5), `c707421`
(P6), `1b5ddcf` (P7), `8db060e` (P8), `a9b29a1` (P9), `0bfe108` (P10),
`553e8e7` (N1), `55caabe` (STATUS).

## Verdict: **FAIL**

Most of the phase is good: all four suites are green, every item's test fails
on the commit before its fix with a real assertion and passes on the fix, no
safety-critical code was touched, and the changed screens look right at
390 and 1280 px, in cs and en, light and dark. Two must-fix findings block the
pass: the notification fix (N1) is claimed as verified, but the "before"
evidence doesn't show the bug and the "after" evidence doesn't cover the case
from the report (M1); and the Lunches send button is still enabled, with no
reason, before the first data refresh (M2).

---

## Must-fix

### M1 (N1): the clipping was never reproduced, and the "after" evidence doesn't cover the report's case

- **Where:** STATUS row N1 and Phase 2 notes; `build/qa-evidence/N1/`.
- **What is wrong:** N1 is *seen on phone, cause not confirmed*, so it had to
  be reproduced first. It wasn't:
  - `before_shade_collapsed.png` (08:35) shows **both** Strakaláři status
    notifications, the `.test` one (2 chips) and the Play app's one (4 chips:
    next lesson, lunch, excuses, alarm), with both rows complete and nothing
    cut off. The report's own `21c_notifications_home.png` doesn't show a
    clipped second row either.
  - The after screenshots (`after_shade_collapsed.png`,
    `after_shade_expanded.png`) only show a `.test` notification with **two**
    chips (next lesson and excuses). The report's case is the second row
    with lunch, excuses and alarm side by side.
  - The Phase 2 notes say the multi-chip row "was also compared against the
    Play app on the same device (`before_shade_collapsed.png`)". That image
    shows the **old** layout, so it says nothing about the new one.
  - `before_ui.xml` is empty (0 bytes).
  - STATUS says "verified collapsed + expanded on Pixel 7 Pro", which reads as
    "the bug was reproduced and is now fixed". Same problem as M3 in phase 1.
  - The test is a text check of the XML files. That's fine as a tripwire, but
    it can't show that anything renders differently.
- **What correct looks like:**
  1. On the `.test` app only, against the demo server, make the status
     notification's second row carry at least three chips: switch on the
     wake-up alarm, and the lunch chip if the demo setup can provide one
     (if it can't, say so). Then save collapsed and expanded shade
     screenshots (`after_shade_collapsed_multi.png`,
     `after_shade_expanded_multi.png`) and
     `dumpsys notification --noredact` cut down to the `.test` record.
  2. Rewrite the N1 row and the Phase 2 notes to say what was actually seen:
     no clipping is visible before, in either app; the change follows the
     plan's code-level suspects (`match_parent` root and the `Title` text
     appearance) plus the font-padding change; and what the new after
     screenshots show. Remove the sentence about the Play-app comparison.
     Delete `before_ui.xml` or say why it's empty.
  3. Add one line under *Questions* asking the owner whether they ever saw
     the second row cut off, and where (phone font size, lock screen,
     heads-up).
  No code change, unless the new screenshots show clipping. If they do, fix it
  and say so.

### M2 (P8): before the first refresh, the send button is still enabled and gives no reason

- **Where:** `app/lib/features/lunches/lunches_live.dart:43–44`
  (`c.stravaConfigured = s.demoMode || core.hasValidCredentials(...).$2;`);
  test `app/test/lunches_live_test.dart:75` (`P8 lunches send disabled …`),
  which forces `..demoMode = false` at l.95.
- **What is wrong:** `AppState.demoMode` is true whenever no absence or
  timetable data has been fetched yet (`app_state.dart:93`, `:739`). So a new
  user who turned on *Používat Stravu* in the wizard and skipped the Strava
  login sees an **enabled** *Odeslat objednávky do Stravy* button with no
  reason, until the first Bakaláři refresh succeeds. The plan's *Done when*
  says "Disabled, with a short reason, when Strava isn't configured", with no
  exception. The reviewer captured exactly this (fresh folder,
  `use_strava: true`, no Strava login): button enabled, no hint, in cs/en,
  light/dark, 390 and 1280 px. The test can't see it because it sets
  `demoMode = false`.
- **What correct looks like:** drop `s.demoMode ||`, so
  `stravaConfigured = core.hasValidCredentials(s.config.data).$2`. The
  reviewer checked: with that change all 701 app tests still pass. Extend
  the P8 live test with a second case: `AppState` with no data
  (`demoMode` stays true, as after a fresh install), `use_strava: true`, no
  Strava login → button disabled and the `strava_not_configured` text shown,
  in cs and en. It must fail on `55caabe`.

---

## Should-fix

### S1 (P5): an extra, untested rule in the core change classifier

- **Where:** `packages/strakalari_core/lib/src/planning/schedule.dart:1200–1202`
  (`suppressedRoomFlag`), and `:1095–1118`.
- **What is wrong:**
  - The item needed "no room change is shown when old = new". The
    `_sameRoomChangeNote` check does that: it empties the
    `Změna místnosti: I (I)` note and drops the `RoomChanged` flag for it.
  - `suppressedRoomFlag` adds a second, wider rule: **any** `RoomChanged`
    lesson with an empty note whose fields match a single-variant baseline
    is no longer a change, even when Bakaláři sent no room text at all. That
    changes what counts as a timetable change, which feeds the Today list and
    the change notifications (`news.dart`).
  - Nothing tests it. The reviewer replaced the condition with `false`: the
    whole core suite (804) and `today_live_test.dart` still pass.
  - Also, `_sameRoomChangeNote` was put between `classifyLesson`'s `///` doc
    block and the function, so that doc now documents the helper.
- **What correct looks like:** remove `suppressedRoomFlag` (lines
  1200–1202, back to `if (flagged)`). All P5 tests stay green. Move
  `_sameRoomChangeNote` above the `/// Compares one lesson…` block, so the
  doc belongs to `classifyLesson` again. If you think the wider rule is
  needed, keep it only with a test that fails without it and a line under
  *Deviations* explaining it.

### S2 (P2): an existing B1 test was switched to the phone layout

- **Where:** `app/test/wizard_live_test.dart:284` (test `renders localized
  Settings category labels in cs and en without raw keys`, 800×1600).
- **What is wrong:** P2 added `narrow: true` to this B1 test. It now checks the
  phone layout only, and the wide wizard layout isn't covered here any more.
  It wasn't needed: the reviewer restored the original line at `55caabe` and
  the test passes. Rule 8: tests aren't changed to get green.
- **What correct looks like:** restore
  `LiveWizardView(tokens: AppTokens.dark())` on that line. (The P1 test's own
  `narrow: true` at l.635 is fine: it was new in this phase.)

### S3 (P6): the P6 test ignores overflow errors

- **Where:** `app/test/timetable_live_test.dart:303–308`.
- **What is wrong:** the P6 test copies the older tests'
  `FlutterError.onError` filter that drops every "overflowed" error. The
  older tests explain why they need it (the Ahem test font); this one doesn't
  need it. The reviewer removed it: the test passes at `55caabe` and still
  fails on the P6 parent for the right reason (legend at 799 > 764). With the
  filter, an overflow in the row P6 itself resized (period box, 6 px gap,
  time box 96 → 90 px) would go unnoticed.
- **What correct looks like:** delete lines 303–308 from the P6 test.

### S4 (P9c): the back-arrow test doesn't check where Back goes

- **Where:** `app/test/mobile_narrow_shell_test.dart:282–288`.
- **What is wrong:** the test is called "… navigate back to More", but after
  tapping the arrow it only checks that the arrow is gone. That would also
  pass if Back went to Today.
- **What correct looks like:** after the tap, assert the route is `/more`
  (for example
  `GoRouter.of(tester.element(find.byType(NavigationBar))).routerDelegate.currentConfiguration.uri.path`
  equals `/more`), for all four subpages.

---

## Notes (no action needed unless you touch the code anyway)

- **N1 (P6b):** the plan writes the target as `1. 8:00 – 8:45` (en dash). The
  list now reads `1.` + 6 px + `8:00 - 8:45`: the time comes from Bakaláři
  with a hyphen, the same as the table header. The real problem was the
  missing gap, which is fixed. Accepted.
- **N2 (P2):** the eye button has `tooltip: ''`
  (`wizard_view.dart:747`), so screen readers get no label. A real label
  would need new strings; not required by the plan.
- **N3 (P7):** the x-axis dates are indented by a fixed `42`/`18` px
  (`marks_view.dart:1104`) to line up with the y labels. They line up at the
  default text size.
- **N4 (P8):** `tools/demo_data.py` writes no Strava login, so demo captures
  (and README lunch images, if regenerated) now show the disabled button with
  the hint. That is correct behaviour, just worth knowing.
- **N5 (P1):** turning `Strings.isMobile` on also switches the other phone
  texts that already existed (`ai_key_steps`, `auto_confirm_*`,
  `session_busy`, `update_store_managed`) on phones. Intended; all exist in
  cs and en.
- **N6 (Deviations):** accepted: P5's demo-server rooms (the real cause of
  `I (I)` in the demo), P8's new `strava_not_configured` string, and N1's
  `includeFontPadding` on the chip layouts (expanded view still shows
  everything in `after_shade_expanded.png`).
- **N7 (phone):** the Play app `io.github.dendlerx.strakalari` wasn't touched
  (see "What the reviewer verified" step 9).

---

## Item by item

| ID | Test fails on parent / passes on commit | Done when | Result |
|---|---|---|---|
| P1 | fails (`Strings.isMobile` false) / passes | Phone wording via `Strings.isMobile`, cs and en ✔ | pass |
| P2 | fails (no eye icon) / passes | Eye toggle on Bakaláři and Strava password ✔ | S2, N2 |
| P3 | fails (Continue at 1136 > 844) / passes | Back/Continue always reachable ✔ (test, screenshot; wide layout also fine) | pass |
| P4 | fails (thumb = track colour) / passes | Thumb visible in both themes ✔ | pass |
| P5 | core and app both fail (`isChange` true; `I (I)` shown) / pass | (a) right empty text ✔; (b) old = new hidden ✔, demo data cause found ✔ | S1 |
| P6 | fails (legend at 799 > 764) / passes | (a) legend visible ✔; (b) gap ✔ (N1); (c) selected week marked ✔ | S3, N1 |
| P7 | fails (no chart) / passes | Line with axis labels ✔ | N3 |
| P8 | live test fails (button enabled); unit test doesn't compile on parent (new field) / both pass | Disabled with reason ✔ once data exists; ✘ before the first refresh | M2, N4 |
| P9 | (a) absences and planner fail (card heights); (b) calendar-only check fails on its own (827 > 708); (c) fails (no arrow) / all pass | Equal heights ✔; calendar on first screen ✔; back arrow ✔ (destination untested) | S4 |
| P10 | fails (width 242 ≠ 334) / passes | Chips and Refresh span card width ✔ | pass |
| N1 | fails (XML text check) / passes | Both rows without clipping ✔ only for 2 chips; bug not reproduced; expanded ✔ | M1 |

## What the reviewer verified, and how

1. **Suites** (worktree, Flutter 3.44.8 / Dart 3.12.2):
   `dart pub get --enforce-lockfile` OK. Core: `dart analyze` no issues,
   `dart test` **804 passed, 2 skipped** (803 at R1 + 1 P5 test; both skips
   are the old POSIX-only ones). App: `flutter analyze` no issues,
   `flutter test` **701 passed, 1 skipped** (687 at R1 + 14 new: P1–P7 one
   each, P8 two, P9 three, P10 one, N1 one). Use these counts as the baseline
   for the re-review. The worktree's uncommitted `generated_plugin*` files
   are line-ending churn from Flutter, not part of any commit.
2. **Tests catch the bugs:** one throwaway worktree in the reviewer's scratch
   space. For each item commit: checked out its parent, copied in only that
   commit's version of the item's test files, ran only the item's test
   (`--plain-name`), then ran the same on the commit. Every item fails on the
   parent with an assertion and passes on the commit. P8's unit test can't
   compile on the parent; its live test fails there with an assertion.
3. **Extra experiments at `55caabe`:**
   - P5 without `suppressedRoomFlag`: all green (S1).
   - P6 test without the overflow filter: passes; on the P6 parent it fails on
     the legend, not on an overflow (S3).
   - B1 label test back in the wide layout: passes (S2).
   - P9 calendar assertion alone on the P9 parent: fails (827 > 708), so (b)
     is really covered.
   - P8 without `s.demoMode ||`: all 701 app tests pass (M2).
4. **Screens:** a capture run derived from `tools/parity/capture_screens.dart`
   (the real router and `MyApp` setup, demo data from `tools/demo_data.py`)
   for Today, Rozvrh (table and list), Absence, Známky with a subject open,
   Plánovač, Obědy (demo data, and a fresh folder with Strava on and no
   login), Aktivita, Nastavení and wizard steps 2–5. That's 112 images: 390
   and 1280 px, cs and en, light and dark. No overflow or render errors.
   Everything looked right except the fresh-folder Obědy (M2). The `→` shows
   as a box only because the capture font lacks it. All the agent's own
   screenshots in `build/qa-evidence/P1`–`P10` and `N1` were opened and
   compared with the report's phone screenshots (`12`, `13`, `15`, `17`,
   `21c`).
5. **Plan corrections used:** N1 left `strakalari_status_rest` (already
   horizontal) and `StatusViews.java` alone, as the plan says. P5 checked the
   demo data first and found the cause there.
6. **Scope:** S1 and S2 are the only changes beyond their items. Moving the
   timetable legend above the grid on phones (P6), the compact narrow Planner
   (P9) and the top-bar back arrow, which reuses the existing Back logic
   (P9), stay inside their items. No tutorial text refers to the legend's
   position, so no tour change was needed.
7. **Config keys and strings:** no key added, removed or renamed.
   `config.example.json`, `config.dart` and `test/parity/` are unchanged on
   the whole phase. The two new strings (`no_pending_excuses`,
   `strava_not_configured`) are in both ARB files and `strings.dart`, with
   real cs and en text. The string table tests are green.
8. **Safety rules:** no diff touches `automation/`, `lunches/`, `strava/`,
   `bakalari/` or `storage/` in core. In `app/lib/controllers/` only one line
   changed (`Strings.isMobile` in `refreshTokens`). P8 only disables the UI
   button; `submitOrders`, the order path, the session lock and the audit are
   untouched. `classifyLesson` (P5) feeds the change list, notifications and
   the log, not the send path. No new `catch` anywhere.
9. **Phone:** read-only check with `adb -s 2C221FDH3002NZ`. The Play app
   `io.github.dendlerx.strakalari` has `lastUpdateTime=2026-11-13 04:07:35`,
   installer `com.android.vending`, and its `KeepAliveService` has been
   running for 4 days, so it wasn't reinstalled, cleared or stopped. The
   `.test` app was last installed 2026-11-17 12:13. The agent's N1 `dumpsys`
   files cover only the `.test` package. The reviewer didn't take shade
   screenshots, which would show the owner's private notifications.
10. **Test integrity:** across the phase, the only removed test line is S2.
    No `skip:` and no loosened assertions. The only `try`-like construct is
    the overflow filter (S3). No new test uses a real host.
11. **Hygiene:** no personal files or screenshots in any commit; all commits
    by the configured user, with no `Co-Authored-By`, `Claude-Session` or
    "Generated with" lines; `qa-roadmap` has no upstream; `main` has no
    commits the branch lacks.
12. **Not checked by the reviewer:** the phone shade itself (the agent's
    screenshots and `dumpsys` were read instead); macOS/iOS builds (not
    possible here).
