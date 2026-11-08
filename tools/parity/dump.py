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
    # DST day arithmetic (Europe/Prague switches 29.3.2026 and 25.10.2026):
    # plain date math has no DST, the Dart port must match it exactly.
    from datetime import date as _date, timedelta as _td
    for y, m, d, n in [(2026, 3, 30, -2), (2026, 10, 28, -5),
                       (2026, 3, 27, 5),
                       (2026, 10, 19, 14), (2026, 4, 15, -30)]:
        start = _date(y, m, d)
        cases.append(_case("addDays", start + _td(days=n), start, n))
    for first, last in [((2026, 3, 28), (2026, 3, 30)),
                        ((2026, 10, 23), (2026, 10, 28)),
                        ((2026, 10, 26), (2026, 10, 19)),
                        ((2026, 10, 26), (2026, 10, 25)),
                        ((2026, 3, 27), (2026, 4, 1))]:
        a, b = _date(*first), _date(*last)
        cases.append(_case("daysBetween", (b - a).days, a, b))
    # JSON writers: audit lines use json.dumps defaults (", " / ": "),
    # data files use json.dump(indent=2); both keep non-ASCII as is.
    samples = [
        {"ts": "2026-11-08T10:00:00", "kind": "excuse", "outcome": "sent",
         "summary": "Příliš žluťoučký kůň", "detail": {"days": ["01.09.2026"],
                                                       "n": 2, "ok": True,
                                                       "none": None}},
        {"a": [], "b": {}, "c": [1, [2, 3], {"d": "e\"f\\g\n\t"}], "z": ""},
        ["x", 1, True, None, {"k": []}],
    ]
    for sample in samples:
        cases.append(_case("pyJsonDumps",
                           json.dumps(sample, ensure_ascii=False), sample))
        cases.append(_case("jsonIndent2",
                           json.dumps(sample, indent=2, ensure_ascii=False),
                           sample))
    # Key store entry name normalization (A-M5): normcase(abspath(data_dir)).
    import hashlib
    import ntpath
    import posixpath

    def _entry_name_win(raw: str) -> str:
        norm = ntpath.normcase(ntpath.normpath(raw))
        digest = hashlib.sha256(norm.encode("utf-8")).hexdigest()[:16]
        return f"fernet-key:{digest}"

    def _entry_name_posix(raw: str) -> str:
        norm = posixpath.normcase(posixpath.normpath(raw))
        digest = hashlib.sha256(norm.encode("utf-8")).hexdigest()[:16]
        return f"fernet-key:{digest}"

    for raw in [
        "C:\\Users\\Student\\AppData\\Local\\Strakalari",
        "C:/Users/Student/AppData/Local/Strakalari",
        "C:\\Users\\Student\\AppData\\Local\\Strakalari\\",
        "C:/Users/Student/AppData/Local/Strakalari/",
        "C:/Users/Student/AppData/Local/Other/../Strakalari/./",
        "c:\\USERS\\student\\AppData\\LOCAL\\strakalari",
    ]:
        cases.append(_case("entryName", _entry_name_win(raw), raw, True))
    for raw in [
        "/home/student/.config/strakalari",
        "/home/student/.config/strakalari/",
        "/home/student/.config/other/../strakalari/./",
        "/home/Student/.config/Strakalari",
    ]:
        cases.append(_case("entryName", _entry_name_posix(raw), raw, False))
    # Per-file writer snapshots (A-M4): Python writes config, cache,
    # history, sidecar, planned skips and presets through their real
    # writers; Dart seeds those bytes on disk, loads + rewrites each
    # file through its real reader/writer, and asserts the bytes match.
    import tempfile
    from strakalari.core import cache as _cache
    from strakalari.core import config as _config
    from strakalari.core import excuse_history as _eh
    from strakalari.core import planned_skips as _ps
    from strakalari.core import school_presets as _sp

    old_data_dir = os.environ.get("STRAKALARI_DATA_DIR")
    old_no_keyring = os.environ.get("STRAKALARI_NO_KEYRING")
    try:
        with tempfile.TemporaryDirectory() as tmp:
            os.environ["STRAKALARI_DATA_DIR"] = tmp
            os.environ["STRAKALARI_NO_KEYRING"] = "1"
            cfg_path = os.path.join(tmp, "config.json")
            cm = _config.ConfigManager(cfg_path)
            cm.set("language", "en")
            cm.set("bakalari_url", "https://bakalari.skola.cz")
            cm.set("bakalari_username", "jan.novak")
            cm.set("use_strava", False)
            cm.set("marks_percent_bands", [87.0, 72.0, 55.0, 40.0])
            cm.save()
            with open(cfg_path, "r", encoding="utf-8") as f:
                cfg_text = f.read()

            _cache.save_data_cache(
                {
                    "timetable": {
                        "01.09.2026": [{"hour": "1", "subject": "ČJ"}]
                    },
                    "absence": [],
                    "grades": {"ČJ": {"marks": [], "average": "1,50"}},
                    "strava_menu": {},
                    "strava_ordered": {"01.09.2026": "1"},
                    "last_updated": "01.09.2026 08:00:00",
                },
                replace=True,
            )
            with open(os.path.join(tmp, "data_cache.json"), "r",
                      encoding="utf-8") as f:
                cache_text = f.read()

            merged_hist, _ = _eh.merge_sent_excuses(
                [{"type": "pure days", "starting_day": "1.9.2026",
                  "ending_day": "02.09.2026"}],
                [{"type": "days and hours", "starting_day": "03.09.2026",
                  "ending_day": "03.09.2026", "starting_lesson": 2,
                  "ending_lesson": 4}],
            )
            hist_path = os.path.join(tmp, "already_excused_lessons.json")
            h.atomic_write_json(hist_path, merged_hist)
            with open(hist_path, "r", encoding="utf-8") as f:
                hist_text = f.read()

            from datetime import datetime as _dt
            sidecar_path = _eh.unconfirmed_path(hist_path)
            _eh.save_unconfirmed(
                hist_path,
                [_eh.unconfirmed_entry(
                    {"type": "pure days", "starting_day": "04.09.2026",
                     "ending_day": "04.09.2026"},
                    _dt(2026, 9, 4, 7, 30, 0),
                )],
            )
            with open(sidecar_path, "r", encoding="utf-8") as f:
                sidecar_text = f.read()

            skips = _ps.entries_for_selection(
                {_date(2026, 9, 7): [1, 2], _date(2026, 9, 8): [1, 2, 3]},
                {_date(2026, 9, 7): [1, 2, 3], _date(2026, 9, 8): [1, 2, 3]},
                template="Lékař",
                cancel_lunch=False,
            )
            skips_cfg_path = os.path.join(tmp, "skips_config.json")
            cm_skips = _config.ConfigManager(skips_cfg_path)
            cm_skips.set_and_save(
                "planned_skips",
                _ps.load_planned_skips({"planned_skips": skips}),
            )
            with open(skips_cfg_path, "r", encoding="utf-8") as f:
                skips_text = f.read()

            preset_data = dict(
                _sp.GEKOM_2026_2027,
                id="test_gekom",
                ranges=[list(r) for r in _sp.GEKOM_2026_2027["ranges"]],
                days=[list(d) for d in _sp.GEKOM_2026_2027["days"]],
            )
            preset_path = os.path.join(
                tmp, "school_presets", "test_gekom.json")
            h.atomic_write_json(preset_path, preset_data)
            with open(preset_path, "r", encoding="utf-8") as f:
                preset_text = f.read()

            cases.append(_case(
                "roundTripFiles",
                {
                    "config": cfg_text,
                    "cache": cache_text,
                    "history": hist_text,
                    "sidecar": sidecar_text,
                    "planned_skips": skips_text,
                    "presets": preset_text,
                },
            ))
    finally:
        if old_data_dir is None:
            os.environ.pop("STRAKALARI_DATA_DIR", None)
        else:
            os.environ["STRAKALARI_DATA_DIR"] = old_data_dir
        if old_no_keyring is None:
            os.environ.pop("STRAKALARI_NO_KEYRING", None)
        else:
            os.environ["STRAKALARI_NO_KEYRING"] = old_no_keyring
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
    # DST rows (spring switch 29.3.2026, autumn switch 25.10.2026).
    cases.append(_case("excuseWindowStart",
                       h.excuse_window_start(date(2026, 4, 15)),
                       date(2026, 4, 15), None))
    cases.append(_case("excuseWindowStart",
                       h.excuse_window_start(date(2026, 4, 15),
                                             date(2026, 3, 20)),
                       date(2026, 4, 15), date(2026, 3, 20)))
    oct_excuse = {"type": "pure days", "starting_day": "24.10.2026",
                  "ending_day": "26.10.2026"}
    oct_pending = [h.unconfirmed_entry(
        {"type": "pure days", "starting_day": "26.10.2026",
         "ending_day": "26.10.2026"}, datetime(2026, 10, 26, 12, 0))]
    cases.append(_case("unconfirmedBlocks",
                       h.unconfirmed_blocks(dict(oct_excuse),
                                            [dict(e) for e in oct_pending]),
                       dict(oct_excuse), [dict(e) for e in oct_pending]))
    cases.append(_case("excuseCovered",
                       h.excuse_covered(dict(oct_excuse), list(oct_pending)),
                       dict(oct_excuse), list(oct_pending)))
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
    from datetime import date as _date, datetime as _datetime

    from strakalari.core import bakalari_excuse as _e
    cases.append(_case("minutesText", _e._minutes_text(605), 605))
    cases.append(_case("minutesText", _e._minutes_text(60), 60))
    cases.append(_case("hourText",
                       _e._hour_text({"Caption": "3", "Begin": 605,
                                      "End": 650}),
                       {"Caption": "3", "Begin": 605, "End": 650}))
    cases.append(_case("hourText",
                       _e._hour_text({"Caption": "", "Begin": 480,
                                      "End": 525}),
                       {"Caption": "", "Begin": 480, "End": 525}))
    cases.append(_case("lesson",
                       _e._lesson([{"Caption": "3"}, {"Caption": "4"}], 3),
                       [{"Caption": "3"}, {"Caption": "4"}], 3))
    cases.append(_case("lesson",
                       _e._lesson([{"Caption": "3"}], 9),
                       [{"Caption": "3"}], 9))
    cases.append(_case("textToHtml", _e.text_to_html("a&b\nJan"),
                       "a&b\nJan"))
    cases.append(_case("textToHtml", _e.text_to_html(""), ""))
    cases.append(_case("jsDate", _e._js_date(_date(2026, 10, 1)),
                       _date(2026, 10, 1), False))
    cases.append(_case("jsDate",
                       _e._js_date(_datetime(2026, 10, 5, 22, 14, 30,
                                            123000)),
                       _datetime(2026, 10, 5, 22, 14, 30, 123000), True))
    cases.append(_case("dateState",
                       _e._date_state(_date(2026, 10, 1)),
                       _date(2026, 10, 1)))
    cases.append(_case("calendarState",
                       _e._calendar_state(_date(2026, 10, 1)),
                       _date(2026, 10, 1)))
    form = ('<html><head>'
            '<link rel="stylesheet" '
            'href="../App_Themes/NextBlueTheme/Basicstyl.css?v=1">'
            '<link rel="stylesheet" href="/DXR.axd?r=1_73,1_67-AbCd">'
            '<script src="/DXR.axd?r=1_11,1_12-AbCd"></script>'
            '</head><body><form id="formbaka" method="post">'
            '<input type="hidden" name="__VIEWSTATE" value="vs-1">'
            '<input type="hidden" name="cphmain_cmbRecipient_VI" '
            'value="U">'
            '<input type="text" name="ctl00$cphmain$cmbRecipient" '
            'value="Novák">'
            '<input type="submit" name="ctl00$cphmain$button_poslat" '
            'value="Odeslat">'
            '</form>'
            '<script>ASPx.createControl(ASPxClientHtmlEditor,'
            '\'cphmain_MessageEditor\',\'MessageEditor\','
            '{\'callBack\':function(arg) { },'
            '\'uniqueID\':\'ctl00$cphmain$MessageEditor\','
            '\'stateObject\':{\'cssFiles\':'
            '[\'../App_Themes/X/styles.css\'],'
            '\'clientState\':\'ActiveView|6|\'}});</script>'
            '</body></html>')
    cases.append(_case("pageResources", _e._page_resources(form), form))
    cases.append(_case("editorDefaults", _e._editor_defaults(form),
                       form))
    cases.append(_case("excusePostback",
                       _e.excuse_postback(
                           form, day_from=_date(2026, 10, 1),
                           day_to=_date(2026, 10, 2), whole_day=False,
                           hour_from={"Caption": "3", "Begin": 605,
                                      "End": 650},
                           hour_to={"Caption": "7", "Begin": 820,
                                    "End": 865},
                           text="Omluvte prosím absenci.",
                           now=_datetime(2026, 10, 5, 22, 14)),
                       form, _date(2026, 10, 1), _date(2026, 10, 2),
                       False,
                       {"Caption": "3", "Begin": 605, "End": 650},
                       {"Caption": "7", "Begin": 820, "End": 865},
                       "Omluvte prosím absenci.",
                       _datetime(2026, 10, 5, 22, 14)))
    return cases


def http_cases() -> list[dict]:
    from strakalari.core import bakalari_http as _s

    cases = []
    for url in ["bakaweb.example.test",
                "https://x.example.test/login",
                "https://x.example.test/bakaweb/next/komens.aspx", ""]:
        cases.append(_case("appRoot", _s.app_root(url), url))
    form_html = ('<form id="other"><input name="x" value="1"></form>'
                 '<form id="formbaka"><input name="a" value="1">'
                 '<input type="submit" name="s">'
                 '<input type="checkbox" name="c1">'
                 '<input type="checkbox" name="c2" checked>'
                 '<select name="sel"><option value="p">P</option>'
                 '<option value="q" selected>Q</option>'
                 '</select><textarea name="t">text</textarea></form>')
    cases.append(_case("formFields",
                       [list(pair) for pair in
                        _s.form_fields(form_html)],
                       form_html))
    cases.append(_case("dxEncodeHtml",
                       _s.dx_encode_html('a&b"c<d>e&amp;'),
                       'a&b"c<d>e&amp;'))
    cases.append(_case("dxState",
                       _s.dx_state({"a": 1, "b": "x"}),
                       {"a": 1, "b": "x"}))
    cases.append(_case("dxCallbackResult",
                       _s.dx_callback_result(
                           "1|/*DX*/({'id':0,'result':'a\\'b\\u0041'})"),
                       "1|/*DX*/({'id':0,'result':'a\\'b\\u0041'})"))
    return cases


def strava_cases() -> list[dict]:
    from strakalari.core.extractors import strava as _x
    from strakalari.core import strava_client as _c
    from strakalari.core import strava_ordering as _o

    cases = []
    cases.append(_case("cleanText",
                       _x.clean_text("<b>Guláš</b> &amp; knedlík<br>zítra"),
                       "<b>Guláš</b> &amp; knedlík<br>zítra"))
    cases.append(_case("cleanText", _x.clean_text("  a\t\nb  "),
                       "  a\t\nb  "))
    cases.append(_case("cleanText", _x.clean_text(""), ""))
    cases.append(_case("cleanText", _x.clean_text(None), None))
    reply = {"table1": [{"id": 1}], "other": [{"id": 2}],
             "table0": [{"id": 3}], "table2": [], "tableX": [{"id": 4}]}
    cases.append(_case("menuTables", _x.menu_tables(dict(reply)),
                       dict(reply)))
    cases.append(_case("menuTables", _x.menu_tables([]), []))
    cases.append(_case("isOrderableMeal",
                       _x.is_orderable_meal({"polevka": "A",
                                             "zkratkaProduktu": "x"}),
                       {"polevka": "A", "zkratkaProduktu": "x"}))
    cases.append(_case("isOrderableMeal",
                       _x.is_orderable_meal({"polevka": "N",
                                             "zkratkaProduktu": ""}),
                       {"polevka": "N", "zkratkaProduktu": ""}))
    cases.append(_case("isOrderableMeal",
                       _x.is_orderable_meal({"polevka": "N",
                                             "zkratkaProduktu": "zkratka"}),
                       {"polevka": "N", "zkratkaProduktu": "zkratka"}))
    cases.append(_case("mealText",
                       _x.meal_text({"druh_popis": "oběd 1",
                                     "nazev": "Guláš ",
                                     "alergeny": [["01", "Obiloviny"],
                                                  ["07", "Mléko"],
                                                  ["", "prázdné"],
                                                  "neplatné"]}),
                       {"druh_popis": "oběd 1", "nazev": "Guláš ",
                        "alergeny": [["01", "Obiloviny"],
                                     ["07", "Mléko"],
                                     ["", "prázdné"], "neplatné"]}))
    cases.append(_case("mealText",
                       _x.meal_text({"druh_popis": "polévka",
                                     "nazev": "Rajská", "alergeny": []}),
                       {"druh_popis": "polévka", "nazev": "Rajská",
                        "alergeny": []}))
    menu = {"table0": [{"datum": "07.09.2026", "druh": "P", "id": 0,
                        "pocet": 0, "polevka": "A", "zkratkaProduktu": "",
                        "druh_popis": "polévka", "nazev": "Rajská",
                        "alergeny": []},
                       {"datum": "07.09.2026", "druh": "1", "id": 1,
                        "pocet": 1, "polevka": "N",
                        "zkratkaProduktu": "zkratka",
                        "druh_popis": "oběd 1", "nazev": "Guláš",
                        "alergeny": [["01", "Obiloviny"]]}]}
    cases.append(_case("menuFromReply", _x.menu_from_reply(dict(menu)),
                       dict(menu)))
    cases.append(_case("menuFromReply", _x.menu_from_reply({}), {}))
    cases.append(_case("orderSheet",
                       _o.order_sheet([{"date": "2026-10-07", "druh": "2",
                                        "pocet": 1},
                                       {"date": "2026-10-07", "druh": "1",
                                        "pocet": 0},
                                       {"date": "2026-10-08", "druh": "3",
                                        "pocet": 0}]),
                       [{"date": "2026-10-07", "druh": "2", "pocet": 1},
                        {"date": "2026-10-07", "druh": "1", "pocet": 0},
                        {"date": "2026-10-08", "druh": "3", "pocet": 0}]))
    for url in ["strava.cz", "https://www.strava.cz/jidlo",
                "app.strava.cz", "", "kantyna.example.test:8080"]:
        cases.append(_case("apiRoot", _c.api_root(url), url))
    return cases


# -- phases 3-4 parity -------------------------------------------------------

def _slot_json(slot):
    from strakalari.core.schedule import SlotBaseline

    if isinstance(slot, SlotBaseline):
        return {"weekday": slot.weekday, "period": slot.period,
                "subject": slot.subject, "teacher": slot.teacher,
                "room": slot.room, "startMin": slot.start_min,
                "support": slot.support}
    if isinstance(slot, dict):
        return dict(slot)
    return None


def _slot_value_json(value):
    if isinstance(value, list):
        return [_slot_json(v) for v in value]
    return _slot_json(value)


def _diff_json(diff) -> dict:
    return {"isChange": diff.is_change, "changed": list(diff.changed),
            "note": diff.note}


def _change_json(item: dict) -> dict:
    return {"day_key": item.get("day_key"), "day": item.get("day"),
            "lesson": item.get("lesson"),
            "diff": _diff_json(item.get("diff"))}


def _state_json(state) -> dict:
    return {"name": state.name, "currentPct": state.current_pct,
            "limitPct": state.limit_pct, "weeklyHours": state.weekly_hours,
            "safeHoursLeft": state.safe_hours_left,
            "projectedPct": state.projected_pct, "warnPct": state.warn_pct,
            "planLimitPct": state.plan_limit_pct,
            "planSafeHoursLeft": state.plan_safe_hours_left,
            "approaching": state.approaching,
            "unclassifiable": state.unclassifiable,
            "taughtHours": state.taught_hours}


def _raw_json(raw):
    if raw is None:
        return None
    return {"kind": raw.kind, "value": raw.value}


def _mark_row_json(row) -> dict:
    return {"key": row.key, "mark": row.mark, "state": row.state,
            "value": row.value, "weight": row.weight,
            "raw": _raw_json(row.raw), "original": row.original,
            "date": row.date}


def _summary_json(summary) -> dict:
    return {"name": summary.name, "scale": summary.scale,
            "detected": summary.detected, "forced": summary.forced,
            "rows": [_mark_row_json(r) for r in summary.rows],
            "planned": summary.planned, "average": summary.average,
            "predicted": summary.predicted,
            "predicting": summary.predicting, "trend": summary.trend,
            "newCount": summary.new_count, "lastDate": summary.last_date,
            "history": [list(h) for h in summary.history]}


def _lesson_json(lesson) -> dict:
    return {"subject": lesson.subject, "day": lesson.day,
            "period": lesson.period, "time": lesson.time,
            "room": lesson.room, "teacher": lesson.teacher,
            "status": lesson.status, "change": lesson.change,
            "excused": lesson.excused}


def _option_json(option) -> dict:
    return {"day": option.day, "term": option.term,
            "lessons": list(option.lessons), "cost": dict(option.cost),
            "names": dict(option.names), "streak": option.streak,
            "finalWeek": option.final_week, "lateWeek": option.late_week,
            "feasible": option.feasible,
            "blockedBy": list(option.blocked_by), "score": option.score}


def _budget_json(budget) -> dict:
    return {"name": budget.name, "canon": budget.canon,
            "limitPct": budget.limit_pct, "reservePct": budget.reserve_pct,
            "currentPct": budget.current_pct, "taught": budget.taught,
            "missed": budget.missed, "future": budget.future,
            "planned": budget.planned, "blocked": budget.blocked,
            "weekly": budget.weekly, "peak": budget.peak}


def _planned_day_json(planned) -> dict:
    return {"entry": planned.entry,
            "days": {day: list(names)
                     for day, names in planned.days.items()},
            "cost": dict(planned.cost), "over": list(planned.over),
            "reserve": list(planned.reserve)}


def _term_json(term) -> dict:
    return {"key": term.key, "start": term.start, "close": term.close,
            "hasData": term.has_data, "active": term.active,
            "capacity": term.capacity, "target": term.target,
            "budgets": {canon: _budget_json(b)
                        for canon, b in
                        ((b.canon, b) for b in term.budgets)},
            "recommended": [_option_json(o) for o in term.recommended],
            "planned": [_planned_day_json(p) for p in term.planned]}


def _year_plan_json(plan) -> dict:
    default = plan.default_term
    return {"terms": [_term_json(t) for t in plan.terms],
            "today": plan.today, "firstDay": plan.first_day,
            "defaultTerm": default.key if default is not None else None}


def _alarm_json(alarm):
    if alarm is None:
        return None
    return {"day": alarm.day, "alarmDt": alarm.alarm_dt,
            "lessonStartDt": alarm.lesson_start_dt, "period": alarm.period,
            "subject": alarm.subject, "room": alarm.room,
            "minutesBefore": alarm.minutes_before}


def _status_json(content) -> dict:
    return {"title": content.title, "text": content.text,
            "sub": content.sub,
            "rows": [{"kind": r.kind, "label": r.label, "value": r.value,
                      "short": r.short} for r in content.rows]}


def _two_week_tt():
    def _fresh():
        return [{"subject": "M", "teacher": "Novák", "room": "U12",
                 "time": "1 (8:00 - 8:45)"},
                {"subject": "F", "teacher": "Dvořák", "room": "F11",
                 "time": "2 (8:55 - 9:40)"}]

    return {"07.09.2026": _fresh(), "14.09.2026": _fresh()}


def schedule_cases() -> list[dict]:
    import copy
    from datetime import date, datetime

    from strakalari.core import schedule as s

    cases = []
    for text in ["3 (10:05 - 10:50)", "1. 8:00 - 8:45", "8:00 - 8:45", "",
                 "nonsense"]:
        cases.append(_case("parseTimeRange", s.parse_time_range(text), text))
    clocked = {"subject": "M", "teacher": "T", "room": "U12",
               "time": "3 (10:05 - 10:50)"}
    cases.append(_case("lessonClock",
                       s.lesson_clock(dict(clocked), "07.09.2026"),
                       dict(clocked), "07.09.2026"))
    bare = {"subject": "M", "time": "bez čísla"}
    cases.append(_case("lessonClock",
                       s.lesson_clock(dict(bare), "07.09.2026"),
                       dict(bare), "07.09.2026"))
    cases.append(_case("periodOf", s._period_of({"hourIndex": 5},
                                               "07.09.2026"),
                       {"hourIndex": 5}, "07.09.2026"))
    cases.append(_case("periodOf", s._period_of(dict(clocked), "07.09.2026"),
                       dict(clocked), "07.09.2026"))
    day = [{"subject": "M", "time": "1 (8:00 - 8:45)"},
           {"subject": "F", "time": "2 (8:55 - 9:40)"}]
    morning = datetime(2026, 9, 7, 7, 30)
    running = datetime(2026, 9, 7, 8, 30)
    evening = datetime(2026, 9, 7, 18, 0)
    for now in (morning, running, evening):
        lessons = [dict(lesson) for lesson in day]
        cases.append(_case("resolveDayLessons",
                           s.resolve_day_lessons(lessons, now, "07.09.2026"),
                           lessons, now, "07.09.2026"))
    cases.append(_case("resolveDayLessons",
                       s.resolve_day_lessons([], morning, "07.09.2026"),
                       [], morning, "07.09.2026"))
    for now in (morning, evening):
        lessons = [dict(lesson) for lesson in day]
        cases.append(_case("futureLessons",
                           s.future_lessons(lessons, now, "07.09.2026"),
                           lessons, now, "07.09.2026"))
    tt = _two_week_tt()
    baseline = s.baseline_from_stable_timetable(tt)
    as_dict = s.baseline_to_dict(baseline)
    cases.append(_case("stableWeeklyHours", s.stable_weekly_hours(baseline),
                       as_dict))
    split = {"07.09.2026": [
        {"subject": "M", "teacher": "Novák", "room": "U12",
         "time": "1 (8:00 - 8:45)"},
        {"subject": "AJ", "teacher": "Bílá", "room": "J1",
         "time": "2 (8:55 - 9:40)", "group": "sk. 1"},
        {"subject": "NJ", "teacher": "Černý", "room": "J2",
         "time": "2 (8:55 - 9:40)", "group": "sk. 2"}]}
    split_base = s.baseline_from_stable_timetable(split)
    cases.append(_case("stableWeeklyHours",
                       s.stable_weekly_hours(split_base),
                       s.baseline_to_dict(split_base)))
    cases.append(_case("baselineToDict", as_dict, as_dict))
    cases.append(_case(
        "baselineFromDict",
        s.baseline_to_dict(s.baseline_from_dict(as_dict)), as_dict))
    week = s.stable_template_week(baseline, date(2026, 9, 7))
    cases.append(_case("stableTemplateWeek",
                       {day: lessons for day, lessons in week.items()},
                       as_dict, date(2026, 9, 7)))
    slot = baseline[(0, 2)]
    raw_ok = {"subject": "F", "teacher": "Dvořák", "room": "F11",
              "time": "2 (8:55 - 9:40)"}
    cases.append(_case(
        "closestVariant",
        _slot_value_json(s.closest_variant(slot, dict(raw_ok),
                                           "07.09.2026")),
        _slot_value_json(slot), dict(raw_ok), "07.09.2026"))
    cases.append(_case(
        "closestVariant",
        _slot_value_json(s.closest_variant(None, dict(raw_ok),
                                           "07.09.2026")),
        None, dict(raw_ok), "07.09.2026"))
    note_only = dict(raw_ok, notice="Písemka z minulé látky")
    cases.append(_case(
        "classifyLesson",
        _diff_json(s.classify_lesson(dict(note_only), "14.09.2026",
                                     baseline)),
        dict(note_only), "14.09.2026", as_dict))
    subst = dict(raw_ok, teacher="Král", notice="Suplování (Král)")
    cases.append(_case(
        "classifyLesson",
        _diff_json(s.classify_lesson(dict(subst), "14.09.2026", baseline)),
        dict(subst), "14.09.2026", as_dict))
    cancelled = {"subject": "M", "teacher": "Novák", "room": "U12",
                 "time": "1 (8:00 - 8:45)", "status": "cancelled"}
    cases.append(_case(
        "classifyLesson",
        _diff_json(s.classify_lesson(dict(cancelled), "07.09.2026",
                                     baseline)),
        dict(cancelled), "07.09.2026", as_dict))
    extra = {"subject": "X", "teacher": "T", "room": "R",
             "time": "7 (14:35 - 15:20)"}
    cases.append(_case(
        "classifyLesson",
        _diff_json(s.classify_lesson(dict(extra), "07.09.2026", baseline,
                                     True)),
        dict(extra), "07.09.2026", as_dict, True))
    tt_changed = _two_week_tt()
    tt_changed["14.09.2026"][1] = dict(subst)
    snapshot = copy.deepcopy(tt_changed)
    cases.append(_case(
        "iterChanges",
        [_change_json(item) for item in
         s.iter_changes(copy.deepcopy(tt_changed), baseline)],
        snapshot, as_dict))
    cases.append(_case(
        "iterNotes",
        [_change_json(item) for item in
         s.iter_notes(copy.deepcopy(tt_changed), baseline)],
        snapshot, as_dict))
    cases.append(_case(
        "iterChanges",
        [_change_json(item) for item in
         s.iter_changes(copy.deepcopy(tt_changed))],
        snapshot))
    tt_backfill = _two_week_tt()
    base_backfill = s.baseline_from_stable_timetable(
        {"07.09.2026": tt_backfill["07.09.2026"]})
    before_backfill = s.baseline_to_dict(base_backfill)
    tt_input = copy.deepcopy(tt_backfill)
    tt_input["07.09.2026"].append({"type": "removed", "subject": "?",
                                   "teacher": "", "room": "",
                                   "time": "2 (8:55 - 9:40)",
                                   "removedinfo": "Zrušeno"})
    tt_snapshot = copy.deepcopy(tt_input)
    stamped_backfill = s.backfill_stable_facts(tt_input, base_backfill)
    cases.append(_case("backfillStableFacts",
                       [stamped_backfill, tt_input,
                        s.baseline_to_dict(base_backfill)],
                       tt_snapshot, before_backfill))
    tt_feed = _two_week_tt()
    subs = [{"day": "14.09.2026", "period": 2, "badge": "S",
             "description": "Suplování (Král)"},
            {"day": "15.09.2026", "period": 1, "badge": "O",
             "description": "Odpadá", "subject_short": "M",
             "time": "1 (8:00 - 8:45)"}]
    tt_before = copy.deepcopy(tt_feed)
    stamped_feed = s.apply_substitution_feed(tt_feed, copy.deepcopy(subs))
    cases.append(_case("applySubstitutionFeed", [stamped_feed, tt_feed],
                       tt_before, subs))
    return cases


def matching_cases() -> list[dict]:
    from strakalari.core import matching as m

    cases = []
    for text in ["Příliš žluťoučký kůň", "ČESKÁ LÍPA", "", None]:
        cases.append(_case("stripDiacritics", m.strip_diacritics(text),
                           text))
    for text in ["  Vepřové  ", "Čočka", "RYBA"]:
        cases.append(_case("normalizeWord", m.normalize_word(text), text))
    for prefs in ["nemám rád vepřové, preferuji lehká jídla",
                  "mám rád kuřecí", "bez hub a česneku", "", None]:
        cases.append(_case("prefsBanKeywords", m.prefs_ban_keywords(prefs),
                           prefs))
    for food, banned in [
            ("Vepřové maso s knedlíkem", ["vepřové"]),
            ("Kuřecí řízek", ["vepřové"]),
            ("Rybí filé", ["ryb"]),
            ("Rybízový koláč", ["ryb"]),
            ("Guláš", ["YOUR_BLACKLIST_EXAMPLE"]),
            ("", ["vepřové"]),
            ("Svíčková", []),
            ("Čočková polévka", ["cocka"])]:
        cases.append(_case("isFoodBanned",
                           list(m.is_food_banned(food, banned)),
                           food, banned))
    return cases


def planned_skips_cases() -> list[dict]:
    from datetime import date

    from strakalari.core import planned_skips as p

    cases = []
    raws = [{"date": "2026-10-05", "template": "dentist"},
            {"start_date": "2026-10-05", "end_date": "2026-10-07",
             "start_period": 2, "end_period": 4, "template": "trip",
             "cancel_lunch": False},
            {"start_date": "2026-10-07", "end_date": "2026-10-05",
             "template": "swap"},
            {"start_date": "nonsense", "template": "bad"},
            None, "garbage", {}]
    for raw in raws:
        cases.append(_case(
            "normalizePlannedEntry",
            p.normalize_planned_entry(raw), raw))
    full = {"start_date": "2026-10-05", "end_date": "2026-10-07",
            "template": "trip"}
    keep = {"start_date": "2026-10-05", "end_date": "2026-10-05",
            "template": "x", "cancel_lunch": False}
    cases.append(_case("cancelsLunch", p.cancels_lunch(full), full))
    cases.append(_case("cancelsLunch", p.cancels_lunch(keep), keep))
    cases.append(_case("entryStartIso", p.entry_start_iso(full), full))
    cases.append(_case("entryEndIso", p.entry_end_iso(full), full))
    cases.append(_case("entryDays", p.entry_days(full), full))
    cases.append(_case("entryDays", p.entry_days(full, 2), full, 2))
    ranged = {"start_date": "2026-10-05", "end_date": "2026-10-06",
              "start_period": 2, "end_period": 4, "template": "t"}
    for day, period in [(date(2026, 10, 5), 1), (date(2026, 10, 5), 3),
                        (date(2026, 10, 6), 9), (date(2026, 10, 8), None)]:
        cases.append(_case("entryCovers",
                           p.entry_covers(dict(ranged), day, period),
                           dict(ranged), day, period))
    picked = {date(2026, 10, 5): [1, 2], date(2026, 10, 6): [1]}
    lessons = {date(2026, 10, 5): [1, 2, 3], date(2026, 10, 6): [1, 2]}
    cases.append(_case(
        "entriesForSelection",
        p.entries_for_selection(picked, lessons, template="ill",
                                cancel_lunch=True),
        dict(picked), {day: list(periods)
                       for day, periods in lessons.items()},
        "ill", True))
    cfg = {"planned_skips": [{"date": "2026-10-05", "template": "ill"},
                             {"start_date": "bad", "template": "x"},
                             "junk"]}
    cases.append(_case("loadPlannedSkips", p.load_planned_skips(cfg), cfg))
    lunch_cfg = {"planned_skips": [full, keep]}
    cases.append(_case("plannedLunchDays",
                       sorted(p.planned_lunch_days(lunch_cfg)), lunch_cfg))
    return cases


def forecast_cases() -> list[dict]:
    from datetime import date

    from strakalari.core import forecast as f
    from strakalari.core.schedule import baseline_from_stable_timetable
    from strakalari.core.schedule import baseline_to_dict

    cases = []
    holidays_in = ["25.12.2026", date(2026, 1, 1), "garbage", None]
    cases.append(_case(
        "normalizeHolidays",
        sorted(day.isoformat()
               for day in f.normalize_holidays(holidays_in)),
        holidays_in))
    table = {"01.09.2026": [{"subject": "Matematika"},
                            {"subject": "Matematika"}],
             "02.09.2026": [{"subject": "Fyzika"}]}
    cases.append(_case("weeklyHoursPerSubject",
                       f.weekly_hours_per_subject(table), table))
    big = {f"{day:02d}.09.2026": [{"subject": "Common"}]
           for day in range(1, 11)}
    big["01.09.2026"].append({"subject": "Rare"})
    cases.append(_case("weeklyHoursPerSubject",
                       f.weekly_hours_per_subject(big), big))
    free = [date(2026, 9, 8)]
    cases.append(_case(
        "schoolDaysBetween",
        f.school_days_between(date(2026, 9, 7), date(2026, 9, 13),
                              set(free)),
        date(2026, 9, 7), date(2026, 9, 13), free))
    for today in [date(2026, 9, 7), date(2027, 1, 15), date(2026, 3, 7)]:
        cases.append(_case("semesterBounds",
                           list(f.semester_bounds(today)), today))
    for name in ["Seminář z matematiky", "  FYZIKA ", None]:
        cases.append(_case("canonSubject", f.canon_subject(name), name))
    for args in [(10.0, 4, 50, 100, 30.0, None, 0.0, None),
                 (50.0, 4, 100, 150, 25.0, None, 0.0, 8.0),
                 (20.0, 5, 60, 120, 25.0, 22.0, 2.0, None)]:
        current, weekly, left, total, limit, warn, reserve, taught = args
        cases.append(_case(
            "forecastSubject",
            _state_json(f.forecast_subject(
                current, weekly, left, total, limit, warn_pct=warn,
                reserve_pct=reserve, taught_hours=taught)),
            *args))
    absence = {"Matematika": 20.0, "Zeměpis": 20.0}
    small = {"01.09.2026": [{"subject": "Matematika"},
                            {"subject": "Zeměpis"}]}
    states, days = f.forecast_all(dict(absence), dict(small),
                                  today=date(2026, 9, 7))
    cases.append(_case(
        "forecastAll",
        [[_state_json(state) for state in states], days],
        {"absence": dict(absence), "timetable": dict(small),
         "today": date(2026, 9, 7)}))
    states, days = f.forecast_all(
        dict(absence), dict(small), subject_limits={"matematika": 30.0},
        warn_pct=22.0, today=date(2026, 9, 7))
    cases.append(_case(
        "forecastAll",
        [[_state_json(state) for state in states], days],
        {"absence": dict(absence), "timetable": dict(small),
         "subjectLimits": {"matematika": 30.0}, "warnPct": 22.0,
         "today": date(2026, 9, 7)}))
    stable_live = baseline_from_stable_timetable(
        {"07.09.2026": [{"subject": "M", "teacher": "T", "room": "U12",
                         "time": "1 (8:00 - 8:45)"}]})
    stable_dict = baseline_to_dict(stable_live)
    absence_mixed = {"M": 10.0, "OneOff": 50.0}
    table_m = {"01.09.2026": [{"subject": "M"}],
               "08.09.2026": [{"subject": "M"}]}
    states, days = f.forecast_all(dict(absence_mixed), dict(table_m),
                                  stable_baseline=stable_live,
                                  today=date(2026, 9, 7))
    cases.append(_case(
        "forecastAll",
        [[_state_json(state) for state in states], days],
        {"absence": dict(absence_mixed), "timetable": dict(table_m),
         "stableBaseline": stable_dict, "today": date(2026, 9, 7)}))
    absence_home = {"Matematika": 10.0, "Třídnická hodina": 50.0}
    table_home = {"07.09.2026": [
        {"subject": "Matematika", "teacher": "T", "room": "R",
         "time": "1 (8:00 - 8:45)"},
        {"subject": "Třídnická hodina", "teacher": "T", "room": "R",
         "time": "2 (8:55 - 9:40)"}]}
    states, days = f.forecast_all(
        dict(absence_home), dict(table_home),
        tracked_subjects=["Matematika"], today=date(2026, 9, 7))
    cases.append(_case(
        "forecastAll",
        [[_state_json(state) for state in states], days],
        {"absence": dict(absence_home), "timetable": dict(table_home),
         "trackedSubjects": ["Matematika"], "today": date(2026, 9, 7)}))
    return cases


def grades_cases() -> list[dict]:
    from datetime import date

    from strakalari.core import grades as g

    cases = []
    for text in ["1", "1-", "5-", "2+", "85", "85 %", "72,5%", "17/20",
                 "0", "N", "?", "", "X", "3/0", None]:
        cases.append(_case("parseRaw", _raw_json(g.parse_raw(text)), text))
    cases.append(_case("parseRaw", _raw_json(g.parse_raw("", "9/10")),
                       "", "9/10"))
    for value in [None, "2,5", -3, 0, "abc", 2]:
        cases.append(_case("parseWeight", g.parse_weight(value), value))
    for mark in [{"Grade": "?"}, {"Grade": "1"},
                 {"Grade": "1", "Planned": True}, {}]:
        cases.append(_case("isPlanned", g.is_planned(mark), mark))
    for bands in [[90, 75, 50, 30], [90, 90, 50, 30], [90, 75, 50],
                  ["a", 75, 50, 30], "90,75,50,30", None]:
        cases.append(_case("bandsValid", g.bands_valid(bands), bands))
    for bands in [[95.0, 80.0, 60.0, 40.0], None, "junk"]:
        cases.append(_case("normalizeBands", list(g.normalize_bands(bands)),
                           bands))
    for pct, bands in [(90.1, None), (90, None), (29, None), (100, None),
                       (80.5, [95.0, 80.0, 60.0, 40.0]),
                       (87, [87.0, 72.0, 55.0, 40.0])]:
        if bands is None:
            cases.append(_case("pctToGrade", g.pct_to_grade(pct), pct))
        else:
            cases.append(_case("pctToGrade", g.pct_to_grade(pct, bands),
                               pct, bands))
    for grade, bands in [(1, None), (1.5, None),
                         (2, [87.0, 72.0, 55.0, 40.0])]:
        if bands is None:
            cases.append(_case("gradeToPct", g.grade_to_pct(grade), grade))
        else:
            cases.append(_case("gradeToPct", g.grade_to_pct(grade, bands),
                               grade, bands))
    for avg in [1.49, 1.5, 2.5, 5.9]:
        cases.append(_case("roundGrade", g.round_grade(avg), avg))
    for avg, scale in [(1.6, "grade"), (None, "grade"), (82.4, "percent"),
                       (None, "percent")]:
        cases.append(_case("finalGrade", g.final_grade(avg, scale),
                           avg, scale))
    for value, scale in [(82.4, "percent"), (1.5, "grade"), (None, "grade")]:
        cases.append(_case("gradeEquivalent",
                           g.grade_equivalent(value, scale), value, scale))
    for value, scale in [(1.0, "grade"), (3.0, "grade"), (5.0, "grade"),
                         (None, "grade"), (88.0, "percent")]:
        cases.append(_case("kindFor", g.kind_for(value, scale),
                           value, scale))
    for value, scale, digits in [(1.83333, "grade", None),
                                 (84.45, "percent", None),
                                 (84.0, "percent", 0), (None, "grade", None)]:
        cases.append(_case("formatValue",
                           g.format_value(value, scale, digits),
                           value, scale, digits))
    for value in [1.5, 2.0, 2.3]:
        cases.append(_case("formatGradeStep", g.format_grade_step(value),
                           value))
    for text, scale, has_pct in [("85", "percent", True),
                                 ("2", "percent", False),
                                 ("2", "grade", True)]:
        cases.append(_case("resolve",
                           g.resolve(g.parse_raw(text), scale, has_pct),
                           text, scale, has_pct))
    marks_scale = [{"Grade": "53"}, {"Grade": "100"}, {"Grade": "?"}]
    cases.append(_case("detectScale", g.detect_scale(marks_scale),
                       marks_scale))
    cases.append(_case("detectScale",
                       g.detect_scale([{"Grade": "1"}, {"Grade": "2-"}]),
                       [{"Grade": "1"}, {"Grade": "2-"}]))
    cases.append(_case("detectScale",
                       g.detect_scale([{"Grade": "N"}], "percent"),
                       [{"Grade": "N"}], "percent"))
    school_grades = {"M": [{"Grade": "1"}], "F": [{"Grade": "85"}]}
    cases.append(_case("detectSchoolScale",
                       g.detect_school_scale(school_grades), school_grades))
    cases.append(_case("weightedAverage",
                       g.weighted_average([[1.0, 1.0], [None, 2.0],
                                           [3.0, 0.0]]),
                       [[1.0, 1.0], [None, 2.0], [3.0, 0.0]]))
    cases.append(_case("weightedAverage", g.weighted_average([]), []))
    dup_marks = [{"Grade": "1", "Date": "1.9.2026"},
                 {"Grade": "1", "Date": "1.9.2026"},
                 {"Id": "7", "Grade": "2"}]
    cases.append(_case("markKeys", g.mark_keys(dup_marks), dup_marks))
    cases.append(_case("emptyPrediction", g.empty_prediction()))
    cases.append(_case("predictionActive",
                       g.prediction_active({"added": [{"Grade": "1"}]}),
                       {"added": [{"Grade": "1"}]}))
    cases.append(_case("predictionActive", g.prediction_active({}), {}))
    weighted = [{"Grade": "1", "Weight": 10, "Date": "05.09.2026"},
                {"Grade": "5", "Weight": 1, "Date": "10.09.2026"}]
    cases.append(_case(
        "summarize",
        _summary_json(g.summarize("M", [dict(m) for m in weighted],
                                  today=date(2026, 9, 13))),
        "M", [dict(m) for m in weighted],
        {"today": date(2026, 9, 13)}))
    pair = [{"Grade": "1"}, {"Grade": "2"}]
    cases.append(_case(
        "summarize",
        _summary_json(g.summarize("M", [dict(m) for m in pair],
                                  scale_pref="percent",
                                  today=date(2026, 9, 13))),
        "M", [dict(m) for m in pair],
        {"scalePref": "percent", "today": date(2026, 9, 13)}))
    percents = [{"Grade": "95"}, {"Grade": "60"}]
    cases.append(_case(
        "summarize",
        _summary_json(g.summarize("M", [dict(m) for m in percents],
                                  scale_pref="grade",
                                  today=date(2026, 9, 13))),
        "M", [dict(m) for m in percents],
        {"scalePref": "grade", "today": date(2026, 9, 13)}))
    what_if = [{"Grade": "1", "Weight": 1, "Date": "1.9.2026"},
               {"Grade": "3", "Weight": 1, "Date": "2.9.2026"}]
    ops = {"added": [{"Grade": "1", "Weight": 2}]}
    cases.append(_case(
        "summarize",
        _summary_json(g.summarize("M", [dict(m) for m in what_if], ops=ops,
                                  today=date(2026, 9, 13))),
        "M", [dict(m) for m in what_if],
        {"ops": ops, "today": date(2026, 9, 13)}))
    all_grades = {"M": [dict(m) for m in weighted],
                  "F": [{"Grade": "85"}, {"Grade": "60"}]}
    cases.append(_case(
        "summarizeAll",
        [_summary_json(summary) for summary in
         g.summarize_all({k: [dict(m) for m in v]
                          for k, v in all_grades.items()},
                         today=date(2026, 9, 13))],
        {k: [dict(m) for m in v] for k, v in all_grades.items()},
        {"today": date(2026, 9, 13)}))
    for text in ["100", "101", "21/20", "abc"]:
        cases.append(_case("validMarkText", g.valid_mark_text(text), text))
    summary_for_weight = g.summarize(
        "M", [dict(m) for m in weighted], today=date(2026, 9, 13))
    cases.append(_case("defaultWeight",
                       g.default_weight(summary_for_weight),
                       [dict(m) for m in weighted]))
    for weight in [1.0, 2.5]:
        cases.append(_case("formatWeight", g.format_weight(weight), weight))
    rows = g.summarize("M", [{"Grade": "1", "Weight": 1},
                             {"Grade": "3", "Weight": 1}],
                       today=date(2026, 9, 13)).rows
    needed = g.needed_for(rows, "grade", 2, 1.0)
    cases.append(_case(
        "neededFor",
        {"status": needed.status, "value": needed.value,
         "count": needed.count},
        [{"Grade": "1", "Weight": 1}, {"Grade": "3", "Weight": 1}],
        "grade", 2, 1.0))
    return cases


def planner_cases() -> list[dict]:
    from datetime import date

    from strakalari.core import planner as pl
    from strakalari.core.models import SubjectState
    from strakalari.core.schedule import baseline_to_dict

    cases = []
    cases.append(_case(
        "schoolYearTerms",
        [list(term) for term in pl.school_year_terms(
            date(2026, 10, 1), sem1_close="25.01.2027",
            sem2_close="26.04.2027")],
        date(2026, 10, 1),
        {"sem1Close": "25.01.2027", "sem2Close": "26.04.2027"}))
    cases.append(_case(
        "schoolYearTerms",
        [list(term) for term in pl.school_year_terms(date(2027, 2, 1))],
        date(2027, 2, 1), {}))
    fetched = {
        "31.08.2026": [
            {"subject": "M", "teacher": "T", "room": "R",
             "time": "1 (8:00 - 8:45)"},
            {"subject": "X", "teacher": "T", "room": "R",
             "time": "2 (8:55 - 9:40)"}],
        "14.09.2026": [
            {"subject": "M", "teacher": "T", "room": "R",
             "time": "1 (8:00 - 8:45)"},
            {"subject": "G", "teacher": "T", "room": "R",
             "time": "3 (10:05 - 10:50)", "notice": "Suplování"}]}
    # Dict-valued baseline (tuple slots): the input shape both the Python
    # and the Dart LessonSource accept. Live SlotBaseline values are also
    # accepted on both sides (Python via hasattr duck-typing, Dart via an
    # explicit SlotBaseline branch) but cannot travel through this JSON
    # oracle, so only the serialized form is pinned here.
    template_live = {(0, 1): {"weekday": 0, "period": 1, "subject": "M",
                              "teacher": "T", "room": "R",
                              "start_min": 480, "support": 1}}
    template_dict = baseline_to_dict(template_live)
    source = pl.LessonSource(fetched, dict(template_live))
    entry = {"start_date": "2026-09-14", "end_date": "2026-09-14",
             "template": "ill"}
    out = pl.entry_lessons(dict(entry), source, set(),
                           from_day=date(2026, 9, 1))
    cases.append(_case(
        "entryLessons",
        {day: [_lesson_json(lesson) for lesson in lessons]
         for day, lessons in out.items()},
        dict(entry),
        {"timetable": fetched, "baseline": template_dict,
         "holidays": [], "fromDay": date(2026, 9, 1)}))
    monday_only = {"start_date": "2026-09-21", "end_date": "2026-09-21",
                   "template": "ill"}
    out = pl.entry_lessons(dict(monday_only), source, set(),
                           from_day=date(2026, 9, 1))
    cases.append(_case(
        "entryLessons",
        {day: [_lesson_json(lesson) for lesson in lessons]
         for day, lessons in out.items()},
        dict(monday_only),
        {"timetable": fetched, "baseline": template_dict,
         "holidays": [], "fromDay": date(2026, 9, 1)}))
    options = [
        pl.DayOption(day=date(2026, 10, 5), term="sem1", lessons=["M"],
                     cost={"m": 1}, names={"m": "Matematika"}),
        pl.DayOption(day=date(2026, 10, 6), term="sem1", lessons=["M", "F"],
                     cost={"m": 1, "f": 1},
                     names={"m": "Matematika", "f": "Fyzika"}),
        pl.DayOption(day=date(2026, 10, 7), term="sem1", lessons=[])]
    span = [date(2026, 10, 5), date(2026, 10, 6), date(2026, 10, 7)]
    free = {"m": 3.0, "f": 2.0}
    picked = pl.spread_plan(list(options), dict(free), 1, list(span))
    cases.append(_case("spreadPlan",
                       [_option_json(option) for option in picked],
                       [_option_json(option) for option in options],
                       dict(free), 1, list(span)))
    states = [SubjectState(name="M", current_pct=20.0, limit_pct=25.0,
                           weekly_hours=5, taught_hours=15.0),
              SubjectState(name="F", current_pct=0.0, limit_pct=25.0,
                           weekly_hours=6, taught_hours=0.0)]
    year_table = {"07.09.2026": [{"subject": "M",
                                  "time": "1 (8:00 - 8:45)"}]}
    planned = [{"start_date": "2026-10-05", "end_date": "2026-10-05",
                "template": "ill"}]
    plan = pl.build_year_plan(
        list(states), timetable=dict(year_table),
        stable_baseline=template_live, holidays=[], planned=planned,
        today=date(2026, 9, 21), sem1_close="25.01.2027",
        sem2_close="30.06.2027", target_days=0)
    cases.append(_case(
        "buildYearPlan", _year_plan_json(plan),
        {"states": [_state_json(state) for state in states],
         "timetable": dict(year_table), "baseline": template_dict,
         "holidays": [], "planned": [dict(entry) for entry in planned],
         "today": date(2026, 9, 21), "sem1Close": "25.01.2027",
         "sem2Close": "30.06.2027", "targetDays": 0}))
    return cases


def school_presets_cases() -> list[dict]:
    import copy

    from strakalari.core import school_presets as sp

    cases = []
    valid = {"id": "x", "title_cs": "Demo"}
    cases.append(_case("validatePreset", sp.validate_preset(dict(valid)),
                       dict(valid)))
    invalid = {"id": 1, "sem1_close": "bad",
               "lunch_cutoff_time": "99:99",
               "marks_percent_bands": [90, 90, 50],
               "days": [["bad", "label"]],
               "ranges": ["nope"]}
    cases.append(_case("validatePreset", sp.validate_preset(dict(invalid)),
                       dict(invalid)))
    for data in [None, "junk"]:
        cases.append(_case("validatePreset", sp.validate_preset(data),
                           data))
    preset = {"id": "demo", "title_cs": "Demo škola",
              "title_en": "Demo school"}
    cases.append(_case("presetTitle", sp.preset_title(dict(preset), "cs"),
                       dict(preset), "cs"))
    cases.append(_case("presetTitle", sp.preset_title(dict(preset), "en"),
                       dict(preset), "en"))
    cases.append(_case("presetTitle", sp.preset_title({}, "cs"), {}, "cs"))
    entries = ["07.09.2026|zahájení", {"date": "08.09.2026", "label": "x"},
               "09.09.2026", "garbage"]
    cases.append(_case("expandEntries", sp.expand_entries(list(entries)),
                       list(entries)))
    for entry in ["07.09.2026|První den",
                  {"date": "08.09.2026", "label": "L"}, "09.09.2026",
                  "garbage", None]:
        cases.append(_case("splitEntry", list(sp._split_entry(entry)),
                           entry))
    for pid in ["gekom_2026_2027", "", "custom", None]:
        cases.append(_case("getPreset", sp.get_preset(pid), pid))
    for pid in ["gekom_2026_2027", ""]:
        cases.append(_case("presetDays", sp.preset_days(pid), pid))
        cases.append(_case("presetCloses", list(sp.preset_closes(pid)),
                           pid))
        cases.append(_case("presetLunchCutoff",
                           sp.preset_lunch_cutoff(pid), pid))
        bands = sp.preset_marks_bands(pid)
        cases.append(_case("presetMarksBands",
                           list(bands) if bands is not None else None,
                           pid))
    user_bands = {"marks_percent_bands": [88.0, 70.0, 50.0, 30.0]}
    bands, source = sp.resolve_marks_bands(dict(user_bands))
    cases.append(_case("resolveMarksBands", [list(bands), source],
                       dict(user_bands)))
    preset_cfg = {"school_preset_id": "gekom_2026_2027"}
    bands, source = sp.resolve_marks_bands(dict(preset_cfg))
    cases.append(_case("resolveMarksBands", [list(bands), source],
                       dict(preset_cfg)))
    bands, source = sp.resolve_marks_bands({})
    cases.append(_case("resolveMarksBands", [list(bands), source], {}))
    for cfg in [{"lunch_order_cutoff_time": "09:30"}, dict(preset_cfg), {}]:
        cases.append(_case("resolveLunchCutoff",
                           sp.resolve_lunch_cutoff(dict(cfg)), dict(cfg)))
    for which, cfg in [("sem1", {"sem1_close": "20.12.2026"}),
                       ("sem2", dict(preset_cfg)), ("sem1", {})]:
        cases.append(_case("resolveClose",
                           sp.resolve_close(which, dict(cfg)), which,
                           dict(cfg)))
    cal_cfg = {"user_free_days": ["22.12.2026|Xmas",
                                  {"date": "23.12.2026", "label": "X"}],
               "forced_school_days": ["07.09.2026"]}
    free_days, labels, info = sp.effective_calendar(dict(cal_cfg))
    cases.append(_case(
        "effectiveCalendar",
        [sorted(day.isoformat() for day in free_days),
         {day.isoformat(): label for day, label in labels.items()},
         info],
        dict(cal_cfg), True))
    free_days, labels, info = sp.effective_calendar(dict(preset_cfg))
    cases.append(_case(
        "effectiveCalendar",
        [sorted(day.isoformat() for day in free_days),
         {day.isoformat(): label for day, label in labels.items()},
         info],
        dict(preset_cfg), True))
    forced_cfg = {"school_preset_id": "",
                  "user_free_days": ["07.09.2026|day off"],
                  "forced_school_days": ["07.09.2026",
                                         "08.09.2026|orphan"]}
    before = copy.deepcopy(forced_cfg)
    changed = sp.prune_orphan_forced(forced_cfg)
    cases.append(_case("pruneOrphanForced", [changed, forced_cfg], before))
    return cases


def lunch_cutoff_cases() -> list[dict]:
    from datetime import date, datetime

    from strakalari.core import lunch_cutoff as lc

    cases = []
    for value in ["12:00", "9.30", "9:5", "25:00", "", None, "abc",
                  "08:00"]:
        cases.append(_case("parseCutoffTime",
                           list(lc.parse_cutoff_time(value)), value))
    for value in ["12:00", "9.30", "", None, "24:00", "9:5", "12:60",
                  "ab:cd"]:
        cases.append(_case("isValidCutoffTime",
                           lc.is_valid_cutoff_time(value), value))
    for value in ["9:5", "garbage", "", None, "23:59"]:
        cases.append(_case("normalizeCutoffTime",
                           lc.normalize_cutoff_time(value), value))
    free = [date(2026, 9, 7)]
    for day in [date(2026, 9, 7), date(2026, 9, 12), date(2026, 9, 13)]:
        cases.append(_case("isBusinessDay",
                           lc.is_business_day(day, list(free)), day,
                           list(free)))
    cases.append(_case("isBusinessDay",
                       lc.is_business_day(date(2026, 9, 7)),
                       date(2026, 9, 7)))
    cases.append(_case(
        "previousBusinessDay",
        lc.previous_business_day(date(2026, 9, 7), list(free)),
        date(2026, 9, 7), list(free)))
    cases.append(_case("previousBusinessDay",
                       lc.previous_business_day(date(2026, 9, 8)),
                       date(2026, 9, 8)))
    deadline = lc.lunch_order_deadline(date(2026, 10, 7), "12:00",
                                       list(free))
    cases.append(_case("lunchOrderDeadline",
                       deadline.strftime("%Y-%m-%dT%H:%M"),
                       date(2026, 10, 7), "12:00", list(free)))
    deadline = lc.lunch_order_deadline(date(2026, 9, 8), "09:30")
    cases.append(_case("lunchOrderDeadline",
                       deadline.strftime("%Y-%m-%dT%H:%M"),
                       date(2026, 9, 8), "09:30"))
    cases.append(_case(
        "isLunchOrderOpen",
        lc.is_lunch_order_open(date(2026, 10, 7),
                               datetime(2026, 10, 5, 11, 0), "12:00",
                               list(free)),
        date(2026, 10, 7), datetime(2026, 10, 5, 11, 0), "12:00",
        list(free)))
    cases.append(_case(
        "isLunchOrderOpen",
        lc.is_lunch_order_open(date(2026, 10, 7),
                               datetime(2026, 10, 6, 13, 0), "12:00",
                               list(free)),
        date(2026, 10, 7), datetime(2026, 10, 6, 13, 0), "12:00",
        list(free)))
    cases.append(_case(
        "isLunchOrderOpen",
        lc.is_lunch_order_open(date(2026, 9, 8), date(2026, 9, 4),
                               "09:30"),
        date(2026, 9, 8), date(2026, 9, 4), "09:30"))
    # DST rows (spring switch 29.3.2026, autumn switch 25.10.2026).
    cases.append(_case("previousBusinessDay",
                       lc.previous_business_day(date(2026, 3, 31)),
                       date(2026, 3, 31)))
    cases.append(_case("previousBusinessDay",
                       lc.previous_business_day(date(2026, 10, 26)),
                       date(2026, 10, 26)))
    deadline = lc.lunch_order_deadline(date(2026, 3, 31), "12:00")
    cases.append(_case("lunchOrderDeadline",
                       deadline.strftime("%Y-%m-%dT%H:%M"),
                       date(2026, 3, 31), "12:00"))
    deadline = lc.lunch_order_deadline(date(2026, 10, 27), "12:00")
    cases.append(_case("lunchOrderDeadline",
                       deadline.strftime("%Y-%m-%dT%H:%M"),
                       date(2026, 10, 27), "12:00"))
    return cases


def _lunch_menu():
    return {
        "28.09.2026": {"table0&1&101": "Vepřový guláš",
                       "table0&1&102": "Kuřecí řízek",
                       "table0&-1&0": "Odhlásit"},
        "29.09.2026": {"table0&1&201": "Smažený sýr",
                       "table0&-1&0": "Odhlásit"},
        "20.09.2026": {"table0&1&301": "Rajská polévka"},
        "01.10.2026": {"table0&1&401": "Vepřo knedlo",
                       "table0&-1&0": "Odhlásit"}}


def lunch_auto_cases() -> list[dict]:
    from datetime import date

    from strakalari.core import lunch_auto as la

    cases = []
    for value in [None, 0, 3, "7", 99, "garbage", -2, 2.5]:
        cases.append(_case("clampGeminiInterval",
                           la.clamp_gemini_interval(value), value))
    for value in [None, "", "2026-09-20", "2026-09-20T10:00:00",
                  "garbage", date(2026, 9, 20)]:
        cases.append(_case("parseLastRun", la.parse_last_run(value),
                           value))
    today = date(2026, 9, 25)
    for enabled, last, interval in [(False, None, 7), (True, None, 7),
                                    (True, "2026-09-20", 7),
                                    (True, "2026-09-24", 7),
                                    (True, "garbage", 7), ("", None, 7)]:
        cases.append(_case(
            "shouldRunGeminiAuto",
            la.should_run_gemini_auto(enabled, last, interval, today),
            enabled, last, interval, today))
    food = _lunch_menu()
    cases.append(_case(
        "filterPicks",
        la.filter_picks({day: dict(meals) for day, meals in food.items()},
                        blacklist=["vepřové"], today=today),
        {day: dict(meals) for day, meals in food.items()},
        {"blacklist": ["vepřové"], "today": today}))
    cases.append(_case(
        "filterPicks",
        la.filter_picks({day: dict(meals) for day, meals in food.items()},
                        blacklist=["vepřové"],
                        cancelled_days=["01.10.2026"], today=today),
        {day: dict(meals) for day, meals in food.items()},
        {"blacklist": ["vepřové"], "cancelledDays": ["01.10.2026"],
         "today": today}))
    gemini_orders = {"28.09.2026": "table0&1&101",
                     "29.09.2026": "table0&1&201"}
    cases.append(_case(
        "mergeGeminiWithFilter",
        la.merge_gemini_with_filter(
            dict(gemini_orders),
            {day: dict(meals) for day, meals in food.items()},
            blacklist=["vepřové"], today=today),
        dict(gemini_orders),
        {day: dict(meals) for day, meals in food.items()},
        {"blacklist": ["vepřové"], "today": today}))
    cases.append(_case(
        "updateHandledDays",
        la.update_handled_days(["20.09.2026", "01.09.2026"],
                               {"28.09.2026": "table0&1&102",
                                "29.09.2026": "table0&-1&0"},
                               ["29.09.2026"], today),
        ["20.09.2026", "01.09.2026"],
        {"28.09.2026": "table0&1&102", "29.09.2026": "table0&-1&0"},
        ["29.09.2026"], today))
    # DST rows (spring switch 29.3.2026, autumn switch 25.10.2026).
    cases.append(_case(
        "shouldRunGeminiAuto",
        la.should_run_gemini_auto(True, "2026-03-29", 1,
                                  date(2026, 3, 30)),
        True, "2026-03-29", 1, date(2026, 3, 30)))
    cases.append(_case(
        "shouldRunGeminiAuto",
        la.should_run_gemini_auto(True, "2026-10-24", 2,
                                  date(2026, 10, 26)),
        True, "2026-10-24", 2, date(2026, 10, 26)))
    oct_today = date(2026, 10, 28)
    cases.append(_case(
        "updateHandledDays",
        la.update_handled_days(["20.10.2026", "01.10.2026"],
                               {"27.10.2026": "table0&1&102",
                                "28.10.2026": "table0&-1&0"},
                               ["28.10.2026"], oct_today),
        ["20.10.2026", "01.10.2026"],
        {"27.10.2026": "table0&1&102", "28.10.2026": "table0&-1&0"},
        ["28.10.2026"], oct_today))
    return cases


def gemini_cases() -> list[dict]:
    from strakalari.core import gemini as gm

    cases = []
    food = {"07.09.2026": {"table0&1&101": "Kuřecí řízek s bramborem",
                           "table0&1&102": "Smažený sýr s hranolky",
                           "table0&-1&0": "Odhlásit oběd"},
            "08.09.2026": {"table0&1&201": "Hovězí guláš"}}
    block = gm.build_menu_block(food)
    cases.append(_case("buildMenuBlock", block, food))
    cases.append(_case("buildPrompt",
                       gm.build_prompt("no pork", block, "en"),
                       "no pork", block, "en"))
    cases.append(_case("buildPrompt",
                       gm.build_prompt("bez vepřového", block, "cs"),
                       "bez vepřového", block, "cs"))
    reply = ("Nejlepší volba:\n"
             '```json {"07.09.2026": "table0&1&101"}```')
    clean, recommended = gm.parse_recommendation_response(reply)
    cases.append(_case("parseRecommendationResponse", [clean, recommended],
                       reply))
    cases.append(_case("parseRecommendationResponse",
                       list(gm.parse_recommendation_response(
                           "no json here")),
                       "no json here"))
    tagged = ('<script>alert(1)</script>'
              '```json {"08.09.2026": "table0&1&201"}```')
    cases.append(_case("parseRecommendationResponse",
                       list(gm.parse_recommendation_response(tagged)),
                       tagged))
    recommended = {"07.09.2026": "table0&1&101",
                   "08.09.2026": "table0&9&999"}
    cases.append(_case(
        "validateRecommendation",
        gm.validate_recommendation(dict(recommended), food),
        dict(recommended), food))
    html, orders = gm.local_fallback_recommendation(food, "maso protein",
                                                    "cs")
    cases.append(_case("localFallbackRecommendation", [html, orders],
                       food, "maso protein", "cs"))
    html, orders = gm.local_fallback_recommendation(food,
                                                    "bez vepřového", "cs")
    cases.append(_case("localFallbackRecommendation", [html, orders],
                       food, "bez vepřového", "cs"))
    return cases


def _news_fixtures():
    past = "29.9.2099 (úterý)"
    future = "5.10.2099 (pondělí)"

    def _lesson(period, subject="M", extra=None):
        row = {"subject": subject, "time": f"{period} (8:00 - 8:45)"}
        row.update(extra or {})
        return row

    old_grades = {"grades": {"M": [{"Id": "1", "Grade": "2",
                                   "Date": "1.9.2099"}]}}
    fresh_grades = {"grades": {"M": [{"Id": "1", "Grade": "2",
                                      "Date": "1.9.2099"},
                                     {"Id": "2", "Grade": "1",
                                      "Date": "2.9.2099",
                                      "Caption": "Test"}],
                               "F": [{"Grade": "3",
                                      "Date": "2.9.2099"}]}}
    old_tt = {"timetable": {past: [_lesson(1),
                                   _lesson(2, "M",
                                           {"absenceType": "Absent"})]}}
    fresh_tt = {"timetable": {
        past: [_lesson(1, "M", {"absenceType": "Absent"}),
               _lesson(2, "M", {"absenceType": "Excused",
                                "absencetext": "Omluveno"})],
        "1.9.2099": [_lesson(1, "M", {"absenceType": "Absent"})]}}
    old_change = {"timetable": {past: [_lesson(1)],
                                future: [_lesson(1), _lesson(2)]}}
    fresh_change = {"timetable": {
        past: [_lesson(1, "M", {"infoChangeCode": "Removed",
                                "type": "removed"})],
        future: [_lesson(1),
                 _lesson(2, "M", {"infoChangeCode": "Removed",
                                  "type": "removed"})]}}
    return old_grades, fresh_grades, old_tt, fresh_tt, old_change, \
        fresh_change, future


def news_cases() -> list[dict]:
    from datetime import date

    from strakalari.core import news as n

    cases = []
    old_grades, fresh_grades, old_tt, fresh_tt, old_change, \
        fresh_change, future = _news_fixtures()
    today = date(2099, 10, 1)
    cases.append(_case("newMarks",
                       n.new_marks(old_grades, fresh_grades),
                       old_grades, fresh_grades))
    cases.append(_case("newMarks", n.new_marks(fresh_grades, fresh_grades),
                       fresh_grades, fresh_grades))
    quarterly_old = {"quarterly_marks": {"M": {"Grade": "2"},
                                         "F": {"Grade": "1"}}}
    quarterly_fresh = {"quarterly_marks": {"M": {"Grade": "1"},
                                           "F": {"Grade": "1"},
                                           "D": {"Grade": "3"}}}
    cases.append(_case("newQuarterlyMarks",
                       n.new_quarterly_marks(quarterly_old,
                                             quarterly_fresh),
                       quarterly_old, quarterly_fresh))
    cases.append(_case("newAbsences", n.new_absences(old_tt, fresh_tt),
                       old_tt, fresh_tt))
    cases.append(_case("newChanges",
                       n.new_changes(old_change, fresh_change, today),
                       old_change, fresh_change, today))
    old_all = {"grades": {}, "timetable": {future: [
        {"subject": "M", "time": "1 (8:00 - 8:45)"}]}}
    marks = [{"Id": str(i), "Grade": "1"} for i in range(6)]
    fresh_all = {"grades": {"M": marks},
                 "timetable": {future: [
                     {"subject": "M", "time": "1 (8:00 - 8:45)",
                      "infoChangeCode": "Removed", "type": "removed"}]}}
    cases.append(_case("findNews",
                       [list(item) for item in
                        n.find_news(old_all, fresh_all, today)],
                       old_all, fresh_all, today))
    quarterly_news = n.find_news({"quarterly_marks": {}},
                                 {"quarterly_marks":
                                  {"M": {"Grade": "1"}}}, today)
    cases.append(_case("findNews",
                       [list(item) for item in quarterly_news],
                       {"quarterly_marks": {}},
                       {"quarterly_marks": {"M": {"Grade": "1"}}},
                       today))
    return cases


def update_cases() -> list[dict]:
    from strakalari.core import update as u

    cases = []
    for value in ["stable", "BETA", " beta ", "nightly", "", None, 5]:
        cases.append(_case("normalizeChannel", u.normalize_channel(value),
                           value))
    for text in ["v1.2.3", "1.2", "v0.1.0-beta.1", "abc", "",
                 "  v2.0.0-rc.1+build "]:
        cases.append(_case("parseVersion", list(u.parse_version(text)),
                           text))
    for text in ["v0.1.0-beta.1+abc", "1.2.3", "v1.0"]:
        core, pre = u._split_version(text)
        cases.append(_case("splitVersion", [list(core), pre], text))
    for text in ["1.2.3", "1.2.3-beta.1", "1.2.3-rc.1"]:
        cases.append(_case("isPrereleaseVersion",
                           u.is_prerelease_version(text), text))
    for text in ["0.1.0-beta.1", "0.1.0-beta.2", "0.1.0", "0.1.1", "1.2",
                 "1.2.0"]:
        key = u.version_key(text)
        cases.append(_case("versionKey",
                           [list(key[0]), key[1],
                            [list(part) for part in key[2]]],
                           text))
    for latest, current in [("1.3.0", "1.2.0"), ("1.2.0", "1.2.0"),
                            ("1.2.0-beta.1", "1.2.0"),
                            ("1.2.0", "1.2.0-beta.1"),
                            ("0.9.9", "1.0.0")]:
        cases.append(_case("isNewer", u.is_newer(latest, current),
                           latest, current))
    stable = {"tag_name": "v1.2.0",
              "html_url": "https://example.test/r/v1.2.0",
              "name": "Release 1.2.0",
              "published_at": "2026-09-01T10:00:00Z",
              "prerelease": False, "draft": False}
    beta = {"tag_name": "v1.3.0-beta.1", "prerelease": True,
            "draft": False}
    draft = {"tag_name": "v1.1.0", "draft": True}
    for payload in [stable, beta, draft, {"no_tag": True}, {}]:
        cases.append(_case("releaseInfo", u._release_info(dict(payload)),
                           dict(payload)))
    releases = [dict(stable), dict(beta), dict(draft)]
    cases.append(_case("pickRelease", u.pick_release(
        [dict(item) for item in releases], "stable"),
        [dict(item) for item in releases], "stable"))
    cases.append(_case("pickRelease", u.pick_release(
        [dict(item) for item in releases], "beta"),
        [dict(item) for item in releases], "beta"))
    cases.append(_case("pickRelease", u.pick_release([], "stable"), [],
                       "stable"))
    now_epoch = 1780000000.0
    cases.append(_case("shouldCheck", u.should_check(None, now_epoch),
                       None, now_epoch))
    fresh = {"checked_at": now_epoch - 3600}
    cases.append(_case("shouldCheck",
                       u.should_check(dict(fresh), now_epoch),
                       dict(fresh), now_epoch))
    stale = {"checked_at": now_epoch - 90000}
    cases.append(_case("shouldCheck",
                       u.should_check(dict(stale), now_epoch),
                       dict(stale), now_epoch))
    broken = {"checked_at": "garbage"}
    cases.append(_case("shouldCheck",
                       u.should_check(dict(broken), now_epoch),
                       dict(broken), now_epoch))
    info = {"version": "9.9.9", "tag": "v9.9.9"}
    cases.append(_case("updateAvailable",
                       u.update_available(dict(info), "1.0.0"),
                       dict(info), "1.0.0"))
    cases.append(_case("updateAvailable",
                       u.update_available(dict(info), "9.9.9"),
                       dict(info), "9.9.9"))
    cases.append(_case("updateAvailable", u.update_available(None, "1.0.0"),
                       None, "1.0.0"))
    return cases


def status_notification_cases() -> list[dict]:
    from datetime import date, datetime

    from strakalari.core import status_notification as sn

    cases = []
    picked = {"background_notification_items": ["lunch", "bogus",
                                                "excuses"]}
    cases.append(_case("selectedItems",
                       sn.selected_items(dict(picked)), dict(picked)))
    cases.append(_case("selectedItems", sn.selected_items({}), {}))
    cases.append(_case(
        "selectedItems",
        sn.selected_items({"background_notification_items": "nope"}),
        {"background_notification_items": "nope"}))
    cases.append(_case("selectedItems", sn.selected_items(None), None))
    base = {"background_notification_items": ["lunch", "excuses"]}
    cases.append(_case("withItem",
                       sn.with_item(dict(base), "wakeup", True),
                       dict(base), "wakeup", True))
    cases.append(_case("withItem",
                       sn.with_item(dict(base), "lunch", False),
                       dict(base), "lunch", False))
    for name in ["", "Guláš", "oběd 1 - Polévka,Řízek(01, 07 )",
                 None, 0]:
        cases.append(_case("mealText", sn.meal_text(name), name))
    monday = [{"subject": "M", "time": "1 (8:00 - 8:45)"},
              {"subject": "M", "time": "2 (8:55 - 9:40)"},
              {"subject": "F", "time": "3 (10:05 - 10:50)"},
              {"subject": "F", "time": "4 (10:55 - 11:40)"},
              {"subject": "X", "time": "6 (12:45 - 13:30)"}]
    timetable = {"09.11.2026": [dict(lesson) for lesson in monday],
                 "10.11.2026": [dict(lesson) for lesson in monday]}
    inputs = sn.StatusInputs(timetable=timetable, config={},
                             free_days=frozenset())
    cases.append(_case(
        "lunchOverAt", sn.lunch_over_at(inputs, date(2026, 11, 9)),
        {"timetable": timetable, "freeDays": []}, date(2026, 11, 9)))
    now = datetime(2026, 11, 9, 7, 0)
    food = {"09.11.2026": {"table0&1&0": "Guláš"}}
    web = {"09.11.2026": "table0&1&0"}
    cfg = {"background_notification_items": ["next_lesson", "lunch",
                                            "lunch_orders", "excuses"],
           "use_strava": True}
    full = sn.StatusInputs(
        timetable={day: [dict(lesson) for lesson in lessons]
                   for day, lessons in timetable.items()},
        food={day: dict(meals) for day, meals in food.items()},
        web_orders=dict(web), config=dict(cfg), free_days=frozenset(),
        pending_excuses=2, last_updated=datetime(2026, 11, 9, 6, 40))
    cases.append(_case(
        "buildStatus", _status_json(sn.build_status(full, now, lang="cs")),
        {"timetable": timetable, "food": food, "webOrders": web,
         "config": cfg, "freeDays": [],
         "pendingExcuses": 2,
         "lastUpdated": datetime(2026, 11, 9, 6, 40)},
        now, {"lang": "cs"}))
    empty = sn.StatusInputs(config={"background_notification_items": []},
                            free_days=frozenset())
    cases.append(_case(
        "buildStatus",
        _status_json(sn.build_status(empty, now, lang="en")),
        {"config": {"background_notification_items": []}, "freeDays": []},
        now, {"lang": "en"}))
    fallback_cfg = {"background_notification_items": []}
    cases.append(_case(
        "buildStatus",
        _status_json(sn.build_status(
            sn.StatusInputs(config=dict(fallback_cfg),
                            free_days=frozenset()),
            now, fallback=("Běží", "Každých 30 min"), lang="cs")),
        {"config": dict(fallback_cfg), "freeDays": []},
        now, {"lang": "cs", "fallback": ["Běží", "Každých 30 min"]}))
    return cases


def wakeup_cases() -> list[dict]:
    from datetime import date, datetime

    from strakalari.core import wakeup as w

    cases = []
    for value in [None, 30, "45", "abc", 0, 9999, "60,5"]:
        cases.append(_case("clampWakeupMinutes",
                           w.clamp_wakeup_minutes(value), value))
    cfg = {"wakeup_skip_dates": ["2026-11-10", "garbage", "2026-10-01"]}
    cases.append(_case("skippedDays",
                       sorted(day.isoformat()
                              for day in w.skipped_days(cfg)),
                       cfg))
    today = date(2026, 11, 1)
    cases.append(_case(
        "withSkippedDay",
        w.with_skipped_day(dict(cfg), date(2026, 11, 11), True, today),
        dict(cfg), date(2026, 11, 11), True, today))
    cases.append(_case(
        "withSkippedDay",
        w.with_skipped_day(dict(cfg), date(2026, 10, 1), False, today),
        dict(cfg), date(2026, 10, 1), False, today))
    raw = {"subject": "M", "time": "1 (8:00 - 8:45)"}
    cases.append(_case("periodOf", w._period_of(dict(raw), "09.11.2026"),
                       dict(raw), "09.11.2026"))
    cancelled = dict(raw, status="cancelled")
    cases.append(_case("isCancelledLesson",
                       w._cancelled(dict(cancelled), "09.11.2026"),
                       dict(cancelled), "09.11.2026"))
    cases.append(_case("isCancelledLesson",
                       w._cancelled(dict(raw), "09.11.2026"),
                       dict(raw), "09.11.2026"))
    table = {"09.11.2026": [dict(raw),
                            {"subject": "F",
                             "time": "2 (8:55 - 9:40)"}],
             "10.11.2026": []}
    indexed = w._index_days(table)
    cases.append(_case(
        "indexDays",
        {day.isoformat(): lessons for day, lessons in indexed.items()},
        table))
    planned = [{"start_date": "2026-11-09", "end_date": "2026-11-09",
                "template": "t"}]
    cases.append(_case("plannedOff",
                       w._planned_off(date(2026, 11, 9), 1, planned),
                       date(2026, 11, 9), 1, planned))
    cases.append(_case("plannedOff",
                       w._planned_off(date(2026, 11, 10), 1, planned),
                       date(2026, 11, 10), 1, planned))
    alarm = w.WakeupAlarm(day=date(2026, 11, 9),
                          alarm_dt=datetime(2026, 11, 9, 7, 30),
                          lesson_start_dt=datetime(2026, 11, 9, 8, 0),
                          period=1, subject="M", room="U12",
                          minutes_before=30)
    alarm_free = w.WakeupAlarm(day=date(2026, 11, 10),
                               alarm_dt=datetime(2026, 11, 10, 9, 0),
                               lesson_start_dt=datetime(
                                   2026, 11, 10, 9, 30),
                               period=None, subject="", room="",
                               minutes_before=45)
    cases.append(_case(
        "clockAppWeekday",
        w.clock_app_weekday(alarm, datetime(2026, 11, 8, 12, 0)),
        _alarm_json(alarm), datetime(2026, 11, 8, 12, 0)))
    cases.append(_case(
        "alarmQueue", w.alarm_queue([alarm, alarm_free], "cs"),
        [_alarm_json(alarm), _alarm_json(alarm_free)], "cs"))
    cases.append(_case("alarmQueue", w.alarm_queue([alarm], "en"),
                       [_alarm_json(alarm)], "en"))
    wake_cfg = {"wakeup_enabled": True, "wakeup_minutes_before": 30}
    now = datetime(2026, 11, 8, 20, 0)
    wake_args = {"timetable": table, "config": dict(wake_cfg), "now": now}
    cases.append(_case(
        "upcomingWakeupAlarms",
        [_alarm_json(item) for item in
         w.upcoming_wakeup_alarms(dict(table), dict(wake_cfg), now=now)],
        dict(wake_args)))
    skip_cfg = dict(wake_cfg, wakeup_skip_dates=["2026-11-09"])
    cases.append(_case(
        "upcomingSkippedDays",
        [[day.isoformat(), _alarm_json(item)] for day, item in
         w.upcoming_skipped_days(dict(table), dict(skip_cfg), now=now)],
        {"timetable": table, "config": dict(skip_cfg), "now": now}))
    cases.append(_case(
        "nextWakeupAlarm",
        _alarm_json(w.next_wakeup_alarm(dict(table), dict(wake_cfg),
                                        now=now)),
        dict(wake_args)))
    rows = w.build_widget_day_rows([dict(raw),
                                    {"subject": "F",
                                     "time": "2 (8:55 - 9:40)"}],
                                   date(2026, 11, 9), lang="cs")
    cases.append(_case(
        "buildWidgetDayRows", rows,
        [dict(raw), {"subject": "F", "time": "2 (8:55 - 9:40)"}],
        date(2026, 11, 9), {"lang": "cs"}))
    payload = w.build_widget_payload(dict(table), dict(wake_cfg), now=now,
                                     lang="cs")
    cases.append(_case("buildWidgetPayload", payload, dict(wake_args),
                       {"lang": "cs"}))
    return cases


def error_report_cases() -> list[dict]:
    from strakalari.core import error_report as er

    cases = []
    cases.append(_case("timeoutUserMessage", er.timeout_user_message()))
    tagged = {"none": None,
              "timeout-builtin": TimeoutError("timed out"),
              "timeout-msg": ValueError("Timeout 30000ms exceeded"),
              "user": er.UserError("missing url"),
              "other": ValueError("boom")}
    for tag, exc in tagged.items():
        cases.append(_case("isTimeoutError", er.is_timeout_error(exc),
                           tag))
    cfg = {"bakalari_username": "novak", "bakalari_password": "secret123",
           "strava_username": "", "plain": "x", "wakeup_enabled": True}
    cases.append(_case("redactConfig", er.redact_config(dict(cfg)),
                       dict(cfg)))
    cases.append(_case("secretValues", sorted(er.secret_values(cfg)),
                       dict(cfg)))
    cases.append(_case(
        "redactValues",
        er.redact_values("login novak with secret123",
                         {"secret123", "novak"}),
        "login novak with secret123", ["secret123", "novak"]))
    cases.append(_case(
        "redactText",
        er.redact_text("login novak with secret123", dict(cfg)),
        "login novak with secret123", dict(cfg)))
    cases.append(_case("shortSummary",
                       er.short_summary(None, "something broke"),
                       None, "something broke"))
    cases.append(_case("shortSummary",
                       er.short_summary(None, "line one\nline two", 4),
                       None, "line one\nline two", 4))
    report = {"at": "09.11.2026 07:00:00", "operation": "refresh",
              "summary": "boom", "traceback": "Traceback X",
              "log_tail": ["a", "b"], "config": {"u": "set"},
              "context": {"os": "windows"}, "extra": {"k": "v"},
              "user_message": ""}
    cases.append(_case("formatReport", er.format_report(dict(report)),
                       dict(report)))
    cases.append(_case("formatReport", er.format_report(None), None))
    return cases


def scheduler_cases() -> list[dict]:
    from datetime import datetime

    from strakalari.core import scheduler as sch

    cases = []
    now = datetime(2026, 9, 25, 12, 0)
    cases.append(_case("nextDue", sch.next_due(None, 60, now),
                       None, 60, now))
    cases.append(_case(
        "nextDue",
        sch.next_due(datetime(2026, 9, 25, 11, 0), 30, now),
        datetime(2026, 9, 25, 11, 0), 30, now))
    cases.append(_case(
        "nextDue",
        sch.next_due(datetime(2026, 9, 25, 11, 0), None, now),
        datetime(2026, 9, 25, 11, 0), None, now))
    cases.append(_case(
        "nextDue",
        sch.next_due(datetime(2026, 9, 25, 11, 0), 0, now),
        datetime(2026, 9, 25, 11, 0), 0, now))
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
    _dump("http", http_cases())
    _dump("strava", strava_cases())
    _dump("schedule", schedule_cases())
    _dump("matching", matching_cases())
    _dump("planned_skips", planned_skips_cases())
    _dump("forecast", forecast_cases())
    _dump("grades", grades_cases())
    _dump("planner", planner_cases())
    _dump("school_presets", school_presets_cases())
    _dump("lunch_cutoff", lunch_cutoff_cases())
    _dump("lunch_auto", lunch_auto_cases())
    _dump("gemini", gemini_cases())
    _dump("news", news_cases())
    _dump("update", update_cases())
    _dump("status_notification", status_notification_cases())
    _dump("wakeup", wakeup_cases())
    _dump("error_report", error_report_cases())
    _dump("scheduler", scheduler_cases())


if __name__ == "__main__":
    main()
