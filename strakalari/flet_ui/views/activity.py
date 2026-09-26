"""Aktivita — is the automation alive and what is it doing right now.

Top: a status hero (state icon, what is happening, refresh / cancel with
a scope picker) and four stat tiles (last run, next run, success rate,
what was sent this week). Left column: the run timeline and the live
log (terminal-style, newest line at the bottom, errors highlighted).
Right column: the automation card (pause switch + current modes) and the
automation history — everything sent or ordered under the user's
accounts, translated and grouped (one row per batch, not per day).
"""

from __future__ import annotations

import re
from datetime import datetime, timedelta

import flet as ft

from strakalari.core.models import parse_cz_date

from .. import components as C
from .. import tutorial as T
from ..state import AppState
from ..strings import S
from ..theme import align_center, border_all, pad_all, pad_sym, radius_all, status_color, tint

PANEL_WIDTH = 380
#: Narrower windows stack the two columns (the left one would be < ~480 px).
WIDE_MIN_WIDTH = 1120
LOG_HEIGHT = 320
HISTORY_ROWS = 10
AUDIT_GROUPS = 12

_AUDIT_BADGE = {
    "sent": "sent", "dry_run": "pending", "covered": "ok",
    "skipped": "warning", "unconfirmed": "warning", "failed": "failed",
}
_SCOPES = (("all", "refresh_all"), ("bakalari", "scope_bakalari"), ("strava", "scope_strava"))


# -- small helpers -------------------------------------------------------------------------
def _clock(when: datetime, now: datetime) -> str:
    """'14:30' today, '25. 9. 14:30' on other days."""
    hm = when.strftime("%H:%M")
    return hm if when.date() == now.date() else f"{C.cz_day(when.date())} {hm}"


def _ago(when: datetime | None, now: datetime) -> str:
    if when is None:
        return "—"
    secs = (now - when).total_seconds()
    if secs < 60:
        return S("ago_now")
    if secs < 3600:
        return S("ago_min").format(n=int(secs // 60))
    if secs < 6 * 3600:
        return S("ago_hours").format(n=int(secs // 3600))
    return _clock(when, now)


def _run_time(run: dict) -> datetime | None:
    try:
        return datetime.fromisoformat(str(run.get("at") or ""))
    except ValueError:
        return None


def _run_when(run: dict, now: datetime) -> str:
    at = _run_time(run)
    return _ago(at, now) if at is not None else str(run.get("finished") or "—")


def _run_kind(run: dict) -> str:
    """ok | cancelled | failed."""
    if run.get("ok"):
        return "ok"
    return "cancelled" if run.get("cancelled") else "failed"


def _duration(seconds) -> str:
    try:
        total = max(0, int(seconds))
    except (TypeError, ValueError):
        return ""
    if total < 60:
        return f"{total} s"
    return f"{total // 60} min {total % 60} s"


def _scope_label(scope: str) -> str:
    return S(dict(_SCOPES).get(str(scope or "all"), "refresh_all"))


def _icon_disc(icon: str, color: str, size: int = 32, icon_size: int = 18) -> ft.Container:
    """A status icon on a soft disc of its own color."""
    return ft.Container(
        content=ft.Icon(icon, size=icon_size, color=color),
        width=size, height=size,
        alignment=align_center(),
        border_radius=radius_all(size // 2),
        bgcolor=tint(color, 0.14),
    )


def _panel_head(title: str, tok, icon: str, extra: list[ft.Control] | None = None) -> ft.Row:
    return ft.Row(
        [ft.Icon(icon, size=16, color=tok.faint), C.section_header(title, tok)]
        + list(extra or []),
        spacing=6,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )


def _is_wide(page) -> bool:
    try:
        width = float(getattr(page, "width", None) or 0)
    except (TypeError, ValueError):
        width = 0.0
    return width <= 0 or width >= WIDE_MIN_WIDTH  # unknown (tests): default window


def _app_version() -> str:
    try:
        from strakalari.core.update import get_current_version

        return str(get_current_version() or "")
    except Exception:
        return ""


def _next_due(state: AppState) -> datetime | None:
    if state.scheduler_last_run is None:
        return None
    try:
        from strakalari.core.scheduler import next_due

        return next_due(state.scheduler_last_run,
                        float(state.get("check_interval_minutes", 60) or 60),
                        datetime.now())
    except Exception:
        return None


def _audit_items(limit: int = 80) -> tuple[list[dict], str]:
    """Newest audit records + the read error ("" when fine)."""
    try:
        from strakalari.core.audit import recent

        return recent(limit=limit), ""
    except Exception as exc:  # noqa: BLE001 - show the failure, not a blank
        return [], str(exc)


def _audit_time(item: dict) -> datetime | None:
    try:
        return datetime.fromisoformat(str(item.get("ts") or ""))
    except ValueError:
        return None


# -- update banner ----------------------------------------------------------------------------
def _update_banner(state: AppState, page: ft.Page) -> ft.Control | None:
    tok = state.tok
    info = state.update_banner
    if info is None:
        return None
    latest = str(info.get("version") or "?")
    desc = S("update_desc").format(cur=_app_version() or "?", v=latest)

    async def _open(e) -> None:
        url = str(info.get("url") or "")
        if not url:
            return
        await C.open_url(page, url)

    return ft.Container(
        content=ft.Row(
            [
                ft.Icon(ft.Icons.NEW_RELEASES_OUTLINED, color=tok.accent, size=22),
                ft.Column(
                    [C.txt(S("update_available").format(v=latest), tok, bold=True),
                     C.txt(desc, tok, size=tok.fs_small, muted=True)],
                    spacing=2, tight=True, expand=True,
                ),
                C.primary_button(S("download_update"), tok, on_click=_open,
                                 icon=ft.Icons.UPGRADE),
                C.ghost_button(S("update_dismiss"), tok,
                               on_click=lambda e: state.dismiss_update()),
            ],
            spacing=10,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        bgcolor=tint(tok.accent, 0.10),
        border=border_all(1, tint(tok.accent, 0.5)),
        border_radius=radius_all(tok.radius_md),
        padding=pad_sym(horizontal=tok.pad, vertical=10),
    )


# -- status hero ------------------------------------------------------------------------------
def _scope_picker(state: AppState) -> ft.SegmentedButton:
    def _changed(e) -> None:
        selected = list(getattr(e.control, "selected", []) or [])
        # Draft-backed: a background re-render between picking and
        # pressing Refresh must not silently reset the scope to "all".
        state.set_draft("activity:scope", selected[0] if selected else "all")

    current = state.draft("activity:scope", "all")
    if current not in dict(_SCOPES):
        current = "all"
    return ft.SegmentedButton(
        segments=[ft.Segment(value=key, label=S(label)) for key, label in _SCOPES],
        selected=[current],
        on_change=_changed,
        show_selected_icon=False,
        tooltip=S("refresh_scope"),
    )


def _show_error(state: AppState, page: ft.Page) -> None:
    from ..overlays import show_error_dialog

    report = state.last_error if isinstance(state.last_error, dict) else {}
    text = state.error_report_text()
    if not text:
        return
    show_error_dialog(page, S("error_title"), str(report.get("summary", "")), text,
                      user_message=str(report.get("user_message", "")))


def _hero(state: AppState, page: ft.Page, now: datetime) -> ft.Control:
    tok = state.tok
    last = state.runs[-1] if state.runs else None
    sending = state.sending_label
    kind = state.status_kind()

    lines: list[ft.Control] = []
    if kind == "working":
        headline = S("refreshing") if state.refresh_running else sending
        color = tok.accent
        disc: ft.Control = ft.Container(
            content=ft.ProgressRing(width=26, height=26, stroke_width=3, color=color),
            width=52, height=52, alignment=align_center(),
            border_radius=radius_all(26), bgcolor=tint(color, 0.14),
        )
        if state.refresh_running and state.current_step:
            lines.append(C.txt(state.current_step, tok, size=tok.fs_small, muted=True))
        lines.append(C.txt(S("activity_working_hint"), tok, size=tok.fs_small, faint=True))
    elif kind == "error":
        headline, color = S("status_error"), tok.red
        disc = _icon_disc(ft.Icons.ERROR_OUTLINE_ROUNDED, color, size=52, icon_size=28)
        if last is not None and not last.get("ok"):
            key = "activity_last_cancelled" if last.get("cancelled") else "activity_last_failed"
            lines.append(C.txt(S(key).format(when=_run_when(last, now)), tok,
                               size=tok.fs_small, muted=True))
        detail = str((last or {}).get("detail") or "")
        if not detail and isinstance(state.last_error, dict):
            detail = str(state.last_error.get("summary") or "")
        if detail:
            lines.append(C.txt(detail, tok, size=tok.fs_small, color=tok.red))
    elif kind == "ok":
        headline, color = S("status_ok"), tok.green
        disc = _icon_disc(ft.Icons.CHECK_CIRCLE_OUTLINE_ROUNDED, color, size=52, icon_size=28)
        lines.append(C.txt(S("activity_last_ok").format(when=_run_when(last or {}, now)), tok,
                           size=tok.fs_small, muted=True))
        if (last or {}).get("detail"):
            lines.append(C.txt(str(last["detail"]), tok, size=tok.fs_small, faint=True))
    else:
        headline, color = S("status_idle"), tok.muted
        disc = _icon_disc(ft.Icons.SCHEDULE_ROUNDED, color, size=52, icon_size=28)
        if last is not None and last.get("cancelled"):
            lines.append(C.txt(S("activity_last_cancelled").format(when=_run_when(last, now)),
                               tok, size=tok.fs_small, muted=True))
        else:
            lines.append(C.txt(S("no_runs_yet"), tok, size=tok.fs_small, muted=True))

    title_row: list[ft.Control] = [
        ft.Text(headline, size=tok.fs_title, weight=ft.FontWeight.BOLD, color=tok.text),
    ]
    if state.automation_paused():
        title_row.append(C.badge(S("automation_paused_banner"), tok, kind="warning"))

    actions: list[ft.Control] = []
    if state.refresh_running:
        actions.append(C.ghost_button(S("cancel_refresh"), tok, icon=ft.Icons.STOP_CIRCLE_OUTLINED,
                                      on_click=lambda e: state.cancel_refresh()))
    else:
        def _refresh(e) -> None:
            from ..overlays import snack

            if not state.start_refresh(state.draft("activity:scope", "all") or "all"):
                snack(page, S("already_running"))

        actions.append(_scope_picker(state))
        actions.append(C.primary_button(S("refresh_data"), tok, on_click=_refresh,
                                        icon=ft.Icons.REFRESH, disabled=bool(sending)))
    if kind == "error" and state.error_report_text():
        lines.append(ft.Container(
            content=C.ghost_button(S("error_details"), tok, icon=ft.Icons.BUG_REPORT_OUTLINED,
                                   on_click=lambda e: _show_error(state, page)),
            padding=ft.Padding(left=0, top=6, right=0, bottom=0),
        ))

    text = ft.Column(
        [ft.Row(title_row, spacing=10, wrap=True,
                vertical_alignment=ft.CrossAxisAlignment.CENTER)] + lines,
        spacing=3, tight=True, expand=True,
    )
    action_row = ft.Row(actions, spacing=8, tight=True, wrap=True,
                        vertical_alignment=ft.CrossAxisAlignment.CENTER)
    wide = _is_wide(page)
    body: list[ft.Control] = [
        ft.Row(
            [disc, text] + ([action_row] if wide else []),
            spacing=14,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
    ]
    if not wide:
        # Side by side the picker + button would starve the text column.
        body.append(ft.Row([action_row], alignment=ft.MainAxisAlignment.END))
    if kind == "working":
        body.append(C.progress_bar(tok))
    return ft.Container(
        content=ft.Column(body, spacing=12, tight=True),
        bgcolor=tint(color, 0.07),
        border=border_all(1, tint(color, 0.4)),
        border_radius=radius_all(tok.radius_md),
        padding=pad_all(tok.pad),
    )


# -- stat tiles -------------------------------------------------------------------------------
def _stats(state: AppState, now: datetime, audit: list[dict]) -> ft.Row:
    tok = state.tok
    last = state.runs[-1] if state.runs else None
    if last is None:
        last_value, last_kind = "—", "info"
    else:
        last_value = _run_when(last, now)
        last_kind = {"ok": "ok", "cancelled": "cancelled"}.get(_run_kind(last), "failed")

    due = _next_due(state)
    next_value = _clock(due, now) if due is not None else "—"

    total = len(state.runs)
    good = sum(1 for r in state.runs if r.get("ok"))
    if not total:
        success, success_kind = "—", "info"
    else:
        success = f"{good}/{total}"
        success_kind = "ok" if good == total else ("warning" if good else "failed")

    week_ago = now - timedelta(days=7)
    sent = sum(1 for item in audit
               if item.get("outcome") == "sent"
               and (_audit_time(item) or datetime.min) >= week_ago)
    return ft.Row(
        [
            C.stat_card(S("last_run"), last_value, tok, kind=last_kind),
            C.stat_card(S("next_run"), next_value, tok),
            C.stat_card(S("stat_success"), success, tok, kind=success_kind),
            C.stat_card(S("stat_sent_week"), str(sent), tok, kind="ok" if sent else "info"),
        ],
        spacing=tok.gap,
    )


# -- run timeline -----------------------------------------------------------------------------
def _history_card(state: AppState, now: datetime) -> ft.Control:
    tok = state.tok
    rows: list[ft.Control] = [_panel_head(S("run_history"), tok, ft.Icons.HISTORY)]
    if not state.runs:
        rows.append(C.hint_text(S("no_runs_yet"), tok))
    look = {
        "ok": (ft.Icons.CHECK_ROUNDED, tok.green, S("run_done"), "sent"),
        "failed": (ft.Icons.CLOSE_ROUNDED, tok.red, S("run_failed"), "failed"),
        "cancelled": (ft.Icons.BLOCK_ROUNDED, tok.muted, S("run_cancelled"), "cancelled"),
    }
    for run in reversed(state.runs[-HISTORY_ROWS:]):
        icon, color, label, badge_kind = look[_run_kind(run)]
        meta = [_scope_label(str(run.get("scope") or "all"))]
        took = _duration(run.get("seconds")) if run.get("seconds") is not None else ""
        if took:
            meta.append(S("run_took").format(d=took))
        text_col: list[ft.Control] = [
            C.txt(" · ".join(meta), tok, size=tok.fs_small, bold=True),
        ]
        if run.get("detail"):
            text_col.append(C.txt(str(run["detail"]), tok, size=tok.fs_tiny,
                                  color=tok.red if badge_kind == "failed" else None,
                                  muted=badge_kind != "failed"))
        rows.append(ft.Container(
            content=ft.Row(
                [
                    _icon_disc(icon, color, size=28, icon_size=16),
                    ft.Column(text_col, spacing=1, tight=True, expand=True),
                    C.txt(_run_when(run, now), tok, size=tok.fs_tiny, faint=True),
                    C.badge(label, tok, kind=badge_kind),
                ],
                spacing=10,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            padding=pad_sym(vertical=3),
        ))
    return C.card(*rows, tok=tok)


# -- live log ---------------------------------------------------------------------------------
_LOG_LINE = re.compile(r"^\[(\d{1,2}:\d{2}(?::\d{2})?)\]\s?(.*)$", re.DOTALL)
_LOG_ERROR = re.compile(
    r"traceback|error|exception|failed|selhal|chyba|^\s*File \"", re.IGNORECASE)
_LOG_WARN = re.compile(r"warning|varování|cancel|zrušen", re.IGNORECASE)


def _log_tone(message: str) -> str:
    """error | warning | ok | "" — drives the line color."""
    if message.strip() in (S("refresh_finished_log"), S("connection_ok")):
        return "ok"
    if _LOG_ERROR.search(message):
        return "error"
    if _LOG_WARN.search(message):
        return "warning"
    return ""


def redacted_log_tail(state: AppState, limit: int = 200) -> str:
    """Log tail with known secret values scrubbed — the only form logs may be copied in."""
    from strakalari.core.error_report import redact_text

    cfg = state.config.data if isinstance(state.config.data, dict) else {}
    return "\n".join(redact_text(line, cfg) for line in state.log_lines[-limit:])


def _split_log(line: str) -> tuple[str, str]:
    """'[10:00:01] text' → ('10:00:01', 'text'); unstamped lines keep the whole text."""
    match = _LOG_LINE.match(line)
    return (match.group(1), match.group(2)) if match else ("", line)


def _log_row(tok, line: str) -> ft.Control:
    stamp, message = _split_log(line)
    tone = _log_tone(message)
    color = {"error": tok.red, "warning": tok.yellow, "ok": tok.green}.get(tone, tok.muted)
    return ft.Row(
        [
            ft.Text(stamp, size=tok.fs_tiny, color=tok.faint, font_family="Consolas",
                    width=58),
            ft.Text(message, size=tok.fs_small, color=color, font_family="Consolas",
                    selectable=True, expand=True),
        ],
        spacing=6,
        vertical_alignment=ft.CrossAxisAlignment.START,
    )


def _log_card(state: AppState, page: ft.Page) -> ft.Control:
    tok = state.tok
    lines = state.log_lines[-150:]
    # One failure logs a message plus its traceback: count runs of
    # consecutive error lines, not the lines themselves.
    tones = [_log_tone(_split_log(line)[1]) for line in lines]
    errors = sum(1 for i, tone in enumerate(tones)
                 if tone == "error" and (i == 0 or tones[i - 1] != "error"))

    def _copy_log(e) -> None:
        from ..overlays import copy_text, snack

        if not state.log_lines:
            snack(page, S("no_log_yet"))
            return
        try:
            body = redacted_log_tail(state)
        except Exception:
            # Fail closed: never fall back to copying raw logs that may
            # still hold secrets.
            snack(page, S("error_copy_failed"))
            return
        if copy_text(page, body):
            snack(page, S("error_copied"))
        else:
            snack(page, S("error_copy_failed"))

    head = _panel_head(
        S("live_log"), tok, ft.Icons.TERMINAL,
        ([C.badge(S("log_errors").format(n=errors), tok, kind="failed")] if errors else [])
        + [
            ft.Container(expand=True),
            ft.IconButton(ft.Icons.CONTENT_COPY_OUTLINED, icon_size=18, icon_color=tok.muted,
                          tooltip=S("log_copy_tooltip"), on_click=_copy_log),
            ft.IconButton(ft.Icons.DELETE_SWEEP_OUTLINED, icon_size=18, icon_color=tok.muted,
                          tooltip=S("clear_log"), on_click=lambda e: state.clear_log()),
        ],
    )
    if lines:
        # Newest at the bottom, like a terminal: auto_scroll follows the tail.
        screen: ft.Control = ft.ListView(
            [_log_row(tok, line) for line in lines],
            spacing=2, auto_scroll=True, expand=True,
        )
    else:
        screen = ft.Container(content=C.hint_text(S("no_log_yet"), tok),
                              alignment=align_center(), expand=True)
    return C.card(
        head,
        ft.Container(
            content=screen,
            # Grows with the log up to LOG_HEIGHT, then scrolls; a short or
            # empty log does not leave a tall blank box.
            height=max(64, min(LOG_HEIGHT, 18 + 19 * len(lines))),
            bgcolor=tok.surface,
            border=border_all(1, tok.border),
            border_radius=radius_all(tok.radius_sm),
            padding=pad_sym(horizontal=10, vertical=8),
        ),
        tok=tok,
    )


# -- automation (right panel) -----------------------------------------------------------------
_MODE_LABEL = {"auto": "mode_auto", "confirm": "mode_confirm", "dry_run": "mode_dry_run"}


def _mode_row(state: AppState, label: str, key: str) -> ft.Row:
    tok = state.tok
    mode = str(state.get(key, "confirm") or "confirm")
    color = {"auto": tok.green, "dry_run": tok.yellow}.get(mode, tok.text)
    return C.kv_row(tok, label, S(_MODE_LABEL.get(mode, "mode_confirm")), value_color=color)


def _automation_card(state: AppState, page: ft.Page) -> ft.Control:
    tok = state.tok
    paused = state.automation_paused()

    def _edit(e) -> None:
        state.settings_section = "rules"
        state.go("settings")

    if paused:
        status: ft.Control = ft.Container(
            content=ft.Row(
                [ft.Icon(ft.Icons.PAUSE_CIRCLE_OUTLINE, size=18, color=tok.yellow),
                 C.txt(S("automation_paused_banner"), tok, size=tok.fs_small, color=tok.yellow,
                       bold=True)],
                spacing=8, vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            bgcolor=tint(tok.yellow, 0.12),
            border_radius=radius_all(tok.radius_sm),
            padding=pad_sym(horizontal=10, vertical=6),
        )
    else:
        status = C.txt(S("automation_running"), tok, size=tok.fs_small, muted=True)
    return C.card(
        _panel_head(S("automation_card"), tok, ft.Icons.BOLT_OUTLINED),
        status,
        C.toggle(tok, S("automation_pause"), paused,
                 on_change=lambda e: state.set_automation_paused(
                     bool(e.control.value if e.control else False), page)),
        C.hint_text(S("automation_pause_hint"), tok),
        C.divider(tok),
        _mode_row(state, S("excuse_mode_label"), "excuse_mode"),
        _mode_row(state, S("order_mode_label"), "strava_order_mode"),
        ft.Row([C.ghost_button(S("automation_edit"), tok, icon=ft.Icons.TUNE, on_click=_edit)],
               alignment=ft.MainAxisAlignment.END),
        tok=tok,
    )


def _group_audit(items: list[dict]) -> list[list[dict]]:
    """Consecutive records of one batch (same minute, kind, outcome, reason) → one group."""
    groups: list[list[dict]] = []
    for item in items:
        detail = item.get("detail") if isinstance(item.get("detail"), dict) else {}
        key = (str(item.get("ts", ""))[:16], item.get("kind"), item.get("outcome"),
               item.get("source"), detail.get("reason"),
               "&-1&" in str(detail.get("meal", "")))
        if groups and groups[-1][0]["_key"] == key:
            groups[-1].append({**item, "_key": key})
        else:
            groups.append([{**item, "_key": key}])
    return groups


def _cz_dates(text: str) -> str:
    """'18.09.2026 (6.)' → '18. 9. 2026 (6.)' in excuse summaries."""
    return re.sub(r"\d{1,2}\.\d{1,2}\.\d{4}", lambda m: C.cz_day_year(m.group(0)), text)


def _days_label(days: list[str], limit: int = 4) -> str:
    parsed = sorted({d for d in (parse_cz_date(x) for x in days) if d is not None})
    if not parsed:
        return ""
    shown = ", ".join(C.cz_day(d) for d in parsed[:limit])
    return shown + (f" +{len(parsed) - limit}" if len(parsed) > limit else "")


def _audit_row(state: AppState, group: list[dict], now: datetime) -> ft.Control:
    tok = state.tok
    first = group[0]
    kind = str(first.get("kind", "excuse"))
    outcome = str(first.get("outcome", "failed"))
    detail = first.get("detail") if isinstance(first.get("detail"), dict) else {}
    badge_kind = _AUDIT_BADGE.get(outcome, "failed")
    color = status_color(badge_kind, tok)

    title = S(f"audit_kind_{kind}")
    sub_parts: list[str] = []
    if kind == "lunch":
        action = S("audit_lunch_cancel" if "&-1&" in str(detail.get("meal", ""))
                   else "audit_lunch_order")
        title = f"{title} · {action}"
        days = [str((g.get("detail") or {}).get("day") or "") for g in group]
        if len(group) == 1 and days[0]:
            meal_name = ""
            try:
                meal_name = str(state.food().get(days[0], {}).get(detail.get("meal"), "") or "")
            except Exception:
                pass
            sub_parts.append(" · ".join(p for p in (C.cz_day(days[0]), meal_name) if p))
        else:
            sub_parts.append(_days_label(days))
        if detail.get("reason") == "low_balance":
            sub_parts.append(S("audit_reason_low_balance"))
    else:
        summaries = [_cz_dates(str(g.get("summary") or "")) for g in group]
        sub_parts.append(", ".join(summaries[:3]) + (f" +{len(summaries) - 3}"
                                                     if len(summaries) > 3 else ""))
    if len(group) > 1:
        title = f"{title} ×{len(group)}"

    when = _audit_time(first)
    meta = " · ".join(p for p in (
        _clock(when, now) if when else "",
        S(f"audit_source_{first.get('source', 'manual')}"),
    ) if p)
    return ft.Container(
        content=ft.Row(
            [
                _icon_disc(ft.Icons.RESTAURANT_OUTLINED if kind == "lunch"
                           else ft.Icons.DESCRIPTION_OUTLINED, color, size=30, icon_size=16),
                ft.Column(
                    [C.txt(title, tok, size=tok.fs_small, bold=True)]
                    + [C.txt(p, tok, size=tok.fs_tiny, muted=True) for p in sub_parts if p]
                    + [C.txt(meta, tok, size=tok.fs_tiny, faint=True)],
                    spacing=1, tight=True, expand=True,
                ),
                C.badge(S(f"audit_{outcome}"), tok, kind=badge_kind),
            ],
            spacing=10,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        padding=pad_sym(vertical=3),
    )


def _audit_filter(state: AppState) -> ft.SegmentedButton:
    def _changed(e) -> None:
        selected = list(getattr(e.control, "selected", []) or [])
        state.set_draft("activity:audit", selected[0] if selected else "all")
        state._emit()

    current = state.draft("activity:audit", "all")
    return ft.SegmentedButton(
        segments=[
            ft.Segment(value="all", label=S("audit_filter_all")),
            ft.Segment(value="excuse", label=S("audit_filter_excuse")),
            ft.Segment(value="lunch", label=S("audit_filter_lunch")),
        ],
        selected=[current if current in ("all", "excuse", "lunch") else "all"],
        on_change=_changed,
        show_selected_icon=False,
    )


def _audit_card(state: AppState, items: list[dict], error: str, now: datetime) -> ft.Control:
    """Everything sent or ordered under the user's accounts (newest first)."""
    tok = state.tok
    rows: list[ft.Control] = [
        _panel_head(S("automation_history"), tok, ft.Icons.FACT_CHECK_OUTLINED),
        _audit_filter(state),
    ]
    if error:
        rows.append(C.txt(f"{S('automation_history')}: {error}", tok, size=tok.fs_small,
                          color=tok.red))
    wanted = state.draft("activity:audit", "all")
    if wanted in ("excuse", "lunch"):
        items = [i for i in items if i.get("kind") == wanted]
    groups = _group_audit(items)
    if not groups and not error:
        rows.append(C.hint_text(S("automation_history_empty"), tok))
    for group in groups[:AUDIT_GROUPS]:
        rows.append(_audit_row(state, group, now))
    return C.card(*rows, tok=tok)


# -- build ------------------------------------------------------------------------------------
def build(state: AppState, page: ft.Page, now: datetime | None = None) -> ft.Control:
    tok = state.tok
    now = now or datetime.now()
    T.offer(state, "activity")
    audit, audit_error = _audit_items()

    version = _app_version()
    actions: list[ft.Control] = []
    if version:
        actions.append(C.txt(f"{S('app_version')} {version}", tok, size=tok.fs_small, faint=True))
    actions.append(ft.IconButton(
        ft.Icons.SYSTEM_UPDATE_ALT, icon_size=18, icon_color=tok.muted,
        tooltip=S("checking_updates") if state.update_check_running else S("check_updates"),
        disabled=bool(state.update_check_running),
        on_click=lambda e: state.start_update_check(force=True),
    ))
    blocks: list[ft.Control] = [
        C.header_row(tok, S("activity_title"), state.updated_label, actions=actions),
    ]
    banner = _update_banner(state, page)
    if banner is not None:
        blocks.append(banner)
    blocks.append(_hero(state, page, now))
    blocks.append(_stats(state, now, audit))

    history = _history_card(state, now)
    log = _log_card(state, page)
    automation = _automation_card(state, page)
    audit_card = _audit_card(state, audit, audit_error, now)
    if _is_wide(page):
        left = ft.Column([history, log], spacing=tok.gap, tight=True,
                         horizontal_alignment=ft.CrossAxisAlignment.STRETCH)
        right = ft.Column([automation, audit_card], spacing=tok.gap, tight=True,
                          horizontal_alignment=ft.CrossAxisAlignment.STRETCH)
        blocks.append(ft.Row(
            [ft.Container(content=left, expand=True),
             ft.Container(content=right, width=PANEL_WIDTH)],
            spacing=tok.gap,
            vertical_alignment=ft.CrossAxisAlignment.START,
        ))
    else:
        # A narrow window squeezes the left column until run details wrap
        # word by word: stack everything full width instead.
        blocks.extend([history, automation, audit_card, log])
    blocks.append(C.bottom_spacer(tok))
    return C.scrollable(state, "activity", blocks, spacing=tok.gap, expand=True)
