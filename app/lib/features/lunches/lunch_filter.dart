// Pure lunch-filter logic. Ports `core/matching.py` prefs parts used by
// `apply_food_filter`/`filter_picks`: keyword extraction, ban matching
// and first-allowed staging.

/// Removes diacritics (á→a, č→c, …). Port of `matching.strip_diacritics`.
String stripDiacritics(String text) {
  const map = {
    'á': 'a', 'ä': 'a', 'č': 'c', 'ď': 'd', 'é': 'e', 'ě': 'e', 'í': 'i',
    'ĺ': 'l', 'ľ': 'l', 'ň': 'n', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'ő': 'o',
    'ř': 'r', 'š': 's', 'ť': 't', 'ú': 'u', 'ů': 'u', 'ü': 'u', 'ý': 'y',
    'ž': 'z', 'à': 'a', 'â': 'a', 'æ': 'ae', 'ç': 'c', 'è': 'e', 'ê': 'e',
    'ë': 'e', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'œ': 'oe',
    'ù': 'u', 'û': 'u', 'ÿ': 'y', 'ă': 'a', 'ș': 's',
    'ț': 't', 'ł': 'l', 'ń': 'n', 'ś': 's', 'ź': 'z', 'ż': 'z', 'ą': 'a',
    'ę': 'e', 'ė': 'e', 'į': 'i', 'ų': 'u', 'ū': 'u',
  };
  final out = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    final lower = ch.toLowerCase();
    final plain = map[lower];
    if (plain == null) {
      out.write(ch);
    } else if (ch == lower) {
      out.write(plain);
    } else {
      out.write(plain.toUpperCase());
    }
  }
  return out.toString();
}

String normalizeWord(String text) =>
    stripDiacritics(text).toLowerCase().trim();

List<String> _tokens(String text) {
  return normalizeWord(text)
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toList();
}

const _suffixes = [
  'oveho', 'ovemu', 'ovych', 'ovymi', 'eciho', 'ecimu',
  'ovech', 'ovou', 'ovym', 'ovy', 'ova', 'ove', 'ovi', 'eci',
  'eho', 'emu', 'ych', 'ymi', 'imi', 'ich', 'ach', 'ami',
  'ou', 'em', 'am', 'im', 'ym',
  'y', 'i', 'e', 'a', 'u', 'o',
];

String _stem(String word) {
  for (final suffix in _suffixes) {
    if (word.endsWith(suffix) && word.length - suffix.length >= 3) {
      return word.substring(0, word.length - suffix.length);
    }
  }
  return word;
}

const _negations = {
  'nemam', 'nemame', 'nerad', 'nerada', 'neradi', 'nerado',
  'nechci', 'nechceme', 'nechutna', 'nechutnaji',
  'nejim', 'nejime', 'neji', 'nemusim', 'nemusime',
  'nesnasim', 'nesnasime', 'bez', 'vynech', 'vynechat',
  'vynechte', 'vynechavat', 'zadny', 'zadna', 'zadne',
  'zadnych', 'zadneho', 'ne',
  'no', 'not', 'dont', 'doesnt', 'dislike', 'dislikes',
  'hate', 'avoid', 'without', 'never',
};

const _likeCues = {
  'rad', 'rada', 'rade', 'radi', 'radsi', 'radeji',
  'preferuji', 'preferuju', 'chutna', 'chutnaji',
  'miluji', 'miluju', 'like', 'love',
};

const _stopwords = {
  'mam', 'mit', 'rad', 'rada', 'rade', 'radi', 'radsi', 'radeji',
  'preferuji', 'preferuju', 'chutna', 'chutnaji', 'chut',
  'jidlo', 'jidla', 'jidel', 'jidlu', 'jidlem',
  'jist', 'jim', 'jime', 'ji', 'obed', 'obedy', 'obeda',
  'menu', 'jidelna', 'jidelne', 'prosim', 'napr', 'napriklad',
  'volne', 'kousek', 'trochu', 'moc', 'velmi',
};

final _clauseSplit =
    RegExp(r'[,;.\n!?:()\[\]{}„“"' "'" r'…]+');
final _conjSplit =
    RegExp(r'\b(?:a|i|plus)\b|\btak[eé]\b', caseSensitive: false);
/// Letters for word splitting: ASCII + Latin-1 Supplement + Latin
/// Extended-A/B (cs/sk/pl/de/fr/ro). Dart's `\W` leaves accented Latin
/// letters like `á` out even with `unicode: true`, so an explicit range
/// is used instead of `[^\W\d_]` (which would split every Czech word).
final _wordRe = RegExp(r'[A-Za-zÀ-žĀ-ʯ]+');

/// Dislike keywords from free-text prefs. Port of
/// `matching.prefs_ban_keywords` (same cases as test_lunch_filter).
List<String> prefsBanKeywords(String? prefs) {
  if (prefs == null || prefs.isEmpty) return [];
  final found = <String>[];
  final seen = <String>{};
  void emit(String text, bool requireNegation) {
    final rawWords =
        _wordRe.allMatches(text).map((m) => m.group(0)!).toList();
    if (rawWords.isEmpty) return;
    final norm = [for (final w in rawWords) normalizeWord(w)];
    if (requireNegation &&
        !norm.any(_negations.contains)) {
      return;
    }
    for (var i = 0; i < rawWords.length; i++) {
      final word = norm[i];
      if (word.length < 3) continue;
      if (_negations.contains(word) || _stopwords.contains(word)) continue;
      if (seen.contains(word)) continue;
      seen.add(word);
      found.add(rawWords[i].trim());
    }
  }

  for (final clause in prefs.split(_clauseSplit)) {
    if (clause.trim().isEmpty) continue;
    final segments = clause
        .split(_conjSplit)
        .map((s) => s)
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (segments.length <= 1) {
      emit(clause, true);
    } else {
      final clauseNorm = [
        for (final w in _wordRe.allMatches(clause)) normalizeWord(w.group(0)!)
      ];
      final clauseNeg = clauseNorm.any(_negations.contains);
      for (final seg in segments) {
        final segNorm = [
          for (final w in _wordRe.allMatches(seg)) normalizeWord(w.group(0)!)
        ];
        if (segNorm.isEmpty) continue;
        if (segNorm.any(_likeCues.contains) &&
            !segNorm.any(_negations.contains)) {
          continue;
        }
        emit(seg, !clauseNeg);
      }
    }
  }
  return found;
}

bool _matches(Set<String> hayStems, String kwStem) {
  if (hayStems.contains(kwStem)) return true;
  if (kwStem.length >= 5) {
    for (final hayStem in hayStems) {
      if (hayStem.length >= 5 &&
          (hayStem.startsWith(kwStem) || kwStem.startsWith(hayStem)) &&
          hayStem.substring(0, 5) == kwStem.substring(0, 5)) {
        return true;
      }
    }
  }
  return false;
}

/// (banned, matchedKeyword). Port of `matching.is_food_banned`.
(bool, String) isFoodBanned(String foodName, List<String> blacklist) {
  if (foodName.isEmpty || blacklist.isEmpty) return (false, '');
  final hayTokens = _tokens(foodName);
  final hayStems = {for (final t in hayTokens) _stem(t)};
  for (final raw in blacklist) {
    final keyword = normalizeWord(raw);
    if (keyword.isEmpty || keyword.startsWith('your_blacklist')) continue;
    final kwStems = [
      for (final t in _tokens(keyword)) _stem(t)
    ].where((s) => s.length >= 3).toList();
    if (kwStems.isEmpty) continue;
    if (kwStems.every((s) => _matches(hayStems, s))) {
      return (true, raw.trim());
    }
  }
  return (false, '');
}

/// 'Soup; Main (1,3,7)' → (soup, main, allergens). Port of
/// `LunchView._split_meal`.
(String, String, String) splitMeal(String name) {
  var text = displayMealName(name).trim();
  var allergens = '';
  final m = RegExp(r'\(\s*(\d{1,2}[a-z]?(?:\s*,\s*\d{1,2}[a-z]?)*)\s*\)\s*$')
      .firstMatch(text);
  if (m != null) {
    allergens = m
        .group(1)!
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .join(', ');
    text = text.substring(0, m.start).trimRight();
  }
  final idx = text.indexOf(';');
  if (idx < 0) return ('', text, allergens);
  return (text.substring(0, idx).trim(), text.substring(idx + 1).trim(),
      allergens);
}

/// Tidy raw Strava names. Port of `LunchView._display_name`.
String displayMealName(String name) {
  var text = name.replaceAllMapped(
      RegExp(r',(\S)'), (m) => ', ${m.group(1)}');
  text = text.replaceAllMapped(
      RegExp(r'(\S)\('), (m) => '${m.group(1)} (');
  return text.replaceAll(RegExp(r'\s+\)'), ')');
}

/// The soup every meal of the day shares ('' when they differ).
String sharedSoup(Map<String, String> meals) {
  final soups = {
    for (final e in meals.entries)
      if (!e.key.contains('&-1&')) splitMeal(e.value).$1,
  };
  return soups.length == 1 ? soups.single : '';
}

/// First-allowed pick per orderable day. Port of the staging part of
/// `filter_picks` used by `apply_food_filter`: skips cancelled and
/// closed days; days without a pick (or with a hidden pick) get the
/// first allowed meal.
Map<String, String> filterPicks({
  required Map<String, Map<String, String>> food,
  required List<String> blacklist,
  required Set<String> cancelledDays,
  required bool Function(String day)? isOpen,
}) {
  final picks = <String, String>{};
  for (final day in food.keys) {
    if (cancelledDays.contains(day)) continue;
    if (isOpen != null) {
      var open = true;
      try {
        open = isOpen(day);
      } catch (_) {
        open = false;
      }
      if (!open) continue;
    }
    final meals = food[day] ?? {};
    for (final e in meals.entries) {
      if (e.key.contains('&-1&')) continue;
      final (banned, _) = isFoodBanned(e.value, blacklist);
      if (!banned) {
        picks[day] = e.key;
        break;
      }
    }
  }
  return picks;
}
