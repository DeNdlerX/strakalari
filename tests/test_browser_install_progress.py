"""Continuous overall Chromium install progress: parser + hidden streaming runner."""

import io
import subprocess
import sys
from itertools import pairwise

import pytest

import strakalari.core.browser as bmod


class TestParseInstallProgress:
    def test_start_line(self):
        assert bmod.parse_install_progress(
            "Downloading Chromium 151.0.7922.34 (playwright chromium v1234)"
            " from https://cdn.playwright.dev/builds/cft/x/chrome-win64.zip"
        ) == ("start", "Chrome")

    def test_start_headless_shell(self):
        assert bmod.parse_install_progress(
            "Downloading Chrome Headless Shell 151.0.7922.34 (playwright"
            " chromium-headless-shell v1234) from https://example.com/x.zip"
        ) == ("start", "Chrome Headless Shell")

    def test_progress_line(self):
        kind, frac = bmod.parse_install_progress("167.7 MiB [====================] 100% 0.0s")
        assert kind == "progress"
        assert frac == pytest.approx(1.0)
        kind, frac = bmod.parse_install_progress("10.2 MiB [==        ] 12% 1.0s")
        assert kind == "progress"
        assert frac == pytest.approx(0.12)

    def test_done_line(self):
        assert bmod.parse_install_progress(
            "Chromium 151.0.7922.34 (playwright chromium v1234) downloaded to"
            " C:\\pw\\chromium-1234"
        ) == ("done", "Chrome")

    def test_url_with_percent_escapes_is_not_progress(self):
        # A wrapped URL continued on its own segment must not fake progress.
        assert bmod.parse_install_progress("https://cdn.example.com/a%20b/c.zip") is None

    def test_noise_returns_none(self):
        assert bmod.parse_install_progress("") is None
        assert bmod.parse_install_progress("   ") is None
        assert bmod.parse_install_progress("Playwright version 1.62.0") is None


class TestShortComponentName:
    def test_dry_run_titles(self):
        assert bmod.short_component_name(
            "Chrome for Testing 151.0.7922.34 (playwright chromium v1234)") == "Chrome"
        assert bmod.short_component_name("FFMPEG playwright build v1011") == "FFMPEG"
        assert bmod.short_component_name(
            "Chrome Headless Shell 151.0.7922.34 (playwright chromium-headless-shell v1234)"
        ) == "Chrome Headless Shell"
        assert bmod.short_component_name("Winldd (playwright winldd v1007)") == "Winldd"


DRY_RUN_STDOUT = (
    "Chrome for Testing 151.0.7922.34 (playwright chromium v1234)\n"
    "  Install location:    C:\\pw\\chromium-1234\n"
    "\n"
    "FFMPEG playwright build v1011\n"
    "  Install location:    C:\\pw\\ffmpeg-1011\n"
)

CANNED_INSTALL = (
    "Downloading Chromium 151.0.7922.34 (playwright chromium v1234)"
    " from https://cdn.playwright.dev/c.zip\r"
    "10.2 MiB [==        ] 12% 1.0s\r"
    "167.7 MiB [====================] 100% 0.0s\r\n"
    "Chromium 151.0.7922.34 (playwright chromium v1234) downloaded to C:\\pw\\chromium-1234\r\n"
    "Downloading FFMPEG playwright build v1011 from https://cdn.playwright.dev/f.zip\r\n"
    "2.1 MiB [====================] 100% 0.0s\r\n"
    "FFMPEG playwright build v1011 downloaded to C:\\pw\\ffmpeg-1011\r\n"
)


class FakePopen:
    instances = []
    output = CANNED_INSTALL

    def __init__(self, cmd, **kwargs):
        self.cmd = cmd
        self.kwargs = kwargs
        self.stdout = io.StringIO(FakePopen.output)
        self.returncode = 0
        FakePopen.instances.append(self)

    def poll(self):
        return 0

    def wait(self, timeout=None):
        return 0

    def kill(self):
        pass


def _patch_install_env(monkeypatch, tmp_path):
    monkeypatch.setattr(bmod, "is_browser_installed", lambda: False)
    monkeypatch.setattr(bmod, "init_browsers_path", lambda: str(tmp_path / "browsers"))
    import playwright._impl._driver as drv

    monkeypatch.setattr(drv, "compute_driver_executable", lambda: ("node", "cli.js"))
    run_calls = []

    def fake_run(cmd, **kwargs):
        run_calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout=DRY_RUN_STDOUT, stderr="")

    monkeypatch.setattr(bmod.subprocess, "run", fake_run)
    FakePopen.instances.clear()
    monkeypatch.setattr(bmod.subprocess, "Popen", FakePopen)
    return run_calls


def _firsts_by_label(events):
    """First event per component label, in order of appearance."""
    seen = {}
    for e in events:
        seen.setdefault(e[0], e)
    return list(seen.values())


def test_ensure_browser_streams_continuous_progress(monkeypatch, tmp_path):
    _patch_install_env(monkeypatch, tmp_path)
    events = []
    logs = []
    ok = bmod.ensure_browser(
        log_callback=logs.append,
        progress_callback=lambda label, frac, cur, total: events.append(
            (label, frac, cur, total)),
    )
    assert ok is True
    firsts = _firsts_by_label(events)
    assert [s[0] for s in firsts] == ["Chrome", "FFMPEG"]
    # "File i of N" counting from the dry-run plan.
    assert firsts[0][2:] == (1, 2)
    assert firsts[1][2:] == (2, 2)
    fracs = [e[1] for e in events]
    assert fracs, "expected percentage events"
    assert all(f is not None and 0.0 <= f <= 1.0 for f in fracs)
    # Continuous overall bar: starts at 0, ends at 1, never jumps back.
    assert fracs[0] == pytest.approx(0.0)
    assert fracs[-1] == pytest.approx(1.0)
    assert all(b >= a for a, b in pairwise(fracs)), fracs
    # Weighted by size: 12 % of the 10.2 MiB Chrome file against the
    # FFMPEG estimate (a tiny file must not own half the bar).
    ffmpeg = bmod._EST_MIB["FFMPEG"]
    assert any(f == pytest.approx(0.12 * 10.2 / (10.2 + ffmpeg)) for f in fracs), fracs
    labels = {e[0] for e in events}
    assert {"Chrome", "FFMPEG"} <= labels


def test_install_hides_popup_window(monkeypatch, tmp_path):
    _patch_install_env(monkeypatch, tmp_path)
    bmod.ensure_browser(progress_callback=lambda *a: None)
    assert FakePopen.instances, "expected the install to run via Popen"
    kwargs = FakePopen.instances[0].kwargs
    assert kwargs.get("stdout") == subprocess.PIPE
    assert kwargs.get("stderr") == subprocess.STDOUT
    if sys.platform == "win32":
        assert kwargs.get("creationflags") == subprocess.CREATE_NO_WINDOW
        assert "startupinfo" in kwargs


def test_install_failure_raises(monkeypatch, tmp_path):
    _patch_install_env(monkeypatch, tmp_path)

    class FailPopen(FakePopen):
        def __init__(self, cmd, **kwargs):
            super().__init__(cmd, **kwargs)
            self.stdout = io.StringIO("boom went wrong\n")

        def wait(self, timeout=None):
            return 1

    monkeypatch.setattr(bmod.subprocess, "Popen", FailPopen)
    monkeypatch.delattr(sys, "frozen", raising=False)
    with pytest.raises(RuntimeError):
        bmod.ensure_browser(progress_callback=lambda *a: None)


def test_wizard_browser_step_renders_working_progress(monkeypatch):
    """Headless build of the browser step with per-file progress set."""
    import strakalari.flet_ui.state as state_mod
    from strakalari.flet_ui.state import AppState
    from strakalari.flet_ui.views import wizard as wiz

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    state = AppState()
    monkeypatch.setattr(state.config, "save", lambda: None)
    monkeypatch.setattr(bmod, "is_browser_installed", lambda: False)
    state.wizard_browser_status = "working"
    state.wizard_browser_label = "Chrome"
    state.wizard_browser_progress = 0.5
    state.wizard_browser_pos = (1, 4)
    state.wizard_step = wiz.STEP_BROWSER
    view = wiz.build(state, None)
    assert view is not None
    # Determinate bar + "Soubor 1/4" label must be in the tree.
    import flet as ft

    bars = []

    def _walk(control):
        if isinstance(control, ft.ProgressBar):
            bars.append(control)
        for child in getattr(control, "controls", None) or []:
            _walk(child)
        content = getattr(control, "content", None)
        if isinstance(control, ft.Container) and content is not None:
            _walk(content)

    _walk(view)
    assert bars, "expected a ProgressBar in the working browser step"
    # Overall progress drives the bar directly (no per-file restart).
    assert any(b.value == pytest.approx(0.5) for b in bars)
    texts = []

    def _walk_text(control):
        if isinstance(control, ft.Text):
            texts.append(control.value or "")
        for child in getattr(control, "controls", None) or []:
            _walk_text(child)
        content = getattr(control, "content", None)
        if isinstance(control, ft.Container) and content is not None:
            _walk_text(content)

    _walk_text(view)
    assert any("1/4" in t for t in texts), f"expected per-file label, got {texts!r}"
    assert "50 %" in texts, f"expected overall percent, got {texts!r}"


def test_default_install_plan_has_known_components():
    plan = bmod._default_install_plan()
    assert plan[:3] == ["Chrome", "FFMPEG", "Chrome Headless Shell"]
    if sys.platform == "win32":
        assert plan == ["Chrome", "FFMPEG", "Chrome Headless Shell", "Winldd"]
    else:
        assert "Winldd" not in plan


def test_ensure_browser_uses_fallback_total_when_dry_run_fails(monkeypatch, tmp_path):
    run_calls = _patch_install_env(monkeypatch, tmp_path)

    def failing_run(cmd, **kwargs):
        run_calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 1, stdout="", stderr="oops")

    monkeypatch.setattr(bmod.subprocess, "run", failing_run)
    events = []
    ok = bmod.ensure_browser(
        progress_callback=lambda label, frac, cur, total: events.append(
            (label, frac, cur, total)),
    )
    assert ok is True
    expected_total = len(bmod._default_install_plan())
    assert expected_total >= 3
    firsts = _firsts_by_label(events)
    assert [s[0] for s in firsts] == ["Chrome", "FFMPEG"]
    assert firsts[0][2:] == (1, expected_total)
    assert firsts[1][2:] == (2, expected_total)


def test_install_total_grows_when_plan_is_short(monkeypatch, tmp_path):
    _patch_install_env(monkeypatch, tmp_path)
    events = []
    # CANNED_INSTALL downloads 2 files but the plan predicts 1: the
    # counter must grow (2/2) rather than clamp at (1/1).
    bmod._run_install(
        ["install", "chromium"], {},
        progress_callback=lambda label, frac, cur, total: events.append(
            (label, frac, cur, total)),
        plan=("Only",),
    )
    starts = _firsts_by_label(events)
    assert [(s[2], s[3]) for s in starts] == [(1, 1), (2, 2)]


RETRY_INSTALL = (
    "Downloading Chromium 151.0.7922.34 (playwright chromium v1234)"
    " from https://cdn.playwright.dev/c.zip\r"
    "10.2 MiB [==        ] 12% 1.0s\r"
    "Downloading Chromium 151.0.7922.34 (playwright chromium v1234)"
    " from https://fallback.example.com/c.zip\r"
    "83.9 MiB [==========  ] 50% 2.0s\r\n"
    "Chromium 151.0.7922.34 (playwright chromium v1234) downloaded to C:\\pw\\chromium-1234\r\n"
)

SINGLE_FILE_INSTALL = (
    "Downloading FFMPEG playwright build v1011 from https://cdn.playwright.dev/f.zip\r\n"
    "2.1 MiB [====================] 100% 0.0s\r\n"
    "FFMPEG playwright build v1011 downloaded to C:\\pw\\ffmpeg-1011\r\n"
)


def test_retry_same_component_keeps_counter(monkeypatch):
    """A repeated Downloading line (fallback-URL retry) is one file."""
    monkeypatch.setattr(bmod.subprocess, "Popen", FakePopen)
    monkeypatch.setattr(FakePopen, "output", RETRY_INSTALL)
    events = []
    bmod._run_install(
        ["install", "chromium"], {},
        progress_callback=lambda label, frac, cur, total: events.append(
            (label, frac, cur, total)),
        plan=("Chrome",),
    )
    assert events, "expected progress events"
    assert {(e[2], e[3]) for e in events} == {(1, 1)}
    fracs = [e[1] for e in events]
    assert fracs[0] == pytest.approx(0.0)
    assert fracs[-1] == pytest.approx(1.0)


def _piped_bar(pct: int, mib: str) -> str:
    """One line of Playwright's non-TTY progress output."""
    filled = pct // 10 * 8
    # Built outside the f-string: a backslash inside one needs Python 3.12.
    bar = "\u25a0" * filled + " " * (80 - filled)
    return f"|{bar}| {pct:3d}% of {mib} MiB\n"


PIPED_INSTALL = (
    "Downloading Chrome for Testing 151.0.7922.34 (playwright chromium v1234)"
    " from https://cdn.playwright.dev/c.zip\n"
    + _piped_bar(0, "170") + _piped_bar(10, "170") + _piped_bar(100, "170")
    + "Chrome for Testing 151.0.7922.34 (playwright chromium v1234)"
    " downloaded to C:\\pw\\chromium-1234\n"
    "Downloading FFMPEG playwright build v1011 from https://cdn.playwright.dev/f.zip\n"
    + _piped_bar(100, "1.4")
    + "FFMPEG playwright build v1011 downloaded to C:\\pw\\ffmpeg-1011\n"
)


def test_parse_download_size_both_formats():
    assert bmod.parse_download_size(_piped_bar(40, "167.7")) == pytest.approx(167.7)
    assert bmod.parse_download_size("167.7 MiB [====    ] 40% 3.1s") == pytest.approx(167.7)
    assert bmod.parse_download_size("Playwright version 1.62.0") is None


def test_piped_output_weights_by_real_size_and_reports_phases(monkeypatch):
    """Piped installs print 10 % steps with the size; FFMPEG is ~1 % of the bar."""
    monkeypatch.setattr(bmod.subprocess, "Popen", FakePopen)
    monkeypatch.setattr(FakePopen, "output", PIPED_INSTALL)
    events, phases = [], []
    bmod._run_install(
        ["install", "chromium"], {},
        progress_callback=lambda label, frac, cur, total: events.append(
            (label, frac, cur, total)),
        phase_callback=phases.append,
        plan=("Chrome", "FFMPEG"),
    )
    fracs = [e[1] for e in events]
    assert all(b >= a for a, b in pairwise(fracs)), fracs
    chrome_done = [e[1] for e in events if e[0] == "Chrome"][-1]
    assert chrome_done == pytest.approx(170 / (170 + bmod._EST_MIB["FFMPEG"]))
    assert fracs[-1] == pytest.approx(1.0)
    assert phases == ["download", "extract", "download", "extract"]


def test_install_complete_needs_both_markers(tmp_path):
    chromium = tmp_path / "chromium-1234" / "chrome-win64"
    chromium.mkdir(parents=True)
    exe = chromium / "chrome.exe"
    exe.write_text("")
    # Executable present but not finished extracting.
    assert bmod._install_complete(str(exe)) is False
    (tmp_path / "chromium-1234" / "INSTALLATION_COMPLETE").write_text("")
    # Chrome done, headless shell (used for headless launches) still missing.
    assert bmod._install_complete(str(exe)) is False
    shell = tmp_path / "chromium_headless_shell-1234"
    shell.mkdir()
    (shell / "INSTALLATION_COMPLETE").write_text("")
    assert bmod._install_complete(str(exe)) is True


def test_is_browser_installed_false_while_installing(monkeypatch):
    monkeypatch.setattr(bmod, "_confirmed_exec", "")
    bmod._INSTALLING.set()
    try:
        assert bmod.is_browser_installed() is False
    finally:
        bmod._INSTALLING.clear()


def test_install_plan_returns_labels_with_locations(monkeypatch):
    def fake_run(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, stdout=DRY_RUN_STDOUT, stderr="")

    monkeypatch.setattr(bmod.subprocess, "run", fake_run)
    plan = bmod._install_plan(["node", "cli.js"], {})
    assert [label for label, _ in plan] == ["Chrome", "FFMPEG"]
    assert all(loc for _, loc in plan)


def test_cached_components_dropped_from_plan(monkeypatch, tmp_path):
    chromium_dir = tmp_path / "chromium-1"
    chromium_dir.mkdir()
    (chromium_dir / "INSTALLATION_COMPLETE").write_text("ok")
    ffmpeg_dir = tmp_path / "ffmpeg-1"
    ffmpeg_dir.mkdir()
    plan = [("Chrome", str(chromium_dir)), ("FFMPEG", str(ffmpeg_dir))]
    kept = bmod._drop_cached_entries(bmod._plan_entries(plan))
    assert [label for label, _ in kept] == ["FFMPEG"]
    # End to end: only the missing file downloads, counter is (1, 1).
    monkeypatch.setattr(bmod.subprocess, "Popen", FakePopen)
    monkeypatch.setattr(FakePopen, "output", SINGLE_FILE_INSTALL)
    events = []
    bmod._run_install(
        ["install", "chromium"], {},
        progress_callback=lambda label, frac, cur, total: events.append(
            (label, frac, cur, total)),
        plan=plan,
    )
    firsts = _firsts_by_label(events)
    assert [(s[0], s[2], s[3]) for s in firsts] == [("FFMPEG", 1, 1)]
    assert events[-1][1] == pytest.approx(1.0)
