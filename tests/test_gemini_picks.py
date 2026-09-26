"""Gemini lunch picks: only that day's menu counts; user-facing texts follow the language."""
from datetime import date




# -- Gemini picks must come from that day's menu -----------------------------

FOOD = {"01.10.2026": {"table1&1&0": "Guláš", "table1&2&0": "Rizoto"},
        "2.10.2026": {"table2&1&0": "Svíčková", "table2&2&0": "Salát"}}


def test_validate_recommendation_rejects_other_days_meal():
    from strakalari.core.gemini import validate_recommendation

    got = validate_recommendation({"01.10.2026": "table2&1&0",
                                   "02.10.2026": "table2&2&0"}, FOOD)
    assert got == {"2.10.2026": "table2&2&0"}


def test_merge_falls_back_to_filter_for_cross_day_pick():
    from strakalari.core.lunch_auto import merge_gemini_with_filter

    got = merge_gemini_with_filter({"01.10.2026": "table2&1&0"}, FOOD,
                                   today=date(2026, 9, 24))
    assert got["01.10.2026"] == "table1&1&0"  # filter pick, not 2.10.'s meal


# -- Gemini user texts follow the requested language ---------------------------

def test_gemini_texts_follow_language():
    from strakalari.core.gemini import local_fallback_recommendation, recommend_lunches, test_api_key

    assert recommend_lunches({}, "", "", language="en")[0] == "No menu to recommend from."
    assert recommend_lunches({}, "", "", language="cs")[0] == "Žádný jídelníček k doporučení."
    assert test_api_key("", language="en") == (False, "Missing API key.")
    html, _ = local_fallback_recommendation({"01.10.2026": {"1": "Polévka"}}, "", language="en")
    assert html.startswith("Local recommendation (no AI):")


def test_core_t_lang_override():
    from strakalari.core.i18n import get_language, t

    assert t("gemini_missing_key", lang="en") == "Missing API key."
    assert t("gemini_missing_key", lang="cs") == "Chybí API klíč."
    # The override never changes the active language.
    assert get_language() in ("cs", "en")
