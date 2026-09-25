"""Marks — průběžná klasifikace per subject, with a what-if predictor.

Left: one card per subject (average, estimated final grade, trend, the
newest marks). Right: an overview (latest and planned marks, the percent
→ grade bands) or, once a subject is picked, its detail: every mark with
topic and weight, the running-average trend, a "what do I need" solver
and the predictor (add / edit / delete marks without touching the real
ones). Scales (1–5 vs percent) are autodetected per subject and can be
switched globally (header) or per subject (detail).
"""

from __future__ import annotations

from datetime import date

import flet as ft

from strakalari.core import grades as gr
from strakalari.core.models import parse_cz_date

from .. import components as C
from .. import tutorial as T
from ..overlays import snack
from ..state import AppState
from ..strings import S
from ..theme import align_center, border_all, pad_all, pad_sym, radius_all, status_color, tint

PANEL_WIDTH = 380
MAX_CHIPS = 14


# -- small formatting helpers ------------------------------------------------------
def _fmt(value: float | None, scale: str) -> str:
    return gr.format_value(value, scale)


def _mark_label(mark: dict, raw: gr.RawMark | None, scale: str, has_pct: bool) -> str:
    """The mark as written, with ``%`` added to bare percentages."""
    text = str(mark.get("Grade", "?")).strip() or "?"
    if raw is None:
        return text
    as_pct = raw.kind == "percent" or (raw.kind == "small" and scale == "percent" and has_pct)
    if as_pct and "%" not in text and "/" not in text:
        return f"{text} %"
    return text


def _subject_has_pct(summary: gr.SubjectSummary) -> bool:
    return any(r.raw is not None and r.raw.kind == "percent" for r in summary.rows)


def _row_kind(summary: gr.SubjectSummary, row: gr.MarkRow, bands) -> str:
    return gr.kind_for(row.value, summary.scale, bands)


def _final_text(summary: gr.SubjectSummary, bands) -> str:
    final = gr.final_grade(summary.current, summary.scale, bands)
    return str(final) if final is not None else "—"


def _day(value) -> str:
    return C.cz_day_year(value) if value else "—"


def _improving(summary: gr.SubjectSummary) -> bool | None:
    """True/False when the newest mark moved the average; None when flat."""
    trend = summary.trend
    if trend is None:
        return None
    eps = 0.5 if summary.scale == "percent" else 0.01
    if abs(trend) < eps:
        return None
    return trend > 0 if summary.scale == "percent" else trend < 0


def _trend_icon(summary: gr.SubjectSummary, tok) -> ft.Control | None:
    up = _improving(summary)
    if up is None:
        return None
    return ft.Icon(
        ft.Icons.TRENDING_UP if up else ft.Icons.TRENDING_DOWN,
        size=18,
        color=tok.green if up else tok.red,
        tooltip=S("marks_trend_up") if up else S("marks_trend_down"),
    )


def _chip(text: str, tok, kind: str, tooltip: str = "", hypothetical: bool = False,
          faded: bool = False) -> ft.Container:
    color = status_color(kind, tok) if kind != "info" else tok.muted
    return ft.Container(
        content=ft.Text(text, size=tok.fs_small, weight=ft.FontWeight.W_600, color=color),
        bgcolor=tint(tok.accent, 0.16) if hypothetical else tint(color, 0.10),
        border=border_all(1, tok.accent if hypothetical else tint(color, 0.45)),
        border_radius=radius_all(tok.radius_sm),
        padding=pad_sym(horizontal=7, vertical=2),
        tooltip=tooltip or None,
        opacity=0.4 if faded else 1.0,
    )


def _mark_tooltip(row: gr.MarkRow) -> str:
    mark = row.mark
    parts = [str(mark.get("Caption") or "").strip(),
             f"{S('marks_weight')} {gr.format_weight(row.weight)}",
             _day(mark.get("Date")) if mark.get("Date") else ""]
    return " · ".join(p for p in parts if p)


# -- aggregates ------------------------------------------------------------------------
def _overall(summaries: list[gr.SubjectSummary], bands) -> tuple[float | None, str]:
    """Mean of subject averages: in percent when every subject is percent,
    else on the 1–5 axis (percent subjects via their grade)."""
    with_avg = [s for s in summaries if s.current is not None]
    if not with_avg:
        return None, "grade"
    if all(s.scale == "percent" for s in with_avg):
        return sum(s.current for s in with_avg) / len(with_avg), "percent"
    vals = [gr.grade_equivalent(s.current, s.scale, bands) for s in with_avg]
    return sum(vals) / len(vals), "grade"


def _report_estimate(summaries: list[gr.SubjectSummary], bands) -> float | None:
    finals = [gr.final_grade(s.current, s.scale, bands) for s in summaries]
    finals = [f for f in finals if f is not None]
    return sum(finals) / len(finals) if finals else None


def _sorted(summaries: list[gr.SubjectSummary], sort: str, bands) -> list[gr.SubjectSummary]:
    if sort == "average":
        # Worst first: the subjects that need attention lead the list.
        return sorted(
            summaries,
            key=lambda s: (s.current is None,
                           -(gr.grade_equivalent(s.current, s.scale, bands) or 0),
                           s.name.casefold()),
        )
    if sort == "recent":
        return sorted(summaries, key=lambda s: (s.last_date or date.min), reverse=True)
    return summaries  # already by name


# -- header ------------------------------------------------------------------------------
def _scale_toggle(state: AppState) -> ft.SegmentedButton:
    def _changed(e) -> None:
        selected = list(getattr(e.control, "selected", []) or [])
        if selected:
            state.set_marks_scale(selected[0])

    return ft.SegmentedButton(
        segments=[
            ft.Segment(value="auto", label=S("marks_scale_auto"), icon=ft.Icons.AUTO_AWESOME_OUTLINED),
            ft.Segment(value="grade", label=S("marks_scale_grade")),
            ft.Segment(value="percent", label=S("marks_scale_percent")),
        ],
        selected=[state.marks_scale()],
        on_change=_changed,
        show_selected_icon=False,
        tooltip=S("marks_scale_tooltip"),
    )


def _sort_toggle(state: AppState) -> ft.SegmentedButton:
    def _changed(e) -> None:
        selected = list(getattr(e.control, "selected", []) or [])
        if selected:
            state.set_marks_sort(selected[0])

    return ft.SegmentedButton(
        segments=[
            ft.Segment(value="name", label=S("marks_sort_name")),
            ft.Segment(value="average", label=S("marks_sort_average")),
            ft.Segment(value="recent", label=S("marks_sort_recent")),
        ],
        selected=[state.marks_sort()],
        on_change=_changed,
        show_selected_icon=False,
    )


def _stats(state: AppState, summaries: list[gr.SubjectSummary], bands) -> ft.Row:
    tok = state.tok
    predicting = any(s.predicting for s in summaries)
    avg, avg_scale = _overall(summaries, bands)
    report = _report_estimate(summaries, bands)
    n_marks = sum(s.real_count for s in summaries)
    n_new = sum(s.new_count for s in summaries)
    suffix = f" · {S('marks_predicted_short')}" if predicting else ""
    return ft.Row(
        [
            C.stat_card(S("marks_average") + suffix, _fmt(avg, avg_scale), tok,
                        kind=gr.kind_for(avg, avg_scale, bands)),
            C.stat_card(S("marks_report") + suffix,
                        f"{report:.2f}" if report is not None else "—", tok,
                        kind=gr.kind_for(report, "grade", bands)),
            C.stat_card(S("marks_total"), str(n_marks), tok),
            C.stat_card(S("marks_new"), str(n_new), tok, kind="ok" if n_new else "info"),
        ],
        spacing=tok.gap,
    )


def _prediction_banner(state: AppState, summaries: list[gr.SubjectSummary]) -> ft.Control | None:
    changed = [s for s in summaries if s.predicting]
    if not changed:
        return None
    tok = state.tok
    return ft.Container(
        content=ft.Row(
            [
                ft.Icon(ft.Icons.SCIENCE_OUTLINED, color=tok.accent, size=20),
                ft.Column(
                    [
                        C.txt(S("marks_prediction_on").format(n=len(changed)), tok, bold=True),
                        C.txt(S("marks_prediction_hint"), tok, size=tok.fs_small, muted=True),
                    ],
                    spacing=2, tight=True, expand=True,
                ),
                C.ghost_button(S("marks_reset_all"), tok, icon=ft.Icons.RESTART_ALT,
                               on_click=lambda e: state.predict_reset()),
            ],
            spacing=10,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        bgcolor=tint(tok.accent, 0.10),
        border=border_all(1, tint(tok.accent, 0.5)),
        border_radius=radius_all(tok.radius_md),
        padding=pad_sym(horizontal=tok.pad, vertical=10),
    )


# -- subject list ------------------------------------------------------------------------
def _subject_card(state: AppState, summary: gr.SubjectSummary, bands) -> ft.Control:
    tok = state.tok
    selected = state.marks_selected == summary.name
    avg_kind = gr.kind_for(summary.current, summary.scale, bands)

    sub_parts = [S("marks_count").format(n=summary.real_count)]
    if summary.last_date:
        sub_parts.append(S("marks_last").format(day=C.cz_day(summary.last_date)))
    if summary.forced:
        sub_parts.append(S("marks_scale_grade") if summary.scale == "grade" else "%")
    title_col = ft.Column(
        [
            ft.Row(
                [C.txt(summary.name, tok, bold=True)]
                + ([C.badge(S("marks_new_badge").format(n=summary.new_count), tok, kind="ok")]
                   if summary.new_count else []),
                spacing=6, wrap=True,
            ),
            C.txt(" · ".join(sub_parts), tok, size=tok.fs_small, faint=True),
        ],
        spacing=2, tight=True, expand=True,
    )

    right: list[ft.Control] = []
    icon = _trend_icon(summary, tok)
    if icon is not None:
        right.append(icon)
    if summary.predicting and summary.average is not None:
        right.append(C.txt(_fmt(summary.average, summary.scale), tok, size=tok.fs_small,
                           faint=True))
        right.append(ft.Icon(ft.Icons.ARROW_FORWARD, size=14, color=tok.faint))
    right.append(C.badge(_fmt(summary.current, summary.scale), tok, kind=avg_kind))
    right.append(ft.Container(
        content=ft.Text(_final_text(summary, bands), size=tok.fs_section,
                        weight=ft.FontWeight.BOLD, color=status_color(avg_kind, tok)
                        if avg_kind != "info" else tok.muted),
        width=34, height=34,
        alignment=align_center(),
        border_radius=radius_all(17),
        bgcolor=tint(status_color(avg_kind, tok), 0.14) if avg_kind != "info" else tok.overlay,
        tooltip=S("marks_final_tooltip"),
    ))

    has_pct = _subject_has_pct(summary)
    newest = [r for r in reversed(summary.rows) if r.state != "removed"]
    chips: list[ft.Control] = [
        _chip(_mark_label(r.mark, r.raw, summary.scale, has_pct), tok,
              _row_kind(summary, r, bands), tooltip=_mark_tooltip(r),
              hypothetical=r.state in ("added", "edited"))
        for r in newest[:MAX_CHIPS]
    ]
    if len(newest) > MAX_CHIPS:
        chips.append(C.txt(f"+{len(newest) - MAX_CHIPS}", tok, size=tok.fs_small, faint=True))
    if summary.planned:
        chips.append(ft.Container(
            content=ft.Row(
                [ft.Icon(ft.Icons.EVENT_OUTLINED, size=13, color=tok.accent),
                 ft.Text(S("marks_planned_count").format(n=len(summary.planned)),
                         size=tok.fs_tiny, color=tok.accent)],
                spacing=3, tight=True,
            ),
            padding=pad_sym(horizontal=4, vertical=2),
        ))

    body = ft.Column(
        [
            ft.Row([title_col, *right], spacing=8,
                   vertical_alignment=ft.CrossAxisAlignment.CENTER),
            *([ft.Row(chips, spacing=5, run_spacing=5, wrap=True)] if chips else []),
        ],
        spacing=8, tight=True,
    )
    return ft.Container(
        content=body,
        bgcolor=tint(tok.accent, 0.08) if selected else tok.card,
        border=border_all(2 if selected else 1, tok.accent if selected else tok.border),
        border_radius=radius_all(tok.radius_md),
        padding=pad_all(tok.pad - (1 if selected else 0)),
        on_click=lambda e, name=summary.name: state.select_marks_subject(name),
        ink=True,
        key=f"marks:subject:{summary.name}",
    )


# -- right panel: overview ------------------------------------------------------------------
def _section(title: str, tok, controls: list[ft.Control], icon=None) -> ft.Control:
    head = [ft.Icon(icon, size=16, color=tok.faint)] if icon else []
    return C.card(
        ft.Row(head + [C.section_header(title, tok)], spacing=6,
               vertical_alignment=ft.CrossAxisAlignment.CENTER),
        *controls,
        tok=tok,
    )


def _recent_marks(state: AppState, summaries, bands, limit: int = 8) -> ft.Control:
    tok = state.tok
    items = []
    for s in summaries:
        for r in s.rows:
            if r.state in ("real", "edited", "removed") and r.date is not None:
                items.append((r.date, s, r))
    items.sort(key=lambda t: t[0], reverse=True)
    rows: list[ft.Control] = []
    for day, s, r in items[:limit]:
        source = r.original if r.state == "edited" and r.original else r.mark
        raw = gr.parse_raw(source.get("Grade"), source.get("Points"))
        value = gr.resolve(raw, s.scale, _subject_has_pct(s), bands)
        caption = str(source.get("Caption") or "").strip()
        rows.append(ft.Container(
            content=ft.Row(
                [
                    ft.Container(
                        content=_chip(_mark_label(source, raw, s.scale, _subject_has_pct(s)),
                                      tok, gr.kind_for(value, s.scale, bands)),
                        width=52,
                    ),
                    ft.Column(
                        [C.txt(s.name, tok, size=tok.fs_small, bold=True),
                         C.txt(" · ".join(p for p in (caption, C.cz_day(day),
                                                      f"{S('marks_weight')} "
                                                      f"{gr.format_weight(r.weight)}") if p),
                               tok, size=tok.fs_tiny, faint=True)],
                        spacing=0, tight=True, expand=True,
                    ),
                ],
                spacing=10, vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            on_click=lambda e, name=s.name: state.select_marks_subject(name),
            padding=pad_sym(vertical=3),
        ))
    if not rows:
        rows.append(C.hint_text(S("marks_no_recent"), tok))
    return _section(S("marks_recent"), tok, rows, icon=ft.Icons.HISTORY)


def _planned_date(mark: dict) -> date | None:
    return parse_cz_date(mark.get("TestDate") or mark.get("Date"))


def _planned_marks(state: AppState, summaries) -> ft.Control | None:
    tok = state.tok
    items = [(_planned_date(m), s, m) for s in summaries for m in s.planned]
    if not items:
        return None
    items.sort(key=lambda t: t[0] or date.max)
    rows = []
    for day, s, m in items:
        caption = str(m.get("Caption") or "").strip() or S("marks_planned_test")
        rows.append(ft.Container(
            content=ft.Row(
                [
                    ft.Container(
                        content=ft.Text(C.cz_day(day) if day else "?", size=tok.fs_small,
                                        weight=ft.FontWeight.W_600, color=tok.accent),
                        width=52,
                    ),
                    ft.Column(
                        [C.txt(s.name, tok, size=tok.fs_small, bold=True),
                         C.txt(f"{caption} · {S('marks_weight')} "
                               f"{gr.format_weight(gr.parse_weight(m.get('Weight')))}",
                               tok, size=tok.fs_tiny, faint=True)],
                        spacing=0, tight=True, expand=True,
                    ),
                ],
                spacing=8, vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            on_click=lambda e, name=s.name: state.select_marks_subject(name),
            padding=pad_sym(vertical=3),
        ))
    return _section(S("marks_planned"), tok, rows, icon=ft.Icons.EVENT_OUTLINED)


def _bands_source_text(state: AppState, source: str) -> str:
    if source == "user":
        return S("marks_bands_src_user")
    if source == "preset":
        from strakalari.core import school_presets as sp
        from strakalari.core.i18n import get_language

        preset = sp.get_preset(str(state.get("school_preset_id", "") or "")) or {}
        return S("marks_bands_src_preset").format(school=sp.preset_title(preset, get_language()))
    return S("marks_bands_src_default")


def _bands_ranges(bands) -> str:
    """``1: 100–87 · 2: 87–72 · … · 5: 40–0`` (the Bakaláři table layout)."""
    tops = (100.0,) + tuple(bands)
    parts = [f"{g}: {tops[g - 1]:g}–{tops[g]:g}" for g in range(1, 5)]
    parts.append(f"5: {tops[4]:g}–0")
    return " · ".join(parts) + " %"


def _bands_card(state: AppState, page) -> ft.Control:
    tok = state.tok
    bands, source = state.marks_bands_source()
    fields: list[ft.TextField] = []
    for grade, bound in enumerate(bands, start=1):
        key = f"marks:band:{grade}"
        f = ft.TextField(
            value=state.draft(key, f"{bound:g}"),
            label=S("marks_band_label").format(grade=grade + 1),
            suffix=ft.Text("%", size=tok.fs_small, color=tok.faint),
            on_change=lambda e, k=key: state.set_draft(k, e.control.value),
            text_size=tok.fs_body, dense=True, expand=True,
            fill_color=tok.surface, border_color=tok.border, focused_border_color=tok.accent,
        )
        fields.append(f)

    def _save(e) -> None:
        try:
            new = [float(str(f.value).replace(",", ".").strip()) for f in fields]
        except (TypeError, ValueError):
            new = []
        if state.set_marks_bands(new):
            state.clear_drafts("marks:band:")
            if page is not None:
                snack(page, S("marks_bands_saved"))
        elif page is not None:
            snack(page, S("marks_bands_invalid"))

    def _reset(e) -> None:
        state.clear_drafts("marks:band:")
        state.set_marks_bands(None)

    buttons: list[ft.Control] = [
        C.ghost_button(S("marks_save"), tok, on_click=_save, icon=ft.Icons.CHECK)]
    if source == "user":
        from strakalari.core import school_presets as sp

        has_preset = sp.preset_marks_bands(str(state.get("school_preset_id", "") or ""))
        buttons.append(ft.TextButton(
            content=ft.Text(S("marks_bands_use_school") if has_preset
                            else S("marks_bands_default"), color=tok.muted),
            on_click=_reset))
    return _section(
        S("marks_bands"), tok,
        [
            ft.Row(
                [ft.Icon(ft.Icons.SCHOOL_OUTLINED if source == "preset" else ft.Icons.TUNE,
                         size=14, color=tok.accent),
                 C.txt(_bands_source_text(state, source), tok, size=tok.fs_small,
                       color=tok.accent)],
                spacing=6, vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            C.txt(_bands_ranges(bands), tok, size=tok.fs_small, muted=True),
            C.hint_text(S("marks_bands_hint"), tok),
            ft.Row(fields, spacing=6),
            ft.Row(buttons, spacing=8),
        ],
        icon=ft.Icons.PERCENT,
    )


def _overview(state: AppState, page, summaries, bands) -> list[ft.Control]:
    tok = state.tok
    out: list[ft.Control] = [
        ft.Container(
            content=ft.Row(
                [ft.Icon(ft.Icons.TOUCH_APP_OUTLINED, size=18, color=tok.faint),
                 C.txt(S("marks_pick_hint"), tok, size=tok.fs_small, muted=True)],
                spacing=8, vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            padding=pad_sym(horizontal=4, vertical=2),
        ),
        _recent_marks(state, summaries, bands),
    ]
    planned = _planned_marks(state, summaries)
    if planned is not None:
        out.append(planned)
    out.append(_bands_card(state, page))
    return out


# -- right panel: subject detail -----------------------------------------------------------
def _trend_chart(summary: gr.SubjectSummary, tok, bands) -> ft.Control | None:
    history = summary.history
    if len(history) < 2:
        return None
    bars = []
    for day, avg in history[-24:]:
        if summary.scale == "percent":
            ratio = avg / 100.0
        else:
            ratio = (5.0 - avg) / 4.0
        ratio = max(0.06, min(1.0, ratio))
        color = status_color(gr.kind_for(avg, summary.scale, bands), tok)
        bars.append(ft.Container(
            content=ft.Column(
                [ft.Container(expand=True),
                 ft.Container(height=round(64 * ratio), bgcolor=color,
                              border_radius=radius_all(3))],
                spacing=0,
            ),
            height=64,
            expand=True,
            tooltip=f"{C.cz_day(day) if day else '?'} · {_fmt(avg, summary.scale)}",
        ))
    return ft.Column(
        [
            C.txt(S("marks_trend"), tok, size=tok.fs_small, muted=True),
            ft.Container(content=ft.Row(bars, spacing=3,
                                        vertical_alignment=ft.CrossAxisAlignment.END),
                         bgcolor=tok.surface, border_radius=radius_all(tok.radius_sm),
                         padding=pad_all(6)),
        ],
        spacing=4, tight=True,
    )


def _scale_picker(state: AppState, summary: gr.SubjectSummary) -> ft.Control:
    tok = state.tok
    current = state.marks_subject_scales().get(summary.name, "auto")

    def _changed(e) -> None:
        selected = list(getattr(e.control, "selected", []) or [])
        if selected:
            state.set_subject_scale(summary.name, selected[0])

    def name(scale: str) -> str:
        return S("marks_scale_grade") if scale == "grade" else S("marks_scale_percent")

    if current == "auto" and summary.forced:
        hint = S("marks_scale_global").format(scale=name(summary.scale))
    else:
        hint = S("marks_detected").format(scale=name(summary.detected))
    return ft.Column(
        [
            ft.SegmentedButton(
                segments=[
                    ft.Segment(value="auto", label=S("marks_scale_auto")),
                    ft.Segment(value="grade", label=S("marks_scale_grade")),
                    ft.Segment(value="percent", label=S("marks_scale_percent")),
                ],
                selected=[current],
                on_change=_changed,
                show_selected_icon=False,
            ),
            C.txt(hint, tok, size=tok.fs_tiny, faint=True),
        ],
        spacing=4, tight=True,
    )


def _detail_stats(summary: gr.SubjectSummary, tok, bands) -> ft.Row:
    def tile(label: str, value: str, kind: str) -> ft.Control:
        color = status_color(kind, tok) if kind != "info" else tok.text
        return ft.Container(
            content=ft.Column(
                [C.txt(label, tok, size=tok.fs_tiny, muted=True),
                 ft.Text(value, size=tok.fs_section, weight=ft.FontWeight.BOLD, color=color)],
                spacing=1, tight=True,
            ),
            bgcolor=tok.surface,
            border_radius=radius_all(tok.radius_sm),
            padding=pad_sym(horizontal=10, vertical=6),
            expand=True,
        )

    tiles = [tile(S("marks_average"), _fmt(summary.average, summary.scale),
                  gr.kind_for(summary.average, summary.scale, bands))]
    if summary.predicting:
        tiles.append(tile(S("marks_predicted"), _fmt(summary.predicted, summary.scale),
                          gr.kind_for(summary.predicted, summary.scale, bands)))
    tiles.append(tile(S("marks_final"), _final_text(summary, bands),
                      gr.kind_for(summary.current, summary.scale, bands)))
    return ft.Row(tiles, spacing=6)


def _needed_card(state: AppState, summary: gr.SubjectSummary, bands) -> ft.Control:
    tok = state.tok
    calc = state.marks_calc(summary.name)
    current_final = gr.final_grade(summary.current, summary.scale, bands)
    # Default goal: one grade better than where the subject is heading.
    try:
        target = int(calc.get("target") or max(1, (current_final or 2) - 1))
    except (TypeError, ValueError):
        target = 1
    target = max(1, min(4, target))
    fallback_weight = gr.default_weight(summary)
    weight_text = calc.get("weight") or gr.format_weight(fallback_weight)
    try:
        weight = float(weight_text.replace(",", "."))
    except ValueError:
        weight = fallback_weight
    if not weight > 0:
        weight = fallback_weight

    target_dd = ft.Dropdown(
        options=[ft.dropdown.Option(str(g), S("marks_target_option").format(grade=g))
                 for g in (1, 2, 3, 4)],
        value=str(target),
        on_select=lambda e: state.set_marks_calc(summary.name, target=e.control.value),
        label=S("marks_target"),
        text_size=tok.fs_body, dense=True, expand=True,
        fill_color=tok.surface, border_color=tok.border, focused_border_color=tok.accent,
    )
    weight_field = ft.TextField(
        value=weight_text, label=S("marks_weight"), width=90, dense=True,
        on_blur=lambda e: state.set_marks_calc(summary.name, weight=e.control.value),
        on_submit=lambda e: state.set_marks_calc(summary.name, weight=e.control.value),
        text_size=tok.fs_body, fill_color=tok.surface,
        border_color=tok.border, focused_border_color=tok.accent,
    )

    need = gr.needed_for(summary.rows, summary.scale, target, weight, bands)
    w_text = gr.format_weight(weight)
    if need.status == "any":
        msg, kind = S("marks_need_any").format(grade=target), "ok"
    elif need.status == "need":
        mark = (f"{need.value:g} %" if summary.scale == "percent"
                else gr.format_grade_step(need.value))
        key = "marks_need_pct" if summary.scale == "percent" else "marks_need_grade"
        msg, kind = S(key).format(mark=mark, grade=target), "warning"
        if summary.scale == "grade" and need.value >= 3 or \
                summary.scale == "percent" and need.value <= bands[2]:
            kind = "ok"
    elif need.count:
        best = "100 %" if summary.scale == "percent" else "1"
        msg, kind = S("marks_need_many").format(n=need.count, mark=best, weight=w_text,
                                                grade=target), "critical"
    else:
        msg, kind = S("marks_need_impossible").format(grade=target), "critical"
    return _section(
        S("marks_need_title"), tok,
        [
            ft.Row([target_dd, weight_field], spacing=8),
            ft.Container(
                content=C.txt(msg, tok, size=tok.fs_small, color=status_color(kind, tok)),
                bgcolor=tint(status_color(kind, tok), 0.10),
                border_radius=radius_all(tok.radius_sm),
                padding=pad_sym(horizontal=10, vertical=8),
            ),
        ],
        icon=ft.Icons.FLAG_OUTLINED,
    )


def _edit_row(state: AppState, page, summary: gr.SubjectSummary, row: gr.MarkRow) -> ft.Control:
    tok = state.tok
    g_key, w_key = "marks:edit:grade", "marks:edit:weight"
    grade_f = ft.TextField(
        value=state.draft(g_key, row.text), label=S("marks_mark"), dense=True, expand=True,
        autofocus=True, on_change=lambda e: state.set_draft(g_key, e.control.value),
        text_size=tok.fs_body, fill_color=tok.surface, border_color=tok.border,
        focused_border_color=tok.accent,
    )
    weight_f = ft.TextField(
        value=state.draft(w_key, gr.format_weight(row.weight)), label=S("marks_weight"),
        width=80, dense=True, on_change=lambda e: state.set_draft(w_key, e.control.value),
        text_size=tok.fs_body, fill_color=tok.surface, border_color=tok.border,
        focused_border_color=tok.accent,
    )

    def _save(e=None) -> None:
        typed = (str(grade_f.value or ""), str(weight_f.value or ""))
        state.clear_drafts("marks:edit:")
        if not state.predict_edit(summary.name, row.key, *typed):
            state.set_draft(g_key, typed[0])
            state.set_draft(w_key, typed[1])
            if page is not None:
                snack(page, S("marks_invalid"))

    def _cancel(e=None) -> None:
        state.clear_drafts("marks:edit:")
        state.set_marks_editing(None)

    grade_f.on_submit = _save
    weight_f.on_submit = _save
    return ft.Container(
        content=ft.Row(
            [grade_f, weight_f,
             ft.IconButton(ft.Icons.CHECK, icon_color=tok.green, icon_size=18,
                           tooltip=S("marks_save"), on_click=_save),
             ft.IconButton(ft.Icons.CLOSE, icon_size=18, tooltip=S("cancel"),
                           on_click=_cancel)],
            spacing=4, vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        bgcolor=tint(tok.accent, 0.08),
        border_radius=radius_all(tok.radius_sm),
        padding=pad_sym(horizontal=6, vertical=6),
    )


def _mark_row(state: AppState, page, summary: gr.SubjectSummary, row: gr.MarkRow,
              bands) -> ft.Control:
    tok = state.tok
    if state.marks_editing == row.key:
        return _edit_row(state, page, summary, row)
    mark = row.mark
    has_pct = _subject_has_pct(summary)
    caption = str(mark.get("Caption") or "").strip()
    note = str(mark.get("Note") or "").strip()

    title = caption or (S("marks_hypothetical") if row.state == "added" else S("marks_no_topic"))
    details = []
    if row.state != "added":
        details.append(_day(mark.get("Date")))
        if mark.get("TestDate"):
            details.append(S("marks_written").format(day=_day(mark.get("TestDate"))))
    details.append(f"{S('marks_weight')} {gr.format_weight(row.weight)}")
    if row.raw is not None and row.value is not None:
        native = "percent" if (row.raw.kind == "percent" or (
            row.raw.kind == "small" and summary.scale == "percent" and has_pct)) else "grade"
        if native != summary.scale:
            details.append(f"≈ {_fmt(row.value, summary.scale)}")
    elif row.state != "removed":
        details.append(S("marks_not_counted"))
    if row.state == "edited" and row.original is not None:
        orig = row.original
        details.append(S("marks_was").format(
            mark=_mark_label(orig, gr.parse_raw(orig.get("Grade"), orig.get("Points")),
                             summary.scale, has_pct),
            weight=gr.format_weight(gr.parse_weight(orig.get("Weight")))))

    text_col = ft.Column(
        [C.txt(title, tok, size=tok.fs_small, bold=bool(caption) or row.state == "added",
               color=tok.accent if row.state == "added" else None),
         C.txt(" · ".join(d for d in details if d), tok, size=tok.fs_tiny, faint=True)]
        + ([C.txt(note, tok, size=tok.fs_tiny, muted=True)] if note else []),
        spacing=1, tight=True, expand=True,
    )

    def _start_edit(e) -> None:
        state.clear_drafts("marks:edit:")
        state.set_marks_editing(row.key)

    actions: list[ft.Control] = []
    if row.state == "removed":
        actions.append(ft.IconButton(ft.Icons.RESTORE, icon_size=18, tooltip=S("restore"),
                                     on_click=lambda e: state.predict_restore(summary.name,
                                                                              row.key)))
    else:
        if row.state == "edited":
            actions.append(ft.IconButton(
                ft.Icons.RESTORE, icon_size=18, tooltip=S("marks_restore_real"),
                on_click=lambda e: state.predict_restore(summary.name, row.key)))
        actions.append(ft.IconButton(ft.Icons.EDIT_OUTLINED, icon_size=18,
                                     tooltip=S("marks_edit"), on_click=_start_edit))
        actions.append(ft.IconButton(
            ft.Icons.DELETE_OUTLINE, icon_size=18,
            tooltip=S("marks_delete") if row.state == "added" else S("marks_leave_out"),
            on_click=lambda e: state.predict_remove(summary.name, row.key)))

    return ft.Container(
        content=ft.Row(
            [ft.Container(content=_chip(_mark_label(mark, row.raw, summary.scale, has_pct), tok,
                                        _row_kind(summary, row, bands),
                                        hypothetical=row.state in ("added", "edited")),
                          width=58),
             text_col, *actions],
            spacing=6, vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        opacity=0.45 if row.state == "removed" else 1.0,
        padding=pad_sym(vertical=2),
    )


def _add_form(state: AppState, page, summary: gr.SubjectSummary) -> ft.Control:
    tok = state.tok
    g_key = f"marks:add:grade:{summary.name}"
    w_key = f"marks:add:weight:{summary.name}"
    grade_f = ft.TextField(
        value=state.draft(g_key), label=S("marks_mark"),
        hint_text="85 %" if summary.scale == "percent" else "1, 2-, 3",
        dense=True, expand=True, on_change=lambda e: state.set_draft(g_key, e.control.value),
        text_size=tok.fs_body, fill_color=tok.surface, border_color=tok.border,
        focused_border_color=tok.accent,
    )
    weight_f = ft.TextField(
        value=state.draft(w_key, gr.format_weight(gr.default_weight(summary))),
        label=S("marks_weight"), width=80, dense=True,
        on_change=lambda e: state.set_draft(w_key, e.control.value),
        text_size=tok.fs_body, fill_color=tok.surface, border_color=tok.border,
        focused_border_color=tok.accent,
    )

    def _add(e=None) -> None:
        typed = str(grade_f.value or "")
        # Cleared before the add re-renders, so the fresh field is empty.
        state.drafts.pop(g_key, None)
        if not state.predict_add(summary.name, typed, weight_f.value):
            state.set_draft(g_key, typed)
            if page is not None:
                snack(page, S("marks_invalid"))

    grade_f.on_submit = _add
    weight_f.on_submit = _add
    return ft.Row(
        [grade_f, weight_f,
         C.primary_button(S("marks_add"), tok, on_click=_add, icon=ft.Icons.ADD)],
        spacing=6, vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )


def _planned_rows(state: AppState, summary: gr.SubjectSummary) -> list[ft.Control]:
    tok = state.tok
    rows: list[ft.Control] = []
    for m in sorted(summary.planned, key=lambda m: _planned_date(m) or date.max):
        day = _planned_date(m)
        weight = gr.format_weight(gr.parse_weight(m.get("Weight")))
        caption = str(m.get("Caption") or "").strip() or S("marks_planned_test")

        rows.append(ft.Row(
            [ft.Icon(ft.Icons.EVENT_OUTLINED, size=16, color=tok.accent),
             ft.Column([C.txt(caption, tok, size=tok.fs_small, bold=True),
                        C.txt(f"{_day(day) if day else '?'} · {S('marks_weight')} {weight}",
                              tok, size=tok.fs_tiny, faint=True)],
                       spacing=0, tight=True, expand=True),
             ft.TextButton(content=ft.Text(S("marks_use_weight"), color=tok.accent,
                                           size=tok.fs_small), on_click=lambda e, w=weight: state.use_planned_weight(summary.name, w))],
            spacing=8, vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ))
    return rows


def _detail(state: AppState, page, summary: gr.SubjectSummary, bands) -> list[ft.Control]:
    tok = state.tok
    head = ft.Row(
        [
            ft.Column([C.txt(summary.name, tok, size=tok.fs_section, bold=True),
                       C.txt(S("marks_count").format(n=summary.real_count), tok,
                             size=tok.fs_small, faint=True)],
                      spacing=2, tight=True, expand=True),
            ft.IconButton(ft.Icons.CLOSE, icon_size=18, tooltip=S("close"),
                          on_click=lambda e: state.select_marks_subject(None)),
        ],
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )
    top: list[ft.Control] = [head, _scale_picker(state, summary),
                             _detail_stats(summary, tok, bands)]
    chart = _trend_chart(summary, tok, bands)
    if chart is not None:
        top.append(chart)
    out: list[ft.Control] = [C.card(*top, tok=tok),
                             T.anchor(state, "marks_need", _needed_card(state, summary, bands))]

    rows = list(reversed([r for r in summary.rows if r.state != "added"]))
    added = [r for r in summary.rows if r.state == "added"]
    mark_controls: list[ft.Control] = [_mark_row(state, page, summary, r, bands)
                                       for r in added + rows]
    if not mark_controls:
        mark_controls.append(C.hint_text(S("marks_none_yet"), tok))
    predictor_head = ft.Row(
        [ft.Icon(ft.Icons.SCIENCE_OUTLINED, size=16, color=tok.faint),
         ft.Container(content=C.section_header(S("marks_predictor"), tok), expand=True)]
        + ([ft.TextButton(content=ft.Text(S("marks_reset"), color=tok.accent,
                                          size=tok.fs_small),
                          on_click=lambda e: state.predict_reset(summary.name))]
           if summary.predicting else []),
        spacing=6, vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )
    out.append(T.anchor(state, "marks_predict", C.card(
        predictor_head,
        C.hint_text(S("marks_predictor_hint"), tok),
        _add_form(state, page, summary),
        C.divider(tok),
        *mark_controls,
        tok=tok,
    )))
    planned = _planned_rows(state, summary)
    if planned:
        out.append(_section(S("marks_planned"), tok, planned, icon=ft.Icons.EVENT_OUTLINED))
    return out


# -- build ------------------------------------------------------------------------------------
def build(state: AppState, page: ft.Page) -> ft.Control:
    tok = state.tok
    grades = state.grades()
    if grades:
        T.offer(state, "marks")
    header = C.header_row(tok, S("marks_title"), state.updated_label,
                          actions=[T.anchor(state, "marks_scale", _scale_toggle(state))]
                          if grades else None)
    blocks: list[ft.Control] = [header]

    if not grades:
        blocks.append(C.empty_state(S("no_data"), tok))
        if state.demo_mode:
            blocks.append(C.txt(S("need_credentials"), tok, size=tok.fs_small, faint=True))
        return ft.Column(blocks, spacing=tok.gap, expand=True)

    bands = state.marks_bands()
    summaries = state.marks_summaries()
    by_name = {s.name: s for s in summaries}
    selected = by_name.get(state.marks_selected or "")

    blocks.append(T.anchor(state, "marks_stats", _stats(state, summaries, bands)))
    banner = _prediction_banner(state, summaries)
    if banner is not None:
        blocks.append(banner)

    cards = [_subject_card(state, s, bands) for s in _sorted(summaries, state.marks_sort(), bands)]
    if cards:
        cards[0] = T.anchor(state, "marks_subject", cards[0])
    left = ft.Column(
        [
            ft.Row([C.txt(S("marks_subjects_n").format(n=len(summaries)), tok, bold=True,
                          size=tok.fs_small),
                    ft.Container(expand=True), _sort_toggle(state)],
                   vertical_alignment=ft.CrossAxisAlignment.CENTER),
            C.scrollable(state, "marks", cards + [C.bottom_spacer(tok)],
                         spacing=tok.gap // 2, expand=True,
                         horizontal_alignment=ft.CrossAxisAlignment.STRETCH),
        ],
        spacing=tok.gap // 2, expand=True,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )
    panel_controls = (_detail(state, page, selected, bands) if selected is not None
                      else _overview(state, page, summaries, bands))
    panel = C.scrollable(
        state, f"marks:panel:{selected.name if selected else ''}",
        panel_controls + [C.bottom_spacer(tok)],
        spacing=tok.gap // 2, expand=True,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )
    blocks.append(ft.Row(
        [ft.Container(content=left, expand=True),
         ft.Container(content=panel, width=PANEL_WIDTH)],
        spacing=tok.gap, expand=True,
        vertical_alignment=ft.CrossAxisAlignment.STRETCH,
    ))
    return ft.Column(blocks, spacing=tok.gap, expand=True)
