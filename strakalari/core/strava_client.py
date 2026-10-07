"""Strava.cz over plain HTTP: login and the menu, through the web app's own API.

The Strava web app (app.strava.cz) is a single-page app talking to its own
JSON endpoints (``/api/login``, ``/api/objednavky`` …); this client sends
the same requests. Ordering lives in :class:`~.strava_ordering.OrderingMixin`.
"""

import json
import os
from urllib.parse import urlsplit

from .helpers import decrypt_strict, is_encrypted_flag, _resolve_path, example_path_for
from .config import _looks_like_placeholder
from .extractors.strava import menu_from_reply, menu_tables
from .error_report import UserError, timeout_user_message
from .i18n import t
from .strava_ordering import OrderingMixin

#: Sent with every request; the same browser identity the app always used.
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) Gecko/20100101 Firefox/124.0"
#: Error numbers after which the web app drops the session and logs out.
SESSION_GONE = frozenset({13, 15, 10102, 90, 1009, 1010, 1011, 1014, 30, 10104})


class StravaError(RuntimeError):
    """A ``{"state": "error"}`` reply of the Strava API."""

    def __init__(self, number, message: str):
        self.number = number
        self.message = str(message or "")
        super().__init__(f"Strava error {number}: {self.message}".strip())


def api_root(url: str) -> str:
    """The web app origin: ``strava.cz`` (the login page users know) → ``app.strava.cz``."""
    raw = str(url or "").strip() or "https://strava.cz"
    if not raw.startswith(("http://", "https://")):
        raw = f"https://{raw}"
    parts = urlsplit(raw)
    host = parts.netloc.lower()
    if host in ("strava.cz", "www.strava.cz"):
        host = "app.strava.cz"
    return f"{parts.scheme}://{host}"


class StravaClient(OrderingMixin):
    """Strava.cz session: login and the menu (over HTTP, no browser).

    Ordering lives in :class:`~.strava_ordering.OrderingMixin`.
    """

    def __init__(self, config_data, logger=None, transport=None):
        # Cooperative cancellation (mirrors BakalariClient; set from
        # Strakalari.fetch_strava_data before each fetch).
        self.cancel_requested = False
        # Optional live predicate (e.g. GUI state) polled alongside the
        # flag so a cancel issued mid-fetch is honored without re-setting.
        self.cancel_callback = None
        self.config = config_data or {}
        # Test hook: an httpx transport replacing the network.
        self._transport = transport
        self._http = None

        self.strava_url = self.config.get("strava_url", "https://strava.cz")

        # Legacy key aliases (read-only compat: nothing writes strava_id /
        # strava_user / strava_enable anymore; the settings UI uses the
        # canonical strava_canteen_id / strava_username / use_strava keys).
        raw_strava_id = self.config.get("strava_canteen_id", "") or self.config.get("strava_id", "")
        self.strava_id = str(raw_strava_id).strip()
        self.strava_username = self.config.get("strava_username", "") or self.config.get("strava_user", "")
        self.strava_password = self.config.get("strava_password", "")
        self.strava_password_encrypted = self.config.get("strava_password_encrypted", False)
        self.strava_enable = self.config.get("use_strava", self.config.get("strava_enable", True))

        self.strava_blacklist = _resolve_path(self.config.get("strava_blacklist", "./strava_blacklist.json"))
        self.logger = logger
        self.logged_in = False
        # Session of the web app: what /api/login returned.
        self.sid = ""
        self.s5url = ""
        self.ignore_cert = ""
        self.user = {}

        self.strava_blacklist_json = []
        self.blacklist_broken = False
        bl_path = self.strava_blacklist
        if self.strava_enable:
            if not os.path.exists(bl_path):
                example_bl = example_path_for(bl_path)
                if os.path.exists(example_bl):
                    bl_path = example_bl
            if os.path.exists(bl_path):
                try:
                    with open(bl_path, "r", encoding="utf-8") as f:
                        loaded = json.load(f)
                    if isinstance(loaded, list):
                        # Never let the example template placeholder govern
                        # real filtering (fresh installs may only have the
                        # example file; a copied example stays harmless).
                        # Same placeholder logic as ConfigManager.
                        self.strava_blacklist_json = [
                            kw for kw in loaded
                            if kw and not _looks_like_placeholder(kw)
                        ]
                    else:
                        self.log(f"Warning: strava blacklist is not a JSON list, treating as empty: {bl_path}")
                        self.strava_blacklist_json = []
                except Exception as e:
                    from .helpers import quarantine_corrupt_file

                    # Fail closed for automatic ordering: an unreadable
                    # blacklist must not silently re-allow banned meals.
                    # (Explicit manual picks bypass the blacklist by design.)
                    # Only undecodable content is quarantined, never a
                    # merely busy file or the shipped example.
                    self.blacklist_broken = True
                    backup = ""
                    if (isinstance(e, ValueError)
                            and os.path.abspath(bl_path) != os.path.abspath(
                                example_path_for(bl_path))):
                        backup = quarantine_corrupt_file(bl_path)
                    hint = f" (preserved at {backup})" if backup else ""
                    self.log(f"Warning: Could not read strava blacklist: {e}{hint}")
                    self.strava_blacklist_json = []

        # The raw menu ({table: [meal]}) of the last fetch; ordering works on it.
        self.menu = {}
        self.foodDict = {}
        self.orderedDict = {}
        # Order changes made by order() since the last reset (evaluate() and
        # strava_order_selected reset it per run). Lets callers save only
        # when something actually changed.
        self.clicks_made = 0
        # Set by order() when the account has too little money for a meal
        # (Strava's warning 5005); every further meal order would fail the
        # same way, so callers stop ordering and tell the user to top up.
        self.insufficient_balance = False
        self.last_notice = ""
        self._pending = []

    def log(self, msg):
        if self.logger:
            self.logger(msg)

    def _debug(self, what: str, exc: BaseException) -> None:
        """Logs a deliberately tolerated failure (see ``describe_swallowed``)."""
        from .helpers import describe_swallowed

        self.log(describe_swallowed(what, exc))

    def _cancelled(self) -> bool:
        if getattr(self, "cancel_requested", False):
            return True
        cb = getattr(self, "cancel_callback", None)
        if callable(cb):
            try:
                return bool(cb())
            except Exception:
                return False
        return False

    def _raise_if_cancelled(self) -> None:
        """Aborts the run promptly when the user hit Zrušit."""
        from .cancel import raise_if_cancelled

        raise_if_cancelled(self._cancelled)

    def _seconds(self, key: str, default: float) -> float:
        import math as _math

        try:
            value = float(self.config.get(key, default))
        except (TypeError, ValueError):
            return default
        # Negative/NaN/inf timeouts come from hand-edited configs.
        if not _math.isfinite(value) or value <= 0:
            return default
        return value

    # -- HTTP --------------------------------------------------------------
    def _client(self):
        if self._http is None:
            import httpx

            timeout_s = self._seconds("page_load_timeout_s", 60.0)
            self._http = httpx.Client(
                base_url=api_root(self.strava_url),
                timeout=httpx.Timeout(timeout_s, connect=min(timeout_s, 20.0)),
                headers={"User-Agent": USER_AGENT, "Accept-Language": "cs,en;q=0.8"},
                transport=self._transport,
            )
        return self._http

    def close(self) -> None:
        if self._http is not None:
            try:
                self._http.close()
            except Exception as e:
                self._debug("closing the Strava HTTP session", e)
            self._http = None
        self.logged_in = False

    def _post(self, path: str, body: dict, *, once: bool = False):
        """One API call as the web app makes it (JSON text body); the parsed reply.

        Retried once when the connection broke before any reply (a dropped
        kept-alive connection) — except ``once`` calls (the save).
        """
        import httpx

        self._raise_if_cancelled()
        client = self._client()
        timeout_s = int(client.timeout.read or 60)
        content = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers = {"Content-Type": "text/plain;charset=UTF-8"}
        try:
            try:
                resp = client.post(path, content=content, headers=headers)
            except (httpx.RemoteProtocolError, httpx.ReadError) as exc:
                if once:
                    raise
                self.log(f"Strava connection dropped ({type(exc).__name__}), retrying once: {path}")
                self._raise_if_cancelled()
                resp = client.post(path, content=content, headers=headers)
        except httpx.TimeoutException as exc:
            self.log(f"Strava request timed out after {timeout_s} s: {path}")
            raise UserError(timeout_user_message()) from exc
        except httpx.TransportError as exc:
            self.log(f"Strava request failed: {path}: {type(exc).__name__}: {exc}")
            if isinstance(exc, httpx.ConnectError):
                raise UserError(t("strava_unreachable")) from exc
            raise UserError(t("strava_connection_lost")) from exc
        if not (resp.is_success or resp.status_code == 555):
            self.log(f"Strava answered HTTP {resp.status_code}: {path}")
            raise UserError(t("strava_server_error", status=resp.status_code))
        try:
            return resp.json()
        except ValueError as exc:
            raise StravaError(resp.status_code, "not a JSON reply") from exc

    def _call(self, path: str, body: dict, *, relogin: bool = True):
        """``_post`` that raises :class:`StravaError` on an error reply and
        logs in again once when Strava dropped the session (``relogin``;
        without it the call is also never repeated on a broken connection)."""
        reply = self._post(path, body, once=not relogin)
        if isinstance(reply, dict) and reply.get("state") == "error":
            number = reply.get("number")
            if relogin and number in SESSION_GONE:
                self.log(f"Strava session expired ({number}), logging in again…")
                self.logged_in = False
                self.login()
                return self._call(path, {**body, "sid": self.sid}, relogin=False)
            raise StravaError(number, reply.get("message"))
        return reply

    def _session_body(self, url_key: str = "url") -> dict:
        return {"cislo": self.strava_id, "sid": self.sid, url_key: self.s5url,
                "lang": "CZ", "ignoreCert": self.ignore_cert}

    # -- Login and menu ------------------------------------------------------
    def _plain_password(self) -> str:
        if is_encrypted_flag(self.strava_password_encrypted):
            password = decrypt_strict(self.strava_password)
            if password is None:
                raise UserError(t("strava_password_undecryptable"))
            return password
        return self.strava_password

    def login(self):
        self._raise_if_cancelled()
        if not str(getattr(self, "strava_id", "") or "").strip():
            raise UserError(t("strava_missing_canteen"))
        if not str(getattr(self, "strava_username", "") or "").strip():
            raise UserError(t("strava_missing_user"))
        if not str(getattr(self, "strava_password", "") or "").strip():
            raise UserError(t("strava_missing_password"))
        if api_root(self.strava_url).startswith("http://"):
            self.log("Warning: Strava URL uses plain http:// — credentials will travel unencrypted.")
        reply = self._post("/api/login", {
            "cislo": self.strava_id, "jmeno": self.strava_username, "heslo": self._plain_password(),
            "zustatPrihlasen": False, "environment": "W", "lang": "CZ"})
        if not isinstance(reply, dict) or reply.get("state") == "error" or not reply.get("sid"):
            self.logged_in = False
            detail = reply.get("message") if isinstance(reply, dict) else ""
            number = reply.get("number") if isinstance(reply, dict) else ""
            self.log(f"Strava login rejected ({number}): {detail}")
            if str(detail or "").strip():
                raise UserError(t("strava_login_rejected", detail=str(detail).strip()[:200]))
            raise UserError(t("strava_login_failed"))
        self.sid = str(reply.get("sid"))
        self.s5url = str(reply.get("s5url") or "")
        self.strava_id = str(reply.get("cislo") or self.strava_id)
        self.ignore_cert = reply.get("ignoreCert", "")
        self.user = reply.get("uzivatel") if isinstance(reply.get("uzivatel"), dict) else {}
        self.logged_in = True
        self.log("Logged in to Strava.")

    def fetch_data(self):
        self._raise_if_cancelled()
        if not self.logged_in:
            self.login()
        self._pending = []
        try:
            reply = self._call("/api/objednavky", {**self._session_body("s5url"), "konto": 0, "podminka": ""})
        except (UserError, InterruptedError):
            raise
        except StravaError as e:
            self.log(f"Strava menu did not load: {e}")
            raise UserError(t("strava_menu_failed", detail=e.message or e.number)) from e
        self.menu = {key: meals for key, meals in menu_tables(reply)}
        self.foodDict, self.orderedDict = menu_from_reply(reply)
        if not self.foodDict:
            # Never serve the previous menu as fresh: downstream refresh
            # paths treat an empty menu as a failed fetch and keep the
            # last good cache instead of overwriting it.
            self.log("Warning: Strava menu is empty — showing no menu, not stale data.")
        elif not self.orderedDict:
            self.log("Strava menu loaded, no meal is ordered on any listed day.")
        return {
            "foodDict": self.foodDict,
            "orderedDict": self.orderedDict
        }
