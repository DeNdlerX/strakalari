"""Store (MSIX) build behaviour: no GitHub update checks, no Run-key
autostart, and no writes into the read-only package dir."""

import importlib.util
import json
import os
import sys

import keyring
import pytest

import strakalari.core.packaging as packaging
from strakalari.core import autostart, helpers, secret_store, update


@pytest.fixture()
def packaged(monkeypatch):
    """Pretend we run inside the Store MSIX package."""
    monkeypatch.setattr(packaging, "is_store_package", lambda: True)
    return packaging


@pytest.fixture()
def unpackaged(monkeypatch):
    """Pretend we run as the classic install (also clears the cache)."""
    monkeypatch.setattr(packaging, "_has_package_identity", lambda: False)
    packaging.is_store_package.cache_clear()
    yield packaging
    packaging.is_store_package.cache_clear()


@pytest.fixture()
def store_install(packaged, monkeypatch, tmp_path):
    """Frozen Store exe in its package dir, with a throwaway LOCALAPPDATA.

    The package dir is writable here, as os.access claims for every
    directory on Windows: the data must still not land in it.
    """
    package = tmp_path / "WindowsApps" / "Strakalari_1.0.0.0_x64__abc"
    package.mkdir(parents=True)
    local = tmp_path / "Local"
    local.mkdir()
    monkeypatch.delenv("STRAKALARI_DATA_DIR", raising=False)
    monkeypatch.setenv("LOCALAPPDATA", str(local))
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(package / "Strakalari.exe"))
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(helpers, "_STORE_DATA_DIRS", set())
    secret_store.clear_cache()
    yield package, local
    secret_store.clear_cache()


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _same(a, b):
    return os.path.normcase(os.path.normpath(str(a))) == os.path.normcase(os.path.normpath(str(b)))


class TestPackageDetection:
    def test_unpackaged_here(self, unpackaged):
        assert unpackaged.is_store_package() is False

    def test_dev_run_never_counts(self, monkeypatch):
        # The Microsoft Store's python.exe has a package identity too.
        monkeypatch.setattr(packaging, "_has_package_identity", lambda: True)
        monkeypatch.delattr(sys, "frozen", raising=False)
        packaging.is_store_package.cache_clear()
        try:
            assert packaging.is_store_package() is False
        finally:
            packaging.is_store_package.cache_clear()

    def test_frozen_with_identity(self, monkeypatch):
        monkeypatch.setattr(packaging, "_has_package_identity", lambda: True)
        monkeypatch.setattr(sys, "frozen", True, raising=False)
        packaging.is_store_package.cache_clear()
        try:
            assert packaging.is_store_package() is True
        finally:
            packaging.is_store_package.cache_clear()

    def test_legacy_dir_absent(self, unpackaged, monkeypatch, tmp_path):
        monkeypatch.setenv("LOCALAPPDATA", str(tmp_path))
        monkeypatch.delenv("APPDATA", raising=False)
        assert packaging.legacy_desktop_data_dir() is None


class TestStoreDataDir:
    def test_never_the_package_dir(self, store_install):
        package, local = store_install
        assert _same(helpers.get_user_data_dir(), local / "Strakalari")
        assert not any(package.iterdir())

    def test_classic_install_data_is_copied(self, store_install):
        _package, local = store_install
        legacy = local / "Programs" / "Strakalari"
        _write(legacy / "config.json", json.dumps({"school": "x"}))
        _write(legacy / "automation_history.jsonl", "history")
        target = local / "Strakalari"
        assert _same(helpers.get_user_data_dir(), target)
        assert json.loads((target / "config.json").read_text("utf-8")) == {"school": "x"}
        assert (target / "automation_history.jsonl").read_text("utf-8") == "history"
        # The classic install keeps its own copy.
        assert (legacy / "config.json").exists()

    def test_copied_passwords_decrypt_with_credential_manager(self, store_install, monkeypatch):
        from tests.test_secret_store import MemoryKeyring

        _package, local = store_install
        legacy = local / "Programs" / "Strakalari"
        _write(legacy / "config.json", "{}")
        previous = keyring.get_keyring()
        keyring.set_keyring(MemoryKeyring())
        monkeypatch.delenv("STRAKALARI_NO_KEYRING", raising=False)
        try:
            # Encrypted by the classic install: key bound to its dir path.
            monkeypatch.setenv("STRAKALARI_DATA_DIR", str(legacy))
            token = helpers.encrypt("hunter2")
            assert not (legacy / "secret.key").exists()
            monkeypatch.delenv("STRAKALARI_DATA_DIR")
            secret_store.clear_cache()

            assert _same(helpers.get_user_data_dir(), local / "Strakalari")
            assert helpers.decrypt(token) == "hunter2"
        finally:
            keyring.set_keyring(previous)

    def test_existing_store_data_wins(self, store_install):
        _package, local = store_install
        _write(local / "Programs" / "Strakalari" / "config.json", '{"from": "classic"}')
        _write(local / "Strakalari" / "config.json", '{"from": "store"}')
        helpers.get_user_data_dir()
        assert json.loads((local / "Strakalari" / "config.json").read_text("utf-8")) == {"from": "store"}


class TestUpdateGate:
    def test_check_returns_none_without_network(self, packaged, monkeypatch):
        def _boom(*a, **k):
            raise AssertionError("no network in Store builds")

        monkeypatch.setattr(update, "fetch_releases", _boom)
        assert update.check_for_updates() is None
        assert update.check_for_updates(force=True) is None

    def test_cached_hidden(self, packaged):
        assert update.load_cached() is None

    def test_gate_off_for_classic(self, unpackaged):
        assert update.updates_managed_externally() is False


class TestAutostartGate:
    def test_set_refused(self, packaged):
        assert autostart.set_autostart(True) is False
        assert autostart.set_autostart(False) is False

    def test_enabled_unknown(self, packaged):
        assert autostart.is_autostart_enabled() is False


def _load_tool(name):
    path = os.path.join(os.path.dirname(__file__), "..", "tools", f"{name}.py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestMsixVersion:
    def test_three_parts(self):
        assert _load_tool("make_msix").msix_version("0.2.0") == "0.2.0.0"

    def test_two_parts(self):
        assert _load_tool("make_msix").msix_version("v1.2") == "1.2.0.0"

    def test_prerelease_refused(self):
        with pytest.raises(SystemExit):
            _load_tool("make_msix").msix_version("0.2.0-beta.1")

    def test_manifest_template_tokens(self):
        path = os.path.join(
            os.path.dirname(__file__), "..", "msix", "AppxManifest.xml")
        with open(path, encoding="utf-8-sig") as handle:
            template = handle.read()
        for token in ("@IDENTITY_NAME@", "@PUBLISHER@", "@VERSION@",
                      "@ARCH@", "@PUBLISHER_DISPLAY@"):
            assert token in template
        assert "runFullTrust" in template
        assert "windows.startupTask" in template
        # Autostart opens the tray, not the window (as the Run value does).
        assert 'uap10:Parameters="--minimized"' in template


def test_store_submit_loads():
    # Stdlib only: the publish job runs it on a bare runner.
    assert "preprocessing" in _load_tool("store_submit").COMMITTED_STATES
