"""Plánovač — a balanced, year-aware plan of days off.

The per-subject forecast lives in the Absences tab; this view is the
planner: how many whole days each semester can still afford, a
recommended plan spread evenly up to the absence closure, a clickable
semester overview, per-subject budgets and the persisted planned days
off. Every plan dialog previews its effect on the limits. Same-day
planning is clock-aware — a day whose lessons already started can't be
planned.
"""

from __future__ import annotations

from datetime import date, datetime, timedelta

import flet as ft

from strakalari.core.helpers import template_name, template_text
from strakalari.core.models import Lesson, parse_cz_date
from strakalari.core.planned_skips import entry_end_iso, entry_start_iso, normalize_planned_entry
from strakalari.core.schedule import future_lessons

from .. import components as C
from .. import tutorial as T
from ..overlays import close_dialog, show_dialog, snack
from ..state import AppState
from ..strings import S
from ..theme import border_all, radius_all, tint


def _templates(state: AppState, kind: str | None = None) -> list[str]:
    """Excuse template texts, optionally filtered to the task kind."""
    return [text for _name, text in _template_options(state, kind)]


def _template_labels(options: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Dropdown items for template options: the user's name for each one,
    "Šablona N" for unnamed ones (the full text is shown under the
    dropdown, so repeating it in the field is just noise)."""
    return [(str(i), name or f"{S('template_n')} {i + 1}")
            for i, (name, _text) in enumerate(options)]


def _template_options(state: AppState, kind: str | None = None) -> list[tuple[str, str]]:
    """Excuse templates as ``(name, text)``, optionally filtered to the task kind.

    kind: "late" -> late_income_excuses, "soon"/"early" ->
    left_soon_excuses, "short" -> short_absence,
    "long"/"day" -> long_absence. Falls back to all templates when the
    kind-specific list is empty, so there is always something to pick.
    The name is "" for unnamed templates.
    """
    kind = str(kind or "").lower()
    keys: tuple[str, ...]
    if kind == "late":
        keys = ("late_income_excuses",)
    elif kind in ("soon", "early"):
        keys = ("left_soon_excuses",)
    elif kind == "short":
        keys = ("short_absence_excuses",)
    elif kind in ("long", "day"):
        keys = ("long_absence_excuses",)
    else:
        keys = ("long_absence_excuses", "short_absence_excuses",
                "late_income_excuses", "left_soon_excuses")
    def _collect(list_keys) -> list[tuple[str, str]]:
        out: list[tuple[str, str]] = []
        for key in list_keys:
            values = state.get(key, [])
            if isinstance(values, list):
                out.extend((template_name(v), template_text(v)) for v in values
                           if template_text(v).strip())
        return out

    found = _collect(keys)
    if not found and len(keys) == 1:
        found = _collect(("long_absence_excuses", "short_absence_excuses",
                          "late_income_excuses", "left_soon_excuses"))
    signature = str(state.get("your_signature", "")).strip()
    if signature:
        # Never duplicate a signature the template already ends with
        # (case-insensitive, mirroring format_excuse_template).
        found = [(name, tpl if signature.lower() in tpl.lower()
                  else f"{tpl.rstrip()}\n{signature}")
                 for name, tpl in found]
    return found or [("", S("default_excuse_template"))]


def _push(page: ft.Page, dlg: ft.AlertDialog | None = None) -> None:
    """Repaints after a dialog-local change (preview text, notes, errors).

    Dialogs live in the page's dialog stack, so ``page.update()`` alone
    does not reliably repaint an open AlertDialog — nudge the dialog
    itself first, then the page. Everything guarded: test doubles and
    unmounted dialogs may lack either.
    """
    for target in (dlg, page):
        if target is None:
            continue
        try:
            target.update()
        except Exception:
            pass


def _dropdown_value(e) -> str | None:
    """Selected dropdown key, tolerant to event payload shapes.

    Normally ``e.control.value``; falls back to ``e.data`` when the
    control reference carries no value (older payloads / test doubles).
    """
    try:
        raw = getattr(getattr(e, "control", None), "value", None)
    except Exception:
        raw = None
    if raw is None:
        try:
            raw = getattr(e, "data", None)
        except Exception:
            raw = None
    return raw


def _day_lessons(state: AppState, day: date) -> list[dict]:
    key = day.strftime("%d.%m.%Y")
    lessons = state.timetable().get(key, []) or []
    return [r for r in lessons if isinstance(r, dict)]


def _plannable_days(state: AppState, days: list[date], now: datetime) -> list[date]:
    """Upcoming school days that can still be planned (clock-aware).

    Past days are dropped; today is kept only while at least one lesson
    (or one clock-less row) hasn't started yet.
    """
    out: list[date] = []
    for day in days:
        if day < now.date():
            continue
        if day == now.date() and not future_lessons(_day_lessons(state, day), now,
                                                    day=day.strftime("%d.%m.%Y")):
            continue
        out.append(day)
    return out


def _days_text(n: int) -> str:
    """'1 den' / '3 dny' / '5 dní' (Czech plural rules; English 1/other)."""
    n = int(n)
    if n == 1:
        return S("days_one").format(n=n)
    if 2 <= n <= 4:
        return S("days_few").format(n=n)
    return S("days_many").format(n=n)


def _hours(value: float) -> str:
    """Budget hours for display: floored, never negative ('3', '0')."""
    import math

    return str(max(0, int(math.floor(float(value) + 1e-9))))


def _term_title(term) -> str:
    return S("term_sem1") if term.key == "sem1" else S("term_sem2")


def _impact_controls(state: AppState, impacts: list) -> list[ft.Control]:
    """'Effect on limits' preview rows for a prospective skip.

    ``impacts`` is ``[(term, [ImpactRow, ...]), ...]`` (see
    ``AppState.plan_impact``). Returns [] when nothing is known, so
    dialogs built on test doubles stay unchanged.
    """
    tok = state.tok
    if not impacts:
        return []
    out: list[ft.Control] = [C.txt(S("impact_title"), tok, size=tok.fs_small, bold=True)]
    worst = "ok"
    any_rows = False
    for term, rows in impacts:
        if len(impacts) > 1:
            out.append(C.txt(_term_title(term), tok, size=tok.fs_tiny, faint=True))
        for row in rows:
            any_rows = True
            color = {"over": tok.red, "reserve": tok.yellow}.get(row.level, tok.muted)
            if row.level == "over" or (row.level == "reserve" and worst == "ok"):
                worst = row.level
            out.append(C.txt(
                S("impact_row").format(name=row.name, cost=row.cost,
                                       left=_hours(row.free_after),
                                       p=f"{row.projected_after:.1f}"),
                tok, size=tok.fs_small, color=color))
    if not any_rows:
        out.append(C.txt(S("impact_none"), tok, size=tok.fs_small, color=tok.green))
        return out
    verdict_color = {"over": tok.red, "reserve": tok.yellow}.get(worst, tok.green)
    out.append(C.txt(S({"over": "impact_over", "reserve": "impact_reserve"}.get(worst, "impact_ok")),
                     tok, size=tok.fs_small, bold=True, color=verdict_color))
    return out


def _state_impact(state: AppState, start_iso: str, end_iso: str,
                  start_p: int | None = None, end_p: int | None = None) -> list:
    fn = getattr(state, "plan_impact", None)
    if fn is None:
        return []
    try:
        return fn(start_iso, end_iso, start_p, end_p)
    except Exception:
        return []


def _plan_dialog(state: AppState, page: ft.Page, day_iso: str, day_label: str) -> None:
    tok = state.tok
    named = _template_options(state, kind="day")
    options = [text for _name, text in named]
    picked = {"idx": 0}
    preview = ft.Text(options[0], size=tok.fs_small, color=tok.muted,
                      selectable=True)

    def _picked(e):
        try:
            idx = int(_dropdown_value(e) or 0)
        except (TypeError, ValueError):
            idx = 0
        picked["idx"] = max(0, min(len(options) - 1, idx))
        preview.value = options[picked["idx"]]
        _push(page, dlg)

    choice = C.dropdown(
        tok, S("choose_template"),
        _template_labels(named),
        "0",
        on_change=_picked,
    )

    strava_on = state.strava_enabled()
    cancel_pick = {"value": True}
    lunch_rows: list = []
    if strava_on:
        try:
            _cz_day = date.fromisoformat(str(day_iso or "")).strftime("%d.%m.%Y")
        except ValueError:
            _cz_day = day_label
        try:
            order_open = state.is_lunch_order_open(_cz_day)
        except Exception:
            order_open = True
        if order_open:
            def _on_cancel_pick(e):
                cancel_pick["value"] = bool(e.control.value)

            lunch_rows.append(C.toggle(tok, S("plan_cancel_lunch"), True,
                                       on_change=_on_cancel_pick))
        else:
            cancel_pick["value"] = False
            try:
                deadline = state.lunch_order_deadline(_cz_day)
                detail = (deadline.strftime("%d.%m.%Y %H:%M")
                          if deadline is not None else "")
            except Exception:
                detail = ""
            lunch_rows.append(C.txt(
                S("lunch_cannot_cancel").format(deadline=detail or "—"),
                tok, size=tok.fs_small, color=tok.yellow))

    def _confirm(e):
        idx = max(0, min(len(options) - 1, picked["idx"]))
        if state.plan_skip(day_iso, options[idx],
                           cancel_lunch=cancel_pick["value"]):
            close_dialog(page, dlg)
            try:
                page.update()
            except Exception:
                pass
            snack(page, S("skip_planned"))
        else:
            snack(page, S("skip_not_planned"))
        try:
            page.update()
        except Exception:
            pass

    content_rows: list = [choice, preview]
    content_rows.extend(lunch_rows)
    impact = _impact_controls(state, _state_impact(state, day_iso, day_iso))
    if impact:
        content_rows.append(C.divider(tok))
        content_rows.extend(impact)
    dlg = ft.AlertDialog(
        title=ft.Text(f"{S('plan_skip')}: {day_label}"),
        content=ft.Column(
            content_rows,
            tight=True,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        ),
        actions=[
            ft.TextButton(S("cancel"), on_click=lambda e: close_dialog(page, dlg)),
            ft.Button(S("confirm"), on_click=_confirm),
        ],
    )
    show_dialog(page, dlg)


def _any_day_open(state: AppState, start: date, end: date) -> bool:
    """True when at least one day in [start, end] is still order-open."""
    cursor = start
    while cursor <= end:
        try:
            if state.is_lunch_order_open(cursor.strftime("%d.%m.%Y")):
                return True
        except Exception:
            pass
        cursor += timedelta(days=1)
    return False


def _max_period(state: AppState) -> int:
    """Highest period number seen in the timetable (min 8 for free input)."""
    top = 0
    try:
        for lessons in state.timetable().values():
            for raw in lessons or []:
                if not isinstance(raw, dict):
                    continue
                try:
                    period = Lesson.from_legacy(raw).period
                except Exception:
                    period = None
                if isinstance(period, int) and period > top:
                    top = period
    except Exception:
        pass
    return max(8, top)


def _period_label(start_period: int | None, end_period: int | None) -> str:
    if start_period is None and end_period is None:
        return S("whole_day")
    if start_period is not None and end_period is not None:
        if start_period == end_period:
            return f"{start_period}."
        return f"{start_period}.–{end_period}."
    if start_period is not None:
        return f"{S('custom_from_lesson')} {start_period}."
    return f"{S('custom_to_lesson')} {end_period}."


def _entry_label(entry: dict) -> str:
    """'Mon 15.09.2026' / '15.09. – 17.09.' + optional period range."""
    try:
        start = date.fromisoformat(entry_start_iso(entry))
        end = date.fromisoformat(entry_end_iso(entry))
    except ValueError:
        return entry_start_iso(entry) or "?"
    if start == end:
        base = f"{C.day_name(start)} {start.strftime('%d.%m.%Y')}"
    else:
        base = f"{start.strftime('%d.%m.%Y')} – {end.strftime('%d.%m.%Y')}"
    try:
        start_p = entry.get("start_period")
        end_p = entry.get("end_period")
        start_p = int(start_p) if start_p is not None else None
        end_p = int(end_p) if end_p is not None else None
    except (TypeError, ValueError):
        start_p, end_p = None, None
    if start_p is None and end_p is None:
        return base
    return f"{base} · {_period_label(start_p, end_p)}"


def _custom_plan_dialog(state: AppState, page: ft.Page, now: datetime) -> None:
    tok = state.tok
    named = _template_options(state, kind="day")
    options = [text for _name, text in named]
    picked = {"template": 0, "from": "whole", "to": "whole"}
    default_start = (now.date() + timedelta(days=1)).strftime("%d.%m.%Y")
    try:
        _states, _days = state.subject_states()
        plannable = _plannable_days(state, sorted(_days), now)
        if plannable:
            default_start = plannable[0].strftime("%d.%m.%Y")
    except Exception:
        pass
    start_field = ft.TextField(label=S("cal_from"), value=default_start,
                               hint_text=S("date_hint"))
    end_field = ft.TextField(label=S("cal_to"), value=default_start,
                             hint_text=S("date_hint"))
    preview = ft.Text(options[0], size=tok.fs_small, color=tok.muted,
                      selectable=True)
    summary = C.txt("", tok, size=tok.fs_small, muted=True)
    error = C.txt("", tok, size=tok.fs_small, color=tok.red)
    max_p = _max_period(state)
    lesson_opts = [("whole", S("whole_day"))] + [(str(i), str(i)) for i in range(0, max_p + 1)]

    def _selection() -> tuple[date | None, date | None, int | None, int | None]:
        start = parse_cz_date((start_field.value or "").strip())
        end = parse_cz_date((end_field.value or "").strip())
        try:
            start_p = None if picked["from"] == "whole" else int(picked["from"])
        except (TypeError, ValueError):
            start_p = None
        try:
            end_p = None if picked["to"] == "whole" else int(picked["to"])
        except (TypeError, ValueError):
            end_p = None
        return start, end, start_p, end_p

    def _refresh_summary() -> None:
        start, end, start_p, end_p = _selection()
        if start is None or end is None:
            summary.value = S("plan_custom_hint")
        else:
            summary.value = (f"{start.strftime('%d.%m.%Y')} – "
                             f"{end.strftime('%d.%m.%Y')} · "
                             f"{_period_label(start_p, end_p)}")
        try:
            page.update()
        except Exception:
            pass

    def _on_select(key: str):
        def _handle(e):
            picked[key] = str(_dropdown_value(e)
                              or ("0" if key == "template" else "whole"))
            if key == "template":
                try:
                    preview.value = options[max(0, min(len(options) - 1, int(picked["template"])))]
                except (TypeError, ValueError):
                    preview.value = options[0]
            _refresh_summary()
        return _handle

    from_dd = C.dropdown(tok, S("custom_from_lesson"), lesson_opts, "whole",
                         on_change=_on_select("from"))
    to_dd = C.dropdown(tok, S("custom_to_lesson"), lesson_opts, "whole",
                       on_change=_on_select("to"))
    choice = C.dropdown(
        tok, S("choose_template"),
        _template_labels(named),
        "0",
        on_change=_on_select("template"),
    )
    start_field.on_change = lambda e: _refresh_summary()
    end_field.on_change = lambda e: _refresh_summary()

    strava_on = state.strava_enabled()
    cancel_pick = {"value": True}
    lunch_rows: list = []

    def _on_cancel_pick(e):
        cancel_pick["value"] = bool(e.control.value)
        _refresh_lunch_note()

    if strava_on:
        lunch_rows.append(C.toggle(tok, S("plan_cancel_lunch"), True,
                                   on_change=_on_cancel_pick))
    lunch_note = C.txt("", tok, size=tok.fs_small, color=tok.yellow)

    def _refresh_lunch_note() -> None:
        if not strava_on:
            lunch_note.value = ""
            return
        if not cancel_pick["value"]:
            lunch_note.value = ""
            _push(page, dlg)
            return
        start, end, _sp, _ep = _selection()
        if start is None or end is None:
            lunch_note.value = ""
            return
        try:
            if not _any_day_open(state, start, end):
                deadline = state.lunch_order_deadline(start.strftime("%d.%m.%Y"))
                detail = (deadline.strftime("%d.%m.%Y %H:%M")
                          if deadline is not None else "")
                lunch_note.value = S("lunch_cannot_cancel").format(deadline=detail or "—")
            else:
                lunch_note.value = ""
        except Exception:
            lunch_note.value = ""
        _push(page, dlg)

    impact_box = ft.Column([], spacing=2, tight=True)

    def _refresh_impact() -> None:
        start, end, start_p, end_p = _selection()
        if start is None or end is None or end < start or (end - start).days > 31:
            impact_box.controls = []
            return
        impact_box.controls = _impact_controls(
            state, _state_impact(state, start.isoformat(), end.isoformat(), start_p, end_p))

    _orig_refresh = _refresh_summary

    def _refresh_summary() -> None:
        _orig_refresh()
        _refresh_lunch_note()
        _refresh_impact()
        _push(page, dlg)

    def _confirm(e):
        start, end, start_p, end_p = _selection()
        valid = (
            start is not None and end is not None
            and end >= start and (end - start).days <= 31
            and start >= now.date()
            and not (start == end and start_p is not None and end_p is not None
                     and end_p < start_p)
        )
        if not valid:
            error.value = S("custom_invalid")
            _push(page, dlg)
            return
        try:
            idx = max(0, min(len(options) - 1, int(picked["template"])))
        except (TypeError, ValueError):
            idx = 0
        want_cancel = bool(cancel_pick["value"]) and strava_on
        if want_cancel:
            try:
                # One closed day (e.g. tomorrow past its cutoff) must not
                # disable cancellation for the still-open rest of the range;
                # plan_custom_skip itself skips closed days individually.
                want_cancel = _any_day_open(state, start, end)
            except Exception:
                pass
        ok = state.plan_custom_skip(start.isoformat(), end.isoformat(),
                                    start_p, end_p, options[idx],
                                    cancel_lunch=want_cancel)
        if not ok:
            error.value = S("custom_invalid")
            _push(page, dlg)
            return
        close_dialog(page, dlg)
        snack(page, S("skip_planned"))
        try:
            page.update()
        except Exception:
            pass

    content_rows = [start_field, end_field, from_dd, to_dd, choice, preview,
                    summary, error]
    content_rows.extend(lunch_rows)
    content_rows.append(lunch_note)
    content_rows.append(impact_box)
    dlg = ft.AlertDialog(
        title=ft.Text(S("plan_custom")),
        content=ft.Column(
            content_rows,
            tight=True,
            scroll=ft.ScrollMode.AUTO,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        ),
        actions=[
            ft.TextButton(S("cancel"), on_click=lambda e: close_dialog(page, dlg)),
            ft.Button(S("confirm"), on_click=_confirm),
        ],
    )
    _refresh_summary()
    show_dialog(page, dlg)


# -- year plan UI -------------------------------------------------------------

def _day_label(day: date) -> str:
    return f"{C.day_name(day)} {day.strftime('%d.%m.%Y')}"


def _tag_badges(state: AppState, option) -> list[ft.Control]:
    tok = state.tok
    out: list[ft.Control] = []
    for tag in option.tags:
        if tag == "bridge":
            out.append(C.badge(S("tag_bridge").format(n=option.streak), tok, kind="sent"))
        elif tag == "long_weekend":
            out.append(C.badge(S("tag_long_weekend"), tok, kind="ok"))
        elif tag == "light":
            out.append(C.badge(S("tag_light"), tok, kind="info"))
        elif tag == "free":
            out.append(C.badge(S("tag_free"), tok, kind="ok"))
        elif tag == "final_week":
            out.append(C.badge(S("tag_final_week"), tok, kind="warning"))
        elif tag == "late_week":
            out.append(C.badge(S("tag_late_week"), tok, kind="pending"))
    return out


def _cost_text(option) -> str:
    lessons = f"{option.lessons_count} {S('lessons_count')}"
    if not option.cost:
        return f"{lessons} · {S('day_cost_free')}"
    return f"{lessons} · {S('day_cost').format(n=option.budget_hours)}"


def _subjects_text(names: list[str], limit: int = 6) -> str:
    unique = sorted(set(n for n in names if str(n).strip()))
    if len(unique) > limit:
        return "; ".join(unique[:limit]) + " …"
    return "; ".join(unique)


def _term_switcher(state: AppState, plan, term) -> ft.Control | None:
    if len(plan.terms) < 2:
        return None
    tok = state.tok
    buttons: list[ft.Control] = []
    for other in plan.terms:
        label = f"{_term_title(other)} · {S('term_until').format(d=C.cz_day(other.close))}"

        def _pick(e, key=other.key):
            state.select_planner_term(key)

        if other.key == term.key:
            buttons.append(C.primary_button(label, tok, on_click=_pick))
        else:
            buttons.append(C.ghost_button(label, tok, on_click=_pick))
    return ft.Row(buttons, spacing=tok.gap // 2, wrap=True)


def _stats_row(state: AppState, term) -> ft.Control:
    tok = state.tok
    planned_days = len(term.planned_dates & set(term.remaining_days))
    planned_hours = sum(p.hours for p in term.planned)
    tight = term.tightest
    tight_label, tight_value, tight_kind = S("stat_tightest"), "—", "info"
    if tight is not None:
        tight_label = f"{S('stat_tightest')} · {S('hours_free').format(n=_hours(tight.free))}"
        tight_value = tight.name
        tight_kind = {"over": "critical", "reserve": "warning", "tight": "warning"}.get(
            tight.status, "ok")
    tight_card = C.stat_card(tight_label, tight_value, tok, kind=tight_kind)
    try:
        # Long subject names stay on one line (full name in the tooltip).
        value_text = tight_card.content.controls[1]
        value_text.max_lines = 1
        value_text.overflow = ft.TextOverflow.ELLIPSIS
        tight_card.tooltip = tight_value
    except Exception:
        pass
    cap_kind = "ok" if term.capacity > 0 else "warning"
    return ft.Row(
        [
            C.stat_card(S("stat_can_afford"), _days_text(term.capacity), tok, kind=cap_kind),
            C.stat_card(S("stat_planned"),
                        f"{_days_text(planned_days)} · {planned_hours} h", tok,
                        kind="sent" if planned_days else "info"),
            tight_card,
            C.stat_card(S("planner_horizon"), str(len(term.remaining_days)), tok),
        ],
        spacing=tok.gap,
    )


def _warnings(state: AppState, term) -> list[ft.Control]:
    tok = state.tok
    budgets = term.budget_by_canon
    over = sorted({budgets[c].name for p in term.planned for c in p.over if c in budgets})
    reserve = sorted({budgets[c].name for p in term.planned for c in p.reserve if c in budgets}
                     - set(over))
    fast = sorted(b.name for b in term.fast_pace)
    out: list[ft.Control] = []
    if over:
        out.append(C.txt(S("warn_over").format(subjects=", ".join(over)), tok,
                         size=tok.fs_small, color=tok.red))
    if reserve:
        out.append(C.txt(S("warn_reserve").format(subjects=", ".join(reserve)), tok,
                         size=tok.fs_small, color=tok.yellow))
    if fast:
        out.append(C.txt(S("warn_pace").format(subjects=", ".join(fast)), tok,
                         size=tok.fs_small, color=tok.yellow))
    return [C.card(*out, tok=tok)] if out else []


def _planned_entry_for(state: AppState, day: date) -> dict | None:
    try:
        return state.planned_for(day.isoformat())
    except Exception:
        return None


def _calendar_cell(state: AppState, page: ft.Page, plan, term, day: date,
                   recommended: set[date], over_days: set[date], now: datetime) -> ft.Control:
    tok = state.tok
    size = 18  # height; the width stretches with the week column
    if day < term.start or day > term.close:
        return ft.Container(height=size)
    option = term.options.get(day)
    is_free = day in plan.holidays
    is_planned = day in term.planned_dates
    past = day < plan.first_day
    lessons = plan.lessons_on(day)
    label = f"{C.day_name(day, short=True)} {C.cz_day(day)}"
    fill: str | None
    border: str | None
    if is_free:
        tip = f"{label} · {plan.free_labels.get(day) or S('cal_tip_free')}"
        fill, border = None, tok.border
    elif is_planned:
        tip = f"{label} · {S('cal_tip_planned')}"
        fill = tok.red if day in over_days else tok.accent
        border = None
        if past:
            fill = tint(fill, 0.45)
    elif past:
        tip = f"{label} · {S('cal_tip_past')}"
        fill, border = tint(tok.overlay, 0.55), None
    elif option is None:
        tip = f"{label} · {len(lessons)} {S('lessons_count')}" if lessons else label
        fill, border = tok.overlay, None
    elif not option.feasible:
        names = ", ".join(sorted(option.names.get(c, c) for c in option.blocked_by))
        tip = f"{label} · {_cost_text(option)}\n{S('cal_tip_blocked').format(subjects=names)}"
        fill, border = tint(tok.red, 0.35), None
    elif day in recommended:
        tip = (f"{label} · {_cost_text(option)}\n"
               f"{S('cal_tip_recommended').format(h=option.budget_hours)}")
        fill, border = tok.green, None
    else:
        tip = f"{label} · {_cost_text(option)}\n{S('cal_tip_fits').format(h=option.budget_hours)}"
        fill, border = tok.overlay, None
    if option is not None and option.final_week and not is_planned:
        tip += f"\n{S('cal_tip_final')}"
    if day == now.date():
        border = tok.text
    on_click = None
    if is_planned and not past:
        entry = _planned_entry_for(state, day)
        if entry is not None:
            on_click = (lambda e, ent=dict(entry): _planned_dialog(state, page, ent))
    elif option is not None and not past:
        on_click = (lambda e, d=day: _plan_dialog(state, page, d.isoformat(), _day_label(d)))
    return ft.Container(
        height=size,
        bgcolor=fill,
        border=border_all(2 if day == now.date() else 1, border) if border else None,
        border_radius=radius_all(3),
        tooltip=tip,
        on_click=on_click,
    )


def _calendar_strip(state: AppState, page: ft.Page, plan, term, now: datetime) -> ft.Control:
    """GitHub-style strip: one column per week (Mon–Fri), whole term."""
    tok = state.tok
    recommended = {o.day for o in term.recommended}
    over_days: set[date] = set()
    for row in term.planned:
        if row.over:
            over_days.update(row.days)
    first_monday = term.start - timedelta(days=term.start.weekday())
    monday = first_monday
    columns: list[ft.Control] = []
    last_month = None
    while monday <= term.close:
        month_label = ""
        week_days = [monday + timedelta(days=i) for i in range(5)]
        in_term = [d for d in week_days if term.start <= d <= term.close]
        if in_term and in_term[0].month != last_month:
            last_month = in_term[0].month
            month_label = f"{in_term[0].month}."
        cells = [_calendar_cell(state, page, plan, term, d, recommended, over_days, now)
                 for d in week_days]
        columns.append(ft.Column(
            [ft.Container(content=C.txt(month_label, tok, size=tok.fs_tiny, faint=True),
                          height=16)] + cells,
            spacing=4, tight=True, expand=1,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        ))
        monday += timedelta(days=7)
    day_names = ft.Column(
        [ft.Container(height=16)] + [
            ft.Container(content=C.txt(C.day_name(first_monday + timedelta(days=i), short=True),
                                       tok, size=tok.fs_tiny, faint=True),
                         height=18, width=24, alignment=ft.Alignment(-1, 0))
            for i in range(5)],
        spacing=4, tight=True,
    )
    strip = ft.Row([day_names] + columns, spacing=4,
                   vertical_alignment=ft.CrossAxisAlignment.START)

    def _legend(color: str | None, label: str, border: str | None = None) -> ft.Control:
        return ft.Row([
            ft.Container(width=12, height=12, bgcolor=color, border_radius=radius_all(3),
                         border=border_all(1, border) if border else None),
            C.txt(label, tok, size=tok.fs_tiny, muted=True),
        ], spacing=4, tight=True)

    legend = ft.Row([
        _legend(tok.overlay, S("legend_school")),
        _legend(None, S("legend_free"), tok.border),
        _legend(tok.green, S("legend_recommended")),
        _legend(tok.accent, S("legend_planned")),
        _legend(tint(tok.red, 0.35), S("legend_blocked")),
        _legend(None, S("legend_today"), tok.text),
    ], spacing=tok.gap, wrap=True)
    return T.anchor(state, "plan_strip", C.card(
        strip, legend, C.txt(S("overview_hint"), tok, size=tok.fs_small, faint=True), tok=tok))


def _target_dropdown(state: AppState, term) -> ft.Control:
    tok = state.tok
    already = len(term.planned_dates & set(term.remaining_days))
    maximum = already + term.capacity
    current = state.planner_target_days()
    top = max(maximum, current, 1)
    options = [("0", S("target_auto").format(n=maximum))]
    options += [(str(i), _days_text(i)) for i in range(1, min(top, 60) + 1)]

    def _changed(e):
        try:
            value = int(_dropdown_value(e) or 0)
        except (TypeError, ValueError):
            value = 0
        if value != state.planner_target_days():
            state.set_planner_target(value)

    dd = C.dropdown(tok, S("target_label"), options, str(current if current <= min(top, 60) else 0),
                    on_change=_changed)
    dd.width = 230
    return dd


def _plan_all_dialog(state: AppState, page: ft.Page, days: list[date]) -> None:
    tok = state.tok
    named = _template_options(state, kind="day")
    options = [text for _name, text in named]
    picked = {"idx": 0, "cancel": True}
    preview = ft.Text(options[0], size=tok.fs_small, color=tok.muted, selectable=True)

    def _picked(e):
        try:
            idx = int(_dropdown_value(e) or 0)
        except (TypeError, ValueError):
            idx = 0
        picked["idx"] = max(0, min(len(options) - 1, idx))
        preview.value = options[picked["idx"]]
        _push(page, dlg)

    choice = C.dropdown(
        tok, S("choose_template"),
        _template_labels(named),
        "0", on_change=_picked)
    listing = ", ".join(f"{C.day_name(d, short=True)} {C.cz_day(d)}" for d in days)
    rows: list = [C.txt(S("plan_all_body").format(days=listing), tok, size=tok.fs_small),
                  choice, preview]
    if state.strava_enabled():
        def _on_cancel(e):
            picked["cancel"] = bool(e.control.value)

        rows.append(C.toggle(tok, S("plan_cancel_lunch"), True, on_change=_on_cancel))

    def _confirm(e):
        n = state.plan_days([d.isoformat() for d in days], options[picked["idx"]],
                            cancel_lunch=bool(picked["cancel"]))
        close_dialog(page, dlg)
        snack(page, S("plan_all_done").format(n=n) if n else S("skip_not_planned"))

    dlg = ft.AlertDialog(
        title=ft.Text(S("plan_all_title")),
        content=ft.Column(rows, tight=True, scroll=ft.ScrollMode.AUTO,
                          horizontal_alignment=ft.CrossAxisAlignment.STRETCH),
        actions=[
            ft.TextButton(S("cancel"), on_click=lambda e: close_dialog(page, dlg)),
            ft.Button(S("confirm"), on_click=_confirm),
        ],
    )
    show_dialog(page, dlg)


def _planned_dialog(state: AppState, page: ft.Page, entry: dict) -> None:
    """A planned day from the overview: what it holds, remove it."""
    tok = state.tok
    rows: list = []
    template = str(entry.get("template", "")).strip()
    if template:
        rows.append(C.txt(template.split("\n")[0][:120], tok, size=tok.fs_small, muted=True))

    def _remove(e):
        close_dialog(page, dlg)
        snack(page, S("plan_removed") if state.unplan_entry(entry) else S("save_failed"))

    dlg = ft.AlertDialog(
        title=ft.Text(_entry_label(entry)),
        content=ft.Column(rows or [C.txt(S("legend_planned"), tok)], tight=True),
        actions=[
            ft.TextButton(S("cancel"), on_click=lambda e: close_dialog(page, dlg)),
            C.danger_button(S("unplan"), tok, on_click=_remove),
        ],
    )
    show_dialog(page, dlg)


def _recommended_blocks(state: AppState, page: ft.Page, term, now: datetime) -> list[ft.Control]:
    tok = state.tok
    picks = list(term.recommended)
    header_actions: list[ft.Control] = [_target_dropdown(state, term)]
    if picks:
        header_actions.append(C.primary_button(
            f"{S('plan_all')} ({len(picks)})", tok, icon=ft.Icons.DONE_ALL,
            on_click=lambda e: _plan_all_dialog(state, page, [o.day for o in picks])))
    blocks: list[ft.Control] = [
        ft.Row([ft.Container(C.section_header(f"{S('section_plan')} ({len(picks)})", tok),
                             expand=True)] + header_actions,
               vertical_alignment=ft.CrossAxisAlignment.CENTER),
        C.txt(S("plan_explain"), tok, size=tok.fs_small, faint=True),
    ]
    if not picks:
        already = len(term.planned_dates & set(term.remaining_days))
        target = state.planner_target_days()
        if target and already >= target:
            text = S("plan_target_met").format(n=already)
        else:
            text = S("plan_budget_empty")
        blocks.append(C.card(C.txt(text, tok, faint=True), tok=tok))
        return blocks
    for option in picks:
        lessons_today = _day_lessons(state, option.day)
        if option.day == now.date() and lessons_today:
            left = len(future_lessons(lessons_today, now, day=option.day.strftime("%d.%m.%Y")))
            when = C.txt(S("today_left_note").format(n=left, t=len(lessons_today)),
                         tok, size=tok.fs_small, color=tok.yellow)
        else:
            when = C.txt(_cost_text(option), tok, size=tok.fs_small, muted=True)

        def _plan(e, d=option.day):
            _plan_dialog(state, page, d.isoformat(), _day_label(d))

        title_row: list[ft.Control] = [C.txt(_day_label(option.day), tok, bold=True)]
        title_row.extend(_tag_badges(state, option))
        blocks.append(T.anchor(state, "plan_first", C.card(ft.Row(
            [
                ft.Column(
                    [ft.Row(title_row, spacing=6, wrap=True), when,
                     C.txt(_subjects_text(option.lessons), tok, size=tok.fs_tiny, faint=True)],
                    spacing=2, expand=True, tight=True),
                C.primary_button(S("plan_skip"), tok, on_click=_plan),
            ],
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ), tok=tok)))
    return blocks


def _budget_bar(state: AppState, budget) -> ft.Control:
    """Stacked bar over the school limit: missed | planned | free | reserve."""
    tok = state.tok
    over = budget.status == "over"
    segments = [
        (budget.missed, tok.red if over else tok.muted),
        (budget.planned, tok.red if over else tok.accent),
        (max(0.0, budget.free), tok.green),
        (max(0.0, min(budget.buffer, budget.school_left)), tint(tok.yellow, 0.55)),
    ]
    total = max(budget.school_cap, budget.missed + budget.planned, 0.1)
    parts: list[ft.Control] = []
    used = 0
    for hours, color in segments:
        share = int(round(max(0.0, hours) / total * 1000))
        if share <= 0:
            continue
        used += share
        parts.append(ft.Container(bgcolor=color, expand=share))
    if used < 1000:
        parts.append(ft.Container(expand=1000 - used))
    return ft.Container(
        content=ft.Row(parts, spacing=0, expand=True),
        bgcolor=tok.overlay, height=8, border_radius=radius_all(4),
        clip_behavior=ft.ClipBehavior.HARD_EDGE, expand=True,
    )


def _budget_blocks(state: AppState, term) -> list[ft.Control]:
    tok = state.tok
    if not term.budgets:
        return []
    rows: list[ft.Control] = []
    for budget in term.budgets:
        kind = {"over": "critical", "reserve": "warning", "tight": "warning"}.get(budget.status, "ok")
        label = S({"over": "budget_over", "reserve": "budget_reserve",
                   "tight": "budget_tight"}.get(budget.status, "budget_ok"))
        rows.append(ft.Column([
            ft.Row([
                ft.Container(C.txt(budget.name, tok, size=tok.fs_small, bold=True), expand=True),
                C.txt(S("budget_final").format(p=f"{budget.projected_pct:.1f}",
                                               limit=budget.limit_pct),
                      tok, size=tok.fs_tiny, faint=True),
                C.badge(label, tok, kind=kind),
            ], spacing=6, vertical_alignment=ft.CrossAxisAlignment.CENTER),
            ft.Row([_budget_bar(state, budget)]),
            C.txt(S("budget_line").format(free=_hours(budget.free), planned=int(budget.planned),
                                          buffer=_hours(budget.buffer)),
                  tok, size=tok.fs_tiny, muted=True),
        ], spacing=3, tight=True))

    def _legend(color: str, label: str) -> ft.Control:
        return ft.Row([ft.Container(width=10, height=10, bgcolor=color, border_radius=radius_all(2)),
                       C.txt(label, tok, size=tok.fs_tiny, muted=True)], spacing=4, tight=True)

    legend = ft.Row([
        _legend(tok.muted, S("legend_missed")),
        _legend(tok.accent, S("legend_planned")),
        _legend(tok.green, S("legend_free_h")),
        _legend(tint(tok.yellow, 0.55), S("legend_buffer")),
    ], spacing=tok.gap, wrap=True)
    return [C.section_header(S("section_budgets"), tok),
            T.anchor(state, "plan_budget", C.card(legend, *rows, tok=tok))]


def _planned_blocks(state: AppState, page: ft.Page, plan, now: datetime) -> list[ft.Control]:
    tok = state.tok
    planned = list(state.planned_skips)
    costs: dict[str, tuple[int, bool, bool]] = {}
    for term in plan.terms:
        for row in term.planned:
            key = repr(normalize_planned_entry(row.entry))
            hours, over, reserve = costs.get(key, (0, False, False))
            costs[key] = (hours + sum(row.cost.values()), over or bool(row.over),
                          reserve or bool(row.reserve))
    blocks: list[ft.Control] = [C.section_header(f"{S('planned_title')} ({len(planned)})", tok)]
    if not planned:
        blocks.append(C.card(C.txt(S("no_planned"), tok, faint=True), tok=tok))
        return blocks
    for entry in sorted(planned, key=lambda e: (entry_start_iso(e), entry_end_iso(e))):
        try:
            is_past = date.fromisoformat(entry_end_iso(entry)) < now.date()
        except ValueError:
            is_past = False
        template_preview = str(entry.get("template", "")).strip().split("\n")[0][:80]
        hours, over, reserve = costs.get(repr(normalize_planned_entry(entry)), (0, False, False))
        title_row: list[ft.Control] = [C.txt(_entry_label(entry), tok, bold=True)]
        if over and not is_past:
            title_row.append(C.badge(S("budget_over"), tok, kind="critical"))
        elif reserve and not is_past:
            title_row.append(C.badge(S("budget_reserve"), tok, kind="warning"))
        details: list[ft.Control] = [ft.Row(title_row, spacing=6, wrap=True)]
        meta = " · ".join(p for p in (
            S("planned_cost").format(h=hours) if hours and not is_past else "",
            template_preview) if p)
        if meta:
            details.append(C.txt(meta, tok, size=tok.fs_small, muted=True))

        def _unplan(e, ent=dict(entry)):  # noqa: B006 - binds this row's entry
            if state.unplan_entry(ent):
                snack(page, S("plan_removed"))
            else:
                snack(page, S("save_failed"))

        blocks.append(C.card(ft.Row(
            [
                ft.Column(details, spacing=2, expand=True, tight=True),
                C.badge(S("day_passed"), tok, kind="pending") if is_past
                else C.danger_button(S("unplan"), tok, on_click=_unplan),
            ],
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ), tok=tok))
    return blocks


def _footer(state: AppState) -> list[ft.Control]:
    tok = state.tok
    blocks: list[ft.Control] = [C.txt(S("holidays_note"), tok, size=tok.fs_small, faint=True)]
    try:
        preset_n, added_n, forced_n, sem1, sem2 = state.calendar_summary()
        blocks.append(C.txt(
            S("cal_summary").format(preset=preset_n, added=added_n, forced=forced_n)
            + f" · {S('cal_closes').format(a=sem1 or S('cal_auto'), b=sem2 or S('cal_auto'))}",
            tok, size=tok.fs_small, faint=True))
    except Exception:
        pass

    def _open_calendar(e):
        state.set_settings_section("calendar")
        state.go("settings")

    blocks.append(C.ghost_button(S("cal_open_calendar"), tok, on_click=_open_calendar))
    return blocks


def build(state: AppState, page: ft.Page, now: datetime | None = None) -> ft.Control:
    tok = state.tok
    now = now or datetime.now()
    intro = C.txt(
        f"{S('planner_desc')} " + S("plan_buffer_note").format(reserve=state.plan_reserve()),
        tok, size=tok.fs_small, muted=True)

    plan = state.year_plan(now) if state.timetable() else None
    states, _days = state.subject_states() if plan is not None else ([], [])
    if plan is None or not states:
        blocks: list[ft.Control] = [
            C.header_row(tok, S("planner_title"), state.updated_label), intro,
            C.empty_state(S("no_data"), tok),
        ]
        if state.demo_mode:
            blocks.append(C.txt(S("need_credentials"), tok, size=tok.fs_small, faint=True))
        elif not state.timetable():
            blocks.append(C.txt(S("planner_need_refresh"), tok, size=tok.fs_small, faint=True))
        return ft.Column(blocks, spacing=tok.gap, expand=True)

    custom_btn = C.primary_button(
        S("plan_custom"), tok, icon=ft.Icons.EDIT_CALENDAR_OUTLINED,
        on_click=lambda e: _custom_plan_dialog(state, page, now))
    custom_btn.tooltip = S("plan_custom_hint")
    blocks = [
        C.header_row(
            tok, S("planner_title"), state.updated_label,
            actions=[
                C.ghost_button(S("see_absences"), tok,
                               on_click=lambda e: state.go("absences")),
                custom_btn,
            ],
        ),
        intro,
    ]

    term = plan.term(state.planner_term_key()) or plan.default_term
    if term is None:
        blocks.append(C.card(C.txt(S("term_nothing"), tok, faint=True), tok=tok))
    else:
        switcher = _term_switcher(state, plan, term)
        if switcher is not None:
            blocks.append(switcher)
        if not term.has_data:
            blocks.append(C.txt(S("term_fresh"), tok, size=tok.fs_small, color=tok.accent))
        elif term.recommended:
            T.offer(state, "planner")
        blocks.append(_stats_row(state, term))
        blocks.extend(_warnings(state, term))
        blocks.append(C.section_header(S("section_overview"), tok))
        blocks.append(_calendar_strip(state, page, plan, term, now))
        blocks.extend(_recommended_blocks(state, page, term, now))
        blocks.extend(_budget_blocks(state, term))
    blocks.extend(_planned_blocks(state, page, plan, now))
    blocks.extend(_footer(state))
    blocks.append(C.bottom_spacer(tok))
    return C.scrollable(state, "planner", blocks, spacing=tok.gap, expand=True)
