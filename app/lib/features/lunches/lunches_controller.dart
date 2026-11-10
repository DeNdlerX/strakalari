import 'package:strakalari_core/strakalari_core.dart' as core;

/// Lunch state. Port of state_lunches.LunchMixin (UI-owned parts).
///
/// No Flutter import: the view observes via listeners. Cutoff checks and
/// blacklist persistence are injectable so tests use fakes.
class LunchController {
  final Map<String, dynamic> config;
  final List<void Function()> _listeners = [];

  Map<String, Map<String, String>> food = {};
  Map<String, String> webOrders = {};
  Map<String, String> orders = {};
  Set<String> pendingOrders = {};
  Set<String> cancelledLunches = {};
  Set<String> lunchHidden = {};
  Map<String, String> lunchReasons = {};
  String lunchPrefs = '';
  bool aiRunning = false;
  bool stravaOn = false;
  bool demoMode = false;
  bool showPastLunches = false;
  bool lunchToolsOpen = false;
  bool sidebarOpen = true;
  Map<String, List<String>> lowBalance = {};

  /// Cutoff predicate (`D.M.YYYY` → open?). Null = always open.
  bool Function(String day)? isOrderOpen;

  /// Current blacklist words (file-backed in the app, fake in tests).
  List<String> Function()? readBlacklist;

  /// Persist [words]; false/throw = edit rejected (mirrors
  /// `_blacklist_words_for_edit` fail-closed behavior).
  bool Function(List<String> words)? writeBlacklist;

  String blacklistEditError = '';

  void Function(String event)? onTutorialEvent;
  void Function(String message)? onLog;

  /// Live-wiring hooks into the shared `AppState` (when non-null).
  bool Function(String day, String mealId)? orderLunchHook;
  void Function(String day)? cancelLunchOrderHook;
  void Function(String prefs)? applyFoodFilterHook;
  bool Function(String word)? addBlacklistWordHook;
  bool Function(String word)? removeBlacklistWordHook;
  void Function(bool show)? setShowPastLunchesHook;
  void Function(bool open)? setLunchToolsHook;
  void Function(bool open)? setSidebarHook;
  void Function(String prefs)? setLunchPrefsHook;

  LunchController(
    this.config, {
    this.isOrderOpen,
    this.readBlacklist,
    this.writeBlacklist,
    this.onTutorialEvent,
    this.onLog,
  });

  void addListener(void Function() fn) => _listeners.add(fn);
  void removeListener(void Function() fn) => _listeners.remove(fn);
  void _emit() {
    for (final fn in List.of(_listeners)) {
      fn();
    }
  }

  dynamic get(String key, [dynamic fallback]) =>
      config.containsKey(key) ? config[key] : fallback;

  bool get stravaEnabled => stravaOn;

  // -- change bookkeeping -----------------------------------------------------
  static String realMeal(Object? mealId) {
    final mid = (mealId ?? '').toString();
    return mid.contains('&-1&') ? '' : mid;
  }

  /// True when the local pick differs from Strava web truth.
  bool lunchIsChange(String day) {
    if (!orders.containsKey(day)) return false;
    return realMeal(orders[day]) != realMeal(webOrders[day]);
  }

  int get pendingLunchCount {
    var n = 0;
    for (final day in pendingOrders) {
      if (lunchIsChange(day)) n++;
    }
    return n;
  }

  bool _stagePick(String day, String mealId) {
    orders[day] = mealId;
    if (lunchIsChange(day)) {
      pendingOrders.add(day);
      return true;
    }
    pendingOrders.remove(day);
    return false;
  }

  /// Records a lunch choice. False (stages nothing) past the cutoff.
  bool orderLunch(String day, String mealId) {
    if (orderLunchHook != null) return orderLunchHook!(day, mealId);
    if (!stravaOn) return false;
    if (isOrderOpen != null) {
      var open = false;
      try {
        open = isOrderOpen!(day);
      } catch (_) {
        open = false;
      }
      if (!open) {
        onLog?.call('closed');
        return false;
      }
    }
    _stagePick(day, mealId);
    cancelledLunches.remove(day);
    onTutorialEvent?.call('lunch_picked');
    _emit();
    return true;
  }

  void cancelLunchOrder(String day) {
    if (cancelLunchOrderHook != null) return cancelLunchOrderHook!(day);
    orders.remove(day);
    pendingOrders.remove(day);
    _emit();
  }

  // -- filter ------------------------------------------------------------------
  List<String> blacklistWords() {
    if (readBlacklist != null) {
      try {
        return readBlacklist!();
      } catch (_) {
        return [];
      }
    }
    return [];
  }

  void applyFoodFilter(String prefs) {
    if (applyFoodFilterHook != null) return applyFoodFilterHook!(prefs);
    final blacklist = blacklistWords();
    final prefWords = core.prefsBanKeywords(prefs);
    final seen = {for (final w in blacklist) w.toLowerCase()};
    final combined = List<String>.of(blacklist);
    for (final word in prefWords) {
      if (!seen.contains(word.toLowerCase())) {
        seen.add(word.toLowerCase());
        combined.add(word);
      }
    }
    final hidden = <String>{};
    final reasons = <String, String>{};
    for (final meals in food.values) {
      for (final e in meals.entries) {
        if (e.key.contains('&-1&')) continue;
        final (banned, keyword) = core.isFoodBanned(e.value, combined);
        if (banned) {
          hidden.add(e.key);
          reasons[e.key] = keyword;
        }
      }
    }
    lunchHidden = hidden;
    lunchReasons = reasons;
    lunchPrefs = prefs;
    final picks = core.filterPicks(
      food,
      blacklist: combined,
      cancelledDays: cancelledLunches,
      isOpen: isOrderOpen == null
          ? null
          : (dt) => isOrderOpen!(
              '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${dt.year}'),
    );
    for (final e in picks.entries) {
      final current = orders[e.key];
      if (current == null || hidden.contains(current)) {
        _stagePick(e.key, e.value);
      }
    }
    _emit();
  }

  // -- blacklist edits ----------------------------------------------------------
  bool addBlacklistWord(String word) {
    if (addBlacklistWordHook != null) return addBlacklistWordHook!(word);
    blacklistEditError = '';
    word = word.trim();
    if (word.length < 3) return false;
    final current = _wordsForEdit();
    if (current == null) return false;
    if (current.any((w) => w.toLowerCase() == word.toLowerCase())) {
      return false;
    }
    final next = [...current, word];
    if (!_write(next)) return false;
    applyFoodFilter(lunchPrefs);
    return true;
  }

  bool removeBlacklistWord(String word) {
    if (removeBlacklistWordHook != null) return removeBlacklistWordHook!(word);
    blacklistEditError = '';
    final current = _wordsForEdit();
    if (current == null) return false;
    final next = [
      for (final w in current)
        if (w.toLowerCase() != word.toLowerCase()) w,
    ];
    if (!_write(next)) return false;
    applyFoodFilter(lunchPrefs);
    return true;
  }

  List<String>? _wordsForEdit() {
    if (readBlacklist == null) return [];
    try {
      return List.of(readBlacklist!());
    } catch (_) {
      blacklistEditError = 'unreadable';
      return null;
    }
  }

  bool _write(List<String> words) {
    if (writeBlacklist == null) return true;
    try {
      return writeBlacklist!(words);
    } catch (_) {
      return false;
    }
  }
}
