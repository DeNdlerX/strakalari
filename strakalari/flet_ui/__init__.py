"""Strakalari Flet UI package (the rewritten frontend)."""

__all__ = ["main"]


def __getattr__(name: str):
    if name == "main":
        from .app import main

        return main
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
