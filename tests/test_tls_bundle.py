"""CA bundle self-repair (strakalari/core/tls.py).

Regression test for the phone app's refresh failing with a bare
``FileNotFoundError`` from ``ssl.create_default_context``. On Android,
``certifi.where()`` is a temp copy of ``cacert.pem`` in the app's cache dir,
Flet's launcher points ``SSL_CERT_FILE`` at it, and Android may purge
that dir while the app keeps running.
"""
import os
import ssl

import certifi
import pytest

from strakalari.core import tls
from strakalari.core.bakalari_http import BakalariSession
from strakalari.core.strava_client import StravaClient


@pytest.fixture
def purged_bundle(monkeypatch, tmp_path):
    """certifi's extracted copy as on the phone, already deleted by the OS."""
    path = tmp_path / "cache" / "tmpk2j3cacert.pem"
    monkeypatch.setattr(certifi, "where", lambda: str(path))
    monkeypatch.setenv("SSL_CERT_FILE", str(path))
    monkeypatch.setenv("REQUESTS_CA_BUNDLE", str(path))
    assert not path.exists()
    return path


def test_restores_a_purged_bundle(purged_bundle):
    logged = []
    assert tls.ensure_ca_bundle(logged.append) is True
    assert purged_bundle.read_text(encoding="ascii") == certifi.contents()
    assert ssl.create_default_context(cafile=str(purged_bundle)).get_ca_certs()
    assert any("restored" in line for line in logged)
    assert [p.name for p in purged_bundle.parent.iterdir()] == [purged_bundle.name]


def test_existing_bundle_is_left_alone(monkeypatch, tmp_path):
    pem = tmp_path / "cacert.pem"
    pem.write_text("kept as is", encoding="ascii")
    monkeypatch.setattr(certifi, "where", lambda: str(pem))
    logged = []
    assert tls.ensure_ca_bundle(logged.append) is False
    assert pem.read_text(encoding="ascii") == "kept as is"
    assert logged == []


def test_never_writes_a_user_chosen_ssl_cert_file(monkeypatch, tmp_path):
    custom = tmp_path / "school-proxy-ca.pem"
    monkeypatch.setenv("SSL_CERT_FILE", str(custom))
    tls.ensure_ca_bundle(lambda _msg: None)
    assert not custom.exists()


def test_unwritable_location_reports_and_does_not_raise(monkeypatch, purged_bundle):
    def refuse(*_args, **_kwargs):
        raise PermissionError("read-only")

    monkeypatch.setattr(tls, "_write_atomically", refuse)
    logged = []
    assert tls.ensure_ca_bundle(logged.append) is False
    assert any("could not be restored" in line for line in logged)


def test_bakalari_session_survives_a_purged_bundle(purged_bundle):
    session = BakalariSession("https://bakalari.example.invalid", "user", lambda: "pw")
    session.close()
    assert purged_bundle.is_file()


def test_strava_client_survives_a_purged_bundle(purged_bundle):
    client = StravaClient({"strava_url": "https://app.strava.example.invalid"})
    client._client()
    client.close()
    assert purged_bundle.is_file()


def test_without_repair_httpx_fails_like_the_phone_did(purged_bundle):
    """Pins the failure mode the repair exists for (httpx 0.28 reads SSL_CERT_FILE)."""
    import httpx

    with pytest.raises(FileNotFoundError):
        httpx.Client()
    assert not os.path.exists(purged_bundle)
