"""Bakaláři web client: session and login, over plain HTTP.

Everything goes to the Bakaláři web pages and their own endpoints
(``bakalari_http``), never through a browser and never the mobile API.

The class is assembled from mixins so no single file carries the whole
client: ``bakalari_timetable`` (weekly + stable timetable),
``bakalari_data`` (marks, absence, sent excuses, substitutions, baseline)
and ``bakalari_excuse`` (the excuse form). Pure parsing helpers live in
``bakalari_common`` and are re-exported here for existing imports.
"""

from .helpers import decrypt_strict, is_encrypted_flag, template_texts
from .i18n import t
from .error_report import UserError
from .bakalari_common import (
    parse_timetable_detail,
    week_offsets,
)
from .bakalari_data import DataMixin
from .bakalari_excuse import ExcuseFormMixin
from .bakalari_timetable import TimetableMixin

__all__ = ["BakalariClient", "parse_timetable_detail", "week_offsets"]

#: Sent with every HTTP request; the same browser identity the app always used.
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) Gecko/20100101 Firefox/124.0"


class BakalariClient(TimetableMixin, DataMixin, ExcuseFormMixin):
    """Bakaláři web session: login and requests; data fetching and the
    excuse form live in the mixins (bakalari_timetable / bakalari_data /
    bakalari_excuse)."""

    def __init__(self, config_data, logger=None, transport=None):
        # HTTP session, created on first use; ``transport`` is a test hook
        # (an httpx transport replacing the network).
        self.session = None
        self._transport = transport
        self.config = config_data or {}

        self.bakalari_url = self.config.get("bakalari_url", "")
        self.username = self.config.get("bakalari_username", "")
        self.password = self.config.get("bakalari_password", "")
        self.password_encrypted = self.config.get("bakalari_password_encrypted", False)
        try:
            self.go_back_weeks = min(max(int(self.config.get("go_back_weeks", 4)), 0), 52)
        except (TypeError, ValueError):
            self.go_back_weeks = 4
        try:
            self.go_forward_weeks = min(max(int(self.config.get("go_forward_weeks", 1)), 0), 8)
        except (TypeError, ValueError):
            self.go_forward_weeks = 1
        self.signature = self.config.get("your_signature", "")

        self.late_income_excuses = template_texts(self.config.get("late_income_excuses", []))
        self.left_soon_excuses = template_texts(self.config.get("left_soon_excuses", []))
        self.long_absence_excuses = template_texts(self.config.get("long_absence_excuses", []))
        self.short_absence_excuses = template_texts(self.config.get("short_absence_excuses", []))

        self.logger = logger
        self.logged_in = False
        # Cooperative cancellation (mirrors StravaClient.cancel_requested;
        # set from Strakalari.fetch_bakalari_data before each fetch).
        self.cancel_requested = False
        # Optional live predicate (e.g. GUI state) polled alongside the flag
        # so a cancel issued mid-fetch is honored without re-setting flags.
        self.cancel_callback = None

        self.timetable_sources = []
        self.timetableData = {}
        self.absencePercentages = {}
        # Elapsed hours per subject from the same absence data
        # (see absence_from_subjects).
        self.absenceDetails = {}
        # School-official subject set (Výuka → Přehled předmětů): only
        # these count toward absence limits. Empty until fetched.
        self.subjectDirectory = {}
        # Průběžná klasifikace (see get_grades): {subject: [{Grade, Weight, Date}]},
        # each subject list sorted by date (oldest first). Empty until fetched.
        self.grades = {}
        # Last grades-scrape failure ("") when fresh; non-empty means the
        # displayed marks are last-known/stale, not freshly scraped.
        self.grades_error = ""
        # Already-sent excuses scraped from Komens → Odeslané
        # (see fetch_sent_excuses). Empty until synced; never part of
        # fetch_data() so routine refreshes stay read-only and fast.
        self.sentExcuses = []
        # Last sent-excuse sync failure ("") = fresh/OK; non-empty = unknown.
        self.sentExcuses_error = ""
        # First day of the range Odeslané showed on the last sync (the
        # web defaults to one month) — bounds the excuse window. None = unknown.
        self.sentExcuses_from = None
        # True after a send the site never confirmed (see
        # ExcuseFormMixin.execute_excuse): it may have gone out.
        self.last_submit_uncertain = False
        # Past school-year weeks (Mondays) to backfill into the timetable
        # history on top of the regular window — set by the refresh.
        self.history_weeks = []
        # Mondays of the weeks the last timetable scrape really loaded.
        self.timetable_loaded_weeks = set()
        # Learned stable timetable (SlotBaseline per slot) + actual-vs-stable
        # diffs for the loaded weeks — filled by update_stable_baseline()
        # during fetch_data() so the run itself compares against stable.
        self.stableBaseline = {}
        # True when the baseline is the scraped "Stálý" template week
        # (complete: empty slots are free periods). False when the view
        # was not scraped — there is then no baseline at all.
        self.stable_complete = False
        # Last absence-scrape failure ("") when fresh; non-empty means the
        # displayed percentages are last-known/stale, not freshly scraped.
        self.absence_error = ""
        self.weekChanges = []
        # Raw scraped "Stálý rozvrh" (stable timetable) view, keyed by day
        # like timetableData. Empty when the view could not be scraped —
        # the run then has no stable baseline.
        self.stableTimetableData = {}
        # Personal substitution feed (Výuka → Suplování), tri-state like
        # sentExcuses: a list (possibly empty) = the feed was actually
        # read; None = unknown (not yet synced, failed or skipped).
        self.substitutions = None
        self.substitutions_error = ""

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
        # Zero/negative/NaN/inf timeouts come from hand-edited configs.
        if not _math.isfinite(value) or value <= 0:
            return default
        return value

    def _plain_password(self) -> str:
        if is_encrypted_flag(self.password_encrypted):
            password = decrypt_strict(self.password)
            if password is None:
                raise UserError(t("bak_password_undecryptable"))
            return password
        return self.password

    def _session(self):
        """The HTTP session, created on first use (no network yet)."""
        if self.session is None:
            from .bakalari_http import BakalariSession

            url = str(self.bakalari_url or "").strip()
            if not url:
                raise UserError(t("bak_missing_url"))
            if not str(self.username or "").strip():
                raise UserError(t("bak_missing_user"))
            if not str(self.password or "").strip():
                raise UserError(t("bak_missing_password"))
            self.session = BakalariSession(
                url, self.username, self._plain_password,
                timeout_s=self._seconds("page_load_timeout_s", 60.0),
                user_agent=USER_AGENT, cancelled=self._cancelled,
                logger=self.log, transport=self._transport,
            )
        return self.session

    def login(self) -> None:
        """Logs in unless the session already is; ``UserError`` when Bakaláři rejects it."""
        session = self._session()
        if session.logged_in:
            self.logged_in = True
            return
        try:
            session.login()
        except InterruptedError:
            raise
        except Exception as e:
            self.logged_in = False
            self.log(f"Login failed: {e}")
            raise
        self.logged_in = True

    def close(self) -> None:
        """Closes the HTTP session."""
        if self.session is not None:
            try:
                self.session.close()
            except Exception as e:
                self._debug("closing the Bakaláři HTTP session", e)
            self.session = None
