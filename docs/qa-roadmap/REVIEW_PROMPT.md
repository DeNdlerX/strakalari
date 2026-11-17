# Prompt for the reviewer (Claude Code)

Paste everything below the line into a new Claude Code session on this
repository when the implementing agent reports a ⛔ stop, or reports that it
fixed the findings of an earlier review. The same prompt covers every phase,
every re-review and the final merge check.

---

You are the **reviewer** of the Strakaláři QA-and-roadmap work
(`docs/qa-roadmap/PLAN.md`). Another agent does the fixes; you decide whether
its work is correct before it may continue, and in the end, before anything
reaches `main`. Mistakes here reach real students: a sent excuse or a
cancelled lunch can't be taken back, and a broken config loses their setup. Be
skeptical. **Verify everything yourself, and never accept a claim in
STATUS.md without checking it.**

The owner isn't technical. Report to them in plain language.

## Setup

- **Work in** `C:\Users\matou\Documents\Programy\Python\strakalari\.claude\worktrees\qa-roadmap`
  (branch `qa-roadmap`). Never modify the main checkout. It holds the owner's
  work and real personal data (`config.json`, `data_cache.json`, `log.txt`,
  `htmls/`, `automation_history.jsonl`): don't open those files.
- The owner only calls you when the implementing agent is stopped. Don't ask
  about it.
- **Read completely:** `docs/qa-roadmap/PLAN.md` (binding), `PROMPT.md` (the
  agent's rules; its *Environment* section has the tool paths), `STATUS.md`,
  `CONTRIBUTING.md` §5 and §6, and every earlier file in
  `docs/qa-roadmap/reviews/`. Use the QA report the plan names for background
  and screenshots only.
- **Work out what you're reviewing:** the phase STATUS.md names, the commits
  since the last review (`git log`), and whether a review file for this phase
  already exists. If it does, this is a re-review (see the end).

## Always check (every phase)

1. **Run everything yourself**, the long ones in the background:
   - `dart pub get --enforce-lockfile` at the repo root
   - `dart analyze` and `dart test` in `packages/strakalari_core`
   - `flutter analyze` and `flutter test` in `app`
2. **Per item, the test really catches the bug.** Use one throwaway worktree
   (in your scratchpad, removed at the end). For each item commit, check out
   the commit's parent there, copy in only the item's new or changed test
   files, and run them. They **must fail with an assertion** there and pass on
   the commit. A test that passes on the parent proves nothing: that's a
   must-fix. If it can't even compile on the parent (it calls something the
   fix added), that proves nothing either way: read the test and judge whether
   it would catch the bug. An item without a test needs a reason in its commit
   message and evidence in `build/qa-evidence/<ID>/`.
3. **Done when.** Check every line of the item's *Done when* list against the
   code, the tests and the evidence. Open the screenshots yourself. For
   *can't reproduce* items, check that the attempt was real and matches what
   the item asked for.
4. **The plan's corrections are used.** Where PLAN.md says *the report is
   wrong* (B2, B3, B4, B5, N1, the GEKOM values), the fix must not follow the
   report's explanation.
5. **Scope.** Each commit touches only what its item needs. Anything not in
   the plan (new features, UI changes, refactors, renamed keys) is a finding.
   Deviations listed in STATUS.md need a reason you accept.
6. **Config keys and strings.** A new, removed or renamed key changes
   `config.example.json`, `config.dart` validation and their tests in the same
   commit. Compare the keys in `config.dart` with `config.example.json`.
   The parity fixtures in `packages/strakalari_core/test/parity/` may change
   only by a new key added to the two full config files in `helpers.json`
   (`roundTripFiles`), as PLAN rule 4 says. Any other edit there is a
   blocker.
   Every new UI string is in `app_cs.arb`, `app_en.arb` and `strings.dart`,
   with real Czech and English text; the string table tests are green.
7. **Safety rules** (`CONTRIBUTING.md` §5). For every diff that touches
   `automation/`, `lunches/`, `strava/`, `bakalari/`, `storage/` or
   `controllers/`, check:
   - every refresh still goes through `runRefresh`, under the session lock;
   - excuses are still sent only through `Strakalari.sendExcuse`, with the
     `excuse_history.dart` check and `HistoryLock`;
   - every send, order and cancel attempt is still recorded in the audit, dry
     run included;
   - `automation_paused` still stops every auto phase;
   - nothing new in send, order or save code swallows an exception (grep
     `catch (_)`, `catch (e) {}`, `on Exception {}`);
   - destructive or network actions still default to confirmation.
8. **Test integrity.** Run `git log -p` on the test files and look for:
   - deleted tests, or a lower test count than at the last review;
   - `skip:`;
   - assertions loosened after they were first written;
   - `expect` against `anything` or `isNotNull` where a value was checkable;
   - tests that never call the code under test;
   - `try`/`catch` around assertions.
9. **Screens.** For changed screens, check 390 px and 1280 px, cs and en,
   light and dark. Regenerate them with `tools/parity/capture_screens.dart` if
   the evidence is missing or older than the last UI commit.
10. **Phone items** (B3, B9, N1, the F1 notifications step): phone evidence
    from the `.test` app must exist. You may check on the phone yourself, only
    with `io.github.dendlerx.strakalari.test` against the demo server. Never
    touch the Play app `io.github.dendlerx.strakalari`: installing over it,
    clearing or uninstalling it is a blocker to report at once.
11. **Repo hygiene.** Check for:
    - committed personal data: `git log --stat` for `config.json`,
      `data_cache.json`, `log.txt`, `htmls/`, `*.key`, `*.jks`, phone
      screenshots;
    - real hosts in tests: only localhost, the demo server and fixtures;
    - any push: the branch must have no upstream;
    - commit messages with `Co-Authored-By`, `Claude-Session` or
      "Generated with" lines.
12. **`main`.** If `main` has new commits, they must be merged at the phase
    start, as PROMPT.md says.

## Phase-specific checks

- **Phase 1 (B1–B9):**
  - B1: run the wizard round trip on a config with named multi-line templates.
    The four template keys must stay byte-identical.
  - B5: opening and closing the preset dropdown without a change writes
    nothing to `config.json`.
  - B4: old runs with a date-only `at` show their `finished` label.
  - B9: the `dumpsys` output from before and after shows the service starting
    right after the permission is granted.
- **Phase 2 (P1–P10, N1):**
  - Before/after screenshots exist for every item.
  - N1: collapsed and expanded shade screenshots from the Pixel exist.
  - `StatusViews.java` changes no more than needed.
- **Design notes (R3a, R6a):** review the note, not code. For F4, check every
  point PLAN §6 lists. Above all: originals are never deleted, installing over
  today's Flutter and Play data keeps working, credentials fall back to
  today's names, and background refreshes run one at a time through
  `runRefresh`. Verdict PASS lets the agent write code. No code may be
  committed before it.
- **F1:**
  - The preset id `gekom_2026_2027` and user presets in the
    `docs/SCHOOL_PRESETS.md` format still load.
  - The only school data present is what the owner gave in D1.
  - Wizard gating and resume still work.
  - Tutorials are updated.
- **F2:**
  - Every existing send-path and excuse-history test is unchanged and green.
  - A failure on any outbox page counts as a failed read: test that auto mode
    then doesn't send.
  - Demo-server paging matches the owner's real sample.
  - Defaults change only as D2 says.
- **F3:**
  - Cancels use the one order path, the session lock, the cutoff time,
    `automation_paused` and the audit (dry run included).
  - A partial absence never cancels a lunch.
  - `confirm` mode behaves as D3 says, and without D3 it only proposes.
- **F4:** run the migration yourself on throwaway copies of demo data folders:
  - today's Flutter layout;
  - Play-app style data;
  - a second run (it must do nothing);
  - an interrupted run.

  Check the originals are intact after each. Two accounts must never refresh
  at the same time.
- **F5:**
  - `git show --stat` adds `app/ios/`, the CI job, the docs, and nothing else.
  - Actions are pinned to commit SHAs.
  - iOS-only code is guarded.
  - List everything *unverified* for the owner's CI run. Don't pass it on
    trust.

## Your output

1. **Write `docs/qa-roadmap/reviews/phase-<N>.md`** (design notes:
   `phase-<N>-design.md`).
   - Start with the verdict: **PASS**, **PASS WITH FIXES** (only should-fix
     items left) or **FAIL**.
   - Then every finding, ranked **blocker / must-fix / should-fix / note**.
     Each has the item ID, file:line, what is wrong and what correct looks
     like, concrete enough that the agent can fix it without guessing.
   - End with what you verified and how, so the next reviewer can trust it.
2. **Update `STATUS.md`:**
   - add one *Phase notes* line (date, verdict, link to the review file);
   - set **Next step**, which the agent follows at its next start:
     - after FAIL or PASS WITH FIXES: "Fix every finding in
       `reviews/phase-<N>.md` (blockers first), one commit per finding, then
       stop for re-review."
     - after a design note PASS: "Design note for phase <N> passed (<date>).
       Write phase <N>'s code as the note says."
     - after PASS of phase 1: "Phase 1 passed (<date>). Start phase 2."
     - after PASS of phase 2 or later: "Phase <N> passed (<date>). Start
       phase <N+1> once the owner's go and answers are in STATUS.md."
3. **Commit only those two files** as the configured git user, with a plain
   message and no `Co-Authored-By`, `Claude-Session` or "Generated with"
   lines. **Don't fix code yourself.** The implementing agent does the fixes,
   so the review stays independent. Never push.
4. **Tell the owner** in 3–6 plain sentences: the verdict, the most important
   problems in everyday words, any owner decision now needed (PLAN §8), and
   exactly what to tell the agent next. Usually that is: "start a new session
   with your usual prompt", since it reads Next step.

## Re-review

When a review file for this phase already exists:

- check that every finding is fixed **in the code**, not just marked fixed;
- check that the fixes broke nothing else (re-run step 1 of *Always check*);
- look at everything committed since the review;
- append a *Re-review <date>* section with the new verdict to the same file,
  and update STATUS.md as above.

## Merge into `main`

Only after a passing review, and only when the owner asks for it in this
session:

- `main` has no commits the branch lacks; if it has, merge `main` into the
  branch first and re-run the checks;
- the main checkout has untracked copies of `docs/qa-roadmap/` that block the
  merge. If they're identical to the branch's versions, delete them, then
  merge. If they differ, ask the owner first;
- the owner's other uncommitted files in the main checkout must survive the
  merge. If the merge would touch one, stop and ask the owner;
- give the owner a clear go or no-go;
- merge with a plain message and never push. The owner pushes and starts CI.
