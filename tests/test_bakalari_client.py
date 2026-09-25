"""BakalariClient: parsing, sent-excuse sync, excuse form flow."""
from strakalari.core.automation import Strakalari
from unittest.mock import MagicMock


class TestGoBackWeeksRobustness:
    def test_garbage_value_falls_back(self):
        app = Strakalari(config_data={"go_back_weeks": "nonsense"}, start_browser=False)
        assert app.go_back_weeks == 4
        app.close()

    def test_extreme_value_is_clamped(self):
        app = Strakalari(config_data={"go_back_weeks": 10 ** 9}, start_browser=False)
        assert app.go_back_weeks <= 52
        app.close()


def test_execute_excuse_submits_after_fill():
    from strakalari.core.bakalari_client import BakalariClient

    client = BakalariClient.__new__(BakalariClient)
    calls = []
    client.fill_excuse_form = lambda *a, **k: calls.append((a, k)) or True
    client._verify_submission = lambda: calls.append("submit") or True
    assert client.execute_excuse("01.09.2026", "01.09.2026", is_days=True) is True
    assert calls[-1] == "submit"


def test_substitutions_init_is_unknown():
    from strakalari.core.bakalari_client import BakalariClient
    client = BakalariClient(MagicMock(), {}, logger=lambda m: None)
    assert client.substitutions is None


def test_unparseable_outbox_is_unknown_not_empty():
    from strakalari.core.bakalari_client import BakalariClient

    client = BakalariClient(MagicMock(), {}, logger=lambda m: None)
    client.login = lambda: True
    client._sleep_s = lambda s: None
    client.sentExcuses = [{"old": 1}]
    client.sentExcuses_error = ""
    page = MagicMock()
    page.content.return_value = "<html><body>nečitelné</body></html>"
    page.locator.return_value.count.return_value = 1
    client.page = page
    assert client.fetch_sent_excuses() is None
    assert client.sentExcuses is None
    assert client.sentExcuses_error != ""


def test_data_detail_with_apostrophe_parses():
    from strakalari.core.bakalari_client import BakalariClient
    client = BakalariClient(MagicMock(), {}, logger=lambda m: None)
    html = (
        "<div data-detail='{\"teacher\":\"O'Neil\",\"subjecttext\":\"M\","
        "\"day\":\"07.09.2026\",\"time\":\"1 (8:00 - 8:45)\"}'></div>"
    )
    client.extract_timetable_data(html)
    assert "07.09.2026" in client.timetableData
    assert client.timetableData["07.09.2026"][0]["teacher"] == "O'Neil"


def test_hour_index_fallback_never_invents_period_zero():
    from strakalari.core.bakalari_client import parse_timetable_detail
    base = {"teacher": "T", "subjecttext": "M", "day": "07.09.2026",
            "time": "bez čísla"}
    assert "period" not in parse_timetable_detail({**base, "hourIndex": 2})
    assert parse_timetable_detail({**base, "hourIndex": 3})["period"] == 1


def test_extract_timetable_data():
    from strakalari.core.automation import Strakalari
    bot = Strakalari(config_data={"strava_enable": False}, start_browser=False)

    sample_html = """
    <div data-detail='{"teacher":"Mgr. Jan Novák","subjecttext":"Matematika","subjectshort":"M","room":"U1","day":"10.09.2026","time":"2 (8:55 - 9:40)","absencetext":"Absence","absenceType":"Absent"}'></div>
    <div data-detail='{"teacher":"Mgr. Eva Bílá","subjecttext":"Fyzika","subjectshort":"FY","room":"L1","day":"10.09.2026","time":"1 (8:00 - 8:45)","absencetext":"","absenceType":""}'></div>
    <!-- Entry with missing teacher should be skipped -->
    <div data-detail='{"teacher":"","subjecttext":"Volná hodina","day":"10.09.2026","time":"3"}'></div>
    """
    bot.bakalari_client.extract_timetable_data(sample_html)

    assert "10.09.2026" in bot.timetableData
    lessons = bot.timetableData["10.09.2026"]
    assert len(lessons) == 2
    # Verify sorted by lesson time (Period 1 should come before Period 2)
    assert lessons[0]["subject"] == "Fyzika"
    assert lessons[1]["subject"] == "Matematika"
    assert lessons[1]["absenceType"] == "Absent"


def test_week_offsets_cover_forward_and_back():
    from strakalari.core.bakalari_client import week_offsets

    # Default config: 4 back (incl. current) + 1 forward = next week first.
    assert week_offsets(4, 1) == [1, 0, -1, -2, -3]
    # Old behavior without forward weeks is unchanged.
    assert week_offsets(4, 0) == [0, -1, -2, -3]
    assert week_offsets(1, 2) == [2, 1, 0]
    assert week_offsets(0, 0) == []
    assert week_offsets("nonsense", None) == []


def test_go_forward_weeks_config_parsing():
    from strakalari.core.automation import Strakalari
    from strakalari.core.bakalari_client import BakalariClient

    bot = Strakalari(config_data={"strava_enable": False}, start_browser=False)
    assert bot.go_forward_weeks == 1
    assert bot.bakalari_client.go_forward_weeks == 1

    dummy_bm = type("DummyBM", (), {"page": None})()
    client = BakalariClient(dummy_bm, {"go_forward_weeks": 3}, logger=None)
    assert client.go_forward_weeks == 3
    client = BakalariClient(dummy_bm, {"go_forward_weeks": 99}, logger=None)
    assert client.go_forward_weeks <= 8
    client = BakalariClient(dummy_bm, {"go_forward_weeks": "nonsense"}, logger=None)
    assert client.go_forward_weeks == 1


def test_update_stable_baseline_learns_and_diffs():
    from strakalari.core.bakalari_client import BakalariClient

    dummy_bm = type("DummyBM", (), {"page": None})()
    client = BakalariClient(dummy_bm, {}, logger=None)
    client.timetableData = {
        "31.08.2026": [
            {"teacher": "Novák", "subject": "M", "room": "U12",
             "time": "1 (8:00 - 8:45)"},
            {"teacher": "Dvořák", "subject": "F", "room": "F11",
             "time": "2 (8:55 - 9:40)"},
        ],
        "07.09.2026": [
            {"teacher": "Novák", "subject": "M", "room": "U12",
             "time": "1 (8:00 - 8:45)"},
            {"teacher": "Dvořák", "subject": "F", "room": "F11",
             "time": "2 (8:55 - 9:40)"},
        ],
        # Next week (forward fetch): same slots, one substitution.
        "14.09.2026": [
            {"teacher": "Novák", "subject": "M", "room": "U12",
             "time": "1 (8:00 - 8:45)"},
            {"teacher": "Král", "subject": "F", "room": "F11",
             "time": "2 (8:55 - 9:40)", "notice": "Suplování (Král)"},
        ],
    }
    baseline = client.update_stable_baseline()
    assert baseline[(0, 2)].teacher == "Dvořák"
    assert len(client.weekChanges) == 1
    assert client.weekChanges[0]["day_key"] == "14.09.2026"
    assert "teacher" in client.weekChanges[0]["diff"].changed


def test_scraped_stable_beats_learned_baseline():
    from strakalari.core.bakalari_client import BakalariClient

    dummy_bm = type("DummyBM", (), {"page": None})()
    client = BakalariClient(dummy_bm, {}, logger=None)
    # Actual weeks all agree on Král — learning alone would call that stable.
    week = lambda: [  # noqa: E731
        {"teacher": "Král", "subject": "F", "room": "F11",
         "time": "2 (8:55 - 9:40)"},
    ]
    client.timetableData = {
        "31.08.2026": week(), "07.09.2026": week(), "14.09.2026": week(),
    }
    # ... but the scraped "Stálý rozvrh" says the slot is Dvořák's.
    client.stableTimetableData = {
        "Pondělí": [
            {"teacher": "Dvořák", "subject": "F", "room": "F11",
             "time": "2 (8:55 - 9:40)"},
        ],
    }
    baseline = client.update_stable_baseline()
    assert baseline[(0, 2)].teacher == "Dvořák"
    # Every actual week now diffs against the true stable.
    assert len(client.weekChanges) == 3
    assert all("teacher" in item["diff"].changed
               for item in client.weekChanges)


def test_extract_timetable_data_into_separate_target():
    from strakalari.core.bakalari_client import BakalariClient

    dummy_bm = type("DummyBM", (), {"page": None})()
    client = BakalariClient(dummy_bm, {}, logger=None)
    html = (
        "<div data-detail='{\"teacher\":\"Novák\",\"subjecttext\":\"M\","
        "\"day\":\"07.09.2026\",\"time\":\"1 (8:00 - 8:45)\"}'></div>"
    )
    stable: dict = {}
    client.extract_timetable_data(html, target=stable)
    assert client.timetableData == {}
    assert "07.09.2026" in stable
    assert stable["07.09.2026"][0]["subject"] == "M"


def test_open_stable_view_targets_perm_exactly():
    from strakalari.core.bakalari_client import BakalariClient

    class MockLocator:
        def __init__(self, page, selector):
            self._page = page
            self._selector = selector

        @property
        def first(self):
            return self

        def wait_for(self, **kwargs):
            if self._selector in self._page.missing:
                raise Exception(f"not visible: {self._selector}")

        def click(self, **kwargs):
            self._page.clicked.append(self._selector)

    class MockPage:
        def __init__(self, html="", missing=()):
            self._html = html
            self.missing = set(missing)
            self.clicked = []

        def locator(self, selector):
            return MockLocator(self, selector)

        def get_by_text(self, *args, **kwargs):
            return MockLocator(self, "get_by_text")

        def wait_for_function(self, *args, **kwargs):
            pass

        def wait_for_load_state(self, *args, **kwargs):
            pass

        def wait_for_timeout(self, *args, **kwargs):
            pass

        def content(self):
            return self._html

    def make_client(**kwargs):
        page = MockPage(**kwargs)
        bm = type("MockBM", (), {"page": page})()
        return BakalariClient(bm, {}, logger=None), page

    # Desktop switcher: clicks ONLY the perm label, nothing else.
    client, page = make_client()
    assert client._open_stable_view() == "testid:timetable-permanent-link"
    assert page.clicked == [
        'label:has(input[data-testid="timetable-permanent-link"])']

    # Desktop missing: falls back to the small-screen perm variant.
    client, page = make_client(missing={
        'label:has(input[data-testid="timetable-permanent-link"])'})
    assert (client._open_stable_view()
            == "testid:timetable-small-permanent-link")

    # Nothing found: "" (callers fall back to the learned baseline).
    client, page = make_client(missing={
        'label:has(input[data-testid="timetable-permanent-link"])',
        'label:has(input[data-testid="timetable-small-permanent-link"])',
        '[data-bind*="SelectedTerm() === \'perm\'"]',
        "get_by_text"})
    assert client._open_stable_view() == ""
    assert page.clicked == []


def test_extract_stable_timetable_scrapes_perm_view():
    from strakalari.core.bakalari_client import BakalariClient

    html = (
        "<div data-detail='{\"teacher\":\"Dvořák\","
        "\"subjecttext\":\"F\",\"room\":\"F11\",\"day\":\"Pondělí\","
        "\"time\":\"2 (8:55 - 9:40)\"}'></div>"
    )

    class MockLabel:
        def __init__(self, page):
            self._page = page

        @property
        def first(self):
            return self

        def wait_for(self, **kwargs):
            pass

        def click(self, **kwargs):
            self._page.clicked.append(True)

    class MockPage:
        clicked: list = []

        def locator(self, selector):
            return MockLabel(self)

        def get_by_text(self, *args, **kwargs):
            return MockLabel(self)

        def wait_for_function(self, *args, **kwargs):
            pass

        def wait_for_load_state(self, *args, **kwargs):
            pass

        def wait_for_timeout(self, *args, **kwargs):
            pass

        def content(self):
            return html

    page = MockPage()
    bm = type("MockBM", (), {"page": page})()
    client = BakalariClient(bm, {}, logger=None)
    assert client.extract_stable_timetable() is True
    # Stable rows land in their own dict, actual weeks untouched.
    assert client.timetableData == {}
    assert "Pondělí" in client.stableTimetableData
    lesson = client.stableTimetableData["Pondělí"][0]
    assert lesson["subject"] == "F"
    assert lesson["teacher"] == "Dvořák"
    # ... and the scraped view feeds the baseline with weekday names.
    baseline = client.update_stable_baseline()
    assert baseline[(0, 2)].teacher == "Dvořák"
