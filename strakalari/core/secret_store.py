"""Where the Fernet key that encrypts stored passwords lives.

Preferred: the OS credential store via ``keyring`` (Windows Credential
Manager, macOS Keychain, Secret Service on Linux). The key then never
sits next to ``config.json``, so copying the app folder does not copy
the means to decrypt the passwords in it.

Fallback: ``secret.key`` in the data dir (the old behaviour) — used
when no usable credential store exists (headless Linux, a stripped
build) or when ``STRAKALARI_NO_KEYRING`` is set. An existing
``secret.key`` is moved into the store on first use and the file is
deleted once the store returns the same key.

The store entry is bound to the data dir path, so separate installs
(portable + installed) keep separate keys. Moving the data folder
therefore means re-entering the passwords once — the same outcome as
copying it to another machine, which is the point.
"""

from __future__ import annotations

import hashlib
import os
import threading

SERVICE = "Strakalari"
KEY_FILE = "secret.key"

_CACHE: dict[str, bytes] = {}
_LOCK = threading.Lock()


class KeyStoreUnavailable(OSError):
    """The credential store exists but refused to answer (e.g. locked).

    Raised instead of silently generating a new key, which would make
    every stored password undecryptable once the store is back.
    """


def _entry_name(data_dir: str) -> str:
    digest = hashlib.sha256(os.path.normcase(os.path.abspath(data_dir)).encode("utf-8"))
    return f"fernet-key:{digest.hexdigest()[:16]}"


def _keyring():
    """The usable keyring module, or None when there is no real backend."""
    if os.environ.get("STRAKALARI_NO_KEYRING", "").strip() not in ("", "0"):
        return None
    try:
        import keyring
        from keyring.backends import fail

        backend = keyring.get_keyring()
    except Exception as exc:  # noqa: BLE001 - no store: file fallback
        print(f"Info: OS credential store unavailable ({type(exc).__name__}), using {KEY_FILE}.")
        return None
    if isinstance(backend, fail.Keyring):
        return None
    try:
        # null.Keyring (-1), fail.Keyring (0) and a chainer without any
        # viable backend all store nothing.
        if float(getattr(backend, "priority", 1)) <= 0:
            return None
    except Exception:  # noqa: BLE001 - priority is informational only
        pass
    return keyring


def _read_file(path: str) -> bytes | None:
    try:
        with open(path, "rb") as f:
            key = f.read().strip()
        return key or None
    except FileNotFoundError:
        return None


def _write_file(path: str, key: bytes) -> None:
    tmp_path = f"{path}.tmp-{os.getpid()}"
    try:
        with open(tmp_path, "wb") as f:
            f.write(key)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    finally:
        try:
            if os.path.exists(tmp_path):
                os.remove(tmp_path)
        except OSError:
            pass
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass  # Windows ACLs: the data dir is per user anyway


def _remove_file(path: str) -> None:
    """Deletes the key file after overwriting it (best effort)."""
    try:
        size = os.path.getsize(path)
        with open(path, "r+b") as f:
            f.write(b"\0" * size)
            f.flush()
            os.fsync(f.fileno())
    except OSError:
        pass
    try:
        os.remove(path)
    except OSError as exc:
        print(f"Warning: could not delete {path!r} after moving the key to the "
              f"credential store: {exc}")


def _valid(key: bytes | None) -> bool:
    if not key:
        return False
    try:
        from cryptography.fernet import Fernet

        Fernet(key)
        return True
    except Exception:  # noqa: BLE001 - any failure = not a usable key
        return False


def _from_store(kr, name: str) -> bytes | None:
    try:
        value = kr.get_password(SERVICE, name)
    except Exception as exc:  # noqa: BLE001 - classified below
        from keyring import errors

        if isinstance(exc, (errors.NoKeyringError, errors.InitError)):
            return None
        raise KeyStoreUnavailable(
            f"The OS credential store did not answer ({type(exc).__name__}: {exc}).") from exc
    return value.encode("ascii") if value else None


def _to_store(kr, name: str, key: bytes) -> bool:
    """Stores and reads back ``key``. True only when the round trip holds."""
    try:
        kr.set_password(SERVICE, name, key.decode("ascii"))
        return kr.get_password(SERVICE, name) == key.decode("ascii")
    except Exception as exc:  # noqa: BLE001 - keep using the file then
        print(f"Warning: could not save the key to the OS credential store "
              f"({type(exc).__name__}: {exc}); keeping {KEY_FILE}.")
        return False


def get_key(data_dir: str) -> bytes:
    """The Fernet key for ``data_dir`` (created on first use)."""
    from cryptography.fernet import Fernet

    with _LOCK:
        cached = _CACHE.get(data_dir)
        if cached:
            return cached
        from .helpers import InterProcessLock

        # The tray and the window may both start on a fresh install:
        # without the lock each could create (and store) its own key.
        lock = InterProcessLock(os.path.join(data_dir, KEY_FILE + ".lock"))
        locked = lock.acquire(timeout_s=10.0)
        try:
            key = _load_or_create(data_dir, Fernet)
        finally:
            if locked:
                lock.release()
        _CACHE[data_dir] = key
        return key


def _load_or_create(data_dir: str, fernet_cls) -> bytes:
    path = os.path.join(data_dir, KEY_FILE)
    file_key = _read_file(path)
    if file_key is not None and not _valid(file_key):
        # Empty/corrupt (crash during write): keep the bytes for debugging.
        from .helpers import quarantine_corrupt_file

        quarantine_corrupt_file(path)
        file_key = None

    kr = _keyring()
    if kr is None:
        if file_key is None:
            file_key = fernet_cls.generate_key()
            _write_file(path, file_key)
        return file_key

    name = _entry_name(data_dir)
    try:
        stored = _from_store(kr, name)
    except KeyStoreUnavailable:
        if file_key is not None:
            return file_key  # not migrated yet: the file is the truth
        raise
    if stored is not None and _valid(stored):
        if file_key is not None:
            if file_key == stored:
                _remove_file(path)  # leftover of an interrupted migration
            else:
                # Two different keys: the file one encrypted whatever is
                # in config.json now (e.g. restored from a backup). Never
                # guess — keep using the file, leave the store alone.
                print(f"Warning: {KEY_FILE} differs from the key in the OS credential "
                      "store; using the file.")
                return file_key
        return stored

    key = file_key or fernet_cls.generate_key()
    if _to_store(kr, name, key):
        if file_key is not None:
            _remove_file(path)
        return key
    if file_key is None:
        _write_file(path, key)
    return key


def carry_key(old_dir: str, new_dir: str) -> bool:
    """Gives ``new_dir`` the key of ``old_dir`` (the data dir moved).

    The store entry is bound to the dir path, so moved data would
    otherwise be undecryptable under the new path. Only for a ``new_dir``
    without its own config: whatever key it has is replaced. The old
    entry stays (the old location may still be used). True when done or
    when ``old_dir`` has no key at all; False when its key exists but
    could not be read or saved (e.g. a locked store). Never raises.
    """
    dest = os.path.join(new_dir, KEY_FILE)
    try:
        key = _read_file(os.path.join(old_dir, KEY_FILE))
        kr = _keyring()
        if not _valid(key):
            key = _from_store(kr, _entry_name(old_dir)) if kr is not None else None
        if not _valid(key):
            return True  # no key: nothing was encrypted
        if kr is not None and _to_store(kr, _entry_name(new_dir), key):
            if os.path.exists(dest):
                _remove_file(dest)  # a stale key would shadow the carried one
        else:
            _write_file(dest, key)
    except OSError as exc:  # includes KeyStoreUnavailable
        print(f"Warning: could not carry the password key to {new_dir!r}: {exc}")
        return False
    with _LOCK:
        _CACHE.pop(new_dir, None)
    return True


def forget_key(data_dir: str) -> bool:
    """Deletes ``data_dir``'s key from the OS credential store and disk.

    Used by the uninstaller's "remove all user data": without it the key
    would stay in Windows Credential Manager forever. True when nothing
    is left behind. Never raises.
    """
    ok = True
    kr = _keyring()
    if kr is not None:
        try:
            kr.delete_password(SERVICE, _entry_name(data_dir))
        except Exception as exc:  # noqa: BLE001 - classified below
            try:
                from keyring import errors

                if not isinstance(exc, errors.PasswordDeleteError):
                    ok = False
            except Exception:
                ok = False
    path = os.path.join(data_dir, KEY_FILE)
    if os.path.exists(path):
        _remove_file(path)
        ok = ok and not os.path.exists(path)
    with _LOCK:
        _CACHE.pop(data_dir, None)
    return ok


def storage_location(data_dir: str) -> str:
    """``"keyring"`` or ``"file"`` — where the key currently lives (for diagnostics)."""
    if os.path.exists(os.path.join(data_dir, KEY_FILE)):
        return "file"
    return "keyring" if _keyring() is not None else "file"


def clear_cache() -> None:
    with _LOCK:
        _CACHE.clear()
