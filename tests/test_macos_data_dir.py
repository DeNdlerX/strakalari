"""Frozen macOS app keeps its data out of the .app bundle.

Older builds wrote config, key and cache next to the executable, i.e.
inside Strakalari.app whenever that was writable (admin install in
/Applications): an update replacing the bundle wiped it all. Now the
data lives in ~/Library/Application Support/Strakalari and old bundle
data is copied over once, along with the password key.
"""

import json
import os
import sys
# Imported before any test fakes sys.platform = "darwin": a first import
# under the fake would reach for macOS-only _scproxy (via keyring).
import urllib.request  # noqa: F401

import pytest

from strakalari.core import helpers, secret_store


@pytest.fixture
def mac(monkeypatch, tmp_path):
    """A frozen macOS app in a writable bundle, with a throwaway home."""
    home = tmp_path / "home"
    home.mkdir()
    bundle = tmp_path / "Applications" / "Strakalari.app" / "Contents" / "MacOS"
    bundle.mkdir(parents=True)
    monkeypatch.delenv("STRAKALARI_DATA_DIR", raising=False)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("USERPROFILE", str(home))  # expanduser on Windows
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(bundle / "Strakalari"))
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(helpers, "_MACOS_DATA_DIRS", {})
    secret_store.clear_cache()
    yield bundle, home / "Library" / "Application Support" / "Strakalari"
    secret_store.clear_cache()


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _same(a, b):
    return os.path.normcase(os.path.normpath(str(a))) == os.path.normcase(os.path.normpath(str(b)))


def _use_bundle(monkeypatch):
    """Resolve to the bundle dir, as an older build did."""
    key = (helpers._install_dir(), helpers._platform_data_dir())
    monkeypatch.setattr(helpers, "_MACOS_DATA_DIRS", {key: key[0]})


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def test_fresh_install_uses_application_support(mac):
    bundle, support = mac
    assert _same(helpers.get_user_data_dir(), str(support))
    assert support.is_dir()
    assert _same(helpers._resolve_path("./config.json"), support / "config.json")
    assert not any(bundle.iterdir())


def test_old_bundle_data_is_moved_once(mac):
    bundle, support = mac
    _write(bundle / "config.json", json.dumps({
        "strava_blacklist": "./my_blacklist.json",
        "already_excused_file": "/abs/elsewhere.json",
        "log_file": "../outside.txt",
    }))
    for name in ("data_cache.json", "automation_history.jsonl", "log.txt",
                 "already_excused_lessons.json", "my_blacklist.json"):
        _write(bundle / name, name)
    _write(bundle / "school_presets" / "mine.json", "preset")
    _write(bundle / "session.lock", "")  # locks are not data

    assert _same(helpers.get_user_data_dir(), str(support))
    assert json.loads(_read(support / "config.json"))["strava_blacklist"] == "./my_blacklist.json"
    for name in ("data_cache.json", "automation_history.jsonl", "log.txt",
                 "already_excused_lessons.json", "my_blacklist.json"):
        assert _read(support / name) == name
    assert _read(support / "school_presets" / "mine.json") == "preset"
    assert not (support / "session.lock").exists()
    assert not (support.parent / "outside.txt").exists()
    # The bundle copy stays (an older build may still run from it).
    assert (bundle / "config.json").exists()


def test_existing_application_support_data_wins(mac):
    bundle, support = mac
    _write(bundle / "config.json", '{"from": "bundle"}')
    _write(bundle / "data_cache.json", "bundle")
    _write(support / "config.json", '{"from": "support"}')
    assert _same(helpers.get_user_data_dir(), str(support))
    assert json.loads(_read(support / "config.json")) == {"from": "support"}
    assert not (support / "data_cache.json").exists()


def test_moved_passwords_still_decrypt_with_key_file(mac, monkeypatch):
    bundle, support = mac
    monkeypatch.setenv("STRAKALARI_NO_KEYRING", "1")
    _write(bundle / "config.json", "{}")
    # Encrypt under the bundle dir, as an older build did.
    _use_bundle(monkeypatch)
    token = helpers.encrypt("hunter2")
    assert (bundle / "secret.key").exists()

    monkeypatch.setattr(helpers, "_MACOS_DATA_DIRS", {})
    secret_store.clear_cache()
    assert _same(helpers.get_user_data_dir(), str(support))
    assert helpers.decrypt(token) == "hunter2"


def test_moved_passwords_still_decrypt_with_keychain(mac, monkeypatch):
    import keyring

    from tests.test_secret_store import MemoryKeyring

    bundle, support = mac
    backend = MemoryKeyring()
    previous = keyring.get_keyring()
    keyring.set_keyring(backend)
    monkeypatch.delenv("STRAKALARI_NO_KEYRING", raising=False)
    try:
        _write(bundle / "config.json", "{}")
        _use_bundle(monkeypatch)
        token = helpers.encrypt("hunter2")
        assert not (bundle / "secret.key").exists()  # key sits in the store

        monkeypatch.setattr(helpers, "_MACOS_DATA_DIRS", {})
        secret_store.clear_cache()
        assert _same(helpers.get_user_data_dir(), str(support))
        assert helpers.decrypt(token) == "hunter2"
        assert not (support / "secret.key").exists()  # carried store to store
    finally:
        keyring.set_keyring(previous)


def test_locked_keychain_keeps_bundle_for_this_run(mac, monkeypatch):
    bundle, support = mac
    _write(bundle / "config.json", "{}")
    monkeypatch.setattr(secret_store, "carry_key", lambda old, new: False)
    assert _same(helpers.get_user_data_dir(), str(bundle))
    # Not marked done: the next launch tries again.
    assert not (support / "config.json").exists()
    monkeypatch.setattr(helpers, "_MACOS_DATA_DIRS", {})
    monkeypatch.setattr(secret_store, "carry_key", lambda old, new: True)
    assert _same(helpers.get_user_data_dir(), str(support))
    assert (support / "config.json").exists()


def test_data_dir_override_still_wins(mac, monkeypatch, tmp_path):
    bundle, _support = mac
    _write(bundle / "config.json", "{}")
    monkeypatch.setenv("STRAKALARI_DATA_DIR", str(tmp_path / "custom"))
    assert _same(helpers.get_user_data_dir(), str(tmp_path / "custom"))


def test_windows_portable_dir_unchanged(monkeypatch, tmp_path):
    exe_dir = tmp_path / "Strakalari"
    exe_dir.mkdir()
    monkeypatch.delenv("STRAKALARI_DATA_DIR", raising=False)
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", str(exe_dir / "Strakalari.exe"))
    monkeypatch.setattr(sys, "platform", "win32")
    assert _same(helpers.get_user_data_dir(), str(exe_dir))


def test_source_run_uses_repo_root(monkeypatch):
    monkeypatch.delenv("STRAKALARI_DATA_DIR", raising=False)
    monkeypatch.delattr(sys, "frozen", raising=False)
    monkeypatch.setattr(sys, "platform", "darwin")
    assert _same(helpers.get_user_data_dir(), helpers.PROJECT_ROOT)
