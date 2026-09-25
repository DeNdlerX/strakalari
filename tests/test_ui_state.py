"""AppState behavior (status, log, routing, credentials, saves)."""
from datetime import datetime, timedelta


def test_status_kind_transitions(state):
    assert state.status_kind() == "idle"
    state.refresh_running = True
    assert state.status_kind() == "working"
    state.refresh_running = False
    state.runs.append({"ok": True, "finished": "now", "started": "now"})
    assert state.status_kind() == "ok"
    state.status = "error"
    # A running refresh always wins over the error flag.
    state.refresh_running = True
    assert state.status_kind() == "working"
    state.refresh_running = False
    assert state.status_kind() == "error"


def test_manual_sends_show_as_working(state):
    """Excuse sends and lunch orders read like a refresh in the top bar."""
    from strakalari.flet_ui.strings import S

    assert state.sending_label == ""
    state.sending_excuses.add("2026-09-25|1|M")
    assert state.sending_label == S("excuse_sending")
    assert state.status_kind() == "working"
    state.sending_excuses.clear()
    state.order_running = True
    assert state.sending_label == S("orders_sending")
    assert state.status_kind() == "working"
    state.order_running = False
    assert state.sending_label == ""
    assert state.status_kind() == "idle"


def test_last_run_label(state):
    assert state.last_run_label == "—"
    state.runs.append({"ok": True, "finished": "07.09. 10:05", "started": "10:00"})
    assert state.last_run_label.startswith("✓")
    state.runs.append({"ok": False, "finished": "07.09. 11:00", "started": "10:55"})
    assert state.last_run_label.startswith("✗")


def test_next_run_label(state):
    assert state.next_run_label == "—"
    state.scheduler_last_run = datetime.now() - timedelta(minutes=30)
    label = state.next_run_label
    assert label != "—" and "." in label


def test_log_ring_buffer_caps(state):
    for i in range(350):
        # Bypass _emit spam: log() emits, so just check the final length.
        state.log_lines.append(f"line {i}")
    state.log("final")
    assert len(state.log_lines) == 300
    assert state.log_lines[-1].endswith("final")


def test_show_browser_mapping(state, monkeypatch):
    monkeypatch.setitem(state.config.data, "hide_window", True)
    assert state.show_browser is False
    monkeypatch.setitem(state.config.data, "hide_window", False)
    assert state.show_browser is True


def test_set_timetable_view_validation(state):
    state.set_timetable_view("nonsense")
    assert state.timetable_view == "table"
    state.set_timetable_view("list")
    assert state.timetable_view == "list"


def test_go_sets_pending_route(state):
    state.go("settings")
    assert state.pending_route == "settings"


def test_cancel_lunch_order(state, monkeypatch):
    # Cutoff-independent: this test covers stage/drop bookkeeping.
    monkeypatch.setattr(state, "is_lunch_order_open", lambda day, now=None: True)
    assert state.order_lunch("07.09.2026", "abc") is True
    assert state.orders.get("07.09.2026") == "abc"
    state.cancel_lunch_order("07.09.2026")
    assert "07.09.2026" not in state.orders


def test_start_refresh_rejects_bad_scope_gracefully(state, monkeypatch):
    # Don't run the worker thread; just verify the busy guard + scope norm.
    started = []

    def fake_work(scope):
        started.append(scope)
        state.refresh_running = False
        state.status = "idle"

    monkeypatch.setattr(state, "_refresh_work", fake_work)
    import threading

    real_thread = threading.Thread

    class ImmediateThread:
        def __init__(self, target=None, args=(), **kwargs):
            self._target, self._args = target, args

        def start(self):
            self._target(*self._args)

    monkeypatch.setattr(threading, "Thread", ImmediateThread)
    try:
        assert state.start_refresh("bogus") is True
    finally:
        monkeypatch.setattr(threading, "Thread", real_thread)
    assert started == ["all"]
    # Busy guard.
    state.refresh_running = True
    assert state.start_refresh("all") is False
    state.refresh_running = False


def test_state_save_reports_failure(monkeypatch):
    from strakalari.flet_ui.state import AppState

    st = AppState.__new__(AppState)
    calls = {}

    class _Cfg:
        def set(self, k, v):
            calls[k] = v

        def save(self):
            raise OSError("disk gone")

    st.config = _Cfg()
    st._refresh_tokens = lambda: calls.setdefault("tok", True)
    st._emit = lambda: None
    assert st.save({"a": 1}) is False


def test_subject_states_empty_without_timetable():
    from strakalari.flet_ui.state import AppState

    st = AppState.__new__(AppState)
    st.data = {}
    st.demo_mode = True
    states, days = AppState.subject_states(st)
    assert states == [] and days == []


def test_needs_setup_false_with_strava_only(app_state):
    app_state.config.data.update({
        "strava_username": "novak",
        "strava_password": "x",
        "strava_canteen_id": "123",
    })
    assert app_state._has_credentials() is False
    assert app_state._has_strava_credentials() is True
    assert app_state._has_any_credentials() is True
    assert app_state.needs_setup() is False


def test_needs_setup_true_with_nothing(app_state):
    assert app_state._has_any_credentials() is False
    assert app_state.needs_setup() is True
