"""Synthetic demo data for local testing and screenshots (never use a real account).

Builds a throwaway data folder (``config.json`` + ``data_cache.json``) for
a made-up student: fake teachers, marks, absences and canteen menus, all
dated relative to today so pending excuses and orderable lunches exist.

Usage (from the repository root)::

    python tools/demo_data.py generate DIR --lang en

The school calendar is the GEKOM 2026/2027 preset; once that year is
over, switch ``PRESET_ID`` to a current preset or the Planner stays empty.
"""

from __future__ import annotations

import argparse
import json
import os
from datetime import date, datetime, timedelta

PRESET_ID = "gekom_2026_2027"

DAYS_CS = ["pondělí", "úterý", "středa", "čtvrtek", "pátek"]
TIMES = ["8:00 - 8:45", "8:55 - 9:40", "10:00 - 10:45", "10:55 - 11:40",
         "11:50 - 12:35", "12:45 - 13:30", "13:40 - 14:25"]
#: name: (short, teacher, room) — every name is made up.
SUBJECTS = {
    "Matematika": ("M", "Mgr. Karel Novák", "P12"),
    "Český jazyk": ("ČJ", "Mgr. Eva Dvořáková", "P08"),
    "Anglický jazyk": ("AJ", "Mgr. Tomáš Malý", "J02"),
    "Německý jazyk": ("NJ", "Mgr. Lucie Veselá", "J04"),
    "Fyzika": ("F", "RNDr. Petr Horák", "F1"),
    "Chemie": ("CH", "Mgr. Jana Pokorná", "CH1"),
    "Biologie": ("BI", "Mgr. Martin Kučera", "B2"),
    "Dějepis": ("D", "PhDr. Alena Marková", "P05"),
    "Zeměpis": ("Z", "Mgr. Ondřej Beneš", "P06"),
    "Informatika": ("IVT", "Ing. David Svoboda", "PC1"),
    "Tělesná výchova": ("TV", "Mgr. Jakub Říha", "TEL"),
    "Základy společenských věd": ("ZSV", "Mgr. Hana Černá", "P03"),
}
WEEK = [
    ["Matematika", "Český jazyk", "Anglický jazyk", "Fyzika", "Dějepis", "Tělesná výchova"],
    ["Chemie", "Matematika", "Německý jazyk", "Biologie", "Informatika", "Informatika"],
    ["Anglický jazyk", "Zeměpis", "Matematika", "Český jazyk", "Základy společenských věd"],
    ["Fyzika", "Německý jazyk", "Biologie", "Matematika", "Dějepis", "Tělesná výchova"],
    ["Český jazyk", "Anglický jazyk", "Chemie", "Zeměpis", "Základy společenských věd"],
]
ABSENCE_PCT = {
    "Matematika": 6.1, "Český jazyk": 4.2, "Anglický jazyk": 8.7, "Německý jazyk": 12.5,
    "Fyzika": 3.8, "Chemie": 18.2, "Biologie": 7.4, "Dějepis": 0.0, "Zeměpis": 5.0,
    "Informatika": 21.4, "Tělesná výchova": 9.1, "Základy společenských věd": 2.6,
}
#: subject: [(mark, weight, days ago)]
MARKS = {
    "Matematika": [("2", 5, 20), ("1-", 2, 15), ("3", 5, 9), ("2", 1, 4), ("1", 2, 1)],
    "Český jazyk": [("1", 5, 18), ("2-", 3, 10), ("1", 1, 3)],
    "Anglický jazyk": [("1", 3, 16), ("1-", 5, 8), ("2", 1, 2)],
    "Německý jazyk": [("3", 5, 17), ("2-", 2, 11), ("3-", 5, 5)],
    "Fyzika": [("2", 5, 14), ("2", 2, 6)],
    "Chemie": [("4", 5, 19), ("3", 3, 12), ("2-", 2, 2)],
    "Biologie": [("1", 5, 13), ("1", 1, 7)],
    "Dějepis": [("2", 5, 15), ("1", 2, 3)],
    "Informatika": [("92", 5, 16), ("78", 3, 9), ("88", 2, 1)],
}
#: Mon..Fri: (soup, meal 1, meal 2, meal 3)
MENUS = [
    ("Hovězí vývar s nudlemi", "Kuřecí řízek, bramborová kaše",
     "Špagety s rajčatovou omáčkou a sýrem", "Zeleninový salát s tofu"),
    ("Čočková polévka", "Vepřový guláš, houskový knedlík", "Rizoto se zeleninou",
     "Palačinky s tvarohem"),
    ("Brokolicový krém", "Pečené kuře, rýže", "Smažený sýr, hranolky",
     "Bulgur s pečenou zeleninou"),
    ("Gulášová polévka", "Svíčková na smetaně, knedlík", "Bramboráky se zelím",
     "Těstovinový salát"),
    ("Rajská polévka", "Rybí filé, bramborový salát", "Kuskus s cizrnou",
     "Buchtičky se šodó"),
]

TOURS_DONE = ["intro", "excuse", "timetable", "lunches", "marks",
              "settings", "activity"]


def _cz_date(day: date) -> str:
    return f"{day.day}.{day.month}.{day.year}"


def build_cache(today: date) -> dict:
    monday = today - timedelta(days=today.weekday())
    # Early in the week the "fresh" absences go to last week, so they are
    # always in the past.
    fresh = 0 if today.weekday() >= 2 else -1
    timetable: dict[str, list] = {}
    baseline: dict[str, dict] = {}
    for week in range(-3, 2):
        for wd in range(5):
            day = monday + timedelta(weeks=week, days=wd)
            key = f"{_cz_date(day)} ({DAYS_CS[wd]})"
            rows = []
            for i, subject in enumerate(WEEK[wd]):
                period = i + 1
                short, teacher, room = SUBJECTS[subject]
                row = {
                    "teacher": teacher, "subject": subject, "subject_short": short,
                    "room": room, "group": "", "theme": "", "notice": "",
                    "date": key, "time": f"{period} ({TIMES[i]})",
                    "absencetext": "", "absenceType": "NoAbsent", "changeinfo": "",
                    "infoChangeCode": "", "changeBadgeChar": "", "hourIndex": period + 1,
                    "period": period,
                }
                if day < today:
                    row["theme"] = "Opakování probrané látky"
                if week == fresh - 2 and wd == 1:  # an old sick day, excused
                    row["absenceType"], row["absencetext"] = "Omluveno", "Omluveno"
                if week == fresh and wd == 1 and period <= 2:  # not excused yet
                    row["absenceType"], row["absencetext"] = "Absent", "Neomluveno"
                if week == fresh and wd == 0 and period == 1:
                    row["absenceType"], row["absencetext"] = "AbsentLate", "Pozdní příchod"
                if week == 1 and wd == 2 and period == 2:
                    row["notice"], row["changeBadgeChar"] = "Suplování", "S"
                    row["teacher"] = SUBJECTS["Základy společenských věd"][1]
                if week == 1 and wd == 4 and period == 5:
                    row["notice"] = "Odpadá"
                rows.append(row)
                baseline.setdefault(f"{wd}|{period}", {
                    "weekday": wd, "period": period, "subject": subject,
                    "teacher": teacher, "room": room, "support": 5,
                })
            timetable[key] = rows

    weekly_hours = {s: sum(day.count(s) for day in WEEK) for s in SUBJECTS}
    details = {}
    for subject, pct in ABSENCE_PCT.items():
        total = weekly_hours[subject] * 4.0
        details[subject] = {"percent": pct, "total_hours": total,
                            "missed_hours": round(total * pct / 100, 1),
                            "approaching": pct >= 15, "unclassifiable": False}

    grades = {
        subject: [{"Grade": mark, "Weight": weight,
                   "Date": _cz_date(today - timedelta(days=ago))}
                  for mark, weight, ago in marks]
        for subject, marks in MARKS.items()
    }

    # Menus from a few days out, so most are still before the order cutoff.
    meals: dict[str, dict] = {}
    ordered: dict[str, str] = {}
    for week in range(1, 3):
        for wd in range(5):
            day = monday + timedelta(weeks=week, days=wd)
            if day <= today + timedelta(days=3):
                continue
            key = day.strftime("%d.%m.%Y")
            soup, *mains = MENUS[wd]
            table = f"table{week * 5 + wd}"
            meals[key] = {f"{table}&-1&0": "Neobjednáno"}
            for n, main in enumerate(mains, start=1):
                meals[key][f"{table}&{n}&0"] = f"{soup}, {main}"
            if week == 1 and wd in (1, 3):
                ordered[key] = f"{table}&{1 + wd % 3}&0"

    return {
        "last_updated": datetime.now().strftime("%d.%m.%Y %H:%M:%S"),
        "timetable": timetable,
        "absence": dict(ABSENCE_PCT),
        "grades": grades,
        "substitutions": [],
        "absence_details": details,
        "stable_baseline": baseline,
        "stable_baseline_source": "scraped",
        "strava_meals": meals,
        "strava_ordered": ordered,
        "_cache_version": 2,
        "subject_directory": {s: v[1] for s, v in SUBJECTS.items()},
    }


def generate(out_dir: str, lang: str = "cs", theme: str = "dark",
             tutorials: bool = False) -> str:
    """Writes a fresh demo data folder; returns its path."""
    os.makedirs(out_dir, exist_ok=True)
    config = {
        "language": lang,
        "theme": theme,
        "disclaimer_accepted": True,
        "school_preset_id": PRESET_ID,
        # Off: no bubbles at all. On: only the Absence tour (with planning) is left to show.
        "tutorials_enabled": tutorials,
        "tutorials_done": TOURS_DONE if tutorials else [],
        "use_strava": True,
        "subject_limits": {"Chemie": 25.0, "Informatika": 25.0},
        "your_signature": "Jan Ukázka",
    }
    for name, data in (("config.json", config),
                       ("data_cache.json", build_cache(date.today()))):
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=1)
    return out_dir


def _cli() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("generate", help="write a demo data folder")
    g.add_argument("dir")
    g.add_argument("--lang", choices=["cs", "en"], default="cs")
    g.add_argument("--theme", choices=["dark", "light"], default="dark")
    g.add_argument("--tutorials", action="store_true",
                   help="leave the Absence tutorial (with planning) on")
    args = parser.parse_args()
    if args.cmd == "generate":
        print(generate(args.dir, args.lang, args.theme, args.tutorials))


if __name__ == "__main__":
    _cli()
