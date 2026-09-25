"""School calendar presets (read-only, shipped with the app) + user overrides.

Ownership split (deliberate):
- Preset days/closures live HERE in code. Editing them in a release
  updates every user on ``school_preset_id`` automatically.
- User data lives in config: ``user_free_days`` (additions),
  ``forced_school_days`` (exceptions re-enabling a preset day),
  ``sem1_close``/``sem2_close`` (prefilled once, then user-owned).

Effective calendar = (preset days + user additions) - forced school days.
Entries accept plain ``DD.MM.RRRR`` strings, ``date`` objects,
``{"date": ..., "label": ...}`` dicts and ``"DD.MM.RRRR|label"`` strings —
old ``holidays`` lists keep parsing.
"""

from __future__ import annotations

from datetime import date, timedelta
from typing import Any, Iterable

PRESET_VERSION = 1

GEKOM_2026_2027 = {
    "id": "gekom_2026_2027",
    "school": "GEKOM",
    "year": "2026/2027",
    "title_cs": "GEKOM 2026/2027",
    "title_en": "GEKOM 2026/2027",
    "version": 1,
    # Absence/marks closure dates (final year ends sooner).
    "sem1_close": "25.01.2027",
    "sem2_close": "26.04.2027",
    # Lunch ordering cutoff (Strava): orders close at this time on the
    # previous business day (Mon–Fri minus free days).
    "lunch_cutoff_time": "12:00",
    # Percent -> grade conversion ("Tabulka převodu hodnocení" in
    # Bakaláři): the top of grades 2–5; each value is already the worse
    # grade. GEKOM: 1 = 100–87, 2 = 87–72, 3 = 72–55, 4 = 55–40, 5 = 40–0
    # (87 % is a 2, 40 % a 5).
    "marks_percent_bands": [87.0, 72.0, 55.0, 40.0],
    # Vacation ranges (inclusive, DD.MM.RRRR). The preset deliberately ends
    # at the absence closure (sem2_close): summer holidays are not part
    # of the school year the planner works with.
    "ranges": [
        ("28.10.2026", "30.10.2026", "Podzimní prázdniny"),
        ("23.12.2026", "03.01.2027", "Vánoční prázdniny"),
        ("22.02.2027", "26.02.2027", "Jarní prázdniny"),
        ("25.03.2027", "29.03.2027", "Velikonoční prázdniny"),
    ],
    # Single days outside the ranges above.
    "days": [
        ("28.09.2026", "Státní svátek"),
        ("16.11.2026", "Ředitelské volno"),
        ("17.11.2026", "Státní svátek"),
        ("29.01.2027", "Pololetní prázdniny"),
        ("10.02.2027", "Ředitelské volno"),
    ],
}

#: Presets shipped with the app. To add a school, add a dict shaped like
#: GEKOM_2026_2027 here (and a test), or — without touching the code —
#: drop a JSON file of the same shape into ``school_presets/`` in the
#: data dir (see docs/SCHOOL_PRESETS.md).
PRESETS: dict[str, dict] = {
    GEKOM_2026_2027["id"]: GEKOM_2026_2027,
}

CUSTOM_ID = "custom"

#: Folder (in the data dir) scanned for user-supplied ``*.json`` presets.
USER_PRESET_DIR = "./school_presets"

#: Default when a preset sets no lunch cutoff and the user entered none.
DEFAULT_LUNCH_CUTOFF = "12:00"


def validate_preset(data: Any) -> list[str]:
    """Problems of a preset dict (empty = usable)."""
    problems: list[str] = []
    if not isinstance(data, dict):
        return ["preset must be a JSON object"]
    pid = str(data.get("id", "") or "")
    if not pid or pid == CUSTOM_ID or not all(c.isalnum() or c in "_-" for c in pid):
        problems.append("'id' must be letters, digits, '_' or '-' (and not 'custom')")
    if not str(data.get("title_cs", "") or data.get("title_en", "") or "").strip():
        problems.append("'title_cs' or 'title_en' is required")
    for key in ("sem1_close", "sem2_close"):
        raw = data.get(key, "")
        if raw and _parse(raw) is None:
            problems.append(f"'{key}' must be DD.MM.YYYY")
    cutoff = str(data.get("lunch_cutoff_time", "") or "").strip()
    if cutoff:
        from .lunch_cutoff import is_valid_cutoff_time

        if not is_valid_cutoff_time(cutoff):
            problems.append("'lunch_cutoff_time' must be HH:MM")
    bands = data.get("marks_percent_bands")
    if bands not in (None, []):
        from .grades import bands_valid

        if not bands_valid(bands):
            problems.append("'marks_percent_bands' must be four decreasing percentages "
                            "within (0, 100] (the top of grades 2–5)")
    for entry in data.get("days", []) or []:
        if not isinstance(entry, (list, tuple)) or len(entry) != 2 or _parse(entry[0]) is None:
            problems.append(f"bad 'days' entry {entry!r} (want [\"DD.MM.YYYY\", \"label\"])")
            break
    for entry in data.get("ranges", []) or []:
        if (not isinstance(entry, (list, tuple)) or len(entry) != 3
                or _parse(entry[0]) is None or _parse(entry[1]) is None):
            problems.append(f"bad 'ranges' entry {entry!r} "
                            "(want [\"DD.MM.YYYY\", \"DD.MM.YYYY\", \"label\"])")
            break
    return problems


def _user_presets() -> dict[str, dict]:
    """Valid presets from ``school_presets/*.json``; bad files are reported, not fatal."""
    import json
    import os

    from .helpers import _resolve_path

    folder = _resolve_path(USER_PRESET_DIR)
    out: dict[str, dict] = {}
    try:
        names = sorted(n for n in os.listdir(folder) if n.lower().endswith(".json"))
    except OSError:
        return out
    for name in names:
        path = os.path.join(folder, name)
        try:
            with open(path, "r", encoding="utf-8-sig") as f:
                data = json.load(f)
        except (OSError, ValueError) as exc:
            print(f"Warning: school preset {name!r} ignored: {exc}")
            continue
        problems = validate_preset(data)
        if problems:
            print(f"Warning: school preset {name!r} ignored: {'; '.join(problems)}")
            continue
        data = dict(data, user_file=name)
        out[str(data["id"])] = data
    return out


def all_presets() -> dict[str, dict]:
    """Shipped presets plus valid user files (a user file never replaces a shipped id)."""
    merged = dict(_user_presets())
    merged.update(PRESETS)
    return merged


def preset_title(preset: dict, language: str = "cs") -> str:
    key = "title_en" if language == "en" else "title_cs"
    return str(preset.get(key) or preset.get("title_cs") or preset.get("title_en")
               or preset.get("id", "?"))


def preset_options(language: str = "cs") -> list[tuple[str, str]]:
    """``[(id, title)]`` for pickers: presets by title, then ``custom`` last."""
    items = sorted(all_presets().values(), key=lambda p: preset_title(p, language).lower())
    return [(str(p["id"]), preset_title(p, language)) for p in items]


def get_preset(preset_id: str | None) -> dict | None:
    if not preset_id or preset_id == CUSTOM_ID:
        return None
    preset = PRESETS.get(str(preset_id))
    if preset is None:
        preset = _user_presets().get(str(preset_id))
    return preset


def _parse(value: Any) -> date | None:
    from .models import parse_cz_date

    return parse_cz_date(value)


def _split_entry(entry: Any) -> tuple[date | None, str]:
    """(date, label) from any accepted entry shape."""
    if isinstance(entry, dict):
        return _parse(entry.get("date")), str(entry.get("label", "") or "")
    if isinstance(entry, str) and "|" in entry:
        raw, _, label = entry.partition("|")
        return _parse(raw.strip()), label.strip()
    return _parse(entry), ""


def expand_entries(entries: Iterable[Any] | None) -> dict[date, str]:
    """{date: label} for user-shaped entry lists (first label wins)."""
    out: dict[date, str] = {}
    for entry in entries or []:
        day, label = _split_entry(entry)
        if day is None:
            continue
        if day not in out:
            out[day] = label
        elif not out[day] and label:
            out[day] = label
    return out


def preset_days(preset_id: str | None) -> dict[date, str]:
    """{date: label} expanded from a preset (ranges inclusive)."""
    preset = get_preset(preset_id)
    if preset is None:
        return {}
    out: dict[date, str] = {}
    for single, label in preset.get("days", []) or []:
        day = _parse(single)
        if day is not None and day not in out:
            out[day] = str(label or "")
    for start_raw, end_raw, label in preset.get("ranges", []) or []:
        start, end = _parse(start_raw), _parse(end_raw)
        if start is None or end is None or end < start:
            continue
        cursor = start
        while cursor <= end:
            if cursor not in out:
                out[cursor] = str(label or "")
            cursor += timedelta(days=1)
    return out


def preset_closes(preset_id: str | None) -> tuple[str, str]:
    """(sem1_close, sem2_close) strings from the preset, else ('','')."""
    preset = get_preset(preset_id)
    if preset is None:
        return "", ""
    return str(preset.get("sem1_close", "") or ""), str(preset.get("sem2_close", "") or "")


def preset_lunch_cutoff(preset_id: str | None) -> str:
    """Lunch ordering cutoff ``HH:MM`` from the preset, else ''."""
    from .lunch_cutoff import normalize_cutoff_time

    preset = get_preset(preset_id)
    if preset is None:
        return ""
    raw = str(preset.get("lunch_cutoff_time", "") or "").strip()
    if not raw:
        return ""
    return normalize_cutoff_time(raw)


def preset_marks_bands(preset_id: str | None) -> tuple[float, float, float, float] | None:
    """Percent -> grade bands from the preset, else None."""
    from .grades import bands_valid, normalize_bands

    preset = get_preset(preset_id)
    if preset is None or not bands_valid(preset.get("marks_percent_bands")):
        return None
    return normalize_bands(preset["marks_percent_bands"])


def resolve_marks_bands(config_data: dict | None) -> tuple[tuple[float, ...], str]:
    """(bands, source): the user's own bands, then the preset's, else the
    built-in default. ``source`` is ``user`` / ``preset`` / ``default``."""
    from .grades import DEFAULT_BANDS, bands_valid, normalize_bands

    config_data = config_data or {}
    user = config_data.get("marks_percent_bands")
    if bands_valid(user):
        return normalize_bands(user), "user"
    preset = preset_marks_bands(str(config_data.get("school_preset_id", "") or ""))
    if preset is not None:
        return preset, "preset"
    return DEFAULT_BANDS, "default"


def resolve_lunch_cutoff(config_data: dict | None) -> str:
    """Resolved lunch cutoff ``HH:MM``: user override, then preset, else 12:00."""
    from .lunch_cutoff import is_valid_cutoff_time, normalize_cutoff_time

    config_data = config_data or {}
    user = str(config_data.get("lunch_order_cutoff_time", "") or "").strip()
    if user and is_valid_cutoff_time(user):
        return normalize_cutoff_time(user)
    preset = preset_lunch_cutoff(str(config_data.get("school_preset_id", "") or ""))
    if preset:
        return preset
    return DEFAULT_LUNCH_CUTOFF


def effective_calendar(config_data: dict | None,
                       clip: bool = True) -> tuple[set[date], dict[date, str], dict]:
    """Effective free-day set with labels + source counts.

    Returns (dates, labels, info) where info carries
    ``preset_days`` / ``user_added`` / ``forced_school`` counts and the
    ``preset_id`` used. Legacy ``holidays`` entries count as user additions
    so pre-migration configs keep working when read directly.

    Days after the final sem2 absence closure (user value, else preset)
    are excluded — even preset days — so the calendar never shows free
    days past the end of the school year the planner works with.
    Stored data is untouched; only the returned view is cut off.
    ``clip=False`` skips that cut: lunch deadlines run past the closure
    (May, June) and must still skip the user's days off there.
    """
    config_data = config_data or {}
    preset_id = str(config_data.get("school_preset_id", "") or "")
    preset_map = preset_days(preset_id)
    user_map = expand_entries(config_data.get("user_free_days"))
    user_map.update(
        {d: lbl for d, lbl in expand_entries(config_data.get("holidays")).items()
         if d not in user_map}
    )
    forced = set(expand_entries(config_data.get("forced_school_days")))

    dates = (set(preset_map) | set(user_map)) - forced
    labels = {d: preset_map.get(d, "") for d in preset_map if d in dates}
    for d, lbl in user_map.items():
        if d in dates and (not labels.get(d)) and lbl:
            labels[d] = lbl
    end = _parse(resolve_close("sem2", config_data)) if clip else None
    if end is not None:
        dates = {d for d in dates if d <= end}
        labels = {d: lbl for d, lbl in labels.items() if d <= end}
    in_scope = (lambda d: end is None or d <= end)
    info = {
        "preset_id": preset_id,
        "preset_days": len([d for d in preset_map if d not in forced and in_scope(d)]),
        "user_added": len([d for d in user_map if d in dates]),
        "forced_school": len([d for d in forced
                              if d in (set(preset_map) | set(user_map)) and in_scope(d)]),
    }
    return dates, labels, info


def resolve_close(which: str, config_data: dict | None) -> str:
    """User close wins, then preset, else '' (auto semester bound)."""
    config_data = config_data or {}
    key = "sem1_close" if which == "sem1" else "sem2_close"
    user = str(config_data.get(key, "") or "").strip()
    if user and _parse(user) is not None:
        return user
    preset = get_preset(str(config_data.get("school_preset_id", "") or ""))
    if preset is not None:
        close = str(preset.get("sem1_close" if which == "sem1" else "sem2_close", "") or "")
        if close and _parse(close) is not None:
            return close
    return ""


def prune_orphan_forced(config_data: dict) -> bool:
    """Drops forced-school entries matching neither preset nor user days.

    Returns True when anything was removed (caller persists).
    """
    forced = list(config_data.get("forced_school_days") or [])
    if not forced:
        return False
    preset_map = preset_days(str(config_data.get("school_preset_id", "") or ""))
    user_map = expand_entries(config_data.get("user_free_days"))
    user_map.update(expand_entries(config_data.get("holidays")))
    known = set(preset_map) | set(user_map)
    kept = [e for e in forced if _split_entry(e)[0] in known]
    if len(kept) != len(forced):
        config_data["forced_school_days"] = kept
        return True
    return False
