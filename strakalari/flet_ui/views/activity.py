"""Aktivita — is the automation alive and what is it doing right now.

Status card (state dot + current step + progress), last/next scheduled run,
run history, and the live log. Refresh controls live here too, with
a scope picker and cancel while a run is in progress.
"""

from __future__ import annotations

import flet as ft

from .. import components as C
from .. import tutorial as T
from ..state import AppState
from ..strings import S


def _scope_dropdown(state: AppState) -> ft.Dropdown:
    tok = state.tok
    dd = C.dropdown(
        tok,
        S("refresh_scope"),
        [
            ("all", S("refresh_all")),
            ("bakalari", S("refresh_bakalari")),
            ("strava", S("refresh_strava")),
        ],
        # Draft-backed: a background re-render between selecting and
        # pressing Refresh must not silently reset the scope to "all".
        state.draft("activity:scope", "all"),
        on_change=lambda e: state.set_draft(
            "activity:scope", (e.control.value if e.control else "") or "all"),
    )
    dd.expand = True
    return dd


def _update_banner(state: AppState, page: ft.Page) -> ft.Control | None:
    tok = state.tok
    info = state.update_banner
    if info is None:
        return None
    latest = str(info.get("version") or "?")
    try:
        from strakalari.core.update import get_current_version

        current = get_current_version()
    except Exception:
        current = "?"
    desc = S("update_desc").format(cur=current, v=latest)

    async def _open(e) -> None:
        url = str(info.get("url") or "")
        if not url:
            return
        await C.open_url(page, url)

    return C.card(
        ft.Row(
            [
                C.txt(S("update_available").format(v=latest), tok, bold=True),
                ft.Container(expand=True),
                C.ghost_button(S("update_dismiss"), tok,
                               on_click=lambda e: state.dismiss_update()),
            ],
            spacing=8,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        C.txt(desc, tok, size=tok.fs_small, muted=True),
        ft.Row(
            [C.primary_button(S("download_update"), tok, on_click=_open,
                              icon=ft.Icons.UPGRADE)],
            spacing=8,
        ),
        tok=tok,
    )


def _status_card(state: AppState, scope_box: ft.Dropdown, page: ft.Page) -> ft.Control:
    tok = state.tok
    if state.refresh_running:
        state_label = state.current_step or S("refreshing")
        dot = C.status_dot(tok, "working")
    elif state.status == "error":
        state_label = S("status_error")
        dot = C.status_dot(tok, "error")
    elif state.runs and state.runs[-1].get("ok"):
        state_label = S("status_ok")
        dot = C.status_dot(tok, "ok")
    else:
        state_label = S("status_idle")
        dot = C.status_dot(tok, "idle")

    head = ft.Row(
        [dot, C.txt(state_label, tok, bold=True)],
        spacing=8,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )
    rows: list[ft.Control] = [head]
    if state.refresh_running:
        rows.append(C.progress_bar(tok))
        rows.append(
            ft.Row(
                [
                    C.ghost_button(
                        S("cancel_refresh"), tok,
                        on_click=lambda e: state.cancel_refresh(),
                    ),
                ],
                spacing=8,
            )
        )
    else:
        def _refresh(e) -> None:
            from ..overlays import snack

            if not state.start_refresh(scope_box.value or "all"):
                snack(page, S("already_running"))

        rows.append(
            ft.Row(
                [
                    scope_box,
                    C.primary_button(
                        S("refresh_data"), tok,
                        on_click=_refresh,
                        icon=ft.Icons.REFRESH,
                    ),
                ],
                spacing=8,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            )
        )
    paused = state.automation_paused()
    rows.append(
        ft.Row(
            [
                C.toggle(tok, S("automation_pause"), paused,
                         on_change=lambda e: state.set_automation_paused(
                             bool(e.control.value if e.control else False), page)),
            ]
            + ([C.badge(S("automation_paused_banner"), tok, kind="warning")] if paused else []),
            spacing=8,
            wrap=True,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        )
    )
    rows.append(C.divider(tok))
    try:
        from strakalari.core.update import get_current_version

        rows.append(C.kv_row(tok, S("app_version"), get_current_version()))
    except Exception:
        pass
    rows.append(C.kv_row(tok, S("last_updated"), state.updated_label))
    rows.append(C.kv_row(tok, S("last_run"), state.last_run_label))
    rows.append(C.kv_row(tok, S("next_run"), state.next_run_label))
    return C.form_card(*rows, tok=tok)


def _history_card(state: AppState) -> ft.Control:
    tok = state.tok
    rows: list[ft.Control] = [C.txt(S("run_history"), tok, bold=True)]
    if not state.runs:
        rows.append(C.txt(S("no_runs_yet"), tok, faint=True))
    for run in reversed(state.runs[-10:]):
        rows.append(
            ft.Row(
                [
                    C.txt(str(run.get("finished", "?")), tok, size=tok.fs_small),
                    C.txt(str(run.get("scope", "")), tok, size=tok.fs_small, muted=True),
                    ft.Container(expand=True),
                    C.txt(str(run.get("detail", "")), tok, size=tok.fs_small, muted=True),
                    C.badge("OK" if run.get("ok") else "ERR", tok,
                            kind="sent" if run.get("ok") else "failed"),
                ],
                spacing=8,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            )
        )
    return C.card(*rows, tok=tok)


_AUDIT_BADGE = {
    "sent": "sent", "dry_run": "pending", "covered": "ok",
    "skipped": "warning", "failed": "failed",
}


def _audit_card(state: AppState) -> ft.Control:
    """Everything sent or ordered under the user's accounts (newest first)."""
    tok = state.tok
    try:
        from strakalari.core.audit import recent

        items = recent(limit=15)
    except Exception as exc:  # noqa: BLE001 - show the failure, not a blank
        items = []
        rows: list[ft.Control] = [C.txt(f"{S('automation_history')}: {exc}", tok, faint=True)]
    else:
        rows = []
    if not items and not rows:
        rows.append(C.txt(S("automation_history_empty"), tok, faint=True))
    for item in items:
        stamp = str(item.get("ts", "")).replace("T", " ")[:16]
        kind = S(f"audit_kind_{item.get('kind', 'excuse')}")
        source = S(f"audit_source_{item.get('source', 'manual')}")
        outcome = str(item.get("outcome", "failed"))
        rows.append(
            ft.Row(
                [
                    C.txt(stamp, tok, size=tok.fs_small),
                    C.txt(f"{kind} · {source}", tok, size=tok.fs_small, muted=True),
                    ft.Container(expand=True),
                    C.txt(str(item.get("summary", "")), tok, size=tok.fs_small, muted=True),
                    C.badge(S(f"audit_{outcome}"), tok,
                            kind=_AUDIT_BADGE.get(outcome, "failed")),
                ],
                spacing=8,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            )
        )
    return C.card(*rows, tok=tok)


def redacted_log_tail(state: AppState, limit: int = 200) -> str:
    """Log tail with known secret values scrubbed — the only form logs may be copied in."""
    from strakalari.core.error_report import redact_text

    cfg = state.config.data if isinstance(state.config.data, dict) else {}
    return "\n".join(redact_text(line, cfg) for line in state.log_lines[-limit:])


def _log_card(state: AppState, page: ft.Page) -> ft.Control:
    tok = state.tok
    lines = state.log_lines[-60:]
    body: list[ft.Control] = [C.txt(S("live_log"), tok, bold=True)]
    if not lines:
        body.append(C.txt(S("no_log_yet"), tok, faint=True))
    for line in lines:
        body.append(C.log_line(tok, line))

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

    body.append(
        ft.Row(
            [
                C.ghost_button(S("clear_log"), tok, on_click=lambda e: state.clear_log()),
                C.ghost_button(S("error_copy_logs"), tok, on_click=_copy_log),
            ],
            spacing=8,
        )
    )
    return C.card(*body, tok=tok)


def build(state: AppState, page: ft.Page) -> ft.Control:
    tok = state.tok
    T.offer(state, "activity")
    scope_box = _scope_dropdown(state)
    banner = _update_banner(state, page)
    return C.scrollable(
        state, "activity",
        [
            C.header_row(tok, S("activity_title"), state.updated_label),
        ]
        + ([banner] if banner is not None else [])
        + [
            _status_card(state, scope_box, page),
            C.section_header(S("run_history"), tok),
            _history_card(state),
            C.section_header(S("automation_history"), tok),
            _audit_card(state),
            C.section_header(S("live_log"), tok),
            _log_card(state, page),
            C.bottom_spacer(tok),
        ],
        spacing=tok.gap,
        expand=True,
    )
