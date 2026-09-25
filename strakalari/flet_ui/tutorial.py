"""Interactive tutorials: short guided tours shown the first time something
appears (the first pending excuse, the first lunch menu, …).

How it works
------------
* A :class:`Tour` is a few :class:`Step` s. Each step is a small callout
  bubble; it can point at a highlighted control (``anchor``) and can wait
  for the user to actually do the thing (``until`` — an event name).
* A view calls :func:`offer` while rendering, at the moment the tour's
  content is on screen (e.g. the Today view offers ``"excuse"`` only when
  a pending excuse exists). The tour starts if tutorials are enabled,
  nothing else runs and it was never finished or skipped.
* A view wraps the control a step talks about in :func:`anchor`. The
  control gets an accent ring; an ``inline`` step also renders its bubble
  right below it (scrolling with the content). Other placements float
  above the content, placed by the Shell via :func:`layer`.
* A state action calls ``state.tutorial_event(name)`` when the user did
  something a step waits for (``until``) — the tour moves on by itself.
  The user can always go on without doing it.

Adding a tutorial for a new feature
-----------------------------------
1. Add a ``Tour`` to ``TOURS`` below (``route`` = the screen it runs on).
2. Add its strings (``tut_<tour>_<n>_title`` / ``_body``) to strings.py.
3. In the view: ``tutorial.offer(state, "<tour>")`` when its content
   exists, then wrap the relevant controls in ``tutorial.anchor(...)``.
4. Optional: ``state.tutorial_event("<event>")`` where the action succeeds.

Progress (``tutorials_done``) and the global switch
(``tutorials_enabled``, Settings → Appearance) live in config; see
:mod:`strakalari.flet_ui.state_tutorial`.
"""

from __future__ import annotations

from dataclasses import dataclass

import flet as ft

from . import components as C
from .strings import S
from .theme import border_all, pad_all, radius_all, tint

#: Where a step's bubble goes. ``inline`` = right below its anchor (the
#: Shell floats it bottom-right when the anchor is not on screen);
#: the rest float over the content area — ``top_left``/``top_right``
#: under the topbar, ``header_right`` under a view header's actions.
PLACES = ("inline", "center", "left", "top_left", "top_right", "header_right",
          "bottom_right")

BUBBLE_WIDTH = 360
#: Height of a view's header_row (title + "updated" line), for bubbles
#: pointing at its actions.
HEADER_HEIGHT = 46

#: The welcome tour: offered by the Shell on every screen, and every
#: other tour waits until it was finished or skipped.
FIRST_TOUR = "intro"


@dataclass(frozen=True)
class Step:
    key: str                       # strings: tut_<key>_title / tut_<key>_body
    anchor: str = ""               # anchor() key highlighted during the step
    place: str = "inline"
    until: str = ""                # event that completes the step ("" = Next only)
    icon: str = ft.Icons.LIGHTBULB_OUTLINE
    welcome: bool = False          # intro card: start / not now / turn off


@dataclass(frozen=True)
class Tour:
    id: str
    route: str | None              # screen it runs on (None = any screen)
    steps: tuple[Step, ...]


TOURS: dict[str, Tour] = {t.id: t for t in (
    # The first-run tour: runs once, right after the setup wizard.
    Tour("intro", None, (
        Step("intro_welcome", place="center", icon=ft.Icons.WAVING_HAND_OUTLINED,
             welcome=True),
        Step("intro_nav", place="left", icon=ft.Icons.MENU_OUTLINED),
        Step("intro_refresh", anchor="refresh", place="top_right", icon=ft.Icons.REFRESH),
        Step("intro_status", anchor="status", place="top_left",
             icon=ft.Icons.MONITOR_HEART_OUTLINED),
        Step("intro_done", place="bottom_right", icon=ft.Icons.SCHOOL_OUTLINED),
    )),
    # The first pending excuse (Today).
    Tour("excuse", "today", (
        Step("excuse_pick", anchor="excuse_card", icon=ft.Icons.EVENT_BUSY_OUTLINED),
        Step("excuse_send", anchor="excuse_card", until="excuse_done",
             icon=ft.Icons.SEND_OUTLINED),
        Step("excuse_done", place="bottom_right", icon=ft.Icons.TASK_ALT),
    )),
    Tour("timetable", "timetable", (
        Step("tt_weeks", anchor="tt_nav", icon=ft.Icons.DATE_RANGE_OUTLINED),
        Step("tt_colors", anchor="tt_legend", icon=ft.Icons.PALETTE_OUTLINED),
    )),
    Tour("absences", "absences", (
        Step("abs_stats", anchor="abs_stats", icon=ft.Icons.PIE_CHART_OUTLINE),
        Step("abs_subject", anchor="abs_first", icon=ft.Icons.PERCENT),
    )),
    Tour("planner", "planner", (
        Step("plan_strip", anchor="plan_strip", icon=ft.Icons.CALENDAR_VIEW_MONTH_OUTLINED),
        Step("plan_pick", anchor="plan_first", until="day_planned",
             icon=ft.Icons.BEACH_ACCESS_OUTLINED),
        Step("plan_budget", anchor="plan_budget", icon=ft.Icons.STACKED_BAR_CHART),
    )),
    # The first orderable lunch menu.
    Tour("lunches", "lunches", (
        Step("lunch_pick", anchor="lunch_day", until="lunch_picked",
             icon=ft.Icons.RESTAURANT_OUTLINED),
        Step("lunch_send", anchor="lunch_send", until="orders_sent",
             icon=ft.Icons.SEND_OUTLINED),
        Step("lunch_tools", anchor="lunch_tools", place="header_right",
             icon=ft.Icons.TUNE_OUTLINED),
    )),
    # Marks: overview -> open a subject -> solver -> what-if predictor -> scale.
    Tour("marks", "marks", (
        Step("marks_stats", anchor="marks_stats", icon=ft.Icons.GRADE_OUTLINED),
        Step("marks_subject", anchor="marks_subject", until="marks_subject_opened",
             icon=ft.Icons.TOUCH_APP_OUTLINED),
        Step("marks_need", anchor="marks_need", icon=ft.Icons.FLAG_OUTLINED),
        Step("marks_predict", anchor="marks_predict", until="marks_predicted",
             icon=ft.Icons.SCIENCE_OUTLINED),
        Step("marks_scale", anchor="marks_scale", place="header_right",
             icon=ft.Icons.PERCENT),
    )),
    Tour("settings", "settings", (
        Step("settings_intro", place="bottom_right", icon=ft.Icons.SETTINGS_OUTLINED),
    )),
    Tour("activity", "activity", (
        Step("activity_intro", place="bottom_right", icon=ft.Icons.HISTORY_OUTLINED),
    )),
)}


# -- per-render bookkeeping ---------------------------------------------------
def begin(state, route: str) -> None:
    """Called by the Shell before building a screen.

    Suspends a tour that belongs to another screen (it restarts when its
    moment comes again) and offers the first-run tour.
    """
    state._tutorial_anchored = False
    current = _current(state)
    if current is not None and current[0].route not in (None, route):
        state.tutorial_suspend()
    offer(state, FIRST_TOUR)


def offer(state, tour_id: str) -> None:
    """The view shows the content ``tour_id`` explains: start it if due."""
    try:
        state.tutorial_offer(tour_id)
    except Exception:
        pass


def _current(state):
    try:
        return state.tutorial_current()
    except Exception:
        return None


def anchor(state, key: str, control: ft.Control) -> ft.Control:
    """Wraps ``control`` when the active step points at ``key``.

    Returns ``control`` untouched otherwise, so views can wrap freely.
    Only the first matching control per render is highlighted.
    """
    current = _current(state)
    if current is None or current[2].anchor != key:
        return control
    if getattr(state, "_tutorial_anchored", False):
        return control
    state._tutorial_anchored = True
    tour, index, step = current
    tok = state.tok
    ring = ft.Container(
        content=control,
        border=border_all(2, tok.accent),
        border_radius=radius_all(tok.radius_md + 3),
        padding=pad_all(3),
        shadow=ft.BoxShadow(blur_radius=18, spread_radius=1, color=tint(tok.accent, 0.35)),
        expand=getattr(control, "expand", None),
    )
    if step.place != "inline":
        return ring
    bubble = _bubble(state, tour, index, step, caret="up")
    return ft.Column(
        [ring, ft.Row([bubble], spacing=0)],
        spacing=0,
        tight=True,
        expand=getattr(control, "expand", None),
        horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
    )


def layer(state) -> ft.Control | None:
    """The floating bubble for the active step, or None.

    Called by the Shell after the screen was built. An ``inline`` step
    whose anchor did not render floats bottom-right instead — except a
    tour's first step: its content is gone (e.g. the excuse was handled
    elsewhere), so the tour is suspended until it shows up again.
    """
    current = _current(state)
    if current is None:
        return None
    tour, index, step = current
    place = step.place
    if place == "inline":
        if getattr(state, "_tutorial_anchored", False):
            return None
        if index == 0:
            state.tutorial_suspend()
            return None
        place = "bottom_right"
    tok = state.tok
    if place == "center":
        return ft.Container(
            content=_bubble(state, tour, index, step, width=440),
            alignment=ft.Alignment(0, -0.2),
            bgcolor=tint(tok.bg, 0.72),
            left=0, top=0, right=0, bottom=0,
            # Absorbs clicks: the welcome card waits for a choice.
            on_click=lambda e: None,
        )
    if place == "left":
        return ft.Container(_bubble(state, tour, index, step, caret="left"),
                            left=0, top=96)
    if place == "top_left":
        return ft.Container(_bubble(state, tour, index, step, caret="up"),
                            left=tok.pad, top=0)
    if place == "top_right":
        return ft.Container(_bubble(state, tour, index, step, caret="up_right"),
                            right=tok.pad, top=0)
    if place == "header_right":
        # Just below an action in a view's header_row (content padding +
        # the title/subtitle block), not the topbar above the content.
        return ft.Container(_bubble(state, tour, index, step, caret="up_right"),
                            right=tok.pad + 8, top=tok.pad + 8 + HEADER_HEIGHT)
    return ft.Container(_bubble(state, tour, index, step),
                        right=tok.pad, bottom=tok.pad)


# -- the bubble ---------------------------------------------------------------
def _dots(tok, count: int, index: int) -> ft.Control:
    return ft.Row(
        [ft.Container(width=14 if i == index else 6, height=6,
                      bgcolor=tok.accent if i <= index else tok.border,
                      border_radius=radius_all(3))
         for i in range(count)],
        spacing=4, tight=True,
    )


def _caret(tok, direction: str) -> ft.Control:
    """Small triangle pointing from the bubble at what it talks about:
    a 45°-rotated square centered on the clip edge, so only its outer
    half (a triangle) shows."""
    side = 12
    diamond = ft.Container(width=side, height=side, bgcolor=_edge(tok),
                           rotate=0.785398, left=10 - side / 2, top=10 - side / 2)
    if direction == "left":
        return ft.Stack([diamond], width=10, height=20,
                        clip_behavior=ft.ClipBehavior.HARD_EDGE)
    return ft.Stack([diamond], width=20, height=10,
                    clip_behavior=ft.ClipBehavior.HARD_EDGE)


def _edge(tok) -> str:
    """Bubble border color (the caret shares it)."""
    return tint(tok.accent, 0.8)


def _text_button(label: str, tok, on_click, color: str | None = None) -> ft.TextButton:
    return ft.TextButton(content=ft.Text(label, color=color or tok.muted, size=tok.fs_small),
                         on_click=on_click)


def _bubble(state, tour: Tour, index: int, step: Step, caret: str = "",
            width: int = BUBBLE_WIDTH) -> ft.Control:
    tok = state.tok
    total = len(tour.steps)
    last = index == total - 1

    close = ft.IconButton(
        ft.Icons.CLOSE, icon_size=16, icon_color=tok.faint,
        tooltip=S("tut_skip_tour"), on_click=lambda e: state.tutorial_skip(),
        style=ft.ButtonStyle(padding=pad_all(4)),
    )
    head = ft.Row(
        [
            ft.Container(
                ft.Icon(step.icon, color=tok.accent, size=18),
                bgcolor=tint(tok.accent, 0.16), border_radius=radius_all(8),
                padding=pad_all(6),
            ),
            ft.Text(S(f"tut_{step.key}_title"), size=tok.fs_section,
                    weight=ft.FontWeight.BOLD, color=tok.text, expand=True),
            close,
        ],
        spacing=10,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )
    body: list[ft.Control] = [
        head,
        ft.Text(S(f"tut_{step.key}_body"), size=tok.fs_body, color=tok.muted),
    ]
    if step.until:
        body.append(ft.Row(
            [ft.Icon(ft.Icons.TOUCH_APP_OUTLINED, size=16, color=tok.accent),
             ft.Text(S(f"tut_{step.key}_try"), size=tok.fs_small, color=tok.accent,
                     weight=ft.FontWeight.W_600, expand=True)],
            spacing=6, vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ))

    if step.welcome:
        body.append(ft.Row(
            [
                C.primary_button(S("tut_start"), tok, icon=ft.Icons.ARROW_FORWARD,
                                 on_click=lambda e: state.tutorial_next()),
                C.ghost_button(S("tut_not_now"), tok, on_click=lambda e: state.tutorial_skip()),
            ],
            spacing=8, wrap=True,
        ))
        body.append(C.divider(tok))
        body.append(ft.Row(
            [
                ft.Text(S("tut_off_note"), size=tok.fs_small, color=tok.faint, expand=True),
                _text_button(S("tut_turn_off"), tok,
                             lambda e: state.set_tutorials_enabled(False), color=tok.red),
            ],
            spacing=8, vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ))
    else:
        nav: list[ft.Control] = [_dots(tok, total, index), ft.Container(expand=True)]
        if index > 0 and not tour.steps[index - 1].until:
            nav.append(_text_button(S("tut_back"), tok, lambda e: state.tutorial_back()))
        if step.until:
            # Doing the action moves on by itself; this is the way on
            # without doing it right now.
            nav.append(_text_button(S("tut_later") if last else S("tut_skip_step"), tok,
                                    lambda e: state.tutorial_next()))
        else:
            nav.append(C.primary_button(
                S("tut_done") if last else S("tut_next"), tok,
                on_click=lambda e: state.tutorial_next(),
            ))
        body.append(ft.Row(nav, spacing=4, vertical_alignment=ft.CrossAxisAlignment.CENTER))

    card = ft.Container(
        content=ft.Column(body, spacing=tok.gap - 2, tight=True),
        width=width,
        bgcolor=tok.card,
        border=border_all(1, _edge(tok)),
        border_radius=radius_all(tok.radius_lg),
        padding=ft.Padding(left=tok.pad, top=tok.pad - 4, right=tok.pad - 6, bottom=tok.pad - 6),
        shadow=ft.BoxShadow(blur_radius=24, spread_radius=0, offset=ft.Offset(0, 6),
                            color=tint("#000000", 0.28)),
    )
    if caret == "left":
        return ft.Row(
            [ft.Column([ft.Container(height=18), _caret(tok, "left")], spacing=0, tight=True),
             card],
            spacing=0, tight=True, vertical_alignment=ft.CrossAxisAlignment.START,
        )
    if caret in ("up", "up_right"):
        tip = ft.Row(
            [ft.Container(width=18), _caret(tok, "up")] if caret == "up"
            else [ft.Container(expand=True), _caret(tok, "up"), ft.Container(width=18)],
            spacing=0, width=width,
        )
        return ft.Column([tip, card], spacing=0, tight=True)
    return card
