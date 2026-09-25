"""Lesson models: status classification, periods, excuse tasks."""
from datetime import date, datetime
from strakalari.core.models import (
    Lesson,
    excuse_tasks_from_lessons,
    lessons_from_timetable,
    parse_cz_date,
)


class TestPeriodParsing:
    def test_period_derived_from_time_string(self):
        from strakalari.core.models import Lesson
        lesson = Lesson.from_legacy({"subject": "M", "teacher": "T",
                                     "time": "3 (10:05 - 10:50)"})
        assert lesson.period == 3

    def test_same_subject_keys_are_unique_per_period(self):
        from strakalari.core.models import excuse_tasks_from_lessons, lessons_from_timetable
        timetable = {"07.09.2026": [
            {"subject": "Matematika", "teacher": "T", "time": "1 (8:00-8:45)",
             "absenceType": "Absent", "absencetext": "Absence"},
            {"subject": "Matematika", "teacher": "T", "time": "2 (8:55-9:40)",
             "absenceType": "Absent", "absencetext": "Absence"},
        ]}
        tasks = excuse_tasks_from_lessons(lessons_from_timetable(timetable))
        assert len(tasks) == 2
        assert tasks[0].key != tasks[1].key


def _absent_lesson(time="1 (8:00-8:45)", abs_type="Absent", abs_text="Absence"):
    return {"teacher": "T", "subject": "M", "time": time,
            "absenceType": abs_type, "absencetext": abs_text, "notice": ""}


class TestExcusedMarker:
    def test_negations_are_not_excused(self):
        from strakalari.core.helpers import is_excused_marker
        assert is_excused_marker("Absent Neomluveno") is False
        assert is_excused_marker("Absent Neomluvená") is False
        assert is_excused_marker("Unexcused Absence") is False
        assert is_excused_marker("") is False

    def test_positive_markers_still_match(self):
        from strakalari.core.helpers import is_excused_marker
        assert is_excused_marker("Omluveno") is True
        assert is_excused_marker("Excused") is True
        assert is_excused_marker("Omluvená absence") is True

    def test_neomluveno_lesson_is_absent(self):
        from strakalari.core.models import Lesson
        lesson = Lesson.from_legacy({
            "subject": "M", "teacher": "T", "time": "1 (8:00-8:45)",
            "absenceType": "Absent", "absencetext": "Neomluveno"})
        assert lesson.status == "absent"
        assert lesson.excused is False

    def test_unexcused_type_is_absent(self):
        from strakalari.core.models import Lesson
        lesson = Lesson.from_legacy({
            "subject": "M", "teacher": "T", "time": "1 (8:00-8:45)",
            "absenceType": "Unexcused", "absencetext": "Absence"})
        assert lesson.status == "absent"
        assert lesson.excused is False

    def test_omluveno_stays_excused(self):
        from strakalari.core.models import Lesson
        lesson = Lesson.from_legacy({
            "subject": "M", "teacher": "T", "time": "1 (8:00-8:45)",
            "absenceType": "Excused", "absencetext": "Omluveno"})
        assert lesson.status == "excused"
        assert lesson.excused is True

    def test_engine_excuses_neomluveno_day(self):
        from strakalari.core.automation import Strakalari
        raw = {"07.09.2026": [_absent_lesson(abs_text="Neomluveno")]}
        excuses = Strakalari.generate_excuses(
            raw, delay_days=0, override_today=datetime(2026, 9, 20))
        assert {"type": "pure days", "starting_day": "07.09.2026",
                "ending_day": "07.09.2026"} in excuses

    def test_engine_excuses_unexcused_type(self):
        from strakalari.core.automation import Strakalari
        raw = {"07.09.2026": [_absent_lesson(abs_type="Unexcused")]}
        excuses = Strakalari.generate_excuses(
            raw, delay_days=0, override_today=datetime(2026, 9, 20))
        assert len(excuses) == 1


def test_noabsent_text_is_present():
    from strakalari.core.models import _lesson_status_from_legacy as status

    assert status({"absencetext": "NoAbsent"})[0] != "absent"
    assert status({"absencetext": "no absence"})[0] != "absent"
    assert status({"absencetext": "Neomluveno"})[0] == "absent"
    assert status({"absencetext": "Unexcused"})[0] == "absent"
    assert status({"absenceType": "NoAbsent"})[0] != "absent"
    assert status({"absenceType": "Absent"})[0] == "absent"


def test_lesson_keeps_period_zero():
    assert Lesson.from_legacy({"subject": "M", "period": 0}).period == 0


def test_excuse_task_label_keeps_period_zero():
    tasks = excuse_tasks_from_lessons(
        [Lesson(subject="M", period=0, status="absent")])
    assert tasks and "0. hodina" in tasks[0].label


class TestCancelNegation:
    def _status(self, raw):
        from strakalari.core.models import _lesson_status_from_legacy
        return _lesson_status_from_legacy(raw)[0]

    def test_plain_cancel_still_cancelled(self):
        assert self._status({"notice": "Odpadá"}) == "cancelled"
        assert self._status({"notice": "Zrušeno"}) == "cancelled"
        assert self._status({"type": "removed", "removedinfo": "Zrušeno (FG, Novák)"}) == "cancelled"

    def test_negated_notice_is_not_cancelled(self):
        assert self._status({"notice": "Neodpadá - beze změny"}) != "cancelled"
        assert self._status({"notice": "Nezrušeno"}) != "cancelled"
        assert self._status({"notice": "Hodina beze změny"}) != "cancelled"

    def test_authoritative_removed_row_wins_over_notice(self):
        # Bakalari's own verdict (type=removed) is a real cancellation
        # even if the notice text looks negated.
        assert self._status({
            "type": "removed",
            "removedinfo": "Zrušeno (FG, Novák)",
            "notice": "Neodpadá",
        }) == "cancelled"


def test_early_task_kind_is_early():
    from strakalari.core.models import Lesson, excuse_tasks_from_lessons
    lessons = [
        Lesson(subject="M", status="early", excused=False),
        Lesson(subject="F", status="absentearly", excused=False),
        Lesson(subject="C", status="late", excused=False),
        Lesson(subject="A", status="absent", excused=False),
    ]
    tasks = excuse_tasks_from_lessons(lessons)
    assert sorted(t.kind for t in tasks) == ["early", "early", "late", "short"]


def test_parse_cz_date():
    assert parse_cz_date("25.12.2026") == date(2026, 12, 25)
    assert parse_cz_date("2026-12-25") == date(2026, 12, 25)
    assert parse_cz_date("nonsense") is None
    assert parse_cz_date("") is None


def test_lessons_from_timetable():
    raw = {"25.12.2026": [{"subject": "Matematika", "time": "1. 8:00 - 8:45",
                            "room": "U12", "status": "absent"}]}
    lessons = lessons_from_timetable(raw)
    assert len(lessons) == 1
    assert lessons[0].subject == "Matematika"
    assert lessons[0].day == date(2026, 12, 25)


def test_excuse_tasks_only_unexcused():
    lessons = [
        Lesson(subject="M", status="absent", excused=False),
        Lesson(subject="F", status="absent", excused=True),
        Lesson(subject="C", status="present", excused=False),
        Lesson(subject="A", status="late", excused=False),
    ]
    tasks = excuse_tasks_from_lessons(lessons)
    assert len(tasks) == 2
    assert all(t.label for t in tasks)
    kinds = sorted(t.kind for t in tasks)
    assert kinds == ["late", "short"]
