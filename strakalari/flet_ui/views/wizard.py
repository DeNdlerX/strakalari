"""First-run setup wizard: Chromium, Bakalari login, Strava login, AI key, calendar.

Shown full-screen by the Shell while ``state.needs_setup()`` is true (no
valid Bakalari credentials, not skipped).

Order matters: the Chromium download comes *before* any credentials
because the Bakalari/Strava login tests need a working browser. Each
credential step (Bakalari, Strava, AI key) runs a live test when the
user presses Continue — the wizard only advances on success (staying
put with the error otherwise). Finishing the wizard kicks off the
first data refresh automatically.
"""

from __future__ import annotations

import flet as ft

from .. import components as C
from ..overlays import snack
from ..state import AppState
from ..strings import S

STEPS_TOTAL = 8

STEP_WELCOME = 0
STEP_DISCLAIMER = 1
STEP_BROWSER = 2
STEP_BAKALARI = 3
STEP_STRAVA = 4
STEP_AI = 5
STEP_CALENDAR = 6
STEP_DONE = 7


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


def _browser_ready(state: AppState) -> bool:
    """True once Chrome is fully installed.

    Trusts the wizard's own status while it downloads (Chrome's
    executable exists long before the install finishes) and probes the
    disk at most until it once says yes — the probe starts Playwright's
    driver, far too slow to repeat on every render.
    """
    status = state.wizard_browser_status
    if status in ("done", "ready"):
        return True
    if status == "working" or status.startswith("error:"):
        return False
    try:
        from strakalari.core.browser import is_browser_installed

        ready = bool(is_browser_installed())
    except Exception:
        return False
    if ready:
        state.wizard_browser_status = "ready"
    return ready


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
    if service in ("bakalari", "strava") and not _browser_ready(state):
        if state.wizard_browser_status == "working":
            # Still downloading: stay on this step and run the test the
            # moment Chrome is in (see _browser_finished).
            state.wizard_pending_test = (service, step)
            state._emit()
            return False
        if page is not None:
            snack(page, S("wiz_need_browser_first"))
        state.wizard_goto(STEP_BROWSER)
        return False
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
                state.wizard_goto(step + 1)
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
    if _waiting_for_browser(state, service):
        return [_busy_row(tok, S("wiz_browser_wait_test"))]
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


def _busy_row(tok, text: str) -> ft.Control:
    return ft.Row(
        [ft.ProgressRing(width=14, height=14, stroke_width=2, color=tok.accent),
         C.txt(text, tok, size=tok.fs_small, muted=True)],
        spacing=8, tight=True,
        vertical_alignment=ft.CrossAxisAlignment.CENTER,
    )


def _waiting_for_browser(state: AppState, service: str) -> bool:
    pending = state.wizard_pending_test
    return bool(pending and pending[0] == service
                and state.wizard_browser_status == "working")


# -- Chrome download panel ---------------------------------------------------
#
# The download reports progress several times a second. A full wizard
# re-render per tick replaced every control: indeterminate animations
# restarted, a field being typed into on a later step lost focus, and
# the screen flickered. Instead, the panel's controls are created once
# (kept on the state, reused by every render) and progress ticks update
# them in place; full renders happen only on start / finish.

_DL_KEY = "_wiz_dl"
_DL_MIN_INTERVAL = 0.12  # s between in-place progress pushes


def _dl_widgets(state: AppState) -> dict:
    widgets = state.__dict__.get(_DL_KEY)
    if widgets is None:
        widgets = {
            "title": ft.Text(expand=True),
            "pct": ft.Text(weight=ft.FontWeight.BOLD),
            "bar": ft.ProgressBar(bar_height=6, border_radius=3),
        }
        state.__dict__[_DL_KEY] = widgets
    return widgets


def _dl_texts(state: AppState) -> tuple[str, str, float | None, str]:
    """(title, percent label, bar value or None, tone) for the panel."""
    status = state.wizard_browser_status
    frac = state.wizard_browser_progress
    if status in ("done", "ready"):
        key = "wiz_browser_done" if status == "done" else "wiz_browser_ok"
        return S(key), "", 1.0, "ok"
    if status.startswith("error:"):
        return (S("wiz_browser_failed").format(e=status[6:]), "",
                frac if isinstance(frac, (int, float)) else 0.0, "error")
    label = state.wizard_browser_label
    if not label:
        # Planning the install (dry run) — no numbers yet.
        return S("wiz_browser_preparing"), "", None, "working"
    try:
        cur, total = (int(v) for v in state.wizard_browser_pos)
    except Exception:
        cur, total = 0, 0
    key = ("wiz_browser_extracting" if state.wizard_browser_phase == "extract"
           else "wiz_browser_downloading")
    title = S(key).format(name=label)
    if cur and total:
        title += f" ({cur}/{total})"
    if isinstance(frac, (int, float)):
        value = max(0.0, min(1.0, float(frac)))
        return title, f"{round(value * 100)} %", value, "working"
    return title, "", None, "working"


def _sync_dl(state: AppState) -> dict:
    tok = state.tok
    widgets = _dl_widgets(state)
    title, pct, value, tone = _dl_texts(state)
    color = {"ok": tok.green, "error": tok.red}.get(tone, tok.accent)
    widgets["title"].value = title
    widgets["title"].size = tok.fs_small
    widgets["title"].color = color if tone != "working" else tok.muted
    widgets["pct"].value = pct
    widgets["pct"].size = tok.fs_small
    widgets["pct"].color = tok.text
    widgets["bar"].value = value
    widgets["bar"].color = color
    widgets["bar"].bgcolor = tok.overlay
    return widgets


def _push_dl(state: AppState, force: bool = False) -> None:
    """Updates the mounted download panel in place (no re-render)."""
    import time as _time

    now = _time.monotonic()
    if not force and now - state.__dict__.get("_wiz_dl_t", 0.0) < _DL_MIN_INTERVAL:
        return
    state.__dict__["_wiz_dl_t"] = now
    widgets = _sync_dl(state)
    page = getattr(state, "_page", None)
    if page is None:
        return
    for control in widgets.values():
        # Only when the panel is on screen: a detached control (other
        # step, wizard closed) must not be updated.
        if not C._is_mounted(control, page):
            continue
        try:
            control.update()
        except Exception:
            pass
    # The ticks come from the download worker: wake the event loop or
    # the patches wait for the next click (see C.wake_ui).
    C.wake_ui(page)


def _dl_panel(state: AppState) -> ft.Control:
    from ..theme import pad_all, radius_all

    tok = state.tok
    widgets = _sync_dl(state)
    return ft.Container(
        content=ft.Column(
            [
                ft.Row([widgets["title"], widgets["pct"]], spacing=8,
                       vertical_alignment=ft.CrossAxisAlignment.CENTER),
                widgets["bar"],
            ],
            spacing=8, tight=True,
        ),
        bgcolor=tok.surface,
        border_radius=radius_all(tok.radius_sm),
        padding=pad_all(12),
    )


def _browser_finished(state: AppState) -> None:
    """Download over (either way): run a queued login test or refresh."""
    pending, state.wizard_pending_test = state.wizard_pending_test, None
    ok = state.wizard_browser_status == "done"
    active = not state.wizard_dismissed
    if pending and ok and active and state.wizard_step == pending[1]:
        _begin_wizard_test(state, getattr(state, "_page", None), *pending)
        return
    if active and (state.wizard_step == STEP_BROWSER or pending):
        state._emit()
        return
    # Elsewhere (typing on a later step): just flip the mini panel to
    # done/failed in place; the next render picks up the new status.
    _push_dl(state, force=True)


def _start_browser_install(state: AppState) -> None:
    if state.wizard_browser_status == "working":
        return
    state.wizard_browser_status = "working"
    state.wizard_browser_progress = None
    state.wizard_browser_label = ""
    state.wizard_browser_pos = (0, 0)
    state.wizard_browser_phase = ""
    state._emit()

    def _on_progress(label: str, frac, cur: int, total: int) -> None:
        state.wizard_browser_label = label or ""
        state.wizard_browser_progress = frac
        state.wizard_browser_pos = (cur, total)
        _push_dl(state, force=frac == 1.0)

    def _on_phase(phase: str) -> None:
        state.wizard_browser_phase = phase
        _push_dl(state, force=True)

    def _work() -> None:
        try:
            from strakalari.core.browser import ensure_browser

            ensure_browser(progress_callback=_on_progress, phase_callback=_on_phase)
            state.wizard_browser_status = "done"
            state.wizard_browser_progress = 1.0
        except Exception as exc:  # noqa: BLE001 - surface in wizard
            state.wizard_browser_status = f"error:{str(exc).splitlines()[0][:160] if str(exc) else '?'}"
        _browser_finished(state)

    state._spawn(_work, (), name="strakalari-wizard-browser")


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
    if step == STEP_BROWSER:
        from ..theme import pad_all

        status = state.wizard_browser_status
        out = [
            C.txt(S("wiz_browser_h"), tok, size=19, bold=True),
            C.txt(S("wiz_browser_p"), tok, muted=True),
        ]
        if _browser_ready(state):
            key = "wiz_browser_done" if status == "done" else "wiz_browser_ok"
            out.append(ft.Container(
                ft.Row(
                    [ft.Icon(ft.Icons.CHECK_CIRCLE, color=tok.green, size=20),
                     C.txt(S(key), tok, color=tok.green)],
                    spacing=8, tight=True,
                    vertical_alignment=ft.CrossAxisAlignment.CENTER,
                ),
                padding=pad_all(4),
            ))
        elif status == "working":
            out += [_dl_panel(state), C.hint_text(S("wiz_browser_bg"), tok)]
        elif status.startswith("error:"):
            out += [
                _dl_panel(state),
                C.ghost_button(S("wiz_retry_browser"), tok, icon=ft.Icons.REFRESH,
                               on_click=lambda e: _start_browser_install(state)),
            ]
        else:
            out += [
                C.txt(S("wiz_browser_missing"), tok, muted=True),
                C.ghost_button(S("wiz_install_browser"), tok, icon=ft.Icons.DOWNLOAD,
                               on_click=lambda e: _start_browser_install(state)),
            ]
        return out
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
                width=280,
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
            ft.Row(cards, spacing=8, wrap=True),
        ]
        if not preset:
            rows_cal.append(C.hint_text(S("wiz_cal_pick"), tok))
        return rows_cal
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
        state.wizard_goto(step + 1)
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


def _background_download(state: AppState, step: int) -> list:
    """Download panel on the steps after the browser one.

    The download keeps running while the user fills in the next steps;
    the panel (same in-place-updated controls) shows how far it is.
    """
    status = state.wizard_browser_status
    if step <= STEP_BROWSER or not (status == "working" or status.startswith("error:")):
        return []
    return [_dl_panel(state)]


def build(state: AppState, page: ft.Page | None) -> ft.Control:
    step = max(0, min(7, int(state.wizard_step)))
    tok = state.tok

    # The login tests need Chromium: start its download as soon as the
    # browser step shows, so it is (usually) ready before the user
    # reaches the credential steps. Headless builds (page=None, tests)
    # never auto-start.
    if step == STEP_BROWSER and page is not None:
        if state.wizard_browser_status == "" and not _browser_ready(state):
            _start_browser_install(state)

    def _next(e):
        if step == STEP_BAKALARI:
            _continue_test_step(state, page, "bakalari", step,
                                _ready_bakalari(state), "wiz_need_bakalari")
            return
        if step == STEP_STRAVA:
            if not _strava_enabled(state):
                if _save_strava(state):
                    state.wizard_goto(step + 1)
                elif page is not None:
                    snack(page, S("save_failed"))
                return
            _continue_test_step(state, page, "strava", step,
                                _ready_strava(state), "wiz_need_strava")
            return
        if step == STEP_AI:
            if not _ai_enabled(state):
                if _save_ai(state):
                    state.wizard_goto(step + 1)
                elif page is not None:
                    snack(page, S("save_failed"))
                return
            _continue_test_step(state, page, "ai", step,
                                _ready_ai(state), "wiz_need_ai_key")
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
        if step >= STEP_DONE:
            state.wizard_finished()
            try:
                _started = bool(state.start_refresh("all"))
            except Exception:
                _started = False
            if page is not None:
                snack(page, S("wiz_finishing_refresh") if _started else S("already_running"))
        else:
            state.wizard_goto(step + 1)

    def _back(e):
        state.wizard_goto(step - 1)

    def _skip(e):
        state.dismiss_wizard()

    testing_now = bool(state.testing) and step in (STEP_BAKALARI, STEP_STRAVA, STEP_AI)
    next_label = S("wiz_next")
    service = _TESTED_STEPS.get(step)
    if service and _test_needed(state, service):
        next_label = S("wiz_test_continue")
    pending = state.wizard_pending_test
    if pending and pending[1] == step and _waiting_for_browser(state, pending[0]):
        testing_now = True
    nav: list[ft.Control] = []
    if step > 0:
        nav.append(C.ghost_button(S("wiz_back"), tok, on_click=_back))
    nav.append(ft.Container(expand=True))
    if step < STEP_DONE:
        nav.append(C.ghost_button(S("wiz_skip"), tok, on_click=_skip))
        if (step == STEP_CALENDAR and not _cal_preset(state)) or (
                step == STEP_DISCLAIMER and not _disclaimer_ok(state)):
            nav.append(C.primary_button(S("wiz_next"), tok, on_click=_next, disabled=True))
        elif testing_now:
            nav.append(C.primary_button(next_label, tok, on_click=_next, disabled=True))
        else:
            nav.append(C.primary_button(next_label, tok, on_click=_next))
    else:
        nav.append(C.primary_button(S("wiz_finish"), tok, on_click=_next))

    dots = ft.Row(
        [
            C.status_dot(tok, "ok" if i < step else ("working" if i == step else "idle"))
            for i in range(STEPS_TOTAL)
        ],
        spacing=6, tight=True,
    )
    card = C.card(
        C.txt(S("wiz_step_of").format(i=step + 1, n=STEPS_TOTAL), tok,
              size=tok.fs_small, muted=True),
        dots,
        C.divider(tok),
        *_step_content(state, page, step),
        *_background_download(state, step),
        C.divider(tok),
        ft.Row(nav, spacing=8, vertical_alignment=ft.CrossAxisAlignment.CENTER),
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
            )],
            alignment=ft.MainAxisAlignment.START,
            horizontal_alignment=ft.CrossAxisAlignment.CENTER,
            spacing=0, tight=True,
            expand=True,
        ),
        padding=24,
        expand=True,
        bgcolor=tok.bg,
    )
