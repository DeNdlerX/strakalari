"""Settings sections: accounts and subject limits."""

from __future__ import annotations

import flet as ft

from ... import components as C
from ...overlays import snack
from ...strings import S
from .common import (
    _browser_available, _save_quiet, _same, _show_value, _test_result,
)


class AccountsMixin:
    """Sections of :class:`SettingsView` (needs ``self.state`` / ``self.page``)."""

    # -- accounts ---------------------------------------------------------
    def _accounts(self) -> list:
        state, tok, page = self.state, self.state.tok, self.page
        b_pass_set = bool(state.get("bakalari_password"))
        s_pass_set = bool(state.get("strava_password", ""))

        def _on_strava_toggle(e):
            if not _save_quiet(state, page, {"use_strava": bool(e.control.value)}):
                e.control.value = bool(state.get("use_strava", True))
                page.update()

        blocks: list = [
            C.txt(S("account_bakalari"), tok, bold=True),
            self._auto(S("bakalari_url"), "acc:bakalari_url", "bakalari_url",
                       str(state.get("bakalari_url", ""))),
            C.hint_text(S("bakalari_url_hint"), tok),
            self._auto(f"{S('account_bakalari')} — {S('username')}",
                       "acc:bakalari_username", "bakalari_username",
                       str(state.get("bakalari_username", ""))),
            self._auto(f"{S('account_bakalari')} — {S('password')}",
                       "acc:bakalari_password", "bakalari_password", "", password=True,
                       hint=S("password_saved_hint") if b_pass_set else S("secret_empty")),
            C.divider(tok),
            C.txt(S("account_strava"), tok, bold=True),
            self._auto(S("strava_url"), "acc:strava_url", "strava_url",
                       str(state.get("strava_url", "https://strava.cz"))),
            self._auto(f"{S('account_strava')} — {S('username')}",
                       "acc:strava_username", "strava_username",
                       str(state.get("strava_username", ""))),
            self._auto(f"{S('account_strava')} — {S('password')}",
                       "acc:strava_password", "strava_password", "", password=True,
                       hint=S("password_saved_hint") if s_pass_set else S("secret_empty")),
            self._auto(S("canteen_id"), "acc:strava_canteen_id", "strava_canteen_id",
                       str(state.get("strava_canteen_id", ""))),
            C.hint_text(S("canteen_id_hint"), tok),
            C.toggle(tok, S("use_strava"), bool(state.get("use_strava", True)),
                     on_change=_on_strava_toggle),
        ]
        card = C.form_card(*blocks, tok=tok)

        def _overrides() -> dict:
            ov = {
                "bakalari_url": state.draft("acc:bakalari_url",
                                            str(state.get("bakalari_url", ""))),
                "bakalari_username": state.draft("acc:bakalari_username",
                                                 str(state.get("bakalari_username", ""))),
                "strava_url": state.draft("acc:strava_url",
                                          str(state.get("strava_url", ""))),
                "strava_username": state.draft("acc:strava_username",
                                               str(state.get("strava_username", ""))),
                "strava_canteen_id": state.draft("acc:strava_canteen_id",
                                                 str(state.get("strava_canteen_id", ""))),
            }
            if state.draft("acc:bakalari_password", "").strip():
                ov["bakalari_password"] = state.draft("acc:bakalari_password", "")
            if state.draft("acc:strava_password", "").strip():
                ov["strava_password"] = state.draft("acc:strava_password", "")
            return ov

        def _test_bakalari(e):
            if not _browser_available():
                snack(page, S("wiz_need_browser_first"))
                return
            if not state.test_connection("bakalari", _overrides()):
                snack(page, S("already_running"))
            else:
                snack(page, S("testing"))

        def _test_strava(e):
            if not _browser_available():
                snack(page, S("wiz_need_browser_first"))
                return
            if not state.test_connection("strava", _overrides()):
                snack(page, S("already_running"))
            else:
                snack(page, S("testing"))

        out: list = [card]
        out.append(ft.Row(
            [
                C.ghost_button(S("test_bakalari"), tok, on_click=_test_bakalari),
                C.ghost_button(S("test_strava"), tok, on_click=_test_strava),
            ],
            spacing=8,
            wrap=True,
        ))
        for svc in ("bakalari", "strava"):
            res = _test_result(state, svc)
            if res is not None:
                out.append(C.card(res, tok=tok))
        return out

    # -- subject limits -----------------------------------------------------
    def _limits(self) -> list:
        state, tok, page = self.state, self.state.tok, self.page

        def _commit_num(dkey: str, ckey: str, fallback: str, default: float,
                        minimum: float | None = None,
                        maximum: float | None = None):
            def _go(e):
                try:
                    val = e.control.value if e.control is not None else state.draft(dkey, fallback)
                except Exception:
                    val = state.draft(dkey, fallback)
                try:
                    num = float(str(val or fallback).replace(",", "."))
                except (TypeError, ValueError):
                    snack(page, S("save_failed"))
                    return
                if minimum is not None:
                    num = max(minimum, num)
                if maximum is not None:
                    num = min(maximum, num)
                if not _same(state.get(ckey), num) and not _save_quiet(
                        state, page, {ckey: num}):
                    return
                state.drafts.pop(dkey, None)
                _show_value(e.control if e is not None else None, num)
            return _go

        default_limit = C.labeled_field(
            tok, S("default_limit"),
            value=state.draft("lim:default", str(state.get("absence_critical_pct", 25.0))),
            on_change=self._bind("lim:default"),
            on_blur=_commit_num("lim:default", "absence_critical_pct",
                               str(state.get("absence_critical_pct", 25.0)), 25.0),
            on_submit=_commit_num("lim:default", "absence_critical_pct",
                                 str(state.get("absence_critical_pct", 25.0)), 25.0),
        )
        warn_limit = C.labeled_field(
            tok, S("warn_limit"),
            value=state.draft("lim:warn", str(state.get("absence_warn_pct", 15.0))),
            on_change=self._bind("lim:warn"),
            on_blur=_commit_num("lim:warn", "absence_warn_pct",
                               str(state.get("absence_warn_pct", 15.0)), 15.0),
            on_submit=_commit_num("lim:warn", "absence_warn_pct",
                                 str(state.get("absence_warn_pct", 15.0)), 15.0),
        )
        reserve_field = C.labeled_field(
            tok, S("reserve_limit"),
            value=state.draft("lim:reserve", str(state.get("absence_plan_reserve_pct", 10.0))),
            on_change=self._bind("lim:reserve"),
            on_blur=_commit_num("lim:reserve", "absence_plan_reserve_pct",
                               str(state.get("absence_plan_reserve_pct", 10.0)), 10.0,
                               minimum=0.0, maximum=99.9),
            on_submit=_commit_num("lim:reserve", "absence_plan_reserve_pct",
                                 str(state.get("absence_plan_reserve_pct", 10.0)), 10.0,
                                 minimum=0.0, maximum=99.9),
        )
        # Only stable, tracked subjects get a limit row — one-offs like
        # Třídnická hodina never count toward absence budgets.
        try:
            allowed = state.limit_subjects()
        except Exception:
            allowed = None
        if allowed is None:
            subjects = sorted(set(state.absence()))
        else:
            subjects = list(allowed)
        limits = dict(state.get("subject_limits", {}) or {})
        limit_rows = ft.Column(
            spacing=6, tight=True,
            horizontal_alignment=ft.CrossAxisAlignment.STRETCH,
        )
        for subject in subjects:
            dkey = f"lim:subj:{subject}"

            def _commit_subj(e, s=subject, k=dkey):
                try:
                    val = e.control.value if e.control is not None else state.draft(k, "")
                except Exception:
                    val = state.draft(k, "")
                raw = str(val or "").strip()
                stored = (state.get("subject_limits", {}) or {}).get(s)
                if (not raw and stored is None) or (
                        raw and stored is not None and _same(stored, raw.replace(",", "."))):
                    state.drafts.pop(k, None)
                    return  # focus moved without an edit: nothing to save
                if not raw:
                    current = dict(state.get("subject_limits", {}) or {})
                    current.pop(s, None)
                    if not _save_quiet(state, page, {"subject_limits": current}):
                        return
                    state.drafts.pop(k, None)
                    return
                try:
                    num = float(raw.replace(",", "."))
                except (TypeError, ValueError):
                    snack(page, S("save_failed"))
                    return
                current = dict(state.get("subject_limits", {}) or {})
                current[s] = num
                if not _save_quiet(state, page, {"subject_limits": current}):
                    return
                state.drafts.pop(k, None)

            box = C.labeled_field(
                tok, subject, value=state.draft(dkey, str(limits.get(subject, ""))),
                on_change=self._bind(dkey),
                on_blur=_commit_subj, on_submit=_commit_subj,
            )
            limit_rows.controls.append(box)
        return [C.form_card(default_limit, warn_limit, reserve_field,
                           C.hint_text(S("reserve_hint"), tok), limit_rows,
                           C.hint_text(S("limit_subject_hint"), tok), tok=tok)]
