"""Tests for the GitHub release check (strakalari.core.update)."""

import json

import strakalari.core.update as update


class TestParseVersion:
    def test_simple(self):
        assert update.parse_version("1.2.3") == (1, 2, 3)

    def test_strips_v_prefix(self):
        assert update.parse_version("v1.2.3") == (1, 2, 3)

    def test_ignores_suffix(self):
        assert update.parse_version("1.2.3-beta") == (1, 2, 3)

    def test_empty_is_zero(self):
        assert update.parse_version("") == (0,)


class TestIsNewer:
    def test_newer_patch(self):
        assert update.is_newer("1.0.1", "1.0.0") is True

    def test_same_is_not_newer(self):
        assert update.is_newer("1.0.0", "1.0.0") is False

    def test_older_is_not_newer(self):
        assert update.is_newer("0.9.9", "1.0.0") is False

    def test_tag_prefix_ignored(self):
        assert update.is_newer("v2.0.0", "1.9.9") is True

    def test_newer_major(self):
        assert update.is_newer("2.0.0", "1.99.99") is True

    def test_stable_is_newer_than_its_beta(self):
        assert update.is_newer("0.1.0", "0.1.0-beta.1") is True
        assert update.is_newer("0.1.0-beta.1", "0.1.0") is False

    def test_beta_is_newer_than_previous_stable(self):
        assert update.is_newer("0.2.0-beta.1", "0.1.0") is True

    def test_beta_numbers_compare_numerically(self):
        assert update.is_newer("0.1.0-beta.10", "0.1.0-beta.9") is True
        assert update.is_newer("0.1.0-beta10", "0.1.0-beta9") is True

    def test_rc_after_beta(self):
        assert update.is_newer("0.1.0-rc.1", "0.1.0-beta.3") is True

    def test_trailing_zeros_equal(self):
        assert update.is_newer("0.1.0", "0.1") is False
        assert update.is_newer("0.1", "0.1.0") is False

    def test_old_dev_build_sees_first_beta(self):
        assert update.is_newer("0.1.0-beta.1", "0.0.1") is True


class TestPrereleaseVersion:
    def test_detects_suffix(self):
        assert update.is_prerelease_version("v0.1.0-beta.1") is True
        assert update.is_prerelease_version("1.0.0rc1") is True

    def test_plain_is_stable(self):
        assert update.is_prerelease_version("v1.2.3") is False
        assert update.is_prerelease_version("1.2.3+build5") is False


class TestNormalizeChannel:
    def test_values(self):
        assert update.normalize_channel("beta") == "beta"
        assert update.normalize_channel("BETA ") == "beta"
        assert update.normalize_channel("stable") == "stable"
        assert update.normalize_channel(None) == "stable"
        assert update.normalize_channel("nightly") == "stable"


def _rel(tag, prerelease=False, draft=False):
    return {
        "tag_name": tag,
        "html_url": f"https://github.com/DeNdlerX/strakalari/releases/tag/{tag}",
        "name": tag,
        "prerelease": prerelease,
        "draft": draft,
        "published_at": "2026-01-01T00:00:00Z",
    }


class TestPickRelease:
    RELEASES = [
        _rel("v0.3.0", draft=True),
        _rel("v0.2.0-beta.1", prerelease=True),
        _rel("v0.1.0"),
        _rel("v0.1.0-beta.2", prerelease=True),
    ]

    def test_stable_skips_prereleases_and_drafts(self):
        assert update.pick_release(self.RELEASES, "stable")["version"] == "0.1.0"

    def test_beta_takes_newest_of_both(self):
        info = update.pick_release(self.RELEASES, "beta")
        assert info["version"] == "0.2.0-beta.1"
        assert info["prerelease"] is True

    def test_beta_includes_stable_when_it_is_newest(self):
        releases = [_rel("v0.1.0-beta.1", prerelease=True), _rel("v0.1.0")]
        assert update.pick_release(releases, "beta")["version"] == "0.1.0"

    def test_suffix_counts_as_prerelease_even_without_flag(self):
        releases = [_rel("v0.1.0-beta.1")]
        assert update.pick_release(releases, "stable") is None
        assert update.pick_release(releases, "beta")["version"] == "0.1.0-beta.1"

    def test_only_betas_stable_gets_none(self):
        releases = [_rel("v0.1.0-beta.1", prerelease=True)]
        assert update.pick_release(releases, "stable") is None

    def test_empty(self):
        assert update.pick_release([], "beta") is None


class _FakeResponse:
    def __init__(self, payload):
        self._payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def read(self):
        return json.dumps(self._payload).encode("utf-8")


class TestFetchLatestRelease:
    def test_success(self, monkeypatch):
        payload = [_rel("v1.2.3"), _rel("v1.3.0-beta.1", prerelease=True)]
        monkeypatch.setattr(update.urllib.request, "urlopen",
                            lambda req, timeout=None: _FakeResponse(payload))
        info = update.fetch_latest_release()
        assert info is not None
        assert info["version"] == "1.2.3"
        assert info["url"].endswith("v1.2.3")
        beta = update.fetch_latest_release("beta")
        assert beta["version"] == "1.3.0-beta.1"

    def test_uses_list_endpoint(self, monkeypatch):
        seen = {}

        def _open(req, timeout=None):
            seen["url"] = req.full_url
            return _FakeResponse([])

        monkeypatch.setattr(update.urllib.request, "urlopen", _open)
        assert update.fetch_latest_release("beta") is None
        # /releases/latest never returns pre-releases.
        assert "/releases/latest" not in seen["url"]
        assert "/releases" in seen["url"]

    def test_network_failure_returns_none(self, monkeypatch):
        def _boom(req, timeout=None):
            raise OSError("offline")

        monkeypatch.setattr(update.urllib.request, "urlopen", _boom)
        assert update.fetch_latest_release() is None

    def test_non_list_payload_returns_none(self, monkeypatch):
        monkeypatch.setattr(update.urllib.request, "urlopen",
                            lambda req, timeout=None: _FakeResponse({"message": "Not Found"}))
        assert update.fetch_latest_release() is None


class TestCheckForUpdates:
    def test_one_fetch_serves_both_channels(self, monkeypatch):
        calls = []
        payload = [_rel("v0.1.0-beta.1", prerelease=True), _rel("v0.0.9")]

        def _open(req, timeout=None):
            calls.append(1)
            return _FakeResponse(payload)

        monkeypatch.setattr(update.urllib.request, "urlopen", _open)
        assert update.check_for_updates(channel="stable")["version"] == "0.0.9"
        # Fresh cache: switching channel needs no new request.
        assert update.check_for_updates(channel="beta")["version"] == "0.1.0-beta.1"
        assert len(calls) == 1
        assert update.load_cached("beta")["version"] == "0.1.0-beta.1"
        assert update.load_cached("stable")["version"] == "0.0.9"

    def test_failure_keeps_stale_cache(self, monkeypatch):
        update.save_cached({"stable": {"version": "1.0.0"}, "beta": None}, checked_at=0)

        def _boom(req, timeout=None):
            raise OSError("offline")

        monkeypatch.setattr(update.urllib.request, "urlopen", _boom)
        assert update.check_for_updates(channel="stable")["version"] == "1.0.0"
        assert update.check_for_updates(channel="beta") is None

    def test_legacy_cache_format_is_ignored(self, monkeypatch):
        import os

        path = update._cache_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"version": "9.9.9", "checked_at": 9e12}, fh)
        assert update.load_cached("stable") is None


class TestCache:
    def test_should_check_no_cache(self):
        assert update.should_check(None) is True

    def test_should_check_fresh(self):
        import time

        assert update.should_check({"checked_at": time.time()}) is False

    def test_should_check_stale(self):
        import time

        old = {"checked_at": time.time() - update.CHECK_INTERVAL_S - 1}
        assert update.should_check(old) is True


class TestUpdateAvailable:
    def test_detects_newer(self, monkeypatch):
        monkeypatch.setattr(update, "get_current_version", lambda: "1.0.0")
        assert update.update_available({"version": "1.0.1"}) is True

    def test_same_version_not_available(self, monkeypatch):
        monkeypatch.setattr(update, "get_current_version", lambda: "1.0.0")
        assert update.update_available({"version": "1.0.0"}) is False

    def test_none_info(self, monkeypatch):
        monkeypatch.setattr(update, "get_current_version", lambda: "1.0.0")
        assert update.update_available(None) is False


class TestStrings:
    def test_update_keys_have_both_languages(self):
        from strakalari.flet_ui.strings import STRINGS

        for key in (
            "update_available", "update_desc", "download_update",
            "check_updates", "checking_updates", "app_version",
            "latest_version", "up_to_date", "update_dismiss",
            "update_open_releases", "update_channel", "update_channel_stable",
            "update_channel_beta", "update_channel_hint",
        ):
            assert key in STRINGS, f"missing UI string: {key}"
            assert STRINGS[key]["cs"] and STRINGS[key]["en"]


class TestChannelState:
    def test_default_channel_follows_build(self, monkeypatch):
        monkeypatch.setattr(update, "get_current_version", lambda: "0.2.0-beta.1")
        assert update.default_channel() == "beta"
        monkeypatch.setattr(update, "get_current_version", lambda: "0.2.0")
        assert update.default_channel() == "stable"

    def test_fresh_config_defaults_to_build_channel(self, monkeypatch, tmp_path):
        from strakalari.core.config import ConfigManager

        monkeypatch.setattr(update, "get_current_version", lambda: "0.2.0-beta.1")
        assert ConfigManager(str(tmp_path / "b.json")).get("update_channel") == "beta"
        monkeypatch.setattr(update, "get_current_version", lambda: "0.2.0")
        assert ConfigManager(str(tmp_path / "s.json")).get("update_channel") == "stable"

    def test_first_install_channel_sticks_after_upgrade(self, monkeypatch, tmp_path):
        from strakalari.core.config import ConfigManager

        path = str(tmp_path / "config.json")
        monkeypatch.setattr(update, "get_current_version", lambda: "0.2.0-beta.1")
        first = ConfigManager(path)
        first.set_and_save("language", "en")  # any first save persists it
        # Upgrading to a stable build keeps the beta channel.
        monkeypatch.setattr(update, "get_current_version", lambda: "0.2.0")
        upgraded = ConfigManager(path)
        assert upgraded.get("update_channel") == "beta"
        upgraded.set_and_save("language", "cs")
        assert ConfigManager(path).get("update_channel") == "beta"

    def test_switch_channel_updates_banner(self, app_state, monkeypatch):
        monkeypatch.setattr(update, "get_current_version", lambda: "0.0.1")
        update.save_cached(
            {"stable": None, "beta": {"version": "0.1.0-beta.1", "url": "u"}},
        )
        monkeypatch.setattr(app_state, "_spawn", lambda *a, **k: None)
        assert app_state.update_banner is None
        assert app_state.set_update_channel("beta") is True
        assert app_state.get("update_channel") == "beta"
        assert app_state.update_banner["version"] == "0.1.0-beta.1"
        assert app_state.set_update_channel("stable") is True
        assert app_state.update_banner is None

    def test_settings_diagnostics_builds_with_channel(self, state):
        from strakalari.flet_ui.views.settings import SettingsView

        assert SettingsView(state, None)._diagnostics()


class TestConfigChannel:
    def test_validation(self):
        from strakalari.core.config import validate_config

        assert not any("update_channel" in p for p in validate_config({"update_channel": "beta"}))
        assert any("update_channel" in p for p in validate_config({"update_channel": "nightly"}))
