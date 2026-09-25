# PyInstaller runtime hook (see strakalari.spec).
#
# Frozen apps don't import `site`, so the `exit()`/`quit()` builtins are
# missing. Flet's pip fallback (flet/utils/pip.py::install_flet_package)
# calls `exit(1)` when it can't install a missing flet-* package, which in
# a frozen app raises `NameError: name 'exit' is not defined` and masks the
# real error. Aliasing to sys.exit restores Flet's intended SystemExit with
# its "Unable to install ..." message.
import builtins
import os
import sys

for _name in ("exit", "quit"):
    if not hasattr(builtins, _name):
        setattr(builtins, _name, sys.exit)


def _bundled_ca_candidates():
    """Possible locations of the bundled certifi CA bundle."""
    candidates = []
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        # PyInstaller one-file layout.
        candidates.append(os.path.join(meipass, "certifi", "cacert.pem"))
    try:
        # PyInstaller one-dir layout (or dev runs).
        candidates.append(os.path.join(
            os.path.dirname(sys.executable), "certifi", "cacert.pem"))
    except Exception:
        pass
    try:
        import certifi
        candidates.append(certifi.where())
    except Exception:
        pass
    return candidates


def _point_ssl_at_bundled_ca():
    """Point TLS verification at the bundled CA store (frozen apps only).

    A frozen exe ships its own OpenSSL but no system CA bundle, so every
    stdlib ``urllib`` HTTPS call (e.g. flet_desktop downloading its client
    on first launch) dies with ``CERTIFICATE_VERIFY_FAILED``. Pointing
    ``SSL_CERT_FILE`` at the bundled certifi ``cacert.pem`` (packed via
    ``collect_all('certifi')`` in the spec) restores verification.

    A user-provided ``SSL_CERT_FILE`` (school MITM proxy setups, etc.) is
    always respected and never overwritten. Never raises.
    """
    try:
        if os.environ.get("SSL_CERT_FILE"):
            return False
        for path in _bundled_ca_candidates():
            try:
                if path and os.path.isfile(path):
                    os.environ["SSL_CERT_FILE"] = path
                    os.environ.setdefault("REQUESTS_CA_BUNDLE", path)
                    return True
            except Exception:
                continue
    except Exception:
        pass
    return False


def _default_browsers_path():
    """Persistent per-user Playwright browsers location (no app imports)."""
    try:
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
    except Exception:
        return ""


def _point_playwright_at_persistent_browsers():
    """Point frozen apps at a persistent Chromium dir (never _MEIPASS).

    Playwright's driver transport forces ``PLAYWRIGHT_BROWSERS_PATH=0``
    (browsers inside the driver package) for frozen apps when the
    variable is unset, which resolves to the ephemeral Temp _MEIPASS
    extraction dir — every launch then dies with "Executable doesn't
    exist at ..._MEI...\\.local-browsers\\...". Setting a persistent
    dir here (before any ``sync_playwright().start()``) disables that
    fallback. Prefers the exe-adjacent ``browsers/`` dir when writable
    (portable installs), else the platform ms-playwright cache
    (AppImage / .app / read-only installs). Respects an explicit
    user-provided value. Never raises.
    """
    try:
        if not getattr(sys, "frozen", False):
            return False
        existing = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
        if existing and existing.strip() and existing.strip() != "0":
            return False
        candidate = ""
        try:
            exe_dir = os.path.normpath(os.path.dirname(sys.executable))
            meipass = getattr(sys, "_MEIPASS", None)
            inside_mei = bool(
                meipass
                and exe_dir.startswith(os.path.normpath(str(meipass)))
            ) or "_MEI" in os.path.normcase(exe_dir).upper()
            # Never inside a macOS .app bundle (see browser.py).
            if (exe_dir and not inside_mei and sys.platform != "darwin"
                    and os.access(exe_dir, os.W_OK)):
                candidate = os.path.join(exe_dir, "browsers")
        except Exception:
            candidate = ""
        if not candidate:
            candidate = _default_browsers_path()
        if candidate and "_MEI" not in os.path.normcase(candidate).upper():
            os.environ["PLAYWRIGHT_BROWSERS_PATH"] = candidate
            try:
                os.makedirs(candidate, exist_ok=True)
            except Exception:
                pass
            return True
    except Exception:
        pass
    return False


try:
    if getattr(sys, "frozen", False):
        _point_ssl_at_bundled_ca()
        _point_playwright_at_persistent_browsers()
except Exception:
    pass
