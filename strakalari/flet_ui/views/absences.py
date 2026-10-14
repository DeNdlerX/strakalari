"""Absence — per-subject meters against their own limits."""

from __future__ import annotations

import flet as ft

from .. import components as C
from .. import tutorial as T
from ..state import AppState
from ..strings import S


def build(state: AppState, page: ft.Page) -> ft.Control:
    tok = state.tok
    states, _days = state.subject_states()
    blocks: list[ft.Control] = [C.header_row(tok, S("absence_title"), state.updated_label)]

    if not states:
        blocks.append(C.empty_state(S("no_data"), tok))
        if state.demo_mode:
            blocks.append(C.txt(S("need_credentials"), tok, size=tok.fs_small, faint=True))
        return ft.Column(blocks, spacing=tok.gap, expand=True)

    avg = sum(s.current_pct for s in states) / len(states)
    warn = sum(1 for s in states if s.status == "warning")
    crit = sum(1 for s in states if s.status == "critical")
    T.offer(state, "absences")
    blocks.append(T.anchor(state, "abs_stats",
        ft.Row(
            [
                C.stat_card(S("avg_absence"), f"{avg:.1f} %", tok),
                C.stat_card(S("warn_subjects"), str(warn), tok, kind="warning" if warn else "ok"),
                C.stat_card(S("crit_subjects"), str(crit), tok, kind="critical" if crit else "ok"),
            ],
            spacing=tok.gap,
        )
    ))

    # Planner budgets for the running semester (planned days off and the
    # illness reserve included) — the same numbers the Planner shows.
    budgets: dict = {}
    try:
        term = state.year_plan().default_term
        if term is not None and term.has_data:
            budgets = term.budget_by_canon
    except Exception:
        budgets = {}

    def _detail(subject) -> str:
        from strakalari.core.forecast import canon_subject

        budget = budgets.get(canon_subject(subject.name))
        if budget is None:
            return (f"{S('col_limit')}: {subject.limit_pct:g} % · "
                    f"{S('safe_to')}: {subject.effective_plan_limit:g} % · "
                    f"{S('col_safe')}: {subject.effective_plan_safe}")
        parts = [f"{S('col_limit')}: {subject.limit_pct:g} %",
                 S("hours_free").format(n=budget.free_hours)]
        if budget.planned:
            parts.append(f"{S('legend_planned')}: {int(budget.planned)} h")
        parts.append(S("budget_end").format(p=f"{budget.projected_pct:.1f}"))
        return " · ".join(parts)

    narrow = C.narrow(state)
    rows: list[ft.Control] = []
    for subject in states:
        info = ft.Column(
            [
                C.txt(subject.name, tok, bold=True),
                C.txt(_detail(subject), tok, size=tok.fs_small, muted=True),
            ],
            spacing=2,
            expand=not narrow,
            tight=True,
        )
        gauge = [
            C.meter(subject.current_pct, tok, kind=subject.status),
            # Fixed slot sized for the longest label, so a shorter
            # badge doesn't shift the meter sideways.
            ft.Container(
                content=ft.Row(
                    [C.badge(
                        {"ok": S("state_ok"), "warning": S("state_warning"),
                         "critical": S("state_critical")}[subject.status],
                        tok, kind=subject.status,
                    )],
                    alignment=ft.MainAxisAlignment.END,
                ),
                width=tok.fs_tiny * 8,
            ),
        ]
        # Phone: the meter goes under the name, which needs the full width.
        body = (ft.Column([info, ft.Row(gauge, vertical_alignment=ft.CrossAxisAlignment.CENTER)],
                          spacing=8, tight=True) if narrow
                else ft.Row([info, *gauge], vertical_alignment=ft.CrossAxisAlignment.CENTER))
        rows.append(T.anchor(state, "abs_first", C.card(body, tok=tok)))
    if narrow:
        # Phone: header and stats scroll away with the list (landscape).
        return C.scrollable(state, "absences", blocks + rows + [C.bottom_spacer(tok)],
                            spacing=tok.gap // 2 + 2, expand=True)
    blocks.append(C.scrollable(state, "absences", rows + [C.bottom_spacer(tok)],
                               spacing=tok.gap // 2, expand=True))
    return ft.Column(blocks, spacing=tok.gap, expand=True)
