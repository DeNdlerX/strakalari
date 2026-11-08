"""Parity fetch: log in to the Bakalari demo server and dump everything.

Read-only: login, two timetable views, grades, absence, substitutions,
subjects, the outbox and excuse hours. Run against one server instance::

    python tools/bakalari_demo_server.py --port 8080 &
    PYTHONUTF8=1 python tools/parity/fetch.py --url http://127.0.0.1:8080 > /tmp/py.json

``packages/strakalari_core/bin/parity_fetch.dart`` prints the same JSON;
the two files must be byte-identical.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, REPO_ROOT)

from strakalari.core.bakalari_client import BakalariClient


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
    args = parser.parse_args()

    client = BakalariClient({
        "bakalari_url": args.url,
        "bakalari_username": args.user,
        "bakalari_password": args.password,
        "go_back_weeks": 1,
        "go_forward_weeks": 1,
    })
    client.login()
    today = date.today()
    monday = today.fromordinal(today.toordinal() - today.weekday())
    client.obtain_absence_info()
    data = {
        "timetable_perm": client._timetable_view("perm", monday),
        "timetable_week": client._timetable_view("cal", monday),
        "grades": client.get_grades(),
        "absence_percentages": client.absencePercentages,
        "absence_details": client.absenceDetails,
        "substitutions": client.fetch_substitutions(),
        "subjects": client.fetch_subject_directory(),
        "outbox": client.fetch_sent_excuses(),
        "excuse_hours": client._excuse_hours(client._session(), monday),
    }
    sys.stdout.buffer.write(
        (json.dumps(canonical(data), ensure_ascii=False,
                    separators=(",", ":")) + "\n").encode("utf-8"))


if __name__ == "__main__":
    main()
