"""Bakaláři timetable: weekly views and the stable ("Stálý") timetable."""

import re
from datetime import datetime, timedelta

from .helpers import extract_lesson_num
from .bakalari_common import (
    parse_timetable_detail,
    _detail_days,
    week_offsets,
)
from .extractors.bakalari import timetable_details


#: A permanent-view atom's IdentCode has a blank date part
#: ("1       003T2RD…"); an actual week's carries the date ("12026092103T2RD…").
_PERM_IDENT_RE = re.compile(r"^\S\s{4}")


def is_perm_view(details) -> bool:
    """True when timetable ``details`` are the permanent ("Stálý") view.

    Every lesson with an IdentCode must have the blank date part; one
    dated IdentCode means an actual week came back instead.
    """
    perm = 0
    for detail in details or []:
        code = str(detail.get("IdentCode") or "") if isinstance(detail, dict) else ""
        if not code:
            continue
        if not _PERM_IDENT_RE.match(code):
            return False
        perm += 1
    return perm > 0


class TimetableMixin:
    """Mixin of :class:`~.bakalari_client.BakalariClient`; uses its session state."""

    def _timetable_view(self, term: str, day) -> list:
        """Lesson details of one timetable view (``cal`` = the week of ``day``,
        ``perm`` = the stable timetable), as the timetable page loads them."""
        content = self._session().json(
            "POST", "/Timetable/GetContentData",
            json={"term": term, "date": day.isoformat(), "selectedClassId": ""})
        return timetable_details(content)

    def fetch_timetable_weeks(self):
        """Loads the regular week window plus the history weeks into
        ``timetable_sources`` (one detail list per loaded week)."""
        self.login()
        current_week = datetime.today().date()
        offsets = week_offsets(self.go_back_weeks, self.go_forward_weeks)
        # Timetable history: older school-year weeks the cache still lacks
        # (all of them on the first run, none afterwards). Fetched after
        # the regular window so a slow backfill never delays fresh data.
        this_monday = current_week - timedelta(days=current_week.weekday())
        for monday in sorted(getattr(self, "history_weeks", None) or (), reverse=True):
            off = (monday - this_monday).days // 7
            if off < 0 and off not in offsets:
                offsets.append(off)
        self.timetable_loaded_weeks = set()
        if not offsets:
            self.log("Warning: no timetable weeks to fetch (go_back_weeks=0, go_forward_weeks=0).")
        for off in offsets:
            self._raise_if_cancelled()
            week_date = current_week + timedelta(weeks=off)
            monday = week_date - timedelta(days=week_date.weekday())
            details = self._timetable_view("cal", monday)
            shown = _detail_days(details)
            target_days = {monday + timedelta(days=i) for i in range(7)}
            if shown and not shown.intersection(target_days):
                # Another week came back: storing it would silently skip
                # this week. The cache merge keeps its previously known days.
                self.log(f"Warning: week of {monday:%d.%m.%Y} did not load (got "
                         f"{min(shown):%d.%m.}–{max(shown):%d.%m.}), skipping it this run.")
                continue
            self.timetable_sources.append(details)
            self.timetable_loaded_weeks.add(monday)

    def add_timetable_details(self, details, target: dict = None, dropped: int = 0):
        """Merges timetable details into ``timetableData`` (or ``target`` —
        the stable view parses into its own dict), grouped per day."""
        results = []
        dropped_incomplete = 0
        for detail in details or []:
            hour_to_add = parse_timetable_detail(detail)
            if hour_to_add is None:
                dropped_incomplete += 1
                continue
            if hour_to_add not in results:
                results.append(hour_to_add)

        unsortedTimetableData = {}
        for result in results:
            date_key = result.get("date")
            if not date_key:
                dropped_incomplete += 1
                continue
            if date_key not in unsortedTimetableData:
                unsortedTimetableData[date_key] = []
            unsortedTimetableData[date_key].append(result)
        if dropped or dropped_incomplete:
            self.log(
                f"Warning: timetable parse dropped {dropped} malformed + "
                f"{dropped_incomplete} dateless/incomplete rows (format may have changed)."
            )

        for day, lessons in unsortedTimetableData.items():
            def lesson_sort_key(item):
                num = extract_lesson_num(item.get("time", ""))
                if num is None:
                    try:
                        num = int(item.get("period")) if item.get("period") is not None else None
                    except (TypeError, ValueError):
                        num = None
                return num if num is not None else 999

            dest = target if target is not None else self.timetableData
            if day not in dest:
                dest[day] = []
            for lesson in sorted(lessons, key=lesson_sort_key):
                if lesson not in dest[day]:
                    dest[day].append(lesson)

    def extract_stable_timetable(self) -> bool:
        """Loads the 'Stálý rozvrh' view into ``stableTimetableData``.

        Returns True when the stable view came back with lessons; False
        when it failed or another view came back (the run then has no
        stable baseline). Never raises except on user cancel.
        """
        self._raise_if_cancelled()
        self.stableTimetableData = {}
        try:
            details = self._timetable_view("perm", datetime.today().date())
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Warning: stable timetable request failed ({e}) — no stable timetable this run.")
            return False
        # The perm view still carries this week's dates — only IdentCode
        # tells it apart from an actual week (blank date part).
        if not is_perm_view(details):
            self.log("Warning: stable timetable view did not load — "
                     "no stable timetable this run.")
            return False
        self.add_timetable_details(details, target=self.stableTimetableData)
        n_lessons = sum(len(v) for v in self.stableTimetableData.values())
        if not n_lessons:
            self.log("Warning: no stable lessons parsed — no stable timetable this run.")
            return False
        self.log(f"Stable timetable loaded: {n_lessons} lessons "
                 f"in {len(self.stableTimetableData)} days.")
        return True
