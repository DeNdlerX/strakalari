"""Bakaláři parsing helpers shared by the client mixins."""

from .helpers import extract_lesson_num, short_room_name


def _split_removed_info(removedinfo: str) -> tuple:
    """Splits ``"Zrušeno (FG, Dušek Filip)"`` into (subject, teacher).

    Cancelled lessons carry no teacher/subject/room keys — only this
    human-readable string. Anything unparseable yields ("", "") and the
    stable baseline fills the facts in later. Never raises.
    """
    try:
        text = str(removedinfo or "")
        start, end = text.find("("), text.rfind(")")
        inner = text[start + 1:end] if 0 <= start < end else ""
        if "," in inner:
            subject, _, teacher = inner.partition(",")
            return subject.strip(), teacher.strip()
        return inner.strip(), ""
    except Exception:
        return "", ""


def _hour_index(value) -> int | None:
    """Raw ``hourIndex`` as int, or None when missing/unparseable."""
    try:
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        return None


def parse_timetable_detail(detail: dict) -> dict | None:
    """Converts one ``data-detail`` JSON blob into a lesson dict.

    Returns None for rows with no usable content. ``type == "removed"``
    rows (cancelled lessons, e.g. ``"Zrušeno (FG, Dušek Filip)"``) carry
    no teacher/subject/room keys — they become ``status="cancelled"``
    lessons instead of being dropped. Bakalari change signals
    (``changeinfo`` / ``infoChangeCode`` / ``changeBadgeChar`` /
    ``hourIndex``) are carried through so classification can trust them
    instead of guessing from the teacher notice alone.
    """
    if not isinstance(detail, dict):
        return None
    changeinfo = str(detail.get("changeinfo") or detail.get("ChangeInfo") or "").strip()
    info_code = str(detail.get("infoChangeCode") or detail.get("InfoChangeCode") or "").strip()
    badge = str(detail.get("changeBadgeChar") or "").strip()
    removedinfo = str(detail.get("removedinfo") or detail.get("RemovedInfo") or "").strip()
    absentinfo = str(detail.get("absentinfo") or detail.get("AbsentInfo") or "").strip()
    notice = str(
        detail.get("notice") or detail.get("Notice")
        or detail.get("change") or detail.get("Change") or ""
    ).strip()
    if not notice:
        # Room/substitution moves (badge "M") put the explanation in
        # changeinfo ("Změna místnosti: II (I)") with an empty notice.
        notice = changeinfo
    hour_index = _hour_index(detail.get("hourIndex") or detail.get("HourIndex"))
    time_text = detail.get("time") or detail.get("Time")

    if absentinfo and not detail.get("teacher"):
        # Class absence: a school event replaces the lesson (absentinfo
        # "B", removedinfo "beseda / přednáška / workshop") and arrives
        # with no type/teacher/subject. The event name stands in for the
        # subject until backfill_stable_facts fills in the stable lesson;
        # it shows as a change, never as cancelled (see is_class_event).
        if not removedinfo:
            return None
        return {
            "teacher": "",
            "subject": removedinfo,
            "subject_short": "",
            "room": "",
            "group": "",
            "theme": "",
            "notice": removedinfo,
            "date": detail.get("day") or detail.get("Day"),
            "time": time_text,
            "absencetext": "",
            "absenceType": "",
            "type": "event",
            "changeinfo": changeinfo,
            "infoChangeCode": info_code,
            "changeBadgeChar": badge,
            "hourIndex": hour_index,
        }

    if str(detail.get("type") or "atom").strip().lower() == "removed":
        if not (removedinfo or notice):
            return None
        subject, teacher = _split_removed_info(removedinfo or notice)
        return {
            "teacher": teacher,
            "subject": subject,
            "subject_short": subject,
            "room": "",
            "group": "",
            "theme": "",
            "notice": removedinfo or notice,
            "change": removedinfo or notice,
            "date": detail.get("day") or detail.get("Day"),
            "time": time_text,
            "absencetext": "",
            "absenceType": "",
            "status": "cancelled",
            "type": "removed",
            "removedinfo": removedinfo,
            "changeinfo": changeinfo,
            "infoChangeCode": info_code,
            "changeBadgeChar": badge,
            "hourIndex": hour_index,
        }

    teacher = detail.get("teacher")
    subject = detail.get("subjecttext") or detail.get("SubjectName")
    if not teacher or str(teacher).strip() == "None":
        return None
    if not subject or str(subject).strip() == "None":
        return None

    period = None
    try:
        period = extract_lesson_num(time_text)
    except Exception:
        period = None
    if period is None and hour_index is not None:
        # Verified against real pages: hourIndex = period + 2 on every
        # row (period 1 <-> 3, ..., period 9 <-> 11). Only periods >= 1
        # are inferred — hourIndex 2 (candidate 0) is not an observed
        # mapping and must stay unknown instead of inventing period 0.
        candidate = hour_index - 2
        if 1 <= candidate <= 15:
            period = candidate
    lesson = {
        "teacher": str(teacher).strip(),
        "subject": str(subject).strip(),
        "subject_short": str(detail.get("subjectshort") or detail.get("SubjectShort") or "").strip(),
        "room": short_room_name(str(detail.get("room") or detail.get("roomtext") or detail.get("RoomName") or "").strip()),
        "group": str(detail.get("group") or detail.get("grouptext") or detail.get("GroupName") or "").strip(),
        "theme": str(detail.get("theme") or detail.get("Theme") or "").strip(),
        "notice": notice,
        "date": detail.get("day") or detail.get("Day"),
        "time": time_text,
        "absencetext": detail.get("absencetext"),
        "absenceType": detail.get("absenceType"),
        "changeinfo": changeinfo,
        "infoChangeCode": info_code,
        "changeBadgeChar": badge,
        "hourIndex": hour_index,
    }
    if period is not None:
        lesson["period"] = period
    return lesson


def _detail_days(details) -> set:
    """Dates of every lesson in a list of timetable details. Never raises."""
    from .models import parse_cz_date

    days = set()
    for detail in details or []:
        try:
            day = parse_cz_date(detail.get("day") or detail.get("Day"))
        except Exception:
            continue
        if day is not None:
            days.add(day)
    return days


def week_offsets(go_back_weeks: int, go_forward_weeks: int) -> list[int]:
    """Newest-first week offsets for the timetable fetch loop.

    ``go_back_weeks`` counts the current week (``0``) plus past weeks,
    ``go_forward_weeks`` adds future weeks on top. E.g. back=4, forward=1
    yields ``[+1, 0, -1, -2, -3]`` — next week first, then today backwards.
    Total weeks fetched = back + forward.
    """
    try:
        back = max(0, int(go_back_weeks))
    except (TypeError, ValueError):
        back = 0
    try:
        forward = max(0, int(go_forward_weeks))
    except (TypeError, ValueError):
        forward = 0
    return list(range(forward, -back, -1))
