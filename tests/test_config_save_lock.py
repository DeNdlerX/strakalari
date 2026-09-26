"""Config saves never write without the inter-process lock."""
import json

import pytest



# -- config save never writes without the inter-process lock ----------------

def test_config_save_refuses_when_lock_busy(tmp_path, monkeypatch):
    import strakalari.core.helpers as helpers
    from strakalari.core.config import ConfigManager

    cfg = tmp_path / "config.json"
    cfg.write_text(json.dumps({"theme": "dark"}), encoding="utf-8")
    manager = ConfigManager(config_path=str(cfg))
    manager.set("theme", "light")
    monkeypatch.setattr(helpers.InterProcessLock, "acquire", lambda self, timeout_s=0: False)
    with pytest.raises(RuntimeError):
        manager.save()
    assert json.loads(cfg.read_text(encoding="utf-8"))["theme"] == "dark"
    monkeypatch.undo()
    manager.save()  # the edit was kept and goes out with the next save
    assert json.loads(cfg.read_text(encoding="utf-8"))["theme"] == "light"
