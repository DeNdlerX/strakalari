"""Parity oracle: runs pure Python functions and dumps expected outputs.

The Dart ports assert these JSON files byte-for-value (``dart test``
``parity_*_test.dart``). Reviewers regenerate with::

    PYTHONUTF8=1 python tools/parity/dump.py

and check ``git diff --exit-code`` on ``packages/strakalari_core/test/parity/``:
any difference means hand-edited expectations or drift.

Only OS- and environment-independent pure functions belong here (no data
dir, no keyring, no network, no ``now``). Dates are dumped as ISO strings.
``fn`` names are the Dart function names (lowerCamelCase).
"""

from __future__ import annotations

import json
import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, REPO_ROOT)

OUT_DIR = os.path.join(
    REPO_ROOT, "packages", "strakalari_core", "test", "parity")


def _jsonable(value):
    from datetime import date, datetime

    if isinstance(value, datetime):
        return {"__datetime__": value.isoformat()}
    if isinstance(value, date):
        return {"__date__": value.isoformat()}
    if isinstance(value, (list, tuple)):
        return [_jsonable(v) for v in value]
    if isinstance(value, dict):
        return {str(k): _jsonable(v) for k, v in value.items()}
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    return {"__repr__": repr(value)}


def _dump(module: str, cases: list[dict]) -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"{module}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"module": module, "cases": cases}, f,
                  indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {path} ({len(cases)} cases)")


def _case(fn: str, result, *args):
    return {"fn": fn, "args": [_jsonable(a) for a in args],
            "expected": _jsonable(result)}


def helpers_cases() -> list[dict]:
    from strakalari.core import helpers as h

    cases = []
    for text in ["15.09.2026", "1. 9. 2026", "3.9.2026 (čtvrtek)",
                 "Pondělí 1. 9. 2026", "2026-11-25", "25/11/2026",
                 "07.09.26", "2026/09/07"]:
        cases.append(_case("parseDate", h.parse_date(text), text))
    for text in ["3 (10:05 - 10:50)", "3", "8:00 - 8:45", "", "13:40 - 14:25"]:
        cases.append(_case("extractLessonNum", h.extract_lesson_num(text), text))
    for text in ["1. 8:00 - 8:45", "3 (10:05 - 10:50)", "8:00 - 8:45"]:
        cases.append(_case("shortTime", h.short_time(text), text))
    for text in ["Mgr. Jana Tláskalová", "Novák", "Bc. Jan Malý, Ph.D.", ""]:
        cases.append(_case("teacherSurname", h.teacher_surname(text), text))
    for text in ["Omluveno", "Neomluveno", "Unexcused Absence", "Excused",
                 "", "Omluvená absence"]:
        cases.append(_case("isExcusedMarker", h.is_excused_marker(text), text))
    for text in ["4A - (104)", "III - (P06)", "U12", "", "4A (104)"]:
        cases.append(_case("shortRoomName", h.short_room_name(text), text))
    cases.append(_case(
        "formatExcuseTemplate",
        h.format_excuse_template(
            "Dobrý den, omluvte absenci dne {date} na hodině {lessons} "
            "z předmětu {subject}.",
            date_str="15.09.2026", lessons_str="2. hodina",
            subject_str="Matematika", signature_str="Jan Novák"),
        "Dobrý den, omluvte absenci dne {date} na hodině {lessons} "
        "z předmětu {subject}.",
        "15.09.2026", "2. hodina", "Matematika", "Jan Novák"))
    for entry in ["plain", {"name": "N", "text": "T"}, {"name": "N"}, None, 5]:
        cases.append(_case("templateText", h.template_text(entry), entry))
    for value in [True, "1", "yes", False, "", "0"]:
        cases.append(_case("isEncryptedFlag", h.is_encrypted_flag(value), value))
    return cases


def models_cases() -> list[dict]:
    from strakalari.core import models as m

    cases = []
    for text in ["25.12.2026", "10.9.2026 (čtvrtek)", "2026-12-25",
                 "07/09/2026", "nonsense", ""]:
        cases.append(_case("parseCzDate", m.parse_cz_date(text), text))
    for value in ["10.9.2026 (čtvrtek)", "07.09.2026", "nonsense",
                  "2026-09-07"]:
        cases.append(_case("canonicalDayKey", m.canonical_day_key(value), value))
    for abs_type, abs_text in [
            ("Absent", "Absence"), ("Absent", "Neomluveno"),
            ("Unexcused", "Absence"), ("Excused", "Omluveno"),
            ("NoAbsent", "NoAbsent"), ("AbsentLate", "x"),
            ("AbsentSoon", "x"), ("", ""), ("School", "Školní akce")]:
        cases.append(_case("absenceKind",
                           m.absence_kind(abs_type, abs_text),
                           abs_type, abs_text))
    for text in ["Odpadá", "Zrušeno", "Neodpadá - beze změny",
                 "Nezrušeno", "Hodina beze změny", ""]:
        cases.append(_case("isCancelNotice", m.is_cancel_notice(text), text))
    lesson = m.Lesson.from_legacy(
        {"subject": "Matematika", "teacher": "T", "time": "1 (8:00-8:45)",
         "room": "4A - (104)", "absenceType": "Absent",
         "absencetext": "Absence"})
    cases.append(_case("lessonFromLegacy", {
        "subject": lesson.subject, "period": lesson.period,
        "status": lesson.status, "excused": lesson.excused,
        "room": lesson.room, "day": lesson.day,
    }, "absent-shape"))
    return cases


def i18n_cases() -> list[dict]:
    from strakalari.core import i18n

    cases = []

    def _t(key, lang, fmt=None):
        try:
            return {"fn": "t", "args": [_jsonable(key), _jsonable(fmt or {}),
                                        _jsonable(lang)],
                    "expected": _jsonable(i18n.t(key, lang=lang,
                                                **(fmt or {})))}
        finally:
            i18n.set_language("cs")

    cases.append(_t("period_label", "cs", {"n": 0}))
    cases.append(_t("auto_excuses_failed", "cs", {"n": 2}))
    cases.append(_t("period_label", "en", {"n": 0}))
    cases.append(_t("auto_excuses_failed", "en", {"n": 2}))
    cases.append(_t("non_existent_key_xyz", "en", None))
    # Missing fmt: the raw text with the placeholder is returned.
    i18n.set_language("cs")
    cases.append({"fn": "t", "args": [_jsonable("bak_login_rejected"),
                                      _jsonable({}), _jsonable("cs")],
                        "expected": _jsonable(i18n.t("bak_login_rejected"))})
    i18n.set_language("cs")
    return cases


def cache_cases() -> list[dict]:
    from datetime import date

    from strakalari.core import cache as c

    cases = []
    old = {"18.09.2026": [{"subject": "M"}],
           "19.09.2026": [{"subject": "F"}]}
    fresh = {"19.09.2026": [{"subject": "F2"}],
             "20.09.2026": []}
    cases.append(_case(
        "mergeTimetableDays",
        c.merge_timetable_days(old, fresh,
                               window_start=date(2026, 9, 1)),
        old, fresh, date(2026, 9, 1)))
    cases.append(_case(
        "mergeTimetableDays",
        c.merge_timetable_days({"19.09.2026": [{"subject": "F"}]},
                               {"19.09.2026": []},
                               window_start=date(2026, 9, 1)),
        {"19.09.2026": [{"subject": "F"}]},
        {"19.09.2026": []}, date(2026, 9, 1)))
    old_garbage = {"10.8.2026 (pondělí)": [{"subject": "old"}],
                   "01.09.2026": [{"subject": "boundary"}],
                   "not-a-date": [{"subject": "kept"}]}
    cases.append(_case(
        "mergeTimetableDays",
        c.merge_timetable_days(old_garbage, {},
                               window_start=date(2026, 9, 1)),
        old_garbage, {}, date(2026, 9, 1)))
    cases.append(_case(
        "mergeTimetableDays",
        c.merge_timetable_days({"10.8.2026 (pondělí)": []}, {}),
        {"10.8.2026 (pondělí)": []}, {}))
    cases.append(_case("mergeTimetableDays",
                       c.merge_timetable_days(None, None), None, None))
    return cases


def config_cases() -> list[dict]:
    import copy

    from strakalari.core import config as cfg

    cases = []
    for text in ["VAS_BAKALARI_LOGIN", "vas_strava_login", "CISLO_JIDELNY",
                 "example value", "YOUR_BLACKLIST_EXAMPLE", "novak",
                 "https://skola.cz", ""]:
        cases.append(_case("looksLikePlaceholder",
                           cfg._looks_like_placeholder(text), text))
    for row in [
            {"bakalari_username": "", "bakalari_url": "",
             "strava_username": "student", "strava_canteen_id": "1950"},
            {"bakalari_username": "novak",
             "bakalari_url": "https://skola.cz",
             "strava_username": "novak", "strava_canteen_id": "1950"},
            {"bakalari_username": "VAS_BAKALARI_LOGIN",
             "bakalari_url": "https://vas-bakalari-portal.cz",
             "strava_username": "x", "strava_canteen_id": "CISLO_JIDELNY"},
            {"bakalari_username": "student",
             "bakalari_url": "https://skola.cz",
             "strava_username": "VAS_STRAVA_LOGIN",
             "strava_canteen_id": "1950"},
    ]:
        cases.append(_case("hasValidCredentials",
                           list(cfg.has_valid_credentials(row)), row))
    base = copy.deepcopy(cfg.CANONICAL_DEFAULTS)
    base.update({"use_strava": True, "strava_username": "u",
                 "strava_canteen_id": "1"})
    cases.append(_case("validateConfig", cfg.validate_config(base), base))
    bad_mode = dict(base)
    bad_mode["excuse_mode"] = "sometimes"
    cases.append(_case("validateConfig",
                       cfg.validate_config(bad_mode), bad_mode))
    bad_weeks = dict(base)
    bad_weeks["go_back_weeks"] = 99
    bad_weeks["go_forward_weeks"] = 99
    cases.append(_case("validateConfig",
                       cfg.validate_config(bad_weeks), bad_weeks))
    return cases


def audit_cases() -> list[dict]:
    from strakalari.core import audit as a

    cases = []
    cases.append(_case(
        "describeExcuse",
        a.describe_excuse({"type": "days and hours",
                           "starting_day": "01.09.2026",
                           "ending_day": "01.09.2026",
                           "starting_lesson": 2, "ending_lesson": 4}),
        {"type": "days and hours", "starting_day": "01.09.2026",
         "ending_day": "01.09.2026", "starting_lesson": 2,
         "ending_lesson": 4}))
    cases.append(_case(
        "describeExcuse",
        a.describe_excuse({"type": "days and hours",
                           "starting_day": "01.09.2026",
                           "ending_day": "03.09.2026"}),
        {"type": "days and hours", "starting_day": "01.09.2026",
         "ending_day": "03.09.2026"}))
    cases.append(_case(
        "describeExcuse",
        a.describe_excuse({"type": "single", "starting_day": "01.09.2026",
                           "starting_lesson": 2, "ending_lesson": 2}),
        {"type": "single", "starting_day": "01.09.2026",
         "starting_lesson": 2, "ending_lesson": 2}))
    return cases


def history_cases() -> list[dict]:
    from datetime import date, datetime, timedelta

    from strakalari.core import excuse_history as h

    cases = []
    week = {"type": "pure days", "starting_day": "07.09.2026",
            "ending_day": "11.09.2026"}
    hours = {"type": "days and hours", "starting_day": "14.09.2026",
             "ending_day": "14.09.2026",
             "starting_lesson": 2, "ending_lesson": 4}
    cases.append(_case(
        "normalizeHistoryItem",
        h.normalize_history_item({"type": "pure days",
                                  "starting_day": "7.9.2026",
                                  "ending_day": "8.9.2026"}),
        {"type": "pure days", "starting_day": "7.9.2026",
         "ending_day": "8.9.2026"}))
    cases.append(_case(
        "baseExcuse",
        h.base_excuse({"type": "soon", "starting_day": "3.9.2026",
                       "ending_day": "3.9.2026", "starting_lesson": 5,
                       "ending_lesson": 5, "templates": ["ui-only"]}),
        {"type": "soon", "starting_day": "3.9.2026",
         "ending_day": "3.9.2026", "starting_lesson": 5,
         "ending_lesson": 5, "templates": ["ui-only"]}))
    today = date(2026, 9, 25)
    cases.append(_case("excuseWindowStart",
                       h.excuse_window_start(today), today, None))
    cases.append(_case("excuseWindowStart",
                       h.excuse_window_start(today, date(2026, 9, 10)),
                       today, date(2026, 9, 10)))
    sent = {"type": "soon", "starting_day": "3.9.2026",
            "ending_day": "3.9.2026", "starting_lesson": 5,
            "ending_lesson": 5, "templates": ["ui-only"]}
    cases.append(_case("historyEntries", h.history_entries(sent), sent))
    old_hist = [dict(week)]
    web = [dict(hours),
           {"type": "pure days", "starting_day": "7.9.2026",
            "ending_day": "11.9.2026"}]
    merged, added = h.merge_sent_excuses(old_hist, web)
    cases.append(_case("mergeSentExcuses", [merged, added],
                       old_hist, web))
    cases.append(_case(
        "excuseCovered",
        h.excuse_covered({"type": "days and hours",
                          "starting_day": "14.09.2026",
                          "ending_day": "14.09.2026",
                          "starting_lesson": 3, "ending_lesson": 4},
                         [dict(hours)]),
        {"type": "days and hours", "starting_day": "14.09.2026",
         "ending_day": "14.09.2026", "starting_lesson": 3,
         "ending_lesson": 4}, [dict(hours)]))
    cases.append(_case(
        "taskCovered",
        h.task_covered(date(2026, 9, 14), 2, [dict(hours)]),
        date(2026, 9, 14), 2, [dict(hours)]))
    cases.append(_case(
        "unconfirmedPath",
        h.unconfirmed_path("/d/already_excused_lessons.json"),
        "/d/already_excused_lessons.json"))
    lesson = {"type": "days and hours", "starting_day": "21.09.2026",
              "ending_day": "21.09.2026",
              "starting_lesson": 3, "ending_lesson": 4}
    now = datetime(2026, 9, 25, 12, 0)
    cases.append(_case("unconfirmedEntry",
                       h.unconfirmed_entry(lesson, now), lesson, now))
    pending = [h.unconfirmed_entry(lesson, now)]
    probe = dict(lesson, starting_lesson=6, ending_lesson=6)
    cases.append(_case("unconfirmedBlocks",
                       h.unconfirmed_blocks(probe, pending), probe, pending))
    old_ts = now - timedelta(minutes=6)
    sent_e = h.unconfirmed_entry(lesson, old_ts)
    day_e = h.unconfirmed_entry({"type": "pure days",
                                 "starting_day": "22.09.2026",
                                 "ending_day": "22.09.2026"}, old_ts)
    still, confirmed, not_sent = h.resolve_unconfirmed(
        [sent_e, day_e], [dict(lesson)], date(2026, 8, 26), now=now)
    cases.append(_case("resolveUnconfirmed", [still, confirmed, not_sent],
                       [sent_e, day_e], [dict(lesson)],
                       date(2026, 8, 26), now))
    return cases


def bakalari_cases() -> list[dict]:
    import json as _json

    from strakalari.core import bakalari_common as _common
    from strakalari.core.extractors import bakalari as _x

    cases = []
    removed = {"type": "removed", "subjecttext": None, "teacher": None,
               "room": None, "absentinfo": None,
               "removedinfo": "Zrušeno (FG, Dušek Filip)",
               "AbsentInfo": None, "day": "18.9.2026 (pátek)",
               "time": "13:40 - 14:25"}
    cases.append(_case("parseTimetableDetail",
                       _common.parse_timetable_detail(dict(removed)),
                       dict(removed)))
    moved = {"type": "atom", "subjecttext": "Matematika",
             "teacher": "Mgr. Jana Tláskalová", "room": "II - (313)",
             "group": "8.1 celá - celá třída", "theme": "",
             "notice": "", "changeinfo": "Změna místnosti: II (I)",
             "absencetext": "", "absenceType": "NoAbsent",
             "day": "18.9.2026 (pátek)", "time": "3 (10:05 - 10:50)",
             "hourIndex": 5, "changeBadgeChar": "M",
             "infoChangeCode": "RoomChanged"}
    cases.append(_case("parseTimetableDetail",
                       _common.parse_timetable_detail(dict(moved)),
                       dict(moved)))
    base = {"teacher": "T", "subjecttext": "M", "day": "07.09.2026",
            "time": "bez čísla"}
    cases.append(_case("parseTimetableDetail",
                       _common.parse_timetable_detail(
                           {**base, "hourIndex": 3}),
                       {**base, "hourIndex": 3}))
    cases.append(_case("parseTimetableDetail",
                       _common.parse_timetable_detail(
                           {**base, "hourIndex": 2}),
                       {**base, "hourIndex": 2}))
    cases.append(_case("parseTimetableDetail",
                       _common.parse_timetable_detail(
                           {"type": "removed"}),
                       {"type": "removed"}))
    event = {"absentinfo": "B", "removedinfo": "beseda",
             "day": "18.09.2026", "time": "1 (8:00 - 8:45)"}
    cases.append(_case("parseTimetableDetail",
                       _common.parse_timetable_detail(dict(event)),
                       dict(event)))
    cases.append(_case("weekOffsets",
                       _common.week_offsets(4, 1), 4, 1))
    cases.append(_case("weekOffsets",
                       _common.week_offsets("nonsense", None),
                       "nonsense", None))
    cases.append(_case("weekOffsets",
                       _common.week_offsets(0, 0), 0, 0))
    import html as _html

    def _mark(subject, grade, weight, day):
        blob = _json.dumps(
            {"nazev": subject, "MarkText": grade, "vaha": weight,
             "udel_datum": day}, ensure_ascii=False)
        return ('<div data-clasif="' +
                _html.escape(blob, quote=True) + '"></div>')

    grades_html = (_mark("Matematika", "3", 10, "12.09.2026") +
                   _mark("Matematika", "1", 10, "05.09.2026") +
                   _mark("Fyzika", "2", 5, "06.09.2026"))
    cases.append(_case("extractGrades",
                       _x.extract_grades(grades_html), grades_html))
    cases.append(_case("extractGrades", _x.extract_grades(""), ""))
    detail = {"Kind": "OMLUVENKA", "DateFrom": "3.9.2026",
              "DateTo": "3.9.2026", "TimeFrom": "10:05", "TimeTo": "10:50",
              "HourFrom": {"Caption": "3"}, "HourTo": {"Caption": "3"}}
    cases.append(_case("sentExcuseEntries",
                       _x.sent_excuse_entries(dict(detail)), dict(detail)))
    cases.append(_case("sentExcuseEntries",
                       _x.sent_excuse_entries(
                           {"Kind": "OMLUVENKA", "DateFrom": "nikdy"}),
                       {"Kind": "OMLUVENKA", "DateFrom": "nikdy"}))
    rows = [{"Name": "Matematika", "LessonCount": 100, "Count": 12,
             "Percent": 0.12},
            {"Name": "Celkem", "LessonCount": 500, "Count": 60,
             "Percent": 0.12},
            {"Name": "Fyzika", "LessonCount": 80, "Count": 20,
             "Percent": 0.25},
            {"Name": "Fyzika", "LessonCount": 80, "Count": 8,
             "Percent": 0.1}]
    percentages, details = _x.absence_from_subjects(rows)
    cases.append(_case("absenceFromSubjects",
                       [percentages, details], rows))
    subj = [{"SubjectName": "Matematika",
             "TeacherName": "Mgr. Jan Novák"}]
    cases.append(_case("subjectDirectory", _x.subject_directory_from_rows(subj), subj))
    content = {"Days": [{"Hours": [{"Atoms": [
        {"TooltipDetails": '{"teacher": "T"}'},
        {"TooltipDetails": "{broken"}]}]}]}
    cases.append(_case("timetableDetails",
                       _x.timetable_details(content), content))
    page = ('DatesInformations = ko.mapping.fromJS('
            '{"DefaultDateFrom": {"DefaultValue": "01.09.2026"}, '
            '"DefaultDateTo": {"DefaultValue": "30.09.2026"}});')
    cases.append(_case("absenceDateRange",
                       list(_x.absence_date_range(page) or []), page))
    change = {"Day": "čtvrtek 17.9.2026", "HourLabel": "3",
              "TimeLabel": "10:05 - 10:50", "ChangeType": "RoomChanged",
              "Description": "Změna místnosti: VIII",
              "ChangeLessonInfo": {"ClassAbbrev": "8.1",
                                  "IsClassGroup": True,
                                  "SubjectAbbrev": "M",
                                  "RoomAbbrev": "VIII"}}
    cases.append(_case("substitutionsFromWeeks",
                       _x.substitutions_from_weeks(
                           [{"Title": "", "Changes": [dict(change)]}]),
                       [{"Title": "", "Changes": [dict(change)]}]))
    listing = ('<table data-idmsg="501" data-msgtype="OMLUVENKA">'
               '<table data-idmsg="502" data-msgtype="OBECNA">'
               '<table data-idmsg="501" data-msgtype="OMLUVENKA">')
    cases.append(_case("outboxExcuseIds",
                       _x.outbox_excuse_ids(listing), listing))
    cases.append(_case("storeRows",
                       _x.store_rows({"data": [1], "totalCount": 1}),
                       {"data": [1], "totalCount": 1}))
    return cases


def main() -> None:
    _dump("helpers", helpers_cases())
    _dump("models", models_cases())
    _dump("i18n", i18n_cases())
    _dump("cache", cache_cases())
    _dump("config", config_cases())
    _dump("audit", audit_cases())
    _dump("history", history_cases())
    _dump("bakalari", bakalari_cases())


if __name__ == "__main__":
    main()
