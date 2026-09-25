"""Frozen-build Chromium path (Playwright _MEIPASS fallback).

Regression test for: frozen exe dying with
``Could not launch Chromium after retries: Executable doesn't exist at
...Temp\\_MEI...\\playwright\\driver\\package\\.local-browsers\\...``.

Root cause: Playwright's driver transport forces
``PLAYWRIGHT_BROWSERS_PATH=0`` (browsers inside the driver package) for
frozen apps when the variable is unset, which resolves to the ephemeral
PyInstaller Temp extraction dir. The app must therefore always point
frozen builds at a persistent, writable dir BEFORE
``sync_playwright().start()``, and the launch retry must restart the
driver so the new location takes effect.
"""
import importlib.util
import os
import sys


RTHOOK = os.path.join(os.path.dirname(__file__), "..", "rthook_frozen_builtins.py")


def load_rthook(name="rthook_frozen_browsers"):
    spec = importlib.util.spec_from_file_location(name, RTHOOK)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _set_frozen(monkeypatch, frozen=True, exe=None):
    if frozen:
        monkeypatch.setattr(sys, "frozen", True, raising=False)
    else:
        monkeypatch.delattr(sys, "frozen", raising=False)
    if exe is not None:
        monkeypatch.setattr(sys, "executable", exe, raising=False)


class TestInitBrowsersPath:
    def test_dev_leaves_env_unset(self, monkeypatch):
        import strakalari.core.browser as bmod
        _set_frozen(monkeypatch, False)
        monkeypatch.delenv("PLAYWRIGHT_BROWSERS_PATH", raising=False)
        assert bmod.init_browsers_path() == ""
        assert "PLAYWRIGHT_BROWSERS_PATH" not in os.environ

    def test_frozen_gui_uses_persistent_exe_adjacent(self, monkeypatch, tmp_path):
        import strakalari.core.browser as bmod
        monkeypatch.setattr(sys, "platform", "win32")  # never in a macOS bundle
        exe = str(tmp_path / "Strakalari.exe")
        _set_frozen(monkeypatch, True, exe)
        monkeypatch.delattr(sys, "_MEIPASS", raising=False)
        monkeypatch.delenv("PLAYWRIGHT_BROWSERS_PATH", raising=False)
        got = bmod.init_browsers_path()
        assert got == os.path.join(str(tmp_path), "browsers")
        assert os.environ["PLAYWRIGHT_BROWSERS_PATH"] == got
        assert "_MEI" not in os.path.normcase(got).upper()

    def test_frozen_zero_is_overridden(self, monkeypatch, tmp_path):
        import strakalari.core.browser as bmod
        exe = str(tmp_path / "Strakalari.exe")
        _set_frozen(monkeypatch, True, exe)
        monkeypatch.delattr(sys, "_MEIPASS", raising=False)
        monkeypatch.setenv("PLAYWRIGHT_BROWSERS_PATH", "0")
        got = bmod.init_browsers_path()
        assert got and got != "0"
        assert os.environ["PLAYWRIGHT_BROWSERS_PATH"] == got

    def test_explicit_override_wins(self, monkeypatch, tmp_path):
        import strakalari.core.browser as bmod
        exe = str(tmp_path / "Strakalari.exe")
        _set_frozen(monkeypatch, True, exe)
        monkeypatch.setenv("PLAYWRIGHT_BROWSERS_PATH", str(tmp_path / "custom"))
        assert bmod.init_browsers_path() == str(tmp_path / "custom")

    def test_readonly_exe_dir_falls_back_to_cache(self, monkeypatch, tmp_path):
        import strakalari.core.browser as bmod
        exe = str(tmp_path / "mount" / "usr" / "bin" / "strakalari")
        _set_frozen(monkeypatch, True, exe)
        monkeypatch.delattr(sys, "_MEIPASS", raising=False)
        monkeypatch.delenv("PLAYWRIGHT_BROWSERS_PATH", raising=False)
        # Simulate a read-only mount (AppImage / .app bundle).
        real_access = os.access

        def fake_access(path, mode):
            if os.path.normcase(os.path.normpath(str(path))).startswith(
                os.path.normcase(os.path.normpath(str(tmp_path / "mount")))
            ):
                return False
            return real_access(path, mode)

        monkeypatch.setattr(os, "access", fake_access)
        cache = tmp_path / "cache"
        cache.mkdir()
        monkeypatch.setenv("XDG_CACHE_HOME", str(cache))
        got = bmod.init_browsers_path()
        assert got.endswith("ms-playwright")
        assert "_MEI" not in os.path.normcase(got).upper()
        assert os.environ["PLAYWRIGHT_BROWSERS_PATH"] == got

    def test_meipass_exe_never_used(self, monkeypatch, tmp_path):
        import strakalari.core.browser as bmod
        meipass = tmp_path / "_MEI12345"
        meipass.mkdir()
        _set_frozen(monkeypatch, True, exe=str(meipass / "Strakalari.exe"))
        monkeypatch.setattr(sys, "_MEIPASS", str(meipass), raising=False)
        monkeypatch.delenv("PLAYWRIGHT_BROWSERS_PATH", raising=False)
        got = bmod.init_browsers_path()
        assert "_MEI" not in os.path.normcase(got).upper()
        assert got.endswith("ms-playwright")


class TestRuntimeHook:
    def test_not_frozen_sets_nothing(self, monkeypatch):
        hook = load_rthook("rthook_nb_1")
        monkeypatch.delattr(sys, "frozen", raising=False)
        monkeypatch.delenv("PLAYWRIGHT_BROWSERS_PATH", raising=False)
        assert hook._point_playwright_at_persistent_browsers() is False
        assert "PLAYWRIGHT_BROWSERS_PATH" not in os.environ

    def test_frozen_sets_persistent(self, monkeypatch, tmp_path):
        hook = load_rthook("rthook_nb_2")
        monkeypatch.setattr(sys, "platform", "win32")  # never in a macOS bundle
        monkeypatch.setattr(sys, "frozen", True, raising=False)
        monkeypatch.setattr(
            sys, "executable", str(tmp_path / "Strakalari.exe"), raising=False
        )
        monkeypatch.delattr(sys, "_MEIPASS", raising=False)
        monkeypatch.delenv("PLAYWRIGHT_BROWSERS_PATH", raising=False)
        assert hook._point_playwright_at_persistent_browsers() is True
        got = os.environ["PLAYWRIGHT_BROWSERS_PATH"]
        assert got == os.path.join(str(tmp_path), "browsers")

    def test_respects_override(self, monkeypatch, tmp_path):
        hook = load_rthook("rthook_nb_3")
        monkeypatch.setattr(sys, "frozen", True, raising=False)
        monkeypatch.setenv("PLAYWRIGHT_BROWSERS_PATH", str(tmp_path / "keep"))
        assert hook._point_playwright_at_persistent_browsers() is False
        assert os.environ["PLAYWRIGHT_BROWSERS_PATH"] == str(tmp_path / "keep")


class TestMacBundle:
    """Chromium never goes into the .app bundle (updates replace it)."""

    def test_browser_dir_uses_shared_cache(self, monkeypatch, tmp_path):
        import strakalari.core.browser as bmod
        exe = str(tmp_path / "Strakalari.app" / "Contents" / "MacOS" / "Strakalari")
        os.makedirs(os.path.dirname(exe))
        _set_frozen(monkeypatch, True, exe)
        monkeypatch.delattr(sys, "_MEIPASS", raising=False)
        monkeypatch.setattr(sys, "platform", "darwin")
        monkeypatch.delenv("PLAYWRIGHT_BROWSERS_PATH", raising=False)
        assert bmod.get_browsers_dir() == bmod.default_browsers_path()
        assert "Strakalari.app" not in bmod.get_browsers_dir()

    def test_explicit_override_still_wins(self, monkeypatch, tmp_path):
        import strakalari.core.browser as bmod
        _set_frozen(monkeypatch, True, str(tmp_path / "Strakalari"))
        monkeypatch.setattr(sys, "platform", "darwin")
        monkeypatch.setenv("PLAYWRIGHT_BROWSERS_PATH", str(tmp_path / "custom"))
        assert bmod.get_browsers_dir() == str(tmp_path / "custom")

    def test_runtime_hook_uses_shared_cache(self, monkeypatch, tmp_path):
        hook = load_rthook("rthook_nb_mac")
        exe_dir = tmp_path / "Strakalari.app" / "Contents" / "MacOS"
        exe_dir.mkdir(parents=True)
        monkeypatch.setattr(sys, "frozen", True, raising=False)
        monkeypatch.setattr(sys, "executable", str(exe_dir / "Strakalari"), raising=False)
        monkeypatch.delattr(sys, "_MEIPASS", raising=False)
        monkeypatch.setattr(sys, "platform", "darwin")
        monkeypatch.setattr(hook, "_default_browsers_path",
                            lambda: str(tmp_path / "Caches" / "ms-playwright"))
        monkeypatch.delenv("PLAYWRIGHT_BROWSERS_PATH", raising=False)
        assert hook._point_playwright_at_persistent_browsers() is True
        assert os.environ["PLAYWRIGHT_BROWSERS_PATH"] == str(tmp_path / "Caches" / "ms-playwright")


class TestBrowserManagerRestart:
    def test_restarts_driver_after_install(self, monkeypatch):
        import strakalari.core.browser_manager as bm_mod

        calls = {"ensure": 0, "starts": 0}
        launches = {"n": 0}

        class FakeBrowser:
            def new_context(self, **kwargs):
                return FakeContext()

        class FakeContext:
            def new_page(self):
                return object()

        class FakeChromium:
            def launch(self, **kwargs):
                launches["n"] += 1
                if launches["n"] == 1:
                    raise Exception(
                        "Executable doesn't exist at C:\\Temp\\_MEI1\\"
                        "playwright\\driver\\package\\.local-browsers\\x"
                        " — run `playwright install`"
                    )
                return FakeBrowser()

        class FakePlaywright:
            chromium = FakeChromium()

            def stop(self):
                pass

        def fake_start():
            calls["starts"] += 1
            return FakePlaywright()

        monkeypatch.setattr(bm_mod, "init_browsers_path", lambda: "D:\\pw")
        monkeypatch.setattr(
            bm_mod, "ensure_browser", lambda *a, **k: calls.__setitem__("ensure", calls["ensure"] + 1)
        )
        monkeypatch.setattr(
            bm_mod, "sync_playwright", lambda: type("S", (), {"start": staticmethod(fake_start)})()
        )

        mgr = bm_mod.BrowserManager("ua", False, True, launch_retries=1)
        try:
            assert mgr.browser is not None
            # Initial start + one restart after the missing-browser install.
            assert calls["starts"] == 2
            assert calls["ensure"] >= 1
            assert launches["n"] == 2
        finally:
            mgr.close()
