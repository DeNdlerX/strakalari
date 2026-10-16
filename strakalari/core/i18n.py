"""Active UI language (``cs`` / ``en``) plus the few core-level texts.

All user-visible UI text lives in ``flet_ui/strings.py``; this module
only owns the language setting (shared with the UI) and messages the
core layer itself shows, so ``core`` never imports the UI package.
"""

from __future__ import annotations

LANGUAGES = ("cs", "en")

_current_lang = "cs"

MESSAGES: dict[str, dict[str, str]] = {
    "error_timeout": {
        "cs": (
            "Server neodpověděl v časovém limitu — připojení k internetu je "
            "nejspíš pomalé nebo nestabilní. Zkuste to znovu, případně zvyšte "
            "Časový limit spojení v Nastavení nebo se připojte k rychlejší síti."
        ),
        "en": (
            "The server did not answer within the time limit — your internet "
            "connection is probably slow or unstable. Try again, raise the "
            "connection timeout in Settings, or switch to a faster network."
        ),
    },
    "bak_login_rejected": {
        "cs": "Přihlášení k Bakalářům selhalo — zkontrolujte jméno a heslo v Nastavení. (Bakaláři: {detail})",
        "en": "Bakaláři login failed — check your username and password in Settings. (Bakaláři: {detail})",
    },
    "bak_missing_url": {
        "cs": "Chybí URL Bakalářů — doplňte ho v Nastavení.",
        "en": "The Bakaláři URL is missing — add it in Settings.",
    },
    "bak_missing_user": {
        "cs": "Chybí uživatelské jméno Bakalářů — doplňte ho v Nastavení.",
        "en": "The Bakaláři username is missing — add it in Settings.",
    },
    "bak_missing_password": {
        "cs": "Chybí heslo Bakalářů — doplňte ho v Nastavení.",
        "en": "The Bakaláři password is missing — add it in Settings.",
    },
    "bak_unreachable": {
        "cs": "Nepodařilo se spojit s Bakaláři ({host}). Zkontrolujte připojení k internetu a adresu Bakalářů v Nastavení.",
        "en": "Could not connect to Bakaláři ({host}). Check your internet connection and the Bakaláři address in Settings.",
    },
    "bak_connection_lost": {
        "cs": "Spojení s Bakaláři se přerušilo. Zkuste to prosím za chvíli znovu.",
        "en": "The connection to Bakaláři was interrupted. Please try again in a moment.",
    },
    "bak_no_login_page": {
        "cs": "Na adrese {host} se nepodařilo najít přihlášení do Bakalářů. Zkontrolujte adresu Bakalářů v Nastavení.",
        "en": "No Bakaláři login was found at {host}. Check the Bakaláři address in Settings.",
    },
    "bak_server_error": {
        "cs": "Bakaláři odpověděli chybou (HTTP {status}). Zkuste to prosím později.",
        "en": "Bakaláři answered with an error (HTTP {status}). Please try again later.",
    },
    "bak_password_undecryptable": {
        "cs": "Heslo k Bakalářům nelze rozšifrovat — zadejte ho znovu v Nastavení.",
        "en": "The stored Bakaláři password cannot be decrypted — enter it again in Settings.",
    },
    "strava_missing_canteen": {
        "cs": "Chybí číslo jídelny Stravy — doplňte ho v Nastavení.",
        "en": "The Strava canteen number is missing — add it in Settings.",
    },
    "strava_missing_user": {
        "cs": "Chybí uživatelské jméno Stravy — doplňte ho v Nastavení.",
        "en": "The Strava username is missing — add it in Settings.",
    },
    "strava_missing_password": {
        "cs": "Chybí heslo Stravy — doplňte ho v Nastavení.",
        "en": "The Strava password is missing — add it in Settings.",
    },
    "strava_password_undecryptable": {
        "cs": "Heslo ke Stravě nelze rozšifrovat — zadejte ho znovu v Nastavení.",
        "en": "The stored Strava password cannot be decrypted — enter it again in Settings.",
    },
    "strava_unreachable": {
        "cs": "Nepodařilo se spojit se Stravou. Zkontrolujte připojení k internetu.",
        "en": "Could not connect to Strava. Check your internet connection.",
    },
    "strava_connection_lost": {
        "cs": "Spojení se Stravou se přerušilo. Zkuste to prosím za chvíli znovu.",
        "en": "The connection to Strava was interrupted. Please try again in a moment.",
    },
    "strava_server_error": {
        "cs": "Strava odpověděla chybou (HTTP {status}). Zkuste to prosím později.",
        "en": "Strava answered with an error (HTTP {status}). Please try again later.",
    },
    "strava_login_failed": {
        "cs": "Přihlášení ke Stravě selhalo — zkontrolujte číslo jídelny, uživatelské jméno a heslo v Nastavení.",
        "en": "Strava login failed — check the canteen number, username and password in Settings.",
    },
    "strava_login_rejected": {
        "cs": "Přihlášení ke Stravě selhalo — zkontrolujte číslo jídelny, uživatelské jméno a heslo v Nastavení. (Strava: {detail})",
        "en": "Strava login failed — check the canteen number, username and password in Settings. (Strava: {detail})",
    },
    "strava_menu_failed": {
        "cs": "Jídelníček ze Stravy se nenačetl. (Strava: {detail})",
        "en": "The Strava menu did not load. (Strava: {detail})",
    },
    "test_bak_missing": {
        "cs": "Chybí URL nebo uživatelské jméno Bakalářů.",
        "en": "The Bakaláři URL or username is missing.",
    },
    "test_bak_ok": {"cs": "Přihlášení k Bakalářům proběhlo úspěšně!", "en": "Bakaláři login successful!"},
    "test_bak_failed": {"cs": "Chyba při přihlašování k Bakalářům: {err}", "en": "Bakaláři login error: {err}"},
    "test_strava_missing": {
        "cs": "Chybí kód jídelny nebo uživatelské jméno Stravy.",
        "en": "The Strava canteen number or username is missing.",
    },
    "test_strava_ok": {"cs": "Přihlášení ke Stravě proběhlo úspěšně!", "en": "Strava login successful!"},
    "test_strava_failed": {"cs": "Chyba při přihlašování ke Stravě: {err}", "en": "Strava login error: {err}"},
    "auto_excuses_failed": {
        "cs": "{n} omluvenek se nepodařilo odeslat",
        "en": "{n} excuse(s) could not be sent",
    },
    "auto_excuse_outbox_unknown": {
        "cs": "Automatické omlouvání přeskočeno — Komens → Odeslané se nepodařilo načíst",
        "en": "Auto-excuse skipped — Komens → Sent could not be read",
    },
    "auto_orders_failed": {
        "cs": "{n} z {total} objednávek obědů neprošlo (podrobnosti v protokolu)",
        "en": "{n} of {total} lunch order(s) did not go through (details in the log)",
    },
    "strava_low_balance": {
        "cs": "Na účtu ve Stravě není dost peněz — {n} obědů se neobjednalo. "
              "Dobijte kredit, objednávky se zkusí znovu při další aktualizaci.",
        "en": "Not enough money on the Strava account — {n} lunch(es) were not ordered. "
              "Top up the account; the orders are retried on the next refresh.",
    },
    "strava_low_balance_manual": {
        "cs": "Na účtu ve Stravě není dost peněz — {n} obědů se neobjednalo. Dobijte kredit a odešlete znovu.",
        "en": "Not enough money on the Strava account — {n} lunch(es) were not ordered. Top up and send again.",
    },
    "period_label": {"cs": "{n}. hodina", "en": "period {n}"},
    "news_mark": {"cs": "Nová známka: {items}", "en": "New mark: {items}"},
    "news_marks": {"cs": "Nové známky: {items}", "en": "New marks: {items}"},
    "news_absence": {"cs": "Nová absence: {items}", "en": "New absence: {items}"},
    "news_absences": {"cs": "Nové absence: {items}", "en": "New absences: {items}"},
    "news_change": {"cs": "Změna v rozvrhu: {items}", "en": "Timetable change: {items}"},
    "news_changes": {"cs": "Změny v rozvrhu: {items}", "en": "Timetable changes: {items}"},
    "news_more": {"cs": "a další ({n})", "en": "and {n} more"},
    "news_cancelled": {"cs": "odpadá", "en": "cancelled"},
    "news_added": {"cs": "hodina navíc", "en": "extra lesson"},
    "news_room": {"cs": "učebna {room}", "en": "room {room}"},
    "news_changed": {"cs": "změna", "en": "changed"},
    "cache_age_now": {"cs": "právě teď", "en": "just now"},
    "cache_age_min": {"cs": "před {n} min", "en": "{n} min ago"},
    "cache_age_hours": {"cs": "před {n} h", "en": "{n} h ago"},
    "cache_age_days": {"cs": "před {n} dny", "en": "{n} days ago"},
    "cache_stale": {"cs": "zastaralé", "en": "stale"},
    "gemini_no_menu": {"cs": "Žádný jídelníček k doporučení.", "en": "No menu to recommend from."},
    "gemini_heading": {"cs": "💡 <b>Doporučení Gemini AI:</b><br><br>",
                       "en": "💡 <b>Gemini AI recommendation:</b><br><br>"},
    "gemini_local_heading": {"cs": "Lokální doporučení (bez AI):<br><br>",
                             "en": "Local recommendation (no AI):<br><br>"},
    "gemini_missing_key": {"cs": "Chybí API klíč.", "en": "Missing API key."},
    "gemini_key_ok": {"cs": "Klíč Gemini funguje ({model}).", "en": "Gemini key works ({model})."},
    "gemini_key_invalid": {"cs": "Neplatný Gemini API klíč (HTTP {status}).",
                           "en": "Invalid Gemini API key (HTTP {status})."},
    "gemini_bad_request": {
        "cs": "Gemini požadavek odmítnut (HTTP 400) — zkontrolujte název modelu.",
        "en": "Gemini request rejected (HTTP 400) — check the model name.",
    },
    "gemini_key_check_failed": {"cs": "Kontrola Gemini klíče selhala: {err}",
                                "en": "Gemini key check failed: {err}"},
}


def set_language(lang: str) -> None:
    """Sets the active language; unknown codes are ignored."""
    global _current_lang
    if lang in LANGUAGES:
        _current_lang = lang


def get_language() -> str:
    return _current_lang


def t(key: str, default: str | None = None, *, lang: str | None = None, **fmt) -> str:
    """Core message in the active language (Czech fallback, then ``default``/key).

    ``lang`` overrides the active language (for callers handed an explicit
    one). ``fmt`` fills ``{placeholders}``; a bad placeholder never raises.
    """
    texts = MESSAGES.get(key) or {}
    text = texts.get(lang or _current_lang) or texts.get("cs") or (default if default else key)
    if fmt:
        try:
            return text.format(**fmt)
        except (KeyError, IndexError, ValueError):
            return text
    return text
