"""Keeps the CA bundle that HTTPS certificate checks read present on disk.

On Android (``flet build``) pure-Python packages ship inside zip files,
so ``certifi.where()`` extracts ``cacert.pem`` to a temp file in the
app's cache dir. Flet's launcher points ``SSL_CERT_FILE`` (read by httpx)
and ``REQUESTS_CA_BUNDLE`` at that file, and makes urllib's default
context load it too. Android may empty the cache dir while the app keeps
running (low storage, "Clear cache"; the background service keeps the
process alive for days). Every new HTTPS client then dies in
``ssl.create_default_context`` with a bare ``FileNotFoundError``.

:func:`ensure_ca_bundle` writes the bundle back to the same path before
a connection is opened, which repairs every one of those readers at once.
"""

from __future__ import annotations

import os
import tempfile
import threading

_lock = threading.Lock()


def ensure_ca_bundle(log=None) -> bool:
    """Restores certifi's ``cacert.pem`` when it has vanished. True if restored.

    Only certifi's own copy (the path ``certifi.where()`` handed out) is
    ever written; a user-chosen ``SSL_CERT_FILE`` (a school TLS proxy's CA)
    is left alone. When the file exists this costs one ``stat``. Never
    raises: if the file cannot be restored, the request fails as before.
    """
    say = log or print
    try:
        import certifi

        path = certifi.where()
    except Exception:  # noqa: BLE001 - no certifi: the stdlib store is used
        return False
    if os.path.isfile(path):
        return False
    with _lock:
        if os.path.isfile(path):
            return False  # another thread restored it meanwhile
        try:
            _write_atomically(path, certifi.contents())
        except Exception as exc:  # noqa: BLE001 - keep the original error path
            say(f"Warning: the TLS certificate bundle is missing and could not be "
                f"restored ({type(exc).__name__}: {exc}).")
            return False
    say("Info: the TLS certificate bundle had been deleted (cleared app cache); "
        "restored it.")
    return True


def _write_atomically(path: str, text: str) -> None:
    """Writes ``text`` to ``path`` via a temp file + ``os.replace``, so a
    thread opening ``path`` meanwhile never reads a half-written bundle."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=directory, prefix=".cacert-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="ascii") as f:
            f.write(text)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise
