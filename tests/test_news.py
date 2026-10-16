"""New marks, absences and timetable changes since the previous refresh (core.news)."""
from datetime import date

import pytest

from strakalari.core.i18n import set_language
from strakalari.core.news import find_news, new_absences, new_changes, new_marks

TODAY = date(2099, 10, 1)
PAST = "29.9.2099 (úterý)"
FUTURE = "5.10.2099 (pondělí)"


@pytest.fixture(autouse=True)
def _czech():
    set_language("cs")
    yield
    set_language("cs")


def _lesson(period, subject="M", **extra):
    return {"subject": subject, "time": f"{period} (8:00 - 8:45)", **extra}


def test_new_mark_reported_once():
    old = {"grades": {"M": [{"Id": "1", "Grade": "2", "Date": "1.9.2099"}]}}
    new = {"grades": {"M": [{"Id": "1", "Grade": "2", "Date": "1.9.2099"},
                            {"Id": "2", "Grade": "1", "Date": "2.9.2099", "Caption": "Test"}],
                      "F": [{"Grade": "3", "Date": "2.9.2099"}]}}
    assert new_marks(old, new) == ["M 1 (Test)", "F 3"]
    assert new_marks(new, new) == []


def test_marks_need_a_previous_state_and_skip_announced_ones():
    new = {"grades": {"M": [{"Id": "1", "Grade": "1"}]}}
    assert new_marks({}, new) == []  # first sync
    assert new_marks(new, {}) == []  # grades did not load this time
    planned = {"grades": {"M": [{"Id": "1", "Grade": "?"}]}}
    assert new_marks({"grades": {}}, planned) == []
    # The announced mark given later keeps its id: still a new mark.
    assert new_marks(planned, new) == ["M 1"]


def test_new_absence_only_on_known_days():
    old = {"timetable": {PAST: [_lesson(1), _lesson(2, absenceType="Absent")]}}
    new = {"timetable": {
        PAST: [_lesson(1, absenceType="Absent"), _lesson(2, absenceType="Excused",
                                                         absencetext="Omluveno")],
        # First loaded now (history week): nothing to compare with.
        "1.9.2099": [_lesson(1, absenceType="Absent")],
    }}
    assert new_absences(old, new) == ["M 29. 9., 1. hodina"]
    assert new_absences(new, new) == []


def test_new_timetable_change_from_today_on():
    old = {"timetable": {PAST: [_lesson(1)], FUTURE: [_lesson(1), _lesson(2)]}}
    new = {"timetable": {
        PAST: [_lesson(1, infoChangeCode="Removed", type="removed")],
        FUTURE: [_lesson(1), _lesson(2, infoChangeCode="Removed", type="removed")],
    }}
    assert new_changes(old, new, TODAY) == ["M 5. 10., 2. hodina: odpadá"]
    assert new_changes(new, new, TODAY) == []


def test_find_news_builds_messages():
    old = {"grades": {}, "timetable": {FUTURE: [_lesson(1)]}}
    marks = [{"Id": str(i), "Grade": "1"} for i in range(6)]
    new = {"grades": {"M": marks},
           "timetable": {FUTURE: [_lesson(1, infoChangeCode="Removed", type="removed")]}}
    news = dict(find_news(old, new, TODAY))
    assert news["new_mark"] == "Nové známky: M 1; M 1; M 1; M 1 a další (2)"
    assert news["timetable_change"] == "Změna v rozvrhu: M 5. 10., 1. hodina: odpadá"
    assert "new_absence" not in news


def test_refresh_reports_news_against_the_cache(monkeypatch, tmp_path):
    import strakalari.core.helpers as helpers_mod
    from strakalari.core.cache import save_data_cache
    from strakalari.core.refresh import run_refresh
    from tests.test_refresh_pipeline import CONFIG, FakeApp

    monkeypatch.setattr(helpers_mod, "get_user_data_dir", lambda: str(tmp_path))
    app = FakeApp([])
    app.grades = {"M": [{"Id": "7", "Grade": "1"}]}
    assert run_refresh(app, CONFIG).news == []  # first sync: nothing to compare
    save_data_cache({"grades": {}})
    assert run_refresh(app, CONFIG).news == [("new_mark", "Nová známka: M 1")]
    # Saved: the next run does not report it again.
    assert run_refresh(app, CONFIG).news == []
