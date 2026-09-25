"""Bakaláři data fetching: marks, absence, sent excuses, subjects, substitutions, stable baseline."""

import re

from .extractors.bakalari import (
    extract_absence_details,
    extract_absence_percentages,
    extract_grades,
    extract_sent_excuses,
    parse_subject_directory,
)


class DataMixin:
    """Mixin of :class:`~.bakalari_client.BakalariClient`; uses its session state."""

    def _dismiss_cookies(self) -> bool:
        """Dismisses the Bakalari cookies banner (``#c-p-bn``).

        The banner overlays the page until accepted and would otherwise
        intercept module clicks. Fast no-op when absent (a count /
        visibility probe, no long waits). Returns True when no banner
        blocks the page. Never raises.
        """
        if self.page is None:
            return True
        try:
            btn = self.page.locator("#c-p-bn").first
        except Exception:
            return True
        try:
            if btn.count() == 0:
                return True
            if not btn.is_visible():
                return True
        except Exception:
            return True
        try:
            try:
                btn.click(timeout=3000)
            except Exception:
                btn.evaluate("el => el.click()")
        except Exception:
            return False
        try:
            btn.wait_for(state="detached", timeout=3000)
            return True
        except Exception:
            pass
        try:
            return not btn.is_visible()
        except Exception:
            return True

    def get_grades(self):
        """Fetches průběžná klasifikace (Klasifikace → Průběžná).

        Opens the grades module, parses the ``data-clasif`` marks and
        stores them on ``self.grades`` grouped per subject, each list
        sorted by date (oldest first). Returns the dict. Best-effort:
        failures only log + set ``grades_error`` (mirroring absence
        handling) so one changed page never breaks the whole Bakalari
        run. Only raises on user cancel.
        """
        if self._cancelled():
            raise InterruptedError("Cancelled by user.")
        if self.page is None:
            self.log("Grades sync skipped: no browser attached.")
            self.grades_error = "no browser attached"
            return {}
        try:
            self._open_module(".ico32-modul-klasifikace", ".ico32-modul-klasifikacePrubezna")

            # The grid refreshes via AJAX: wait for the marks themselves.
            settle_ms = self._settle_ms()
            _marks_loaded = False
            try:
                self.page.wait_for_function(
                    "() => document.body && document.body.innerHTML.includes('data-clasif')",
                    timeout=settle_ms,
                )
                _marks_loaded = True
            except Exception:
                pass
            self._sleep_s(0.5)

            grades = extract_grades(self.page.content())
            self.grades = grades
            if grades:
                self.grades_error = ""
                n_marks = sum(len(v) for v in grades.values())
                self.log(f"Grades synced: {n_marks} marks in {len(grades)} subjects.")
            else:
                self.log("Warning: no grades parsed — "
                         "either no marks recorded or the page markup changed.")
                # An empty parse with the marks grid never loaded means the
                # page didn't render (login page / failed load) — flag it so
                # refresh paths keep the last good cache instead of wiping it.
                self.grades_error = "" if _marks_loaded else "marks grid did not load (empty parse)"
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
        if self._cancelled():
            raise InterruptedError("Cancelled by user.")
        # A standalone call on an expired session would burn the full
        # element budgets and then scrape the login page as an empty
        # absence table — login first (fast path no-ops when valid).
        self.login()
        try:
            # More robust wait
            omluvenky_loc = self.page.locator(".ico32-modul-omluvenky").first
            try:
                self._wait_for_module(".ico32-modul-omluvenky")
                omluvenky_loc.click(timeout=self._nav_ms, once=True)
            except InterruptedError:
                raise
            except Exception:
                vyuka_loc = self.page.locator(".ico32-modul-vyuka").first
                self._wait_for_module(".ico32-modul-vyuka")
                vyuka_loc.click(timeout=self._nav_ms, once=True)
                self._wait_for_module(".ico32-modul-omluvenky")
                omluvenky_loc.click(timeout=self._nav_ms, once=True)

            # The absence grid is an AJAX refresh: wait on its content
            # (never networkidle — the SPA's background traffic never idles).
            settle_ms = self._settle_ms()
            _grid_loaded = False
            if settle_ms > 0:
                try:
                    self.page.wait_for_function(
                        "() => document.body && document.body.innerHTML.includes('aria-colindex')",
                        timeout=settle_ms,
                    )
                    _grid_loaded = True
                except InterruptedError:
                    raise
                except Exception:
                    pass
            self._sleep_s(0.2)
            content = self.page.content()
            self.absencePercentages = extract_absence_percentages(content)
            try:
                self.absenceDetails = extract_absence_details(content)
            except Exception as e:
                self.log(f"Warning: absence details parse failed ({type(e).__name__}: {e}) — falling back to percentage estimates.")
                self.absenceDetails = {}
            self.absence_error = ""
            if not self.absencePercentages:
                self.log("Warning: no absence percentages parsed — "
                         "either no absence recorded or the page markup changed.")
                # Grid never loaded + empty parse = failed load, not "no
                # absence": flag it so refresh paths keep the last good
                # cache instead of wiping it with {}.
                if not _grid_loaded:
                    self.absence_error = "absence grid did not load (empty parse)"

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

    def fetch_sent_excuses(self, limit: int = 100) -> list | None:
        """Scrapes already-sent excuses (Komens → Odeslané → OMLUVENKA).

        Opens each ``[data-msgtype=\"OMLUVENKA\"]`` row, parses its detail
        header (Od/Do dates + optional lesson hours) and stores the result
        on ``self.sentExcuses``. Returns the parsed history-shaped entries.

        Tri-state: a list (possibly empty) = the outbox was actually read
        (empty genuinely means "nothing sent"); None = the sync failed or
        was skipped, i.e. unknown — callers must treat it as "nothing
        learned", never as "nothing sent". Never raises except on user
        cancel. ``self.sentExcuses_error`` carries the last failure.
        """
        if self._cancelled():
            raise InterruptedError("Cancelled by user.")
        if self.page is None:
            self.log("Sent-excuse sync skipped: no browser attached.")
            self.sentExcuses_error = "no browser attached"
            return None
        try:
            limit = max(1, int(limit))
        except (TypeError, ValueError):
            limit = 100
        try:
            self._open_module(".ico32-modul-vyuka", ".ico32-modul-komens",
                              ".ico32-modul-komensOdeslane")
            # Wait on the outbox rows themselves (never on menu words like
            # 'Odeslan': the side menu contains them, so such a wait would
            # succeed while the list is still loading and read as empty).
            rows = self.page.locator('[data-msgtype="OMLUVENKA"]')
            try:
                rows.first.wait_for(
                    state="attached",
                    timeout=self._settle_ms(),
                )
            except Exception:
                pass
            self._sleep_s(0.2)

            try:
                total = rows.count()
            except Exception:
                total = 0
            self.sentExcuses_from = self._outbox_period_start()
            if not total:
                # Slow link: the list may simply not have arrived yet.
                # Wait out the same page once more and recount — never
                # refresh, and never report a still-loading outbox as
                # empty without a second settled check.
                try:
                    self._wait_for_page_settled(self._settle_ms())
                except InterruptedError:
                    raise
                except Exception:
                    pass
                try:
                    rows.first.wait_for(
                        state="attached",
                        timeout=self._settle_ms(),
                    )
                except Exception:
                    pass
                try:
                    total = rows.count()
                except Exception:
                    total = 0
            if not total:
                self.log("No sent excuses (OMLUVENKA) found in Komens → Odeslané.")
                self.sentExcuses = []
                return []
            if total > limit:
                self.log(f"Sent excuses: {total} on the web, reading first {limit}.")
            else:
                self.log(f"Komens → Odeslané: {total} message(s) on the web.")

            sources = []
            for idx in range(min(total, limit)):
                if self._cancelled():
                    raise InterruptedError("Cancelled by user.")
                try:
                    row = rows.nth(idx)
                    msg_id = row.get_attribute("data-idmsg")
                    if not msg_id:
                        self.log(f"Warning: sent excuse #{idx + 1} has no message id, skipped.")
                        continue
                    # Single attempt: opening the detail IS a navigation —
                    # retrying a dispatched-but-slow click would reopen the
                    # same message again (visible refresh loop on one row).
                    row.click(timeout=self._nav_ms, once=True)
                    # Wait for THIS message's detail: the page always holds
                    # the detail template (same testids), and the previous
                    # message stays rendered until the AJAX reply lands —
                    # a generic wait would read a stale or empty detail.
                    self.page.locator(
                        f'#message_detail #komens_bar_message[data-idmsg="{msg_id}"]'
                    ).first.wait_for(state="attached", timeout=self._nav_ms)
                    self._sleep_s(0.2)
                    sources.append(str(
                        self.page.locator("#message_detail").first.inner_html()))
                except InterruptedError:
                    raise
                except Exception as e:
                    self.log(f"Warning: could not open sent excuse #{idx + 1}: {e}")
                    continue

            parsed = extract_sent_excuses(sources)
            self.sentExcuses = parsed
            self.sentExcuses_error = ""
            if sources and not parsed:
                # Fully unparseable outbox: [] must not read as "nothing
                # sent" — flag it and report unknown (None), so callers
                # keep the last known state.
                self.sentExcuses = None
                self.sentExcuses_error = "outbox parse failed (unparseable content)"
                self.log("Warning: sent-excuse outbox unparseable — keeping last known state.")
                return None
            n_messages = len(sources)
            if len(parsed) != n_messages:
                # One hour-based web message expands to three history
                # entries (income + soon + days and hours) for dedupe —
                # report the web message count so the log never claims more
                # sent messages than the outbox actually holds.
                self.log(
                    f"Sent excuses synced from the web: {n_messages} message(s) "
                    f"({len(parsed)} history entries)."
                )
            else:
                self.log(f"Sent excuses synced from the web: {n_messages} message(s).")
            return parsed
        except InterruptedError:
            raise
        except Exception as e:
            self.sentExcuses_error = f"{type(e).__name__}: {e}".splitlines()[0][:200]
            self.log(f"Could not sync sent excuses: {e} — will retry next time.")
            return None

    def _outbox_period_start(self):
        """First day of the period Odeslané lists ("26.8.2026 - 25.9.2026"), or None."""
        from .models import parse_cz_date

        try:
            label = str(self.page.locator("#cphmain_obdobiLabel").first.inner_text(
                timeout=self._element_ms))
        except InterruptedError:
            raise
        except Exception:
            return None
        found = re.findall(r"\d{1,2}\s*\.\s*\d{1,2}\s*\.\s*\d{4}", label)
        if not found:
            return None
        try:
            start = parse_cz_date(re.sub(r"\s+", "", found[0]))
        except Exception:
            return None
        if start is not None:
            self.log(f"Komens → Odeslané lists {label.strip()}.")
        return start

    def fetch_subject_directory(self) -> dict:
        """Fetches the school-official subject directory.

        Opens Vyuka → Prehled predmetu and parses the subject → teacher
        table. Only the subject names are used downstream (the canonical
        absence-tracked set); teachers ride along for display. Returns
        the dict (possibly empty). Best-effort: failures only log,
        mirroring the grades handling. Only raises on
        user cancel.
        """
        if self._cancelled():
            raise InterruptedError("Cancelled by user.")
        if self.page is None:
            self.log("Subject directory skipped: no browser attached.")
            return {}
        try:
            self._open_module(".ico32-modul-vyuka", ".ico32-modul-predmetyPrehled")
            settle_ms = self._settle_ms()
            if settle_ms > 0:
                try:
                    self.page.wait_for_function(
                        "() => document.body && document.body.innerHTML.includes('<td')",
                        timeout=settle_ms,
                    )
                except Exception:
                    pass
            self._sleep_s(0.2)
            directory = parse_subject_directory(self.page.content())
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
            # good cache instead of treating old rows as freshly scraped.
            self.subjectDirectory = {}
            return {}

    def fetch_substitutions(self) -> list | None:
        """Scrapes the personal substitution feed (Vyuka → Suplovani).

        Returns the parsed feed entries (possibly empty = genuinely no
        changes this week) or None when the sync failed or was skipped
        (unknown — callers must not treat it as no changes). Only raises
        on user cancel. Best-effort: failures only log + set
        substitutions_error, mirroring the grades handling.
        """
        from .extractors.bakalari import parse_substitutions

        if self._cancelled():
            raise InterruptedError("Cancelled by user.")
        if self.page is None:
            self.log("Substitution feed skipped: no browser attached.")
            self.substitutions_error = "no browser attached"
            return None
        try:
            self._open_module(".ico32-modul-vyuka", ".ico32-modul-suplovani")
            settle_ms = self._settle_ms()
            if settle_ms > 0:
                try:
                    self.page.wait_for_function(
                        "() => document.body && ("
                        "document.body.innerHTML.includes('substitutions-entry')"
                        " || document.body.innerHTML.includes('substitutions-no-substitution')"
                        ")",
                        timeout=settle_ms,
                    )
                except Exception:
                    pass
            self._sleep_s(0.2)
            html = str(self.page.content())
            if ("substitutions-entry" not in html
                    and "substitutions-no-substitution" not in html):
                self.log("Warning: substitution feed did not load — will retry next time.")
                self.substitutions_error = "feed did not load"
                return None
            entries = parse_substitutions(html)
            if not entries and "substitutions-no-substitution" not in html:
                # No rows and no empty-state marker: the feed content
                # itself never rendered (still loading or markup moved) —
                # unknown, not "no changes".
                self.log("Warning: substitution feed content missing — will retry next time.")
                self.substitutions_error = "feed content missing"
                return None
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
        # Full overview rows from the same page: elapsed hours + school
        # verdict badges per subject (see extract_absence_details).
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

        if self._cancelled():
            raise InterruptedError("Cancelled by user.")
        self.login()
        self.extract_timetable_html()
        for timetable in self.timetable_sources:
            self.extract_timetable_data(timetable)
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
