"""Dnes — the home screen: pending excuses, next lesson, changes, lunch."""

from __future__ import annotations

from datetime import date, datetime, timedelta

import flet as ft

from strakalari.core.models import Lesson
from strakalari.core.schedule import (
    iter_changes,
    iter_notes,
    lesson_clock,
    resolve_day_lessons,
)

from .. import components as C
from .. import tutorial as T
from ..overlays import snack as show_snack
from ..state import AppState
from ..strings import S


def _snack(page: ft.Page, text: str, undo=None) -> None:
    show_snack(page, text, action_label=S("undo") if undo is not None else None,
               on_action=lambda e: undo() if undo else None)


def _undo_ignore(page: ft.Page, state: AppState, keys: list[str]) -> None:
    if not state.unignore_keys(keys):
        _snack(page, state.last_ignore_error or S("save_failed"))


def _options_for(state: AppState, kind: str) -> list[str]:
    from .planner import _templates

    return _templates(state, kind=kind)


def _one_line(tpl: str) -> str:
    return " ".join(str(tpl or "").split())


def _option_items(options: list[str]) -> list[tuple[str, str]]:
    # The whole text, never a clipped prefix: templates often share their
    # opening words and differ only further on.
    return [(str(i), _one_line(tpl) or f"{S('choose_template')} {i + 1}")
            for i, tpl in enumerate(options)]


def _choose(state: AppState, key: str, value: str | None, n: int) -> None:
    try:
        state.picked_templates[key] = max(0, min(n - 1, int(value or 0)))
    except (TypeError, ValueError):
        state.picked_templates[key] = 0


def _template_dropdown(state: AppState, key: str, options: list[str]):
    """Template dropdown + a full-text preview of the picked template.

    The closed dropdown field clips long texts to one line, so the whole
    picked text is shown under it as well.
    """
    tok = state.tok
    preview = C.txt(_picked_option(state, key, options), tok, size=tok.fs_small, muted=True)

    def _on_change(e, k=key):
        _choose(state, k, e.control.value, len(options))
        preview.value = _picked_option(state, k, options)
        try:
            preview.update()
        except Exception:
            pass

    dd = C.dropdown(
        tok, S("choose_template"), _option_items(options),
        str(state.picked_templates.get(key, 0)),
        on_change=_on_change,
    )
    dd.expand = True  # expand on the control itself, not a wrapper
    return dd, preview


def _picked_option(state: AppState, key: str, options: list[str]) -> str:
    if not options:
        return ""
    idx = state.picked_templates.get(key, 0)
    try:
        return options[max(0, min(len(options) - 1, int(idx)))]
    except (TypeError, ValueError):
        return options[0]


def _ignored_blocks(state: AppState, page: ft.Page) -> list[ft.Control]:
    """Tasks the user hid via Ignore (already excused manually)."""
    tok = state.tok
    try:
        ignored = state.ignored_tasks()
    except Exception:
        return []
    if not ignored:
        return []
    out: list[ft.Control] = [
        C.section_header(f"{S('ignored_title')} ({len(ignored)})", tok)
    ]
    for item in ignored[:12]:
        item_key = str(item.get("key", ""))

        def _restore(e, k=item_key):
            if not state.unignore_excuse(k):
                _snack(page, state.last_ignore_error or S("save_failed"))

        out.append(
            C.card(
                ft.Row(
                    [
                        ft.Column(
                            [C.txt(str(item.get("label", item_key)), tok,
                                   size=tok.fs_small, faint=True)],
                            spacing=1, expand=True, tight=True,
                        ),
                        C.ghost_button(S("restore"), tok, on_click=_restore),
                    ],
                    spacing=8,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                ),
                tok=tok,
            )
        )
    if len(ignored) > 12:
        out.append(C.txt(f"+ {len(ignored) - 12} {S('more_tasks')}", tok,
                         size=tok.fs_small, faint=True))
    return out


def _excuse_cards(state: AppState, page: ft.Page, tasks: list[dict]) -> list[ft.Control]:
    """Compact pending-excuse cards with kind badge + kind-matched templates."""
    tok = state.tok
    blocks: list[ft.Control] = [
        C.section_header(f"{S('pending_excuses')} ({len(tasks)})", tok)
    ]
    if not tasks:
        blocks.append(C.card(C.txt(S("no_data") if state.demo_mode else S("no_changes"), tok, faint=True), tok=tok))
        blocks.extend(_ignored_blocks(state, page))
        return blocks

    T.offer(state, "excuse")
    by_day: dict[str, list] = {}
    for task in tasks[:12]:
        by_day.setdefault(str(task.get("date", "")), []).append(task)
    if len(tasks) > 12:
        blocks.append(C.txt(f"+ {len(tasks) - 12} {S('more_tasks')}", tok,
                            size=tok.fs_small, faint=True))
    for day_iso, day_tasks in by_day.items():
        try:
            day_title = date.fromisoformat(day_iso).strftime("%d.%m.%Y")
        except ValueError:
            day_title = day_iso
        if len(day_tasks) > 1:
            # A whole-day excuse only when the whole day was missed;
            # otherwise the button sends lesson ranges (see day_excuse_plan).
            try:
                whole_day = bool(state.day_fully_absent(day_iso))
            except Exception:
                whole_day = False
            options = _options_for(state, "day" if whole_day else "short")
            key = f"day|{day_iso}"

            def _send_day(e, iso=day_iso, k=key, opts=options):
                if not state.submit_day_excuse(iso, _picked_option(state, k, opts), page):
                    if state.demo_mode and not state._has_credentials():
                        pass  # submit_* already toasted need_credentials
                    elif k in state.sending_excuses:
                        _snack(page, S("already_running"))
                    else:
                        _snack(page, S("excuse_failed"))
                    try:
                        page.update()
                    except Exception:
                        pass

            def _ignore_day(e, iso=day_iso):
                added = state.ignore_day(iso)
                if added:
                    _snack(page, S("ignored_msg"),
                           undo=lambda ks=list(added): _undo_ignore(page, state, ks))
                elif state.last_ignore_error:
                    _snack(page, state.last_ignore_error)

            picker, preview = _template_dropdown(state, key, options)
            blocks.append(T.anchor(state, "excuse_card",
                C.card(
                    ft.Row(
                        [
                            C.txt(day_title, tok, bold=True),
                            C.kind_badge("long" if whole_day else "short", tok),
                        ],
                        spacing=8,
                        vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    ),
                    ft.Row(
                        [
                            picker,
                            C.primary_button(S("excuse_day") if whole_day else S("excuse_all"),
                                             tok, on_click=_send_day),
                            C.ghost_button(S("ignore_day"), tok, on_click=_ignore_day),
                        ],
                        spacing=8,
                        vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    ),
                    preview,
                    tok=tok,
                )
            ))
        for task in day_tasks:
            kind = str(task.get("kind", "short")).lower()
            options = _options_for(state, kind)
            key = str(task.get("key", ""))

            def _send(e, t=task, k=key, opts=options):
                if not state.submit_excuse(t, page, template=_picked_option(state, k, opts)):
                    if state.demo_mode and not state._has_credentials():
                        pass  # submit_* already toasted need_credentials
                    elif k in state.sending_excuses:
                        _snack(page, S("already_running"))
                    else:
                        _snack(page, S("excuse_failed"))
                    try:
                        page.update()
                    except Exception:
                        pass

            def _ignore(e, t=task):
                ignored_key = state.ignore_excuse(t)
                if ignored_key:
                    _snack(page, S("ignored_msg"),
                           undo=lambda k=ignored_key: _undo_ignore(page, state, [k]))
                elif state.last_ignore_error:
                    _snack(page, state.last_ignore_error)

            picker, preview = _template_dropdown(state, key, options)
            blocks.append(T.anchor(state, "excuse_card",
                C.card(
                    ft.Row(
                        [
                            C.kind_badge(kind, tok),
                            ft.Column(
                                [C.txt(task["label"], tok, bold=True),
                                 C.txt(task.get("detail", ""), tok, size=tok.fs_small,
                                       muted=True)]
                                if task.get("detail") else
                                [C.txt(task["label"], tok, bold=True)],
                                spacing=1, expand=True, tight=True,
                            ),
                        ],
                        spacing=8,
                        vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    ),
                    ft.Row(
                        [
                            picker,
                            C.primary_button(S("excused_btn"), tok, on_click=_send),
                            C.ghost_button(S("ignore_btn"), tok, on_click=_ignore),
                        ],
                        spacing=8,
                        vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    ),
                    preview,
                    tok=tok,
                )
            ))
    blocks.extend(_ignored_blocks(state, page))
    return blocks


def _lesson_headline(parsed: Lesson) -> str:
    headline = f"{parsed.subject or '?'}"
    if parsed.period is not None:
        headline += f" · {parsed.period}. {S('period').lower()}"
    return headline


def _lesson_meta(parsed: Lesson) -> str:
    clock = lesson_clock({"time": parsed.time})
    if clock:
        time_label = f"{clock[0] // 60}:{clock[0] % 60:02d} – {clock[1] // 60}:{clock[1] % 60:02d}"
    else:
        time_label = C.short_time(str(parsed.time or ""))
    return " · ".join(p for p in (
        str(parsed.teacher or ""),
        str(parsed.room or ""),
        time_label,
    ) if p)


def _status_badge(parsed: Lesson, tok) -> ft.Control | None:
    if not parsed.status:
        return None
    label = {
        "late": S("status_late"),
        "soon": S("status_soon"),
        "early": S("status_early"),
        "absent": S("status_absent"),
        "cancelled": S("status_lesson_cancelled"),
        "excused": S("status_excused"),
    }.get(parsed.status.lower(), parsed.status)
    return C.badge(label, tok, kind=C.lesson_kind(parsed.status))


def _next_lesson_card(state: AppState, now: datetime) -> ft.Control:
    """Clock-aware: running lesson, next-up with countdown, or next school day."""
    tok = state.tok
    timetable = state.timetable()
    today = now.date()
    today_key = today.strftime("%d.%m.%Y")
    todays = [r for r in (timetable.get(today_key, []) or []) if isinstance(r, dict)]

    resolved = resolve_day_lessons(todays, now, day=today_key)
    phase = resolved["phase"]

    if phase == "running":
        parsed = Lesson.from_legacy(resolved["current"], day=today_key)
        clock = lesson_clock(resolved["current"], day=today_key)
        bits: list[ft.Control] = [
            ft.Row([C.txt(S("now_running"), tok, size=tok.fs_small, bold=True,
                          color=tok.green),
                    _status_badge(parsed, tok)] if _status_badge(parsed, tok)
                  else [C.txt(S("now_running"), tok, size=tok.fs_small, bold=True,
                              color=tok.green)],
                    spacing=6),
            C.txt(_lesson_headline(parsed), tok, bold=True, size=tok.fs_section),
            C.txt(_lesson_meta(parsed), tok, size=tok.fs_small, muted=True),
        ]
        if clock:
            left = clock[1] - (now.hour * 60 + now.minute)
            bits.append(C.txt(S("ends_in").format(m=max(1, left)), tok,
                              size=tok.fs_small, faint=True))
        if resolved.get("upcoming") is not None:
            nxt = Lesson.from_legacy(resolved["upcoming"], day=today_key)
            bits.append(C.txt(f"{S('up_next')}: {_lesson_headline(nxt)}", tok,
                              size=tok.fs_small, muted=True))
        return C.card(*bits, tok=tok)

    if phase in ("before", "between"):
        parsed = Lesson.from_legacy(resolved["upcoming"], day=today_key)
        clock = lesson_clock(resolved["upcoming"], day=today_key)
        bits = [
            C.txt(S("before_school") if phase == "before" else S("up_next"), tok,
                  size=tok.fs_small, bold=True, color=tok.accent),
            C.txt(_lesson_headline(parsed), tok, bold=True, size=tok.fs_section),
            C.txt(_lesson_meta(parsed), tok, size=tok.fs_small, muted=True),
        ]
        if clock:
            wait = clock[0] - (now.hour * 60 + now.minute)
            bits.append(C.txt(S("starts_in").format(m=max(1, wait)), tok,
                              size=tok.fs_small, faint=True))
        badge = _status_badge(parsed, tok)
        if badge is not None:
            bits.append(badge)
        return C.card(*bits, tok=tok)

    # Evening / weekend / holiday: show the next school day's first lesson.
    for ahead in range(1, 8):
        day = today + timedelta(days=ahead)
        key = day.strftime("%d.%m.%Y")
        rows = sorted(
            [r for r in (timetable.get(key, []) or []) if isinstance(r, dict)],
            key=lambda l: (lesson_clock(l, day=key) or (9999, 9999))[0],
        )
        if not rows:
            continue
        parsed = Lesson.from_legacy(rows[0], day=key)
        try:
            day_name = C.day_name(day)
        except Exception:
            day_name = ""
        return C.card(
            C.txt(f"{S('next_school_day')}: {day_name} {C.cz_day(key)}", tok,
                  size=tok.fs_small, bold=True, color=tok.accent),
            C.txt(_lesson_headline(parsed), tok, bold=True, size=tok.fs_section),
            C.txt(_lesson_meta(parsed), tok, size=tok.fs_small, muted=True),
            tok=tok,
        )
    return C.card(C.txt(S("no_data") if state.demo_mode else S("no_lessons_today"), tok, faint=True), tok=tok)


def _changes_block(state: AppState) -> list[ft.Control]:
    """Real schedule changes (diffed vs stable) + teacher notes below them."""
    tok = state.tok
    try:
        baseline = state.stable_baseline()
        complete = getattr(state, "stable_complete", None)
        complete = bool(complete() if callable(complete) else complete)
        changes = iter_changes(state.timetable(), baseline, complete=complete)
        notes = iter_notes(state.timetable(), baseline, complete=complete)
    except Exception:
        changes, notes = [], []
    # Only this week, in timetable order (day, then lesson).
    monday = date.today() - timedelta(days=date.today().weekday())
    sunday = monday + timedelta(days=6)

    def _order(item) -> tuple:
        period = Lesson.from_legacy(item.get("lesson") or {}, day=item.get("day_key")).period
        return (item["day"], period if period is not None else 99)

    week_changes = sorted((c for c in changes
                           if c.get("day") is not None and monday <= c["day"] <= sunday),
                          key=_order)[:5]
    blocks: list[ft.Control] = [
        C.section_header(f"{S('week_changes')} ({len(week_changes)})", tok)
    ]
    if not week_changes:
        blocks.append(C.card(C.txt(S("no_data") if state.demo_mode else S("no_changes"), tok, faint=True), tok=tok))
    for item in week_changes:
        parsed = Lesson.from_legacy(item["lesson"], day=item["day_key"])
        title = f"{parsed.subject or '?'} — {C.cz_day(item['day_key'])}"
        if parsed.period is not None:
            title += f" · {parsed.period}."
        row: list[ft.Control] = [
            ft.Column(
                [C.txt(title, tok, bold=True, size=tok.fs_small),
                 C.txt(item["diff"].note, tok, size=tok.fs_small, muted=True)]
                if item["diff"].note else
                [C.txt(title, tok, bold=True, size=tok.fs_small)],
                spacing=1, expand=True, tight=True,
            ),
            C.change_badge(tok, tooltip=item["diff"].note),
        ]
        blocks.append(C.card(ft.Row(row, spacing=8,
                                    vertical_alignment=ft.CrossAxisAlignment.CENTER),
                             tok=tok))
    week_notes = sorted((n for n in notes
                         if n.get("day") is not None and monday <= n["day"] <= sunday),
                        key=_order)[:3]
    if week_notes:
        blocks.append(C.section_header(
            f"{S('notes_title')} ({len(week_notes)})", tok))
    for item in week_notes:
        parsed = Lesson.from_legacy(item["lesson"], day=item["day_key"])
        blocks.append(
            C.card(
                ft.Row(
                    [
                        C.note_dot(tok),
                        C.txt(f"{parsed.subject or '?'} — {C.cz_day(item['day_key'])}: "
                              f"{item['diff'].note}", tok, size=tok.fs_small, muted=True),
                    ],
                    spacing=6,
                    vertical_alignment=ft.CrossAxisAlignment.START,
                ),
                tok=tok,
            )
        )
    return blocks


def build(state: AppState, page: ft.Page, now: datetime | None = None) -> ft.Control:
    tok = state.tok
    now = now or datetime.now()
    blocks: list[ft.Control] = [C.header_row(tok, S("today_title"), state.updated_label)]

    if state.demo_mode:
        blocks.append(
            C.card(
                C.txt(S("setup_needed"), tok, muted=True),
                ft.Row(
                    [
                        C.primary_button(
                            S("refresh_data"), tok,
                            on_click=lambda e: (
                                state.start_refresh("all")
                                or _snack(page, S("already_running"))
                            ),
                            icon=ft.Icons.REFRESH,
                        ),
                        C.ghost_button(
                            S("go_to_settings"), tok,
                            on_click=lambda e: state.go("settings"),
                        ),
                    ],
                    spacing=8,
                    wrap=True,
                ),
                tok=tok,
            )
        )

    blocks.extend(_excuse_cards(state, page, state.excuse_tasks()))

    blocks.append(C.section_header(S("next_lesson"), tok))
    blocks.append(_next_lesson_card(state, now))

    blocks.extend(_changes_block(state))

    # -- lunch today ---------------------------------------------------------
    blocks.append(C.section_header(S("lunch_today"), tok))
    today_key = now.date().strftime("%d.%m.%Y")
    menu = state.food().get(today_key, {})
    order = state.orders.get(today_key) or state.web_orders.get(today_key)
    if today_key in state.cancelled_lunches or "&-1&" in str(order or ""):
        lunch_text = S("no_lunch")
    elif order:
        lunch_text = f"{S('ordered')}: {menu.get(order, order)}"
    elif menu:
        lunch_text = ", ".join(list(menu.values())[:3])
    else:
        lunch_text = S("no_data") if state.demo_mode else S("no_lunch")
    blocks.append(C.card(C.txt(lunch_text, tok), tok=tok))
    blocks.extend(_planner_tip(state, now))
    blocks.append(C.bottom_spacer(tok))

    return C.scrollable(state, "today", blocks, spacing=tok.gap, expand=True)


def _planner_tip(state: AppState, now: datetime) -> list[ft.Control]:
    """The planner's next recommended day off, when it is within two weeks."""
    tok = state.tok
    if state.demo_mode:
        return []
    try:
        term = state.year_plan(now).default_term
        upcoming = [o for o in (term.recommended if term else [])
                    if o.day <= now.date() + timedelta(days=14)]
    except Exception:
        return []
    if not upcoming:
        return []
    option = upcoming[0]
    label = f"{C.day_name(option.day)} {C.cz_day(option.day)}"
    return [
        C.section_header(S("planner_suggestion"), tok),
        C.card(ft.Row(
            [
                ft.Icon(ft.Icons.BEACH_ACCESS_OUTLINED, color=tok.green, size=20),
                C.txt(S("planner_next").format(day=label), tok, bold=True),
                ft.Container(expand=True),
                C.ghost_button(S("nav_planner"), tok, on_click=lambda e: state.go("planner")),
            ],
            spacing=tok.gap, vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ), tok=tok),
    ]
