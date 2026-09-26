"""log.txt never receives a stored password or API key in the clear."""

from strakalari.core.automation import Strakalari
from strakalari.core.error_report import REDACTED, secret_values
from strakalari.core.helpers import encrypt


def _app(tmp_path, config):
    app = Strakalari.__new__(Strakalari)
    app.encoding = "utf-8"
    app.logFile = str(tmp_path / "log.txt")
    app.on_log = None
    app.config_data = config
    return app


def test_plaintext_and_ciphertext_secrets_are_scrubbed(tmp_path):
    cipher = encrypt("hunter2-secret")
    app = _app(tmp_path, {"bakalari_password": cipher, "bakalari_password_encrypted": True,
                          "bakalari_username": "novak.jan"})
    seen = []
    app.on_log = seen.append
    app.write_log(f"fill('#password', 'hunter2-secret') failed; raw={cipher}")
    text = (tmp_path / "log.txt").read_text(encoding="utf-8")
    assert "hunter2-secret" not in text
    assert cipher not in text
    assert REDACTED in text
    assert "hunter2-secret" not in seen[0]
    # Not a report: the user's own name may stay in their own log.
    app.write_log("user novak.jan logged in")
    assert "novak.jan" in (tmp_path / "log.txt").read_text(encoding="utf-8")


def test_cache_follows_a_changed_password(tmp_path):
    app = _app(tmp_path, {"strava_password": "old-pass-1", "strava_password_encrypted": False})
    app.write_log("old-pass-1")
    app.config_data["strava_password"] = "new-pass-2"
    app.write_log("new-pass-2")
    text = (tmp_path / "log.txt").read_text(encoding="utf-8")
    assert "old-pass-1" not in text and "new-pass-2" not in text


def test_secret_values_skip_personal_data():
    values = secret_values({"gemini_api_key": "AIzaKEY123", "your_signature": "Jan Novák"})
    assert values == {"AIzaKEY123"}
