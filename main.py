"""
Strakalari - Master Entry Point.

GUI-only: opens the Flet desktop UI, or the system tray
when launched with --minimized (e.g. Windows autostart).
"""

import sys


def _forget_secrets() -> int:
    """``--forget-secrets``: drop the stored password key (uninstaller).

    The key lives in the OS credential store, which the uninstaller cannot
    reach on its own; removing it makes the passwords left in config.json
    undecryptable, which is the point of "remove all user data".
    """
    from strakalari.core.helpers import get_user_data_dir
    from strakalari.core.secret_store import forget_key

    return 0 if forget_key(get_user_data_dir()) else 1


def main():
    args = sys.argv[1:]
    if "--forget-secrets" in args:
        sys.exit(_forget_secrets())
    if "--minimized" in args:
        # Autostart: background service in the system tray.
        from strakalari.flet_ui.tray import run as run_tray
        run_tray()
    else:
        # Default: the Flet UI.
        from strakalari.flet_ui.app import run as run_flet
        run_flet()


if __name__ == "__main__":
    main()
