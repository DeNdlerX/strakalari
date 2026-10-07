"""Bakaláři web over plain HTTP: session, login and WebForms helpers.

Talks to the same pages and endpoints the Bakaláři web app uses itself
(never the mobile API): the login form, the pages' own JSON endpoints
and, for the WebForms (``.aspx``) pages, form posts and DevExpress
callbacks rebuilt from the page's raw HTML.
"""

import json
import re
from html.parser import HTMLParser
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit, urlunsplit

import httpx

from .cancel import raise_if_cancelled
from .error_report import UserError, timeout_user_message
from .i18n import t


class SessionExpired(Exception):
    """The server answered with the login page: the session is gone."""


def app_root(url: str) -> str:
    """Web root of the configured Bakaláři URL, without a trailing slash.

    Users paste whatever the address bar showed (``bakaweb.x.cz``,
    ``https://bakaweb.x.cz/login``, ``…/next/komens.aspx``); page names
    are dropped so a school hosted under a sub-path keeps that path.
    """
    raw = str(url or "").strip()
    if not raw:
        return ""
    if not raw.startswith(("http://", "https://")):
        raw = f"https://{raw}"
    parts = urlsplit(raw)
    segments = [s for s in parts.path.split("/") if s]
    while segments and (segments[-1].lower() in ("login", "dashboard", "next")
                        or "." in segments[-1]):
        segments.pop()
    path = "/" + "/".join(segments) if segments else ""
    return urlunsplit((parts.scheme, parts.netloc, path, "", ""))


# -- Raw-HTML form handling (what a browser would submit) --------------------

_SKIPPED_INPUT_TYPES = ("submit", "button", "image", "reset", "file")


class _FormFields(HTMLParser):
    """Collects the submittable fields of one ``<form id=…>`` in tree order."""

    def __init__(self, form_id: str):
        super().__init__(convert_charrefs=True)
        self.form_id = form_id
        self.depth = 0
        self.fields: list = []
        self._textarea = None
        self._select = None

    def handle_starttag(self, tag, attrs):
        a = {k: (v if v is not None else "") for k, v in attrs}
        if tag == "form":
            if self.depth or a.get("id") == self.form_id:
                self.depth += 1
            return
        if not self.depth or "disabled" in a:
            return
        name = a.get("name")
        if tag == "input" and name:
            kind = a.get("type", "text").lower()
            if kind in _SKIPPED_INPUT_TYPES:
                return
            if kind in ("checkbox", "radio") and "checked" not in a:
                return
            default = "on" if kind in ("checkbox", "radio") else ""
            self.fields.append((name, a.get("value", default)))
        elif tag == "textarea" and name:
            self._textarea = [name, ""]
        elif tag == "select" and name:
            self._select = {"name": name, "first": None, "chosen": None}
        elif tag == "option" and self._select is not None:
            value = a.get("value", "")
            if self._select["first"] is None:
                self._select["first"] = value
            if "selected" in a:
                self._select["chosen"] = value

    def handle_data(self, data):
        if self._textarea is not None:
            self._textarea[1] += data

    def handle_endtag(self, tag):
        if tag == "form" and self.depth:
            self.depth -= 1
        elif tag == "textarea" and self._textarea is not None:
            self.fields.append(tuple(self._textarea))
            self._textarea = None
        elif tag == "select" and self._select is not None:
            chosen = self._select["chosen"]
            if chosen is None:
                chosen = self._select["first"]
            if chosen is not None:
                self.fields.append((self._select["name"], chosen))
            self._select = None


def form_fields(page_html: str, form_id: str = "formbaka") -> list:
    """``[(name, value)]`` a browser would submit from the raw form HTML.

    Fields the page's JavaScript adds later (DevExpress ``$State`` and
    friends) are not in the raw HTML; callers add those themselves.
    """
    parser = _FormFields(form_id)
    parser.feed(str(page_html or ""))
    parser.close()
    return parser.fields


def form_body(fields: list) -> dict:
    """Request kwargs posting ``fields`` form-encoded, order and duplicates kept."""
    return {
        "content": urlencode(fields, encoding="utf-8").encode("ascii"),
        "headers": {"Content-Type": "application/x-www-form-urlencoded; charset=UTF-8"},
    }


def dx_encode_html(text: str) -> str:
    """``ASPx.Str.EncodeHtml`` of the DevExpress client, step for step.

    DevExpress runs every client state through it before posting (the
    pre-escaped entities get an ``x`` so the server can tell them apart).
    """
    for old, new in (("&amp;", "&ampx;"), ("&", "&amp;"), ("&quot;", "&quotx;"),
                     ('"', "&quot;"), ("&lt;", "&ltx;"), ("<", "&lt;"),
                     ("&gt;", "&gtx;"), (">", "&gt;")):
        text = text.replace(old, new)
    return text


def dx_state(state: dict) -> str:
    """A DevExpress client-state field value (compact JSON, then encoded)."""
    return dx_encode_html(json.dumps(state, ensure_ascii=False, separators=(",", ":")))


_JS_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}


def _read_js_string(text: str, start: int) -> str:
    """Decodes the JS string literal whose opening quote is at ``start``."""
    quote = text[start]
    out = []
    i = start + 1
    while i < len(text):
        ch = text[i]
        if ch == quote:
            return "".join(out)
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if nxt == "u" and re.fullmatch(r"[0-9a-fA-F]{4}", text[i + 2:i + 6]):
            out.append(chr(int(text[i + 2:i + 6], 16)))
            i += 6
        elif nxt == "x" and re.fullmatch(r"[0-9a-fA-F]{2}", text[i + 2:i + 4]):
            out.append(chr(int(text[i + 2:i + 4], 16)))
            i += 4
        else:
            out.append(_JS_ESCAPES.get(nxt, nxt))
            i += 2
    raise ValueError("unterminated string in the DevExpress callback reply")


def dx_callback_result(reply: str) -> str:
    """The ``result`` string of a DevExpress callback reply.

    Replies look like ``<n>|<state>/*DX*/({'id':0,'result':'…'})`` with the
    result as a JS string literal. Raises ``RuntimeError`` on a callback
    error and ``ValueError`` when the reply is not a callback reply at all.
    """
    text = str(reply or "")
    start = text.find("/*DX*/(")
    if start < 0:
        raise ValueError("not a DevExpress callback reply")
    body = text[start + 7:]
    error = re.search(r"['\"]error['\"]\s*:\s*\{\s*['\"]message['\"]\s*:\s*(['\"])", body)
    if error:
        raise RuntimeError(f"DevExpress callback error: {_read_js_string(body, error.start(1))[:200]}")
    result = re.search(r"['\"]result['\"]\s*:\s*(['\"])", body)
    if not result:
        raise ValueError("DevExpress callback reply without a result")
    return _read_js_string(body, result.start(1))


# -- Login page --------------------------------------------------------------

_LOGIN_ERROR_NODE_RE = re.compile(
    r"<(\w+)[^>]*(?:class=\"[^\"]*\b(?:login-error|validation-summary-errors|alert-danger"
    r"|dx-invalid-message)\b[^\"]*\"|id=\"loginError\")[^>]*>(.*?)</\1>",
    re.IGNORECASE | re.DOTALL,
)
_LOGIN_ERROR_WORDS = ("nesprávné", "neplatné", "chybné", "neúspěšné", "špatné",
                      "nespravne", "invalid", "incorrect")


def _visible_text(fragment: str) -> str:
    import html as _html

    text = re.sub(r"<(script|style)\b.*?</\1>", " ", str(fragment or ""), flags=re.I | re.S)
    text = _html.unescape(re.sub(r"<[^>]+>", " ", text))
    return re.sub(r"\s+", " ", text).strip()


def login_error_text(resp: httpx.Response) -> str:
    """Why Bakaláři rejected the login, or ``""``. Never raises."""
    try:
        message = (parse_qs(urlsplit(str(resp.url)).query).get("e") or [""])[0].strip()
        if message:
            return message[:300]
        body = resp.text
        for match in _LOGIN_ERROR_NODE_RE.finditer(body):
            text = _visible_text(match.group(2))
            if text:
                return text[:300]
        visible = _visible_text(body)
        lowered = visible.lower()
        for word in _LOGIN_ERROR_WORDS:
            idx = lowered.find(word)
            if idx >= 0:
                return visible[max(0, idx - 40):idx + 120].strip()[:300]
    except Exception:
        pass
    return ""


def _is_login_page(resp: httpx.Response) -> bool:
    """True when ``resp`` is (or redirected to) the login form."""
    if resp.status_code == 401:
        return True
    if urlsplit(str(resp.url)).path.lower().rstrip("/").endswith("/login"):
        return True
    if "html" in resp.headers.get("content-type", ""):
        return 'id="loginButton"' in resp.text
    return False


def _login_post_url(page: httpx.Response) -> str:
    """Where the login form posts to (the button's formaction, else the form's action)."""
    body = page.text
    target = re.search(r'id="loginButton"[^>]*?formaction="([^"]+)"', body) or re.search(
        r'formaction="([^"]+)"[^>]*?id="loginButton"', body) or re.search(
        r'<form[^>]*id="formlogin"[^>]*action="([^"]+)"', body)
    return urljoin(str(page.url), target.group(1) if target else "Login")


class BakalariSession:
    """One logged-in Bakaláři web session (cookies, timeouts, re-login).

    Every request checks the cancel predicate first. A reply that lands on
    the login page means the server dropped the session: read requests log
    in again and are retried once; :meth:`send_once` (the excuse post) is
    never repeated.
    """

    def __init__(self, base_url: str, username: str, password_provider, *,
                 timeout_s: float = 60.0, user_agent: str = "", cancelled=None,
                 logger=None, transport=None):
        self.root = app_root(base_url)
        self.username = username
        self._password = password_provider
        self._cancelled = cancelled or (lambda: False)
        self._log = logger
        self.timeout_s = timeout_s
        self.logged_in = False
        headers = {"Accept-Language": "cs,en;q=0.8"}
        if user_agent:
            headers["User-Agent"] = user_agent
        self._client = httpx.Client(
            follow_redirects=True,
            timeout=httpx.Timeout(timeout_s, connect=min(timeout_s, 20.0)),
            headers=headers,
            transport=transport,
        )

    def log(self, msg: str) -> None:
        if self._log:
            self._log(msg)

    def close(self) -> None:
        self._client.close()

    def _send(self, method: str, path: str, *, once: bool = False, **kwargs) -> httpx.Response:
        """One request; a read is retried once when the connection broke
        before any reply (the server dropped an idle kept-alive connection).
        ``once`` requests (the excuse post) are never repeated."""
        raise_if_cancelled(self._cancelled)
        url = path if path.startswith(("http://", "https://")) else self.root + path
        try:
            try:
                return self._client.request(method, url, **kwargs)
            except (httpx.RemoteProtocolError, httpx.ReadError) as exc:
                if once:
                    raise
                self.log(f"Bakaláři connection dropped ({type(exc).__name__}), retrying once: {method} {path}")
                raise_if_cancelled(self._cancelled)
                return self._client.request(method, url, **kwargs)
        except httpx.TimeoutException as exc:
            self.log(f"Bakaláři request timed out after {self.timeout_s:.0f} s: {method} {path}")
            raise UserError(timeout_user_message()) from exc
        except httpx.TransportError as exc:
            self.log(f"Bakaláři request failed: {method} {path}: {type(exc).__name__}: {exc}")
            raise UserError(t("bak_not_loading", seconds=int(self.timeout_s))) from exc

    def login(self) -> None:
        """Logs in with the login form; ``UserError`` when Bakaláři rejects it."""
        if self.root.startswith("http://"):
            self.log("Warning: Bakaláři URL uses plain http:// — credentials will travel unencrypted.")
        page = self._send("GET", "/login")
        if not _is_login_page(page):
            # The session cookie is still valid: /login went straight to the app.
            self.logged_in = True
            return
        fields = dict(form_fields(page.text, "formlogin"))
        fields.update({"username": self.username, "password": self._password(),
                       "returnUrl": fields.get("returnUrl", ""), "login": ""})
        self.log("Logging in to Bakaláři…")
        resp = self._send("POST", _login_post_url(page), data=fields)
        if _is_login_page(resp):
            self.logged_in = False
            detail = login_error_text(resp) or f"HTTP {resp.status_code}, still on the login page"
            raise UserError(t("bak_login_rejected", detail=detail[:200]))
        self.logged_in = True
        self.log("Logged in to Bakaláři.")

    def request(self, method: str, path: str, **kwargs) -> httpx.Response:
        """One request in the logged-in session (logs in first when needed)."""
        if not self.logged_in:
            self.login()
        resp = self._send(method, path, **kwargs)
        if _is_login_page(resp):
            self.logged_in = False
            self.log("Bakaláři session expired, logging in again…")
            self.login()
            resp = self._send(method, path, **kwargs)
            if _is_login_page(resp):
                raise SessionExpired(f"{method} {path}: still on the login page after logging in")
        resp.raise_for_status()
        return resp

    def send_once(self, method: str, path: str, **kwargs) -> httpx.Response:
        """One request that must never be repeated (the excuse post).

        No re-login, no retry and redirects are not followed: the caller
        reads the raw reply. Network failures raise ``UserError`` with the
        httpx error as ``__cause__`` so the caller can tell "never sent"
        (connect errors) from "maybe sent".
        """
        if not self.logged_in:
            self.login()
        return self._send(method, path, once=True, follow_redirects=False, **kwargs)

    def get_html(self, path: str, **kwargs) -> str:
        return self.request("GET", path, **kwargs).text

    def json(self, method: str, path: str, **kwargs):
        """The ``data`` of a ``{success, error, data}`` JSON reply (raises on failure)."""
        resp = self.request(method, path, **kwargs)
        try:
            payload = resp.json()
        except ValueError as exc:
            raise RuntimeError(f"{path}: not a JSON reply (HTTP {resp.status_code})") from exc
        if isinstance(payload, dict) and "success" in payload:
            if not payload.get("success"):
                raise RuntimeError(f"{path}: {payload.get('error') or 'request failed'}")
            return payload.get("data")
        return payload

    def dx_callback(self, path: str, page_html: str, callback_id: str, param: str) -> str:
        """Runs a DevExpress callback of a page and returns its result HTML."""
        fields = form_fields(page_html)
        fields += [("__CALLBACKID", callback_id), ("__CALLBACKPARAM", f"c0:{param}")]
        resp = self.request("POST", path, **form_body(fields))
        return dx_callback_result(resp.text)
