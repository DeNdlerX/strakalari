# R3c review: F1c design note (`design-F1c.md`)

Reviewed 2026-11-19 at `qa-roadmap` @ `f8db00f` (base `main` @ `f8d5582`;
`main` has no commits the branch lacks). The note came in `12490c6`,
written from the owner's phone test and the reviewer's direction in
[`phase-3b.md`](phase-3b.md#owner-changes-need-design-f1cmd-first-no-code-before-it-passes)
(O3–O6). No O3–O6 code was written: `12490c6` touches only the note and
`f8db00f` only STATUS. The R3b code fixes in the same round passed
([`phase-3b.md`](phase-3b.md#re-review-2026-11-19)).

## Verdict: FAIL

The note has the right shape and is mostly right about the code. The
short Absence screen, the Plánovač and Limity sub-pages, the old
`/planner` link, the real Budík card in the wizard and the early setup
refresh are all designed on top of existing parts, with no new config key
and no change to how excuses are sent or lunches ordered. The reviewer
checked the early refresh closely: running it with automation paused in
memory is enough, nothing automatic can happen during setup.

Two findings block building from it:

- **M1:** the one calendar would lose a thing the app can do today. A day
  with one lesson already planned (say, a doctor at the 3rd lesson) could
  no longer get more lessons. The old custom dialog allowed it, and the
  note removes that dialog.
- **M2:** the test list promises that tests keep checks they can't keep,
  and leaves several tests without saying what happens to them. In R3
  that is how tests got deleted.

Nine smaller points (S1–S9). The ones a student would notice: Absence
could silently show the other term's numbers (S1); planning a single
lesson would cancel the lunch unless the student unticks it (S3); a value
typed on the limits page can be lost when leaving with the phone's Back
button (S4); tapping *Dokončit* while the early refresh still runs would
skip the full first refresh, so lunches would be missing for up to an
hour (S5).

**Update the same day, after the owner read this review:** two owner
changes for the same note (section
[*Owner changes*](#owner-changes-2026-11-19-after-the-review) below). O7:
Limity and Plánovač go back to where they were opened. O8: a tap on a
phone notification or the home-screen widget opens the matching screen.

---

## Must-fix

### M1 (O3, §2.3 item 6): a day that is partly planned can no longer get more lessons

- **Where:** `design-F1c.md` l.98–100 (a planned future day: single tap
  opens `showPlannedDialog`, multi mode `onTap: null`), l.124
  (`CustomPlanDialog` removed), l.298 (`alreadyPlannedLessonsAreLockedAndSplitThePick`
  "keeping every … assertion").
- **What is wrong:**
  - A day counts as planned when it is in `term.plannedDates`. Core fills
    that with every day an entry touches, also an entry for one lesson
    (`packages/strakalari_core/lib/src/planning/planner.dart:999`, through
    `entryDays`). Today's strip uses the same flag
    (`planner_view.dart:735`, `:776`), and the note keeps it.
  - So with the note's calendar, a student who planned only the 3rd
    lesson can't add lessons 1–2 or 4–5 of that day: a tap opens the
    existing plan, and multi mode ignores the day.
  - Today `CustomPlanDialog` allows it: planned lessons are locked and the
    pick splits around them (`plan_picker_test.dart:248`,
    `alreadyPlannedLessonsAreLockedAndSplitThePick`); only a fully planned
    day can't be tapped (`:290`, `fullyPlannedDaysAndHolidaysCannotBeTapped`).
    The note removes that dialog, so the feature is lost, and the test it
    says it keeps can't pass.
  - `showPlannedDialog` gets one entry: `plannedFor` returns the first
    entry that touches the day (`planner_controller.dart:293`). With two
    partial entries on one day, the calendar shows and removes only one.
- **What correct looks like** (in §2.3 item 6 and §7):
  - Decide from the day's M2 slots, not from `plannedDates` alone:
    - **Fully planned:** the day has taught slots and none is pickable
      because they are `planned`. Single tap opens the planned dialog;
      in multi mode the day can't be tapped (as today).
    - **Partly planned:** some slots `planned`, some pickable. Single tap
      opens the upgraded `PlanDayDialog` with *Vybrat jen některé hodiny*
      already open: planned lessons shown locked with `cal_tip_planned`,
      the rest pickable; the whole-day toggle means "all that are still
      pickable". Confirm builds the entries with `entriesForSelection`
      (the taught periods as `lessons`, so the pick splits around the
      planned ones, as today) and saves them with one `planEntries`. In
      multi mode a tap adds only the pickable lessons (today's `_tapDay`).
    - Both keep the planned colour. Say whether a partly planned day gets
      a marker.
  - A day with more than one entry: the planned dialog lists each entry
    with its own *Zrušit plán* (or say where the other entries are
    removed). Pick one and write it down.
  - Tests: `alreadyPlannedLessonsAreLockedAndSplitThePick` keeps its
    assertions (locked `3. Chemie`, split into `(null, 2)` and `(4, null)`)
    in single mode, and the same in multi mode;
    `fullyPlannedDaysAndHolidaysCannotBeTapped` keeps its assertions in
    multi mode, and in single mode a fully planned day opens the planned
    dialog; a day with two entries shows both.

### M2 (O3, §7 items 2, 3 and 7): the test list promises checks that can't hold, and leaves tests without a fate

- **Where:** `design-F1c.md` l.292–302 and l.321–322.
- **What is wrong:** §7 says the 12 `plan_picker_test.dart` tests keep
  "every single test name & assertion", and that `absences_view_test.dart`
  "keeps all existing tests". Checked against the files:
  - `plan_picker_test.dart` builds `CustomPlanDialog` directly
    (`buildPickerHost`, `:55–78`). Against the note's new UI:
    - `tappingADayTakesItOffWhole` (`:92`) first expects a disabled
      *Potvrdit* before any tap. On the new page a tap opens
      `PlanDayDialog`; there is no *Potvrdit* before it.
    - `tappingAPickedDayAgainUnpicksIt` (`:121`) and
      `daysInARowBecomeOneRange` (`:171`): *Potvrdit* becomes the multi
      bar's *Naplánovat* (`plan:multi_confirm`) and then the confirm in
      `PlanMultiDialog`.
    - `untickedLessonsStayAttended` (`:142`),
      `weekChangesAreShownAndCancelledLessonsLocked` (`:195`),
      `startedLessonsTodayCannotBePicked` (`:312`) and
      `wholeDaySwitchClearsAndRefillsTheDay` (`:366`, uses `preselect`):
      the lesson list is now inside `PlanDayDialog`, behind *Vybrat jen
      některé hodiny*.
    - `monthNavigationStaysInsideTheSchoolYear` (`:401`) passes
      `firstMonth` / `lastMonth` and expects the header `12/2026`. The
      note computes the bounds from the term and shows month names from
      `pick_months`.
    - `alreadyPlanned…` and `fullyPlanned…`: see M1.
  - `planner_view_test.dart`: `custom picker taps a day whole and
    confirms` (`:345`) taps `plan_custom`, which goes, and isn't in the
    note's list of what is preserved. P9a+b (`:505`) checks four
    equal-height `StatCard`s and *Limity* next to `plan_custom` on one row
    (`:608`); `PlannerPage` has no `StatCard`, no *Limity* and no
    `plan_custom`.
  - `absences_view_test.dart`: `F1b each subject renders once…` (`:180`)
    expects 4 `StatCard`s (`:275`); there will be 3. `F1 Absence tab …
    opens shared limits editor that saves to config` (`:117`) looks for
    `LimitsEditorContent` (`:168`), which goes. Its save check has to move,
    not disappear.
  - `absences_live_test.dart` case 2 (`:202`) checks two halves: 3 KPIs
    and `Meter` (stays on Absence), and `term_nothing`, the planned entry
    with unplan and the footer (moves to Plánovač). The note keeps only
    the Plánovač half.
  - `planner_live_test.dart` `LiveAbsencesView renders subjects, budgets
    and recommendations` (`:57`): the recommendations leave Absence. Not
    mentioned.
  - `tutorial_test.dart`: the F1b tour tests (`:560` on) aren't named:
    `planner tour is removed and absences tour has 4 merged steps`, the two
    skip tests (`:569`, `:582`), `LiveAbsencesView offers tour only when
    recommended days exist` (`:602`, whose offer rule the note changes),
    and `strings exist for every step` (`:345`, the route set).
  - `calendar_days_dst_test.dart`: the wide test (`:164`) compares the
    rows of 22 Oct and 12 Nov. In a one-month grid they are on different
    pages, and weekdays are columns. `custom dialog: October 2026 ends with
    Friday 30 Oct` (`:197`) builds `CustomPlanDialog`.
  - `settings_sections_test.dart:779` expects
    `find.byType(LimitsEditorContent)` to find nothing; the class goes.
  - In R3 a loose test list ended in deleted tests (R3 M1); in R3b it was
    M2 and S8.
- **What correct looks like:**
  - §7: one line per test that changes: file, test name, what it builds
    and taps afterwards, which assertions stay word for word, and which
    change, with the new expected value. At least the tests above.
  - For each assertion that moves, say which test takes it over (for
    example P9a's equal heights: `absences_view_test.dart:85` already
    covers the 3-card row; the limits save check: `limits_page_test.dart`).
  - Every test stays unless its code goes. One that really has to go is
    listed under *Deviations* with the reason. None is expected.
  - Baseline for F1c code: core 809 passed / 2 skipped, app 739 passed / 1
    skipped. The app count may only go up.

---

## Should-fix

### S1 (O3, §2.2): Absence would show whichever term was last picked in Plánovač

- **Where:** `design-F1c.md` l.62 ("the active/selected term");
  `absences_live.dart:40`, `:82` and `absences_view.dart:135` use
  `s.plannerTerm`.
- **What is wrong:** in F1b the term buttons sat on the same screen. F1c
  moves them to Plánovač. A student who looks at *2. pololetí* there and
  goes back sees the 2nd term's budget rows and `planner_next` on
  Absence, with nothing saying which term it is.
- **What correct looks like:** Absence always uses `yp.defaultTerm` (the
  current term) for the budget rows and `planner_next`; `plannerTerm`
  only changes Plánovač. Test: pick sem2 in `LivePlannerPage`, go to
  `/absences`: the budget rows are sem1's.

### S2 (O3, §2.3 item 6): days of the other term aren't defined

- **Where:** `design-F1c.md` l.81–84, l.93 and l.101.
- **What is wrong:** the months run from September to the selected term's
  closure, but a day can only be picked "within `[term.start,
  term.close]`". With *2. pololetí* selected in November, the student can
  page back to November–January: future school days of the 1st term. The
  note doesn't say how they look. Today's strip leaves days outside the
  selected term empty (`planner_view.dart:730`), so a future school day
  would look like no day.
- **What correct looks like** (reviewer's suggestion; another rule is fine
  if the note writes it down): each cell takes its look and options from
  the term it belongs to (`plan.terms`), so every future school day from
  today to the selected term's closure is coloured and can be tapped. The
  term buttons change the summary line, the recommended list, the
  warnings and the month the calendar opens on. Test: sem2 selected, page
  back to December, tap a future school day: the day dialog opens.

### S3 (O3, §2.3 item 6): planning some lessons would cancel the lunch by default

- **Where:** `design-F1c.md` l.105–113 and l.122; `planner_view.dart:1284`
  and `:1533` (`cancelLunch = true`); core `plannedLunchDays`
  (`planned_skips.dart:257–265`), which cancels the lunch on every day an
  entry touches, also a partial one.
- **What is wrong:** today, picking some lessons happens only in the
  separate custom dialog. F1c puts it one tap away in the normal day
  dialog. A student who plans only the 1st lesson for a doctor still eats
  at school, but gets the lunch cancelled unless they untick the box. A
  lunch cancelled after the cutoff can't be ordered back. The plan's F3
  already says a partial absence never cancels a lunch automatically.
- **What correct looks like:** when the picked lessons don't cover the
  whole day, *Odhlásit oběd* starts unticked (the student can tick it); a
  whole day keeps today's default (ticked). In `PlanMultiDialog` the box
  starts unticked when any chosen day is partial. Same `cancel_lunch` key,
  same staging, no change to the order path. Tests in
  `planner_dialog_test.dart` for both dialogs.

### S4 (O4, §3.1): leaving the limits page by Android Back or the rail can lose a typed value

- **Where:** `design-F1c.md` l.146 and l.170. `AutosaveField` saves on
  blur only (`settings_view.dart:78–80`), not in `dispose` (`:95–99`).
  Android Back runs `ShellBackScope` → `_stepBackOnPhone` → `context.go`
  (`scaffold.dart:105–155`) without unfocusing. The old dialog's *Zavřít*
  unfocused first (`absences_view.dart:82`) and then called
  `onLimitsUpdated` (`:90`), which is `s.save(const {})`
  (`absences_live.dart:25`).
- **What is wrong:** the note unfocuses only for the page's own back
  arrow. A student who types a new default limit and presses the phone's
  Back button (or clicks another rail item on the desktop) can lose it,
  with no message. And every save on the page is quiet; the old dialog
  ended with one normal save so the other screens and the phone's status
  notification picked up the new limits. The note drops it.
- **What correct looks like:** the note says how every way out (the back
  arrow, Android Back, the rail or bottom bar, any route change) saves the
  focused field first, and that leaving the page does the same
  `s.save(const {})` once. Tests: type in *Výchozí limit* and in a subject
  row, leave with Android Back (as `android_back_test.dart` does): both
  values are saved, and one normal save follows.

### S5 (O6, §5): *Dokončit* during the early refresh skips the full first refresh

- **Where:** `design-F1c.md` l.239. `wizard_controller.dart:623–631`
  (*Dokončit* calls `onFinishRefresh()` → `startRefresh()`);
  `activity.dart:312–313` (`claimFlight('refresh_running')` is false while
  any refresh runs).
- **What is wrong:** if the early Bakaláři run is still going when the
  student taps *Dokončit*, `startRefresh()` returns `false`, the wizard
  says `already_running`, and nothing starts the `'all'` run later. Strava
  menus and orders, and the student's own automatic modes, then wait for
  the next scheduled refresh (`check_interval_minutes`, 60 by default).
  The owner measured 6.6–8.7 s for one refresh; on the desktop the steps
  after Bakaláři (Strava off, the name, *Dokončit*) can take less. And
  "already running" is misleading there: the run that is going doesn't
  load Strava.
- **What correct looks like:** when the early run is still going at
  *Dokončit*, queue one normal `'all'` run (an in-memory flag in
  `AppState`, never saved). The early run's `finishRun` starts it through
  the normal `startRefresh` → session lock → `runRefresh`. *Dokončit*
  shows `wiz_finishing_refresh`. Tests: early run in flight at *Dokončit*
  → exactly one `'all'` run starts after it ends, without
  `pauseAutomation`; no early run → unchanged.

### S6 (O6, §5 and §7 item 6): start the early run once, and test that the pause holds

- **Where:** `design-F1c.md` l.214–217 and l.319–320;
  `wizard_controller.dart:465–472` (`continueTestStep`); `config.dart:122`
  and `:124` (`excuse_mode` and `strava_order_mode` default to `confirm`).
- **What is wrong:**
  - `continueTestStep` runs on every *Pokračovat* with an already verified
    login. Back to Bakaláři and forward again would start another full
    Bakaláři refresh each time (about 1 MB each in the owner's
    measurement).
  - With the default modes nothing automatic runs anyway, so a test with
    the default config passes also without the pause. It wouldn't notice
    if `runConfig` were replaced by `app.configData`.
- **What correct looks like:**
  - Start the early run once per verified Bakaláři fingerprint: remember
    it in memory in `AppState` (like `wizardVerified`). The continue path
    starts it only when that fingerprint hasn't had one, which also covers
    a resumed wizard.
  - The O6 test uses `excuse_mode: auto`, and a fake app whose outbox read
    succeeds and whose `excusePending` counts calls (run as
    `refreshReportsNewsAgainstTheCache` does, with `state.createApp` and
    `state.spawn`). The early run: 0 calls, `automation_paused_log` in the
    log, and `config.json` on disk has no `automation_paused: true`. The
    same run without `pauseAutomation`: `excusePending` is called, so the
    test can see a send.

### S7 (O3): work out a month's lessons once, not per cell

- **Where:** `design-F1c.md` l.95–104 and l.119; `pickerSlotsFor`
  (`controllers/planner.dart:400`).
- **What is wrong:** every cell needs its day's lessons to decide whether
  it can be tapped and how it looks, the bar needs them for the hours, the
  dialog for its list. `LivePlannerPage` rebuilds on every `AppState`
  update, including refresh progress. The reviewer timed `pickerSlotsFor`
  on `tools/demo_data.py` data in a debug test run: about 92 ms for one
  pass over a 31-day month. A release build is faster, but the calendar is
  now the main thing on the page.
- **What correct looks like:** build one `Map<DateTime, List<PickerSlot>>`
  for the visible month per build (or cache it in `AppState`, keyed by
  `dataRev`, the planned entries and today) and use it for the cells, the
  bar and the dialog. Say so in §2.3.

### S8 (§8 *Done when*): phone evidence for O5 and O6

- **Where:** `design-F1c.md` l.334–343.
- **What is wrong:** the Telefon step exists only on Android and asks for
  permissions. It is the F1 notifications step, which the reviewer must
  see on the phone. The *Done when* list has 390 / 1280 px captures only.
- **What correct looks like:** add: on the Pixel, the `.test` app only,
  against the demo server: the Telefon step showing `WakeupCard`;
  switching the alarm on (the notification prompt); *Povolit přesné
  budíky* → the system screen → back → the warning is gone; the next
  wake-up shown once the early refresh is done; after *Dokončit*,
  `adb -s 2C221FDH3002NZ shell dumpsys alarm` lists the `.test` alarm;
  Aktivita shows the early `bakalari` run and then the `all` run. Files in
  `build/qa-evidence/F1c/`.

### S9 (§6, strings): name the reused keys and keep the house style

- The three KPI cards: *Varovné předměty* / *Kritické předměty* in §2.2
  aren't the app's texts. Say that Absence reuses `_threeCardStats`
  (`absences_view.dart:329`) as it is: `avg_absence`, `warn_subjects`
  (*S varováním*), `crit_subjects` (*Kritické*). Then `_fourCardStats` and
  `stat_warn_crit` go, as the note says.
- `limit_use_default` in English: `Default ({pct:g} %)`, with the space,
  like `abs_no_limits` (`All subjects use the default limit of
  {pct:g} %.`).
- The three changed texts (`overview_hint`, `tut_abs_stats_body`,
  `tut_plan_strip_body`): write the new cs and en wording into the note,
  like the new keys. `tut_plan_strip_body` keeps its even-spread sentence
  (`tutorial_test.dart:663`).

---

## Owner changes (2026-11-19, after the review)

The owner read this review and wrote: "Can it go back from where you
opened it? Also thats another thing, can you make the app open the
correct tab when clicking on a notification or a widget?" (word for word
in STATUS). Both go into `design-F1c.md` with the fixes above: exact
behaviour, tests and *Done when*, like the rest of the note, and one
commit each when the code is written. Below is the reviewer's direction,
checked against the code. Where the agent sees a better way, the note
says why.

### O7: Limity and Plánovač go back to where they were opened

- **Today's note:** both sub-pages always go back to Absence
  (`design-F1c.md` l.42, l.146; N24).
- **Direction:**
  - `/absences/limits` opened from *Nastavení → Limity* goes back to
    Settings, with the *Limity* section still open (`settingsSection` /
    `settingsOpen` stay in memory, so `/settings` shows it); opened from
    Absence (the *Limity* button or the no-limits banner), back to
    Absence.
  - The reviewer applies the same rule to `/absences/plan`, since the
    owner asked it of the sub-page that has two ways in, and Plánovač has
    them too: opened from the *Dnes* tip, back to Dnes; from Absence,
    back to Absence; from the old `/planner` link or a notification (O8),
    back to Absence, its parent.
  - "Back" means all of them: the page's own arrow (phone and desktop) and
    Android Back. The rail and the bottom bar stay as they are.
  - One way to do it: the opener adds where it came from,
    `/absences/limits?from=settings`; the route builder reads
    `state.uri.queryParameters['from']` and gives it to `ShellBackScope`
    and the page's arrow; `backTarget` takes it as a parameter (it stays a
    pure function, easy to test); only known routes are accepted, anything
    else means Absence. `routeForLocation` already drops the query
    (`router.dart:57–58`). If the agent prefers `context.push` / `pop`, the
    note says how Android Back and a cold start (nothing to pop) behave.
- **Must stay true:** S4 (the typed value is saved whichever way the
  student leaves); no config key; the wide rail keeps *Absence* selected
  on both sub-pages.
- **Tests:** `backTarget` for each opener; Limity from Settings → Android
  Back and the arrow land on `/settings` with the *Limity* section open;
  from Absence → `/absences`; Plánovač from the *Dnes* tip → `/today`;
  `/planner` → Plánovač → back → `/absences`.

### O8: a tap on a notification or the widget opens the right screen

- **Today (checked on the code):** every tap opens the app the same way,
  with no screen in it:
  - event notifications: `Notifications.openApp`
    (`Notifications.java:89–96`), one launch intent with request code `0`
    for all of them; Dart's `AndroidNotifications.sendNotification`
    (`android_notifications.dart:24–39`) has the event as `tag` but passes
    only title and text (`android_channel.dart:59`, `StrakalariChannel.java:170–175`,
    `:326–334`);
  - the ongoing status notification (`KeepAliveService.java:116`), the
    wake-up alarm (`AlarmReceiver.java:117`, `:204`;
    `AlarmRingService.java:193`): the same `openApp`;
  - the timetable widget: `openAppIntent` (`TimetableWidgetProvider.java:429–436`)
    on the subtitle, the empty text and every lesson row (`:215–219`);
  - `MainActivity.kt` doesn't read the intent at all. The app opens on
    `/today` from cold, or wherever it was when it is already running.
- **Direction:** the tap carries a route, and the app opens it.
  - **Which screen** (reviewer's proposal; the note gives the final table,
    one row per event in core `eventTypes`):

    | Tap on | Opens |
    |---|---|
    | `excuse_needs_confirm` | Dnes (the excuse card where it is confirmed) |
    | `excuse_sent`, `automation_failed`, `refresh_failed`, `update_available` | Aktivita (the run, the error, the update card at `activity_view.dart:395`) |
    | `refresh_done` | Dnes |
    | `lunch_ordered`, `lunch_skipped` | Obědy |
    | `planner_suggestion` | Plánovač (`/absences/plan`) |
    | `new_absence` | Absence |
    | `new_mark`, `new_quarterly_mark` | Známky |
    | `timetable_change` | Rozvrh |
    | the ongoing status notification | Dnes |
    | the alarm icon in the status bar (`AlarmClockInfo`) | Budík (`openMoreRoute(…, 'alarm')`) |
    | the ringing alarm's notification | Dnes |
    | the timetable widget | Rozvrh |

  - **Android side:** `openApp(ctx, route)` puts the route in an extra
    and makes each route's `PendingIntent` distinct (its own request code,
    or a data URI with the route). Without that, Android keeps one intent
    for request code `0` and every notification opens the last route
    posted. The `notify` channel call gets a `route` argument.
  - **App side:** `MainActivity` (`launchMode="singleTop"`) hands the
    route to Dart both at a cold start (the launch intent) and while
    running (`onNewIntent`). Dart sets `appState.pendingRoute`;
    `AppScaffold` already goes there (`scaffold.dart:216–222`); its
    allow-list gets the F1c sub-routes.
  - **Background:** notifications from the background refresh go through
    the same `AndroidNotifications` (`background.dart:223`) and channel,
    so they carry the route too.
- **Must stay true:**
  - A tap only opens a screen: no refresh, send, order or save.
  - While the setup wizard is open, a tap doesn't leave it
    (`setupPending` wins; the route is dropped).
  - A route the app doesn't know opens Dnes (`routeForLocation`); an old
    `planner` opens Plánovač.
  - The notification texts, the per-event switches in *Nastavení →
    Oznámení* and the channels stay as they are. No config key, no new
    string.
  - Desktop is out: notifications there go through PowerShell,
    `osascript` or `notify-send` (`desktop/notifications.dart`), which
    can't open a screen in the running app. The note says so in one
    line; the owner can ask for it separately.
- **Tests:**
  - a Dart table from event to route with a test that fails when an event
    in `eventTypes` has no route, and that every route resolves to itself
    with `routeForLocation`;
  - `AndroidNotifications` passes the route for the tag (fake channel);
  - a launch route opens that screen in the shell; it is dropped while the
    wizard is shown; an unknown route opens Dnes.
  - The Java part can't run in a Dart test, like N1: a text check of the
    distinct request codes is fine, and the proof is the phone.
- **Phone evidence** (`.test` app only, demo server): from a closed app
  and from a running one, a tap on an event notification opens its
  screen; the status notification opens Dnes; the widget opens Rozvrh.
  Screenshots in `build/qa-evidence/F1c/O8/`.

---

## Notes (no action needed)

- **N22 (accepted):** the sub-routes `/absences/plan` and
  `/absences/limits` inside the shell, `/planner` → `/absences/plan`, no
  new rail or *Více* entry, the new tour id `absences_plan` (an old
  `planner` in `tutorials_done` stays harmless, N9), reusing `WakeupCard`
  and `pickerSlotsFor`, no config key, 800 string keys (still `>= 790`).
- **N23 (O3, navigation detail):** on the phone the bottom bar keeps
  *Více* selected only for a route in `moreRoutes`; any other route
  highlights *Dnes* (`scaffold.dart:296–304`; the side rail already falls
  back to *Více*). So the note's `navRoute` is needed for the bottom bar
  too, not only the wide rail. The real route stays for `tutorialBegin`, `ViewErrorBoundary` and
  `ShellBackScope`. The top-bar arrow already doesn't show on the
  sub-routes (they aren't in `moreRoutes`, `scaffold.dart:626–628`), so
  the note's suppression only matters if `navRoute` is used there.
- **N24 (O4, owner):** `/absences/limits` always goes back to Absence,
  also when opened from *Nastavení → Limity*. **Superseded by O7:** the
  owner wants it to go back to where it was opened.
- **N25 (O5, one way):** the note keeps the old lone switch "only in
  headless/non-wired unit tests". A screen that exists only for tests
  means the tests don't test the real step. Better: on Android the step
  always shows `WakeupCard`, and tests pass a fake `WakeupPhone`. Not
  required.
- **N26 (O6, a failure during setup):** a failed early run queues the
  normal error dialog, and the wizard page shows it (`router.dart:166`).
  So a slow Bakaláři server can show *Obnovení selhalo* during setup. That
  is what the review direction asked ("sees it like any failed refresh");
  accepted.
- **N27 (O6, safety, checked):** the in-memory copy is enough.
  `runRefresh` never writes the config. The only gate on the automatic
  steps reads the config it is given (`refresh.dart:590–598`);
  `AppState.automationPaused()`, which reads the file, is used only by the
  Activity banner. Scope `'bakalari'` is accepted by `startRefresh`
  (`activity.dart:314`). The first sync reports no news (`news.dart:106`,
  `:147`). `_refreshWork` still stops when there are no credentials
  (`activity.dart:330`).

---

## What the reviewer verified, and how

1. **The note against the code:** every file, line, class, key and method
   it names was looked up: `router.dart` (routes, `routeForLocation`,
   the `/planner` redirect, `popPendingMessages` on `/wizard`),
   `scaffold.dart` (`backTarget`, `ShellBackScope`, `_stepBackOnPhone`,
   the three layouts' selection, the top-bar arrow, `pendingRoute`),
   `tours.dart` and `controllers/tutorial.dart` (route matching, offer,
   skip flags), `planner_view.dart` (`_cell`, `showPlanDayDialog`,
   `showPlannedDialog`, `PlanDayDialog`, `CustomPlanDialog`,
   `PickerSlot`), `planner_controller.dart` (`plannedFor`, `planEntries`),
   core `entriesForSelection`, `plannedLunchDays` and `plannedDates`,
   `absences_view.dart` / `absences_live.dart` (KPI rows, the limits
   dialog, `plannerTerm`), `settings_view.dart` (`AutosaveField`,
   `LimitsEditorContent`, the Settings link), `wakeup_card.dart`,
   `settings_live.dart`, `wizard_controller.dart` and `wizard_live.dart`
   (test, save, permission and *Dokončit* paths), `activity.dart`
   (`startRefresh`, `_refreshWork`, `_refreshLocked`) and core
   `refresh.dart` (`runRefresh`, `_autoPhases`). The gaps are M1, M2 and
   S1–S9.
2. **The tests §7 names:** every test in `app/test` that uses
   `CustomPlanDialog`, `showCustomPlanDialog`, `LimitsEditorContent`,
   `plan_custom`, `StatCard` counts, the `absences` tour or the planner
   grid was read against the note (M2).
3. **Strings:** a script checked every reused key in both ARB files (all
   there, 796 keys each). `plan_custom`, `plan_custom_hint`,
   `stat_warn_crit` and `open_absences` have one use each in `app/lib`,
   which the note removes, plus the tests in M2.
4. **O6 safety:** read the whole refresh path from `startRefresh` to
   `finishRun` and every reader of `automation_paused` (grep over core
   `lib` and `app/lib`), N27.
5. **Timing:** a throwaway test (not committed) timed `pickerSlotsFor`
   on `tools/demo_data.py` data, S7.
6. **No O3–O6 code** and no change to config files, parity fixtures or
   ARB files in `12490c6` / `f8db00f`.
7. **Suites and hygiene:** see the re-review in `phase-3b.md` (same
   commit: core 809 passed / 2 skipped, app 739 passed / 1 skipped; no
   upstream; no trailers; no personal files).
8. **Not checked:** the phone (no code yet); macOS and iOS builds (not
   possible here).

---

## Re-review 2026-11-19

Reviewed at `qa-roadmap` @ `91ae11f` (base `main` @ `f8d5582`; `main` has
no commits the branch lacks). Commits since the review (`b77994c`, owner
changes in `5401453`): `224f5a1` (M1), `ada7340` (M2), `f05c318` (S1),
`54c65ea` (S2), `a4d6d45` (S3), `ad4693c` (S4), `b4c3497` (S5),
`18d230f` (S6), `c24ab03` (S7), `10b5d6f` (S8), `8c9df9e` (S9),
`1513a22` (O7), `0cd2e21` (O8), `91ae11f` (STATUS). One commit per
finding. `git diff 5401453..HEAD --stat` touches only `design-F1c.md` and
`STATUS.md`: no code, config key, string or parity fixture.

### Verdict: FAIL

The note is close. Every earlier finding (M1, M2, S1–S9) is now in the
note, and both owner changes (O7, O8) are designed with routes, tests and
phone evidence. The reviewer checked the O8 Android part against the Java
and Kotlin code, and the partly-planned-day design (M1) against the lesson
data: both hold.

Two of the new fixes would not work in the real app, and the tests the
note lists would still pass, so nobody would notice before the phone:

- **M3:** the full first refresh queued at *Dokončit* (the S5 fix) is
  started while the early refresh still holds the "one refresh at a time"
  lock, so it is refused as busy and never runs. That is the problem S5
  was meant to fix.
- **M4:** the *Plánovač* tip on *Dnes* (O7) would do nothing: the app only
  follows a pending screen whose name matches its list exactly, and the
  tip adds `?from=today` to the name.

Two smaller ones: the way the limits page saves a focused field when the
student leaves can't work as written (S10), and the calendar's month cache
would let a student plan today's lessons that already started (S11).

### Earlier findings, checked in the note

- **M1 fixed** (§2.3 item 6, l.102–108, l.116, l.125; tests l.412–413,
  l.454–455). A cell's state comes from the day's `PickerSlot`s. The data
  supports it: `planned` is set per lesson (`controllers/planner.dart:529`,
  `entryCovers(e, day, period)`), and `pickable` excludes planned lessons
  (`planner_view.dart:223`). Fully planned, partly planned (planned colour
  plus a 4 px dot), the split through `entriesForSelection` with the taught
  periods as `lessons` (as `CustomPlanDialog._entries` does today,
  `planner_view.dart:1578–1598`), multi mode adding only pickable lessons,
  and a planned dialog that lists every entry with its own *Zrušit plán*.
  The two picker tests keep their assertions.
- **M2 fixed** (§9.1, l.406–442). One line per changing test with what it
  builds and taps, what stays and what changes. The reviewer listed every
  test file that uses anything F1c changes (23 files). The 12 in §9.1 are
  the ones that change; the other 11 don't need to: `card_outline_test`
  (subject rows only), `planner_reserve_test` (`ReserveDialog`),
  `ui_views_test` (smoke builds, §9.2 adds two), `strings_table_parity_test`,
  `activity_live_test`, `app_state_lunches_test`, `wizard_setup_full_test`
  (step indices unchanged), `android_phone_background_test`,
  `wakeup_settings_card_test`, `wakeup_ui_test` (no change to
  `WakeupCard`), `app_state_excuses_and_planner_test` (only additions).
  Every test name in §9.1 exists, and the kept assertions match the files
  (e.g. *Prosinec 2026* is the cs `pick_months` entry, the three-card
  equal-height check is `absences_view_test.dart:85`). No test is deleted.
- **S1 fixed** (§2.2 l.60; test l.452). **S2 fixed** (l.87; test l.456).
  **S3 fixed** (l.122, l.132; tests l.457). **S6 fixed** (§5 l.222–236;
  test l.469–472). The S6 test can see a send: the pause gate reads the
  config passed to `runRefresh` (`refresh.dart:590–598`), the excuse mode
  comes from the app object, so the control run calls `excusePending`.
  `automation_paused_log` reaches `logLines` through `workerLog` with a
  time stamp in front, so the check is "some line contains it". **S8
  fixed** (§10 l.502–508). **S9 fixed** (l.59, l.371, l.379–385; the
  even-spread words `rovnoměrně` / `evenly` that `tutorial_test.dart:663`
  checks are kept).
- **S4, S5, S7 written into the note**, but each fix has a gap: S10, M3
  and S11 below.
- **O7** (§6, §2.1): written as asked (`?from=`, pure `backTarget`, both
  arrows and Android Back, `navRoute` for the rail and the bottom bar).
  `settingsSection` / `settingsOpen` really stay in memory when leaving
  Settings (only `closeSettingsSection` and `openMoreRoute('settings')`
  reset them), so back from Limity lands on the open *Limity* section.
  One gap: M4.
- **O8** (§7): complete, see N31.
- **N25 adopted:** the Telefon step always shows `WakeupCard`.

### Must-fix

#### M3 (O6, S5, §5 l.261): the queued full refresh is started inside the session lock and is refused

- **Where:** `design-F1c.md` l.261 ("When the early run exits
  `finishRun` … `finishRun` clears `pendingFullRefresh = false` and starts
  exactly one normal `startRefresh('all')`"), test l.473, *Done when*
  l.498. Code: `activity.dart:343–348` (`_refreshLocked` runs inside
  `withSessionLockAsync`), `:476–479` (`finishRun` is called from
  `_refreshLocked`'s `finally`, so while the lock is held), `:322`
  (`startRefresh` calls `spawn`), `app_state.dart:251–257` (`liveSpawn`
  calls the job at once, so `_refreshWork` runs up to the lock attempt
  synchronously), `session_lock.dart:67–75` (one try, timeout 0),
  `storage/helpers.dart:418` (a lock this process already holds is
  refused).
- **What is wrong:** the flight latch is free after `finishRun`
  (`:583`), so `startRefresh('all')` returns `true`, but its
  `_refreshWork` tries the session lock while the early run still holds
  it. It gets `held == false`, logs `session_busy` and records a skipped
  `'all'` run (`:361–365`). The Strava menus, orders and the student's
  automatic modes then wait for the next scheduled refresh, the exact
  thing S5 asked to prevent. The reviewer checked the lock with a
  throwaway test (not committed): a second `withSessionLockAsync` inside a
  first one, same lock file, gets `held == false`; after the first one
  ends, `true`. A test that only checks that `startRefresh('all')` was
  called (as l.473 reads) passes anyway.
- **What correct looks like:**
  - Start the queued run after the lock is released: in `_refreshWork`,
    in a `finally` around its whole body (it runs after
    `withSessionLockAsync` has returned, and also after the
    missing-credentials, busy and lock-failure exits). There: if
    `pendingFullRefresh`, clear it and `earlyRefreshInFlight`, then call
    `startRefresh('all')`. Not in `finishRun`, and not in a microtask
    scheduled from it (that still runs before the lock is released).
  - Test (in `app_state_excuses_and_planner_test.dart`): `state.spawn`
    calls the job at once and keeps its future (like `liveSpawn` and
    `refreshReportsNewsAgainstTheCache`), the real session lock, a fake
    app whose Bakaláři fetch waits on a `Completer`. Start the early run,
    call `finishWizardRefresh()` while it waits (returns `true`), complete
    the fetch, await every job: `state.runs` holds the `'bakalari'` run
    and then one `'all'` run with `ok == true`, and no line in
    `state.logLines` contains `Strings.get('session_busy')`.

#### M4 (O7, §2.1 l.45, §6 l.272, §7.3 l.343): the *Dnes* tip with `?from=today` does nothing

- **Where:** `design-F1c.md` l.45 and l.272 (the tip calls
  `TodayController.onGo('absences/plan?from=today')`), l.39 and l.343
  (the `pendingRoute` allow-list gets `'absences/plan'` and
  `'absences/limits'`), tests l.427 and l.448. Code:
  `today_live.dart:22` (`onGo: s.go`), `app_state.dart:925–928` (`go`
  only sets `pendingRoute`), `scaffold.dart:215–223` (the shell navigates
  only when `pendingRoute` is exactly a shell route, `'more'` or
  `'wizard'`).
- **What is wrong:** `pendingRoute` becomes
  `'absences/plan?from=today'`, which matches no entry, even with the two
  new ones. The shell doesn't navigate, and the value stays in
  `pendingRoute` (it is cleared only when it matches). The student taps
  *Plánovač* on *Dnes* and nothing happens. The test at l.427 checks only
  the string handed to `onGo`, and l.448 can open the location directly,
  so both pass.
- **What correct looks like:**
  - `AppScaffold` checks the path part of `pendingRoute` (before `?`)
    against the allow-list (shell routes, `'more'`, `'wizard'`, the two
    sub-routes), navigates with the whole string
    (`context.go(routeLocation(pending))` keeps `?from=today`), and clears
    `pendingRoute` whether or not it matched, so a bad value can't stick.
    O8's `applyLaunchRoute` keeps working (its routes carry no query).
  - Test (in §9.2 item 1, the line at l.427 points to it): the real shell
    (`buildRouter` + `AppScaffold`) on `/today` at 390 × 844 with a
    recommended day, tap the tip: the location is
    `/absences/plan?from=today` and `LivePlannerPage` is shown; Android
    Back (`handlePopRoute`) and `plan:back_btn` land on `/today`.

### Should-fix

#### S10 (O4, S4, §3.1 l.158–160): a field that owns its focus no longer has it in `dispose()`

- **Where:** `design-F1c.md` l.158 ("in `_AutosaveFieldState.dispose()`,
  when `saveOnDispose` is true and `focus.hasFocus`, it runs the parse +
  `c.saveQuiet`"), l.159–160. Code: `settings_view.dart:78–80` (commit on
  blur), `:95–99` (`dispose`).
- **What is wrong:**
  - Flutter disposes the children first: the `TextField`'s own `Focus`
    detaches the node before `_AutosaveFieldState.dispose()` runs, so
    `focus.hasFocus` is `false` there, and the blur listener doesn't fire
    either. The reviewer checked it with a throwaway widget test (not
    committed): a field typed into and then removed with its page prints
    `deactivate hasFocus=true text=30`, then `dispose hasFocus=false
    text=30`. Built as written, the typed *Výchozí limit* is still lost on
    Android Back. The S4 test at l.465 would fail, so it can't ship, but
    the agent would have to leave the note.
  - The back arrow (l.159) runs `onLeave` (the normal save)
    synchronously after `unfocus()`, while the blur commit comes in the
    next microtask: the normal save runs before the field's value is
    saved. The old dialog did it the other way round (`absences_view.dart:82`
    unfocus, `:90` `onLimitsUpdated` after the dialog closed).
- **What correct looks like:**
  - With `saveOnDispose`, `dispose()` runs `_commit`'s comparison without
    looking at the focus: it saves quietly only when the parsed text
    differs from the saved value (`SettingsController.sameValue`, as
    `_commit` does), skips a value that doesn't parse, and never touches
    `context`. (Remembering `focus.hasFocus` in `deactivate()`, where it is
    still true, is fine too.)
  - One way out for every exit: the back arrow unfocuses and calls
    `onBack()` only; the page's `dispose()` flushes the subject row and
    schedules the one `onLeave` post-frame, as l.160 already says for the
    other exits. `_notifiedLeave` goes.
  - Tests: l.465 as written, plus the arrow with the field still focused:
    the value is saved and the one normal save comes after it.

#### S11 (O3, S7, §2.3 l.92): the month cache keeps today's started lessons pickable

- **Where:** `design-F1c.md` l.92 (cache key: month, `dataRev`, planned
  entries, `today`, closures, holidays). Code: `controllers/planner.dart:406`,
  `:456–459`, `:526–527` (for today, `pickerSlotsFor` marks a lesson
  `past` from the clock: it has started). Today `lessonsFor` is live on
  every call (`absences_live.dart:110`).
- **What is wrong:** the key has the date but not the time. Within a
  day nothing in the key changes until the next refresh (60 minutes by
  default), so a lesson that started at 8:00 stays pickable in the cell
  and in the dialog. A student planning "the rest of today" at 10:00 could
  include a lesson they sat in, which `startedLessonsTodayCannotBePicked`
  exists to stop. That test builds fresh state, so it passes anyway.
- **What correct looks like:** today's slots are never served from the
  cache: `pickerSlotsForMonth` computes today with `pickerSlotsFor(today,
  now)` on every call (one day) and caches the others. Test (one
  `AppState`, no refresh between): clock 7:50, today's first lesson is
  pickable; clock 8:05, the same `LivePlannerPage` after a rebuild shows
  it locked with `pick_started`.

### Notes (no action needed)

- **N28 (O7, l.272):** the note quotes `routeLocation` as
  `route.startsWith('/') ? route : '/$route'`; the code is `'/$route'`
  (`router.dart:54`). Both give `/absences/plan?from=today`, so
  `routeLocation` needs no change.
- **N29 (§8 l.383, l.385):** `overview_hint` and `tut_plan_strip_body`
  change from *Klikněte* / *Click* to *Klepněte* / *Tap*, also on the
  desktop. The app already mixes them (`pick_how` says *Klepněte*), so it
  isn't required. If wanted: keep the desktop words in the base text and
  put the tap wording in `_mobileCs` / `_mobileEn`
  (`strings.dart:1620–1636`).
- **N30 (§9.1 l.429):** the test name `case 3: active term shows 4 KPIs,
  …` should say 3 once the count changes. A name change, not a weaker test.
- **N31 (O8, checked):** `MainActivity` is `singleTop`
  (`AndroidManifest.xml:37`), so a tap on a running app reaches
  `onNewIntent`. It creates its channel per engine and uses no cached
  engine (`MainActivity.kt`), so after a cold start Dart runs `main` again
  and `takeLaunchRoute` picks the route up. The only other activity
  `PendingIntent` is the widget's (`REQUEST_OPEN = 7310`,
  `TimetableWidgetProvider.java:53`, `:435`), which the note replaces with
  `openApp(ctx, "timetable")`, so no request code is shared by accident.
  The event name already reaches `AndroidNotifications` as `tag`
  (`notifier.dart:96`). The line numbers the note gives for
  `Notifications.java`, `KeepAliveService.java`, `AlarmReceiver.java`,
  `AlarmRingService.java` and `TimetableWidgetProvider.java` are right.

### What the reviewer verified, and how

1. **Suites** at `91ae11f`: `dart pub get --enforce-lockfile` at the root;
   core `dart analyze` no issues, `dart test` **809 passed, 2 skipped**;
   app `flutter analyze` no issues, `flutter test` **739 passed,
   1 skipped**. Same as the baseline, as expected with no code change.
2. **The note against the code**, for every fix and owner change:
   `planner_view.dart` (`PickerSlot`, `_cell`, `PlanDayDialog`,
   `showPlannedDialog`, `CustomPlanDialog`), `controllers/planner.dart`
   (`pickerSlotsFor`, `firstPlannableDay`, `yearPlan` cache),
   `planner_controller.dart`, core `entriesForSelection`,
   `settings_view.dart` (`AutosaveField`), `absences_view.dart` /
   `absences_live.dart`, `app_state.dart` (`save`, `saveQuiet`, `go`,
   `liveSpawn`), `activity.dart` (`startRefresh`, `_refreshWork`,
   `_refreshLocked`, `finishRun`, `testConnection`: the Strava login test
   takes no session lock, so it works during the early run), core
   `session_lock.dart` and `InterProcessLock`, core `refresh.dart`
   (`_autoPhases`), `router.dart`, `scaffold.dart`, `more.dart`,
   `today_live.dart`, `wizard_controller.dart`, `settings_live.dart`, the
   Android Java and Kotlin files and `android_notifications.dart`.
3. **Two throwaway tests** in a separate worktree in the reviewer's
   scratch folder (removed afterwards, nothing committed): the nested
   session lock (M3) and a focused field's `hasFocus` in `deactivate` and
   `dispose` (S10).
4. **Tests:** every test file in `app/test` that uses what F1c changes,
   against §9.1 (M2 above).
5. **Strings:** a script over both ARB files: the 8 new keys don't exist
   yet, every reused key exists in cs and en (796 keys each), and the 4
   removed keys are used only where the note removes them
   (`absences_view.dart:186`, `:192`, `:379`, `planner_view.dart:1614`,
   `settings_view.dart:1039`).
6. **Hygiene:** no upstream; no `Co-Authored-By`, `Claude-Session` or
   "Generated with" lines since `b77994c`; no personal files. The worktree
   has uncommitted line-ending-only changes in the generated plugin
   registrant files (`app/linux`, `app/macos`, `app/windows`), made by the
   Flutter tool, never committed.
7. **Not checked:** the phone (no code yet); macOS and iOS (not possible
   here).
