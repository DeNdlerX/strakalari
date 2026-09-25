import json
import os
from datetime import datetime, timedelta
from .helpers import _resolve_path, atomic_write_json

CACHE_FILE = './data_cache.json'
CACHE_VERSION = 2


def _parse_ts(value) -> datetime | None:
    if not value:
        return None
    for fmt in ("%d.%m.%Y %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(str(value).strip(), fmt)
        except ValueError:
            continue
    try:
        return datetime.fromisoformat(str(value).strip())
    except ValueError:
        return None


def _read_cache(strict: bool) -> dict:
    """The on-disk cache; ``strict`` raises when the file is busy.

    Only undecodable content is quarantined — a merely locked file must
    survive untouched.
    """
    path = _resolve_path(CACHE_FILE)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, 'r', encoding='utf-8') as f:
            data = json.load(f)
    except (json.JSONDecodeError, UnicodeDecodeError) as e:
        from .helpers import quarantine_corrupt_file

        backup = quarantine_corrupt_file(path)
        hint = f" Preserved at {backup}." if backup else ""
        print(f'Warning: Could not read data cache: {e}.{hint} Starting fresh.')
        return {}
    except OSError as e:
        if strict:
            raise
        print(f'Warning: Could not read data cache right now: {e}.')
        return {}
    if not isinstance(data, dict):
        return {}
    if "_cache_version" in data and data["_cache_version"] != CACHE_VERSION:
        print(f'Warning: ignoring data cache with version {data["_cache_version"]!r} (expected {CACHE_VERSION}).')
        return {}
    return data


def load_data_cache() -> dict:
    return _read_cache(strict=False)


def save_data_cache(data: dict, replace: bool = False) -> dict:
    """Merges `data` into the on-disk cache (default) or replaces it entirely
    when `replace=True`. A busy cache file is left untouched: merging
    against an unreadable file would drop every other key."""
    path = _resolve_path(CACHE_FILE)
    try:
        current = {} if replace else _read_cache(strict=True)
    except OSError as e:
        print(f'Warning: Could not save data cache: {e} — disk cache unchanged.')
        return dict(data or {})
    current.update(data or {})
    current["_cache_version"] = CACHE_VERSION
    if "last_updated" not in current or (data and "last_updated" in data):
        current["last_updated"] = (data or {}).get(
            "last_updated", current.get("last_updated", datetime.now().strftime("%d.%m.%Y %H:%M:%S"))
        )
    try:
        atomic_write_json(path, current)
    except Exception as e:
        print(f'Warning: Could not save data cache: {e} — in-memory data kept, disk cache unchanged.')
    return current


def merge_timetable_days(old: dict | None, fresh: dict | None, window_start=None) -> dict:
    """Day-granular merge of timetables for full-refresh saves.

    A week that fails to render (slow link, session hiccup) contributes
    no days to the fresh scrape — a blind full replace would then delete
    previously scraped days and with them pending excuse tasks, so an
    unsent lesson vanishes from pending as if excused. Unscraped days
    therefore survive: fresh days win (including present-but-empty),
    days missing from fresh are kept, and parseable days older than
    ``window_start`` are pruned so stale semester data still drops.
    Unparseable keys are always kept, never dropped on ambiguity.
    """
    merged = dict(old or {})
    for key, lessons in (fresh or {}).items():
        merged[key] = lessons
    if window_start is None:
        return merged
    from .models import parse_cz_date

    for key in list(merged.keys()):
        if key in (fresh or {}):
            continue
        try:
            day = parse_cz_date(key)
        except Exception:
            day = None
        if day is not None and day < window_start:
            try:
                del merged[key]
            except KeyError:
                pass
    return merged


def cache_age(cache: dict | None = None) -> timedelta | None:
    """Age of the cache based on its ``last_updated`` stamp (None = unknown)."""
    data = cache if cache is not None else load_data_cache()
    ts = _parse_ts((data or {}).get("last_updated"))
    if ts is None:
        return None
    return datetime.now() - ts


def last_updated_time(cache: dict | None = None) -> datetime | None:
    """Parsed ``last_updated`` stamp of the data cache (None when unknown)."""
    data = cache if cache is not None else load_data_cache()
    return _parse_ts((data or {}).get("last_updated"))


def startup_seed(cache: dict | None = None, now: datetime | None = None) -> datetime | None:
    """Scheduler seed: when the cached data was last refreshed.

    Returns None when the stamp is missing, unparsable, or in the future
    (clock skew / bogus stamp) — callers then refresh on start, exactly
    like before. Only positive evidence of fresh data defers the run.
    """
    try:
        seed = last_updated_time(cache)
    except Exception:
        return None
    if seed is None:
        return None
    try:
        if seed > (now or datetime.now()):
            return None
    except Exception:
        return None
    return seed


def is_cache_stale(cache: dict | None = None, ttl_hours: float = 24) -> bool:
    """True when the cache is missing, unparsable, or older than ``ttl_hours``."""
    data = cache if cache is not None else load_data_cache()
    if not data:
        return True
    age = cache_age(data)
    if age is None:
        return True
    try:
        return age > timedelta(hours=float(ttl_hours))
    except (TypeError, ValueError):
        return age > timedelta(hours=24)


def describe_cache(cache: dict | None = None, ttl_hours: float = 24) -> str:
    """Short human label for the UI header, e.g. 'Aktualizováno: … (zastaralé)''."""
    from .i18n import t

    data = cache if cache is not None else load_data_cache()
    last = (data or {}).get("last_updated") or "—"
    age = cache_age(data)
    if age is None:
        return f"{last}"
    hours = age.total_seconds() / 3600
    if hours < 1:
        mins = int(age.total_seconds() // 60)
        age_s = t("cache_age_min", n=mins) if mins >= 1 else t("cache_age_now")
    elif hours < 48:
        age_s = t("cache_age_hours", n=f"{hours:.1f}")
    else:
        age_s = t("cache_age_days", n=int(hours // 24))
    stale = f" ({t('cache_stale')})" if is_cache_stale(data, ttl_hours) else ""
    return f"{last} · {age_s}{stale}"
