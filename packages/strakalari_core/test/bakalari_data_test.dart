import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:test/test.dart';

import 'package:strakalari_core/src/bakalari/client.dart';
import 'package:strakalari_core/src/bakalari/http_session.dart';

import 'fake_bakalari.dart';

const String outboxPage = '<html><body><form id="formbaka" method="post" '
    'action="./komens.aspx?l=o">\n'
    '<input type="hidden" name="__VIEWSTATE" value="state-1">\n'
    '<input type="hidden" name="ctl00\$cphmain\$hfListType" id="hfListType" '
    'value="odeslane">\n'
    '<span id="cphmain_obdobiLabel">26.8.2026 - 25.9.2026</span>\n'
    '</form></body></html>';

String outboxListing(List<String> ids, [List<String> other = const ['777']]) {
  final rows = [
    for (final id in ids)
      '<table class="message" data-idmsg="$id" data-msgtype="OMLUVENKA"></table>',
    for (final id in other)
      '<table class="message" data-idmsg="$id" data-msgtype="OBECNA"></table>',
  ].join();
  return dxReply('<div class="komens-messages-wrapper">$rows</div>');
}

String outboxListingWithMarkers(
  List<String> ids, {
  int? loadedCount,
  String? allLoaded,
}) {
  final parts = <String>[
    if (loadedCount != null)
      '<input type="hidden" id="hfLoadedMessagesCount" value="$loadedCount">',
    if (allLoaded != null)
      '<input type="hidden" id="hfAllMessagesLoaded" value="$allLoaded">',
    for (final id in ids)
      '<table class="message" data-idmsg="$id" data-msgtype="OMLUVENKA"></table>',
  ];
  return dxReply('<div class="komens-messages-wrapper">${parts.join()}</div>');
}

Map<String, Object?> excuseDetail(String dayFrom,
    [String? dayTo,
    (int, int)? hours,
    (String, String) times = ('', '')]) {
  final detail = <String, Object?>{
    'Kind': 'OMLUVENKA',
    'DateFrom': dayFrom,
    'DateTo': dayTo ?? dayFrom,
    'TimeFrom': times.$1,
    'TimeTo': times.$2,
  };
  if (hours != null) {
    detail['HourFrom'] = {'Caption': '${hours.$1}'};
    detail['HourTo'] = {'Caption': '${hours.$2}'};
  }
  return detail;
}

Map<String, Object?> outboxRoutes(
    List<String> ids, Map<String, Map<String, Object?>> details) {
  Object? detailHandler(FakeRequest request) {
    final payload = jsonDecode(utf8.decode(request.body)) as Map;
    final data = details['${payload['idmsg']}']!;
    return {'success': true, 'error': null, 'data': data};
  }

  return {
    'GET /next/komens.aspx': outboxPage,
    'POST /next/komens.aspx': outboxListing(ids),
    'POST /Komens/GetMessageDataAsync': detailHandler,
  };
}

void main() {
  BakalariClient client(Map<String, Object?> routes) =>
      BakalariClient(Map.of(fakeConfig),
          transport: FakeBakalari(routes));

  group('fetchData', () {
    test('aSecondRunSeesOnlyFreshData', () async {
      var subject = 'Matematika';
      final logs = <String>[];
      final server = FakeBakalari({
        'POST /Timetable/GetContentData': (FakeRequest req) {
          final payload = jsonDecode(utf8.decode(req.body)) as Map;
          final date = DateTime.parse('${payload['date']}');
          return weekContent([
            {
              'day': '${date.day}.${date.month}.${date.year}',
              'teacher': 'Novák',
              'subjecttext': subject,
              'time': '1 (8:00 - 8:45)',
            }
          ]);
        },
      });
      final bak = BakalariClient(
          {...fakeConfig, 'go_back_weeks': 1, 'go_forward_weeks': 0},
          logger: logs.add, transport: server);
      // Stale state a previous run (or the UI) left behind.
      bak.absencePercentages = {'Stará': 9.0};
      bak.grades = {
        'Stará': [
          {'Grade': '1'}
        ]
      };
      bak.weekChanges = ['stale'];
      final first = await bak.fetchData();
      expect(jsonEncode(first['timetable']), contains('Matematika'));
      expect(first['absence'], isNot(contains('Stará')));
      expect(first['grades'], isNot(contains('Stará')));
      expect(first['changes'], isNot(contains('stale')));

      subject = 'Fyzika';
      final second = await bak.fetchData();
      final text = jsonEncode(second['timetable']);
      expect(text, contains('Fyzika'));
      expect(text, isNot(contains('Matematika')));
    });
  });

  group('sentExcuses', () {
    test('outboxReadsEveryExcuseDetail', () async {
      final bak = client(outboxRoutes(
        ['501', '502'],
        {
          '501': excuseDetail('3.9.2026', null, (3, 3)),
          '502': excuseDetail('10.9.2026', null, (3, 3)),
        },
      ));
      final parsed = await bak.fetchSentExcuses();
      expect(parsed, isNotNull);
      expect(
          {for (final e in parsed!) e['starting_day']},
          {'03.09.2026', '10.09.2026'});
      expect({for (final e in parsed) e['starting_lesson']}, {3});
      expect(bak.sentExcusesError, '');
      expect(
          bak.sentExcusesFrom, DateTime(2026, 8, 26));
    });

    test('wholeDayExcuseIsOneEntry', () async {
      final bak = client(outboxRoutes(
        ['501'],
        {'501': excuseDetail('3.9.2026', '4.9.2026')},
      ));
      expect(await bak.fetchSentExcuses(), [
        {
          'type': 'pure days',
          'starting_day': '03.09.2026',
          'ending_day': '04.09.2026',
        }
      ]);
    });

    test('emptyOutboxIsARealEmptyList', () async {
      final bak = client(outboxRoutes([], {}));
      expect(await bak.fetchSentExcuses(), isEmpty);
      expect(bak.sentExcusesError, '');
    });

    test('rowsWithZeroExcusesFailWhenCachedInPeriodExcusesExist', () async {
      // Listing has message rows (data-idmsg) but 0 recognised OMLUVENKA rows,
      // while knownOutboxDetails holds an excuse dated inside the listed period.
      final cachedDetails = <String, List<Map<String, Object?>>>{
        '501|0:2026-09-10T08:00:00': [
          {
            'type': 'pure days',
            'starting_day': '09.09.2026',
            'ending_day': '09.09.2026',
          }
        ],
      };
      final bak = client(outboxRoutes([], {}))
        ..knownOutboxDetails = Map.of(cachedDetails);
      expect(await bak.fetchSentExcuses(), isNull);
      expect(bak.sentExcuses, isNull);
      expect(bak.sentExcusesFrom, isNull);
      expect(bak.sentExcusesError, isNotEmpty);
      expect(bak.outboxDetailsUpdated, isFalse);
      // Cache must not be wiped on a suspected markup change.
      expect(bak.knownOutboxDetails, equals(cachedDetails));

      // Out-of-period cached excuses do not trigger the sanity check.
      final bakOld = client(outboxRoutes([], {}))
        ..knownOutboxDetails = {
          '401|0:2025-10-01T08:00:00': [
            {
              'type': 'pure days',
              'starting_day': '30.09.2025',
              'ending_day': '30.09.2025',
            }
          ],
        };
      expect(await bakOld.fetchSentExcuses(), isEmpty);

      // One hidden/missing excuse when another excuse is still present still succeeds.
      final bakPartial = client(outboxRoutes(
        ['502'],
        {'502': excuseDetail('12.9.2026')},
      ))
        ..knownOutboxDetails = {
          ...cachedDetails,
          '502|0:2026-09-12T08:00:00': [
            {
              'type': 'pure days',
              'starting_day': '12.09.2026',
              'ending_day': '12.09.2026',
            }
          ],
        };
      final partial = await bakPartial.fetchSentExcuses();
      expect(partial, hasLength(1));
      expect(partial!.single['starting_day'], '12.09.2026');
    });

    test('anotherFolderIsUnknownNotEmpty', () async {
      final routes = outboxRoutes([], {});
      routes['GET /next/komens.aspx'] =
          outboxPage.replaceAll('value="odeslane"', 'value="prijate"');
      final bak = client(routes);
      expect(await bak.fetchSentExcuses(), isNull);
      expect(bak.sentExcusesError.isNotEmpty, isTrue);
    });

    test('outboxListNotLoadingIsUnknownNotEmpty', () async {
      final routes = outboxRoutes([], {});
      routes['POST /next/komens.aspx'] = dxReply('<div>Chyba</div>');
      final bak = client(routes);
      expect(await bak.fetchSentExcuses(), isNull);
      expect(bak.sentExcusesError.isNotEmpty, isTrue);
    });

    test('unparseableOutboxIsUnknownNotEmpty', () async {
      final bak = client({
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': outboxListing(['501']),
        'POST /Komens/GetMessageDataAsync':
            HttpResponseData(statusCode: 500, url: Uri.parse(fakeRoot)),
      });
      expect(await bak.fetchSentExcuses(), isNull);
      expect(bak.sentExcusesError.isNotEmpty, isTrue);
      expect(bak.sentExcuses, isNull);
    });

    test('fetchesWholeSchoolYearPeriodAndPagesCumulatively', () async {
      for (final (total, pageSize, expectedCounts) in [
        (17, 6, [6, 12, 17]),
        (12, 6, [6, 12, 12]),
        (49, 21, [21, 42, 49]),
        (49, 1000, [49]),
      ]) {
        final ids = [for (var i = 1; i <= total; i++) '${5000 + i}'];
        final details = <String, Map<String, Object?>>{
          for (var i = 0; i < total; i++)
            ids[i]: excuseDetail('${(i % 28) + 1}.9.2026'),
        };
        final callbackParams = <Map<String, Object?>>[];
        final server = FakeBakalari({
          'GET /next/komens.aspx': outboxPage.replaceAll(
              '26.8.2026 - 25.9.2026', '20.8.2026 - 31.8.2027'),
          'POST /next/komens.aspx': (FakeRequest req) {
            final form = Uri.splitQueryString(utf8.decode(req.body));
            final raw = form['__CALLBACKPARAM']!.substring(3);
            final cb = jsonDecode(raw) as Map<String, Object?>;
            callbackParams.add(cb);
            final pageNumber = cb['pageNumber'] as int;
            final size = cb['pageSize'] as int;
            final reload = cb['reloadMessages'] as bool;
            final slice =
                reload ? ids.take(size).toList() : ids.take(pageNumber * size).toList();
            final prevEnd = reload ? 0 : (pageNumber - 1) * size;
            final loadedCount = reload
                ? slice.length
                : (slice.length > prevEnd ? slice.length - prevEnd : 0);
            final allLoaded =
                (reload ? ids.length < size : loadedCount == 0) ? 'all' : '';
            return outboxListingWithMarkers(
              slice,
              loadedCount: loadedCount,
              allLoaded: allLoaded,
            );
          },
          'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
            final payload = jsonDecode(utf8.decode(req.body)) as Map;
            return {'success': true, 'error': null, 'data': details['${payload['idmsg']}']!};
          },
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server)
          ..outboxPageSize = pageSize;
        final parsed = await bak.fetchSentExcuses();
        expect(parsed, isNotNull, reason: '$total/$pageSize');
        expect(bak.sentExcusesFrom, DateTime(2026, 8, 20));
        expect(bak.sentExcusesError, '');

        final getCall = server.calls('GET', '/next/komens.aspx').single;
        expect(getCall.url.queryParameters, {'s': 'rok', 'l': 'o'});
        final postCalls = server.calls('POST', '/next/komens.aspx');
        expect(postCalls, hasLength(expectedCounts.length));
        for (final p in postCalls) {
          expect(p.url.queryParameters, {'s': 'rok', 'l': 'o'});
        }
        expect([for (final cb in callbackParams) cb['pageNumber']],
            [for (var i = 1; i <= expectedCounts.length; i++) i]);
        expect([for (final cb in callbackParams) cb['reloadMessages']],
            [true, for (var i = 1; i < expectedCounts.length; i++) false]);
        expect(
            server.calls('POST', '/Komens/GetMessageDataAsync'),
            hasLength(total));
        expect(
            {for (final e in parsed!) e['starting_day']},
            hasLength(total >= 28 ? 28 : total));
      }
    });

    test('mixedMessageTypesStillTriggerNextPage', () async {
      final rows = [
        ('101', 'OMLUVENKA'),
        ('102', 'OBECNA'),
        ('103', 'OMLUVENKA'),
        ('104', 'OBECNA'),
        ('105', 'OMLUVENKA'),
        ('106', 'OBECNA'),
        ('107', 'OMLUVENKA'),
      ];
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': (FakeRequest req) {
          final form = Uri.splitQueryString(utf8.decode(req.body));
          final cb = jsonDecode(form['__CALLBACKPARAM']!.substring(3)) as Map;
          final pageNumber = cb['pageNumber'] as int;
          final size = cb['pageSize'] as int;
          final reload = cb['reloadMessages'] as bool;
          final shown =
              reload ? rows.take(size) : rows.take(pageNumber * size);
          final html = [
            for (final (id, kind) in shown)
              '<table class="message" data-idmsg="$id" data-msgtype="$kind"></table>',
          ].join();
          return dxReply('<div class="komens-messages-wrapper">$html</div>');
        },
        'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
          final id = '${(jsonDecode(utf8.decode(req.body)) as Map)['idmsg']}';
          return {
            'success': true,
            'error': null,
            'data': excuseDetail('${int.parse(id) - 90}.9.2026'),
          };
        },
      });
      final bak = BakalariClient(Map.of(fakeConfig), transport: server)
        ..outboxPageSize = 6;
      final parsed = await bak.fetchSentExcuses();
      expect(parsed, hasLength(4));
      expect(server.calls('POST', '/next/komens.aspx'), hasLength(2));
      expect(
          {for (final e in parsed!) e['starting_day']},
          {'11.09.2026', '13.09.2026', '15.09.2026', '17.09.2026'});
    });

    test('pageTwoFailureOrDetailFailureFailsWholeRead', () async {
      // Page 2 returns 500 -> whole read fails (null), not partial page 1.
      var listCalls = 0;
      final bakPageFail = BakalariClient(
        Map.of(fakeConfig),
        transport: FakeBakalari({
          'GET /next/komens.aspx': outboxPage,
          'POST /next/komens.aspx': (_) {
            listCalls++;
            if (listCalls == 1) {
              return outboxListing(['501', '502'], const []);
            }
            return HttpResponseData(statusCode: 500, url: Uri.parse(fakeRoot));
          },
          'POST /Komens/GetMessageDataAsync': (_) =>
              {'success': true, 'error': null, 'data': excuseDetail('3.9.2026')},
        }),
      )..outboxPageSize = 2;
      expect(await bakPageFail.fetchSentExcuses(), isNull);
      expect(bakPageFail.sentExcuses, isNull);
      expect(bakPageFail.sentExcusesFrom, isNull);
      expect(bakPageFail.sentExcusesError, isNotEmpty);

      // Page 2 returns invalid wrapper -> whole read fails.
      var listCalls2 = 0;
      final bakBadWrapper = BakalariClient(
        Map.of(fakeConfig),
        transport: FakeBakalari({
          'GET /next/komens.aspx': outboxPage,
          'POST /next/komens.aspx': (_) {
            listCalls2++;
            return listCalls2 == 1
                ? outboxListing(['501', '502'], const [])
                : dxReply('<div>error</div>');
          },
        }),
      )..outboxPageSize = 2;
      expect(await bakBadWrapper.fetchSentExcuses(), isNull);
      expect(bakBadWrapper.sentExcuses, isNull);
      expect(bakBadWrapper.sentExcusesFrom, isNull);

      // Detail #1 cached, detail #2 returns 500 -> whole read fails (no partial).
      final bakDetailFail = BakalariClient(
        Map.of(fakeConfig),
        transport: FakeBakalari({
          'GET /next/komens.aspx': outboxPage,
          'POST /next/komens.aspx': outboxListing(['501', '502'], const []),
          'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
            final id = '${(jsonDecode(utf8.decode(req.body)) as Map)['idmsg']}';
            if (id == '502') {
              return HttpResponseData(statusCode: 500, url: Uri.parse(fakeRoot));
            }
            return {'success': true, 'error': null, 'data': excuseDetail('3.9.2026')};
          },
        }),
      )..knownOutboxDetails = {
          '501': [
            {
              'type': 'pure days',
              'starting_day': '03.09.2026',
              'ending_day': '03.09.2026',
            }
          ]
        };
      expect(await bakDetailFail.fetchSentExcuses(), isNull);
      expect(bakDetailFail.sentExcuses, isNull);
      expect(bakDetailFail.sentExcusesFrom, isNull);
      expect(bakDetailFail.sentExcusesError, isNotEmpty);
    });

    test('explicitPositiveLimitFailsClosedWhenExceeded', () async {
      final ids = ['501', '502', '503', '504', '505', '506'];
      final bak = client(outboxRoutes(ids, {
        for (final id in ids) id: excuseDetail('3.9.2026'),
      }));
      expect(await bak.fetchSentExcuses(limit: 5), isNull);
      expect(bak.sentExcuses, isNull);
      expect(bak.sentExcusesFrom, isNull);
      expect(bak.sentExcusesError, contains('limit 5'));
    });

    test('positiveLimitReadsNewestAndNarrowsSentExcusesFrom (R4 Q1)', () async {
      final rows = [
        ('606', '0:2026-11-10T08:00:00', '09.11.2026'),
        ('605', '0:2026-11-05T08:00:00', '04.11.2026'),
        ('604', '0:2026-10-28T08:00:00', '27.10.2026'),
        ('603', '0:2026-10-20T08:00:00', '19.10.2026'),
        ('602', '0:2026-10-15T08:00:00', '14.10.2026'),
        ('601', '0:2026-09-10T08:00:00', '09.09.2026'),
      ];
      final details = {for (final r in rows) r.$1: excuseDetail(r.$3)};
      final html = [
        for (final r in rows)
          '<table class="message" data-idmsg="${r.$1}" data-sortdate="${r.$2}" data-msgtype="OMLUVENKA"></table>',
      ].join();

      final logs = <String>[];
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage.replaceAll(
            '26.8.2026 - 25.9.2026', '20.8.2026 - 31.8.2027'),
        'POST /next/komens.aspx':
            dxReply('<div class="komens-messages-wrapper">$html</div>'),
        'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
          final id = '${(jsonDecode(utf8.decode(req.body)) as Map)['idmsg']}';
          return {'success': true, 'error': null, 'data': details[id]!};
        },
      });
      final bak = BakalariClient(Map.of(fakeConfig),
          logger: logs.add, transport: server);
      final parsed = await bak.fetchSentExcuses(limit: 5);
      expect(parsed, isNotNull);
      expect(parsed, hasLength(5));
      final detailCalls = server.calls('POST', '/Komens/GetMessageDataAsync');
      expect(detailCalls, hasLength(5));
      final requestedIds = [
        for (final c in detailCalls)
          '${(jsonDecode(utf8.decode(c.body)) as Map)['idmsg']}'
      ];
      expect(requestedIds, isNot(contains('601')));
      expect(bak.sentExcusesFrom, DateTime(2026, 10, 15));
      expect(bak.sentExcusesError, '');
      expect(
          logs.any((l) => l.contains('15.10.2026') && l.contains('5')), isTrue);

      // When periodStart is already later than the 5th newest sent date,
      // sentExcusesFrom stays clamped to periodStart (never widens earlier).
      final serverLaterPeriod = FakeBakalari({
        'GET /next/komens.aspx': outboxPage.replaceAll(
            '26.8.2026 - 25.9.2026', '20.10.2026 - 31.8.2027'),
        'POST /next/komens.aspx':
            dxReply('<div class="komens-messages-wrapper">$html</div>'),
        'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
          final id = '${(jsonDecode(utf8.decode(req.body)) as Map)['idmsg']}';
          return {'success': true, 'error': null, 'data': details[id]!};
        },
      });
      final bakLater =
          BakalariClient(Map.of(fakeConfig), transport: serverLaterPeriod);
      expect(await bakLater.fetchSentExcuses(limit: 5), hasLength(5));
      expect(bakLater.sentExcusesFrom, DateTime(2026, 10, 20));
    });

    test('limitCutInsideADayStartsTheWindowTheDayAfter (R4 S5)', () async {
      // Newest first. Limit 2 reads 603 and 602; 601 was sent the same day
      // as 602, earlier, and is not read, so 5.11. is not read completely.
      final rows = [
        ('603', '0:2026-11-10T10:00:00', '10.11.2026'),
        ('602', '0:2026-11-05T12:00:00', '04.11.2026'),
        ('601', '0:2026-11-05T09:00:00', '05.11.2026'),
      ];
      final details = {for (final r in rows) r.$1: excuseDetail(r.$3)};
      final html = [
        for (final r in rows)
          '<table class="message" data-idmsg="${r.$1}" data-sortdate="${r.$2}" data-msgtype="OMLUVENKA"></table>',
      ].join();
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage.replaceAll(
            '26.8.2026 - 25.9.2026', '20.8.2026 - 31.8.2027'),
        'POST /next/komens.aspx':
            dxReply('<div class="komens-messages-wrapper">$html</div>'),
        'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
          final id = '${(jsonDecode(utf8.decode(req.body)) as Map)['idmsg']}';
          return {'success': true, 'error': null, 'data': details[id]!};
        },
      });
      final bak = BakalariClient(Map.of(fakeConfig), transport: server);
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 0)), () async {
        expect(await bak.fetchSentExcuses(limit: 2), hasLength(2));
      });
      expect(bak.sentExcusesFrom, DateTime(2026, 11, 6));
      final requestedIds = [
        for (final c in server.calls('POST', '/Komens/GetMessageDataAsync'))
          '${(jsonDecode(utf8.decode(c.body)) as Map)['idmsg']}'
      ];
      expect(requestedIds, ['603', '602']);
    });

    test('limitCutFailsClosedWhenTheFirstUnreadDayIsTodayOrUnknown (R4 S5)',
        () async {
      Future<void> read(String html) async {
        final server = FakeBakalari({
          'GET /next/komens.aspx': outboxPage.replaceAll(
              '26.8.2026 - 25.9.2026', '20.8.2026 - 31.8.2027'),
          'POST /next/komens.aspx':
              dxReply('<div class="komens-messages-wrapper">$html</div>'),
          'POST /Komens/GetMessageDataAsync': (_) => {
                'success': true,
                'error': null,
                'data': excuseDetail('19.11.2026'),
              },
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server);
        await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 0)), () async {
          expect(await bak.fetchSentExcuses(limit: 1), isNull);
        });
        expect(bak.sentExcuses, isNull);
        expect(bak.sentExcusesFrom, isNull);
        expect(bak.sentExcusesError, contains('limit 1'));
        expect(server.calls('POST', '/Komens/GetMessageDataAsync'), isEmpty);
      }

      // Both sent today: the day after the unread one is tomorrow.
      await read(
          '<table data-idmsg="702" data-sortdate="0:2026-11-20T09:00:00" data-msgtype="OMLUVENKA"></table>'
          '<table data-idmsg="701" data-sortdate="0:2026-11-20T08:00:00" data-msgtype="OMLUVENKA"></table>');
      // The first unread one has no sent date.
      await read(
          '<table data-idmsg="702" data-sortdate="0:2026-11-18T09:00:00" data-msgtype="OMLUVENKA"></table>'
          '<table data-idmsg="701" data-msgtype="OMLUVENKA"></table>');
    });

    test('detailCacheSkipsKnownMessagesAndFetchesNewOnesOnly', () async {
      var includeThird = false;
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': (_) {
          final rows = [
            '<table data-idmsg="501" data-sortdate="0:2026-09-04T08:00:00" data-msgtype="OMLUVENKA"></table>',
            '<table data-idmsg="502" data-sortdate="0:2026-09-11T08:00:00" data-msgtype="OMLUVENKA"></table>',
            if (includeThird)
              '<table data-idmsg="503" data-sortdate="0:2026-09-18T08:00:00" data-msgtype="OMLUVENKA"></table>',
          ].join();
          return dxReply('<div class="komens-messages-wrapper">$rows</div>');
        },
        'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
          final id = '${(jsonDecode(utf8.decode(req.body)) as Map)['idmsg']}';
          final day = id == '501'
              ? '3.9.2026'
              : (id == '502' ? '10.9.2026' : '17.9.2026');
          return {'success': true, 'error': null, 'data': excuseDetail(day)};
        },
      });
      final bak = BakalariClient(Map.of(fakeConfig), transport: server);
      final first = await bak.fetchSentExcuses();
      expect(first, hasLength(2));
      expect(server.calls('POST', '/Komens/GetMessageDataAsync'), hasLength(2));
      expect(bak.outboxDetailsUpdated, isTrue);
      expect(bak.knownOutboxDetails.keys.toSet(), {
        '501|0:2026-09-04T08:00:00',
        '502|0:2026-09-11T08:00:00',
      });

      includeThird = true;
      final second = await bak.fetchSentExcuses();
      expect(second, hasLength(3));
      final detailCalls = server.calls('POST', '/Komens/GetMessageDataAsync');
      expect(detailCalls, hasLength(3));
      expect((jsonDecode(utf8.decode(detailCalls.last.body)) as Map)['idmsg'],
          '503');
    });

    test('aDetailThatGaveNoEntriesIsReadAgainNextSync (R4 M1)', () async {
      var good = false;
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': outboxListing(['501'], const []),
        'POST /Komens/GetMessageDataAsync': (FakeRequest _) => {
              'success': true,
              'error': null,
              'data': good ? excuseDetail('3.9.2026') : null,
            },
      });
      final bak = BakalariClient(Map.of(fakeConfig), transport: server);
      expect(await bak.fetchSentExcuses(), isEmpty);
      expect(bak.knownOutboxDetails.containsKey('501'), isFalse);
      good = true;
      expect(await bak.fetchSentExcuses(), [
        {
          'type': 'pure days',
          'starting_day': '03.09.2026',
          'ending_day': '03.09.2026',
        }
      ]);
      expect(server.calls('POST', '/Komens/GetMessageDataAsync'), hasLength(2));
    });

    test('pageTwoRepeatingPageOneFailsOutboxRead (R4 S1)', () async {
      var calls = 0;
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': (_) {
          calls++;
          return outboxListingWithMarkers(
            const ['501', '502', '503', '504'],
            loadedCount: 4,
            allLoaded: '',
          );
        },
        'POST /Komens/GetMessageDataAsync': (_) =>
            {'success': true, 'error': null, 'data': excuseDetail('3.9.2026')},
      });
      final bak = BakalariClient(Map.of(fakeConfig), transport: server)
        ..outboxPageSize = 4;
      expect(await bak.fetchSentExcuses(), isNull);
      expect(bak.sentExcusesError, contains('no progress'));
      expect(calls, 2);
    });

    test('nonCumulativePagesFailOutboxRead (R4 S1)', () async {
      var calls = 0;
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': (_) {
          calls++;
          return outboxListingWithMarkers(
            calls == 1
                ? const ['501', '502', '503', '504']
                : const ['505', '506', '507', '508'],
            loadedCount: 4,
            allLoaded: '',
          );
        },
        'POST /Komens/GetMessageDataAsync': (_) =>
            {'success': true, 'error': null, 'data': excuseDetail('3.9.2026')},
      });
      final bak = BakalariClient(Map.of(fakeConfig), transport: server)
        ..outboxPageSize = 4;
      expect(await bak.fetchSentExcuses(), isNull);
      expect(bak.sentExcusesError, isNotEmpty);
      expect(calls, 2);
    });

    test('exactMultipleEndsWhenOverflowPageCarriesEndMarkers (R4 S1)',
        () async {
      final ids = [for (var i = 1; i <= 12; i++) '${500 + i}'];
      for (final (loadedCount, allLoaded, shouldSucceed) in [
        (0, 'all', true),
        (null, 'all', true),
        (0, '', true),
        (null, null, false),
      ]) {
        final server = FakeBakalari({
          'GET /next/komens.aspx': outboxPage,
          'POST /next/komens.aspx': (FakeRequest req) {
            final form = Uri.splitQueryString(utf8.decode(req.body));
            final cb = jsonDecode(form['__CALLBACKPARAM']!.substring(3)) as Map;
            final pageNumber = cb['pageNumber'] as int;
            if (pageNumber == 1) {
              return outboxListingWithMarkers(
                ids.take(6).toList(),
                loadedCount: 6,
                allLoaded: '',
              );
            }
            if (pageNumber == 2) {
              return outboxListingWithMarkers(
                ids,
                loadedCount: 6,
                allLoaded: '',
              );
            }
            return outboxListingWithMarkers(
              ids,
              loadedCount: loadedCount,
              allLoaded: allLoaded,
            );
          },
          'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
            final id =
                int.parse('${(jsonDecode(utf8.decode(req.body)) as Map)['idmsg']}');
            return {
              'success': true,
              'error': null,
              'data': excuseDetail('${id - 500}.9.2026'),
            };
          },
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server)
          ..outboxPageSize = 6;
        final parsed = await bak.fetchSentExcuses();
        if (shouldSucceed) {
          expect(parsed, hasLength(12),
              reason: 'markers: ($loadedCount, $allLoaded)');
          expect(server.calls('POST', '/next/komens.aspx'), hasLength(3));
        } else {
          expect(parsed, isNull);
          expect(bak.sentExcusesError, contains('no progress'));
        }
      }
    });

    test('pageTwoMissingAnIdFromPageOneFailsOutboxRead (R4 S1)', () async {
      var calls = 0;
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': (_) {
          calls++;
          return outboxListingWithMarkers(
            calls == 1
                ? const ['501', '502', '503', '504']
                : const ['502', '503', '504', '505', '506'],
            loadedCount: 4,
            allLoaded: '',
          );
        },
        'POST /Komens/GetMessageDataAsync': (_) =>
            {'success': true, 'error': null, 'data': excuseDetail('3.9.2026')},
      });
      final bak = BakalariClient(Map.of(fakeConfig), transport: server)
        ..outboxPageSize = 4;
      expect(await bak.fetchSentExcuses(), isNull);
      expect(bak.sentExcusesError, contains('not cumulative'));
      expect(calls, 2);
    });

    test('fetchAllOutboxIdsThrowsPastMaxPages (R4 S1)', () async {
      final server = FakeBakalari({
        'GET /next/komens.aspx': outboxPage,
        'POST /next/komens.aspx': (FakeRequest req) {
          final form = Uri.splitQueryString(utf8.decode(req.body));
          final cb = jsonDecode(form['__CALLBACKPARAM']!.substring(3)) as Map;
          final pageNumber = cb['pageNumber'] as int;
          final size = cb['pageSize'] as int;
          final ids = [
            for (var i = 1; i <= pageNumber * size; i++) '${500 + i}'
          ];
          return outboxListingWithMarkers(
            ids,
            loadedCount: size,
            allLoaded: '',
          );
        },
      });
      final bak = BakalariClient(Map.of(fakeConfig), transport: server);
      await expectLater(
        bak.fetchAllOutboxIds(bak.bakalariSession(), pageSize: 2, maxPages: 3),
        throwsA(isA<StateError>()),
      );
      expect(server.calls('POST', '/next/komens.aspx'), hasLength(3));
    });
  });

  group('absence', () {
    const absencePage = '<html><body><script>\n'
        'var DatesInformations = ko.mapping.fromJS('
        '{"DefaultDateFrom": {"DefaultValue": "2026-09-01T00:00:00+02:00"},\n'
        '  "DefaultDateTo": {"DefaultValue": "2026-09-15T00:00:00+02:00"}});\n'
        '</script></body></html>';

    final rows = [
      {
        'Name': 'Matematika',
        'LessonCount': 8,
        'Count': 2,
        'Percent': 0.25,
      },
      {
        'Name': 'Fyzika',
        'LessonCount': 6,
        'Count': 0,
        'Percent': 0,
      },
      {
        'Name': 'Celkem',
        'LessonCount': 14,
        'Count': 2,
        'Percent': 0.14,
      },
    ];

    test('parsesTheSubjectRows', () async {
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 0)), () async {
        for (final reply in [
          {'data': rows, 'totalCount': 3},
          rows,
        ]) {
          final server = FakeBakalari({
            'GET /Absence/Continuous': absencePage,
            'GET /Absence/Continuous/GetAbsenceBySubjects': reply,
          });
          final bak = BakalariClient(
              Map.of(fakeConfig), transport: server);
          await bak.obtainAbsenceInfo();
          expect(bak.absenceError, '');
          expect(bak.absencePercentages,
              {'Matematika': 25.0, 'Fyzika': 0.0});
          expect(
              (bak.absenceDetails['Matematika'] as Map)['missed_hours'], 2);
          final calls = server.calls(
              'GET', '/Absence/Continuous/GetAbsenceBySubjects');
          expect(calls, hasLength(1));
          expect(calls.single.url.queryParameters['dateFrom'], '2026-09-01');
          expect(calls.single.url.queryParameters['dateTo'], '2026-11-20');
          // F6 §4.2: zero GET /Absence/Continuous page loads on the direct path.
          expect(server.calls('GET', '/Absence/Continuous'), isEmpty);
        }
      });
    });

    test('directAbsenceDateFromBoundaryAug31VsSep1AndFallbacks (R8a S7)',
        () async {
      // 31 August 2026 -> 2025-09-01 (previous school year).
      await withClock(Clock.fixed(DateTime(2026, 8, 31, 10, 0)), () async {
        final server = FakeBakalari({
          'GET /Absence/Continuous/GetAbsenceBySubjects': {'data': rows},
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server);
        await bak.obtainAbsenceInfo();
        final req =
            server.calls('GET', '/Absence/Continuous/GetAbsenceBySubjects').single;
        expect(req.url.queryParameters['dateFrom'], '2025-09-01');
        expect(req.url.queryParameters['dateTo'], '2026-08-31');
      });

      // 1 September 2026 -> 2026-09-01 (new school year).
      await withClock(Clock.fixed(DateTime(2026, 9, 1, 10, 0)), () async {
        final server = FakeBakalari({
          'GET /Absence/Continuous/GetAbsenceBySubjects': {'data': rows},
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server);
        await bak.obtainAbsenceInfo();
        final req =
            server.calls('GET', '/Absence/Continuous/GetAbsenceBySubjects').single;
        expect(req.url.queryParameters['dateFrom'], '2026-09-01');
        expect(req.url.queryParameters['dateTo'], '2026-09-01');
      });

      // Empty direct reply while cache had subjects -> falls back to /Absence/Continuous.
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 0)), () async {
        var jsonCalls = 0;
        final server = FakeBakalari({
          'GET /Absence/Continuous': absencePage,
          'GET /Absence/Continuous/GetAbsenceBySubjects': (_) {
            jsonCalls++;
            return jsonCalls == 1 ? {'data': <Object?>[]} : {'data': rows};
          },
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server);
        await bak.obtainAbsenceInfo(cachedHasSubjects: true);
        expect(bak.absenceDirectFailed, isTrue);
        expect(server.calls('GET', '/Absence/Continuous'), hasLength(1));
        expect(bak.absencePercentages, {'Matematika': 25.0, 'Fyzika': 0.0});
      });

      // With allowPageFallback: false (throttled quick tick), skips page load.
      await withClock(Clock.fixed(DateTime(2026, 11, 20, 10, 0)), () async {
        final server = FakeBakalari({
          'GET /Absence/Continuous': absencePage,
          'GET /Absence/Continuous/GetAbsenceBySubjects':
              HttpResponseData(statusCode: 500, url: Uri.parse(fakeRoot)),
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server);
        await bak.obtainAbsenceInfo(allowPageFallback: false);
        expect(bak.absenceDirectFailed, isTrue);
        expect(bak.absenceError, isNotEmpty);
        expect(server.calls('GET', '/Absence/Continuous'), isEmpty);
      });
    });

    test('replyWithoutRowsIsFlagged', () async {
      final bak = client({
        'GET /Absence/Continuous': absencePage,
        'GET /Absence/Continuous/GetAbsenceBySubjects':
            {'unexpected': 1},
      });
      await bak.obtainAbsenceInfo();
      expect(bak.absencePercentages, isEmpty);
      expect(bak.absenceError.isNotEmpty, isTrue);
    });
  });

  group('substitutions', () {
    test('areParsedFromTheWeekReply', () async {
      final server = FakeBakalari({
        'POST /Timetable/substitutions/dates': {
          'success': true,
          'data': [
            {
              'Changes': [
                {
                  'Day': 'pondělí 7.9.2026',
                  'HourLabel': '3. hod',
                  'TimeLabel': '9:50 - 10:35',
                  'ChangeType': 'Canceled',
                  'Description': 'Odpadá',
                  'ChangeLessonInfo': {
                    'ClassAbbrev': '4.A',
                    'IsClassGroup': true,
                    'SubjectAbbrev': 'M',
                    'RoomAbbrev': '104',
                  }
                }
              ]
            }
          ]
        },
      });
      final bak = BakalariClient(
          Map.of(fakeConfig), transport: server);
      expect(await bak.fetchSubstitutions(), [
        {
          'day': '7.9.2026',
          'period': 3,
          'time': '9:50 - 10:35',
          'badge': 'O',
          'info': '4.A | M | 104',
          'subject_short': 'M',
          'description': 'Odpadá',
        }
      ]);
      final calls = server.calls(
          'POST', '/Timetable/substitutions/dates');
      expect(calls, hasLength(1));
      final form = Uri.splitQueryString(utf8.decode(calls.single.body));
      expect(form.keys.toSet(), {'dateFrom', 'dateTo'});
    });

    test('failedSubstitutionsAreUnknown', () async {
      final bak = client({
        'POST /Timetable/substitutions/dates': {
          'success': false,
          'error': 'x',
        },
      });
      expect(await bak.fetchSubstitutions(), isNull);
      expect(bak.substitutionsError.isNotEmpty, isTrue);
    });
  });

  group('grades', () {
    String mark(String subject, String grade, Object? weight, String date) {
      final blob = jsonEncode({
        'nazev': subject,
        'MarkText': grade,
        'vaha': weight,
        'udel_datum': date,
      });
      final esc = blob
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;')
          .replaceAll('"', '&quot;');
      return '<div data-clasif="$esc"></div>';
    }

    String gradesPage(String marksHtml) =>
        '<html><body><form id="formbaka" method="post" '
        'action="./prubzna.aspx">$marksHtml</form></body></html>';

    test('fetchesParsesAndSorts', () async {
      final html = mark('Matematika', '3', 10, '12.09.2026') +
          mark('Matematika', '1', 10, '05.09.2026') +
          mark('Fyzika', '2', 5, '06.09.2026');
      final server = FakeBakalari({
        'GET /next/prubzna.aspx': gradesPage(html),
      });
      final bak = BakalariClient(
          Map.of(fakeConfig), transport: server);
      final data = await bak.getGrades();
      expect(
          [for (final m in data['Matematika']!) m['Date']],
          ['05.09.2026', '12.09.2026']);
      expect(data['Fyzika'],
          [{'Grade': '2', 'Weight': 5, 'Date': '06.09.2026'}]);
      expect(bak.grades, data);
      expect(bak.gradesError, '');
      expect(server.calls('GET', '/next/prubzna.aspx'), hasLength(1));
    });

    test('failureKeepsErrorWithoutRaising', () async {
      final bak = client({
        'GET /next/prubzna.aspx':
            HttpResponseData(statusCode: 500, url: Uri.parse(fakeRoot)),
      });
      expect(await bak.getGrades(), isEmpty);
      expect(bak.gradesError, contains('HTTP 500'));
    });

    test('emptyOtherPageIsAnErrorNotNoMarks', () async {
      final bak = client({
        'GET /next/prubzna.aspx': '<html>Chyba serveru</html>',
      });
      expect(await bak.getGrades(), isEmpty);
      expect(bak.gradesError.isNotEmpty, isTrue);
    });
  });

  group('subjectDirectory', () {
    test('fetchesDirectory', () async {
      final bak = client({
        'POST /Teaching/Subjects': {
          'data': [
            {
              'SubjectName': 'Matematika',
              'TeacherName': 'Mgr. Jan Novák',
            }
          ]
        },
      });
      expect(await bak.fetchSubjectDirectory(),
          {'Matematika': 'Mgr. Jan Novák'});
    });

    test('expiredSessionLogsInAgainAndRetriesOnce', () async {
      final server = FakeBakalari({
        'POST /Teaching/Subjects': {
          'data': [
            {
              'SubjectName': 'Matematika',
              'TeacherName': 'Mgr. Jan Novák',
            }
          ]
        },
      });
      final bak = BakalariClient(
          Map.of(fakeConfig), transport: server);
      await bak.login();
      server.expireSession();
      expect(await bak.fetchSubjectDirectory(),
          {'Matematika': 'Mgr. Jan Novák'});
      expect(server.logins, 2);
    });
  });

  group('f6Step1FreeWins', () {
    test('cachedOutboxFieldsSkipPageWhenCompleteAndReloadWhenShort (R8a M1, S6)',
        () async {
      final now = DateTime(2026, 11, 20, 10, 0);
      await withClock(Clock.fixed(now), () async {
        // Simulate server where a 3-field callback (missing hfListType) returns
        // only the recent 30-day excuse 202, dropping older excuse 101 (Sep 10).
        final server = FakeBakalari({
          'GET /next/komens.aspx': outboxPageHtml(
            periodLabel: '20.8.2026 - 31.8.2027',
          ),
          'POST /next/komens.aspx': (FakeRequest req) {
            final form = Uri.splitQueryString(utf8.decode(req.body));
            final isFullForm = form.containsKey('ctl00\$cphmain\$hfListType');
            final rows = isFullForm
                ? '<table data-idmsg="202" data-sortdate="0:2026-11-10T08:00:00" data-msgtype="OMLUVENKA"></table>'
                  '<table data-idmsg="101" data-sortdate="0:2026-09-10T08:00:00" data-msgtype="OMLUVENKA"></table>'
                : '<table data-idmsg="202" data-sortdate="0:2026-11-10T08:00:00" data-msgtype="OMLUVENKA"></table>';
            return dxReply('<div class="komens-messages-wrapper">$rows</div>');
          },
          'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
            final body = jsonDecode(utf8.decode(req.body)) as Map;
            final id = '${body['idmsg']}';
            final day = id == '101' ? '10.09.2026' : '10.11.2026';
            return {
              'Kind': 'OMLUVENKA',
              'DateFrom': day,
              'DateTo': day,
            };
          },
        });

        // 1. First read (manual or cold cache) loads the full page and caches 3 fields.
        final bak = BakalariClient(Map.of(fakeConfig), transport: server);
        final first = await bak.fetchSentExcuses(useCachedForm: true);
        expect(first, hasLength(2));
        expect(server.calls('GET', '/next/komens.aspx'), hasLength(1));
        expect(bak.outboxFormUpdated, isTrue);
        expect(bak.knownOutboxForm?['period_start'], '2026-08-20');
        expect(bak.knownOutboxForm?['period_end'], '2027-08-31');

        // 2. Second scheduled read uses cached 3 fields -> server drops older 101 ->
        //    completeness check rejects it, logs loudly, and reloads the full page!
        final logs = <String>[];
        final bak2 = BakalariClient(
          Map.of(fakeConfig),
          transport: server,
          logger: logs.add,
        )
          ..knownOutboxForm = Map<String, Object?>.of(bak.knownOutboxForm!)
          ..knownOutboxDetails = Map.of(bak.knownOutboxDetails);
        final second = await bak2.fetchSentExcuses(useCachedForm: true);
        expect(second, hasLength(2));
        expect(server.calls('GET', '/next/komens.aspx'), hasLength(2));
        expect(
          logs.any((l) => l.contains('Komens cached form fields rejected')),
          isTrue,
        );
        expect(bak2.sentExcusesFrom, DateTime(2026, 8, 20));

        // 3. Manual refresh (useCachedForm: false) ALWAYS loads the full page.
        final bak3 = BakalariClient(Map.of(fakeConfig), transport: server)
          ..knownOutboxForm = Map<String, Object?>.of(bak2.knownOutboxForm!)
          ..knownOutboxDetails = Map.of(bak2.knownOutboxDetails);
        await bak3.fetchSentExcuses(useCachedForm: false);
        expect(server.calls('GET', '/next/komens.aspx'), hasLength(3));
      });
    });

    test('cachedOutboxFieldsSucceedWithoutPageLoadWhenComplete', () async {
      final now = DateTime(2026, 11, 20, 10, 0);
      await withClock(Clock.fixed(now), () async {
        final server = FakeBakalari({
          'GET /next/komens.aspx': outboxPageHtml(
            periodLabel: '20.8.2026 - 31.8.2027',
          ),
          'POST /next/komens.aspx': (_) => dxReply(
                '<div class="komens-messages-wrapper">'
                '<table data-idmsg="202" data-sortdate="0:2026-11-10T08:00:00" data-msgtype="OMLUVENKA"></table>'
                '<table data-idmsg="101" data-sortdate="0:2026-09-10T08:00:00" data-msgtype="OMLUVENKA"></table>'
                '</div>',
              ),
          'POST /Komens/GetMessageDataAsync': (FakeRequest req) {
            final body = jsonDecode(utf8.decode(req.body)) as Map;
            final day = body['idmsg'] == '101' ? '10.09.2026' : '10.11.2026';
            return {'Kind': 'OMLUVENKA', 'DateFrom': day, 'DateTo': day};
          },
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server)
          ..knownOutboxForm = {
            'path': '/next/komens.aspx?s=rok&l=o',
            'viewstate': 'vs-year',
            'viewstate_generator': 'VSG12345',
            'event_validation': 'ev-year',
            'period_start': '2026-08-20',
            'period_end': '2027-08-31',
            'fetched_at': now.subtract(const Duration(hours: 6)).toIso8601String(),
          }
          ..knownOutboxDetails = {
            '101|0:2026-09-10T08:00:00': [
              {
                'type': 'pure days',
                'starting_day': '10.09.2026',
                'ending_day': '10.09.2026',
              }
            ],
          };
        final entries = await bak.fetchSentExcuses(useCachedForm: true);
        expect(entries, hasLength(2));
        expect(server.calls('GET', '/next/komens.aspx'), isEmpty);
        expect(bak.sentExcusesFrom, DateTime(2026, 8, 20));
      });
    });

    test('rejectedCachedOutboxWithFailedReloadNeverReleasesUnconfirmed (R8a M1)',
        () async {
      final now = DateTime(2026, 11, 20, 10, 0);
      await withClock(Clock.fixed(now), () async {
        final server = FakeBakalari({
          'GET /next/komens.aspx':
              HttpResponseData(statusCode: 500, url: Uri.parse(fakeRoot)),
          // 3-field callback returns only recent 202 (missing known 101).
          'POST /next/komens.aspx': (_) => dxReply(
                '<div class="komens-messages-wrapper">'
                '<table data-idmsg="202" data-sortdate="0:2026-11-10T08:00:00" data-msgtype="OMLUVENKA"></table>'
                '</div>',
              ),
        });
        final bak = BakalariClient(Map.of(fakeConfig), transport: server)
          ..knownOutboxForm = {
            'path': '/next/komens.aspx?s=rok&l=o',
            'viewstate': 'vs-year',
            'viewstate_generator': 'VSG12345',
            'event_validation': 'ev-year',
            'period_start': '2026-08-20',
            'period_end': '2027-08-31',
            'fetched_at': now.subtract(const Duration(hours: 1)).toIso8601String(),
          }
          ..knownOutboxDetails = {
            '101|0:2026-09-10T08:00:00': [
              {
                'type': 'pure days',
                'starting_day': '10.09.2026',
                'ending_day': '10.09.2026',
              }
            ],
          };
        final result = await bak.fetchSentExcuses(useCachedForm: true);
        expect(result, isNull);
        expect(bak.sentExcuses, isNull);
        expect(bak.sentExcusesFrom, isNull);
        expect(bak.outboxDetailsUpdated, isFalse);
        expect(bak.outboxFormUpdated, isFalse);
      });
    });

    test('fetchDataOrderAndCachedStableBaselineMatchesFullRun (R8a S1, S3, S4, S5)',
        () async {
      final now = DateTime(2026, 9, 7, 10, 0); // Monday
      await withClock(Clock.fixed(now), () async {
        final permLesson = {
          'IdentCode': '1       003T2RD',
          'day': 'Pondělí',
          'time': '1 (8:00 - 8:45)',
          'subjecttext': 'Matematika',
          'teacher': 'Mgr. Novák',
          'room': '104',
        };
        final cancelledActual = {
          'IdentCode': '12026090703T2RD',
          'day': '7.9.2026',
          'time': '1 (8:00 - 8:45)',
          'subjecttext': '',
          'teacher': '',
          'room': '',
          'type': 'removed',
          'removedinfo': 'Odpadá',
        };

        FakeBakalari makeServer() => FakeBakalari({
              'GET /Absence/Continuous/GetAbsenceBySubjects': {
                'data': [
                  {
                    'Name': 'Matematika',
                    'LessonCount': 10,
                    'Count': 1,
                    'Percent': 0.1,
                  }
                ],
              },
              'POST /Timetable/substitutions/dates': {
                'success': true,
                'data': <Object?>[],
              },
              'POST /Timetable/GetContentData': (FakeRequest req) {
                final payload = jsonDecode(utf8.decode(req.body)) as Map;
                if (payload['term'] == 'perm') {
                  return weekContent([permLesson]);
                }
                return weekContent([cancelledActual]);
              },
              'GET /Marks/Widget': marksWidgetHtml([
                {
                  'grade': '1',
                  'subject': 'Matematika',
                  'note': 'Test',
                  'date': '7.9.',
                  'is_new': true,
                }
              ]),
              'GET /next/prubzna.aspx': '<html>prubzna.aspx</html>',
              'POST /Teaching/Subjects': {
                'data': [
                  {'SubjectName': 'Matematika', 'TeacherName': 'Mgr. Novák'}
                ],
              },
            });

        // 1. Full run: check fetch order (absence -> feed -> weeks -> perm -> widget -> grades -> subjects).
        final fullServer = makeServer();
        final fullClient = BakalariClient(
          {...fakeConfig, 'go_back_weeks': 0, 'go_forward_weeks': 0},
          transport: fullServer,
        );
        final fullData = await fullClient.fetchData(
          weekOffsetsOverride: [0],
          fetchMarksWidget: true,
        );
        final paths = fullServer.requests.map((r) => '${r.method} ${r.url.path}').toList();
        final iAbs = paths.indexOf('GET /Absence/Continuous/GetAbsenceBySubjects');
        final iFeed = paths.indexOf('POST /Timetable/substitutions/dates');
        final iWeek = paths.indexOf('POST /Timetable/GetContentData');
        final iWidget = paths.indexOf('GET /Marks/Widget');
        final iGrades = paths.indexOf('GET /next/prubzna.aspx');
        expect(iAbs, lessThan(iFeed));
        expect(iFeed, lessThan(iWeek));
        expect(iWidget, lessThan(iGrades));
        expect(fullClient.marksWidget, hasLength(1));
        expect((fullData['stable_baseline'] as Map).isNotEmpty, isTrue);
        expect((fullData['timetable'] as Map).isNotEmpty, isTrue);

        // 2. Run skipping perm with cached stable_baseline produces identical timetable days!
        final cachedServer = makeServer();
        final cachedClient = BakalariClient(
          {...fakeConfig, 'go_back_weeks': 0, 'go_forward_weeks': 0},
          transport: cachedServer,
        );
        final cachedData = await cachedClient.fetchData(
          weekOffsetsOverride: [0],
          fetchStable: false,
          cachedStableBaseline:
              (fullData['stable_baseline'] as Map).cast<String, Object?>(),
        );
        expect(cachedClient.stableComplete, isTrue);
        expect(cachedData.containsKey('stable_baseline'), isFalse);
        expect(cachedData['timetable'], fullData['timetable']);
        expect(jsonEncode(cachedData['timetable']), contains('Matematika'));
        // Only 1 GetContentData call (cal), 0 perm calls.
        expect(
          cachedServer.calls('POST', '/Timetable/GetContentData'),
          hasLength(1),
        );
      });
    });
  });
}
