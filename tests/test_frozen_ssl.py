"""Frozen-build TLS wiring (rthook_frozen_builtins.py).

Regression test for: frozen Windows exe dying on startup with
``ssl.SSLCertVerificationError: unable to get local issuer certificate``
when flet_desktop downloads its client over HTTPS — the frozen OpenSSL
has no CA bundle unless the runtime hook points SSL_CERT_FILE at the
bundled certifi store.
"""
import importlib.util
import os
import sys


RTHOOK = os.path.join(os.path.dirname(__file__), "..", "rthook_frozen_builtins.py")


def load_rthook():
    spec = importlib.util.spec_from_file_location("rthook_frozen_builtins", RTHOOK)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_import_without_frozen_sets_nothing(monkeypatch):
    monkeypatch.delenv("SSL_CERT_FILE", raising=False)
    monkeypatch.delenv("REQUESTS_CA_BUNDLE", raising=False)
    assert not getattr(sys, "frozen", False)
    load_rthook()
    assert "SSL_CERT_FILE" not in os.environ


def test_sets_ssl_cert_file_from_meipass(monkeypatch, tmp_path):
    hook = load_rthook()
    bundle_dir = tmp_path / "certifi"
    bundle_dir.mkdir()
    pem = bundle_dir / "cacert.pem"
    pem.write_text("dummy-ca", encoding="ascii")
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    monkeypatch.delenv("SSL_CERT_FILE", raising=False)
    monkeypatch.delenv("REQUESTS_CA_BUNDLE", raising=False)
    try:
        assert hook._point_ssl_at_bundled_ca() is True
        assert os.environ["SSL_CERT_FILE"] == str(pem)
    finally:
        monkeypatch.delattr(sys, "_MEIPASS", raising=False)


def test_respects_existing_ssl_cert_file(monkeypatch, tmp_path):
    hook = load_rthook()
    bundle_dir = tmp_path / "certifi"
    bundle_dir.mkdir()
    (bundle_dir / "cacert.pem").write_text("dummy-ca", encoding="ascii")
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    monkeypatch.setenv("SSL_CERT_FILE", "C:\\custom\\ca.pem")
    try:
        assert hook._point_ssl_at_bundled_ca() is False
        assert os.environ["SSL_CERT_FILE"] == "C:\\custom\\ca.pem"
    finally:
        monkeypatch.delattr(sys, "_MEIPASS", raising=False)


def test_missing_bundle_sets_nothing_and_never_raises(monkeypatch, tmp_path):
    hook = load_rthook()
    monkeypatch.setattr(sys, "_MEIPASS", str(tmp_path), raising=False)
    monkeypatch.delenv("SSL_CERT_FILE", raising=False)
    monkeypatch.delenv("REQUESTS_CA_BUNDLE", raising=False)
    # Hide the real certifi fallback so only the (empty) _MEIPASS matters.
    monkeypatch.setitem(sys.modules, "certifi", None)
    try:
        assert hook._point_ssl_at_bundled_ca() is False
        assert "SSL_CERT_FILE" not in os.environ
    finally:
        monkeypatch.delattr(sys, "_MEIPASS", raising=False)
