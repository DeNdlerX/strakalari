"""Submits the site never confirmed must never turn into a duplicate excuse.

A send click can go out and the page then stall (slow link): the excuse
may or may not have arrived. Such a submit is recorded in a sidecar next
to the history, blocks every re-send, and is settled only by a
successfully read Komens outbox. Without that read, auto mode must not
send at all.
"""

import json
from datetime import date, datetime, timedelta
from unittest.mock import MagicMock

from strakalari.core.automation import Strakalari
from strakalari.core.excuse_history import (
    UNCONFIRMED_MIN_AGE,
    load_unconfirmed,
    resolve_unconfirmed,
    unconfirmed_blocks,
    unconfirmed_entry,
    unconfirmed_path,
)
from strakalari.core.refresh import run_refresh

LESSON = {"type": "days and hours", "starting_day": "21.09.2026", "ending_day": "21.09.2026",
          "starting_lesson": 3, "ending_lesson": 4}
DAY = {"type": "pure days", "starting_day": "22.09.2026", "ending_day": "22.09.2026"}
NOW = datetime(2026, 9, 25, 12, 0)


# -- pure helpers -----------------------------------------------------------------

class TestHelpers:
    def test_sidecar_sits_next_to_history(self):
        assert unconfirmed_path("/d/already_excused_lessons.json") == \
            "/d/already_excused_lessons.unconfirmed.json"

    def test_overlap_blocks_even_a_partial_resend(self):
        pending = [unconfirmed_entry(LESSON, NOW)]
        assert unconfirmed_blocks(dict(LESSON), pending)
        assert unconfirmed_blocks({**LESSON, "starting_lesson": 4, "ending_lesson": 4}, pending)
        assert not unconfirmed_blocks({**LESSON, "starting_lesson": 6, "ending_lesson": 6}, pending)
        assert not unconfirmed_blocks(DAY, pending)

    def test_whole_day_blocks_its_lessons(self):
        pending = [unconfirmed_entry(DAY, NOW)]
        assert unconfirmed_blocks({**LESSON, "starting_day": "22.09.2026",
                                   "ending_day": "22.09.2026"}, pending)

    def test_resolve(self):
        old = NOW - UNCONFIRMED_MIN_AGE - timedelta(minutes=1)
        sent = unconfirmed_entry(LESSON, old)
        lost = unconfirmed_entry(DAY, old)
        fresh = unconfirmed_entry({**DAY, "starting_day": "23.09.2026",
                                   "ending_day": "23.09.2026"}, NOW)
        history = [dict(LESSON)]
        still, confirmed, not_sent = resolve_unconfirmed(
            [sent, lost, fresh], history, date(2026, 8, 26), now=NOW)
        assert confirmed == [sent]
        assert not_sent == [lost]
        assert still == [fresh]

    def test_submit_before_the_outbox_range_stays_open(self):
        old = unconfirmed_entry(DAY, datetime(2026, 8, 1, 9, 0))
        still, confirmed, not_sent = resolve_unconfirmed([old], [], date(2026, 8, 26), now=NOW)
        assert still == [old] and not confirmed and not not_sent


# -- the send path ------------------------------------------------------------------

def _app(tmp_path, uncertain=True):
    app = Strakalari.__new__(Strakalari)
    app.excuse_mode = "auto"
    app.encoding = "utf-8"
    app.already_excused_file = str(tmp_path / "history.json")
    app.config_data = {}
    app.cancel_requested = False
    app.logs = []
    app.write_log = app.logs.append
    client = MagicMock()

    def _execute(*a, **k):
        client.last_submit_uncertain = uncertain
        return False

    client.execute_excuse.side_effect = _execute
    app.bakalari_client = client
    return app, client


class TestSendPath:
    def test_uncertain_submit_is_recorded_not_failed(self, tmp_path):
        app, client = _app(tmp_path)
        assert app._send_excuse(dict(LESSON), "x") == "unconfirmed"
        pending = load_unconfirmed(app.already_excused_file)
        assert len(pending) == 1 and pending[0]["starting_lesson"] == 3
        assert not (tmp_path / "history.json").exists()

    def test_unconfirmed_blocks_the_next_send(self, tmp_path):
        app, client = _app(tmp_path)
        app._send_excuse(dict(LESSON), "x")
        assert app._send_excuse(dict(LESSON), "x") == "skipped"
        assert client.execute_excuse.call_count == 1

    def test_certain_failure_is_retryable(self, tmp_path):
        app, client = _app(tmp_path, uncertain=False)
        assert app._send_excuse(dict(LESSON), "x") == "failed"
        assert load_unconfirmed(app.already_excused_file) == []
        assert app._send_excuse(dict(LESSON), "x") == "failed"
        assert client.execute_excuse.call_count == 2

    def test_sidecar_write_failure_falls_back_to_history(self, tmp_path, monkeypatch):
        import strakalari.core.automation as automation

        def _boom(*a, **k):
            raise OSError("disk full")

        monkeypatch.setattr(automation, "save_unconfirmed", _boom)
        app, client = _app(tmp_path)
        assert app._send_excuse(dict(LESSON), "x") == "unconfirmed"
        history = json.loads((tmp_path / "history.json").read_text(encoding="utf-8"))
        assert any(h["type"] == "days and hours" and h["starting_lesson"] == 3 for h in history)
        assert app._send_excuse(dict(LESSON), "x") == "covered"

    def test_auto_counts_a_new_unconfirmed_as_a_failure(self, tmp_path, monkeypatch):
        app, client = _app(tmp_path)
        monkeypatch.setattr(Strakalari, "generate_excuses", staticmethod(lambda *a, **k: [dict(LESSON)]))
        monkeypatch.setattr(Strakalari, "default_excuse_text", lambda self, e: "x")
        app.excuse_delay_days = 0
        assert app.excuse_pending() == 0
        assert app.last_excuse_failures == 1


# -- outbox settles it ----------------------------------------------------------------

def _seed(app, entry):
    with open(unconfirmed_path(app.already_excused_file), "w", encoding="utf-8") as f:
        json.dump([entry], f)


class TestOutboxSettles:
    def _sync_app(self, tmp_path, discovered):
        app, client = _app(tmp_path)
        client.page = object()
        client.fetch_sent_excuses.return_value = discovered
        client.sentExcuses_from = date(2026, 8, 26)
        return app

    def test_found_in_outbox_is_confirmed(self, tmp_path):
        app = self._sync_app(tmp_path, [dict(LESSON)])
        _seed(app, unconfirmed_entry(LESSON, datetime.now()))
        app.sync_web_excuses_to_history()
        assert app.last_outbox_sync_ok is True
        assert load_unconfirmed(app.already_excused_file) == []

    def test_absent_from_outbox_after_grace_is_released(self, tmp_path):
        app = self._sync_app(tmp_path, [])
        _seed(app, unconfirmed_entry(LESSON, datetime.now() - timedelta(hours=1)))
        app.sync_web_excuses_to_history()
        assert app.last_outbox_sync_ok is True
        assert load_unconfirmed(app.already_excused_file) == []
        assert any("NOT sent" in m for m in app.logs)

    def test_fresh_submit_is_kept(self, tmp_path):
        app = self._sync_app(tmp_path, [])
        _seed(app, unconfirmed_entry(LESSON, datetime.now()))
        app.sync_web_excuses_to_history()
        assert len(load_unconfirmed(app.already_excused_file)) == 1

    def test_failed_read_settles_nothing(self, tmp_path):
        app = self._sync_app(tmp_path, None)
        _seed(app, unconfirmed_entry(LESSON, datetime.now() - timedelta(hours=1)))
        app.sync_web_excuses_to_history()
        assert app.last_outbox_sync_ok is False
        assert len(load_unconfirmed(app.already_excused_file)) == 1


# -- refresh gate -------------------------------------------------------------------

class _GateApp:
    strava_enable = False
    excuse_mode = "auto"
    strava_order_mode = "confirm"

    def __init__(self, outbox_ok):
        self.calls = []
        self._ok = outbox_ok
        self.last_outbox_sync_ok = False
        self.timetableData = {"1.9.2099": [{"subject": "M"}]}
        self.absencePercentages = {"M": 2.0}
        self.grades = {}
        self.stableBaseline = {}
        self.absenceDetails = {}
        self.subjectDirectory = {}
        self.bakalari_client = None
        self.strava_client = None

    def fetch_bakalari_data(self):
        self.calls.append("bakalari")

    def sync_web_excuses_to_history(self):
        self.last_outbox_sync_ok = self._ok
        return 0

    def excuse_pending(self):
        self.calls.append("excuse")
        return 0


class TestRefreshGate:
    CONFIG = {"bakalari_url": "https://bakalari.test", "bakalari_username": "student"}

    def test_no_auto_excuse_without_an_outbox_read(self, monkeypatch, tmp_path):
        import strakalari.core.helpers as helpers_mod

        monkeypatch.setattr(helpers_mod, "get_user_data_dir", lambda: str(tmp_path))
        app = _GateApp(outbox_ok=False)
        result = run_refresh(app, self.CONFIG)
        assert "excuse" not in app.calls
        assert any(phase == "auto_excuse" for phase, _ in result.errors)

    def test_auto_excuse_runs_after_an_outbox_read(self, monkeypatch, tmp_path):
        import strakalari.core.helpers as helpers_mod

        monkeypatch.setattr(helpers_mod, "get_user_data_dir", lambda: str(tmp_path))
        app = _GateApp(outbox_ok=True)
        run_refresh(app, self.CONFIG)
        assert "excuse" in app.calls
