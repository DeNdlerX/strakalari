"""Rozvrh — week navigation with a real grid table (days × periods).

Default is the grid: rows are days (Y), columns are lesson periods (X)
and the cells share the available width, so the whole week is visible at
once. Free periods stay blank; attendance, changes and cancellations are
drawn in the cell itself (see ``_look``); today's row and the current or
next lesson are highlighted. Tapping a cell opens the detail dialog.
A list view (one card per day, past days folded) stays available via the
toggle — the choice persists in config. The selected week lives in
``AppState`` so navigation survives full re-renders.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from datetime import time as dtime

import flet as ft

from strakalari.core.helpers import extract_lesson_num
from strakalari.core.i18n import get_language
from strakalari.core.models import Lesson, parse_cz_date
from strakalari.core.schedule import LessonDiff, classify_lesson, stable_template_week

from .. import components as C
from .. import tutorial as T
from ..overlays import close_dialog, show_dialog
from ..state import AppState
from ..strings import S
from ..theme import border_all, pad_all, pad_sym, radius_all, tint

CZECH_DAYS = C.CZECH_DAY_NAMES
ENGLISH_DAYS = C.ENGLISH_DAY_NAMES

STATUS_TEXT = {
    "late": "status_late",
    "soon": "status_soon",
    "early": "status_early",
    "absent": "status_absent",
    "cancelled": "status_lesson_cancelled",
    "excused": "status_excused",
}


def _day_names() -> list[str]:
    return ENGLISH_DAYS if get_language() == "en" else CZECH_DAYS


def _weeks(timetable: dict) -> dict[date, dict[date, list[dict]]]:
    """Groups ``{day: lessons}`` by week Monday (keys in any date format)."""
    weeks: dict[date, dict[date, list[dict]]] = {}
    for day_key, lessons in (timetable or {}).items():
        day = parse_cz_date(day_key)
        if day is None:
            continue
        monday = day - timedelta(days=day.weekday())
        weeks.setdefault(monday, {})[day] = lessons or []
    return weeks


def _resolve_current(weeks: dict[date, dict], state: AppState) -> date:
    today = date.today()
    this_mon = today - timedelta(days=today.weekday())
    if state.timetable_monday_iso:
        try:
            pinned = date.fromisoformat(state.timetable_monday_iso)
            if pinned in weeks:
                return pinned
        except ValueError:
            pass
    if this_mon in weeks:
        return this_mon
    mondays = sorted(weeks)
    if not mondays:
        return this_mon
    future = [m for m in mondays if m >= this_mon]
    return future[0] if future else mondays[-1]


def _status_label(status: str) -> str:
    key = STATUS_TEXT.get(str(status or "").lower())
    return S(key) if key else str(status)


def _diff_of(state: AppState, lesson: dict, day: date) -> LessonDiff:
    """Real change vs teacher note, diffed against the stable timetable."""
    try:
        complete = getattr(state, "stable_complete", None)
        complete = bool(complete() if callable(complete) else complete)
        return classify_lesson(lesson, day=day, baseline=state.stable_baseline(),
                               complete=complete)
    except Exception:
        return LessonDiff(note=str((lesson or {}).get("change", "") or ""))


_FIELD_LABELS = {
    "subject": "field_subject",
    "teacher": "field_teacher",
    "room": "field_room",
    "time": "field_time",
    "status": "field_status",
    "notice": "field_notice",
}


def _diff_summary(diff: LessonDiff) -> str:
    fields = ", ".join(S(_FIELD_LABELS[f]) for f in diff.changed
                       if f in _FIELD_LABELS) or S("real_change")
    return S("changed_to").format(fields=fields)


def _diff_tooltip(diff: LessonDiff) -> str:
    tip = _diff_summary(diff) if diff.is_change else S("note_label")
    if diff.note:
        tip += f": {diff.note}"
    return tip


def _detail_dialog(state: AppState, page: ft.Page, lesson: dict, day: date) -> None:
    tok = state.tok
    parsed = Lesson.from_legacy(lesson, day=day)
    subject = parsed.subject or "?"

    try:
        day_name = _day_names()[day.weekday()]
    except (IndexError, AttributeError):
        day_name = ""
    if parsed.period is not None:
        subtitle = (
            f"{day_name} {C.cz_day_year(day)} · "
            f"{parsed.period}. {S('period').lower()} · {C.short_time(parsed.time)}"
            if C.short_time(parsed.time)
            else f"{day_name} {C.cz_day_year(day)} · {parsed.period}. {S('period').lower()}"
        )
    else:
        time = C.short_time(parsed.time)
        subtitle = f"{day_name} {C.cz_day_year(day)}" + (f" · {time}" if time else "")

    badges: list[ft.Control] = []
    if parsed.status:
        badges.append(
            C.badge(_status_label(parsed.status), tok, kind=C.lesson_kind(parsed.status))
        )
    diff = _diff_of(state, lesson, day)
    if diff.is_change:
        badges.append(C.change_badge(tok, tooltip=_diff_tooltip(diff)))

    body: list[ft.Control] = [
        C.txt(subtitle, tok, size=tok.fs_small, muted=True),
    ]
    if badges:
        body.append(ft.Row(badges, spacing=6, wrap=True))
    body.append(C.divider(tok))
    for label_key, value in (
        ("room", parsed.room),
        ("teacher", parsed.teacher),
        ("group", str(lesson.get("group", "") or "")),
        ("theme", str(lesson.get("theme", "") or "")),
    ):
        if value:
            body.append(C.kv_row(tok, S(label_key), str(value)))
    if diff.is_change:
        # What changed vs the stable timetable (usual -> actual).
        try:
            slot = state.stable_baseline().get((day.weekday(), parsed.period if parsed.period is not None else -1))
            if isinstance(slot, list):
                # Split-group slot: compare against the closest variant so
                # the "usual" row shows the right group, not an arbitrary one.
                from strakalari.core.schedule import closest_variant

                slot = closest_variant(slot, lesson, day) or slot[0]
        except Exception:
            slot = None
        usual = {
            "subject": getattr(slot, "subject", ""),
            "teacher": getattr(slot, "teacher", ""),
            "room": getattr(slot, "room", ""),
        }
        actual = {"subject": parsed.subject, "teacher": parsed.teacher,
                  "room": parsed.room}
        stable_names = {"subject": S("col_subject"), "teacher": S("teacher"),
                        "room": S("room")}
        for field_name in ("subject", "teacher", "room", "time", "status", "notice"):
            if field_name not in diff.changed:
                continue
            if field_name in usual:
                old, new = usual[field_name] or "—", actual[field_name] or "—"
                if old != new:
                    body.append(C.kv_row(
                        tok, f"{S('stable_value')} · {stable_names[field_name]}", old))
                    body.append(C.kv_row(
                        tok, f"{S('current_value')} · {stable_names[field_name]}",
                        new, value_color=tok.accent))
            else:
                body.append(C.txt(_diff_summary(diff), tok, size=tok.fs_small,
                                  bold=True, color=tok.accent))
                break
    if diff.note:
        body.append(
            ft.Container(
                content=ft.Row(
                    [
                        ft.Icon(ft.Icons.INFO_OUTLINED, size=16, color=tok.accent),
                        ft.Text(
                            f"{S('note_label')}: {diff.note}",
                            size=tok.fs_small,
                            color=tok.text,
                            expand=True,
                        ),
                    ],
                    spacing=8,
                    tight=True,
                    vertical_alignment=ft.CrossAxisAlignment.START,
                ),
                bgcolor=tok.overlay,
                border=border_all(1, tok.accent),
                border_radius=radius_all(tok.radius_sm),
                padding=pad_sym(horizontal=10, vertical=8),
            )
        )
    dlg = ft.AlertDialog(
        title=ft.Text(subject, weight=ft.FontWeight.BOLD, size=tok.fs_section),
        content=ft.Container(
            content=ft.Column(
                body,
                spacing=8,
                tight=True,
                horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
            ),
            width=380,
        ),
        actions=[ft.TextButton(S("close"), on_click=lambda e: close_dialog(page, dlg))],
        actions_alignment=ft.MainAxisAlignment.END,
        scrollable=True,
    )
    show_dialog(page, dlg)


# -- shared lesson look (grid cells + list rows) ---------------------------
@dataclass
class _Look:
    """How one lesson renders: identical rules for the grid and the list."""

    parsed: Lesson
    diff: LessonDiff
    cancelled: bool
    changed: set[str]
    bar: str | None      # attendance color (absent / late / excused)
    fill: str | None     # tile background
    tag: str             # one short label ("Absence", "Suplování", …)
    tag_color: str
    tooltip: str


def _change_tag(changed: set[str]) -> str:
    if "added" in changed:
        return S("tag_added")
    if "teacher" in changed:
        return S("tag_substitution")
    if "room" in changed and not changed - {"room", "notice"}:
        return S("tag_room_change")
    return S("real_change")


def _look(state: AppState, raw: dict, day: date) -> _Look:
    tok = state.tok
    parsed = Lesson.from_legacy(raw, day=day)
    diff = _diff_of(state, raw, day)
    status = str(parsed.status or "").lower()
    cancelled = status == "cancelled"
    changed = set(diff.changed) if diff.is_change else set()
    bar = {
        "absent": tok.red,
        "late": tok.orange,
        "early": tok.orange,
        "soon": tok.orange,
        "excused": tok.green,
    }.get(status)
    if cancelled:
        fill = None
    elif diff.is_change:
        fill = tint(tok.accent, 0.22)
    elif bar:
        fill = tint(bar, 0.12)
    else:
        fill = tok.card
    if cancelled:
        tag, tag_color = S("status_lesson_cancelled"), tok.muted
    elif status:
        tag, tag_color = _status_label(status), bar or tok.muted
    elif diff.is_change:
        tag, tag_color = _change_tag(changed), tok.accent
    else:
        tag, tag_color = "", tok.faint

    lines = [parsed.subject or "?"]
    who = " · ".join(p for p in (parsed.teacher, parsed.room) if p)
    if who:
        lines.append(who)
    if C.short_time(parsed.time):
        lines.append(C.short_time(parsed.time))
    if status and not cancelled:
        lines.append(_status_label(status))
    if diff.is_change or diff.note:
        lines.append(_diff_tooltip(diff))
    return _Look(parsed, diff, cancelled, changed, bar, fill, tag, tag_color,
                 "\n".join(lines))


def _meta_text(tok, look: _Look, size: int) -> ft.Text:
    """'U12 · Nováková' with the changed parts in the accent color."""
    room = look.parsed.room
    surname = C.teacher_surname(look.parsed.teacher)
    spans: list[ft.TextSpan] = []
    if room:
        spans.append(ft.TextSpan(room, ft.TextStyle(
            color=tok.accent if "room" in look.changed else tok.muted,
            weight=ft.FontWeight.W_600)))
    if surname:
        if spans:
            spans.append(ft.TextSpan(" · ", ft.TextStyle(color=tok.faint)))
        spans.append(ft.TextSpan(surname, ft.TextStyle(
            color=tok.accent if "teacher" in look.changed else tok.faint)))
    return ft.Text(spans=spans, size=size, max_lines=1,
                   overflow=ft.TextOverflow.ELLIPSIS)


def _subject_text(tok, look: _Look, value: str, size: int) -> ft.Text:
    if look.cancelled:
        color = tok.faint
    elif look.changed & {"subject", "added"}:
        color = tok.accent
    else:
        color = tok.text
    return ft.Text(
        value,
        size=size,
        weight=ft.FontWeight.BOLD,
        color=color,
        max_lines=1,
        overflow=ft.TextOverflow.ELLIPSIS,
        style=ft.TextStyle(decoration=ft.TextDecoration.LINE_THROUGH,
                           decoration_color=tok.faint)
        if look.cancelled else None,
    )


def _bar(color: str | None, height: int) -> ft.Container:
    return ft.Container(width=3, height=height, bgcolor=color,
                        border_radius=radius_all(2))


# -- "now" marker ------------------------------------------------------------
_CLOCK_RE = re.compile(r"(\d{1,2}):(\d{2})\s*[-–]\s*(\d{1,2}):(\d{2})")


def _clock_range(label: str) -> tuple[dtime, dtime] | None:
    m = _CLOCK_RE.search(str(label or ""))
    if not m:
        return None
    try:
        return (dtime(int(m.group(1)), int(m.group(2))),
                dtime(int(m.group(3)), int(m.group(4))))
    except ValueError:
        return None


def _focus_period(lessons: list[dict], day: date, now: datetime) -> tuple[int | None, str]:
    """(period, "now" | "next") on today's row; (None, "") elsewhere."""
    if day != now.date():
        return None, ""
    upcoming: list[tuple[dtime, int]] = []
    for raw in lessons:
        if not isinstance(raw, dict):
            continue
        if Lesson.from_legacy(raw, day=day).status == "cancelled":
            continue
        period = _period_of(raw, day)
        span = _clock_range(C.short_time(Lesson.from_legacy(raw, day=day).time))
        if period is None or span is None:
            continue
        start, end = span
        if start <= now.time() < end:
            return period, "now"
        if start > now.time():
            upcoming.append((start, period))
    if upcoming:
        return min(upcoming)[1], "next"
    return None, ""


# -- grid table (days × periods, fills the available width) ----------------
GUTTER_W = 72
ROW_H = 68
HEADER_H = 38
GAP = 4
ROW_PAD = 2
#: Horizontal space outside the grid: rail + divider + content padding.
_CHROME_W = 100 + 2 * 24
_STOPWORDS = {"a", "i", "z", "ze", "s", "se", "v", "ve", "na", "pro", "and", "of", "the"}


def _period_of(raw: dict, day) -> int | None:
    parsed = Lesson.from_legacy(raw, day=day)
    num = extract_lesson_num(parsed.time)
    if num is None:
        num = parsed.period
    try:
        return int(num) if num is not None else None
    except (TypeError, ValueError):
        return None


def _period_time(lessons_by_day: dict, period: int) -> str:
    """Most common clock time for ``period`` across the week."""
    from collections import Counter

    seen: Counter[str] = Counter()
    for day, lessons in lessons_by_day.items():
        for raw in lessons or []:
            if not isinstance(raw, dict):
                continue
            if _period_of(raw, day) == period:
                label = C.short_time(Lesson.from_legacy(raw, day=day).time)
                if label:
                    seen[label] += 1
    return seen.most_common(1)[0][0] if seen else ""


def _abbrev(subject: str) -> str:
    """Initials of a multi-word name ('Základy společenských věd' -> 'ZSV')."""
    words = [w for w in re.split(r"[\s/-]+", str(subject or "")) if w]
    significant = [w for w in words if w.lower() not in _STOPWORDS]
    if len(significant) < 2:
        return str(subject or "")
    return "".join(w[0].upper() for w in significant)[:5]


def _cell_chars(page, periods: int) -> int:
    """Roughly how many bold characters fit on one line of a grid cell."""
    try:
        width = float(getattr(page, "width", None) or 0)
    except (TypeError, ValueError):
        width = 0.0
    if width <= 0:
        width = 1240.0  # default window width
    usable = width - _CHROME_W - GUTTER_W - GAP * max(1, periods)
    cell = usable / max(1, periods)
    return max(3, int((cell - 24) / 7.5))


def _cell_subject(raw: dict, full: str, max_chars: int) -> str:
    """Full name when it fits, else Bakaláři's short name (or initials)."""
    full = full or "?"
    if len(full) <= max_chars:
        return full
    short = str(raw.get("subject_short") or "").strip()
    if short and short != full:
        return short
    return _abbrev(full)


def _grid_cell(
    state: AppState, page: ft.Page, raw: dict | None, day: date,
    focus: str, max_chars: int,
) -> ft.Control:
    tok = state.tok
    if not isinstance(raw, dict):
        # Free period: blank space keeps the column rhythm, no frame.
        return ft.Container(expand=1, height=ROW_H)
    look = _look(state, raw, day)
    subject = _cell_subject(raw, look.parsed.subject, max_chars)
    body: list[ft.Control] = [
        _subject_text(tok, look, subject, tok.fs_body),
        _meta_text(tok, look, tok.fs_tiny),
    ]
    tag_row: list[ft.Control] = []
    if look.tag:
        tag_row.append(ft.Text(look.tag, size=tok.fs_tiny, color=look.tag_color,
                               weight=ft.FontWeight.W_600, max_lines=1,
                               overflow=ft.TextOverflow.ELLIPSIS, expand=True))
    if look.diff.note and not look.diff.is_change:
        # A change's notice is the change itself; the dot marks plain notes.
        if not tag_row:
            tag_row.append(ft.Container(expand=True))
        tag_row.append(ft.Container(width=6, height=6, bgcolor=tok.accent,
                                    border_radius=radius_all(3)))
    if tag_row:
        body.append(ft.Row(tag_row, spacing=4,
                           vertical_alignment=ft.CrossAxisAlignment.CENTER))
    if focus == "now":
        frame = border_all(2, tok.accent)
    elif focus == "next":
        frame = border_all(1, tok.accent)
    elif look.cancelled:
        frame = border_all(1, tok.border)
    else:
        frame = None
    return ft.Container(
        content=ft.Row(
            [
                _bar(look.bar, ROW_H - 16) if look.bar else ft.Container(width=0),
                ft.Column(body, spacing=1, expand=True, tight=True,
                          alignment=ft.MainAxisAlignment.CENTER),
            ],
            spacing=6,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        expand=1,
        height=ROW_H,
        bgcolor=look.fill,
        border=frame,
        border_radius=radius_all(tok.radius_sm),
        padding=pad_sym(horizontal=8, vertical=6),
        tooltip=look.tooltip,
        on_click=lambda e, l=raw, d=day: _detail_dialog(state, page, l, d),
    )


def _period_header(tok, period: int, time_label: str, active: bool) -> ft.Control:
    return ft.Container(
        content=ft.Column(
            [
                C.txt(f"{period}.", tok, bold=True, size=tok.fs_small,
                      color=tok.accent if active else None),
                C.txt(time_label, tok, size=tok.fs_tiny, faint=True)
                if time_label
                else ft.Container(height=0),
            ],
            spacing=0,
            tight=True,
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            alignment=ft.MainAxisAlignment.CENTER,
        ),
        expand=1,
        height=HEADER_H,
    )


def _day_gutter(tok, day: date, count: int, is_today: bool) -> ft.Control:
    name = C.day_name(day, short=True)
    color = tok.accent_text if is_today else None
    return ft.Container(
        content=ft.Column(
            [
                C.txt(name, tok, size=tok.fs_section, bold=True, color=color),
                C.txt(C.cz_day(day), tok, size=tok.fs_tiny,
                      color=color, faint=not is_today),
            ],
            spacing=0,
            tight=True,
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            alignment=ft.MainAxisAlignment.CENTER,
        ),
        width=GUTTER_W,
        height=ROW_H,
        bgcolor=tok.accent if is_today else tok.surface,
        border_radius=radius_all(tok.radius_sm),
        tooltip=f"{C.day_name(day)} {C.cz_day_year(day)} · {count} {S('lessons_count')}",
    )


def _combined_cell(raws: list[dict]) -> dict | None:
    """Merges split-group lessons sharing one period into a single cell.

    Previously only the first group was kept and the rest silently dropped
    from the grid. Subjects/teachers/rooms are joined so every group stays
    visible; clock/status/change come from the first group.
    """
    raws = [r for r in (raws or []) if isinstance(r, dict)]
    if not raws:
        return None
    if len(raws) == 1:
        return raws[0]
    subjects: list[str] = []
    shorts: list[str] = []
    teachers: list[str] = []
    rooms: list[str] = []
    for r in raws:
        for key, acc in (("subject", subjects), ("subject_short", shorts),
                         ("teacher", teachers), ("room", rooms)):
            try:
                val = str((r or {}).get(key, "") or "").strip()
            except Exception:
                val = ""
            if val and val not in acc:
                acc.append(val)
    combined = dict(raws[0])
    if subjects:
        combined["subject"] = " / ".join(subjects)
    if shorts:
        combined["subject_short"] = " / ".join(shorts)
    if len(teachers) > 1:
        combined["teacher"] = ", ".join(teachers)
    if len(rooms) > 1:
        combined["room"] = ", ".join(rooms)
    return combined


def _table_view(
    state: AppState, page: ft.Page, week_days: dict[date, list[dict]], names: list[str],
    now: datetime | None = None,
) -> ft.Control:
    """Whole week at once: rows are days, columns periods, cells share the width."""
    tok = state.tok
    now = now or datetime.now()
    today = now.date()
    days = sorted(week_days)
    by_day_period: dict[date, dict[int, list[dict]]] = {}
    for day in days:
        for raw in week_days[day] or []:
            if not isinstance(raw, dict):
                continue
            period = _period_of(raw, day)
            if period is None:
                continue
            by_day_period.setdefault(day, {}).setdefault(period, []).append(raw)
    periods = sorted({p for per_day in by_day_period.values() for p in per_day})
    if not periods:
        return C.card(C.txt(S("no_lessons_today"), tok, faint=True), tok=tok)

    max_chars = _cell_chars(page, len(periods))
    focus_period, focus_kind = None, ""
    if today in week_days:
        focus_period, focus_kind = _focus_period(week_days[today] or [], today, now)

    header = ft.Container(
        content=ft.Row(
            [ft.Container(width=GUTTER_W)]
            + [_period_header(tok, p, _period_time(week_days, p),
                              active=p == focus_period)
               for p in periods],
            spacing=GAP,
        ),
        padding=pad_sym(horizontal=ROW_PAD),
    )
    grid = ft.Column([header], spacing=GAP, tight=True)
    for day in days:
        lessons = [r for r in (week_days[day] or []) if isinstance(r, dict)]
        is_today = day == today
        cells: list[ft.Control] = [_day_gutter(tok, day, len(lessons), is_today)]
        for period in periods:
            cells.append(_grid_cell(
                state, page, _combined_cell(by_day_period.get(day, {}).get(period)),
                day, focus_kind if is_today and period == focus_period else "",
                max_chars,
            ))
        grid.controls.append(ft.Container(
            content=ft.Row(cells, spacing=GAP,
                           vertical_alignment=ft.CrossAxisAlignment.CENTER),
            bgcolor=tint(tok.accent, 0.08) if is_today else None,
            border_radius=radius_all(tok.radius_md),
            padding=pad_all(ROW_PAD),
        ))
    return grid


def _lesson_row(state: AppState, page: ft.Page, lesson: dict, day: date,
                focus: str = "") -> ft.Control:
    tok = state.tok
    look = _look(state, lesson, day)
    _num = extract_lesson_num(look.parsed.time)
    period = _num if _num is not None else look.parsed.period
    trailing: list[ft.Control] = []
    if look.tag:
        trailing.append(C.txt(look.tag, tok, size=tok.fs_small, bold=True,
                              color=look.tag_color))
    if look.diff.note and not look.diff.is_change:
        trailing.append(C.note_dot(tok, tooltip=f"{S('note_label')}: {look.diff.note}"))
    return ft.Container(
        content=ft.Row(
            [
                ft.Container(
                    C.txt(f"{period}." if period is not None else "", tok,
                          bold=True, size=tok.fs_small,
                          color=tok.accent if focus else None),
                    width=24,
                    alignment=ft.Alignment(1, 0),
                ),
                ft.Container(
                    C.txt(C.short_time(look.parsed.time), tok, size=tok.fs_small,
                          faint=True),
                    width=96,
                ),
                _bar(look.bar or (tok.accent if look.diff.is_change else None), 32),
                ft.Column(
                    [
                        _subject_text(tok, look, look.parsed.subject or "?", tok.fs_body),
                        _meta_text(tok, look, tok.fs_small),
                    ],
                    spacing=0,
                    expand=True,
                    tight=True,
                ),
                *trailing,
            ],
            spacing=10,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        bgcolor=None if look.fill == tok.card else look.fill,
        border=border_all(1, tok.accent) if focus else None,
        border_radius=radius_all(tok.radius_sm),
        padding=pad_sym(horizontal=8, vertical=6),
        tooltip=look.tooltip,
        on_click=lambda e, l=lesson, d=day: _detail_dialog(state, page, l, d),
    )


def _day_summary(state: AppState, lessons: list[dict], day: date) -> str:
    """'7 hodin · 2× Absence · 1× Změna' for a collapsed past day."""
    counts: dict[str, int] = {}
    for raw in lessons:
        look = _look(state, raw, day)
        if look.tag:
            counts[look.tag] = counts.get(look.tag, 0) + 1
    parts = [f"{len(lessons)} {S('lessons_count')}"]
    parts += [f"{n}× {tag}" for tag, n in counts.items()]
    return " · ".join(parts)


def _list_view(
    state: AppState, page: ft.Page, week_days: dict[date, list[dict]], names: list[str],
    now: datetime | None = None,
) -> list[ft.Control]:
    tok = state.tok
    now = now or datetime.now()
    today = now.date()
    week_has_today = today in week_days
    day_cards: list[ft.Control] = []
    for day in sorted(week_days):
        lessons = sorted(
            [l for l in (week_days[day] or []) if isinstance(l, dict)],
            key=lambda l: extract_lesson_num(str((l or {}).get("time", ""))) or 0,
        )
        is_today = day == today
        title = f"{names[day.weekday()]} {C.cz_day_year(day)}"
        focus_period, focus_kind = _focus_period(lessons, day, now)
        rows: list[ft.Control] = []
        if not lessons:
            rows.append(C.txt(S("no_lessons_today"), tok, size=tok.fs_small, faint=True))
        for lesson in lessons:
            focus = focus_kind if _period_of(lesson, day) == focus_period else ""
            rows.append(_lesson_row(state, page, lesson, day, focus=focus))
        if week_has_today and day < today:
            # Past days of the current week fold away; the summary keeps
            # absences and changes visible without opening them.
            day_cards.append(C.collapsed(tok, title, rows,
                                         subtitle=_day_summary(state, lessons, day)))
            continue
        title_row = ft.Row(
            [
                C.txt(title, tok, bold=True, color=tok.accent if is_today else None),
                C.badge(S("today_badge"), tok) if is_today else ft.Container(width=0),
                ft.Container(expand=True),
                C.txt(f"{len(lessons)} {S('lessons_count')}", tok,
                      size=tok.fs_small, faint=True),
            ],
            spacing=8,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        )
        card = C.card(title_row, ft.Column(rows, spacing=2, tight=True), tok=tok)
        if is_today:
            card.border = border_all(1, tok.accent)
        day_cards.append(card)
    return day_cards


def _legend(tok) -> ft.Row:
    def swatch(control: ft.Control, label: str) -> ft.Row:
        return ft.Row([control, C.txt(label, tok, size=tok.fs_small, muted=True)],
                      spacing=6, tight=True,
                      vertical_alignment=ft.CrossAxisAlignment.CENTER)

    def box(fill: str | None, border=None) -> ft.Container:
        return ft.Container(width=14, height=14, bgcolor=fill, border=border,
                            border_radius=radius_all(4))

    struck = ft.Text("Aa", size=tok.fs_small, color=tok.faint,
                     weight=ft.FontWeight.BOLD,
                     style=ft.TextStyle(decoration=ft.TextDecoration.LINE_THROUGH,
                                        decoration_color=tok.faint))
    return ft.Row(
        [
            swatch(_bar(tok.red, 14), S("status_absent")),
            swatch(_bar(tok.orange, 14), S("legend_late_early")),
            swatch(_bar(tok.green, 14), S("status_excused")),
            swatch(box(tint(tok.accent, 0.22), border_all(1, tok.accent)), S("legend_change")),
            swatch(struck, S("status_lesson_cancelled")),
            swatch(ft.Container(width=6, height=6, bgcolor=tok.accent,
                                border_radius=radius_all(3)), S("note_label")),
            swatch(box(None, border_all(2, tok.accent)), S("legend_now")),
        ],
        spacing=16,
        run_spacing=6,
        wrap=True,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )


def _view_toggle(state: AppState) -> ft.SegmentedButton:
    current = state.timetable_view if state.timetable_view in ("table", "list") else "table"

    def _changed(e) -> None:
        selected = list(getattr(e.control, "selected", []) or [])
        if selected:
            state.set_timetable_view(selected[0])

    return ft.SegmentedButton(
        segments=[
            ft.Segment(value="table", label=S("view_table"), icon=ft.Icons.GRID_VIEW_OUTLINED),
            ft.Segment(value="list", label=S("view_list"), icon=ft.Icons.VIEW_AGENDA_OUTLINED),
        ],
        selected=[current],
        on_change=_changed,
        show_selected_icon=False,
    )


def build(state: AppState, page: ft.Page) -> ft.Control:
    tok = state.tok
    weeks = _weeks(state.timetable())
    header = C.header_row(tok, S("timetable_title"), state.updated_label)

    if not weeks:
        empty: list = [C.empty_state(S("no_data"), tok)]
        if state.demo_mode:
            empty.append(C.txt(S("need_credentials"), tok, size=tok.fs_small, faint=True))
        return ft.Column([header, *empty], spacing=tok.gap, expand=True)

    try:
        baseline = state.stable_baseline() or {}
    except Exception:
        baseline = {}
    show_stable = (bool(getattr(state, "show_stable_timetable", False))
                   and bool(baseline))

    current = _resolve_current(weeks, state)
    mondays = sorted(weeks)
    fri = current + timedelta(days=4)
    week_label = (
        f"{S('week')} {current.isocalendar()[1]} · "
        f"{current.strftime('%d.%m.')} – {fri.strftime('%d.%m.%Y')}"
    )

    def _go(delta: int) -> None:
        # Resolve at click time: the build-time ``idx`` is stale when
        # clicks queue up before the re-render (rapid clicks) or the data
        # refreshed in between — stepping from live state never loses a week.
        try:
            fresh = _weeks(state.timetable())
        except Exception:
            fresh = weeks
        keys = sorted(fresh) if fresh else list(mondays)
        if not keys:
            return
        try:
            base = _resolve_current(fresh, state)
        except Exception:
            base = current
        at = keys.index(base) if base in keys else 0
        new_idx = max(0, min(len(keys) - 1, at + delta))
        state.go_timetable_week(keys[new_idx].isoformat())

    def _this_week() -> None:
        state.go_timetable_week(None)

    def _toggle_stable(e) -> None:
        state.set_show_stable(not show_stable)

    stable_btn = (
        C.primary_button(S("stable_view"), tok, on_click=_toggle_stable)
        if show_stable
        else C.ghost_button(S("stable_view"), tok, on_click=_toggle_stable)
    )

    if show_stable:
        today = date.today()
        monday = today - timedelta(days=today.weekday())
        week_days = stable_template_week(baseline, monday)
        nav = ft.Row(
            [
                ft.IconButton(ft.Icons.CHEVRON_LEFT, icon_size=22, disabled=True),
                C.txt(S("stable_timetable"), tok, bold=True),
                ft.IconButton(ft.Icons.CHEVRON_RIGHT, icon_size=22, disabled=True),
                C.ghost_button(S("this_week"), tok, on_click=lambda e: _this_week()),
                stable_btn,
                ft.Container(expand=True),
                _view_toggle(state),
            ],
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        )
    else:
        week_days = weeks.get(current, {})
        nav = ft.Row(
            [
                ft.IconButton(
                    ft.Icons.CHEVRON_LEFT,
                    tooltip=S("prev_week"),
                    icon_size=22,
                    on_click=lambda e: _go(-1),
                ),
                C.txt(week_label, tok, bold=True),
                ft.IconButton(
                    ft.Icons.CHEVRON_RIGHT,
                    tooltip=S("next_week"),
                    icon_size=22,
                    on_click=lambda e: _go(1),
                ),
                C.ghost_button(S("this_week"), tok, on_click=lambda e: _this_week()),
                stable_btn,
                ft.Container(expand=True),
                _view_toggle(state),
            ],
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        )
    legend = _legend(tok)
    T.offer(state, "timetable")
    nav = T.anchor(state, "tt_nav", nav)
    legend = T.anchor(state, "tt_legend", legend)

    names = _day_names()
    is_table = state.timetable_view != "list"
    if is_table:
        # Header/nav stay fixed; the grid fits the width (cells share it),
        # so only a short window ever needs to scroll — vertically.
        content: ft.Control = C.scrollable(
            state, "timetable:table",
            [_table_view(state, page, week_days, names), C.bottom_spacer(tok)],
            spacing=tok.gap, expand=True,
        )
    else:
        # Own scroll key: the list must not open at the grid's offset.
        day_cards = _list_view(state, page, week_days, names)
        content = C.scrollable(
            state, "timetable:list", day_cards + [C.bottom_spacer(tok)],
            spacing=tok.gap, expand=True,
        )

    return ft.Column(
        [
            header,
            nav,
            legend,
            content,
        ],
        spacing=tok.gap,
        expand=True,
    )
