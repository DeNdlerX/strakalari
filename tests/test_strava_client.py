"""StravaClient: blacklist loading, meal ordering and restore."""
from unittest.mock import MagicMock

from strakalari.core.strava_client import StravaClient


class TestPlaceholderFilter:
    def test_client_drops_example_placeholders(self, tmp_path):
        from strakalari.core.strava_client import StravaClient
        bl = tmp_path / "strava_blacklist.json"
        bl.write_text('["vepro", "VAS_BLACKLIST_X", "your_blacklist_0", '
                      '"CISLO_JIDELNY", "example dish"]', encoding="utf-8")
        bm = MagicMock()
        bm.page = MagicMock()
        client = StravaClient(
            bm, {"use_strava": True, "strava_blacklist": str(bl)},
            logger=lambda m: None)
        assert client.strava_blacklist_json == ["vepro"]


class TestRestoreAndForcing:
    def _client(self):
        from strakalari.core.strava_client import StravaClient
        logs = []
        bm = MagicMock()
        bm.page = MagicMock()
        client = StravaClient(
            bm, {"use_strava": True,
                 "strava_blacklist": "./strava_blacklist.json"},
            logger=logs.append)
        return client, logs

    def test_deorder_original_logs_skip(self):
        client, logs = self._client()
        client._restore_original(
            [{"day": "D", "meal_id": "x&1&0", "all_ids": []}],
            {"D": "t&-1&0"})
        assert any("D" in m for m in logs)

    def test_forcing_covers_all_siblings(self):
        client, _logs = self._client()
        target = "t&1&0"
        sibs = ["t&2&0", "t&3&0", "t&4&0"]
        clicks = []
        client._click_meal = lambda mid: clicks.append(mid) or True
        # Direct + final target clicks verify; siblings never do.
        client._verified = lambda mid: (
            mid == target and clicks.count(target) >= 2)
        assert client.order(target, [target] + sibs) is True
        for s in sibs:
            assert s in clicks


def test_strava_client_save_confirm_ignores_skip_navigation():
    """
    Verify that save_confirm does not attempt to click off-screen skip navigation links.
    """
    from unittest.mock import MagicMock
    from strakalari.core.strava_client import StravaClient

    mock_bm = MagicMock()
    mock_page = MagicMock()
    mock_bm.page = mock_page

    # Mock locators: none of the legitimate save selectors match
    mock_loc = MagicMock()
    mock_loc.wait_for.side_effect = Exception("Timeout waiting for element")
    mock_page.locator.return_value.first = mock_loc

    logs = []
    client = StravaClient(mock_bm, {"use_strava": True}, logger=logs.append)
    client.save_confirm()

    # Ensure no click was performed on nonexistent element
    assert mock_loc.click.call_count == 0


def test_strava_client_save_confirm_clicks_save_button():
    """
    Verify that save_confirm finds and clicks the 'Uložit změny' button when present.
    """
    from unittest.mock import MagicMock
    from strakalari.core.strava_client import StravaClient

    mock_bm = MagicMock()
    mock_page = MagicMock()
    mock_bm.page = mock_page

    mock_loc = MagicMock()
    mock_loc.bounding_box.return_value = {"x": 500, "y": 800, "width": 120, "height": 45}
    mock_page.locator.return_value.first = mock_loc

    logs = []
    client = StravaClient(mock_bm, {"use_strava": True}, logger=logs.append)
    client._verified = lambda mid: True
    client.save_confirm(["table1&1&0"])

    assert mock_loc.click.call_count == 1


def test_order_skips_clicks_when_already_ordered():
    from strakalari.core.strava_client import StravaClient

    class FakeLoc:
        def __init__(self, page, selector):
            self._page = page
            self._selector = selector

        @property
        def first(self):
            return self

        def count(self):
            return 1

        def evaluate(self, js):
            sel = self._selector
            return (self._page.selected is not None
                    and self._page.selected in sel)

    class FakePage:
        def __init__(self):
            self.selected = None
            self.requested = []

        def locator(self, selector):
            return FakeLoc(self, selector)

    class FakeBM:
        def __init__(self, page):
            self.page = page

        def scroll_up(self):
            pass

        def scroll_until_visible(self, by, identifier):
            self.page.requested.append(identifier)
            return object()

        def click_element(self, el, identifier=None):
            self.page.selected = identifier
            return True

        def random_sleep(self, *args):
            pass

    menu = ["table9&1&0", "table9&2&0", "table9&3&0"]
    page = FakePage()
    client = StravaClient(FakeBM(page), {"use_strava": False},
                          logger=lambda m: None)
    # Already ordered on the web: True with zero clicks, no sibling cycle.
    page.selected = "table9&2&0"
    assert client.order("table9&2&0", menu) is True
    assert client.clicks_made == 0
    assert page.requested == []


def test_order_clicks_target_directly_and_verifies():
    from strakalari.core.strava_client import StravaClient

    class FakeLoc:
        def __init__(self, page, selector):
            self._page = page
            self._selector = selector

        @property
        def first(self):
            return self

        def count(self):
            return 1

        def evaluate(self, js):
            sel = self._selector
            return (self._page.selected is not None
                    and self._page.selected in sel)

    class FakePage:
        def __init__(self):
            self.selected = None
            self.requested = []

        def locator(self, selector):
            return FakeLoc(self, selector)

    class FakeBM:
        def __init__(self, page):
            self.page = page

        def scroll_up(self):
            pass

        def scroll_until_visible(self, by, identifier):
            self.page.requested.append(identifier)
            return object()

        def click_element(self, el, identifier=None):
            self.page.selected = identifier
            return True

        def random_sleep(self, *args):
            pass

    menu = ["table9&1&0", "table9&2&0", "table9&3&0"]
    page = FakePage()
    page.selected = "table9&1&0"
    client = StravaClient(FakeBM(page), {"use_strava": False},
                          logger=lambda m: None)
    # One direct click on the target, verified — siblings untouched.
    assert client.order("table9&2&0", menu) is True
    assert client.clicks_made == 1
    assert page.requested == ["table9&2&0"]
    assert page.selected == "table9&2&0"


def test_order_fails_honestly_when_unverifiable():
    from strakalari.core.strava_client import StravaClient

    class FakeLoc:
        def __init__(self, page, selector):
            self._page = page
            self._selector = selector

        @property
        def first(self):
            return self

        def count(self):
            return 1

        def evaluate(self, js):
            # Broken page: clicks never take effect.
            return False

    class FakePage:
        def locator(self, selector):
            return FakeLoc(self, selector)

    class FakeBM:
        def __init__(self, page):
            self.page = page

        def scroll_up(self):
            pass

        def scroll_until_visible(self, by, identifier):
            return object()

        def click_element(self, el, identifier=None):
            return True

        def random_sleep(self, *args):
            pass

    menu = ["table9&1&0", "table9&2&0", "table9&3&0"]
    page = FakePage()
    client = StravaClient(FakeBM(page), {"use_strava": False},
                          logger=lambda m: None)
    # The direct click happened but never verified. No save button
    # means the immediate-save frontend, where the sibling forcing
    # sequence would really order other meals — so it must not run.
    assert client.order("table9&2&0", menu) is False
    assert client.clicks_made == 1


def test_reconcile_ordered_live_finds_js_only_selection():
    from strakalari.core.strava_client import StravaClient

    class FakeLoc:
        def __init__(self, page, selector):
            self._page = page
            self._selector = selector

        @property
        def first(self):
            return self

        def count(self):
            return 1

        def evaluate(self, js):
            sel = self._selector
            return (self._page.selected is not None
                    and self._page.selected in sel)

    class FakePage:
        def __init__(self):
            self.selected = None

        def locator(self, selector):
            return FakeLoc(self, selector)

    class FakeBM:
        def __init__(self, page):
            self.page = page

    day = "09.09.2026"
    menu = {"table0&1&0": "A", "table0&2&0": "B", "table0&-1&0": "day"}

    # Static parse blind, live DOM knows: entry is added.
    page = FakePage()
    page.selected = "table0&2&0"
    client = StravaClient(FakeBM(page), {"use_strava": False},
                          logger=lambda m: None)
    client.foodDict = {day: dict(menu)}
    client.orderedDict = {}
    client._reconcile_ordered_live()
    assert client.orderedDict == {day: "table0&2&0"}

    # Static stale, live knows better: entry is corrected.
    page.selected = "table0&1&0"
    client.orderedDict = {day: "table0&2&0"}
    client._reconcile_ordered_live()
    assert client.orderedDict == {day: "table0&1&0"}

    # Static confirmed by live: kept silently.
    logs = []
    client2 = StravaClient(FakeBM(page), {"use_strava": False},
                           logger=logs.append)
    client2.foodDict = {day: dict(menu)}
    client2.orderedDict = {day: "table0&1&0"}
    client2._reconcile_ordered_live()
    assert client2.orderedDict == {day: "table0&1&0"}
    assert not any("live check shows" in m for m in logs)


def test_reconcile_ordered_live_warns_when_nothing_found():
    from strakalari.core.strava_client import StravaClient

    class FakeLoc:
        @property
        def first(self):
            return self

        def count(self):
            return 0

        def evaluate(self, js):
            return False

    class FakePage:
        def locator(self, selector):
            return FakeLoc()

    class FakeBM:
        def __init__(self, page):
            self.page = page

    logs = []
    client = StravaClient(FakeBM(FakePage()), {"use_strava": False},
                          logger=logs.append)
    client.foodDict = {"09.09.2026": {"table0&1&0": "A"}}
    client.orderedDict = {}
    client._reconcile_ordered_live()
    assert client.orderedDict == {}
    assert any("no ordered meal was detected" in m for m in logs)


def test_day_cancel_clicks_only_header_and_verifies_meals():
    from strakalari.core.strava_client import StravaClient

    header, m1, m2 = "table2&-1&0", "table2&1&0", "table2&2&0"

    class FakeLoc:
        def __init__(self, page, selector):
            self._page = page
            self._selector = selector

        @property
        def first(self):
            return self

        def count(self):
            return 1

        def evaluate(self, js):
            for mid, state in self._page.meals.items():
                if mid in self._selector:
                    return state
            return False

    class FakePage:
        def __init__(self):
            self.meals = {}
            self.requested = []

        def locator(self, selector):
            return FakeLoc(self, selector)

    class FakeBM:
        def __init__(self, page):
            self.page = page

        def scroll_up(self):
            pass

        def scroll_until_visible(self, by, identifier):
            self.page.requested.append(identifier)
            return object()

        def click_element(self, el, identifier=None):
            # Radio behaviour: header click clears the day's meals.
            if identifier == header:
                for mid in self.page.meals:
                    self.page.meals[mid] = False
            else:
                self.page.meals[identifier] = True
            return True

        def random_sleep(self, *args):
            pass

    menu = [header, m1, m2]
    page = FakePage()
    client = StravaClient(FakeBM(page), {"use_strava": False},
                          logger=lambda m: None)
    # Day already fully cancelled: True, zero clicks.
    page.meals = {m1: False, m2: False}
    assert client.order(header, menu) is True
    assert client.clicks_made == 0
    assert page.requested == []
    # One meal ordered: only the header is clicked, never a meal.
    page.meals = {m1: True, m2: False}
    assert client.order(header, menu) is True
    assert page.requested == [header]
    assert page.meals == {m1: False, m2: False}


def _client(**kw):
    bm = MagicMock()
    bm.page = MagicMock()
    cfg = {"strava_order_mode": "auto", "use_strava": True,
           "strava_blacklist": "./strava_blacklist.json"}
    client = StravaClient(bm, cfg, logger=lambda m: None, **kw)
    return client


class TestSaveConfirmVerify:
    def _page_ok(self):
        page = MagicMock()
        page.url = "https://strava.cz/objednavky"
        first = MagicMock()
        first.wait_for.return_value = None
        loc = MagicMock()
        loc.first = first
        # Success-path button locator + error locator share .locator();
        # error count must read as "no error".
        err_first = MagicMock()
        err_first.count.return_value = 0
        err_loc = MagicMock()
        err_loc.first = err_first
        err_loc.all.return_value = []

        calls = {"n": 0}

        def locator(sel):
            calls["n"] += 1
            if "alert" in sel or "error" in sel or "role" in sel:
                return err_loc
            return loc

        page.locator.side_effect = locator
        page.wait_for_timeout.return_value = None
        return page

    def test_click_success_still_true(self):
        client = _client()
        client.page = self._page_ok()
        client._verified = lambda mid: True
        assert client.save_confirm(["x&1&0"]) is True

    def test_no_ids_is_false(self):
        # Fail-closed: nothing to verify means nothing claimed as saved.
        client = _client()
        client.page = self._page_ok()
        assert client.save_confirm() is False
        assert client.save_confirm([]) is False

    def test_explicit_error_is_false(self):
        client = _client()
        page = self._page_ok()
        err_loc = page.locator(".alert-danger")
        err_el = MagicMock()
        err_el.is_visible.return_value = True
        err_el.inner_text.return_value = "Chyba uložení"
        err_loc.all.return_value = [err_el]
        client.page = page
        client._verified = lambda mid: True
        assert client.save_confirm(["x&1&0"]) is False

    def test_login_redirect_is_false(self):
        client = _client()
        page = self._page_ok()
        page.url = "https://strava.cz/login?expired=1"
        client.page = page
        client._verified = lambda mid: True
        assert client.save_confirm(["x&1&0"]) is False
