import 'dart:convert';

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
            return outboxListing(slice, const []);
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
        expect(
            calls.single.url.queryParameters['dateFrom'],
            '2026-09-01T00:00:00+02:00');
      }
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
}
