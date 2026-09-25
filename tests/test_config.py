import os
import json
import tempfile
from strakalari.core.helpers import decrypt
from strakalari.core.automation import Strakalari
from strakalari.core.config import (
    validate_config,
    ConfigManager,
    CANONICAL_DEFAULTS,
)


class TestExampleParity:
    def test_example_keys_match_canonical(self):
        repo = os.path.join(os.path.dirname(__file__), "..", "config.example.json")
        with open(repo, "r", encoding="utf-8") as f:
            example = json.load(f)
        assert set(example) == set(CANONICAL_DEFAULTS), (
            f"missing: {sorted(set(CANONICAL_DEFAULTS) - set(example))}, "
            f"extra: {sorted(set(example) - set(CANONICAL_DEFAULTS))}"
        )


class TestValidateNewRules:
    def _base(self):
        import copy

        data = copy.deepcopy(CANONICAL_DEFAULTS)
        # Fresh-install defaults intentionally flag empty Strava creds;
        # fill them so the new rules are what this tests.
        data.update({"use_strava": True, "strava_username": "u",
                     "strava_canteen_id": "1"})
        return data

    def test_defaults_pass(self):
        assert validate_config(self._base()) == []

    def test_negative_delay_rejected(self):
        data = self._base()
        data["excuse_delay_days"] = -1
        assert any("excuse_delay_days" in p for p in validate_config(data))

    def test_bad_language_and_model_rejected(self):
        data = self._base()
        data["language"] = "de"
        data["gemini_model"] = "  "
        problems = validate_config(data)
        assert any("language" in p for p in problems)
        assert any("gemini_model" in p for p in problems)


class TestConfigManager:
    def test_missing_config_initializes_defaults_without_exit(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            fake_config_path = os.path.join(tmpdir, "non_existent_config.json")
            assert not os.path.exists(fake_config_path)

            # Should not call sys.exit(1)
            cfg = ConfigManager(fake_config_path)
            assert isinstance(cfg.data, dict)
            # Should have standard template excuses loaded
            assert "late_income_excuses" in cfg.data
            assert "short_absence_excuses" in cfg.data
            assert len(cfg.data["late_income_excuses"]) > 0

    def test_get_and_set(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "config.json")
            cfg = ConfigManager(config_path)

            cfg.set("custom_key", "custom_val")
            assert cfg.get("custom_key") == "custom_val"
            assert cfg.get("non_existent_key", "default_val") == "default_val"

    def test_set_password_auto_encryption(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "config.json")
            cfg = ConfigManager(config_path)

            raw_password = "SecretPassword123!"
            cfg.set("bakalari_password", raw_password)

            stored_val = cfg.get("bakalari_password")
            assert stored_val != raw_password
            assert cfg.get("bakalari_password_encrypted") is True

            # Decrypting should return the original password
            decrypted = decrypt(stored_val)
            assert decrypted == raw_password

    def test_prevent_double_encryption(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "config.json")
            cfg = ConfigManager(config_path)

            raw_password = "SecretPassword123!"
            cfg.set("bakalari_password", raw_password)
            encrypted_first = cfg.get("bakalari_password")

            # Setting the already-encrypted password again should NOT double encrypt
            cfg.set("bakalari_password", encrypted_first)
            assert cfg.get("bakalari_password") == encrypted_first

    def test_save_and_reload(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "config.json")
            cfg = ConfigManager(config_path)
            cfg.set("your_signature", "Jan Novák")
            cfg.save()

            assert os.path.exists(config_path)

            # Modify on disk directly
            with open(config_path, "r", encoding="utf-8") as f:
                disk_data = json.load(f)
            disk_data["your_signature"] = "Petr Svoboda"
            with open(config_path, "w", encoding="utf-8") as f:
                json.dump(disk_data, f)

            # Reload
            cfg.reload()
            assert cfg.get("your_signature") == "Petr Svoboda"

    def test_load_merges_defaults_on_partial_config(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "partial_config.json")
            # Write partial config lacking modern fields
            partial_data = {
                "bakalari_username": "student1",
                "bakalari_url": "https://skola.cz",
            }
            with open(config_path, "w", encoding="utf-8") as f:
                json.dump(partial_data, f)

            cfg = ConfigManager(config_path)
            # Custom fields preserved
            assert cfg.get("bakalari_username") == "student1"
            assert cfg.get("bakalari_url") == "https://skola.cz"
            # Missing fields automatically filled with defaults.
            assert cfg.get("excuse_mode") == "confirm"
            assert cfg.get("strava_order_mode") == "confirm"
            assert cfg.get("language") == "cs"
            assert isinstance(cfg.get("late_income_excuses"), list)

    def test_blacklist_management(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "config.json")
            bl_path = os.path.join(tmpdir, "bl.json")
            cfg = ConfigManager(config_path)
            cfg.set_and_save("strava_blacklist", bl_path)

            assert cfg.get_blacklist() == []
            assert cfg.add_blacklist_item("vepřové") is True
            assert cfg.add_blacklist_item("vepřové") is False  # duplicate
            assert "vepřové" in cfg.get_blacklist()

            assert cfg.remove_blacklist_item("vepřové") is True
            assert "vepřové" not in cfg.get_blacklist()

    def test_history_management(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "config.json")
            hist_path = os.path.join(tmpdir, "history.json")
            cfg = ConfigManager(config_path)
            cfg.set_and_save("already_excused_file", hist_path)

            assert cfg.get_excuse_history() == []
            # Write a dummy history item
            with open(hist_path, "w", encoding="utf-8") as f:
                json.dump([{"type": "income", "starting_day": "01.09.2026"}], f)

            assert len(cfg.get_excuse_history()) == 1

    def test_blacklist_example_fallback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "config.json")
            bl_path = os.path.join(tmpdir, "strava_blacklist.json")
            bl_example = os.path.join(tmpdir, "strava_blacklist.example.json")
            with open(bl_example, "w", encoding="utf-8") as f:
                json.dump(["rybí", "vepřový"], f)

            cfg = ConfigManager(config_path)
            cfg.set_and_save("strava_blacklist", bl_path)
            # A missing blacklist means "no bans" — the example template
            # must never leak into the live filter path.
            assert cfg.get_blacklist() == []

            # When saving a new item, it writes to main file
            cfg.add_blacklist_item("kuřecí")
            assert os.path.exists(bl_path)
            assert "kuřecí" in cfg.get_blacklist()

    def test_blacklist_filters_template_placeholders(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "config.json")
            bl_path = os.path.join(tmpdir, "strava_blacklist.json")
            with open(bl_path, "w", encoding="utf-8") as f:
                json.dump(["YOUR_BLACKLIST_EXAMPLE", "vepřové"], f)

            cfg = ConfigManager(config_path)
            cfg.set_and_save("strava_blacklist", bl_path)
            assert cfg.get_blacklist() == ["vepřové"]

    def test_history_example_fallback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            config_path = os.path.join(tmpdir, "config.json")
            hist_path = os.path.join(tmpdir, "already_excused_lessons.json")
            hist_example = os.path.join(tmpdir, "already_excused_lessons.example.json")
            with open(hist_example, "w", encoding="utf-8") as f:
                json.dump([{"type": "pure days", "starting_day": "01.09.2026"}], f)

            cfg = ConfigManager(config_path)
            cfg.set_and_save("already_excused_file", hist_path)
            # Main file does not exist yet, fallback reads from example
            assert len(cfg.get_excuse_history()) == 1


class TestPasswordOverridesEncrypted:
    def test_plaintext_override_decrypts(self):
        from strakalari.core.helpers import decrypt_strict
        app = Strakalari(config_data={"bakalari_password": "tajneheslo123"},
                         start_browser=False)
        try:
            stored = app.config_manager.data["bakalari_password"]
            assert app.config_manager.data["bakalari_password_encrypted"] is True
            assert decrypt_strict(stored) == "tajneheslo123"
        finally:
            app.close()


class TestLegacyAliasValidation:
    def test_legacy_aliases_pass(self):
        from strakalari.core.config import validate_config
        problems = validate_config(
            {"use_strava": True, "strava_user": "s", "strava_id": "1"})
        assert not any("Strava" in p for p in problems)

    def test_missing_both_still_flagged(self):
        from strakalari.core.config import validate_config
        problems = validate_config({"use_strava": True})
        assert any("username" in p for p in problems)
        assert any("canteen" in p for p in problems)


class TestValidatorGaps:
    def _base(self):
        import copy
        from strakalari.core.config import CANONICAL_DEFAULTS
        data = copy.deepcopy(CANONICAL_DEFAULTS)
        data.update({"use_strava": True, "strava_username": "u",
                     "strava_canteen_id": "1"})
        return data

    def test_bad_excuse_selection_rejected(self):
        from strakalari.core.config import validate_config
        data = self._base()
        data["default_excuse_selection"] = "sometimes"
        assert any("default_excuse_selection" in p
                   for p in validate_config(data))

    def test_week_caps_rejected(self):
        from strakalari.core.config import validate_config
        data = self._base()
        data["go_back_weeks"] = 99
        data["go_forward_weeks"] = 99
        problems = validate_config(data)
        assert any("go_back_weeks" in p for p in problems)
        assert any("go_forward_weeks" in p for p in problems)

    def test_week_caps_accept_bounds(self):
        from strakalari.core.config import validate_config
        data = self._base()
        data["go_back_weeks"] = 52
        data["go_forward_weeks"] = 8
        assert validate_config(data) == []

    def test_explicit_null_keeps_default(self, tmp_path):
        import json
        from strakalari.core.config import ConfigManager
        cfg_path = tmp_path / "c.json"
        cfg_path.write_text(json.dumps({"theme": None, "go_back_weeks": None,
                                        "language": "en"}), encoding="utf-8")
        mgr = ConfigManager(str(cfg_path))
        assert mgr.data["theme"] == "dark"
        assert mgr.data["go_back_weeks"] == 4
        assert mgr.data["language"] == "en"


class TestExampleFiles:
    def test_repo_example_files_are_valid(self):
        import json
        import pathlib
        root = pathlib.Path(__file__).resolve().parent.parent
        for name in ("already_excused_lessons.example.json",
                     "strava_blacklist.example.json"):
            data = json.loads((root / name).read_text(encoding="utf-8"))
            assert isinstance(data, list), name


class TestCanonicalConfig:
    def test_legacy_keys_are_ignored(self):
        mgr = ConfigManager.__new__(ConfigManager)
        mgr.data = dict(CANONICAL_DEFAULTS)
        mgr.data.update({
            "strava_enable": False,
            "strava_user": "jan",
            "strava_id": "1234",
            "confirm_excuses": False,
        })
        # No migration: canonical values stand, legacy keys unread.
        assert mgr.get("use_strava") is True
        assert mgr.get("strava_username") == ""
        assert mgr.get("excuse_mode") == "confirm"

    def test_canonical_keys_used_verbatim(self):
        mgr = ConfigManager.__new__(ConfigManager)
        mgr.data = dict(CANONICAL_DEFAULTS)
        mgr.data.update({"use_strava": False, "excuse_mode": "auto"})
        assert mgr.get("use_strava") is False
        assert mgr.get("excuse_mode") == "auto"

    def test_validate_catches_bad_mode_and_thresholds(self):
        problems = validate_config({
            "bakalari_username": "x", "bakalari_url": "",
            "use_strava": False, "excuse_mode": "sometimes",
            "strava_order_mode": "confirm",
            "absence_warn_pct": 30, "absence_critical_pct": 20,
            "theme": "neon",
        })
        assert any("excuse_mode" in p for p in problems)
        assert any("warn" in p.lower() or "threshold" in p.lower() for p in problems)
        assert any("Theme" in p for p in problems)

    def test_manager_set_get_canonical(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            cfg = ConfigManager(os.path.join(tmpdir, "c.json"))
            cfg.set("strava_canteen_id", "999")
            assert cfg.get("strava_canteen_id") == "999"
            cfg.set("excuse_mode", "auto")
            assert cfg.get("excuse_mode") == "auto"


class TestFirstRunKeys:
    def test_strava_only_credentials_recognized(self):
        from strakalari.core.config import has_valid_credentials
        bak, strava = has_valid_credentials({
            "bakalari_username": "", "bakalari_url": "",
            "strava_username": "student", "strava_canteen_id": "1950",
        })
        assert bak is False
        assert strava is True

    def test_legacy_strava_alias_recognized(self):
        from strakalari.core.config import has_valid_credentials
        bak, strava = has_valid_credentials({
            "bakalari_username": "", "bakalari_url": "",
            "strava_user": "student", "strava_id": "1950",
        })
        assert bak is False
        assert strava is True

    def test_example_placeholders_rejected(self):
        from strakalari.core.config import has_valid_credentials
        bak, strava = has_valid_credentials({
            "bakalari_username": "VAS_BAKALARI_LOGIN",
            "bakalari_url": "https://vas-bakalari-portal.cz",
            "strava_username": "x", "strava_canteen_id": "CISLO_JIDELNY",
        })
        assert (bak, strava) == (False, False)


class TestCredentialsPlaceholders:
    def test_example_strava_login_rejected(self):
        from strakalari.core.config import has_valid_credentials
        bak, strava = has_valid_credentials({
            "bakalari_username": "student", "bakalari_url": "https://skola.cz",
            "strava_username": "VAS_STRAVA_LOGIN", "strava_canteen_id": "1950",
        })
        assert bak is True
        assert strava is False

    def test_real_credentials_accepted(self):
        from strakalari.core.config import has_valid_credentials
        bak, strava = has_valid_credentials({
            "bakalari_username": "novak", "bakalari_url": "https://skola.cz",
            "strava_username": "novak", "strava_canteen_id": "1950",
        })
        assert (bak, strava) == (True, True)


def test_new_canonical_keys():
    from strakalari.core.config import CANONICAL_DEFAULTS
    import json

    assert CANONICAL_DEFAULTS["timetable_view"] == "table"
    assert CANONICAL_DEFAULTS["compact_density"] is False
    example = json.load(open("config.example.json", encoding="utf-8"))
    assert set(example) == set(CANONICAL_DEFAULTS)


def test_has_valid_credentials_strava_only():
    from strakalari.core.config import has_valid_credentials

    cfg = {"bakalari_url": "", "bakalari_username": "",
           "strava_username": "novak", "strava_canteen_id": "123"}
    assert has_valid_credentials(cfg) == (False, True)


def test_integer_strava_id_handling():
    from strakalari.core.automation import Strakalari
    bot = Strakalari(config_data={"strava_canteen_id": 9876, "use_strava": False}, start_browser=False)
    assert bot.strava_id == "9876"
    assert isinstance(bot.strava_id, str)


class TestStravaEnableDefault:
    def test_partial_config_without_use_strava_stays_enabled(self, tmp_path):
        from strakalari.core.automation import Strakalari

        app = Strakalari(
            config_file=str(tmp_path / "config.json"),
            config_data={"bakalari_url": "https://example.test"},
            start_browser=False,
        )
        assert app.strava_enable is True
        assert app.strava_client.strava_enable is True
