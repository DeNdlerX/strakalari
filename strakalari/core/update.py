"""GitHub release check — notifies about newer Strakalari versions.

Queries ``api.github.com/repos/<owner>/<repo>/releases`` with the
standard library only (no new dependencies — the frozen build already
ships ``certifi``'s CA store for ``urllib`` HTTPS). All failures (offline,
rate-limited, no releases yet) return ``None`` so the UI simply stays
silent; update checks must never break the app.

Two update channels (config ``update_channel``, defaulting to the kind of
build first installed — see ``default_channel``):

* ``stable`` — only full releases (not marked pre-release on GitHub and
  without a ``-beta``-style version suffix).
* ``beta`` — pre-releases *and* full releases, whichever is newest.

The list endpoint is used instead of ``/releases/latest`` because the
latter never returns pre-releases. Drafts are always skipped.

Results for both channels are cached for 24 h in ``update_cache.json``
next to the user config so every launch doesn't hit the API and
switching the channel needs no extra request.
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.request

GITHUB_REPO = "DeNdlerX/strakalari"
API_URL = f"https://api.github.com/repos/{GITHUB_REPO}/releases?per_page=50"
RELEASES_URL = f"https://github.com/{GITHUB_REPO}/releases"
CHECK_INTERVAL_S = 24 * 3600
CACHE_FILENAME = "update_cache.json"

CHANNEL_STABLE = "stable"
CHANNEL_BETA = "beta"
UPDATE_CHANNELS = (CHANNEL_STABLE, CHANNEL_BETA)


def normalize_channel(value: object) -> str:
    """Anything but ``beta`` (case-insensitive) means ``stable``."""
    return CHANNEL_BETA if str(value or "").strip().lower() == CHANNEL_BETA else CHANNEL_STABLE


def default_channel() -> str:
    """Channel for a config that has none yet: follows the running build.

    A beta build defaults to ``beta``, a stable one to ``stable``. The
    config persists the value on its first save, so a user who first
    installed a beta stays on beta after upgrading to a stable release
    (and vice versa) until they switch in Settings.
    """
    return CHANNEL_BETA if is_prerelease_version(get_current_version()) else CHANNEL_STABLE


def get_current_version() -> str:
    """Single source: ``strakalari.__version__`` (stamped by CI at build)."""
    try:
        from strakalari import __version__

        return str(__version__)
    except Exception:
        return "0.0.0"


def parse_version(text: str) -> tuple[int, ...]:
    """'v1.2.3' -> (1, 2, 3). Non-numeric suffixes are ignored."""
    cleaned = str(text or "").strip().lstrip("vV")
    parts: list[int] = []
    for chunk in re.split(r"[.\-+_]", cleaned):
        match = re.match(r"(\d+)", chunk)
        if match:
            parts.append(int(match.group(1)))
        elif parts:
            break
    return tuple(parts) if parts else (0,)


_CORE_RE = re.compile(r"^(\d+(?:\.\d+)*)(.*)$")


def _split_version(text: str) -> tuple[tuple[int, ...], str]:
    """'v0.1.0-beta.1+abc' -> ((0, 1, 0), 'beta.1'). Build metadata dropped."""
    cleaned = str(text or "").strip().lstrip("vV").split("+", 1)[0]
    match = _CORE_RE.match(cleaned)
    if not match:
        return (0,), ""
    core = tuple(int(p) for p in match.group(1).split("."))
    pre = match.group(2).lstrip(".-_").strip()
    return core, pre


def is_prerelease_version(text: str) -> bool:
    """True for 'v0.1.0-beta.1', '1.0.0-rc1' etc.; False for '1.0.0'."""
    return bool(_split_version(text)[1])


def version_key(text: str) -> tuple:
    """Sortable key with SemVer ordering of pre-releases.

    ``0.1.0-beta.1 < 0.1.0-beta.2 < 0.1.0-rc.1 < 0.1.0 < 0.1.1``; trailing
    zeros don't matter (``0.1 == 0.1.0``).
    """
    core, pre = _split_version(text)
    padded = list(core)
    while len(padded) > 1 and padded[-1] == 0:
        padded.pop()
    if not pre:
        # A final release sorts after every pre-release of the same core.
        return (tuple(padded), 1, ())
    idents: list[tuple[int, int, str]] = []
    for ident in re.split(r"[.\-_]", pre):
        if not ident:
            continue
        if ident.isdigit():
            idents.append((0, int(ident), ""))
        else:
            # 'beta2' -> ('beta', 2) so beta10 > beta9.
            m = re.match(r"^([A-Za-z]+)(\d+)$", ident)
            if m:
                idents.append((1, 0, m.group(1).lower()))
                idents.append((0, int(m.group(2)), ""))
            else:
                idents.append((1, 0, ident.lower()))
    return (tuple(padded), 0, tuple(idents))


def is_newer(latest: str, current: str) -> bool:
    """True when ``latest`` is a higher version than ``current``."""
    try:
        return version_key(latest) > version_key(current)
    except Exception:
        return False


def _release_info(payload: dict) -> dict | None:
    """GitHub release JSON -> the small dict the UI and cache use."""
    if not isinstance(payload, dict):
        return None
    tag = str(payload.get("tag_name") or "").strip()
    if not tag:
        return None
    url = str(payload.get("html_url") or RELEASES_URL).strip() or RELEASES_URL
    version = tag.lstrip("vV")
    return {
        "version": version,
        "tag": tag,
        "url": url,
        "name": str(payload.get("name") or tag),
        "published_at": str(payload.get("published_at") or ""),
        "prerelease": bool(payload.get("prerelease")) or is_prerelease_version(version),
        "draft": bool(payload.get("draft")),
    }


def pick_release(releases: list, channel: str = CHANNEL_STABLE) -> dict | None:
    """Newest release relevant to ``channel`` (drafts never count)."""
    beta = normalize_channel(channel) == CHANNEL_BETA
    best: dict | None = None
    for payload in releases or []:
        info = _release_info(payload)
        if info is None or info["draft"]:
            continue
        if info["prerelease"] and not beta:
            continue
        if best is None or is_newer(info["version"], best["version"]):
            best = info
    return best


def fetch_releases(timeout: float = 30.0) -> list | None:
    """Raw release list from GitHub (newest first). None on any failure."""
    try:
        request = urllib.request.Request(
            API_URL,
            headers={
                "User-Agent": "Strakalari-UpdateCheck",
                "Accept": "application/vnd.github+json",
            },
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
        return payload if isinstance(payload, list) else None
    except Exception:
        return None


def fetch_latest_release(channel: str = CHANNEL_STABLE, timeout: float = 30.0) -> dict | None:
    """Newest release for ``channel``. Returns None on any failure."""
    releases = fetch_releases(timeout=timeout)
    if releases is None:
        return None
    info = pick_release(releases, channel)
    if info is not None:
        info["checked_at"] = time.time()
    return info


def _cache_path() -> str:
    try:
        from strakalari.core.helpers import _resolve_path

        return _resolve_path(CACHE_FILENAME)
    except Exception:
        return os.path.abspath(CACHE_FILENAME)


def _load_cache_file() -> dict | None:
    """``{"checked_at": ts, "channels": {"stable": info|None, "beta": ...}}``.

    Anything else (missing, corrupt, the pre-channel single-release
    format) is None, which simply triggers a fresh check.
    """
    try:
        path = _cache_path()
        if not os.path.exists(path):
            return None
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        if isinstance(data, dict) and isinstance(data.get("channels"), dict):
            return data
        return None
    except (json.JSONDecodeError, UnicodeDecodeError, OSError):
        try:
            from strakalari.core.helpers import quarantine_corrupt_file

            quarantine_corrupt_file(_cache_path())
        except Exception:
            pass
        return None
    except Exception:
        return None


def load_cached(channel: str = CHANNEL_STABLE) -> dict | None:
    """Last known release for ``channel`` (may be stale) or None."""
    cache = _load_cache_file()
    if not cache:
        return None
    info = cache["channels"].get(normalize_channel(channel))
    return info if isinstance(info, dict) and info.get("version") else None


def save_cached(channels: dict, checked_at: float | None = None) -> None:
    try:
        from strakalari.core.helpers import atomic_write_json

        atomic_write_json(
            _cache_path(),
            {
                "checked_at": checked_at if checked_at is not None else time.time(),
                "channels": {c: channels.get(c) for c in UPDATE_CHANNELS},
            },
        )
    except Exception:
        pass


def should_check(cached: dict | None, now: float | None = None) -> bool:
    """True when there is no cache or it is older than 24 h."""
    if not cached or not isinstance(cached, dict):
        return True
    try:
        checked_at = float(cached.get("checked_at") or 0)
    except (TypeError, ValueError):
        return True
    return (now if now is not None else time.time()) - checked_at >= CHECK_INTERVAL_S


def check_for_updates(force: bool = False, channel: str = CHANNEL_STABLE) -> dict | None:
    """Returns cached-or-fresh release info for ``channel``, or None.

    With ``force=False`` a fresh cache (< 24 h) is returned without any
    network call. One request refreshes both channels. Failures keep the
    stale cache so the banner can still show a previously seen release.
    """
    channel = normalize_channel(channel)
    cache = _load_cache_file()
    if not force and cache and not should_check(cache):
        return load_cached(channel)
    releases = fetch_releases()
    if releases is None:
        return load_cached(channel)
    now = time.time()
    picks: dict = {}
    for name in UPDATE_CHANNELS:
        info = pick_release(releases, name)
        if info is not None:
            info["checked_at"] = now
        picks[name] = info
    save_cached(picks, checked_at=now)
    return picks[channel]


def update_available(info: dict | None, current: str | None = None) -> bool:
    """True when ``info`` names a release newer than the running app."""
    if not info or not isinstance(info, dict):
        return False
    return is_newer(str(info.get("version") or ""), current or get_current_version())
