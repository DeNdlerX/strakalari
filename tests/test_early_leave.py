"""Early-leave ("soon") category: detection, excuses, templates, UI wiring."""
from datetime import datetime
from types import SimpleNamespace

from strakalari.core.automation import Strakalari
from strakalari.core.extractors.bakalari import extract_sent_excuses


def _lesson(abs_type="", abs_text="", period="1"):
    return {
        "teacher": "T1",
        "subject": "M",
        "time": period,
        "absenceType": abs_type,
        "absencetext": abs_text,
    }


class TestSoonDetection:
    def test_absent_soon_yields_soon_excuse(self):
        raw = {"10.09.2026": [_lesson("AbsentSoon", "AbsentSoon")]}
        excuses = Strakalari.generate_excuses(
            raw, delay_days=1, override_today=datetime(2026, 9, 15))
        assert len(excuses) == 1
        assert excuses[0]["type"] == "soon"
        assert excuses[0]["starting_lesson"] == 1
        assert excuses[0]["ending_lesson"] == 1

    def test_brzky_odchod_variants(self):
        for text in ("Brzký odchod", "Brzky odchod"):
            raw = {"10.09.2026": [_lesson(text, text)]}
            excuses = Strakalari.generate_excuses(
                raw, delay_days=1, override_today=datetime(2026, 9, 15))
            assert excuses == [{
                "type": "soon", "starting_day": "10.09.2026",
                "ending_day": "10.09.2026", "starting_lesson": 1,
                "ending_lesson": 1,
            }], text

    def test_late_still_yields_income(self):
        raw = {"10.09.2026": [_lesson("AbsentLate", "Pozdní příchod")]}
        excuses = Strakalari.generate_excuses(
            raw, delay_days=1, override_today=datetime(2026, 9, 15))
        assert [e["type"] for e in excuses] == ["income"]

    def test_soon_does_not_merge_into_full_day(self):
        raw = {"10.09.2026": [
            _lesson("AbsentSoon", "Brzký odchod", period="1"),
            _lesson("Absent", "Absence", period="2"),
        ]}
        excuses = Strakalari.generate_excuses(
            raw, delay_days=1, override_today=datetime(2026, 9, 15))
        by_type = sorted(e["type"] for e in excuses)
        assert by_type == ["days and hours", "soon"]


class TestSoonStatus:
    def _status(self, raw):
        from strakalari.core.models import _lesson_status_from_legacy
        return _lesson_status_from_legacy(raw)[0]

    def test_absent_soon_is_soon_not_absent(self):
        assert self._status({"absenceType": "AbsentSoon"}) == "soon"
        assert self._status({"absencetext": "AbsentSoon"}) == "soon"

    def test_brzky_odchod_is_soon(self):
        assert self._status({"absencetext": "Brzký odchod"}) == "soon"
        assert self._status({"absenceType": "Brzky odchod"}) == "soon"

    def test_generic_early_unchanged(self):
        assert self._status({"absencetext": "Předčasný odchod"}) == "early"
        assert self._status({"absenceType": "AbsentEarly"}) == "early"

    def test_excused_soon_stays_excused(self):
        assert self._status({
            "absenceType": "AbsentSoon", "absencetext": "Omluveno"}) == "excused"

    def test_soon_task_kind(self):
        from strakalari.core.models import (
            excuse_tasks_from_lessons, lessons_from_timetable)
        timetable = {"10.09.2026": [{
            "subject": "M", "teacher": "T", "time": "1 (8:00-8:45)",
            "absenceType": "AbsentSoon", "absencetext": "Brzký odchod"}]}
        tasks = excuse_tasks_from_lessons(lessons_from_timetable(timetable))
        assert len(tasks) == 1
        assert tasks[0].kind == "soon"

    def test_soon_badge_kind_is_late_color(self):
        from strakalari.flet_ui.components import lesson_kind
        assert lesson_kind("soon") == "late"


class TestSoonTemplates:
    def test_config_defaults(self):
        from strakalari.core.config import CANONICAL_DEFAULTS
        assert len(CANONICAL_DEFAULTS["left_soon_excuses"]) >= 1

    def test_planner_templates_for_soon(self):
        from strakalari.flet_ui.views.planner import _templates
        state = SimpleNamespace(get=lambda k, d=None: {
            "left_soon_excuses": ["SOON-TPL"],
            "late_income_excuses": ["LATE-TPL"],
            "short_absence_excuses": ["SHORT-TPL"],
            "long_absence_excuses": ["LONG-TPL"],
            "your_signature": "",
        }.get(k, d))
        assert _templates(state, kind="soon") == ["SOON-TPL"]
        assert _templates(state, kind="late") == ["LATE-TPL"]

    def test_web_hour_excuse_dedupes_soon(self):
        html = ('<div data-testid="komens-message-detail-header">'
                "Od: 10.9.2026 (2. hod.) Do: 10.9.2026 (2. hod.)</div>")
        result = extract_sent_excuses(html)
        assert {"type": "soon", "starting_day": "10.09.2026",
                "ending_day": "10.09.2026", "starting_lesson": 2,
                "ending_lesson": 2} in result
