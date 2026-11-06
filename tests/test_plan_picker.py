"""Custom days-off picker: tap a day in the calendar, untick lessons.

Drives the dialog through its controls (FakePage from the planner dialog
tests): a tapped day is taken off whole, its lessons — with the week's
substitutions and cancellations — can be unticked one by one, and Confirm
plans the fewest entries that cover exactly the picked lessons.
"""

from datetime import date, datetime
from types import SimpleNamespace

import flet as ft

from strakalari.core.schedule import baseline_from_dict
from strakalari.flet_ui import components as C
from strakalari.flet_ui.views import planner as P

from .test_planner_dialog import FakePage, FakeState

MONDAY = date(2026, 11, 9)
TIMES = ["8:00 - 8:45", "8:55 - 9:40", "10:00 - 10:45", "10:55 - 11:40", "11:50 - 12:35"]
WEEK = [["Matematika", "Fyzika", "Chemie", "Dějepis", "Biologie"],
        ["Chemie", "Matematika", "Biologie", "Fyzika", "Dějepis"]]


def _row(subject, period, **extra):
    row = {"subject": subject, "teacher": f"Mgr. Jan {subject}", "room": "U1",
           "time": f"{period} ({TIMES[period - 1]})", "period": period, "notice": "",
           "absenceType": "NoAbsent", "absencetext": ""}
    row.update(extra)
    return row


def _baseline():
    raw = {}
    for wd in range(5):
        for i, subject in enumerate(WEEK[wd % 2]):
            raw[f"{wd}|{i + 1}"] = {"weekday": wd, "period": i + 1, "subject": subject,
                                    "teacher": f"Mgr. Jan {subject}", "room": "U1"}
    return baseline_from_dict(raw)


def _timetable():
    """Mon + Tue of the fetched week; Tuesday has a substitution and a cancellation."""
    mon = [_row(s, i + 1) for i, s in enumerate(WEEK[0])]
    tue = [_row(s, i + 1) for i, s in enumerate(WEEK[1])]
    tue[1] = _row("Matematika", 2, notice="Suplování", teacher="Mgr. Petr Novák")
    tue[3] = _row("Fyzika", 4, notice="Odpadá")
    return {"09.11.2026": mon, "10.11.2026": tue}


class PickerState(FakeState):
    def __init__(self, planned=(), holidays=()):
        super().__init__()
        self.planned_skips = list(planned)
        self.entries = []
        self._holidays = set(holidays)

    def timetable(self):
        return _timetable()

    def stable_baseline(self):
        return _baseline()

    def stable_complete(self):
        return True

    def calendar_data(self):
        return self._holidays, {d: "Svátek" for d in self._holidays}, {}

    def plan_entries(self, entries):
        self.entries.extend(entries)
        return len(entries)


def _walk(control):
    yield control
    content = getattr(control, "content", None)
    if isinstance(content, ft.Control):
        yield from _walk(content)
    for child in getattr(control, "controls", None) or []:
        yield from _walk(child)


def _texts(control):
    out = []
    for c in _walk(control):
        if isinstance(c, ft.Text):
            if c.value:
                out.append(str(c.value))
            out.extend(str(s.text) for s in (c.spans or []))
    return out


def _open(state, now=datetime(2026, 11, 9, 7, 0), preselect=None):
    page = FakePage()
    P._custom_plan_dialog(state, page, now, preselect=preselect)
    return page, page._dialogs[-1]


def _cell(dlg, day):
    label = f"{C.day_name(day, short=True)} {C.cz_day(day)}"
    for c in _walk(dlg.content):
        if isinstance(c, ft.Container) and str(c.tooltip or "").startswith(label):
            return c
    raise AssertionError(f"no calendar cell for {label}")


def _lesson(dlg, subject):
    """The lesson row whose title is ``subject`` (in the open day)."""
    for c in _walk(dlg.content):
        if (isinstance(c, ft.Container) and isinstance(c.content, ft.Row)
                and len(c.content.controls) == 3
                and isinstance(c.content.controls[2], ft.Column)
                and c.content.controls[2].controls[0].value == subject):
            return c
    raise AssertionError(f"no lesson row {subject}")


def _tap(control):
    assert control.on_click is not None, "control is not tappable"
    control.on_click(SimpleNamespace())


def _confirm(dlg):
    dlg.actions[1].on_click(SimpleNamespace())


def test_tapping_a_day_takes_it_off_whole():
    state = PickerState()
    page, dlg = _open(state)
    assert dlg.actions[1].disabled  # nothing picked yet
    _tap(_cell(dlg, MONDAY))
    assert not dlg.actions[1].disabled
    _confirm(dlg)
    assert dlg.open is False
    assert [(e["start_date"], e["end_date"], e.get("start_period"), e.get("end_period"))
            for e in state.entries] == [("2026-11-09", "2026-11-09", None, None)]


def test_tapping_a_picked_day_again_unpicks_it():
    state = PickerState()
    _page, dlg = _open(state)
    _tap(_cell(dlg, MONDAY))
    _tap(_cell(dlg, MONDAY))
    assert dlg.actions[1].disabled


def test_unticked_lessons_stay_attended():
    state = PickerState()
    _page, dlg = _open(state)
    _tap(_cell(dlg, MONDAY))
    _tap(_lesson(dlg, "Matematika"))  # 1st lesson: going to school for it
    _tap(_lesson(dlg, "Fyzika"))  # 2nd as well
    _confirm(dlg)
    assert [(e["start_date"], e.get("start_period"), e.get("end_period"))
            for e in state.entries] == [("2026-11-09", 3, None)]


def test_days_in_a_row_become_one_range():
    state = PickerState()
    _page, dlg = _open(state)
    _tap(_cell(dlg, MONDAY))
    _tap(_cell(dlg, date(2026, 11, 10)))
    _confirm(dlg)
    assert [(e["start_date"], e["end_date"]) for e in state.entries] == [
        ("2026-11-09", "2026-11-10")]


def test_week_changes_are_shown_and_cancelled_lessons_locked():
    state = PickerState()
    _page, dlg = _open(state)
    tue = date(2026, 11, 10)
    assert P.S("pick_tip_change") in str(_cell(dlg, tue).tooltip)
    assert P.S("pick_tip_change") not in str(_cell(dlg, MONDAY).tooltip)
    _tap(_cell(dlg, tue))
    texts = _texts(dlg.content)
    assert P.S("tag_substitution") in texts
    assert P.S("status_lesson_cancelled") in texts
    cancelled = _lesson(dlg, "Fyzika")
    assert cancelled.on_click is None
    # Lesson 4 is cancelled: unticking lessons 1-3 still leaves one whole block.
    for subject in ("Chemie", "Matematika", "Biologie"):
        _tap(_lesson(dlg, subject))
    _confirm(dlg)
    assert [(e.get("start_period"), e.get("end_period")) for e in state.entries] == [(5, None)]


def test_unfetched_week_uses_the_stable_timetable():
    state = PickerState()
    _page, dlg = _open(state)
    thursday = date(2026, 11, 19)
    _tap(_cell(dlg, thursday))
    texts = _texts(dlg.content)
    assert P.S("pick_from_stable") in texts
    assert "Chemie" in texts  # Thursday's template (odd weekday pattern)
    # The template has no clock times: no bare period number as the "time".
    assert not [t for t in texts if t[:1].isdigit() and " · " in t]


def test_already_planned_lessons_are_locked_and_split_the_pick():
    planned = [{"start_date": "2026-11-09", "end_date": "2026-11-09",
                "start_period": 3, "end_period": 3, "template": "x"}]
    state = PickerState(planned=planned)
    _page, dlg = _open(state)
    _tap(_cell(dlg, MONDAY))
    assert _lesson(dlg, "Chemie").on_click is None
    _confirm(dlg)
    assert [(e.get("start_period"), e.get("end_period")) for e in state.entries] == [
        (None, 2), (4, None)]


def test_fully_planned_days_and_holidays_cannot_be_tapped():
    planned = [{"start_date": "2026-11-09", "end_date": "2026-11-09", "template": "x"}]
    holiday = date(2026, 11, 17)
    state = PickerState(planned=planned, holidays={holiday})
    _page, dlg = _open(state)
    assert _cell(dlg, MONDAY).on_click is None
    assert _cell(dlg, holiday).on_click is None
    assert "Svátek" in str(_cell(dlg, holiday).tooltip)


def test_started_lessons_today_cannot_be_picked():
    state = PickerState()
    _page, dlg = _open(state, now=datetime(2026, 11, 9, 10, 30))
    _tap(_cell(dlg, MONDAY))
    assert _lesson(dlg, "Matematika").on_click is None  # 8:00, long over
    assert _lesson(dlg, "Dějepis").on_click is not None  # 10:55, still ahead
    _confirm(dlg)
    assert [(e["start_date"], e.get("start_period"), e.get("end_period"))
            for e in state.entries] == [("2026-11-09", 4, None)]


def test_past_days_are_not_tappable():
    state = PickerState()
    _page, dlg = _open(state, now=datetime(2026, 11, 11, 7, 0))
    assert _cell(dlg, MONDAY).on_click is None


def test_whole_day_switch_clears_and_refills_the_day():
    state = PickerState()
    _page, dlg = _open(state, preselect=MONDAY)
    assert not dlg.actions[1].disabled  # opened with Monday picked
    whole = next(c for c in _walk(dlg.content)
                 if isinstance(c, ft.Container) and P.S("whole_day") in _texts(c)
                 and c.on_click is not None and isinstance(c.content, ft.Row)
                 and len(c.content.controls) == 2)
    _tap(whole)
    assert dlg.actions[1].disabled
    _tap(_lesson(dlg, "Biologie"))
    _confirm(dlg)
    assert [(e.get("start_period"), e.get("end_period")) for e in state.entries] == [(5, None)]


def test_month_navigation_stays_inside_the_school_year():
    state = PickerState()
    _page, dlg = _open(state)
    prev_btn = next(c for c in _walk(dlg.content) if isinstance(c, ft.IconButton)
                    and c.icon == ft.Icons.CHEVRON_LEFT)
    assert prev_btn.disabled  # November: nothing earlier to plan
    next_btn = next(c for c in _walk(dlg.content) if isinstance(c, ft.IconButton)
                    and c.icon == ft.Icons.CHEVRON_RIGHT)
    next_btn.on_click(SimpleNamespace())
    assert _cell(dlg, date(2026, 12, 1)) is not None
