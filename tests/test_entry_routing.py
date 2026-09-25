"""Entry-point routing (--minimized -> tray, default -> Flet UI).

Importing `main` or `strakalari.__main__` must never launch the GUI
as a side effect (regression: __main__ used to call run() on import).
"""

import importlib
import sys


def _patched_runs(monkeypatch):
    import strakalari.flet_ui.app as app_mod
    import strakalari.flet_ui.tray as tray_mod

    calls = {}
    monkeypatch.setattr(app_mod, "run", lambda: calls.setdefault("app", True))
    monkeypatch.setattr(tray_mod, "run", lambda: calls.setdefault("tray", True))
    return calls


def test_import_has_no_side_effect(monkeypatch):
    monkeypatch.setattr(sys, "argv", ["strakalari"])
    calls = _patched_runs(monkeypatch)
    for mod in ("main", "strakalari.__main__"):
        sys.modules.pop(mod, None)
    importlib.import_module("main")
    importlib.import_module("strakalari.__main__")
    assert calls == {}


def test_default_routes_to_flet_app(monkeypatch):
    import main as entry

    monkeypatch.setattr(sys, "argv", ["strakalari"])
    calls = _patched_runs(monkeypatch)
    entry.main()
    assert calls == {"app": True}


def test_minimized_routes_to_tray(monkeypatch):
    import main as entry

    monkeypatch.setattr(sys, "argv", ["strakalari", "--minimized"])
    calls = _patched_runs(monkeypatch)
    entry.main()
    assert calls == {"tray": True}


def test_package_entry_shares_main(monkeypatch):
    import main as entry
    import strakalari.__main__ as pkg_entry

    assert pkg_entry.main is entry.main
    monkeypatch.setattr(sys, "argv", ["strakalari", "--minimized"])
    calls = _patched_runs(monkeypatch)
    pkg_entry.main()
    assert calls == {"tray": True}


def test_package_root_exports_legacy_names():
    import strakalari

    assert callable(strakalari.extract_grades)
    assert callable(strakalari.extract_sent_excuses)
    assert "extract_grades" in strakalari.__all__
