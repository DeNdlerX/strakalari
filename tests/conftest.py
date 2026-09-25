"""Shared pytest fixtures."""
import pytest


@pytest.fixture(autouse=True)
def _isolated_data_dir(monkeypatch, tmp_path):
    """Every test gets a throwaway data dir.

    Keeps tests from reading the developer's real config/secret key and
    from leaving ``secret.key`` / ``log.txt`` / lock files in the repo.
    """
    data_dir = tmp_path / "strakalari-data"
    monkeypatch.setenv("STRAKALARI_DATA_DIR", str(data_dir))
    # The OS credential store is per user, not per test: never touch it.
    monkeypatch.setenv("STRAKALARI_NO_KEYRING", "1")
    return data_dir


@pytest.fixture()
def state(monkeypatch, tmp_path):
    """AppState with an empty cache and a throwaway config; saves stubbed out.

    Never reads or writes the developer's real config.json / data cache.
    """
    import strakalari.flet_ui.state as state_mod

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    real_cm = state_mod.ConfigManager
    cfg_path = str(tmp_path / "config.json")
    monkeypatch.setattr(
        state_mod, "ConfigManager", lambda *a, **k: real_cm(config_path=cfg_path)
    )
    app_state = state_mod.AppState()
    # Never write the real config file from tests.
    monkeypatch.setattr(app_state, "save", lambda updates: updates)
    return app_state


@pytest.fixture()
def app_state(monkeypatch, tmp_path):
    """AppState with an empty cache and a real config file in tmp_path."""
    import strakalari.flet_ui.state as state_mod

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    cfg_path = str(tmp_path / "config.json")
    real_cm = state_mod.ConfigManager
    monkeypatch.setattr(
        state_mod, "ConfigManager", lambda *a, **k: real_cm(config_path=cfg_path)
    )
    return state_mod.AppState()
