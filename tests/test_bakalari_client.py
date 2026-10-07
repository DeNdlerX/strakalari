"""BakalariClient: parsing, sent-excuse sync, stable timetable."""
from strakalari.core.automation import Strakalari


class TestGoBackWeeksRobustness:
    def test_garbage_value_falls_back(self):
        app = Strakalari(config_data={"go_back_weeks": "nonsense"})
        assert app.go_back_weeks == 4
        app.close()

    def test_extreme_value_is_clamped(self):
        app = Strakalari(config_data={"go_back_weeks": 10 ** 9})
        assert app.go_back_weeks <= 52
        app.close()


def test_substitutions_init_is_unknown():
    from strakalari.core.bakalari_client import BakalariClient
    client = BakalariClient({}, logger=lambda m: None)
    assert client.substitutions is None


def test_unparseable_outbox_is_unknown_not_empty():
    import httpx

    from tests.fake_bakalari import client as fake_client
    from tests.test_bakalari_http import OUTBOX_PAGE, outbox_listing

    client, _ = fake_client({
        ("GET", "/next/komens.aspx"): OUTBOX_PAGE,
        ("POST", "/next/komens.aspx"): outbox_listing(["501"]),
        ("POST", "/Komens/GetMessageDataAsync"): httpx.Response(500),
    })
    client.sentExcuses = [{"old": 1}]
    client.sentExcuses_error = ""
    assert client.fetch_sent_excuses() is None
    assert client.sentExcuses is None
    assert client.sentExcuses_error != ""


def test_hour_index_fallback_never_invents_period_zero():
    from strakalari.core.bakalari_client import parse_timetable_detail
    base = {"teacher": "T", "subjecttext": "M", "day": "07.09.2026",
            "time": "bez čísla"}
    assert "period" not in parse_timetable_detail({**base, "hourIndex": 2})
    assert parse_timetable_detail({**base, "hourIndex": 3})["period"] == 1


def test_add_timetable_details():
    from strakalari.core.automation import Strakalari
    bot = Strakalari(config_data={"strava_enable": False})

    bot.bakalari_client.add_timetable_details([
        {"teacher": "Mgr. Jan Novák", "subjecttext": "Matematika", "subjectshort": "M", "room": "U1",
         "day": "10.09.2026", "time": "2 (8:55 - 9:40)", "absencetext": "Absence", "absenceType": "Absent"},
        {"teacher": "Mgr. Eva Bílá", "subjecttext": "Fyzika", "subjectshort": "FY", "room": "L1",
         "day": "10.09.2026", "time": "1 (8:00 - 8:45)", "absencetext": "", "absenceType": ""},
        # Entry with missing teacher should be skipped
        {"teacher": "", "subjecttext": "Volná hodina", "day": "10.09.2026", "time": "3"},
    ])

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

    bot = Strakalari(config_data={"strava_enable": False})
    assert bot.go_forward_weeks == 1
    assert bot.bakalari_client.go_forward_weeks == 1

    client = BakalariClient({"go_forward_weeks": 3}, logger=None)
    assert client.go_forward_weeks == 3
    client = BakalariClient({"go_forward_weeks": 99}, logger=None)
    assert client.go_forward_weeks <= 8
    client = BakalariClient({"go_forward_weeks": "nonsense"}, logger=None)
    assert client.go_forward_weeks == 1


def test_no_stable_view_means_no_baseline():
    """Nothing is learned from actual weeks: Bakaláři's own flags decide."""
    from strakalari.core.bakalari_client import BakalariClient

    client = BakalariClient({}, logger=None)
    week = lambda teacher, **extra: [  # noqa: E731
        {"teacher": "Novák", "subject": "M", "room": "U12", "time": "1 (8:00 - 8:45)"},
        {"teacher": teacher, "subject": "F", "room": "F11", "time": "2 (8:55 - 9:40)", **extra},
    ]
    client.timetableData = {
        "31.08.2026": week("Dvořák"),
        "07.09.2026": week("Dvořák"),
        "14.09.2026": week("Král", infoChangeCode="Substitution"),
    }
    assert client.update_stable_baseline() == {}
    assert client.stable_complete is False
    assert [c["day_key"] for c in client.weekChanges] == ["14.09.2026"]


def test_scraped_stable_is_the_baseline():
    from strakalari.core.bakalari_client import BakalariClient

    client = BakalariClient({}, logger=None)
    # Actual weeks all agree on Král...
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


def test_add_timetable_details_into_separate_target():
    from strakalari.core.bakalari_client import BakalariClient

    client = BakalariClient({}, logger=None)
    stable: dict = {}
    client.add_timetable_details([{"teacher": "Novák", "subjecttext": "M", "day": "07.09.2026",
                                   "time": "1 (8:00 - 8:45)"}], target=stable)
    assert client.timetableData == {}
    assert "07.09.2026" in stable
    assert stable["07.09.2026"][0]["subject"] == "M"


_FIXTURES = __import__("pathlib").Path(__file__).parent / "fixtures"


def _details(name):
    """Lesson details of a timetable view (anonymized fixture)."""
    import json

    return json.loads((_FIXTURES / name).read_text(encoding="utf-8"))


def _stable_client(perm_reply):
    """Client whose server answers the stable ("perm") view with ``perm_reply``."""
    import json

    from tests.fake_bakalari import client as fake_client, week_content

    def content(request):
        term = json.loads(request.content)["term"]
        return week_content(perm_reply if term == "perm" else _details("timetable_actual_week.json"))

    client, server = fake_client({("POST", "/Timetable/GetContentData"): content})
    return client, server


def test_perm_view_is_told_apart_by_ident_code():
    from strakalari.core.bakalari_timetable import is_perm_view

    perm = _details("timetable_perm_view.json")
    actual = _details("timetable_actual_week.json")
    assert is_perm_view(perm) is True
    assert is_perm_view(actual) is False
    assert is_perm_view(perm + actual) is False  # mixed reply
    assert is_perm_view([]) is False


def test_extract_stable_timetable_scrapes_perm_view():
    import json

    client, server = _stable_client(_details("timetable_perm_view.json"))
    assert client.extract_stable_timetable() is True
    # Asks for exactly the stable ("perm") view.
    [request] = server.calls("POST", "/Timetable/GetContentData")
    assert json.loads(request.content)["term"] == "perm"
    # Stable rows land in their own dict, actual weeks untouched.
    assert client.timetableData == {}
    baseline = client.update_stable_baseline()
    assert client.stable_complete is True
    assert baseline[(0, 1)].subject == "Seminář z matematiky S"
    assert baseline[(4, 7)].subject == "Finanční gramotnost"
    # Odd/even-week PE (two gyms) keeps both variants in one slot.
    assert {v.room.split()[0] for v in baseline[(2, 5)]} == {"TSOU", "TSM"}


def test_extract_stable_timetable_rejects_stale_actual_week():
    """An actual week coming back must not turn into "stable"."""
    client, _ = _stable_client(_details("timetable_actual_week.json"))
    assert client.extract_stable_timetable() is False
    assert client.stableTimetableData == {}
    assert client.update_stable_baseline() == {}
