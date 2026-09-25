import glob
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
from playwright.sync_api import sync_playwright


def _is_frozen() -> bool:
    return bool(getattr(sys, "frozen", False))


def _is_ephemeral_path(path: str) -> bool:
    """True for PyInstaller onefile extraction dirs (deleted on exit)."""
    if not path:
        return True
    norm = os.path.normcase(os.path.normpath(path))
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass and norm.startswith(os.path.normcase(os.path.normpath(str(meipass)))):
        return True
    # Heuristic for the classic Temp\_MEIxxxxxx layout (en locale, sandbox, …).
    parts = norm.split(os.sep)
    if any(p.startswith("_mei") for p in parts):
        return True
    return False


def default_browsers_path() -> str:
    """Playwright's standard persistent per-user browsers location.

    Mirrors the location the ``playwright install`` CLI uses when
    PLAYWRIGHT_BROWSERS_PATH is unset, so frozen and dev installs share
    one cache instead of re-downloading ~320 MB per layout.
    """
    if sys.platform == "win32":
        base = (
            os.environ.get("LOCALAPPDATA")
            or os.environ.get("APPDATA")
            or os.path.expanduser("~")
        )
        return os.path.normpath(os.path.join(base, "ms-playwright"))
    if sys.platform == "darwin":
        return os.path.normpath(
            os.path.expanduser("~/Library/Caches/ms-playwright")
        )
    cache = os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return os.path.normpath(os.path.join(cache, "ms-playwright"))


def _exe_adjacent_browsers_dir() -> str:
    """Portable candidate next to the frozen exe (e.g. ``<app>/browsers``).

    For PyInstaller onefile ``sys.executable`` is the real exe path, NOT
    the Temp _MEIPASS extraction dir — but guard against both anyway.
    Returns "" when unusable (dev runs, read-only mounts such as an
    AppImage / .app bundle, or anything ephemeral).
    """
    if not _is_frozen():
        return ""
    if sys.platform == "darwin":
        # Inside the .app bundle: an update replaces it (a fresh ~320 MB
        # download each time) and writes break its code-signature seal.
        return ""
    try:
        exe_dir = os.path.normpath(os.path.dirname(sys.executable))
    except Exception:
        return ""
    if not exe_dir or _is_ephemeral_path(exe_dir):
        return ""
    try:
        if not os.access(exe_dir, os.W_OK):
            return ""
    except Exception:
        return ""
    candidate = os.path.join(exe_dir, "browsers")
    if _is_ephemeral_path(candidate):
        return ""
    return candidate


def get_browsers_dir() -> str:
    """Resolve the persistent dir Chromium is installed to / launched from.

    - An explicit PLAYWRIGHT_BROWSERS_PATH (other than "0"/empty) always
      wins — school-lab overrides and power users keep working.
    - Frozen builds default to the exe-adjacent ``browsers/`` dir when it
      is writable (preserves the historic portable-CLI layout and keeps
      GUI installs self-contained), otherwise to the platform
      ``ms-playwright`` cache (AppImage / .app / read-only installs).
    - Dev runs return "" so Playwright keeps its own default.
    """
    env = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
    if env and env.strip() and env.strip() != "0":
        return env
    if not _is_frozen():
        return ""
    portable = _exe_adjacent_browsers_dir()
    if portable:
        # Exe-adjacent dir keeps portable-CLI installs self-contained
        # (historic behavior) and fresh GUI installs together; the
        # read-only-mount case already returned "" above and falls
        # through to the shared cache below.
        return portable
    return default_browsers_path()


def init_browsers_path() -> str:
    """
    Configures Playwright browser storage location.

    Always points frozen builds at a persistent, writable directory.
    This must run before ``sync_playwright().start()``: Playwright's
    driver transport forces ``PLAYWRIGHT_BROWSERS_PATH=0`` (browsers
    inside the driver package) for frozen apps when the variable is
    unset, which resolves to the ephemeral Temp _MEIPASS dir where the
    browsers are never bundled — every launch then dies with
    "Executable doesn't exist at ..._MEI...\\.local-browsers\\...".
    """
    existing = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
    if existing and existing.strip() and existing.strip() != "0":
        return existing

    browsers_dir = get_browsers_dir()
    if browsers_dir and not _is_ephemeral_path(browsers_dir):
        os.environ["PLAYWRIGHT_BROWSERS_PATH"] = browsers_dir
        return browsers_dir

    # Last resort: never leave a frozen app on the "0" fallback.
    fallback = default_browsers_path()
    if _is_frozen() and fallback and not _is_ephemeral_path(fallback):
        os.environ["PLAYWRIGHT_BROWSERS_PATH"] = fallback
        return fallback
    return browsers_dir


# Serializes installs: the wizard's download and a login test's
# BrowserManager (which calls ensure_browser too) must never run two
# ``playwright install`` processes into the same directory at once.
_INSTALL_LOCK = threading.Lock()
# Set while an install runs in this process: Chrome's executable exists
# long before the remaining components (headless shell, ffmpeg) are in.
_INSTALLING = threading.Event()
# Executable path last confirmed complete, so repeat checks skip
# starting the Playwright driver (a node process, ~0.5 s each).
_confirmed_exec: str = ""

_MARKER = "INSTALLATION_COMPLETE"


def _install_complete(exec_path: str) -> bool:
    """True when Chromium and its headless shell carry the install marker.

    Playwright writes ``INSTALLATION_COMPLETE`` into a component's dir
    only after it is fully extracted, so a half-extracted Chrome (or a
    Chrome whose headless shell, used for headless launches, is still
    downloading) does not count as installed.
    """
    if not exec_path or not os.path.exists(exec_path):
        return False
    folder = os.path.dirname(exec_path)
    for _ in range(4):
        name = os.path.basename(folder)
        m = re.fullmatch(r"chromium-(\d+)", name)
        if m:
            if not os.path.exists(os.path.join(folder, _MARKER)):
                return False
            shell = os.path.join(os.path.dirname(folder),
                                 f"chromium_headless_shell-{m.group(1)}")
            return os.path.exists(os.path.join(shell, _MARKER))
        parent = os.path.dirname(folder)
        if parent == folder:
            break
        folder = parent
    # Unknown layout (custom executable, future Playwright): the file
    # existing is the best signal available.
    return True


def is_browser_installed() -> bool:
    """Checks whether the Playwright Chromium browser is installed.

    Path check only, and it must stay that way: this runs on the UI
    thread during view renders, so launching a real browser here costs
    seconds per render and piles up headless Chromes on every
    re-render. Actual launch verification belongs in worker threads
    that own a BrowserManager (which closes what it opens).
    """
    global _confirmed_exec
    if _INSTALLING.is_set():
        return False
    if _confirmed_exec and _install_complete(_confirmed_exec):
        return True
    init_browsers_path()
    try:
        with sync_playwright() as p:
            exec_path = p.chromium.executable_path
    except Exception:
        return False
    if _install_complete(exec_path):
        _confirmed_exec = exec_path
        return True
    return False


def short_component_name(raw: str) -> str:
    """Shortens a Playwright component title for the progress label.

    ``install --dry-run`` uses slightly different titles ("Chrome for
    Testing …"), so matching is substring-based, not positional.
    """
    low = (raw or "").strip().lower()
    if "headless" in low:
        return "Chrome Headless Shell"
    if "chromium" in low or "chrome for testing" in low:
        return "Chrome"
    if "ffmpeg" in low:
        return "FFMPEG"
    if "winldd" in low:
        return "Winldd"
    words = (raw or "").split()
    return (" ".join(words[:3])[:48] or "…")


_PROGRESS_PCT_RE = re.compile(r"(\d{1,3}(?:\.\d+)?)\s*%")


def parse_install_progress(segment: str):
    """Parses one ``playwright install`` output segment.

    Returns ("start", label), ("progress", 0.0-1.0) or ("done", label),
    or None when the segment carries no signal. The CLI redraws its bar
    with carriage returns, so callers must split on ``\
`` as well as
    ``\\n`` before feeding segments here.
    """
    text = (segment or "").strip()
    if not text:
        return None
    low = text.lower()
    if low.startswith("downloading "):
        rest = text[len("Downloading "):]
        rest = re.split(r"\s+from\s+", rest, maxsplit=1)[0]
        return ("start", short_component_name(rest))
    m = re.search(r"(.+?)\s+downloaded to\s+", text, re.IGNORECASE)
    if m:
        return ("done", short_component_name(m.group(1)))
    if "http" in low:
        # A wrapped download URL can contain %XX escapes — not progress.
        return None
    m = _PROGRESS_PCT_RE.search(text)
    if m:
        try:
            return ("progress", max(0.0, min(1.0, float(m.group(1)) / 100.0)))
        except ValueError:
            return None
    return None


def _hidden_process_kwargs() -> dict:
    """Suppresses the popup console window for child processes on Windows.

    The frozen GUI builds with console=False, yet the Playwright driver
    (node cli.js) is a console program — without this, every install pops
    a black terminal window over the app.
    """
    if sys.platform != "win32":
        return {}
    kwargs: dict = {}
    try:
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    except AttributeError:
        kwargs["creationflags"] = 0x08000000
    try:
        startupinfo = subprocess.STARTUPINFO()
        startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startupinfo.wShowWindow = subprocess.SW_HIDE
        kwargs["startupinfo"] = startupinfo
    except Exception:
        pass
    return kwargs


def _install_plan(cmd_prefix: list, env: dict) -> list:
    """Best-effort list of (label, install location) via ``install --dry-run``.

    Cheap and offline (no download). Returns [] when it cannot run, in
    which case callers substitute ``_default_install_plan`` so progress
    still carries an "i of N" total. Locations come from the dry-run's
    ``Install location:`` lines and let the runner skip components whose
    ``INSTALLATION_COMPLETE`` marker already exists, so the counter and
    the overall bar stay accurate on resume/repair runs.
    """
    try:
        proc = subprocess.run(
            [*cmd_prefix, "install", "--dry-run", "chromium"],
            env=env, capture_output=True, text=True, timeout=60,
            encoding="utf-8", errors="replace",
            **_hidden_process_kwargs(),
        )
        if proc.returncode != 0:
            return []
        entries = []
        for block in re.split(r"\n\s*\n", proc.stdout or ""):
            lines = block.strip().splitlines()
            if not lines or not lines[0].strip():
                continue
            label = short_component_name(lines[0].strip())
            location = ""
            for line in lines[1:]:
                m = re.match(r"\s*Install location:\s*(.+?)\s*$", line)
                if m:
                    location = m.group(1)
                    break
            entries.append((label, location))
        return entries
    except Exception:
        return []


def _default_install_plan() -> list:
    """Static fallback for the ``install chromium`` component set.

    Used only when ``install --dry-run`` cannot run (broken driver env
    can fail it even though the real install works). Mirrors what
    current Playwright downloads for ``install chromium``: Chromium,
    FFMPEG and the headless shell on every platform, plus Winldd on
    Windows. Names are already short labels (see
    ``short_component_name``).
    """
    plan = ["Chrome", "FFMPEG", "Chrome Headless Shell"]
    if sys.platform == "win32":
        plan.append("Winldd")
    return plan


def _plan_entries(plan) -> list:
    """Normalizes plan items to (label, location) tuples.

    ``_install_plan`` already returns tuples; the static fallback and
    older callers pass bare label strings (location "").
    """
    entries = []
    for item in plan or ():
        if isinstance(item, (tuple, list)) and len(item) == 2:
            entries.append((str(item[0]), str(item[1] or "")))
        else:
            entries.append((str(item), ""))
    return entries


def _drop_cached_entries(entries: list) -> list:
    """Drops plan entries Playwright would skip as already installed.

    A component whose install dir holds the ``INSTALLATION_COMPLETE``
    marker prints nothing during ``install`` — keeping it in the plan
    would leave the (i/n) counter stranded (e.g. stuck at 2/4) and the
    overall bar short of full. Entries without a known location are
    always kept. Never returns [] for a non-empty plan: when everything
    is cached the install is a fast no-op and the caller still snaps to
    done.
    """
    if not entries or not any(loc for _, loc in entries):
        return entries
    missing = [
        (label, loc) for label, loc in entries
        if not loc
        or not os.path.exists(os.path.join(loc, "INSTALLATION_COMPLETE"))
    ]
    return missing or entries


# Rough download sizes (MiB) per component, used to weight the overall
# bar until the real size shows up in the install output. Equal weights
# made the ~1 MiB FFMPEG file jump the bar by a quarter.
_EST_MIB = {
    "Chrome": 175.0,
    "Chrome Headless Shell": 110.0,
    "FFMPEG": 1.5,
    "Winldd": 0.1,
}
_EST_MIB_DEFAULT = 20.0

_SIZE_MIB_RE = re.compile(r"(\d+(?:\.\d+)?)\s*MiB", re.IGNORECASE)


def parse_download_size(segment: str) -> float | None:
    """Total size in MiB from a progress line, or None.

    Piped (non-TTY) installs print ``|■■■■    |  40% of 167.7 MiB``;
    terminal installs print ``167.7 MiB [====    ] 40% 3.1s``. Both
    carry the file's total size.
    """
    text = segment or ""
    if "http" in text.lower():
        return None
    m = _SIZE_MIB_RE.search(text)
    if not m:
        return None
    try:
        size = float(m.group(1))
    except ValueError:
        return None
    return size if size > 0 else None


def _download_zip_size(since: float) -> int | None:
    """Bytes written so far to Playwright's in-flight download.

    With stdout piped, Playwright reports progress only every 10 %,
    so the bar would stall for many seconds per step. The download
    lands in ``<tmp>/playwright-download-*/<file>.zip``; its growing
    size gives smooth progress. Only dirs touched after ``since`` count,
    so leftovers from earlier runs are ignored. None when not found.
    """
    try:
        pattern = os.path.join(tempfile.gettempdir(), "playwright-download-*")
        newest, newest_t = "", 0.0
        for folder in glob.glob(pattern):
            try:
                t = os.path.getmtime(folder)
            except OSError:
                continue
            if t >= since - 2 and t > newest_t:
                newest, newest_t = folder, t
        if not newest:
            return None
        sizes = []
        for name in os.listdir(newest):
            try:
                sizes.append(os.path.getsize(os.path.join(newest, name)))
            except OSError:
                continue
        return max(sizes) if sizes else None
    except Exception:
        return None


def _run_install(cmd, env, log_callback=None, progress_callback=None,
                 plan=(), timeout=600, phase_callback=None) -> str:
    """Runs ``playwright install`` streaming continuous overall progress.

    No popup window (hidden-process flags). progress_callback(label,
    overall_fraction_or_None, current, total): the fraction runs 0.0 →
    1.0 across the whole install, weighted by download size (estimates
    until the real size is printed), and never moves backwards;
    (current, total) counts actually downloaded files. A repeated
    ``Downloading <same title>`` (Playwright retries one component over
    fallback URLs) keeps the counter. Between Playwright's 10 % steps the
    size of the file being downloaded is polled so the bar moves
    smoothly. phase_callback(phase) receives "download" when a file
    starts and "extract" once its bytes are in (unzipping can take a
    while for Chrome). Raises TimeoutExpired / CalledProcessError on
    failure. A reader thread is used because the bar updates arrive with
    carriage returns and no newlines, so plain line iteration would
    stall; it reads one char at a time so progress dispatches
    immediately instead of hanging until the pipe buffer fills.
    """
    proc = subprocess.Popen(
        cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, bufsize=1, errors="replace", **_hidden_process_kwargs(),
    )
    chunks: queue.Queue = queue.Queue()

    def _reader() -> None:
        try:
            while True:
                data = proc.stdout.read(1)
                if not data:
                    break
                chunks.put(data)
        except Exception:
            pass
        finally:
            chunks.put(None)

    threading.Thread(target=_reader, daemon=True).start()
    entries = _drop_cached_entries(_plan_entries(plan))
    weights = [_EST_MIB.get(lbl, _EST_MIB_DEFAULT) for lbl, _ in entries]
    total = len(entries)
    current = 0
    label = entries[0][0] if entries else ""
    frac = None
    file_frac = 0.0
    file_done = True
    file_started = 0.0
    phase = ""
    tail: list = []

    def _overall() -> float:
        if not current:
            return 0.0
        done_w = sum(weights[:current - 1])
        all_w = sum(weights) or 1.0
        value = (done_w + file_frac * weights[current - 1]) / all_w
        return max(0.0, min(1.0, value))

    def _emit() -> None:
        if not progress_callback:
            return
        try:
            progress_callback(label, frac, current, total)
        except Exception:
            pass

    def _set_phase(new: str) -> None:
        nonlocal phase
        if new == phase:
            return
        phase = new
        if phase_callback:
            try:
                phase_callback(new)
            except Exception:
                pass

    def _advance(new_file_frac: float) -> bool:
        """Moves the bar forward; True when the visible value changed."""
        nonlocal frac, file_frac
        file_frac = max(file_frac, max(0.0, min(1.0, new_file_frac)))
        if file_frac >= 0.999:
            _set_phase("extract")
        value = _overall()
        if frac is not None and value <= frac + 0.0005:
            return False
        frac = value if frac is None else max(frac, value)
        return True

    def _handle(segment: str) -> None:
        nonlocal current, label, frac, total, file_done, file_frac, file_started
        parsed = parse_install_progress(segment)
        if parsed is None:
            return
        kind, payload = parsed
        if kind == "start":
            if file_done or payload != label:
                label = payload
                current += 1
                # The plan is a pre-run estimate: grow the total instead of
                # clamping, so the (i/n) counter never shows (5/4) or stalls
                # when the real install downloads more than predicted.
                if current > total:
                    total = current
                    weights.append(0.0)
                weights[current - 1] = _EST_MIB.get(label, _EST_MIB_DEFAULT)
                file_done = False
                file_frac = 0.0
                if log_callback:
                    if total:
                        log_callback(f"Stahuji ({current}/{total}): {label}…")
                    else:
                        log_callback(f"Stahuji: {label}…")
            # A same-component retry (fallback URL) keeps the counter
            # and the bar; the new attempt catches up from there.
            file_started = time.time()
            _set_phase("download")
            if frac is None:
                frac = _overall()
            _emit()
        elif kind == "progress":
            if current:
                size = parse_download_size(segment)
                if size:
                    weights[current - 1] = size
            _advance(payload)
            _emit()
        elif kind == "done":
            file_done = True
            _advance(1.0)
            _emit()

    def _poll_zip() -> None:
        if file_done or not current or phase != "download":
            return
        size = _download_zip_size(file_started)
        if not size:
            return
        mib = size / (1024 * 1024)
        # Stop just short of the file's end: 100 % comes from the CLI.
        if _advance(min(mib / (weights[current - 1] or 1.0), 0.995)):
            _emit()

    deadline = time.monotonic() + timeout
    buf = ""
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(cmd, timeout)
            try:
                data = chunks.get(timeout=min(0.25, remaining))
            except queue.Empty:
                if proc.poll() is not None:
                    break
                _poll_zip()
                continue
            if data is None:
                break
            buf += data
            # Drain anything else already queued so CR-heavy bursts are
            # handled in one pass instead of one wakeup per char.
            try:
                while True:
                    chunk = chunks.get_nowait()
                    if chunk is None:
                        chunks.put(None)
                        break
                    buf += chunk
            except queue.Empty:
                pass
            *segments, buf = re.split("[" + chr(13) + chr(10) + "]", buf)
            for segment in segments:
                tail.append(segment)
                del tail[:-30]
                _handle(segment)
        if buf.strip():
            tail.append(buf)
            _handle(buf)
        rc = proc.wait(timeout=max(1.0, deadline - time.monotonic()))
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
        raise
    if rc != 0:
        detail = " ".join(t for t in tail if t.strip())[-500:]
        raise subprocess.CalledProcessError(rc, cmd, detail)
    if total:
        current = total
    frac = 1.0
    _emit()
    return "\n".join(tail)


def ensure_browser(log_callback=None, progress_callback=None,
                   phase_callback=None) -> bool:
    """
    Verifies that the Playwright Chromium browser is installed.
    If not present, downloads it to the persistent browsers dir.
    Optional log_callback can receive status messages.
    Optional progress_callback(label, overall_fraction_or_None, current,
    total) receives continuous download progress for in-app progress
    bars: the fraction runs 0.0 → 1.0 across the whole install.
    Optional phase_callback(phase) gets "download" / "extract" per file.
    Concurrent callers wait for one install instead of starting a
    second one. The install runs hidden — no popup terminal on Windows.
    """
    browsers_dir = init_browsers_path()
    if is_browser_installed():
        return True
    with _INSTALL_LOCK:
        # Another thread may have finished the install while we waited.
        if is_browser_installed():
            return True
        _INSTALLING.set()
        try:
            return _install(browsers_dir, log_callback, progress_callback,
                            phase_callback)
        finally:
            _INSTALLING.clear()


def _install(browsers_dir, log_callback, progress_callback,
             phase_callback) -> bool:
    def _log(msg: str):
        if log_callback:
            log_callback(msg)
        else:
            print(msg)

    target_desc = f"into: {browsers_dir}" if browsers_dir else "to default system location"
    _log("\n" + "=" * 62)
    _log("  First-time setup: Strakalari requires Chrome for automation.")
    _log(f"  Downloading Chrome {target_desc}...")
    _log("  (This happens only once)")
    _log("=" * 62 + "\n")

    if browsers_dir:
        try:
            os.makedirs(browsers_dir, exist_ok=True)
        except Exception:
            pass

    def _build_cmd():
        from playwright._impl._driver import compute_driver_executable
        try:
            from playwright._impl._driver import get_driver_env
            driver_env = get_driver_env()
        except ImportError:
            driver_env = os.environ.copy()
        if browsers_dir:
            driver_env["PLAYWRIGHT_BROWSERS_PATH"] = browsers_dir
        result = compute_driver_executable()
        # Playwright changed this API's return shape across versions:
        # older releases returned (driver_executable, env_dict) while
        # current ones return (node_executable, cli_js_path) — two strs.
        # Passing the cli.js path as subprocess env raised
        # "AttributeError: 'str' object has no attribute 'keys'".
        if isinstance(result, (tuple, list)) and len(result) == 2 and isinstance(result[1], dict):
            driver_env.update(result[1])
            cmd = [result[0], "install", "chromium"]
        else:
            node_exe, cli_js = result
            cmd = [node_exe, cli_js, "install", "chromium"]
        return cmd, driver_env

    try:
        cmd, driver_env = _build_cmd()
        # The dry-run probe is best-effort: when it fails, the static
        # fallback keeps the (i/n) file counter working anyway.
        plan = _install_plan(cmd[:-2], driver_env) or _default_install_plan()
        _run_install(cmd, driver_env, log_callback=_log,
                     progress_callback=progress_callback, plan=plan,
                     phase_callback=phase_callback)
        _log("\n[OK] Chrome installed successfully! Starting Strakalari...\n")
        return True
    except Exception as e:
        _log(f"\nNotice: Automatic driver download failed ({e}), attempting fallback...")
        if not getattr(sys, "frozen", False):
            try:
                env = os.environ.copy()
                if browsers_dir:
                    env["PLAYWRIGHT_BROWSERS_PATH"] = browsers_dir
                prefix = [sys.executable, "-m", "playwright"]
                plan = _install_plan(prefix, env) or _default_install_plan()
                _run_install([*prefix, "install", "chromium"], env,
                             log_callback=_log,
                             progress_callback=progress_callback, plan=plan,
                     phase_callback=phase_callback)
                _log("\n[OK] Chrome installed successfully! Starting Strakalari...\n")
                return True
            except Exception as e2:
                err = f"Could not automatically install Chrome: {e2}. Please run manually: playwright install chromium"
                _log(f"\nError: {err}\n")
                raise RuntimeError(err) from e2
        else:
            err = (f"Could not automatically install the Playwright Chromium driver: {e}. "
                   "Reinstall/run: playwright install chromium "
                   "(with PLAYWRIGHT_BROWSERS_PATH pointing at the app's browsers dir).")
            _log(f"\nError: {err}\n")
            raise RuntimeError(err) from e
