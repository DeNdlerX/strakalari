import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package:html_unescape/html_unescape.dart';

import 'package:strakalari_core/src/error_report.dart';
import 'package:strakalari_core/src/i18n.dart' show t;
import 'package:strakalari_core/src/strava/client.dart';
import 'package:strakalari_core/src/strava/extractors.dart';
import 'package:strakalari_core/src/strava/ordering.dart';
import 'package:strakalari_core/src/bakalari/http_session.dart';

const Map<String, Object?> testConfig = {
  'use_strava': true,
  'strava_canteen_id': '1234',
  'strava_username': 'novak',
  'strava_password': 'heslo',
  'strava_blacklist': './strava_blacklist.json',
};

DateTime get day1 =>
    DateTime.now().add(const Duration(days: 7));
DateTime get day2 => day1.add(const Duration(days: 1));

String czDay(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}.${d.month.toString().padLeft(2, '0')}.${d.year}';
String isoDay(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String isoDayBefore(DateTime d, int days) =>
    isoDay(d.subtract(Duration(days: days)));

Map<String, Object?> meal(DateTime day, int ident, String druh,
    String name,
    {int count = 0, Map<String, Object?>? extra}) {
  final m = <String, Object?>{
    'datum': czDay(day),
    'druh': druh,
    'id': ident,
    'pocet': count,
    'cena': '45.00',
    'omezeni': '5E',
    'polevka': 'N',
    'zkratkaProduktu': 'zkratka',
    'druh_popis': 'oběd $ident',
    'nazev': name,
    'alergeny': [
      ['01', 'Obiloviny'],
      ['07', 'Mléko'],
    ],
    'casKonec': '${isoDayBefore(day, 1)}T14:00:00',
    'casOdhlaseni': '${isoDayBefore(day, 1)}T14:00:00',
  };
  if (extra != null) m.addAll(extra);
  return m;
}

Map<String, Object?> soup(DateTime day) => meal(day, 0, 'P', 'polévka',
    extra: {
      'omezeni': 'B',
      'polevka': 'A',
      'cena': '0',
      'casKonec': '9999-12-31T00:00:00',
      'casOdhlaseni': '9999-12-31T00:00:00',
      'alergeny': <Object?>[],
    });

/// app.strava.cz: login, the menu, and saving the order sheet.
class FakeStravaTransport implements HttpTransport {
  Map<String, List<Map<String, Object?>>> menu;
  Map<String, Object?> user;
  String s5url;
  final List<(String, Map<String, Object?>)> requests = [];
  final List<String> saves = [];
  int logins = 0;
  String? sid;
  Object? saveReply;
  bool applySaves = true;
  final Map<String, int> drops = {};

  FakeStravaTransport(
      {Map<String, List<Map<String, Object?>>>? menu,
      Map<String, Object?>? user,
      this.s5url = ''})
      : menu = menu ??
            {
              'table0': [],
              'table1': [],
            },
        user = user ?? {'konto': '100', 'limit': '0.00', 'mena': 'Kč'};

  factory FakeStravaTransport.standard(
      {String konto = '100', String s5url = ''}) {
    final d1 = day1;
    final d2 = day2;
    return FakeStravaTransport(
        menu: {
          'table0': [
            soup(d1),
            meal(d1, 1, '1', 'Guláš', count: 1),
            meal(d1, 2, '2', 'Rizoto'),
          ],
          'table1': [
            soup(d2),
            meal(d2, 1, '1', 'Řízek'),
            meal(d2, 2, '2', 'Těstoviny'),
          ],
        },
        user: {'konto': konto, 'limit': '0.00', 'mena': 'Kč'},
        s5url: s5url);
  }

  HttpResponseData jsonReply(Uri url, Object? obj, {int status = 200}) =>
      HttpResponseData(
          statusCode: status,
          url: url,
          bodyBytes: utf8.encode(jsonEncode(obj)));

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) async {
    final path = url.path;
    final payload = (body == null || body.isEmpty)
        ? <String, Object?>{}
        : (jsonDecode(utf8.decode(body)) as Map)
            .cast<String, Object?>();
    requests.add((path, payload));
    if ((drops[path] ?? 0) > 0) {
      drops[path] = drops[path]! - 1;
      throw SocketException('Server disconnected');
    }
    if (path == '/api/login') {
      if (payload['cislo'] != '1234' ||
          payload['jmeno'] != 'novak' ||
          payload['heslo'] != 'heslo') {
        return jsonReply(url, {
          'state': 'error',
          'number': 1001,
          'message': 'Chybné heslo',
        });
      }
      logins += 1;
      sid = 'sid$logins';
      return jsonReply(url, {
        'sid': sid,
        's5url': s5url,
        'cislo': '1234',
        'ignoreCert': 'false',
        'uzivatel': jsonDecode(jsonEncode(user)),
      });
    }
    if (payload['sid'] != sid) {
      return jsonReply(
          url, {'state': 'error', 'number': 13, 'message': 'Neplatné SID'});
    }
    if (path == '/api/objednavky') {
      return jsonReply(
          url, jsonDecode(jsonEncode(menu)));
    }
    if (path == '/api/saveOrders') {
      saves.add(payload['xml'] as String);
      if (saveReply != null) {
        final r = saveReply;
        if (r is bool) {
          return HttpResponseData(
              statusCode: 200, url: url, bodyBytes: utf8.encode('$r'));
        }
        return jsonReply(url, r);
      }
      if (applySaves) {
        final rows = RegExp(
                r'<datum>([\d-]+)</datum>\s*<druh>(\w)</druh>\s*<pocet>(\d+)</pocet>')
            .allMatches(
                HtmlUnescape().convert(payload['xml'] as String));
        for (final row in rows) {
          final iso = row.group(1)!;
          final druh = row.group(2)!;
          final count = int.parse(row.group(3)!);
          final parsed = DateTime.parse(iso);
          final day = czDay(parsed);
          for (final meals in menu.values) {
            for (final m in meals) {
              if (m['datum'] == day && m['druh'] == druh) {
                m['pocet'] = count;
              }
            }
          }
        }
      }
      return jsonReply(url, {'konto': '55'});
    }
    return HttpResponseData(statusCode: 404, url: url);
  }

  @override
  void close() {}

  List<Map<String, Object?>> calls(String path) =>
      [for (final (p, b) in requests) if (p == path) b];
}

(StravaClient, FakeStravaTransport, List<String>) stravaClient(
    FakeStravaTransport server,
    {Map<String, Object?>? config}) {
  final logs = <String>[];
  final client = StravaClient(
      {...testConfig, ...?config},
      logger: logs.add,
      transport: server);
  return (client, server, logs);
}

// The web app's own builder output for the same three changes
// (tests/fixtures/strava_save_orders.txt).
const String expectedOrderSheet = '&lt;?xml version="1.0" encoding="UTF-8"?&gt;\n'
    '  &lt;VFPData&gt;\n'
    '     &lt;xsd:schema xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:msdata="urn:schemas-microsoft-com:xml-msdata" id="VFPData"&gt;\n'
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
    '     &lt;/xsd:schema&gt;&lt;rozpisobjednavek&gt;\n'
    '&lt;datum&gt;2026-10-07&lt;/datum&gt;\n'
    '&lt;druh&gt;2&lt;/druh&gt;\n'
    '&lt;pocet&gt;1&lt;/pocet&gt;\n'
    '&lt;/rozpisobjednavek&gt;&lt;rozpisobjednavek&gt;\n'
    '&lt;datum&gt;2026-10-07&lt;/datum&gt;\n'
    '&lt;druh&gt;1&lt;/druh&gt;\n'
    '&lt;pocet&gt;0&lt;/pocet&gt;\n'
    '&lt;/rozpisobjednavek&gt;&lt;rozpisobjednavek&gt;\n'
    '&lt;datum&gt;2026-10-08&lt;/datum&gt;\n'
    '&lt;druh&gt;3&lt;/druh&gt;\n'
    '&lt;pocet&gt;0&lt;/pocet&gt;\n'
    '&lt;/rozpisobjednavek&gt;\n'
    '&lt;/VFPData&gt;';

void main() {
  group('blacklist', () {
    test('clientDropsExamplePlaceholders', () {
      final dir =
          Directory.systemTemp.createTempSync('strava_bl_');
      try {
        final bl = File('${dir.path}/strava_blacklist.json');
        bl.writeAsStringSync(
            '["vepro", "VAS_BLACKLIST_X", "your_blacklist_0", '
            '"CISLO_JIDELNY", "example dish"]',
            encoding: utf8);
        final client = StravaClient({
          'use_strava': true,
          'strava_blacklist': bl.path,
        }, logger: (_) {});
        expect(client.stravaBlacklistJson, ['vepro']);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('loginAndMenu', () {
    test('loginAndMenuKeepTheIdsAndTextsOfTheWebPage', () async {
      final (client, server, _) =
          stravaClient(FakeStravaTransport.standard());
      final data = await client.fetchData();
      final login = server.calls('/api/login').single;
      expect(login['environment'], 'W');
      expect(login['zustatPrihlasen'], isFalse);
      final menuCall = server.calls('/api/objednavky').single;
      expect(menuCall['sid'], 'sid1');
      expect(menuCall['s5url'], '');
      expect(menuCall['konto'], 0);
      const weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday'
      ];
      final d1 = day1;
      expect((data['foodDict'] as Map)[czDay(d1)], {
        'table0&-1&0':
            '${weekdays[d1.weekday - 1]} ${d1.day.toString().padLeft(2, '0')}/${d1.month.toString().padLeft(2, '0')}/${d1.year}',
        'table0&1&0': 'oběd 1 - Guláš(01, 07 )',
        'table0&2&0': 'oběd 2 - Rizoto(01, 07 )',
      });
      expect((data['orderedDict'] as Map), {czDay(d1): 'table0&1&0'});
    });

    test('wrongPasswordIsAUserErrorWithStravasReason', () async {
      final (client, _, _) = stravaClient(
          FakeStravaTransport.standard(),
          config: {'strava_password': 'spatne'});
      await expectLater(
          client.login(),
          throwsA(isA<UserError>().having(
              (e) => '$e', 'message', contains('Chybné heslo'))));
    });

    test('stravaServerErrorIsAUserError', () async {
      final client = StravaClient(Map.of(testConfig),
          transport: _StatusTransport(502));
      await expectLater(
          client.login(),
          throwsA(isA<UserError>().having(
              (e) => '$e', 'message', contains('HTTP 502'))));
    });

    test('menuErrorShowsStravasReason', () async {
      final server = FakeStravaTransport.standard();
      final client = StravaClient(Map.of(testConfig),
          logger: (_) {},
          transport: _MenuErrorTransport(server));
      await expectLater(
          client.fetchData(),
          throwsA(isA<UserError>().having(
              (e) => '$e', 'message', contains('Jídelna je uzavřena'))));
    });

    test('droppedSessionLogsInAgainForReads', () async {
      final server = FakeStravaTransport.standard();
      final (client, _, _) = stravaClient(server);
      await client.fetchData();
      server.sid = 'expired';
      await client.fetchData();
      expect(server.logins, 2);
    });

    test('unreachableStravaIsAUserError', () async {
      final client = StravaClient(Map.of(testConfig),
          transport: _ThrowingTransport(
              SocketException('down')));
      await expectLater(client.login(), throwsA(isA<UserError>()));
    });

    test('connectFailureMessagesFollowThePhase', () async {
      // Python: ConnectTimeout is a timeout, ConnectError is "unreachable",
      // any other transport error after connecting is "connection lost".
      Future<String> messageFor(Object error) async {
        final client = StravaClient(Map.of(testConfig),
            transport: _ThrowingTransport(error));
        try {
          await client.login();
        } on UserError catch (e) {
          return e.message;
        }
        return '';
      }

      expect(await messageFor(ConnectFailure(TimeoutException('connect'))),
          timeoutUserMessage());
      expect(
          await messageFor(ConnectFailure(SocketException('refused'))),
          t('strava_unreachable'));
      expect(await messageFor(SocketException('reset after connect')),
          t('strava_connection_lost'));
    });
  });

  group('ordering', () {
    test('orderIsStagedAndSavedOnceAsTheWebAppDoes', () async {
      final (client, server, _) =
          stravaClient(FakeStravaTransport.standard());
      final d1 = day1;
      final d2 = day2;
      await client.fetchData();
      expect(client.order('table1&2&0'), isTrue);
      expect(client.order('table0&2&0'), isTrue);
      expect(server.saves, isEmpty);
      expect(
          await client.saveConfirm(['table1&2&0', 'table0&2&0']),
          isTrue);
      final [sheet] = server.saves;
      final rows = RegExp(
              r'<datum>([\d-]+)</datum>\s*<druh>(\w)</druh>\s*<pocet>(\d+)</pocet>')
          .allMatches(sheet
              .replaceAll('&lt;', '<')
              .replaceAll('&gt;', '>'))
          .map((m) => (m.group(1)!, m.group(2)!, m.group(3)!))
          .toList();
      expect(rows, [
        (isoDay(d2), '2', '1'),
        (isoDay(d1), '2', '1'),
        (isoDay(d1), '1', '0'),
      ]);
      expect(client.orderedDict,
          {czDay(d1): 'table0&2&0', czDay(d2): 'table1&2&0'});
    });

    test('orderSheetMatchesTheWebAppByteForByte', () {
      expect(
          orderSheet([
            {'date': '2026-10-07', 'druh': '2', 'pocet': 1},
            {'date': '2026-10-07', 'druh': '1', 'pocet': 0},
            {'date': '2026-10-08', 'druh': '3', 'pocet': 0},
          ]),
          expectedOrderSheet);
    });

    test('alreadyOrderedMealNeedsNoChange', () async {
      final (client, server, _) =
          stravaClient(FakeStravaTransport.standard());
      await client.fetchData();
      expect(client.order('table0&1&0'), isTrue);
      expect(client.clicksMade, 0);
      expect(await client.saveConfirm(['table0&1&0']), isTrue);
      expect(server.saves, isEmpty);
    });

    test('dayCancelZeroesTheOrderedMeal', () async {
      final (client, server, _) =
          stravaClient(FakeStravaTransport.standard());
      final d1 = day1;
      await client.fetchData();
      expect(client.order('table0&-1&0'), isTrue);
      expect(await client.saveConfirm(['table0&-1&0']), isTrue);
      expect(client.orderedDict.containsKey(czDay(d1)), isFalse);
      expect(server.saves.single, contains('&lt;pocet&gt;0&lt;/pocet&gt;'));
    });

    test('closedOrderWindowStagesNothing', () async {
      final server = FakeStravaTransport.standard();
      server.menu['table1']![2]['casKonec'] = '2000-01-01T00:00:00';
      final (client, _, _) = stravaClient(server);
      await client.fetchData();
      expect(client.order('table1&2&0'), isFalse);
      expect(client.lastNotice, contains('[5010]'));
      expect(client.clicksMade, 0);
    });

    test('lowBalanceIsRefusedBeforeAnythingIsSent', () async {
      final (client, server, _) =
          stravaClient(FakeStravaTransport.standard(konto: '50'));
      await client.fetchData();
      expect(client.order('table1&1&0'), isTrue);
      expect(client.order('table1&2&0'), isTrue);
      expect(client.order('table0&2&0'), isTrue);
      final (client2, _, _) =
          stravaClient(FakeStravaTransport.standard(konto: '40'));
      await client2.fetchData();
      expect(client2.order('table1&1&0'), isFalse);
      expect(client2.insufficientBalance, isTrue);
      expect(client2.lastNotice, contains('[5005]'));
      expect(server.saves, isEmpty);
    });

    test('failedRunDropsTheStagedChanges', () async {
      final (client, server, _) =
          stravaClient(FakeStravaTransport.standard());
      await client.fetchData();
      client.order('table1&1&0');
      client.restoreOriginal([
        {'day': czDay(day2)}
      ], {});
      expect(client.verified('table1&1&0'), isFalse);
      expect(server.saves, isEmpty);
    });

    test('rejectedSaveIsNotSuccess', () async {
      final server = FakeStravaTransport.standard()
        ..saveReply = {
          'state': 'error',
          'number': 5005,
          'message': 'Nedostatečný zůstatek'
        };
      final (client, _, _) = stravaClient(server);
      await client.fetchData();
      client.order('table1&1&0');
      expect(await client.saveConfirm(['table1&1&0']), isFalse);
      expect(client.lastNotice, contains('Nedostatečný'));
      expect(server.saves, hasLength(1));
    });

    test('saveNotShownOnTheMenuIsNotSuccess', () async {
      final server = FakeStravaTransport.standard()..applySaves = false;
      final (client, _, _) = stravaClient(server);
      await client.fetchData();
      client.order('table1&1&0');
      expect(await client.saveConfirm(['table1&1&0']), isFalse);
      expect(server.saves, hasLength(1));
    });

    test('menuDayFoundWhenTheSoupRowHasNoDate', () {
      final d1 = day1;
      final noDateSoup = soup(d1)..remove('datum');
      final (food, _) = menuFromReply({
        'table0': [
          noDateSoup,
          meal(d1, 1, '1', 'Řízek'),
        ]
      });
      expect(food.keys.toList(), [czDay(d1)]);
      expect(food[czDay(d1)]!.containsKey('table0&1&0'), isTrue);
    });

    test('soupsKeptPerDayWithTheirAllergens', () async {
      final d1 = day1;
      final d2 = day2;
      final named = soup(d1)
        ..['nazev'] = 'Frankfurtská'
        ..['alergeny'] = [
          ['01', 'Obiloviny obsahující lepek    '],
          ['07', 'Mléko   '],
        ];
      final noDateSoup = soup(d2)
        ..remove('datum')
        ..['nazev'] = 'Boršč';
      final reply = {
        'table0': [named, meal(d1, 1, '1', 'Řízek')],
        'table1': [noDateSoup, meal(d2, 1, '1', 'Guláš')],
      };
      expect(soupsFromReply(reply), {
        czDay(d1): 'Frankfurtská(01, 07 )',
        czDay(d2): 'Boršč',
      });
      // The soup stays out of the orderable meals.
      final (food, _) = menuFromReply(reply);
      expect(food[czDay(d1)]!.keys, ['table0&-1&0', 'table0&1&0']);
      expect(soupsFromReply('garbage'), isEmpty);

      final (client, _, _) = stravaClient(FakeStravaTransport.standard());
      await client.fetchData();
      expect(client.soupDict, {czDay(d1): 'polévka', czDay(d2): 'polévka'});
    });

    test('newerBackendOrdersNothing', () async {
      final (client, server, _) = stravaClient(
          FakeStravaTransport.standard(
              s5url: 'https://s5.example.test'));
      await client.fetchData();
      expect(client.foodDict, isNotEmpty);
      expect(client.order('table1&1&0'), isFalse);
      expect(server.saves, isEmpty);
    });

    test('droppedConnectionRetriedForReadsNeverForTheSave',
        () async {
      final inner = FakeStravaTransport.standard();
      final drops = {'/api/objednavky': 1, '/api/saveOrders': 1};
      final flaky = _FlakyTransport(inner, drops);
      final client = StravaClient(Map.of(testConfig),
          logger: (_) {}, transport: flaky);
      await client.fetchData();
      expect(client.order('table1&1&0'), isTrue);
      expect(await client.saveConfirm(['table1&1&0']), isFalse);
      expect(inner.saves, isEmpty);
    });
  });
}

class _StatusTransport implements HttpTransport {
  final int status;
  _StatusTransport(this.status);

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) async {
    if (url.path == '/api/login') {
      return HttpResponseData(statusCode: status, url: url);
    }
    return HttpResponseData(statusCode: 404, url: url);
  }

  @override
  void close() {}
}

class _ThrowingTransport implements HttpTransport {
  final Object error;
  _ThrowingTransport(this.error);

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) =>
      Future.error(error);

  @override
  void close() {}
}

class _MenuErrorTransport implements HttpTransport {
  final FakeStravaTransport inner;
  _MenuErrorTransport(this.inner);

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) async {
    if (url.path == '/api/objednavky') {
      return inner.jsonReply(url, {
        'state': 'error',
        'number': 77,
        'message': 'Jídelna je uzavřena',
      });
    }
    return inner.send(method, url,
        headers: headers, body: body, timeout: timeout);
  }

  @override
  void close() {}
}

class _FlakyTransport implements HttpTransport {
  final HttpTransport inner;
  final Map<String, int> drops;
  _FlakyTransport(this.inner, this.drops);

  @override
  Future<HttpResponseData> send(String method, Uri url,
      {Map<String, String>? headers,
      List<int>? body,
      Duration timeout = const Duration(seconds: 60)}) {
    if ((drops[url.path] ?? 0) > 0) {
      drops[url.path] = drops[url.path]! - 1;
      throw SocketException('Server disconnected');
    }
    return inner.send(method, url,
        headers: headers, body: body, timeout: timeout);
  }

  @override
  void close() => inner.close();
}
