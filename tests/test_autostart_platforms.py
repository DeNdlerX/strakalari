"""Autostart on each platform: the entry is written, read back and removed.

Never touches the real registry or home directory: Windows gets a fake
``winreg``, macOS/Linux a temporary HOME.
"""

import sys
import types

import pytest

import strakalari.core.autostart as autostart


@pytest.fixture()
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("HOME", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path))
    monkeypatch.setenv("APPDATA", str(tmp_path / "AppData"))
    monkeypatch.setattr(autostart.os.path, "expanduser",
                        lambda p: p.replace("~", str(tmp_path), 1))
    return tmp_path


class _FakeWinreg(types.ModuleType):
    HKEY_CURRENT_USER = object()
    KEY_READ = 1
    KEY_SET_VALUE = 2
    REG_SZ = 1

    def __init__(self, fail=False):
        super().__init__("winreg")
        self.values = {}
        self.fail = fail

    def OpenKey(self, root, path, reserved, access):
        if self.fail:
            raise PermissionError("denied")
        return path

    def CloseKey(self, key):
        pass

    def QueryValueEx(self, key, name):
        if name not in self.values:
            raise FileNotFoundError(name)
        return self.values[name], self.REG_SZ

    def SetValueEx(self, key, name, reserved, kind, value):
        self.values[name] = value

    def DeleteValue(self, key, name):
        if name not in self.values:
            raise FileNotFoundError(name)
        del self.values[name]


@pytest.fixture()
def windows(monkeypatch, home):
    reg = _FakeWinreg()
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setitem(sys.modules, "winreg", reg)
    return reg


class TestWindows:
    def test_round_trip(self, windows):
        assert autostart.is_autostart_enabled() is False
        assert autostart.set_autostart(True) is True
        assert "--minimized" in windows.values["Strakalari"]
        assert autostart.is_autostart_enabled() is True
        assert autostart.set_autostart(False) is True
        assert autostart.is_autostart_enabled() is False
        # Disabling twice is not an error.
        assert autostart.set_autostart(False) is True

    def test_legacy_startup_shortcut_counts_and_is_adopted(self, windows):
        lnk = autostart._startup_shortcut_path()
        autostart.os.makedirs(autostart.os.path.dirname(lnk))
        open(lnk, "w").close()
        assert autostart.is_autostart_enabled() is True
        assert autostart.set_autostart(True) is True
        assert not autostart.os.path.exists(lnk)  # the Run value is the only source now

    def test_registry_failure_reports_false(self, monkeypatch, home):
        monkeypatch.setattr(sys, "platform", "win32")
        monkeypatch.setitem(sys.modules, "winreg", _FakeWinreg(fail=True))
        assert autostart.set_autostart(True) is False


class TestMacOS:
    def test_round_trip_writes_an_escaped_plist(self, monkeypatch, home):
        monkeypatch.setattr(sys, "platform", "darwin")
        monkeypatch.setattr(sys, "executable", "/Apps/A & B/python")
        assert autostart.set_autostart(True) is True
        plist = home / "Library" / "LaunchAgents" / "cz.strakalari.app.plist"
        text = plist.read_text(encoding="utf-8")
        assert "<string>/Apps/A &amp; B/python</string>" in text
        assert "<string>--minimized</string>" in text
        assert autostart.is_autostart_enabled() is True
        assert autostart.set_autostart(False) is True
        assert not plist.exists()


class TestLinux:
    def test_round_trip_quotes_paths_with_spaces(self, monkeypatch, home):
        monkeypatch.setattr(sys, "platform", "linux")
        monkeypatch.setattr(sys, "executable", "/opt/my apps/python")
        assert autostart.set_autostart(True, minimized=False) is True
        entry = home / ".config" / "autostart" / "strakalari.desktop"
        text = entry.read_text(encoding="utf-8")
        assert 'Exec="/opt/my apps/python"' in text
        assert "--minimized" not in text
        assert autostart.is_autostart_enabled() is True
        assert autostart.set_autostart(False) is True
        assert not entry.exists()
