"""Tests for core/schedule.py: stable baseline, change-vs-note, lesson clock."""

from datetime import date, datetime

from strakalari.core.schedule import (
    baseline_from_dict,
    baseline_from_stable_timetable,
    baseline_to_dict,
    classify_lesson,
    closest_variant,
    future_lessons,
    iter_changes,
    iter_notes,
    parse_time_range,
    resolve_day_lessons,
    stable_template_week,
    stable_weekly_hours,
)


def _two_weeks(**overrides):
    """Two identical weeks (Mon 07.09 + Mon 14.09.2026) with optional patch.

    Patch entries are (week, index, patch). Two disagreeing weeks form a
    1:1 tie with NO baseline — only explicit substitution/cancellation
    notices count as changes there. Use _three_weeks for majority diffs.
    """
    base = [
        {"subject": "M", "teacher": "Novák", "room": "U12",
         "time": "1 (8:00 - 8:45)"},
        {"subject": "F", "teacher": "Dvořák", "room": "F11",
         "time": "2 (8:55 - 9:40)"},
    ]
    week1 = [dict(lesson) for lesson in base]
    week2 = [dict(lesson) for lesson in base]
    for day, idx, patch in overrides.get("patch", []):
        (week1 if day == 0 else week2)[idx].update(patch)
    return {"07.09.2026": week1, "14.09.2026": week2}


def _three_weeks(**overrides):
    """Three weeks (Mon 31.08 + 07.09 + 14.09.2026); two agree -> majority."""
    base = [
        {"subject": "M", "teacher": "Novák", "room": "U12",
         "time": "1 (8:00 - 8:45)"},
        {"subject": "F", "teacher": "Dvořák", "room": "F11",
         "time": "2 (8:55 - 9:40)"},
    ]
    weeks = [[dict(lesson) for lesson in base] for _ in range(3)]
    for day, idx, patch in overrides.get("patch", []):
        weeks[day][idx].update(patch)
    return {"31.08.2026": weeks[0], "07.09.2026": weeks[1],
            "14.09.2026": weeks[2]}


def test_parse_time_range_formats():
    assert parse_time_range("3 (10:05 - 10:50)") == (10, 5, 10, 50)
    assert parse_time_range("1. 8:00 - 8:45") == (8, 0, 8, 45)
    assert parse_time_range("8:00 - 8:45") == (8, 0, 8, 45)
    assert parse_time_range("nonsense") is None
    assert parse_time_range("") is None


def test_description_only_is_note_not_change():
    tt = _two_weeks(patch=[(1, 1, {"notice": "Písemka z minulé látky"})])
    baseline = baseline_from_stable_timetable(tt)
    diff = classify_lesson(tt["14.09.2026"][1], day="14.09.2026",
                           baseline=baseline)
    assert diff.is_change is False
    assert diff.note == "Písemka z minulé látky"
    assert iter_changes(tt, baseline) == []
    assert len(iter_notes(tt, baseline)) == 1


def test_substitute_teacher_is_change():
    # 1:1 tie -> no baseline; the explicit substitution notice still counts.
    tt = _two_weeks(patch=[(1, 1, {"teacher": "Král",
                                   "notice": "Suplování (Král)"})])
    changes = iter_changes(tt)
    assert len(changes) == 1
    assert changes[0]["day_key"] == "14.09.2026"
    # The note is still preserved on the change.
    assert changes[0]["diff"].note == "Suplování (Král)"


def _stable_of(tt, day_key):
    """Baseline as the scraped "Stálý" view would give it: one clean week."""
    return baseline_from_stable_timetable({day_key: tt[day_key]})


def test_stable_baseline_gives_field_diffs():
    tt = _three_weeks(patch=[(2, 1, {"teacher": "Král", "notice": "Suplování"})])
    baseline = _stable_of(tt, "31.08.2026")
    assert baseline[(0, 2)].teacher == "Dvořák"
    changes = iter_changes(tt, baseline)
    assert len(changes) == 1
    assert changes[0]["day_key"] == "14.09.2026"
    assert "teacher" in changes[0]["diff"].changed


def test_room_move_and_cancelled_are_changes():
    tt = _three_weeks(patch=[(2, 0, {"room": "U99"})])
    baseline = _stable_of(tt, "31.08.2026")
    changes = iter_changes(tt, baseline)
    assert len(changes) == 1
    assert "room" in changes[0]["diff"].changed

    diff = classify_lesson(
        {"subject": "M", "teacher": "Novák", "room": "U12",
         "time": "1 (8:00 - 8:45)", "status": "cancelled"},
        day="07.09.2026", baseline=baseline)
    assert diff.is_change is True


def test_absent_status_is_not_a_schedule_change():
    tt = _two_weeks()
    baseline = baseline_from_stable_timetable(tt)
    diff = classify_lesson(
        {"subject": "M", "teacher": "Novák", "room": "U12",
         "time": "1 (8:00 - 8:45)", "status": "absent"},
        day="07.09.2026", baseline=baseline)
    assert diff.is_change is False


def test_without_baseline_keywords_decide():
    # No stable view: the annotated lesson counts via its substitution
    # keyword, the plain one stays quiet — nothing is learned from weeks.
    tt = {
        "08.09.2026": [{"subject": "F", "teacher": "Dvořák", "room": "F11",
                        "time": "2 (8:55 - 9:40)"}],
        "15.09.2026": [{"subject": "F", "teacher": "Král", "room": "F11",
                        "time": "2 (8:55 - 9:40)",
                        "notice": "Suplování (Král)"}],
    }
    changes = iter_changes(tt)
    assert len(changes) == 1
    assert changes[0]["day_key"] == "15.09.2026"


def test_tie_without_keywords_is_quiet():
    # A silent difference with no majority is NOT a change — with only
    # two disagreeing weeks nobody can tell which side is stable (e.g.
    # homeroom periods in the first school week).
    tt = {
        "08.09.2026": [{"subject": "Třídnická hodina", "teacher": "Picka",
                        "room": "VIII", "time": "1 (8:00 - 8:45)"}],
        "15.09.2026": [{"subject": "M", "teacher": "Novák", "room": "U12",
                        "time": "1 (8:00 - 8:45)",
                        "notice": "Povolená absence 30%"}],
    }
    assert iter_changes(tt) == []
    assert len(iter_notes(tt)) == 1


def test_resolve_day_lessons_phases():
    day = [{"subject": "M", "time": "1. 8:00 - 8:45"},
           {"subject": "F", "time": "2. 8:55 - 9:40"}]
    assert resolve_day_lessons(day, datetime(2026, 9, 8, 7, 30))["phase"] == "before"
    running = resolve_day_lessons(day, datetime(2026, 9, 8, 8, 10))
    assert running["phase"] == "running"
    assert running["current"]["subject"] == "M"
    between = resolve_day_lessons(day, datetime(2026, 9, 8, 8, 50))
    assert between["phase"] == "between"
    assert between["upcoming"]["subject"] == "F"
    assert resolve_day_lessons(day, datetime(2026, 9, 8, 20, 0))["phase"] == "done"
    assert resolve_day_lessons([], datetime(2026, 9, 8, 8, 0))["phase"] == "empty"


def test_future_lessons_drops_started():
    day = [{"subject": "M", "time": "1. 8:00 - 8:45"},
           {"subject": "F", "time": "2. 8:55 - 9:40"},
           {"subject": "X"}]  # no clock -> kept
    future = future_lessons(day, datetime(2026, 9, 8, 8, 50))
    assert [lesson["subject"] for lesson in future] == ["F", "X"]
    # During/after F only the clock-less row is still "plannable".
    future = future_lessons(day, datetime(2026, 9, 8, 9, 0))
    assert [lesson["subject"] for lesson in future] == ["X"]


def test_stable_weekly_hours_counts_baseline_slots():
    tt = _three_weeks()
    baseline = baseline_from_stable_timetable(tt)
    assert stable_weekly_hours(baseline) == {"M": 1, "F": 1}
    assert stable_weekly_hours({}) == {}
    assert stable_weekly_hours(None) == {}


def test_baseline_serialization_roundtrip():
    tt = _three_weeks()
    baseline = baseline_from_stable_timetable(tt)
    data = baseline_to_dict(baseline)
    assert set(data) == {"0|1", "0|2"}
    restored = baseline_from_dict(data)
    assert stable_weekly_hours(restored) == {"M": 1, "F": 1}
    assert restored[(0, 2)].teacher == "Dvořák"
    # Corrupt input never raises.
    assert baseline_from_dict(None) == {}
    assert baseline_from_dict({"bogus": {"subject": "X"}}) == {}


def test_forecast_prefers_stable_hours_over_raw_weeks():
    from strakalari.core import forecast as fc

    # Raw weeks contain a one-off extra Physics (substitution week) that
    # must not double its weekly hours in the forecast. The extra row has
    # no period clock, so the baseline ignores it while raw counting sees it.
    timetable = {
        "31.08.2026": [{"subject": "M", "time": "1 (8:00 - 8:45)"},
                       {"subject": "F", "time": "2 (8:55 - 9:40)"}],
        "07.09.2026": [{"subject": "M", "time": "1 (8:00 - 8:45)"},
                       {"subject": "F", "time": "2 (8:55 - 9:40)"}],
        "14.09.2026": [{"subject": "M", "time": "1 (8:00 - 8:45)"},
                       {"subject": "F", "time": "2 (8:55 - 9:40)"},
                       {"subject": "F"}],
    }
    baseline = baseline_from_stable_timetable(timetable)
    assert stable_weekly_hours(baseline) == {"M": 1, "F": 1}
    absence = {"M": 10.0, "F": 10.0}
    plain, _ = fc.forecast_all(absence, timetable, today=date(2026, 9, 7))
    stable, _ = fc.forecast_all(absence, timetable, today=date(2026, 9, 7),
                                stable_baseline=baseline)
    by_name = {s.name: s for s in stable}
    assert by_name["F"].weekly_hours == 1
    assert by_name["M"].weekly_hours == 1
    # Raw counting sees 4 F lessons over 3 days -> normalizes differently.
    assert {s.name: s.weekly_hours for s in plain} != {"M": 1, "F": 1}
    # A subject the baseline never saw is free to skip (never budgeted).
    absence2 = {"M": 10.0, "X": 10.0}
    mixed, _ = fc.forecast_all(absence2, timetable, today=date(2026, 9, 7),
                               stable_baseline=baseline)
    assert {s.name for s in mixed} == {"M"}


def test_baseline_from_stable_timetable_date_and_name_keys():
    stable = {
        # Scraped stable view may label days with dates ...
        "07.09.2026": [{"subject": "M", "teacher": "Novák", "room": "U12",
                        "time": "1 (8:00 - 8:45)"}],
        # ... or with weekday names.
        "Úterý": [{"subject": "F", "teacher": "Dvořák", "room": "F11",
                   "time": "2 (8:55 - 9:40)"}],
        "nonsense": [{"subject": "X", "time": "1 (8:00 - 8:45)"}],
    }
    baseline = baseline_from_stable_timetable(stable)
    assert set(baseline) == {(0, 1), (1, 2)}
    assert baseline[(0, 1)].subject == "M"
    assert baseline[(1, 2)].teacher == "Dvořák"
    assert baseline_from_stable_timetable({}) == {}


def _split_stable():
    """Stable view with a split-group slot: two lessons, one period."""
    return {
        "07.09.2026": [
            {"subject": "M", "teacher": "Novák", "room": "U12",
             "time": "1 (8:00 - 8:45)"},
            {"subject": "AJ", "teacher": "Bílá", "room": "J1",
             "time": "2 (8:55 - 9:40)", "group": "sk. 1"},
            {"subject": "NJ", "teacher": "Černý", "room": "J2",
             "time": "2 (8:55 - 9:40)", "group": "sk. 2"},
        ],
    }


def test_split_slot_keeps_every_variant():
    baseline = baseline_from_stable_timetable(_split_stable())
    assert baseline[(0, 1)].subject == "M"  # single stays unwrapped
    variants = baseline[(0, 2)]
    assert isinstance(variants, list) and len(variants) == 2
    assert {v.subject for v in variants} == {"AJ", "NJ"}


def test_split_slot_group_lessons_are_not_changes():
    baseline = baseline_from_stable_timetable(_split_stable())
    for subject, teacher in (("AJ", "Bílá"), ("NJ", "Černý")):
        diff = classify_lesson(
            {"subject": subject, "teacher": teacher,
             "room": "J1" if subject == "AJ" else "J2",
             "time": "2 (8:55 - 9:40)"},
            day="07.09.2026", baseline=baseline)
        assert diff.is_change is False
    # A stranger in the same slot IS a change, diffed vs closest variant.
    diff = classify_lesson(
        {"subject": "AJ", "teacher": "Král", "room": "J1",
         "time": "2 (8:55 - 9:40)", "notice": "Suplování"},
        day="07.09.2026", baseline=baseline)
    assert diff.is_change is True
    assert diff.changed == ["teacher"]
    assert len(iter_changes(
        {"07.09.2026": [
            {"subject": "AJ", "teacher": "Bílá", "room": "J1",
             "time": "2 (8:55 - 9:40)"},
            {"subject": "NJ", "teacher": "Černý", "room": "J2",
             "time": "2 (8:55 - 9:40)"}]},
        baseline)) == 0


def test_split_slot_hours_count_distinct_subjects():
    baseline = baseline_from_stable_timetable(_split_stable())
    assert stable_weekly_hours(baseline) == {"M": 1, "AJ": 1, "NJ": 1}
    # Same subject in both halves (split class, one teacher each) counts once.
    same_subject = baseline_from_stable_timetable({
        "07.09.2026": [
            {"subject": "TV", "teacher": "Malý", "room": "T1",
             "time": "3 (10:00 - 10:45)"},
            {"subject": "TV", "teacher": "Velká", "room": "T2",
             "time": "3 (10:00 - 10:45)"},
        ],
    })
    assert stable_weekly_hours(same_subject) == {"TV": 1}


def test_variant_serialization_roundtrip_and_closest():
    baseline = baseline_from_stable_timetable(_split_stable())
    data = baseline_to_dict(baseline)
    assert isinstance(data["0|2"], list) and len(data["0|2"]) == 2
    assert isinstance(data["0|1"], dict)
    restored = baseline_from_dict(data)
    assert {v.subject for v in restored[(0, 2)]} == {"AJ", "NJ"}
    nearest = closest_variant(
        restored[(0, 2)],
        {"subject": "NJ", "teacher": "Černý", "room": "J2",
         "time": "2 (8:55 - 9:40)"}, day="07.09.2026")
    assert nearest is not None and nearest.subject == "NJ"
    assert closest_variant(None, {}, day="07.09.2026") is None


def test_stable_template_week_renders_slots():
    from strakalari.core.helpers import extract_lesson_num

    baseline = baseline_from_stable_timetable(_split_stable())
    # Any date in the week works as anchor — output starts on Monday.
    week = stable_template_week(baseline, date(2026, 9, 9))
    assert list(week) == [date(2026, 9, 7)]
    lessons = week[date(2026, 9, 7)]
    assert [extract_lesson_num(r["time"]) for r in lessons] == [1, 2, 2]
    assert lessons[0]["subject"] == "M"
    assert lessons[0]["teacher"] == "Novák"
    assert "8:00" in lessons[0]["time"]
    assert {r["subject"] for r in lessons[1:]} == {"AJ", "NJ"}
    assert stable_template_week(None) == {}
    assert stable_template_week({(9, 1): None}) == {}


def test_core_schedule_period_of_zero():
    from strakalari.core.schedule import _period_of

    assert _period_of({"subject": "M", "period": 0}, None) == 0
    assert _period_of({"subject": "M", "period": 1}, None) == 1
    assert _period_of({"subject": "M"}, None) is None


def test_period_zero_sorts_first_not_last():
    from strakalari.core.schedule import _period_of

    periods = [10, 0, 1, 5]
    raws = [{"subject": "M", "period": p} for p in periods]
    ordered = sorted(raws, key=lambda raw: (
        _p if (_p := _period_of(raw, None)) is not None else 999))
    assert [r["period"] for r in ordered] == [0, 1, 5, 10]


class TestScheduleNegationGuard:
    def test_negated_notice_is_no_change_without_baseline(self):
        from strakalari.core.schedule import classify_lesson
        raw = {"subject": "M", "teacher": "T", "time": "1 (8:00 - 8:45)",
               "notice": "Neodpadá - beze změny"}
        assert classify_lesson(raw, day="07.09.2026", baseline=None).is_change is False

    def test_plain_cancel_notice_is_change_without_baseline(self):
        from strakalari.core.schedule import classify_lesson
        raw = {"subject": "M", "teacher": "T", "time": "1 (8:00 - 8:45)",
               "notice": "Odpadá"}
        assert classify_lesson(raw, day="07.09.2026", baseline=None).is_change is True

    def test_real_substitution_still_detected(self):
        from strakalari.core.schedule import classify_lesson
        raw = {"subject": "M", "teacher": "T", "time": "1 (8:00 - 8:45)",
               "notice": "Suplování (Král)"}
        assert classify_lesson(raw, day="07.09.2026", baseline=None).is_change is True
