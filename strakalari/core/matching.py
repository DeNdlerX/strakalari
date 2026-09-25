"""Blacklist matching: diacritics-insensitive, whole-word, Czech-stem aware.

``vepřové`` matches ``vepřového``, ``čočka`` matches ``cocka`` and ``ryba``
matches ``rybí`` — but ``ryb`` never matches ``rybíz`` (a different word).
"""

from __future__ import annotations

import re
import unicodedata


def strip_diacritics(text: str) -> str:
    normalized = unicodedata.normalize("NFD", str(text or ""))
    return "".join(c for c in normalized if unicodedata.category(c) != "Mn")


def normalize_word(text: str) -> str:
    return strip_diacritics(text).lower().strip()


# Czech case/adjective endings, longest first. One ending is stripped as
# long as a stem of at least 3 letters remains, so short food words
# collapse with their inflections: ryba/ryby/rybí -> ryb, sýr/sýrová -> syr,
# maso/masová -> mas, kuře/kuřecí -> kur.
_SUFFIXES = (
    "oveho", "ovemu", "ovych", "ovymi", "eciho", "ecimu",
    "ovech", "ovou", "ovym", "ovy", "ova", "ove", "ovi", "eci",
    "eho", "emu", "ych", "ymi", "imi", "ich", "ach", "ami",
    "ou", "em", "am", "im", "ym",
    "y", "i", "e", "a", "u", "o",
)


def _stem(word: str) -> str:
    """Reduces a normalized word to a crude Czech stem for comparison."""
    for suffix in _SUFFIXES:
        if word.endswith(suffix) and len(word) - len(suffix) >= 3:
            return word[: -len(suffix)]
    return word


def _tokens(text: str) -> list[str]:
    return [t for t in re.split(r"[^a-z0-9]+", normalize_word(text)) if t]


# -- free-text preference keywords -------------------------------------------
# The lunches sidebar prefs field is free text (same wording as the AI
# prompt: "nemám rád vepřové, preferuji lehká jídla"). Only negation
# clauses contribute ban keywords — likes must never hide meals.
# A clause joined by "a"/"i" can mix a dislike with a like
# ("nemám rád vepřové a mám rád kuřecí"): the like-segment must not
# poison the ban list, while "bez hub a česneku" keeps both
# (the second segment just inherits the negation).

_PREF_NEGATIONS = frozenset({
    # Czech
    "nemam", "nemame", "nerad", "nerada", "neradi", "nerado",
    "nechci", "nechceme", "nechutna", "nechutnaji",
    "nejim", "nejime", "neji", "nemusim", "nemusime",
    "nesnasim", "nesnasime", "bez", "vynech", "vynechat",
    "vynechte", "vynechavat", "zadny", "zadna", "zadne",
    "zadnych", "zadneho", "ne",
    # English
    "no", "not", "dont", "doesnt", "dislike", "dislikes",
    "hate", "avoid", "without", "never",
})

# Like-cues: a conjunction-segment carrying one of these (without its
# own negation) is a like-segment and contributes no ban keywords.
_PREF_LIKE_CUES = frozenset({
    "rad", "rada", "rade", "radi", "radsi", "radeji",
    "preferuji", "preferuju", "chutna", "chutnaji",
    "miluji", "miluju", "like", "love",
})

# Standalone conjunctions joining segments inside one clause.
_CONJ_SPLIT_RE = re.compile(r"\b(?:a|i|plus)\b|\btak[eé]\b", re.IGNORECASE)

_PREF_STOPWORDS = frozenset({
    # Like/meal-generic filler that must never become a ban keyword.
    "mam", "mit", "rad", "rada", "rade", "radi", "radsi", "radeji",
    "preferuji", "preferuju", "chutna", "chutnaji", "chut",
    "jidlo", "jidla", "jidel", "jidlu", "jidlem",
    "jist", "jim", "jime", "ji", "obed", "obedy", "obeda",
    "menu", "jidelna", "jidelne", "prosim", "napr", "napriklad",
    "volne", "kousek", "trochu", "moc", "velmi",
})

_CLAUSE_SPLIT_RE = re.compile(r"[,;.\n!?:()\[\]{}„“\"'…]+")
_WORD_RE = re.compile(r"[^\W\d_]+", re.UNICODE)


def prefs_ban_keywords(prefs: object) -> list[str]:
    """Extracts dislike keywords from free-text lunch preferences.

    Splits on sentence/clause boundaries; a clause contributes its
    content words only when it carries a negation cue (``nemám rád
    X``, ``bez X``, ``no X``). Pure-like clauses (``mám rád kuřecí``)
    are ignored so likes never hide meals. A clause joined by
    "a"/"i" is split into segments first: a segment with a like-cue
    and no negation of its own (``mám rád kuřecí``) is skipped, while
    plain segments (``česneku`` in ``bez hub a česneku``) inherit the
    clause negation. Returns raw words (diacritics preserved for
    display); matching stays in :func:`is_food_banned`, which
    normalizes internally.
    """
    if not prefs:
        return []
    found: list[str] = []
    seen: set[str] = set()
    for clause in _CLAUSE_SPLIT_RE.split(str(prefs)):
        if not clause.strip():
            continue
        segments = [s for s in _CONJ_SPLIT_RE.split(clause) if s and s.strip()]
        if len(segments) <= 1:
            _emit_prefs_segment(clause, True, found, seen)
        else:
            clause_norm = [normalize_word(w) for w in _WORD_RE.findall(clause)]
            clause_neg = any(t in _PREF_NEGATIONS for t in clause_norm)
            for seg in segments:
                seg_norm = [normalize_word(w) for w in _WORD_RE.findall(seg)]
                if not seg_norm:
                    continue
                if any(t in _PREF_LIKE_CUES for t in seg_norm) and not any(
                    t in _PREF_NEGATIONS for t in seg_norm
                ):
                    continue
                # Plain segments inherit the clause negation
                # ("česneku" in "bez hub a česneku"); segments of a
                # negation-free clause still need their own cue.
                _emit_prefs_segment(seg, not clause_neg, found, seen)
    return found


def _emit_prefs_segment(
    text: str, require_negation: bool, found: list[str], seen: set[str]
) -> None:
    """Appends content words of one prefs segment to ``found``."""
    raw_words = _WORD_RE.findall(text)
    if not raw_words:
        return
    norm = [normalize_word(w) for w in raw_words]
    if require_negation and not any(t in _PREF_NEGATIONS for t in norm):
        return
    for raw, word in zip(raw_words, norm, strict=True):
        if len(word) < 3:
            continue
        if word in _PREF_NEGATIONS or word in _PREF_STOPWORDS:
            continue
        key = word
        if key in seen:
            continue
        seen.add(key)
        found.append(raw.strip())


def is_food_banned(food_name: str, blacklist: list) -> tuple[bool, str]:
    """Returns (banned, matched_keyword). Case/diacritics-insensitive.

    Matches whole words by crude Czech stem, so ``vepřové`` matches
    ``vepřového`` and ``čočka`` matches ``cocka`` — but ``ryb`` does NOT
    match ``rybíz`` (different stem).
    """
    if not food_name or not blacklist:
        return False, ""
    hay_tokens = _tokens(food_name)
    hay_stems = {_stem(t): t for t in hay_tokens}
    def _matches(hay_stems: set[str], kw_stem: str) -> bool:
        if kw_stem in hay_stems:
            return True
        # Prefix match for inflections ("vepr" vs "veproveho"),
        # but require a shared stem of 5+ chars: 4-letter overlaps
        # like "rybi"/"rybiz" ("rybí" vs "rybíz") are different
        # words, not inflections.
        if len(kw_stem) >= 5:
            for hay_stem in hay_stems:
                if len(hay_stem) >= 5 and (
                    hay_stem.startswith(kw_stem) or kw_stem.startswith(hay_stem)
                ):
                    if hay_stem[:5] == kw_stem[:5]:
                        return True
        return False

    hay_set = set(hay_stems)
    for raw in blacklist or []:
        keyword = normalize_word(raw)
        if not keyword or keyword.startswith("your_blacklist"):
            continue
        # A multi-word phrase bans only when EVERY word matches ("vepřové
        # maso" must not ban "kuřecí maso" via the shared word "maso").
        kw_stems = [_stem(t) for t in _tokens(keyword)]
        kw_stems = [s for s in kw_stems if len(s) >= 3]
        if not kw_stems:
            continue
        if all(_matches(hay_set, kw_stem) for kw_stem in kw_stems):
            return True, str(raw).strip()
    return False, ""
