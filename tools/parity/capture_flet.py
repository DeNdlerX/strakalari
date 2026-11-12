import os
import subprocess
import sys
import tempfile
import time
import urllib.request
from playwright.sync_api import sync_playwright

#: Keeps the capture hermetic: no OS credential store, no GitHub update check
#: (that is where an "update available" button in the Flet set came from).
_HERMETIC_ENV = {
    "PYTHONIOENCODING": "utf-8",
    "STRAKALARI_NO_KEYRING": "1",
    "DEMO_NO_UPDATE_BANNER": "1",
}

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, ROOT)

from tools.demo_data import generate

SCREENS_WIDE = ["today", "timetable", "absences", "marks", "planner", "lunches", "activity", "settings"]
MORE_ROUTES = ["absences", "planner", "activity", "settings"]
NARROW_TABS = ["today", "timetable", "marks", "lunches", "more"]
MORE_TILES = {
    "absences": 105,
    "planner": 161,
    "activity": 217,
    "settings": 273,
}

def wait_http(url, timeout=30.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(url, timeout=2):
                return
        except OSError:
            time.sleep(0.5)
    raise RuntimeError(f"Server at {url} did not respond within {timeout}s")

def _is_splash(png):
    """True while the page still shows the Flet start-up logo (almost all white)."""
    import io

    from PIL import Image

    small = Image.open(io.BytesIO(png)).convert("RGB").resize((64, 64), Image.NEAREST)
    white = sum(1 for x in range(64) for y in range(64) if small.getpixel((x, y)) == (255, 255, 255))
    return white / 4096 > 0.85


def _screenshot(page, path=None, tries=3):
    """page.screenshot that survives a slow frame (Playwright times out now and then)."""
    for attempt in range(tries):
        try:
            return page.screenshot(path=path) if path else page.screenshot()
        except Exception:
            if attempt == tries - 1:
                raise
            time.sleep(2)


def open_app(page, url, timeout=120.0):
    """Opens the app and waits until it has really rendered.

    A fixed sleep was not enough: the first render sometimes takes far longer
    (CanvasKit start-up), and the capture then saved the logo instead of the
    screen. Fails loudly if the app never appears.
    """
    page.goto(url)
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(1)
        if not _is_splash(_screenshot(page)):
            time.sleep(2)  # let the first frame settle (fonts, icons)
            return
    raise RuntimeError(f"The app at {url} still shows the start-up logo after {timeout:.0f}s")


def capture_wizard(out_dir, lang, theme, port):
    """The first-run wizard: a folder with no credentials (no demo data)."""
    import json

    with tempfile.TemporaryDirectory(prefix=f"flet-wiz-{lang}-{theme}-", ignore_cleanup_errors=True) as tmp_dir:
        with open(os.path.join(tmp_dir, "config.json"), "w", encoding="utf-8") as f:
            json.dump({"theme": theme, "language": lang}, f)
        server = subprocess.Popen(
            [sys.executable, os.path.join(ROOT, "tools", "parity", "serve_wizard.py"), tmp_dir, "--port", str(port)],
            env={**os.environ, **_HERMETIC_ENV},
        )
        try:
            url = f"http://127.0.0.1:{port}"
            wait_http(url)
            with sync_playwright() as p:
                browser = p.chromium.launch(
                    headless=True,
                    args=["--use-gl=swiftshader", "--enable-unsafe-swiftshader"],
                )
                for width, height in [(1280, 800), (390, 844)]:
                    page = browser.new_page(viewport={"width": width, "height": height},
                                            device_scale_factor=1)
                    open_app(page, url)
                    dest = os.path.join(out_dir, f"wizard-{lang}-{theme}-{width}.png")
                    _screenshot(page, dest)
                    print(f"Captured {dest}")
                    page.close()
                browser.close()
        finally:
            try:
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(server.pid)], capture_output=True)
            except Exception:
                server.kill()
            time.sleep(1)


def capture_flet():
    out_dir = os.path.join(ROOT, "build", "parity-screens", "flet")
    os.makedirs(out_dir, exist_ok=True)
    port = 8556

    languages = ["cs", "en"]
    themes = ["dark", "light"]
    viewports = [(1280, 800), (390, 844)]

    for lang in languages:
        for theme in themes:
            with tempfile.TemporaryDirectory(prefix=f"flet-cap-{lang}-{theme}-", ignore_cleanup_errors=True) as tmp_dir:
                generate(tmp_dir, lang=lang, theme=theme, tutorials=False)
                capture_wizard(out_dir, lang, theme, port + 1)
                server = subprocess.Popen(
                    [sys.executable, os.path.join(ROOT, "tools", "demo_data.py"), "serve", tmp_dir, "--port", str(port)],
                    env={**os.environ, **_HERMETIC_ENV},
                )
                try:
                    url = f"http://127.0.0.1:{port}"
                    wait_http(url)
                    with sync_playwright() as p:
                        browser = p.chromium.launch(
                            headless=True,
                            args=["--use-gl=swiftshader", "--enable-unsafe-swiftshader"],
                        )
                        for width, height in viewports:
                            page = browser.new_page(
                                viewport={"width": width, "height": height},
                                device_scale_factor=1,
                            )
                            open_app(page, url)  # CanvasKit / first render

                            def click_nav(screen):
                                if width >= 720:
                                    if screen in SCREENS_WIDE:
                                        idx = SCREENS_WIDE.index(screen)
                                        page.mouse.click(50, 45 + 64 * idx)
                                        time.sleep(1.5)
                                else:
                                    if screen == "more":
                                        page.mouse.click(width * 4.5 / 5, height - 40)
                                        time.sleep(1.5)
                                    elif screen in NARROW_TABS:
                                        idx = NARROW_TABS.index(screen)
                                        page.mouse.click(width * (idx + 0.5) / 5, height - 40)
                                        time.sleep(1.5)
                                    elif screen in MORE_TILES:
                                        page.mouse.click(width * 4.5 / 5, height - 40)
                                        time.sleep(1.0)
                                        page.mouse.click(width / 2, MORE_TILES[screen])
                                        time.sleep(1.5)

                            all_screens = ["today", "timetable", "absences", "marks", "planner", "lunches", "activity", "settings"]
                            if width < 720:
                                all_screens.append("more")

                            for s in all_screens:
                                click_nav(s)
                                dest = os.path.join(out_dir, f"{s}-{lang}-{theme}-{width}.png")
                                _screenshot(page, dest)
                                print(f"Captured {dest}")

                            page.close()
                        browser.close()
                finally:
                    try:
                        subprocess.run(["taskkill", "/F", "/T", "/PID", str(server.pid)], capture_output=True)
                    except Exception:
                        server.kill()
                    time.sleep(1)

if __name__ == "__main__":
    capture_flet()
