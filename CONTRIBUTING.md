# Contributing to Strakaláři

Thanks for wanting to help! This guide covers local development, testing, building installers, and the rules that keep the project healthy.

End-user documentation lives in [README.md](README.md) / [README.en.md](README.en.md) — this file is for developers only.

---

## 1. Prerequisites

- **Python 3.11 or 3.12** (frozen release builds pin **3.11**; do not develop on <3.11).
- Git.
- No admin rights needed for development (but Windows tray/autostart features are best tested on Windows).

## 2. Local setup

```bash
git clone https://github.com/DeNdlerX/strakalari.git
cd strakalari
```

**On GNU/Linux and macOS:**

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
playwright install chromium
```

**On Windows (PowerShell):**

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
playwright install chromium
```

Create your local config from the template (never commit the real one — `config.json` holds credentials):

```bash
cp config.example.json config.json        # GNU/Linux, macOS
copy config.example.json config.json      # Windows PowerShell
```

## 3. Running from source

```bash
python main.py                 # desktop UI (Windows: run.bat)
python main.py --minimized     # tray mode (background service)
python -m strakalari.flet_ui --view web --port 8555   # browser preview of the UI
```

Without credentials the wizard can be skipped ("Skip for now"); the screens then stay empty until real data is cached.

### Configuration and data files

Users configure everything on the **Settings** screen; the files below are for development and debugging.

- `config.json` — settings. `config.example.json` is the full key reference. `strava_blacklist.json` holds the forbidden lunch ingredients.
- `data_cache.json` — the downloaded timetable, absences, marks and menu.
- `already_excused_lessons.json`, `automation_history.jsonl` — what was sent (the Activity screen reads the history).
- `log.txt`, `console.log` — the app log and the captured stdout/stderr of windowed builds.
- `school_presets/*.json` — user-added school calendars (see [docs/SCHOOL_PRESETS.md](docs/SCHOOL_PRESETS.md)).

Where they live (`core.helpers.get_user_data_dir`): next to `main.py` when running from source, next to the executable when that folder is writable (the Windows installer puts it in `%LOCALAPPDATA%\Programs\Strakalari`), otherwise `%LOCALAPPDATA%\Strakalari`, `~/Library/Application Support/Strakalari` (macOS, always) or `~/.config/strakalari` (Linux, e.g. the read-only AppImage mount). `STRAKALARI_DATA_DIR` overrides all of them.

Passwords and the Gemini key are encrypted; the key is kept in the OS credential store via `keyring` (`core.secret_store`), falling back to `secret.key` in the data folder where no store exists. The in-app "Copy log" button scrubs passwords, usernames and the signature (`core.error_report.redact_text`); the raw files are not scrubbed.

## 4. Tests

```bash
python -m pytest tests/ -v
python -m ruff check .   # lint: bug-finding rules only (config in pyproject.toml)
```

- CI runs the linter and the suite on Ubuntu + Windows × Python 3.11/3.12 (see `.github/workflows/test.yml`).
- CI minutes are limited — **always run the full suite locally and make it pass before pushing**. Don't use CI as your test runner.
- Add a test when you fix a bug or change behavior (`tests/test_*.py`).

## 5. Project layout

```
main.py                  # entry point: UI, or tray with --minimized
strakalari/core/         # business logic (no UI imports)
  bakalari_client.py     #   Bakaláři session + login (Playwright), assembled from:
  bakalari_timetable.py  #     weekly + stable timetable scraping
  bakalari_data.py       #     marks, absence, sent excuses, substitutions, baseline
  bakalari_excuse.py     #     the excuse form (fill, lesson pickers, verified submit)
  bakalari_common.py     #     pure parsing helpers shared by the above
  strava_client.py       #   Strava menu scraping + meal clicks
  automation.py          #   Strakalari: clients + excuse sending + order application
  refresh.py             #   THE refresh pipeline (used by the UI and the tray)
  excuse_history.py      #   already-excused history: coverage checks + send lock
  audit.py               #   automation history: every send/order attempt (Activity screen)
  secret_store.py        #   password-encryption key in the OS credential store (keyring)
  school_presets.py      #   school calendars (shipped + school_presets/*.json)
  lunch_auto.py          #   auto-mode lunch picks (blacklist filter / Gemini)
  models.py, schedule.py, forecast.py, planned_skips.py, …
strakalari/flet_ui/      # Flet desktop UI
  state.py               #   AppState core (+ state_*.py mixins per feature)
  views/, strings.py, tray.py, app.py
tests/                   # pytest suite, one file per feature (shared fixtures in conftest.py)
tools/demo_data.py       # synthetic demo data + README screenshots
config.example.json      # canonical config-key reference (keep in sync with code!)
strakalari.spec          # PyInstaller bundle definition
installer.iss            # Inno Setup script (Windows installer)
```

These rules keep the automation safe:

- **One pipeline.** Anything that refreshes data or runs auto modes goes through `core.refresh.run_refresh` — never a second copy in the UI or the tray.
- **One session at a time.** The tray and the window are separate processes (on macOS always: every launch runs the tray, which opens the window, because Cocoa needs the main thread — see `flet_ui/macos.py`). Whole refreshes and order submits run under `core.refresh.session_lock()` (an OS file lock); a caller that cannot get it skips with a visible message instead of running in parallel.
- **One send path.** Excuses are sent only via `Strakalari._send_excuse`, which checks the history for coverage and holds the history lock across check, submit and write. Navigation-triggering clicks use `click(once=True)` and are never retried.
- **Everything is recorded.** Every send/order attempt (manual or auto, real or dry run, success or failure) goes to `core.audit`; `automation_paused` must stop every auto phase.
- **New feature, new tutorial.** Interactive tutorials live in `flet_ui/tutorial.py`: add a `Tour` to `TOURS`, its `tut_*` strings (cs + en), call `tutorial.offer(state, "<id>")` in the view once the feature's content is on screen, wrap the controls it explains in `tutorial.anchor(...)`, and fire `state.tutorial_event("<name>")` where the action succeeds if a step waits for it. The module docstring has the details.
- **Fail loudly.** In send, order and save code an exception is never swallowed silently: log it (`writeLog` / `self.log`), or `print("Warning: …")` where no logger exists (windowed builds write stdout/stderr to `console.log`). An auto phase that did not do its job is an `AutomationError` in `RefreshResult.errors`, which the UI and tray surface. Silent `except Exception: pass` is fine only for optional probes (is an element visible, cosmetic UI updates).

## 6. Contribution guidelines

- **Match existing style and conventions.** Touch only what the task needs — no drive-by refactors, renames, or reformatting.
- **Config keys are canonical.** The keys in `config.example.json` are the only valid names — no aliases, no silent migration. If you add/remove/rename a key, update `config.example.json`, the validation in `strakalari/core/config.py`, and its tests in the same PR.
- **Dependencies are pinned exactly** in `requirements.txt` (CI resolves fresh every run; floating ranges have shipped broken combos before). `flet` + `flet-desktop` + `flet-web` must share one version. If you bump a version, re-run the full test suite **plus a local frozen smoke test** (section 7) before committing.
- **Keep it locale-safe.** Releases are QA-tested on an English-locale Windows machine — never assume a Czech locale: no locale-dependent date/number parsing, no hardcoded Czech strings in logic (UI text belongs in `strakalari/flet_ui/strings.py` with both `cs` and `en`), no console codepage assumptions.
- **Keep it end-user safe.** The installer is used by non-technical classmates: no scary dialogs, no unexplained failures, no data loss. Destructive/network actions default to confirmation (`confirm` modes).
- **Screenshots use synthetic data only.** README images live in `docs/images/` (`<screen>-cs.png` / `<screen>-en.png`, dark theme) and come from `python tools/demo_data.py screenshots`, which builds a made-up student in a throwaway data folder and captures both languages with headless Chromium. `generate` / `serve` give you the same demo data to click through by hand. Never take screenshots from a real account.
- **User docs stay non-technical.** README.md / README.en.md are for classmates who just download the installer; anything about source, config files or internals belongs here.
- **GPLv3.** All contributions are under the project's GNU GPLv3 license.

## 7. Building installers locally

Verify packaging work locally (PyInstaller + smoke test) rather than burning CI release runs:

```bash
pyinstaller strakalari.spec
```

- **Windows installer**: compile `installer.iss` with Inno Setup (`ISCC.exe`); local builds fall back to the hardcoded version in the script, CI stamps the release version.
- **Linux**: AppImage packaging — see `.github/workflows/build.yml` (`build-linux` job).
- **macOS**: `.dmg` drag-and-drop bundle — see `build-macos` in the same workflow.

After building, smoke-test the actual artifact (launch, wizard, one refresh) before pushing.

## 8. Releases

Releases are cut by tagging: `git tag vX.Y.Z && git push origin vX.Y.Z` — or run the **Build & Release Strakalari** workflow by hand with the `release_tag` input (the tag is created on the selected commit). The `build.yml` workflow builds all three platforms, runs the test suite, and a single final job publishes one GitHub Release with every installer attached and generated notes. Keep `strakalari/__init__.py:__version__` sensible — CI stamps it from the tag at build time.

- **Stable** (`v0.2.0`): published as a **draft** — review it and press *Publish*.
- **Beta** (`v0.2.0-beta.1`, anything with a `-suffix`): published immediately and marked **Pre-release**. Only users on the *Beta* update channel (Settings → Diagnostics; the default for anyone whose first install was a beta) are notified; *Stable* users never see pre-releases. Beta users are also notified about stable releases, and `0.2.0` counts as newer than `0.2.0-beta.N`.

The in-app update check reads the public GitHub API without a token, so it only works while the repository is public (a private repo answers 404 and the check stays silent).

## 9. Reporting bugs

Include: app version, OS (+ locale if non-English), what you did, what happened vs. what you expected, and the relevant part of `log.txt` / `console.log` (redact credentials). The in-app "Copy log" button already scrubs passwords, usernames and the signature. Check open [issues](https://github.com/DeNdlerX/strakalari/issues) first to avoid duplicates.
