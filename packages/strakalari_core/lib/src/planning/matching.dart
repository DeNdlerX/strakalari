// Blacklist matching: diacritics-insensitive, whole-word, Czech-stem aware.
//
// Port of strakalari/core/matching.py. ``vepřové`` matches ``vepřového``,
// ``čočka`` matches ``cocka`` and ``ryba`` matches ``rybí`` — but ``ryb``
// never matches ``rybíz`` (a different word).

/// Strips diacritics the way Python's `unicodedata.normalize("NFD", …)`
/// plus Mn-filtering does: precomposed letters map to their base letter,
/// combining marks are dropped, everything else passes through unchanged.
///
/// Letters without a decomposition (`ø`, `ł`, `ß`, …) are kept, exactly
/// like Python keeps them.
String stripDiacritics(Object? text) {
  final clean = _falsyToEmpty(text).replaceAll(_combiningRe, '');
  final buf = StringBuffer();
  for (var i = 0; i < clean.length; i++) {
    final ch = clean[i];
    buf.write(_diaLookup[ch] ?? ch);
  }
  return buf.toString();
}

/// Lowercase, diacritics-free, trimmed form used for every comparison.
String normalizeWord(Object? text) =>
    stripDiacritics(text).toLowerCase().trim();

/// Mirrors Python's `str(text or "")`.
String _falsyToEmpty(Object? text) {
  if (text == null) return '';
  if (text is bool) return text ? 'True' : '';
  if (text is num && text == 0) return '';
  if (text is String && text.isEmpty) return '';
  if (text is Iterable && text.isEmpty) return '';
  if (text is Map && text.isEmpty) return '';
  return '$text';
}

bool _isFalsy(Object? value) {
  if (value == null) return true;
  if (value is bool) return !value;
  if (value is num) return value == 0;
  if (value is String) return value.isEmpty;
  if (value is Iterable) return value.isEmpty;
  if (value is Map) return value.isEmpty;
  return false;
}

// Combining-mark ranges stripped like Python's Mn category filter.
final RegExp _combiningRe = RegExp(
    r'[\u0300-\u036f\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f]');

// Precomposed letters grouped by the base letter Python's NFD
// decomposition yields. Only letters that actually decompose are listed
// (`ø`, `ł`, `đ`, `ß`, `æ`, `œ`, `ı` have no decomposition and stay as-is,
// exactly like Python).
const Map<String, String> _diaGroups = {
  'a': 'àáâãäåāăąǎȁȃạảấầẩẫậắằẳẵặ',
  'c': 'çćĉċč',
  'd': 'ďḍḏ',
  'e': 'èéêëēĕėęěẹẻẽếềểễệ',
  'g': 'ĝğġģ',
  'h': 'ĥḥ',
  'i': 'ìíîïĩīĭįǐȉȋịỉ',
  'j': 'ĵ',
  'k': 'ķ',
  'l': 'ĺļľŀ',
  'n': 'ñńņň',
  'o': 'òóôõöōŏőơọỏ',
  'r': 'ŕŗř',
  's': 'śŝşšș',
  't': 'ţťț',
  'u': 'ùúûüũūŭůűųưụủứừửữự',
  'w': 'ŵ',
  'y': 'ýÿŷ',
  'z': 'źżž',
};

Map<String, String> _buildDiaLookup() {
  final lookup = <String, String>{};
  for (final group in _diaGroups.entries) {
    for (var i = 0; i < group.value.length; i++) {
      final ch = group.value[i];
      lookup[ch] = group.key;
      final up = ch.toUpperCase();
      if (up != ch && up.length == 1) lookup[up] = group.key.toUpperCase();
    }
  }
  // NFD("İ") is "I" + combining dot, which the combining-mark strip
  // removes — so İ maps to I.
  lookup['İ'] = 'I';
  return lookup;
}

final Map<String, String> _diaLookup = _buildDiaLookup();

// Czech case/adjective endings, longest first. One ending is stripped as
// long as a stem of at least 3 letters remains, so short food words
// collapse with their inflections: ryba/ryby/rybí -> ryb, sýr/sýrová -> syr,
// maso/masová -> mas, kuře/kuřecí -> kur.
const List<String> _suffixes = [
  'oveho',
  'ovemu',
  'ovych',
  'ovymi',
  'eciho',
  'ecimu',
  'ovech',
  'ovou',
  'ovym',
  'ovy',
  'ova',
  'ove',
  'ovi',
  'eci',
  'eho',
  'emu',
  'ych',
  'ymi',
  'imi',
  'ich',
  'ach',
  'ami',
  'ou',
  'em',
  'am',
  'im',
  'ym',
  'y',
  'i',
  'e',
  'a',
  'u',
  'o',
];

/// Reduces a normalized word to a crude Czech stem for comparison.
String _stem(String word) {
  for (final suffix in _suffixes) {
    if (word.endsWith(suffix) && word.length - suffix.length >= 3) {
      return word.substring(0, word.length - suffix.length);
    }
  }
  return word;
}

List<String> _tokens(Object? text) => normalizeWord(text)
    .split(RegExp(r'[^a-z0-9]+'))
    .where((t) => t.isNotEmpty)
    .toList();

// -- free-text preference keywords -------------------------------------------
// The lunches sidebar prefs field is free text (same wording as the AI
// prompt: "nemám rád vepřové, preferuji lehká jídla"). Only negation
// clauses contribute ban keywords — likes must never hide meals.
// A clause joined by "a"/"i" can mix a dislike with a like
// ("nemám rád vepřové a mám rád kuřecí"): the like-segment must not
// poison the ban list, while "bez hub a česneku" keeps both
// (the second segment just inherits the negation).

const Set<String> _prefNegations = {
  // Czech
  'nemam',
  'nemame',
  'nerad',
  'nerada',
  'neradi',
  'nerado',
  'nechci',
  'nechceme',
  'nechutna',
  'nechutnaji',
  'nejim',
  'nejime',
  'neji',
  'nemusim',
  'nemusime',
  'nesnasim',
  'nesnasime',
  'bez',
  'vynech',
  'vynechat',
  'vynechte',
  'vynechavat',
  'zadny',
  'zadna',
  'zadne',
  'zadnych',
  'zadneho',
  'ne',
  // English
  'no',
  'not',
  'dont',
  'doesnt',
  'dislike',
  'dislikes',
  'hate',
  'avoid',
  'without',
  'never',
};

// Like-cues: a conjunction-segment carrying one of these (without its
// own negation) is a like-segment and contributes no ban keywords.
const Set<String> _prefLikeCues = {
  'rad',
  'rada',
  'rade',
  'radi',
  'radsi',
  'radeji',
  'preferuji',
  'preferuju',
  'chutna',
  'chutnaji',
  'miluji',
  'miluju',
  'like',
  'love',
};

// Standalone conjunctions joining segments inside one clause.
//
// Word boundaries are matched with explicit letter-class lookarounds
// instead of `\b`: Dart's `\b` is ASCII-only, so `také` (é = non-word
// in Dart, word in Python) would never split. The lookarounds make
// `také` split exactly like Python's `\btak[eé]\b`.
final RegExp _conjSplitRe = RegExp(
    r'(?<![A-Za-zÀ-ɏḀ-ỿ])(?:a|i|plus|tak[eé])(?![A-Za-zÀ-ɏḀ-ỿ])',
    caseSensitive: false);

const Set<String> _prefStopwords = {
  // Like/meal-generic filler that must never become a ban keyword.
  'mam',
  'mit',
  'rad',
  'rada',
  'rade',
  'radi',
  'radsi',
  'radeji',
  'preferuji',
  'preferuju',
  'chutna',
  'chutnaji',
  'chut',
  'jidlo',
  'jidla',
  'jidel',
  'jidlu',
  'jidlem',
  'jist',
  'jim',
  'jime',
  'ji',
  'obed',
  'obedy',
  'obeda',
  'menu',
  'jidelna',
  'jidelne',
  'prosim',
  'napr',
  'napriklad',
  'volne',
  'kousek',
  'trochu',
  'moc',
  'velmi',
};

final RegExp _clauseSplitRe =
    RegExp('[,;.\\n!?:()\\[\\]{}„“"\'…]+');

// Any-letter runs. Python's `[^\W\d_]+` is Unicode-aware; Dart's `\w`
// stays ASCII-only even with `unicode: true`, so the letter ranges are
// spelled out (Latin-1 Supplement + Latin Extended-A/B + Latin Extended
// Additional cover Czech/Slovak plus the neighboring languages).
final RegExp _wordRe = RegExp(r'[A-Za-zÀ-ɏḀ-ỿ]+');

/// Extracts dislike keywords from free-text lunch preferences.
///
/// Splits on sentence/clause boundaries; a clause contributes its
/// content words only when it carries a negation cue (``nemám rád
/// X``, ``bez X``, ``no X``). Pure-like clauses (``mám rád kuřecí``)
/// are ignored so likes never hide meals. A clause joined by
/// "a"/"i" is split into segments first: a segment with a like-cue
/// and no negation of its own (``mám rád kuřecí``) is skipped, while
/// plain segments (``česneku`` in ``bez hub a česneku``) inherit the
/// clause negation. Returns raw words (diacritics preserved for
/// display); matching stays in [isFoodBanned], which
/// normalizes internally.
List<String> prefsBanKeywords(Object? prefs) {
  if (_isFalsy(prefs)) return [];
  final found = <String>[];
  final seen = <String>{};
  for (final clause in '$prefs'.split(_clauseSplitRe)) {
    if (clause.trim().isEmpty) continue;
    final segments = clause
        .split(_conjSplitRe)
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (segments.length <= 1) {
      _emitPrefsSegment(clause, true, found, seen);
    } else {
      final clauseNorm = [
        for (final m in _wordRe.allMatches(clause)) normalizeWord(m.group(0))
      ];
      final clauseNeg = clauseNorm.any(_prefNegations.contains);
      for (final seg in segments) {
        final segNorm = [
          for (final m in _wordRe.allMatches(seg)) normalizeWord(m.group(0))
        ];
        if (segNorm.isEmpty) continue;
        if (segNorm.any(_prefLikeCues.contains) &&
            !segNorm.any(_prefNegations.contains)) {
          continue;
        }
        // Plain segments inherit the clause negation
        // ("česneku" in "bez hub a česneku"); segments of a
        // negation-free clause still need their own cue.
        _emitPrefsSegment(seg, !clauseNeg, found, seen);
      }
    }
  }
  return found;
}

/// Appends content words of one prefs segment to [found].
void _emitPrefsSegment(
    String text, bool requireNegation, List<String> found, Set<String> seen) {
  final rawWords =
      _wordRe.allMatches(text).map((m) => m.group(0)!).toList();
  if (rawWords.isEmpty) return;
  final norm = [for (final w in rawWords) normalizeWord(w)];
  if (requireNegation && !norm.any(_prefNegations.contains)) return;
  for (var i = 0; i < rawWords.length; i++) {
    final word = norm[i];
    if (word.length < 3) continue;
    if (_prefNegations.contains(word) || _prefStopwords.contains(word)) {
      continue;
    }
    final key = word;
    if (seen.contains(key)) continue;
    seen.add(key);
    found.add(rawWords[i].trim());
  }
}

/// Returns (banned, matched_keyword). Case/diacritics-insensitive.
///
/// Matches whole words by crude Czech stem, so ``vepřové`` matches
/// ``vepřového`` and ``čočka`` matches ``cocka`` — but ``ryb`` does NOT
/// match ``rybíz`` (different stem).
(bool, String) isFoodBanned(Object? foodName, List<Object?>? blacklist) {
  if (_isFalsy(foodName) || blacklist == null || blacklist.isEmpty) {
    return (false, '');
  }
  final hayStems = <String>{};
  for (final t in _tokens(foodName)) {
    hayStems.add(_stem(t));
  }
  bool matches(Set<String> hay, String kwStem) {
    if (hay.contains(kwStem)) return true;
    // Prefix match for inflections ("vepr" vs "veproveho"),
    // but require a shared stem of 5+ chars: 4-letter overlaps
    // like "rybi"/"rybiz" ("rybí" vs "rybíz") are different
    // words, not inflections.
    if (kwStem.length >= 5) {
      for (final hayStem in hay) {
        if (hayStem.length >= 5 &&
            (hayStem.startsWith(kwStem) ||
                kwStem.startsWith(hayStem))) {
          if (hayStem.substring(0, 5) == kwStem.substring(0, 5)) return true;
        }
      }
    }
    return false;
  }

  for (final raw in blacklist) {
    final keyword = normalizeWord(raw);
    if (keyword.isEmpty || keyword.startsWith('your_blacklist')) continue;
    // A multi-word phrase bans only when EVERY word matches ("vepřové
    // maso" must not ban "kuřecí maso" via the shared word "maso").
    var kwStems = [for (final t in _tokens(keyword)) _stem(t)];
    kwStems = [for (final s in kwStems) if (s.length >= 3) s];
    if (kwStems.isEmpty) continue;
    if (kwStems.every((kwStem) => matches(hayStems, kwStem))) {
      return (true, '$raw'.trim());
    }
  }
  return (false, '');
}
