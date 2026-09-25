"""Guard rails for switching on automatic sending and ordering.

``auto`` submits things under the user's school account without asking,
so turning it on always goes through a warning dialog. It recommends a
dry run first when none was ever recorded in the automation history, and
points at the pause switch.
"""

from __future__ import annotations

from typing import Callable

import flet as ft

from .overlays import close_dialog, show_dialog
from .strings import S

MODE_KEYS = {"excuse_mode": "excuse", "strava_order_mode": "lunch"}


def confirm_auto_mode(
    page: ft.Page,
    mode_key: str,
    on_confirm: Callable[[], None],
    on_dry_run: Callable[[], None],
    on_cancel: Callable[[], None],
) -> ft.AlertDialog:
    """Shows the "turn on automatic mode?" dialog for ``mode_key``.

    Exactly one of the callbacks runs: ``on_confirm`` (keep ``auto``),
    ``on_dry_run`` (switch to ``dry_run`` instead) or ``on_cancel``
    (dialog dismissed — revert the picker).
    """
    kind = MODE_KEYS.get(mode_key, "excuse")
    try:
        from strakalari.core.audit import has_dry_run

        tried = has_dry_run(kind)
    except Exception as exc:  # noqa: BLE001 - recommend the dry run then
        print(f"Warning: could not read the automation history: {exc}")
        tried = False

    done = {"handled": False}

    def _finish(callback: Callable[[], None]) -> Callable:
        def _go(e=None) -> None:
            if done["handled"]:
                return
            done["handled"] = True
            close_dialog(page, dlg)
            callback()
        return _go

    body: list[ft.Control] = [
        ft.Text(S("auto_confirm_excuse" if kind == "excuse" else "auto_confirm_lunch")),
    ]
    if not tried:
        body.append(ft.Text(S("auto_confirm_no_dry_run"), weight=ft.FontWeight.BOLD))
    body.append(ft.Text(S("auto_confirm_pause_hint"), size=12))

    dlg = ft.AlertDialog(
        modal=True,
        title=ft.Text(S("auto_confirm_title")),
        content=ft.Column(body, tight=True, spacing=10, width=440),
        actions=[
            ft.TextButton(S("cancel"), on_click=_finish(on_cancel)),
            ft.TextButton(S("auto_confirm_dry"), on_click=_finish(on_dry_run)),
            ft.Button(S("auto_confirm_ok"), on_click=_finish(on_confirm)),
        ],
    )
    dlg.on_dismiss = _finish(on_cancel)
    show_dialog(page, dlg)
    return dlg
