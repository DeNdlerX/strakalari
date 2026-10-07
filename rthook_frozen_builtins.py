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


try:
    if getattr(sys, "frozen", False):
        _point_ssl_at_bundled_ca()
except Exception:
    pass
