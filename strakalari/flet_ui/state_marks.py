"""Marks view: scale choice, sorting, subject selection and the predictor.

Mixin of :class:`strakalari.flet_ui.state.AppState` — it relies on the
state attributes and helpers defined there (``config``, ``grades``,
``save``, ``_emit`` …).

Predictions live in memory only (``marks_predictions``): they are
what-ifs for this session, never written to disk, so a hypothetical mark
can not linger next to the real one once the teacher enters it.
"""

from __future__ import annotations

from strakalari.core import grades as gr

MARKS_SORTS = ("name", "average", "recent")


class MarksMixin:
    # -- lazily created UI memory (AppState.__init__ stays untouched) -----
    @property
    def marks_predictions(self) -> dict[str, dict]:
        """{subject: {"added": [...], "edits": {key: {...}}, "removed": [...]}}"""
        store = self.__dict__.get("_marks_predictions")
        if store is None:
            store = self.__dict__["_marks_predictions"] = {}
        return store

    @property
    def marks_selected(self) -> str | None:
        return self.__dict__.get("_marks_selected")

    @property
    def marks_editing(self) -> str | None:
        """Key of the mark row being edited inline (in the selected subject)."""
        return self.__dict__.get("_marks_editing")

    # -- persisted preferences ------------------------------------------------
    def marks_scale(self) -> str:
        value = str(self.get("marks_scale", "auto") or "auto")
        return value if value in gr.SCALE_CHOICES else "auto"

    def marks_subject_scales(self) -> dict[str, str]:
        raw = self.get("marks_subject_scales", {}) or {}
        if not isinstance(raw, dict):
            return {}
        return {str(k): str(v) for k, v in raw.items() if v in gr.SCALES}

    def marks_bands(self) -> tuple[float, float, float, float]:
        return self.marks_bands_source()[0]

    def marks_bands_source(self) -> tuple[tuple[float, ...], str]:
        """(bands, "user" | "preset" | "default") — see resolve_marks_bands."""
        from strakalari.core.school_presets import resolve_marks_bands

        try:
            return resolve_marks_bands(self.config.data)
        except Exception:
            return gr.DEFAULT_BANDS, "default"

    def marks_sort(self) -> str:
        value = str(self.get("marks_sort", "name") or "name")
        return value if value in MARKS_SORTS else "name"

    def set_marks_scale(self, scale: str) -> bool:
        """Global scale; picking one clears the per-subject overrides so the
        switch visibly applies everywhere."""
        if scale not in gr.SCALE_CHOICES:
            return False
        return bool(self.save({"marks_scale": scale, "marks_subject_scales": {}}))

    def set_subject_scale(self, subject: str, scale: str) -> bool:
        """Per-subject override; ``auto`` drops it (the global choice applies)."""
        scales = self.marks_subject_scales()
        if scale in gr.SCALES:
            scales[str(subject)] = scale
        else:
            scales.pop(str(subject), None)
        return bool(self.save({"marks_subject_scales": scales}))

    def set_marks_bands(self, bands) -> bool:
        """Own bands; ``None`` drops them (back to the school preset / default)."""
        if bands is None:
            return bool(self.save({"marks_percent_bands": []}))
        if not gr.bands_valid(bands):
            return False
        return bool(self.save({"marks_percent_bands": [float(b) for b in bands]}))

    def set_marks_sort(self, sort: str) -> bool:
        if sort not in MARKS_SORTS:
            return False
        return bool(self.save({"marks_sort": sort}))

    # -- summaries --------------------------------------------------------------
    def marks_summaries(self) -> list[gr.SubjectSummary]:
        try:
            return gr.summarize_all(
                self.grades(),
                scale_pref=self.marks_scale(),
                subject_scales=self.marks_subject_scales(),
                predictions=self.marks_predictions,
                bands=self.marks_bands(),
            )
        except Exception as exc:  # noqa: BLE001 - a bad mark must not blank the tab
            print(f"Warning: marks summary failed: {exc}")
            return []

    # -- selection -----------------------------------------------------------------
    def select_marks_subject(self, subject: str | None) -> None:
        if self.marks_selected == subject:
            subject = None  # clicking the open subject again closes it
        self.__dict__["_marks_selected"] = subject
        self.__dict__["_marks_editing"] = None
        if subject is not None:
            self.tutorial_event("marks_subject_opened")
        self._emit()

    def set_marks_editing(self, key: str | None) -> None:
        self.__dict__["_marks_editing"] = key
        self._emit()

    # -- "what do I need" calculator inputs (per subject, in memory) --------------
    def marks_calc(self, subject: str) -> dict:
        """{"target": "2", "weight": "3"} as last picked for ``subject``."""
        store = self.__dict__.setdefault("_marks_calc", {})
        return store.setdefault(subject, {})

    def set_marks_calc(self, subject: str, **values) -> None:
        calc = self.marks_calc(subject)
        changed = False
        for key, value in values.items():
            value = str(value or "").strip()
            if calc.get(key) != value:
                calc[key] = value
                changed = True
        if changed:
            self._emit()

    def use_planned_weight(self, subject: str, weight: str) -> None:
        """Pre-fills the predictor's weight with an announced test's weight."""
        self.set_draft(f"marks:add:weight:{subject}", weight)
        self._emit()

    # -- predictor -------------------------------------------------------------------
    def _ops(self, subject: str) -> dict:
        store = self.marks_predictions
        ops = store.get(subject)
        if not isinstance(ops, dict):
            ops = store[subject] = gr.empty_prediction()
        return ops

    def _drop_if_empty(self, subject: str) -> None:
        if not gr.prediction_active(self.marks_predictions.get(subject)):
            self.marks_predictions.pop(subject, None)

    @staticmethod
    def _clean_mark(grade: str, weight) -> dict | None:
        text = str(grade or "").strip()
        if not gr.valid_mark_text(text):
            return None
        try:
            w = float(str(weight).replace(",", ".").strip())
        except (TypeError, ValueError):
            return None
        if not (0 < w <= 100):
            return None
        return {"Grade": text, "Weight": w}

    def predict_add(self, subject: str, grade: str, weight) -> bool:
        """Adds a hypothetical mark. False (nothing changes) when invalid."""
        mark = self._clean_mark(grade, weight)
        if mark is None:
            return False
        self._ops(subject)["added"].append(mark)
        self.tutorial_event("marks_predicted")
        self._emit()
        return True

    def predict_edit(self, subject: str, key: str, grade: str, weight) -> bool:
        """Changes a real or hypothetical mark in the prediction."""
        mark = self._clean_mark(grade, weight)
        if mark is None:
            return False
        ops = self._ops(subject)
        if key.startswith("add:"):
            try:
                ops["added"][int(key[4:])] = mark
            except (ValueError, IndexError):
                return False
        elif self._same_as_real(subject, key, mark):
            ops["edits"].pop(key, None)  # saved back unchanged: not an edit
        else:
            ops["edits"][key] = mark
        self.__dict__["_marks_editing"] = None
        self._drop_if_empty(subject)
        self.tutorial_event("marks_predicted")
        self._emit()
        return True

    def _same_as_real(self, subject: str, key: str, mark: dict) -> bool:
        real = [m for m in (self.grades().get(subject) or [])
                if isinstance(m, dict) and not gr.is_planned(m)]
        for k, original in zip(gr.mark_keys(real), real, strict=True):
            if k == key:
                return (str(original.get("Grade", "")).strip() == mark["Grade"]
                        and gr.parse_weight(original.get("Weight")) == mark["Weight"])
        return False

    def predict_remove(self, subject: str, key: str) -> None:
        """Deletes a hypothetical mark, or leaves a real one out of the prediction."""
        ops = self._ops(subject)
        if key.startswith("add:"):
            try:
                del ops["added"][int(key[4:])]
            except (ValueError, IndexError):
                pass
        else:
            ops["edits"].pop(key, None)
            if key not in ops["removed"]:
                ops["removed"].append(key)
        if self.marks_editing == key or str(self.marks_editing or "").startswith("add:"):
            # Hypothetical keys are positional: any open editor may now
            # point at a different mark.
            self.__dict__["_marks_editing"] = None
        self._drop_if_empty(subject)
        self.tutorial_event("marks_predicted")
        self._emit()

    def predict_restore(self, subject: str, key: str) -> None:
        """Brings a real mark back to its real value (undoes edit / removal)."""
        ops = self._ops(subject)
        ops["edits"].pop(key, None)
        ops["removed"] = [k for k in ops["removed"] if k != key]
        self._drop_if_empty(subject)
        self._emit()

    def predict_reset(self, subject: str | None = None) -> None:
        if subject is None:
            self.marks_predictions.clear()
        else:
            self.marks_predictions.pop(subject, None)
        self.__dict__["_marks_editing"] = None
        self._emit()
