"""Week loading: a reply showing another week is never stored."""
from datetime import date, timedelta

from strakalari.core.bakalari_common import _detail_days
from tests.fake_bakalari import client as fake_client, week_content


def _lesson(day: date) -> dict:
    return {"day": f"{day.day}.{day.month}.{day.year}", "teacher": "Novák",
            "subjecttext": "Matematika", "time": "1 (8:00 - 8:45)"}


def _client(day: date):
    """Client whose server answers every week with a lesson on ``day``."""
    client, _ = fake_client({("POST", "/Timetable/GetContentData"): week_content([_lesson(day)])},
                            go_back_weeks=1, go_forward_weeks=0)
    return client


def test_lesson_days_parsed_from_details():
    assert _detail_days([_lesson(date(2026, 9, 7))]) == {date(2026, 9, 7)}


def test_stale_previous_week_is_skipped():
    client = _client(date.today() - timedelta(days=7))
    client.fetch_timetable_weeks()
    assert client.timetable_sources == []


def test_target_week_is_kept():
    client = _client(date.today())
    client.fetch_timetable_weeks()
    assert len(client.timetable_sources) == 1
