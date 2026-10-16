"""StravaClient over HTTP, against a fake Strava web app API.

Login and the menu (ids and texts the rest of the app keys on), ordering
staged with the web app's own checks, and the one save that only counts
when a fresh menu shows it. All names, numbers and data are made up.
"""

import html
import json
import re
from datetime import date, datetime, timedelta
from pathlib import Path

import httpx
import pytest

from strakalari.core.strava_client import StravaClient

CONFIG = {"use_strava": True, "strava_canteen_id": "1234", "strava_username": "novak",
          "strava_password": "heslo", "strava_blacklist": "./strava_blacklist.json"}
DAY1 = date.today() + timedelta(days=7)
DAY2 = DAY1 + timedelta(days=1)
_WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def _meal(day: date, ident: int, druh: str, name: str, count: int = 0, **extra) -> dict:
    meal = {"datum": f"{day:%d.%m.%Y}", "druh": druh, "id": ident, "pocet": count, "cena": "45.00",
            "omezeni": "5E", "polevka": "N", "zkratkaProduktu": "zkratka", "druh_popis": f"oběd {ident}",
            "nazev": name, "alergeny": [["01", "Obiloviny"], ["07", "Mléko"]],
            "casKonec": f"{day - timedelta(days=1):%Y-%m-%d}T14:00:00",
            "casOdhlaseni": f"{day - timedelta(days=1):%Y-%m-%d}T14:00:00"}
    meal.update(extra)
    return meal


def _soup(day: date) -> dict:
    return _meal(day, 0, "P", "polévka", omezeni="B", polevka="A", cena="0",
                 casKonec="9999-12-31T00:00:00", casOdhlaseni="9999-12-31T00:00:00", alergeny=[])


class FakeStrava:
    """app.strava.cz: login, the menu, and saving the order sheet."""

    def __init__(self, konto="100", limit="0.00", s5url=""):
        self.menu = {
            "table0": [_soup(DAY1), _meal(DAY1, 1, "1", "Guláš", count=1), _meal(DAY1, 2, "2", "Rizoto")],
            "table1": [_soup(DAY2), _meal(DAY2, 1, "1", "Řízek"), _meal(DAY2, 2, "2", "Těstoviny")],
        }
        self.user = {"konto": konto, "limit": limit, "mena": "Kč"}
        self.s5url = s5url
        self.requests = []
        self.saves = []
        self.logins = 0
        self.sid = None
        self.save_reply = None
        self.apply_saves = True

    def transport(self):
        return httpx.MockTransport(self.handle)

    def handle(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content or b"{}")
        self.requests.append((request.url.path, body))
        if request.url.path == "/api/login":
            if (body.get("cislo"), body.get("jmeno"), body.get("heslo")) != ("1234", "novak", "heslo"):
                return httpx.Response(200, json={"state": "error", "number": 1001, "message": "Chybné heslo"})
            self.logins += 1
            self.sid = f"sid{self.logins}"
            return httpx.Response(200, json={"sid": self.sid, "s5url": self.s5url, "cislo": "1234",
                                             "ignoreCert": "false", "uzivatel": dict(self.user)})
        if body.get("sid") != self.sid:
            return httpx.Response(200, json={"state": "error", "number": 13, "message": "Neplatné SID"})
        if request.url.path == "/api/objednavky":
            return httpx.Response(200, json=json.loads(json.dumps(self.menu)))
        if request.url.path == "/api/saveOrders":
            self.saves.append(body["xml"])
            if self.save_reply is not None:
                return httpx.Response(200, json=self.save_reply)
            if self.apply_saves:
                rows = re.findall(r"<datum>([\d-]+)</datum>\s*<druh>(\w)</druh>\s*<pocet>(\d+)</pocet>",
                                  html.unescape(body["xml"]))
                for iso, druh, count in rows:
                    for meals in self.menu.values():
                        for meal in meals:
                            if meal["datum"] == datetime.strptime(iso, "%Y-%m-%d").strftime("%d.%m.%Y") \
                                    and meal["druh"] == druh:
                                meal["pocet"] = int(count)
            return httpx.Response(200, json={"konto": "55"})
        return httpx.Response(404)

    def calls(self, path):
        return [b for p, b in self.requests if p == path]


def _client(server=None, **config):
    server = server or FakeStrava()
    logs = []
    client = StravaClient({**CONFIG, **config}, logger=logs.append, transport=server.transport())
    client.logs = logs
    return client, server


def _day(d: date) -> str:
    return f"{d:%d.%m.%Y}"


# -- blacklist -------------------------------------------------------------------

def test_client_drops_example_placeholders(tmp_path):
    bl = tmp_path / "strava_blacklist.json"
    bl.write_text('["vepro", "VAS_BLACKLIST_X", "your_blacklist_0", '
                  '"CISLO_JIDELNY", "example dish"]', encoding="utf-8")
    client = StravaClient({"use_strava": True, "strava_blacklist": str(bl)}, logger=lambda m: None)
    assert client.strava_blacklist_json == ["vepro"]


# -- login and menu ------------------------------------------------------------------

def test_login_and_menu_keep_the_ids_and_texts_of_the_web_page():
    client, server = _client()
    data = client.fetch_data()
    login = server.calls("/api/login")[0]
    assert login["environment"] == "W" and login["zustatPrihlasen"] is False
    menu = server.calls("/api/objednavky")[0]
    assert menu["sid"] == "sid1" and menu["s5url"] == "" and menu["konto"] == 0
    assert data["foodDict"][_day(DAY1)] == {
        "table0&-1&0": f"{_WEEKDAYS[DAY1.weekday()]} {DAY1:%d/%m/%Y}",
        "table0&1&0": "oběd 1 - Guláš(01, 07 )",
        "table0&2&0": "oběd 2 - Rizoto(01, 07 )",
    }
    assert data["orderedDict"] == {_day(DAY1): "table0&1&0"}


def test_wrong_password_is_a_user_error_with_stravas_reason():
    from strakalari.core.error_report import UserError

    client, _ = _client(strava_password="spatne")
    with pytest.raises(UserError) as exc_info:
        client.login()
    assert "Chybné heslo" in str(exc_info.value)


def test_strava_server_error_is_a_user_error():
    from strakalari.core.error_report import UserError

    client = StravaClient(CONFIG, transport=httpx.MockTransport(lambda r: httpx.Response(502)))
    with pytest.raises(UserError) as exc_info:
        client.login()
    assert "HTTP 502" in str(exc_info.value)


def test_menu_error_shows_stravas_reason():
    from strakalari.core.error_report import UserError

    server = FakeStrava()
    real = server.handle

    def handle(request):
        if request.url.path == "/api/objednavky":
            return httpx.Response(200, json={"state": "error", "number": 77, "message": "Jídelna je uzavřena"})
        return real(request)

    client = StravaClient(CONFIG, transport=httpx.MockTransport(handle))
    with pytest.raises(UserError) as exc_info:
        client.fetch_data()
    assert "Jídelna je uzavřena" in str(exc_info.value)


def test_dropped_session_logs_in_again_for_reads():
    client, server = _client()
    client.fetch_data()
    server.sid = "expired"
    client.fetch_data()
    assert server.logins == 2


def test_unreachable_strava_is_a_user_error():
    from strakalari.core.error_report import UserError

    def down(request):
        raise httpx.ConnectError("down", request=request)

    client = StravaClient(CONFIG, transport=httpx.MockTransport(down))
    with pytest.raises(UserError):
        client.login()


# -- ordering --------------------------------------------------------------------------

def test_order_is_staged_and_saved_once_as_the_web_app_does():
    client, server = _client()
    client.fetch_data()
    assert client.order("table1&2&0") is True
    assert client.order("table0&2&0") is True  # switches the day's meal
    assert server.saves == []  # nothing sent before the save
    assert client.save_confirm(["table1&2&0", "table0&2&0"]) is True
    [sheet] = server.saves
    rows = re.findall(r"<datum>([\d-]+)</datum>\s*<druh>(\w)</druh>\s*<pocet>(\d+)</pocet>", html.unescape(sheet))
    assert rows == [(f"{DAY2:%Y-%m-%d}", "2", "1"), (f"{DAY1:%Y-%m-%d}", "2", "1"), (f"{DAY1:%Y-%m-%d}", "1", "0")]
    assert client.orderedDict == {_day(DAY1): "table0&2&0", _day(DAY2): "table1&2&0"}


def test_order_sheet_matches_the_web_app_byte_for_byte():
    """Captured from the web app's own builder for the same three changes."""
    from strakalari.core.strava_ordering import order_sheet

    expected = (Path(__file__).parent / "fixtures" / "strava_save_orders.txt").read_text(encoding="utf-8")
    assert order_sheet([{"date": "2026-10-07", "druh": "2", "pocet": 1},
                        {"date": "2026-10-07", "druh": "1", "pocet": 0},
                        {"date": "2026-10-08", "druh": "3", "pocet": 0}]) == expected


def test_already_ordered_meal_needs_no_change():
    client, server = _client()
    client.fetch_data()
    assert client.order("table0&1&0") is True
    assert client.clicks_made == 0
    assert client.save_confirm(["table0&1&0"]) is True
    assert server.saves == []


def test_day_cancel_zeroes_the_ordered_meal():
    client, server = _client()
    client.fetch_data()
    assert client.order("table0&-1&0") is True
    assert client.save_confirm(["table0&-1&0"]) is True
    assert _day(DAY1) not in client.orderedDict
    assert "&lt;pocet&gt;0&lt;/pocet&gt;" in server.saves[0]


def test_closed_order_window_stages_nothing():
    server = FakeStrava()
    server.menu["table1"][2]["casKonec"] = "2000-01-01T00:00:00"
    client, _ = _client(server)
    client.fetch_data()
    assert client.order("table1&2&0") is False
    assert "[5010]" in client.last_notice
    assert client.clicks_made == 0


def test_low_balance_is_refused_before_anything_is_sent():
    client, server = _client(FakeStrava(konto="50"))
    client.fetch_data()
    assert client.order("table1&1&0") is True  # 50 - 45 = 5 stays above the limit 0
    assert client.order("table1&2&0") is True  # a switch on the same day costs nothing more
    assert client.order("table0&2&0") is True  # switching a paid day refunds the old meal
    client2, _ = _client(FakeStrava(konto="40"))
    client2.fetch_data()
    assert client2.order("table1&1&0") is False
    assert client2.insufficient_balance is True
    assert "[5005]" in client2.last_notice
    assert server.saves == []


def test_failed_run_drops_the_staged_changes():
    client, server = _client()
    client.fetch_data()
    client.order("table1&1&0")
    client._restore_original([{"day": _day(DAY2)}], {})
    assert client._verified("table1&1&0") is False
    assert server.saves == []


def test_rejected_save_is_not_success():
    server = FakeStrava()
    server.save_reply = {"state": "error", "number": 5005, "message": "Nedostatečný zůstatek"}
    client, _ = _client(server)
    client.fetch_data()
    client.order("table1&1&0")
    assert client.save_confirm(["table1&1&0"]) is False
    assert "Nedostatečný" in client.last_notice
    assert len(server.saves) == 1


def test_save_not_shown_on_the_menu_is_not_success():
    server = FakeStrava()
    server.apply_saves = False
    client, _ = _client(server)
    client.fetch_data()
    client.order("table1&1&0")
    assert client.save_confirm(["table1&1&0"]) is False
    assert len(server.saves) == 1  # never repeated


def test_menu_day_found_when_the_soup_row_has_no_date():
    from strakalari.core.extractors.strava import menu_from_reply

    soup = _soup(DAY1)
    del soup["datum"]
    food, _ordered = menu_from_reply({"table0": [soup, _meal(DAY1, 1, "1", "Řízek")]})
    assert list(food) == [f"{DAY1:%d.%m.%Y}"]
    assert "table0&1&0" in food[f"{DAY1:%d.%m.%Y}"]


def test_newer_backend_orders_nothing():
    client, server = _client(FakeStrava(s5url="https://s5.example.test"))
    client.fetch_data()
    assert client.foodDict  # reading works
    assert client.order("table1&1&0") is False
    assert server.saves == []


def test_dropped_connection_retried_for_reads_never_for_the_save():
    server = FakeStrava()
    real = server.handle
    drops = {"/api/objednavky": 1, "/api/saveOrders": 1}

    def flaky(request):
        if drops.get(request.url.path):
            drops[request.url.path] -= 1
            raise httpx.RemoteProtocolError("Server disconnected", request=request)
        return real(request)

    client = StravaClient(CONFIG, logger=lambda m: None, transport=httpx.MockTransport(flaky))
    client.fetch_data()  # the dropped menu read is retried
    assert client.order("table1&1&0") is True
    # The dropped save is not repeated; the fresh menu then shows nothing saved.
    assert client.save_confirm(["table1&1&0"]) is False
    assert server.saves == []
