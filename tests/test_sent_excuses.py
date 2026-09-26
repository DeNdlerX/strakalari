"""Tests for already-sent (web) excuse sync — the legacy
``check_webpage_for_excuses`` feature reimplemented for Playwright.

Covers the pure parser (``extract_sent_excuses``), the history merge
(``excuse_history.merge_sent_excuses``) and the no-browser safety of
``sync_web_excuses_to_history``.
"""
from strakalari.core.extractors.bakalari import extract_sent_excuses
from strakalari.core.automation import Strakalari
from strakalari.core.excuse_history import merge_sent_excuses


def _detail_html(body: str) -> str:
    return (
        '<div data-testid="komens-message-detail-header">'
        f"{body}</div>"
    )


class TestExtractSentExcuses:
    def test_empty_and_none(self):
        assert extract_sent_excuses("") == []
        assert extract_sent_excuses(None) == []
        assert extract_sent_excuses([]) == []

    def test_pure_days(self):
        html = _detail_html("Od: 7.9.2026<br>Do: 9.9.2026")
        assert extract_sent_excuses(html) == [{
            "type": "pure days",
            "starting_day": "07.09.2026",
            "ending_day": "09.09.2026",
        }]

    def test_days_and_hours_yields_three_entries(self):
        html = _detail_html("Od: 10.9.2026 (2. hod.) Do: 10.9.2026 (4. hod.)")
        result = extract_sent_excuses(html)
        assert {"type": "income", "starting_day": "10.09.2026",
                "ending_day": "10.09.2026", "starting_lesson": 2,
                "ending_lesson": 4} in result
        assert {"type": "soon", "starting_day": "10.09.2026",
                "ending_day": "10.09.2026", "starting_lesson": 2,
                "ending_lesson": 4} in result
        assert {"type": "days and hours", "starting_day": "10.09.2026",
                "ending_day": "10.09.2026", "starting_lesson": 2,
                "ending_lesson": 4} in result
        assert len(result) == 3

    def test_no_match_returns_empty(self):
        html = _detail_html("Hello, this is a regular message without dates.")
        assert extract_sent_excuses(html) == []

    def test_dedupes_across_sources(self):
        html = _detail_html("Od: 7.9.2026 Do: 7.9.2026")
        assert extract_sent_excuses([html, html]) == [{
            "type": "pure days",
            "starting_day": "07.09.2026",
            "ending_day": "07.09.2026",
        }]

    def test_skips_garbage_sources(self):
        good = _detail_html("Od: 7.9.2026 Do: 8.9.2026")
        assert extract_sent_excuses(["", None, good]) == [{
            "type": "pure days",
            "starting_day": "07.09.2026",
            "ending_day": "08.09.2026",
        }]


class TestMergeSentExcuses:
    def test_adds_only_new(self):
        history = [{"type": "pure days", "starting_day": "07.09.2026",
                    "ending_day": "08.09.2026"}]
        discovered = [
            {"type": "pure days", "starting_day": "07.09.2026",
             "ending_day": "08.09.2026"},
            {"type": "pure days", "starting_day": "10.09.2026",
             "ending_day": "10.09.2026"},
        ]
        merged, added = merge_sent_excuses(history, discovered)
        assert added == 1
        assert len(merged) == 2

    def test_canonicalizes_spellings(self):
        history = [{"type": "pure days", "starting_day": "7.9.2026",
                    "ending_day": "8.9.2026"}]
        discovered = [{"type": "pure days", "starting_day": "07.09.2026",
                       "ending_day": "08.09.2026"}]
        merged, added = merge_sent_excuses(history, discovered)
        assert added == 0
        assert len(merged) == 1

    def test_strips_ui_keys_and_ignores_junk(self):
        history = []
        discovered = [
            {"type": "pure days", "starting_day": "10.09.2026",
             "ending_day": "10.09.2026", "templates": ["x"],
             "default_preview": "y"},
            "not-a-dict",
            None,
        ]
        merged, added = merge_sent_excuses(history, discovered)
        assert added == 1
        assert merged == [{"type": "pure days", "starting_day": "10.09.2026",
                           "ending_day": "10.09.2026"}]

    def test_sync_without_browser_is_noop(self, tmp_path):
        hist = tmp_path / "already_excused_lessons.json"
        hist.write_text("[]", encoding="utf-8")
        app = Strakalari(
            config_data={"already_excused_file": str(hist)},
            start_browser=False,
        )
        try:
            assert app.sync_web_excuses_to_history() == 0
        finally:
            try:
                app.close()
            except Exception:
                pass
        # History file untouched.
        assert hist.read_text(encoding="utf-8").strip() == "[]"


def test_sent_excuses_tristate():
    from strakalari.core.bakalari_client import BakalariClient

    client = BakalariClient.__new__(BakalariClient)
    client.page = None
    client.log = lambda *a: None
    client.sentExcuses = []
    client.sentExcuses_error = ""
    assert client.fetch_sent_excuses() is None
    assert client.sentExcuses_error != ""


def test_sync_treats_none_as_unknown():
    from strakalari.core.automation import Strakalari

    app = Strakalari.__new__(Strakalari)
    app.cancel_requested = False
    app.write_log = lambda *a: None

    class _Client:
        page = object()

        def fetch_sent_excuses(self, limit=100):
            return None

    app.bakalari_client = _Client()
    app.config_data = {}
    app._load_history = lambda: ([], "nowhere.json")
    assert app.sync_web_excuses_to_history() == 0


# -- real Bakaláři markup (Komens → Odeslané detail, anonymized) ---------------

from pathlib import Path

_FIXTURE = Path(__file__).parent / "fixtures" / "komens_sent_detail_hours.html"


def _real_detail() -> str:
    return _FIXTURE.read_text(encoding="utf-8")


class TestRealDetailMarkup:
    def test_hour_excuse_with_clock_times(self):
        # "Od: 3.9.2026 10:05 (3. hod.)" spread over ~800 chars of markup,
        # ~2500 chars after the header — the old HTML regex found nothing.
        assert extract_sent_excuses(_real_detail()) == [
            {"type": t, "starting_day": "03.09.2026", "ending_day": "03.09.2026",
             "starting_lesson": 3, "ending_lesson": 3}
            for t in ("income", "soon", "days and hours")
        ]

    def test_whole_day_excuse(self):
        html = _real_detail()
        for time in ("10:05", "10:50"):
            html = html.replace(f'<i class="ico20-data-hodiny bk-font-20"></i>{time}', "")
        html = html.replace('<span class="margin-left-5">(3. hod.)</span>', "")
        html = html.replace("3.9.2026 </span>", "25.9.2026 </span>")
        assert extract_sent_excuses(html) == [{
            "type": "pure days", "starting_day": "25.09.2026", "ending_day": "25.09.2026"}]

    def test_clock_times_without_lessons_learn_nothing(self):
        # Unknown lessons must never be recorded as a whole excused day.
        html = _real_detail().replace('<span class="margin-left-5">(3. hod.)</span>', "")
        assert extract_sent_excuses(html) == []

    def test_template_alone_is_not_an_excuse(self):
        template = ('<table data-testid="komens-message-detail-header"><tr '
                    'data-testid="komens-message-detail-excuse-wrapper"><td>'
                    'Od:<span> {{:DateFrom}} </span>{{:TimeFrom}}'
                    '<span>({{:HourFrom.Caption}}. hod.)</span>'
                    'Do:<span> {{:DateTo}} </span></td></tr></table>')
        assert extract_sent_excuses(template) == []
        # ...and never hides the rendered detail that follows it.
        assert extract_sent_excuses(template + _real_detail())[0]["starting_lesson"] == 3
