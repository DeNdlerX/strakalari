import os
import re
import base64
from datetime import datetime
import sys

try:
    from cryptography.fernet import Fernet, InvalidToken
except ImportError:
    Fernet = None
    InvalidToken = Exception

def _install_dir() -> str:
    """Repository root, or the executable's directory when frozen (PyInstaller)."""
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


# Root directory of the repository/project (or directory of executable if frozen with PyInstaller)
PROJECT_ROOT = _install_dir()

# Legacy XOR key: only ever used to read passwords stored by old versions.
legacy_encryption_key = "4f88a3b32e010dd296cb6aa3b3c"


def get_user_data_dir() -> str:
    """Returns a writable user data directory depending on platform and installation mode.

    ``STRAKALARI_DATA_DIR`` overrides everything (tests, portable setups).
    """
    override = os.environ.get("STRAKALARI_DATA_DIR", "").strip()
    if override:
        os.makedirs(override, exist_ok=True)
        return override
    frozen = getattr(sys, "frozen", False)
    if frozen and sys.platform == "darwin":
        return _macos_app_data_dir()
    # If running from source or portable directory is writable, keep local
    root = _install_dir()
    if not frozen or os.access(root, os.W_OK):
        return root
    return _platform_data_dir()


def _platform_data_dir() -> str:
    """The per-user data dir of an installed (frozen) app, created."""
    if sys.platform == "win32":
        app_data = os.environ.get("LOCALAPPDATA") or os.environ.get("APPDATA") or os.path.expanduser("~")
        data_dir = os.path.join(app_data, "Strakalari")
    elif sys.platform == "darwin":
        data_dir = os.path.expanduser("~/Library/Application Support/Strakalari")
    else:
        # Linux / Unix XDG base directory
        xdg_config = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
        data_dir = os.path.join(xdg_config, "strakalari")

    os.makedirs(data_dir, exist_ok=True)
    return data_dir


#: Resolved macOS data dir per (bundle dir, target dir), fixed for the
#: process lifetime: every caller must agree on one location.
_MACOS_DATA_DIRS: dict[tuple[str, str], str] = {}

#: User files older builds wrote next to the executable, inside the .app
#: bundle. config.json is not listed: it is copied last and marks a
#: finished move. secret.key is carried by secret_store.carry_key.
_BUNDLE_DATA_ITEMS = (
    "config.json.bak",
    "data_cache.json",
    "already_excused_lessons.json",
    "already_excused_lessons.unconfirmed.json",
    "strava_blacklist.json",
    "automation_history.jsonl",
    "update_cache.json",
    "log.txt",
    "school_presets",
)


def _macos_app_data_dir() -> str:
    """~/Library/Application Support/Strakalari for the frozen macOS app.

    Never the bundle: an admin-installed .app is writable, but updating
    it (replacing the bundle) would wipe everything in it, and writes
    there break its code-signature seal. Data an older build left in the
    bundle is copied over once. If that copy cannot finish, this run keeps
    using the bundle, and the next launch tries again.
    """
    bundle = _install_dir()
    target = _platform_data_dir()
    cache_key = (bundle, target)
    cached = _MACOS_DATA_DIRS.get(cache_key)
    if cached is not None:
        return cached
    chosen = target
    if _needs_bundle_migration(bundle, target) and not _migrate_bundle_data(bundle, target):
        print(f"Warning: could not move the data out of the app bundle ({bundle}); "
              "using it for now, retrying on the next launch.")
        chosen = bundle
    _MACOS_DATA_DIRS[cache_key] = chosen
    return chosen


def _needs_bundle_migration(bundle: str, target: str) -> bool:
    if os.path.normcase(os.path.abspath(bundle)) == os.path.normcase(os.path.abspath(target)):
        return False
    return (os.path.isfile(os.path.join(bundle, "config.json"))
            and not os.path.exists(os.path.join(target, "config.json")))


def _bundle_data_items(bundle: str) -> list[str]:
    """Relative names to copy: the defaults plus relative paths config.json points at."""
    import json

    items = list(_BUNDLE_DATA_ITEMS)
    try:
        with open(os.path.join(bundle, "config.json"), encoding="utf-8") as f:
            cfg = json.load(f)
    except (OSError, ValueError):
        cfg = {}
    if isinstance(cfg, dict):
        for key in ("strava_blacklist", "already_excused_file", "log_file"):
            value = cfg.get(key)
            if not isinstance(value, str) or not value.strip() or os.path.isabs(value):
                continue
            rel = os.path.normpath(value)
            if rel.startswith(os.pardir) or rel in items:
                continue  # outside the bundle dir, or already listed
            items.append(rel)
    return items


def _copy_missing(src: str, dst: str) -> None:
    """Copies ``src`` (file or dir) to ``dst`` unless ``dst`` exists; atomic rename."""
    import shutil

    if not os.path.exists(src) or os.path.exists(dst):
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = f"{dst}.migrating-{os.getpid()}"
    try:
        if os.path.isdir(src):
            shutil.copytree(src, tmp)
        else:
            shutil.copy2(src, tmp)
        os.replace(tmp, dst)
    finally:
        if os.path.isdir(tmp):
            shutil.rmtree(tmp, ignore_errors=True)
        elif os.path.exists(tmp):
            os.remove(tmp)


def _migrate_bundle_data(bundle: str, target: str) -> bool:
    """Copies the user data from ``bundle`` to ``target``. True when done.

    The bundle copy is left in place (an older build still reads it).
    Never raises: a failure returns False and nothing is marked done.
    """
    from .secret_store import carry_key

    lock = InterProcessLock(os.path.join(target, "migrate.lock"))
    # The tray and the window can start together: one of them copies.
    if not lock.acquire(timeout_s=30.0):
        return False
    try:
        if not _needs_bundle_migration(bundle, target):
            return True  # the other process finished it
        for rel in _bundle_data_items(bundle):
            _copy_missing(os.path.join(bundle, rel), os.path.join(target, rel))
        # The store entry is bound to the dir path: without the old key
        # the moved passwords could not be decrypted.
        if not carry_key(bundle, target):
            return False
        _copy_missing(os.path.join(bundle, "config.json"), os.path.join(target, "config.json"))
        return True
    except Exception as exc:  # noqa: BLE001 - reported by the caller's warning
        print(f"Warning: moving the data out of the app bundle failed "
              f"({type(exc).__name__}: {exc}).")
        return False
    finally:
        lock.release()


def _get_fernet() -> "Fernet":
    """Fernet for stored secrets; the key lives in the OS credential store
    when one is available (see :mod:`.secret_store`), else in ``secret.key``."""
    if Fernet is None:
        raise RuntimeError("cryptography package is not installed.")
    from .secret_store import get_key

    return Fernet(get_key(get_user_data_dir()))


def _resolve_path(p: str, base_dir: str = None) -> str:
    """Resolves relative file paths against the base_dir, user data dir, or project root."""
    if not p:
        return p
    if not os.path.isabs(p):
        root = base_dir if base_dir else get_user_data_dir()
        return os.path.normpath(os.path.join(root, p))
    return p


def quarantine_corrupt_file(path: str) -> str:
    """Renames an unreadable JSON file aside so its bytes survive debugging.

    Returns the backup path, or "" when there was nothing to preserve
    (missing file) or the rename itself failed. Never raises.
    """
    try:
        if not path or not os.path.exists(path):
            return ""
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = f"{path}.corrupt-{stamp}"
        os.replace(path, backup)
        return backup
    except Exception:
        return ""


def example_path_for(path: str) -> str:
    """Returns the sibling ``.example.json`` template path.

    Suffix-only replacement: ``str.replace(".json", ...)`` would also
    rewrite a directory named e.g. ``my.json.d`` mid-path.
    """
    if path.endswith(".json"):
        return path[: -len(".json")] + ".example.json"
    return path + ".example.json"


def try_file_lock(lock_path: str, stale_after_s: float = 120.0):
    """Best-effort inter-process lock (returns opaque token or None).

    The in-process ``threading.Lock`` does not help when the tray and the
    UI run as two processes sharing ``log.txt``. The token must be passed
    to :func:`release_file_lock`. Stale locks (older than
    ``stale_after_s``) are reclaimed so a killed process cannot block
    rotation forever.
    """
    import time

    try:
        directory = os.path.dirname(os.path.abspath(lock_path))
        os.makedirs(directory, exist_ok=True)
        try:
            if os.path.exists(lock_path):
                age = time.time() - os.path.getmtime(lock_path)
                if age < stale_after_s:
                    return None
                try:
                    os.remove(lock_path)
                except OSError:
                    return None
        except OSError:
            pass
        fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        try:
            os.write(fd, str(os.getpid()).encode("ascii"))
        finally:
            os.close(fd)
        return lock_path
    except (OSError, ValueError):
        return None


class InterProcessLock:
    """Exclusive OS-level lock on ``path`` (``fcntl.flock`` / ``msvcrt.locking``).

    Unlike :func:`try_file_lock`, the OS drops the lock when the holder
    dies, so a killed tray or window can never leave a stale lock behind.
    Also exclusive between threads of one process (each acquire opens its
    own handle). Falls back to "always acquired" only where neither
    locking API exists.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self._fh = None

    def _try_once(self) -> bool:
        directory = os.path.dirname(os.path.abspath(self.path))
        os.makedirs(directory, exist_ok=True)
        fh = open(self.path, "a+b")
        try:
            if sys.platform == "win32":
                import msvcrt

                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, ImportError) as exc:
            fh.close()
            if isinstance(exc, ImportError):
                return True
            return False
        self._fh = fh
        return True

    def acquire(self, timeout_s: float = 0.0) -> bool:
        """True once held; False when still busy after ``timeout_s``."""
        import time

        if self._fh is not None:
            raise RuntimeError(f"lock {self.path!r} is already held by this object")
        deadline = time.monotonic() + max(0.0, timeout_s)
        while True:
            try:
                if self._try_once():
                    return True
            except OSError:
                return False
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.25)

    def release(self) -> None:
        fh, self._fh = self._fh, None
        if fh is None:
            return
        try:
            if sys.platform == "win32":
                import msvcrt

                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        except (OSError, ImportError):
            pass  # closing the handle below releases it anyway
        finally:
            fh.close()

    @property
    def held(self) -> bool:
        return self._fh is not None


def describe_swallowed(what: str, exc: BaseException) -> str:
    """One log line for an exception a scraper deliberately carries on after.

    Waits that time out and fallbacks that fire are expected on slow
    links, so they must not fail the run — but a silent ``pass`` makes a
    changed page look like "no data". The line names the step and the
    exception type (first message line only: call logs are long).
    """
    first = ""
    try:
        text = str(exc).strip()
        first = text.splitlines()[0][:160] if text else ""
    except Exception:  # noqa: BLE001 - the type alone still helps
        pass
    return f"Debug: {what} — {type(exc).__name__}{': ' + first if first else ''}"


def clear_input(locator) -> None:
    """Empties a text input before key-by-key typing. Never raises except
    ``InterruptedError`` (cancel).

    ``press_sequentially`` appends to whatever the field holds: a retry
    after a partially typed value, or a value the site kept after a failed
    login postback, would otherwise be typed twice. ``fill('')`` first;
    select-all + Delete for inputs that ignore ``fill()``.
    """
    try:
        locator.fill("")
        return
    except InterruptedError:
        raise
    except Exception:
        pass
    try:
        locator.press("ControlOrMeta+a")
        locator.press("Delete")
    except InterruptedError:
        raise
    except Exception:
        pass


def release_file_lock(token) -> None:
    """Releases a lock acquired with :func:`try_file_lock`."""
    if not token:
        return
    try:
        os.remove(str(token))
    except OSError:
        pass


def atomic_write_json(path: str, data, encoding: str = "utf-8") -> None:
    """Writes JSON atomically (temp file + os.replace) so a crash or kill
    can never leave a truncated file behind. Creates parent dirs as needed."""
    import json
    import tempfile

    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=directory, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding=encoding) as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise


def encrypt(password: str, key: str = None) -> str:
    """Encrypts text using Fernet. 'key' argument is ignored and kept for backward compatibility."""
    if not password:
        return ""
    if Fernet is None:
        # Fallback to plain text if crypto not available during weird build issues
        return password
    f = _get_fernet()
    return f.encrypt(password.encode("utf-8")).decode("ascii")


def decrypt(password_hash: str, key: str = None) -> str:
    """Decrypts text. Automatically falls back to legacy XOR if Fernet fails, migrating it seamlessly.

    NOTE: this returns the input unchanged when nothing can decode it — callers
    that must distinguish failure (e.g. settings UI) should use decrypt_strict().
    """
    if not password_hash:
        return ""

    if Fernet is not None:
        try:
            f = _get_fernet()
            return f.decrypt(password_hash.encode("ascii")).decode("utf-8")
        except (InvalidToken, ValueError, TypeError, OSError):
            pass # Fallback to legacy XOR (OSError: secret.key file IO failed)

    # Legacy XOR cipher fallback
    try:
        encrypted_bytes = base64.b64decode(password_hash.encode("ascii"))
        legacy_key = key or legacy_encryption_key
        key_bytes = legacy_key.encode("utf-8")
        decrypted_bytes = bytearray(encrypted_bytes[i] ^ key_bytes[i % len(key_bytes)] for i in range(len(encrypted_bytes)))
        return decrypted_bytes.decode("utf-8")
    except Exception:
        # Fallback to returning raw string if not a valid base64 encrypted hash
        return password_hash


def is_encrypted_flag(value) -> bool:
    """True when a ``*_encrypted`` config flag means ciphertext.

    Config round-trips real booleans, but a hand-edited config can hold
    ``1``/``"1"``/``"yes"`` — reading those as plaintext would type the
    ciphertext as the password.
    """
    if value is True:
        return True
    try:
        return str(value).strip().lower() in ("true", "1", "yes")
    except Exception:
        return False


def decrypt_strict(password_hash: str, key: str = None):
    """Like decrypt(), but returns None when the value cannot be decoded.

    Used where echoing undecryptable ciphertext would be harmful (settings UI:
    it would display — and on save, double-encrypt — garbage).
    """
    if not password_hash:
        return ""

    if Fernet is not None:
        try:
            f = _get_fernet()
            return f.decrypt(password_hash.encode("ascii")).decode("utf-8")
        except Exception:
            pass  # Try the legacy cipher below.

    # Legacy XOR cipher (strict: standard base64 + valid UTF-8 required).
    try:
        encrypted_bytes = base64.b64decode(password_hash.encode("ascii"), validate=True)
        legacy_key = key or legacy_encryption_key
        key_bytes = legacy_key.encode("utf-8")
        decrypted_bytes = bytearray(encrypted_bytes[i] ^ key_bytes[i % len(key_bytes)] for i in range(len(encrypted_bytes)))
        return decrypted_bytes.decode("utf-8")
    except Exception:
        return None


def parse_date(date_str: str) -> datetime:
    """Parses date string into datetime object supporting multiple formats and prefix day names."""
    if not date_str:
        raise ValueError("Empty date string")
    # Remove parenthesized days of week, e.g. " (úterý)", " (St)"
    s = re.sub(r"\(.*?\)", "", str(date_str)).strip()
    # Normalize spaces around dots, e.g. "1. 9. 2026" -> "1.9.2026"
    s = re.sub(r"\s*\.\s*", ".", s)

    # Search for date pattern anywhere in the string to ignore leading day names (e.g. "Pondělí 1.9.2026")
    m = re.search(r"(\d{1,2}\.\d{1,2}\.\d{4})|(\d{4}-\d{1,2}-\d{1,2})|(\d{1,2}/\d{1,2}/\d{4})", s)
    if m:
        clean_date = m.group(0)
    else:
        clean_date = s.split(" ")[0].split("T")[0].strip()

    for fmt in ("%d.%m.%Y", "%Y-%m-%d", "%d/%m/%Y", "%d.%m.%y", "%Y/%m/%d"):
        try:
            return datetime.strptime(clean_date, fmt)
        except ValueError:
            pass
    raise ValueError(f"Unable to parse date string: {date_str}")


def extract_lesson_num(time_str: str):
    """Extracts integer lesson index from a time/lesson string."""
    if not time_str:
        return None
    match = re.search(r"(\d+)\s*\(", str(time_str))
    if match:
        return int(match.group(1))
    # Bare leading number ("3") — but never a clock time ("8:00",
    # "13:40 - 14:25"): the lookahead rejects digits followed (after
    # optional digits/spaces) by a colon, so multi-digit hours can't
    # backtrack into a bogus period ("13:40" -> 1).
    match_start = re.match(r"^(\d+)(?![\d\s]*:)", str(time_str).strip())
    return int(match_start.group(1)) if match_start else None


def is_excused_marker(text: str) -> bool:
    """True when a Bakalari absence label means 'already excused'.

    Negations must NOT match: "Neomluveno"/"Neomluvená" contain "omluv"
    and "Unexcused" contains "excus", so a naive substring check treats
    unexcused absences as excused (and they silently never get excused).
    """
    low = str(text or "").lower()
    if ("neomluv" in low or "unexcus" in low or "neexcus" in low
            # Word-boundary negations: a bare substring ("no excus") also
            # matches inside "omluveno excused" (ve-no-excus-ed).
            or re.search(r"\b(not|without|no)\s+excus", low)
            or re.search(r"\bbeze?\s+omluv", low)):
        return False
    return "omluv" in low or "excus" in low


def short_room_name(room: str | None) -> str:
    """Returns the short display name of a Bakalari room.

    Bakalari room labels carry the building code in parentheses, e.g.
    ``"4A - (104)"`` or ``"III - (P06)"`` — only the part before the
    dash (``"4A"`` / ``"III"``) is shown to students. Plain names
    (``"U12"``, ``""``) pass through unchanged.
    """
    text = str(room or "").strip()
    if not text:
        return ""
    # Canonical shape: "<short> - (<code>)", dash may be hyphen/en/em dash
    # with or without surrounding spaces.
    m = re.match(r"^(.*?)\s+[-–—]\s*\(.*\)\s*$", text)
    if m and m.group(1).strip():
        return m.group(1).strip()
    m = re.match(r"^(.*?)\s*[-–—]\s*\(.*\)\s*$", text)
    if m and m.group(1).strip():
        return m.group(1).strip()
    # Fallback: trailing parenthesized suffix without a dash ("4A (104)").
    m = re.match(r"^(.*?)\s+\(.*\)\s*$", text)
    if m and m.group(1).strip():
        return m.group(1).strip()
    return text


def template_text(entry) -> str:
    """The excuse text of a template entry.

    Entries are plain strings (older configs) or ``{"name", "text"}``
    dicts; anything else reads as an empty template.
    """
    if isinstance(entry, dict):
        return str(entry.get("text", "") or "")
    return "" if entry is None else str(entry)


def template_name(entry) -> str:
    """The user-given short name of a template entry ("" when unnamed)."""
    if isinstance(entry, dict):
        return " ".join(str(entry.get("name", "") or "").split())
    return ""


def template_texts(entries) -> list[str]:
    """Excuse texts of a configured template list (names dropped)."""
    if not isinstance(entries, list):
        return []
    return [template_text(e) for e in entries]


def format_excuse_template(
    template_str: str,
    date_str: str = "",
    lessons_str: str = "",
    subject_str: str = "",
    signature_str: str = "",
) -> str:
    """Formats an excuse template by replacing variables like {date}, {lessons}, {subject}, {signature}."""
    if not template_str:
        return ""
    res = template_str
    res = res.replace("{date}", date_str)
    res = res.replace("{lessons}", str(lessons_str))
    res = res.replace("{subject}", subject_str)
    if "{signature}" in res:
        res = res.replace("{signature}", signature_str)
    else:
        stripped_sig = signature_str.strip() if signature_str else ""
        # Case-insensitive check so "Jan Novák" in template isn't duplicated
        # when the configured signature is "jan novák" and vice versa.
        if stripped_sig and stripped_sig.lower() not in res.lower():
            res = f"{res.strip()}\n{stripped_sig}"
    return res.strip()
