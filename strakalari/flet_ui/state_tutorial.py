"""AppState mixin: interactive tutorial progress (which tour, which step).

The tours themselves live in :mod:`strakalari.flet_ui.tutorial`. This
mixin only tracks progress: the active ``(tour id, step)`` in memory and
the finished/skipped tour ids in config (``tutorials_done``), plus the
global ``tutorials_enabled`` switch.

Every method is ``getattr``-safe: test doubles that bypass ``__init__``
(and every state action that fires :meth:`tutorial_event`) must keep
working without tutorial bookkeeping.
"""

from __future__ import annotations


class TutorialMixin:
    # -- config ------------------------------------------------------------
    def tutorials_enabled(self) -> bool:
        try:
            return bool(self.get("tutorials_enabled", True))
        except Exception:
            return True

    def tutorials_done(self) -> set[str]:
        done: set[str] = set(getattr(self, "_tutorials_done_session", set()) or set())
        try:
            stored = self.get("tutorials_done", [])
            if isinstance(stored, list):
                done.update(str(t) for t in stored if str(t or "").strip())
        except Exception:
            pass
        return done

    def _remember_tutorial_done(self, tour_id: str, quiet: bool) -> None:
        """Marks a tour finished/skipped for good (this session even when
        the config write fails, so a failed save never loops the tour)."""
        session = getattr(self, "_tutorials_done_session", None)
        if not isinstance(session, set):
            session = self._tutorials_done_session = set()
        session.add(tour_id)
        stored = self.tutorials_done() | {tour_id}
        update = {"tutorials_done": sorted(stored)}
        try:
            if quiet:
                self.save_quiet(update)
            else:
                self.save(update)
        except Exception as exc:  # noqa: BLE001 - progress only, never fatal
            print(f"Warning: could not save tutorial progress: {exc}")

    def set_tutorials_enabled(self, enabled: bool) -> bool:
        if not enabled:
            self.tutorial = None
        return bool(self.save({"tutorials_enabled": bool(enabled)}))

    def reset_tutorials(self) -> bool:
        """Replays every tour (each shows again when its moment comes)."""
        self._tutorials_done_session = set()
        self.tutorial = None
        return bool(self.save({"tutorials_done": [], "tutorials_enabled": True}))

    # -- progress ------------------------------------------------------------
    def tutorial_current(self):
        """``(tour, index, step)`` of the active tour, or None."""
        active = getattr(self, "tutorial", None)
        if not active:
            return None
        from .tutorial import TOURS

        tour = TOURS.get(active[0])
        if tour is None or not (0 <= active[1] < len(tour.steps)):
            self.tutorial = None
            return None
        return tour, active[1], tour.steps[active[1]]

    def tutorial_offer(self, tour_id: str) -> bool:
        """Starts ``tour_id`` when nothing else runs and it was never done.

        Views call it while rendering (the moment the tour's content is on
        screen), so it never emits. Returns True when that tour is active.
        """
        active = getattr(self, "tutorial", None)
        if active:
            return active[0] == tour_id
        if not self.tutorials_enabled():
            return False
        done = self.tutorials_done()
        from .tutorial import FIRST_TOUR, TOURS

        if tour_id in done or tour_id not in TOURS:
            return False
        if tour_id != FIRST_TOUR and FIRST_TOUR not in done:
            return False  # the welcome tour always comes first
        self.tutorial = (tour_id, 0)
        return True

    def tutorial_suspend(self) -> None:
        """Drops the active tour WITHOUT marking it done (it is offered
        again, from its first step, the next time its moment comes)."""
        self.tutorial = None

    def _tutorial_goto(self, index: int, quiet: bool = False) -> None:
        current = self.tutorial_current()
        if current is None:
            return
        tour = current[0]
        if index >= len(tour.steps):
            self.tutorial = None
            self._remember_tutorial_done(tour.id, quiet=quiet)
            return
        self.tutorial = (tour.id, max(0, index))
        if not quiet:
            self._emit()

    def tutorial_next(self) -> None:
        current = self.tutorial_current()
        if current is not None:
            self._tutorial_goto(current[1] + 1)

    def tutorial_back(self) -> None:
        current = self.tutorial_current()
        if current is not None and current[1] > 0:
            self._tutorial_goto(current[1] - 1)

    def tutorial_skip(self) -> None:
        """Ends the active tour for good ("Skip tutorial")."""
        current = self.tutorial_current()
        if current is None:
            return
        self.tutorial = None
        self._remember_tutorial_done(current[0].id, quiet=False)

    def tutorial_event(self, name: str) -> None:
        """The user just did ``name`` (e.g. sent an excuse).

        Advances the active tour past the first remaining step waiting
        for it. Never emits: the state action firing it repaints anyway.
        """
        try:
            current = self.tutorial_current()
        except Exception:
            return
        if current is None:
            return
        tour, index, _step = current
        for later in range(index, len(tour.steps)):
            if tour.steps[later].until == name:
                self._tutorial_goto(later + 1, quiet=True)
                return
