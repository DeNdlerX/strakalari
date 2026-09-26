"""Structured error reports with secrets redacted.

When a background operation (refresh, excuse submit, lunch order, view
render) fails, the UI shows a popup with a "copy log" button. The copied
text must let us identify the bug without leaking credentials — that is
what this module builds:

* the exception type + message + full traceback (today only the first
  line was kept, which hides the actual cause),
* environment context (app version, OS, Python),
* the tail of the in-memory log (what the app was doing),
* which config values are filled in (key names + set/empty only —
  values never leave the machine).
"""

from __future__ import annotations

import platform
import sys
import traceback
from datetime import datetime

REDACTED = "***"

#: Config keys containing any of these markers hold secrets.
SECRET_MARKERS = ("password", "passwd", "api_key", "apikey", "token", "secret")


class UserError(Exception):
    """A failure the user can fix themselves (missing URL, bad login, ...).

    ``report_error`` turns these into a friendly dialog with a fix-it hint
    instead of the full bug-report popup. The diagnostics bundle is still
    built and copyable — only tucked behind a secondary "not your fault?"
    line instead of dumped on screen.
    """


#: How much of the live log travels with the report.
LOG_TAIL_LINES = 60

#: Single log lines longer than this are truncated in the report.
MAX_LINE_CHARS = 500

#: Exception type names that always mean "the page never loaded in time".
_TIMEOUT_TYPE_NAMES = frozenset({"TimeoutError", "TimeoutExpired"})

#: Message fragments (lowercased) identifying a wait that ran out of time.
_TIMEOUT_MESSAGE_HINTS = (
    "timeout",
    "timed out",
    "exceeded",
    "time-out",
    "vypršel",
    "vyprsel",
)


def is_timeout_error(exc: BaseException | None) -> bool:
    """True when ``exc`` is a load/wait timeout (slow connection), not a bug.

    Covers the builtin ``TimeoutError``, Playwright's timeout (same name,
    message like ``Timeout 30000ms exceeded``) and anything whose message
    says the wait ran out. Cancellation (``InterruptedError``) and
    ``UserError`` are never timeouts — callers branch on those first.
    Never raises.
    """
    if exc is None:
        return False
    try:
        if isinstance(exc, (InterruptedError, KeyboardInterrupt, UserError)):
            return False
        if type(exc).__name__ in _TIMEOUT_TYPE_NAMES:
            return True
        text = str(exc or "").lower()
        return any(hint in text for hint in _TIMEOUT_MESSAGE_HINTS)
    except Exception:
        return False


def timeout_user_message() -> str:
    """Friendly fix-it text for timeouts (slow/unstable connection).

    Shown in the error dialog instead of the traceback dump; the dialog
    keeps its copy-logs button behind the "not your fault?" line, so a
    user who believes the connection is fine can still send the logs.
    """
    from .i18n import t

    return t("error_timeout")


def _is_secret_key(key: object) -> bool:
    lowered = str(key or "").lower()
    return any(marker in lowered for marker in SECRET_MARKERS)


def _is_empty_value(value: object) -> bool:
    """``True`` when a config value counts as unset (nothing to leak)."""
    if value is None:
        return True
    if isinstance(value, bool):
        return False  # False is a real choice, not an empty value
    if isinstance(value, (str, bytes, list, tuple, set, dict)):
        return len(value) == 0
    return False


def redact_config(config: dict | None) -> dict:
    """Maps ``config`` to ``{key: \"set\" | \"empty\"}`` — values never leave the machine.

    Key names alone tell us which integrations are configured (e.g. Strava
    vs. Bakalari-only); the actual values (usernames, URLs, passwords,
    excuse texts, signatures) are not needed to fix a bug and stay private.
    """
    return {
        key: ("empty" if _is_empty_value(value) else "set")
        for key, value in (config or {}).items()
    }


#: Config keys whose values identify the student (not secrets, but
#: personal data that has no business in a pasted bug report).
PERSONAL_KEYS = ("bakalari_username", "strava_username", "strava_user", "your_signature")


def _sensitive_values(config: dict | None) -> set[str]:
    """Every config value that must never appear in a report.

    Secrets are stored encrypted, so the ciphertext alone would never
    match a leaked plaintext password (e.g. echoed in a Playwright call
    log) — the decrypted value is scrubbed too. The signature (usually
    the student's name) is also scrubbed word by word.
    """
    values: set[str] = set()
    cfg = config or {}
    for key, value in cfg.items():
        if isinstance(value, bool) or not value or isinstance(value, (dict, list, tuple, set)):
            continue
        value = str(value)
        if _is_secret_key(key):
            values.add(value)
            if cfg.get(f"{key}_encrypted") is True:
                try:
                    from .helpers import decrypt_strict

                    plain = decrypt_strict(value)
                except Exception:  # noqa: BLE001 - ciphertext still scrubbed
                    plain = None
                if plain:
                    values.add(plain)
        elif key in PERSONAL_KEYS:
            values.add(value.strip())
            if key == "your_signature":
                values.update(w for w in value.replace(",", " ").split() if len(w) >= 3)
    values.discard("")
    return values


def secret_values(config: dict | None) -> set[str]:
    """Only the secrets (passwords, API keys) of ``config``, ciphertext and plaintext.

    For the local ``log.txt``: it stays on the user's machine, so names
    and usernames may stay in it, but a password must never be written
    to disk in the clear.
    """
    cfg = config or {}
    return _sensitive_values({k: v for k, v in cfg.items()
                              if _is_secret_key(k) or k.endswith("_encrypted")})


def redact_values(text: str, values: set[str] | frozenset[str]) -> str:
    """Replaces every value of ``values`` in ``text`` with the redaction marker."""
    import re as _re

    out = str(text or "")
    long_secrets: set[str] = set()
    short_secrets: set[str] = set()
    for secret in values:
        if len(secret) >= 4:
            long_secrets.add(secret)
        else:
            short_secrets.add(secret)
    # Longest first so overlapping values redact cleanly.
    for secret in sorted(long_secrets, key=len, reverse=True):
        if secret in out:
            out = out.replace(secret, REDACTED)
    # Short secrets (PINs) only on token boundaries — a blanket substring
    # replace of a 1-3 char value would nuke ordinary prose.
    for secret in sorted(short_secrets, key=len, reverse=True):
        try:
            out = _re.sub(r"(?<!\S)" + _re.escape(secret) + r"(?!\S)", REDACTED, out)
        except Exception:
            continue
    return out


def redact_text(text: str, config: dict | None = None) -> str:
    """Scrubs known secret and personal *values* out of free text (tracebacks, logs)."""
    return redact_values(text, _sensitive_values(config))


def redact_with_saved_config(text: str) -> str:
    """``redact_text`` against the config on disk, for code with no config at hand.

    Used before tracebacks go to console.log (the scheduler, tray): a
    Playwright call log can echo a typed password. Never raises.
    """
    try:
        from .config import ConfigManager

        config = ConfigManager().data
    except Exception:  # noqa: BLE001 - no config means no known secrets
        config = None
    try:
        return redact_text(text, config)
    except Exception:  # noqa: BLE001 - fail closed
        return "(redaction failed, details withheld)"


def short_summary(exc: BaseException | None, message: str = "", limit: int = 200) -> str:
    """One-line human summary: ``TypeName: first line``."""
    if exc is not None:
        text = f"{type(exc).__name__}: {exc}".strip()
    else:
        text = str(message or "").strip()
    first = text.splitlines()[0] if text else ""
    return (first[:limit] or "unknown error").strip() or "unknown error"


def current_traceback() -> str:
    """``traceback.format_exc()`` or ``""`` when called outside a handler."""
    try:
        formatted = traceback.format_exc()
    except Exception:
        return ""
    if not formatted or "NoneType: None" in formatted:
        return ""
    return formatted.strip()


def collect_context() -> dict:
    """Environment block: version, build kind, OS, Python, UI language."""
    try:
        from .update import get_current_version

        version = get_current_version()
    except Exception:
        version = "?"
    try:
        from .i18n import get_language

        language = get_language()
    except Exception:
        language = "?"
    return {
        "app_version": version,
        # Installer build vs. a source checkout behave differently (paths,
        # bundled browser, stdio) — the first thing to know about a bug.
        "build": "installer" if getattr(sys, "frozen", False) else "source",
        "platform": platform.platform(),
        "python": sys.version.split()[0],
        "language": language,
    }


def build_report(
    operation: str,
    summary: str,
    traceback_str: str = "",
    log_tail: list[str] | None = None,
    config: dict | None = None,
    extra: dict | None = None,
    user_message: str = "",
) -> dict:
    """Assembles the report dict stored on ``AppState.last_error``."""
    tail = [str(line)[:MAX_LINE_CHARS] for line in (log_tail or [])[-LOG_TAIL_LINES:]]
    summary = redact_text(str(summary or "unknown error"), config)
    # Extra values are free text too (labels, day counts) — scrub any secret
    # that ended up in them before the report is stored or pasted.
    safe_extra: dict = {}
    try:
        for k, v in (extra or {}).items():
            safe_extra[str(k)] = redact_text(str(v), config)
    except Exception:
        safe_extra = {}
    return {
        "at": datetime.now().strftime("%d.%m.%Y %H:%M:%S"),
        "operation": str(operation or "?"),
        "summary": summary,
        "traceback": redact_text(str(traceback_str or "").strip(), config),
        "log_tail": [redact_text(line, config) for line in tail],
        "config": redact_config(config),
        "context": collect_context(),
        "extra": safe_extra,
        # Friendly fix-it text for user-fixable failures ("") for real bugs.
        "user_message": redact_text(str(user_message or "").strip(), config),
    }


def format_report(report: dict | None) -> str:
    """Renders the report as copy-pasteable plain text."""
    if not isinstance(report, dict) or not report:
        return ""
    lines = [
        "Strakalari error report",
        f"time: {report.get('at', '?')}",
        f"operation: {report.get('operation', '?')}",
        f"error: {report.get('summary', '?')}",
    ]
    context = report.get("context") or {}
    if isinstance(context, dict) and context:
        lines.append(
            "environment: "
            + ", ".join(f"{k}={v}" for k, v in context.items())
        )
    extra = report.get("extra") or {}
    if isinstance(extra, dict) and extra:
        lines.append(
            "details: " + ", ".join(f"{k}={v}" for k, v in extra.items())
        )
    tb = str(report.get("traceback") or "").strip()
    lines.append("traceback:")
    lines.append(tb if tb else "(no traceback captured)")
    tail = report.get("log_tail") or []
    lines.append(f"recent log ({len(tail)} lines):")
    lines.extend(str(line) for line in tail)
    config = report.get("config") or {}
    if isinstance(config, dict) and config:
        lines.append("config (values hidden, filled status only):")
        for key in sorted(config, key=str):
            lines.append(f"  {key}={config[key]}")
    return "\n".join(lines).strip() + "\n"
