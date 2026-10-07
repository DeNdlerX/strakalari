"""Bakaláři data fetching: marks, absence, sent excuses, subjects, substitutions, stable baseline."""

import json
import re
from datetime import date, datetime, time, timedelta, timezone

from .extractors.bakalari import (
    absence_date_range,
    absence_from_subjects,
    extract_grades,
    outbox_excuse_ids,
    sent_excuse_entries,
    store_rows,
    subject_directory_from_rows,
    substitutions_from_weeks,
)

#: Komens → Odeslané (the menu's own link), its list callback control and
#: the list type the page reports for the sent folder.
_OUTBOX_PATH = "/next/komens.aspx?l=o"
_OUTBOX_CALLBACK_ID = "ctl00$cphmain$message_list_content"
_OUTBOX_LIST_TYPE = "odeslane"


def _utc_iso(day: date, at: time) -> str:
    """Local ``day`` + ``at`` as the UTC ISO string the web's scripts send."""
    return datetime.combine(day, at).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class DataMixin:
    """Mixin of :class:`~.bakalari_client.BakalariClient`; uses its session state."""

    def get_grades(self):
        """Fetches průběžná klasifikace (Klasifikace → Průběžná).

        Parses the ``data-clasif`` marks of the grades page and stores them
        on ``self.grades`` grouped per subject, each list sorted by date
        (oldest first). Returns the dict. Best-effort: failures only log +
        set ``grades_error`` (mirroring absence handling) so one changed
        page never breaks the whole Bakaláři run. Only raises on user cancel.
        """
        self._raise_if_cancelled()
        try:
            html = self._session().get_html("/next/prubzna.aspx")
            grades = extract_grades(html)
            self.grades = grades
            if grades:
                self.grades_error = ""
                n_marks = sum(len(v) for v in grades.values())
                self.log(f"Grades synced: {n_marks} marks in {len(grades)} subjects.")
            else:
                self.log("Warning: no grades parsed — "
                         "either no marks recorded or the page format changed.")
                # An empty parse of something that is not the grades page
                # (error page, changed URL) must not wipe the last good cache.
                self.grades_error = "" if "prubzna.aspx" in html else "grades page did not load (empty parse)"
            return grades
        except InterruptedError:
            raise
        except Exception as e:
            self.grades_error = f"{type(e).__name__}: {e}".splitlines()[0][:200]
            self.log(f"Could not obtain grades: {e} — showing no marks, not stale data.")
            # Never serve previous marks as fresh: callers treat an empty
            # dict as a failed sync (the refresh keeps the last good cache).
            self.grades = {}
            return {}

    def obtain_absence_info(self):
        self._raise_if_cancelled()
        try:
            session = self._session()
            page = session.get_html("/Absence/Continuous")
            dates = absence_date_range(page)
            if dates is None:
                raise RuntimeError("absence page without its date range (format changed?)")
            rows = session.json("GET", "/Absence/Continuous/GetAbsenceBySubjects", params={
                "dateFrom": dates[0], "dateTo": dates[1], "lateChecked": "false",
                "schoolChecked": "false", "soonChecked": "false",
            })
            if store_rows(rows) is None:
                # A failed load, not "no absence": the refresh keeps the cache.
                raise RuntimeError("absence reply without rows (format changed?)")
            self.absencePercentages, self.absenceDetails = absence_from_subjects(rows)
            self.absence_error = ""
            if not self.absencePercentages:
                self.log("Warning: no absence percentages parsed — "
                         "either no absence recorded or the format changed.")

            try:
                warn_pct = float(self.config.get("absence_warn_pct", 15.0))
            except (TypeError, ValueError):
                warn_pct = 15.0
            try:
                crit_pct = float(self.config.get("absence_critical_pct", 25.0))
            except (TypeError, ValueError):
                crit_pct = 25.0
            if not (0 < warn_pct < crit_pct <= 100):
                warn_pct, crit_pct = 15.0, 25.0

            for key, value in self.absencePercentages.items():
                if 0.0 <= value <= warn_pct:
                    self.log(f"Recommendation: Skip the {key} lessons! Your absence is only {value}%!")
                elif value < crit_pct:
                    self.log(f"Recommendation: Watch the {key} lessons, your absence ({value}%) is approaching the {crit_pct}% limit!")
                elif value >= crit_pct:
                    self.log(f"Recommendation: You should probably attend the {key} lessons more, your absence is {value}%!")
        except InterruptedError:
            raise
        except Exception as e:
            self.absence_error = f"{type(e).__name__}: {e}".splitlines()[0][:200]
            self.log(f"Could not obtain absence info: {e} — showing no data, not stale values.")
            # Never serve previous percentages as fresh: callers treat an
            # empty dict as a failed sync (the refresh keeps the last good
            # cache instead of overwriting it).
            self.absencePercentages = {}
            self.absenceDetails = {}

    def fetch_sent_excuses(self, limit: int = 100) -> list | None:
        """Reads already-sent excuses (Komens → Odeslané → OMLUVENKA).

        Loads the outbox list the way the page does (its DevExpress list
        callback), then each excuse's detail (Od/Do dates + optional
        lessons), and stores the history-shaped entries on
        ``self.sentExcuses``. Returns them.

        Tri-state: a list (possibly empty) = the outbox was actually read
        (empty genuinely means "nothing sent"); None = the sync failed or
        was skipped, i.e. unknown — callers must treat it as "nothing
        learned", never as "nothing sent". Never raises except on user
        cancel. ``self.sentExcuses_error`` carries the last failure.
        """
        self._raise_if_cancelled()
        try:
            limit = max(1, int(limit))
        except (TypeError, ValueError):
            limit = 100
        try:
            session = self._session()
            page, ids = self._outbox_excuse_ids(session, limit + 1)
            self.sentExcuses_from = self._outbox_period_start(page)
            if not ids:
                self.log("No sent excuses (OMLUVENKA) found in Komens → Odeslané.")
                self.sentExcuses = []
                self.sentExcuses_error = ""
                return []
            if len(ids) > limit:
                self.log(f"Sent excuses: {len(ids)} on the web, reading first {limit}.")
                ids = ids[:limit]
            else:
                self.log(f"Komens → Odeslané: {len(ids)} excuse(s) on the web.")

            parsed: list = []
            read = 0
            for msg_id in ids:
                self._raise_if_cancelled()
                try:
                    detail = self._outbox_detail(session, msg_id)
                except InterruptedError:
                    raise
                except Exception as e:
                    self.log(f"Warning: could not read sent excuse {msg_id}: {e}")
                    continue
                read += 1
                for entry in sent_excuse_entries(detail):
                    if entry not in parsed:
                        parsed.append(entry)

            if not read:
                # Not one detail readable: [] must not read as "nothing
                # sent" — report unknown (None) so callers keep the last
                # known state.
                self.sentExcuses = None
                self.sentExcuses_error = "outbox details unreadable"
                self.log("Warning: sent-excuse details unreadable — keeping last known state.")
                return None
            self.sentExcuses = parsed
            self.sentExcuses_error = ""
            if len(parsed) != read:
                # One hour-based web message expands to three history
                # entries (income + soon + days and hours) for dedupe —
                # report the web message count so the log never claims more
                # sent messages than the outbox actually holds.
                self.log(f"Sent excuses synced from the web: {read} message(s) "
                         f"({len(parsed)} history entries).")
            else:
                self.log(f"Sent excuses synced from the web: {read} message(s).")
            return parsed
        except InterruptedError:
            raise
        except Exception as e:
            self.sentExcuses_error = f"{type(e).__name__}: {e}".splitlines()[0][:200]
            self.log(f"Could not sync sent excuses: {e} — will retry next time.")
            return None

    def _outbox_excuse_ids(self, session, page_size: int) -> tuple:
        """``(page_html, ids)``: Komens → Odeslané and the message ids of its
        excuse rows, loaded the way the page does (its list callback)."""
        page = session.get_html(_OUTBOX_PATH)
        list_type = re.search(r'id="hfListType"[^>]*?value="([^"]*)"', page)
        if not list_type or list_type.group(1) != _OUTBOX_LIST_TYPE:
            # Another folder read as the outbox would report "nothing sent".
            raise RuntimeError("Komens page is not the sent folder (format changed?)")
        param = json.dumps({
            "showRepressed": False, "pageNumber": 1, "pageSize": page_size,
            "reloadMessages": True, "sortOrder": 0, "onlyRating": True,
            "onlyExcuses": True, "onlySystemMessages": True,
            "onlyGeneralMessages": True, "onlyUnread": False,
        }, separators=(",", ":"))
        listing = session.dx_callback(_OUTBOX_PATH, page, _OUTBOX_CALLBACK_ID, param)
        if "komens-messages-wrapper" not in listing:
            raise RuntimeError("outbox list did not load (format changed?)")
        return page, outbox_excuse_ids(listing)

    @staticmethod
    def _outbox_detail(session, msg_id: str) -> dict:
        """The detail of one sent message (``/Komens/GetMessageDataAsync``)."""
        return session.json("POST", "/Komens/GetMessageDataAsync", json={
            "idmsg": msg_id, "komensMessageListType": _OUTBOX_LIST_TYPE})

    def _outbox_period_start(self, page_html: str):
        """First day of the period Odeslané lists ("26.8.2026 - 25.9.2026"), or None."""
        from .models import parse_cz_date

        label = re.search(r'id="cphmain_obdobiLabel"[^>]*>([^<]*)<', str(page_html or ""))
        if not label:
            return None
        found = re.findall(r"\d{1,2}\s*\.\s*\d{1,2}\s*\.\s*\d{4}", label.group(1))
        if not found:
            return None
        try:
            start = parse_cz_date(re.sub(r"\s+", "", found[0]))
        except Exception:
            return None
        if start is not None:
            self.log(f"Komens → Odeslané lists {label.group(1).strip()}.")
        return start

    def fetch_subject_directory(self) -> dict:
        """Fetches the school-official subject directory (Výuka → Přehled předmětů).

        Only the subject names are used downstream (the canonical
        absence-tracked set); teachers ride along for display. Returns the
        dict (possibly empty). Best-effort: failures only log, mirroring
        the grades handling. Only raises on user cancel.
        """
        self._raise_if_cancelled()
        try:
            rows = self._session().json("POST", "/Teaching/Subjects",
                                        headers={"X-Requested-With": "XMLHttpRequest"})
            directory = subject_directory_from_rows(rows)
            self.subjectDirectory = directory
            if directory:
                self.log(f"Subject directory synced: {len(directory)} subjects.")
            else:
                self.log("Warning: no subjects parsed from the directory.")
            return directory
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Could not sync subject directory: {e} — continuing without it.")
            # Unknown, not stale: clear so consumers fall back to the last
            # good cache instead of treating old rows as freshly fetched.
            self.subjectDirectory = {}
            return {}

    def fetch_substitutions(self) -> list | None:
        """Reads the personal substitution feed (Výuka → Suplování).

        Same range as the page shows by default: from today's week to the
        week 14 days ahead. Returns the parsed feed entries (possibly empty
        = genuinely no changes) or None when the sync failed (unknown —
        callers must not treat it as no changes). Only raises on user
        cancel. Best-effort: failures only log + set substitutions_error.
        """
        self._raise_if_cancelled()
        today = date.today()
        start = today - timedelta(days=today.weekday())
        end_day = today + timedelta(days=14)
        end = end_day - timedelta(days=end_day.weekday()) + timedelta(days=4)
        try:
            weeks = self._session().json("POST", "/Timetable/substitutions/dates", data={
                "dateFrom": _utc_iso(start, time(0, 0)),
                "dateTo": _utc_iso(end, time(0, 0)),
            })
            entries = substitutions_from_weeks(weeks)
            self.substitutions = entries
            self.substitutions_error = ""
            self.log(f"Substitution feed synced: {len(entries)} entries.")
            return entries
        except InterruptedError:
            raise
        except Exception as e:
            self.substitutions_error = f"{type(e).__name__}: {e}".splitlines()[0][:200]
            self.log(f"Could not sync substitution feed: {e} — will retry next time.")
            return None

    def update_stable_baseline(self):
        """Builds the stable baseline and diffs the loaded weeks against it.

        The baseline comes only from the scraped "Stálý rozvrh" view. When
        that scrape failed there is no baseline at all: guessing a template
        from actual weeks flagged real lessons as changes, so Bakaláři's
        own change flags decide instead. Stores the baseline on
        ``self.stableBaseline`` and the diffs on ``self.weekChanges``, logs
        a short summary, and returns the baseline. Never raises.
        """
        from .schedule import (
            apply_substitution_feed,
            backfill_stable_facts,
            baseline_from_stable_timetable,
            iter_changes,
        )

        baseline = {}
        if self.stableTimetableData:
            try:
                baseline = baseline_from_stable_timetable(self.stableTimetableData)
            except Exception as e:
                self.log(f"Warning: could not use scraped stable timetable: {e}")
                baseline = {}
        used_scraped = bool(baseline)
        source = "scraped stable timetable (Stálý rozvrh)"
        if not baseline:
            self.log("No stable timetable this run — changes come from Bakaláři's own flags.")
        self.stableBaseline = baseline
        # The scraped template week is complete: an empty slot is a free
        # period, so added/missing lessons are real changes.
        self.stable_complete = used_scraped
        try:
            feed = getattr(self, "substitutions", None)
            if isinstance(feed, list) and feed:
                stamped = apply_substitution_feed(self.timetableData, feed)
                if stamped:
                    self.log(f"Substitution feed stamped {stamped} lesson(s).")
        except Exception as e:
            self.log(f"Warning: could not apply substitution feed: {e}")
        try:
            matched = backfill_stable_facts(self.timetableData, baseline)
            if matched:
                self.log(f"Stable: {matched} cancelled lesson(s) matched to stable slots.")
        except Exception as e:
            self.log(f"Warning: could not match cancelled lessons to stable: {e}")
        try:
            self.weekChanges = iter_changes(
                self.timetableData, baseline, complete=used_scraped)
        except Exception as e:
            self.log(f"Warning: could not compare weeks against stable: {e}")
            self.weekChanges = []
        if baseline:
            self.log(f"Stable timetable: {len(baseline)} slots ({source}).")
        if self.weekChanges:
            self.log(f"Schedule changes vs stable: {len(self.weekChanges)}.")
            for item in self.weekChanges[:5]:
                try:
                    lesson = item.get("lesson", {}) or {}
                    diff = item.get("diff")
                    fields = ", ".join(getattr(diff, "changed", []) or [])
                    subject = lesson.get("subject", "?")
                    day_key = item.get("day_key", "?")
                    note = getattr(diff, "note", "") or ""
                    detail = f"{subject} {day_key} [{fields}]".strip()
                    if note:
                        detail += f": {note}"
                    self.log(f"  Change: {detail}")
                except Exception:
                    continue
            if len(self.weekChanges) > 5:
                self.log(f"  … and {len(self.weekChanges) - 5} more.")
        else:
            self.log("No schedule changes vs stable.")
        return self.stableBaseline

    def fetch_data(self):
        self.timetable_sources = []
        self.timetableData = {}
        self.absencePercentages = {}
        # Elapsed hours per subject from the same absence data
        # (see absence_from_subjects).
        self.absenceDetails = {}
        # School-official subject set (Výuka → Přehled předmětů): only
        # these count toward absence limits. Empty until fetched.
        self.subjectDirectory = {}
        self.absence_error = ""
        self.grades = {}
        self.grades_error = ""
        # NOTE: sentExcuses is deliberately NOT reset here: the outbox sync
        # (fetch_sent_excuses) never runs inside fetch_data(), so clearing
        # would report "nothing sent" for state that is simply unknown.
        self.stableBaseline = {}
        self.stable_complete = False
        self.weekChanges = []
        self.stableTimetableData = {}
        # Tri-state like sentExcuses: None = unknown until the feed sync
        # below actually reads it (never [] = "no changes" by default).
        self.substitutions = None
        self.substitutions_error = ""

        self._raise_if_cancelled()
        self.login()
        self.fetch_timetable_weeks()
        for details in self.timetable_sources:
            self.add_timetable_details(details)
        try:
            self.extract_stable_timetable()
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Warning: stable timetable scrape failed ({e}), "
                     "no stable timetable this run.")
        # Personal substitution feed rides along the same loop so the
        # authoritative change list is available when the baseline is
        # built below. Best effort only — it must never fail the run.
        try:
            self.fetch_substitutions()
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Warning: substitution feed failed ({e}), continuing without it.")
            self.substitutions = None
            self.substitutions_error = str(e).splitlines()[0][:200] if str(e) else "failed"
        self.update_stable_baseline()
        self.obtain_absence_info()
        # Průběžná klasifikace rides along the same Bakalari loop so one
        # refresh carries timetable + absence + grades together. Best
        # effort only — a changed grades page must never fail the run.
        try:
            self.get_grades()
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Warning: grades scrape failed ({e}), continuing without fresh grades.")
        # Subject directory rides along the same loop (one extra module).
        # Best effort only — an empty directory simply disables the
        # tracked-subject filter downstream.
        try:
            self.fetch_subject_directory()
        except InterruptedError:
            raise
        except Exception as e:
            self.log(f"Warning: subject directory failed ({e}), continuing without it.")
        # NOTE: stable_baseline uses (weekday, period) tuple keys and
        # SlotBaseline values — never JSON-serializable. Callers that cache
        # must use baseline_to_dict(); the returned dict is converted here
        # so a direct save_data_cache() can never fail on it.
        try:
            from .schedule import baseline_to_dict

            serializable_baseline = baseline_to_dict(self.stableBaseline)
        except Exception:
            serializable_baseline = {}
        return {
            "timetable": self.timetableData,
            "absence": self.absencePercentages,
            "grades": self.grades,
            "stable_baseline": serializable_baseline,
            "stable_baseline_source": "scraped" if serializable_baseline else "",
            "changes": self.weekChanges,
            "substitutions": self.substitutions,
            "absence_details": self.absenceDetails,
            "subject_directory": self.subjectDirectory,
        }
