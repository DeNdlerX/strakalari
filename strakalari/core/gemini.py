"""Gemini AI lunch recommendations with retries and a local keyword fallback.

``recommend_lunches()`` returns ``(html_text, {date: meal_id})``; picks are
validated against the menu before anything can be ordered.
"""

from __future__ import annotations

import json
import re
import time
import urllib.request
from typing import Dict, Tuple

from .i18n import t


def build_menu_block(food_data: dict) -> str:
    lines: list[str] = []
    for day, meals in (food_data or {}).items():
        items = [f"  ID: {mid} | {mname}" for mid, mname in meals.items() if "&-1&" not in mid]
        lines.append(f"Den {day}:\n" + "\n".join(items))
    return "\n\n".join(lines)


def build_prompt(pref: str, menu_block: str, language: str = "cs") -> str:
    if language == "en":
        return (
            f"You are a lunch picker assistant. User preferences: '{pref}'.\n"
            f"Pick the single best meal for each day from this menu:\n"
            f"{menu_block}\n\n"
            "Answer with bullet points explaining the nutritional benefits "
            'and end with a valid JSON block ```json {"DD.MM.YYYY": "meal_ID"} ```.'
        )
    return (
        f"Jsi asistent pro výběr obědů. Uživatel má preference: '{pref}'.\n"
        f"Vyber pro každý den jedno nejvhodnější jídlo z následující nabídky:\n"
        f"{menu_block}\n\n"
        "Odpověz ve formátu odrážek s českým vysvětlením nutričních výhod "
        'a na konci uveď platný JSON blok ```json {"DD.MM.YYYY": "ID_jidla"} ```.'
    )


def parse_recommendation_response(text: str) -> Tuple[str, dict]:
    """Extracts (clean_text, {date: meal_id}) from a Gemini reply."""
    recommended: dict = {}
    # Strip elements that must never come from a model reply (scripts,
    # frames, embeds, images, forms) before the text is rendered.
    text = re.sub(
        r"</?(script|iframe|object|embed|img|link|meta|style|form|input|button|video|audio)[^>]*>",
        "", text, flags=re.IGNORECASE,
    )
    m = re.search(r"```json\s*(\{.*?\})\s*```", text, re.DOTALL)
    if m:
        try:
            parsed = json.loads(m.group(1))
            if isinstance(parsed, dict):
                recommended = {str(k): str(v) for k, v in parsed.items()}
        except Exception:
            recommended = {}
    if not recommended:
        # Greedy-match fallback: a reply with several ```json blocks defeats
        # the first-match above — try every block until one parses.
        for block in re.findall(r"```json\s*(.*?)\s*```", text, re.DOTALL):
            try:
                parsed = json.loads(block)
            except Exception:
                continue
            if isinstance(parsed, dict):
                recommended = {str(k): str(v) for k, v in parsed.items()}
                break
    clean = text.split("```json")[0].strip().replace("\n", "<br>")
    return clean, recommended


def validate_recommendation(recommended: dict, food_data: dict) -> dict:
    """Keeps only ``{day: meal_id}`` pairs present on the menu.

    The model may hallucinate IDs or dates; callers must never forward
    those to ordering. Day keys match canonically (``7.9.2026`` and
    ``07.09.2026`` are the same day) but the returned day key is the
    menu's own spelling so downstream ``foodDict.get(day)`` hits.
    """
    if not isinstance(recommended, dict) or not isinstance(food_data, dict):
        return {}
    from .models import canonical_day_key

    # The meal must be on THAT day's menu: an id borrowed from another
    # day passes a global check but Strava can never order it there.
    day_ids: dict[str, set[str]] = {}
    canon_to_day: dict[str, str] = {}
    for day, meals in (food_data or {}).items():
        if not isinstance(meals, dict):
            continue
        canon = canonical_day_key(day)
        day_ids.setdefault(canon, set()).update(str(mid) for mid in meals)
        canon_to_day.setdefault(canon, str(day))
    valid: dict = {}
    for day, mid in recommended.items():
        mid_s = str(mid)
        canon = canonical_day_key(str(day))
        if canon in canon_to_day and mid_s in day_ids.get(canon, ()):
            valid[canon_to_day[canon]] = mid_s
    return valid


def local_fallback_recommendation(food_data: dict, pref: str, language: str = "cs") -> Tuple[str, dict]:
    """Keyword-based fallback when no API key / API fails. Returns (html, orders)."""
    pref_lower = (pref or "").lower()
    html_lines: list[str] = []
    orders: Dict[str, str] = {}
    for day, meals in (food_data or {}).items():
        best_id, best_name, best_score = None, None, -999
        for mid, mname in meals.items():
            if "&-1&" in mid:
                continue
            score = 0
            name_l = str(mname).lower()
            if any(p in pref_lower for p in ["bílkovin", "protein", "maso"]):
                if any(k in name_l for k in ["krůtí", "kuřec", "kuře"]):
                    score += 30
                elif any(k in name_l for k in ["hověz", "steak", "roštěn"]):
                    score += 25
                elif any(k in name_l for k in ["rybí", "ryba", "ryby", "rybu", "rybou", "filé", "losos", "tuňák"]):
                    score += 25
                elif any(k in name_l for k in ["vejce", "tvaroh", "luštěnin", "čočka", "fazole"]):
                    score += 20
            if any(p in pref_lower for p in ["bez vepř", "ne vepř"]):
                if any(k in name_l for k in ["vepř", "sekaná", "výpeč", "šunk", "slanina"]):
                    score -= 50
            if any(p in pref_lower for p in ["lehk", "salát", "vegetarián", "zelenin"]):
                if any(k in name_l for k in ["salát", "zelenin", "brokolic", "špenát"]):
                    score += 20
                if any(k in name_l for k in ["smažen", "tatar", "majonez"]):
                    score -= 20
            if score > best_score:
                best_score, best_id, best_name = score, mid, mname
        if best_id:
            orders[day] = best_id
            html_lines.append(f"• <b>{day}</b>: {best_name}")
    header = t("gemini_local_heading", lang=language)
    html = header + "<br>".join(html_lines)
    return html, orders


def recommend_lunches(
    food_data: dict,
    pref: str,
    api_key: str,
    model: str = "gemini-3.8-flash",
    language: str = "cs",
    timeout: int = 30,
    retries: int = 2,
    allow_fallback: bool = True,
) -> Tuple[str, dict]:
    """Tries Gemini (with retry), falls back to local keywords.

    With ``allow_fallback=False`` a failed request returns ``("", {})``
    instead of the local keyword picks, so callers can tell a real AI
    answer from the fallback (the auto-run only stamps real answers).
    """
    def _fallback(data: dict) -> Tuple[str, dict]:
        if not allow_fallback:
            return "", {}
        return local_fallback_recommendation(data, pref, language=language)

    if not food_data:
        return t("gemini_no_menu", lang=language), {}
    try:
        menu_block = build_menu_block(food_data)
    except Exception:
        return _fallback(food_data if isinstance(food_data, dict) else {})
    api_key = (api_key or "").strip()
    if not api_key:
        return _fallback(food_data)
    prompt = build_prompt(pref, menu_block, language)
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    headers = {"Content-Type": "application/json", "x-goog-api-key": api_key}
    payload = json.dumps({"contents": [{"parts": [{"text": prompt}]}]}).encode("utf-8")
    last_err: Exception | None = None
    for attempt in range(retries + 1):
        try:
            req = urllib.request.Request(url, data=payload, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                text = data["candidates"][0]["content"]["parts"][0]["text"]
                clean, recommended = parse_recommendation_response(text)
                html = t("gemini_heading", lang=language) + clean
                # Never forward hallucinated IDs/dates to ordering — and
                # never stage nothing while the menu is full: an empty
                # answer counts as a failure (retry, then local fallback).
                valid_orders = validate_recommendation(recommended, food_data)
                if valid_orders:
                    return html, valid_orders
                last_err = ValueError("Gemini returned no usable meal picks")
        except Exception as e:  # noqa: BLE001 - network/API, always fall back
            last_err = e
        if attempt < retries:
            time.sleep(1 + attempt)
    # Never let the key reach stdout/the log, even via an echoed request.
    err_text = str(last_err).replace(api_key, "***") if api_key else str(last_err)
    print(f"Gemini API request failed: {err_text}")
    return _fallback(food_data)


def test_api_key(
    api_key: str,
    model: str = "gemini-3.8-flash",
    timeout: int = 20,
    language: str = "cs",
) -> Tuple[bool, str]:
    """Lightweight validation of a Gemini API key (no browser needed).

    GETs the single model's metadata endpoint — cheap, no quota burn
    beyond one read. Returns (ok, message). The key is never embedded
    in the returned message.
    """
    key = (api_key or "").strip()
    if not key:
        return False, t("gemini_missing_key", lang=language)
    model_name = (model or "gemini-3.8-flash").strip() or "gemini-3.8-flash"
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{model_name}"
    try:
        req = urllib.request.Request(
            url, headers={"Accept": "application/json", "x-goog-api-key": key})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            try:
                data = json.loads(resp.read().decode("utf-8"))
            except Exception:
                data = {}
            display = str((data or {}).get("displayName", "") or model_name)
            return True, t("gemini_key_ok", lang=language, model=display)
    except Exception as e:  # noqa: BLE001 - network/API, message only
        text = str(e).replace(key, "***")
        status = getattr(e, "code", None)
        if status in (401, 403):
            return False, t("gemini_key_invalid", lang=language, status=status)
        if status == 400:
            # Google returns 400 both for a bad key ("API key not valid")
            # and for a bad request (unknown model). Tell them apart via
            # the response body instead of blaming the key every time.
            try:
                _fp = getattr(e, "fp", None)
                _body = _fp.read().decode("utf-8", "replace") if _fp is not None else ""
            except Exception:
                _body = ""
            _low = _body.lower()
            if "api key not valid" in _low or "api_key_invalid" in _low:
                return False, t("gemini_key_invalid", lang=language, status=400)
            return False, t("gemini_bad_request", lang=language)
        first = text.splitlines()[0][:160] if text.strip() else "unknown error"
        return False, t("gemini_key_check_failed", lang=language,
                        err=f"{type(e).__name__}: {first}")
