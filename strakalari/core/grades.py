"""Marks (průběžná klasifikace) maths: parsing, scales, averages, predictions.

Pure logic, no UI. Two scales exist in Bakaláři:

* ``grade`` — the Czech 1–5 scale (1 best). ``"1-"`` sits halfway to the
  next grade (1.5), a trailing ``"+"`` keeps the base grade.
* ``percent`` — 0–100 %, written ``"85 %"``, as points (``"17/20"``) or,
  in many schools, as a bare number (``"85"``).

Every mark is read in its own right first: ``"2-"`` is always a grade,
``"85"`` / ``"85 %"`` / ``"17/20"`` are always percent. Only a bare
``1``–``5`` is ambiguous; it follows the subject's scale. A subject's
scale is detected from its unambiguous marks (falling back to the whole
school's marks) and can be forced by the user. Marks written in the
other scale are converted through the percent bands so they still count.

Predictions never touch the real marks: they are a small set of
operations (added / edited / removed marks) applied on top, so a
refresh that brings new real marks keeps the user's what-ifs intact.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date, timedelta
from itertools import pairwise
from typing import Iterable

from .models import parse_cz_date

SCALES = ("grade", "percent")
SCALE_CHOICES = ("auto",) + SCALES

#: Grade boundaries as Bakaláři's "Tabulka převodu" lists them: the top of
#: grades 2, 3, 4 and 5. A boundary value already belongs to the worse
#: grade (87 % is the first 2 when the 2 starts at 87). Schools override
#: it through their preset or ``marks_percent_bands``.
DEFAULT_BANDS: tuple[float, float, float, float] = (90.0, 75.0, 50.0, 30.0)

#: Grade steps a real mark can take (``1``, ``1-``, ``2`` … ``5``).
GRADE_STEPS = (1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0)

_GRADE_RE = re.compile(r"^([1-5])\s*([+\-−–])$")
_PERCENT_RE = re.compile(r"^(\d+(?:[.,]\d+)?)\s*%$")
_POINTS_RE = re.compile(r"^(\d+(?:[.,]\d+)?)\s*/\s*(\d+(?:[.,]\d+)?)$")
_NUMBER_RE = re.compile(r"^\d+(?:[.,]\d+)?$")


# -- parsing -----------------------------------------------------------------
@dataclass(frozen=True)
class RawMark:
    """A mark read on its own: ``kind`` is grade, percent or small (1–5)."""

    kind: str
    value: float


def _num(text: str) -> float:
    return float(str(text).replace(",", "."))


def parse_raw(text, points=None) -> RawMark | None:
    """Reads one mark without context. None for non-counting marks.

    ``"2-"`` -> grade 2.5, ``"85 %"`` / ``"85"`` / ``"17/20"`` -> percent,
    bare ``"1"``–``"5"`` -> small (scale decides). ``N``, ``X``, ``?``,
    ``A`` and empty text do not count. ``points`` (Bakaláři PointsText)
    is used when the mark text itself is not a number.
    """
    raw = str(text if text is not None else "").strip()
    m = _GRADE_RE.match(raw)
    if m:
        base = float(m.group(1))
        return RawMark("grade", min(5.0, base + 0.5) if m.group(2) != "+" else base)
    m = _PERCENT_RE.match(raw)
    if m:
        return RawMark("percent", _clamp_pct(_num(m.group(1))))
    m = _POINTS_RE.match(raw)
    if m:
        got, top = _num(m.group(1)), _num(m.group(2))
        if top > 0:
            return RawMark("percent", _clamp_pct(got / top * 100.0))
        return None
    if _NUMBER_RE.match(raw):
        value = _num(raw)
        if 1.0 <= value <= 5.0:
            return RawMark("small", value)
        return RawMark("percent", _clamp_pct(value))
    if points not in (None, "") and raw != str(points).strip():
        found = parse_raw(points)
        if found is not None and found.kind == "percent":
            return found
    return None


def _clamp_pct(value: float) -> float:
    return max(0.0, min(100.0, float(value)))


def parse_weight(value) -> float:
    """Mark weight; missing or invalid -> 1, zero stays zero (not counted)."""
    try:
        w = float(str(value).replace(",", ".").strip())
    except (TypeError, ValueError):
        return 1.0
    if w != w or w < 0:  # NaN / negative
        return 1.0
    return w


def is_planned(mark: dict) -> bool:
    """True for an announced-but-not-yet-given mark (``?`` in Bakaláři)."""
    mark = mark or {}
    if mark.get("Planned"):
        return True
    return str(mark.get("Grade", "")).strip() == "?"


# -- scale conversion ----------------------------------------------------------
def bands_valid(bands) -> bool:
    """True for four strictly decreasing boundaries within (0, 100]."""
    if isinstance(bands, (str, bytes)) or not isinstance(bands, (list, tuple)):
        return False
    try:
        vals = [float(b) for b in bands]
    except (TypeError, ValueError):
        return False
    return (len(vals) == 4 and all(0 < v <= 100 for v in vals)
            and all(a > b for a, b in pairwise(vals)))


def normalize_bands(bands) -> tuple[float, float, float, float]:
    """The bands as floats when valid, else :data:`DEFAULT_BANDS`."""
    if not bands_valid(bands):
        return DEFAULT_BANDS
    return tuple(float(b) for b in bands)  # type: ignore[return-value]


def pct_to_grade(pct: float, bands=DEFAULT_BANDS) -> int:
    """Final grade (1–5) a percentage earns; a boundary is the worse grade's top."""
    for grade, bound in enumerate(bands, start=1):
        if pct > bound + 1e-9:
            return grade
    return 5


def grade_to_pct(grade: float, bands=DEFAULT_BANDS) -> float:
    """Percent equivalent of a grade: the middle of its band, interpolated
    for in-between values (``1-`` = 1.5 lands between the 1 and 2 middles)."""
    tops = (100.0,) + tuple(bands)
    mids = [(tops[i] + tops[i + 1]) / 2 for i in range(4)] + [tops[4] / 2]
    g = max(1.0, min(5.0, float(grade)))
    lo = int(g)
    if lo >= 5:
        return mids[4]
    frac = g - lo
    return mids[lo - 1] + (mids[lo] - mids[lo - 1]) * frac


def round_grade(avg: float) -> int:
    """Czech report-card rounding: halves go down a grade (1.5 -> 2)."""
    return max(1, min(5, int(avg + 0.5 + 1e-9)))


def final_grade(avg: float | None, scale: str, bands=DEFAULT_BANDS) -> int | None:
    if avg is None:
        return None
    return pct_to_grade(avg, bands) if scale == "percent" else round_grade(avg)


def grade_equivalent(value: float | None, scale: str, bands=DEFAULT_BANDS) -> float | None:
    """A value on the 1–5 axis (continuous for grades, stepped for percent)."""
    if value is None:
        return None
    return float(pct_to_grade(value, bands)) if scale == "percent" else float(value)


def kind_for(value: float | None, scale: str, bands=DEFAULT_BANDS) -> str:
    """Badge colour: ok (1–2), warning (3), critical (4–5), info (none)."""
    g = grade_equivalent(value, scale, bands)
    if g is None:
        return "info"
    if g <= 2:
        return "ok"
    if g <= 3:
        return "warning"
    return "critical"


def format_value(value: float | None, scale: str, digits: int | None = None) -> str:
    """``1.83`` for grade averages, ``84.5 %`` for percent; ``—`` for None."""
    if value is None:
        return "—"
    if scale == "percent":
        d = 1 if digits is None else digits
        text = f"{value:.{d}f}".rstrip("0").rstrip(".") if d else f"{value:.0f}"
        return f"{text} %"
    return f"{value:.{2 if digits is None else digits}f}"


def format_grade_step(value: float) -> str:
    """``1.5`` -> ``1-``, ``2.0`` -> ``2``."""
    base = int(value)
    return f"{base}-" if value - base >= 0.25 else str(base)


def resolve(raw: RawMark | None, scale: str, subject_has_pct: bool,
            bands=DEFAULT_BANDS) -> float | None:
    """A mark's value on ``scale`` (converting from the other scale).

    A bare 1–5 follows the subject scale, except on a percent subject
    with no real percentage at all (a forced switch on a 1–5 subject):
    reading "2" as 2 % would be absurd there, so it converts instead.
    """
    if raw is None:
        return None
    kind = raw.kind
    if kind == "small":
        kind = "percent" if (scale == "percent" and subject_has_pct) else "grade"
    if kind == scale:
        return raw.value
    if scale == "percent":
        return grade_to_pct(raw.value, bands)
    return float(pct_to_grade(raw.value, bands))


def detect_scale(marks: Iterable[dict], fallback: str = "grade") -> str:
    """``percent`` when unambiguous percentages outnumber the grade-like
    marks; ``fallback`` when a subject has nothing but ``?`` / ``N`` marks."""
    pct = grade = 0
    for mark in marks or []:
        if not isinstance(mark, dict) or is_planned(mark):
            continue
        raw = parse_raw(mark.get("Grade"), mark.get("Points"))
        if raw is None:
            continue
        if raw.kind == "percent":
            pct += 1
        else:
            grade += 1
    if pct == 0 and grade == 0:
        return fallback if fallback in SCALES else "grade"
    return "percent" if pct >= grade and pct > 0 else "grade"


def detect_school_scale(grades: dict) -> str:
    """Scale of the whole marks page (the prior for subjects without evidence)."""
    everything = [m for ms in (grades or {}).values() for m in (ms or [])]
    return detect_scale(everything, "grade")


# -- averages -------------------------------------------------------------------
def weighted_average(pairs: Iterable[tuple[float | None, float]]) -> float | None:
    total = weight = 0.0
    for value, w in pairs:
        if value is None or w <= 0:
            continue
        total += value * w
        weight += w
    return total / weight if weight > 0 else None


# -- predictions ------------------------------------------------------------------
def mark_keys(marks: list) -> list[str]:
    """Stable identity per real mark: the Bakaláři id, else its content plus
    an occurrence counter (two identical marks on one day stay distinct)."""
    seen: dict[str, int] = {}
    keys: list[str] = []
    for mark in marks or []:
        mark = mark if isinstance(mark, dict) else {}
        ident = str(mark.get("Id") or "").strip()
        if ident:
            base = f"id:{ident}"
        else:
            base = "|".join(str(mark.get(k, "")) for k in ("Date", "Grade", "Weight", "Caption"))
        n = seen.get(base, 0)
        seen[base] = n + 1
        keys.append(f"{base}#{n}" if n else base)
    return keys


def empty_prediction() -> dict:
    return {"added": [], "edits": {}, "removed": []}


def prediction_active(ops: dict | None) -> bool:
    ops = ops or {}
    return bool(ops.get("added") or ops.get("edits") or ops.get("removed"))


@dataclass
class MarkRow:
    """One mark as the view shows it (real, edited, removed or hypothetical)."""

    key: str
    mark: dict
    state: str               # real | edited | removed | added
    value: float | None      # on the subject scale; None = does not count
    weight: float
    raw: RawMark | None
    original: dict | None = None  # the real mark behind an edit
    date: date | None = None

    @property
    def text(self) -> str:
        return str(self.mark.get("Grade", "?"))

    @property
    def counts(self) -> bool:
        return self.state != "removed" and self.value is not None and self.weight > 0


@dataclass
class SubjectSummary:
    name: str
    scale: str
    detected: str
    forced: bool
    rows: list[MarkRow]                 # chronological, oldest first
    planned: list[dict]
    average: float | None               # real marks only
    predicted: float | None             # with the prediction applied
    predicting: bool
    trend: float | None                 # real avg change caused by the newest mark
    new_count: int
    last_date: date | None
    history: list[tuple[date | None, float]] = field(default_factory=list)

    @property
    def current(self) -> float | None:
        """The average the UI leads with: predicted while predicting."""
        return self.predicted if self.predicting else self.average

    @property
    def real_count(self) -> int:
        return sum(1 for r in self.rows if r.state != "added" and r.value is not None)


def _entry(mark: dict) -> dict:
    return mark if isinstance(mark, dict) else {}


def summarize(name: str, marks: list, *, scale_pref: str = "auto",
              fallback: str = "grade", ops: dict | None = None,
              bands=DEFAULT_BANDS, today: date | None = None,
              new_days: int = 7) -> SubjectSummary:
    """Everything the marks view needs about one subject."""
    today = today or date.today()
    bands = normalize_bands(bands)
    real = [_entry(m) for m in (marks or []) if isinstance(m, dict)]
    planned = [m for m in real if is_planned(m)]
    given = [m for m in real if not is_planned(m)]
    detected = detect_scale(given, fallback)
    forced = scale_pref in SCALES
    scale = scale_pref if forced else detected

    ops = ops or {}
    edits = ops.get("edits") or {}
    removed = set(ops.get("removed") or [])
    added = list(ops.get("added") or [])

    def _raw(m: dict) -> RawMark | None:
        return parse_raw(m.get("Grade"), m.get("Points"))

    # Every candidate mark (real, edits, hypotheticals) decides whether
    # a bare 1–5 may be a percentage on this subject.
    candidates = given + [e for e in edits.values() if isinstance(e, dict)] + added
    has_pct = any((r := _raw(m)) is not None and r.kind == "percent" for m in candidates)

    def _value(m: dict) -> tuple[RawMark | None, float | None]:
        raw = _raw(m)
        return raw, resolve(raw, scale, has_pct, bands)

    rows: list[MarkRow] = []
    keys = mark_keys(given)
    for key, mark in zip(keys, given, strict=True):
        day = parse_cz_date(mark.get("Date"))
        if key in removed:
            raw, value = _value(mark)
            rows.append(MarkRow(key, mark, "removed", value, parse_weight(mark.get("Weight")),
                                raw, date=day))
            continue
        edit = edits.get(key)
        if isinstance(edit, dict):
            shown = dict(mark)
            shown["Grade"] = edit.get("Grade", mark.get("Grade"))
            shown["Weight"] = edit.get("Weight", mark.get("Weight"))
            shown.pop("Points", None)
            raw, value = _value(shown)
            rows.append(MarkRow(key, shown, "edited", value, parse_weight(shown.get("Weight")),
                                raw, original=mark, date=day))
            continue
        raw, value = _value(mark)
        rows.append(MarkRow(key, mark, "real", value, parse_weight(mark.get("Weight")),
                            raw, date=day))
    rows.sort(key=lambda r: (r.date or date.min))
    for i, mark in enumerate(added):
        mark = _entry(mark)
        raw, value = _value(mark)
        rows.append(MarkRow(f"add:{i}", mark, "added", value,
                            parse_weight(mark.get("Weight")), raw, date=None))

    real_rows = [r for r in rows if r.state in ("real", "edited", "removed")]
    real_pairs = []
    for r in real_rows:
        source = r.original if r.state == "edited" else r.mark
        raw = _raw(source)
        real_pairs.append((resolve(raw, scale, has_pct, bands), parse_weight(source.get("Weight"))))
    average = weighted_average(real_pairs)
    predicting = prediction_active(ops)
    predicted = weighted_average((r.value, r.weight) for r in rows if r.counts) if predicting else None

    # Running average over the real marks (chronological) — the trend line.
    history: list[tuple[date | None, float]] = []
    total = weight = 0.0
    for r, (value, w) in zip(real_rows, real_pairs, strict=True):
        if value is None or w <= 0:
            continue
        total += value * w
        weight += w
        history.append((r.date, total / weight))
    trend = history[-1][1] - history[-2][1] if len(history) >= 2 else None

    cutoff = today - timedelta(days=new_days)
    new_count = sum(
        1 for m in given
        if m.get("New") or ((d := parse_cz_date(m.get("Date"))) is not None and d >= cutoff)
    )
    dates = [r.date for r in real_rows if r.date is not None]
    return SubjectSummary(
        name=name, scale=scale, detected=detected, forced=forced, rows=rows,
        planned=planned, average=average, predicted=predicted,
        predicting=predicting, trend=trend, new_count=new_count,
        last_date=max(dates) if dates else None, history=history,
    )


def summarize_all(grades: dict, *, scale_pref: str = "auto",
                  subject_scales: dict | None = None,
                  predictions: dict | None = None, bands=DEFAULT_BANDS,
                  today: date | None = None) -> list[SubjectSummary]:
    """One summary per subject; a per-subject choice beats the global one."""
    subject_scales = subject_scales or {}
    predictions = predictions or {}
    school = detect_school_scale(grades)
    out = []
    for name in sorted(grades or {}, key=lambda s: str(s).casefold()):
        pref = subject_scales.get(name)
        if pref not in SCALES:
            pref = scale_pref if scale_pref in SCALES else "auto"
        out.append(summarize(name, grades.get(name) or [], scale_pref=pref,
                             fallback=school, ops=predictions.get(name),
                             bands=bands, today=today))
    return out


def valid_mark_text(text: str) -> bool:
    """True when ``text`` is a mark the predictor can count.

    Stricter than :func:`parse_raw` (which clamps odd page data): a typed
    percentage above 100 or points above the maximum are refused.
    """
    raw = str(text or "").strip()
    if parse_raw(raw) is None:
        return False
    m = _POINTS_RE.match(raw)
    if m:
        return _num(m.group(1)) <= _num(m.group(2))
    m = _PERCENT_RE.match(raw)
    if m:
        return _num(m.group(1)) <= 100
    if _NUMBER_RE.match(raw):
        return _num(raw) <= 100
    return True


def default_weight(summary: SubjectSummary) -> float:
    """The subject's most common real weight (ties -> the higher one)."""
    counts: dict[float, int] = {}
    for r in summary.rows:
        if r.state in ("real", "edited"):
            counts[r.weight] = counts.get(r.weight, 0) + 1
    if not counts:
        return 1.0
    return max(counts, key=lambda w: (counts[w], w))


def format_weight(weight: float) -> str:
    return f"{weight:g}"


# -- "what do I need" ----------------------------------------------------------------
@dataclass(frozen=True)
class Needed:
    """What the next mark must be to finish with ``target``.

    ``status``: ``any`` (even the worst mark keeps the target), ``need``
    (``value`` is the worst acceptable mark), ``impossible`` (not with one
    mark — ``count`` best marks of that weight would do, 0 = unreachable).
    """

    status: str
    value: float | None = None
    count: int = 0


def needed_for(rows: list[MarkRow], scale: str, target: int, weight: float,
               bands=DEFAULT_BANDS) -> Needed:
    """Worst next mark (of ``weight``) that still ends on final ``target``."""
    bands = normalize_bands(bands)
    weight = max(0.01, float(weight))
    total = sum(r.value * r.weight for r in rows if r.counts)
    wsum = sum(r.weight for r in rows if r.counts)

    def ok(avg: float) -> bool:
        return final_grade(avg, scale, bands) <= target

    if scale == "percent":
        if ok(total / (wsum + weight)):  # even 0 % keeps the target
            return Needed("any")
        lower = bands[target - 1] if target < 5 else 0.0
        start = max(0, int((lower * (wsum + weight) - total) / weight))
        for pct in range(start, 101):  # whole percents; boundaries are strict
            if ok((total + pct * weight) / (wsum + weight)):
                return Needed("need", float(pct))
        best = 100.0
    else:
        acceptable = [g for g in GRADE_STEPS if ok((total + g * weight) / (wsum + weight))]
        if acceptable and max(acceptable) >= 5.0:
            return Needed("any")
        if acceptable:
            return Needed("need", max(acceptable))
        best = 1.0
    for n in range(2, 61):
        if ok((total + best * weight * n) / (wsum + weight * n)):
            return Needed("impossible", best, n)
    return Needed("impossible", best, 0)
