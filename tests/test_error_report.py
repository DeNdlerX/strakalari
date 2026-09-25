"""Error popup diagnostics: redaction, report content, state wiring, dialog copy."""

import flet as ft

import inspect

import pytest

from strakalari.core import error_report as er


@pytest.fixture
def state(monkeypatch):
    import strakalari.flet_ui.state as state_mod

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    app_state = state_mod.AppState()
    monkeypatch.setattr(app_state, "_emit", lambda: None)
    return app_state


class FakeClipboard(ft.Clipboard):
    """Clipboard service double that records instead of touching the OS."""

    def __init__(self):
        super().__init__()
        self.saved = None

    async def set(self, value):  # noqa: D102 - matches ft.Clipboard.set
        self.saved = value


class FakePage:
    """Minimal page double: task runner + clipboard + dialog capture."""

    def __init__(self):
        self.clipboard_service = FakeClipboard()
        self.overlay = [self.clipboard_service]
        self.controls = []
        self.copied_legacy = None
        self.shown = None
        self.bgcolor = None
        self.theme_mode = None

    @property
    def saved_clipboard(self):
        return self.clipboard_service.saved

    def run_task(self, handler, *args, **kwargs):
        import asyncio

        result = handler(*args, **kwargs)
        if inspect.isawaitable(result):
            asyncio.run(result)
        return result

    def set_clipboard(self, text):
        self.copied_legacy = text

    def show_dialog(self, dlg):
        self.shown = dlg

    def pop_dialog(self):
        raise Exception("no dialog open")

    def add(self, *controls):
        self.controls.extend(controls)

    def update(self):
        pass


# -- redaction ------------------------------------------------------------

def test_redact_config_exposes_only_presence():
    config = {
        "bakalari_url": "https://school.example.cz",
        "bakalari_username": "student",
        "bakalari_password": "hunter2-hunter2",
        "strava_password": "lunch-secret",
        "gemini_api_key": "AIza-secret-value",
        "bakalari_password_encrypted": False,
        "check_interval_minutes": 60,
        "empty_slot": "",
        "no_value": None,
    }
    redacted = er.redact_config(config)
    assert redacted["bakalari_password"] == "set"
    assert redacted["bakalari_url"] == "set"
    assert redacted["bakalari_username"] == "set"
    assert redacted["bakalari_password_encrypted"] == "set"  # False is a real choice
    assert redacted["check_interval_minutes"] == "set"
    assert redacted["empty_slot"] == "empty"
    assert redacted["no_value"] == "empty"
    # No value survives — the whole point of presence-only redaction.
    blob = " ".join(str(v) for v in redacted.values())
    for secret in ("hunter2-hunter2", "lunch-secret", "AIza-secret-value",
                   "https://school.example.cz", "student"):
        assert secret not in blob
    # Original untouched.
    assert config["bakalari_password"] == "hunter2-hunter2"


def test_activity_log_copy_redacts_secrets():
    from strakalari.flet_ui.views import activity as act_mod

    class Cfg:
        data = {"bakalari_password": "hunter2-hunter2"}

    class St:
        config = Cfg()
        log_lines = ["[10:00] login with hunter2-hunter2 failed", "[10:01] ok"]

    body = act_mod.redacted_log_tail(St(), 200)
    assert "hunter2-hunter2" not in body
    assert "***" in body
    assert "ok" in body


# -- user-fixable errors --------------------------------------------------

def test_user_error_marks_report_friendly(state):
    try:
        raise er.UserError("Chybí URL Bakalářů — doplňte ho v Nastavení.")
    except er.UserError as exc:
        report = state.report_error("refresh (all)", exc)
    assert report["user_message"] == "Chybí URL Bakalářů — doplňte ho v Nastavení."
    assert "Traceback" in report["traceback"]  # diagnostics still built for copy


def test_regular_error_has_no_user_message(state):
    try:
        raise RuntimeError("boom")
    except RuntimeError as exc:
        report = state.report_error("refresh (all)", exc)
    assert report.get("user_message", "") == ""


def _dialog_texts(control):
    """Collects every ft.Text value in a dialog tree."""
    found = []
    value = getattr(control, "value", None)
    if isinstance(value, str):
        found.append(value)
    for child in getattr(control, "controls", None) or []:
        found.extend(_dialog_texts(child))
    content = getattr(control, "content", None)
    if content is not None and not isinstance(content, str):
        found.extend(_dialog_texts(content))
    return found


def test_user_dialog_hides_traceback_but_copies():
    import flet as ft

    from strakalari.flet_ui.overlays import show_error_dialog

    page = FakePage()
    report = "Strakalari error report\ntraceback:\nTraceback (most recent call last):\n"
    dlg = show_error_dialog(page, "Něco se pokazilo", "UserError: x", report,
                            user_message="Chybí URL Bakalářů — doplňte ho v Nastavení.")
    assert page.shown is dlg
    assert isinstance(dlg, ft.AlertDialog)
    shown = _dialog_texts(dlg) + _dialog_texts(dlg.actions[0]) + _dialog_texts(dlg.actions[1])
    assert any("Chybí URL" in t for t in shown)
    assert not any("traceback:" in t for t in shown)
    copy_btn = dlg.actions[1]
    copy_btn.on_click(object())
    assert page.saved_clipboard == report


def test_clients_raise_user_error_for_missing_login():
    from strakalari.core.bakalari_client import BakalariClient

    class StubBM:
        page = None

    with pytest.raises(er.UserError):
        BakalariClient(StubBM(), {}).login()
    with pytest.raises(er.UserError):
        BakalariClient(StubBM(), {"bakalari_url": "https://x.example"}).login()


def test_is_timeout_error_classification():
    assert er.is_timeout_error(TimeoutError("Timeout 30000ms exceeded."))
    assert er.is_timeout_error(TimeoutError("login timed out"))
    assert er.is_timeout_error(
        Exception("Timeout 250ms exceeded. (budget 30000ms in 250ms slices)"))
    assert not er.is_timeout_error(RuntimeError("boom"))
    assert not er.is_timeout_error(RuntimeError("net::ERR_CONNECTION_REFUSED"))
    assert not er.is_timeout_error(InterruptedError("cancelled"))
    assert not er.is_timeout_error(None)
    try:
        raise er.UserError("Chybí URL Bakalářů — doplňte ho v Nastavení.")
    except er.UserError as exc:
        assert not er.is_timeout_error(exc)


def test_timeout_error_marks_report_friendly(state):
    try:
        raise TimeoutError("Timeout 30000ms exceeded.")
    except TimeoutError as exc:
        report = state.report_error("refresh (all)", exc)
    assert report["user_message"] == er.timeout_user_message()
    assert "Traceback" in report["traceback"]  # diagnostics still built for copy


def test_timeout_user_message_names_fix():
    text = er.timeout_user_message()
    assert "Nastavení" in text or "Settings" in text
    assert "síti" in text or "network" in text


def test_goto_timeout_raises_friendly_user_error():
    from strakalari.core.bakalari_client import BakalariClient

    class _TimeoutPage:
        def __init__(self):
            self.goto_calls = []

        def goto(self, url, timeout=None, wait_until=None):
            self.goto_calls.append(url)
            raise TimeoutError(f"Timeout {timeout}ms exceeded.")

    raw = _TimeoutPage()
    bm = type("BM", (), {"page": raw})()
    client = BakalariClient(bm, {"page_load_timeout_s": 5}, logger=None)
    with pytest.raises(er.UserError) as exc_info:
        client._goto("https://skola.bakalari.cz")
    assert str(exc_info.value) == er.timeout_user_message()
    assert raw.goto_calls == ["https://skola.bakalari.cz"]  # issued once, never refreshed


def test_goto_hard_error_reraises_unchanged():
    from strakalari.core.bakalari_client import BakalariClient

    class _RefusedPage:
        def goto(self, url, timeout=None, wait_until=None):
            raise RuntimeError("net::ERR_CONNECTION_REFUSED")

    bm = type("BM", (), {"page": _RefusedPage()})()
    client = BakalariClient(bm, {}, logger=None)
    with pytest.raises(RuntimeError):
        client._goto("https://skola.bakalari.cz")


def test_redact_text_scrubs_secret_values():
    config = {"bakalari_password": "hunter2-hunter2", "other": "x"}
    text = "login failed for hunter2-hunter2 at school"
    assert "hunter2-hunter2" not in er.redact_text(text, config)
    assert "***" in er.redact_text(text, config)


def test_report_never_contains_secrets(state):
    state.config.data["bakalari_password"] = "hunter2-hunter2"
    try:
        raise RuntimeError("boom hunter2-hunter2")
    except RuntimeError as exc:
        report = state.report_error("refresh (all)", exc)
    text = er.format_report(report)
    assert "hunter2-hunter2" not in text
    assert "boom" in text


# -- report content -------------------------------------------------------

def test_build_report_carries_diagnostics():
    try:
        raise ValueError("bad week number")
    except ValueError:
        tb = er.current_traceback()
    report = er.build_report(
        "refresh (all)", "ValueError: bad week number", tb,
        log_tail=["[10:00:01] Stahuji data z Bakalářů…"],
        config={"bakalari_url": "https://x.example"},
        extra={"scope": "all"},
    )
    assert report["operation"] == "refresh (all)"
    assert "Traceback" in report["traceback"]
    assert "bad week number" in report["traceback"]
    assert report["context"]["app_version"]
    assert report["context"]["platform"]
    assert report["log_tail"] == ["[10:00:01] Stahuji data z Bakalářů…"]
    assert report["config"]["bakalari_url"] == "set"

    text = er.format_report(report)
    for needle in ("Strakalari error report", "operation: refresh (all)",
                   "ValueError", "recent log", "config (values hidden"):
        assert needle in text


def test_short_summary_prefers_type_and_first_line():
    try:
        raise ConnectionError("timeout\nsecond line")
    except ConnectionError as exc:
        assert er.short_summary(exc) == "ConnectionError: timeout"
    assert er.short_summary(None, message="plain") == "plain"
    assert er.short_summary(None, message="") == "unknown error"


# -- AppState wiring ------------------------------------------------------

def test_report_error_queues_popup_with_traceback(state):
    state.log("[10:00:01] Stahuji data z Bakalářů…")
    try:
        raise TimeoutError("login timed out")
    except TimeoutError as exc:
        report = state.report_error("refresh (all)", exc)
    assert state.last_error is report
    assert state.error_dialog_pending is True
    assert state.status == "error"
    assert "TimeoutError" in report["summary"]
    assert "Traceback" in report["traceback"]
    text = state.error_report_text()
    assert "operation: refresh (all)" in text
    assert "Stahuji data" in text  # log context travels along


def test_report_error_outside_handler_still_safe(state):
    report = state.report_error("orders", message="empty payload")
    assert report["traceback"] == ""
    assert "no traceback" in state.error_report_text()


def test_acknowledge_clears_pending_but_keeps_report(state):
    state.report_error("excuse", message="nope")
    state.acknowledge_error()
    assert state.error_dialog_pending is False
    assert "nope" in state.error_report_text()


# -- dialog + clipboard ---------------------------------------------------

def test_copy_text_does_not_mount_clipboard_into_overlay(monkeypatch):
    """Regression: mounting ft.Clipboard into page.overlay crashes the client.

    Clipboard is a service (auto-registered on construction), not a visual
    control — appending it to the overlay tree made the frontend render
    "Unknown control: Clipboard" as a red error box on copy.
    """
    import flet as ft

    from strakalari.flet_ui import overlays as ov

    created = []

    class RecordingClipboard(ft.Clipboard):
        def __init__(self):
            super().__init__()
            created.append(self)
            self.saved = None

        async def set(self, value):  # noqa: D102 - matches ft.Clipboard.set
            self.saved = value

    monkeypatch.setattr(ft, "Clipboard", RecordingClipboard)
    page = FakePage()
    page.overlay = []  # no pre-mounted service double
    assert ov.copy_text(page, "hello logs") is True
    assert created and created[0].saved == "hello logs"
    assert page.overlay == []


def test_copy_text_writes_to_clipboard_service():
    from strakalari.flet_ui.overlays import copy_text

    page = FakePage()
    assert copy_text(page, "hello logs") is True
    assert page.saved_clipboard == "hello logs"
    assert copy_text(page, "") is False
    assert page.saved_clipboard == "hello logs"  # empty write is a no-op


def test_error_dialog_copy_button_copies_report():
    import flet as ft

    from strakalari.flet_ui.overlays import show_error_dialog

    page = FakePage()
    report = "Strakalari error report\nerror: ValueError: x\n"
    dlg = show_error_dialog(page, "Něco se pokazilo", "ValueError: x", report)
    assert page.shown is dlg
    assert isinstance(dlg, ft.AlertDialog)
    copy_btn = dlg.actions[1]
    copy_btn.on_click(object())
    assert page.saved_clipboard == report
    # ft.Button has no .text — the label lives in .content (an ft.Text
    # after the click flips it to the "copied" confirmation).
    copy_content = getattr(copy_btn, "content", None)
    copy_label = getattr(copy_btn, "text", None) or getattr(
        copy_content, "value", copy_content)
    assert copy_label  # label flips to the "copied" confirmation
    close_btn = dlg.actions[0]
    close_content = getattr(close_btn, "content", None)
    close_label = getattr(close_btn, "text", None) or getattr(
        close_content, "value", close_content)
    assert close_label  # close button labelled


def test_shell_pops_queued_error_once(monkeypatch):
    import unittest.mock as mock

    import strakalari.flet_ui.state as state_mod
    from strakalari.flet_ui.app import Shell

    with mock.patch.object(state_mod, "load_data_cache", lambda: {}):
        full = state_mod.AppState()
    monkeypatch.setattr(full, "_emit", lambda: None)
    full.wizard_dismissed = True
    try:
        raise RuntimeError("view boom")
    except RuntimeError as exc:
        full.report_error("refresh (all)", exc)
    assert full.error_dialog_pending is True

    page = FakePage()
    shell = Shell(page, full)
    shell.render()
    assert full.error_dialog_pending is False
    assert page.shown is not None
    summary_text = page.shown.content.content.controls[0].value
    assert "RuntimeError: view boom" in summary_text
    # Second render must not re-open the dialog.
    page.shown = None
    shell.render()
    assert page.shown is None


def test_extra_secrets_redacted():
    from strakalari.core.error_report import build_report, format_report

    config = {"bakalari_password": "s3cr3t-pass", "pin_token": "123", "num_secret": 12345}
    rep = build_report("op", "boom", config=config,
                       extra={"label": "leak s3cr3t-pass here", "pin": "code 123 done"})
    text = format_report(rep)
    assert "s3cr3t-pass" not in text
    assert "code 123 done" not in text  # short PIN redacted on token boundary
    assert "***" in text


def test_redact_text_numeric_and_short():
    from strakalari.core.error_report import redact_text

    config = {"api_token": 12345, "pin_token": "abc"}
    assert "12345" not in redact_text("key 12345 used", config)
    assert redact_text("use abc now", config) != "use abc now"
    # ...but prose without the token is untouched
    assert redact_text("nothing here", config) == "nothing here"


def test_redact_text_scrubs_decrypted_password_and_personal_data():
    from strakalari.core.error_report import redact_text
    from strakalari.core.helpers import encrypt

    config = {
        "bakalari_password": encrypt("Tajne-Heslo-42"),
        "bakalari_password_encrypted": True,
        "bakalari_username": "novak.jan",
        "your_signature": "Jan Novák, 3.B",
    }
    text = ('locator.fill("Tajne-Heslo-42") for novak.jan\n'
            "signed Jan Novák, 3.B / Novák")
    out = redact_text(text, config)
    for leaked in ("Tajne-Heslo-42", "novak.jan", "Novák"):
        assert leaked not in out


def test_report_log_tail_is_context_not_traceback_copy(state):
    for i in range(80):
        state.log(f"step {i}")
    try:
        raise ValueError("boom")
    except ValueError as exc:
        report = state.report_error("refresh (all)", exc)
    tail = report["log_tail"]
    assert len(tail) == er.LOG_TAIL_LINES
    assert tail[-1].endswith("step 79")  # what the app did right before
    assert not any("Traceback" in line for line in tail)
    assert "Traceback" in report["traceback"]


def test_report_is_persisted_redacted_to_stderr(state, capsys):
    state.config.data["bakalari_password"] = "hunter2secret"
    try:
        raise RuntimeError("fill failed: hunter2secret")
    except RuntimeError as exc:
        state.report_error("excuse", exc)
    out = capsys.readouterr().out
    assert "Error report:" in out and "operation: excuse" in out
    assert "hunter2secret" not in out


def test_context_names_build_and_language():
    ctx = er.collect_context()
    assert ctx["build"] in ("installer", "source")
    assert ctx["language"] in ("cs", "en")
