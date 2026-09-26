"""Flet views build and reuse their controls."""
from types import SimpleNamespace


class TestPlannerSignature:
    def test_signature_not_duplicated(self):
        from strakalari.flet_ui.views.planner import _templates
        state = SimpleNamespace(
            get=lambda k, d=None: {
                "long_absence_excuses": ["Omluvte absenci.\nJan Novák"],
                "short_absence_excuses": [],
                "late_income_excuses": [],
                "your_signature": "jan novák",
            }.get(k, d)
        )
        templates = _templates(state)
        assert templates[0].lower().count("jan novák") == 1


def test_timetable_period_helpers():
    from strakalari.flet_ui.views.timetable import _period_of, _period_time

    assert _period_of({"time": "3 (10:05 - 10:50)"}, "07.09.2026") == 3
    assert _period_of({"time": "1. 8:00 - 8:45"}, "07.09.2026") == 1
    assert _period_of({"time": "nonsense"}, "07.09.2026") is None

    week = {
        "07.09.2026": [{"time": "1. 8:00 - 8:45"}, {"time": "2. 8:55 - 9:40"}],
        "08.09.2026": [{"time": "1. 8:00 - 8:45"}],
    }
    assert _period_time(week, 1) == "8:00 - 8:45"
    assert _period_time(week, 9) == ""


def test_table_view_structure(state):
    from strakalari.flet_ui.views.timetable import _table_view

    week = {
        __import__("datetime").date(2026, 9, 7): [
            {"subject": "M", "time": "1. 8:00 - 8:45", "room": "U12", "teacher": "Novák"},
            {"subject": "F", "time": "2. 8:55 - 9:40", "room": "F11", "teacher": "Dvořák",
             "status": "late"},
        ],
        __import__("datetime").date(2026, 9, 8): [
            {"subject": "C", "time": "1. 8:00 - 8:45", "room": "U08", "teacher": "Svobodová"},
        ],
    }
    names = ["Po", "Út", "St", "Čt", "Pá", "So", "Ne"]
    grid = _table_view(state, None, week, names)
    # Column[header, one row per day]: 2 days + header.
    assert len(grid.controls) == 3
    # Header has gutter + 2 period columns; each day row likewise.
    header, monday, tuesday = (c.content for c in grid.controls)
    assert len(header.controls) == 3
    assert len(monday.controls) == 3
    # Cells share the width instead of forcing a horizontal scroll.
    assert all(cell.expand for cell in monday.controls[1:])
    # A free period is blank: no frame, no fill, not clickable.
    free = tuesday.controls[2]
    assert free.content is None and free.bgcolor is None
    assert free.border is None and free.on_click is None


def test_all_views_build_headless(state):
    from strakalari.flet_ui.views import (
        absences, activity, lunches, marks, planner, settings, timetable, today,
    )

    for mod in (today, timetable, absences, marks, planner, lunches, activity, settings):
        assert mod.build(state, None) is not None
    # Busy + error states must build too.
    state.refresh_running = True
    state.current_step = "fetching…"
    assert activity.build(state, None) is not None
    state.refresh_running = False
    state.status = "error"
    state.runs.append({"ok": False, "finished": "x", "started": "x", "detail": "boom"})
    assert activity.build(state, None) is not None


def test_scrollable_reuses_container_across_rebuilds(state):
    import flet as ft

    from strakalari.flet_ui import components as C

    first = C.scrollable(state, "scroll-test-a", [ft.Text("one")],
                         spacing=5, expand=True)
    second = C.scrollable(state, "scroll-test-a", [ft.Text("two")],
                          spacing=9, expand=True)
    # Same object (scroll offset survives), fresh children, props refreshed.
    assert second is first
    assert [c.value for c in first.controls] == ["two"]
    assert first.spacing == 9
    assert first.scroll == ft.ScrollMode.AUTO


def test_scrollable_row_and_type_mismatch(state):
    import flet as ft

    from strakalari.flet_ui import components as C

    row = C.scrollable(state, "scroll-test-grid", ["x"],
                       make=ft.Row, tight=True)
    assert isinstance(row, ft.Row)
    assert C.scrollable(state, "scroll-test-grid", ["y"],
                        make=ft.Row) is row
    # Same key but another container kind rebuilds instead of mixing.
    col = C.scrollable(state, "scroll-test-grid", ["z"], make=ft.Column)
    assert isinstance(col, ft.Column) and col is not row


def test_timetable_build_reuses_body_across_renders(state):
    from strakalari.flet_ui.views import timetable as tt

    # Seed real cache rows (no fictional fallback): the scroll-reuse
    # assertion only applies to the populated week view.
    state.data = {
        "absence": {"Matematika": 5.0},
        "timetable": {
            "07.09.2026": [
                {"subject": "Matematika", "time": "1 (8:00 - 8:45)",
                 "room": "U12", "teacher": "Novak"},
            ],
        },
    }
    state.demo_mode = False
    first = tt.build(state, None)
    second = tt.build(state, None)
    # Outer root is fresh, but the scrolling body is the cached object,
    # so rebuilt weeks never jump back to the top.
    assert first.controls[3] is second.controls[3]
    assert first.controls[3] is state._scroll_cols["timetable:table"]
    # The list keeps its own scroller (and offset), never the grid's.
    state.timetable_view = "list"
    try:
        listed = tt.build(state, None)
    finally:
        state.timetable_view = "table"
    assert listed.controls[3] is state._scroll_cols["timetable:list"]
    assert listed.controls[3] is not first.controls[3]


def _seed_week(state):
    from datetime import datetime, timedelta

    base = __import__("datetime").date(2026, 9, 7)
    days = {}
    for week in range(3):
        for add in (0, 1):
            day = base + timedelta(days=week * 7 + add)
            days[day.strftime("%d.%m.%Y")] = [
                {"subject": "Matematika", "time": "1 (8:00 - 8:45)",
                 "room": "U12", "teacher": "Novak"},
            ]
    from strakalari.core.schedule import baseline_from_stable_timetable, baseline_to_dict

    first = min(days, key=lambda k: datetime.strptime(k, "%d.%m.%Y"))
    state.data = {"absence": {"Matematika": 5.0}, "timetable": days,
                  "stable_baseline": baseline_to_dict(
                      baseline_from_stable_timetable({first: days[first]})),
                  "stable_baseline_source": "scraped"}
    state.demo_mode = False


def test_timetable_list_view_builds(state):
    from strakalari.flet_ui.views import timetable as tt

    _seed_week(state)
    state.timetable_view = "list"
    try:
        assert tt.build(state, None) is not None
    finally:
        state.timetable_view = "table"


def test_timetable_stable_view_builds(state):
    from strakalari.flet_ui.views import timetable as tt

    _seed_week(state)
    assert state.stable_baseline(), "seed must carry a scraped baseline"
    state.set_show_stable(True)
    try:
        assert tt.build(state, None) is not None
    finally:
        state.set_show_stable(False)


def test_day_name_follows_app_language():
    from strakalari.core import i18n as core_i18n
    from strakalari.flet_ui import components as C

    monday = __import__("datetime").date(2026, 9, 14)
    prev = core_i18n.get_language()
    try:
        core_i18n.set_language("cs")
        assert C.day_name(monday) == "Pondělí"
        assert C.day_name(monday, short=True) == "Po"
        core_i18n.set_language("en")
        assert C.day_name(monday) == "Monday"
        assert C.day_name(monday, short=True) == "Mon"
    finally:
        core_i18n.set_language(prev)


def test_timetable_period_of_zero():
    from strakalari.flet_ui.views.timetable import _period_of

    assert _period_of({"subject": "M", "period": 0}, None) == 0
    assert _period_of({"subject": "M", "period": 2}, None) == 2
    assert _period_of({"subject": "M"}, None) is None


def _real_session():
    from types import SimpleNamespace

    from flet.messaging.session import Session
    from flet.pubsub.pubsub_hub import PubSubHub

    conn = SimpleNamespace(pubsubhub=PubSubHub(), send_message=lambda m: None)
    return Session(conn)


def test_stale_method_reply_does_not_raise():
    """A reply for a control removed mid-call must not kill the session.

    Unguarded, Flet raises "Control with ID … is not registered" from its
    receive loop, which then exits and the UI stops responding.
    """
    import asyncio

    import pytest

    from strakalari.flet_ui.app import _tolerate_stale_method_results

    async def scenario(guarded: bool):
        session = _real_session()
        if guarded:
            _tolerate_stale_method_results(session.page)
            # Idempotent: a second call must not wrap the wrapper.
            _tolerate_stale_method_results(session.page)
        call = asyncio.create_task(
            session.invoke_method(987654, "scroll_to", {}, timeout=2))
        await asyncio.sleep(0)
        call_id = next(iter(session._Session__method_calls))
        session.handle_invoke_method_results(987654, call_id, None, "gone")
        with pytest.raises(RuntimeError):
            await call  # the caller sees a normal, catchable failure

    with pytest.raises(RuntimeError, match="not registered"):
        asyncio.run(scenario(guarded=False))
    asyncio.run(scenario(guarded=True))


def test_restore_scroll_only_touches_scrollers_of_current_render(state):
    import flet as ft

    from strakalari.flet_ui import components as C

    C.begin_render(state)
    C.scrollable(state, "screen-a", [ft.Text("a")])
    C.begin_render(state)  # navigated: screen-a is no longer built
    C.scrollable(state, "screen-b", [ft.Text("b")])
    state._scroll_offsets.update({"screen-a": 120.0, "screen-b": 80.0})

    scheduled = []

    class _Page:
        def run_task(self, fn):
            scheduled.append(fn)

    C.restore_scroll_offsets(state, _Page())
    assert len(scheduled) == 1
    assert scheduled[0].__defaults__[0] is state._scroll_cols["screen-b"]


def test_grid_subject_uses_short_name_only_when_needed():
    from strakalari.flet_ui.views.timetable import _abbrev, _cell_subject

    raw = {"subject": "Informatika a výpočetní technika", "subject_short": "IVT"}
    assert _cell_subject(raw, raw["subject"], 40) == raw["subject"]
    assert _cell_subject(raw, raw["subject"], 12) == "IVT"
    # No short name cached (older caches): initials, stop-words skipped.
    assert _cell_subject({}, "Základy společenských věd", 12) == "ZSV"
    assert _abbrev("Český jazyk a literatura") == "ČJL"
    assert _abbrev("Matematika") == "Matematika"


def test_focus_period_marks_current_then_next_lesson():
    from datetime import date, datetime

    from strakalari.flet_ui.views.timetable import _focus_period

    day = date(2026, 9, 24)
    lessons = [
        {"subject": "M", "time": "1 (8:00 - 8:45)"},
        {"subject": "F", "time": "2 (8:55 - 9:40)"},
        {"subject": "C", "time": "3 (10:00 - 10:45)", "status": "cancelled"},
        {"subject": "D", "time": "4 (10:55 - 11:40)"},
    ]
    assert _focus_period(lessons, day, datetime(2026, 9, 24, 8, 10)) == (1, "now")
    assert _focus_period(lessons, day, datetime(2026, 9, 24, 8, 50)) == (2, "next")
    # A cancelled lesson is never "next": skip to the one that happens.
    assert _focus_period(lessons, day, datetime(2026, 9, 24, 9, 45)) == (4, "next")
    assert _focus_period(lessons, day, datetime(2026, 9, 24, 15, 0)) == (None, "")
    assert _focus_period(lessons, date(2026, 9, 23),
                         datetime(2026, 9, 24, 8, 10)) == (None, "")


def test_lesson_look_encodes_state_in_the_cell(state):
    from datetime import date

    from strakalari.flet_ui.strings import S
    from strakalari.flet_ui.views.timetable import _look

    tok = state.tok
    day = date(2026, 9, 7)
    plain = _look(state, {"subject": "M", "time": "1 (8:00 - 8:45)"}, day)
    assert plain.fill == tok.card and plain.bar is None and plain.tag == ""

    absent = _look(state, {"subject": "M", "time": "1 (8:00 - 8:45)",
                           "absenceType": "Absent"}, day)
    assert absent.bar == tok.red and absent.tag == S("status_absent")

    cancelled = _look(state, {"subject": "M", "time": "1 (8:00 - 8:45)",
                              "notice": "Odpadá"}, day)
    assert cancelled.cancelled and cancelled.fill is None
    assert cancelled.tag == S("status_lesson_cancelled")

    changed = _look(state, {"subject": "M", "time": "1 (8:00 - 8:45)",
                            "notice": "Suplování", "infoChangeCode": "Substitution"}, day)
    assert changed.diff.is_change and changed.fill != tok.card


def test_settings_nav_groups_cover_every_section():
    from strakalari.flet_ui.views.settings import NAV_GROUPS, SECTION_ICONS, SECTIONS

    grouped = [sid for _, ids in NAV_GROUPS for sid in ids]
    assert sorted(grouped) == sorted(sid for sid, _ in SECTIONS)
    assert len(grouped) == len(set(grouped))
    assert set(SECTION_ICONS) == set(grouped)


def test_lunch_meal_name_split():
    from strakalari.flet_ui.views.lunches import LunchView

    split = LunchView._split_meal
    assert split("Kulajda; Pečené kuře, rýže (1,7,9)") == (
        "Kulajda", "Pečené kuře, rýže", "1, 7, 9")
    assert split("Rizoto se sýrem,okurka(1a, 7)") == (
        "", "Rizoto se sýrem, okurka", "1a, 7")
    # Parentheses that are not allergen codes stay in the name.
    assert split("Buchty (sladké)") == ("", "Buchty (sladké)", "")
    meals = {"1": "Kulajda; A (1)", "2": "Kulajda; B (7)", "x&-1&": "Odhlásit"}
    assert LunchView._shared_soup(meals) == "Kulajda"
    assert LunchView._shared_soup({"1": "A; X", "2": "B; Y"}) == ""


def test_lunch_menu_hides_past_days_until_asked(state):
    from datetime import date, timedelta

    from strakalari.flet_ui.strings import S
    from strakalari.flet_ui.views import lunches

    today = date.today()
    past = (today - timedelta(days=7)).strftime("%d.%m.%Y")
    future = (today + timedelta(days=7)).strftime("%d.%m.%Y")
    state.data = {"timetable": {future: []}, "absence": {"M": 1.0},
                  "strava_meals": {past: {"p1": "Staré jídlo (1)"},
                                   future: {"f1": "Nové jídlo (1)"}}}
    state.demo_mode = False

    def texts(control, out=None):
        out = [] if out is None else out
        for attr in ("value", "text"):
            v = getattr(control, attr, None)
            if isinstance(v, str):
                out.append(v)
        for attr in ("content", "controls"):
            v = getattr(control, attr, None)
            for child in (v if isinstance(v, list) else [v]):
                if child is not None and hasattr(child, "_i"):
                    texts(child, out)
        return out

    shown = texts(lunches.build(state, None))
    assert "Nové jídlo" in shown and "Staré jídlo" not in shown
    assert S("lunch_show_past").format(n=1) in shown
    state.show_past_lunches = True
    assert "Staré jídlo" in texts(lunches.build(state, None))
