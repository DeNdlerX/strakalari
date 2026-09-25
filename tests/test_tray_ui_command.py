"""Tray UI launcher: frozen exe must not use `-m` (bootloader ignores it)."""

import sys


def _set_frozen(monkeypatch, frozen=True):
    if frozen:
        monkeypatch.setattr(sys, "frozen", True, raising=False)
    else:
        monkeypatch.delattr(sys, "frozen", raising=False)


class TestUiCommand:
    def test_source_uses_module(self, monkeypatch):
        from strakalari.flet_ui.tray import TrayApp

        _set_frozen(monkeypatch, False)
        app = TrayApp.__new__(TrayApp)
        cmd = app._ui_command()
        assert cmd == [sys.executable, "-m", "strakalari.flet_ui"]

    def test_frozen_runs_bare_exe(self, monkeypatch):
        from strakalari.flet_ui.tray import TrayApp

        _set_frozen(monkeypatch, True)
        monkeypatch.setattr(sys, "executable", "C:/app/Strakalari.exe", raising=False)
        app = TrayApp.__new__(TrayApp)
        assert app._ui_command() == ["C:/app/Strakalari.exe"]

    def test_tray_refresh_preserves_baseline_and_strava(self, monkeypatch, tmp_path):
        """Tray refresh with Strava disabled must keep cached menu + baseline."""
        import strakalari.flet_ui.tray as tray_mod
        from strakalari.core.cache import save_data_cache, load_data_cache
        from strakalari.core import config as config_mod

        # Redirect user-data dir to tmp.
        import strakalari.core.helpers as helpers_mod

        monkeypatch.setattr(
            helpers_mod, "get_user_data_dir", lambda: str(tmp_path)
        )
        # Seed previous cache with menu + baseline.
        seed = {
            "timetable": {"d": []},
            "absence": {"M": 1.0},
            "strava_meals": {"1.1.2026": {"a&1&0": "X"}},
            "strava_ordered": {"1.1.2026": "a&1&0"},
            "stable_baseline": {"Mon-1": ["Mat"]},
        }
        save_data_cache(seed, replace=True)

        class FakeApp:
            strava_enable = False
            timetableData = {"d": [{"x": 1}]}
            absencePercentages = {"M": 2.0}
            grades = {}
            stableBaseline = {}
            foodDict = {}
            orderedDict = {}

            def fetchBakalariData(self):
                pass

            def close(self):
                pass

        monkeypatch.setattr(
            "strakalari.core.automation.Strakalari", lambda **kw: FakeApp()
        )
        # ConfigManager().data must report credentials; patch at class level.
        def fake_init(self, config_path="./config.json", encoding="utf-8"):
            self.encoding = encoding
            self.config_path = str(tmp_path / "config.json")
            self.data = {
                "bakalari_url": "https://x",
                "bakalari_username": "u",
                "use_strava": False,
                "excuse_mode": "confirm",
                "strava_order_mode": "confirm",
            }
            self.migration_warnings = []

        monkeypatch.setattr(config_mod.ConfigManager, "__init__", fake_init)
        import strakalari.core.notify as notify_mod

        monkeypatch.setattr(notify_mod, "notify", lambda *a, **k: None)

        tray = tray_mod.TrayApp.__new__(tray_mod.TrayApp)
        tray._prefs = lambda: {}
        result = tray_mod.TrayApp._job_refresh(tray)
        assert "subjects" in result
        final = load_data_cache()
        assert final.get("strava_meals") == {"1.1.2026": {"a&1&0": "X"}}
        assert final.get("stable_baseline") == {"Mon-1": ["Mat"]}


class TestTrayQuit:
    def test_quit_terminates_ui_process(self):
        from strakalari.core.scheduler import PeriodicRunner
        from strakalari.flet_ui.tray import TrayApp
        app = TrayApp.__new__(TrayApp)
        app.runner = PeriodicRunner()
        calls = []

        class FakeProc:
            def poll(self):
                return None
            def terminate(self):
                calls.append("terminate")

        app._ui_process = FakeProc()
        app._icon = None
        app.quit()
        assert calls == ["terminate"]
        assert app._ui_process is None
