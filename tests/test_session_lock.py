"""Cross-process guards: the session lock and merge-on-save config."""
import json
import subprocess
import sys
import textwrap

from strakalari.core.config import ConfigManager
from strakalari.core.helpers import InterProcessLock
from strakalari.core.refresh import session_lock


def test_session_lock_is_exclusive_within_process():
    with session_lock() as first:
        assert first is True
        with session_lock() as second:
            assert second is False
    with session_lock() as again:
        assert again is True


def test_session_lock_blocks_other_process(tmp_path):
    lock_path = tmp_path / "x.lock"
    lock = InterProcessLock(str(lock_path))
    assert lock.acquire()
    try:
        code = textwrap.dedent(f"""
            import sys
            sys.path.insert(0, {repr(str(__import__('pathlib').Path(__file__).resolve().parents[1]))})
            from strakalari.core.helpers import InterProcessLock
            print(InterProcessLock({str(lock_path)!r}).acquire())
        """)
        out = subprocess.run([sys.executable, "-c", code], capture_output=True,
                             text=True, timeout=60)
        assert out.stdout.strip() == "False", out.stderr
    finally:
        lock.release()
    # Released (and a dead holder never keeps it): acquirable again.
    other = InterProcessLock(str(lock_path))
    assert other.acquire()
    other.release()


def test_config_save_keeps_other_process_edits(tmp_path):
    path = tmp_path / "config.json"
    window = ConfigManager(config_path=str(path))
    window.set("theme", "light")
    window.save()

    tray = ConfigManager(config_path=str(path))
    tray.set("gemini_last_run", "2026-09-24")
    tray.save()

    # The window's copy is stale; saving an unrelated edit must not
    # roll back the tray's stamp.
    window.set("language", "en")
    window.save()

    on_disk = json.loads(path.read_text(encoding="utf-8"))
    assert on_disk["gemini_last_run"] == "2026-09-24"
    assert on_disk["language"] == "en"
    assert on_disk["theme"] == "light"
    assert window.get("gemini_last_run") == "2026-09-24"


def test_config_save_own_edit_wins_on_same_key(tmp_path):
    path = tmp_path / "config.json"
    a = ConfigManager(config_path=str(path))
    a.save()
    b = ConfigManager(config_path=str(path))
    b.set("theme", "light")
    b.save()
    a.set("theme", "dark")
    a.save()
    assert json.loads(path.read_text(encoding="utf-8"))["theme"] == "dark"


def test_tray_refresh_skips_while_window_holds_session(monkeypatch):
    from strakalari.flet_ui.tray import TrayApp

    tray = TrayApp.__new__(TrayApp)
    ran = []
    monkeypatch.setattr(tray, "_job_refresh_inner", lambda: ran.append(1) or "ok",
                        raising=False)
    with session_lock() as held:
        assert held
        assert "skipped" in tray._job_refresh()
    assert ran == []
    assert tray._job_refresh() == "ok"


def test_window_refresh_skips_while_tray_holds_session(state, monkeypatch):
    state.demo_mode = False
    called = []
    monkeypatch.setattr(state, "_refresh_locked", lambda *a: called.append(a))
    with session_lock():
        state._refresh_work("all")
    assert called == []
    assert state.runs[-1]["ok"] is False
    state._refresh_work("all")
    assert len(called) == 1
