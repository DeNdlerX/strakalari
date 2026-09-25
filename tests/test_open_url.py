"""Regression: external links (e.g. 'Získat klíč zdarma') must open a browser.

``Page.launch_url`` is a coroutine in Flet 0.86 — calling it without
``await`` from a sync handler silently discards the coroutine and nothing
opens. All click handlers must therefore go through the awaited
``components.open_url`` helper.
"""

import asyncio
import inspect

from strakalari.flet_ui import components as C


class _FakePage:
    def __init__(self, fail=False):
        self.opened = []
        self.fail = fail

    async def launch_url(self, url):
        if self.fail:
            raise RuntimeError("client cannot open URL")
        self.opened.append(url)


def test_open_url_awaits_launch_url():
    page = _FakePage()
    asyncio.run(C.open_url(page, C.AI_STUDIO_URL))
    assert page.opened == [C.AI_STUDIO_URL]


def test_open_url_falls_back_to_webbrowser(monkeypatch):
    opened = []
    monkeypatch.setattr("webbrowser.open", opened.append)
    asyncio.run(C.open_url(_FakePage(fail=True), C.AI_STUDIO_URL))
    assert opened == [C.AI_STUDIO_URL]


def test_open_url_ignores_empty():
    page = _FakePage()
    asyncio.run(C.open_url(page, ""))
    assert page.opened == []


def test_click_handlers_are_coroutine_functions():
    """Guards the actual bug: a sync handler can never await launch_url."""
    import ast
    import pathlib

    root = pathlib.Path(__file__).resolve().parent.parent / "strakalari" / "flet_ui"
    offenders = []
    for path in (root / "views").glob("*.py"):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith(
                ("_open_key", "_open_releases", "_open")
            ):
                src = ast.get_source_segment(path.read_text(encoding="utf-8"), node) or ""
                if "open_url" in src or "launch_url" in src:
                    if not isinstance(node, ast.AsyncFunctionDef):
                        offenders.append(f"{path.name}:{node.lineno} {node.name}")
    assert not offenders, f"sync URL handlers (never awaited): {offenders}"


def test_helper_itself_is_coroutine():
    assert inspect.iscoroutinefunction(C.open_url)
