# Prompt for the implementing agent

Paste everything below the line into a new session of your implementing agent,
opened on this repository. The same prompt continues the work in every later
session: it picks up from `docs/qa-roadmap/STATUS.md`.

---

You fix bugs and build features in **Strakaláři**, a Flutter + Dart app for
Windows, macOS, Linux and Android. It excuses school absences in Bakaláři and
orders lunches on Strava.cz. The owner isn't technical: you make the technical
calls inside the plan, and you report in plain language.

**The plan is binding:** `docs/qa-roadmap/PLAN.md`. Read it completely before
doing anything else, then `CONTRIBUTING.md` §5 and §6, whose rules you must
keep. The plan comes from a phone QA report:
`C:\Users\matou\.gemini\antigravity\brain\decaa44b-a33f-4ebc-b215-43ac09eda9da\qa_and_vision_report.md`
(its screenshots are in the same folder). Read the report for background and
open its screenshots, but **where the report and the plan differ, the plan
wins.** The plan corrects several of the report's explanations.

## Where you work

- Main checkout: `C:\Users\matou\Documents\Programy\Python\strakalari`. **Never
  modify anything there.** It holds the owner's uncommitted work and real
  personal data (`config.json`, `data_cache.json`, `log.txt`, `htmls/`,
  `automation_history.jsonl`, `already_excused_lessons.json`, `secret.key*`).
  Don't open or copy those files.
- Your worktree: `C:\Users\matou\Documents\Programy\Python\strakalari\.claude\worktrees\qa-roadmap`,
  on branch `qa-roadmap`.
  - If it doesn't exist yet (first session), create it from `main`:
    `git -C "C:/Users/matou/Documents/Programy/Python/strakalari" worktree add .claude/worktrees/qa-roadmap -b qa-roadmap main`.
    Copy `docs/qa-roadmap/PLAN.md`, `PROMPT.md` and `REVIEW_PROMPT.md` from
    the main checkout into the worktree, create `docs/qa-roadmap/STATUS.md`
    from the template in PLAN §10, and commit them as the first commit.
  - Don't touch the old worktree `.claude/worktrees/flutter-migration`.

## Every session

1. `cd` into the worktree. Read `PLAN.md`, `STATUS.md` and the newest file in
   `docs/qa-roadmap/reviews/`, if there is one.
2. When starting a new phase: if `main` has new commits, `git merge main` and
   note the new base in STATUS.md.
3. Continue from STATUS.md's **Next step**.
4. Before you stop: update STATUS.md (rows, Next step), commit, and tell the
   owner in 3–5 plain sentences what's done, what's next and any question.

## Working loop (one plan item at a time, in plan order)

1. Read the item in PLAN.md and its **label**, then the code it names.
2. **Reproduce.** *confirmed in code*: write a test that fails because of the
   bug. *seen on phone, cause not confirmed*: reproduce it with a test, a
   390 px screenshot or on the phone. If it doesn't reproduce, set the item to
   *can't reproduce*, write what you tried under *Questions*, and go on to the
   next item. Never guess-fix.
3. Fix it. Touch only what the item needs.
4. Run the checks until everything is green:
   - once per session, at the repo root: `dart pub get --enforce-lockfile`
     (one pub workspace, one `pubspec.lock`)
   - core: `dart analyze` and `dart test` in `packages/strakalari_core`
   - app: `flutter analyze` and `flutter test` in `app`
5. Visual and phone items: put before/after screenshots and command output in
   `build/qa-evidence/<ID>/` (git ignores `build/`, so it's never committed).
6. Check every line of the item's **Done when** list. Update its STATUS.md row
   (commit, test name, evidence path) and commit: **one item per commit**,
   message starting with the ID, test and fix together. Never commit a broken
   tree.

## Stop and hand over

- **At every ⛔ in PLAN §7:** write *Phase notes* in STATUS.md: what was done,
  every deviation from the plan, what you're unsure about, and how to verify
  it. Commit, and tell the owner: "Phase N is done: please have the reviewer
  check it before I continue." **Don't start the next phase.**
- **Feature phases (3–7):** don't start one until STATUS.md has the owner's
  "go" and the answers to its PLAN §8 questions. If the owner gives them in
  chat, write them into STATUS.md word for word, with the date. Phases 3 and 6
  start with a design note and a stop **before any code**.
- **Also stop and ask** (add it under *Questions* and tell the owner) when:
  - a fix would change how excuses are sent, lunches ordered or cancelled,
    locks taken or files written, beyond what the item says;
  - a needed decision isn't in the plan;
  - a test can't pass without changing what it checks;
  - you'd need real school data (addresses, canteen numbers, real pages).

## Hard rules

- **Git:** never push, never open a PR, never merge into `main`. Commit as the
  configured git user, with plain messages and **no `Co-Authored-By`,
  `Claude-Session` or "Generated with" lines**.
- **No real services:** never contact real Bakaláři or Strava servers, never
  use real credentials, and never send a real excuse or order. Use fakes,
  `tools/demo_data.py` and `tools/bakalari_demo_server.py`, in dry run.
- **Bakaláři:** the web interface only (pages, postbacks, the pages' own JSON
  endpoints). Never the `/api/3` mobile API.
- **Only plan items.** No extra features, no redesign beyond the item, no
  drive-by refactors. Anything else goes as one line under *Questions*.
- **Safety rules** (`CONTRIBUTING.md` §5) stay true in every commit: one
  pipeline, one session at a time, one send path, everything recorded,
  `automation_paused`, fail loudly. Destructive or network actions default to
  confirmation.
- **Config keys:** a new, removed or renamed key changes `config.example.json`,
  `packages/strakalari_core/lib/src/storage/config.dart` and their tests in
  the same commit. **Strings:** both ARB files and `strings.dart`, cs and en.
- **Tests:** never delete, skip or weaken a test to get green.
- **Personal data:** no real data in commits, tests or screenshots; screenshots
  come from demo data only. Phone screenshots stay in `build/qa-evidence/`
  (the shade can show the owner's real Play app).
- **Phone:** use only the test app `io.github.dendlerx.strakalari.test`. Never
  install over, clear or uninstall the Play app `io.github.dendlerx.strakalari`.
  Ask the owner before clearing or uninstalling the `.test` app.
- **Signing key:** never regenerate, move or overwrite `~/.strakalari-signing/`.
- **Flutter version:** never run `flutter upgrade`. Use exactly 3.44.8.

## Environment (Windows 11 PC)

- **Flutter 3.44.8 / Dart 3.12.2:** `~/flutter/3.44.8/bin/flutter` and `…/bin/dart`.
  They're not on PATH, so call them by full path or prepend
  `~/flutter/3.44.8/bin` to PATH in each command.
- **Android:**
  - JDK 17 at `~/java/17.0.13+11`, Android SDK at `~/Android/sdk`, adb at
    `~/Android/sdk/platform-tools/adb.exe`.
  - The test phone is a Pixel 7 Pro, serial `2C221FDH3002NZ`. Always pass
    `-s 2C221FDH3002NZ`, because a stale emulator also shows up.
  - In Git Bash, set `MSYS_NO_PATHCONV=1` for adb paths like `/sdcard`.
  - Build the test app (from `packages/strakalari_core`):
    `dart run tool/build_android.dart apk --flavor phonetest --stage C:/strakalari-build`,
    then `adb -s 2C221FDH3002NZ install -r <apk>` (keeps its data).
  - Screenshots: `adb -s 2C221FDH3002NZ exec-out screencap -p > <file>.png`.
    Notifications: `adb -s 2C221FDH3002NZ shell dumpsys notification --noredact`.
    Services: `… shell dumpsys activity services io.github.dendlerx.strakalari.test`.
- **Demo server for the phone:**
  `C:/Users/matou/Documents/Programy/Python/strakalari/.venv/Scripts/python.exe tools/bakalari_demo_server.py --port 18080 --user demo --password demo`,
  then `adb -s 2C221FDH3002NZ reverse tcp:18080 tcp:18080`. Set `PYTHONUTF8=1`
  when you redirect Python output.
- **Demo data on the PC:** use a throwaway folder in your scratch space, never
  the repo: `python tools/demo_data.py generate <DIR>`, then run the app with
  `STRAKALARI_DATA_DIR=<DIR>`. 390/1280 px screenshots:
  `tools/parity/capture_screens.dart`.
- **Windows desktop builds:** Visual Studio 2026 with the C++ tools is installed.
  macOS and iOS can't be built here: write those parts and mark them
  *unverified* in STATUS.md.
- **Long commands** (builds, the full test suites): run them in the
  background. Read large files in parts.

Start now: set up the worktree if needed, read the plan, and continue with
phase 0 or the Next step in STATUS.md.
