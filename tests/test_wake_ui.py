"""C.wake_ui: off-loop updates must wake Flet's event loop."""

import asyncio
import threading
import time
from types import SimpleNamespace

from strakalari.flet_ui import components as C


def _page(loop):
    return SimpleNamespace(session=SimpleNamespace(connection=SimpleNamespace(loop=loop)))


def test_worker_thread_update_wakes_the_loop():
    loop = asyncio.new_event_loop()
    try:
        # An asyncio.Queue fed from another thread (what Flet's send
        # queue gets from a worker's update()) stays stuck until woken.
        queue: asyncio.Queue = asyncio.Queue()
        got = []
        sent = []

        async def consumer():
            got.append(await queue.get())
            got.append(time.monotonic() - sent[0])

        def worker():
            loop.call_soon_threadsafe(lambda: None)  # let consumer start
            time.sleep(0.1)
            sent.append(time.monotonic())
            queue.put_nowait("patch")
            C.wake_ui(_page(loop))

        threading.Thread(target=worker, daemon=True).start()
        # Without the wake the loop sleeps until its next timer (the
        # 5 s timeout here) — the "only updates after a click" bug.
        loop.run_until_complete(asyncio.wait_for(consumer(), timeout=5))
        assert got[0] == "patch"
        assert got[1] < 1.0
    finally:
        loop.close()


def test_noop_on_loop_thread_and_without_session():
    calls = []

    class _Loop:
        def call_soon_threadsafe(self, fn):
            calls.append(fn)

    C.wake_ui(SimpleNamespace())  # no session: silently ignored
    C.wake_ui(_page(None))

    loop = asyncio.new_event_loop()
    try:
        async def on_loop():
            C.wake_ui(_page(asyncio.get_running_loop()))

        loop.run_until_complete(on_loop())
    finally:
        loop.close()
    assert calls == []

    C.wake_ui(_page(_Loop()))  # worker thread (no running loop): wakes
    assert len(calls) == 1
