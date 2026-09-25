"""The one refresh pipeline: fetch, run auto modes, persist the cache.

Used by the UI (refresh button + in-window scheduler) and by the tray's
background scheduler, so both behave identically:

1. Bakaláři: fetch, then pull already-sent web excuses into the local
   history (before any auto-excuse, so nothing is sent twice).
2. Strava: fetch the menu. A failure here is recorded but never discards
   the Bakaláři data fetched in step 1.
3. Auto modes (``auto`` only — ``confirm``/``dry_run`` stay manual):
   excuses, then lunches (planned-skip days never get a lunch).
4. Persist: only good fresh values are merged into the cache. A failed or
   empty phase keeps the previous cached values; timetables merge
   day-granular so an unrendered week never deletes known days.

Progress is reported through ``emit(key, **fmt)`` with message keys the
UI translates (see ``flet_ui/strings.py``); the tray passes no emitter.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Any, Callable, Iterable, Iterator

from .error_report import UserError

Emit = Callable[..., None]

SCOPES = ("all", "bakalari", "strava")

#: Lock file shared by every process that drives the school sites (the
#: tray and the window are separate processes, each with a scheduler).
SESSION_LOCK_FILE = "./session.lock"


@contextmanager
def session_lock(timeout_s: float = 0.0) -> Iterator[bool]:
    """Serializes whole refreshes and order submits across processes.

    Yields True when held, False when another refresh or submit (this or
    another process) kept it for ``timeout_s`` — callers must then skip,
    not run in parallel: two runs would both log in, both auto-send and
    race each other's cache writes. The OS releases the lock when a
    holder dies, so a killed process never blocks the next run.
    """
    from .helpers import InterProcessLock, _resolve_path

    lock = InterProcessLock(_resolve_path(SESSION_LOCK_FILE))
    held = lock.acquire(timeout_s)
    try:
        yield held
    finally:
        if held:
            lock.release()


@dataclass
class RefreshResult:
    scope: str = "all"
    saved: dict = field(default_factory=dict)
    bakalari_fetched: bool = False
    strava_fetched: bool = False
    subjects: int = 0
    menu_days: int = 0
    excuses_sent: int = 0
    excuses_failed: int = 0
    lunches_ordered: int = 0
    #: True when ``automation_paused`` kept an ``auto`` mode from running.
    automation_paused: bool = False
    auto_ordered_days: set = field(default_factory=set)
    used_gemini: bool = False
    #: True when Strava refused auto orders for lack of money.
    low_balance: bool = False
    #: Days auto mode could not order because the account ran out of money.
    unfunded_days: list = field(default_factory=list)
    #: (phase, exception) for phases that failed without aborting the run.
    errors: list = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.errors

    @property
    def automation_errors(self) -> list:
        """Failures of the auto-send / auto-order phases (fail loudly on these)."""
        return [(phase, exc) for phase, exc in self.errors
                if phase in ("auto_excuse", "auto_lunch")]

    @property
    def only_low_balance(self) -> bool:
        """True when the only automation failure is an empty Strava account.

        That is not a bug and not worth a bug-report popup or an early
        retry every 5 minutes: callers warn (at most once a day) instead.
        """
        auto = self.automation_errors
        return bool(auto) and all(isinstance(exc, LowBalanceError) for _p, exc in auto)


class AutomationError(UserError):
    """An ``auto`` phase did not do what it was supposed to.

    A :class:`UserError`: the UI shows its message as-is (no bug-report
    traceback) — the reason per item is in the log above it.
    """


class LowBalanceError(AutomationError):
    """Strava refused lunch orders: not enough money on the account."""


#: Data-cache keys of the "not enough money on Strava" warning: the last
#: detection (``{"at": iso, "days": [...]}`` or None once orders go
#: through again) and the day the user was last notified about it.
LOW_BALANCE_KEY = "strava_low_balance"
LOW_BALANCE_NOTIFIED_KEY = "strava_low_balance_notified"


def record_low_balance(days: Iterable[str] | None) -> None:
    """Remembers (``days``) or clears (None) the low-balance warning. Never raises."""
    from .cache import save_data_cache

    try:
        if days is None:
            save_data_cache({LOW_BALANCE_KEY: None})
        else:
            save_data_cache({LOW_BALANCE_KEY: {
                "at": datetime.now().isoformat(timespec="seconds"),
                "days": sorted({str(d) for d in days}),
            }})
    except Exception:
        pass


def claim_low_balance_notice(today=None) -> bool:
    """True at most once per day: whether to notify about an empty account.

    The scheduler retries every interval, and one toast per run would nag
    all day about the same unpaid lunches. Shared by the tray and the
    window through the data cache. Never raises.
    """
    from datetime import date as _date

    from .cache import load_data_cache, save_data_cache

    stamp = (today or _date.today()).isoformat()
    try:
        if load_data_cache().get(LOW_BALANCE_NOTIFIED_KEY) == stamp:
            return False
        save_data_cache({LOW_BALANCE_NOTIFIED_KEY: stamp})
    except Exception:
        pass
    return True


def automation_paused(config_data: dict | None) -> bool:
    """True when the user paused all automatic sending and ordering."""
    value = (config_data or {}).get("automation_paused", False)
    return value is True or str(value).strip().lower() in ("true", "1", "yes")


def _first_line(exc: BaseException) -> str:
    text = str(exc).strip()
    return text.splitlines()[0][:200] if text else type(exc).__name__


def _bakalari_payload(app: Any) -> dict:
    """Good fresh Bakaláři values only; failed parts are left out."""
    client = getattr(app, "bakalari_client", None)
    payload: dict = {"timetable": dict(app.timetableData or {})}
    absence = app.absencePercentages or {}
    if absence or not getattr(client, "absence_error", ""):
        payload["absence"] = dict(absence)
    grades = app.grades or {}
    if grades or not getattr(client, "grades_error", ""):
        payload["grades"] = dict(grades)
    substitutions = getattr(client, "substitutions", None)
    if isinstance(substitutions, list):
        payload["substitutions"] = substitutions
    details = getattr(app, "absenceDetails", None)
    if isinstance(details, dict) and details:
        payload["absence_details"] = details
    directory = getattr(app, "subjectDirectory", None)
    if isinstance(directory, dict) and directory:
        payload["subject_directory"] = directory
    try:
        from .schedule import baseline_to_dict

        baseline = baseline_to_dict(app.stableBaseline)
    except Exception:
        baseline = {}
    if baseline:
        payload["stable_baseline"] = baseline
        payload["stable_baseline_source"] = (
            "scraped" if getattr(app, "stable_complete", False) else "learned")
    return payload


def _go_back_weeks(app: Any, config_data: dict) -> int:
    try:
        return max(0, int(getattr(app, "go_back_weeks", None)
                          or config_data.get("go_back_weeks", 4)))
    except (TypeError, ValueError):
        return 4


#: Data-cache key of the timetable history: which past weeks of the running
#: school year were fetched once ({"school_year_start": iso, "weeks": [iso
#: Mondays]}). Those weeks are history — never re-fetched, never excused.
TIMETABLE_HISTORY_KEY = "timetable_history"

#: Data-cache key: first day of the range Komens → Odeslané listed on the
#: last sync (ISO date) — bounds the excuse window in the UI.
SENT_EXCUSES_FROM_KEY = "sent_excuses_from"


def _school_year_start(today: date) -> date:
    from .planner import school_year_terms

    return school_year_terms(today)[0][1]


def _history_done_weeks(year_start: date) -> set:
    """Mondays already in the timetable history of this school year."""
    from .cache import load_data_cache

    try:
        stored = load_data_cache().get(TIMETABLE_HISTORY_KEY) or {}
    except Exception:
        stored = {}
    if not isinstance(stored, dict) or stored.get("school_year_start") != year_start.isoformat():
        return set()  # first run, or a new school year
    done = set()
    for raw in stored.get("weeks") or []:
        try:
            done.add(date.fromisoformat(str(raw)))
        except ValueError:
            continue
    return done


def _missing_history_weeks(app: Any, cfg: dict, today: date, done: set) -> list:
    """Past school-year Mondays neither in the history nor in the regular window."""
    from .bakalari_common import week_offsets

    year_start = _school_year_start(today)
    this_monday = today - timedelta(days=today.weekday())
    forward = getattr(app, "go_forward_weeks", None)
    try:
        forward = int(cfg.get("go_forward_weeks", 1) if forward is None else forward)
    except (TypeError, ValueError):
        forward = 1
    regular = {this_monday + timedelta(weeks=off)
               for off in week_offsets(_go_back_weeks(app, cfg), forward)}
    monday = year_start - timedelta(days=year_start.weekday())
    missing = []
    while monday < this_monday:
        if monday not in regular and monday not in done:
            missing.append(monday)
        monday += timedelta(weeks=1)
    return missing


def _record_history_weeks(app: Any, fresh: dict, today: date, done: set) -> None:
    """Adds the past weeks this run loaded to the stored timetable history."""
    client = getattr(app, "bakalari_client", None)
    year_start = _school_year_start(today)
    first_monday = year_start - timedelta(days=year_start.weekday())
    this_monday = today - timedelta(days=today.weekday())
    loaded = {m for m in (getattr(client, "timetable_loaded_weeks", None) or ())
              if isinstance(m, date) and first_monday <= m < this_monday}
    fresh[TIMETABLE_HISTORY_KEY] = {
        "school_year_start": year_start.isoformat(),
        "weeks": sorted(m.isoformat() for m in done | loaded),
    }


def run_refresh(
    app: Any,
    config_data: dict | None,
    scope: str = "all",
    cancelled_lunch_days: Iterable[str] | None = None,
    is_cancelled: Callable[[], bool] | None = None,
    emit: Emit | None = None,
    lunch_prompt: str = "",
    now: datetime | None = None,
) -> RefreshResult:
    """Runs one refresh on an already constructed ``Strakalari`` app.

    Raises on a Bakaláři failure (nothing is saved then) and
    ``InterruptedError`` on cancel. Strava and auto-mode failures are
    recorded in ``result.errors`` / the log and never lose fetched data.
    """
    from .config import has_valid_credentials

    cfg = config_data if isinstance(config_data, dict) else {}
    scope = scope if scope in SCOPES else "all"
    started = now or datetime.now()
    result = RefreshResult(scope=scope)

    def _emit(key: str, **fmt) -> None:
        if callable(emit):
            try:
                emit(key, **fmt)
            except Exception:
                pass

    def _check_cancel() -> None:
        if callable(is_cancelled) and is_cancelled():
            raise InterruptedError("cancelled")

    has_bak, has_strava = has_valid_credentials(cfg)
    fresh: dict = {}
    try:
        _fetch_phases(app, scope, has_bak, has_strava, fresh, result, _emit, _check_cancel)
        _check_cancel()
        _auto_phases(app, cfg, fresh, result, _emit, is_cancelled,
                     cancelled_lunch_days, lunch_prompt)
    except InterruptedError:
        # Cancelled after (part of) the fetch: keep what already arrived
        # (and any auto order that went through) instead of dropping it.
        # No global stamp — the run was not complete.
        if fresh:
            _emit("saving_cache")
            _persist(app, cfg, fresh, started)
        raise

    # -- 4. Persist -------------------------------------------------------
    _emit("saving_cache")
    fetched_any = result.bakalari_fetched or result.strava_fetched
    fetch_errors = [e for e in result.errors if e not in result.automation_errors]
    if scope == "all" and fetched_any and not fetch_errors:
        # The global stamp only moves on complete full refreshes, so a
        # partial or failed run never makes stale data look fresh.
        fresh["last_updated"] = started.strftime("%d.%m.%Y %H:%M:%S")
    _persist(app, cfg, fresh, started)
    result.saved = fresh
    return result


def _persist(app: Any, cfg: dict, fresh: dict, started: datetime) -> None:
    """Merges ``fresh`` into the data cache (timetables day-granular)."""
    from .cache import load_data_cache, merge_timetable_days, save_data_cache

    if isinstance(fresh.get("timetable"), dict):
        try:
            previous = load_data_cache().get("timetable")
        except Exception:
            previous = None
        window_start = min(
            started.date() - timedelta(days=_go_back_weeks(app, cfg) * 7 + 7),
            # The running school year stays: it is the timetable history.
            _school_year_start(started.date()))
        fresh["timetable"] = merge_timetable_days(previous, fresh["timetable"], window_start)
    if fresh:
        save_data_cache(fresh)


def _fetch_phases(app, scope, has_bak, has_strava, fresh, result, _emit, _check_cancel) -> None:
    # -- 1. Bakaláři ------------------------------------------------------
    if scope in ("all", "bakalari"):
        if not has_bak:
            _emit("bakalari_skipped_log")
        else:
            _check_cancel()
            today = datetime.now().date()
            year_start = _school_year_start(today)
            done = _history_done_weeks(year_start)
            missing = _missing_history_weeks(app, getattr(app, "config_data", None) or {},
                                             today, done)
            client = getattr(app, "bakalari_client", None)
            if client is not None:
                client.history_weeks = missing
            if missing:
                _emit("timetable_history_log", n=len(missing))
            _emit("fetching_bakalari")
            app.fetchBakalariData()
            payload = _bakalari_payload(app)
            _emit("baseline_log",
                  slots=len(getattr(app, "stableBaseline", None) or {}),
                  changes=len(getattr(app, "weekChanges", None) or []))
            if payload.get("timetable") or payload.get("absence"):
                fresh.update(payload)
                result.bakalari_fetched = True
                result.subjects = len(payload.get("absence") or {})
                _record_history_weeks(app, fresh, today, done)
                _emit("bakalari_done_log", n=result.subjects)
            else:
                _emit("refresh_empty_warn")
            try:
                app.sync_web_excuses_to_history()
            except InterruptedError:
                raise
            except Exception as exc:
                _emit("excuse_sync_failed", err=_first_line(exc))
            outbox_from = getattr(client, "sentExcuses_from", None)
            if isinstance(outbox_from, date):
                fresh[SENT_EXCUSES_FROM_KEY] = outbox_from.isoformat()

    # -- 2. Strava --------------------------------------------------------
    if scope in ("all", "strava"):
        if not getattr(app, "strava_enable", False):
            _emit("strava_disabled_skip")
        elif not has_strava:
            _emit("strava_skipped_log")
        else:
            _check_cancel()
            _emit("fetching_menu")
            try:
                app.fetchStravaData()
            except InterruptedError:
                raise
            except Exception as exc:
                result.errors.append(("strava", exc))
                _emit("strava_fetch_failed", err=_first_line(exc))
            else:
                food = dict(app.foodDict or {})
                if food:
                    fresh["strava_meals"] = food
                    fresh["strava_ordered"] = dict(app.orderedDict or {})
                    result.strava_fetched = True
                    result.menu_days = len(food)
                    _emit("strava_done_log", n=len(food))
                else:
                    _emit("strava_menu_empty")


def _auto_phases(app, cfg, fresh, result, _emit, is_cancelled,
                 cancelled_lunch_days, lunch_prompt) -> None:
    from .i18n import t

    # -- 3. Auto modes ----------------------------------------------------
    paused = automation_paused(cfg)
    wants_excuse = result.bakalari_fetched and getattr(app, "excuse_mode", "") == "auto"
    wants_lunch = result.strava_fetched and getattr(app, "strava_order_mode", "") == "auto"
    if paused and (wants_excuse or wants_lunch):
        result.automation_paused = True
        _emit("automation_paused_log")
        wants_excuse = wants_lunch = False

    if wants_excuse:
        _emit("auto_excuse_log")
        try:
            app.cancel_callback = is_cancelled
            result.excuses_sent = int(app.excuseAbsence() or 0)
            result.excuses_failed = int(getattr(app, "last_excuse_failures", 0) or 0)
            if result.excuses_sent:
                _emit("auto_excuses_sent", n=result.excuses_sent)
            if result.excuses_failed:
                raise AutomationError(t("auto_excuses_failed", n=result.excuses_failed))
        except InterruptedError:
            raise
        except Exception as exc:
            result.errors.append(("auto_excuse", exc))
            _emit("auto_excuse_failed", err=_first_line(exc))

    if wants_lunch:
        _auto_lunch(app, cfg, fresh, result, _emit, cancelled_lunch_days, lunch_prompt)


def _auto_lunch(app, cfg, fresh, result, _emit, cancelled_lunch_days, lunch_prompt) -> None:
    """Auto-mode lunch orders (fills gaps only, see ``plan_auto_orders``)."""
    from .cache import load_data_cache
    from .i18n import t
    from .lunch_auto import HANDLED_KEY, plan_auto_orders, update_handled_days
    from .planned_skips import planned_lunch_days

    _emit("auto_lunch_log")
    client = app.strava_client
    try:
        handled = load_data_cache().get(HANDLED_KEY) or []
    except Exception:
        handled = []
    ordered_before = dict(getattr(client, "orderedDict", None) or {})
    placed: set = set()
    try:
        cancelled = planned_lunch_days(cfg) | set(cancelled_lunch_days or ())
        orders, result.used_gemini = plan_auto_orders(
            app.foodDict, cfg,
            blacklist=list(getattr(client, "strava_blacklist_json", None) or []),
            blacklist_broken=bool(getattr(client, "blacklist_broken", False)),
            cancelled_days=cancelled, emit=_emit, prompt_fallback=lunch_prompt,
            ordered=ordered_before, handled=handled,
        )
        if not orders:
            _emit("auto_lunch_none")
        elif app.stravaOrderSelected(dict(orders), source="auto"):
            placed = {str(d) for d in orders}
            fresh["strava_ordered"] = dict(client.orderedDict or {})
            fresh[LOW_BALANCE_KEY] = None  # orders go through again
            result.auto_ordered_days = set(placed)
            result.lunches_ordered = len(orders)
            _emit("auto_lunch_sent", n=len(orders))
        else:
            placed = {str(d) for d in (getattr(app, "last_ordered_days", None) or ())}
            if placed:
                # Partial: what went through is web truth all the same.
                fresh["strava_ordered"] = dict(client.orderedDict or {})
                result.auto_ordered_days = set(placed)
                result.lunches_ordered = len(placed)
            unfunded = list(getattr(app, "last_unfunded_days", None) or [])
            if getattr(app, "last_order_low_balance", False) and unfunded:
                result.low_balance = True
                result.unfunded_days = unfunded
                fresh[LOW_BALANCE_KEY] = {
                    "at": datetime.now().isoformat(timespec="seconds"),
                    "days": sorted(set(unfunded)),
                }
                if len(orders) - len(placed) - len(unfunded) <= 0:
                    # Nothing else went wrong: an empty account, not a bug.
                    raise LowBalanceError(t("strava_low_balance", n=len(unfunded)))
            raise AutomationError(t("auto_orders_failed", n=len(orders) - len(placed),
                                    total=len(orders)))
    except InterruptedError:
        raise
    except Exception as exc:
        result.errors.append(("auto_lunch", exc))
        _emit("auto_lunch_failed", err=_first_line(exc))
    finally:
        if not result.low_balance:
            # Nothing was refused for lack of money this run (topped up, or
            # the days were ordered elsewhere): the warning is over.
            fresh[LOW_BALANCE_KEY] = None
        try:
            fresh[HANDLED_KEY] = update_handled_days(
                handled, getattr(client, "orderedDict", None) or ordered_before, placed)
        except Exception:
            pass
