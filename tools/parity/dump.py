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
        cases.append(_case("parseDate", h.parse_date(text).isoformat(), text))
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
        result = m.parse_cz_date(text)
        cases.append(_case("parseCzDate",
                           result.isoformat() if result else None, text))
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
        "room": lesson.room,
        "day": lesson.day.isoformat() if lesson.day else None,
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


def main() -> None:
    _dump("helpers", helpers_cases())
    _dump("models", models_cases())
    _dump("i18n", i18n_cases())


if __name__ == "__main__":
    main()
