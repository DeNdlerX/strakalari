"""Launch ``tools/bakalari_demo_server.py`` pinned to a simulated ``--today YYYY-MM-DD``."""

from __future__ import annotations

import argparse
import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, REPO_ROOT)

from tools import bakalari_demo_server  # noqa: E402
from tools.parity.fake_clock import install_fake_clock  # noqa: E402


def main() -> None:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--today", default=None)
    known, remaining = parser.parse_known_args()
    if known.today:
        install_fake_clock(known.today, ("tools.bakalari_demo_server",))
    sys.argv = [sys.argv[0], *remaining]
    bakalari_demo_server.main()


if __name__ == "__main__":
    main()
