""""Excuse day" claims a whole day only when the whole day was missed, and
sends every lesson as its own excuse when the day card's switch is on."""



# -- "Excuse day" only claims a whole day when the whole day was missed ------

def _day_state(state, lessons, tasks):
    state.demo_mode = False
    state.data = {"timetable": {"18.09.2026": lessons}}
    state.excuse_tasks = lambda: tasks
    return state


def _lesson(period, subject, absent=True):
    return {"subject": subject, "teacher": "T", "time": f"{period} (8:00 - 8:45)",
            "absenceType": "Absent" if absent else "NoAbsent"}


def _task(period, subject, kind="short"):
    return {"key": f"2026-09-18|{period}|{subject}", "kind": kind, "label": subject,
            "date": "2026-09-18", "period": period}


def test_fully_absent_day_is_one_whole_day_excuse(state):
    st = _day_state(state, [_lesson(1, "M"), _lesson(2, "F")],
                    [_task(1, "M"), _task(2, "F")])
    assert st.day_fully_absent("2026-09-18") is True
    assert st.day_excuse_plan("2026-09-18") == [
        {"type": "pure days", "starting_day": "18.09.2026", "ending_day": "18.09.2026"}]


def test_partial_day_becomes_lesson_ranges(state):
    st = _day_state(state,
                    [_lesson(1, "M"), _lesson(2, "F"), _lesson(3, "Ch", absent=False),
                     _lesson(4, "D"), _lesson(5, "Z")],
                    [_task(1, "M", kind="late"), _task(2, "F"), _task(4, "D"), _task(5, "Z")])
    assert st.day_fully_absent("2026-09-18") is False
    plan = st.day_excuse_plan("2026-09-18")
    assert {"type": "income", "starting_day": "18.09.2026", "ending_day": "18.09.2026",
            "starting_lesson": 1, "ending_lesson": 1} in plan
    ranges = [(p["starting_lesson"], p["ending_lesson"]) for p in plan
              if p["type"] == "days and hours"]
    assert sorted(ranges) == [(2, 2), (4, 5)]


# -- "Each lesson separately": one excuse (one message) per lesson ------------

def test_per_lesson_splits_a_fully_absent_day(state):
    st = _day_state(state, [_lesson(1, "M"), _lesson(2, "F")],
                    [_task(2, "F"), _task(1, "M")])
    assert st.day_excuse_plan("2026-09-18", per_lesson=True) == [
        {"type": "days and hours", "starting_day": "18.09.2026", "ending_day": "18.09.2026",
         "starting_lesson": 1, "ending_lesson": 1},
        {"type": "days and hours", "starting_day": "18.09.2026", "ending_day": "18.09.2026",
         "starting_lesson": 2, "ending_lesson": 2},
    ]


def test_per_lesson_never_merges_ranges_and_keeps_late_arrivals(state):
    st = _day_state(state,
                    [_lesson(1, "M"), _lesson(2, "F"), _lesson(3, "Ch", absent=False),
                     _lesson(4, "D"), _lesson(5, "Z"), _lesson(6, "Tv")],
                    [_task(1, "M", kind="late"), _task(2, "F"), _task(4, "D"), _task(5, "Z"),
                     _task(6, "Tv", kind="early")])
    plan = st.day_excuse_plan("2026-09-18", per_lesson=True)
    assert [(p["type"], p["starting_lesson"], p["ending_lesson"]) for p in plan] == [
        ("income", 1, 1), ("days and hours", 2, 2), ("days and hours", 4, 4),
        ("days and hours", 5, 5), ("soon", 6, 6)]


def _sending_state(monkeypatch, tasks):
    """A bare AppState whose worker runs inline against a recording client."""
    import threading

    import strakalari.core.automation as auto_mod
    from strakalari.flet_ui.state import AppState

    sent = []

    class _App:
        excuse_mode = "confirm"

        def __init__(self, *a, **k):
            pass

        def send_excuse_outcome(self, excuse, custom_text=None):
            sent.append((excuse, custom_text))
            return "sent"

        def close(self):
            pass

    monkeypatch.setattr(auto_mod, "Strakalari", _App)
    st = AppState.__new__(AppState)
    st._flight_lock = threading.Lock()
    st.sending_excuses = set()
    st.excuse_log = []
    st.demo_mode = False
    st.log_lines = []
    st.log = st.log_lines.append
    st._worker_log = st.log_lines.append
    st._core_log = st.log_lines.append
    st._emit = lambda: None
    st._notify = lambda *a, **k: None
    st.report_error = lambda *a, **k: None
    st.tutorial_event = lambda *a, **k: None
    st._spawn = lambda fn, name=None: fn()
    st.current_step = ""
    st.excuse_tasks = lambda: tasks
    st.timetable = lambda: {"18.09.2026": [_lesson(1, "M"), _lesson(2, "F")]}
    return st, sent


def test_submit_day_excuse_per_lesson_sends_one_message_per_lesson(monkeypatch):
    tasks = [_task(1, "M"), _task(2, "F")]
    st, sent = _sending_state(monkeypatch, tasks)
    assert st.submit_day_excuse("2026-09-18", template="Omluvte", page=None,
                                per_lesson=True) is True
    assert [(e["type"], e["starting_lesson"], e["ending_lesson"], text) for e, text in sent] == [
        ("days and hours", 1, 1, "Omluvte"), ("days and hours", 2, 2, "Omluvte")]
    assert sorted(entry["key"] for entry in st.excuse_log) == sorted(t["key"] for t in tasks)
    assert st.sending_excuses == set()


def test_submit_day_excuse_without_the_switch_stays_one_whole_day(monkeypatch):
    st, sent = _sending_state(monkeypatch, [_task(1, "M"), _task(2, "F")])
    assert st.submit_day_excuse("2026-09-18", template="Omluvte", page=None) is True
    assert [e["type"] for e, _text in sent] == ["pure days"]


def _day_card(state, tasks):
    import flet as ft

    from strakalari.flet_ui.views import today

    blocks = today._excuse_cards(state, None, tasks)
    controls, stack = [], list(reversed(blocks))  # walked in display order
    while stack:
        ctl = stack.pop()
        if ctl is None:
            continue
        controls.append(ctl)
        for attr in ("title", "controls", "content"):
            child = getattr(ctl, attr, None)
            if isinstance(child, (list, tuple)):
                stack.extend(reversed(child))
            elif child is not None:
                stack.append(child)
    switches = [c for c in controls if isinstance(c, ft.Switch)]
    buttons = [c for c in controls if isinstance(c, ft.Button)
               and not isinstance(c, ft.OutlinedButton)]
    return switches, buttons, [str(getattr(c, "value", "") or "") for c in controls]


def test_day_card_switch_sends_lessons_separately(state, monkeypatch):
    tasks = [_task(1, "M"), _task(2, "F")]
    st = _day_state(state, [_lesson(1, "M"), _lesson(2, "F")], tasks)
    st.config.set("your_signature", "Jan Novák")
    calls = []
    monkeypatch.setattr(st, "submit_day_excuse",
                        lambda iso, text, page, per_lesson=False: calls.append((iso, per_lesson)) or True)

    switches, buttons, _texts = _day_card(st, tasks)
    assert len(switches) == 1 and switches[0].value is False
    assert buttons[0].content.value in ("Omluvit celý den", "Excuse whole day")
    buttons[0].on_click(None)

    st.config.set("excuse_day_per_lesson", True)
    switches, buttons, texts = _day_card(st, tasks)
    assert switches[0].value is True
    assert buttons[0].content.value in ("Omluvit 2 hodiny", "Excuse 2 lessons")
    assert any(t.startswith(("2 hodiny zvlášť", "2 lessons separately")) for t in texts)
    buttons[0].on_click(None)
    assert calls == [("2026-09-18", False), ("2026-09-18", True)]


def test_day_card_switch_is_remembered_and_a_failed_save_restores_it(app_state, monkeypatch):
    assert app_state.excuse_day_per_lesson() is False
    assert app_state.set_excuse_day_per_lesson(True) is True
    assert app_state.excuse_day_per_lesson() is True

    def _broken_save():
        raise OSError("disk full")

    monkeypatch.setattr(app_state.config, "save", _broken_save)
    assert app_state.set_excuse_day_per_lesson(False) is False
    assert app_state.excuse_day_per_lesson() is True
