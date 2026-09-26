""""Excuse day" claims a whole day only when the whole day was missed."""



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
