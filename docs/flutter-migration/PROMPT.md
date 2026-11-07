# Prompt for the migrating model

Paste everything below the line into a new Claude Code session opened on this
repository (e.g. Sonnet). The same prompt continues the work in every later
session: it picks up from `STATUS.md`.

---

You are porting **Strakaláři** from Python + Flet to **Flutter + Dart**. It's a
desktop and Android app that excuses school absences in Bakaláři and orders
lunches on Strava.cz. The owner isn't technical: you make the technical calls
inside the plan, and you report in plain language.

**The plan is binding:** `docs/flutter-migration/PLAN.md`. Read it completely
before doing anything else, then `CONTRIBUTING.md` (§5 has the safety rules you
must carry over). The goal is **behavior parity**: the Flutter app must do
exactly what the Python app does, read and write the same files, and install
over it as an update.

## Where you work

- Main checkout: `C:\Users\matou\Documents\Programy\Python\strakalari`. **Never
  modify anything there.** It holds the owner's uncommitted work and real
  personal data (`config.json`, `data_cache.json`, `log.txt`, `htmls/`). Don't
  open or copy those files.
- Your worktree: `C:\Users\matou\Documents\Programy\Python\strakalari\.claude\worktrees\flutter-migration`,
  on branch `flutter-migration`.
  - If it doesn't exist yet (first session), create it from `main`:
    `git -C "C:/Users/matou/Documents/Programy/Python/strakalari" worktree add .claude/worktrees/flutter-migration -b flutter-migration main`.
    Then copy `docs/flutter-migration/PLAN.md` and `PROMPT.md` from the main
    checkout into the worktree and commit them as the first commit.
  - If this session was started in some other worktree, still do all work in
    the one above.

## Every session

1. `cd` into the worktree. Read `PLAN.md` and `STATUS.md` (STATUS doesn't exist
   before phase 0 is done).
2. When starting a new phase: `git merge main`, port every Python change since
   the "Last main commit ported" in STATUS.md, and update that line.
3. Continue from STATUS.md's **Next step**.
4. Before you stop: update STATUS.md (rows, Next step), commit, and tell the
   owner in 3–5 plain sentences what's done, what's next and any question.

## Working loop (one Python module at a time)

1. Read the Python module and **all** of its tests completely.
2. Write the Dart tests first: the same cases, the same names in camelCase, the
   same expected values. Add parity cases to `tools/parity/dump.py` for pure
   functions.
3. Port the code. Follow the Python logic line by line. Keep the docstring
   intent as Dart doc comments. Check PLAN §3.5 (pitfalls) for every regex,
   division, rounding, date and JSON write.
4. Run the checks until everything is green:
   - core: `dart analyze` and `dart test` in `packages/strakalari_core`
   - app: `flutter analyze` and `flutter test` in `app`
   - after changing `tools/parity/`: run the Python reference suite too
5. Update the module's row in STATUS.md and commit. One module, or one screen,
   per commit. Never commit a broken tree.

## Stop and hand over

- **At every ⛔ checkpoint in PLAN §4:** write *Checkpoint notes* in STATUS.md
  (what was done, every deviation from Python, what you're unsure about, how to
  verify it) and commit. Tell the owner: "Checkpoint X reached: please have a
  reviewer model check it before I continue." **Don't start the next phase.**
- **Also stop and ask** (add it under *Questions* in STATUS.md and tell the
  owner) when:
  - a safety rule and the port seem to conflict;
  - a needed decision isn't in the plan;
  - you'd have to change Python code;
  - a test can't pass without changing what it checks.
- **Python behavior that looks wrong:** port it as is and note it under
  *Questions*. Don't fix it.

## Hard rules

- **Git:** never push, never open a PR, never merge into `main`. Commit as the
  configured git user, with plain commit messages and **no `Co-Authored-By` or
  `Claude-Session` lines**.
- **No real services:** never contact real Bakaláři or Strava servers, never
  use real credentials, and never send a real excuse or order. Use fakes,
  `tools/demo_data.py` and `tools/bakalari_demo_server.py`, in dry run.
- **Bakaláři:** the web interface only (pages, postbacks, the pages' own JSON
  endpoints). Never the `/api/3` mobile API.
- **No extras:** no new features, no redesign, no renamed config keys, no
  "improvements". If something seems worth improving, write one line under
  *Questions*.
- **Python is read-only.** The only exceptions are `tools/parity/` and merges
  from `main`.
- **Tests:** never delete, skip or weaken a test to get green. A dropped test
  goes under *Dropped* in STATUS.md with the reason.
- **Signing key:** never regenerate, move or overwrite
  `~/.strakalari-signing/`. Build the Android app as the test package
  `io.github.dendlerx.strakalari.test` for the phone. Never install over the
  Play Store app `io.github.dendlerx.strakalari`.
- **Flutter version:** never run `flutter upgrade` on `~/flutter/3.44.8`. Flet's
  phone build still needs that exact version.

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
- **Windows desktop builds:** Visual Studio 2026 with the C++ tools is installed.
  macOS can't be built here. Write the macOS and Linux parts and mark them
  *unverified* in STATUS.md.
- **Python reference:** the venv lives in the main checkout. From the worktree,
  run `C:/Users/matou/Documents/Programy/Python/strakalari/.venv/Scripts/python.exe -m pytest tests/`.
  Set `PYTHONUTF8=1` when you redirect Python output.
- **Demo data:** use a throwaway folder in your scratchpad, never the repo:
  - `python tools/demo_data.py generate <DIR>`
  - run either app with `STRAKALARI_DATA_DIR=<DIR>`.
- **Demo server:** `python tools/bakalari_demo_server.py --port 8080 --user demo --password demo`
  (plain HTTP on localhost).
- **Long commands** (builds, the full test suite): run them in the background.
  Read large files in parts.

Start now: set up the worktree if needed, read the plan, and continue with
phase 0 or the Next step in STATUS.md.
