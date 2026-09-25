"""Automatic lunch picks (``strava_order_mode = auto``) — pure helpers.

Used by the refresh pipeline (auto mode) and the Lunches view filter:
first non-banned meal per orderable day, optionally Gemini picks when an
auto run is due. No I/O except the optional Gemini request.
"""

from __future__ import annotations

import re
from datetime import date, datetime
from typing import Callable, Dict, Iterable

GEMINI_INTERVAL_DEFAULT = 2
GEMINI_INTERVAL_MIN = 1
GEMINI_INTERVAL_MAX = 30


def clamp_gemini_interval(value: object) -> int:
    """Clamps the Gemini auto-run interval to [1, 30] days (default 2)."""
    try:
        num = int(float(str(value if value is not None else GEMINI_INTERVAL_DEFAULT).replace(",", ".")))
    except (TypeError, ValueError):
        return GEMINI_INTERVAL_DEFAULT
    return max(GEMINI_INTERVAL_MIN, min(GEMINI_INTERVAL_MAX, num))


def parse_last_run(value: object) -> date | None:
    """Parses the stored ``gemini_last_run`` stamp (ISO date, CZ fallback)."""
    text = str(value or "").strip()
    if not text:
        return None
    try:
        return date.fromisoformat(text[:10])
    except ValueError:
        pass
    m = re.match(r"^\s*(\d{1,2})\.(\d{1,2})\.(\d{4})\s*$", text)
    if m:
        try:
            return date(int(m.group(3)), int(m.group(2)), int(m.group(1)))
        except ValueError:
            return None
    return None


def should_run_gemini_auto(
    enabled: object,
    last_run_iso: object,
    interval_days: object,
    today: date | datetime | None = None,
) -> bool:
    """True when a Gemini auto-run is due (date granularity — hour-agnostic).

    Runs at most once per ``interval_days``: never ran → due, otherwise
    ``(today - last_run).days >= interval``. A corrupt stamp counts as
    never-ran (fail open toward running once, the run re-stamps).
    """
    if not bool(enabled):
        return False
    if today is None:
        today = date.today()
    elif isinstance(today, datetime):
        today = today.date()
    interval = clamp_gemini_interval(interval_days)
    last = parse_last_run(last_run_iso)
    if last is None:
        return True
    try:
        return (today - last).days >= interval
    except Exception:
        return True


def _meal_order_key(mid: str) -> int:
    m = re.search(r"&(\d+)&", str(mid))
    return int(m.group(1)) if m else 99


def _canon_day(value: object) -> str:
    """Best-effort canonical day key (``DD.MM.YYYY``), spelling-tolerant.

    Falls back to the stripped raw string when unparseable — callers
    only use it for equality, never for date math.
    """
    try:
        from .models import canonical_day_key as _cdk

        return _cdk(value)
    except Exception:
        return str(value or "").strip()


def filter_picks(
    food_data: dict,
    blacklist: Iterable[str] | None = None,
    cancelled_days: Iterable[str] | None = None,
    is_open: Callable[[date], bool] | None = None,
    today: date | datetime | None = None,
) -> Dict[str, str]:
    """First-non-banned pick per orderable day (mirrors ``evaluate()``).

    Skips past days, planner-cancelled days and cutoff-closed days. Days
    where everything is banned fall back to the menu's deorder element
    (``&-1&`` id) when present, else are left unpicked. Pure — no I/O.
    """
    from .matching import is_food_banned as _is_banned

    if today is None:
        today = date.today()
    elif isinstance(today, datetime):
        today = today.date()
    cancelled = {_canon_day(d) for d in (cancelled_days or [])}
    active_blacklist = [b for b in (blacklist or []) if b]

    def _banned(name: object) -> bool:
        try:
            banned, _kw = _is_banned(str(name or ""), list(active_blacklist))
            return bool(banned)
        except Exception:
            # Fail-closed: an uncheckable meal must not be auto-ordered.
            return True

    picks: Dict[str, str] = {}
    for day, selection in (food_data or {}).items():
        day_s = str(day)
        if _canon_day(day_s) in cancelled:
            continue
        if not isinstance(selection, dict) or not selection:
            continue
        try:
            from .helpers import parse_date as _parse

            _parsed = _parse(day_s)
            day_date = _parsed.date() if isinstance(_parsed, datetime) else _parsed
        except Exception:
            continue
        try:
            if day_date < today:
                continue
        except Exception:
            continue
        if callable(is_open):
            try:
                if not is_open(day_date):
                    continue
            except Exception:
                # Fail-closed: an uncheckable cutoff must skip the day.
                continue
        deorder_id: str | None = None
        available: list[tuple[str, str]] = []
        for mid, name in selection.items():
            if "&-1&" in str(mid):
                deorder_id = str(mid)
            else:
                available.append((str(mid), str(name)))
        available.sort(key=lambda item: _meal_order_key(item[0]))
        chosen: str | None = None
        for mid, name in available:
            if _banned(name):
                continue
            chosen = mid
            break
        if chosen is None and deorder_id is not None:
            chosen = deorder_id
        if chosen is not None:
            # Canonical day key: "01.10.2026" and "1.10.2026" spellings
            # must not coexist as two entries for the same day.
            picks[_canon_day(day_s)] = chosen
    return picks


def merge_gemini_with_filter(
    gemini_orders: dict | None,
    food_data: dict,
    blacklist: Iterable[str] | None = None,
    cancelled_days: Iterable[str] | None = None,
    is_open: Callable[[date], bool] | None = None,
    today: date | datetime | None = None,
) -> Dict[str, str]:
    """Keeps valid Gemini picks, fills the gaps with :func:`filter_picks`.

    A Gemini pick survives only when the meal is on the menu, not banned,
    the day is orderable (future, open, not cancelled). Remaining
    orderable days get the filter pick so auto mode never leaves a day
    empty while the menu is full.
    """
    from .matching import is_food_banned as _is_banned

    if today is None:
        today = date.today()
    elif isinstance(today, datetime):
        today = today.date()
    cancelled = {_canon_day(d) for d in (cancelled_days or [])}
    active_blacklist = [b for b in (blacklist or []) if b]
    # Canonical-tolerant menu lookup: Gemini day keys may use another
    # spelling than the extractor's raw keys.
    _canon_food: dict[str, str] = {}
    for _day_key in (food_data or {}):
        try:
            _canon_food.setdefault(_canon_day(_day_key), str(_day_key))
        except Exception:
            continue

    def _banned(name: object) -> bool:
        try:
            banned, _kw = _is_banned(str(name or ""), list(active_blacklist))
            return bool(banned)
        except Exception:
            # Fail-closed: an uncheckable meal must not be auto-ordered.
            return True

    def _day_ok(day_s: str) -> date | None:
        if _canon_day(day_s) in cancelled:
            return None
        meals = (food_data or {}).get(day_s)
        if not isinstance(meals, dict) or not meals:
            try:
                meals = (food_data or {}).get(_canon_food.get(_canon_day(day_s), day_s))
            except Exception:
                meals = None
        if not isinstance(meals, dict) or not meals:
            return None
        try:
            from .helpers import parse_date as _parse

            _parsed = _parse(day_s)
            day_date = _parsed.date() if isinstance(_parsed, datetime) else _parsed
        except Exception:
            return None
        try:
            if day_date < today:
                return None
        except Exception:
            return None
        if callable(is_open):
            try:
                if not is_open(day_date):
                    return None
            except Exception:
                # Fail-closed: an uncheckable cutoff must skip the day.
                return None
        return day_date

    merged: Dict[str, str] = {}
    for day, mid in (gemini_orders or {}).items():
        day_s, mid_s = str(day), str(mid)
        if _day_ok(day_s) is None:
            continue
        try:
            _menu = (food_data or {}).get(day_s)
            if not isinstance(_menu, dict):
                _menu = (food_data or {}).get(_canon_food.get(_canon_day(day_s), day_s)) or {}
        except Exception:
            _menu = {}
        # The meal must be on THAT day's menu — an id borrowed from
        # another day would be skipped at order time and block the
        # filter fallback for this day.
        if not isinstance(_menu, dict) or mid_s not in _menu:
            continue
        if "&-1&" not in mid_s:
            if _banned(_menu.get(mid_s, "")):
                continue
        # Canonical day key (see filter_picks): raw spellings from Gemini
        # ("1.10.2026") must merge with extractor keys ("01.10.2026").
        merged[_canon_day(day_s)] = mid_s
    for day, mid in filter_picks(
        food_data, blacklist=active_blacklist,
        cancelled_days=cancelled, is_open=is_open, today=today,
    ).items():
        merged.setdefault(str(day), str(mid))
    return merged


def order_window_predicate(
    config_data: dict | None,
    now: datetime | None = None,
) -> Callable[[date], bool] | None:
    """``date -> bool`` cutoff predicate for auto picks (None = unavailable).

    Fail-closed: a day whose deadline cannot be computed reads as closed.
    """
    try:
        from .lunch_cutoff import is_lunch_order_open
        from .school_presets import effective_calendar, resolve_lunch_cutoff

        cfg = config_data if isinstance(config_data, dict) else {}
        cutoff = resolve_lunch_cutoff(cfg)
        free, _, _ = effective_calendar(cfg, clip=False)
    except Exception:
        return None
    moment = now or datetime.now()

    def _is_open(day: date) -> bool:
        try:
            return bool(is_lunch_order_open(day, moment, cutoff, free))
        except Exception:
            return False

    return _is_open


def _planned_deorders(food: dict, ordered: dict, cancelled: set[str],
                      is_open: Callable[[date], bool]) -> Dict[str, str]:
    """Cancellations for planned days off that still hold an ordered lunch.

    Only days whose lunch is ordered on the web, whose menu offers a
    cancel (``&-1&``) control and whose order window is still open.
    """
    from .helpers import parse_date as _parse

    ordered_days = {_canon_day(d) for d, meal in (ordered or {}).items()
                    if meal and "&-1&" not in str(meal)}
    out: Dict[str, str] = {}
    for day, meals in (food or {}).items():
        canon = _canon_day(day)
        if canon not in cancelled or canon not in ordered_days:
            continue
        deorder = next((str(mid) for mid in (meals or {}) if "&-1&" in str(mid)), None)
        if deorder is None:
            continue
        try:
            parsed = _parse(str(day))
            day_date = parsed.date() if isinstance(parsed, datetime) else parsed
            if day_date < date.today() or not is_open(day_date):
                continue
        except Exception:
            continue  # fail-closed: an uncheckable day is left alone
        out[canon] = deorder
    return out


def plan_auto_orders(
    food_data: dict,
    config_data: dict | None,
    blacklist: Iterable[str] | None = None,
    blacklist_broken: bool = False,
    cancelled_days: Iterable[str] | None = None,
    emit: Callable[..., None] | None = None,
    prompt_fallback: str = "",
    ordered: dict | None = None,
    handled: Iterable[str] | None = None,
) -> tuple[Dict[str, str], bool]:
    """Auto-mode lunch picks: Gemini when due, else the blacklist filter.

    Returns ``(orders, used_gemini)``; ``used_gemini`` is True only when a
    real Gemini answer produced picks (callers then stamp
    ``gemini_last_run``). A corrupt blacklist yields no picks at all
    (fail-closed). ``emit(key, **fmt)`` receives progress events.
    ``prompt_fallback`` is used when no ``gemini_prompt`` is configured.

    Auto mode only fills gaps, it never overrides the user:

    * days already ordered on the web (``ordered``) keep their meal;
    * days in ``handled`` (dealt with by an earlier auto run, see
      :func:`update_handled_days`) are left alone, so a lunch the user
      cancelled on the web is not ordered again;
    * ``cancelled_days`` (planned days off) get no meal — and when a meal
      is still ordered there, its cancellation instead.

    Never raises.
    """
    def _emit(key: str, **fmt) -> None:
        if callable(emit):
            try:
                emit(key, **fmt)
            except Exception:
                pass

    food = dict(food_data or {})
    if not food:
        return {}, False
    cfg = config_data if isinstance(config_data, dict) else {}
    cancelled = {_canon_day(d) for d in (cancelled_days or ())}
    is_open = order_window_predicate(cfg)
    if is_open is None:
        # No verifiable deadline means no verifiably orderable day.
        return {}, False
    deorders = _planned_deorders(food, ordered or {}, cancelled, is_open)
    if blacklist_broken:
        _emit("blacklist_broken_log")
        return deorders, False
    skip = set(cancelled) | {_canon_day(d) for d in (handled or ())}
    skip |= {_canon_day(d) for d, meal in (ordered or {}).items() if meal}
    food = {day: meals for day, meals in food.items() if _canon_day(day) not in skip}
    if not food:
        return deorders, False
    words = [w for w in (blacklist or []) if w]
    enabled = bool(cfg.get("gemini_auto_enabled", False))
    if should_run_gemini_auto(enabled, cfg.get("gemini_last_run", ""),
                              cfg.get("gemini_interval_days", GEMINI_INTERVAL_DEFAULT)):
        try:
            from .gemini import recommend_lunches
            from .helpers import decrypt_strict, is_encrypted_flag
            from .i18n import get_language

            key = str(cfg.get("gemini_api_key", "") or "")
            if is_encrypted_flag(cfg.get("gemini_api_key_encrypted")):
                key = decrypt_strict(key) or ""
            key = key.strip()
            model = str(cfg.get("gemini_model", "") or "").strip() or "gemini-3.8-flash"
            if key:
                _html, gemini_orders = recommend_lunches(
                    food,
                    str(cfg.get("gemini_prompt", "") or "").strip() or str(prompt_fallback or ""),
                    key,
                    model=model, language=get_language(), allow_fallback=False,
                )
                if gemini_orders:
                    merged = merge_gemini_with_filter(
                        gemini_orders, food, blacklist=words,
                        cancelled_days=cancelled, is_open=is_open,
                    )
                    if merged:
                        _emit("gemini_auto_used", model=model)
                        return {**merged, **deorders}, True
        except Exception:
            pass
    try:
        picks = filter_picks(food, blacklist=words, cancelled_days=cancelled,
                             is_open=is_open)
    except Exception:
        return deorders, False
    if picks:
        _emit("filter_auto_used")
    return {**picks, **deorders}, False


#: Data-cache key: days an earlier auto run already dealt with.
HANDLED_KEY = "auto_lunch_handled"


def update_handled_days(previous: Iterable[str] | None, ordered: dict | None,
                        placed: Iterable[str] | None,
                        today: date | None = None) -> list[str]:
    """Days auto mode must not touch again, pruned to the last week.

    A day counts as handled once it held an order (placed by auto mode or
    by the user): from then on the user owns it, so cancelling it on the
    web is final. Days that failed (e.g. no money) are not added and get
    retried on the next run.
    """
    from .models import parse_cz_date

    today = today or date.today()
    days = {_canon_day(d) for d in (previous or ())}
    days |= {_canon_day(d) for d, meal in (ordered or {}).items()
             if meal and "&-1&" not in str(meal)}
    days |= {_canon_day(d) for d in (placed or ())}
    kept = []
    for day in days:
        parsed = parse_cz_date(day)
        if parsed is None or (today - parsed).days <= 7:
            kept.append(day)
    return sorted(kept, key=lambda d: (parse_cz_date(d) or date.min, d))
