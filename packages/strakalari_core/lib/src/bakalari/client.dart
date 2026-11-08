// Bakaláři web client: session and login, over plain HTTP.
//
// Port of strakalari/core/bakalari_client.py. Everything goes to the
// Bakaláři web pages and their own endpoints (`http_session`), never
// through a browser and never the mobile API.
//
// The class is assembled from mixins so no single file carries the whole
// client: `timetable.dart` (weekly + stable timetable), `data.dart`
// (marks, absence, sent excuses, substitutions, baseline) and
// `excuse.dart` (the excuse form) land in later commits of this phase.
// Pure parsing helpers live in `common.dart` and are re-exported here
// for existing imports.
import '../automation/cancel.dart';
import '../error_report.dart';
import '../storage/helpers.dart';
import '../i18n.dart';
import 'http_session.dart';
import 'timetable.dart';
import 'data.dart';
import 'excuse.dart';

export 'common.dart' show parseTimetableDetail, weekOffsets;

/// Sent with every HTTP request; the same browser identity the app always used.
const String userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:124.0) '
    'Gecko/20100101 Firefox/124.0';

/// Bakaláři web session: login and requests; data fetching and the
/// excuse form live in the mixins (`timetable.dart` / `data.dart` /
/// `excuse.dart`).
/// Shared base of [BakalariClient]: the mixins (`timetable.dart` /
/// `data.dart` / `excuse.dart`) constrain on this, so the client can mix
/// them in without a cyclic `mixin ... on BakalariClient`.
abstract class BakalariClientBase {
  /// HTTP session, created on first use; [transportOverride] is a test
  /// hook (a transport replacing the network).
  BakalariSession? session;
  final HttpTransport? _transportOverride;

  final Map<String, Object?> config;

  late final String bakalariUrl;
  late final String username;
  late final String password;
  late final bool passwordEncrypted;

  late final int goBackWeeks;
  late final int goForwardWeeks;
  late final String signature;

  late final List<String> lateIncomeExcuses;
  late final List<String> leftSoonExcuses;
  late final List<String> longAbsenceExcuses;
  late final List<String> shortAbsenceExcuses;

  final void Function(String)? logger;
  bool loggedIn = false;

  /// Cooperative cancellation (mirrors StravaClient.cancel_requested;
  /// set from Strakalari.fetch_bakalari_data before each fetch).
  bool cancelRequested = false;

  /// Optional live predicate (e.g. GUI state) polled alongside the flag
  /// so a cancel issued mid-fetch is honored without re-setting flags.
  bool Function()? cancelCallback;

  List<Object?> timetableSources = [];
  Map<String, Object?> timetableData = {};
  Map<String, double> absencePercentages = {};
  // Elapsed hours per subject from the same absence data
  // (see absence_from_subjects).
  Map<String, Object?> absenceDetails = {};
  // School-official subject set (Výuka → Přehled předmětů): only
  // these count toward absence limits. Empty until fetched.
  Map<String, String> subjectDirectory = {};
  // Průběžná klasifikace (see get_grades): {subject: [{Grade, Weight, Date}]},
  // each subject list sorted by date (oldest first). Empty until fetched.
  Map<String, List<Map<String, Object?>>> grades = {};
  // Quarterly marks from the same page: {subject: {Grade[, Note]}}.
  Map<String, Map<String, Object?>> quarterlyMarks = {};
  // Last grades-scrape failure ("") when fresh; non-empty means the
  // displayed marks are last-known/stale, not freshly scraped.
  String gradesError = '';
  // Already-sent excuses scraped from Komens → Odeslané
  // (see fetch_sent_excuses). Empty until synced; never part of
  // fetch_data() so routine refreshes stay read-only and fast.
  // Tri-state: a list (possibly empty) = the outbox was actually read,
  // null = unknown (not yet synced, failed or skipped).
  List<Map<String, Object?>>? sentExcuses = [];
  // Last sent-excuse sync failure ("") = fresh/OK; non-empty = unknown.
  String sentExcusesError = '';
  // First day of the range Odeslané showed on the last sync (the
  // web defaults to one month) — bounds the excuse window. Null = unknown.
  DateTime? sentExcusesFrom;
  // True after a send the site never confirmed (see
  // ExcuseFormMixin.execute_excuse): it may have gone out.
  bool lastSubmitUncertain = false;
  // Past school-year weeks (Mondays) to backfill into the timetable
  // history on top of the regular window — set by the refresh.
  List<DateTime> historyWeeks = [];
  // Mondays of the weeks the last timetable scrape really loaded.
  Set<DateTime> timetableLoadedWeeks = {};
  // Learned stable timetable (SlotBaseline per slot) + actual-vs-stable
  // diffs for the loaded weeks — filled by update_stable_baseline()
  // during fetch_data() so the run itself compares against stable.
  Map<Object, Object?> stableBaseline = {};
  // True when the baseline is the scraped "Stálý" template week
  // (complete: empty slots are free periods). False when the view
  // was not scraped — there is then no baseline at all.
  bool stableComplete = false;
  // Last absence-scrape failure ("") when fresh; non-empty means the
  // displayed percentages are last-known/stale, not freshly scraped.
  String absenceError = '';
  List<Object?> weekChanges = [];
  // Raw scraped "Stálý rozvrh" (stable timetable) view, keyed by day
  // like timetableData. Empty when the view could not be scraped —
  // the run then has no stable baseline.
  Map<String, Object?> stableTimetableData = {};
  // Personal substitution feed (Výuka → Suplování), tri-state like
  // sentExcuses: a list (possibly empty) = the feed was actually
  // read; null = unknown (not yet synced, failed or skipped).
  List<Map<String, Object?>>? substitutions;
  String substitutionsError = '';

  BakalariClientBase(Map<String, Object?>? configData,
      {this.logger, HttpTransport? transport})
      : config = Map<String, Object?>.of(configData ?? {}),
        _transportOverride = transport {
    bakalariUrl = '${config['bakalari_url'] ?? ''}';
    username = '${config['bakalari_username'] ?? ''}';
    password = '${config['bakalari_password'] ?? ''}';
    passwordEncrypted =
        isEncryptedFlag(config['bakalari_password_encrypted']);
    goBackWeeks = _clampInt(config['go_back_weeks'], 4, 0, 52);
    goForwardWeeks = _clampInt(config['go_forward_weeks'], 1, 0, 8);
    signature = '${config['your_signature'] ?? ''}';

    lateIncomeExcuses =
        templateTexts(config['late_income_excuses']);
    leftSoonExcuses =
        templateTexts(config['left_soon_excuses']);
    longAbsenceExcuses =
        templateTexts(config['long_absence_excuses']);
    shortAbsenceExcuses =
        templateTexts(config['short_absence_excuses']);
  }

  void log(String message) {
    logger?.call(message);
  }

  /// Logs a deliberately tolerated failure (see `describe_swallowed`).
  void debug(String what, Object exc) {
    log(describeSwallowed(what, exc));
  }

  bool _isCancelled() {
    if (cancelRequested) return true;
    final cb = cancelCallback;
    if (cb != null) {
      try {
        return cb();
      } on Object {
        return false;
      }
    }
    return false;
  }

  /// Aborts the run promptly when the user hit Zrušit.
  void raiseIfCancelledNow() {
    raiseIfCancelled(_isCancelled);
  }

  double _seconds(String key, double defaultValue) {
    final raw = config.containsKey(key) ? config[key] : defaultValue;
    final value = raw is double
        ? raw
        : raw is int
            ? raw.toDouble()
            : raw is bool
                ? (raw ? 1.0 : 0.0)
                : double.tryParse('${raw ?? ''}'.trim());
    // Zero/negative/NaN/inf timeouts come from hand-edited configs.
    if (value == null ||
        value.isNaN ||
        value.isInfinite ||
        value <= 0) {
      return defaultValue;
    }
    return value;
  }

  String _plainPassword() {
    if (isEncryptedFlag(passwordEncrypted)) {
      final plain = decryptStrict(password);
      if (plain == null) {
        throw UserError(t('bak_password_undecryptable'));
      }
      return plain;
    }
    return password;
  }

  /// The HTTP session, created on first use (no network yet).
  BakalariSession bakalariSession() {
    var current = session;
    if (current == null) {
      final url = bakalariUrl.trim();
      if (url.isEmpty) {
        throw UserError(t('bak_missing_url'));
      }
      if (username.trim().isEmpty) {
        throw UserError(t('bak_missing_user'));
      }
      if (password.trim().isEmpty) {
        throw UserError(t('bak_missing_password'));
      }
      // Eager like Python (whose constructor argument evaluates now),
      // while the provider still re-reads the password on every login.
      _plainPassword();
      current = BakalariSession(
        url,
        username,
        _plainPassword,
        timeoutS: _seconds('page_load_timeout_s', 60.0),
        userAgent: userAgent,
        isCancelled: _isCancelled,
        logger: log,
        transport: _transportOverride,
      );
      session = current;
    }
    return current;
  }

  /// Logs in unless the session already is; [UserError] when Bakaláři rejects it.
  Future<void> login() async {
    final current = bakalariSession();
    if (current.loggedIn) {
      loggedIn = true;
      return;
    }
    try {
      await current.login();
    } on CancelledError {
      rethrow;
    } catch (e) {
      loggedIn = false;
      log('Login failed: $e');
      rethrow;
    }
    loggedIn = true;
  }

  /// Closes the HTTP session.
  void close() {
    final current = session;
    if (current != null) {
      try {
        current.close();
      } on Object catch (e) {
        debug('closing the Bakaláři HTTP session', e);
      }
      session = null;
    }
  }
}

/// Bakaláři web session: login and requests; data fetching and the
/// excuse form live in the mixins below.
class BakalariClient extends BakalariClientBase
    with TimetableMixin, DataMixin, ExcuseFormMixin {
  BakalariClient(super.configData, {super.logger, super.transport});
}

int _clampInt(Object? value, int fallback, int min, int max) {
  int parsed;
  if (value is int) {
    parsed = value;
  } else if (value is double) {
    if (value.isNaN || value.isInfinite) return fallback;
    parsed = value.truncate();
  } else if (value is bool) {
    parsed = value ? 1 : 0;
  } else {
    parsed = int.tryParse('${value ?? ''}'.trim()) ?? fallback;
  }
  if (parsed < min) return min;
  if (parsed > max) return max;
  return parsed;
}
