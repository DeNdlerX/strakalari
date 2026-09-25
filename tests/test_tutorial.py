"""Interactive tutorials: tour progress, gating, anchors and the Shell layer."""

import flet as ft
import pytest

import strakalari.flet_ui.state as state_mod
from strakalari.flet_ui import tutorial as T
from strakalari.flet_ui.strings import STRINGS


@pytest.fixture()
def st(app_state):
    """Real config file (tmp): progress must persist across instances."""
    return app_state


def _finish_intro(st):
    assert st.tutorial_offer("intro")
    st.tutorial_skip()


class TestGating:
    def test_intro_comes_first(self, st):
        assert not st.tutorial_offer("excuse")
        assert st.tutorial_offer("intro")
        # One tour at a time.
        assert not st.tutorial_offer("excuse")

    def test_contextual_tour_after_intro(self, st):
        _finish_intro(st)
        assert st.tutorial_offer("excuse")
        assert st.tutorial_current()[0].id == "excuse"

    def test_disabled_offers_nothing(self, st):
        assert st.set_tutorials_enabled(False)
        assert not st.tutorial_offer("intro")

    def test_turning_off_drops_the_active_tour(self, st):
        st.tutorial_offer("intro")
        st.set_tutorials_enabled(False)
        assert st.tutorial_current() is None

    def test_unknown_tour_is_ignored(self, st):
        _finish_intro(st)
        assert not st.tutorial_offer("nope")


class TestProgress:
    def test_skip_is_remembered_across_restarts(self, st):
        _finish_intro(st)
        again = state_mod.AppState()
        assert "intro" in again.tutorials_done()
        assert not again.tutorial_offer("intro")

    def test_next_through_the_end_marks_done(self, st):
        st.tutorial_offer("intro")
        for _ in T.TOURS["intro"].steps:
            st.tutorial_next()
        assert st.tutorial_current() is None
        assert "intro" in st.tutorials_done()

    def test_back_stays_in_bounds(self, st):
        st.tutorial_offer("intro")
        st.tutorial_back()
        assert st.tutorial == ("intro", 0)
        st.tutorial_next()
        st.tutorial_back()
        assert st.tutorial == ("intro", 0)

    def test_suspend_does_not_mark_done(self, st):
        _finish_intro(st)
        st.tutorial_offer("excuse")
        st.tutorial_suspend()
        assert "excuse" not in st.tutorials_done()
        assert st.tutorial_offer("excuse")
        assert st.tutorial == ("excuse", 0)

    def test_event_skips_ahead_to_the_waiting_step(self, st):
        _finish_intro(st)
        st.tutorial_offer("excuse")  # step 0 has no `until`
        st.tutorial_event("excuse_done")
        # Jumped past the step that waited for it (index 1).
        assert st.tutorial == ("excuse", 2)

    def test_unrelated_event_is_ignored(self, st):
        _finish_intro(st)
        st.tutorial_offer("excuse")
        st.tutorial_event("orders_sent")
        assert st.tutorial == ("excuse", 0)

    def test_event_on_last_waiting_step_finishes(self, st):
        _finish_intro(st)
        st.tutorial_offer("lunches")
        st.tutorial_event("lunch_picked")
        st.tutorial_event("orders_sent")
        assert st.tutorial == ("lunches", 2)
        st.tutorial_next()
        assert "lunches" in st.tutorials_done()

    def test_event_without_tour_is_harmless(self):
        bare = state_mod.AppState.__new__(state_mod.AppState)
        bare.tutorial_event("excuse_done")  # no __init__ state at all

    def test_reset_replays_everything(self, st):
        _finish_intro(st)
        st.set_tutorials_enabled(False)
        assert st.reset_tutorials()
        assert st.tutorials_enabled()
        assert st.tutorials_done() == set()

    def test_order_lunch_fires_its_event(self, st, monkeypatch):
        _finish_intro(st)
        st.tutorial_offer("lunches")
        monkeypatch.setattr(st, "is_lunch_order_open", lambda day, now=None: True)
        assert st.order_lunch("01.10.2026", "meal-1")
        assert st.tutorial == ("lunches", 1)


class TestRendering:
    def test_anchor_passthrough_without_tour(self, st):
        control = ft.Text("x")
        assert T.anchor(st, "excuse_card", control) is control

    def test_anchor_wraps_first_match_with_inline_bubble(self, st):
        _finish_intro(st)
        st.tutorial_offer("excuse")
        T.begin(st, "today")
        first, second = ft.Text("a"), ft.Text("b")
        wrapped = T.anchor(st, "excuse_card", first)
        assert isinstance(wrapped, ft.Column)  # ring + bubble
        assert wrapped.controls[0].content is first
        # Only the first matching control is highlighted.
        assert T.anchor(st, "excuse_card", second) is second
        assert T.layer(st) is None  # the bubble is already inline

    def test_missing_first_anchor_suspends(self, st):
        _finish_intro(st)
        st.tutorial_offer("excuse")
        T.begin(st, "today")
        assert T.layer(st) is None
        assert st.tutorial_current() is None
        assert "excuse" not in st.tutorials_done()

    def test_missing_later_anchor_floats(self, st):
        _finish_intro(st)
        st.tutorial_offer("excuse")
        st.tutorial_next()
        T.begin(st, "today")
        assert T.layer(st) is not None
        assert st.tutorial == ("excuse", 1)

    def test_other_screen_suspends_the_tour(self, st):
        _finish_intro(st)
        st.tutorial_offer("excuse")
        T.begin(st, "lunches")
        assert st.tutorial_current() is None

    def test_intro_floats_on_any_screen(self, st):
        T.begin(st, "settings")
        assert st.tutorial == ("intro", 0)
        assert T.layer(st) is not None

    @pytest.mark.parametrize("tour_id", sorted(T.TOURS))
    def test_every_step_bubble_builds(self, st, tour_id):
        tour = T.TOURS[tour_id]
        for index, step in enumerate(tour.steps):
            for caret in ("", "up", "up_right", "left"):
                assert T._bubble(st, tour, index, step, caret=caret) is not None

    def test_today_view_anchors_first_excuse(self, st, monkeypatch):
        from strakalari.flet_ui.views import today

        _finish_intro(st)
        tasks = [{"key": f"k{i}", "label": f"L{i}", "date": "2026-09-2{i}",
                  "kind": "short", "period": 1} for i in (1, 2)]
        monkeypatch.setattr(st, "excuse_tasks", lambda: tasks)
        T.begin(st, "today")
        today.build(st, None)
        assert st.tutorial == ("excuse", 0)
        assert st._tutorial_anchored


def test_strings_exist_for_every_step():
    for tour in T.TOURS.values():
        for step in tour.steps:
            keys = [f"tut_{step.key}_title", f"tut_{step.key}_body"]
            if step.until:
                keys.append(f"tut_{step.key}_try")
            for key in keys:
                assert key in STRINGS, key
                assert STRINGS[key].get("cs") and STRINGS[key].get("en"), key
        assert tour.route is None or tour.route in (
            "today", "timetable", "absences", "marks", "planner",
            "lunches", "activity", "settings")
        assert all(step.place in T.PLACES for step in tour.steps)


def test_shell_stacks_the_floating_bubble(st):
    from strakalari.flet_ui.app import Shell

    class FakePage:
        def __init__(self):
            self.controls, self.overlay = [], []
            self.bgcolor = self.theme_mode = None

        def add(self, *controls):
            self.controls.extend(controls)

        def update(self):
            pass

    st.wizard_dismissed = True
    shell = Shell(FakePage(), st)
    shell.render()
    assert isinstance(shell.content.content, ft.Stack)  # the welcome card
    st.tutorial_skip()  # emits -> re-render
    assert not isinstance(shell.content.content, ft.Stack)


def test_config_validation_rejects_bad_progress():
    from strakalari.core.config import CANONICAL_DEFAULTS, validate_config

    data = dict(CANONICAL_DEFAULTS, tutorials_done="intro")
    assert any("tutorials_done" in p for p in validate_config(data))
    assert not any("tutorials" in p for p in validate_config(dict(CANONICAL_DEFAULTS)))


class TestMarksTour:
    GRADES = {
        "Matematika": [{"Grade": "2", "Weight": 10, "Date": "05.09.2026"},
                       {"Grade": "1", "Weight": 10, "Date": "12.09.2026"}],
        "Fyzika": [{"Grade": "3", "Weight": 5, "Date": "06.09.2026"}],
    }

    def _marks_state(self, st):
        st.data = {"grades": self.GRADES}
        st.demo_mode = False
        _finish_intro(st)
        return st

    def _render(self, st):
        from strakalari.flet_ui.views import marks

        T.begin(st, "marks")
        view = marks.build(st, None)
        return view, T.layer(st)

    def test_walkthrough_follows_the_user(self, st):
        st = self._marks_state(st)
        self._render(st)
        assert st.tutorial == ("marks", 0) and st._tutorial_anchored
        st.tutorial_next()
        self._render(st)
        assert st._tutorial_anchored  # first subject card
        st.select_marks_subject("Matematika")  # the action moves the tour on
        assert st.tutorial == ("marks", 2)
        self._render(st)
        assert st._tutorial_anchored  # the "what do I need" card
        st.tutorial_next()
        self._render(st)
        assert st._tutorial_anchored  # the predictor card
        assert st.predict_add("Matematika", "1", 10)
        assert st.tutorial == ("marks", 4)
        _view, bubble = self._render(st)
        assert bubble is not None  # floats under the scale toggle
        st.tutorial_next()
        assert "marks" in st.tutorials_done()

    def test_no_marks_no_tour(self, st):
        _finish_intro(st)
        self._render(st)
        assert st.tutorial_current() is None
