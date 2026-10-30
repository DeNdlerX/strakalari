"""Settings sections: excuse templates, automation rules, wake-up alarm,
background running and AI."""

from __future__ import annotations

from datetime import date

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

                from ...safety import confirm_auto_mode

                confirm_auto_mode(
                    page, ckey,
                    on_confirm=lambda: _set("auto"),
                    on_dry_run=lambda: _set("dry_run"),
                    on_cancel=lambda: _set(previous),
                    unsigned=not str(state.get("your_signature", "") or "").strip(),
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
        return [
            C.form_card(C.hint_text(S("automation_disclaimer"), tok),
                        pause, C.hint_text(S("automation_pause_hint"), tok),
                        excuse_mode, order_mode,
                        C.hint_text(S("automation_modes_hint"), tok),
                        interval, delay, goback, goforward, pick,
                        cutoff, tok=tok),
        ]

    # -- wake-up alarm (section "alarm", Android only) ----------------------------
    def _wakeup(self) -> list:
        """The phone's wake-up alarm (the section exists in the Android app only)."""
        state, tok, page = self.state, self.state.tok, self.page
        if not state.wakeup_available():
            return [C.form_card(C.txt(S("wakeup_title"), tok, bold=True),
                                C.hint_text(S("wakeup_unavailable"), tok), tok=tok)]
        from strakalari.core import android
        from strakalari.core.wakeup import clamp_wakeup_minutes, skipped_days, with_skipped_day

        enabled = bool(state.get("wakeup_enabled", False))
        minutes = clamp_wakeup_minutes(state.get("wakeup_minutes_before", 60))

        def _toggle(e):
            on = bool(e.control.value) if e.control is not None else False
            if not state.save({"wakeup_enabled": on}):
                snack(page, S("save_failed"))
            elif on:
                android.request_notification_permission()

        def _parse_minutes(raw: str) -> int:
            try:
                float(str(raw).strip().replace(",", "."))
            except ValueError:
                raise ValueError(S("wakeup_minutes_invalid")) from None
            return clamp_wakeup_minutes(raw)

        def _set_skipped(day: date, skip: bool) -> None:
            skips = with_skipped_day(state.config.data, day, skip)
            if not state.save({"wakeup_skip_dates": skips}):
                snack(page, S("save_failed"))

        def _day(day: date) -> str:
            return f"{C.day_name(day, short=True)} {C.cz_day(day)}"

        def _open_clock(alarm) -> None:
            if not android.open_system_alarm(alarm.alarm_dt.hour, alarm.alarm_dt.minute,
                                             f"Strakaláři · {alarm.subject}"):
                snack(page, S("wakeup_clock_failed"))

        def _live_rows() -> list[ft.Control]:
            """Everything that follows the saved minutes, the permissions and
            the timetable: rebuilt in place when the minutes change."""
            minutes = clamp_wakeup_minutes(state.get("wakeup_minutes_before", 60))
            rows: list[ft.Control] = [C.hint_text(S("wakeup_hint").format(n=minutes), tok)]
            if not enabled:
                return rows
            if not android.notifications_enabled():
                rows += [
                    C.txt(S("wakeup_notif_off"), tok, size=tok.fs_small, color=tok.yellow),
                    ft.Row([
                        C.primary_button(S("notif_allow"), tok,
                                         icon=ft.Icons.NOTIFICATIONS_ACTIVE,
                                         on_click=lambda e: android.request_notification_permission()),
                        C.ghost_button(S("notif_open_settings"), tok,
                                       on_click=lambda e: android.open_notification_settings()),
                    ], spacing=8, run_spacing=8, wrap=True),
                ]
            if not android.exact_alarms_allowed():
                rows += [
                    C.txt(S("wakeup_exact_off"), tok, size=tok.fs_small, color=tok.yellow),
                    C.ghost_button(S("wakeup_exact_allow"), tok, icon=ft.Icons.ALARM_ON,
                                   on_click=lambda e: android.open_exact_alarm_settings()),
                ]

            alarm = state.next_wakeup_alarm()
            if alarm is None:
                rows.append(C.txt(S("wakeup_none"), tok, size=tok.fs_small, muted=True))
            else:
                rows.append(C.txt(
                    S("wakeup_next").format(day=_day(alarm.day), alarm=alarm.alarm_time_label,
                                            subject=alarm.subject,
                                            lesson=alarm.lesson_time_label),
                    tok, size=tok.fs_small, color=tok.accent, bold=True,
                ))
                rows.append(ft.Row([
                    C.ghost_button(S("wakeup_skip_next"), tok, icon=ft.Icons.ALARM_OFF,
                                   on_click=lambda e, d=alarm.day: _set_skipped(d, True)),
                    C.ghost_button(S("wakeup_set_clock"), tok, icon=ft.Icons.ALARM_ADD,
                                   on_click=lambda e, a=alarm: _open_clock(a)),
                ], spacing=8, run_spacing=8, wrap=True))

            skipped = sorted(d for d in skipped_days(state.config.data) if d >= date.today())
            if skipped:
                rows.append(C.txt(S("wakeup_skipped"), tok, size=tok.fs_small, muted=True))
                rows.append(ft.Row([
                    C.ghost_button(S("wakeup_restore_day").format(day=_day(d)), tok,
                                   icon=ft.Icons.RESTORE,
                                   on_click=lambda e, d=d: _set_skipped(d, False))
                    for d in skipped
                ], spacing=8, run_spacing=8, wrap=True))
            return rows

        live = ft.Column(_live_rows(), spacing=tok.gap, tight=True)

        def _refresh_live(_value=None) -> None:
            live.controls = _live_rows()
            try:
                live.update()
            except Exception:
                pass  # not on screen: the next render builds it fresh

        return [C.form_card(
            C.txt(S("wakeup_title"), tok, bold=True),
            C.toggle(tok, S("wakeup_enable"), enabled, on_change=_toggle),
            self._auto(S("wakeup_minutes"), "rule:wakeup_min", "wakeup_minutes_before",
                       str(minutes), parse=_parse_minutes, on_saved=_refresh_live),
            live,
            tok=tok,
        )]

    # -- background (section id "browser" kept for saved navigation) ------------
    def _browser(self) -> list:
        state, tok, page = self.state, self.state.tok, self.page
        from strakalari.core.packaging import mobile_platform

        if mobile_platform() == "android":
            return self._phone_background()

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

        try:
            from strakalari.core.autostart import is_autostart_enabled
            from strakalari.core.packaging import is_store_package

            store_managed = bool(is_store_package())
            autostart_on = False if store_managed else bool(is_autostart_enabled())
        except Exception:
            store_managed, autostart_on = False, False
        if store_managed:
            # StartupTask is owned by Windows (Settings > Apps > Startup);
            # the HKCU Run toggle has no effect inside the MSIX container.
            async def _open_startup_settings(e) -> None:
                await C.open_url(page, "ms-settings:startupapps")

            autostart = ft.Column(
                [
                    C.hint_text(S("autostart_store_managed"), tok),
                    C.ghost_button(S("autostart_open_settings"), tok,
                                   on_click=_open_startup_settings,
                                   icon=ft.Icons.OPEN_IN_NEW),
                ],
                spacing=8,
            )
        else:
            autostart = C.toggle(tok, S("autostart"), autostart_on,
                                 on_change=_commit_auto)
        tray = C.toggle(tok, S("minimize_to_tray"),
                        bool(state.get("minimize_to_tray", True)),
                        on_change=_commit_tray)
        return [C.form_card(autostart, tray, tok=tok)]

    def _phone_background(self) -> list:
        """Android: run in the background (the app starts / stops its
        service when the setting is saved, see app._setup_phone_background)."""
        state, tok, page = self.state, self.state.tok, self.page

        def _commit(e):
            _save_quiet(state, page, {"run_in_background": bool(e.control.value)})

        return [C.form_card(
            C.toggle(tok, S("run_in_background"), bool(state.get("run_in_background", True)),
                     on_change=_commit),
            C.hint_text(S("run_in_background_hint"), tok),
            tok=tok,
        )]
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
