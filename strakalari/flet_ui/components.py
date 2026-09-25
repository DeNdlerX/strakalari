"""Reusable component kit — every screen must build UI from these.

No view may hardcode colors, radii, or spacing. If a pattern is missing
here, add it here (so both themes get it automatically) instead of
inventing a one-off in a view.
"""

from __future__ import annotations

from typing import Callable

import flet as ft

from strakalari.core.models import parse_cz_date

from .theme import Tokens, align_center, border_all, pad_all, pad_sym, radius_all, status_color


#: Where to get a free Gemini API key (Google AI Studio, no card needed).
AI_STUDIO_URL = "https://aistudio.google.com/apikey"


async def open_url(page, url: str) -> None:
    """Opens ``url`` in the system browser.

    ``Page.launch_url`` is a coroutine in this Flet version — calling it
    without ``await`` silently does nothing (the coroutine is discarded),
    which is why every caller must ``await`` this helper from an
    ``async def`` click handler. Falls back to :mod:`webbrowser` so the
    link still opens on desktop when the Flet client can't handle it.
    """
    url = str(url or "")
    if not url:
        return
    try:
        await page.launch_url(url)
        return
    except Exception:
        pass
    try:
        import webbrowser

        webbrowser.open(url)
    except Exception:
        pass


def txt(
    value: str,
    tok: Tokens,
    size: int | None = None,
    bold: bool = False,
    color: str | None = None,
    muted: bool = False,
    faint: bool = False,
) -> ft.Text:
    if faint:
        color = color or tok.faint
    elif muted:
        color = color or tok.muted
    return ft.Text(
        value,
        size=size or tok.fs_body,
        weight=ft.FontWeight.BOLD if bold else ft.FontWeight.NORMAL,
        color=color or tok.text,
    )


def title(value: str, tok: Tokens) -> ft.Text:
    return txt(value, tok, size=tok.fs_title, bold=True)


def section_header(value: str, tok: Tokens) -> ft.Text:
    return txt(value.upper(), tok, size=tok.fs_small, bold=True, faint=True)


def card(*children: ft.Control, tok: Tokens, padding: int | None = None) -> ft.Container:
    # The inner Row (max main-axis size) guarantees full-width cards even
    # when content is plain text; without it text-only cards shrink-wrap.
    # STRETCH aligns children (inputs, dividers) to the full card width —
    # safe here because the cross axis (horizontal) is always bounded.
    inner = ft.Column(
        list(children),
        spacing=tok.gap // 2,
        tight=True,
        expand=True,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )
    return ft.Container(
        content=ft.Row([inner], vertical_alignment=ft.CrossAxisAlignment.START),
        bgcolor=tok.card,
        border=border_all(1, tok.border),
        border_radius=radius_all(tok.radius_md),
        padding=pad_all(padding if padding is not None else tok.pad),
    )


def cz_day(value) -> str:
    """Czech short date: '7. 9.' — accepts date or DD.MM.YYYY string."""
    from datetime import date as _date

    day = value if isinstance(value, _date) else parse_cz_date(value)
    if day is None:
        return str(value or "?")
    return f"{day.day}. {day.month}."


def cz_day_year(value) -> str:
    from datetime import date as _date

    day = value if isinstance(value, _date) else parse_cz_date(value)
    if day is None:
        return str(value or "?")
    return f"{day.day}. {day.month}. {day.year}"


CZECH_DAY_NAMES = ["Pondělí", "Úterý", "Středa", "Čtvrtek", "Pátek", "Sobota", "Neděle"]
ENGLISH_DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
CZECH_DAY_NAMES_SHORT = ["Po", "Út", "St", "Čt", "Pá", "So", "Ne"]
ENGLISH_DAY_NAMES_SHORT = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def day_name(value, short: bool = False) -> str:
    """Weekday name in the app language — accepts date or DD.MM.YYYY string.

    ``strftime("%A")`` follows the OS display locale, so it disagrees with
    the in-app language on foreign-locale machines; this never does.
    """
    from datetime import date as _date

    from strakalari.core.i18n import get_language

    day = value if isinstance(value, _date) else parse_cz_date(value)
    if day is None:
        return str(value or "?")
    try:
        idx = day.weekday()
    except AttributeError:
        return str(value or "?")
    en = get_language() == "en"
    if short:
        return (ENGLISH_DAY_NAMES_SHORT if en else CZECH_DAY_NAMES_SHORT)[idx]
    return (ENGLISH_DAY_NAMES if en else CZECH_DAY_NAMES)[idx]


def short_time(raw: str) -> str:
    """Strips the leading period number from both time formats.

    Demo: ``1. 8:00 - 8:45`` -> ``8:00 - 8:45``.
    Real cache: ``3 (10:05 - 10:50)`` -> ``10:05 - 10:50``.
    """
    import re

    text = str(raw or "").strip()
    m = re.match(r"^\s*\d+\s*\((.*)\)\s*$", text)
    if m:
        return m.group(1).strip()
    return re.sub(r"^\s*\d+\.\s*", "", text).strip()


def teacher_surname(full_name: str) -> str:
    """'Mgr. Jana Tláskalová' -> 'Tláskalová' (titles stripped)."""
    tokens = [t.strip().rstrip(",") for t in str(full_name or "").split() if t.strip()]
    suffixes = {
        "ph.d.", "phd", "csc.", "csc", "drsc.", "drsc", "dis.", "dis", "mba",
        "th.d.", "thd", "dr.", "mgr.", "ing.", "bc.", "mudr.", "judr.", "paeddr.",
    }
    while tokens and tokens[0].lower() in suffixes:
        tokens.pop(0)
    while tokens and tokens[-1].lower() in suffixes:
        tokens.pop()
    return tokens[-1] if tokens else ""


def lesson_kind(status: str) -> str:
    """Maps a normalized lesson status to a badge kind.

    Every actionable state gets its own color: absent (red, must excuse)
    vs late/early/soon (orange, partial) vs cancelled (grey, no action).
    """
    return {
        "": "ok",
        "late": "late",
        "early": "late",
        "soon": "late",
        "absent": "critical",
        "cancelled": "cancelled",
        "excused": "sent",
    }.get(str(status or "").lower(), "info")


def badge(text: str, tok: Tokens, kind: str = "info") -> ft.Container:
    color = status_color(kind, tok) if kind in (
        "ok", "warning", "critical", "late", "cancelled", "pending", "sent", "failed",
    ) else tok.accent
    return ft.Container(
        content=ft.Text(text, size=tok.fs_tiny, weight=ft.FontWeight.W_600, color=color),
        border=border_all(1, color),
        border_radius=radius_all(tok.radius_sm),
        padding=pad_sym(horizontal=8, vertical=3),
    )


def meter(value_pct: float, tok: Tokens, kind: str = "ok", width: int = 140) -> ft.Row:
    ratio = max(0.0, min(1.0, value_pct / 100.0))
    fill = max(1, round(ratio * 100))
    bar = ft.Row(
        [
            ft.Container(
                bgcolor=status_color(kind, tok),
                border_radius=radius_all(4),
                expand=fill,
            ),
            ft.Container(expand=max(1, 100 - fill)),
        ],
        spacing=0,
        expand=True,
    )
    track = ft.Container(
        content=bar,
        bgcolor=tok.overlay,
        border_radius=radius_all(4),
        height=8,
        width=width,
        padding=pad_all(0),
    )
    return ft.Row(
        [
            track,
            txt(f"{value_pct:.1f} %", tok, size=tok.fs_small, muted=True),
        ],
        spacing=8,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )


def stat_card(label: str, value: str, tok: Tokens, kind: str = "info") -> ft.Container:
    color = status_color(kind, tok) if kind in (
        "ok", "warning", "critical", "late", "cancelled", "pending", "sent", "failed",
    ) else tok.accent
    return ft.Container(
        content=ft.Column(
            [
                txt(label, tok, size=tok.fs_small, muted=True),
                ft.Text(value, size=tok.fs_title, weight=ft.FontWeight.BOLD, color=color),
            ],
            spacing=2,
            tight=True,
        ),
        bgcolor=tok.card,
        border=border_all(1, tok.border),
        border_radius=radius_all(tok.radius_md),
        padding=pad_all(tok.pad),
        expand=True,
    )


def primary_button(
    text: str, tok: Tokens, on_click: Callable | None = None, icon: str | None = None,
    disabled: bool = False,
) -> ft.Button:
    # Explicit colors override Flutter's disabled look, so a disabled
    # button needs its own muted colors or it still looks clickable.
    fg = tok.faint if disabled else tok.accent_text
    return ft.Button(
        content=ft.Text(text, color=fg),
        icon=icon,
        on_click=on_click,
        bgcolor=tok.overlay if disabled else tok.accent,
        color=fg,
        disabled=disabled,
    )


def ghost_button(
    text: str, tok: Tokens, on_click: Callable | None = None, icon: str | None = None
) -> ft.OutlinedButton:
    return ft.OutlinedButton(content=ft.Text(text, color=tok.text), icon=icon, on_click=on_click)


def danger_button(
    text: str, tok: Tokens, on_click: Callable | None = None
) -> ft.TextButton:
    return ft.TextButton(content=ft.Text(text, color=tok.red), on_click=on_click)


def _scroll_recorder(state, key: str):
    """Builds the ``on_scroll`` handler tracking one scroller's offset.

    Flet only fires ``on_scroll`` for user-driven moves, so restoring a
    saved offset programmatically never feeds back into the record.
    The handler is defensive: test doubles and older Flet payloads may
    carry the pixels under ``e.pixels``, ``e.data`` or a plain dict.
    """

    def _handler(e) -> None:
        try:
            px = getattr(e, "pixels", None)
            if px is None:
                data = getattr(e, "data", None)
                px = getattr(data, "pixels", None) if data is not None else None
            if px is None and isinstance(e, dict):
                px = e.get("pixels")
            if px is None:
                return
            state.__dict__.setdefault("_scroll_offsets", {})[key] = float(px)
        except Exception:
            pass

    return _handler


def begin_render(state) -> None:
    """Starts a render pass: forgets which scrollers the last one built."""
    try:
        state.__dict__["_scroll_active"] = set()
    except Exception:
        pass


def _is_mounted(control, page) -> bool:
    """True when ``control`` is registered in the page's live session."""
    try:
        index = page.session.index
    except Exception:
        # No session to ask (tests, older Flet): don't block the restore.
        return True
    try:
        return index.get(control._i) is control
    except Exception:
        return False


def wake_ui(page) -> None:
    """Flushes updates made off the event-loop thread to the window.

    Flet's socket transport queues outgoing patches with
    ``asyncio.Queue.put_nowait``, which is not thread-safe: called from a
    worker thread it never wakes the event loop, so the patch sits in the
    queue until something else does (typically the user's next click).
    Background renders were therefore laggy and the Chrome download bar
    only moved when the window was clicked. Scheduling a no-op with
    ``call_soon_threadsafe`` wakes the loop, which then sends everything
    queued. No-op on the loop thread itself and without a live session.
    """
    try:
        loop = page.session.connection.loop
    except Exception:
        return
    if loop is None:
        return
    try:
        import asyncio

        if asyncio.get_running_loop() is loop:
            return
    except RuntimeError:
        pass  # worker thread: no running loop here
    try:
        loop.call_soon_threadsafe(lambda: None)
    except Exception:
        pass  # loop closed (window gone): nothing to flush


def restore_scroll_offsets(state, page=None) -> None:
    """Re-applies tracked scroll offsets after a full re-render.

    Views rebuild fresh children on every state change and the Shell
    re-mounts them under new parents, so even a reused scrollable
    container remounts at offset 0. The offsets recorded via
    ``on_scroll`` are pushed back with ``scroll_to`` (dispatched through
    ``page.run_task``, the supported sync -> async bridge). Missing
    pages, unmounted columns and short content are all no-ops.
    """
    try:
        offsets = dict(state.__dict__.get("_scroll_offsets", {}) or {})
    except Exception:
        return
    if not offsets:
        return
    try:
        cols = state.__dict__.get("_scroll_cols", {}) or {}
        # Only scrollers the current render actually built: cached ones
        # from other screens are detached, and a scroll_to racing their
        # removal gets a reply for an unregistered control, which kills
        # Flet's receive loop (the UI stops responding).
        active = set(state.__dict__.get("_scroll_active", ()) or ())
    except Exception:
        return
    if page is None:
        page = getattr(state, "_page", None)
    run_task = getattr(page, "run_task", None)
    if not callable(run_task):
        return
    for k, px in offsets.items():
        if k not in active:
            continue
        try:
            offset = float(px)
        except (TypeError, ValueError):
            continue
        if not offset or offset <= 0:
            continue
        col = cols.get(k)
        if col is None:
            continue
        if not callable(getattr(col, "scroll_to", None)):
            continue
        if not _is_mounted(col, page):
            continue

        async def _one(_c=col, _o=offset) -> None:
            try:
                await _c.scroll_to(offset=_o)
            except Exception:
                pass

        try:
            run_task(_one)
        except Exception:
            pass


def scrollable(state, key: str, controls, make=None, **kwargs):
    """A scrollable container that survives re-renders without jumping.

    Views rebuild fresh children on every state change; a brand-new
    scrollable would mount at offset 0 each time (the list jumps back to
    the top on every lunch pick or toggle). Reusing the container object
    per ``key`` preserves identity, a stable ``key`` lets Flutter keep
    the viewport state across re-mounts, and the ``on_scroll`` record
    plus :func:`restore_scroll_offsets` pushes the exact pixel offset
    back after ``page.update()``. ``make`` is ft.Column (default) or
    ft.Row for horizontal scrollers.
    """
    make = make or ft.Column
    kwargs.setdefault("scroll", ft.ScrollMode.AUTO)
    cache = state.__dict__.setdefault("_scroll_cols", {})
    state.__dict__.setdefault("_scroll_offsets", {})
    state.__dict__.setdefault("_scroll_active", set()).add(key)
    col = cache.get(key)
    if col is None or not isinstance(col, make):
        col = make(**kwargs)
        try:
            col.key = key
        except Exception:
            pass
        try:
            col.on_scroll = _scroll_recorder(state, key)
        except Exception:
            pass
        try:
            if getattr(col, "scroll_interval", None) == 10:
                col.scroll_interval = 50
        except Exception:
            pass
        cache[key] = col
    else:
        for name, value in kwargs.items():
            if name in ("key", "on_scroll"):
                continue
            try:
                setattr(col, name, value)
            except Exception:
                pass
        try:
            if getattr(col, "key", None) != key:
                col.key = key
        except Exception:
            pass
        try:
            if getattr(col, "on_scroll", None) is None:
                col.on_scroll = _scroll_recorder(state, key)
        except Exception:
            pass
    col.controls = list(controls) if isinstance(controls, (list, tuple)) else [controls]
    return col


def field(
    tok: Tokens,
    label: str,
    value: str = "",
    password: bool = False,
    multiline: bool = False,
    hint: str = "",
    on_change: Callable | None = None,
    on_blur: Callable | None = None,
    on_submit: Callable | None = None,
) -> ft.TextField:
    return ft.TextField(
        label=label,
        value=value,
        password=password,
        can_reveal_password=password,
        multiline=multiline,
        min_lines=3 if multiline else 1,
        hint_text=hint,
        on_change=on_change,
        on_blur=on_blur,
        on_submit=on_submit,
        text_size=tok.fs_body,
        fill_color=tok.surface,
        border_color=tok.border,
        focused_border_color=tok.accent,
    )


def labeled_field(
    tok: Tokens,
    label: str,
    value: str = "",
    password: bool = False,
    multiline: bool = False,
    hint: str = "",
    on_change: Callable | None = None,
    on_blur: Callable | None = None,
    on_submit: Callable | None = None,
) -> ft.Column:
    """Static caption above the input (no floating label).

    Floating labels overlap the input border until filled, which reads as
    "empty/unset" even when a value is stored. A fixed caption never moves.
    """
    box = ft.TextField(
        value=value,
        password=password,
        can_reveal_password=password,
        multiline=multiline,
        min_lines=3 if multiline else 1,
        hint_text=hint or label,
        on_change=on_change,
        on_blur=on_blur,
        on_submit=on_submit,
        text_size=tok.fs_body,
        fill_color=tok.surface,
        border_color=tok.border,
        focused_border_color=tok.accent,
    )
    caption = txt(label, tok, size=tok.fs_small, bold=True)
    return ft.Column([caption, box], spacing=4, tight=True,
                     horizontal_alignment=ft.CrossAxisAlignment.STRETCH)


def radio_dot(tok: Tokens, selected: bool, size: int = 20) -> ft.Container:
    """Radio-circle picker dot (lunches, single-choice rows)."""
    inner = ft.Container(
        width=size - 10,
        height=size - 10,
        bgcolor=tok.accent if selected else None,
        border_radius=radius_all((size - 10) // 2),
    )
    return ft.Container(
        content=ft.Row([inner], alignment=ft.MainAxisAlignment.CENTER,
                       vertical_alignment=ft.CrossAxisAlignment.CENTER),
        width=size,
        height=size,
        border=border_all(2, tok.accent if selected else tok.faint),
        border_radius=radius_all(size // 2),
        padding=pad_all(0),
    )


def change_badge(tok: Tokens, tooltip: str = "") -> ft.Container:
    """Short 'Změna' pill — never renders raw note text (no clipping)."""
    from .strings import S

    return ft.Container(
        content=ft.Text(
            S("real_change"),
            size=tok.fs_tiny,
            weight=ft.FontWeight.W_600,
            color=tok.accent,
            max_lines=1,
            overflow=ft.TextOverflow.ELLIPSIS,
        ),
        border=border_all(1, tok.accent),
        border_radius=radius_all(tok.radius_sm),
        padding=pad_sym(horizontal=6, vertical=2),
        tooltip=tooltip,
    )


def note_dot(tok: Tokens, tooltip: str = "") -> ft.Container:
    """Tiny accent dot marking a teacher note (details live in the dialog)."""
    return ft.Container(
        content=ft.Text("●", size=10, color=tok.accent),
        tooltip=tooltip,
        padding=pad_sym(horizontal=2, vertical=0),
    )


def kind_badge(kind: str, tok: Tokens) -> ft.Container:
    """Badge for an excuse-task kind (late/soon/early/short/long)."""
    from .strings import S

    label = {
        "late": S("kind_late"),
        "soon": S("kind_soon"),
        "early": S("kind_early"),
        "short": S("kind_short"),
        "long": S("kind_long"),
    }.get(str(kind or "").lower(), S("kind_short"))
    color = tok.yellow if str(kind or "").lower() in ("late", "soon", "early") else tok.accent
    return ft.Container(
        content=ft.Text(label, size=tok.fs_tiny, weight=ft.FontWeight.W_600,
                        color=color),
        border=border_all(1, color),
        border_radius=radius_all(tok.radius_sm),
        padding=pad_sym(horizontal=8, vertical=3),
    )


def collapsed(
    tok: Tokens,
    title: str,
    controls: list[ft.Control],
    subtitle: str = "",
    initially_expanded: bool = False,
) -> ft.ExpansionTile:
    """Collapsible section (AI panel, blacklist, …)."""
    return ft.ExpansionTile(
        title=ft.Text(title, size=tok.fs_body, weight=ft.FontWeight.W_600,
                      color=tok.text),
        subtitle=ft.Text(subtitle, size=tok.fs_small, color=tok.faint)
        if subtitle else None,
        controls=controls,
        expanded=initially_expanded,
        collapsed_bgcolor=tok.card,
        bgcolor=tok.card,
        shape=ft.RoundedRectangleBorder(radius=tok.radius_md),
        collapsed_shape=ft.RoundedRectangleBorder(radius=tok.radius_md),
        tile_padding=pad_sym(horizontal=12, vertical=4),
        controls_padding=pad_all(tok.pad),
    )


def dropdown(
    tok: Tokens,
    label: str,
    options: list[tuple[str, str]],
    value: str | None,
    on_change: Callable | None = None,
) -> ft.Dropdown:
    return ft.Dropdown(
        label=label,
        options=[ft.dropdown.Option(key, text) for key, text in options],
        value=value,
        on_select=on_change,
        text_size=tok.fs_body,
        fill_color=tok.surface,
        border_color=tok.border,
        focused_border_color=tok.accent,
    )


def toggle(
    tok: Tokens, label: str, value: bool, on_change: Callable | None = None
) -> ft.Switch:
    return ft.Switch(label=label, value=value, on_change=on_change, active_color=tok.accent)


def empty_state(text: str, tok: Tokens, action: ft.Control | None = None) -> ft.Container:
    controls: list[ft.Control] = [
        ft.Icon(ft.Icons.INBOX_OUTLINED, size=40, color=tok.faint),
        txt(text, tok, faint=True),
    ]
    if action is not None:
        controls.append(action)
    return ft.Container(
        content=ft.Column(
            controls,
            spacing=tok.gap,
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            tight=True,
        ),
        alignment=align_center(),
        padding=pad_sym(vertical=40),
    )


def header_row(
    tok: Tokens,
    heading: str,
    updated: str = "",
    actions: list[ft.Control] | None = None,
) -> ft.Row:
    left = ft.Column(
        [title(heading, tok)]
        + ([txt(updated, tok, size=tok.fs_small, faint=True)] if updated else []),
        spacing=2,
        tight=True,
        expand=True,
    )
    return ft.Row([left] + list(actions or []), vertical_alignment=ft.CrossAxisAlignment.CENTER)


def divider(tok: Tokens) -> ft.Divider:
    return ft.Divider(height=1, thickness=1, color=tok.border)


def bottom_spacer(tok: Tokens) -> ft.Container:
    """Breathing room at the end of scrollable views (last row never clips)."""
    return ft.Container(height=tok.pad * 2)


def status_dot(tok: Tokens, kind: str = "idle", size: int = 10) -> ft.Container:
    """Small colored dot for automation status.

    kind: idle | working | ok | error.
    """
    color = {
        "idle": tok.faint,
        "working": tok.yellow,
        "ok": tok.green,
        "error": tok.red,
    }.get(kind, tok.faint)
    return ft.Container(
        width=size,
        height=size,
        bgcolor=color,
        border_radius=radius_all(size // 2),
    )


def kv_row(tok: Tokens, label: str, value: str, value_color: str | None = None) -> ft.Row:
    """Label : value row used in status cards and diagnostics."""
    return ft.Row(
        [
            txt(label, tok, size=tok.fs_small, muted=True),
            ft.Container(expand=True),
            txt(value, tok, size=tok.fs_small, bold=True,
                color=value_color or tok.text),
        ],
        spacing=8,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )


def progress_bar(tok: Tokens) -> ft.ProgressBar:
    return ft.ProgressBar(color=tok.accent, bgcolor=tok.overlay)


def log_line(tok: Tokens, text: str) -> ft.Text:
    return ft.Text(
        text,
        size=tok.fs_small,
        color=tok.muted,
        font_family="Consolas",
        selectable=True,
    )


def hint_text(value: str, tok: Tokens) -> ft.Text:
    return txt(value, tok, size=tok.fs_small, faint=True)


def form_card(*children: ft.Control, tok: Tokens, padding: int | None = None) -> ft.Container:
    """Card with generous vertical rhythm for stacked labeled inputs.

    Floating field labels sit on the input's top border, so forms need
    wider spacing than plain text/badge cards (see ``card``).
    """
    inner = ft.Column(
        list(children),
        spacing=tok.gap + 8,
        tight=True,
        expand=True,
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )
    return ft.Container(
        content=ft.Row([inner], vertical_alignment=ft.CrossAxisAlignment.START),
        bgcolor=tok.card,
        border=border_all(1, tok.border),
        border_radius=radius_all(tok.radius_md),
        padding=pad_all(padding if padding is not None else tok.pad),
    )
