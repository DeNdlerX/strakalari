"""First-run setup wizard: Bakalari login, subject limits, Strava login,
AI key, calendar, wake-up alarm (Android only), excuse signature and
templates.

Shown full-screen by the Shell while ``state.needs_setup()`` is true (no
valid Bakalari credentials, not skipped).

Each credential step (Bakalari, Strava, AI key) runs a live test when the
user presses Continue — the wizard only advances on success (staying
put with the error otherwise). Finishing the wizard kicks off the
first data refresh automatically.

The limits step loads the subjects with a Bakalari-only refresh the
first time it shows (right after the login step).
"""

from __future__ import annotations

import flet as ft

from .. import components as C
from ..overlays import snack
from ..state import AppState
from ..strings import S

STEPS_TOTAL = 10

STEP_WELCOME = 0
STEP_DISCLAIMER = 1
STEP_BAKALARI = 2
STEP_LIMITS = 3
STEP_STRAVA = 4
STEP_AI = 5
STEP_CALENDAR = 6
STEP_ALARM = 7
STEP_EXCUSES = 8
STEP_DONE = 9


def _alarm_here() -> bool:
    """The wake-up alarm rings on the Android phone only."""
    from strakalari.core.packaging import mobile_platform

    return mobile_platform() == "android"


def _shown_steps() -> list[int]:
    """The steps this platform walks through (the alarm step: Android only)."""
    return [s for s in range(STEPS_TOTAL) if s != STEP_ALARM or _alarm_here()]


def _step_after(step: int) -> int:
    return next((s for s in _shown_steps() if s > step), STEP_DONE)


def _step_before(step: int) -> int:
    return next((s for s in reversed(_shown_steps()) if s < step), 0)


def _v(state: AppState, key: str, fallback: str = "") -> str:
    return state.draft(key, fallback)


def _bind(state: AppState, key: str):
    return lambda e, k=key: state.set_draft(k, e.control.value or "")


def _field(state: AppState, label: str, key: str, fallback: str = "",
           password: bool = False, hint: str = "") -> ft.Control:
    return C.labeled_field(
        state.tok, label, value=_v(state, key, fallback),
        password=password, hint=hint, on_change=_bind(state, key),
    )


def _strava_enabled(state: AppState) -> bool:
    raw = state.drafts.get("wiz:strava_enabled")
    if raw is not None:
        return raw == "1"
    return bool(state.get("use_strava", True))


def _ai_enabled(state: AppState) -> bool:
    raw = state.drafts.get("wiz:ai_enabled")
    if raw is not None:
        return raw == "1"
    return bool(state.get("gemini_api_key", ""))


def _save_bakalari(state: AppState) -> bool:
    url = _v(state, "wiz:bakalari_url", str(state.get("bakalari_url", ""))).strip()
    user = _v(state, "wiz:bakalari_username", str(state.get("bakalari_username", ""))).strip()
    pw = _v(state, "wiz:bakalari_password", "")
    has_pw = bool(pw.strip()) or bool(state.get("bakalari_password", ""))
    if not url or not user or not has_pw:
        return False
    updates = {"bakalari_url": url, "bakalari_username": user}
    if pw:
        updates["bakalari_password"] = pw
    return bool(state.save(updates))


def _save_strava(state: AppState) -> bool:
    if not _strava_enabled(state):
        return bool(state.save({"use_strava": False}))
    user = _v(state, "wiz:strava_username", str(state.get("strava_username", ""))).strip()
    pw = _v(state, "wiz:strava_password", "")
    cid = _v(state, "wiz:strava_canteen_id", str(state.get("strava_canteen_id", ""))).strip()
    has_pw = bool(pw.strip()) or bool(state.get("strava_password", ""))
    if not user or not has_pw or not cid:
        return False
    updates = {"use_strava": True, "strava_username": user, "strava_canteen_id": cid}
    if pw:
        updates["strava_password"] = pw
    return bool(state.save(updates))


def _save_ai(state: AppState) -> bool:
    if not _ai_enabled(state):
        # Disabling must stick: clear the stored key (encrypt("") is ""
        # and reads back falsy), otherwise the old key silently re-enables AI.
        return bool(state.save({"gemini_api_key": "", "gemini_api_key_encrypted": False}))
    key = _v(state, "wiz:ai_key", "").strip()
    has_key = bool(key) or bool(state.get("gemini_api_key", ""))
    if not has_key:
        return False
    updates: dict = {}
    if key:
        updates["gemini_api_key"] = key
    model = _v(state, "wiz:ai_model", str(state.get("gemini_model", "gemini-3.8-flash"))).strip()
    if model:
        updates["gemini_model"] = model
    if updates:
        return bool(state.save(updates))
    return True


# -- live-test helpers (draft-backed, no save needed to test) ---------------

def _overrides_bakalari(state: AppState) -> dict:
    ov = {
        "bakalari_url": _v(state, "wiz:bakalari_url",
                           str(state.get("bakalari_url", ""))).strip(),
        "bakalari_username": _v(state, "wiz:bakalari_username",
                                str(state.get("bakalari_username", ""))).strip(),
    }
    pw = _v(state, "wiz:bakalari_password", "")
    if pw.strip():
        ov["bakalari_password"] = pw
    return ov


def _overrides_strava(state: AppState) -> dict:
    ov = {
        "strava_username": _v(state, "wiz:strava_username",
                              str(state.get("strava_username", ""))).strip(),
        "strava_canteen_id": _v(state, "wiz:strava_canteen_id",
                                str(state.get("strava_canteen_id", ""))).strip(),
    }
    pw = _v(state, "wiz:strava_password", "")
    if pw.strip():
        ov["strava_password"] = pw
    return ov


def _overrides_ai(state: AppState) -> dict:
    ov: dict = {}
    key = _v(state, "wiz:ai_key", "").strip()
    if key:
        ov["gemini_api_key"] = key
    model = _v(state, "wiz:ai_model",
               str(state.get("gemini_model", "gemini-3.8-flash"))).strip()
    if model:
        ov["gemini_model"] = model
    return ov


def _overrides_for(state: AppState, service: str) -> dict:
    if service == "bakalari":
        return _overrides_bakalari(state)
    if service == "strava":
        return _overrides_strava(state)
    return _overrides_ai(state)


def _fp_for(state: AppState, service: str) -> str:
    """Fingerprint of the values a test ran against (re-test on change)."""
    return f"{service}:{sorted(_overrides_for(state, service).items())!r}"


def _ready_bakalari(state: AppState) -> bool:
    ov = _overrides_bakalari(state)
    has_pw = bool(ov.get("bakalari_password")) or bool(state.get("bakalari_password", ""))
    return bool(ov.get("bakalari_url") and ov.get("bakalari_username") and has_pw)


def _ready_strava(state: AppState) -> bool:
    if not _strava_enabled(state):
        return True
    ov = _overrides_strava(state)
    has_pw = bool(ov.get("strava_password")) or bool(state.get("strava_password", ""))
    return bool(ov.get("strava_username") and has_pw and ov.get("strava_canteen_id"))


def _ready_ai(state: AppState) -> bool:
    if not _ai_enabled(state):
        return True
    ov = _overrides_ai(state)
    return bool(ov.get("gemini_api_key") or state.get("gemini_api_key", ""))


def _save_for(service: str, state: AppState) -> bool:
    if service == "bakalari":
        return _save_bakalari(state)
    if service == "strava":
        return _save_strava(state)
    return _save_ai(state)


def _begin_wizard_test(state: AppState, page: ft.Page | None,
                       service: str, step: int) -> bool:
    """Starts the live test for a wizard step. Returns True if started.

    On success the values are saved, the fingerprint is marked verified
    and the wizard auto-advances (when still on the same step with
    unchanged fields). On failure the wizard stays put showing the
    error — the user fixes the fields and presses Continue again.
    """
    fp = _fp_for(state, service)
    overrides = _overrides_for(state, service)

    def _on_done(ok: bool, _message: str) -> None:
        if not ok:
            return
        if not _save_for(service, state):
            # Tested fine but not persisted: never advance past values
            # that would be gone after a restart.
            if page is not None:
                snack(page, S("save_failed"))
            return
        state.wizard_verified[service] = fp
        try:
            if (state.wizard_step == step and not state.wizard_dismissed
                    and _fp_for(state, service) == fp):
                state.wizard_goto(_step_after(step))
        except Exception:
            pass

    if not state.test_connection(service, overrides, on_done=_on_done):
        if page is not None:
            snack(page, S("already_running"))
        return False
    return True


def _test_rows(state: AppState, service: str) -> list:
    """Spinner or last-result line for a credential step.

    The test itself is started by the primary "Test & continue" button,
    so there is no separate test button here.
    """
    tok = state.tok
    if state.testing == service:
        return [_busy_row(tok, S("testing"))]
    last = state.last_test or {}
    if last.get("service") == service and last.get("at"):
        color = tok.green if last.get("ok") else tok.red
        prefix = S("connection_ok") if last.get("ok") else S("connection_failed")
        return [C.txt(f"{prefix} ({last.get('at')}): {last.get('message', '')}",
                      tok, size=tok.fs_small, color=color)]
    return []


def _disclaimer_ok(state: AppState) -> bool:
    """Accepted now (checkbox) or in an earlier run (config)."""
    return bool(state.drafts.get("wiz:disclaimer")) or bool(state.get("disclaimer_accepted", False))


def _preset_ids() -> tuple[str, ...]:
    """Every selectable calendar: shipped + user presets, then ``custom``."""
    from strakalari.core import school_presets as sp
    from strakalari.core.i18n import get_language

    return tuple(pid for pid, _ in sp.preset_options(get_language())) + (sp.CUSTOM_ID,)


def _cal_preset(state: AppState) -> str:
    # No default: the user must explicitly pick a card before continuing.
    raw = state.drafts.get("wiz:cal_preset")
    if raw is not None:
        return raw if raw in _preset_ids() else ""
    return ""


def _preset_lines(preset_id: str) -> tuple[int, list[tuple[str, int]]]:
    """(total days, [(label, count)]) grouped by label, first-date order.

    Days after the preset's own sem2 closure are excluded so the wizard
    preview never advertises free days past the final end date.
    """
    from strakalari.core import school_presets as sp

    days = sp.preset_days(preset_id)
    _, sem2_raw = sp.preset_closes(preset_id)
    if sem2_raw:
        from strakalari.core.models import parse_cz_date

        sem2_end = parse_cz_date(sem2_raw)
        if sem2_end is not None:
            days = {d: lbl for d, lbl in days.items() if d <= sem2_end}
    counts: dict[str, int] = {}
    order: list[str] = []
    for day in sorted(days):
        label = days[day] or ""
        if label not in counts:
            counts[label] = 0
            order.append(label)
        counts[label] += 1
    return len(days), [(label, counts[label]) for label in order]


def _save_calendar(state: AppState) -> bool:
    preset = _cal_preset(state)
    if preset not in _preset_ids():
        return False
    # Closures and free days resolve from the preset (or stay empty for
    # custom until filled in Settings) — the wizard asks for no dates.
    return bool(state.save({"school_preset_id": preset}))


def _limit_subjects(state: AppState) -> list[str]:
    """The subjects Settings > Subject limits lists (stable + tracked)."""
    try:
        allowed = state.limit_subjects()
    except Exception:
        allowed = None
    if allowed is None:
        return sorted(set(state.absence()))
    return list(allowed)


def _start_limits_refresh(state: AppState) -> None:
    """Loads the subjects once, the first time the limits step shows."""
    if state.drafts.get("wiz:limits_refresh") or state.refresh_running:
        return
    if not state._has_credentials() or _limit_subjects(state):
        return
    state.set_draft("wiz:limits_refresh", "1")
    state.start_refresh("bakalari")


def _limit_value(raw: str) -> float | None:
    """A limit in percent, None when blank. Raises ValueError when invalid."""
    text = str(raw or "").strip().replace(",", ".")
    if not text:
        return None
    num = float(text)
    if not 0 <= num <= 100:
        raise ValueError(text)
    return num


def _limits_updates(state: AppState) -> dict | None:
    """Config updates for the limits step, None when a value is invalid.

    A blank subject falls back to the default limit (no own entry).
    """
    try:
        default = _limit_value(_v(state, "wiz:limit_default",
                                  str(state.get("absence_critical_pct", 25.0))))
        limits = dict(state.get("subject_limits", {}) or {})
        for subject in _limit_subjects(state):
            value = _limit_value(_v(state, f"wiz:limit:{subject}",
                                    str(limits.get(subject, ""))))
            if value is None:
                limits.pop(subject, None)
            else:
                limits[subject] = value
    except ValueError:
        return None
    updates: dict = {"subject_limits": limits}
    if default is not None:
        updates["absence_critical_pct"] = default
    return updates


def _signature(state: AppState) -> str:
    return _v(state, "wiz:signature", str(state.get("your_signature", "") or "")).strip()


def _save_signature(state: AppState) -> bool:
    # Required: without a name every excuse would go out unsigned.
    name = _signature(state)
    if not name:
        return False
    return bool(state.save({"your_signature": name}))


def _alarm_enabled(state: AppState) -> bool:
    raw = state.drafts.get("wiz:wakeup_enabled")
    if raw is not None:
        return raw == "1"
    return bool(state.get("wakeup_enabled", False))


def _alarm_minutes(state: AppState) -> int | None:
    """The typed minutes (clamped to 1–720), None when not a number."""
    from strakalari.core.wakeup import clamp_wakeup_minutes

    stored = clamp_wakeup_minutes(state.get("wakeup_minutes_before", 60))
    raw = _v(state, "wiz:wakeup_minutes", str(stored)).strip().replace(",", ".")
    try:
        float(raw)
    except ValueError:
        return None
    return clamp_wakeup_minutes(raw)


def _save_alarm(state: AppState) -> bool:
    """Saves the alarm step; False when the minutes aren't a number."""
    if not _alarm_enabled(state):
        return bool(state.save({"wakeup_enabled": False}))
    minutes = _alarm_minutes(state)
    if minutes is None:
        return False
    if not state.save({"wakeup_enabled": True, "wakeup_minutes_before": minutes}):
        return False
    from strakalari.core import android

    android.request_notification_permission()  # the alarm rings as a notification
    return True


def _busy_row(tok, text: str) -> ft.Control:
    return ft.Row(
        [ft.ProgressRing(width=14, height=14, stroke_width=2, color=tok.accent),
         C.txt(text, tok, size=tok.fs_small, muted=True)],
        spacing=8, tight=True,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )


def _step_content(state: AppState, page: ft.Page | None, step: int) -> list:
    tok = state.tok
    if step == STEP_WELCOME:
        lang = state.get("language", "cs")
        return [
            C.txt(S("wiz_welcome_h"), tok, size=22, bold=True),
            C.txt(S("wiz_welcome_p"), tok, muted=True),
            ft.Row(
                [
                    C.ghost_button("Čeština", tok,
                                   on_click=lambda e: state.set_language("cs"))
                    if lang != "cs" else C.primary_button("Čeština", tok,
                                                          on_click=lambda e: None),
                    C.ghost_button("English", tok,
                                   on_click=lambda e: state.set_language("en"))
                    if lang != "en" else C.primary_button("English", tok,
                                                          on_click=lambda e: None),
                ],
                spacing=8,
            ),
        ]
    if step == STEP_DISCLAIMER:
        def _ack(e):
            state.set_draft("wiz:disclaimer", "1" if (e.control and e.control.value) else "")
            state._emit()

        return [
            C.txt(S("wiz_disclaimer_h"), tok, size=19, bold=True),
            C.txt(S("wiz_disclaimer_p"), tok, muted=True),
            C.txt(S("wiz_disclaimer_rules"), tok),
            ft.Checkbox(label=S("wiz_disclaimer_ack"), value=_disclaimer_ok(state),
                        on_change=_ack, active_color=tok.accent),
        ]
    if step == STEP_BAKALARI:
        rows = [
            C.txt(S("wiz_bakalari_h"), tok, size=19, bold=True),
            C.txt(S("wiz_bakalari_p"), tok, muted=True),
            _field(state, S("bakalari_url"), "wiz:bakalari_url",
                   str(state.get("bakalari_url", "")),
                   hint=S("bakalari_url_hint")),
            _field(state, S("username"), "wiz:bakalari_username",
                   str(state.get("bakalari_username", ""))),
            _field(state, S("password"), "wiz:bakalari_password", "",
                   password=True,
                   hint=S("new_password") if state.get("bakalari_password") else S("secret_empty")),
        ]
        rows += _test_rows(state, "bakalari")
        return rows
    if step == STEP_LIMITS:
        rows = [
            C.txt(S("wiz_limits_h"), tok, size=19, bold=True),
            C.txt(S("wiz_limits_p"), tok, muted=True),
        ]
        if state.refresh_running:
            # No inputs while loading: every progress tick rebuilds the wizard.
            rows.append(_busy_row(tok, S("wiz_limits_loading")))
            if state.current_step:
                rows.append(C.txt(state.current_step, tok, size=tok.fs_small, faint=True))
            return rows
        subjects = _limit_subjects(state)
        if not subjects:
            def _reload(e):
                if not state.start_refresh("bakalari") and page is not None:
                    snack(page, S("already_running"))

            rows += [
                C.hint_text(S("wiz_limits_none"), tok),
                ft.Row([C.ghost_button(S("wiz_limits_retry"), tok, icon=ft.Icons.REFRESH,
                                       on_click=_reload)]),
            ]
            return rows
        limits = state.get("subject_limits", {}) or {}
        rows += [
            _field(state, S("default_limit"), "wiz:limit_default",
                   str(state.get("absence_critical_pct", 25.0))),
            C.hint_text(S("limit_subject_hint"), tok),
        ]
        rows += [_field(state, subject, f"wiz:limit:{subject}",
                        str(limits.get(subject, "")))
                 for subject in subjects]
        return rows
    if step == STEP_STRAVA:
        enabled = _strava_enabled(state)

        def _toggle_strava(e):
            state.set_draft("wiz:strava_enabled", "1" if e.control.value else "")
            state._emit()

        out: list = [
            C.txt(S("wiz_strava_h"), tok, size=19, bold=True),
            C.txt(S("wiz_strava_p"), tok, muted=True),
            C.toggle(tok, S("use_strava"), enabled, on_change=_toggle_strava),
        ]
        if enabled:
            out += [
                _field(state, S("username"), "wiz:strava_username",
                       str(state.get("strava_username", ""))),
                _field(state, S("password"), "wiz:strava_password", "",
                       password=True,
                       hint=S("new_password") if state.get("strava_password") else S("secret_empty")),
                _field(state, S("canteen_id"), "wiz:strava_canteen_id",
                       str(state.get("strava_canteen_id", "")),
                       hint=S("canteen_id_hint")),
            ]
            out += _test_rows(state, "strava")
        return out
    if step == STEP_AI:
        enabled = _ai_enabled(state)

        def _toggle_ai(e):
            state.set_draft("wiz:ai_enabled", "1" if e.control.value else "")
            state._emit()

        async def _open_key(e):
            if page is not None:
                await C.open_url(page, C.AI_STUDIO_URL)

        out = [
            C.txt(S("wiz_ai_h"), tok, size=19, bold=True),
            C.txt(S("wiz_ai_p"), tok, muted=True),
            C.toggle(tok, S("wiz_use_ai"), enabled, on_change=_toggle_ai),
        ]
        if enabled:
            out += [
                _field(state, S("gemini_key"), "wiz:ai_key", "",
                       password=True,
                       hint=S("new_password") if state.get("gemini_api_key") else S("secret_empty")),
                C.ghost_button(S("ai_key_link"), tok, icon=ft.Icons.OPEN_IN_NEW,
                               on_click=_open_key),
                C.hint_text(S("ai_key_steps"), tok),
                _field(state, S("gemini_model"), "wiz:ai_model",
                       str(state.get("gemini_model", "gemini-3.8-flash"))),
                C.hint_text(S("ai_model_hint"), tok),
            ]
            out += _test_rows(state, "ai")
        return out
    if step == STEP_CALENDAR:
        from strakalari.core import school_presets as sp

        from ..theme import border_all, pad_all, radius_all

        preset = _cal_preset(state)
        narrow = C.narrow(state)

        def _pick(p):
            state.set_draft("wiz:cal_preset", p)
            state._emit()

        def _option_card(pid: str, title: str, body: list) -> ft.Control:
            selected = preset == pid
            return ft.Container(
                content=ft.Column(
                    [
                        ft.Row(
                            [
                                C.txt(title, tok, bold=True),
                                ft.Container(expand=True),
                                ft.Icon(
                                    ft.Icons.CHECK_CIRCLE
                                    if selected else
                                    ft.Icons.RADIO_BUTTON_UNCHECKED,
                                    color=tok.accent if selected else tok.faint,
                                    size=20,
                                ),
                            ],
                            spacing=8, tight=True,
                            vertical_alignment=ft.CrossAxisAlignment.CENTER,
                        ),
                        *body,
                    ],
                    spacing=4, tight=True,
                ),
                bgcolor=tok.card,
                border=border_all(2 if selected else 1,
                                 tok.accent if selected else tok.border),
                border_radius=radius_all(tok.radius_md),
                padding=pad_all(tok.pad),
                width=None if narrow else 280,  # phone: stacked, full width
                on_click=lambda e, p=pid: _pick(p),
            )

        from strakalari.core.i18n import get_language

        def _preset_body(pid: str) -> list:
            total, groups = _preset_lines(pid)
            s1, s2 = sp.preset_closes(pid)
            return [
                C.txt(S("cal_closes").format(a=s1 or S("cal_auto"), b=s2 or S("cal_auto")),
                      tok, size=tok.fs_small, muted=True),
                C.txt(S("wiz_cal_days").format(n=total, end=s2 or S("cal_auto")),
                      tok, size=tok.fs_small, bold=True),
                C.txt(" · ".join(f"{label} {count}" for label, count in groups),
                      tok, size=tok.fs_small, muted=True),
                C.txt(S("wiz_cal_only_school"), tok, size=tok.fs_small, faint=True),
            ]

        cards = [_option_card(pid, title, _preset_body(pid))
                 for pid, title in sp.preset_options(get_language())]
        cards.append(_option_card("custom", S("wiz_cal_custom"),
                                  [C.txt(S("wiz_cal_custom_p"), tok,
                                         size=tok.fs_small, muted=True)]))
        rows_cal: list = [
            C.txt(S("wiz_cal_h"), tok, size=19, bold=True),
            C.txt(S("wiz_cal_p"), tok, muted=True),
            ft.Column(cards, spacing=8, tight=True,
                      horizontal_alignment=ft.CrossAxisAlignment.STRETCH)
            if narrow else ft.Row(cards, spacing=8, wrap=True),
        ]
        if not preset:
            rows_cal.append(C.hint_text(S("wiz_cal_pick"), tok))
        return rows_cal
    if step == STEP_ALARM:
        from strakalari.core import android

        enabled = _alarm_enabled(state)

        def _toggle_alarm(e):
            state.set_draft("wiz:wakeup_enabled", "1" if e.control.value else "")
            state._emit()

        rows_alarm: list = [
            C.txt(S("wiz_alarm_h"), tok, size=19, bold=True),
            C.txt(S("wiz_alarm_p"), tok, muted=True),
            C.toggle(tok, S("wakeup_enable"), enabled, on_change=_toggle_alarm),
        ]
        if enabled:
            minutes = _alarm_minutes(state) or 60
            rows_alarm += [
                _field(state, S("wakeup_minutes"), "wiz:wakeup_minutes", str(minutes)),
                C.hint_text(S("wakeup_hint").format(n=minutes), tok),
            ]
            if android.available() and not android.exact_alarms_allowed():
                rows_alarm += [
                    C.txt(S("wakeup_exact_off"), tok, size=tok.fs_small, color=tok.yellow),
                    ft.Row([C.ghost_button(S("wakeup_exact_allow"), tok, icon=ft.Icons.ALARM_ON,
                                           on_click=lambda e: android.open_exact_alarm_settings())]),
                ]
        rows_alarm.append(C.hint_text(S("wiz_alarm_later"), tok))
        return rows_alarm
    if step == STEP_EXCUSES:
        from .settings.common import _tpl_editor

        return [
            C.txt(S("wiz_excuses_h"), tok, size=19, bold=True),
            C.txt(S("wiz_excuses_p"), tok, muted=True),
            _field(state, S("signature"), "wiz:signature",
                   str(state.get("your_signature", "") or ""),
                   hint=S("signature_hint")),
            C.hint_text(S("wiz_excuses_tpl"), tok),
            _tpl_editor(state, page, "late_income_excuses", "tpl_late"),
            _tpl_editor(state, page, "left_soon_excuses", "tpl_soon"),
            _tpl_editor(state, page, "short_absence_excuses", "tpl_short"),
            _tpl_editor(state, page, "long_absence_excuses", "tpl_long"),
        ]
    return [
        C.txt(S("wiz_done_h"), tok, size=19, bold=True),
        C.txt(S("wiz_done_p"), tok, muted=True),
        C.hint_text(S("wiz_done_next"), tok),
    ]


def _continue_test_step(state: AppState, page: ft.Page | None,
                        service: str, step: int,
                        ready_ok: bool, need_key: str) -> bool:
    """Continue handler shared by the tested steps. True if advanced."""
    if not ready_ok:
        if page is not None:
            snack(page, S(need_key))
        return False
    if state.wizard_verified.get(service) == _fp_for(state, service):
        if not _save_for(service, state):
            if page is not None:
                snack(page, S("save_failed"))
            return False
        state.wizard_goto(_step_after(step))
        return True
    if state.testing:
        return False
    _begin_wizard_test(state, page, service, step)
    return False


_TESTED_STEPS = {STEP_BAKALARI: "bakalari", STEP_STRAVA: "strava", STEP_AI: "ai"}


def _test_needed(state: AppState, service: str) -> bool:
    """True when Continue on this step will run a live test first."""
    if service == "strava" and not _strava_enabled(state):
        return False
    if service == "ai" and not _ai_enabled(state):
        return False
    return state.wizard_verified.get(service) != _fp_for(state, service)


def build(state: AppState, page: ft.Page | None) -> ft.Control:
    step = max(0, min(STEP_DONE, int(state.wizard_step)))
    tok = state.tok

    def _next(e):
        if step == STEP_BAKALARI:
            _continue_test_step(state, page, "bakalari", step,
                                _ready_bakalari(state), "wiz_need_bakalari")
            return
        if step == STEP_STRAVA:
            if not _strava_enabled(state):
                if _save_strava(state):
                    state.wizard_goto(_step_after(step))
                elif page is not None:
                    snack(page, S("save_failed"))
                return
            _continue_test_step(state, page, "strava", step,
                                _ready_strava(state), "wiz_need_strava")
            return
        if step == STEP_AI:
            if not _ai_enabled(state):
                if _save_ai(state):
                    state.wizard_goto(_step_after(step))
                elif page is not None:
                    snack(page, S("save_failed"))
                return
            _continue_test_step(state, page, "ai", step,
                                _ready_ai(state), "wiz_need_ai_key")
            return
        if step == STEP_LIMITS:
            updates = _limits_updates(state)
            if updates is None or not state.save(updates):
                if page is not None:
                    snack(page, S("wiz_limits_invalid") if updates is None else S("save_failed"))
                return
        if step == STEP_DISCLAIMER:
            if not _disclaimer_ok(state):
                if page is not None:
                    snack(page, S("wiz_disclaimer_need"))
                return
            if not state.get("disclaimer_accepted", False):
                state.save({"disclaimer_accepted": True})
        if step == STEP_CALENDAR and not _save_calendar(state):
            if page is not None:
                snack(page, S("wiz_cal_pick") if not _cal_preset(state) else S("save_failed"))
            return
        if step == STEP_ALARM and not _save_alarm(state):
            if page is not None:
                snack(page, S("wakeup_minutes_invalid") if _alarm_minutes(state) is None
                      else S("save_failed"))
            return
        if step == STEP_EXCUSES and not _save_signature(state):
            if page is not None:
                snack(page, S("wiz_need_signature") if not _signature(state) else S("save_failed"))
            return
        if step >= STEP_DONE:
            state.wizard_finished()
            try:
                _started = bool(state.start_refresh("all"))
            except Exception:
                _started = False
            if page is not None:
                snack(page, S("wiz_finishing_refresh") if _started else S("already_running"))
        else:
            state.wizard_goto(_step_after(step))

    def _back(e):
        state.wizard_goto(_step_before(step))

    def _skip(e):
        # One step only, nothing of it saved: skipping must never jump
        # past the remaining steps and finish the setup.
        state.wizard_goto(_step_after(step))

    if step == STEP_LIMITS:
        _start_limits_refresh(state)
    testing_now = bool(state.testing) and step in (STEP_BAKALARI, STEP_STRAVA, STEP_AI)
    # The subjects are loading: stay here (inputs elsewhere would lose
    # focus on every progress tick); Skip still leaves the wizard.
    limits_loading = step == STEP_LIMITS and bool(state.refresh_running)
    next_label = S("wiz_next")
    service = _TESTED_STEPS.get(step)
    if service and _test_needed(state, service):
        next_label = S("wiz_test_continue")
    nav: list[ft.Control] = []
    if step > 0 and not limits_loading:
        nav.append(C.ghost_button(S("wiz_back"), tok, on_click=_back))
    nav.append(ft.Container(expand=True))
    if step < STEP_DONE:
        # Welcome has nothing to skip; the disclaimer must be accepted.
        if step not in (STEP_WELCOME, STEP_DISCLAIMER):
            nav.append(C.ghost_button(S("wiz_skip"), tok, on_click=_skip))
        if (step == STEP_CALENDAR and not _cal_preset(state)) or (
                step == STEP_DISCLAIMER and not _disclaimer_ok(state)):
            nav.append(C.primary_button(S("wiz_next"), tok, on_click=_next, disabled=True))
        elif testing_now or limits_loading:
            nav.append(C.primary_button(next_label, tok, on_click=_next, disabled=True))
        else:
            nav.append(C.primary_button(next_label, tok, on_click=_next))
    else:
        nav.append(C.primary_button(S("wiz_finish"), tok, on_click=_next))

    shown = _shown_steps()
    dots = ft.Row(
        [
            C.status_dot(tok, "ok" if i < step else ("working" if i == step else "idle"))
            for i in shown
        ],
        spacing=6, tight=True,
    )
    narrow = C.narrow(state)
    if narrow:
        # Phone: the main button gets its own full-width line, Back and
        # Skip share the one below (all three side by side don't fit).
        primary, rest = nav[-1], [c for c in nav[:-1] if not isinstance(c, ft.Container)]
        primary.expand = True
        nav_row: ft.Control = ft.Column(
            [ft.Row([primary])]
            + ([ft.Row(rest, alignment=ft.MainAxisAlignment.SPACE_BETWEEN)] if rest else []),
            spacing=8, tight=True,
        )
    else:
        nav_row = ft.Row(nav, spacing=8, vertical_alignment=ft.CrossAxisAlignment.CENTER)
    card = C.card(
        C.txt(S("wiz_step_of").format(i=sum(1 for s in shown if s <= step), n=len(shown)), tok,
              size=tok.fs_small, muted=True),
        dots,
        C.divider(tok),
        *_step_content(state, page, step),
        C.divider(tok),
        nav_row,
        tok=tok,
    )
    return ft.Container(
        content=C.scrollable(
            state, f"wizard:{step}",
            # Centered, ~600 px on wide windows, full width on narrow
            # ones (a fixed width overflowed small windows; a bare
            # Column child hugged the left edge on large ones).
            [ft.ResponsiveRow(
                [ft.Container(card, col={"xs": 12, "md": 9, "lg": 7,
                                         "xl": 6, "xxl": 5})],
                alignment=ft.MainAxisAlignment.CENTER,
                spacing=0,
            )],
            alignment=ft.MainAxisAlignment.START,
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            spacing=0, tight=True,
            expand=True,
        ),
        padding=8 if narrow else 24,
        expand=True,
        bgcolor=tok.bg,
    )
