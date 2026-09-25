"""Gemini API key validation: success, rejection, redaction (all offline)."""

import io
import urllib.error

import strakalari.core.gemini as gemini_mod


class _FakeResp:
    def __init__(self, payload: bytes):
        self._payload = payload

    def read(self):
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_api_key_success(monkeypatch):
    monkeypatch.setattr(
        gemini_mod.urllib.request, "urlopen",
        lambda req, timeout=20: _FakeResp(b'{"displayName": "Gemini Flash"}'),
    )
    ok, message = gemini_mod.test_api_key("AIza-secret", model="gemini-3.8-flash")
    assert ok is True
    assert "Gemini Flash" in message
    assert "AIza-secret" not in message


def test_api_key_empty():
    ok, message = gemini_mod.test_api_key("")
    assert ok is False
    assert message


def test_api_key_invalid_key(monkeypatch):
    def _raise(req, timeout=20):
        raise urllib.error.HTTPError(req.full_url, 400, "Bad Request", {}, io.BytesIO(b'{"error": {"message": "API key not valid."}}'))

    monkeypatch.setattr(gemini_mod.urllib.request, "urlopen", _raise)
    ok, message = gemini_mod.test_api_key("AIza-wrong")
    assert ok is False
    assert "Neplatný" in message
    assert "AIza-wrong" not in message


def test_api_key_bad_model_not_blamed_on_key(monkeypatch):
    def _raise(req, timeout=20):
        raise urllib.error.HTTPError(req.full_url, 400, "Bad Request", {}, io.BytesIO(b'{"error": {"message": "models/xyz is not found."}}'))

    monkeypatch.setattr(gemini_mod.urllib.request, "urlopen", _raise)
    ok, message = gemini_mod.test_api_key("AIza-good", model="xyz")
    assert ok is False
    assert "model" in message
    assert "AIza-good" not in message


def test_api_key_network_error_redacts_key(monkeypatch):
    secret = "AIza-topsecret"

    def _raise(req, timeout=20):
        raise urllib.error.URLError(f"boom {secret} unreachable")

    monkeypatch.setattr(gemini_mod.urllib.request, "urlopen", _raise)
    ok, message = gemini_mod.test_api_key(secret)
    assert ok is False
    assert secret not in message


def test_recommend_lunches_strips_api_key(monkeypatch):
    import urllib.request

    import strakalari.core.gemini as gemini

    seen = {}

    class _Resp:
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def read(self):
            return b"{}"

    def _fake_urlopen(req, timeout=None):
        seen["url"] = req.full_url
        seen["key"] = req.get_header("X-goog-api-key")
        return _Resp()

    monkeypatch.setattr(urllib.request, "urlopen", _fake_urlopen)
    food = {"01.10.2026": {"1&2&3": "Rajská omáčka"}}
    gemini.recommend_lunches(food, "x", "  SECRETKEY \n")
    # The key travels in a header, never in the URL (where logs see it).
    assert seen["key"] == "SECRETKEY"
    assert "SECRETKEY" not in seen["url"]
