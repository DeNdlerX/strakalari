# Phase 9 parity soak: side-by-side runs

Runs the Python reference and the Dart port side by side on demo data
and dry run for several days. Goal: **no open parity differences**.
Fixing differences is follow-up work — this checklist only finds and
records them (do NOT fix other agents' code here, just list it).

> **Beta release gate:** no beta is cut from this branch until the owner
> explicitly says so. No tags, no merges, no pushes — even with a green
> soak. Checkpoint D (release review) must pass first.

## Ground rules (PLAN §2.4–5, binding every day)

- **Never real servers, never real accounts.** All network runs go to
  `tools/bakalari_demo_server.py` on localhost. Strava stays disabled
  (`use_strava: false`); the refresh runs force `excuse_mode: dry_run`.
- **Throwaway data dirs only.** Pass a fresh empty dir per side per day
  (or reuse the pair to prove accumulating state — see Day 2+). Never a
  real data dir, never the repo checkout.
- **Native-path pitfall (Windows):** `python.exe` and `dart.exe` are
  native programs — pass native `C:/…` paths for `--data-dir` (an MSYS
  `/tmp/…` path lands on a drive-relative `C:\tmp\…` instead). Shell
  redirects (`> file`) are handled by bash and can use either form.
- Python commands below use the reference interpreter (3.11) that owns
  the installed test deps; Dart commands use the pinned **Flutter
  3.44.8** SDK. `STRAKALARI_DATA_DIR` is set by the scripts from
  `--data-dir` — do not pre-seed the dirs.

## One-time setup (per machine)

```bash
# 1. Demo server (one instance for the whole session; any free port):
python tools/bakalari_demo_server.py --port 18080 &
# Login is demo / demo; the server prints its URL on start.
```

## Daily routine (every soak day, back-to-back, same order)

```bash
# 2. Suites must stay green (read-only runs):
PYTHONUTF8=1 python -m pytest tests/ -q -p no:cacheprovider   # expect: 1643 passed
cd packages/strakalari_core && dart analyze                  # expect: No issues found
cd packages/strakalari_core && dart test                     # expect: All tests passed (720)
cd app && flutter analyze                                    # expect: No issues found

# 3. Parity oracle must be untouched (hand-edits would show as drift):
PYTHONUTF8=1 python tools/parity/dump.py
git diff --exit-code packages/strakalari_core/test/parity/  # expect: empty

# 4. Dry-run refresh parity, Python vs Dart (fresh throwaway dirs):
PYTHONUTF8=1 python tools/parity/soak_refresh.py \
    --url http://127.0.0.1:18080 --data-dir C:/Temp/soak9/dayN-py > dayN-py.json
dart bin/refresh_dryrun.dart \
    --url http://127.0.0.1:18080 --data-dir C:/Temp/soak9/dayN-dart > dayN-dart.json
python tools/parity/soak_compare.py dayN-py.json dayN-dart.json  # expect: IDENTICAL (modulo ts)

# 5. Fetch parity (byte-identical, no ts involved):
PYTHONUTF8=1 python tools/parity/fetch.py --url http://127.0.0.1:18080 > dayN-fetch-py.json
dart bin/parity_fetch.dart --url http://127.0.0.1:18080 > dayN-fetch-dart.json
cmp dayN-fetch-py.json dayN-fetch-dart.json && echo FETCH-OK
```

(`dart bin/…` runs from `packages/strakalari_core/`; replace `C:/Temp/soak9`
with any scratch dir **outside the repo**.)

Day 2+: repeat the routine twice — once on **fresh** dirs (first-run
behavior) and once **reusing the previous day's pair on both sides**
(accumulating state: appended audit trail, grown `timetable_history`,
outbox/history fills). Both must compare identically.

Optional (not daily, demo server only): the real-submit proof with a
fresh server instance per side —
`soak_refresh.py --send-day DD.MM.YYYY` is dry-run-only tooling; the
Dart side takes `--send-day DD.MM.YYYY`. Sent/history/outbox must match.
Record the date and the day used.

## What to compare (the checklist)

| # | Item | How | Green when |
|---|------|-----|------------|
| 1 | Python suite | `pytest tests/` | 1643 passed, no new failures |
| 2 | Dart suite | `dart test` (core) | all passed (720 on 2026-11-08) |
| 3 | Analyzers | `dart analyze`, `flutter analyze` | No issues found |
| 4 | Parity oracle | `dump.py` + `git diff --exit-code` | empty diff |
| 5 | Refresh parity | `soak_compare.py` | `IDENTICAL (modulo ts)` |
| 6 | Fetch parity | `cmp` | byte-identical |
| 7 | `saved_keys` / `cache_keys` incl. `stable_baseline` | inside item 5 JSON | equal |
| 8 | Audit trail, outbox, history | inside item 5 JSON (modulo `ts`) | equal |
| 9 | `main` merged, Python diff ported | `STATUS.md`: last ported commit | up to date |

Out of soak scope (owned by their phases, listed here so nobody
re-tests them daily): install-over tests (phases 7–8, Windows Sandbox /
test phone), screenshots (phase 6), store packaging.

## Logging

One line per day (append at the bottom of this file or in the soak
scratch dir, never committed user data):

`YYYY-MM-DD · py@<sha> dart@<sha> (git rev-parse --short HEAD) · suites OK · refresh IDENTICAL · fetch OK · notes: …`

- `2026-11-13 · py@0ffdcff dart@2f2b0f6 · suites OK (1643 py, 802+2skip core, 640+1skip app, 5/5 APK) · refresh IDENTICAL (fresh & accumulating) · fetch OK (31116 B) · notes: Day 1 against local bakalari_demo_server; fixed Windows toast console flash (9d868c5) and MSIX VC++ runtime DLLs + AppId comment (2f2b0f6)`

## Exit criteria (all must hold)

1. **No open parity differences**: items 1–9 green for several
   consecutive days (minimum three), on fresh and on reused data dirs.
2. `main` merged into the branch and its Python diff ported
   (`STATUS.md` records the commit).
3. Docs updated (README, CONTRIBUTING, PRIVACY wording for the Flutter
   builds — done in phase 9 prep).
4. ⛔ Checkpoint D (release review) passed by a reviewer.
5. **The beta is released only on the owner's explicit go-ahead.**
   The command path is the existing tag flow (`vX.Y.Z-beta.N`,
   Pre-release); nothing in this checklist performs it.
