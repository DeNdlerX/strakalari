"""Shared data models for Strakalari (UI-agnostic).

These dataclasses are the contract between the backend (extractors, cache,
forecast engine) and any frontend (Flet UI, CLI). They accept the loose
dict shapes produced by the legacy extractors via ``*_from_legacy`` helpers,
so views never have to guess dict keys again.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any, Iterable

from .helpers import extract_lesson_num, is_excused_marker, short_room_name


def _str(value: Any, default: str = "") -> str:
    return str(value).strip() if value is not None else default


def parse_cz_date(value: Any) -> date | None:
    """Parses ``DD.MM.YYYY`` / ISO dates; None when unparseable.

    Real Bakalari cache keys carry a weekday suffix (``10.9.2026 (čtvrtek)``)
    and single-digit day/month — both are accepted here.
    """
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    if isinstance(value, datetime):
        return value.date()
    text = _str(value).split("(")[0].strip()
    for fmt in ("%d.%m.%Y", "%Y-%m-%d", "%d.%m.%y", "%Y/%m/%d", "%d/%m/%Y"):
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            continue
    return None


def canonical_day_key(value: Any) -> str:
    """Normalizes any parsable day to ``DD.MM.YYYY`` (zero-padded).

    Timetable cache keys (``7.9.2026 (pondělí)``), food keys
    (``07.09.2026``) and ``date`` objects all collapse to one form so
    views can look up "today" with a plain string comparison.
    Unparseable input is returned stripped, unchanged.
    """
    day = parse_cz_date(value)
    if day is None:
        return _str(value)
    return day.strftime("%d.%m.%Y")


@dataclass
class Lesson:
    """One taught lesson."""

    subject: str
    day: date | None = None
    period: int | None = None
    time: str = ""
    room: str = ""
    teacher: str = ""
    status: str = ""  # e.g. "absent" / "late" / "present" / ""
    change: str = ""  # e.g. "suplování" / "odpadá" / "přesun" / ""
    excused: bool = False

    def __post_init__(self) -> None:
        # Bakalari labels rooms as "<short> - (<code>)" ("4A - (104)");
        # the UI only ever shows the short part.
        try:
            self.room = short_room_name(self.room)
        except Exception:
            pass

    @classmethod
    def from_legacy(cls, raw: dict, day: Any = None) -> "Lesson":
        raw = raw or {}
        parsed_day = parse_cz_date(raw.get("date", day))
        period = raw.get("period")
        try:
            period = int(period) if period is not None else None
        except (TypeError, ValueError):
            period = None
        if period is None:
            # Real Bakalari rows carry no "period" key, only a "time" string
            # like "3 (10:05 - 10:50)" — derive it so task keys don't collide.
            try:
                period = extract_lesson_num(raw.get("time", ""))
            except Exception:
                period = None
        status, change, excused = _lesson_status_from_legacy(raw)
        return cls(
            subject=_str(raw.get("subject"), "?"),
            day=parsed_day,
            period=period,
            time=_str(raw.get("time")),
            room=short_room_name(_str(raw.get("room"))),
            teacher=_str(raw.get("teacher")),
            status=status,
            change=change,
            excused=excused,
        )


def _absent_text_marked(abs_text: str) -> bool:
    """True when free-text absence text positively marks an absence.

    Plain substring matching misfires on negations that embed the stem
    (``NoAbsent`` contains ``absent`` but means present). Tokens carrying
    an English ``no``-prefix (``noabsent``, ``no absence``) are therefore
    skipped; Czech ``neomluveno``/``neomluven`` stay positive markers.
    """
    markers = ("neomluv", "neomluveno", "zamešk", "chyb", "absence", "absent", "unexcused")
    negations = ("no", "bez", "beze")
    prev = ""
    for token in re.findall(r"[a-zá-ž]+", str(abs_text or "").lower()):
        if any(m in token for m in markers):
            # Negations: "no absence" or "bez absence" mean present.
            if prev in negations:
                prev = token
                continue
            rest = token
            # Strip one English "no" negation prefix ("noabsent" -> "absent").
            if rest.startswith("no") and rest != "no" and any(m in rest[2:] for m in markers):
                prev = token
                continue
            return True
        prev = token
    return False


def cancel_negated(text: str) -> bool:
    """True when a cancel-looking text is actually negated (no cancellation).

    Plain substring matching misfires on negations that embed the stem
    (``Neodpadá`` contains ``odpad`` but means the lesson goes ahead).
    Texts carrying an explicit negation (``neodpadá``, ``nezrušeno``,
    ``beze změny`` …) must therefore never classify as cancelled.
    """
    low = str(text or "").lower()
    markers = (
        "neodpad", "nezruš", "nezrus", "neruší", "nerusi",
        "neodpadne", "nezruší", "nezrusi",
        "beze změn", "beze zmen", "bez změn", "bez zmen",
        "nedošlo ke změně", "nedoslo ke zmene",
    )
    if any(m in low for m in markers):
        return True
    # Word-boundary negations: "ne odpadá" / "není zrušeno".
    if re.search(r"\bne\s+(odpad|zruš|zrus)", low):
        return True
    if re.search(r"\bnení\s+(zrušen|zrusen)", low):
        return True
    return False


def absence_kind(absence_type: Any, absence_text: Any) -> str:
    """Classifies Bakaláři's absence fields for one lesson.

    Returns ``"excused"``, ``"soon"`` (brzký odchod), ``"late"``
    (pozdní příchod), ``"early"`` (generic předčasný odchod),
    ``"absent"`` or ``""`` (present / no absence). The single source of
    truth for both the UI task list and automatic excusing.
    """
    abs_type = _str(absence_type).lower()
    abs_text = _str(absence_text).lower()
    combined = f"{abs_text} {abs_type}"
    # "Neomluveno"/"Unexcused" embed "omluv"/"excus" but mean the
    # opposite — is_excused_marker() handles the negations.
    excused = is_excused_marker(combined)
    # Early leave is checked before late/early/absent: "absentsoon"
    # embeds "absent" and "brzký odchod" embeds "odchod".
    if (any(k in combined for k in ("absentsoon", "brzk", "soon"))
            or abs_type in ("brzky odchod", "brzký odchod")):
        return "excused" if excused else "soon"
    if any(k in combined for k in ("pozdn", "income", "absentlate", "late")):
        return "excused" if excused else "late"
    if any(k in combined for k in ("předčasn", "predcasn", "odchod", "absentearly", "early")):
        return "excused" if excused else "early"
    if excused:
        return "excused"
    if (abs_type in ("absent", "unexcused", "neomluven", "neomluveno", "neomluvena", "neomluvená")
            or _absent_text_marked(abs_text)):
        return "absent"
    return ""


_CANCEL_KEYWORDS = ("odpad", "zruš", "zrus", "vyjm", "vynat", "vyňat")

# Standalone negators that flip a following keyword ("ne odpadá").
_CANCEL_NEGATORS = frozenset({
    "ne", "neni", "není", "nebude", "nebudou", "nebyl", "nebyla",
    "nebylo", "nebyly", "nedojde", "nedošlo", "nedoslo",
})


def is_cancel_notice(text: Any) -> bool:
    """True when a lesson notice marks the lesson as cancelled.

    Negated forms never count: "Neodpadá" / "Nezrušeno" embed the
    keyword stems, "nebude zrušeno" negates with a separate word, and
    "beze změny" style phrases mean the lesson goes ahead.
    """
    low = str(text or "").lower()
    if cancel_negated(low):
        return False
    prev = ""
    for word in re.findall(r"[a-zá-ž]+", low):
        if any(kw in word for kw in _CANCEL_KEYWORDS):
            ne_prefixed = word.startswith("ne") and any(kw in word[2:] for kw in _CANCEL_KEYWORDS)
            if not ne_prefixed and prev not in _CANCEL_NEGATORS:
                return True
        prev = word
    return False


def _lesson_status_from_legacy(raw: dict) -> tuple[str, str, bool]:
    """Derives (status, change, excused) from Bakalari seed shapes.

    Real cache rows carry ``absenceType`` / ``absencetext`` / ``notice``
    (e.g. ``NoAbsent``, ``Absent``, ``AbsentLate``, ``suplování``,
    ``odpadá``); demo rows and older caches carry a plain ``status``
    (``absent`` / ``late``). Both are normalized to
    ``"" | late | early | soon | absent | cancelled | excused`` so every
    frontend shares one vocabulary. Precedence is cancelled > late/early >
    excused > unexcused > substitution > present.
    """
    abs_type = raw.get("absenceType")
    abs_text = raw.get("absencetext")
    notice = _str(raw.get("notice") or raw.get("change"))
    notice_lower = notice.lower()
    # Bakalari cancellation signals: the classic "odpadá" notice, the
    # scraped "removed" row ("Zrušeno (FG, Dušek Filip)" in removedinfo /
    # changeinfo), or an explicit removal change code.
    cancel_signal = " ".join((
        notice_lower,
        _str(raw.get("changeinfo")).lower(),
        _str(raw.get("removedinfo")).lower(),
    ))
    detail_type = _str(raw.get("type")).lower()
    info_code = _str(raw.get("infoChangeCode")).lower()
    if (detail_type == "removed"
            or info_code in ("removed", "cancelled", "canceled")
            or _str(raw.get("status")).lower() in ("cancelled", "odpadá")
            or is_cancel_notice(cancel_signal)):
        return "cancelled", notice or _str(raw.get("changeinfo")) or _str(raw.get("removedinfo")), False
    kind = absence_kind(abs_type, abs_text)
    if kind == "excused":
        return "excused", "", True
    if kind in ("soon", "late", "early"):
        return kind, notice, False
    if kind == "absent":
        return "absent", "", False
    # Demo / legacy plain-status rows win over the substitution notice —
    # an explicitly late/absent lesson stays late/absent even with a note.
    legacy = _str(raw.get("status")).lower()
    if legacy in ("absent", "absentlate", "nepritomen", "neprítomen", "absence", "unexcused"):
        return "absent", _str(raw.get("change")), False
    if legacy in ("soon", "brzký odchod", "brzky odchod"):
        return "soon", _str(raw.get("change")), False
    if legacy in ("late", "income", "pozdní příchod"):
        return "late", _str(raw.get("change")), False
    if legacy in ("early", "předčasný odchod"):
        return "early", _str(raw.get("change")), False
    if legacy in ("excused", "omluveno"):
        return "excused", "", True
    if any(k in notice_lower for k in ("supl", "změn")):
        return "", notice, False
    if legacy in ("", "present", "přítomen", "noabsent", "none"):
        return "", _str(raw.get("change")) or notice, False
    if legacy:
        return "", _str(raw.get("change")) or notice, False
    return "", notice, False


def lessons_from_timetable(timetable: dict) -> list[Lesson]:
    """Flattens legacy ``{day: [lesson_dict, ...]}`` into Lessons."""
    out: list[Lesson] = []
    for day_key, lessons in (timetable or {}).items():
        for raw in lessons or []:
            if isinstance(raw, dict):
                out.append(Lesson.from_legacy(raw, day=day_key))
    return out


@dataclass
class SubjectState:
    """Absence state of one subject, including its own limit.

    ``limit_pct`` / ``safe_hours_left`` are the school truth. The
    planning reserve (see ``forecast_subject``) is baked into
    ``plan_limit_pct`` / ``plan_safe_hours_left`` — the planner reads
    the ``effective_plan_*`` properties so suggestions stop earlier.
    ``None`` means \"no forecast attached\" (hand-built states fall
    back to the school values).
    """

    name: str
    current_pct: float = 0.0
    limit_pct: float = 25.0
    weekly_hours: int = 0
    safe_hours_left: int = 0
    projected_pct: float = 0.0
    warn_pct: float = 0.0  # explicit warn threshold; <=0 derives 60% of limit
    plan_limit_pct: float | None = None
    plan_safe_hours_left: int | None = None
    # School verdict badges from the absence overview (display:none-gated,
    # so True always means the school actually flagged the subject).
    approaching: bool = False
    unclassifiable: bool = False
    # Already-taught hours (elapsed, never planned totals); 0 = unknown.
    taught_hours: float = 0.0

    @property
    def effective_plan_limit(self) -> float:
        """Planning limit: school limit minus the safety reserve."""
        if self.plan_limit_pct is None:
            return self.limit_pct
        return self.plan_limit_pct

    @property
    def effective_plan_safe(self) -> int:
        """Remaining hours the planner may still spend."""
        if self.plan_safe_hours_left is None:
            return self.safe_hours_left
        return self.plan_safe_hours_left

    @property
    def plan_status(self) -> str:
        """ok/warning/critical against the reserve-aware planning limit."""
        if self.unclassifiable or self.current_pct >= self.effective_plan_limit:
            return "critical"
        warn_at = self.warn_pct if self.warn_pct > 0 else self.effective_plan_limit * 0.6
        if self.approaching or self.current_pct >= warn_at:
            return "warning"
        return "ok"

    @property
    def status(self) -> str:
        warn_at = self.warn_pct if self.warn_pct > 0 else self.limit_pct * 0.6
        if self.unclassifiable or self.current_pct >= self.limit_pct:
            return "critical"
        if self.approaching or self.current_pct >= warn_at:
            return "warning"
        return "ok"


@dataclass
class ExcuseTask:
    """One absence/late arrival waiting for (one-click) excusing."""

    key: str
    kind: str  # "late" | "early" | "soon" | "short" (generic early leaves are "early")
    label: str
    detail: str = ""
    date: date | None = None
    period: int | None = None
    template: str = ""
    status: str = "pending"  # pending | sent | failed


def excuse_tasks_from_lessons(lessons: Iterable[Lesson]) -> list[ExcuseTask]:
    """Builds pending excuse tasks from unexcused absent/late lessons."""
    tasks: list[ExcuseTask] = []
    for lesson in lessons:
        if lesson.excused or lesson.status in ("excused", "cancelled", "", "present"):
            continue
        if lesson.status not in ("absent", "absence", "nepritomen", "neprítomen",
                                 "unexcused", "late", "early", "soon",
                                 "absentlate", "absentearly"):
            continue
        if lesson.status == "soon":
            kind = "soon"
        elif lesson.status in ("late", "absentlate"):
            kind = "late"
        elif lesson.status in ("early", "absentearly"):
            kind = "early"
        else:
            kind = "short"
        day = lesson.day
        day_label = f"{day.day}. {day.month}." if day else "?"
        if lesson.period is not None:
            from .i18n import t

            period_label = ", " + t("period_label", n=lesson.period)
        else:
            period_label = ""
        key = f"{day.isoformat() if day else '?'}|{lesson.period}|{lesson.subject}"
        tasks.append(
            ExcuseTask(
                key=key,
                kind=kind,
                label=f"{lesson.subject} — {day_label}{period_label}",
                detail=" · ".join(p for p in (lesson.teacher, lesson.room) if p),
                date=lesson.day,
                period=lesson.period,
            )
        )
    return tasks
