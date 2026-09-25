"""The password-encryption key lives in the OS credential store."""
import keyring
import pytest
from keyring.backend import KeyringBackend

from strakalari.core import secret_store
from strakalari.core.helpers import decrypt, encrypt, get_user_data_dir


class MemoryKeyring(KeyringBackend):
    priority = 1

    def __init__(self):
        super().__init__()
        self.store = {}
        self.fail_get = None

    def get_password(self, service, username):
        if self.fail_get:
            raise self.fail_get
        return self.store.get((service, username))

    def set_password(self, service, username, password):
        self.store[(service, username)] = password

    def delete_password(self, service, username):
        self.store.pop((service, username), None)


@pytest.fixture
def store(monkeypatch):
    backend = MemoryKeyring()
    previous = keyring.get_keyring()
    keyring.set_keyring(backend)
    monkeypatch.delenv("STRAKALARI_NO_KEYRING", raising=False)
    secret_store.clear_cache()
    yield backend
    keyring.set_keyring(previous)
    secret_store.clear_cache()


def _key_file():
    import os

    return os.path.join(get_user_data_dir(), "secret.key")


def test_new_key_goes_to_the_store_not_a_file(store):
    import os

    token = encrypt("hunter2")
    assert not os.path.exists(_key_file())
    assert len(store.store) == 1
    secret_store.clear_cache()
    assert decrypt(token) == "hunter2"
    assert secret_store.storage_location(get_user_data_dir()) == "keyring"


def test_existing_key_file_is_migrated_and_deleted(store, monkeypatch):
    import os

    monkeypatch.setenv("STRAKALARI_NO_KEYRING", "1")
    token = encrypt("hunter2")
    assert os.path.exists(_key_file())
    secret_store.clear_cache()
    monkeypatch.delenv("STRAKALARI_NO_KEYRING")

    assert decrypt(token) == "hunter2"
    assert not os.path.exists(_key_file())
    assert len(store.store) == 1
    secret_store.clear_cache()
    assert decrypt(token) == "hunter2"


def test_copied_folder_without_store_entry_cannot_decrypt(store, monkeypatch, tmp_path):
    token = encrypt("hunter2")
    # Another machine/user: same files, empty credential store.
    store.store.clear()
    secret_store.clear_cache()
    from strakalari.core.helpers import decrypt_strict

    assert decrypt_strict(token) is None


def test_locked_store_with_file_uses_file(store, monkeypatch):
    monkeypatch.setenv("STRAKALARI_NO_KEYRING", "1")
    token = encrypt("hunter2")
    secret_store.clear_cache()
    monkeypatch.delenv("STRAKALARI_NO_KEYRING")
    store.fail_get = keyring.errors.KeyringLocked("locked")
    assert decrypt(token) == "hunter2"


def test_locked_store_without_file_fails_loudly(store):
    store.fail_get = keyring.errors.KeyringLocked("locked")
    with pytest.raises(secret_store.KeyStoreUnavailable):
        encrypt("hunter2")


def test_different_file_and_store_keys_prefer_file(store, monkeypatch):
    import os

    encrypt("x")  # creates a store key
    secret_store.clear_cache()
    monkeypatch.setenv("STRAKALARI_NO_KEYRING", "1")
    token = encrypt("hunter2")  # separate file key (e.g. restored backup)
    assert os.path.exists(_key_file())
    secret_store.clear_cache()
    monkeypatch.delenv("STRAKALARI_NO_KEYRING")
    assert decrypt(token) == "hunter2"
    assert os.path.exists(_key_file())


def test_no_backend_falls_back_to_file(monkeypatch):
    import os

    from keyring.backends import fail

    previous = keyring.get_keyring()
    keyring.set_keyring(fail.Keyring())
    monkeypatch.delenv("STRAKALARI_NO_KEYRING", raising=False)
    secret_store.clear_cache()
    try:
        token = encrypt("hunter2")
        assert os.path.exists(_key_file())
        assert decrypt(token) == "hunter2"
    finally:
        keyring.set_keyring(previous)
        secret_store.clear_cache()


def test_entry_is_bound_to_the_data_dir(tmp_path):
    assert secret_store._entry_name(str(tmp_path / "a")) != secret_store._entry_name(str(tmp_path / "b"))
