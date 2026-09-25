"""
Top-level package execution entrypoint (python -m strakalari).

Opens the desktop UI, or the system tray with --minimized.
Routing lives in main.main() — this module only re-exports it, so
`python -m strakalari` and `python main.py` can never diverge, and
importing this module never launches the GUI as a side effect.
"""
from main import main

if __name__ == "__main__":
    main()
