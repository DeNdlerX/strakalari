"""Settings sections: appearance, advanced, notifications and diagnostics."""

from __future__ import annotations

import flet as ft

from strakalari.core.i18n import get_language
from strakalari.core.notify import EVENT_TYPES

from ... import components as C
from ...overlays import snack
from ...strings import S, notif_label
from .common import _save_quiet


class AppPrefsMixin:
    """Sections of :class:`SettingsView` (needs ``self.state`` / ``self.page``)."""

    # -- appearance ------------------------------------------------------------------
    def _appearance(self) -> list:
        state, tok, page = self.state, self.state.tok, self.page

        def _on_theme(e):
            if not state.set_theme(e.control.value or "dark"):
                e.control.value = state.tok.mode
                snack(page, S("save_failed"))
                page.update()

        def _on_lang(e):
            if not state.set_language(e.control.value or "cs"):
                e.control.value = get_language()
                snack(page, S("save_failed"))
                page.update()

        def _on_density(e):
            if not state.save({"compact_density": bool(e.control.value)}):
                e.control.value = state.density_compact()
                snack(page, S("save_failed"))
                page.update()

        theme_dd = C.dropdown(
            tok, S("theme_dark") + " / " + S("theme_light"),
            [("dark", S("theme_dark")), ("light", S("theme_light"))],
            state.tok.mode,
            on_change=_on_theme,
        )
        lang_dd = C.dropdown(
            tok, S("language"), [("cs", "Čeština"), ("en", "English")],
            get_language(),
            on_change=_on_lang,
        )
        density = C.toggle(tok, f"{S('density')} ({S('density_compact')})",
                           state.density_compact(),
                           on_change=_on_density)
        return [C.card(theme_dd, lang_dd, density, tok=tok), self._tutorials_card()]

    def _tutorials_card(self) -> ft.Control:
        state, tok, page = self.state, self.state.tok, self.page

        def _on_toggle(e):
            if not state.set_tutorials_enabled(bool(e.control.value)):
                e.control.value = state.tutorials_enabled()
                snack(page, S("save_failed"))
                page.update()

        def _replay(e):
            if state.reset_tutorials():
                snack(page, S("tutorials_replayed"))
            else:
                snack(page, S("save_failed"))

        return C.card(
            C.txt(S("tutorials"), tok, bold=True),
            C.txt(S("tutorials_hint"), tok, size=tok.fs_small, muted=True),
            C.toggle(tok, S("tutorials_toggle"), state.tutorials_enabled(),
                     on_change=_on_toggle),
            ft.Row([C.ghost_button(S("tutorials_replay"), tok, icon=ft.Icons.REPLAY,
                                   on_click=_replay)]),
            tok=tok,
        )
    # -- advanced --------------------------------------------------------------------------
    def _advanced(self) -> list:
        state, tok = self.state, self.state.tok

        def _float_parse(default: float):
            def _parse(raw: str) -> float:
                try:
                    return float(str(raw or default).replace(",", "."))
                except (TypeError, ValueError):
                    raise ValueError(S("save_failed")) from None
            return _parse

        ttl = self._auto(S("cache_ttl"), "adv:ttl", "cache_ttl_hours",
                         str(state.get("cache_ttl_hours", 24)), parse=_float_parse(24))
        page_to = self._auto(S("timeout_page"), "adv:page_to", "page_load_timeout_s",
                             str(state.get("page_load_timeout_s", 60.0)),
                             parse=_float_parse(60.0))
        elem_to = self._auto(S("timeout_element"), "adv:elem_to", "element_wait_s",
                             str(state.get("element_wait_s", 30.0)),
                             parse=_float_parse(30.0))
        week_delay = self._auto(S("week_switch_delay"), "adv:week_delay",
                                "week_switch_delay_s",
                                str(state.get("week_switch_delay_s", 2.5)),
                                parse=_float_parse(2.5))
        log_file = self._auto(S("log_file"), "adv:log_file", "log_file",
                              str(state.get("log_file", "./log.txt")))
        blacklist = self._auto(S("blacklist_file"), "adv:blacklist", "strava_blacklist",
                               str(state.get("strava_blacklist", "./strava_blacklist.json")))
        return [C.form_card(ttl, page_to, elem_to, week_delay, C.divider(tok),
                           log_file, blacklist, tok=tok)]

    # -- notifications -------------------------------------------------------------------
    def _notifications(self) -> list:
        state, tok, page = self.state, self.state.tok, self.page
        prefs = dict(state.get("notifications", {}) or {})
        switches: list[ft.Control] = []

        def _on_toggle(e, ev: str) -> None:
            new_val = bool(e.control.value)
            prefs[ev] = new_val
            if not _save_quiet(state, page, {"notifications": dict(prefs)}):
                prefs[ev] = not new_val
                try:
                    e.control.value = not new_val
                    page.update()
                except Exception:
                    pass

        for event in EVENT_TYPES:
            switches.append(C.toggle(
                tok, notif_label(event), prefs.get(event, True),
                on_change=lambda e, ev=event: _on_toggle(e, ev),
            ))
        return [C.card(*switches, tok=tok)]

    # -- diagnostics -----------------------------------------------------------------------
    def _diagnostics(self) -> list:
        state, tok, page = self.state, self.state.tok, self.page
        try:
            problems = state.config.validate()
        except Exception as exc:
            # Never report green when validation itself crashed — that
            # hides broken configs behind a false "config OK".
            problems = [f"{S('config_problems')}: {exc}".splitlines()[0][:200]]
        if problems:
            rows: list[ft.Control] = [C.txt(S("config_problems"), tok, bold=True)]
            rows.extend(C.txt(f"• {p}", tok, size=tok.fs_small, color=tok.red)
                        for p in problems)
        else:
            rows = [C.txt(S("config_ok"), tok, size=tok.fs_small, color=tok.green)]
        rows.append(C.divider(tok))
        try:
            from strakalari.core.update import get_current_version

            rows.append(C.kv_row(tok, S("app_version"), get_current_version()))
        except Exception:
            pass
        channel = getattr(state, "update_channel", "stable")

        def _on_channel(e):
            value = (e.control.value if e.control else "") or "stable"
            if value != channel and not state.set_update_channel(value):
                try:
                    snack(page, S("save_failed"))
                except Exception:
                    pass

        rows.append(
            C.dropdown(
                tok, S("update_channel"),
                [("stable", S("update_channel_stable")), ("beta", S("update_channel_beta"))],
                channel, on_change=_on_channel,
            )
        )
        rows.append(C.txt(S("update_channel_hint"), tok, size=tok.fs_small, muted=True))
        info = state.update_banner
        if info is not None:
            rows.append(C.kv_row(tok, S("latest_version"), str(info.get("version") or "?")))

            async def _open_releases(e) -> None:
                await C.open_url(page, str(info.get("url") or ""))

            rows.append(
                ft.Row(
                    [
                        C.primary_button(S("download_update"), tok, on_click=_open_releases,
                                         icon=ft.Icons.UPGRADE),
                        C.ghost_button(S("update_dismiss"), tok,
                                       on_click=lambda e: state.dismiss_update()),
                    ],
                    spacing=8,
                )
            )
        elif state.update_check_running:
            rows.append(C.txt(S("checking_updates"), tok, size=tok.fs_small, muted=True))
        else:
            try:
                from strakalari.core.update import load_cached

                cached = load_cached(channel)
            except Exception:
                cached = None
            if cached and cached.get("version"):
                rows.append(C.kv_row(tok, S("latest_version"),
                                     f"{cached.get('version')} ({S('up_to_date')})"))
            rows.append(
                ft.Row(
                    [C.ghost_button(S("check_updates"), tok,
                                    on_click=lambda e: state.start_update_check(force=True))],
                    spacing=8,
                )
            )
        rows.append(C.divider(tok))
        rows.append(C.kv_row(tok, S("cache_info"), state.updated_label))
        rows.append(
            ft.Row(
                [C.ghost_button(S("clear_cache"), tok,
                                on_click=lambda e: self._clear_cache())],
                spacing=8,
            )
        )
        return [C.card(*rows, tok=tok)]

    def _clear_cache(self) -> None:
        import os

        try:
            from strakalari.core.cache import CACHE_FILE
            from strakalari.core.helpers import _resolve_path

            path = _resolve_path(CACHE_FILE)
            if os.path.exists(path):
                os.remove(path)
        except Exception as exc:  # noqa: BLE001 - report, don't crash
            snack(self.page, str(exc))
            return
        self.state.reload_cache()
        snack(self.page, S("cache_cleared"))
