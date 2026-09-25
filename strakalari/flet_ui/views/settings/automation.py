"""Settings sections: excuse templates, automation rules, browser and AI."""

from __future__ import annotations

import flet as ft

from ... import components as C
from ...overlays import snack
from ...strings import S
from .common import (
    _save_feedback, _save_quiet, _test_result, _tpl_editor,
)


class AutomationMixin:
    """Sections of :class:`SettingsView` (needs ``self.state`` / ``self.page``)."""

    # -- templates ------------------------------------------------------------
    def _templates(self) -> list:
        state, tok = self.state, self.state.tok

        sig_card = C.form_card(
            self._auto(S("signature"), "tpl:your_signature", "your_signature",
                       str(state.get("your_signature", ""))),
            tok=tok,
        )
        return [
            _tpl_editor(state, self.page, "late_income_excuses", "tpl_late"),
            _tpl_editor(state, self.page, "left_soon_excuses", "tpl_soon"),
            _tpl_editor(state, self.page, "short_absence_excuses", "tpl_short"),
            _tpl_editor(state, self.page, "long_absence_excuses", "tpl_long"),
            sig_card,
        ]

    # -- automation -------------------------------------------------------------
    def _automation(self) -> list:
        state, tok, page = self.state, self.state.tok, self.page
        modes = [("auto", S("mode_auto")), ("confirm", S("mode_confirm")),
                 ("dry_run", S("mode_dry_run"))]

        def _commit_mode(ckey: str, fallback: str):
            def _go(e):
                val = (e.control.value if e.control else "") or fallback
                _save_quiet(state, page, {ckey: val})
            return _go

        def _commit_guarded(ckey: str):
            """Mode picker: switching to ``auto`` needs an explicit OK."""
            def _go(e):
                control = e.control if e else None
                val = (control.value if control else "") or "confirm"
                previous = str(state.get(ckey, "confirm") or "confirm")
                if val != "auto" or previous == "auto":
                    _save_quiet(state, page, {ckey: val})
                    return

                def _set(value: str) -> None:
                    if value != previous:
                        _save_quiet(state, page, {ckey: value})
                    if control is not None:
                        control.value = value
                        try:
                            control.update()
                        except Exception:
                            pass  # re-rendered from config on the next emit

                from ..safety import confirm_auto_mode

                confirm_auto_mode(
                    page, ckey,
                    on_confirm=lambda: _set("auto"),
                    on_dry_run=lambda: _set("dry_run"),
                    on_cancel=lambda: _set(previous),
                )
            return _go

        excuse_mode = C.dropdown(
            tok, S("excuse_mode_label"), modes,
            str(state.get("excuse_mode", "confirm")),
            on_change=_commit_guarded("excuse_mode"),
        )
        order_mode = C.dropdown(
            tok, S("order_mode_label"), modes,
            str(state.get("strava_order_mode", "confirm")),
            on_change=_commit_guarded("strava_order_mode"),
        )
        pause = C.toggle(
            tok, S("automation_pause"), state.automation_paused(),
            on_change=lambda e: state.set_automation_paused(
                bool(e.control.value if e.control else False), page),
        )

        def _int_parse(default: int, minimum: int):
            def _parse(raw: str) -> int:
                try:
                    return max(minimum, int(float(str(raw or default).replace(",", "."))))
                except (TypeError, ValueError):
                    raise ValueError(S("save_failed")) from None
            return _parse

        interval = self._auto(S("check_interval"), "rule:interval",
                              "check_interval_minutes",
                              str(state.get("check_interval_minutes", 60)),
                              parse=_int_parse(60, 1))
        delay = self._auto(S("excuse_delay"), "rule:delay",
                           "excuse_delay_days",
                           str(state.get("excuse_delay_days", 2)),
                           parse=_int_parse(2, 0))
        goback = self._auto(S("go_back_weeks"), "rule:goback",
                            "go_back_weeks",
                            str(state.get("go_back_weeks", 4)),
                            parse=_int_parse(4, 0))
        goforward = self._auto(S("go_forward_weeks"), "rule:goforward",
                               "go_forward_weeks",
                               str(state.get("go_forward_weeks", 1)),
                               parse=_int_parse(1, 0))
        pick = C.dropdown(
            tok, S("default_excuse_pick"),
            [("first", S("pick_first")), ("random", S("pick_random"))],
            str(state.get("default_excuse_selection", "first")),
            on_change=_commit_mode("default_excuse_selection", "first"),
        )
        try:
            from strakalari.core import school_presets as _sp

            _preset_cutoff = _sp.preset_lunch_cutoff(
                str(state.get("school_preset_id", "") or ""))
        except Exception:
            _preset_cutoff = ""
        _cutoff_fb = str(state.get("lunch_order_cutoff_time", "") or "")

        def _parse_cutoff(raw: str) -> str:
            from strakalari.core.lunch_cutoff import is_valid_cutoff_time

            cleaned = str(raw or "").strip()
            if cleaned and not is_valid_cutoff_time(cleaned):
                raise ValueError(S("lunch_cutoff_invalid"))
            return cleaned

        cutoff = self._auto(S("lunch_cutoff_label"), "rule:cutoff",
                            "lunch_order_cutoff_time", _cutoff_fb,
                            hint=(_preset_cutoff or "12:00") + " · " + S("lunch_cutoff_hint"),
                            parse=_parse_cutoff)
        return [C.form_card(C.hint_text(S("automation_disclaimer"), tok),
                           pause, C.hint_text(S("automation_pause_hint"), tok),
                           excuse_mode, order_mode,
                           C.hint_text(S("automation_modes_hint"), tok),
                           interval, delay, goback, goforward, pick,
                           cutoff, tok=tok)]

    # -- browser & background ----------------------------------------------------
    def _browser(self) -> list:
        state, tok, page = self.state, self.state.tok, self.page

        def _commit_show(e):
            _save_quiet(state, page, {"hide_window": not bool(e.control.value)})

        def _commit_max(e):
            _save_quiet(state, page, {"maximize_window": bool(e.control.value)})

        def _commit_tray(e):
            _save_quiet(state, page, {"minimize_to_tray": bool(e.control.value)})

        def _commit_auto(e):
            wanted = bool(e.control.value)
            try:
                from strakalari.core.autostart import set_autostart

                ok = bool(set_autostart(wanted))
                message = S("autostart_failed")
            except Exception as exc:  # noqa: BLE001 - report, don't crash
                ok, message = False, f"{S('autostart_failed')} ({exc})"
            if not ok:
                # set_autostart reports failure by returning False: the
                # switch must not claim a state the system did not take.
                try:
                    e.control.value = not wanted
                    e.control.update()
                except Exception:
                    pass
                snack(page, message)

        show = C.toggle(tok, S("show_browser"), state.show_browser,
                        on_change=_commit_show)
        maximized = C.toggle(tok, S("maximize_browser"),
                             bool(state.get("maximize_window", False)),
                             on_change=_commit_max)
        try:
            from strakalari.core.autostart import is_autostart_enabled

            autostart_on = bool(is_autostart_enabled())
        except Exception:
            autostart_on = False
        autostart = C.toggle(tok, S("autostart"), autostart_on,
                             on_change=_commit_auto)
        tray = C.toggle(tok, S("minimize_to_tray"),
                        bool(state.get("minimize_to_tray", True)),
                        on_change=_commit_tray)
        return [C.form_card(show, C.hint_text(S("show_browser_hint"), tok),
                           maximized, autostart, tray, tok=tok)]
    # -- AI ----------------------------------------------------------------------------
    def _ai(self) -> list:
        state, tok, page = self.state, self.state.tok, self.page
        # A stored key counts when the ciphertext is non-empty, whatever the
        # flag says (legacy plaintext keys have the flag unset) — same rule
        # as the wizard and the lunches card.
        has_key = bool(state.get("gemini_api_key"))
        key_field = self._auto(S("gemini_key"), "ai:key", "gemini_api_key", "",
                               password=True,
                               hint=S("key_saved_hint") if has_key else S("secret_empty"))
        model_field = self._auto(S("gemini_model"), "ai:model", "gemini_model",
                                 str(state.get("gemini_model", "gemini-3.8-flash")))

        def _on_auto_toggle(e):
            try:
                _save_quiet(state, page,
                            {"gemini_auto_enabled": bool(e.control.value)})
            except Exception:
                pass

        def _parse_interval(raw: str) -> int:
            try:
                num = int(float(str(raw or "2").replace(",", ".")))
            except (TypeError, ValueError):
                raise ValueError(S("save_failed")) from None
            return max(1, min(30, num))

        auto_toggle = C.toggle(
            tok, S("ai_auto_enable"),
            bool(state.get("gemini_auto_enabled", False)),
            on_change=_on_auto_toggle,
        )
        prompt_field = self._auto(
            S("ai_prompt"), "ai:prompt", "gemini_prompt",
            str(state.get("gemini_prompt", "") or ""),
            multiline=True, hint=S("ai_prompt_hint"),
        )
        interval_field = self._auto(
            S("ai_interval"), "ai:interval", "gemini_interval_days",
            str(state.get("gemini_interval_days", 2)),
            hint=S("ai_interval_hint"), parse=_parse_interval,
        )
        try:
            _last = str(state.get("gemini_last_run", "") or "").strip()
        except Exception:
            _last = ""
        async def _open_key(e):
            await C.open_url(page, C.AI_STUDIO_URL)

        out = [C.form_card(key_field,
                           C.ghost_button(S("ai_key_link"), tok,
                                          icon=ft.Icons.OPEN_IN_NEW,
                                          on_click=_open_key),
                           C.hint_text(S("ai_key_steps"), tok),
                           C.hint_text(S("gemini_key_hint"), tok),
                           model_field,
                           C.hint_text(S("ai_model_hint"), tok),
                           tok=tok)]
        out.append(C.form_card(
            auto_toggle,
            C.hint_text(S("ai_auto_hint"), tok),
            prompt_field,
            interval_field,
            C.kv_row(tok, S("ai_last_run"), _last or S("ai_never")),
            tok=tok,
        ))

        def _ai_overrides() -> dict:
            ov: dict = {}
            if state.draft("ai:key", "").strip():
                ov["gemini_api_key"] = state.draft("ai:key", "")
            model = state.draft(
                "ai:model", str(state.get("gemini_model", "gemini-3.8-flash"))).strip()
            if model:
                ov["gemini_model"] = model
            return ov

        def _test_ai(e):
            if not state.test_connection("ai", _ai_overrides()):
                snack(page, S("already_running"))
            else:
                snack(page, S("testing"))

        def _clear_ai_key(e):
            ok = _save_feedback(state, page,
                                {"gemini_api_key": "", "gemini_api_key_encrypted": False})
            if ok:
                state.clear_drafts("ai:")

        test_row: list = [C.ghost_button(S("wiz_test_key"), tok, on_click=_test_ai)]
        if has_key:
            test_row.append(C.ghost_button(S("delete"), tok, on_click=_clear_ai_key))
        out.append(ft.Row(test_row, spacing=8, wrap=True))
        res = _test_result(state, "ai")
        if res is not None:
            out.append(C.card(res, tok=tok))
        return out
