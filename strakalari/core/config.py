import json
import os
from typing import Any, Dict

from .helpers import _resolve_path, atomic_write_json, encrypt, example_path_for, quarantine_corrupt_file


def _looks_like_placeholder(value: str) -> bool:
    """True for template/example values that must not count as configured."""
    low = str(value or "").lower()
    return any(bit in low for bit in (
        "vas_", "vase_", "cislo_", "vas-bakalari", "vas_strava", "vase_heslo",
        "example", "placeholder", "your_",
    ))


def _is_demo_history_item(item: object) -> bool:
    """True for example-template history rows that must not seed real data.

    Drops non-dict rows, rows without ``type``/``starting_day``, and rows
    carrying placeholder text (``VAS_…``, ``example``, …). Applied only
    to the ``.example.json`` fallback, never to the real history file.
    (Day-range types carry ``ending_day`` too, but single-lesson types
    legitimately do not — so it is not required here.)
    """
    if not isinstance(item, dict):
        return True
    if not item.get("type") or not item.get("starting_day"):
        return True
    try:
        return any(
            _looks_like_placeholder(value)
            for value in item.values()
            if isinstance(value, str)
        )
    except Exception:
        return False


def has_valid_credentials(cfg_data: dict) -> tuple[bool, bool]:
    """Checks configured credentials without any GUI dependency.

    Returns (has_bakalari, has_strava). Used by the GUI's first-run
    detection and unit-tested here at the core level.
    """
    bak_user = str(cfg_data.get("bakalari_username", "") or "")
    bak_url = str(cfg_data.get("bakalari_url", "") or "")
    strava_user = str(cfg_data.get("strava_username", "") or cfg_data.get("strava_user", "") or "")
    strava_id = str(cfg_data.get("strava_canteen_id", "") or cfg_data.get("strava_id", "") or "")

    has_bakalari = bool(
        bak_user and bak_url
        and not _looks_like_placeholder(bak_user)
        and not _looks_like_placeholder(bak_url)
    )
    has_strava = bool(
        strava_user and strava_id
        and not _looks_like_placeholder(strava_user)
        and not _looks_like_placeholder(strava_id)
    )
    return has_bakalari, has_strava


# ---------------------------------------------------------------------------
# Canonical config schema (single names only — no aliases, no migration).
EXCUSE_MODES = ("auto", "confirm", "dry_run")

CANONICAL_DEFAULTS: Dict[str, Any] = {
    "bakalari_url": "",
    "bakalari_username": "",
    "bakalari_password": "",
    "bakalari_password_encrypted": False,
    "strava_url": "https://strava.cz",
    "strava_canteen_id": "",
    "strava_username": "",
    "strava_password": "",
    "strava_password_encrypted": False,
    "use_strava": True,
    "log_file": "./log.txt",
    "strava_blacklist": "./strava_blacklist.json",
    "already_excused_file": "./already_excused_lessons.json",
    "theme": "dark",
    "absence_warn_pct": 15.0,
    "absence_critical_pct": 25.0,
    "absence_plan_reserve_pct": 10.0,
    "cache_ttl_hours": 24,
    "page_load_timeout_s": 60.0,
    "element_wait_s": 30.0,
    "week_switch_delay_s": 2.5,
    "gemini_model": "gemini-3.8-flash",
    "gemini_api_key": "",
    "gemini_api_key_encrypted": False,
    "gemini_auto_enabled": False,
    "gemini_prompt": "",
    "gemini_interval_days": 2,
    "gemini_last_run": "",
    "late_income_excuses": [
        "Dobrý den, omluvte prosím pozdní příchod z důvodu dopravních komplikací.\nDěkuji\n",
        "Dobrý den, omluvte prosím pozdní příchod z důvodu návštěvy lékaře.\nDěkuji\n",
    ],
    "left_soon_excuses": [
        "Dobrý den, omluvte prosím předčasný odchod z rodinných důvodů.\nDěkuji\n",
        "Dobrý den, omluvte prosím předčasný odchod z důvodu návštěvy lékaře.\nDěkuji\n",
    ],
    "short_absence_excuses": [
        "Dobrý den, omluvte prosím absenci z rodinných důvodů.\nDěkuji\n",
        "Dobrý den, omluvte prosím absenci z osobních důvodů.\nDěkuji\n",
    ],
    "long_absence_excuses": [
        "Dobrý den, omluvte prosím absenci z důvodu nemoci.\nDěkuji\n",
        "Dobrý den, omluvte prosím absenci z rodinných důvodů.\nDěkuji\n",
    ],
    "your_signature": "",
    "go_back_weeks": 4,
    "go_forward_weeks": 1,
    "excuse_delay_days": 2,
    "sent_excuses_limit": 100,
    "maximize_window": False,
    "hide_window": True,
    "minimize_to_tray": True,
    "language": "cs",
    "excuse_mode": "confirm",
    "default_excuse_selection": "first",
    "strava_order_mode": "confirm",
    "automation_paused": False,
    "disclaimer_accepted": False,
    "lunch_order_cutoff_time": "",
    "subject_limits": {},
    # No school is assumed: the wizard (or Settings) picks a preset.
    "school_preset_id": "custom",
    "user_free_days": [],
    "forced_school_days": [],
    "sem1_close": "",
    "sem2_close": "",
    "holidays": [],
    "school_year_end": "",
    "check_interval_minutes": 60,
    "notifications": {},
    "planned_skips": [],
    "planner_target_days": 0,
    # Interactive tutorials: global switch + ids of finished/skipped tours.
    "tutorials_enabled": True,
    "tutorials_done": [],
    "ignored_excuses": [],
    "timetable_view": "table",
    "compact_density": False,
    # Marks view: "auto" detects 1–5 vs percent per subject; a per-subject
    # choice ({subject: "grade" | "percent"}) beats the global one.
    "marks_scale": "auto",
    "marks_subject_scales": {},
    # Top of grades 2–5 in percent (a boundary is the worse grade). Empty =
    # the school preset's table, else the built-in 90/75/50/30.
    "marks_percent_bands": [],
    "marks_sort": "name",
    # Update notifications: "stable" (full releases only) or "beta"
    # (pre-releases too, whichever is newest). ConfigManager replaces
    # this with the running build's kind (beta build -> "beta").
    "update_channel": "stable",
}


def validate_config(data: Dict[str, Any]) -> list:
    """Returns human-readable config problems (empty = OK)."""
    problems: list = []
    bak_user = str(data.get("bakalari_username", "") or "")
    bak_url = str(data.get("bakalari_url", "") or "")
    if (bak_user or bak_url) and not (bak_user and bak_url):
        problems.append("Bakaláři: username and URL must both be set.")
    if bak_url and "://" not in bak_url and "." not in bak_url:
        problems.append(f"Bakaláři URL looks invalid: {bak_url!r}.")
    if data.get("use_strava", True):
        # Legacy read-aliases (strava_user / strava_id) count: the runtime
        # (StravaClient, Strakalari) and has_valid_credentials() honor
        # them, so the validator must not reject them.
        _strava_user = str(data.get("strava_username", "") or data.get("strava_user", "") or "")
        _strava_id = str(data.get("strava_canteen_id", "") or data.get("strava_id", "") or "")
        if not _strava_user:
            problems.append("Strava: username is empty (integration enabled).")
        if not _strava_id:
            problems.append("Strava: canteen ID is empty (integration enabled).")
    for mode_key in ("excuse_mode", "strava_order_mode"):
        if str(data.get(mode_key, "confirm")).lower() not in EXCUSE_MODES:
            problems.append(
                f"'{mode_key}' must be one of {list(EXCUSE_MODES)}, "
                f"got {data.get(mode_key)!r}."
            )
    try:
        from .lunch_cutoff import is_valid_cutoff_time

        if not is_valid_cutoff_time(data.get("lunch_order_cutoff_time", "")):
            problems.append(
                "'lunch_order_cutoff_time' must be empty (school preset, else 12:00) or 'HH:MM' ('HH.MM' accepted too)."
            )
    except Exception:
        if str(data.get("lunch_order_cutoff_time", "") or "").strip():
            problems.append(
                "'lunch_order_cutoff_time' could not be validated (validator unavailable)."
            )
    if str(data.get("timetable_view", "table") or "table") not in ("table", "list"):
        problems.append(f"'timetable_view' must be 'table' or 'list', got {data.get('timetable_view')!r}.")
    if str(data.get("marks_scale", "auto") or "auto") not in ("auto", "grade", "percent"):
        problems.append(
            f"'marks_scale' must be 'auto', 'grade' or 'percent', got {data.get('marks_scale')!r}."
        )
    _subject_scales = data.get("marks_subject_scales", {})
    if not isinstance(_subject_scales, dict) or any(
        v not in ("grade", "percent") for v in _subject_scales.values()
    ):
        problems.append("'marks_subject_scales' must map subjects to 'grade' or 'percent'.")
    from .grades import bands_valid

    _bands = data.get("marks_percent_bands", [])
    if _bands not in (None, []) and not bands_valid(_bands):
        problems.append(
            "'marks_percent_bands' must be empty or four decreasing percentages within (0, 100]."
        )
    if str(data.get("marks_sort", "name") or "name") not in ("name", "average", "recent"):
        problems.append(f"'marks_sort' must be 'name', 'average' or 'recent', got {data.get('marks_sort')!r}.")
    try:
        warn = float(data.get("absence_warn_pct", 15))
        crit = float(data.get("absence_critical_pct", 25))
        if not (0 < warn < crit <= 100):
            problems.append("Absence thresholds must satisfy 0 < warn < critical <= 100.")
    except (TypeError, ValueError):
        problems.append("Absence thresholds must be numbers.")
    try:
        reserve = float(data.get("absence_plan_reserve_pct", 10))
        if not (0 <= reserve < 100):
            problems.append("'absence_plan_reserve_pct' must be within [0, 100).")
    except (TypeError, ValueError):
        problems.append("'absence_plan_reserve_pct' must be a number.")
    try:
        target_days = int(data.get("planner_target_days", 0) or 0)
        if not (0 <= target_days <= 200):
            problems.append("'planner_target_days' must be within [0, 200].")
    except (TypeError, ValueError):
        problems.append("'planner_target_days' must be a whole number.")
    if not isinstance(data.get("tutorials_done", []), list):
        problems.append("'tutorials_done' must be a list of tutorial ids.")
    for timeout_key, minimum, maximum in (
        ("page_load_timeout_s", 5.0, 180.0),
        ("element_wait_s", 2.0, 120.0),
        ("week_switch_delay_s", 0.0, 30.0),
    ):
        try:
            timeout_val = float(data.get(timeout_key, minimum))
        except (TypeError, ValueError):
            problems.append(f"'{timeout_key}' must be a number.")
            continue
        if not (minimum <= timeout_val <= maximum):
            problems.append(
                f"'{timeout_key}' must be between {minimum} and {maximum} seconds."
            )
    if str(data.get("update_channel", "stable") or "stable").lower() not in ("stable", "beta"):
        problems.append(
            f"'update_channel' must be 'stable' or 'beta', got {data.get('update_channel')!r}."
        )
    if str(data.get("theme", "dark")).lower() not in ("dark", "light"):
        problems.append("Theme must be 'dark' or 'light'.")
    if str(data.get("language", "cs")).lower() not in ("cs", "en"):
        problems.append(f"'language' must be 'cs' or 'en', got {data.get('language')!r}.")
    if not str(data.get("gemini_model", "gemini-3.8-flash") or "").strip():
        problems.append("'gemini_model' must not be empty.")
    try:
        _g_interval = int(float(str(data.get("gemini_interval_days", 2)).replace(",", ".")))
    except (TypeError, ValueError):
        problems.append("'gemini_interval_days' must be a whole number.")
    else:
        if not (1 <= _g_interval <= 30):
            problems.append("'gemini_interval_days' must be within [1, 30].")
    try:
        delay = int(data.get("excuse_delay_days", 2))
        if delay < 0:
            problems.append("'excuse_delay_days' must be >= 0.")
    except (TypeError, ValueError):
        problems.append("'excuse_delay_days' must be a whole number.")
    for weeks_key, minimum, maximum in (
        ("go_back_weeks", 0, 52),
        ("go_forward_weeks", 0, 8),
    ):
        try:
            weeks = int(data.get(weeks_key, 0))
        except (TypeError, ValueError):
            problems.append(f"'{weeks_key}' must be a whole number.")
            continue
        if not (minimum <= weeks <= maximum):
            problems.append(f"'{weeks_key}' must be within [{minimum}, {maximum}] (runtime clamps to it).")
    if str(data.get("default_excuse_selection", "first")).lower() not in ("first", "random"):
        problems.append(
            f"'default_excuse_selection' must be 'first' or 'random', "
            f"got {data.get('default_excuse_selection')!r}."
        )
    try:
        interval = float(data.get("check_interval_minutes", 60))
        if interval < 1:
            problems.append("'check_interval_minutes' must be >= 1.")
    except (TypeError, ValueError):
        problems.append("'check_interval_minutes' must be a number.")
    limits = data.get("subject_limits", {})
    if not isinstance(limits, dict):
        problems.append("'subject_limits' must be an object mapping subject -> percent.")
    else:
        for subject, pct in limits.items():
            try:
                value = float(pct)
            except (TypeError, ValueError):
                problems.append(f"Subject limit for {subject!r} must be a number.")
                break
            if not (0 < value <= 100):
                problems.append(f"Subject limit for {subject!r} must be within (0, 100].")
                break
    return problems


class ConfigManager:
    """
    Manages loading, saving, and updating Strakalari configuration settings.
    Handles password obfuscation, defaults fallback, and path resolution automatically.
    """

    def __init__(self, config_path: str = "./config.json", encoding: str = "utf-8"):
        self.encoding = encoding
        self.config_path = _resolve_path(config_path)
        self.data: Dict[str, Any] = {}
        self.load()

    def _get_default_config(self) -> Dict[str, Any]:
        """Returns a fresh copy of the built-in canonical defaults.

        Deliberately never reads ``config.example.json``: its placeholder
        demo values must not leak into real configs.
        """
        import copy

        defaults = copy.deepcopy(CANONICAL_DEFAULTS)
        try:
            from .update import default_channel

            # Written to disk by the first save, so the channel sticks to
            # the kind of build the user first installed.
            defaults["update_channel"] = default_channel()
        except Exception:
            pass
        return defaults

    def load(self) -> Dict[str, Any]:
        """Loads configuration from JSON file and merges on top of defaults."""
        self._load_inner()
        self._remember_baseline()
        return self.data

    def _remember_baseline(self) -> None:
        """Snapshot of what is on disk, so save() writes only real edits."""
        import copy

        self._baseline = copy.deepcopy(self.data)
        self._touched: set = set()

    def _load_inner(self) -> Dict[str, Any]:
        defaults = self._get_default_config()
        if not os.path.exists(self.config_path):
            self.data = defaults
            return self.data

        try:
            with open(self.config_path, "r", encoding=self.encoding) as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    # Explicit nulls never override defaults: a hand-edited
                    # `"key": null` falls back to the canonical default
                    # instead of poisoning the runtime with None.
                    for key, value in loaded.items():
                        if value is not None:
                            defaults[key] = value
                else:
                    print(f"Warning: Config '{self.config_path}' does not contain a JSON object. Using fallback defaults.")
                self.data = defaults
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            # Quarantine the corrupt file BEFORE falling back: a later
            # save() would otherwise atomically overwrite the original
            # bytes and destroy credentials/config for good.
            backup = quarantine_corrupt_file(self.config_path)
            hint = f" Preserved at {backup}." if backup else ""
            print(f"Warning: Failed to load '{self.config_path}': {e}. Using fallback defaults.{hint}")
            self.data = defaults
        except OSError as e:
            # Busy or locked (antivirus, the other process mid-write), not
            # corrupt: keep the file untouched and refuse to save over it
            # until a later load succeeds.
            print(f"Warning: Could not read '{self.config_path}' right now: {e}. Using defaults, not saving.")
            self.data = defaults
            self._unreadable = True
            return self.data
        self._unreadable = False

        # No stored-data migration: the project is pre-release with a single
        # user, so legacy keys are simply ignored (defaults win). Unknown
        # keys stay on disk untouched but are never read.

        return self.data

    def reload(self) -> Dict[str, Any]:
        """Reloads configuration from disk."""
        return self.load()

    def save(self) -> None:
        """Saves current configuration to JSON file (atomically).

        Refuses when the file existed but could not be read at load time —
        writing then would replace the user's settings with defaults.
        """
        if getattr(self, "_unreadable", False) and os.path.exists(self.config_path):
            raise RuntimeError(
                f"Config '{self.config_path}' could not be read at startup; "
                "not overwriting it. Restart the app.")
        from .helpers import InterProcessLock

        # The tray and the window are separate processes, each with its
        # own ConfigManager. Writing our whole (possibly hours old) copy
        # would silently undo whatever the other one saved meanwhile, so
        # only the keys edited here are applied on top of the file as it
        # is now — under a lock so two saves cannot interleave.
        lock = InterProcessLock(self.config_path + ".lock")
        if not lock.acquire(timeout_s=10.0):
            # Writing unlocked could interleave with the other process's
            # save and silently drop its edits: fail loudly instead (the
            # edits stay in memory and go out with the next save).
            raise RuntimeError(
                f"Config '{self.config_path}' is being saved by another "
                "process; not saved — try again.")
        try:
            merged = self._merge_onto_disk()
            try:
                atomic_write_json(self.config_path, merged, encoding=self.encoding)
            except OSError as e:
                raise RuntimeError(f"Could not save config to '{self.config_path}': {e}") from e
        finally:
            lock.release()
        if merged is not self.data:
            # In place: other objects (Strakalari.config_data) share it.
            self.data.clear()
            self.data.update(merged)
        self._remember_baseline()

    def _merge_onto_disk(self) -> Dict[str, Any]:
        """Current file content with this instance's edits applied.

        Falls back to this instance's full data when the file is missing
        or unreadable (nothing on disk worth preserving then).
        """
        baseline = getattr(self, "_baseline", None)
        if baseline is None or not os.path.exists(self.config_path):
            return self.data
        try:
            with open(self.config_path, "r", encoding=self.encoding) as f:
                on_disk = json.load(f)
        except (OSError, ValueError):
            return self.data
        if not isinstance(on_disk, dict):
            return self.data
        merged = self._get_default_config()
        merged.update({k: v for k, v in on_disk.items() if v is not None})
        touched = getattr(self, "_touched", set())
        for key, value in self.data.items():
            if key in touched or key not in baseline or baseline[key] != value:
                merged[key] = value
        for key in baseline:
            if key not in self.data:
                merged.pop(key, None)
        return merged

    def get(self, key: str, default: Any = None) -> Any:
        """Retrieves a configuration value by key."""
        return self.data.get(key, default)

    def set(self, key: str, value: Any, auto_encrypt: bool = True) -> None:
        """Sets a configuration value, automatically encrypting passwords if appropriate."""
        if key not in CANONICAL_DEFAULTS:
            # Warn about typos, but still store (keys of newer versions).
            print(f"Warning: unknown config key {key!r} — storing anyway.")
        if not hasattr(self, "_touched"):
            self._touched = set()
        self._touched.add(key)
        if auto_encrypt and key in ("strava_password", "bakalari_password", "gemini_api_key"):
            self._touched.add(f"{key}_encrypted")
        if key in ("excuse_mode", "strava_order_mode"):
            normalized = str(value).lower()
            if normalized not in EXCUSE_MODES:
                raise ValueError(f"'{key}' must be one of {list(EXCUSE_MODES)}, got {value!r}.")
            self.data[key] = normalized
            return
        if auto_encrypt and key in ("strava_password", "bakalari_password", "gemini_api_key"):
            # Avoid re-encrypting if value is already the encrypted string in data
            if self.data.get(f"{key}_encrypted", False) and self.data.get(key) == value:
                return
            self.data[key] = encrypt(str(value))
            self.data[f"{key}_encrypted"] = True
        else:
            self.data[key] = value

    def set_and_save(self, key: str, value: Any, auto_encrypt: bool = True) -> None:
        """Sets a configuration value and immediately persists to disk."""
        self.set(key, value, auto_encrypt=auto_encrypt)
        self.save()

    def validate(self) -> list:
        """Validates current config, returning human-readable problems."""
        return validate_config(self.data)

    def get_blacklist_path(self) -> str:
        """Returns the resolved absolute path to the blacklist file."""
        return _resolve_path(self.get("strava_blacklist", "./strava_blacklist.json"))

    def get_blacklist(self) -> list:
        """Loads blacklist keywords from strava_blacklist.json.

        Returns [] when the file is missing: the default blacklist is
        empty (a missing file means "no bans", never the example template).
        Placeholder entries from older templates (``YOUR_BLACKLIST_EXAMPLE``)
        are filtered from any loaded list so a copied old example stays
        harmless.
        """
        return self._read_blacklist(strict=False)

    def _read_blacklist(self, strict: bool) -> list:
        """Blacklist keywords; ``strict`` raises when the file is busy.

        Only undecodable content is quarantined. A busy file (OSError)
        reads as empty for display, but edits (``strict``) must fail
        instead of saving a list that would drop every existing keyword.
        """
        path = self.get_blacklist_path()
        if not os.path.exists(path):
            return []
        try:
            with open(path, "r", encoding=self.encoding) as f:
                data = json.load(f)
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            backup = quarantine_corrupt_file(path)
            hint = f" Preserved at {backup}." if backup else ""
            print(f"Warning: Could not read blacklist file '{path}': {e}. Treating as empty.{hint}")
            return []
        except OSError as e:
            if strict:
                raise RuntimeError(f"Blacklist file '{path}' is not readable right now: {e}") from e
            print(f"Warning: Could not read blacklist file '{path}' right now: {e}.")
            return []
        if isinstance(data, list):
            return [kw for kw in data if not _looks_like_placeholder(kw)]
        print(f"Warning: Blacklist file '{path}' does not contain a JSON list. Treating as empty.")
        return []

    def set_blacklist(self, items: list) -> None:
        """Saves blacklist keywords list to strava_blacklist.json (atomically)."""
        path = self.get_blacklist_path()
        # Deduplicate while preserving order, strip whitespace
        cleaned = []
        for item in items:
            s = str(item).strip()
            if s and s not in cleaned:
                cleaned.append(s)
        atomic_write_json(path, cleaned, encoding=self.encoding)

    def add_blacklist_item(self, item: str) -> bool:
        """Adds a keyword to blacklist if not already present."""
        clean = item.strip()
        if not clean:
            return False
        current = self._read_blacklist(strict=True)
        if clean.lower() not in [x.lower() for x in current]:
            current.append(clean)
            self.set_blacklist(current)
            return True
        return False

    def remove_blacklist_item(self, item: str) -> bool:
        """Removes a keyword from blacklist."""
        clean = item.strip().lower()
        current = self._read_blacklist(strict=True)
        new_list = [x for x in current if x.strip().lower() != clean]
        if len(new_list) != len(current):
            self.set_blacklist(new_list)
            return True
        return False

    def get_already_excused_path(self) -> str:
        """Returns the resolved absolute path to the already excused lessons file."""
        return _resolve_path(self.get("already_excused_file", "./already_excused_lessons.json"))

    def get_excuse_history(self) -> list:
        """Loads and returns history from already_excused_lessons.json (or example template if missing)."""
        path = self.get_already_excused_path()
        if not os.path.exists(path):
            example_path = example_path_for(path)
            if os.path.exists(example_path):
                try:
                    with open(example_path, "r", encoding=self.encoding) as f:
                        data = json.load(f)
                        items = list(data) if isinstance(data, list) else []
                        # Template fallback: filter demo/placeholder rows
                        # so they never seed real dedup history.
                        return [it for it in items if not _is_demo_history_item(it)]
                except Exception as e:
                    print(f"Warning: Could not read excuse history template '{example_path}': {e}")
            return []
        try:
            with open(path, "r", encoding=self.encoding) as f:
                data = json.load(f)
                if isinstance(data, list):
                    return list(data)
                print(f"Warning: Excuse history file '{path}' does not contain a JSON list. Treating as empty.")
                return []
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            backup = quarantine_corrupt_file(path)
            hint = f" Preserved at {backup}." if backup else ""
            print(f"Warning: Could not read excuse history file '{path}': {e}. Treating as empty.{hint}")
            return []
        except OSError as e:
            print(f"Warning: Could not read excuse history file '{path}' right now: {e}.")
            return []
