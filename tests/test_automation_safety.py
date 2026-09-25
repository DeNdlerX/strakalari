"""Guard rails: automation history, pause switch, loud auto failures."""
from strakalari.core import audit
from strakalari.core.refresh import AutomationError, automation_paused, run_refresh
from tests.test_refresh_pipeline import CONFIG, FakeApp
from tests.test_strava_ordering import DAY1, DAY2, _app, _Client


def test_audit_roundtrip_newest_first():
    assert audit.recent() == []
    assert audit.record("excuse", "sent", "auto", "01.09.2026")
    assert audit.record("lunch", "dry_run", "manual", "02.09.2026: order")
    items = audit.recent()
    assert [i["kind"] for i in items] == ["lunch", "excuse"]
    assert items[1]["source"] == "auto"
    assert audit.has_dry_run("lunch") and not audit.has_dry_run("excuse")


def test_audit_skips_corrupt_lines():
    audit.record("excuse", "sent", "manual", "x")
    with open(audit.history_path(), "a", encoding="utf-8") as f:
        f.write("{not json\n")
    assert len(audit.recent()) == 1


def test_describe_excuse_has_no_text():
    label = audit.describe_excuse({"type": "days and hours", "starting_day": "01.09.2026",
                                   "ending_day": "01.09.2026", "starting_lesson": 2,
                                   "ending_lesson": 4})
    assert label == "01.09.2026 (2.–4.)"


def test_automation_paused_flag_parsing():
    assert automation_paused({"automation_paused": True})
    assert automation_paused({"automation_paused": "true"})
    assert not automation_paused({"automation_paused": False})
    assert not automation_paused({})


def test_paused_refresh_never_sends_or_orders():
    calls = []
    cfg = dict(CONFIG, automation_paused=True)
    result = run_refresh(FakeApp(calls, excuse_mode="auto", order_mode="auto"), cfg)
    assert "excuse" not in calls
    assert not [c for c in calls if isinstance(c, tuple) and c[0] == "order"]
    assert result.automation_paused
    # Fetching still works while paused.
    assert result.bakalari_fetched and result.strava_fetched


def test_failed_auto_excuse_is_an_error_but_data_is_fresh():
    class _App(FakeApp):
        def excuseAbsence(self):
            self.last_excuse_failures = 2
            return 1

    result = run_refresh(_App([], excuse_mode="auto"), CONFIG)
    assert result.excuses_sent == 1 and result.excuses_failed == 2
    assert [p for p, _ in result.automation_errors] == ["auto_excuse"]
    assert isinstance(result.automation_errors[0][1], AutomationError)
    # Fetch itself was fine: the freshness stamp still moves.
    assert "last_updated" in result.saved


def test_failed_auto_order_is_reported():
    class _App(FakeApp):
        def stravaOrderSelected(self, orders, source="manual"):
            self.last_ordered_days = set()
            return False

    result = run_refresh(_App([], order_mode="auto"), CONFIG)
    assert [p for p, _ in result.automation_errors] == ["auto_lunch"]
    assert result.lunches_ordered == 0


def test_order_outcomes_are_recorded_per_day():
    client = _Client({"a&2&0": True, "b&2&0": False})
    app = _app(client)
    assert app.stravaOrderSelected({DAY1: "a&2&0", DAY2: "b&2&0"}, source="auto") is False
    outcomes = {i["detail"]["day"]: i["outcome"] for i in audit.recent()}
    # Nothing is placed when any day fails (fail-closed, restored).
    assert outcomes == {DAY1: "failed", DAY2: "failed"}
    assert all(i["source"] == "auto" for i in audit.recent())


def test_successful_order_is_recorded_as_sent():
    client = _Client({"a&2&0": True, "b&2&0": True})
    app = _app(client)
    assert app.stravaOrderSelected({DAY1: "a&2&0", DAY2: "b&2&0"}) is True
    assert {i["outcome"] for i in audit.recent()} == {"sent"}


def test_dry_run_order_is_recorded_as_dry_run():
    client = _Client({})
    app = _app(client)
    app.strava_order_mode = "dry_run"
    assert app.stravaOrderSelected({DAY1: "a&2&0"}) is True
    assert audit.recent()[0]["outcome"] == "dry_run"
    assert audit.has_dry_run("lunch")


def test_excuse_outcomes_are_recorded(tmp_path):
    from tests.test_excuse_history import _app as _excuse_app
    from tests.test_excuse_history import _day

    app, client = _excuse_app(tmp_path)
    excuse = _day("21.09.2026", 3, 3)
    assert app._send_excuse(dict(excuse), "x", source="auto") == "sent"
    assert app._send_excuse(dict(excuse), "x") == "covered"
    client.execute_excuse.side_effect = lambda *a, **k: False
    assert app._send_excuse(_day("22.09.2026", 1, 1), "x") == "failed"
    items = audit.recent()
    assert [i["outcome"] for i in items] == ["failed", "covered", "sent"]
    assert items[-1]["source"] == "auto"
    # Only dates/lessons are stored — never the excuse wording.
    assert all("x" != i["summary"] for i in items)


def test_auto_excuse_counts_failures(tmp_path):
    from tests.test_excuse_history import _app as _excuse_app

    app, client = _excuse_app(tmp_path)
    client.execute_excuse.side_effect = lambda *a, **k: False
    client.timetableData = {"01.09.2026": [
        {"teacher": "T", "subject": "M", "time": "1 (8:00)", "absenceType": "absent"},
    ]}
    app.excuse_delay_days = 0
    app.default_excuse_text = lambda excuse: "x"
    app.cancel_requested = False
    app.cancel_callback = None
    assert app.excuseAbsence() == 0
    assert app.last_excuse_failures == 1


class _Page:
    def __init__(self):
        self.dialogs = []

    def show_dialog(self, dlg):
        self.dialogs.append(dlg)

    def pop_dialog(self):
        return self.dialogs.pop() if self.dialogs else None

    def update(self):
        pass


def _texts(dlg):
    return " ".join(str(getattr(c, "value", "")) for c in dlg.content.controls)


def test_auto_confirm_dialog_recommends_dry_run_first():
    from strakalari.flet_ui.safety import confirm_auto_mode

    page, picked = _Page(), []
    dlg = confirm_auto_mode(page, "excuse_mode", lambda: picked.append("auto"),
                            lambda: picked.append("dry"), lambda: picked.append("cancel"))
    from strakalari.flet_ui.strings import S

    assert S("auto_confirm_no_dry_run") in _texts(dlg)
    dlg.actions[1].on_click(None)  # "Dry run first"
    dlg.on_dismiss(None)  # closing afterwards must not also cancel
    assert picked == ["dry"]


def test_auto_confirm_dialog_after_dry_run():
    from strakalari.flet_ui.safety import confirm_auto_mode
    from strakalari.flet_ui.strings import S

    audit.record("lunch", "dry_run", "manual", "x")
    page, picked = _Page(), []
    dlg = confirm_auto_mode(page, "strava_order_mode", lambda: picked.append("auto"),
                            lambda: picked.append("dry"), lambda: picked.append("cancel"))
    assert S("auto_confirm_no_dry_run") not in _texts(dlg)
    dlg.actions[2].on_click(None)
    assert picked == ["auto"]


def test_pause_toggle_persists(state):
    state.save = type(state).save.__get__(state)  # real save (tmp config)
    assert state.automation_paused() is False
    assert state.set_automation_paused(True)
    assert state.automation_paused() is True
    assert state.config.data["automation_paused"] is True
