"""Pending-excuse generation from the timetable (generate_excuses)."""
from datetime import datetime
import pytest
from strakalari.core.automation import Strakalari
from strakalari.core.automation import generate_excuses


def _absent_lesson(time="1 (8:00-8:45)"):
    return {"teacher": "T", "subject": "M", "time": time,
            "absenceType": "Absent", "absencetext": "Absence", "notice": ""}


class TestWeekendBridging:
    def test_gap_days_are_not_merged(self):
        raw = {
            "07.09.2026": [_absent_lesson()],
            "09.09.2026": [_absent_lesson()],
        }
        excuses = Strakalari.generate_excuses(raw, delay_days=0,
                                              override_today=datetime(2026, 9, 20))
        ranges = [(e["starting_day"], e["ending_day"]) for e in excuses
                  if e["type"] == "pure days"]
        assert ("07.09.2026", "07.09.2026") in ranges
        assert ("09.09.2026", "09.09.2026") in ranges
        assert not any(s != e for s, e in ranges)

    def test_truly_consecutive_days_still_merge(self):
        raw = {
            "07.09.2026": [_absent_lesson()],
            "08.09.2026": [_absent_lesson()],
        }
        excuses = Strakalari.generate_excuses(raw, delay_days=0,
                                              override_today=datetime(2026, 9, 20))
        assert {"type": "pure days", "starting_day": "07.09.2026",
                "ending_day": "08.09.2026"} in excuses


def _absent(time="1 (8:00-8:45)", notice=""):
    return {"teacher": "T", "subject": "M", "time": time,
            "absenceType": "Absent", "absencetext": "Absence",
            "notice": notice}


OVERRIDE_TODAY = datetime(2026, 9, 20)


class TestNegatedCancelNotice:
    @pytest.mark.parametrize("notice", [
        "Neodpadá - beze změny",
        "NEODPADÁ",
        "Nezrušeno",
        "nezruseno",
        "Hodina nevyjmuta ze suplování",
        "ne odpadá",
    ])
    def test_negated_notice_still_excuses(self, notice):
        from strakalari.core.automation import Strakalari
        raw = {"10.09.2026": [_absent(notice=notice)]}
        excuses = Strakalari.generate_excuses(
            raw, delay_days=0, override_today=OVERRIDE_TODAY)
        assert len(excuses) == 1

    @pytest.mark.parametrize("notice", [
        "Odpadá", "Hodina odpadá", "Zrušeno", "Zruseno",
        "Vyjmuto ze suplování", "Vyňato",
    ])
    def test_positive_notice_stays_cancelled(self, notice):
        from strakalari.core.automation import Strakalari
        raw = {"10.09.2026": [_absent(notice=notice)]}
        excuses = Strakalari.generate_excuses(
            raw, delay_days=0, override_today=OVERRIDE_TODAY)
        assert excuses == []


def _lesson(abs_type="Absent", abs_text="Absence", time="1 (8:00-8:45)"):
    return {"teacher": "T", "subject": "M", "time": time,
            "absenceType": abs_type, "absencetext": abs_text, "notice": ""}


OVERRIDE_TODAY_bugfix_r3 = datetime(2026, 9, 15)


class TestAbsenceCaseInsensitive:
    @pytest.mark.parametrize("abs_type,abs_text", [
        ("absent", "neomluveno"),
        ("ABSENT", "NEOMLUVENO"),
        ("Absent", "Neomluvena"),
        ("Absent", "Neomluvená"),
        ("Unexcused", "Absence"),
        ("unexcused", "absence"),
    ])
    def test_variants_generate_excuses(self, abs_type, abs_text):
        raw = {"10.09.2026": [_lesson(abs_type, abs_text)]}
        excuses = generate_excuses(raw, delay_days=0, override_today=OVERRIDE_TODAY_bugfix_r3)
        assert len(excuses) == 1

    @pytest.mark.parametrize("abs_type,abs_text", [
        ("AbsentLate", "Pozdni prichod"),
        ("absentlate", "pozdní příchod"),
    ])
    def test_late_variants_are_income(self, abs_type, abs_text):
        raw = {"10.09.2026": [_lesson(abs_type, abs_text)]}
        excuses = generate_excuses(raw, delay_days=0, override_today=OVERRIDE_TODAY_bugfix_r3)
        assert len(excuses) == 1
        assert excuses[0]["type"] == "income"

    def test_cutoff_is_date_based_not_hour_based(self):
        # Same absence must be included whether the run happens at 00:30
        # or 23:30 on the cutoff boundary day.
        raw = {"13.09.2026": [_lesson()]}
        morning = datetime(2026, 9, 15, 0, 30)
        night = datetime(2026, 9, 15, 23, 30)
        assert generate_excuses(raw, delay_days=2, override_today=morning) == \
            generate_excuses(raw, delay_days=2, override_today=night)


def _lesson_issue(teacher, subject, time, absencetext="", absenceType=""):
    return {
        "teacher": teacher,
        "subject": subject,
        "time": time,
        "absencetext": absencetext,
        "absenceType": absenceType,
    }


OVERRIDE_TODAY_issue = datetime(2026, 9, 15)


class TestExcusedLessonsSkipped:
    def test_excused_type_skipped(self):
        raw = {
            "10.09.2026": [
                _lesson_issue("T1", "M", "1", absencetext="Omluveno", absenceType="Excused"),
                _lesson_issue("T2", "F", "2", absencetext="Absence", absenceType="Absent"),
            ]
        }
        excuses = generate_excuses(raw, delay_days=1, override_today=OVERRIDE_TODAY_issue)
        assert len(excuses) == 1
        assert excuses[0]["starting_lesson"] == 2
        assert excuses[0]["ending_lesson"] == 2

    def test_excused_text_with_absent_type_skipped(self):
        # Lesson marked Absent type but already excused must NOT be re-excused.
        raw = {
            "10.09.2026": [
                _lesson_issue("T1", "M", "1", absencetext="Omluvená", absenceType="Absent"),
            ]
        }
        excuses = generate_excuses(raw, delay_days=1, override_today=OVERRIDE_TODAY_issue)
        assert excuses == []

    def test_fully_excused_day_produces_nothing(self):
        raw = {
            "10.09.2026": [
                _lesson_issue("T1", "M", "1", absencetext="Omluveno"),
                _lesson_issue("T2", "F", "2", absencetext="Omluveno"),
            ]
        }
        assert generate_excuses(raw, delay_days=1, override_today=OVERRIDE_TODAY_issue) == []


class TestHolidayBridging:
    def test_friday_and_tuesday_do_not_bridge(self):
        # 04.09.2026 = Friday, 08.09.2026 = Tuesday (Monday holiday, no data).
        # The gap must end the chain: one excuse per absent day, never a
        # range spanning the holiday.
        raw = {
            "04.09.2026": [
                _lesson_issue("T1", "M", "1", absencetext="Absence"),
                _lesson_issue("T2", "F", "2", absencetext="Absence"),
            ],
            "08.09.2026": [
                _lesson_issue("T1", "M", "1", absencetext="Absence"),
                _lesson_issue("T2", "F", "2", absencetext="Absence"),
            ],
        }
        excuses = generate_excuses(raw, delay_days=1, override_today=OVERRIDE_TODAY_issue)
        assert len(excuses) == 2
        assert all(e["type"] == "pure days" for e in excuses)
        assert excuses[0]["starting_day"] == excuses[0]["ending_day"] == "04.09.2026"
        assert excuses[1]["starting_day"] == excuses[1]["ending_day"] == "08.09.2026"

    def test_present_day_still_breaks_chain(self):
        raw = {
            "07.09.2026": [
                _lesson_issue("T1", "M", "1", absencetext="Absence"),
                _lesson_issue("T2", "F", "2", absencetext="Absence"),
            ],
            "08.09.2026": [
                _lesson_issue("T1", "M", "1"),
                _lesson_issue("T2", "F", "2"),
            ],
            "09.09.2026": [
                _lesson_issue("T1", "M", "1", absencetext="Absence"),
                _lesson_issue("T2", "F", "2", absencetext="Absence"),
            ],
        }
        excuses = generate_excuses(raw, delay_days=1, override_today=OVERRIDE_TODAY_issue)
        assert len(excuses) == 2
        assert excuses[0]["starting_day"] == "07.09.2026"
        assert excuses[1]["starting_day"] == "09.09.2026"


class TestTemplatePick:
    def test_first_mode(self):
        assert Strakalari._pick_template(["a", "b"], "first") == "a"

    def test_random_mode_picks_from_list(self):
        for _ in range(20):
            assert Strakalari._pick_template(["a", "b", "c"], "random") in ("a", "b", "c")

    def test_empty_templates(self):
        assert Strakalari._pick_template([], "random") == ""


class TestExcuseDelayConfig:
    def test_default_delay(self, tmp_path):
        bot = Strakalari(config_file=str(tmp_path / "c.json"), start_browser=False)
        assert bot.excuse_delay_days == 2

    def test_custom_delay(self, tmp_path):
        bot = Strakalari(
            config_file=str(tmp_path / "c.json"),
            config_data={"excuse_delay_days": 5},
            start_browser=False,
        )
        assert bot.excuse_delay_days == 5


def test_multi_group_status_prioritization():
    """
    Verify that in split class groups (e.g. language groups where period 2 has both
    a Czech and German group), an absent status is NOT overwritten by present status.
    """
    raw_data = {
        "10.09.2026": [
            {
                "teacher": "Mgr. Jan Novák",
                "subject": "Matematika",
                "time": "1 (8:00 - 8:45)",
                "absencetext": "",
                "absenceType": "",
            },
            {
                "teacher": "Mgr. Eva Bílá",
                "subject": "Německý jazyk (sk. 1)",
                "time": "2 (8:55 - 9:40)",
                "absencetext": "Absence",
                "absenceType": "Absent",
            },
            {
                # Split group: second entry for period 2 with present status
                "teacher": "Mgr. Petr Černý",
                "subject": "Francouzský jazyk (sk. 2)",
                "time": "2 (8:55 - 9:40)",
                "absencetext": "",
                "absenceType": "",
            },
        ]
    }

    # Override today so cutoff date includes 10.09.2026
    override_today = datetime(2026, 9, 15)
    excuses = generate_excuses(raw_data, delay_days=1, override_today=override_today)

    assert len(excuses) == 1
    excuse = excuses[0]
    assert excuse["type"] == "days and hours"
    assert excuse["starting_day"] == "10.09.2026"
    assert excuse["starting_lesson"] == 2
    assert excuse["ending_lesson"] == 2


def test_pure_days_consecutive():
    """
    Full days of absence across consecutive dates should be grouped into a single pure days excuse.
    """
    raw_data = {
        "07.09.2026": [
            {
                "teacher": "T1",
                "subject": "M",
                "time": "1",
                "absencetext": "Absence",
            },
            {
                "teacher": "T2",
                "subject": "F",
                "time": "2",
                "absencetext": "Absence",
            },
        ],
        "08.09.2026": [
            {
                "teacher": "T1",
                "subject": "M",
                "time": "1",
                "absencetext": "Absence",
            },
            {
                "teacher": "T2",
                "subject": "F",
                "time": "2",
                "absencetext": "Absence",
            },
        ],
    }

    override_today = datetime(2026, 9, 15)
    excuses = generate_excuses(raw_data, delay_days=1, override_today=override_today)

    assert len(excuses) == 1
    assert excuses[0]["type"] == "pure days"
    assert excuses[0]["starting_day"] == "07.09.2026"
    assert excuses[0]["ending_day"] == "08.09.2026"


def test_late_income_excuse():
    raw_data = {
        "10.09.2026": [
            {
                "teacher": "T1",
                "subject": "M",
                "time": "1",
                "absencetext": "Pozdní příchod",
                "absenceType": "AbsentLate",
            },
            {
                "teacher": "T2",
                "subject": "F",
                "time": "2",
                "absencetext": "",
            },
        ]
    }

    override_today = datetime(2026, 9, 15)
    excuses = generate_excuses(raw_data, delay_days=1, override_today=override_today)

    assert len(excuses) == 1
    assert excuses[0]["type"] == "income"
    assert excuses[0]["starting_lesson"] == 1
    assert excuses[0]["ending_lesson"] == 1


def test_pure_days_across_weekend():
    """
    Friday and Monday full absences must NOT bridge the weekend: no data
    exists for Saturday/Sunday, so each day gets its own excuse instead
    of one range covering days with no absence.
    04.09.2026 is Friday, 07.09.2026 is Monday.
    """
    raw_data = {
        "04.09.2026": [
            {"teacher": "T1", "subject": "M", "time": "1", "absencetext": "Absence"},
            {"teacher": "T2", "subject": "F", "time": "2", "absencetext": "Absence"},
        ],
        "07.09.2026": [
            {"teacher": "T1", "subject": "M", "time": "1", "absencetext": "Absence"},
            {"teacher": "T2", "subject": "F", "time": "2", "absencetext": "Absence"},
        ],
    }
    override_today = datetime(2026, 9, 15)
    excuses = generate_excuses(raw_data, delay_days=1, override_today=override_today)

    assert len(excuses) == 2
    assert all(e["type"] == "pure days" for e in excuses)
    assert excuses[0]["starting_day"] == excuses[0]["ending_day"] == "04.09.2026"
    assert excuses[1]["starting_day"] == excuses[1]["ending_day"] == "07.09.2026"


def test_delay_days_cutoff():
    """
    Absences occurring within delay_days window should be ignored until delay passes.
    """
    raw_data = {
        # 5 days ago: should be excused
        "10.09.2026": [
            {"teacher": "T1", "subject": "M", "time": "1", "absencetext": "Absence"}
        ],
        # 1 day ago: within delay_days=2 cutoff, should be skipped
        "14.09.2026": [
            {"teacher": "T1", "subject": "M", "time": "1", "absencetext": "Absence"}
        ],
    }
    override_today = datetime(2026, 9, 15)
    excuses = generate_excuses(raw_data, delay_days=2, override_today=override_today)

    assert len(excuses) == 1
    assert excuses[0]["starting_day"] == "10.09.2026"


def test_fragmented_same_day_absences():
    """
    Non-consecutive absences on the same day (e.g. absent period 1 and 4, present periods 2-3)
    must generate separate excuse entries.
    """
    raw_data = {
        "10.09.2026": [
            {"teacher": "T1", "subject": "M", "time": "1 (8:00 - 8:45)", "absencetext": "Absence"},
            {"teacher": "T2", "subject": "ČJ", "time": "2 (8:55 - 9:40)", "absencetext": ""},
            {"teacher": "T3", "subject": "AJ", "time": "3 (10:00 - 10:45)", "absencetext": ""},
            {"teacher": "T4", "subject": "D", "time": "4 (10:55 - 11:40)", "absencetext": "Absence"},
        ]
    }
    override_today = datetime(2026, 9, 15)
    excuses = generate_excuses(raw_data, delay_days=1, override_today=override_today)

    assert len(excuses) == 2
    assert excuses[0]["starting_lesson"] == 1
    assert excuses[0]["ending_lesson"] == 1
    assert excuses[1]["starting_lesson"] == 4
    assert excuses[1]["ending_lesson"] == 4


def test_generic_early_leave_is_auto_excused_like_ui():
    """AbsentEarly (předčasný odchod) was offered in the UI but never auto-excused."""
    from strakalari.core.models import absence_kind

    raw = {"10.09.2026": [
        {"teacher": "T", "subject": "M", "time": "1", "absencetext": "", "absenceType": ""},
        {"teacher": "T", "subject": "F", "time": "2", "absencetext": "Předčasný odchod",
         "absenceType": "AbsentEarly"},
    ]}
    assert absence_kind("AbsentEarly", "Předčasný odchod") == "early"
    excuses = generate_excuses(raw, delay_days=1, override_today=datetime(2026, 9, 15))
    assert [(e["type"], e["starting_lesson"]) for e in excuses] == [("soon", 2)]


def test_not_counted_absence_is_never_excused():
    """"Nezapočtená absence" is an absence on paper only — ignore it."""
    from strakalari.core.models import absence_kind

    assert absence_kind("NotCounted", "Nezapočtená absence") == ""
    assert absence_kind("", "Nezapočtená absence") == ""
    assert absence_kind("School", "Školní akce") == ""
    assert absence_kind("Absent", "Absence") == "absent"
    raw = {"10.09.2026": [
        {"teacher": "T", "subject": "M", "time": "1", "absencetext": "Nezapočtená absence",
         "absenceType": "NotCounted"},
        {"teacher": "T", "subject": "F", "time": "2", "absencetext": "Nezapočtená absence",
         "absenceType": "NotCounted"},
    ]}
    assert generate_excuses(raw, delay_days=1, override_today=datetime(2026, 9, 15)) == []
