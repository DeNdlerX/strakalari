"""Serves the Flet UI on a data folder WITHOUT skipping the first-run wizard.

`tools/demo_data.py serve` marks the wizard as dismissed (it is made for
screenshots of the finished app). This one is the same server but leaves
`wizard_dismissed` alone, so a folder with no credentials opens the wizard.

    python tools/parity/serve_wizard.py DIR --port 8557
"""
import argparse
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--port", type=int, default=8557)
    args = ap.parse_args()
    os.environ["STRAKALARI_DATA_DIR"] = os.path.abspath(args.dir)
    os.environ["FLET_FORCE_WEB_SERVER"] = "1"
    os.environ.setdefault("STRAKALARI_NO_KEYRING", "1")
    os.chdir(args.dir)
    sys.path.insert(0, ROOT)

    import flet as ft

    from strakalari.core import update
    from strakalari.flet_ui import app
    from strakalari.flet_ui.assets import assets_dir

    update.updates_managed_externally = lambda: True
    ft.app(target=app.main, view=None, port=args.port, assets_dir=str(assets_dir()))


if __name__ == "__main__":
    main()
