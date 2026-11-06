"""The phone's background notification as an overview: today's lunch, the
next lesson, open lunch orders, pending excuses, the wake-up alarm and the
last update — what it says, how it stays current, and its settings."""

from __future__ import annotations

import json
import re
import zipfile
from datetime import datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest

from strakalari.core import status_notification as sn
from strakalari.core.status_notification import (
    DEFAULT_ITEMS,
    ITEMS,
    StatusContent,
    StatusInputs,
    StatusNotifier,
    build_status,
    lunch_over_at,
    meal_text,
    selected_items,
    with_item,
)

ROOT = Path(__file__).resolve().parents[1]
JAVA = (ROOT / "mobile" / "strakalari_android" / "flutter" / "strakalari_android" / "android"
        / "src" / "main")
#: No school holidays, the 12:00 lunch cutoff.
CFG = {"school_preset_id": "custom", "user_free_days": [], "holidays": []}
ALL = {**CFG, "background_notification_items": list(ITEMS)}

# Monday 9 November 2026 and the rest of that week.
MON, TUE, WED, THU, FRI = "09.11.2026", "10.11.2026", "11.11.2026", "12.11.2026", "13.11.2026"
NEXT_MON = "16.11.2026"


def _menu(table: str, *dishes: str) -> dict:
    meals = {f"{table}&-1&0": "Monday 09/11/2026"}  # the day's "no lunch" control
    meals.update({f"{table}&{n}&0": dish for n, dish in enumerate(dishes, start=1)})
    return meals


FOOD = {
    MON: _menu("table0", "oběd 1 - Polévka,Kuřecí řízek, kaše(01, 07 )", "oběd 2 - Guláš(01)"),
    TUE: _menu("table1", "oběd 1 - Svíčková(01)"),
    WED: _menu("table2", "oběd 1 - Rizoto"),
    FRI: _menu("table4", "oběd 1 - Ryba"),
    NEXT_MON: _menu("table5", "oběd 1 - Buchtičky se šodó"),
}
TT = {
    MON: [{"time": "1 (8:00 - 8:45)", "subject": "Matematika", "room": "214",
           "teacher": "Mgr. Jan Novák"},
          {"time": "2 (8:55 - 9:40)", "subject": "Fyzika", "room": "105"},
          {"time": "4 (10:55 - 11:40)", "subject": "Dějepis", "room": "12"}],
    TUE: [{"time": "1 (8:00 - 8:45)", "subject": "Chemie", "room": "L1"}],
}


def _inputs(**over) -> StatusInputs:
    base = dict(timetable=TT, food=FOOD, web_orders={MON: "table0&1&0"}, config=ALL)
    base.update(over)
    return StatusInputs(**base)


def _lines(content: StatusContent) -> list[str]:
    """Title and text lines; dates keep a no-break space ("9.\u00a011."), read as a space."""
    text = f"{content.title}\n{content.text}".replace("\u00a0", " ")
    return [line for line in text.split("\n") if line]


# -- choosing what to show --------------------------------------------------------------

class TestItems:
    def test_defaults_match_the_config_schema(self):
        from strakalari.core.config import CANONICAL_DEFAULTS

        assert CANONICAL_DEFAULTS["background_notification_items"] == list(DEFAULT_ITEMS)
        assert selected_items({}) == list(DEFAULT_ITEMS)
        assert set(DEFAULT_ITEMS) <= set(ITEMS)

    def test_selection_keeps_display_order_and_drops_unknown(self):
        cfg = {"background_notification_items": ["excuses", "bogus", "lunch"]}
        assert selected_items(cfg) == ["lunch", "excuses"]
        assert selected_items({"background_notification_items": "lunch"}) == list(DEFAULT_ITEMS)
        assert selected_items({"background_notification_items": []}) == []

    def test_switching_an_item(self):
        cfg = {"background_notification_items": ["excuses"]}
        assert with_item(cfg, "lunch", True) == ["lunch", "excuses"]
        assert with_item(cfg, "excuses", False) == []

    def test_config_validation(self):
        from strakalari.core.config import validate_config

        def _problems(value):
            return [p for p in validate_config({"use_strava": False,
                                                "background_notification_items": value})
                    if "background_notification_items" in p]

        assert _problems(["lunch", "updated"]) == [] and _problems([]) == []
        assert _problems(["lunch", "weather"]) and _problems("lunch")


# -- the lines ---------------------------------------------------------------------------

#: Periods 1-7 at a typical school's times.
CLOCK = {1: "8:00 - 8:45", 2: "8:55 - 9:40", 3: "10:00 - 10:45", 4: "10:55 - 11:40",
         5: "11:50 - 12:35", 6: "12:45 - 13:30", 7: "13:40 - 14:25"}


def _day(*periods: int, cancelled: tuple = ()) -> list[dict]:
    return [{"time": f"{p} ({CLOCK[p]})", "subject": f"Předmět {p}",
             **({"status": "cancelled"} if p in cancelled else {})} for p in periods]


def _over(**days) -> str | None:
    """When Monday's lunch is over, as H:MM (``days``: Monday's and other days' lessons)."""
    tt = {MON: days.pop("mon"), **{key: lessons for key, lessons in days.values()}}
    minute = lunch_over_at(StatusInputs(timetable=tt, config=CFG),
                           datetime(2026, 11, 9).date())
    return None if minute is None else f"{minute // 60}:{minute % 60:02d}"


class TestLunchtime:
    def test_the_first_free_period_after_the_fourth(self):
        # Period 5 is free on Monday; Tuesday shows when period 5 ends.
        assert _over(mon=_day(1, 2, 3, 4, 6), tue=(TUE, _day(1, 2, 3, 4, 5))) == "12:35"

    def test_a_free_period_of_unknown_time_ends_when_the_next_lesson_starts(self):
        assert _over(mon=_day(1, 2, 3, 4, 6)) == "12:45"

    def test_only_the_first_of_two_free_periods(self):
        assert _over(mon=_day(1, 2, 3, 4, 7), tue=(TUE, _day(1, 2, 3, 4, 5, 6))) == "12:35"

    def test_a_cancelled_lesson_leaves_its_period_free(self):
        assert _over(mon=_day(1, 2, 3, 4, 5, 6, cancelled=(5,))) == "12:35"

    def test_without_a_gap_after_the_fourth_lunch_ends_with_the_classes(self):
        assert _over(mon=_day(1, 2, 3, 4, 5, 6)) == "13:30"
        assert _over(mon=_day(1, 2, 4)) == "11:40"  # a gap before the 4th doesn't count
        assert _over(mon=_day(1, 2, 3)) == "10:45"

    def test_no_lessons(self):
        assert _over(mon=[]) is None
        assert _over(mon=_day(1, 2, cancelled=(1, 2))) is None

    def test_the_lunch_line_follows_it(self):
        tt = {MON: _day(1, 2, 3, 4, 6), TUE: _day(1, 2, 3, 4, 5)}
        before = build_status(_inputs(timetable=tt), datetime(2026, 11, 9, 12, 34), lang="cs")
        assert _lines(before)[:2] == ["Oběd dnes", "Oběd 1 - Polévka, Kuřecí řízek, kaše"]
        after = build_status(_inputs(timetable=tt), datetime(2026, 11, 9, 12, 35), lang="cs")
        assert _lines(after)[:2] == ["Oběd zítra", "Neobjednáno"]

    def test_a_day_without_lessons_switches_at_three(self):
        before = build_status(_inputs(timetable={}), datetime(2026, 11, 9, 14, 59), lang="en")
        assert _lines(before)[0] == "Lunch today"
        after = build_status(_inputs(timetable={}), datetime(2026, 11, 9, 15, 0), lang="en")
        assert _lines(after)[0] == "Lunch tomorrow"


class TestLunch:
    def test_todays_lunch_until_classes_end_then_the_next(self):
        # Monday: periods 1, 2 and 4, so lunch is over when period 4 ends.
        morning = build_status(_inputs(), datetime(2026, 11, 9, 11, 39), lang="cs")
        assert _lines(morning)[:2] == ["Oběd dnes", "Oběd 1 - Polévka, Kuřecí řízek, kaše"]
        afternoon = build_status(_inputs(), datetime(2026, 11, 9, 11, 40), lang="cs")
        assert _lines(afternoon)[:2] == ["Oběd zítra", "Neobjednáno"]

    def test_weekend_and_gaps_show_the_next_menu_day(self):
        inputs = _inputs(web_orders={FRI: "table4&1&0", NEXT_MON: "table5&1&0"})
        thursday = build_status(inputs, datetime(2026, 11, 12, 9, 0), lang="cs")
        assert _lines(thursday)[:2] == ["Oběd zítra", "Oběd 1 - Ryba"]  # no menu on Thursday
        friday = build_status(inputs, datetime(2026, 11, 13, 16, 0), lang="en")
        assert _lines(friday)[:2] == ["Lunch on Monday", "Oběd 1 - Buchtičky se šodó"]
        assert _lines(build_status(inputs, datetime(2026, 11, 13, 16, 0), lang="cs"))[0] == (
            "Oběd v pondělí")

    def test_no_lunch_and_unknown_meal(self):
        none = _inputs(web_orders={MON: "table0&-1&0"})
        assert _lines(build_status(none, datetime(2026, 11, 9, 7, 0), lang="en"))[:2] == [
            "Lunch today", "Not ordered"]
        gone = _inputs(web_orders={MON: "table0&9&0"})  # ordered, but not on the menu
        assert _lines(build_status(gone, datetime(2026, 11, 9, 7, 0), lang="cs"))[1] == (
            "Objednáno")

    def test_strava_off_hides_the_lunch_lines(self):
        inputs = _inputs(config={**ALL, "use_strava": False})
        lines = _lines(build_status(inputs, datetime(2026, 11, 9, 7, 0), lang="cs"))
        assert lines[0].startswith("Další hodina")
        assert not [line for line in lines if "Oběd" in line or "obědy" in line]

    def test_meal_text(self):
        assert meal_text("oběd 1 - Polévka,Hlavní jídlo, příloha(01, 07 )") == (
            "Oběd 1 - Polévka, Hlavní jídlo, příloha")
        assert meal_text("  Kulajda;  Svíčková (1,3,7)") == "Kulajda; Svíčková"
        assert meal_text("Rizoto (hrášek)") == "Rizoto (hrášek)"  # not an allergen list


class TestNextLesson:
    def _line(self, now, inputs=None, lang="cs"):
        lines = _lines(build_status(inputs or _inputs(config={**ALL, "use_strava": False}),
                                    now, lang=lang))
        return next((line for line in lines if "hodina" in line or "lesson" in line), "")

    def test_before_and_during_school(self):
        assert self._line(datetime(2026, 11, 9, 7, 0)) == (
            "Další hodina: 1. Matematika · 8:00 · 214 · Novák")
        # Fyzika runs since 8:55; period 3 is free.
        assert self._line(datetime(2026, 11, 9, 9, 0)) == "Další hodina: 4. Dějepis · 10:55 · 12"
        assert self._line(datetime(2026, 11, 9, 9, 0), lang="en") == (
            "Next lesson: 4. Dějepis · 10:55 · 12")

    def test_after_school_the_next_school_day(self):
        assert self._line(datetime(2026, 11, 9, 12, 0)) == (
            "Další hodina zítra: 1. Chemie · 8:00 · L1")
        holiday = {**ALL, "use_strava": False,
                   "user_free_days": [{"date": TUE, "label": "Ředitelské volno"}]}
        tt = {**TT, THU: [{"time": "2 (8:55 - 9:40)", "subject": "Biologie"}]}
        assert self._line(datetime(2026, 11, 9, 12, 0),
                          _inputs(timetable=tt, config=holiday), lang="en") == (
            "Next lesson on Thursday: 2. Biologie · 8:55")

    def test_days_off_handed_over_with_the_data(self):
        """The app passes the calendar's days off along (no preset files read per tick)."""
        tt = {**TT, WED: [{"time": "1 (8:00 - 8:45)", "subject": "Zeměpis"}]}
        inputs = _inputs(timetable=tt, config={**ALL, "use_strava": False},
                         free_days=frozenset({datetime(2026, 11, 10).date()}))
        assert self._line(datetime(2026, 11, 9, 12, 0), inputs) == (
            "Další hodina ve středu: 1. Zeměpis · 8:00")

    def test_cancelled_and_planned_lessons_are_skipped(self):
        tt = {MON: [{"time": "1 (8:00 - 8:45)", "subject": "Matematika", "status": "cancelled"},
                    {"time": "2 (8:55 - 9:40)", "subject": "Fyzika"},
                    {"time": "3 (10:00 - 10:45)", "subject": "Chemie"}]}
        cfg = {**ALL, "use_strava": False,
               "planned_skips": [{"start_date": "2026-11-09", "end_date": "2026-11-09",
                                  "start_period": 2, "end_period": 2}]}
        assert self._line(datetime(2026, 11, 9, 7, 0), _inputs(timetable=tt, config=cfg)) == (
            "Další hodina: 3. Chemie · 10:00")

    def test_no_timetable_no_line(self):
        assert self._line(datetime(2026, 11, 9, 7, 0), _inputs(timetable={})) == ""


class TestOtherLines:
    def test_open_orders_name_the_days_and_the_first_deadline(self):
        lines = _lines(build_status(_inputs(), datetime(2026, 11, 9, 7, 0), lang="cs"))
        assert ("Neobjednané obědy: Út 10. 11., St 11. 11., Pá 13. 11. a další 1 · "
                "uzávěrka dnes 12:00") in lines
        # Past Monday noon Tuesday closed; a planned day off doesn't count.
        cfg = {**ALL, "planned_skips": [{"start_date": "2026-11-11", "end_date": "2026-11-11"}]}
        lines = _lines(build_status(_inputs(config=cfg), datetime(2026, 11, 9, 13, 0),
                                    lang="en"))
        assert "Lunches not ordered: Fri 13. 11., Mon 16. 11. · order by Thursday 12:00" in lines

    def test_more_than_three_open_days(self):
        food = {**FOOD, THU: _menu("table3", "oběd 1 - Halušky")}
        # Sunday: Monday's lunch closed on Friday, the other five are open.
        lines = _lines(build_status(_inputs(food=food, web_orders={}),
                                    datetime(2026, 11, 8, 10, 0), lang="cs"))
        assert ("Neobjednané obědy: Út 10. 11., St 11. 11., Čt 12. 11. a další 2 · "
                "uzávěrka zítra 12:00") in lines

    def test_excuses_only_when_waiting(self):
        now = datetime(2026, 11, 9, 7, 0)
        assert "Omluvenky k odeslání: 2" in _lines(build_status(_inputs(pending_excuses=2), now,
                                                                lang="cs"))
        assert not [line for line in _lines(build_status(_inputs(), now, lang="cs"))
                    if "Omluvenky" in line]

    def test_wakeup_alarm(self):
        cfg = {**ALL, "wakeup_enabled": True, "wakeup_minutes_before": 60}
        lines = _lines(build_status(_inputs(config=cfg), datetime(2026, 11, 9, 7, 30),
                                    lang="cs"))
        assert "Budík: zítra v 7:00" in lines
        lines = _lines(build_status(_inputs(config=cfg), datetime(2026, 11, 9, 6, 0),
                                    lang="en"))
        assert "Alarm: today at 7:00" in lines

    def test_updated_goes_to_the_header(self):
        stamp = datetime(2026, 11, 9, 6, 40)
        now = datetime(2026, 11, 9, 7, 0)
        assert build_status(_inputs(last_updated=stamp), now, lang="cs").sub == (
            "Aktualizováno 6:40")
        assert build_status(_inputs(last_updated=stamp), now + timedelta(days=1),
                            lang="en").sub == "Updated 9.\u00a011. 6:40"
        off = {**ALL, "background_notification_items": ["lunch"]}
        assert build_status(_inputs(last_updated=stamp, config=off), now).sub == ""

    def test_nothing_to_show_keeps_the_plain_text(self):
        inputs = StatusInputs(config=ALL, last_updated=datetime(2026, 11, 9, 6, 40))
        content = build_status(inputs, datetime(2026, 11, 9, 7, 0),
                               fallback=("Běží na pozadí", "Každých 30 min"), lang="cs")
        assert content == StatusContent("Běží na pozadí", "Každých 30 min", "Aktualizováno 6:40")
        none = {**CFG, "background_notification_items": []}
        assert build_status(_inputs(config=none), datetime(2026, 11, 9, 7, 0),
                            fallback=("A", "B")) == StatusContent("A", "B", "")

    def test_a_broken_line_leaves_the_others(self, monkeypatch):
        def _boom(*args):
            raise RuntimeError("broken calendar")

        monkeypatch.setattr(sn, "_orders_line", _boom)
        lines = _lines(build_status(_inputs(pending_excuses=1), datetime(2026, 11, 9, 7, 0),
                                    lang="en"))
        assert lines[0] == "Lunch today" and "Excuses to send: 1" in lines


# -- keeping the notification current ----------------------------------------------------

class TestNotifier:
    def _notifier(self, inputs=None):
        state = {"inputs": inputs or _inputs(), "gathered": 0, "ok": True}
        posted: list[StatusContent] = []

        def _gather():
            state["gathered"] += 1
            return state["inputs"]

        def _post(content):
            if state["ok"]:
                posted.append(content)
            return state["ok"]

        return StatusNotifier(_gather, _post, lambda: ("F", "f")), state, posted

    def test_posts_changes_only_and_moves_with_the_clock(self):
        notifier, state, posted = self._notifier()
        assert notifier.tick(datetime(2026, 11, 9, 8, 50)) is True
        assert posted[-1].text.split("\n")[1].startswith("Další hodina: 2. Fyzika")
        assert notifier.tick(datetime(2026, 11, 9, 8, 50, 30)) is False  # same minute
        assert notifier.tick(datetime(2026, 11, 9, 8, 51)) is False  # nothing changed
        assert notifier.tick(datetime(2026, 11, 9, 8, 55)) is True  # Fyzika has begun
        assert "4. Dějepis" in posted[-1].text and state["gathered"] == 1

    def test_a_poke_gathers_again(self):
        notifier, state, posted = self._notifier()
        notifier.tick(datetime(2026, 11, 9, 7, 0))
        state["inputs"] = _inputs(pending_excuses=3)
        notifier.poke()
        assert notifier.tick(datetime(2026, 11, 9, 7, 0)) is True
        assert "Omluvenky k odeslání: 3" in posted[-1].text and state["gathered"] == 2

    def test_a_new_day_gathers_again(self):
        notifier, state, _ = self._notifier()
        notifier.tick(datetime(2026, 11, 9, 23, 59))
        notifier.tick(datetime(2026, 11, 10, 0, 0))
        assert state["gathered"] == 2

    def test_hidden_notification_posts_nothing_then_starts_afresh(self):
        notifier, state, posted = self._notifier()
        notifier.tick(datetime(2026, 11, 9, 7, 0))
        state["inputs"] = None  # background running switched off
        notifier.poke()
        assert notifier.tick(datetime(2026, 11, 9, 7, 1)) is False
        state["inputs"] = _inputs()
        notifier.poke()
        assert notifier.tick(datetime(2026, 11, 9, 7, 2)) is True  # same content, sent again
        assert posted[0] == posted[1]

    def test_a_failed_post_is_tried_again(self):
        notifier, state, posted = self._notifier()
        state["ok"] = False
        assert notifier.tick(datetime(2026, 11, 9, 7, 0)) is False
        state["ok"] = True
        assert notifier.tick(datetime(2026, 11, 9, 7, 1)) is True and len(posted) == 1

    def test_current_counts_as_delivered(self):
        notifier, state, posted = self._notifier()
        content = notifier.current(datetime(2026, 11, 9, 7, 0))
        assert content.title == "Oběd dnes"
        assert notifier.tick(datetime(2026, 11, 9, 7, 0, 10)) is False and posted == []

    def test_a_failed_gather_is_retried(self):
        calls = []

        def _gather():
            calls.append(1)
            if len(calls) == 1:
                raise OSError("history file busy")
            return _inputs()

        notifier = StatusNotifier(_gather, lambda c: True)
        with pytest.raises(OSError):
            notifier.tick(datetime(2026, 11, 9, 7, 0))
        assert notifier.tick(datetime(2026, 11, 9, 7, 0, 5)) is True

    def test_thread_stops(self):
        notifier, _, _ = self._notifier()
        notifier.tick_s = 0.01
        notifier.start()
        notifier.stop()
        notifier._thread.join(timeout=5)
        assert not notifier._thread.is_alive()


# -- the phone ---------------------------------------------------------------------------

class _FakeIntent:
    def __init__(self, action):
        self.action, self.extras, self.component = action, {}, None

    def setClassName(self, package, name):
        self.component = (package, name)

    def putExtra(self, key, value):
        self.extras[key] = value


class TestAndroidBridge:
    def test_update_goes_to_the_status_receiver(self, monkeypatch):
        from strakalari.core import android

        sent = []
        ctx = SimpleNamespace(getPackageName=lambda: "io.github.dendlerx.strakalari",
                              sendBroadcast=sent.append)
        monkeypatch.setattr(android, "context", lambda: ctx)
        monkeypatch.setattr(android, "_autoclass", lambda name: {
            "android.content.Intent": _FakeIntent}[name])
        assert android.update_background_notification("Oběd dnes", "Řízek", "") is True
        (intent,) = sent
        assert intent.action == android.ACTION_UPDATE_STATUS
        assert intent.component == ("io.github.dendlerx.strakalari",
                                    f"{android.JAVA_PACKAGE}.StatusReceiver")
        assert intent.extras == {"title": "Oběd dnes", "text": "Řízek", "sub": ""}

    def test_no_op_off_android(self, monkeypatch):
        from strakalari.core import android

        monkeypatch.delenv("FLET_PLATFORM", raising=False)
        assert android.update_background_notification("t", "x") is False

    def test_java_side_matches(self):
        from strakalari.core import android

        receiver = (JAVA / "java" / "io" / "github" / "dendlerx" / "strakalari" / "android"
                    / "StatusReceiver.java").read_text(encoding="utf-8")
        assert f'"{android.ACTION_UPDATE_STATUS}"' in receiver
        for key in ("title", "text", "sub"):
            assert f'getStringExtra("{key}")' in receiver
        manifest = (JAVA / "AndroidManifest.xml").read_text(encoding="utf-8")
        assert re.search(r'android:name="[\w.]+\.StatusReceiver"\s+android:exported="false"',
                         manifest)
        service = (JAVA / "java" / "io" / "github" / "dendlerx" / "strakalari" / "android"
                   / "KeepAliveService.java").read_text(encoding="utf-8")
        assert '"sub"' in service and "setSubText" in (
            JAVA / "java" / "io" / "github" / "dendlerx" / "strakalari" / "android"
            / "Notifications.java").read_text(encoding="utf-8")

    def test_extension_wheel_ships_the_receiver(self, tmp_path):
        import importlib.util

        spec = importlib.util.spec_from_file_location("make_mobile",
                                                      ROOT / "tools" / "make_mobile.py")
        mm = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mm)
        with zipfile.ZipFile(mm.extension_wheel(str(tmp_path))) as zf:
            names = set(zf.namelist())
        assert ("flutter/strakalari_android/android/src/main/java/io/github/dendlerx/"
                "strakalari/android/StatusReceiver.java") in names


@pytest.fixture()
def phone_state(app_state, monkeypatch):
    """An Android app with a lunch ordered for today and a lesson ahead."""
    from strakalari.core import android
    from strakalari.core.status_notification import StatusNotifier as RealNotifier

    today = datetime.now().date()
    key = today.strftime("%d.%m.%Y")
    app_state.data = {
        "timetable": {key: [{"time": "1 (8:00 - 8:45)", "subject": "Matematika"}]},
        "strava_meals": {key: {"t0&-1&0": "x", "t0&1&0": "oběd 1 - Řízek"}},
        "strava_ordered": {key: "t0&1&0"},
        "last_updated": datetime.now().strftime("%d.%m.%Y %H:%M:%S"),
    }
    app_state.demo_mode = False
    app_state.web_orders = {key: "t0&1&0"}
    app_state.config.data.update(CFG)
    monkeypatch.setattr(app_state, "excuse_tasks", lambda: [{"key": "a"}])
    monkeypatch.setattr(android, "available", lambda: True)
    monkeypatch.setattr(android, "context", lambda: object())
    monkeypatch.setattr(android, "request_notification_permission", lambda: None)
    monkeypatch.setattr(android, "schedule_wake", lambda at: True)
    monkeypatch.setattr(android, "stop_background", lambda: None)
    started, updated, notifiers = [], [], []
    monkeypatch.setattr(android, "start_background", lambda texts: started.append(texts))
    monkeypatch.setattr(android, "update_background_notification",
                        lambda title, text, sub="": updated.append((title, text, sub)) or True)

    class _Notifier(RealNotifier):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            notifiers.append(self)

        def start(self):  # no thread in tests: ticks are driven by hand
            pass

    monkeypatch.setattr(sn, "StatusNotifier", _Notifier)
    return SimpleNamespace(state=app_state, started=started, updated=updated,
                           notifiers=notifiers, today=today)


class TestPhoneWiring:
    def _setup(self, phone):
        from strakalari.core.scheduler import PeriodicRunner
        from strakalari.flet_ui import app

        phone.state.wizard_dismissed = True
        phone.state.save({"run_in_background": True, "check_interval_minutes": 30})
        app._setup_phone_background(phone.state, PeriodicRunner(interval_minutes=30))
        return phone.notifiers[-1]

    def test_the_service_starts_with_the_overview(self, phone_state):
        self._setup(phone_state)
        (texts,) = phone_state.started
        if (datetime.now().hour, datetime.now().minute) < (8, 45):  # the day's classes end
            assert texts["title"] == "Oběd dnes" and texts["text"].startswith("Oběd 1 - Řízek")
        assert "Omluvenky k odeslání: 1" in f"{texts['title']}\n{texts['text']}"
        assert texts["sub"].startswith("Aktualizováno") and texts["channel"]

    def test_settings_changes_reach_the_notification(self, phone_state):
        notifier = self._setup(phone_state)
        phone_state.state.save({"background_notification_items": []})
        assert notifier.tick() is True
        title, text, sub = phone_state.updated[-1]
        assert "30" in text and sub == ""  # the plain "running in the background" text
        assert len(phone_state.started) == 1  # updated in place, no new start

    def test_new_data_reaches_the_notification(self, phone_state, monkeypatch):
        notifier = self._setup(phone_state)
        monkeypatch.setattr(phone_state.state, "excuse_tasks", lambda: [])
        phone_state.state._emit()
        assert notifier.tick() is True
        assert "Omluvenky" not in phone_state.updated[-1][1]

    def test_nothing_is_posted_with_background_running_off(self, phone_state):
        notifier = self._setup(phone_state)
        phone_state.state.save({"run_in_background": False})
        assert notifier.tick() is False and phone_state.updated == []


# -- settings ----------------------------------------------------------------------------

def _walk(control):
    yield control
    for attr in ("content", "controls"):
        value = getattr(control, attr, None)
        for child in (value if isinstance(value, list) else [value]):
            if child is not None and hasattr(child, "_i"):
                yield from _walk(child)


def _texts(controls) -> list[str]:
    return [v for c in controls for x in _walk(c)
            for v in (getattr(x, "value", None), getattr(x, "label", None))
            if isinstance(v, str) and v]


class TestSettings:
    def _section(self, state, monkeypatch):
        from strakalari.flet_ui.views.settings import SettingsView

        monkeypatch.setenv("FLET_PLATFORM", "android")
        return SettingsView(state, None)._browser()

    def test_background_section_lists_the_lines_and_a_preview(self, phone_state, monkeypatch):
        from strakalari.flet_ui.strings import S

        texts = _texts(self._section(phone_state.state, monkeypatch))
        for item in ITEMS:
            assert S(f"bg_item_{item}") in texts
        assert S("bg_preview") in texts and "Omluvenky k odeslání: 1" in "\n".join(texts)

    def test_a_switch_saves_and_updates_the_preview_in_place(self, phone_state, monkeypatch):
        from strakalari.flet_ui.strings import S

        state = phone_state.state
        renders = []
        state.listen(lambda: renders.append(1))
        controls = self._section(state, monkeypatch)
        switch = next(c for root in controls for c in _walk(root)
                      if getattr(c, "label", None) == S("bg_item_excuses"))
        assert switch.value is True
        assert "Omluvenky k odeslání: 1" in "\n".join(_texts(controls))
        switch.value = False
        switch.on_change(SimpleNamespace(control=switch))
        assert state.get("background_notification_items") == [
            i for i in DEFAULT_ITEMS if i != "excuses"]
        assert "Omluvenky k odeslání: 1" not in "\n".join(_texts(controls)) and renders == []
        saved = json.loads(Path(state.config.config_path).read_text(encoding="utf-8"))
        assert "excuses" not in saved["background_notification_items"]
