"""Design tokens — the single source of truth for the whole UI.

Both themes are first-class citizens: every screen reads colors only from
``tokens()`` for the active mode. Nothing outside this module may contain
a hardcoded color, radius, or spacing value (see ``components.py``).

Scale: 8pt base grid. Type: system font stack, 6 sizes.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Tokens:
    mode: str
    # Surfaces (cards are the brightest layer in both modes)
    bg: str
    surface: str
    card: str
    overlay: str
    border: str
    # Text
    text: str
    muted: str
    faint: str
    # Accent + semantics
    accent: str
    accent_text: str
    green: str
    yellow: str
    red: str
    orange: str
    purple: str
    # Geometry
    radius_sm: int = 8
    radius_md: int = 12
    radius_lg: int = 16
    pad: int = 16          # default card padding
    gap: int = 12          # default spacing between blocks
    rail_width: int = 200
    # Type scale
    fs_title: int = 20
    fs_section: int = 15
    fs_body: int = 13
    fs_small: int = 12
    fs_tiny: int = 11


DARK = Tokens(
    mode="dark",
    bg="#0f1115",
    surface="#16191f",
    card="#1c2027",
    overlay="#2a2f39",
    border="#2e3440",
    text="#e8eaf0",
    muted="#a7adbd",
    faint="#858c9b",
    accent="#7aa5f8",
    accent_text="#0f1115",
    green="#8fd0a0",
    yellow="#e8c87a",
    red="#e88a9b",
    orange="#e8a87a",
    purple="#c4a5f5",
)

LIGHT = Tokens(
    mode="light",
    bg="#eef1f6",
    surface="#f5f7fb",
    card="#ffffff",
    overlay="#e2e8f2",
    border="#c9d2e0",
    text="#131a26",
    muted="#4c5a72",
    faint="#6f7a90",
    accent="#2456d6",
    accent_text="#ffffff",
    green="#177245",
    yellow="#9a6206",
    red="#c2243c",
    orange="#c2540a",
    purple="#6f2fc4",
)


def normalize_mode(mode: str) -> str:
    return "light" if str(mode or "dark").lower() == "light" else "dark"


def tokens(mode: str = "dark") -> Tokens:
    return LIGHT if normalize_mode(mode) == "light" else DARK


def tint(color: str, alpha: float) -> str:
    """``#RRGGBB`` at ``alpha`` opacity as Flet's ``#AARRGGBB``.

    Soft state fills (selected rows, changed lessons, today's row) derive
    from the semantic colors so both themes stay in sync automatically.
    """
    value = str(color or "").lstrip("#")
    if len(value) != 6:
        return color
    a = max(0, min(255, round(float(alpha) * 255)))
    return f"#{a:02x}{value}"


def status_color(status: str, tok: Tokens) -> str:
    """Semantic color for absence/status states."""
    return {
        "ok": tok.green,
        "warning": tok.yellow,
        "critical": tok.red,
        "late": tok.orange,
        "cancelled": tok.muted,
        "pending": tok.yellow,
        "sent": tok.green,
        "failed": tok.red,
    }.get(status, tok.muted)


# -- geometry helpers (Flet 0.86 dataclass API; no .all() shortcuts) --------
def border_all(width: int, color: str):
    import flet as ft

    side = ft.BorderSide(width=width, color=color)
    return ft.Border(left=side, top=side, right=side, bottom=side)


def radius_all(value: int):
    import flet as ft

    return ft.BorderRadius(
        top_left=value, top_right=value, bottom_left=value, bottom_right=value
    )


def pad_all(value: int):
    import flet as ft

    return ft.Padding(left=value, top=value, right=value, bottom=value)


def pad_sym(horizontal: int = 0, vertical: int = 0):
    import flet as ft

    return ft.Padding(left=horizontal, top=vertical, right=horizontal, bottom=vertical)


def align_center():
    import flet as ft

    return ft.Alignment(0, 0)
