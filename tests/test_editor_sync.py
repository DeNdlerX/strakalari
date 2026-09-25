"""Regression: kontrola textu omluvenky musí hledat i v iframe editoru.

Log 23. 9.: výběr hodin už procházel, ale každá omluvenka padala na
"excuse text sync not confirmed". DevExpress HtmlEditor (cphmain_MessageEditor_DesignIFrame)
drží rozepsaný text v iframe — innerText hlavní stránky ho nikdy neobsahuje,
takže původní poll nemohl projít. Vzorek htmls/omluveni_absence.html (gitignored).
"""
from unittest.mock import MagicMock


def _client(page):
    from strakalari.core.bakalari_client import BakalariClient

    bm = MagicMock()
    bm.page = page
    return BakalariClient(bm, {"bakalari_url": "https://bakaweb.gekom.cz"},
                          logger=lambda m: None)


class TestEditorSyncProbe:
    def test_probe_covers_iframes(self):
        seen = {}
        page = MagicMock()

        def _wff(js, timeout=None):
            seen["js"] = js
            return True

        page.wait_for_function.side_effect = _wff
        client = _client(page)
        assert client._wait_for_editor_sync(
            "Omluvte prosím absenci dne 18.09.2026. Podpis", timeout_ms=1000) is True
        assert "iframe" in seen["js"]
        assert "contentDocument" in seen["js"]

    def test_timeout_returns_false(self):
        page = MagicMock()
        page.wait_for_function.side_effect = Exception("Timeout exceeded")
        client = _client(page)
        assert client._wait_for_editor_sync(
            "Omluvte prosím absenci", timeout_ms=50) is False

    def test_empty_text_passes_without_page(self):
        client = _client(MagicMock())
        assert client._wait_for_editor_sync("", timeout_ms=50) is True
        assert client._wait_for_editor_sync(None, timeout_ms=50) is True
