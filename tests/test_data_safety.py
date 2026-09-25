"""Fail-safe handling of corrupt local JSON data (history, blacklist)."""

import glob
import json
import os
from unittest.mock import MagicMock


class TestQuarantine:
    def test_missing_file_returns_empty(self, tmp_path):
        from strakalari.core.helpers import quarantine_corrupt_file

        assert quarantine_corrupt_file(str(tmp_path / "nope.json")) == ""

    def test_corrupt_file_preserved(self, tmp_path):
        from strakalari.core.helpers import quarantine_corrupt_file

        target = tmp_path / "data.json"
        target.write_text("{broken", encoding="utf-8")
        backup = quarantine_corrupt_file(str(target))
        assert backup and os.path.exists(backup)
        assert not os.path.exists(str(target))
        assert open(backup, encoding="utf-8").read() == "{broken"


class TestHistoryQuarantine:
    def _app(self, history_file):
        from strakalari.core.automation import Strakalari

        app = Strakalari.__new__(Strakalari)
        app.already_excused_file = history_file
        app.encoding = "utf-8"
        app.writeLog = lambda m: None
        return app

    def test_corrupt_history_backed_up(self, tmp_path):
        bad = tmp_path / "already_excused_lessons.json"
        bad.write_text("{oops", encoding="utf-8")
        app = self._app(str(bad))
        history, path = app._load_history()
        assert history == []
        assert path == str(bad)
        assert not os.path.exists(str(bad))  # moved aside
        backups = glob.glob(str(tmp_path / "*.corrupt-*"))
        assert len(backups) == 1
        assert open(backups[0], encoding="utf-8").read() == "{oops"


class TestBlacklistFailClosed:
    def _client(self, bl_path):
        from strakalari.core.strava_client import StravaClient

        bm = MagicMock()
        bm.page = MagicMock()
        cfg = {"strava_order_mode": "auto", "use_strava": True,
               "strava_blacklist": bl_path}
        logs = []
        return StravaClient(bm, cfg, logger=logs.append), logs

    def test_corrupt_blacklist_disables_auto_order(self, tmp_path):
        bad = tmp_path / "strava_blacklist.json"
        bad.write_text("[\"unclosed", encoding="utf-8")
        client, logs = self._client(str(bad))
        assert client.blacklist_broken is True
        assert any("blacklist" in m.lower() for m in logs)
        assert not os.path.exists(str(bad))
        assert glob.glob(str(tmp_path / "*.corrupt-*"))

    def test_valid_blacklist_unaffected(self, tmp_path):
        good = tmp_path / "strava_blacklist.json"
        good.write_text(json.dumps(["vepro"]), encoding="utf-8")
        client, _logs = self._client(str(good))
        assert client.blacklist_broken is False
        assert client.strava_blacklist_json == ["vepro"]


def test_busy_config_is_not_quarantined_or_overwritten(tmp_path):
    import pytest

    from strakalari.core.config import ConfigManager

    busy = tmp_path / "config.json"
    busy.mkdir()  # opening a directory raises OSError, like a locked file
    manager = ConfigManager(config_path=str(busy))
    assert busy.exists()
    assert not list(tmp_path.glob("config.json.corrupt-*"))
    with pytest.raises(RuntimeError):
        manager.save()


def test_busy_cache_is_left_untouched(tmp_path, monkeypatch):
    import strakalari.core.helpers as helpers_mod
    from strakalari.core.cache import CACHE_FILE, load_data_cache, save_data_cache

    monkeypatch.setattr(helpers_mod, "get_user_data_dir", lambda: str(tmp_path))
    busy = tmp_path / CACHE_FILE.lstrip("./")
    busy.mkdir()
    assert load_data_cache() == {}
    save_data_cache({"absence": {"M": 1.0}})
    assert busy.is_dir()
    assert not list(tmp_path.glob("*.corrupt-*"))


def test_write_log_lines_are_timestamped(tmp_path):
    import re

    from strakalari.core.automation import Strakalari

    app = Strakalari.__new__(Strakalari)
    app.logFile = str(tmp_path / "log.txt")
    app.encoding = "utf-8"
    app.on_log = None
    app.writeLog("hello")
    text = (tmp_path / "log.txt").read_text(encoding="utf-8")
    assert re.match(r"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] hello\n", text)
