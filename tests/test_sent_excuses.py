"""Already-sent (web) excuses: the detail parser, the history merge and the sync.

Covers ``sent_excuse_entries`` (one ``/Komens/GetMessageDataAsync``
detail -> history entries), ``excuse_history.merge_sent_excuses`` and the
safety of ``sync_web_excuses_to_history``. All data is made up.
"""
from strakalari.core.extractors.bakalari import sent_excuse_entries
from strakalari.core.automation import Strakalari
from strakalari.core.excuse_history import merge_sent_excuses


def _detail(day_from, day_to=None, hours=None, times=("", "")):
    detail = {"Kind": "OMLUVENKA", "DateFrom": day_from, "DateTo": day_to or day_from,
              "TimeFrom": times[0], "TimeTo": times[1]}
    if hours:
        detail["HourFrom"] = {"Caption": str(hours[0])}
        detail["HourTo"] = {"Caption": str(hours[1])}
    return detail


class TestSentExcuseEntries:
    def test_lessons_yield_every_hour_shape(self):
        # One hour-based web excuse dedupes against every local shape.
        assert sent_excuse_entries(_detail("3.9.2026", hours=(3, 3), times=("10:05", "10:50"))) == [
            {"type": t, "starting_day": "03.09.2026", "ending_day": "03.09.2026",
             "starting_lesson": 3, "ending_lesson": 3}
            for t in ("income", "soon", "days and hours")
        ]

    def test_whole_days(self):
        assert sent_excuse_entries(_detail("25.9.2026", "26.9.2026")) == [{
            "type": "pure days", "starting_day": "25.09.2026", "ending_day": "26.09.2026"}]

    def test_clock_times_without_lessons_learn_nothing(self):
        # Unknown lessons must never be recorded as a whole excused day.
        assert sent_excuse_entries(_detail("3.9.2026", times=("10:05", "10:50"))) == []

    def test_other_messages_and_garbage_learn_nothing(self):
        assert sent_excuse_entries({**_detail("3.9.2026"), "Kind": "OBECNA"}) == []
        assert sent_excuse_entries({"Kind": "OMLUVENKA", "DateFrom": "nikdy"}) == []
        assert sent_excuse_entries(None) == []


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

    def test_sync_without_credentials_is_noop(self, tmp_path):
        hist = tmp_path / "already_excused_lessons.json"
        hist.write_text("[]", encoding="utf-8")
        app = Strakalari(
            config_data={"already_excused_file": str(hist)},
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

    client = BakalariClient({})  # no URL: the read fails
    client.sentExcuses = []
    assert client.fetch_sent_excuses() is None
    assert client.sentExcuses_error != ""


def test_sync_treats_none_as_unknown():
    from strakalari.core.automation import Strakalari

    app = Strakalari.__new__(Strakalari)
    app.cancel_requested = False
    app.write_log = lambda *a: None

    class _Client:
        def fetch_sent_excuses(self, limit=100):
            return None

    app.bakalari_client = _Client()
    app.config_data = {}
    app._load_history = lambda: ([], "nowhere.json")
    assert app.sync_web_excuses_to_history() == 0
