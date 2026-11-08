"""Soak parity (Python side): dry-run refresh against the demo server.

Prints the same canonical JSON as
``packages/strakalari_core/bin/refresh_dryrun.dart`` so the two runs can
be compared (modulo ``ts`` timestamps) with
``tools/parity/soak_compare.py``.

Reproducible run (phase 9 soak; demo server only, throwaway data dirs)::

    python tools/bakalari_demo_server.py --port 18080 &
    PYTHONUTF8=1 python tools/parity/soak_refresh.py \
        --url http://127.0.0.1:18080 --data-dir <tmp-py> > py.json
    dart bin/refresh_dryrun.dart \
        --url http://127.0.0.1:18080 --data-dir <tmp-dart> > dart.json
    python tools/parity/soak_compare.py py.json dart.json

Never sends anything: ``excuse_mode`` is forced to ``dry_run`` and Strava
is disabled. Never point this at a real server or a real data dir.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, REPO_ROOT)
os.environ["STRAKALARI_NO_KEYRING"] = "1"


def canonical(value):
    if isinstance(value, dict):
        return {str(k): canonical(value[k]) for k in sorted(value, key=str)}
    if isinstance(value, (list, tuple)):
        return [canonical(v) for v in value]
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--url", default="http://127.0.0.1:8080")
    parser.add_argument("--user", default="demo")
    parser.add_argument("--password", default="demo")
    parser.add_argument("--data-dir", default=None,
                        help="throwaway dir (STRAKALARI_DATA_DIR); "
                             "never a real data dir")
    args = parser.parse_args()

    from strakalari.core.audit import recent
    from strakalari.core.automation import Strakalari
    from strakalari.core.cache import load_data_cache
    from strakalari.core.excuse_history import load_unconfirmed
    from strakalari.core.helpers import parse_date
    from strakalari.core.refresh import run_refresh

    data_dir = args.data_dir or os.environ.get("STRAKALARI_DATA_DIR", "")
    if not data_dir:
        raise SystemExit("refusing to run without --data-dir (never a real data dir)")
    os.makedirs(data_dir, exist_ok=True)
    os.environ["STRAKALARI_DATA_DIR"] = data_dir

    config = {
        "bakalari_url": args.url,
        "bakalari_username": args.user,
        "bakalari_password": args.password,
        "go_back_weeks": 1,
        "go_forward_weeks": 1,
        "excuse_mode": "dry_run",
        "strava_order_mode": "confirm",
        "use_strava": False,
    }
    app = Strakalari(config_file=os.path.join(data_dir, "config.json"),
                     config_data=config)
    try:
        result = run_refresh(app, app.config_data)

        # Seed a deterministic unexcused lesson on the latest loaded school
        # day at least 3 days before today so excuse_pending() exercises
        # generate_excuses + send_excuse in dry_run mode against the server.
        today_d = datetime.now().date()
        eligible_days = []
        for day_key, lessons in (app.timetableData or {}).items():
            if not isinstance(lessons, list) or not lessons:
                continue
            try:
                parsed = parse_date(day_key).date()
            except ValueError:
                continue
            if (today_d - parsed).days >= 3:
                eligible_days.append((parsed, day_key, lessons))
        if eligible_days:
            eligible_days.sort(key=lambda item: item[0], reverse=True)
            _, _, target_lessons = eligible_days[0]
            if isinstance(target_lessons[0], dict):
                target_lessons[0]["absenceType"] = "Absent"
                target_lessons[0]["absencetext"] = "neomluveno"
        pending_sent = app.excuse_pending()

        # A dry-run one-click excuse for a synthetic past absence (fill
        # only, mirrors refresh_dryrun.dart).
        past = datetime.now() - timedelta(days=5)
        day = past.strftime("%d.%m.%Y")
        single_outcome = app.excuse_single(
            {"type": "days and hours",
             "starting_day": day,
             "ending_day": day,
             "starting_lesson": 2,
             "ending_lesson": 4},
            "Omluvte prosim absenci.")

        history = []
        try:
            with open(app.already_excused_file, encoding="utf-8") as f:
                history = json.load(f)
        except (OSError, ValueError):
            history = []

        cache = load_data_cache()
        data = {
            "result": {
                "scope": result.scope,
                "bakalari_fetched": result.bakalari_fetched,
                "strava_fetched": result.strava_fetched,
                "subjects": result.subjects,
                "menu_days": result.menu_days,
                "excuses_sent": result.excuses_sent,
                "excuses_failed": result.excuses_failed,
                "lunches_ordered": result.lunches_ordered,
                "automation_paused": result.automation_paused,
                "low_balance": result.low_balance,
                "errors": [f"{phase}: {exc}" for phase, exc in result.errors],
                "news": [f"{event}: {message}" for event, message in result.news],
                "saved_keys": sorted(result.saved.keys()),
            },
            "dry_run_pending_sent": pending_sent,
            "dry_run_single_filled": single_outcome,
            "audit": recent(limit=2000),
            "outbox": app.bakalari_client.fetch_sent_excuses(limit=100),
            "history": history,
            "sidecar": load_unconfirmed(app.already_excused_file),
            "cache_keys": sorted(cache.keys()),
            "cache": cache,
        }
        sys.stdout.buffer.write(
            (json.dumps(canonical(data), ensure_ascii=False,
                        separators=(",", ":")) + "\n").encode("utf-8"))
    finally:
        app.close()


if __name__ == "__main__":
    main()
