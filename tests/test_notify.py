"""Tests for the per-platform notification backends (strakalari.core.notify)."""

import subprocess

import strakalari.core.notify as notify_mod
from strakalari.core.notify import APP_ID, _cdata, _ps_single_quote, _send_linux, _send_macos, _send_windows, _toast_ps_script
import pytest
from strakalari.core.notify import EVENT_TYPES, is_enabled, notify


class _OkResult:
    returncode = 0
    stdout = b""
    stderr = b""


class _FailResult:
    returncode = 1
    stdout = b""
    stderr = b"boom"


def _fake_run(capture, result):
    def _run(cmd, **kwargs):
        capture.append((cmd, kwargs))
        return result

    return _run


# -- script building --------------------------------------------------------

def test_app_id_is_plain_ascii():
    assert APP_ID.isascii()


def test_ps_single_quote_escapes_apostrophe():
    assert _ps_single_quote("Petrův test") == "Petrův test"
    assert _ps_single_quote("it's") == "it''s"
    # $ and backtick stay literal inside single quotes — no escaping needed.
    assert _ps_single_quote("cena $5 `x`") == "cena $5 `x`"


def test_cdata_guards_closing_sequence():
    assert _cdata("a]]>b") == "<![CDATA[a]] >b]]>"


def test_toast_script_keeps_diacritics_and_uses_winrt():
    script = _toast_ps_script("Strakaláři", "Příliš žluťoučký kůň", "refresh_done")
    assert "Strakaláři" in script
    assert "Příliš žluťoučký kůň" in script
    assert "CreateToastNotifier" in script
    assert "ToastNotification" in script
    # No -Command-hostile here-strings; single-quoted literals instead.
    assert '@"' not in script


def test_toast_script_escapes_apostrophe_in_message():
    script = _toast_ps_script("Test", "Petrova omluvenka", "it's")
    assert "it''s" in script


# -- Windows backend --------------------------------------------------------

def test_send_windows_writes_bom_script_with_diacritics(monkeypatch, tmp_path):
    capture = []
    seen_files = []

    def _fake_which(name):
        return "powershell.exe" if name == "powershell.exe" else None

    def _run(cmd, **kwargs):
        capture.append(cmd)
        with open(cmd[-1], "rb") as handle:
            seen_files.append(handle.read())
        return _OkResult()

    monkeypatch.setattr(notify_mod.shutil, "which", _fake_which)
    monkeypatch.setattr(notify_mod.subprocess, "run", _run)
    assert _send_windows("Strakaláři", "Příliš žluťoučký kůň", "refresh_done") is True
    assert capture and capture[0][:4] == [
        "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
    ]
    assert capture[0][-2] == "-File"
    raw = seen_files[0]
    assert raw.startswith(b"\xef\xbb\xbf")  # UTF-8 BOM for PowerShell 5.1
    assert "Příliš žluťoučký kůň".encode("utf-8") in raw


def test_send_windows_nonzero_exit_is_failure(monkeypatch):
    monkeypatch.setattr(notify_mod.shutil, "which", lambda name: "powershell.exe")
    monkeypatch.setattr(notify_mod.subprocess, "run", _fake_run([], _FailResult()))
    assert _send_windows("T", "M", "refresh_done") is False


def test_send_windows_no_powershell_is_failure(monkeypatch):
    monkeypatch.setattr(notify_mod.shutil, "which", lambda name: None)
    assert _send_windows("T", "M", "refresh_done") is False


# -- Linux / macOS backends --------------------------------------------------

def test_send_linux_uses_notify_send(monkeypatch):
    capture = []
    monkeypatch.setattr(notify_mod.shutil, "which", lambda name: "/usr/bin/notify-send")
    monkeypatch.setattr(notify_mod.subprocess, "run", _fake_run(capture, _OkResult()))
    assert _send_linux("Strakaláři", "hotovo") is True
    cmd = capture[0][0]
    assert cmd[0] == "/usr/bin/notify-send"
    assert "Strakaláři" in cmd and "hotovo" in cmd


def test_send_linux_failure_without_fallback(monkeypatch):
    monkeypatch.setattr(notify_mod.shutil, "which", lambda name: "/usr/bin/notify-send")
    monkeypatch.setattr(notify_mod.subprocess, "run", _fake_run([], _FailResult()))
    assert _send_linux("T", "M") is False
    monkeypatch.setattr(notify_mod.shutil, "which", lambda name: None)
    assert _send_linux("T", "M") is False


def test_send_macos_uses_osascript(monkeypatch):
    capture = []
    monkeypatch.setattr(notify_mod.shutil, "which", lambda name: "/usr/bin/osascript")
    monkeypatch.setattr(notify_mod.subprocess, "run", _fake_run(capture, _OkResult()))
    assert _send_macos("Strakaláři", 'zpráva "s uvozovkami"') is True
    cmd = capture[0][0]
    assert cmd[0] == "/usr/bin/osascript"
    assert '\\"s uvozovkami\\"' in cmd[2]


def test_send_macos_failure(monkeypatch):
    monkeypatch.setattr(notify_mod.shutil, "which", lambda name: "/usr/bin/osascript")
    monkeypatch.setattr(notify_mod.subprocess, "run", _fake_run([], _FailResult()))
    assert _send_macos("T", "M") is False
    monkeypatch.setattr(notify_mod.shutil, "which", lambda name: None)
    assert _send_macos("T", "M") is False


# -- dispatch ----------------------------------------------------------------

def test_notify_dispatches_per_platform(monkeypatch):
    calls = []
    monkeypatch.setattr(notify_mod.sys, "platform", "win32")
    monkeypatch.setattr(
        notify_mod, "_send_windows", lambda t, m, tag: calls.append(("win", tag)) or True
    )
    assert notify("refresh_done", "hotovo", {}) is True
    assert calls == [("win", "refresh_done")]

    calls.clear()
    monkeypatch.setattr(notify_mod.sys, "platform", "darwin")
    monkeypatch.setattr(notify_mod, "_send_macos", lambda t, m: calls.append("mac") or True)
    assert notify("refresh_done", "hotovo", {}) is True
    assert calls == ["mac"]

    calls.clear()
    monkeypatch.setattr(notify_mod.sys, "platform", "linux")
    monkeypatch.setattr(notify_mod, "_send_linux", lambda t, m: calls.append("linux") or True)
    assert notify("refresh_done", "hotovo", {}) is True
    assert calls == ["linux"]


def test_notify_falls_back_to_plyer_then_stdout(monkeypatch, capsys):
    monkeypatch.setattr(notify_mod.sys, "platform", "win32")
    monkeypatch.setattr(notify_mod, "_send_windows", lambda t, m, tag: False)

    seen = []
    monkeypatch.setattr(notify_mod, "_send_plyer", lambda t, m: seen.append((t, m)) or True)
    assert notify("refresh_done", "hotovo", {}) is True
    assert seen and seen[0][1] == "hotovo"

    monkeypatch.setattr(notify_mod, "_send_plyer", lambda t, m: False)
    assert notify("refresh_done", "hotovo", {}) is False
    out = capsys.readouterr().out
    assert "hotovo" in out


def test_notify_never_raises_from_backend(monkeypatch, capsys):
    monkeypatch.setattr(notify_mod.sys, "platform", "win32")

    def _boom(title, message, tag):
        raise RuntimeError("backend exploded")

    monkeypatch.setattr(notify_mod, "_send_windows", _boom)
    monkeypatch.setattr(notify_mod, "_send_plyer", lambda t, m: False)
    assert notify("refresh_done", "hotovo", {}) is False
    assert "hotovo" in capsys.readouterr().out


def test_real_subprocess_run_signature(monkeypatch):
    """Guards the kwargs we pass to subprocess.run (timeout, DEVNULL stdin)."""
    capture = []
    monkeypatch.setattr(notify_mod.shutil, "which", lambda name: "/usr/bin/notify-send")

    def _run(cmd, **kwargs):
        capture.append(kwargs)
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(notify_mod.subprocess, "run", _run)
    assert _send_linux("T", "M") is True
    assert capture[0]["timeout"] == 15
    assert capture[0]["stdin"] == subprocess.DEVNULL


def test_notify_prefs():
    assert is_enabled(None, "excuse_sent") is True
    assert is_enabled({}, "excuse_sent") is True
    assert is_enabled({"excuse_sent": False}, "excuse_sent") is False
    assert is_enabled({"excuse_sent": False}, "refresh_done") is True
    with pytest.raises(ValueError):
        notify("no_such_event", "x")
    # Disabled event never touches the backend.
    assert notify("excuse_sent", "x", {"excuse_sent": False}) is False
    assert set(EVENT_TYPES) >= {"excuse_sent", "refresh_failed", "planner_suggestion"}
