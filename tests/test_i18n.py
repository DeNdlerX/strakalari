from strakalari.core.error_report import timeout_user_message
from strakalari.core.i18n import get_language, set_language, t


def teardown_function():
    set_language("cs")


def test_get_and_set_language():
    set_language("en")
    assert get_language() == "en"
    set_language("xx")
    assert get_language() == "en"


def test_core_messages_follow_language():
    set_language("cs")
    assert "připojení" in timeout_user_message()
    set_language("en")
    assert "connection" in timeout_user_message()


def test_missing_key_falls_back():
    assert t("non_existent_key_xyz", default="Fallback") == "Fallback"
    assert t("non_existent_key_xyz") == "non_existent_key_xyz"


class TestI18nKeys:
    def test_new_flet_strings_present(self):
        from strakalari.flet_ui.strings import STRINGS
        for key in ("excuse_sending", "excuse_failed", "need_credentials",
                    "send_orders", "orders_sending", "orders_sent", "orders_failed"):
            assert key in STRINGS
            assert STRINGS[key]["cs"] and STRINGS[key]["en"]


DEAD_KEYS = ["apply_filter", "cal_preset_days", "cal_use_preset", "cancel_order",
             "change", "col_pct", "col_state", "current_task", "demo_data",
             "density_comfort", "empty_lesson", "ends_at", "excuse_one_click",
             "leave_blank_keeps", "leave_blank_keeps_key", "password_kept",
             "lesson_detail", "lunch_will_cancel", "notes_count",
             "notif_section_hint", "order", "order_cancelled", "orders_partial",
             "refresh_cancelled", "refresh_finished", "save", "saves_instantly",
             "school_done", "stale", "status", "status_working",
             "today_subtitle", "holidays", "school_year_end", "limit_pct",
             "best_days", "no_suggestions", "plan_safe_note", "tightest", "budget_left"]


def test_dead_keys_removed_and_live_keys_kept():
    from strakalari.flet_ui.strings import STRINGS

    for key in DEAD_KEYS:
        assert key not in STRINGS, f"dead key still present: {key}"
    for key in ("need_credentials", "already_running", "bakalari_skipped_log",
                "update_open_releases", "wiz_finishing_refresh", "theme",
                "blacklist_broken_log"):
        assert STRINGS[key]["cs"] and STRINGS[key]["en"]


def test_core_messages_have_both_languages_and_same_placeholders():
    import string

    from strakalari.core.i18n import MESSAGES

    def fields(text):
        return {name for _, name, _, _ in string.Formatter().parse(text) if name}

    for key, texts in MESSAGES.items():
        assert texts.get("cs") and texts.get("en"), key
        assert fields(texts["cs"]) == fields(texts["en"]), key


def test_core_message_follows_language():
    from strakalari.core import i18n

    before = i18n.get_language()
    try:
        i18n.set_language("en")
        assert i18n.t("auto_excuses_failed", n=2) == "2 excuse(s) could not be sent"
        i18n.set_language("cs")
        assert i18n.t("auto_excuses_failed", n=2).startswith("2 omluvenek")
        assert i18n.t("bak_login_rejected").startswith("Přihlášení")  # missing fmt: raw text
    finally:
        i18n.set_language(before)
