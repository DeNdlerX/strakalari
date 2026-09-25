"""Overlay helpers (dialogs + snackbars) for Flet 0.86+ API."""

from __future__ import annotations

import inspect
from typing import Callable

import flet as ft

from .theme import border_all, pad_all, radius_all


def show_dialog(page: ft.Page, dialog: ft.AlertDialog) -> None:
    page.show_dialog(dialog)


def close_dialog(page: ft.Page, dialog: ft.AlertDialog | None = None) -> None:
    """Closes the topmost dialog and repaints.

    ``page.pop_dialog()`` returns None (no exception) when nothing is open,
    so a None return must NOT count as closed. Always flush an update:
    ``pop_dialog`` only nudges the dialog itself, which alone does not
    reliably repaint the modal away — the unconditional ``page.update()``
    is what actually dismisses it.
    """
    popped = None
    try:
        popped = page.pop_dialog()
    except Exception:
        popped = None
    try:
        if dialog is not None:
            dialog.open = False
            if popped is None or popped is not dialog:
                dialog.update()
    except Exception:
        pass
    try:
        page.update()
    except Exception:
        pass


def snack(
    page: ft.Page,
    text: str,
    action_label: str | None = None,
    on_action: Callable | None = None,
) -> None:
    # NOTE: the callback lives ONLY on the action button. Flet fires both
    # SnackBarAction.on_click and SnackBar.on_action on an action tap, so
    # registering the same callback twice would run it twice (e.g. a future
    # Undo popping two entries).
    bar = ft.SnackBar(
        ft.Text(text),
        action=ft.SnackBarAction(action_label, on_click=on_action) if action_label else None,
    )
    try:
        # Drop stale snackbars so the overlay doesn't grow on every refresh.
        page.overlay[:] = [c for c in page.overlay if not isinstance(c, ft.SnackBar)]
        page.overlay.append(bar)
        bar.open = True
        page.update()
    except Exception:
        pass


def _clipboard_service(page: ft.Page) -> ft.Clipboard:
    """Returns the ``ft.Clipboard`` service for ``page``.

    ``ft.Clipboard`` is a *service*, not a visual control: constructing it
    inside an event handler auto-registers it with the page's service
    registry. It must never be appended to ``page.overlay`` — the overlay
    is the visual control tree, and mounting a service there makes the
    client fail with "Unknown control: Clipboard".
    """
    for control in list(getattr(page, "overlay", []) or []):
        if isinstance(control, ft.Clipboard):
            return control
    registry = getattr(page, "_services", None)
    for svc in list(getattr(registry, "_services", []) or []):
        if isinstance(svc, ft.Clipboard):
            return svc
    return ft.Clipboard()


def copy_text(page: ft.Page, text: str) -> bool:
    """Copies ``text`` to the OS clipboard. Returns True if dispatched.

    ``ft.Clipboard.set`` is a coroutine, but UI event handlers in this
    codebase are sync — so the write is dispatched via ``page.run_task``
    (the supported sync -> async bridge). A legacy sync
    ``page.set_clipboard`` is still honored as a fallback.
    """
    payload = str(text or "")
    if not payload:
        return False
    try:
        service = _clipboard_service(page)
    except Exception:
        service = None
    if service is not None:
        run_task = getattr(page, "run_task", None)
        if callable(run_task):
            try:
                async def _write() -> None:
                    await service.set(payload)

                run_task(_write)
                return True
            except Exception:
                return False
        # No task runner (headless/test doubles): drive the coroutine
        # directly when no event loop is already running.
        try:
            import asyncio

            try:
                asyncio.get_running_loop()
            except RuntimeError:
                asyncio.run(service.set(payload))
                return True
        except Exception:
            pass
        return False
    legacy = getattr(page, "set_clipboard", None)
    if callable(legacy):
        try:
            result = legacy(payload)
            if inspect.isawaitable(result):
                import asyncio

                try:
                    asyncio.get_running_loop()
                except RuntimeError:
                    asyncio.run(result)
            return True
        except Exception:
            return False
    return False


def show_error_dialog(
    page: ft.Page,
    title: str,
    summary: str,
    report_text: str,
    on_close: Callable | None = None,
    user_message: str = "",
) -> ft.AlertDialog:
    """Error popup with a copy-logs button.

    ``summary`` is the one-line cause; ``report_text`` is the full
    diagnostics bundle (also selectable in the dialog for manual copy).
    When ``user_message`` is set the failure is user-fixable: the dialog
    shows the friendly fix-it text instead of the traceback dump, with the
    full bundle one copy-tap away behind a secondary line.
    Never raises — a failing popup must not hide the error behind it.
    """
    from .strings import S

    body_text = str(report_text or "").strip() or "(no details captured)"
    copy_btn = ft.Button(S("error_copy_logs"), icon=ft.Icons.CONTENT_COPY)

    def _dismiss(e) -> None:
        close_dialog(page, dlg)
        try:
            page.update()
        except Exception:
            pass
        if callable(on_close):
            try:
                on_close()
            except Exception:
                pass

    def _copy(e) -> None:
        if copy_text(page, str(report_text or "")):
            # ft.Button has no .text (label lives in .content) — replace
            # the content so the confirmation is actually visible.
            try:
                copy_btn.content = ft.Text(S("error_copied"))
            except Exception:
                pass
            snack(page, S("error_copied"))
        else:
            snack(page, S("error_copy_failed"))
        try:
            page.update()
        except Exception:
            pass

    copy_btn.on_click = _copy
    friendly = str(user_message or "").strip()
    if friendly:
        # User-fixable failure: friendly fix-it text plus the secondary
        # "not your fault?" copy line — no traceback dump on screen.
        # (The copy button still copies the full diagnostics bundle.)
        message_controls: list = [
            ft.Text(friendly, selectable=True),
            ft.Text(
                S("error_not_yours"),
                size=12,
                color=ft.Colors.GREY_500,
                selectable=True,
            ),
        ]
    else:
        message_controls = [
            ft.Text(str(summary or ""), selectable=True),
            ft.Text(
                S("error_hint"),
                size=12,
                color=ft.Colors.GREY_500,
                selectable=True,
            ),
            ft.Container(
                content=ft.Column(
                    [
                        ft.Text(
                            body_text,
                            selectable=True,
                            font_family="Consolas",
                            size=12,
                        )
                    ],
                    scroll=ft.ScrollMode.AUTO,
                    tight=True,
                ),
                height=220,
                border=border_all(1, ft.Colors.GREY_400),
                border_radius=radius_all(8),
                padding=pad_all(8),
            ),
        ]
    dlg = ft.AlertDialog(
        modal=True,
        title=ft.Row(
            [
                ft.Icon(ft.Icons.ERROR_OUTLINE),
                ft.Text(str(title or S("error_title"))),
            ],
            spacing=8,
            tight=True,
            vertical_alignment=ft.CrossAxisAlignment.CENTER,
        ),
        content=ft.Container(
            content=ft.Column(
                message_controls,
                spacing=8,
                tight=True,
            ),
            width=560,
        ),
        actions=[
            ft.TextButton(S("error_close"), on_click=_dismiss),
            copy_btn,
        ],
    )
    try:
        show_dialog(page, dlg)
    except Exception:
        pass
    return dlg
