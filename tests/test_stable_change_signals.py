"""Bakalari change signals: cancelled ("removed") rows and changeinfo codes.

Regression tests for the Friday-cancellation bug: the actual-week page
marks a cancelled lesson as ``type == "removed"`` with only
``removedinfo`` (``"Zrušeno (FG, Dušek Filip)"``) and a bare clock —
the old parser dropped the row, so the UI never showed a change.
Room moves arrive with ``infoChangeCode == "RoomChanged"`` and the
explanation in ``changeinfo`` while ``notice`` stays empty.
"""

import json


from strakalari.core.bakalari_client import BakalariClient, parse_timetable_detail
from strakalari.core.extractors.bakalari import parse_substitutions
from strakalari.core.helpers import extract_lesson_num
from strakalari.core.schedule import (
    apply_substitution_feed,
    backfill_stable_facts,
    baseline_from_stable_timetable,
    classify_lesson,
    iter_changes,
)


def _client():
    dummy_bm = type("DummyBM", (), {"page": None})()
    return BakalariClient(dummy_bm, {}, logger=None)


def _removed_detail():
    return {
        "type": "removed",
        "subjecttext": None,
        "teacher": None,
        "room": None,
        "absentinfo": None,
        "removedinfo": "Zrušeno (FG, Dušek Filip)",
        "AbsentInfo": None,
        "day": "18.9.2026 (pátek)",
        "time": "13:40 - 14:25",
    }


def _moved_detail():
    return {
        "type": "atom",
        "subjecttext": "Matematika",
        "teacher": "Mgr. Jana Tláskalová",
        "room": "II - (313)",
        "group": "8.1 celá - celá třída",
        "theme": "",
        "notice": "",
        "changeinfo": "Změna místnosti: II (I)",
        "absencetext": "",
        "absenceType": "NoAbsent",
        "day": "18.9.2026 (pátek)",
        "time": "3 (10:05 - 10:50)",
        "hourIndex": 5,
        "changeBadgeChar": "M",
        "infoChangeCode": "RoomChanged",
    }


def _html(*details):
    return "".join(
        f"<div data-detail='{json.dumps(d, ensure_ascii=False)}'></div>"
        for d in details
    )


def test_removed_row_parses_to_cancelled_lesson():
    lesson = parse_timetable_detail(_removed_detail())
    assert lesson is not None
    assert lesson["status"] == "cancelled"
    assert lesson["type"] == "removed"
    assert lesson["notice"] == "Zrušeno (FG, Dušek Filip)"
    assert lesson["time"] == "13:40 - 14:25"
    assert lesson["date"] == "18.9.2026 (pátek)"


def test_empty_removed_row_still_dropped():
    assert parse_timetable_detail({"type": "removed"}) is None
    assert parse_timetable_detail(None) is None


def test_atom_row_without_teacher_still_dropped():
    assert parse_timetable_detail(
        {"type": "atom", "teacher": "", "subjecttext": "Volná hodina",
         "day": "10.09.2026", "time": "3"}) is None


def test_room_move_keeps_changeinfo_as_note():
    lesson = parse_timetable_detail(_moved_detail())
    assert lesson is not None
    assert lesson["notice"] == "Změna místnosti: II (I)"
    assert lesson["infoChangeCode"] == "RoomChanged"
    assert lesson["changeBadgeChar"] == "M"
    assert lesson["room"] == "II"
    assert lesson.get("period") == 3


def test_extract_keeps_removed_rows():
    client = _client()
    client.extract_timetable_data(_html(_moved_detail(), _removed_detail()))
    friday = client.timetableData["18.9.2026 (pátek)"]
    assert len(friday) == 2
    removed = [lesson for lesson in friday if lesson.get("type") == "removed"]
    assert len(removed) == 1
    assert removed[0]["status"] == "cancelled"


def test_two_digit_clock_is_not_a_period():
    assert extract_lesson_num("13:40 - 14:25") is None
    assert extract_lesson_num("8:00 - 8:45") is None
    assert extract_lesson_num("3 (10:05 - 10:50)") == 3
    assert extract_lesson_num("3") == 3


def _stable():
    return {
        "Pátek": [
            {"subject": "Matematika", "teacher": "Tláskalová", "room": "I",
             "time": "3 (10:05 - 10:50)"},
            {"subject": "Finanční gramotnost", "teacher": "Dušek",
             "room": "VIII", "time": "7 (13:40 - 14:25)"},
        ],
    }


def test_backfill_matches_cancelled_lesson_to_stable_slot():
    baseline = baseline_from_stable_timetable(_stable())
    assert (4, 7) in baseline  # intermediate: the slot exists
    timetable = {"18.09.2026": [parse_timetable_detail(_removed_detail())]}
    assert backfill_stable_facts(timetable, baseline) == 1
    lesson = timetable["18.09.2026"][0]
    assert lesson["period"] == 7
    assert lesson["subject"] == "Finanční gramotnost"
    assert lesson["teacher"] == "Dušek"
    assert lesson["room"] == "VIII"
    # The human-readable cancellation note survives the enrichment.
    assert lesson["notice"] == "Zrušeno (FG, Dušek Filip)"


def test_backfill_is_safe_on_garbage():
    assert backfill_stable_facts(None, None) == 0
    assert backfill_stable_facts({}, {}) == 0
    assert backfill_stable_facts({"nonsense": [{"type": "removed"}]}, {}) == 0


def test_cancelled_lesson_classifies_as_change():
    baseline = baseline_from_stable_timetable(_stable())
    timetable = {"18.09.2026": [parse_timetable_detail(_removed_detail())]}
    backfill_stable_facts(timetable, baseline)
    diff = classify_lesson(timetable["18.09.2026"][0],
                           day="18.09.2026", baseline=baseline)
    assert diff.is_change is True
    assert diff.changed == ["status"]
    assert "Zrušeno" in diff.note


def test_room_move_classifies_as_change_with_stable():
    baseline = baseline_from_stable_timetable(_stable())
    diff = classify_lesson(parse_timetable_detail(_moved_detail()),
                           day="18.09.2026", baseline=baseline)
    assert diff.is_change is True
    assert "room" in diff.changed
    assert "Změna místnosti" in diff.note


def test_room_move_flagged_without_baseline():
    # Bakalari's own change code counts even with no stable to diff
    # against (the notice alone carries no keyword for a bare move).
    diff = classify_lesson(parse_timetable_detail(_moved_detail()),
                           day="18.09.2026", baseline=None)
    assert diff.is_change is True


def test_zruseno_note_counts_without_baseline():
    diff = classify_lesson(
        {"subject": "FG", "teacher": "Dušek", "time": "13:40 - 14:25",
         "notice": "Zrušeno (FG, Dušek Filip)"},
        day="18.09.2026", baseline=None)
    assert diff.is_change is True


def test_end_to_end_cancelled_vs_scraped_stable():
    client = _client()
    client.timetableData = {
        "18.09.2026": [
            {"subject": "Matematika", "teacher": "Tláskalová", "room": "I",
             "time": "3 (10:05 - 10:50)"},
            parse_timetable_detail(_removed_detail()),
        ],
    }
    client.stableTimetableData = _stable()
    baseline = client.update_stable_baseline()
    assert (4, 7) in baseline
    by_subject = {item["lesson"].get("subject"): item
                  for item in client.weekChanges}
    assert "Finanční gramotnost" in by_subject
    change = by_subject["Finanční gramotnost"]
    assert change["day_key"] == "18.09.2026"
    assert change["diff"].changed == ["status"]
    # The untouched lesson stays quiet.
    assert "Matematika" not in by_subject


def _added_detail():
    return {
        "type": "atom",
        "subjecttext": "Třídnická hodina",
        "teacher": "PaedDr. Jaroslav Picka",
        "room": "VIII - (114)",
        "group": "8.1 celá - celá třída",
        "theme": "Seznámení se ŠŘ a KŘ",
        "notice": "",
        "changeinfo": "Přidáno do rozvrhu: TřH, Picka Jaroslav, VIII",
        "absencetext": "",
        "absenceType": "NoAbsent",
        "day": "1.9.2026 (úterý)",
        "time": "1 (8:00 - 8:45)",
        "hourIndex": 3,
        "changeBadgeChar": "N",
        "infoChangeCode": "Added",
    }


def _substitution_detail():
    return {
        "type": "atom",
        "subjecttext": "Anglický jazyk",
        "teacher": "B.A. Christopher Neil Dunn P.G.C.E.",
        "room": "3A - (111)",
        "group": "8.1 sk2 - skupina 2",
        "theme": "(SUPPLY) Dn",
        "notice": "",
        "changeinfo": "Suplování: Dunn Christopher Neil (Pr)",
        "absencetext": "",
        "absenceType": "NoAbsent",
        "day": "2.9.2026 (středa)",
        "time": "4 (11:00 - 11:45)",
        "hourIndex": 6,
        "changeBadgeChar": "S",
        "infoChangeCode": "Substitution",
    }


def _vyjmuto_detail():
    detail = _removed_detail()
    detail["removedinfo"] = "Vyjmuto z rozvrhu (SFG, Korcová Zuzana)"
    detail["day"] = "1.9.2026 (úterý)"
    detail["time"] = "8:00 - 8:45"
    return detail


def test_vyjmuto_row_parses_to_cancelled_lesson():
    lesson = parse_timetable_detail(_vyjmuto_detail())
    assert lesson is not None
    assert lesson["status"] == "cancelled"
    assert lesson["subject"] == "SFG"
    assert lesson["teacher"] == "Korcová Zuzana"


def test_vyjmuto_counts_without_baseline():
    diff = classify_lesson(parse_timetable_detail(_vyjmuto_detail()),
                           day="1.9.2026", baseline=None)
    assert diff.is_change is True


def test_added_lesson_flagged_without_baseline():
    lesson = parse_timetable_detail(_added_detail())
    assert lesson["notice"] == "Přidáno do rozvrhu: TřH, Picka Jaroslav, VIII"
    diff = classify_lesson(lesson, day="1.9.2026", baseline=None)
    assert diff.is_change is True


def test_substitution_diffs_teacher_room_against_stable():
    stable = {
        "Středa": [
            {"subject": "Anglický jazyk", "teacher": "Perlíková",
             "room": "V", "time": "4 (11:00 - 11:45)"},
        ],
    }
    baseline = baseline_from_stable_timetable(stable)
    assert (2, 4) in baseline
    diff = classify_lesson(parse_timetable_detail(_substitution_detail()),
                           day="2.9.2026", baseline=baseline)
    assert diff.is_change is True
    assert "teacher" in diff.changed
    assert "Suplování" in diff.note


def test_late_lesson_keeps_teacher_note_as_note_not_change():
    from strakalari.core.models import Lesson

    raw = {"subject": "M", "teacher": "Tláskalová", "room": "III",
           "time": "3 (10:05 - 10:50)", "date": "3.9.2026 (čtvrtek)",
           "absenceType": "AbsentLate", "absencetext": "Pozdní příchod",
           "notice": "- kritéria hodnocení"}
    parsed = Lesson.from_legacy(raw, day="3.9.2026")
    assert parsed.status == "late"
    assert parsed.change == "- kritéria hodnocení"
    baseline = baseline_from_stable_timetable({
        "Čtvrtek": [{"subject": "M", "teacher": "Tláskalová", "room": "III",
                     "time": "3 (10:05 - 10:50)"}],
    })
    diff = classify_lesson(raw, day="3.9.2026", baseline=baseline)
    assert diff.is_change is False
    assert diff.note == "- kritéria hodnocení"


def _feed_html():
    def _entry(badge, period, time, info, description):
        return (
            '<div data-testid="substitutions-entry">'
            f'<div data-testid="substitutions-badge">{badge}</div>'
            f'<span data-testid="substitutions-hour-label">{period}</span>'
            f'<span data-testid="substitutions-time-label">{time}</span>'
            f'<div data-testid="substitutions-lesson-info">{info}</div>'
            '<div data-testid="substitutions-lesson-description">'
            f"<span>{description}</span></div></div>"
        )

    return (
        '<div data-testid="substitutions-day-header">čtvrtek 17.9.2026</div>'
        + _entry("M", "3", "10:05 - 10:50", "8.1 | M | VIII", "Změna místnosti: VIII")
        + '<div data-testid="substitutions-day-header">pátek 18.9.2026</div>'
        + _entry("O", "7", "13:40 - 14:25", "8.1 | FG | VIII", "Zrušeno")
    )


def test_parse_substitutions_reads_badges_and_days():
    entries = parse_substitutions(_feed_html())
    assert len(entries) == 2
    assert entries[0] == {
        "day": "17.9.2026", "period": 3, "time": "10:05 - 10:50",
        "badge": "M", "info": "8.1 | M | VIII", "subject_short": "M",
        "description": "Změna místnosti: VIII",
    }
    assert entries[1]["badge"] == "O"
    assert entries[1]["day"] == "18.9.2026"
    assert entries[1]["period"] == 7
    assert entries[1]["subject_short"] == "FG"


def test_parse_substitutions_never_raises():
    assert parse_substitutions("") == []
    assert parse_substitutions(None) == []
    assert parse_substitutions("<html>no feed here</html>") == []
    # Entries before any day header are orphaned and skipped.
    assert parse_substitutions(
        '<div data-testid="substitutions-entry">'
        '<div data-testid="substitutions-badge">M</div></div>') == []


def test_feed_stamps_signal_less_lesson():
    timetable = {
        "17.09.2026": [
            {"subject": "Matematika", "teacher": "Tláskalová", "room": "VIII",
             "time": "3 (10:05 - 10:50)", "date": "17.09.2026"},
        ],
    }
    feed = [parse_substitutions(_feed_html())[0]]
    assert apply_substitution_feed(timetable, feed) == 1
    lesson = timetable["17.09.2026"][0]
    assert lesson["infoChangeCode"] == "RoomChanged"
    assert "Změna místnosti: VIII" in lesson["notice"]
    # Second application is a no-op (no duplicated descriptions).
    assert apply_substitution_feed(timetable, feed) == 0
    assert lesson["notice"].count("Změna místnosti: VIII") == 1


def test_feed_synthesizes_missing_cancelled_lesson():
    timetable = {"18.09.2026": []}
    feed = [parse_substitutions(_feed_html())[1]]
    assert apply_substitution_feed(timetable, feed) == 1
    shell = timetable["18.09.2026"][0]
    assert shell["status"] == "cancelled"
    assert shell["type"] == "removed"
    assert shell["period"] == 7
    assert shell["subject"] == "FG"
    # The shell classifies as a change even with no baseline.
    diff = classify_lesson(shell, day="18.09.2026", baseline=None)
    assert diff.is_change is True


def test_feed_skips_non_cancelled_without_lesson():
    assert apply_substitution_feed({"18.09.2026": []}, [{
        "day": "18.9.2026", "period": 3, "time": "10:05 - 10:50",
        "badge": "M", "info": "", "subject_short": "M",
        "description": "Změna místnosti: II",
    }]) == 0


def test_feed_matches_period_less_cancelled_row_by_clock():
    # Awaiting backfill, the removed row has no period number: the feed
    # must match it by clock, not synthesize a duplicate shell.
    timetable = {
        "18.09.2026": [
            {"subject": "FG", "teacher": "Dušek Filip", "room": "",
             "time": "13:40 - 14:25", "date": "18.09.2026",
             "notice": "Zrušeno (FG, Dušek Filip)", "status": "cancelled",
             "type": "removed"},
        ],
    }
    feed = [parse_substitutions(_feed_html())[1]]
    assert apply_substitution_feed(timetable, feed) == 0
    assert len(timetable["18.09.2026"]) == 1


def test_feed_end_to_end_flags_unmarked_change():
    client = _client()
    client.timetableData = {
        "17.09.2026": [
            # Row identical to stable and carrying no signals: without
            # the feed nothing would flag it.
            {"subject": "Matematika", "teacher": "Tláskalová", "room": "III",
             "time": "3 (10:05 - 10:50)", "date": "17.09.2026",
             "notice": "", "infoChangeCode": ""},
        ],
    }
    client.stableTimetableData = {
        "Čtvrtek": [{"subject": "Matematika", "teacher": "Tláskalová",
                     "room": "III", "time": "3 (10:05 - 10:50)"}],
    }
    assert client.update_stable_baseline() and client.weekChanges == []
    client.substitutions = [parse_substitutions(_feed_html())[0]]
    baseline = client.update_stable_baseline()
    assert (3, 3) in baseline
    assert len(client.weekChanges) == 1
    assert "místnosti" in client.weekChanges[0]["diff"].note.lower()


def _friday_template():
    return {
        "Pátek": [
            {"subject": "Matematika", "teacher": "Tláskalová", "room": "I",
             "time": "3 (10:05 - 10:50)"},
            {"subject": "Finanční gramotnost", "teacher": "Dušek",
             "room": "VIII", "time": "7 (13:40 - 14:25)"},
        ],
    }


def _extra_hour_row():
    # Třídnická hodina in Friday p5: a free slot, carrying no signals.
    return {"subject": "Třídnická hodina", "teacher": "Svobodová",
            "room": "VIII", "time": "5 (11:55 - 12:40)",
            "date": "11.9.2026 (pátek)", "notice": "", "infoChangeCode": ""}


def test_added_hour_in_free_slot_needs_complete_template():
    baseline = baseline_from_stable_timetable(_friday_template())
    diff = classify_lesson(_extra_hour_row(), day="11.09.2026",
                           baseline=baseline, complete=True)
    assert diff.is_change is True
    assert diff.changed == ["added"]


def test_added_hour_silent_with_learned_fallback():
    # Same empty slot, but the baseline is not a complete template week:
    # an empty slot only means "no data", never an added hour.
    baseline = baseline_from_stable_timetable(_friday_template())
    diff = classify_lesson(_extra_hour_row(), day="11.09.2026",
                           baseline=baseline)
    assert diff.is_change is False


def test_missing_stable_hour_needs_complete_template():
    baseline = baseline_from_stable_timetable(_friday_template())
    timetable = {"11.09.2026": [
        {"subject": "Matematika", "teacher": "Tláskalová", "room": "I",
         "time": "3 (10:05 - 10:50)"},
    ]}
    assert iter_changes(timetable, baseline) == []
    missing = iter_changes(timetable, baseline, complete=True)
    assert len(missing) == 1
    item = missing[0]
    assert item["day_key"] == "11.09.2026"
    assert item["diff"].changed == ["missing"]
    assert item["diff"].is_change is True
    # The synthesized row carries the stable facts for rendering.
    assert item["lesson"]["subject"] == "Finanční gramotnost"
    assert item["lesson"]["period"] == 7


def test_split_slot_matches_any_variant():
    stable = {"Středa": [
        {"subject": "Tělesná výchova", "teacher": "Neumannová",
         "room": "TSOU", "time": "5 (11:55 - 12:40)"},
        {"subject": "Tělesná výchova", "teacher": "Neumannová",
         "room": "TSM", "time": "5 (11:55 - 12:40)"},
    ]}
    baseline = baseline_from_stable_timetable(stable)
    assert isinstance(baseline[(2, 5)], list)  # both rooms kept as stable
    one_room = {"subject": "Tělesná výchova", "teacher": "Neumannová",
                "room": "TSM", "time": "5 (11:55 - 12:40)"}
    assert classify_lesson(one_room, day="16.09.2026",
                           baseline=baseline).is_change is False
    assert classify_lesson(one_room, day="16.09.2026", baseline=baseline,
                           complete=True).is_change is False
    # A split slot covered by one variant is never reported missing.
    assert iter_changes({"16.09.2026": [one_room]}, baseline,
                        complete=True) == []
    other = dict(one_room, subject="Dějepis")
    assert classify_lesson(other, day="16.09.2026",
                           baseline=baseline).is_change is True


def test_no_stable_view_never_reports_added_or_missing():
    client = _client()
    client.timetableData = {
        "07.09.2026": [{"subject": "M", "teacher": "Novák", "room": "I",
                        "time": "1 (8:00 - 8:45)"}],
    }
    assert client.update_stable_baseline() == {}
    assert client.stable_complete is False
    # Without a scraped template nothing is guessed: a plain lesson stays quiet.
    unseen = {"subject": "Třídnická hodina", "teacher": "Picka",
              "room": "VIII", "time": "1 (8:00 - 8:45)", "notice": ""}
    timetable = dict(client.timetableData, **{"09.09.2026": [unseen]})
    assert iter_changes(timetable, {}) == []


def test_update_stable_baseline_tracks_completeness():
    client = _client()
    client.timetableData = {
        "18.09.2026": [{"subject": "Matematika", "teacher": "Tláskalová",
                        "room": "I", "time": "3 (10:05 - 10:50)"}],
    }
    client.stableTimetableData = {}
    assert client.update_stable_baseline() == {}
    assert client.stable_complete is False
    client.stableTimetableData = _stable()
    assert client.update_stable_baseline()
    assert client.stable_complete is True


def test_stable_complete_reads_cache_source(monkeypatch):
    import strakalari.flet_ui.state as state_mod
    from strakalari.flet_ui.state import AppState

    monkeypatch.setattr(state_mod, "load_data_cache", lambda: {})
    app_state = AppState()
    monkeypatch.setattr(app_state, "save", lambda updates: updates)
    assert app_state.stable_complete() is False
    app_state.data = {"stable_baseline_source": "scraped"}
    assert app_state.stable_complete() is True
    app_state.data = {"stable_baseline_source": "learned"}
    assert app_state.stable_complete() is False
