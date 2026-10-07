"""Parsers for what the Bakaláři web returns (see docs/BAKALARI_API.md).

The grades page is a WebForms page whose marks sit in ``data-clasif``
attributes; everything else comes from the pages' own JSON endpoints.
"""

import html
import json
import re


def _zero_pad_day(date_str: str) -> str:
    """Normalizes ``D.M.YYYY`` to zero-padded ``DD.MM.YYYY``.

    Tolerates surrounding whitespace and trailing dots (the web renders
    e.g. ``"24. 9. 2026."``); raises ValueError when unparseable (the
    caller treats that as "no entry", never a crash).
    """
    parts = [p.strip() for p in str(date_str).strip().rstrip(".").split(".")]
    parts = [p for p in parts if p]
    if len(parts) != 3:
        raise ValueError(f"Unparseable date: {date_str!r}")
    day, month, year = parts
    return f"{day.zfill(2)}.{month.zfill(2)}.{year}"


_GRADES_RE = re.compile(
    r'data-clasif\s*=\s*(["\'])(\{[^}]*?MarkText[^}]*?\})\1',
    re.DOTALL | re.IGNORECASE,
)

_ATTR_OPEN_RE = re.compile(r'data-clasif\s*=\s*(["\'])', re.IGNORECASE)


def _iter_grade_blobs(source: str):
    """Yields ``data-clasif`` JSON blobs with balanced-brace scanning.

    The old ``[^}]*`` regex broke on nested objects (``{"a": {"b": 1},
    ...}``) or a ``}`` inside a string value. This scanner counts braces
    while respecting quoted strings (both quote styles, backslash
    escapes), so nested/escaped content parses. Yields raw blob strings.
    """
    n = len(source)
    for m in _ATTR_OPEN_RE.finditer(source):
        i = m.end()
        while i < n and source[i].isspace():
            i += 1
        if i >= n or source[i] != "{":
            continue
        depth = 0
        in_str = None
        esc = False
        j = i
        closed = False
        while j < n:
            ch = source[j]
            if in_str is not None:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == in_str:
                    in_str = None
            else:
                if ch == '"' or ch == "'":
                    in_str = ch
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        closed = True
                        break
            j += 1
        if closed:
            yield source[i:j + 1]


def _grade_date_key(date_str):
    """Sort key for ``udel_datum`` values (Czech ``D.M.YYYY`` or ISO).

    Unparseable/missing dates sort after real ones, ordered by their raw
    string so the order stays deterministic. Never raises.
    """
    try:
        from ..helpers import parse_date

        return (0, parse_date(str(date_str)))
    except Exception:
        return (1, str(date_str or ""))


def _grade_extras(grade: dict, entry: dict) -> dict:
    """Optional mark details, only the ones the page actually filled in.

    ``caption`` is the topic ("pololetní test"), ``strdatum`` the day the
    test was (or is planned to be) written, ``PointsText`` a points mark,
    ``MarkTooltip`` "plánovaná klasifikace" flags an announced mark ("?").
    Empty values are left out so plain marks keep their three keys.
    """
    extras: dict = {}

    def _text(key: str) -> str:
        value = grade.get(key)
        return str(value).strip() if value is not None else ""

    if _text("id"):
        extras["Id"] = _text("id")
    if _text("caption"):
        extras["Caption"] = _text("caption")
    note = " · ".join(t for t in (_text("poznamkakzobrazeni"), _text("VerbalEvaluation")) if t)
    if note:
        extras["Note"] = note
    test_day = _text("strdatum")
    if test_day and test_day != str(entry.get("Date") or "").strip():
        extras["TestDate"] = test_day
    if _text("PointsText"):
        extras["Points"] = _text("PointsText")
    if grade.get("IsNew") is True:
        extras["New"] = True
    tooltip = _text("MarkTooltip").lower()
    if entry.get("Grade") == "?" or "plánovan" in tooltip:
        extras["Planned"] = True
    return extras


def extract_grades(html_string: str) -> dict:
    """Extracts průběžná klasifikace marks from the Bakalari grades page.

    Parses the ``data-clasif`` JSON blobs (``nazev`` / ``MarkText`` /
    ``vaha`` / ``udel_datum``) and groups them per subject::

        {"Matematika": [{"Grade": "1", "Weight": 10, "Date": "5.9.2026"}, ...]}

    Optional details (Id, Caption, Note, TestDate, Points, New, Planned)
    are added per mark only when the page provides them.

    Every subject list is sorted by date (oldest first); the raw page
    groups by subject but leaves dates unordered. Never raises —
    returns {} on empty or unparseable input.
    """
    result_dict: dict = {}
    if not html_string:
        return result_dict
    try:
        source = html.unescape(str(html_string))
    except Exception:
        return result_dict
    blobs = list(_iter_grade_blobs(source))
    if not blobs:
        # Fallback: the legacy regex for markups the scanner misses.
        blobs = [m.group(2) for m in _GRADES_RE.finditer(source)]
    for blob in blobs:
        try:
            grade = json.loads(blob)
        except (ValueError, TypeError):
            continue
        if not isinstance(grade, dict):
            continue
        subject = grade.get("nazev")
        score = grade.get("MarkText")
        if subject is None or score is None:
            continue
        subject = str(subject).strip()
        if not subject:
            continue
        entry = {
            "Grade": str(score).strip(),
            "Weight": grade.get("vaha"),
            "Date": grade.get("udel_datum"),
        }
        entry.update(_grade_extras(grade, entry))
        result_dict.setdefault(subject, []).append(entry)
    for marks in result_dict.values():
        try:
            marks.sort(key=lambda e: _grade_date_key((e or {}).get("Date")))
        except Exception:
            continue
    return result_dict


# -- Web JSON endpoints ---------------------------------------------------------

_SUMMARY_WORDS = ("zameškanost", "zameskanost", "celkem", "součet", "soucet",
                  "souhrn", "průměr", "prumer")


def _clean_name(value) -> str:
    return re.sub(r"[\s\xa0]+", " ", str(value or "")).strip()


def _number(value) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def store_rows(reply) -> list | None:
    """Rows of a DevExtreme ``AspNet.createStore`` reply (a bare list or
    ``{"data": [...], "totalCount": …}``); None when it carries no rows list."""
    if isinstance(reply, dict):
        reply = reply.get("data")
    return reply if isinstance(reply, list) else None


def timetable_details(content) -> list:
    """Lesson details of a ``/Timetable/GetContentData`` reply.

    Every atom carries ``TooltipDetails``: the same JSON the rendered
    page puts into ``data-detail`` (see ``parse_timetable_detail``).
    Unparseable atoms are skipped. Never raises.
    """
    details: list = []
    try:
        days = (content or {}).get("Days") or []
    except AttributeError:
        return details
    for day in days:
        for hour in (day or {}).get("Hours") or []:
            for atom in (hour or {}).get("Atoms") or []:
                try:
                    detail = json.loads((atom or {}).get("TooltipDetails") or "")
                except (TypeError, ValueError):
                    continue
                if isinstance(detail, dict):
                    details.append(detail)
    return details


def absence_date_range(page_html: str):
    """Default ``(dateFrom, dateTo)`` the absence page queries, or None."""
    match = re.search(r"DatesInformations\s*=\s*ko\.mapping\.fromJS\((\{.*?\})\);",
                      str(page_html or ""), re.DOTALL)
    if not match:
        return None
    try:
        info = json.loads(match.group(1))
        return (info["DefaultDateFrom"]["DefaultValue"], info["DefaultDateTo"]["DefaultValue"])
    except (ValueError, KeyError, TypeError):
        return None


def absence_from_subjects(rows) -> tuple:
    """``(percentages, details)`` from ``/Absence/Continuous/GetAbsenceBySubjects`` rows.

    Rows are ``{Name, LessonCount, Count, Percent}`` with ``Percent`` as a
    0–1 fraction (the page shows it with two decimals). The school's
    verdict badges are deliberately not used: the app judges absence by
    its own limits, so ``approaching`` / ``unclassifiable`` stay False
    (exactly what the rendered-page parser reported). Never raises.
    """
    percentages: dict = {}
    details: dict = {}
    for row in store_rows(rows) or []:
        try:
            subject = _clean_name(row.get("Name"))
            fraction = _number(row.get("Percent"))
        except AttributeError:
            continue
        if not subject or fraction is None:
            continue
        if any(word in subject.lower() for word in _SUMMARY_WORDS):
            continue
        pct = round(fraction * 100, 2)
        if subject in percentages and pct <= percentages[subject]:
            continue
        percentages[subject] = pct
        details[subject] = {
            "percent": pct,
            "total_hours": _number(row.get("LessonCount")),
            "missed_hours": _number(row.get("Count")),
            "approaching": False,
            "unclassifiable": False,
        }
    return percentages, details


def subject_directory_from_rows(rows) -> dict:
    """``{subject: teacher}`` from the ``/Teaching/Subjects`` grid rows. Never raises."""
    directory: dict = {}
    for row in store_rows(rows) or []:
        try:
            subject = _clean_name(row.get("SubjectName"))
            teacher = _clean_name(row.get("TeacherName"))
        except AttributeError:
            continue
        if subject:
            directory[subject] = teacher
    return directory


#: ``ChangeType`` -> feed badge, as the substitutions page maps it.
_SUBSTITUTION_BADGES = {"Canceled": "O", "Removed": "O", "Substitution": "S",
                        "Added": "N", "RoomChanged": "M", "Absence": "A"}


def substitutions_from_weeks(weeks) -> list:
    """Feed entries from ``/Timetable/substitutions/dates`` (same shape as
    ``parse_substitutions``). Never raises: [] on garbage."""
    entries: list = []
    for week in weeks or []:
        try:
            changes = week.get("Changes") or []
        except AttributeError:
            continue
        for change in changes:
            try:
                day = re.search(r"\d{1,2}\.\d{1,2}\.\d{4}", str(change.get("Day") or ""))
                if not day:
                    continue
                hour = re.search(r"\d+", str(change.get("HourLabel") or ""))
                info = change.get("ChangeLessonInfo") or {}
                class_text = ""
                if info.get("ClassAbbrev"):
                    group = info.get("GroupAbbrev")
                    class_text = (info["ClassAbbrev"] if info.get("IsClassGroup") or not group
                                  else f"{info['ClassAbbrev']} ({group})")
                parts = [class_text, info.get("SubjectAbbrev") or "", info.get("RoomAbbrev") or ""]
                entries.append({
                    "day": day.group(0),
                    "period": int(hour.group(0)) if hour else None,
                    "time": _clean_name(change.get("TimeLabel")),
                    "badge": _SUBSTITUTION_BADGES.get(str(change.get("ChangeType") or ""), "-"),
                    "info": " | ".join(p for p in parts if str(p).strip()),
                    "subject_short": _clean_name(info.get("SubjectAbbrev")),
                    "description": _clean_name(change.get("Description")),
                })
            except (AttributeError, TypeError, ValueError):
                continue
    return entries


def outbox_excuse_ids(list_html: str) -> list:
    """Message ids of the excuse (OMLUVENKA) rows of the Komens list, in order."""
    ids: list = []
    for match in re.finditer(r"<table\b[^>]*?data-idmsg=\"(\d+)\"[^>]*?data-msgtype=\"([^\"]*)\"",
                             str(list_html or "")):
        if match.group(2) == "OMLUVENKA" and match.group(1) not in ids:
            ids.append(match.group(1))
    return ids


def _lesson_caption(hour) -> int | None:
    try:
        return int(str((hour or {}).get("Caption")).strip())
    except (AttributeError, TypeError, ValueError):
        return None


def sent_excuse_entries(detail) -> list:
    """History entries of one ``/Komens/GetMessageDataAsync`` excuse detail.

    Same rules as the rendered-detail parser: lessons -> three entries
    (``income`` + ``soon`` + ``days and hours``, so web excuses dedupe
    against every locally generated shape); no lessons and no clock times
    -> a whole-day entry; clock times without lessons -> the covered
    lessons are unknown, so nothing is learned. Never raises.
    """
    try:
        if str(detail.get("Kind") or "OMLUVENKA") != "OMLUVENKA":
            return []
        start_day = _zero_pad_day(detail.get("DateFrom"))
        end_day = _zero_pad_day(detail.get("DateTo"))
    except (AttributeError, ValueError):
        return []
    start_lesson = _lesson_caption(detail.get("HourFrom"))
    end_lesson = _lesson_caption(detail.get("HourTo"))
    if start_lesson is None or end_lesson is None:
        if str(detail.get("TimeFrom") or "").strip() or str(detail.get("TimeTo") or "").strip():
            return []
        return [{"type": "pure days", "starting_day": start_day, "ending_day": end_day}]
    base = {"starting_day": start_day, "ending_day": end_day,
            "starting_lesson": start_lesson, "ending_lesson": end_lesson}
    return [{"type": kind, **base} for kind in ("income", "soon", "days and hours")]
