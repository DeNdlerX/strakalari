"""A tiny fake Bakaláři web server for the plain-HTTP client tests.

Serves the login form and whatever routes a test registers, behind a
session cookie, through ``httpx.MockTransport`` (never the network).
All names and data are made up.
"""

import json
from urllib.parse import parse_qs

import httpx

ROOT = "https://bakalari.example.test"
USER = "student"
PASSWORD = "heslo"
CONFIG = {"bakalari_url": f"{ROOT}/login", "bakalari_username": USER,
          "bakalari_password": PASSWORD}

LOGIN_PAGE = """<html><body>
<form id="formlogin" method="post" action="/login">
<input type="hidden" name="returnUrl" value="">
<input id="username" name="username" type="text" value="">
<input id="password" name="password" type="password">
<button id="loginButton" type="submit" name="login" formaction="/Login">Přihlásit</button>
</form>{error}</body></html>"""


def _reply(value) -> httpx.Response:
    if isinstance(value, httpx.Response):
        return value
    if isinstance(value, str):
        return httpx.Response(200, text=value, headers={"Content-Type": "text/html; charset=utf-8"})
    return httpx.Response(200, json=value)


class FakeBakalari:
    """``routes`` maps ``(METHOD, path)`` to a reply: HTML text, JSON data,
    an ``httpx.Response`` or a callable taking the request."""

    def __init__(self, routes=None):
        self.routes = dict(routes or {})
        self.requests: list = []
        self.logins = 0
        self._token = None

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handle)

    def expire_session(self) -> None:
        self._token = None

    def calls(self, method: str, path: str) -> list:
        return [r for r in self.requests if r.method == method and r.url.path == path]

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        path = request.url.path
        if request.method == "GET" and path == "/login":
            if self._token and request.headers.get("cookie") == f"BakaAuth={self._token}":
                # A still-valid session goes straight into the app.
                return httpx.Response(302, headers={"Location": f"{ROOT}/dashboard"})
            return _reply(LOGIN_PAGE.format(error=""))
        if request.method == "POST" and path == "/Login":
            form = parse_qs(request.content.decode("utf-8"))
            if form.get("username") == [USER] and form.get("password") == [PASSWORD]:
                self.logins += 1
                self._token = f"t{self.logins}"
                return httpx.Response(302, headers={
                    "Location": f"{ROOT}/dashboard",
                    "Set-Cookie": f"BakaAuth={self._token}; Path=/"})
            return _reply(LOGIN_PAGE.format(
                error='<div class="login-error">Nesprávné jméno nebo heslo</div>'))
        if not self._token or request.headers.get("cookie") != f"BakaAuth={self._token}":
            return httpx.Response(302, headers={"Location": f"{ROOT}/login"})
        if path == "/dashboard":
            return _reply("<html><body>dashboard</body></html>")
        handler = self.routes.get((request.method, path))
        if handler is None:
            return httpx.Response(404, text="not found")
        return _reply(handler(request) if callable(handler) else handler)


def client(routes=None, **config):
    """``(BakalariClient, FakeBakalari)`` wired together."""
    from strakalari.core.bakalari_client import BakalariClient

    server = FakeBakalari(routes)
    logs: list = []
    bak = BakalariClient({**CONFIG, **config}, logger=logs.append, transport=server.transport())
    bak.logs = logs
    return bak, server


def week_content(details) -> dict:
    """A ``/Timetable/GetContentData`` reply holding ``details`` (one atom each)."""
    return {"Days": [{"Hours": [{"Atoms": [{"TooltipDetails": json.dumps(d, ensure_ascii=False)}]}
                                for d in details]}]}


def dx_reply(result_html: str) -> str:
    """A DevExpress callback reply carrying ``result_html``."""
    return "0|/*DX*/({'id':0,'result':" + json.dumps(result_html) + "})"
