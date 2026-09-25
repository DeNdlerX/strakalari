"""Obědy — weekly menu with a radio picker, web order state, AI + blacklist.

One tap on a meal row selects it (radio circle); a single Send button
pushes everything at once. The status pill per day distinguishes what the
Strava WEB reports ("Ordered in Strava") from local picks ("To send").
The AI filter and the food blacklist live in a collapsible side panel
on the right (toggled from the header).
"""

from __future__ import annotations

import re
from datetime import date

import flet as ft

from strakalari.core.models import parse_cz_date

from .. import components as C
from .. import tutorial as T
from ..overlays import snack
from ..state import AppState
from ..strings import S
from ..theme import tint

#: Trailing allergen list: "(1,3,7,9)", "(1a, 3, 7)".
_ALLERGENS_RE = re.compile(r"\(\s*(\d{1,2}[a-z]?(?:\s*,\s*\d{1,2}[a-z]?)*)\s*\)\s*$")


class LunchView:
    def __init__(self, state: AppState, page: ft.Page) -> None:
        self.state = state
        self.page = page

    @property
    def busy(self) -> bool:
        # Kept for compatibility: the running flag lives on AppState now
        # (a view-local flag never survived the Shell's rebuild-on-emit).
        return bool(getattr(self.state, "ai_running", False))

    @busy.setter
    def busy(self, value: bool) -> None:
        try:
            self.state.ai_running = bool(value)
        except Exception:
            pass

    def recommend(self) -> None:
        if not bool(self.state.get("gemini_api_key")):
            snack(self.page, S("recommend_no_key"))
            return
        if not self.state.start_ai_recommend(self.page):
            snack(self.page, S("ai_already_running"))

    # -- day status ------------------------------------------------------
    def _day_status(self, day: str, ordered: str | None) -> ft.Control | None:
        state, tok = self.state, self.state.tok
        if day in state.cancelled_lunches:
            return C.badge(S("no_lunch"), tok, kind="warning")
        if not ordered:
            return None
        if state.web_orders.get(day) == ordered:
            return C.badge(S("web_ordered"), tok, kind="sent")
        try:
            if not state.is_lunch_order_open(day):
                # Past the previous-business-day cutoff Send skips this day,
                # so "to send" would lie — the "Uzavřeno" badge in the card
                # header covers it. The pick stays staged underneath (a
                # later cutoff still sends it).
                return None
        except Exception:
            pass
        return C.badge(S("to_send"), tok, kind="pending")

    # -- meal rows ---------------------------------------------------------
    @staticmethod
    def _display_name(name: str) -> str:
        """Tidy raw Strava names ("zeleninou,Mexický" -> "zeleninou, Mexický")."""
        import re

        text = re.sub(r",(\S)", r", \1", str(name or ""))
        return re.sub(r"\s+\)", ")", re.sub(r"(\S)\(", r"\1 (", text))

    @classmethod
    def _split_meal(cls, name: str) -> tuple[str, str, str]:
        """'Soup; Main (1,3,7)' -> ('Soup', 'Main', '1, 3, 7').

        Soup is the part before the first ';' (empty without one);
        allergens are a trailing parenthesized list of codes.
        """
        text = cls._display_name(name).strip()
        allergens = ""
        m = _ALLERGENS_RE.search(text)
        if m:
            allergens = ", ".join(
                p.strip() for p in m.group(1).split(",") if p.strip())
            text = text[:m.start()].rstrip()
        soup, sep, main = text.partition(";")
        if not sep:
            return "", text, allergens
        return soup.strip(), main.strip(), allergens

    @classmethod
    def _shared_soup(cls, meals: dict[str, str]) -> str:
        """The soup every meal of the day shares ('' when they differ)."""
        soups = {
            cls._split_meal(str(name))[0]
            for mid, name in (meals or {}).items()
            if "&-1&" not in str(mid)
        }
        return soups.pop() if len(soups) == 1 else ""

    def _meal_row(self, day: str, mid: str, name: str, selected: bool,
                  disabled: bool = False, shared_soup: str = "") -> ft.Control:
        state, tok = self.state, self.state.tok
        soup, main, allergens = self._split_meal(name)
        label = main if shared_soup and soup == shared_soup else (
            f"{soup}; {main}" if soup else main)

        def _pick(e, d=day, m=mid):
            if disabled:
                snack(self.page, S("lunch_order_closed"))
                return
            if not state.order_lunch(d, m):
                # Cutoff closed between render and tap: tell the user
                # instead of a silent no-op (next render shows the badge).
                snack(self.page, S("lunch_order_closed"))
                try:
                    self.page.update()
                except Exception:
                    pass

        return ft.Container(
            content=ft.Row(
                [
                    C.radio_dot(tok, selected),
                    ft.Container(
                        C.txt(label or self._display_name(name), tok,
                              size=tok.fs_body, bold=selected,
                              color=tok.accent if selected else None,
                              muted=disabled),
                        expand=True,
                    ),
                    C.txt(allergens, tok, size=tok.fs_tiny, faint=True)
                    if allergens else ft.Container(width=0),
                ],
                spacing=10,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            bgcolor=tint(tok.accent, 0.14) if selected else None,
            border=C.border_all(1, tok.accent if selected else tok.border),
            border_radius=8,
            padding=ft.Padding(left=10, top=8, right=12, bottom=8),
            on_click=None if disabled else _pick,
            opacity=0.55 if disabled else 1.0,
            tooltip=f"{S('allergens')}: {allergens}" if allergens else None,
        )

    def _day_card(self, day: str, meals: dict[str, str]) -> ft.Control:
        state, tok = self.state, self.state.tok
        # Ordering closes at the set time on the previous business day
        # (preset, else 12:00) — past-deadline days are read-only.
        try:
            order_open = bool(state.is_lunch_order_open(day))
        except Exception:
            order_open = True
        # Local pick first; without one the radio follows the web truth
        # (clearing a pick must not pretend nothing is ordered).
        # A planner-cancelled day owns the "No lunch" radio: the stale web
        # meal must not stay highlighted alongside it.
        ordered = state.orders.get(day) or state.web_orders.get(day)
        is_cancelled = day in state.cancelled_lunches
        status = self._day_status(day, ordered)
        head: list[ft.Control] = [
            C.txt(f"{C.day_name(day)} {C.cz_day_year(day)}", tok, bold=True)]
        if status is not None:
            head.append(status)
        if not order_open:
            head.append(C.badge(S("lunch_closed_badge"), tok, kind="warning"))
        rows: list[ft.Control] = [
            ft.Row(head, spacing=8, vertical_alignment=ft.CrossAxisAlignment.CENTER)
        ]
        if not order_open:
            try:
                deadline = state.lunch_order_deadline(day)
                detail = (deadline.strftime("%d.%m.%Y %H:%M")
                          if deadline is not None else "")
            except Exception:
                detail = ""
            rows.append(C.txt(
                S("lunch_order_closed") + (f" ({detail})" if detail else ""),
                tok, size=tok.fs_small, faint=True))
        shared_soup = self._shared_soup(meals)
        if shared_soup:
            rows.append(C.txt(f"{S('lunch_soup')}: {shared_soup}", tok,
                              size=tok.fs_small, muted=True))
        hidden = 0
        deorder_id: str | None = None
        for mid, name in (meals or {}).items():
            if "&-1&" in str(mid):
                deorder_id = str(mid)
                continue
            if mid in state.lunch_hidden:
                hidden += 1
                continue
            rows.append(self._meal_row(day, str(mid), str(name),
                                     bool(ordered == mid and not is_cancelled),
                                     disabled=not order_open,
                                     shared_soup=shared_soup))
        # "No lunch" radio: deorders on the web when possible, otherwise
        # just clears the local pick.
        no_lunch_selected = (
            day in state.cancelled_lunches
            or (ordered is not None and ordered == deorder_id)
        )

        def _no_lunch(e, d=day, m=deorder_id):
            if not order_open:
                snack(self.page, S("lunch_order_closed"))
                return
            if m:
                if not state.order_lunch(d, m):
                    try:
                        self.page.update()
                    except Exception:
                        pass
            else:
                state.cancel_lunch_order(d)

        rows.append(
            ft.Container(
                content=ft.Row(
                    [
                        C.radio_dot(tok, bool(no_lunch_selected)),
                        C.txt(S("no_order_option"), tok, size=tok.fs_small,
                              muted=True),
                    ],
                    spacing=10,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                ),
                bgcolor=tint(tok.accent, 0.14) if no_lunch_selected else None,
                border=C.border_all(
                    1, tok.accent if no_lunch_selected else tok.border),
                border_radius=8,
                padding=ft.Padding(left=10, top=8, right=10, bottom=8),
                on_click=None if not order_open else _no_lunch,
                opacity=0.55 if not order_open else 1.0,
            )
        )
        if hidden:
            rows.append(C.txt(S("hidden_meals").format(n=hidden), tok,
                              size=tok.fs_small, faint=True))
        return C.card(*rows, tok=tok)

    # -- side panel (AI + blacklist, right column) -------------------------------
    def _ai_card(self) -> ft.Control:
        state, tok = self.state, self.state.tok
        model = str(state.get("gemini_model", "") or "")
        # Stored key counts when non-empty, whatever the flag says (legacy
        # plaintext keys have the flag unset) — same rule as settings/wizard.
        has_key = bool(state.get("gemini_api_key"))
        head = ft.Row(
            [
                ft.Icon(ft.Icons.AUTO_AWESOME_OUTLINED, size=18,
                        color=tok.accent),
                C.txt(S("ai_section"), tok, bold=True),
                ft.Container(expand=True),
                C.badge(model, tok) if model else ft.Container(width=0),
            ],
            spacing=8,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        )
        pref = C.labeled_field(
            tok, S("ai_prefs"), value=state.lunch_prefs,
            hint=S("ai_prefs_hint"), multiline=True,
            on_change=lambda e: setattr(state, "lunch_prefs",
                                        e.control.value or ""),
        )
        body: list[ft.Control] = [head, pref]
        if not has_key:
            async def _open_key(e):
                await C.open_url(self.page, C.AI_STUDIO_URL)

            body.append(
                ft.Row(
                    [
                        ft.Icon(ft.Icons.INFO_OUTLINED, size=16,
                                color=tok.accent),
                        ft.Container(
                            C.txt(S("ai_no_key"), tok, size=tok.fs_small,
                                  muted=True),
                            expand=True,
                        ),
                    ],
                    spacing=8,
                    vertical_alignment=ft.CrossAxisAlignment.START,
                )
            )
            body.append(
                ft.Row(
                    [
                        C.ghost_button(S("ai_key_link"), tok,
                                       icon=ft.Icons.OPEN_IN_NEW,
                                       on_click=_open_key),
                        C.ghost_button(S("go_to_settings"), tok,
                                       on_click=lambda e: state.go("settings")),
                    ],
                    spacing=8,
                    wrap=True,
                )
            )
        recommend_btn = C.primary_button(
            S("recommend"), tok,
            on_click=lambda e: self.recommend(),
            icon=ft.Icons.AUTO_AWESOME_OUTLINED,
        )
        recommend_btn.disabled = bool(getattr(state, "ai_running", False)) or not has_key
        body.append(
            ft.Row(
                [
                    recommend_btn,
                    C.ghost_button(
                        S("apply_filter_long"), tok,
                        on_click=lambda e: state.apply_food_filter(
                            state.lunch_prefs),
                    ),
                ],
                spacing=8,
                wrap=True,
            )
        )
        body.append(C.txt(S("filter_hint"), tok, size=tok.fs_small, faint=True))
        if not has_key:
            body.append(C.txt(
                S("recommend_no_key"), tok,
                size=tok.fs_small, color=tok.yellow))
        if getattr(state, "ai_running", False):
            body.append(
                ft.Row(
                    [
                        ft.ProgressRing(width=16, height=16, color=tok.accent),
                        C.txt(S("ai_running"), tok, size=tok.fs_small,
                              muted=True),
                    ],
                    spacing=8,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                )
            )
            body.append(C.progress_bar(tok))
        if state.lunch_hidden:
            body.append(C.txt(
                S("hidden_meals").format(n=len(state.lunch_hidden)), tok,
                size=tok.fs_small, faint=True))
        return C.card(*body, tok=tok)

    def _blacklist_card(self) -> ft.Control:
        state, tok = self.state, self.state.tok
        words = state.blacklist_words()
        head = ft.Row(
            [
                ft.Icon(ft.Icons.BLOCK_OUTLINED, size=18, color=tok.muted),
                C.txt(S("blacklist_section"), tok, bold=True),
                ft.Container(expand=True),
                C.badge(f"{len(words)}", tok),
            ],
            spacing=8,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        )
        rows: list[ft.Control] = [
            head,
            C.txt(S("blacklist_hint"), tok, size=tok.fs_small, muted=True),
        ]
        if not words:
            rows.append(C.txt(S("no_blacklist"), tok, size=tok.fs_small,
                              faint=True))
        for word in words:
            rows.append(
                ft.Container(
                    content=ft.Row(
                        [
                            ft.Container(C.txt(word, tok, size=tok.fs_small),
                                         expand=True),
                            ft.IconButton(
                                ft.Icons.DELETE_OUTLINE,
                                tooltip=S("delete"),
                                icon_size=18,
                                on_click=lambda e, w=word:
                                    state.remove_blacklist_word(w),
                            ),
                        ],
                        spacing=4,
                        vertical_alignment=ft.CrossAxisAlignment.CENTER,
                    ),
                    bgcolor=tok.surface,
                    border=C.border_all(1, tok.border),
                    border_radius=8,
                    padding=ft.Padding(left=10, top=2, right=4, bottom=2),
                )
            )
        new_field = C.field(
            tok, S("add_word"), value=state.draft("blacklist_new", ""),
            hint=S("add_word"),
            on_change=lambda e: state.set_draft("blacklist_new",
                                                e.control.value or ""),
        )

        def _add(e):
            if state.add_blacklist_word(state.draft("blacklist_new", "")):
                state.set_draft("blacklist_new", "")
            else:
                snack(self.page, getattr(state, "_blacklist_edit_error", "")
                      or S("blacklist_add_failed"))

        new_field.on_submit = _add
        rows.append(
            ft.Row(
                [ft.Container(new_field, expand=True),
                 C.primary_button(S("add"), tok, on_click=_add)],
                spacing=8,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            )
        )
        return C.card(*rows, tok=tok)

    def _sidebar(self) -> ft.Control:
        state, tok = self.state, self.state.tok
        bar = ft.Row(
            [
                C.txt(S("ai_tools"), tok, bold=True),
                ft.Container(expand=True),
                ft.IconButton(
                    ft.Icons.CLOSE, tooltip=S("hide_sidebar"), icon_size=18,
                    on_click=lambda e: state.set_lunches_sidebar(False),
                ),
            ],
            spacing=4,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        )
        return C.scrollable(
            state, "lunches:side",
            [bar, self._ai_card(), self._blacklist_card()],
            spacing=tok.gap, expand=True,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        )

    # -- build -----------------------------------------------------------------
    def build(self) -> ft.Control:
        state, tok = self.state, self.state.tok

        if not state.strava_enabled():
            def _open_accounts(e):
                state.set_settings_section("accounts")
                state.go("settings")

            return ft.Column(
                [
                    C.header_row(tok, S("lunch_title"), state.updated_label),
                    C.card(
                        C.txt(S("strava_disabled_title"), tok, bold=True),
                        C.txt(S("strava_disabled_msg"), tok, size=tok.fs_small, muted=True),
                        C.ghost_button(S("go_to_settings"), tok, on_click=_open_accounts),
                        tok=tok,
                    ),
                ],
                spacing=tok.gap,
                expand=True,
            )

        def _open(day: str) -> bool:
            try:
                return bool(state.is_lunch_order_open(day))
            except Exception:
                return True

        # Same selection as submit_orders: staged (pending) picks only.
        staged = set(getattr(state, "pending_orders", None) or set())
        pending = sum(
            1 for day, mid in state.orders.items()
            if mid and day in staged and state.web_orders.get(day) != mid and _open(day)
        )
        # Planner-cancelled days without a staged pick still queue a deorder
        # at send time (menu unknown when planned) — count them so Send
        # reflects what submit_orders will actually transmit.
        try:
            _food = state.food() or {}
        except Exception:
            _food = {}
        for day in state.cancelled_lunches:
            if day in state.orders:
                continue
            web = str(state.web_orders.get(day, "") or "")
            if not web or "&-1&" in web:
                continue  # nothing ordered there: nothing to cancel
            if not _open(day):
                continue
            meals = _food.get(day, {}) or {}
            if any("&-1&" in str(mid) for mid in meals):
                pending += 1
        sidebar_open = bool(getattr(state, "lunches_sidebar_open", True))

        def _send(e):
            if state.submit_orders(self.page):
                return
            if state.order_running or state.refresh_running:
                snack(self.page, S("already_running"))
            elif not pending:
                snack(self.page, S("no_changes"))
            # else: submit_orders already toasted the reason (need_credentials).

        send_btn = C.primary_button(
            f"{S('send_orders')}" + (f" ({pending})" if pending else ""),
            tok,
            on_click=_send,
            icon=ft.Icons.SEND_OUTLINED,
        )
        toggle = ft.IconButton(
            ft.Icons.TUNE_OUTLINED,
            tooltip=S("hide_sidebar") if sidebar_open else S("show_sidebar"),
            icon_size=22,
            icon_color=tok.accent if sidebar_open else None,
            on_click=lambda e: state.set_lunches_sidebar(not sidebar_open),
        )
        header = C.header_row(tok, S("lunch_title"), state.updated_label,
                              actions=[T.anchor(state, "lunch_tools", toggle)])
        hint = C.txt(S("pick_hint"), tok, size=tok.fs_small, faint=True)
        send_row = T.anchor(state, "lunch_send", ft.Row([send_btn], spacing=8))
        menu_controls: list[ft.Control] = []
        low = None
        try:
            low = state.low_balance_warning()
        except Exception:
            low = None
        if low:
            days = ", ".join(C.cz_day(d) for d in (low.get("days") or [])[:10])
            menu_controls.append(C.card(
                ft.Row(
                    [ft.Icon(ft.Icons.ACCOUNT_BALANCE_WALLET_OUTLINED, color=tok.yellow, size=20),
                     C.txt(S("low_balance_title"), tok, bold=True, color=tok.yellow)],
                    spacing=8, vertical_alignment=ft.CrossAxisAlignment.CENTER,
                ),
                C.txt(S("low_balance_body").format(days=days or "—"), tok,
                      size=tok.fs_small, muted=True),
                tok=tok,
            ))
        if not state.food():
            menu_controls.append(C.empty_state(S("no_data"), tok))
            menu_controls.append(C.txt(S("need_credentials"), tok,
                                       size=tok.fs_small, faint=True))
        today = date.today()
        past: list[tuple[str, dict]] = []
        upcoming: list[tuple[str, dict]] = []
        for day, meals in state.food().items():
            parsed = parse_cz_date(day)
            (past if parsed is not None and parsed < today else upcoming).append(
                (day, meals or {}))
        show_past = bool(getattr(state, "show_past_lunches", False))
        if past:
            # Opens on today / the next orderable day: past (closed) days
            # only matter for checking history, so they fold away.
            menu_controls.append(ft.Row([C.ghost_button(
                S("lunch_hide_past") if show_past
                else S("lunch_show_past").format(n=len(past)),
                tok,
                icon=ft.Icons.EXPAND_LESS if show_past else ft.Icons.HISTORY,
                on_click=lambda e: state.set_show_past_lunches(not show_past),
            )]))
        # The lunch tour starts once a day can actually be ordered.
        first_open = next((d for d, meals in upcoming if meals and _open(d)), None)
        if first_open is not None:
            T.offer(state, "lunches")
        for day, meals in (past if show_past else []) + upcoming:
            card = self._day_card(day, meals)
            if day == first_open:
                card = T.anchor(state, "lunch_day", card)
            menu_controls.append(card)
        menu_controls.append(C.bottom_spacer(tok))
        menu = C.scrollable(
            state, "lunches:menu", menu_controls,
            spacing=tok.gap, expand=True,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        )
        left = ft.Column(
            [hint, send_row, menu],
            spacing=tok.gap,
            expand=True,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        )
        if sidebar_open:
            body = ft.Row(
                [
                    ft.Container(content=left, expand=True),
                    ft.Container(content=self._sidebar(), width=360),
                ],
                spacing=tok.gap,
                expand=True,
                vertical_alignment=ft.CrossAxisAlignment.STRETCH,
            )
        else:
            body = ft.Row(
                [ft.Container(content=left, expand=True)],
                spacing=0,
                expand=True,
                vertical_alignment=ft.CrossAxisAlignment.STRETCH,
            )
        return ft.Column(
            [header, body],
            spacing=tok.gap,
            expand=True,
        )


def build(state: AppState, page: ft.Page) -> ft.Control:
    return LunchView(state, page).build()
