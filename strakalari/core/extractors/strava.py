"""Parsers for what the Strava web app API returns (see docs/STRAVA_API.md)."""

import html
import re


def clean_text(text: str) -> str:
    """Removes HTML tags, newlines, tabs, and unescapes HTML entities."""
    if not text:
        return ""

    # 1. Replace line break and block tags with a space to prevent words merging
    text = re.sub(r'<(?:br\s*/?|/div|/p|/tr|/td)[^>]*>', ' ', text, flags=re.IGNORECASE)

    # 2. Remove any remaining HTML tags (e.g., <span>, <path d="...">, etc.)
    text = re.sub(r'<[^>]+>', '', text)

    # 3. Unescape HTML entities (converts &amp; to &, &lt; to <, etc.)
    text = html.unescape(text)

    # 4. Normalize whitespace (replace newlines/tabs/multiple spaces with a single space)
    text = re.sub(r'\s+', ' ', text)

    # 5. Strip leading/trailing spaces
    return text.strip()


# -- Web app JSON (/api/objednavky) --------------------------------------------

_WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def menu_tables(reply) -> list:
    """``[(table_key, meals)]`` of an ``/api/objednavky`` reply, in day order."""
    if not isinstance(reply, dict):
        return []
    tables = []
    for key, meals in reply.items():
        match = re.fullmatch(r"table(\d+)", str(key))
        if match and isinstance(meals, list) and meals:
            tables.append((int(match.group(1)), key, meals))
    return [(key, meals) for _, key, meals in sorted(tables)]


def is_orderable_meal(meal: dict) -> bool:
    """False for rows the web shows without an order control (the soup row)."""
    return meal.get("polevka") != "A" and str(meal.get("zkratkaProduktu") or "") != ""


def meal_text(meal: dict) -> str:
    """The meal as the menu label reads: ``oběd 1 - <name>(01, 03 )``."""
    codes = [str(a[0]).strip() for a in meal.get("alergeny") or []
             if isinstance(a, (list, tuple)) and a and str(a[0]).strip()]
    text = f"{clean_text(meal.get('druh_popis'))} - {clean_text(meal.get('nazev'))}"
    return f"{text}({', '.join(codes)} )" if codes else text


def menu_from_reply(reply) -> tuple:
    """``(foodDict, orderedDict)`` from an ``/api/objednavky`` reply.

    Same shapes and ids the menu page's elements carried: per day a
    ``<table>&-1&0`` day control (cancel the day) plus ``<table>&<id>&0``
    per orderable meal; the ordered meal is the one with ``pocet`` > 0.
    Never raises: ``({}, {})`` on garbage.
    """
    from datetime import datetime

    food, ordered = {}, {}
    for key, meals in menu_tables(reply):
        # The day's date from the first row carrying one: the soup row
        # comes first and may have none.
        day, when = "", None
        for meal in meals:
            try:
                day = str(meal.get("datum") or "").strip()
                when = datetime.strptime(day, "%d.%m.%Y")
                break
            except (AttributeError, ValueError):
                continue
        if when is None:
            continue
        selection = {f"{key}&-1&0": f"{_WEEKDAYS[when.weekday()]} {when:%d/%m/%Y}"}
        for meal in meals:
            if not isinstance(meal, dict) or not is_orderable_meal(meal):
                continue
            meal_id = f"{key}&{meal.get('id')}&0"
            selection[meal_id] = meal_text(meal)
            try:
                count = int(meal.get("pocet") or 0)
            except (TypeError, ValueError):
                count = 0
            if count > 0 and day not in ordered:
                ordered[day] = meal_id
        food[day] = selection
    return food, ordered
