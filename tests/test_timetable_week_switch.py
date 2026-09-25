"""Week switching: a page still showing the previous week is never stored."""
import json
from datetime import date, timedelta
from html import escape
from types import SimpleNamespace
from unittest.mock import MagicMock

from strakalari.core.bakalari_client import BakalariClient, _html_lesson_days


def _week_html(day: date) -> str:
    detail = {"day": f"{day.day}.{day.month}.{day.year}", "teacher": "Novák",
              "subjecttext": "Matematika", "time": "1 (8:00 - 8:45)"}
    return f'<div data-detail="{escape(json.dumps(detail))}"></div>'


def _client(page_html: str) -> BakalariClient:
    page = MagicMock()
    page.content.return_value = page_html
    bm = SimpleNamespace(page=page, random_sleep=lambda *a, **k: None)
    client = BakalariClient(bm, {"go_back_weeks": 1, "go_forward_weeks": 0,
                                 "week_switch_delay_s": 0})
    client.logged_in = True
    client._sleep_s = lambda s: None
    return client


def test_lesson_days_parsed_from_page():
    assert _html_lesson_days(_week_html(date(2026, 9, 7))) == {date(2026, 9, 7)}


def test_stale_previous_week_is_skipped():
    last_week = date.today() - timedelta(days=7)
    client = _client(_week_html(last_week))
    client.extract_timetable_html()
    assert client.timetable_sources == []


def test_target_week_is_kept():
    client = _client(_week_html(date.today()))
    client.extract_timetable_html()
    assert len(client.timetable_sources) == 1
