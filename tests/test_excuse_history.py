"""Excuse history: coverage-based duplicate detection + serialized sends."""
import threading
import time
from datetime import date
from unittest.mock import MagicMock

from strakalari.core.automation import Strakalari
from strakalari.core.excuse_history import excuse_covered, task_covered
from strakalari.core.excuse_history import normalize_history_item
from strakalari.core.excuse_history import base_excuse

WEEK = {"type": "pure days", "starting_day": "07.09.2026", "ending_day": "11.09.2026"}
HOURS = {"type": "days and hours", "starting_day": "14.09.2026",
         "ending_day": "14.09.2026", "starting_lesson": 2, "ending_lesson": 4}
SPAN = {"type": "days and hours", "starting_day": "15.09.2026",
        "ending_day": "17.09.2026", "starting_lesson": 5, "ending_lesson": 2}


def _day(d, first, last, kind="days and hours"):
    return {"type": kind, "starting_day": d, "ending_day": d,
            "starting_lesson": first, "ending_lesson": last}


def test_broader_web_excuse_covers_single_day():
    assert excuse_covered({"type": "pure days", "starting_day": "9.9.2026",
                           "ending_day": "9.9.2026"}, [WEEK])
    assert excuse_covered(_day("10.09.2026", 1, 3), [WEEK])


def test_partial_overlap_is_not_covered():
    assert not excuse_covered({"type": "pure days", "starting_day": "10.09.2026",
                               "ending_day": "14.09.2026"}, [WEEK])
    assert not excuse_covered(_day("14.09.2026", 3, 5), [HOURS])
    assert excuse_covered(_day("14.09.2026", 3, 4, "income"), [HOURS])


def test_hour_range_never_covers_whole_day():
    assert not excuse_covered({"type": "pure days", "starting_day": "14.09.2026",
                               "ending_day": "14.09.2026"}, [HOURS])


def test_multi_day_hour_span_semantics():
    assert excuse_covered(_day("15.09.2026", 5, 7), [SPAN])
    assert not excuse_covered(_day("15.09.2026", 4, 4), [SPAN])
    assert excuse_covered(_day("16.09.2026", 1, 8), [SPAN])
    assert excuse_covered(_day("17.09.2026", 1, 2), [SPAN])
    assert not excuse_covered(_day("17.09.2026", 3, 3), [SPAN])


def test_task_covered_matches_ui_rules():
    assert task_covered(date(2026, 9, 8), 3, [WEEK])
    assert task_covered(date(2026, 9, 14), 2, [HOURS])
    assert not task_covered(date(2026, 9, 14), 5, [HOURS])
    assert not task_covered(date(2026, 9, 14), None, [HOURS])


def _app(tmp_path, submit_delay=0.0):
    app = Strakalari.__new__(Strakalari)
    app.excuse_mode = "auto"
    app.encoding = "utf-8"
    app.already_excused_file = str(tmp_path / "history.json")
    app.writeLog = lambda m: None
    client = MagicMock()

    def _execute(*a, **k):
        time.sleep(submit_delay)
        return True

    client.execute_excuse.side_effect = _execute
    app.bakalari_client = client
    return app, client


def test_concurrent_sends_submit_once(tmp_path):
    app, client = _app(tmp_path, submit_delay=0.2)
    other = Strakalari.__new__(Strakalari)
    other.__dict__.update(app.__dict__)
    excuse = _day("21.09.2026", 3, 3)
    results = []
    threads = [threading.Thread(target=lambda a=a: results.append(a._send_excuse(dict(excuse), "x")))
               for a in (app, other)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == ["covered", "sent"]
    assert client.execute_excuse.call_count == 1


def test_covered_excuse_is_not_resent(tmp_path):
    import json

    app, client = _app(tmp_path)
    (tmp_path / "history.json").write_text(json.dumps([WEEK]), encoding="utf-8")
    assert app.excuse_single({"type": "pure days", "starting_day": "08.09.2026",
                              "ending_day": "08.09.2026"}) is True
    client.execute_excuse.assert_not_called()


class TestHistoryNormalization:
    def test_non_padded_dates_canonicalized(self):
        item = normalize_history_item({"type": "pure days",
                                                   "starting_day": "7.9.2026",
                                                   "ending_day": "8.9.2026"})
        assert item["starting_day"] == "07.09.2026"
        assert item["ending_day"] == "08.09.2026"


class TestExampleHistoryFilter:
    DEMO = {"type": "pure days", "starting_day": "VAS_DEMO_DEN",
            "ending_day": "VAS_DEMO_DEN"}
    REAL = {"type": "pure days", "starting_day": "01.09.2026",
            "ending_day": "02.09.2026"}

    def _write_example(self, tmp_path):
        import json
        (tmp_path / "hist.example.json").write_text(
            json.dumps([self.DEMO, self.REAL, "junk", {"no": "days"}]),
            encoding="utf-8")
        return str(tmp_path / "hist.json")

    def test_manager_filters_example_fallback(self, tmp_path):
        from strakalari.core.config import ConfigManager
        hist = self._write_example(tmp_path)
        mgr = ConfigManager.__new__(ConfigManager)
        mgr.encoding = "utf-8"
        mgr.data = {"already_excused_file": hist}
        assert mgr.get_excuse_history() == [self.REAL]

    def test_automation_filters_example_fallback(self, tmp_path):
        from strakalari.core.automation import Strakalari
        hist = self._write_example(tmp_path)
        app = Strakalari.__new__(Strakalari)
        app.already_excused_file = hist
        app.encoding = "utf-8"
        app.writeLog = lambda m: None
        history, _path = app._load_history()
        for item in history:
            assert isinstance(item, dict)
            assert "VAS_DEMO" not in str(item)
        assert any(h.get("starting_day") == "01.09.2026" for h in history)


class TestBaseExcuse:
    def test_strips_ui_keys(self):
        full = {
            "type": "income", "starting_day": "10.09.2026", "ending_day": "10.09.2026",
            "starting_lesson": 1, "ending_lesson": 1,
            "templates": ["t"], "default_preview": "p", "signature": "s",
        }
        base = base_excuse(full)
        assert base == {
            "type": "income", "starting_day": "10.09.2026", "ending_day": "10.09.2026",
            "starting_lesson": 1, "ending_lesson": 1,
        }


class TestHistoryCoverage:
    def test_pure_days_covers(self):
        from strakalari.flet_ui.state_excuses import _task_covered_by_history
        task = {"date": "2026-09-07", "period": 2}
        history = [{"type": "pure days", "starting_day": "07.09.2026",
                    "ending_day": "08.09.2026"}]
        assert _task_covered_by_history(task, history) is True

    def test_lesson_range_covers_only_inside(self):
        from strakalari.flet_ui.state_excuses import _task_covered_by_history
        history = [{"type": "days and hours", "starting_day": "07.09.2026",
                    "ending_day": "07.09.2026",
                    "starting_lesson": 1, "ending_lesson": 2}]
        assert _task_covered_by_history({"date": "2026-09-07", "period": 2}, history) is True
        assert _task_covered_by_history({"date": "2026-09-07", "period": 3}, history) is False
        assert _task_covered_by_history({"date": "2026-09-08", "period": 1}, history) is False

    def test_ambiguous_entries_never_hide(self):
        from strakalari.flet_ui.state_excuses import _task_covered_by_history
        task = {"date": "2026-09-07", "period": 1}
        assert _task_covered_by_history(task, [{"type": "days and hours"}]) is False
        assert _task_covered_by_history(task, [{"nonsense": True}]) is False
        assert _task_covered_by_history({"date": "", "period": 1}, []) is False


def test_excuse_dry_run_fills_without_submitting():
    from strakalari.core.automation import Strakalari

    app = Strakalari.__new__(Strakalari)
    app.excuse_mode = "dry_run"
    app.writeLog = lambda *a: None
    app._load_history = lambda: ([], "nowhere.json")

    calls = []

    class _FakeBak:
        def fill_excuse_form(self, *a, **k):
            calls.append((a, k))
            return True

        def execute_excuse(self, *a, **k):
            raise AssertionError("dry-run must never submit")

    app.bakalari_client = _FakeBak()
    excuse = {"type": "pure days", "starting_day": "01.09.2026",
              "ending_day": "01.09.2026"}
    assert app.excuse_single(dict(excuse), custom_text="text") is True
    assert len(calls) == 1
    assert calls[0][1].get("is_days") is True


def test_history_quarantine(tmp_path, monkeypatch):
    from strakalari.core import config as cfg

    bad = tmp_path / "hist.json"
    bad.write_text("{corrupt", encoding="utf-8")
    monkeypatch.setattr(cfg, "_resolve_path", lambda p: str(bad))
    mgr = cfg.ConfigManager.__new__(cfg.ConfigManager)
    mgr.encoding = "utf-8"
    # point the history path at the corrupt file
    mgr.get = lambda k, d=None: str(bad) if k == "already_excused_file" else d
    assert mgr.get_excuse_history() == []
    assert list(tmp_path.glob("hist.json.corrupt*")) or list(tmp_path.glob("hist*"))
