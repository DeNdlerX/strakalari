"""Wake-up alarm planning, the Android widget's data, visible free periods
in the timetable views and collapsible day cards."""

from __future__ import annotations

import json
import zipfile
from datetime import date, datetime, timedelta
from pathlib import Path

import flet as ft

from strakalari.core import wakeup
from strakalari.core.schedule import SlotBaseline
from strakalari.core.wakeup import (
    WakeupAlarm,
    alarm_queue,
    build_widget_day_rows,
    build_widget_payload,
    clamp_wakeup_minutes,
    next_wakeup_alarm,
    skipped_days,
    sync_android,
    upcoming_wakeup_alarms,
    with_skipped_day,
)

ROOT = Path(__file__).resolve().parents[1]
ON = {"wakeup_enabled": True, "wakeup_minutes_before": 60}
#: For tests on today's date: no school holidays to land on.
NO_HOLIDAYS = {"school_preset_id": "custom", "user_free_days": [], "holidays": []}


def _walk_controls(root):
    """Every Flet control reachable from ``root`` (title/subtitle included)."""
    seen = set()
    stack = list(reversed(list(root))) if isinstance(root, (list, tuple, set)) else [root]
    while stack:
        ctl = stack.pop()
        if ctl is None or id(ctl) in seen:
            continue
        seen.add(id(ctl))
        yield ctl
        for attr in ("content", "controls", "title", "subtitle", "leading", "trailing"):
            child = getattr(ctl, attr, None)
            if isinstance(child, (list, tuple)):
                stack.extend(reversed(child))
            elif child is not None:
                stack.append(child)


def _texts(root) -> list[str]:
    return [str(v) for c in _walk_controls(root)
            for v in (getattr(c, "value", None), getattr(c, "label", None)) if v]


# -- wake-up alarm --------------------------------------------------------------------

class TestWakeupAlarm:
    def test_clamp_wakeup_minutes(self):
        assert clamp_wakeup_minutes(None) == 60
        assert clamp_wakeup_minutes("abc", default=45) == 45
        assert clamp_wakeup_minutes(0) == 1
        assert clamp_wakeup_minutes(9999) == 720
        assert clamp_wakeup_minutes("75,5") == 75

    def test_disabled_returns_nothing(self):
        tt = {"12.10.2026": [{"time": "1 (8:00 - 8:45)", "subject": "Matematika"}]}
        cfg = {"wakeup_enabled": False}
        assert next_wakeup_alarm(tt, cfg, now=datetime(2026, 10, 12, 6, 0)) is None
        assert upcoming_wakeup_alarms(tt, cfg, now=datetime(2026, 10, 12, 6, 0)) == []

    def test_first_lesson_alarm(self):
        tt = {"12.10.2026": [
            {"time": "1 (8:00 - 8:45)", "subject": "Matematika", "room": "204"},
            {"time": "2 (8:55 - 9:40)", "subject": "Čeština"},
        ]}
        alarm = next_wakeup_alarm(tt, {**ON, "wakeup_minutes_before": 45},
                                  now=datetime(2026, 10, 12, 6, 30))
        assert isinstance(alarm, WakeupAlarm)
        assert (alarm.day, alarm.period, alarm.subject, alarm.room) == (
            date(2026, 10, 12), 1, "Matematika", "204")
        assert alarm.alarm_dt == datetime(2026, 10, 12, 7, 15)
        assert (alarm.alarm_time_label, alarm.lesson_time_label) == ("07:15", "08:00")

    def test_cancelled_first_lesson_moves_the_alarm(self):
        tt = {"12.10.2026": [
            {"time": "1 (8:00 - 8:45)", "subject": "Matematika", "status": "cancelled"},
            {"time": "2 (8:55 - 9:40)", "subject": "Fyzika"},
        ]}
        alarm = next_wakeup_alarm(tt, ON, now=datetime(2026, 10, 12, 6, 0))
        assert (alarm.period, alarm.subject) == (2, "Fyzika")
        assert alarm.alarm_dt == datetime(2026, 10, 12, 7, 55)

    def test_past_alarm_moves_to_the_next_school_day(self):
        tt = {
            "12.10.2026": [{"time": "1 (8:00 - 8:45)", "subject": "Matematika"}],
            "13.10.2026": [{"time": "2 (8:55 - 9:40)", "subject": "Angličtina"}],
        }
        alarm = next_wakeup_alarm(tt, ON, now=datetime(2026, 10, 12, 7, 5))
        assert (alarm.day, alarm.alarm_time_label) == (date(2026, 10, 13), "07:55")

    def test_skips_free_days_skipped_days_and_planned_absences(self):
        tt = {
            "12.10.2026": [{"time": "1 (8:00 - 8:45)", "subject": "Pondělí"}],
            "13.10.2026": [{"time": "1 (8:00 - 8:45)", "subject": "Úterý"}],
            "14.10.2026": [
                {"time": "1 (8:00 - 8:45)", "subject": "Středa 1"},
                {"time": "2 (8:55 - 9:40)", "subject": "Středa 2"},
            ],
        }
        cfg = {
            **ON,
            # The format the school calendar settings store.
            "user_free_days": [{"date": "12.10.2026", "label": "Ředitelské volno"}],
            "wakeup_skip_dates": ["2026-10-13"],
            "planned_skips": [{"start_date": "2026-10-14", "end_date": "2026-10-14",
                               "start_period": 1, "end_period": 1}],
        }
        alarm = next_wakeup_alarm(tt, cfg, now=datetime(2026, 10, 12, 6, 0))
        assert (alarm.day, alarm.subject, alarm.alarm_time_label) == (
            date(2026, 10, 14), "Středa 2", "07:55")

    def test_multi_day_planned_absence_follows_the_planner(self):
        lesson = [{"time": "1 (8:00 - 8:45)", "subject": "M"},
                  {"time": "2 (8:55 - 9:40)", "subject": "F"},
                  {"time": "3 (10:00 - 10:45)", "subject": "C"}]
        tt = {f"{d}.10.2026": lesson for d in (12, 13, 14)}
        # From period 2 on Monday through period 1 on Wednesday.
        cfg = {**ON, "planned_skips": [{"start_date": "2026-10-12", "end_date": "2026-10-14",
                                        "start_period": 2, "end_period": 1}]}
        alarms = upcoming_wakeup_alarms(tt, cfg, now=datetime(2026, 10, 12, 6, 0), horizon_days=2)
        assert [(a.day.day, a.period) for a in alarms] == [(12, 1), (14, 2)]

    def test_stable_timetable_covers_later_weeks(self):
        tt = {"16.10.2026": [{"time": "1 (8:00 - 8:45)", "subject": "Pátek"}]}
        baseline = {(0, 1): SlotBaseline(weekday=0, period=1, subject="Matematika",
                                         teacher="Novák", start_min=480)}
        # Without any cached week the template's start time alone ("1 (8:00)") will do.
        alarm = next_wakeup_alarm({}, ON, now=datetime(2026, 10, 16, 12, 0),
                                  stable_baseline=baseline)
        assert (alarm.day, alarm.alarm_time_label) == (date(2026, 10, 19), "07:00")
        # With one, the template day shows that period's full clock.
        rows = build_widget_payload(tt, {}, now=datetime(2026, 10, 19, 6, 0),
                                    stable_baseline=baseline)["days"][0]["rows"]
        assert (rows[0]["time"], rows[0]["start"], rows[0]["end"]) == ("8:00 - 8:45", 480, 525)
        alarm = next_wakeup_alarm(tt, {**ON, "wakeup_minutes_before": 30},
                                  now=datetime(2026, 10, 16, 12, 0), stable_baseline=baseline)
        assert (alarm.day, alarm.subject, alarm.alarm_time_label) == (
            date(2026, 10, 19), "Matematika", "07:30")

    def test_queue_spans_two_weeks_for_the_phone(self):
        lessons = [{"time": "1 (8:00 - 8:45)", "subject": "M", "room": "U12"}]
        tt = {(date(2026, 10, 12) + timedelta(days=i)).strftime("%d.%m.%Y"): lessons
              for i in range(14) if (date(2026, 10, 12) + timedelta(days=i)).weekday() < 5}
        alarms = upcoming_wakeup_alarms(tt, ON, now=datetime(2026, 10, 12, 6, 0))
        assert len(alarms) == 10
        queue = alarm_queue(alarms, lang="cs")
        first = queue[0]
        assert first["at"] == int(datetime(2026, 10, 12, 7, 0).timestamp() * 1000)
        assert first["lesson"] == int(datetime(2026, 10, 12, 8, 0).timestamp() * 1000)
        assert first["title"] == "Budík · M v 08:00"
        assert first["text"] == "1. hodina · učebna U12"
        assert alarm_queue(alarms[:1], lang="en")[0]["text"] == "Period 1 · room U12"

    def test_skip_list_keeps_only_upcoming_days(self):
        cfg = {"wakeup_skip_dates": ["2026-10-01", "2026-10-20", "junk"]}
        assert skipped_days(cfg) == {date(2026, 10, 1), date(2026, 10, 20)}
        today = date(2026, 10, 12)
        assert with_skipped_day(cfg, date(2026, 10, 13), True, today) == [
            "2026-10-13", "2026-10-20"]
        assert with_skipped_day(cfg, date(2026, 10, 20), False, today) == []


# -- home-screen widget ---------------------------------------------------------------

class TestWidgetPayload:
    def test_day_rows_show_free_periods_as_empty_slots(self):
        lessons = [
            {"time": "2 (8:55 - 9:40)", "subject": "Čeština", "room": "101",
             "teacher": "Mgr. Jana Nováková"},
            {"time": "4 (10:55 - 11:40)", "subject": "Fyzika", "room": "F2"},
        ]
        rows = build_widget_day_rows(lessons, date(2026, 10, 12))
        assert [(r["period"], r["kind"]) for r in rows] == [
            ("1.", "pause"), ("2.", "lesson"), ("3.", "pause"), ("4.", "lesson")]
        assert rows[1]["meta"] == "101 · Nováková"
        assert (rows[1]["start"], rows[1]["end"]) == (535, 580)
        assert rows[0]["subject"] == "" and rows[0]["start"] == -1

    def test_payload_has_dates_and_clock_times_not_today(self):
        tt = {
            "12.10.2026": [{"time": "1 (8:00 - 8:45)", "subject": "Matematika"}],
            "13.10.2026": [
                {"time": "1 (8:00 - 8:45)", "subject": "Čeština"},
                {"time": "3 (10:00 - 10:45)", "subject": "Dějepis",
                 "status": "cancelled"},
            ],
            "14.10.2026": [{"time": "3 (10:00 - 10:45)", "subject": "Biologie"}],
        }
        cfg = {"user_free_days": [{"date": "12.10.2026", "label": "Ředitelské volno"}]}
        payload = build_widget_payload(tt, cfg, now=datetime(2026, 10, 13, 6, 30), lang="cs")
        assert (payload["today"], payload["tomorrow"]) == ("Dnes", "Zítra")
        days = {d["iso"]: d for d in payload["days"]}
        monday, tuesday = days["2026-10-12"], days["2026-10-13"]
        assert monday["label"] == "Pondělí 12. 10."
        assert monday["free"] is True and monday["subtitle"] == "Ředitelské volno"
        assert tuesday["taught"] == 1 and tuesday["subtitle"] == "1 hodina"
        assert tuesday["end"] == 8 * 60 + 45  # the cancelled lesson doesn't count
        rows = tuesday["rows"]
        assert [r["kind"] for r in rows] == ["lesson", "pause", "lesson"]
        # The pause takes the usual clock of its period from the other days.
        assert rows[2]["status"] == "cancelled" and rows[2]["badge"] == "Odpadá"
        # A free period takes its number's usual clock from the other days.
        wednesday = days["2026-10-14"]["rows"]
        assert [(r["kind"], r["time"]) for r in wednesday] == [
            ("pause", "8:00 - 8:45"), ("pause", ""), ("lesson", "10:00 - 10:45")]
        # Weekends without lessons are left out; three weeks from Monday.
        assert "2026-10-17" not in days and "2026-10-30" in days
        assert "focus" not in json.dumps(payload) and "default_index" not in payload

    def test_preset_holiday_name_is_the_subtitle(self, monkeypatch):
        monkeypatch.setattr(wakeup, "effective_calendar", lambda cfg, clip=True: (
            {date(2026, 10, 29)}, {date(2026, 10, 29): "Podzimní prázdniny"}, {}))
        payload = build_widget_payload({"29.10.2026": []}, {}, now=datetime(2026, 10, 28),
                                       lang="cs")
        day = next(d for d in payload["days"] if d["iso"] == "2026-10-29")
        assert day["subtitle"] == "Podzimní prázdniny"

    def test_empty_text_says_when_there_is_no_data(self):
        assert build_widget_payload({}, {}, lang="en")["empty"] == "No data yet — open Strakaláři"
        assert build_widget_payload({"12.10.2026": []}, {}, lang="en")["empty"] == "No lessons"


class TestSyncAndroid:
    def test_sends_only_changes(self, monkeypatch):
        from strakalari.core import android

        calls = []
        monkeypatch.setattr(wakeup, "_sent", {})
        monkeypatch.setattr(android, "available", lambda: True)
        monkeypatch.setattr(android, "update_timetable_widget",
                            lambda raw: calls.append(("widget", json.loads(raw))) or True)
        monkeypatch.setattr(android, "set_wakeup_alarms",
                            lambda raw, channel, dismiss: calls.append(
                                ("alarms", json.loads(raw), channel, dismiss)) or True)
        tt = {"12.10.2026": [{"time": "1 (8:00 - 8:45)", "subject": "Matematika"}]}
        now = datetime(2026, 10, 12, 6, 0)

        sync_android(tt, ON, now=now)
        assert [c[0] for c in calls] == ["widget", "alarms"]
        assert calls[1][1][0]["title"].endswith("08:00") and calls[1][2] and calls[1][3]

        calls.clear()
        sync_android(tt, ON, now=now)
        assert calls == []  # nothing changed

        sync_android(tt, {"wakeup_enabled": False}, now=now)
        assert [(c[0], c[1]) for c in calls] == [("alarms", [])]  # the queue is cleared

    def test_no_op_off_android(self, monkeypatch):
        from strakalari.core import android

        def _never(*args):
            raise AssertionError("must not reach the phone bridge")

        monkeypatch.setattr(android, "available", lambda: False)
        monkeypatch.setattr(android, "update_timetable_widget", _never)
        monkeypatch.setattr(android, "set_wakeup_alarms", _never)
        sync_android({}, ON)


# -- timetable views: free periods and collapsible days --------------------------------

class TestTimetableViews:
    def test_grid_frames_only_free_periods_within_a_day(self, state):
        from strakalari.flet_ui.views import timetable as tt

        week = {
            date(2026, 10, 12): [
                {"time": "1 (8:00 - 8:45)", "subject": "Matematika"},
                {"time": "3 (10:00 - 10:45)", "subject": "Fyzika"},
            ],
            date(2026, 10, 13): [{"time": "1 (8:00 - 8:45)", "subject": "Chemie"}],
        }
        grid = tt._table_view(state, None, week, tt._day_names())
        header_cells = grid.controls[0].content.controls
        assert [c.content.controls[0].value for c in header_cells[1:]] == ["1.", "2.", "3."]
        monday = grid.controls[1].content.controls
        tuesday = grid.controls[2].content.controls
        assert monday[2].bgcolor == state.tok.surface and monday[2].border is not None
        # After Tuesday's last lesson: plain space, not a "pause".
        assert tuesday[2].border is None and tuesday[3].border is None

    def test_list_view_shows_pauses_and_folds_days(self, state):
        from strakalari.flet_ui.views import timetable as tt

        week = {
            date(2026, 10, 12): [
                {"time": "2 (8:55 - 9:40)", "subject": "Matematika"},
                {"time": "4 (10:55 - 11:40)", "subject": "Čeština"},
            ],
            date(2026, 10, 13): [{"time": "1 (8:00 - 8:45)", "subject": "Angličtina"}],
        }
        tiles = [c for c in tt._list_view(state, None, week, tt._day_names())
                 if isinstance(c, ft.ExpansionTile)]
        assert len(tiles) == 2
        monday_rows = tiles[0].controls
        assert len(monday_rows) == 4
        for pause in (monday_rows[0], monday_rows[2]):
            slot = pause.content.controls[2]
            assert slot.bgcolor == state.tok.surface and slot.border is not None

        state.set_day_expanded("tt:2026-10-12", False)
        tiles = [c for c in tt._list_view(state, None, week, tt._day_names())
                 if isinstance(c, ft.ExpansionTile)]
        assert tiles[0].expanded is False


class TestCollapsibleDays:
    def test_whole_day_excuse_lists_lessons_in_a_folded_section(self, state, monkeypatch):
        from strakalari.flet_ui.views import today

        tasks = [
            {"key": "2026-10-12#1", "label": "Po 12.10. · 1. hodina (M)", "date": "2026-10-12",
             "kind": "short", "period": 1},
            {"key": "2026-10-12#2", "label": "Po 12.10. · 2. hodina (ČJ)", "date": "2026-10-12",
             "kind": "short", "period": 2},
        ]
        monkeypatch.setattr(state, "excuse_tasks", lambda: tasks)
        tiles = [c for c in _walk_controls(today._excuse_cards(state, None, tasks))
                 if isinstance(c, ft.ExpansionTile)]
        assert len(tiles) == 1 and tiles[0].expanded is False
        assert tiles[0].title.value in ("Nebo jednotlivě (2 hodiny)", "Or one by one (2 lessons)")

        state.set_day_expanded("excuse:2026-10-12", True)
        tiles = [c for c in _walk_controls(today._excuse_cards(state, None, tasks))
                 if isinstance(c, ft.ExpansionTile)]
        assert tiles[0].expanded is True

    def test_lunch_days_open_from_today_on(self, state):
        from strakalari.flet_ui.views import lunches

        future = (date.today() + timedelta(days=3)).strftime("%d.%m.%Y")
        past = (date.today() - timedelta(days=3)).strftime("%d.%m.%Y")
        view = lunches.LunchView(state, None)
        assert view._day_card(future, {"m1": "Polévka; Řízek"}).expanded is True
        assert view._day_card(past, {"m1": "Polévka; Řízek"}).expanded is False
        state.set_day_expanded(f"lunch:{future}", False)
        assert view._day_card(future, {"m1": "Polévka; Řízek"}).expanded is False


# -- wake-up alarm in the UI (phone only) ------------------------------------------------

class TestWakeupUI:
    def _phone(self, monkeypatch, state, notifications=True, exact=True):
        from strakalari.core import android

        monkeypatch.setattr(state, "wakeup_available", lambda: True)
        monkeypatch.setattr(android, "notifications_enabled", lambda: notifications)
        monkeypatch.setattr(android, "exact_alarms_allowed", lambda: exact)

    def _settings(self, state):
        from strakalari.flet_ui.views.settings import view as settings_view

        return settings_view.SettingsView(state, None)._automation()

    def test_settings_card_is_phone_only(self, state):
        from strakalari.flet_ui.strings import S

        assert S("wakeup_title") not in _texts(self._settings(state))

    def test_settings_card_shows_next_alarm_and_warnings(self, monkeypatch, state):
        from strakalari.flet_ui.strings import S

        self._phone(monkeypatch, state, notifications=False, exact=False)
        day = date.today() + timedelta(days=1)
        state.data = {"timetable": {day.strftime("%d.%m.%Y"): [
            {"time": "1 (8:00 - 8:45)", "subject": "Matematika"}]}}
        state.demo_mode = False
        state.config.data.update({**ON, **NO_HOLIDAYS, "wakeup_skip_dates": [
            (date.today() + timedelta(days=5)).isoformat(), "2000-01-01"]})
        texts = _texts(self._settings(state))
        assert S("wakeup_title") in texts and S("wakeup_enable") in texts
        assert S("wakeup_notif_off") in texts and S("wakeup_exact_off") in texts
        assert any("07:00" in t and "Matematika" in t for t in texts)
        # One restore button: the past skipped day is gone.
        assert sum(1 for t in texts if t.startswith(S("wakeup_restore_day").split("{")[0])) == 1

    def test_today_card_shows_the_alarm_on_its_day(self, monkeypatch, state):
        from strakalari.flet_ui.views import today

        today_str = date.today().strftime("%d.%m.%Y")
        state.data = {"timetable": {today_str: [
            {"time": "1 (8:00 - 8:45)", "subject": "Matematika", "room": "201"}]},
            "absence": {"Matematika": 1.0}}
        state.demo_mode = False
        state.config.data.update({**ON, **NO_HOLIDAYS, "wakeup_minutes_before": 45})
        now = datetime.combine(date.today(), datetime.min.time()).replace(hour=6, minute=30)
        assert not any("07:15" in t for t in _texts(today._next_lesson_card(state, now)))
        self._phone(monkeypatch, state)
        assert any("07:15" in t for t in _texts(today._next_lesson_card(state, now)))

    def test_only_relevant_saves_reach_the_phone(self, monkeypatch, app_state):
        calls = []
        monkeypatch.setattr(app_state, "sync_android_state", lambda: calls.append(1))
        app_state.save({"theme": "light"})
        assert calls == []
        app_state.save({"wakeup_enabled": True})
        assert calls == [1]

    def test_demo_lessons_never_ring(self, monkeypatch, state):
        self._phone(monkeypatch, state)
        state.demo_mode = True
        state.config.data.update(ON)
        assert state.next_wakeup_alarm() is None


def test_extension_wheel_ships_widget_and_alarm(tmp_path):
    import importlib.util

    spec = importlib.util.spec_from_file_location("make_mobile", ROOT / "tools" / "make_mobile.py")
    mm = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mm)
    with zipfile.ZipFile(mm.extension_wheel(str(tmp_path))) as zf:
        names = set(zf.namelist())
    base = "flutter/strakalari_android/android/src/main/"
    java = base + "java/io/github/dendlerx/strakalari/android/"
    assert {
        java + "AlarmReceiver.java",
        java + "TimetableWidgetProvider.java",
        java + "TimetableWidgetService.java",
        base + "res/xml/timetable_widget_info.xml",
        base + "res/layout/timetable_widget.xml",
        base + "res/layout/timetable_widget_item.xml",
        base + "res/layout/timetable_widget_pause_item.xml",
        base + "res/values/strings.xml",
        base + "res/values-en/strings.xml",
    } <= names
