// Strava ordering over HTTP: staged changes, one save, verified against a
// fresh menu.
//
// Port of strakalari/core/strava_ordering.py.
//
// Everything here spends or refunds the student's money. Like the web app,
// [OrderingMixin.order] only stages a change (with the page's own checks:
// order deadline, cancel deadline, balance); nothing reaches Strava until
// [OrderingMixin.saveConfirm] posts the changes once and confirms them by
// reloading the menu. A failed run never saves anything.
import 'package:clock/clock.dart';

import '../automation/cancel.dart';
import 'client.dart';

/// Strava's "not enough money on the account" warning (code 5005).
const String lowBalanceCode = '5005';

final RegExp _mealIdRe = RegExp(r'^(table\d+)&(-?\d+)&\d+$');

/// The order sheet the web app saves for canteens on the older backend
/// (``s5url`` empty), entity-encoded exactly as it sends it.
const String _orderSheetHead =
    '&lt;?xml version="1.0" encoding="UTF-8"?&gt;\n  &lt;VFPData&gt;\n'
    '     &lt;xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema" '
    'xmlns:msdata="urn:schemas-microsoft-com:xml-msdata" id="VFPData"&gt;\n'
    '        &lt;xsd:element name="VFPData" msdata:IsDataSet="true"&gt;\n'
    '           &lt;xsd:complexType&gt;\n'
    '              &lt;xsd:choice maxOccurs="unbounded"&gt;\n'
    '                 &lt;xsd:element name="rozpisobjednavek" minOccurs="0" maxOccurs="unbounded"&gt;\n'
    '                    &lt;xsd:complexType&gt;\n'
    '                       &lt;xsd:sequence&gt;\n'
    '                          &lt;xsd:element name="datum" type="xsd:date" /&gt;\n'
    '                          &lt;xsd:element name="druh"&gt;\n'
    '                             &lt;xsd:simpleType&gt;\n'
    '                                &lt;xsd:restriction base="xsd:string"&gt;\n'
    '                                   &lt;xsd:maxLength value="1" /&gt;\n'
    '                                &lt;/xsd:restriction&gt;\n'
    '                             &lt;/xsd:simpleType&gt;\n'
    '                          &lt;/xsd:element&gt;\n'
    '                          &lt;xsd:element name="pocet"&gt;\n'
    '                             &lt;xsd:simpleType&gt;\n'
    '                                &lt;xsd:restriction base="xsd:decimal"&gt;\n'
    '                                   &lt;xsd:totalDigits value="5" /&gt;\n'
    '                                   &lt;xsd:fractionDigits value="0" /&gt;\n'
    '                                &lt;/xsd:restriction&gt;\n'
    '                             &lt;/xsd:simpleType&gt;\n'
    '                          &lt;/xsd:element&gt;\n'
    '                       &lt;/xsd:sequence&gt;\n'
    '                    &lt;/xsd:complexType&gt;\n'
    '                 &lt;/xsd:element&gt;\n'
    '              &lt;/xsd:choice&gt;\n'
    '              &lt;xsd:anyAttribute namespace="http://www.w3.org/XML/1998/namespace" processContents="lax" /&gt;\n'
    '           &lt;/xsd:complexType&gt;\n'
    '        &lt;/xsd:element&gt;\n'
    '     &lt;/xsd:schema&gt;';

/// The ``xml`` of ``/api/saveOrders``: one row (date, meal kind, count)
/// per change.
String orderSheet(List<Map<String, Object?>> changes) {
  final body = StringBuffer();
  for (var i = 0; i < changes.length; i++) {
    body.write(
        '&lt;rozpisobjednavek&gt;\n&lt;datum&gt;${changes[i]['date']}&lt;/datum&gt;\n'
        '&lt;druh&gt;${changes[i]['druh']}&lt;/druh&gt;\n'
        '&lt;pocet&gt;${changes[i]['pocet']}&lt;/pocet&gt;\n'
        '&lt;/rozpisobjednavek&gt;');
  }
  return '$_orderSheetHead$body\n&lt;/VFPData&gt;';
}

double? _number(Object? value, [double? defaultValue]) {
  try {
    return double.parse('$value'.replaceAll(',', '.'));
  } on FormatException {
    return defaultValue;
  }
}

DateTime? _moment(Object? value) => DateTime.tryParse('$value');

/// Ordering on top of [StravaClientBase]'s session.
///
/// Mixin of [StravaClientBase]; uses its session state. The staged-state
/// checks double as the automation's seam (phase 4 calls [order],
/// [verified], [restoreOriginal], [saveConfirm] and reads
/// [noticeSuffix]).
mixin OrderingMixin on StravaClientBase {
  /// `(table, index)` of a menu meal id (`table3&2&0`), or null.
  (String, int)? locateMeal(Object? mealId) {
    final match = _mealIdRe.firstMatch('${mealId ?? ''}');
    if (match == null) return null;
    final table = match.group(1)!;
    final ident = match.group(2)!;
    final meals = menu[table];
    if (meals == null) return null;
    for (var index = 0; index < meals.length; index++) {
      if ('${meals[index]['id']}' == ident) return (table, index);
    }
    return null;
  }

  /// The meal's count with the staged changes applied.
  int stagedCount(String table, int index) {
    for (final change in pending) {
      if (change['table'] == table && change['index'] == index) {
        return change['pocet'] as int;
      }
    }
    return int.tryParse('${menu[table]?[index]['pocet'] ?? 0}') ?? 0;
  }

  void _stage(String table, int index, int count) {
    for (final change in pending) {
      if (change['table'] == table && change['index'] == index) {
        change['pocet'] = count;
        return;
      }
    }
    final original =
        int.tryParse('${menu[table]?[index]['pocet'] ?? 0}') ?? 0;
    pending.add(
        {'table': table, 'index': index, 'pocet': count, 'prev': original});
  }

  /// The account balance with the staged changes paid / refunded (null
  /// when unknown).
  double? _balanceAfterChanges() {
    final balance = _number(user['konto']);
    if (balance == null) return null;
    var result = balance;
    for (final change in pending) {
      final table = change['table'] as String;
      final index = change['index'] as int;
      final price =
          _number(menu[table]?[index]['cena'], 0.0) ?? 0.0;
      result -= ((change['pocet'] as int) - (change['prev'] as int)) *
          price;
    }
    return result;
  }

  /// True when [dayFoodIdentifier] is the day's ordered meal.
  bool isFoodOrdered(Object? dayFoodIdentifier) {
    if (dayFoodIdentifier == null ||
        '$dayFoodIdentifier'.isEmpty ||
        '$dayFoodIdentifier'.contains('&-1&')) {
      // The day control never reads ordered; the day's meals tell.
      return false;
    }
    final where = locateMeal(dayFoodIdentifier);
    return where != null && stagedCount(where.$1, where.$2) > 0;
  }

  /// Staged-state check; never raises.
  bool verified(Object? dayFoodIdentifier) {
    try {
      return isFoodOrdered(dayFoodIdentifier);
    } on Object {
      return false;
    }
  }

  bool _refuse(String code, String text) {
    lastNotice = 'Warning [$code] $text';
    return false;
  }

  bool _supportedBackend() {
    if (s5url.isNotEmpty) {
      // Canteens on the newer backend stage every click on the server
      // (/api/pridejJidloS5); not implemented — never guess with money.
      log("Warning: this canteen uses Strava's newer backend; ordering over HTTP "
          'is not supported for it yet — nothing changed.');
      return false;
    }
    return true;
  }

  /// Stages a whole-day cancel (every ordered meal of the day to 0).
  bool _cancelDay(String table) {
    final meals = menu[table] ?? const [];
    final ordered = [
      for (var i = 0; i < meals.length; i++)
        if (stagedCount(table, i) > 0) i
    ];
    if (ordered.isEmpty) return true;
    if (!_supportedBackend()) return false;
    final now = clock.now();
    for (final index in ordered) {
      final meal = meals[index];
      final deadline = _moment(meal['casOdhlaseni']);
      if (deadline != null && !now.isBefore(deadline)) {
        log("Warning: ${meal['datum']}: the cancel deadline has passed, not cancelling.");
        return _refuse(
            '5011', "${meal['nazev']}: cancelling is closed.");
      }
    }
    for (final index in ordered) {
      _stage(table, index, 0);
    }
    clicksMade += 1;
    return true;
  }

  /// Stages one meal as the day's order (or, for `&-1&`, the day's
  /// cancel).
  ///
  /// True when the wanted state is staged (or already held, with no
  /// change). False — with nothing staged — when the menu does not have
  /// the meal, its order window closed, or the account cannot pay it
  /// ([insufficientBalance]). Nothing is sent before [saveConfirm].
  bool order(Object? dayFoodIdentifier,
      [List<Object?>? allDayIdentifiers]) {
    if (dayFoodIdentifier == null ||
        '$dayFoodIdentifier'.isEmpty) {
      return false;
    }
    lastNotice = '';
    final match = _mealIdRe.firstMatch('$dayFoodIdentifier');
    if (match != null && match.group(2) == '-1') {
      return _cancelDay(match.group(1)!);
    }
    final where = locateMeal(dayFoodIdentifier);
    if (where == null) {
      log('Notice: $dayFoodIdentifier is not on the loaded menu.');
      return false;
    }
    final (table, index) = where;
    if (stagedCount(table, index) > 0) return true;
    if (!_supportedBackend()) return false;
    final meal = menu[table]![index];
    final restriction = '${meal['omezeni'] ?? ''}';
    if (meal['polevka'] == 'A' ||
        restriction.contains('B') ||
        restriction.contains('D')) {
      log('Notice: $dayFoodIdentifier cannot be ordered.');
      return false;
    }
    final now = clock.now();
    final deadline = _moment(meal['casKonec']);
    if (deadline != null && !now.isBefore(deadline)) {
      return _refuse('5010', "${meal['nazev']}: ordering is closed.");
    }
    final others = [
      for (var i = 0; i < menu[table]!.length; i++)
        if (i != index && stagedCount(table, i) > 0) i
    ];
    for (final other in others) {
      final cancelDeadline =
          _moment(menu[table]![other]['casOdhlaseni']);
      if (cancelDeadline != null && !now.isBefore(cancelDeadline)) {
        return _refuse('5011',
            "${menu[table]![other]['nazev']}: changing is closed.");
      }
    }
    if (restriction.contains('E')) {
      // The web app's own check: after paying, the balance must stay
      // at or above the lower of the credit limit and the balance.
      final balance = _balanceAfterChanges();
      final konto = _number(user['konto']);
      final limit = _number(user['limit']);
      final price = _number(meal['cena'], 0.0);
      final refund = others.fold<double>(
          0.0,
          (sum, o) =>
              sum +
              (_number(menu[table]![o]['cena'], 0.0) ?? 0.0) *
                  stagedCount(table, o));
      final floor = konto == null || limit == null
          ? null
          : (limit < konto ? limit : konto);
      if (balance == null ||
          floor == null ||
          balance + refund - (price ?? 0.0) < floor) {
        insufficientBalance = true;
        final currency = '${user['mena'] ?? ''}';
        log('Warning: not enough money on the Strava account for $dayFoodIdentifier '
            '(balance $balance $currency, meal ${meal['cena']} $currency).');
        return _refuse(
            lowBalanceCode, 'Not enough money on the account.');
      }
    }
    _stage(table, index, 1);
    for (final other in others) {
      _stage(table, other, 0);
    }
    clicksMade += 1;
    return true;
  }

  /// Drops every staged change: a failed run never saves anything. Never
  /// raises.
  void restoreOriginal(
      List<Object?> failed, Map<String, Object?> originalOrdered) {
    final dropped = pending.length;
    pending.clear();
    if (dropped > 0) {
      log('Strava: $dropped unsaved change(s) dropped, nothing was saved.');
    }
  }

  /// Truthy: changes are staged until [saveConfirm] saves them.
  bool findSaveButton([int timeoutMs = 0]) => true;

  /// `' — <notice>'` for failure logs (`''` when there is none).
  String noticeSuffix() =>
      lastNotice.isEmpty ? '' : ' — Strava says: $lastNotice';

  // -- Save ---------------------------------------------------------------

  /// `[(date, meal id or null for a cancelled day)]` the save must
  /// produce.
  List<(String, String?)> _wanted(List<String>? verifyIds) {
    final wanted = <(String, String?)>[];
    for (final mealId in verifyIds ?? const <String>[]) {
      final match = _mealIdRe.firstMatch(mealId);
      if (match == null || !menu.containsKey(match.group(1))) continue;
      final meals = menu[match.group(1)]!;
      wanted.add((
        '${meals[0]['datum']}',
        match.group(2) == '-1' ? null : match.group(2)
      ));
    }
    return wanted;
  }

  /// The wanted (date, meal) pairs a fresh menu does NOT show.
  List<(String, String?)> _holds(List<(String, String?)> wanted) {
    final byDay = <String, List<Map<String, Object?>>>{};
    for (final meals in menu.values) {
      if (meals.isNotEmpty) byDay['${meals[0]['datum']}'] = meals;
    }
    final lost = <(String, String?)>[];
    for (final (day, ident) in wanted) {
      final ordered = {
        for (final m in byDay[day] ?? const <Map<String, Object?>>[])
          if ((int.tryParse('${m['pocet'] ?? 0}') ?? 0) > 0)
            '${m['id']}'
      };
      if ((ident == null && ordered.isNotEmpty) ||
          (ident != null && !ordered.contains(ident))) {
        lost.add((day, ident));
      }
    }
    return lost;
  }

  /// Saves the staged changes once; true only when a fresh menu shows
  /// them.
  ///
  /// Fail-closed: nothing to verify, a rejected save, or a menu that
  /// does not show the selections afterwards all return false. The save
  /// is never repeated.
  Future<bool> saveConfirm([List<String>? verifyIds]) async {
    if (verifyIds == null || verifyIds.isEmpty) {
      log('Warning: Strava save_confirm called with nothing to verify — nothing saved.');
      return false;
    }
    final wanted = _wanted(verifyIds);
    if (wanted.length != verifyIds.length) {
      log('Warning: Strava save: a selection is not on the loaded menu — nothing saved.');
      return false;
    }
    final changes = [
      for (final c in pending)
        if (c['pocet'] != c['prev']) c
    ];
    if (changes.isEmpty) {
      log('Strava: the selection already matches the web — nothing to save.');
      return !_holds(wanted).isNotEmpty;
    }
    if (!_supportedBackend()) return false;
    final sheet = orderSheet([
      for (final c in changes)
        {
          'date': '${menu[c['table'] as String]![c['index'] as int]['datum']}'
              .split('.')
              .reversed
              .join('-'),
          'druh': menu[c['table'] as String]![c['index'] as int]['druh']!,
          'pocet': c['pocet']!,
        }
    ]);
    Object? reply;
    try {
      reply = await callApi('/api/saveOrders',
          {...sessionBody(), 'xml': sheet}, relogin: false);
    } on CancelledError {
      rethrow;
    } on StravaError catch (e) {
      lastNotice = e.message;
      log('Warning: Strava did not save the orders (${e.number}): ${e.message}');
      return false;
    } on Object catch (e) {
      log('Warning: Strava save failed (${e.runtimeType}: $e) — checking what went through…');
      reply = null;
    }
    if (reply == false) {
      log("Warning: Strava did not save the orders (it answered 'false').");
      return false;
    }
    pending.clear();
    try {
      await fetchData();
    } on CancelledError {
      rethrow;
    } on Object catch (e) {
      log('Warning: could not reload the Strava menu after saving (${e.runtimeType}: $e) — '
          'the orders may or may not have been saved; check Strava.');
      return false;
    }
    final lost = _holds(wanted);
    if (lost.isNotEmpty) {
      log('Warning: Strava does not show ${lost.length} saved selection(s) after saving: '
          '${lost.map((l) => l.$1).join(', ')} — check Strava.');
      return false;
    }
    log('Strava orders saved (${changes.length} change(s)) and confirmed on the menu.');
    return true;
  }
}
