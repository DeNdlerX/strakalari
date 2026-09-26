"""Flet application shell: sidebar navigation, theming, background scheduler."""

from __future__ import annotations

import time
from datetime import datetime

import flet as ft

from strakalari.core import notify as notify_core
from strakalari.core.scheduler import JobFailed, PeriodicRunner

from . import components as C
from . import tutorial as T
from .macos import embedded_tray_supported, tray_hosts_window
from .overlays import show_error_dialog, snack
from .state import AppState
from .strings import S
from .theme import pad_all
from .views import absences, activity, lunches, marks, planner, settings, timetable, today, wizard

ROUTES = ("today", "timetable", "absences", "marks", "planner", "lunches", "activity", "settings")


def _destinations(pending_lunches: int = 0) -> list[ft.NavigationRailDestination]:
    try:
        n = int(pending_lunches or 0)
    except (TypeError, ValueError):
        n = 0
    lunch_label = S("nav_lunches") + (f" ({n})" if n > 0 else "")
    return [
        ft.NavigationRailDestination(icon=ft.Icons.HOME_OUTLINED, label=S("nav_today")),
        ft.NavigationRailDestination(icon=ft.Icons.CALENDAR_MONTH_OUTLINED, label=S("nav_timetable")),
        ft.NavigationRailDestination(icon=ft.Icons.EVENT_BUSY_OUTLINED, label=S("nav_absences")),
        ft.NavigationRailDestination(icon=ft.Icons.GRADE_OUTLINED, label=S("nav_marks")),
        ft.NavigationRailDestination(icon=ft.Icons.EVENT_NOTE_OUTLINED, label=S("nav_planner")),
        ft.NavigationRailDestination(icon=ft.Icons.RESTAURANT_OUTLINED, label=lunch_label),
        ft.NavigationRailDestination(icon=ft.Icons.HISTORY_OUTLINED, label=S("nav_activity")),
        ft.NavigationRailDestination(icon=ft.Icons.SETTINGS_OUTLINED, label=S("nav_settings")),
    ]


_BUILDERS = {
    "today": today.build,
    "timetable": timetable.build,
    "absences": absences.build,
    "marks": marks.build,
    "planner": planner.build,
    "lunches": lunches.build,
    "activity": activity.build,
    "settings": settings.build,
}


class Shell:
    def __init__(self, page: ft.Page, state: AppState) -> None:
        import os

        self.page = page
        self.state = state
        try:
            state.bind_page(page)
        except Exception:
            pass
        self.runner: PeriodicRunner | None = None
        initial = os.environ.get("STRAKALARI_ROUTE", "today")
        if initial not in ROUTES:
            print(f"Warning: unknown STRAKALARI_ROUTE={initial!r}, falling back to 'today'.")
        self.route = initial if initial in ROUTES else "today"
        self.content = ft.Container(expand=True)
        self.rail = ft.NavigationRail(
            destinations=_destinations(),
            selected_index=ROUTES.index(self.route) if self.route in ROUTES else 0,
            on_change=self._on_nav,
            bgcolor=state.tok.surface,
        )
        self.topbar = ft.Row(spacing=8, tight=True)
        self._wizard_shown = False
        self._in_render = False  # guards report_error() re-entering render()
        self._last_built_route: str | None = None
        state.listen(self.render)
        state.listen_progress(self.render_progress)
        # Quiet settings saves skip the render, so the scheduler interval
        # follows config saves directly instead of the next repaint.
        listen_config = getattr(state, "listen_config", None)
        if callable(listen_config):
            listen_config(self._sync_runner_interval)

    def _sync_runner_interval(self) -> None:
        """Keeps the background interval in sync with settings."""
        if self.runner is None:
            return
        try:
            self.runner.interval_minutes = max(
                1.0, float(self.state.get("check_interval_minutes", 60) or 60)
            )
        except (TypeError, ValueError):
            pass

    def _on_nav(self, e) -> None:
        self.route = ROUTES[int(e.control.selected_index)]
        self.render()

    def on_resize(self, e=None) -> None:
        """Re-lays out width-sensitive screens (the timetable picks full or
        short subject names from the window width, Activity stacks its two
        columns when narrow). Steps of 60 px keep a drag-resize from
        rebuilding the view on every pixel."""
        if self.route not in ("timetable", "activity"):
            return
        try:
            bucket = int(float(self.page.width or 0) // 60)
        except (TypeError, ValueError):
            return
        if bucket == getattr(self, "_width_bucket", None):
            return
        self._width_bucket = bucket
        self.render()

    def go(self, route: str) -> None:
        if route in ROUTES:
            self.route = route
            self.render()

    def _apply_chrome(self) -> None:
        tok = self.state.tok
        self.page.bgcolor = tok.bg
        self.page.theme_mode = (
            ft.ThemeMode.LIGHT if tok.mode == "light" else ft.ThemeMode.DARK
        )
        self.rail.bgcolor = tok.surface
        _apply_locale(self.page)
        try:
            pending = int(getattr(self.state, "pending_lunch_count", 0) or 0)
        except (TypeError, ValueError):
            pending = 0
        self.rail.destinations = _destinations(pending)
        self.rail.selected_index = ROUTES.index(self.route)

    def _status_text(self) -> str:
        state = self.state
        if state.refresh_running:
            return state.current_step or S("refreshing")
        sending = state.sending_label
        if sending:
            return state.current_step or sending
        if state.status == "error" and state.runs:
            return f"{S('status_error')}: {state.runs[-1].get('detail', '')}"
        if state.runs and state.runs[-1].get("ok"):
            return f"{S('status_ok')} · {S('last_run')}: {state.last_run_label}"
        return S("status_idle")

    def _refresh_clicked(self, e) -> None:
        state = self.state
        if state.refresh_running:
            state.cancel_refresh()
            return
        if not state.start_refresh("all"):
            snack(self.page, S("already_running"))
            return
        snack(self.page, S("refresh_started"))

    def _build_topbar(self) -> None:
        state, tok = self.state, self.state.tok
        # The status pill carries the state; its tooltip the full status
        # text and the refresh bookkeeping (updated / next run). It takes
        # the free width and clips a long message (an error detail can run
        # for several lines), so the refresh button always stays visible.
        status_text = self._status_text()
        label = C.txt(status_text, tok, size=tok.fs_small, muted=True)
        label.max_lines = 2
        label.overflow = ft.TextOverflow.ELLIPSIS
        label.expand = True
        status_pill = ft.Container(
            content=ft.Row(
                [C.status_dot(tok, state.status_kind()), label],
                spacing=8,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            ),
            padding=pad_all(8),
            expand=True,
            on_click=lambda e: self.go("activity"),
            tooltip=f"{status_text}\n{S('last_updated')}: {state.updated_label}"
                    f"   ·   {S('next_run')}: {state.next_run_label}",
        )
        if state.refresh_running:
            action = ft.Row(
                [
                    ft.ProgressRing(width=18, height=18, color=tok.accent),
                    C.txt(S("refreshing"), tok, size=tok.fs_small, muted=True),
                    ft.IconButton(
                        ft.Icons.CLOSE, tooltip=S("cancel_refresh"),
                        icon_size=18, on_click=self._refresh_clicked,
                    ),
                ],
                spacing=6,
                tight=True,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            )
        elif state.sending_label:
            # A send can't be cancelled midway (the web form may already
            # be submitted), so unlike a refresh there is no close button.
            action = ft.Row(
                [
                    ft.ProgressRing(width=18, height=18, color=tok.accent),
                    C.txt(state.sending_label, tok, size=tok.fs_small, muted=True),
                ],
                spacing=6,
                tight=True,
                vertical_alignment=ft.CrossAxisAlignment.CENTER,
            )
        else:
            action = T.anchor(state, "refresh", C.primary_button(
                S("refresh_data"), tok,
                on_click=self._refresh_clicked, icon=ft.Icons.REFRESH,
            ))
        controls: list = [T.anchor(state, "status", status_pill)]
        banner = state.update_banner
        if banner is not None:
            latest = str(banner.get("version") or "?")

            def _open_update(e) -> None:
                self.go("activity")

            controls.append(
                C.ghost_button(
                    S("update_available").format(v=latest), tok,
                    on_click=_open_update, icon=ft.Icons.UPGRADE,
                )
            )
        controls.append(action)
        self.topbar.controls = controls

    def refresh_data(self) -> None:
        self._refresh_clicked(None)

    def _maybe_show_error(self) -> None:
        """Pops the queued error dialog (once per failure).

        ``report_error`` only sets a flag — background workers must never
        touch the page directly, so the Shell shows the dialog on the
        next render instead. A failing popup must never break rendering.
        """
        state = self.state
        if not state.error_dialog_pending or not state.last_error:
            return
        try:
            report = state.last_error
            summary = str(report.get("summary", "")) if isinstance(report, dict) else ""
            user_message = str(report.get("user_message", "")) if isinstance(report, dict) else ""
            text = state.error_report_text()
        except Exception:
            return
        # Acknowledge BEFORE showing: a failing show_dialog must not loop.
        state.acknowledge_error()
        if not text:
            return
        try:
            show_error_dialog(self.page, S("error_title"), summary, text,
                              user_message=user_message)
        except Exception:
            pass

    def render(self) -> None:
        # ``report_error`` emits (which re-enters render); without this
        # guard a crashing view would recurse until the stack overflows.
        if self._in_render:
            return
        self._in_render = True
        try:
            self._render_inner()
        finally:
            self._in_render = False
            # Background emits (workers) must push their patch now, not
            # on the next click.
            C.wake_ui(self.page)

    def render_progress(self) -> None:
        """Background worker tick (~1 Hz): repaint only the status bar.

        Used while the user edits settings so half-typed inputs keep
        focus. Everywhere else (or once the refresh is done) it falls
        back to a full render so e.g. the activity log keeps updating
        live. User actions always go through ``render`` (full rebuild),
        so clicks in settings are never swallowed by this fast-path.
        """
        try:
            on_settings = (
                self.state.refresh_running
                and self.route == "settings"
                and self._last_built_route == "settings"
                and bool(self.page.controls)
            )
        except Exception:
            on_settings = False
        if not on_settings:
            self.render()
            return
        self._build_topbar()
        try:
            right = self.page.controls[0].controls[2]
            right.controls[0] = self.topbar
        except (IndexError, AttributeError):
            pass
        try:
            self.page.update()
        except Exception:
            pass
        C.wake_ui(self.page)

    def _restore_scroll(self) -> None:
        # Every view rebuild re-mounts its scrollers at offset 0; push the
        # last user-measured offsets back (no-op without a bound page).
        try:
            C.restore_scroll_offsets(self.state, self.page)
        except Exception:
            pass

    def _render_inner(self) -> None:
        # Fresh installs get the full-screen first-run wizard instead of
        # the normal chrome until it is finished or skipped. Once the
        # wizard is showing, it owns the screen for the whole session:
        # intermediate saves (e.g. Bakalari credentials on step 1) flip
        # needs_setup() to False, but must NOT eject the user to the main
        # chrome before Strava/AI/browser steps are done.
        if not self.state.wizard_dismissed and (
            self._wizard_shown or self.state.needs_setup()
        ):
            self._wizard_shown = True
            self.state.wizard_shown = True
            self._apply_chrome()
            C.begin_render(self.state)
            view = wizard.build(self.state, self.page)
            try:
                self.page.controls.clear()
            except Exception:
                pass
            try:
                self.page.add(ft.Column([view], expand=True, spacing=0))
            except Exception:
                pass
            try:
                self.page.update()
            except Exception:
                pass
            self._restore_scroll()
            self._maybe_show_error()
            return
        if self._wizard_shown:
            # Leaving the wizard: drop its root so the normal chrome
            # re-attaches below instead of patching the wizard column.
            self._wizard_shown = False
            try:
                self.page.controls.clear()
            except Exception:
                pass
        # Views navigate by setting state.pending_route.
        if self.state.pending_route in ROUTES:
            self.route = self.state.pending_route  # type: ignore[assignment]
            self.state.pending_route = None
        elif self.state.pending_route is not None:
            # Drop invalid routes instead of letting them linger forever.
            self.state.pending_route = None
        self._sync_runner_interval()
        # Tutorials: suspend a tour of another screen, offer the intro.
        T.begin(self.state, self.route)
        self._apply_chrome()
        self._build_topbar()
        builder = _BUILDERS[self.route]
        C.begin_render(self.state)
        # No outer scroll: each view owns its scrolling regions (the
        # timetable keeps its header fixed and scrolls only the grid).
        try:
            view = builder(self.state, self.page)
        except Exception as exc:
            # A crashing view must not blank the whole app: record full
            # diagnostics (popup via _maybe_show_error below) and show a
            # fallback card instead.
            try:
                self.state.report_error(f"view ({self.route})", exc)
            except Exception:
                pass
            view = C.card(
                C.txt(S("status_error"), self.state.tok, bold=True),
                tok=self.state.tok,
            )
        body = ft.Column(
            [view],
            expand=True,
        )
        padded = ft.Container(
            content=body,
            padding=pad_all(self.state.tok.pad + 8),
            expand=True,
        )
        # A floating tutorial bubble (if a step wants one) stacks over the
        # content; inline bubbles already sit inside the view.
        bubble = T.layer(self.state)
        self.content.content = (
            padded if bubble is None
            else ft.Stack([padded, bubble], expand=True, fit=ft.StackFit.EXPAND)
        )
        if not self.page.controls:
            self.page.add(
                ft.Row(
                    [
                        self.rail,
                        ft.VerticalDivider(width=1, color=self.state.tok.border),
                        ft.Column(
                            [
                                self.topbar,
                                self.content,
                            ],
                            expand=True,
                            spacing=0,
                        ),
                    ],
                    expand=True,
                    spacing=0,
                    vertical_alignment=ft.CrossAxisAlignment.STRETCH,
                )
            )
        else:
            # Re-attach rebuilt chrome (the topbar is a fresh control).
            try:
                right = self.page.controls[0].controls[2]
                right.controls[0] = self.topbar
            except (IndexError, AttributeError):
                pass
        self._last_built_route = self.route
        try:
            self.page.update()
        except Exception:
            # Window already closed (background emit won): nothing to paint.
            pass
        self._restore_scroll()
        self._maybe_show_error()


# Single-instance guards, held for the whole process lifetime: dropping
# the last reference closes the listener socket and would let a duplicate
# start. _primary_guard covers a standalone UI (MAIN_PORT); _child_guard
# covers a UI child spawned by the tray process (UI_PORT instead — the
# tray parent owns MAIN_PORT and forwards show requests to the child).
_primary_guard = None
_child_guard = None
#: Runner started by main() in this process (if any). Flet may invoke
#: the target again for a new session — the previous scheduler must be
#: stopped first, otherwise every re-entry leaks a refresh loop (each
#: with its own headless browser).
_active_runner = None


def _is_tray_child() -> bool:
    """True inside a UI process spawned by the tray (the tray owns that UI)."""
    import os

    return os.environ.get("STRAKALARI_TRAY_CHILD", "").strip().lower() in (
        "1", "true", "yes", "on",
    )


def _call_on_ui_thread(page: ft.Page, fn, *args) -> None:
    """Runs ``fn`` where ``page.update()`` actually paints.

    pystray menu callbacks and socket listener threads run on raw OS
    threads without Flet's page context, so a direct ``page.update()``
    there silently no-ops. ``page.run_thread`` re-attaches the context.
    """
    run_thread = getattr(page, "run_thread", None)
    if callable(run_thread):
        try:
            run_thread(fn, *args)
            return
        except Exception:
            pass
    try:
        fn(*args)
    except Exception:
        pass


def _invoke_window(page: ft.Page, name: str, *args) -> bool:
    """Calls a ``page.window`` method that may be sync or async.

    Flet made ``destroy``/``close``/``to_front`` coroutines: calling them
    without awaiting silently no-ops (the tray Quit handler then stops the
    icon but the window stays open and the process never exits). Sync
    builds call directly; coroutines are driven on the public
    ``page.loop`` from any thread. Returns True when issued. Never raises.
    """
    try:
        method = getattr(getattr(page, "window", None), name, None)
        if not callable(method):
            return False
        result = method(*args)
    except Exception:
        return False
    try:
        import inspect

        awaitable = inspect.isawaitable(result)
    except Exception:
        awaitable = False
    if not awaitable:
        return True
    try:
        import asyncio

        loop = page.loop
        future = asyncio.run_coroutine_threadsafe(result, loop)
    except Exception:
        try:
            result.close()
        except Exception:
            pass
        return False

    def _swallow(fut) -> None:
        try:
            fut.result()
        except Exception:
            pass

    try:
        future.add_done_callback(_swallow)
    except Exception:
        pass
    return True


def _show_page_window(page: ft.Page) -> None:
    """Restores a hidden/minimized window (same steps as tray Open)."""
    try:
        # minimized=False also covers [-]-to-taskbar: Open must
        # un-minimize, not just un-hide.
        try:
            page.window.minimized = False
        except Exception:
            pass
        page.window.visible = True
        page.window.skip_task_bar = False
        try:
            page.window.focused = True
        except Exception:
            pass
        # Coroutine on current Flet (see _invoke_window); a bare call
        # would silently no-op and never bring the window forward.
        _invoke_window(page, "to_front")
        page.update()
        try:
            page.window.update()
        except Exception:
            pass
    except Exception:
        pass


def _close_page_window(page: ft.Page) -> None:
    """Closes the window for real (past any close-to-tray intercept)."""
    try:
        page.window.prevent_close = False
    except Exception:
        pass
    # destroy()/close() are coroutines on current Flet — a bare call
    # silently no-ops, leaving the window open and this process behind
    # after tray Quit (see _invoke_window).
    if _invoke_window(page, "destroy"):
        return
    _invoke_window(page, "close")


def _release_instance_guards() -> None:
    global _primary_guard, _child_guard
    for guard in (_primary_guard, _child_guard):
        if guard is not None:
            try:
                guard.close()
            except Exception:
                pass
    _primary_guard = None
    _child_guard = None


def _setup_single_instance(page: ft.Page) -> None:
    """Second launch shows this window instead of opening a duplicate.

    The MAIN_PORT guard is claimed in run() before any window exists; the
    show callback is attached here where the page is available. A
    tray-spawned child instead listens on UI_PORT for the tray parent's
    forwards. Never raises (must not break startup).
    """
    global _child_guard
    from .single_instance import UI_PORT, SingleInstance

    if _is_tray_child():
        # Tray Quit asks for a clean close: killing this process would
        # orphan the window on macOS, where Flet launches it through
        # `open` (not our descendant) and ignores SIGTERM.
        guard = SingleInstance(
            UI_PORT, on_quit=lambda: _call_on_ui_thread(page, _close_page_window, page))
        if not guard.acquire():
            # Practically unreachable (the tray never spawns two
            # children); stay usable, just without a show listener.
            print("Warning: another UI child is already running.")
            return
        _child_guard = guard
    else:
        guard = _primary_guard
        if guard is None:
            return  # degraded start (port squatted); nothing to listen on
    guard.on_show = lambda: _call_on_ui_thread(page, _show_page_window, page)
    prev_close = page.on_close

    def _close_with_guard(e) -> None:
        _release_instance_guards()
        if callable(prev_close):
            try:
                prev_close(e)
            except Exception:
                pass

    page.on_close = _close_with_guard


def _startup_seed(state: AppState):
    """Last successful refresh time from the loaded cache (None = unknown).

    Never raises: without positive evidence of fresh data the scheduler
    keeps its old refresh-on-start behavior.
    """
    try:
        from strakalari.core.cache import startup_seed

        return startup_seed(getattr(state, "data", None) or {})
    except Exception:
        return None


#: Longest the scheduled refresh job waits for the refresh it started.
#: Far above a normal run (browser timeouts end those in minutes); past
#: it the job counts as failed and gets the runner's early retry.
_REFRESH_JOB_WAIT_S = 30 * 60


def _register_jobs(state: AppState) -> PeriodicRunner:
    def _on_result(result) -> None:
        # Scheduler heartbeat: track it for the "next run" label.
        state.scheduler_last_run = datetime.now()
        if not result.ok and not getattr(result, "reported", False):
            state.log(S("job_failed_log").format(name=result.name))
            # The cause (last traceback line) belongs in the live log, so a
            # copied log / error report shows why, not just which job.
            cause = str(result.error or "").strip().splitlines()
            if cause:
                state.log(cause[-1][:300])
            try:
                prefs = state.get("notifications", {})
                notify_core.notify("refresh_failed", S("job_failed").format(name=result.name), prefs)
            except Exception:
                pass

    def _refresh_job():
        state.scheduler_last_run = datetime.now()
        if state.setup_pending:
            return "skipped (setup not finished)"
        if state.refresh_running:
            return "skipped (a refresh is already running)"
        if state.demo_mode and not state._has_credentials():
            return "skipped (no credentials configured)"
        before = state.runs[-1] if state.runs else None
        if not state.start_refresh("all"):
            # Another refresh is running: fresh data is on its way.
            return "refresh busy"
        # The refresh runs on the page executor; wait for its outcome so a
        # failed run gets the runner's early retry instead of counting as
        # a success the moment it was started. Bounded, and woken by
        # shutdown: a hung refresh must not freeze the scheduler thread.
        deadline = time.monotonic() + _REFRESH_JOB_WAIT_S
        while state.refresh_running:
            if runner.wait_stopped(1.0):
                return "refresh still running at shutdown"
            if time.monotonic() >= deadline:
                raise RuntimeError(
                    f"refresh still running after {_REFRESH_JOB_WAIT_S // 60} min")
        last = state.runs[-1] if state.runs else None
        if last is not None and last is not before and not last.get("ok"):
            if not last.get("cancelled"):
                # The worker already logged and notified the failure.
                raise JobFailed(str(last.get("detail") or "refresh failed"))
        return "refresh finished"

    runner = PeriodicRunner(
        interval_minutes=float(state.get("check_interval_minutes", 60) or 60),
        on_result=_on_result,
        # Anchor the first auto-run to the last successful refresh; with
        # no or an overdue cache (None) the app refreshes on start.
        last_run=_startup_seed(state),
    )
    if runner._last_run is not None:
        # The "next run" label derives from this; seed it so it is right
        # from launch instead of showing "—" until the first tick.
        state.scheduler_last_run = runner._last_run
    runner.add_job("refresh", _refresh_job)
    return runner


def _is_window_close_event(e) -> bool:
    """True when a Flet window event is the native close (X) request.

    Flet 0.86 delivers a WindowEvent with ``type`` == WindowEventType.CLOSE;
    older code checked ``e.data == \"close\"``. Accept both so the
    minimize-to-tray intercept keeps working across versions.
    """
    try:
        t = getattr(e, "type", None)
        if t is not None:
            name = getattr(t, "value", t)
            if str(name).lower() == "close":
                return True
            if str(t).lower().endswith("close"):
                return True
    except Exception:
        pass
    try:
        if str(getattr(e, "data", "")).lower() == "close":
            return True
    except Exception:
        pass
    return False


def _setup_minimize_to_tray(page: ft.Page, state: AppState, runner: PeriodicRunner):
    """Closes (X) hide the window into a tray icon instead of quitting.

    The "Minimize to tray" setting is read at every close, so toggling it
    in Settings applies at once: on -> X hides the window (the icon starts
    on the first hide if it was not running yet), off -> X quits. Returns
    the pystray Icon, or None when no embedded tray exists here
    (STRAKALARI_NO_TRAY=1 for TrayApp child windows, macOS — the tray
    process hosts the window there, see macos.py — or pystray / the icon
    image unavailable); X then simply quits. The tray menu Quit stops the
    scheduler, stops the icon and destroys the window.
    """
    import os
    import threading

    def _plain_close() -> None:
        page.on_close = lambda e: runner.stop() if runner is not None else None

    if not embedded_tray_supported() or os.environ.get(
            "STRAKALARI_NO_TRAY", "").strip().lower() in ("1", "true", "yes", "on"):
        _plain_close()
        return None
    try:
        import pystray

        from .tray import _icon_image
    except Exception as exc:  # noqa: BLE001 - tray is optional; never break startup
        print(f"Warning: system tray unavailable ({type(exc).__name__}), close will quit.")
        _plain_close()
        return None
    try:
        image = _icon_image()
    except Exception:
        image = None
    if image is None:
        _plain_close()
        return None

    quitting = {"value": False}
    icon_holder: dict = {"running": False}

    def _enabled() -> bool:
        try:
            return bool(state.get("minimize_to_tray", True))
        except Exception:
            return True

    def _ui_thread(fn, *args) -> None:
        _call_on_ui_thread(page, fn, *args)

    def _show_window() -> None:
        _show_page_window(page)

    def _start_icon() -> None:
        if icon_holder.get("running"):
            return
        icon_holder["running"] = True
        try:
            threading.Thread(target=icon_holder["icon"].run, daemon=True).start()
        except Exception:
            icon_holder["running"] = False

    def _hide_window() -> None:
        _start_icon()  # never hide without a way back
        try:
            page.window.skip_task_bar = True
            page.window.visible = False
            page.update()
        except Exception:
            pass

    def _tray_refresh(icon=None, item=None) -> None:
        try:
            state.start_refresh("all")
        except Exception:
            pass

    def _quit(icon=None) -> None:
        quitting["value"] = True
        _release_instance_guards()
        try:
            runner.stop()
        except Exception:
            pass
        ic = icon or icon_holder.get("icon")
        if ic is not None and (icon is not None or icon_holder.get("running")):
            try:
                ic.stop()
            except Exception:
                pass
        # destroy() also talks to the client over the page connection,
        # so it needs the UI thread just like show() does.
        _ui_thread(_close_page_window, page)

    def _quit_from_tray(icon, item=None) -> None:
        _quit(icon)

    def _on_window_event(e) -> None:
        if quitting["value"]:
            return
        if _is_window_close_event(e):
            if _enabled():
                _hide_window()
            else:
                _quit()

    try:
        menu = pystray.Menu(
            pystray.MenuItem(S("tray_open"),
                             lambda icon, item=None: _ui_thread(_show_window), default=True),
            pystray.MenuItem(S("tray_refresh"),
                             lambda icon, item=None: _ui_thread(_tray_refresh)),
            pystray.MenuItem(S("tray_quit"), _quit_from_tray),
        )
        icon = pystray.Icon("Strakalari", image, "Strakaláři", menu)
    except Exception as exc:  # noqa: BLE001 - fall back to plain close
        print(f"Warning: could not create tray icon ({type(exc).__name__}), close will quit.")
        _plain_close()
        return None
    icon_holder["icon"] = icon

    try:
        page.window.prevent_close = True
    except Exception:
        pass
    try:
        page.window.on_event = _on_window_event
    except Exception:
        pass

    def _on_page_close(e) -> None:
        quitting["value"] = True
        _release_instance_guards()
        try:
            runner.stop()
        except Exception:
            pass
        if icon_holder.get("running"):
            try:
                icon.stop()
            except Exception:
                pass

    page.on_close = _on_page_close
    if _enabled():
        _start_icon()
    return icon


def _tolerate_stale_method_results(page: ft.Page) -> None:
    """Keeps the session alive when a method reply targets a removed control.

    Every render rebuilds the view, so a control can leave the page while
    one of its method calls (e.g. ``scroll_to``) is still in flight. Flet
    then raises "Control with ID … is not registered" inside its receive
    loop, the loop exits and the UI stops reacting to input. The reply is
    stale, not fatal: release the waiting call and carry on. Never raises.
    """
    session = getattr(page, "session", None)
    original = getattr(session, "handle_invoke_method_results", None)
    if not callable(original) or getattr(original, "_stale_tolerant", False):
        return

    def _handle(control_id, call_id, result, error):
        try:
            return original(control_id, call_id, result, error)
        except RuntimeError:
            # Name-mangled Session internals (flet is pinned exactly).
            calls = getattr(session, "_Session__method_calls", None)
            results = getattr(session, "_Session__method_call_results", None)
            evt = calls.pop(call_id, None) if isinstance(calls, dict) else None
            if evt is not None and isinstance(results, dict):
                results[evt] = (None, "control was removed from the page")
                evt.set()
            return None

    _handle._stale_tolerant = True  # type: ignore[attr-defined]
    try:
        session.handle_invoke_method_results = _handle
    except Exception:
        pass


def _apply_locale(page: ft.Page) -> None:
    """Pins Flutter's own texts (dialog buttons, tooltips, pickers) to the app language.

    Left unset they follow the OS locale — English on a typical Linux
    install even when the app itself is set to Czech.
    """
    from strakalari.core.i18n import get_language

    lang = get_language()
    current = ft.Locale("en", "US") if lang == "en" else ft.Locale("cs", "CZ")
    cfg = getattr(page, "locale_configuration", None)
    if cfg is not None and getattr(cfg, "current_locale", None) == current:
        return
    try:
        page.locale_configuration = ft.LocaleConfiguration(
            supported_locales=[ft.Locale("cs", "CZ"), ft.Locale("en", "US")],
            current_locale=current,
        )
    except Exception:
        pass


def main(page: ft.Page) -> None:
    global _active_runner

    state = AppState()
    page.title = S("app_title")
    try:
        from .assets import window_icon_path

        icon = window_icon_path()
        if icon:
            page.window.icon = icon
    except Exception:
        pass
    _tolerate_stale_method_results(page)
    page.window.min_width, page.window.min_height = 960, 640
    page.window.width, page.window.height = 1240, 800
    shell = Shell(page, state)
    try:
        page.on_resize = shell.on_resize
    except Exception:
        pass
    shell.render()
    # A re-entered session (Flet may invoke the target again) must not
    # leak the previous scheduler: stop it before starting a new one.
    prev = _active_runner
    _active_runner = None
    if prev is not None:
        try:
            prev.stop()
        except Exception:
            pass
    # A tray-spawned child must not run its own scheduler: the tray
    # parent already refreshes in the background, and a second loop
    # means duplicate browsers, duplicate notifications and refreshes
    # fighting over the cache.
    runner = None if _is_tray_child() else _register_jobs(state)
    shell.runner = runner
    if runner is not None:
        runner.start()
        _active_runner = runner
    # Non-blocking GitHub release check (silent when offline).
    try:
        state.start_update_check()
    except Exception:
        pass
    # X hides into the tray (real quit is tray-menu Quit); without the
    # tray (toggle off / unavailable) X quits as before.
    try:
        _setup_minimize_to_tray(page, state, runner)
    except Exception:
        page.on_close = lambda e: runner.stop() if runner is not None else None
    # A second app launch restores this window instead of starting a
    # duplicate (tray-spawned children listen on their own port instead).
    try:
        _setup_single_instance(page)
    except Exception:
        pass


def run() -> None:
    from .startup import ensure_stdio

    ensure_stdio()

    import argparse

    global _primary_guard

    parser = argparse.ArgumentParser(prog="strakalari.flet_ui")
    parser.add_argument("--view", default="app",
                        choices=["app", "web"],
                        help="'app' opens a desktop window, 'web' serves locally.")
    parser.add_argument("--port", type=int, default=8555,
                        help="Local port for --view web (ignored by the desktop window).")
    parser.add_argument("--minimized", action="store_true",
                        help="Start minimized in the system tray (same as the top-level --minimized).")
    args = parser.parse_args()
    if args.minimized or (
            args.view == "app" and tray_hosts_window() and not _is_tray_child()):
        # Same routing as main.py: autostart/tray path, not the desktop
        # window. On macOS every launch goes here: the tray process owns
        # the main thread (Cocoa) and opens the window as its child.
        from .tray import run as run_tray

        run_tray()
        return
    if not _is_tray_child():
        # A second launch shows the running window instead of opening a
        # duplicate. This runs before any window exists; the show callback
        # is attached later in main(). Tray-spawned children skip this —
        # the tray parent owns MAIN_PORT and forwards to them.
        from .single_instance import MAIN_PORT, ensure_single_primary

        status, guard = ensure_single_primary(MAIN_PORT, mode="show")
        if status == "secondary":
            return
        if guard is not None:
            _primary_guard = guard  # held for the process lifetime
            # NOTE: never sweep same-named processes here. A PyInstaller
            # onefile app is two same-named processes (bootloader parent +
            # payload child): taskkill /IM <own-name> from the child matches
            # the parent, and /T takes the child down with it — the sweep
            # kills this process (instant silent exit 1). Stale instances
            # are stopped by the installer (a different process name).
            # Orphaned viewers / headless browsers carry no such risk and
            # are reaped (a killed run never ran their teardown).
            try:
                from .single_instance import (
                    kill_orphaned_flet_views,
                    kill_orphaned_headless_browsers,
                )

                kill_orphaned_flet_views()
                kill_orphaned_headless_browsers()
            except Exception:
                pass
    try:
        from .assets import assets_dir

        assets = str(assets_dir())
    except Exception:
        assets = "assets"
    if args.view == "web":
        import sys as _sys

        if getattr(_sys, "frozen", False):
            # flet_web is deliberately excluded from the bundle (spec):
            # the web view would crash trying to pip-install it (no pip
            # inside the bundle), so fall back to the desktop window.
            print("Warning: --view web is not available in the frozen build; opening the desktop window.")
        else:
            ft.app(target=main, view=ft.AppView.WEB_BROWSER, port=args.port,
                   assets_dir=assets)
            return
    ft.app(target=main, assets_dir=assets)


if __name__ == "__main__":
    run()
